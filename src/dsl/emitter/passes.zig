//! Pass Emission Module
//!
//! Handles emission of pass declarations:
//! - #renderPass (render pass definition + commands)
//! - #computePass (compute pass definition + commands)
//!
//! Emits pass commands: pipeline, bind groups, vertex/index buffers, draw/dispatch.
//!
//! ## Invariants
//!
//! * Pass IDs are assigned sequentially starting from next_pass_id.
//! * Render passes have begin_render_pass + end_pass bracketing.
//! * Compute passes have begin_compute_pass + end_pass bracketing.
//! * All iteration is bounded by MAX_PASSES or MAX_COMMANDS.
//! * Depth texture ID is 0xFFFF when no depth attachment is specified.

const std = @import("std");
const Emitter = @import("../Emitter.zig").Emitter;
const Node = @import("../Ast.zig").Node;
const opcodes = @import("../../bytecode/opcodes.zig");
const utils = @import("utils.zig");
const resources = @import("resources.zig");

/// Maximum passes to emit (prevents runaway iteration).
const MAX_PASSES: u32 = 128;

/// Maximum commands per pass.
const MAX_COMMANDS: u32 = 256;

/// Maximum array elements to process.
const MAX_ARRAY_ELEMENTS: u32 = 64;

/// Emit #renderPass and #computePass declarations.
pub fn emitPasses(e: *Emitter) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(e.ast.nodes.len > 0);

    const initial_pass_id = e.next_pass_id;

    // Render passes
    var rp_it = e.analysis.symbols.render_pass.iterator();
    for (0..MAX_PASSES) |_| {
        const entry = rp_it.next() orelse break;
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        const pass_id = e.next_pass_id;
        e.next_pass_id += 1;
        try e.pass_ids.put(e.gpa, name, pass_id);

        try emitRenderPassDefinition(e, pass_id, info.node);
    } else unreachable; // Exceeded MAX_PASSES

    // Compute passes
    var cp_it = e.analysis.symbols.compute_pass.iterator();
    for (0..MAX_PASSES) |_| {
        const entry = cp_it.next() orelse break;
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        const pass_id = e.next_pass_id;
        e.next_pass_id += 1;
        try e.pass_ids.put(e.gpa, name, pass_id);

        try emitComputePassDefinition(e, pass_id, info.node);
    } else unreachable; // Exceeded MAX_PASSES

    // Post-condition: pass IDs were assigned sequentially
    std.debug.assert(e.next_pass_id >= initial_pass_id);
}

fn emitRenderPassDefinition(e: *Emitter, pass_id: u16, node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(node.toInt() < e.ast.nodes.len);

    // Create pass descriptor
    const desc = "{}";
    const desc_id = try e.builder.addData(e.gpa, desc);

    // Define pass
    try e.builder.getEmitter().definePass(
        e.gpa,
        pass_id,
        .render,
        desc_id.toInt(),
    );

    // Parse depth texture from depthStencilAttachment if present
    const depth_texture_id = getDepthTextureId(e, node);

    // Parse color texture from colorAttachments[0].view
    const color_texture_id = getColorTextureId(e, node);

    // Begin render pass with parsed color texture
    try e.builder.getEmitter().beginRenderPass(
        e.gpa,
        color_texture_id,
        opcodes.LoadOp.clear,
        opcodes.StoreOp.store,
        depth_texture_id,
    );

    // Emit pass body commands
    try emitPassCommands(e, node);

    // End the render pass
    try e.builder.getEmitter().endPass(e.gpa);

    // End pass definition
    try e.builder.getEmitter().endPassDef(e.gpa);
}

