//! Resource Emission Module
//!
//! Handles emission of resource declarations:
//! - #data (float32Array, shapes like cube/plane, blob files, WASM data)
//! - #imageBitmap (create ImageBitmap from blob data)
//! - #buffer (GPU buffers)
//! - #texture (GPU textures)
//! - #sampler (GPU samplers)
//! - #bindGroup (bind groups)
//!
//! ## Shape Generators
//!
//! Compile-time vertex data generation for common shapes:
//! ```
//! #data cubeVertices {
//!   cube={ format=[position4 color4 uv2] }
//! }
//! ```
//! Supported shapes: cube, plane (sphere coming soon)
//!
//! ## Invariants
//!
//! * Resource IDs are assigned sequentially starting from their respective counters.
//! * Data section entries are created before buffer initialization.
//! * All iteration is bounded by MAX_RESOURCES or MAX_ARRAY_ELEMENTS.
//! * Texture canvas size is detected from canvas builtin refs in size array elements.
//! * Bind group entries are parsed before descriptor encoding.
//! * Blob files are read from base_dir + relative URL during compilation.

const std = @import("std");
const emitter_mod = @import("../Emitter.zig");
const Emitter = emitter_mod.Emitter;
const UniformBindingKey = emitter_mod.UniformBindingKey;
const Node = @import("../Ast.zig").Node;
const DescriptorEncoder = @import("../DescriptorEncoder.zig").DescriptorEncoder;
const utils = @import("utils.zig");
const shapes = @import("shapes.zig");

// Use bytecode module import
const bytecode_mod = @import("bytecode");
const uniform_table = bytecode_mod.uniform_table;

// Use reflect module import
const reflect = @import("reflect");
const fs = std.fs;

/// Maximum resources of each type (prevents runaway iteration).
const MAX_RESOURCES: u32 = 256;

/// Maximum array elements to process.
const MAX_ARRAY_ELEMENTS: u32 = 1024;

/// Maximum file size for embedded assets (16 MB).
const MAX_FILE_SIZE: u32 = 16 * 1024 * 1024;

/// Read file into allocated buffer.
/// Caller owns returned memory.
fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // Pre-condition
    std.debug.assert(path.len > 0);

    const file = try fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const size: u32 = if (stat.size > MAX_FILE_SIZE)
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

/// Emit #data declarations to the data section.
///
/// Processes all `#data` macros and adds their content to the bytecode data section.
/// Supports three data types:
/// - `float32Array`: Inline f32 values or runtime-generated arrays
/// - `blob`: File embedding from disk (requires base_dir)
/// - `wasm`: WASM-generated data with module + function reference
///
/// No bytecode is emitted directly; data is stored in the data section for
/// buffer initialization via `mappedAtCreation` or runtime writes.
///
/// Complexity: O(n × m) where n = data declarations, m = average elements per declaration.
pub fn emitData(e: *Emitter) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(e.ast.nodes.len > 0);

    const initial_count = e.data_ids.count();

    var it = e.analysis.symbols.data.iterator();
    for (0..MAX_RESOURCES) |_| {
        const entry = it.next() orelse break;
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        // Try float32Array first
        if (utils.findPropertyValue(e, info.node, "float32Array")) |float_array| {
            try emitFloat32ArrayData(e, name, float_array);
            continue;
        }

        // Try shape generators (cube, plane, sphere)
        if (utils.findPropertyValue(e, info.node, "cube")) |shape_node| {
            try emitShapeData(e, name, shape_node, .cube);
            continue;
        }
        if (utils.findPropertyValue(e, info.node, "plane")) |shape_node| {
            try emitShapeData(e, name, shape_node, .plane);
            continue;
        }

        // Try blob property (file embedding)
        if (utils.findPropertyValue(e, info.node, "blob")) |blob_node| {
            try emitBlobData(e, name, blob_node, info.node);
            continue;
        }

        // Try wasm property (WASM-generated data)
        if (utils.findPropertyValue(e, info.node, "wasm")) |wasm_node| {
            try emitWasmData(e, name, wasm_node);
            continue;
        }
    } else unreachable; // Exceeded MAX_RESOURCES

    // Post-condition: we processed data symbols
    std.debug.assert(e.data_ids.count() >= initial_count);
}

/// Pool info for ping-pong resources (buffers, bind groups).
/// Used when pool=N is specified on a resource.
pub const PoolInfo = struct {
    /// Base resource ID (first in the pool).
    base_id: u16,
    /// Number of resources in the pool.
    pool_size: u8,
};

/// Extended bind group entry with pingPong offset for pooled resources.
/// Used during parsing before adjusting resource IDs for each pool instance.
pub const BindGroupEntryWithPingPong = struct {
    /// Underlying bind group entry data.
    entry: DescriptorEncoder.BindGroupEntry,
    /// PingPong offset for pooled resources (0 = no offset).
    ping_pong: u8,
    /// Buffer name for pool lookup (if applicable).
    buffer_name: []const u8,
};

/// Emit float32Array data to data section (inline array only).
/// Generated arrays via runtime opcodes have been removed - use WASM calls or compute shaders.
fn emitFloat32ArrayData(e: *Emitter, name: []const u8, float_array: Node.Index) Emitter.Error!void {
    const array_tag = e.ast.nodes.items(.tag)[float_array.toInt()];

    // Only inline arrays are supported
    if (array_tag == .array) {
        try emitInlineFloat32Array(e, name, float_array);
        return;
    }

    // Object syntax (numberOfElements + initEachElementWith) is no longer supported
    // Use WASM calls or compute shaders for buffer initialization instead
}

/// Shape type enumeration
const ShapeType = enum { cube, plane };

/// Emit shape data to data section using compile-time shape generators.
/// Parses format array from shape property and generates vertices.
fn emitShapeData(e: *Emitter, name: []const u8, shape_node: Node.Index, shape_type: ShapeType) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(shape_node.toInt() < e.ast.nodes.len);

    // Parse format array from shape config (shape_node is an object: { format=[...] })
    var format_buf: [8]shapes.Format = undefined;
    var format_count: usize = 0;

    if (utils.findPropertyValueInObject(e, shape_node, "format")) |format_node| {
        const format_tag = e.ast.nodes.items(.tag)[format_node.toInt()];
        if (format_tag == .array) {
            const array_data = e.ast.nodes.items(.data)[format_node.toInt()];
            const elements = e.ast.extraData(array_data.extra_range);

            for (0..@min(elements.len, 8)) |i| {
                const elem: Node.Index = @enumFromInt(elements[i]);
                const elem_tag = e.ast.nodes.items(.tag)[elem.toInt()];

                if (elem_tag == .identifier_value) {
                    const token = e.ast.nodes.items(.main_token)[elem.toInt()];
                    const fmt_name = utils.getTokenSlice(e, token);

                    if (shapes.Format.fromString(fmt_name)) |fmt| {
                        format_buf[format_count] = fmt;
                        format_count += 1;
                    }
                }
            }
        }
    }

    // Default format if none specified
    if (format_count == 0) {
        format_buf[0] = .position4;
        format_buf[1] = .color4;
        format_buf[2] = .uv2;
        format_count = 3;
    }

    const config = shapes.ShapeConfig{
        .formats = format_buf[0..format_count],
    };

    // Generate shape vertices
    const bytes = switch (shape_type) {
        .cube => shapes.generateCube(e.gpa, config) catch return error.OutOfMemory,
        .plane => shapes.generatePlane(e.gpa, config) catch return error.OutOfMemory,
    };
    defer e.gpa.free(bytes);

    // Add to data section
    const data_id = try e.builder.addData(e.gpa, bytes);
    try e.data_ids.put(e.gpa, name, data_id.toInt());

    // Post-condition
    std.debug.assert(e.data_ids.get(name) != null);
}

/// Emit inline float32Array to data section (original behavior).
fn emitInlineFloat32Array(e: *Emitter, name: []const u8, float_array: Node.Index) Emitter.Error!void {
    // Get array elements
    const array_data = e.ast.nodes.items(.data)[float_array.toInt()];
    const elements = e.ast.extraData(array_data.extra_range);

    // Convert elements to f32 bytes
    var bytes = std.ArrayListUnmanaged(u8){};
    defer bytes.deinit(e.gpa);

    // Bounded iteration over elements
    const max_elements = @min(elements.len, MAX_ARRAY_ELEMENTS);
    for (0..max_elements) |i| {
        const elem_idx = elements[i];
        const elem: Node.Index = @enumFromInt(elem_idx);
        const value = parseFloatElement(e, elem);

        // Write f32 as little-endian bytes
        const f32_bytes = @as([4]u8, @bitCast(value));
        try bytes.appendSlice(e.gpa, &f32_bytes);
    }

    // Add to data section
    const data_id = try e.builder.addData(e.gpa, bytes.items);
    try e.data_ids.put(e.gpa, name, data_id.toInt());
}

/// Resolve element count from numberOfElements property.
/// Handles both literal numbers and #define references.
fn resolveElementCount(e: *Emitter, node: Node.Index) u32 {
    const tag = e.ast.nodes.items(.tag)[node.toInt()];

    // Direct number
    if (tag == .number_value) {
        return utils.parseNumber(e, node) orelse 0;
    }

    // Identifier reference (e.g., NUM_PARTICLES from #define)
    if (tag == .identifier_value) {
        const token = e.ast.nodes.items(.main_token)[node.toInt()];
        const name = utils.getTokenSlice(e, token);

        // Look up in defines
        if (e.analysis.symbols.define.get(name)) |info| {
            const define_data = e.ast.nodes.items(.data)[info.node.toInt()];
            const value_node = define_data.node;
            return utils.resolveNumericValueOrString(e, value_node) orelse 0;
        }
    }

    // Try resolving as expression
    return utils.resolveNumericValueOrString(e, node) orelse 0;
}

/// Get expression string from a node.
/// Handles string literals and identifier references.
fn getExpressionString(e: *Emitter, node: Node.Index) []const u8 {
    const tag = e.ast.nodes.items(.tag)[node.toInt()];

    if (tag == .string_value) {
        return utils.getStringContent(e, node);
    }

    if (tag == .identifier_value) {
        const token = e.ast.nodes.items(.main_token)[node.toInt()];
        return utils.getTokenSlice(e, token);
    }

    return "";
}

