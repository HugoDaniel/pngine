//! WASM Module Emission
//!
//! Handles emission of WASM-related declarations:
//! - #wasmCall (WASM module loading + function call definitions)
//!
//! ## Emission Order
//!
//! 1. Collect unique WASM modules from #wasmCall declarations
//! 2. Read .wasm files from disk and add to data section
//! 3. Emit init_wasm_module opcodes for each module
//! 4. Track call IDs for queue dataFrom={wasm=...} references
//!
//! ## Invariants
//!
//! * Module IDs are assigned per unique URL (multiple calls can share one module).
//! * Call IDs are assigned sequentially for each #wasmCall declaration.
//! * WASM file must exist and be readable at compile time.
//! * Function name is interned in string table for runtime lookup.
//! * All iteration is bounded by MAX_WASM_MODULES or MAX_WASM_ARGS.

const std = @import("std");
const Emitter = @import("../Emitter.zig").Emitter;
const Node = @import("../Ast.zig").Node;
const opcodes = @import("../../bytecode/opcodes.zig");
const utils = @import("utils.zig");
const fs = std.fs;

/// Maximum WASM modules to process.
const MAX_WASM_MODULES: u32 = 64;

/// Maximum arguments per WASM call.
const MAX_WASM_ARGS: u32 = 16;

/// Maximum file size for WASM modules (4 MB).
const MAX_WASM_FILE_SIZE: u32 = 4 * 1024 * 1024;

/// WASM module info for deduplication.
const WasmModuleInfo = struct {
    module_id: u16,
    data_id: u16,
};

/// Read file into allocated buffer.
/// Caller owns returned memory.
fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // Pre-condition
    std.debug.assert(path.len > 0);

    const file = try fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const size: u32 = if (stat.size > MAX_WASM_FILE_SIZE)
        return error.FileTooLarge
    else
        @intCast(stat.size);

    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    // Bounded read loop
    var bytes_read: u32 = 0;
    for (0..size + 1) |_| {
        if (bytes_read >= size) break;
        const n: u32 = @intCast(try file.read(buffer[bytes_read..]));
        if (n == 0) break;
        bytes_read += n;
    }

    // Post-condition
    std.debug.assert(bytes_read <= size);

    return buffer;
}

/// Emit #wasmCall declarations.
///
/// This function:
/// 1. Collects unique WASM module URLs
/// 2. Reads .wasm files and adds to data section
/// 3. Emits init_wasm_module opcodes
/// 4. Registers call IDs for later use in queue emission
pub fn emitWasmCalls(e: *Emitter) Emitter.Error!void {
    // Pre-condition: AST must be valid
    std.debug.assert(e.ast.nodes.len > 0);

    const initial_module_id = e.next_wasm_module_id;
    const initial_call_id = e.next_wasm_call_id;

    // Track unique modules by URL to avoid duplicate loading
    var module_by_url = std.StringHashMapUnmanaged(WasmModuleInfo){};
    defer module_by_url.deinit(e.gpa);

    var it = e.analysis.symbols.wasm_call.iterator();
    for (0..MAX_WASM_MODULES) |_| {
        const entry = it.next() orelse break;
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        // Assign call ID for this #wasmCall
        const call_id = e.next_wasm_call_id;
        e.next_wasm_call_id += 1;
        try e.wasm_call_ids.put(e.gpa, name, call_id);

        // Parse module URL: module={ url="..." }
        const module_prop = utils.findPropertyValue(e, info.node, "module") orelse continue;
        const module_tag = e.ast.nodes.items(.tag)[module_prop.toInt()];
        if (module_tag != .object) continue;

        const url_prop = utils.findPropertyValueInObject(e, module_prop, "url") orelse continue;
        const url = utils.getStringContent(e, url_prop);
        if (url.len == 0) continue;

        // Check if we already loaded this module
        if (module_by_url.get(url)) |existing| {
            // Reuse existing module
            try e.wasm_module_ids.put(e.gpa, name, existing.module_id);
            continue;
        }

        // Load new WASM module
        const module_id = e.next_wasm_module_id;
        e.next_wasm_module_id += 1;

        // Read WASM file from disk
        const base_dir = e.options.base_dir orelse ".";
        var path_buf: [4096]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_dir, url }) catch continue;

        const wasm_bytes = readFile(e.gpa, full_path) catch |err| {
            std.debug.print("Warning: Could not read WASM file '{s}': {}\n", .{ full_path, err });
            continue;
        };
        defer e.gpa.free(wasm_bytes);

        // Add WASM bytes to data section
        const data_id = e.builder.addData(e.gpa, wasm_bytes) catch continue;

        // Track module for deduplication
        // Note: url points to AST source which outlives this function, no need to dupe
        try module_by_url.put(e.gpa, url, .{
            .module_id = module_id,
            .data_id = data_id.toInt(),
        });

        // Track module ID by call name for later lookup
        try e.wasm_module_ids.put(e.gpa, name, module_id);

        // Emit init_wasm_module opcode
        try e.builder.getEmitter().initWasmModule(
            e.gpa,
            module_id,
            data_id.toInt(),
        );
    }

    // Post-condition: IDs were assigned
    std.debug.assert(e.next_wasm_module_id >= initial_module_id);
    std.debug.assert(e.next_wasm_call_id >= initial_call_id);
}

