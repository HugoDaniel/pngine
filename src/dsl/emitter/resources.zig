//! Resource Emission Module
//!
//! Handles emission of resource declarations:
//! - #data (float32Array data to data section)
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

const std = @import("std");
const Emitter = @import("../Emitter.zig").Emitter;
const Node = @import("../Ast.zig").Node;
const DescriptorEncoder = @import("../DescriptorEncoder.zig").DescriptorEncoder;
const utils = @import("utils.zig");

/// Maximum resources of each type (prevents runaway iteration).
const MAX_RESOURCES: u32 = 256;

/// Maximum array elements to process.
const MAX_ARRAY_ELEMENTS: u32 = 1024;

/// Emit #data declarations - add float32Array data to data section.
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

        // Find float32Array property
        const float_array = utils.findPropertyValue(e, info.node, "float32Array") orelse continue;
        const array_tag = e.ast.nodes.items(.tag)[float_array.toInt()];
        if (array_tag != .array) continue;

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

    // Post-condition: we processed data symbols
    std.debug.assert(e.data_ids.count() >= initial_count);
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

        // Get size property - can be number, expression, or string expression
        const size_value = utils.findPropertyValue(e, info.node, "size") orelse continue;
        const size = utils.resolveNumericValueOrString(e, size_value) orelse 0;

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

/// Emit write_buffer for buffer initialization from mappedAtCreation.
fn emitBufferInitialization(e: *Emitter, buffer_id: u16, mapped_value: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(mapped_value.toInt() < e.ast.nodes.len);

    const value_tag = e.ast.nodes.items(.tag)[mapped_value.toInt()];
    if (value_tag != .identifier_value) return;

    const token = e.ast.nodes.items(.main_token)[mapped_value.toInt()];
    const data_name = utils.getTokenSlice(e, token);

    // Look up the data_id for this data declaration
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
