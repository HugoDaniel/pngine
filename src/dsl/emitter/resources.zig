//! Resource Emission Module
//!
//! Handles emission of resource declarations:
//! - #data (float32Array data to data section, or blob file to data section)
//! - #imageBitmap (create ImageBitmap from blob data)
//! - #buffer (GPU buffers)
//! - #texture (GPU textures)
//! - #sampler (GPU samplers)
//! - #bindGroup (bind groups)
//!
//! ## Invariants
//!
//! * Resource IDs are assigned sequentially starting from their respective counters.
//! * Data section entries are created before buffer initialization.
//! * All iteration is bounded by MAX_RESOURCES or MAX_ARRAY_ELEMENTS.
//! * Texture canvas size is detected from "$canvas" in size array elements.
//! * Bind group entries are parsed before descriptor encoding.
//! * Blob files are read from base_dir + relative URL during compilation.

const std = @import("std");
const Emitter = @import("../Emitter.zig").Emitter;
const Node = @import("../Ast.zig").Node;
const DescriptorEncoder = @import("../DescriptorEncoder.zig").DescriptorEncoder;
const utils = @import("utils.zig");
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

/// Emit #data declarations - add float32Array or blob file data to data section.
/// No bytecode emitted, just populates data section for buffer initialization.
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
    }

    // Post-condition: we processed data symbols
    std.debug.assert(e.data_ids.count() >= initial_count);
}

/// Emit float32Array data to data section.
fn emitFloat32ArrayData(e: *Emitter, name: []const u8, float_array: Node.Index) Emitter.Error!void {
    const array_tag = e.ast.nodes.items(.tag)[float_array.toInt()];
    if (array_tag != .array) return;

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

/// Emit #buffer declarations.
pub fn emitBuffers(e: *Emitter) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(e.ast.nodes.len > 0);

    const initial_buffer_id = e.next_buffer_id;

    var it = e.analysis.symbols.buffer.iterator();
    for (0..MAX_RESOURCES) |_| {
        const entry = it.next() orelse break;
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        const buffer_id = e.next_buffer_id;
        e.next_buffer_id += 1;
        try e.buffer_ids.put(e.gpa, name, buffer_id);

        // Get size property - can be number, expression, string expression, or WASM data reference
        const size_value = utils.findPropertyValue(e, info.node, "size") orelse continue;
        const size = resolveBufferSize(e, size_value);

        // Get usage flags
        var usage = utils.parseBufferUsage(e, info.node);

        // Check for mappedAtCreation - requires COPY_DST for write_buffer
        const mapped_value = utils.findPropertyValue(e, info.node, "mappedAtCreation");
        if (mapped_value != null) {
            usage.copy_dst = true;
        }

        try e.builder.getEmitter().createBuffer(
            e.gpa,
            buffer_id,
            @intCast(size),
            @bitCast(usage),
        );

        // If mappedAtCreation is set, emit write_buffer to initialize data
        if (mapped_value) |mv| {
            try emitBufferInitialization(e, buffer_id, mv);
        }
    }

    // Post-condition: buffer IDs were assigned sequentially
    std.debug.assert(e.next_buffer_id >= initial_buffer_id);
}

/// Resolve buffer size from size property value.
/// Handles: numbers, expressions, string expressions, identifier refs to #data (including WASM data).
fn resolveBufferSize(e: *Emitter, size_node: Node.Index) u32 {
    // Pre-condition
    std.debug.assert(size_node.toInt() < e.ast.nodes.len);

    const size_tag = e.ast.nodes.items(.tag)[size_node.toInt()];

    // Check for identifier reference to #data (including WASM data)
    if (size_tag == .identifier_value) {
        const token = e.ast.nodes.items(.main_token)[size_node.toInt()];
        const data_name = utils.getTokenSlice(e, token);

        // Check WASM data entries first (they store byte size)
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

/// Emit write_buffer for buffer initialization from mappedAtCreation.
fn emitBufferInitialization(e: *Emitter, buffer_id: u16, mapped_value: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(mapped_value.toInt() < e.ast.nodes.len);

    const value_tag = e.ast.nodes.items(.tag)[mapped_value.toInt()];
    if (value_tag != .identifier_value) return;

    const token = e.ast.nodes.items(.main_token)[mapped_value.toInt()];
    const data_name = utils.getTokenSlice(e, token);

    // Check WASM data entries first
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

/// Emit #texture declarations.
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

        // Check if texture uses canvas size (size=["$canvas.width", "$canvas.height"])
        const use_canvas_size = textureUsesCanvasSize(e, info.node);

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

/// Check if texture has size=["$canvas.width", "$canvas.height"] or similar.
pub fn textureUsesCanvasSize(e: *Emitter, node: Node.Index) bool {
    // Pre-condition
    std.debug.assert(node.toInt() < e.ast.nodes.len);

    const size_value = utils.findPropertyValue(e, node, "size") orelse return false;
    const size_tag = e.ast.nodes.items(.tag)[size_value.toInt()];

    if (size_tag != .array) return false;

    const array_data = e.ast.nodes.items(.data)[size_value.toInt()];
    const elements = e.ast.extraData(array_data.extra_range);

    // Check if any element is a runtime interpolation or string containing "$canvas"
    for (elements) |elem_idx| {
        const elem: Node.Index = @enumFromInt(elem_idx);
        const elem_tag = e.ast.nodes.items(.tag)[elem.toInt()];

        // Runtime interpolation strings are marked with a separate tag
        if (elem_tag == .runtime_interpolation) {
            return true;
        }

        if (elem_tag == .string_value) {
            const content = utils.getStringContent(e, elem);
            if (std.mem.indexOf(u8, content, "$canvas") != null) {
                return true;
            }
        }
    }

    return false;
}

/// Emit #sampler declarations.
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

/// Emit #bindGroup declarations.
pub fn emitBindGroups(e: *Emitter) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(e.ast.nodes.len > 0);

    const initial_bind_group_id = e.next_bind_group_id;

    var it = e.analysis.symbols.bind_group.iterator();
    for (0..MAX_RESOURCES) |_| {
        const entry = it.next() orelse break;
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        const group_id = e.next_bind_group_id;
        e.next_bind_group_id += 1;
        try e.bind_group_ids.put(e.gpa, name, group_id);

        // Parse entries array
        var entries_list: std.ArrayListUnmanaged(DescriptorEncoder.BindGroupEntry) = .{};
        defer entries_list.deinit(e.gpa);

        try parseBindGroupEntries(e, info.node, &entries_list);

        // Resolve layout reference - returns pipeline ID for 'auto' layouts
        const pipeline_id = utils.resolveBindGroupLayoutId(e, info.node);
        const group_index = utils.getBindGroupIndex(e, info.node);

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
            pipeline_id, // Pipeline ID to get layout from
            desc_id.toInt(),
        );
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

        // Support both bare identifiers (image=dataName) and refs (image=$data.name)
        var data_name: []const u8 = "";
        if (image_tag == .identifier_value) {
            const token = e.ast.nodes.items(.main_token)[image_value.toInt()];
            data_name = utils.getTokenSlice(e, token);
        } else if (image_tag == .reference) {
            if (utils.getReference(e, image_value)) |ref| {
                data_name = ref.name;
            }
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