/// Get depth texture ID from depthStencilAttachment property.
/// Returns 0xFFFF if no depth attachment is specified.
pub fn getDepthTextureId(e: *Emitter, node: Node.Index) u16 {
    // Pre-condition
    std.debug.assert(node.toInt() < e.ast.nodes.len);

    const depth_attachment = utils.findPropertyValue(e, node, "depthStencilAttachment") orelse return 0xFFFF;
    const depth_tag = e.ast.nodes.items(.tag)[depth_attachment.toInt()];

    if (depth_tag != .object) return 0xFFFF;

    // Look for view property in the depth attachment object
    const view_value = utils.findPropertyValueInObject(e, depth_attachment, "view") orelse return 0xFFFF;

    const view_tag = e.ast.nodes.items(.tag)[view_value.toInt()];

    if (view_tag == .identifier_value) {
        const token = e.ast.nodes.items(.main_token)[view_value.toInt()];
        const texture_name = utils.getTokenSlice(e, token);
        if (e.texture_ids.get(texture_name)) |id| {
            return id;
        }
    }

    return 0xFFFF;
}

/// Special value for canvas/surface texture (contextCurrentTexture).
/// Uses 0xFFFE to distinguish from 0xFFFF (no depth texture).
pub const CANVAS_TEXTURE_ID: u16 = 0xFFFE;

/// Get color texture ID from colorAttachments[0].view property.
/// Returns CANVAS_TEXTURE_ID (0xFFFE) for contextCurrentTexture or if not specified.
/// Returns the actual texture ID for other texture references.
pub fn getColorTextureId(e: *Emitter, node: Node.Index) u16 {
    // Pre-condition
    std.debug.assert(node.toInt() < e.ast.nodes.len);

    // Find colorAttachments property
    const color_attachments = utils.findPropertyValue(e, node, "colorAttachments") orelse return CANVAS_TEXTURE_ID;
    const ca_tag = e.ast.nodes.items(.tag)[color_attachments.toInt()];

    // Must be an array
    if (ca_tag != .array) return CANVAS_TEXTURE_ID;

    // Get first element of the array
    const first_attachment = utils.getArrayFirstElement(e, color_attachments) orelse return CANVAS_TEXTURE_ID;
    const first_tag = e.ast.nodes.items(.tag)[first_attachment.toInt()];

    // First element must be an object
    if (first_tag != .object) return CANVAS_TEXTURE_ID;

    // Look for view property in the attachment object
    const view_value = utils.findPropertyValueInObject(e, first_attachment, "view") orelse return CANVAS_TEXTURE_ID;
    const view_tag = e.ast.nodes.items(.tag)[view_value.toInt()];

    if (view_tag == .identifier_value) {
        const token = e.ast.nodes.items(.main_token)[view_value.toInt()];
        const texture_name = utils.getTokenSlice(e, token);

        // contextCurrentTexture means canvas
        if (std.mem.eql(u8, texture_name, "contextCurrentTexture")) {
            return CANVAS_TEXTURE_ID;
        }

        // Look up the texture ID
        if (e.texture_ids.get(texture_name)) |id| {
            return id;
        }
    }

    // Default to canvas
    return CANVAS_TEXTURE_ID;
}

fn emitComputePassDefinition(e: *Emitter, pass_id: u16, node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(node.toInt() < e.ast.nodes.len);

    const desc = "{}";
    const desc_id = try e.builder.addData(e.gpa, desc);

    try e.builder.getEmitter().definePass(
        e.gpa,
        pass_id,
        .compute,
        desc_id.toInt(),
    );

    // Begin compute pass
    try e.builder.getEmitter().beginComputePass(e.gpa);

    // Emit pass body commands
    try emitPassCommands(e, node);

    // End the compute pass
    try e.builder.getEmitter().endPass(e.gpa);

    // End pass definition
    try e.builder.getEmitter().endPassDef(e.gpa);
}