/// Emit a WASM call and buffer write for dataFrom={wasm=...}.
///
/// Called from frames.zig when processing queue writeBuffer with dataFrom.
/// Emits:
/// 1. call_wasm_func - calls the WASM function with encoded args
/// 2. write_buffer_from_wasm - writes result from WASM memory to GPU buffer
pub fn emitWasmCallForBuffer(
    e: *Emitter,
    wasm_call_name: []const u8,
    buffer_id: u16,
    offset: u32,
) Emitter.Error!void {
    // Pre-conditions
    std.debug.assert(wasm_call_name.len > 0);
    std.debug.assert(e.ast.nodes.len > 0);

    // Look up call ID
    const call_id = e.wasm_call_ids.get(wasm_call_name) orelse return;

    // Look up module ID (stored by call name)
    const module_id = e.wasm_module_ids.get(wasm_call_name) orelse return;

    // Get #wasmCall declaration for args and return type
    const call_info = e.analysis.symbols.wasm_call.get(wasm_call_name) orelse return;

    // Get function name and intern it
    const func_prop = utils.findPropertyValue(e, call_info.node, "func") orelse return;
    const func_tag = e.ast.nodes.items(.tag)[func_prop.toInt()];

    var func_name: []const u8 = "";
    if (func_tag == .identifier_value) {
        const token = e.ast.nodes.items(.main_token)[func_prop.toInt()];
        func_name = utils.getTokenSlice(e, token);
    } else if (func_tag == .string_value) {
        func_name = utils.getStringContent(e, func_prop);
    }

    if (func_name.len == 0) return;

    const func_name_id = e.builder.internString(e.gpa, func_name) catch return;

    // Encode arguments
    var args_buf: [256]u8 = undefined;
    const args = encodeWasmArgs(e, call_info.node, &args_buf) catch return;

    // Emit call_wasm_func
    try e.builder.getEmitter().callWasmFunc(
        e.gpa,
        call_id,
        module_id,
        func_name_id.toInt(),
        args,
    );

    // Get return type byte length
    const byte_len = getReturnsByteLength(e, call_info.node);
    if (byte_len == 0) return;

    // Emit write_buffer_from_wasm
    try e.builder.getEmitter().writeBufferFromWasm(
        e.gpa,
        call_id,
        buffer_id,
        offset,
        byte_len,
    );
}

/// Encode WASM function arguments from args=[...] property.
///
/// Returns encoded bytes: [arg_count:u8][arg_type:u8][value?:4 bytes]...
fn encodeWasmArgs(e: *Emitter, node: Node.Index, buf: []u8) ![]u8 {
    // Pre-condition
    std.debug.assert(node.toInt() < e.ast.nodes.len);
    std.debug.assert(buf.len >= 1);

    const args_prop = utils.findPropertyValue(e, node, "args") orelse {
        buf[0] = 0; // No arguments
        return buf[0..1];
    };

    const args_tag = e.ast.nodes.items(.tag)[args_prop.toInt()];
    if (args_tag != .array) {
        buf[0] = 0;
        return buf[0..1];
    }

    const array_data = e.ast.nodes.items(.data)[args_prop.toInt()];
    const elements = e.ast.extraData(array_data.extra_range);

    var offset: usize = 1; // Reserve first byte for count
    var arg_count: u8 = 0;

    const max_elements = @min(elements.len, MAX_WASM_ARGS);
    for (0..max_elements) |i| {
        const elem_idx = elements[i];
        const elem: Node.Index = @enumFromInt(elem_idx);

        const arg_type = parseArgType(e, elem);
        if (offset >= buf.len) break;

        buf[offset] = @intFromEnum(arg_type);
        offset += 1;
        arg_count += 1;

        // Add literal value bytes if needed
        const value_size = arg_type.valueByteSize();
        if (value_size > 0 and offset + value_size <= buf.len) {
            const literal = parseLiteralValue(e, elem, arg_type);
            @memcpy(buf[offset .. offset + value_size], &literal);
            offset += value_size;
        }
    }

    buf[0] = arg_count;

    // Post-condition: encoded data is valid
    std.debug.assert(offset <= buf.len);
    std.debug.assert(arg_count <= MAX_WASM_ARGS);

    return buf[0..offset];
}