/// Emit blob file data to data section.
/// Format: [mime_len:u8][mime:bytes][data:bytes]
fn emitBlobData(e: *Emitter, name: []const u8, blob_node: Node.Index, data_node: Node.Index) Emitter.Error!void {
    const base_dir = e.options.base_dir orelse return; // Skip if no base_dir

    // Parse blob={file={url="..."}}
    const blob_tag = e.ast.nodes.items(.tag)[blob_node.toInt()];
    if (blob_tag != .object) return;

    const file_node = utils.findPropertyValueInObject(e, blob_node, "file") orelse return;
    const file_tag = e.ast.nodes.items(.tag)[file_node.toInt()];
    if (file_tag != .object) return;

    const url_node = utils.findPropertyValueInObject(e, file_node, "url") orelse return;
    const url = utils.getStringContent(e, url_node);
    if (url.len == 0) return;

    // Get mime type from parent data node
    const mime = if (utils.findPropertyValue(e, data_node, "mime")) |mime_node|
        utils.getStringContent(e, mime_node)
    else
        "application/octet-stream";

    // Construct full path: base_dir + url
    var path_buf: [4096]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_dir, url }) catch return;

    // Read file from disk
    const file_data = readFile(e.gpa, full_path) catch |err| {
        std.debug.print("Warning: Could not read file '{s}': {}\n", .{ full_path, err });
        return;
    };
    defer e.gpa.free(file_data);

    // Build data entry: [mime_len:u8][mime:bytes][data:bytes]
    var bytes = std.ArrayListUnmanaged(u8){};
    defer bytes.deinit(e.gpa);

    const mime_len: u8 = @intCast(@min(mime.len, 255));
    try bytes.append(e.gpa, mime_len);
    try bytes.appendSlice(e.gpa, mime[0..mime_len]);
    try bytes.appendSlice(e.gpa, file_data);

    // Add to data section
    const data_id = try e.builder.addData(e.gpa, bytes.items);
    try e.data_ids.put(e.gpa, name, data_id.toInt());
}

/// Emit WASM-generated data entry.
/// Embeds WASM module and registers entry for runtime data generation.
fn emitWasmData(e: *Emitter, name: []const u8, wasm_node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(wasm_node.toInt() < e.ast.nodes.len);
    std.debug.assert(name.len > 0);

    const base_dir = e.options.base_dir orelse return;

    // Parse wasm={module={url=...}, func=..., returns=...}
    const wasm_tag = e.ast.nodes.items(.tag)[wasm_node.toInt()];
    if (wasm_tag != .object) return;

    // Get module URL
    const module_node = utils.findPropertyValueInObject(e, wasm_node, "module") orelse return;
    const module_tag = e.ast.nodes.items(.tag)[module_node.toInt()];
    if (module_tag != .object) return;

    const url_node = utils.findPropertyValueInObject(e, module_node, "url") orelse return;
    const url = utils.getStringContent(e, url_node);
    if (url.len == 0) return;

    // Get function name
    const func_node = utils.findPropertyValueInObject(e, wasm_node, "func") orelse return;
    const func_tag = e.ast.nodes.items(.tag)[func_node.toInt()];
    var func_name: []const u8 = "";
    if (func_tag == .identifier_value) {
        const token = e.ast.nodes.items(.main_token)[func_node.toInt()];
        func_name = utils.getTokenSlice(e, token);
    } else if (func_tag == .string_value) {
        func_name = utils.getStringContent(e, func_node);
    }
    if (func_name.len == 0) return;

    // Get returns type and parse byte size
    const returns_node = utils.findPropertyValueInObject(e, wasm_node, "returns") orelse return;
    const returns_str = utils.getStringContent(e, returns_node);
    const byte_size = parseWgslReturnType(returns_str);
    if (byte_size == 0) return;

    // Read WASM file
    var path_buf: [4096]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_dir, url }) catch return;

    const wasm_bytes = readFile(e.gpa, full_path) catch |err| {
        std.debug.print("Warning: Could not read WASM file '{s}': {}\n", .{ full_path, err });
        return;
    };
    defer e.gpa.free(wasm_bytes);

    // Add WASM to data section
    const wasm_data_id = e.builder.addData(e.gpa, wasm_bytes) catch return;

    // Assign module ID
    const module_id = e.next_wasm_module_id;
    e.next_wasm_module_id += 1;

    // Emit init_wasm_module opcode
    try e.builder.getEmitter().initWasmModule(e.gpa, module_id, wasm_data_id.toInt());

    // Intern function name
    const func_name_id = e.builder.internString(e.gpa, func_name) catch return;

    // Register WASM data entry for buffer initialization
    try e.wasm_data_entries.put(e.gpa, name, .{
        .module_id = module_id,
        .wasm_data_id = wasm_data_id.toInt(),
        .func_name_id = func_name_id.toInt(),
        .byte_size = byte_size,
    });

    // Post-condition: entry was registered
    std.debug.assert(e.wasm_data_entries.get(name) != null);
}

/// Parse WGSL return type to byte size.
/// Supports: array<f32, N>, mat4x4, vec4, f32, etc.
fn parseWgslReturnType(type_str: []const u8) u32 {
    // Pre-condition
    if (type_str.len == 0) return 0;

    // Handle array<type, count>
    if (std.mem.startsWith(u8, type_str, "array<")) {
        // Find the count after the comma
        if (std.mem.lastIndexOf(u8, type_str, ",")) |comma_pos| {
            const after_comma = type_str[comma_pos + 1 ..];
            // Find the closing >
            if (std.mem.indexOf(u8, after_comma, ">")) |gt_pos| {
                const count_str = std.mem.trim(u8, after_comma[0..gt_pos], " \t");
                const count = std.fmt.parseInt(u32, count_str, 10) catch return 0;

                // Determine element size from type (between < and ,)
                const type_start = 6; // "array<".len
                const elem_type = std.mem.trim(u8, type_str[type_start..comma_pos], " \t");
                const elem_size = getTypeSize(elem_type);

                return count * elem_size;
            }
        }
        return 0;
    }

    // Simple type
    return getTypeSize(type_str);
}

/// Get byte size of a WGSL type.
fn getTypeSize(type_name: []const u8) u32 {
    const type_sizes = [_]struct { name: []const u8, size: u32 }{
        .{ .name = "f32", .size = 4 },
        .{ .name = "i32", .size = 4 },
        .{ .name = "u32", .size = 4 },
        .{ .name = "f16", .size = 2 },
        .{ .name = "vec2", .size = 8 },
        .{ .name = "vec2f", .size = 8 },
        .{ .name = "vec2i", .size = 8 },
        .{ .name = "vec2u", .size = 8 },
        .{ .name = "vec3", .size = 12 },
        .{ .name = "vec3f", .size = 12 },
        .{ .name = "vec3i", .size = 12 },
        .{ .name = "vec3u", .size = 12 },
        .{ .name = "vec4", .size = 16 },
        .{ .name = "vec4f", .size = 16 },
        .{ .name = "vec4i", .size = 16 },
        .{ .name = "vec4u", .size = 16 },
        .{ .name = "mat2x2", .size = 16 },
        .{ .name = "mat2x2f", .size = 16 },
        .{ .name = "mat3x3", .size = 36 },
        .{ .name = "mat3x3f", .size = 36 },
        .{ .name = "mat4x4", .size = 64 },
        .{ .name = "mat4x4f", .size = 64 },
    };

    for (type_sizes) |entry| {
        if (std.mem.eql(u8, type_name, entry.name)) {
            return entry.size;
        }
    }

    return 0;
}

/// Parse a float value from an array element node.
fn parseFloatElement(e: *Emitter, elem: Node.Index) f32 {
    // Pre-condition
    std.debug.assert(elem.toInt() < e.ast.nodes.len);

    const elem_tag = e.ast.nodes.items(.tag)[elem.toInt()];

    if (elem_tag == .number_value) {
        const token = e.ast.nodes.items(.main_token)[elem.toInt()];
        const text = utils.getTokenSlice(e, token);
        return std.fmt.parseFloat(f32, text) catch 0.0;
    } else if (elem_tag == .expr_negate) {
        // Handle negative numbers: -X
        const neg_data = e.ast.nodes.items(.data)[elem.toInt()];
        const inner: Node.Index = neg_data.node;
        const inner_tag = e.ast.nodes.items(.tag)[inner.toInt()];
        if (inner_tag == .number_value) {
            const token = e.ast.nodes.items(.main_token)[inner.toInt()];
            const text = utils.getTokenSlice(e, token);
            const parsed = std.fmt.parseFloat(f32, text) catch 0.0;
            return -parsed;
        }
    }
    // Unhandled tags (identifiers, etc.) result in 0.0
    return 0.0;
}

/// Emit #buffer declarations to bytecode.
///
/// Processes all `#buffer` macros and emits `create_buffer` opcodes.
/// Supports pool=N for ping-pong buffer patterns (creates N sequential buffers).
///
/// Buffer initialization modes:
/// - `mappedAtCreation=dataName`: Pre-fill with inline data from #data
/// - `mappedAtCreation=wasmDataName`: Pre-fill with WASM-generated data
/// - `mappedAtCreation=generatedArrayName`: Pre-fill with runtime-generated array
///
/// Pool buffers get sequential IDs: buffer_0, buffer_1, ... buffer_{N-1}.
/// The base ID is stored in buffer_ids for reference resolution.
///
/// Complexity: O(n × p) where n = buffer declarations, p = average pool size.
pub fn emitBuffers(e: *Emitter) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(e.ast.nodes.len > 0);

    const initial_buffer_id = e.next_buffer_id;

    var it = e.analysis.symbols.buffer.iterator();
    for (0..MAX_RESOURCES) |_| {
        const entry = it.next() orelse break;
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        // Check for pool property (ping-pong buffers)
        const pool_size: u8 = if (utils.findPropertyValue(e, info.node, "pool")) |pool_node|
            @intCast(utils.parseNumber(e, pool_node) orelse 1)
        else
            1;

        const base_buffer_id = e.next_buffer_id;

        // Store pool info if pool_size > 1
        if (pool_size > 1) {
            try e.buffer_pools.put(e.gpa, name, .{
                .base_id = base_buffer_id,
                .pool_size = pool_size,
            });
        }

        // Register the base buffer ID with the name
        try e.buffer_ids.put(e.gpa, name, base_buffer_id);

        // Get size property - can be number, expression, string expression, or WASM data reference
        const size_value = utils.findPropertyValue(e, info.node, "size") orelse continue;
        const size = resolveBufferSize(e, size_value);

        // Get usage flags
        var usage = utils.parseBufferUsage(e, info.node);

        // Check for mappedAtCreation - requires COPY_DST for write_buffer
        const mapped_value = utils.findPropertyValue(e, info.node, "mappedAtCreation");
        if (mapped_value != null) {
            usage.copy_dst = true;

            // Validate buffer size >= data size
            try validateBufferDataSize(e, name, size, mapped_value.?);
        }

        // Create pool_size buffers with sequential IDs
        for (0..pool_size) |i| {
            const buffer_id = e.next_buffer_id;
            e.next_buffer_id += 1;

            try e.builder.getEmitter().createBuffer(
                e.gpa,
                buffer_id,
                @intCast(size),
                @bitCast(usage),
            );

            // If mappedAtCreation is set, initialize all pool buffers with the same data
            if (mapped_value) |mv| {
                try emitBufferInitialization(e, buffer_id, mv);
            }

            // Record uniform binding for runtime reflection (only for base buffer)
            // This allows runtime to set uniforms by field name
            if (i == 0) {
                try recordUniformBinding(e, size_value, buffer_id);
            }
        }
    }

    // Post-condition: buffer IDs were assigned sequentially
    std.debug.assert(e.next_buffer_id >= initial_buffer_id);
}