fn emitPassCommands(e: *Emitter, node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(node.toInt() < e.ast.nodes.len);

    // First, collect pool offset arrays (if specified)
    var vb_pool_offsets: [MAX_ARRAY_ELEMENTS]u8 = [_]u8{0} ** MAX_ARRAY_ELEMENTS;
    var bg_pool_offsets: [MAX_ARRAY_ELEMENTS]u8 = [_]u8{0} ** MAX_ARRAY_ELEMENTS;

    if (utils.findPropertyValue(e, node, "vertexBuffersPoolOffsets")) |offsets_node| {
        parsePoolOffsets(e, offsets_node, &vb_pool_offsets);
    }
    if (utils.findPropertyValue(e, node, "bindGroupsPoolOffsets")) |offsets_node| {
        parsePoolOffsets(e, offsets_node, &bg_pool_offsets);
    }

    const data = e.ast.nodes.items(.data)[node.toInt()];
    const props = e.ast.extraData(data.extra_range);

    // Bounded iteration over properties
    const max_props = @min(props.len, MAX_COMMANDS);
    for (0..max_props) |i| {
        const prop_idx = props[i];
        const prop_node: Node.Index = @enumFromInt(prop_idx);
        const prop_token = e.ast.nodes.items(.main_token)[prop_node.toInt()];
        const prop_name = utils.getTokenSlice(e, prop_token);

        if (std.mem.eql(u8, prop_name, "pipeline")) {
            try emitPipelineCommand(e, prop_node);
        } else if (std.mem.eql(u8, prop_name, "bindGroups")) {
            try emitBindGroupCommandsWithOffsets(e, prop_node, &bg_pool_offsets);
        } else if (std.mem.eql(u8, prop_name, "vertexBuffers")) {
            try emitVertexBufferCommandsWithOffsets(e, prop_node, &vb_pool_offsets);
        } else if (std.mem.eql(u8, prop_name, "indexBuffer")) {
            try emitIndexBufferCommand(e, prop_node);
        } else if (std.mem.eql(u8, prop_name, "draw")) {
            try emitDrawCommand(e, prop_node);
        } else if (std.mem.eql(u8, prop_name, "drawIndexed")) {
            try emitDrawIndexedCommand(e, prop_node);
        } else if (std.mem.eql(u8, prop_name, "dispatch")) {
            try emitDispatchCommand(e, prop_node);
        } else if (std.mem.eql(u8, prop_name, "dispatchWorkgroups")) {
            try emitDispatchWorkgroupsCommand(e, prop_node);
        } else if (std.mem.eql(u8, prop_name, "executeBundles")) {
            try emitExecuteBundlesCommand(e, prop_node);
        }
    }
}

/// Parse pool offsets array into a fixed-size buffer.
fn parsePoolOffsets(e: *Emitter, offsets_node: Node.Index, out: *[MAX_ARRAY_ELEMENTS]u8) void {
    const tag = e.ast.nodes.items(.tag)[offsets_node.toInt()];
    if (tag != .array) return;

    const array_data = e.ast.nodes.items(.data)[offsets_node.toInt()];
    const elements = e.ast.extraData(array_data.extra_range);

    const max_elements = @min(elements.len, MAX_ARRAY_ELEMENTS);
    for (0..max_elements) |i| {
        const elem_idx = elements[i];
        const elem: Node.Index = @enumFromInt(elem_idx);
        out[i] = @intCast(utils.parseNumber(e, elem) orelse 0);
    }
}

/// Emit set_pipeline command with pipeline identifier.
fn emitPipelineCommand(e: *Emitter, prop_node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(prop_node.toInt() < e.ast.nodes.len);

    const prop_data = e.ast.nodes.items(.data)[prop_node.toInt()];
    const value_node = prop_data.node;
    const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];

    if (value_tag == .identifier_value) {
        const name = utils.getNodeText(e, value_node);
        if (e.pipeline_ids.get(name)) |pipeline_id| {
            try e.builder.getEmitter().setPipeline(e.gpa, pipeline_id);
        }
    }
}

/// Draw parameters parsed from object syntax.
const DrawParams = struct {
    vertex_count: u32 = 3,
    instance_count: u32 = 1,
    first_vertex: u32 = 0,
    first_instance: u32 = 0,
};