/// Parse argument type from a node.
/// Recognizes: canvas.width, time.total, literals
fn parseArgType(e: *Emitter, node: Node.Index) opcodes.WasmArgType {
    const tag = e.ast.nodes.items(.tag)[node.toInt()];

    // Handle builtin refs (canvas.width, time.total)
    if (tag == .builtin_ref) {
        return classifyBuiltinRef(e, node);
    }

    // Handle number values
    if (tag == .number_value) {
        // Check if it's a float or integer
        const token = e.ast.nodes.items(.main_token)[node.toInt()];
        const text = utils.getTokenSlice(e, token);
        if (std.mem.indexOf(u8, text, ".") != null) {
            return .literal_f32;
        }
        return .literal_u32;
    } else if (tag == .expr_negate) {
        // Negative number
        return .literal_f32;
    }

    return .literal_f32; // Default
}

/// Classify a builtin ref node (canvas.width, time.total).
fn classifyBuiltinRef(e: *Emitter, node: Node.Index) opcodes.WasmArgType {
    const data = e.ast.nodes.items(.data)[node.toInt()];
    const namespace_token = data.node_and_node[0];
    const property_token = data.node_and_node[1];

    const namespace = utils.getTokenSlice(e, namespace_token);
    const property = utils.getTokenSlice(e, property_token);

    if (std.mem.eql(u8, namespace, "canvas")) {
        if (std.mem.eql(u8, property, "width")) return .canvas_width;
        if (std.mem.eql(u8, property, "height")) return .canvas_height;
    } else if (std.mem.eql(u8, namespace, "time")) {
        if (std.mem.eql(u8, property, "total")) return .time_total;
        if (std.mem.eql(u8, property, "delta")) return .time_delta;
    }

    return .literal_f32; // Unknown builtin - treat as literal
}

/// Parse literal value from a node into 4 bytes.
fn parseLiteralValue(e: *Emitter, node: Node.Index, arg_type: opcodes.WasmArgType) [4]u8 {
    const tag = e.ast.nodes.items(.tag)[node.toInt()];

    if (tag == .number_value) {
        const token = e.ast.nodes.items(.main_token)[node.toInt()];
        const text = utils.getTokenSlice(e, token);

        return switch (arg_type) {
            .literal_f32 => blk: {
                const val = std.fmt.parseFloat(f32, text) catch 0.0;
                break :blk @bitCast(val);
            },
            .literal_i32 => blk: {
                const val = std.fmt.parseInt(i32, text, 10) catch 0;
                break :blk @bitCast(val);
            },
            .literal_u32 => blk: {
                const val = std.fmt.parseInt(u32, text, 10) catch 0;
                break :blk @bitCast(val);
            },
            else => std.mem.zeroes([4]u8),
        };
    } else if (tag == .expr_negate) {
        // Handle negative numbers
        const neg_data = e.ast.nodes.items(.data)[node.toInt()];
        const inner: Node.Index = neg_data.node;
        const inner_tag = e.ast.nodes.items(.tag)[inner.toInt()];

        if (inner_tag == .number_value) {
            const token = e.ast.nodes.items(.main_token)[inner.toInt()];
            const text = utils.getTokenSlice(e, token);
            const val = std.fmt.parseFloat(f32, text) catch 0.0;
            return @bitCast(-val);
        }
    }

    return std.mem.zeroes([4]u8);
}

/// Get return type byte length from returns="mat4x4" property.
fn getReturnsByteLength(e: *Emitter, node: Node.Index) u32 {
    const returns_prop = utils.findPropertyValue(e, node, "returns") orelse return 0;
    const returns_tag = e.ast.nodes.items(.tag)[returns_prop.toInt()];

    var type_name: []const u8 = "";
    if (returns_tag == .string_value) {
        type_name = utils.getStringContent(e, returns_prop);
    } else if (returns_tag == .identifier_value) {
        const token = e.ast.nodes.items(.main_token)[returns_prop.toInt()];
        type_name = utils.getTokenSlice(e, token);
    }

    return opcodes.WasmReturnType.byteSize(type_name) orelse 0;
}