/// Resolve buffer size from size property value.
/// Handles: numbers, expressions, string expressions, identifier refs to #data,
/// and WGSL binding references (shader.binding for auto-sizing).
fn resolveBufferSize(e: *Emitter, size_node: Node.Index) u32 {
    // Pre-condition
    std.debug.assert(size_node.toInt() < e.ast.nodes.len);

    const size_tag = e.ast.nodes.items(.tag)[size_node.toInt()];

    // Check for uniform_access (shader.binding) - bare identifier syntax
    if (size_tag == .uniform_access) {
        const data = e.ast.nodes.items(.data)[size_node.toInt()];
        const module_token = data.node_and_node[0];
        const var_token = data.node_and_node[1];
        const module_name = utils.getTokenSlice(e, module_token);
        const var_name = utils.getTokenSlice(e, var_token);

        // Construct "module.var" for lookup
        var buf: [256]u8 = undefined;
        const full_name = std.fmt.bufPrint(&buf, "{s}.{s}", .{ module_name, var_name }) catch {
            std.log.warn("Could not format WGSL binding name", .{});
            return 0;
        };

        if (e.getBindingSizeFromWgsl(full_name)) |size| {
            return size;
        }
        std.log.warn("Could not resolve WGSL binding size for '{s}'", .{full_name});
        return 0;
    }

    // Check for identifier reference to #data (including WASM data)
    if (size_tag == .identifier_value) {
        const token = e.ast.nodes.items(.main_token)[size_node.toInt()];
        const data_name = utils.getTokenSlice(e, token);

        // Check WASM data entries (they store byte size)
        if (e.wasm_data_entries.get(data_name)) |wasm_entry| {
            return wasm_entry.byte_size;
        }

        // Check regular data entries (need to look up actual data size)
        if (e.data_ids.get(data_name)) |data_id| {
            // Get size from data section
            return e.builder.getDataSize(data_id);
        }
    }

    // Fall back to normal numeric resolution
    return utils.resolveNumericValueOrString(e, size_node) orelse 0;
}

/// Record uniform binding for runtime reflection.
/// If size_node is a shader.binding reference (uniform_access), extracts
/// the binding metadata from WGSL reflection and adds it to the uniform table.
///
/// Pre-condition: buffer_id is a valid buffer that was just created.
/// Post-condition: If size comes from shader binding, uniform table is updated.
fn recordUniformBinding(e: *Emitter, size_node: Node.Index, buffer_id: u16) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(size_node.toInt() < e.ast.nodes.len);

    const size_tag = e.ast.nodes.items(.tag)[size_node.toInt()];

    // Only process uniform_access (shader.binding) nodes
    if (size_tag != .uniform_access) return;

    const data = e.ast.nodes.items(.data)[size_node.toInt()];
    const module_token = data.node_and_node[0];
    const var_token = data.node_and_node[1];
    const module_name = utils.getTokenSlice(e, module_token);
    const binding_name = utils.getTokenSlice(e, var_token);

    // Get reflection data for the shader
    const reflection = e.getWgslReflection(module_name) orelse {
        std.log.warn("No WGSL reflection data for '{s}'", .{module_name});
        return;
    };

    // Find the binding by name
    const binding = reflection.getBindingByName(binding_name) orelse {
        std.log.warn("No binding '{s}' found in shader '{s}'", .{ binding_name, module_name });
        return;
    };

    // Intern the binding name in string table
    const binding_name_id = try e.builder.internString(e.gpa, binding.name);

    // Convert reflection fields to uniform table fields
    var fields_buf: [uniform_table.MAX_FIELDS]uniform_table.UniformField = undefined;
    var field_count: usize = 0;

    for (binding.layout.fields) |field| {
        if (field_count >= uniform_table.MAX_FIELDS) break;

        // Intern field name
        const field_name_id = try e.builder.internString(e.gpa, field.name);

        fields_buf[field_count] = .{
            .name_string_id = field_name_id.toInt(),
            .offset = @intCast(field.offset),
            .size = @intCast(field.size),
            .uniform_type = uniform_table.UniformType.fromWgslType(field.type),
        };
        field_count += 1;
    }

    // Add binding to uniform table
    try e.builder.addUniformBinding(
        e.gpa,
        buffer_id,
        binding_name_id.toInt(),
        @intCast(binding.group),
        @intCast(binding.binding),
        fields_buf[0..field_count],
    );
}

/// Validate that buffer size is sufficient for the data being written.
/// Returns EmitError if buffer size < data size.
///
/// Pre-condition: mapped_value is a valid AST node index
/// Post-condition: Returns error if buffer too small, ok otherwise
fn validateBufferDataSize(e: *Emitter, buffer_name: []const u8, buffer_size: u32, mapped_value: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(mapped_value.toInt() < e.ast.nodes.len);

    const value_tag = e.ast.nodes.items(.tag)[mapped_value.toInt()];
    if (value_tag != .identifier_value) return; // Not a data reference

    const token = e.ast.nodes.items(.main_token)[mapped_value.toInt()];
    const data_name = utils.getTokenSlice(e, token);

    // Check for regular data declaration
    if (e.data_ids.get(data_name)) |data_id| {
        const data_size = e.builder.getDataSize(data_id);
        if (buffer_size < data_size) {
            // Log at warn level (err causes test framework to fail)
            std.log.warn("buffer '{s}' size ({d} bytes) is smaller than data '{s}' ({d} bytes)", .{
                buffer_name,
                buffer_size,
                data_name,
                data_size,
            });
            return Emitter.Error.EmitError;
        }
    }

    // Check for generated arrays
    if (e.generated_arrays.get(data_name)) |gen_array| {
        if (buffer_size < gen_array.byte_size) {
            std.log.warn("buffer '{s}' size ({d} bytes) is smaller than generated array '{s}' ({d} bytes)", .{
                buffer_name,
                buffer_size,
                data_name,
                gen_array.byte_size,
            });
            return Emitter.Error.EmitError;
        }
    }

    // Check for WASM data entries
    if (e.wasm_data_entries.get(data_name)) |wasm_entry| {
        if (buffer_size < wasm_entry.byte_size) {
            std.log.warn("buffer '{s}' size ({d} bytes) is smaller than WASM data '{s}' ({d} bytes)", .{
                buffer_name,
                buffer_size,
                data_name,
                wasm_entry.byte_size,
            });
            return Emitter.Error.EmitError;
        }
    }

    // Post-condition: if we reach here, validation passed
}

/// Emit write_buffer for buffer initialization from mappedAtCreation.
/// Handles: inline data and WASM-generated data.
/// For runtime buffer initialization, use compute shaders via #init macro.
fn emitBufferInitialization(e: *Emitter, buffer_id: u16, mapped_value: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(mapped_value.toInt() < e.ast.nodes.len);

    const value_tag = e.ast.nodes.items(.tag)[mapped_value.toInt()];
    if (value_tag != .identifier_value) return;

    const token = e.ast.nodes.items(.main_token)[mapped_value.toInt()];
    const data_name = utils.getTokenSlice(e, token);

    // Check WASM data entries
    if (e.wasm_data_entries.get(data_name)) |wasm_entry| {
        // Emit call_wasm_func to generate the data
        // Note: For init-time WASM calls, we don't pass runtime args (canvas size, time)
        // The WASM function should return static data
        try e.builder.getEmitter().callWasmFunc(
            e.gpa,
            0, // call_id (not used for init-time calls)
            wasm_entry.module_id,
            wasm_entry.func_name_id,
            &[_]u8{0}, // No arguments for init-time data generation
        );

        // Emit write_buffer_from_wasm to copy result to buffer
        try e.builder.getEmitter().writeBufferFromWasm(
            e.gpa,
            0, // call_id (same as above)
            buffer_id,
            0, // offset
            wasm_entry.byte_size,
        );
        return;
    }

    // Look up the data_id for regular data declaration
    if (e.data_ids.get(data_name)) |data_id| {
        try e.builder.getEmitter().writeBuffer(
            e.gpa,
            buffer_id,
            0, // offset
            data_id,
        );
    }
}

/// Emit #texture declarations to bytecode.
///
/// Processes all `#texture` macros and emits `create_texture` opcodes.
/// Supports two size modes:
/// - Fixed size: `width=N height=M` - creates texture with specified dimensions
/// - Canvas size: `size=[canvas.width canvas.height]` - resizes with canvas
///
/// Texture descriptors are encoded to the data section and referenced by ID.
/// Canvas-sized textures use a special descriptor flag for runtime resizing.
///
/// Complexity: O(n) where n = texture declarations.
pub fn emitTextures(e: *Emitter) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(e.ast.nodes.len > 0);

    const initial_texture_id = e.next_texture_id;

    var it = e.analysis.symbols.texture.iterator();
    for (0..MAX_RESOURCES) |_| {
        const entry = it.next() orelse break;
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        const texture_id = e.next_texture_id;
        e.next_texture_id += 1;
        try e.texture_ids.put(e.gpa, name, texture_id);

        // Check if texture uses canvas size (size=[canvas.width canvas.height])
        const use_canvas_size = textureUsesCanvasSize(e, info.node);

        // Check if texture uses imageBitmap size (size=[img.width img.height])
        const image_bitmap_id = textureUsesImageBitmapSize(e, info.node);

        const sample_count = utils.parsePropertyNumber(e, info.node, "sampleCount") orelse 1;

        // Parse format
        const format_enum = utils.parseTextureFormat(e, info.node);

        // Parse usage flags
        const usage = utils.parseTextureUsage(e, info.node);

        // Encode descriptor
        const desc = if (use_canvas_size)
            DescriptorEncoder.encodeTextureCanvasSize(
                e.gpa,
                format_enum,
                usage,
                sample_count,
            ) catch return error.OutOfMemory
        else if (image_bitmap_id) |ib_id|
            DescriptorEncoder.encodeTextureImageBitmapSize(
                e.gpa,
                ib_id,
                format_enum,
                usage,
                sample_count,
            ) catch return error.OutOfMemory
        else blk: {
            const width = utils.parsePropertyNumber(e, info.node, "width") orelse 256;
            const height = utils.parsePropertyNumber(e, info.node, "height") orelse 256;
            break :blk DescriptorEncoder.encodeTexture(
                e.gpa,
                width,
                height,
                format_enum,
                usage,
                sample_count,
            ) catch return error.OutOfMemory;
        };
        defer e.gpa.free(desc);

        const desc_id = try e.builder.addData(e.gpa, desc);

        // Emit create_texture opcode
        try e.builder.getEmitter().createTexture(
            e.gpa,
            texture_id,
            desc_id.toInt(),
        );
    }

    // Post-condition: texture IDs were assigned sequentially
    std.debug.assert(e.next_texture_id >= initial_texture_id);
}