/// DrawIndexed parameters parsed from object syntax.
const DrawIndexedParams = struct {
    index_count: u32 = 3,
    instance_count: u32 = 1,
    first_index: u32 = 0,
    base_vertex: u32 = 0,
    first_instance: u32 = 0,
};

/// Emit draw command with full WebGPU parameters.
/// Handles:
/// - Number literals: draw=3
/// - Identifier (#define refs): draw=VERTEX_COUNT
/// - Arrays: draw=[3 1]
/// - Objects: draw={ vertexCount=3 instanceCount=1 firstVertex=0 firstInstance=0 }
fn emitDrawCommand(e: *Emitter, prop_node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(prop_node.toInt() < e.ast.nodes.len);

    const prop_data = e.ast.nodes.items(.data)[prop_node.toInt()];
    const value_node = prop_data.node;
    const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];

    if (value_tag == .object) {
        // Parse object syntax: { vertexCount=N instanceCount=N ... }
        const params = parseDrawParams(e, value_node);
        try e.builder.getEmitter().draw(
            e.gpa,
            params.vertex_count,
            params.instance_count,
            params.first_vertex,
            params.first_instance,
        );
    } else if (value_tag == .array) {
        const counts = parseCountPair(e, value_node, 3, 1);
        try e.builder.getEmitter().draw(e.gpa, counts[0], counts[1], 0, 0);
    } else {
        // Handle number_value, identifier_value (#define refs), and expressions
        const count = utils.resolveNumericValue(e, value_node) orelse 3;
        try e.builder.getEmitter().draw(e.gpa, count, 1, 0, 0);
    }
}

/// Parse draw parameters from object node.
fn parseDrawParams(e: *Emitter, obj_node: Node.Index) DrawParams {
    var params = DrawParams{};

    const obj_data = e.ast.nodes.items(.data)[obj_node.toInt()];
    const props = e.ast.extraData(obj_data.extra_range);

    const max_props = @min(props.len, MAX_COMMANDS);
    for (0..max_props) |i| {
        const prop_idx = props[i];
        const inner: Node.Index = @enumFromInt(prop_idx);
        const inner_token = e.ast.nodes.items(.main_token)[inner.toInt()];
        const prop_name = utils.getTokenSlice(e, inner_token);
        const inner_data = e.ast.nodes.items(.data)[inner.toInt()];

        if (std.mem.eql(u8, prop_name, "vertexCount")) {
            params.vertex_count = utils.resolveNumericValueOrString(e, inner_data.node) orelse 3;
        } else if (std.mem.eql(u8, prop_name, "instanceCount")) {
            params.instance_count = utils.resolveNumericValueOrString(e, inner_data.node) orelse 1;
        } else if (std.mem.eql(u8, prop_name, "firstVertex")) {
            params.first_vertex = utils.resolveNumericValueOrString(e, inner_data.node) orelse 0;
        } else if (std.mem.eql(u8, prop_name, "firstInstance")) {
            params.first_instance = utils.resolveNumericValueOrString(e, inner_data.node) orelse 0;
        }
    }

    return params;
}

/// Emit draw_indexed command with full WebGPU parameters.
/// Handles number literals, identifiers, arrays, and objects.
fn emitDrawIndexedCommand(e: *Emitter, prop_node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(prop_node.toInt() < e.ast.nodes.len);

    const prop_data = e.ast.nodes.items(.data)[prop_node.toInt()];
    const value_node = prop_data.node;
    const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];

    if (value_tag == .object) {
        // Parse object syntax: { indexCount=N instanceCount=N ... }
        const params = parseDrawIndexedParams(e, value_node);
        try e.builder.getEmitter().drawIndexed(
            e.gpa,
            params.index_count,
            params.instance_count,
            params.first_index,
            params.base_vertex,
            params.first_instance,
        );
    } else if (value_tag == .array) {
        const counts = parseCountPair(e, value_node, 3, 1);
        try e.builder.getEmitter().drawIndexed(e.gpa, counts[0], counts[1], 0, 0, 0);
    } else {
        // Handle number_value, identifier_value (#define refs), and expressions
        const count = utils.resolveNumericValue(e, value_node) orelse 3;
        try e.builder.getEmitter().drawIndexed(e.gpa, count, 1, 0, 0, 0);
    }
}

/// Parse drawIndexed parameters from object node.
fn parseDrawIndexedParams(e: *Emitter, obj_node: Node.Index) DrawIndexedParams {
    var params = DrawIndexedParams{};

    const obj_data = e.ast.nodes.items(.data)[obj_node.toInt()];
    const props = e.ast.extraData(obj_data.extra_range);

    const max_props = @min(props.len, MAX_COMMANDS);
    for (0..max_props) |i| {
        const prop_idx = props[i];
        const inner: Node.Index = @enumFromInt(prop_idx);
        const inner_token = e.ast.nodes.items(.main_token)[inner.toInt()];
        const prop_name = utils.getTokenSlice(e, inner_token);
        const inner_data = e.ast.nodes.items(.data)[inner.toInt()];

        if (std.mem.eql(u8, prop_name, "indexCount")) {
            params.index_count = utils.resolveNumericValueOrString(e, inner_data.node) orelse 3;
        } else if (std.mem.eql(u8, prop_name, "instanceCount")) {
            params.instance_count = utils.resolveNumericValueOrString(e, inner_data.node) orelse 1;
        } else if (std.mem.eql(u8, prop_name, "firstIndex")) {
            params.first_index = utils.resolveNumericValueOrString(e, inner_data.node) orelse 0;
        } else if (std.mem.eql(u8, prop_name, "baseVertex")) {
            params.base_vertex = utils.resolveNumericValueOrString(e, inner_data.node) orelse 0;
        } else if (std.mem.eql(u8, prop_name, "firstInstance")) {
            params.first_instance = utils.resolveNumericValueOrString(e, inner_data.node) orelse 0;
        }
    }

    return params;
}

/// Emit dispatch command for compute passes.
fn emitDispatchCommand(e: *Emitter, prop_node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(prop_node.toInt() < e.ast.nodes.len);

    const prop_data = e.ast.nodes.items(.data)[prop_node.toInt()];
    const value_node = prop_data.node;
    const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];

    if (value_tag == .array) {
        const array_data = e.ast.nodes.items(.data)[value_node.toInt()];
        const elements = e.ast.extraData(array_data.extra_range);
        var xyz: [3]u32 = .{ 1, 1, 1 };

        // Bounded iteration
        const max_elements = @min(elements.len, 3);
        for (0..max_elements) |i| {
            const elem_idx = elements[i];
            const elem: Node.Index = @enumFromInt(elem_idx);
            xyz[i] = utils.parseNumber(e, elem) orelse 1;
        }
        try e.builder.getEmitter().dispatch(e.gpa, xyz[0], xyz[1], xyz[2]);
    }

    // Post-condition: dispatch was emitted (if array) or skipped (otherwise)
}

/// Parse array of 2 numbers (e.g., [vertex_count instance_count]).
fn parseCountPair(e: *Emitter, array_node: Node.Index, default0: u32, default1: u32) [2]u32 {
    // Pre-condition
    std.debug.assert(array_node.toInt() < e.ast.nodes.len);

    const array_data = e.ast.nodes.items(.data)[array_node.toInt()];
    const elements = e.ast.extraData(array_data.extra_range);
    var counts: [2]u32 = .{ default0, default1 };

    // Bounded iteration
    const max_elements = @min(elements.len, 2);
    for (0..max_elements) |i| {
        const elem_idx = elements[i];
        const elem: Node.Index = @enumFromInt(elem_idx);
        counts[i] = utils.parseNumber(e, elem) orelse if (i == 0) default0 else default1;
    }

    // Post-condition: counts has valid values
    std.debug.assert(counts[0] >= 0 and counts[1] >= 0);

    return counts;
}