/// Check if texture has size=[canvas.width canvas.height] (builtin refs or legacy runtime interpolation strings).
pub fn textureUsesCanvasSize(e: *Emitter, node: Node.Index) bool {
    // Pre-condition
    std.debug.assert(node.toInt() < e.ast.nodes.len);

    const size_value = utils.findPropertyValue(e, node, "size") orelse return false;
    const size_tag = e.ast.nodes.items(.tag)[size_value.toInt()];

    if (size_tag != .array) return false;

    const array_data = e.ast.nodes.items(.data)[size_value.toInt()];
    const elements = e.ast.extraData(array_data.extra_range);

    // Check if any element is a builtin ref or runtime interpolation (legacy)
    for (elements) |elem_idx| {
        const elem: Node.Index = @enumFromInt(elem_idx);
        const elem_tag = e.ast.nodes.items(.tag)[elem.toInt()];

        // Builtin ref (canvas.width, canvas.height) - clean syntax
        if (elem_tag == .builtin_ref) {
            const data = e.ast.nodes.items(.data)[elem.toInt()];
            const namespace_token = data.node_and_node[0];
            const namespace = utils.getTokenSlice(e, namespace_token);
            if (std.mem.eql(u8, namespace, "canvas")) {
                return true;
            }
        }

        // Note: runtime_interpolation is deprecated and caught by Analyzer
    }

    return false;
}

/// Check if texture has size=[imageBitmap.width imageBitmap.height] (uniform_access refs to imageBitmap).
/// Returns the imageBitmap ID if found, null otherwise.
pub fn textureUsesImageBitmapSize(e: *Emitter, node: Node.Index) ?u16 {
    // Pre-condition
    std.debug.assert(node.toInt() < e.ast.nodes.len);

    const size_value = utils.findPropertyValue(e, node, "size") orelse return null;
    const size_tag = e.ast.nodes.items(.tag)[size_value.toInt()];

    if (size_tag != .array) return null;

    const array_data = e.ast.nodes.items(.data)[size_value.toInt()];
    const elements = e.ast.extraData(array_data.extra_range);

    // Check if any element is a uniform_access referencing an imageBitmap
    for (elements) |elem_idx| {
        const elem: Node.Index = @enumFromInt(elem_idx);
        const elem_tag = e.ast.nodes.items(.tag)[elem.toInt()];

        // uniform_access (imageBitmap.width, imageBitmap.height)
        if (elem_tag == .uniform_access) {
            const data = e.ast.nodes.items(.data)[elem.toInt()];
            const name_token = data.node_and_node[0];
            const prop_token = data.node_and_node[1];
            const name = utils.getTokenSlice(e, name_token);
            const prop = utils.getTokenSlice(e, prop_token);

            // Check if this references an imageBitmap and is width/height property
            if ((std.mem.eql(u8, prop, "width") or std.mem.eql(u8, prop, "height"))) {
                // Look up the imageBitmap ID
                if (e.image_bitmap_ids.get(name)) |ib_id| {
                    return ib_id;
                }
            }
        }
    }

    return null;
}

/// Emit #sampler declarations to bytecode.
///
/// Processes all `#sampler` macros and emits `create_sampler` opcodes.
/// Sampler descriptors are encoded to the data section and referenced by ID.
///
/// Supported properties:
/// - `magFilter`, `minFilter`: "nearest" | "linear"
/// - `addressMode`: "clamp-to-edge" | "repeat" | "mirror-repeat"
///
/// Complexity: O(n) where n = sampler declarations.
pub fn emitSamplers(e: *Emitter) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(e.ast.nodes.len > 0);

    const initial_sampler_id = e.next_sampler_id;

    var it = e.analysis.symbols.sampler.iterator();
    for (0..MAX_RESOURCES) |_| {
        const entry = it.next() orelse break;
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        const sampler_id = e.next_sampler_id;
        e.next_sampler_id += 1;
        try e.sampler_ids.put(e.gpa, name, sampler_id);

        // Parse sampler properties
        const mag_filter = utils.parseSamplerFilter(e, info.node, "magFilter");
        const min_filter = utils.parseSamplerFilter(e, info.node, "minFilter");
        const address_mode = utils.parseSamplerAddressMode(e, info.node);

        // Encode descriptor
        const desc = DescriptorEncoder.encodeSampler(
            e.gpa,
            mag_filter,
            min_filter,
            address_mode,
        ) catch return error.OutOfMemory;
        defer e.gpa.free(desc);

        const desc_id = try e.builder.addData(e.gpa, desc);

        // Emit create_sampler opcode
        try e.builder.getEmitter().createSampler(
            e.gpa,
            sampler_id,
            desc_id.toInt(),
        );
    }

    // Post-condition: sampler IDs were assigned sequentially
    std.debug.assert(e.next_sampler_id >= initial_sampler_id);
}

/// Emit #bindGroup declarations to bytecode.
///
/// Processes all `#bindGroup` macros and emits `create_bind_group` opcodes.
/// Supports pool=N for ping-pong bind group patterns.
///
/// Bind group entries reference resources by ID:
/// - `buffer`: References a #buffer (supports pingPong offset for pools)
/// - `texture`: References a #texture (creates implicit texture view)
/// - `sampler`: References a #sampler
///
/// Pool bind groups adjust buffer IDs based on pingPong offsets:
/// `actual_id = base_id + (pingPong + pool_idx) % pool_size`
///
/// Complexity: O(n × p × e) where n = bind groups, p = pool size, e = entries.
pub fn emitBindGroups(e: *Emitter) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(e.ast.nodes.len > 0);

    const initial_bind_group_id = e.next_bind_group_id;

    var it = e.analysis.symbols.bind_group.iterator();
    for (0..MAX_RESOURCES) |_| {
        const entry = it.next() orelse break;
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        // Check for pool property (ping-pong bind groups)
        const pool_size: u8 = if (utils.findPropertyValue(e, info.node, "pool")) |pool_node|
            @intCast(utils.parseNumber(e, pool_node) orelse 1)
        else
            1;

        const base_group_id = e.next_bind_group_id;

        // Store pool info if pool_size > 1
        if (pool_size > 1) {
            try e.bind_group_pools.put(e.gpa, name, .{
                .base_id = base_group_id,
                .pool_size = pool_size,
            });
        }

        // Register the base bind group ID with the name
        try e.bind_group_ids.put(e.gpa, name, base_group_id);

        // Parse entries with pingPong info
        var entries_with_pp: std.ArrayListUnmanaged(BindGroupEntryWithPingPong) = .{};
        defer entries_with_pp.deinit(e.gpa);
        try parseBindGroupEntriesWithPingPong(e, info.node, &entries_with_pp);

        // Resolve layout reference - returns pipeline ID for 'auto' layouts
        const pipeline_id = utils.resolveBindGroupLayoutId(e, info.node);
        const group_index = utils.getBindGroupIndex(e, info.node);

        // Create pool_size bind groups
        for (0..pool_size) |pool_idx| {
            const group_id = e.next_bind_group_id;
            e.next_bind_group_id += 1;

            // Build adjusted entries for this pool instance
            var entries_list: std.ArrayListUnmanaged(DescriptorEncoder.BindGroupEntry) = .{};
            defer entries_list.deinit(e.gpa);

            for (entries_with_pp.items) |ewp| {
                var adjusted_entry = ewp.entry;

                // Adjust buffer resource_id based on pingPong and pool index
                if (ewp.entry.resource_type == .buffer and ewp.buffer_name.len > 0) {
                    if (e.buffer_pools.get(ewp.buffer_name)) |buf_pool| {
                        // Calculate adjusted buffer ID: base + (pingPong + poolIdx) % poolSize
                        const offset: u8 = @intCast((ewp.ping_pong + pool_idx) % buf_pool.pool_size);
                        adjusted_entry.resource_id = buf_pool.base_id + offset;
                    }

                    // Track (group, binding) -> buffer_id for uniform table
                    // Only track on first pool instance to avoid duplicates
                    if (pool_idx == 0) {
                        const buffer_id = e.buffer_ids.get(ewp.buffer_name) orelse continue;
                        const key = UniformBindingKey{
                            .group = group_index,
                            .binding = adjusted_entry.binding,
                        };
                        e.uniform_bindings.put(e.gpa, key, buffer_id) catch {};
                    }
                }

                entries_list.append(e.gpa, adjusted_entry) catch continue;
            }

            // Encode entries with group index
            const desc = DescriptorEncoder.encodeBindGroupDescriptor(
                e.gpa,
                group_index,
                entries_list.items,
            ) catch return error.OutOfMemory;
            defer e.gpa.free(desc);

            const desc_id = try e.builder.addData(e.gpa, desc);

            try e.builder.getEmitter().createBindGroup(
                e.gpa,
                group_id,
                pipeline_id,
                desc_id.toInt(),
            );
        }
    }

    // Post-condition: bind group IDs were assigned sequentially
    std.debug.assert(e.next_bind_group_id >= initial_bind_group_id);
}

/// Parse bind group entries from a node into the entries list.
fn parseBindGroupEntries(
    e: *Emitter,
    node: Node.Index,
    entries_list: *std.ArrayListUnmanaged(DescriptorEncoder.BindGroupEntry),
) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(node.toInt() < e.ast.nodes.len);

    const entries_value = utils.findPropertyValue(e, node, "entries") orelse return;
    const ev_tag = e.ast.nodes.items(.tag)[entries_value.toInt()];
    if (ev_tag != .array) return;

    const array_data = e.ast.nodes.items(.data)[entries_value.toInt()];
    const elements = e.ast.extraData(array_data.extra_range);

    // Bounded iteration over entries
    const max_elements = @min(elements.len, MAX_ARRAY_ELEMENTS);
    for (0..max_elements) |i| {
        const elem_idx = elements[i];
        const elem: Node.Index = @enumFromInt(elem_idx);
        const elem_tag = e.ast.nodes.items(.tag)[elem.toInt()];

        if (elem_tag == .object) {
            if (utils.parseBindGroupEntry(e, elem)) |bg_entry| {
                entries_list.append(e.gpa, bg_entry) catch continue;
            }
        }
    }

    // Post-condition: entries_list was populated (may be empty if no valid entries)
    std.debug.assert(entries_list.capacity >= entries_list.items.len);
}