fn emitBindGroupCommands(e: *Emitter, prop_node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(prop_node.toInt() < e.ast.nodes.len);

    const prop_data = e.ast.nodes.items(.data)[prop_node.toInt()];
    const value_node = prop_data.node;
    const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];

    if (value_tag == .array) {
        const array_data = e.ast.nodes.items(.data)[value_node.toInt()];
        const elements = e.ast.extraData(array_data.extra_range);

        // Bounded iteration
        const max_elements = @min(elements.len, MAX_ARRAY_ELEMENTS);
        for (0..max_elements) |slot| {
            const elem_idx = elements[slot];
            const elem: Node.Index = @enumFromInt(elem_idx);
            const group_id = resolveBindGroupId(e, elem);

            if (group_id) |id| {
                try e.builder.getEmitter().setBindGroup(
                    e.gpa,
                    @intCast(slot),
                    id,
                );
            }
        }
    } else {
        // Single bind group at slot 0
        const group_id = resolveBindGroupId(e, value_node);
        if (group_id) |id| {
            try e.builder.getEmitter().setBindGroup(e.gpa, 0, id);
        }
    }
}

/// Resolve a bind group identifier to its ID.
pub fn resolveBindGroupId(e: *Emitter, node: Node.Index) ?u16 {
    // Pre-condition
    std.debug.assert(node.toInt() < e.ast.nodes.len);

    const tag = e.ast.nodes.items(.tag)[node.toInt()];

    if (tag == .identifier_value) {
        const name = utils.getNodeText(e, node);
        return e.bind_group_ids.get(name);
    }

    return null;
}

/// Resolve a buffer identifier to its ID.
pub fn resolveBufferId(e: *Emitter, node: Node.Index) ?u16 {
    // Pre-conditions: valid node index
    std.debug.assert(node.toInt() < e.ast.nodes.len);
    std.debug.assert(e.ast.nodes.len > 0);

    const tag = e.ast.nodes.items(.tag)[node.toInt()];

    if (tag == .identifier_value) {
        const name = utils.getNodeText(e, node);
        return e.buffer_ids.get(name);
    }

    return null;
}

/// Emit set_vertex_buffer commands for vertex buffer bindings.
/// Handles arrays of identifiers and single values.
fn emitVertexBufferCommands(e: *Emitter, prop_node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(prop_node.toInt() < e.ast.nodes.len);

    const prop_data = e.ast.nodes.items(.data)[prop_node.toInt()];
    const value_node = prop_data.node;
    const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];

    if (value_tag == .array) {
        const array_data = e.ast.nodes.items(.data)[value_node.toInt()];
        const elements = e.ast.extraData(array_data.extra_range);

        // Bounded iteration
        const max_elements = @min(elements.len, MAX_ARRAY_ELEMENTS);
        for (0..max_elements) |slot| {
            const elem_idx = elements[slot];
            const elem: Node.Index = @enumFromInt(elem_idx);

            if (resolveBufferId(e, elem)) |buffer_id| {
                try e.builder.getEmitter().setVertexBuffer(
                    e.gpa,
                    @intCast(slot),
                    buffer_id,
                );
            }
        }
    } else {
        // Single vertex buffer at slot 0
        if (resolveBufferId(e, value_node)) |buffer_id| {
            try e.builder.getEmitter().setVertexBuffer(e.gpa, 0, buffer_id);
        }
    }
}

fn emitIndexBufferCommand(e: *Emitter, prop_node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(prop_node.toInt() < e.ast.nodes.len);

    const prop_data = e.ast.nodes.items(.data)[prop_node.toInt()];
    const value_node = prop_data.node;
    const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];

    if (value_tag == .identifier_value) {
        const name = utils.getNodeText(e, value_node);
        if (e.buffer_ids.get(name)) |buffer_id| {
            // Format 0 = uint16, 1 = uint32 (default to uint16)
            try e.builder.getEmitter().setIndexBuffer(e.gpa, buffer_id, 0);
        }
    }
}

/// Emit vertex buffer commands with pool offsets.
/// Uses set_vertex_buffer_pool for pooled buffers, set_vertex_buffer otherwise.
fn emitVertexBufferCommandsWithOffsets(
    e: *Emitter,
    prop_node: Node.Index,
    pool_offsets: *const [MAX_ARRAY_ELEMENTS]u8,
) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(prop_node.toInt() < e.ast.nodes.len);

    const prop_data = e.ast.nodes.items(.data)[prop_node.toInt()];
    const value_node = prop_data.node;
    const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];

    if (value_tag == .array) {
        const array_data = e.ast.nodes.items(.data)[value_node.toInt()];
        const elements = e.ast.extraData(array_data.extra_range);

        const max_elements = @min(elements.len, MAX_ARRAY_ELEMENTS);
        for (0..max_elements) |slot| {
            const elem_idx = elements[slot];
            const elem: Node.Index = @enumFromInt(elem_idx);
            const buffer_name = getBufferName(e, elem);
            const buffer_id = resolveBufferId(e, elem);

            if (buffer_id) |base_id| {
                // Check if this buffer has a pool
                if (e.buffer_pools.get(buffer_name)) |pool_info| {
                    // Use pool-aware opcode
                    try e.builder.getEmitter().setVertexBufferPool(
                        e.gpa,
                        @intCast(slot),
                        pool_info.base_id,
                        pool_info.pool_size,
                        pool_offsets[slot],
                    );
                } else {
                    // Use regular opcode
                    try e.builder.getEmitter().setVertexBuffer(
                        e.gpa,
                        @intCast(slot),
                        base_id,
                    );
                }
            }
        }
    } else {
        // Single vertex buffer at slot 0
        const buffer_name = getBufferName(e, value_node);
        if (resolveBufferId(e, value_node)) |base_id| {
            if (e.buffer_pools.get(buffer_name)) |pool_info| {
                try e.builder.getEmitter().setVertexBufferPool(
                    e.gpa,
                    0,
                    pool_info.base_id,
                    pool_info.pool_size,
                    pool_offsets[0],
                );
            } else {
                try e.builder.getEmitter().setVertexBuffer(e.gpa, 0, base_id);
            }
        }
    }
}

/// Emit bind group commands with pool offsets.
/// Uses set_bind_group_pool for pooled bind groups, set_bind_group otherwise.
fn emitBindGroupCommandsWithOffsets(
    e: *Emitter,
    prop_node: Node.Index,
    pool_offsets: *const [MAX_ARRAY_ELEMENTS]u8,
) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(prop_node.toInt() < e.ast.nodes.len);

    const prop_data = e.ast.nodes.items(.data)[prop_node.toInt()];
    const value_node = prop_data.node;
    const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];

    if (value_tag == .array) {
        const array_data = e.ast.nodes.items(.data)[value_node.toInt()];
        const elements = e.ast.extraData(array_data.extra_range);

        const max_elements = @min(elements.len, MAX_ARRAY_ELEMENTS);
        for (0..max_elements) |slot| {
            const elem_idx = elements[slot];
            const elem: Node.Index = @enumFromInt(elem_idx);
            const group_name = getBindGroupName(e, elem);
            const group_id = resolveBindGroupId(e, elem);

            if (group_id) |base_id| {
                // Check if this bind group has a pool
                if (e.bind_group_pools.get(group_name)) |pool_info| {
                    // Use pool-aware opcode
                    try e.builder.getEmitter().setBindGroupPool(
                        e.gpa,
                        @intCast(slot),
                        pool_info.base_id,
                        pool_info.pool_size,
                        pool_offsets[slot],
                    );
                } else {
                    // Use regular opcode
                    try e.builder.getEmitter().setBindGroup(
                        e.gpa,
                        @intCast(slot),
                        base_id,
                    );
                }
            }
        }
    } else {
        // Single bind group at slot 0
        const group_name = getBindGroupName(e, value_node);
        if (resolveBindGroupId(e, value_node)) |base_id| {
            if (e.bind_group_pools.get(group_name)) |pool_info| {
                try e.builder.getEmitter().setBindGroupPool(
                    e.gpa,
                    0,
                    pool_info.base_id,
                    pool_info.pool_size,
                    pool_offsets[0],
                );
            } else {
                try e.builder.getEmitter().setBindGroup(e.gpa, 0, base_id);
            }
        }
    }
}