/// Parse bind group entries with pingPong info for pooled bind groups.
/// Extracts both the standard entry data and pingPong offset from resource objects.
fn parseBindGroupEntriesWithPingPong(
    e: *Emitter,
    node: Node.Index,
    entries_list: *std.ArrayListUnmanaged(BindGroupEntryWithPingPong),
) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(node.toInt() < e.ast.nodes.len);

    const entries_value = utils.findPropertyValue(e, node, "entries") orelse return;
    const ev_tag = e.ast.nodes.items(.tag)[entries_value.toInt()];
    if (ev_tag != .array) return;

    const array_data = e.ast.nodes.items(.data)[entries_value.toInt()];
    const elements = e.ast.extraData(array_data.extra_range);

    // Bounded iteration over entries
    const max_elements = @min(elements.len, MAX_ARRAY_ELEMENTS);
    for (0..max_elements) |i| {
        const elem_idx = elements[i];
        const elem: Node.Index = @enumFromInt(elem_idx);
        const elem_tag = e.ast.nodes.items(.tag)[elem.toInt()];

        if (elem_tag == .object) {
            if (parseBindGroupEntryWithPingPong(e, elem)) |entry_with_pp| {
                entries_list.append(e.gpa, entry_with_pp) catch continue;
            }
        }
    }

    // Post-condition
    std.debug.assert(entries_list.capacity >= entries_list.items.len);
}

/// Parse a single bind group entry with pingPong info.
/// Returns BindGroupEntryWithPingPong containing standard entry + pingPong offset + buffer name.
fn parseBindGroupEntryWithPingPong(e: *Emitter, entry_node: Node.Index) ?BindGroupEntryWithPingPong {
    const entry_data = e.ast.nodes.items(.data)[entry_node.toInt()];
    const entry_props = e.ast.extraData(entry_data.extra_range);

    var result = BindGroupEntryWithPingPong{
        .entry = .{
            .binding = 0,
            .resource_type = .buffer,
            .resource_id = 0,
        },
        .ping_pong = 0,
        .buffer_name = "",
    };

    for (entry_props) |prop_idx| {
        const prop: Node.Index = @enumFromInt(prop_idx);
        const prop_token = e.ast.nodes.items(.main_token)[prop.toInt()];
        const prop_name = utils.getTokenSlice(e, prop_token);
        const prop_data = e.ast.nodes.items(.data)[prop.toInt()];
        const value_node = prop_data.node;

        if (std.mem.eql(u8, prop_name, "binding")) {
            result.entry.binding = @intCast(utils.parseNumber(e, value_node) orelse 0);
        } else if (std.mem.eql(u8, prop_name, "resource")) {
            const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];
            if (value_tag == .object) {
                // Parse resource={buffer=..., pingPong=..., size=...}
                if (utils.findPropertyValueInObject(e, value_node, "buffer")) |buf_node| {
                    result.entry.resource_type = .buffer;
                    const buf_tag = e.ast.nodes.items(.tag)[buf_node.toInt()];

                    // Get buffer name for pool lookup
                    if (buf_tag == .identifier_value) {
                        result.buffer_name = utils.getNodeText(e, buf_node);
                        if (e.buffer_ids.get(result.buffer_name)) |id| {
                            result.entry.resource_id = id;
                        }
                    }

                    // Extract pingPong offset
                    if (utils.findPropertyValueInObject(e, value_node, "pingPong")) |pp_node| {
                        result.ping_pong = @intCast(utils.parseNumber(e, pp_node) orelse 0);
                    }

                    // Extract size property (can be number, identifier, or expression)
                    if (utils.findPropertyValueInObject(e, value_node, "size")) |size_node| {
                        result.entry.size = resolveBufferSize(e, size_node);
                    }
                } else if (utils.findPropertyValueInObject(e, value_node, "texture")) |tex_node| {
                    result.entry.resource_type = .texture_view;
                    if (utils.resolveResourceId(e, tex_node, "texture")) |id| {
                        result.entry.resource_id = id;
                    }
                } else if (utils.findPropertyValueInObject(e, value_node, "sampler")) |samp_node| {
                    result.entry.resource_type = .sampler;
                    if (utils.resolveResourceId(e, samp_node, "sampler")) |id| {
                        result.entry.resource_id = id;
                    }
                }
            } else if (value_tag == .identifier_value) {
                // Direct identifier reference
                const name = utils.getNodeText(e, value_node);
                if (e.sampler_ids.get(name)) |id| {
                    result.entry.resource_type = .sampler;
                    result.entry.resource_id = id;
                } else if (e.texture_ids.get(name)) |id| {
                    result.entry.resource_type = .texture_view;
                    result.entry.resource_id = id;
                } else if (e.buffer_ids.get(name)) |id| {
                    result.entry.resource_type = .buffer;
                    result.entry.resource_id = id;
                    result.buffer_name = name;
                }
            }
        } else if (std.mem.eql(u8, prop_name, "offset")) {
            result.entry.offset = utils.parseNumber(e, value_node) orelse 0;
        } else if (std.mem.eql(u8, prop_name, "size")) {
            result.entry.size = utils.parseNumber(e, value_node) orelse 0;
        }
    }

    return result;
}

/// Emit #imageBitmap declarations.
///
/// ImageBitmaps are decoded image data that can be copied to textures.
/// At runtime, the blob data is decoded via createImageBitmap() API,
/// then copied to GPU texture via copyExternalImageToTexture().
///
/// This two-step process matches WebGPU's design: decode on CPU, then upload.
pub fn emitImageBitmaps(e: *Emitter) Emitter.Error!void {
    // Pre-condition: AST must be valid
    std.debug.assert(e.ast.nodes.len > 0);

    const initial_id = e.next_image_bitmap_id;

    var it = e.analysis.symbols.image_bitmap.iterator();
    for (0..MAX_RESOURCES) |_| {
        const entry = it.next() orelse break;
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        const bitmap_id = e.next_image_bitmap_id;
        e.next_image_bitmap_id += 1;
        try e.image_bitmap_ids.put(e.gpa, name, bitmap_id);

        // The `image` property must reference a #data blob containing encoded image bytes
        const image_value = utils.findPropertyValue(e, info.node, "image") orelse continue;
        const image_tag = e.ast.nodes.items(.tag)[image_value.toInt()];

        // Support bare identifiers (image=dataName) referencing #data
        var data_name: []const u8 = "";
        if (image_tag == .identifier_value) {
            const token = e.ast.nodes.items(.main_token)[image_value.toInt()];
            data_name = utils.getTokenSlice(e, token);
        }

        if (data_name.len == 0) continue;

        // Blob must have been emitted by emitData() - skip if missing
        const blob_data_id = e.data_ids.get(data_name) orelse continue;

        try e.builder.getEmitter().createImageBitmap(
            e.gpa,
            bitmap_id,
            blob_data_id,
        );
    }

    // Post-condition: IDs assigned sequentially from initial value
    std.debug.assert(e.next_image_bitmap_id >= initial_id);
}

// ============================================================================
// Texture Views, Query Sets, Bind Group Layouts, Pipeline Layouts
// ============================================================================

/// Emit #textureView declarations.
/// Creates GPUTextureView objects from existing textures.
///
/// Opcode: create_texture_view (0x0C)
/// Params: view_id, texture_id, descriptor_data_id
pub fn emitTextureViews(e: *Emitter) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(e.ast.nodes.len > 0);

    const initial_id = e.next_texture_view_id;

    var it = e.analysis.symbols.texture_view.iterator();
    for (0..MAX_RESOURCES) |_| {
        const entry = it.next() orelse break;
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        const view_id = e.next_texture_view_id;
        e.next_texture_view_id += 1;
        try e.texture_view_ids.put(e.gpa, name, view_id);

        // Get texture reference (supports both bare identifiers and references)
        const texture_node = utils.findPropertyValue(e, info.node, "texture") orelse continue;
        const texture_name = utils.getResourceName(e, texture_node) orelse continue;
        const texture_id = e.texture_ids.get(texture_name) orelse continue;

        // Encode descriptor with optional properties
        var encoder = DescriptorEncoder.init();
        defer encoder.deinit(e.gpa);

        const field_count_pos = try encoder.beginDescriptor(e.gpa, .bind_group_layout);
        var field_count: u8 = 0;

        // Optional: format
        if (utils.findPropertyValue(e, info.node, "format")) |format_node| {
            const format_str = utils.getStringContent(e, format_node);
            const format = DescriptorEncoder.TextureFormat.fromString(format_str);
            try encoder.writeEnumField(e.gpa, 0x01, @intFromEnum(format));
            field_count += 1;
        }

        // Optional: dimension
        if (utils.findPropertyValue(e, info.node, "dimension")) |dim_node| {
            const dim_str = utils.getStringContent(e, dim_node);
            const dim_val = textureViewDimensionFromString(dim_str);
            try encoder.writeEnumField(e.gpa, 0x02, dim_val);
            field_count += 1;
        }

        // Optional: baseMipLevel
        if (utils.findPropertyValue(e, info.node, "baseMipLevel")) |node| {
            if (utils.resolveNumericValue(e, node)) |val| {
                try encoder.writeU32Field(e.gpa, 0x03, val);
                field_count += 1;
            }
        }

        // Optional: mipLevelCount
        if (utils.findPropertyValue(e, info.node, "mipLevelCount")) |node| {
            if (utils.resolveNumericValue(e, node)) |val| {
                try encoder.writeU32Field(e.gpa, 0x04, val);
                field_count += 1;
            }
        }

        // Optional: baseArrayLayer
        if (utils.findPropertyValue(e, info.node, "baseArrayLayer")) |node| {
            if (utils.resolveNumericValue(e, node)) |val| {
                try encoder.writeU32Field(e.gpa, 0x05, val);
                field_count += 1;
            }
        }

        // Optional: arrayLayerCount
        if (utils.findPropertyValue(e, info.node, "arrayLayerCount")) |node| {
            if (utils.resolveNumericValue(e, node)) |val| {
                try encoder.writeU32Field(e.gpa, 0x06, val);
                field_count += 1;
            }
        }

        encoder.endDescriptor(field_count_pos, field_count);

        const desc_data = try encoder.toOwnedSlice(e.gpa);
        defer e.gpa.free(desc_data);
        const desc_data_id = try e.builder.addData(e.gpa, desc_data);

        try e.builder.getEmitter().createTextureView(
            e.gpa,
            view_id,
            texture_id,
            @intFromEnum(desc_data_id),
        );
    }

    // Post-condition
    std.debug.assert(e.next_texture_view_id >= initial_id);
}

/// Emit #querySet declarations.
/// Creates GPUQuerySet objects for occlusion/timestamp queries.
///
/// Opcode: create_query_set (0x0D)
/// Params: query_set_id, descriptor_data_id
pub fn emitQuerySets(e: *Emitter) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(e.ast.nodes.len > 0);

    const initial_id = e.next_query_set_id;

    var it = e.analysis.symbols.query_set.iterator();
    for (0..MAX_RESOURCES) |_| {
        const entry = it.next() orelse break;
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        const query_set_id = e.next_query_set_id;
        e.next_query_set_id += 1;
        try e.query_set_ids.put(e.gpa, name, query_set_id);

        // Get type (default: occlusion)
        var query_type: u8 = 0; // 0=occlusion, 1=timestamp
        if (utils.findPropertyValue(e, info.node, "type")) |type_node| {
            const type_str = utils.getStringContent(e, type_node);
            if (std.mem.eql(u8, type_str, "timestamp")) {
                query_type = 1;
            }
        }

        // Get count (required)
        const count: u32 = blk: {
            if (utils.findPropertyValue(e, info.node, "count")) |count_node| {
                break :blk utils.resolveNumericValue(e, count_node) orelse 1;
            }
            break :blk 1;
        };

        // Encode simple descriptor: [type:u8][count:u16]
        var desc_buf: [3]u8 = undefined;
        desc_buf[0] = query_type;
        desc_buf[1] = @intCast(count & 0xFF);
        desc_buf[2] = @intCast(count >> 8);

        const desc_data_id = try e.builder.addData(e.gpa, &desc_buf);

        try e.builder.getEmitter().createQuerySet(
            e.gpa,
            query_set_id,
            @intFromEnum(desc_data_id),
        );
    }

    // Post-condition
    std.debug.assert(e.next_query_set_id >= initial_id);
}

/// Emit #bindGroupLayout declarations.
/// Creates GPUBindGroupLayout objects defining binding slot layouts.
///
/// Opcode: create_bind_group_layout (0x06)
/// Params: layout_id, descriptor_data_id
pub fn emitBindGroupLayouts(e: *Emitter) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(e.ast.nodes.len > 0);

    const initial_id = e.next_bind_group_layout_id;

    var it = e.analysis.symbols.bind_group_layout.iterator();
    for (0..MAX_RESOURCES) |_| {
        const entry = it.next() orelse break;
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        const layout_id = e.next_bind_group_layout_id;
        e.next_bind_group_layout_id += 1;
        try e.bind_group_layout_ids.put(e.gpa, name, layout_id);

        // Get entries array
        const entries_node = utils.findPropertyValue(e, info.node, "entries") orelse continue;
        const entries = utils.collectArrayElements(e, entries_node);
        if (entries.len == 0) continue;

        // Encode descriptor
        var encoder = DescriptorEncoder.init();
        defer encoder.deinit(e.gpa);

        const field_count_pos = try encoder.beginDescriptor(e.gpa, .bind_group_layout);

        // Write entries array header
        try encoder.writeByte(e.gpa, 0x01); // entries field
        try encoder.writeByte(e.gpa, @intFromEnum(DescriptorEncoder.ValueType.array));
        try encoder.writeByte(e.gpa, @intCast(@min(entries.len, 255)));

        // Encode each entry
        for (entries) |entry_idx| {
            try encodeBindGroupLayoutEntry(e, &encoder, @enumFromInt(entry_idx));
        }

        encoder.endDescriptor(field_count_pos, 1);

        const desc_data = try encoder.toOwnedSlice(e.gpa);
        defer e.gpa.free(desc_data);
        const desc_data_id = try e.builder.addData(e.gpa, desc_data);

        try e.builder.getEmitter().createBindGroupLayout(
            e.gpa,
            layout_id,
            @intFromEnum(desc_data_id),
        );
    }

    // Post-condition
    std.debug.assert(e.next_bind_group_layout_id >= initial_id);
}

/// Emit #pipelineLayout declarations.
/// Creates GPUPipelineLayout objects from bind group layouts.
///
/// Opcode: create_pipeline_layout (0x07)
/// Params: layout_id, descriptor_data_id
pub fn emitPipelineLayouts(e: *Emitter) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(e.ast.nodes.len > 0);

    const initial_id = e.next_pipeline_layout_id;

    var it = e.analysis.symbols.pipeline_layout.iterator();
    for (0..MAX_RESOURCES) |_| {
        const entry = it.next() orelse break;
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        const layout_id = e.next_pipeline_layout_id;
        e.next_pipeline_layout_id += 1;
        try e.pipeline_layout_ids.put(e.gpa, name, layout_id);

        // Get bindGroupLayouts array
        const bgl_node = utils.findPropertyValue(e, info.node, "bindGroupLayouts") orelse continue;
        const bgl_elements = utils.collectArrayElements(e, bgl_node);
        if (bgl_elements.len == 0) continue;

        // Encode descriptor: [count:u8][layout_id:u16]...
        var desc_buf = std.ArrayListUnmanaged(u8){};
        defer desc_buf.deinit(e.gpa);

        try desc_buf.append(e.gpa, @intCast(@min(bgl_elements.len, 255)));

        for (bgl_elements) |elem_idx| {
            const elem_node: Node.Index = @enumFromInt(elem_idx);
            const elem_tag = e.ast.nodes.items(.tag)[elem_node.toInt()];
            if (elem_tag != .identifier_value) continue;
            const bgl_name = utils.getNodeText(e, elem_node);
            const bgl_id = e.bind_group_layout_ids.get(bgl_name) orelse continue;
            try desc_buf.append(e.gpa, @intCast(bgl_id & 0xFF));
            try desc_buf.append(e.gpa, @intCast(bgl_id >> 8));
        }

        const desc_data_id = try e.builder.addData(e.gpa, desc_buf.items);

        try e.builder.getEmitter().createPipelineLayout(
            e.gpa,
            layout_id,
            @intFromEnum(desc_data_id),
        );
    }

    // Post-condition
    std.debug.assert(e.next_pipeline_layout_id >= initial_id);
}

/// Emit #renderBundle declarations.
/// Creates pre-recorded render bundles for efficient draw command replay.
///
/// Opcode: create_render_bundle (0x0E)
/// Params: bundle_id, descriptor_data_id
///
/// Descriptor format:
/// - colorFormats count (u8)
/// - colorFormats array (u8 format IDs)
/// - depthStencilFormat (u8, 0xFF = none)
/// - sampleCount (u8)
/// - pipeline_id (u16)
/// - bindGroups count (u8)
/// - bindGroups array (u16 group IDs)
/// - vertexBuffers count (u8)
/// - vertexBuffers array (u16 buffer IDs)
/// - hasIndexBuffer (u8)
/// - indexBuffer (u16, if hasIndexBuffer)
/// - drawType (u8: 0=draw, 1=drawIndexed)
/// - draw params (4 or 5 u32s)
pub fn emitRenderBundles(e: *Emitter) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(e.ast.nodes.len > 0);

    const initial_id = e.next_render_bundle_id;

    var it = e.analysis.symbols.render_bundle.iterator();
    for (0..MAX_RESOURCES) |_| {
        const entry = it.next() orelse break;
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        const bundle_id = e.next_render_bundle_id;
        e.next_render_bundle_id += 1;
        try e.render_bundle_ids.put(e.gpa, name, bundle_id);

        // Build descriptor
        var desc_buf = std.ArrayListUnmanaged(u8){};
        defer desc_buf.deinit(e.gpa);

        // colorFormats
        if (utils.findPropertyValue(e, info.node, "colorFormats")) |cf_node| {
            const formats = utils.collectArrayElements(e, cf_node);
            try desc_buf.append(e.gpa, @intCast(@min(formats.len, 255)));
            for (formats) |fmt_idx| {
                const fmt_node: Node.Index = @enumFromInt(fmt_idx);
                const fmt_str = utils.getStringContent(e, fmt_node);
                const fmt_id = @intFromEnum(DescriptorEncoder.TextureFormat.fromString(fmt_str));
                try desc_buf.append(e.gpa, fmt_id);
            }
        } else {
            try desc_buf.append(e.gpa, 0); // 0 color formats
        }

        // depthStencilFormat
        if (utils.findPropertyValue(e, info.node, "depthStencilFormat")) |ds_node| {
            const ds_str = utils.getStringContent(e, ds_node);
            const ds_fmt = @intFromEnum(DescriptorEncoder.TextureFormat.fromString(ds_str));
            try desc_buf.append(e.gpa, ds_fmt);
        } else {
            try desc_buf.append(e.gpa, 0xFF); // none
        }

        // sampleCount
        const sample_count: u8 = if (utils.findPropertyValue(e, info.node, "sampleCount")) |sc|
            @intCast(utils.resolveNumericValue(e, sc) orelse 1)
        else
            1;
        try desc_buf.append(e.gpa, sample_count);

        // pipeline identifier
        var pipeline_id: u16 = 0;
        if (utils.findPropertyValue(e, info.node, "pipeline")) |p_node| {
            const p_tag = e.ast.nodes.items(.tag)[p_node.toInt()];
            if (p_tag == .identifier_value) {
                const pipe_name = utils.getNodeText(e, p_node);
                pipeline_id = e.pipeline_ids.get(pipe_name) orelse 0;
            }
        }
        try desc_buf.append(e.gpa, @intCast(pipeline_id & 0xFF));
        try desc_buf.append(e.gpa, @intCast(pipeline_id >> 8));

        // bindGroups
        if (utils.findPropertyValue(e, info.node, "bindGroups")) |bg_node| {
            const groups = utils.collectArrayElements(e, bg_node);
            try desc_buf.append(e.gpa, @intCast(@min(groups.len, 255)));
            for (groups) |grp_idx| {
                const grp_node: Node.Index = @enumFromInt(grp_idx);
                const grp_tag = e.ast.nodes.items(.tag)[grp_node.toInt()];
                if (grp_tag == .identifier_value) {
                    const grp_name = utils.getNodeText(e, grp_node);
                    const grp_id = e.bind_group_ids.get(grp_name) orelse 0;
                    try desc_buf.append(e.gpa, @intCast(grp_id & 0xFF));
                    try desc_buf.append(e.gpa, @intCast(grp_id >> 8));
                }
            }
        } else {
            try desc_buf.append(e.gpa, 0); // 0 bind groups
        }

        // vertexBuffers
        if (utils.findPropertyValue(e, info.node, "vertexBuffers")) |vb_node| {
            const buffers = utils.collectArrayElements(e, vb_node);
            try desc_buf.append(e.gpa, @intCast(@min(buffers.len, 255)));
            for (buffers) |buf_idx| {
                const buf_node: Node.Index = @enumFromInt(buf_idx);
                const buf_tag = e.ast.nodes.items(.tag)[buf_node.toInt()];
                if (buf_tag == .identifier_value) {
                    const buf_name = utils.getNodeText(e, buf_node);
                    const buf_id = e.buffer_ids.get(buf_name) orelse 0;
                    try desc_buf.append(e.gpa, @intCast(buf_id & 0xFF));
                    try desc_buf.append(e.gpa, @intCast(buf_id >> 8));
                }
            }
        } else {
            try desc_buf.append(e.gpa, 0); // 0 vertex buffers
        }

        // indexBuffer
        if (utils.findPropertyValue(e, info.node, "indexBuffer")) |ib_node| {
            try desc_buf.append(e.gpa, 1); // has index buffer
            const ib_tag = e.ast.nodes.items(.tag)[ib_node.toInt()];
            if (ib_tag == .identifier_value) {
                const ib_name = utils.getNodeText(e, ib_node);
                const buf_id = e.buffer_ids.get(ib_name) orelse 0;
                try desc_buf.append(e.gpa, @intCast(buf_id & 0xFF));
                try desc_buf.append(e.gpa, @intCast(buf_id >> 8));
            } else {
                try desc_buf.append(e.gpa, 0);
                try desc_buf.append(e.gpa, 0);
            }
        } else {
            try desc_buf.append(e.gpa, 0); // no index buffer
        }

        // draw command
        if (utils.findPropertyValue(e, info.node, "drawIndexed")) |di_node| {
            try desc_buf.append(e.gpa, 1); // drawIndexed
            const count = utils.resolveNumericValue(e, di_node) orelse 0;
            // index_count, instance_count=1, first_index=0, base_vertex=0, first_instance=0
            try appendU32(&desc_buf, e.gpa, count);
            try appendU32(&desc_buf, e.gpa, 1);
            try appendU32(&desc_buf, e.gpa, 0);
            try appendU32(&desc_buf, e.gpa, 0);
            try appendU32(&desc_buf, e.gpa, 0);
        } else if (utils.findPropertyValue(e, info.node, "draw")) |d_node| {
            try desc_buf.append(e.gpa, 0); // draw
            const count = utils.resolveNumericValue(e, d_node) orelse 0;
            // vertex_count, instance_count=1, first_vertex=0, first_instance=0
            try appendU32(&desc_buf, e.gpa, count);
            try appendU32(&desc_buf, e.gpa, 1);
            try appendU32(&desc_buf, e.gpa, 0);
            try appendU32(&desc_buf, e.gpa, 0);
        } else {
            try desc_buf.append(e.gpa, 0); // draw with 0 vertices
            try appendU32(&desc_buf, e.gpa, 0);
            try appendU32(&desc_buf, e.gpa, 1);
            try appendU32(&desc_buf, e.gpa, 0);
            try appendU32(&desc_buf, e.gpa, 0);
        }

        const desc_data_id = try e.builder.addData(e.gpa, desc_buf.items);

        try e.builder.getEmitter().createRenderBundle(
            e.gpa,
            bundle_id,
            @intFromEnum(desc_data_id),
        );
    }

    // Post-condition
    std.debug.assert(e.next_render_bundle_id >= initial_id);
}