/// Get buffer name from a node (for pool lookup).
fn getBufferName(e: *Emitter, node: Node.Index) []const u8 {
    const tag = e.ast.nodes.items(.tag)[node.toInt()];

    if (tag == .identifier_value) {
        return utils.getNodeText(e, node);
    }
    return "";
}

/// Get bind group name from a node (for pool lookup).
fn getBindGroupName(e: *Emitter, node: Node.Index) []const u8 {
    const tag = e.ast.nodes.items(.tag)[node.toInt()];

    if (tag == .identifier_value) {
        return utils.getNodeText(e, node);
    }
    return "";
}

/// Emit dispatchWorkgroups command for compute passes.
/// Supports expression evaluation (e.g., "ceil(NUM_PARTICLES / 64)").
fn emitDispatchWorkgroupsCommand(e: *Emitter, prop_node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(prop_node.toInt() < e.ast.nodes.len);

    const prop_data = e.ast.nodes.items(.data)[prop_node.toInt()];
    const value_node = prop_data.node;

    // Try to resolve as numeric value (handles #define references and expressions)
    if (utils.resolveNumericValueOrString(e, value_node)) |count| {
        // Dispatch as single workgroup count (x = count, y = 1, z = 1)
        try e.builder.getEmitter().dispatch(e.gpa, count, 1, 1);
    }
}

/// Emit execute_bundles command to replay pre-recorded render bundles.
/// Handles arrays of render bundle references.
fn emitExecuteBundlesCommand(e: *Emitter, prop_node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(prop_node.toInt() < e.ast.nodes.len);

    const prop_data = e.ast.nodes.items(.data)[prop_node.toInt()];
    const value_node = prop_data.node;
    const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];

    var bundle_ids: [16]u16 = undefined;
    var count: usize = 0;

    if (value_tag == .array) {
        const array_data = e.ast.nodes.items(.data)[value_node.toInt()];
        const elements = e.ast.extraData(array_data.extra_range);

        // Bounded iteration
        const max_elements = @min(elements.len, 16);
        for (0..max_elements) |i| {
            const elem_idx = elements[i];
            const elem: Node.Index = @enumFromInt(elem_idx);
            const bundle_id = resolveRenderBundleId(e, elem);

            if (bundle_id) |id| {
                bundle_ids[count] = id;
                count += 1;
            }
        }
    } else {
        // Single render bundle
        const bundle_id = resolveRenderBundleId(e, value_node);
        if (bundle_id) |id| {
            bundle_ids[0] = id;
            count = 1;
        }
    }

    // Only emit if we have bundles to execute
    if (count > 0) {
        try e.builder.getEmitter().executeBundles(e.gpa, bundle_ids[0..count]);
    }
}

/// Resolve a render bundle identifier to its ID.
fn resolveRenderBundleId(e: *Emitter, node: Node.Index) ?u16 {
    // Pre-condition
    std.debug.assert(node.toInt() < e.ast.nodes.len);

    const tag = e.ast.nodes.items(.tag)[node.toInt()];

    if (tag == .identifier_value) {
        const name = utils.getNodeText(e, node);
        return e.render_bundle_ids.get(name);
    }

    return null;
}