fn appendU32(buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, value: u32) !void {
    try buf.append(gpa, @intCast(value & 0xFF));
    try buf.append(gpa, @intCast((value >> 8) & 0xFF));
    try buf.append(gpa, @intCast((value >> 16) & 0xFF));
    try buf.append(gpa, @intCast((value >> 24) & 0xFF));
}

/// Encode a single bind group layout entry.
fn encodeBindGroupLayoutEntry(e: *Emitter, encoder: *DescriptorEncoder, entry_node: Node.Index) !void {
    // Get binding number
    var binding: u8 = 0;
    if (utils.findPropertyValueInObject(e, entry_node, "binding")) |b| {
        binding = @intCast(utils.resolveNumericValue(e, b) orelse 0);
    }

    // Get visibility flags
    var visibility: u8 = 0;
    if (utils.findPropertyValueInObject(e, entry_node, "visibility")) |v| {
        visibility = parseVisibilityFlags(e, v);
    }

    // Determine resource type and encode
    try encoder.writeByte(e.gpa, binding);
    try encoder.writeByte(e.gpa, visibility);

    // Check for buffer binding
    if (utils.findPropertyValueInObject(e, entry_node, "buffer")) |buf_node| {
        try encoder.writeByte(e.gpa, 0x00); // resource_type = buffer
        try encodeBufferBindingLayout(e, encoder, buf_node);
        return;
    }

    // Check for sampler binding
    if (utils.findPropertyValueInObject(e, entry_node, "sampler")) |samp_node| {
        try encoder.writeByte(e.gpa, 0x01); // resource_type = sampler
        try encodeSamplerBindingLayout(e, encoder, samp_node);
        return;
    }

    // Check for texture binding
    if (utils.findPropertyValueInObject(e, entry_node, "texture")) |tex_node| {
        try encoder.writeByte(e.gpa, 0x02); // resource_type = texture
        try encodeTextureBindingLayout(e, encoder, tex_node);
        return;
    }

    // Check for storageTexture binding
    if (utils.findPropertyValueInObject(e, entry_node, "storageTexture")) |st_node| {
        try encoder.writeByte(e.gpa, 0x03); // resource_type = storageTexture
        try encodeStorageTextureBindingLayout(e, encoder, st_node);
        return;
    }

    // Check for externalTexture binding (no additional data)
    if (utils.findPropertyValueInObject(e, entry_node, "externalTexture") != null) {
        try encoder.writeByte(e.gpa, 0x04); // resource_type = externalTexture
        return;
    }

    // Default: buffer with no specific layout
    try encoder.writeByte(e.gpa, 0x00);
}

fn encodeBufferBindingLayout(e: *Emitter, encoder: *DescriptorEncoder, node: Node.Index) !void {
    // type: "uniform" | "storage" | "read-only-storage"
    var buf_type: u8 = 0; // uniform
    if (utils.findPropertyValueInObject(e, node, "type")) |t| {
        const type_str = utils.getStringContent(e, t);
        if (std.mem.eql(u8, type_str, "storage")) buf_type = 1;
        if (std.mem.eql(u8, type_str, "read-only-storage")) buf_type = 2;
    }
    try encoder.writeByte(e.gpa, buf_type);

    // hasDynamicOffset
    var dynamic_offset: u8 = 0;
    if (utils.findPropertyValueInObject(e, node, "hasDynamicOffset")) |d| {
        const bool_str = utils.getStringContent(e, d);
        if (std.mem.eql(u8, bool_str, "true")) dynamic_offset = 1;
    }
    try encoder.writeByte(e.gpa, dynamic_offset);

    // minBindingSize (u32)
    var min_size: u32 = 0;
    if (utils.findPropertyValueInObject(e, node, "minBindingSize")) |m| {
        min_size = utils.resolveNumericValue(e, m) orelse 0;
    }
    try encoder.writeU32(e.gpa, min_size);
}

fn encodeSamplerBindingLayout(e: *Emitter, encoder: *DescriptorEncoder, node: Node.Index) !void {
    // type: "filtering" | "non-filtering" | "comparison"
    var samp_type: u8 = 0; // filtering
    if (utils.findPropertyValueInObject(e, node, "type")) |t| {
        const type_str = utils.getStringContent(e, t);
        if (std.mem.eql(u8, type_str, "non-filtering")) samp_type = 1;
        if (std.mem.eql(u8, type_str, "comparison")) samp_type = 2;
    }
    try encoder.writeByte(e.gpa, samp_type);
}

fn encodeTextureBindingLayout(e: *Emitter, encoder: *DescriptorEncoder, node: Node.Index) !void {
    // sampleType: "float" | "unfilterable-float" | "depth" | "sint" | "uint"
    var sample_type: u8 = 0; // float
    if (utils.findPropertyValueInObject(e, node, "sampleType")) |t| {
        const type_str = utils.getStringContent(e, t);
        if (std.mem.eql(u8, type_str, "unfilterable-float")) sample_type = 1;
        if (std.mem.eql(u8, type_str, "depth")) sample_type = 2;
        if (std.mem.eql(u8, type_str, "sint")) sample_type = 3;
        if (std.mem.eql(u8, type_str, "uint")) sample_type = 4;
    }
    try encoder.writeByte(e.gpa, sample_type);

    // viewDimension
    var view_dim: u8 = 1; // "2d"
    if (utils.findPropertyValueInObject(e, node, "viewDimension")) |d| {
        view_dim = textureViewDimensionFromString(utils.getStringContent(e, d));
    } else if (utils.findPropertyValueInObject(e, node, "dimension")) |d| {
        view_dim = textureViewDimensionFromString(utils.getStringContent(e, d));
    }
    try encoder.writeByte(e.gpa, view_dim);

    // multisampled
    var multisampled: u8 = 0;
    if (utils.findPropertyValueInObject(e, node, "multisampled")) |m| {
        const ms_str = utils.getStringContent(e, m);
        if (std.mem.eql(u8, ms_str, "true")) multisampled = 1;
    }
    try encoder.writeByte(e.gpa, multisampled);
}

fn encodeStorageTextureBindingLayout(e: *Emitter, encoder: *DescriptorEncoder, node: Node.Index) !void {
    // format (required)
    var format: u8 = 0;
    if (utils.findPropertyValueInObject(e, node, "format")) |f| {
        format = @intFromEnum(DescriptorEncoder.TextureFormat.fromString(utils.getStringContent(e, f)));
    }
    try encoder.writeByte(e.gpa, format);

    // access: "write-only" | "read-only" | "read-write"
    var access: u8 = 0; // write-only
    if (utils.findPropertyValueInObject(e, node, "access")) |a| {
        const access_str = utils.getStringContent(e, a);
        if (std.mem.eql(u8, access_str, "read-only")) access = 1;
        if (std.mem.eql(u8, access_str, "read-write")) access = 2;
    }
    try encoder.writeByte(e.gpa, access);

    // viewDimension
    var view_dim: u8 = 1; // "2d"
    if (utils.findPropertyValueInObject(e, node, "viewDimension")) |d| {
        view_dim = textureViewDimensionFromString(utils.getStringContent(e, d));
    } else if (utils.findPropertyValueInObject(e, node, "dimension")) |d| {
        view_dim = textureViewDimensionFromString(utils.getStringContent(e, d));
    }
    try encoder.writeByte(e.gpa, view_dim);
}

fn textureViewDimensionFromString(s: []const u8) u8 {
    const map = std.StaticStringMap(u8).initComptime(.{
        .{ "1d", 0 },
        .{ "2d", 1 },
        .{ "2d-array", 2 },
        .{ "cube", 3 },
        .{ "cube-array", 4 },
        .{ "3d", 5 },
    });
    return map.get(s) orelse 1; // default: 2d
}

fn parseVisibilityFlags(e: *Emitter, node: Node.Index) u8 {
    const node_tag = e.ast.nodes.items(.tag)[@intFromEnum(node)];
    var flags: u8 = 0;

    if (node_tag == .array) {
        const elements = utils.collectArrayElements(e, node);
        for (elements) |elem_idx| {
            const elem_node: Node.Index = @enumFromInt(elem_idx);
            const flag_str = utils.getNodeText(e, elem_node);
            if (std.mem.eql(u8, flag_str, "VERTEX")) flags |= 0x01;
            if (std.mem.eql(u8, flag_str, "FRAGMENT")) flags |= 0x02;
            if (std.mem.eql(u8, flag_str, "COMPUTE")) flags |= 0x04;
        }
    } else {
        // Single value
        const flag_str = utils.getNodeText(e, node);
        if (std.mem.eql(u8, flag_str, "VERTEX")) flags |= 0x01;
        if (std.mem.eql(u8, flag_str, "FRAGMENT")) flags |= 0x02;
        if (std.mem.eql(u8, flag_str, "COMPUTE")) flags |= 0x04;
    }

    return flags;
}

// ============================================================================
// Tests
// ============================================================================
//
// Property: parseWgslReturnType("array<T, N>") = N × sizeof(T) for all supported T.
// Property: parseWgslReturnType(T) = sizeof(T) for scalar/vector/matrix types.
// Property: parseWgslReturnType returns 0 for invalid or unknown types.

test "parseWgslReturnType: array<f32, N>" {
    // Goal: Verify array size calculation for f32 element type.
    // Method: Test N × 4 bytes for various N values and whitespace variants.

    // Basic float arrays: N × 4 bytes
    try std.testing.expectEqual(@as(u32, 1440), parseWgslReturnType("array<f32, 360>"));
    try std.testing.expectEqual(@as(u32, 400), parseWgslReturnType("array<f32, 100>"));
    try std.testing.expectEqual(@as(u32, 4), parseWgslReturnType("array<f32, 1>"));

    // Whitespace tolerance: parsing should handle varied spacing
    try std.testing.expectEqual(@as(u32, 1440), parseWgslReturnType("array<f32,360>"));
    try std.testing.expectEqual(@as(u32, 1440), parseWgslReturnType("array< f32, 360 >"));
    try std.testing.expectEqual(@as(u32, 1440), parseWgslReturnType("array<f32 , 360>"));
}

test "parseWgslReturnType: array<i32/u32, N>" {
    // Goal: Verify array size calculation for integer types.
    // Method: i32 and u32 are both 4 bytes, same as f32.

    try std.testing.expectEqual(@as(u32, 400), parseWgslReturnType("array<i32, 100>"));
    try std.testing.expectEqual(@as(u32, 400), parseWgslReturnType("array<u32, 100>"));
}

test "parseWgslReturnType: array<vec, N>" {
    // Goal: Verify array size calculation for vector element types.
    // Method: vec2=8, vec3=12, vec4=16 bytes; test with/without 'f' suffix.

    // vec2 = 8 bytes per element
    try std.testing.expectEqual(@as(u32, 80), parseWgslReturnType("array<vec2, 10>"));
    try std.testing.expectEqual(@as(u32, 80), parseWgslReturnType("array<vec2f, 10>"));

    // vec3 = 12 bytes per element
    try std.testing.expectEqual(@as(u32, 120), parseWgslReturnType("array<vec3, 10>"));
    try std.testing.expectEqual(@as(u32, 120), parseWgslReturnType("array<vec3f, 10>"));

    // vec4 = 16 bytes per element
    try std.testing.expectEqual(@as(u32, 160), parseWgslReturnType("array<vec4, 10>"));
    try std.testing.expectEqual(@as(u32, 160), parseWgslReturnType("array<vec4f, 10>"));
}

test "parseWgslReturnType: array<mat, N>" {
    // Goal: Verify array size calculation for matrix element types.
    // Method: mat2x2=16, mat3x3=36, mat4x4=64 bytes.

    // mat2x2 = 16 bytes per element (4 floats)
    try std.testing.expectEqual(@as(u32, 160), parseWgslReturnType("array<mat2x2, 10>"));

    // mat3x3 = 36 bytes per element (9 floats)
    try std.testing.expectEqual(@as(u32, 360), parseWgslReturnType("array<mat3x3, 10>"));

    // mat4x4 = 64 bytes per element (16 floats)
    try std.testing.expectEqual(@as(u32, 640), parseWgslReturnType("array<mat4x4, 10>"));
    try std.testing.expectEqual(@as(u32, 64), parseWgslReturnType("array<mat4x4, 1>"));
}

test "parseWgslReturnType: simple types" {
    // Goal: Verify non-array types return their direct size.
    // Method: Scalars, vectors, matrices without array wrapper.

    try std.testing.expectEqual(@as(u32, 4), parseWgslReturnType("f32"));
    try std.testing.expectEqual(@as(u32, 4), parseWgslReturnType("i32"));
    try std.testing.expectEqual(@as(u32, 4), parseWgslReturnType("u32"));
    try std.testing.expectEqual(@as(u32, 8), parseWgslReturnType("vec2"));
    try std.testing.expectEqual(@as(u32, 12), parseWgslReturnType("vec3"));
    try std.testing.expectEqual(@as(u32, 16), parseWgslReturnType("vec4"));
    try std.testing.expectEqual(@as(u32, 64), parseWgslReturnType("mat4x4"));
}

test "parseWgslReturnType: invalid returns 0" {
    // Goal: Verify graceful handling of invalid/unknown type strings.
    // Method: Empty, unknown, malformed array syntax should all return 0.

    try std.testing.expectEqual(@as(u32, 0), parseWgslReturnType(""));
    try std.testing.expectEqual(@as(u32, 0), parseWgslReturnType("unknown"));
    try std.testing.expectEqual(@as(u32, 0), parseWgslReturnType("array<"));
    try std.testing.expectEqual(@as(u32, 0), parseWgslReturnType("array<f32>"));
    try std.testing.expectEqual(@as(u32, 0), parseWgslReturnType("array<unknown, 10>"));
}

test "getTypeSize: all supported types" {
    // Goal: Verify byte sizes for all WGSL types used in buffer calculations.
    // Method: Check scalars, vectors (with suffixes), and matrices.

    // Scalars: f32/i32/u32=4, f16=2
    try std.testing.expectEqual(@as(u32, 4), getTypeSize("f32"));
    try std.testing.expectEqual(@as(u32, 4), getTypeSize("i32"));
    try std.testing.expectEqual(@as(u32, 4), getTypeSize("u32"));
    try std.testing.expectEqual(@as(u32, 2), getTypeSize("f16"));

    // Vectors: vec2=8, vec3=12, vec4=16 (with type suffixes)
    try std.testing.expectEqual(@as(u32, 8), getTypeSize("vec2"));
    try std.testing.expectEqual(@as(u32, 8), getTypeSize("vec2f"));
    try std.testing.expectEqual(@as(u32, 8), getTypeSize("vec2i"));
    try std.testing.expectEqual(@as(u32, 8), getTypeSize("vec2u"));
    try std.testing.expectEqual(@as(u32, 12), getTypeSize("vec3"));
    try std.testing.expectEqual(@as(u32, 12), getTypeSize("vec3f"));
    try std.testing.expectEqual(@as(u32, 16), getTypeSize("vec4"));
    try std.testing.expectEqual(@as(u32, 16), getTypeSize("vec4f"));

    // Matrices: mat2x2=16, mat3x3=36, mat4x4=64
    try std.testing.expectEqual(@as(u32, 16), getTypeSize("mat2x2"));
    try std.testing.expectEqual(@as(u32, 16), getTypeSize("mat2x2f"));
    try std.testing.expectEqual(@as(u32, 36), getTypeSize("mat3x3"));
    try std.testing.expectEqual(@as(u32, 36), getTypeSize("mat3x3f"));
    try std.testing.expectEqual(@as(u32, 64), getTypeSize("mat4x4"));
    try std.testing.expectEqual(@as(u32, 64), getTypeSize("mat4x4f"));

    // Unknown types return 0 (safe default)
    try std.testing.expectEqual(@as(u32, 0), getTypeSize("unknown"));
    try std.testing.expectEqual(@as(u32, 0), getTypeSize(""));
}

// ============================================================================
// Uniform Table Population
// ============================================================================

/// Populate the uniform table from WGSL reflection data.
///
/// For each uniform binding in the shaders, finds the corresponding buffer
/// and adds field metadata to enable runtime `setUniform()` by name.
///
/// Complexity: O(shaders × bindings × fields)
pub fn populateUniformTable(e: *Emitter) Emitter.Error!void {
    // First, trigger reflection for all #wgsl shaders to populate wgsl_reflections
    var wgsl_it = e.analysis.symbols.wgsl.iterator();
    for (0..MAX_RESOURCES) |_| {
        const wgsl_entry = wgsl_it.next() orelse break;
        const shader_name = wgsl_entry.key_ptr.*;
        // Trigger reflection (result is cached)
        _ = e.getWgslReflection(shader_name);
    }

    // Also trigger for #shaderModule shaders (they may have uniform bindings)
    var sm_it = e.analysis.symbols.shader_module.iterator();
    for (0..MAX_RESOURCES) |_| {
        const sm_entry = sm_it.next() orelse break;
        const shader_name = sm_entry.key_ptr.*;
        _ = e.getWgslReflection(shader_name);
    }

    // Iterate through all WGSL reflections
    var it = e.wgsl_reflections.iterator();
    for (0..MAX_RESOURCES) |_| {
        const entry = it.next() orelse break;
        const reflection = entry.value_ptr.*;

        // Process each uniform binding
        for (reflection.bindings) |binding| {
            if (binding.address_space != .uniform) continue;

            // Look up buffer_id from (group, binding)
            const key = UniformBindingKey{
                .group = @intCast(binding.group),
                .binding = @intCast(binding.binding),
            };
            const buffer_id = e.uniform_bindings.get(key) orelse continue;

            // Convert reflection fields to uniform table fields
            var fields: std.ArrayListUnmanaged(uniform_table.UniformField) = .{};
            defer fields.deinit(e.gpa);

            for (binding.layout.fields) |field| {
                // Add field name to string table
                const name_id = e.builder.internString(e.gpa, field.name) catch continue;

                fields.append(e.gpa, .{
                    .name_string_id = name_id.toInt(),
                    .offset = @intCast(field.offset),
                    .size = @intCast(field.size),
                    .uniform_type = uniform_table.UniformType.fromWgslType(field.type),
                }) catch continue;
            }

            // Add binding name to string table
            const binding_name_id = e.builder.internString(e.gpa, binding.name) catch continue;

            // Add to uniform table
            e.builder.addUniformBinding(
                e.gpa,
                buffer_id,
                binding_name_id.toInt(),
                @intCast(binding.group),
                @intCast(binding.binding),
                fields.items,
            ) catch continue;
        }
    }
}
