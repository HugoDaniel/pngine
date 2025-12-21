//! Frame Emission Module
//!
//! Handles emission of frame declarations:
//! - #frame (frame definition + execution order)
//! - #queue (buffer write actions, inlined in frames)
//!
//! Frames define the execution order of passes and queue actions.
//!
//! ## Invariants
//!
//! * Frame IDs are assigned sequentially starting from next_frame_id.
//! * Queue IDs are assigned sequentially starting from next_queue_id.
//! * Queue actions (writeBuffer) are inlined in frames, not emitted separately.
//! * All iteration is bounded by MAX_QUEUE_ACTIONS or MAX_PERFORM_ACTIONS.
//! * Frame names are interned in string table before use.

const std = @import("std");
const Emitter = @import("../Emitter.zig").Emitter;
const Node = @import("../Ast.zig").Node;
const utils = @import("utils.zig");
const passes = @import("passes.zig");
const wasm = @import("wasm.zig");

/// Maximum queue actions per frame (prevents runaway iteration).
const MAX_QUEUE_ACTIONS: u32 = 64;

/// Maximum perform actions per frame.
const MAX_PERFORM_ACTIONS: u32 = 64;

/// Maximum array elements to parse.
const MAX_ARRAY_ELEMENTS: u32 = 256;

/// Collect queue IDs (queues are inlined at frame execution, not bytecode-defined).
/// Queues don't emit bytecode here - they're inlined when frames reference them.
pub fn collectQueues(e: *Emitter) Emitter.Error!void {
    // Pre-condition: ID counter starts at expected value
    const initial_id = e.next_queue_id;
    std.debug.assert(e.queue_ids.count() == 0);

    var it = e.analysis.symbols.queue.iterator();
    for (0..MAX_QUEUE_ACTIONS) |_| {
        const entry = it.next() orelse break;
        const name = entry.key_ptr.*;

        const queue_id = e.next_queue_id;
        e.next_queue_id += 1;
        try e.queue_ids.put(e.gpa, name, queue_id);
    } else unreachable; // Exceeded MAX_QUEUE_ACTIONS

    // Post-condition: IDs assigned match symbol count
    std.debug.assert(e.next_queue_id - initial_id == e.queue_ids.count());
}

/// Emit a queue's actions (write_buffer, copyExternalImageToTexture) inline.
/// Called when a frame references a queue in its perform array.
pub fn emitQueueAction(e: *Emitter, queue_name: []const u8) Emitter.Error!void {
    // Pre-conditions
    std.debug.assert(queue_name.len > 0);
    std.debug.assert(e.ast.nodes.len > 0);

    // Queue must exist in symbol table
    const info = e.analysis.symbols.queue.get(queue_name) orelse return;
    std.debug.assert(info.node.toInt() < e.ast.nodes.len);

    // Look for writeBuffer property in queue definition
    if (utils.findPropertyValue(e, info.node, "writeBuffer")) |write_buffer_value| {
        const wb_tag = e.ast.nodes.items(.tag)[write_buffer_value.toInt()];
        if (wb_tag == .object) {
            try emitWriteBufferFromObject(e, write_buffer_value);
        }
    }

    // Look for copyExternalImageToTexture property
    if (utils.findPropertyValue(e, info.node, "copyExternalImageToTexture")) |ceit_value| {
        const ceit_tag = e.ast.nodes.items(.tag)[ceit_value.toInt()];
        if (ceit_tag == .object) {
            try emitCopyExternalImageToTexture(e, ceit_value);
        }
    }
}

/// Parse and emit a writeBuffer command from an object node.
fn emitWriteBufferFromObject(e: *Emitter, obj_node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(obj_node.toInt() < e.ast.nodes.len);

    // Parse writeBuffer object: { buffer=..., bufferOffset=..., data=..., dataFrom=... }
    const buffer_prop = utils.findPropertyValueInObject(e, obj_node, "buffer");
    const offset_prop = utils.findPropertyValueInObject(e, obj_node, "bufferOffset");
    const data_prop = utils.findPropertyValueInObject(e, obj_node, "data");
    const data_from_prop = utils.findPropertyValueInObject(e, obj_node, "dataFrom");

    // Resolve buffer reference
    const buffer_id = if (buffer_prop) |bp| passes.resolveBufferId(e, bp) else null;
    if (buffer_id == null) return;

    // Parse offset (default 0)
    const offset: u32 = if (offset_prop) |op|
        utils.parseNumber(e, op) orelse 0
    else
        0;

    // Handle dataFrom={wasm=...} - calls WASM function and writes result
    if (data_from_prop) |df| {
        try emitDataFromSource(e, buffer_id.?, offset, df);
        return;
    }

    // Handle data property (literal data)
    if (data_prop) |dp| {
        try emitWriteBufferData(e, buffer_id.?, offset, dp);
    }
}

/// Emit buffer write from a dataFrom source.
fn emitDataFromSource(e: *Emitter, buffer_id: u16, offset: u32, data_from_node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(data_from_node.toInt() < e.ast.nodes.len);

    const tag = e.ast.nodes.items(.tag)[data_from_node.toInt()];
    if (tag != .object) return;

    // Check for wasm={...} property
    if (utils.findPropertyValueInObject(e, data_from_node, "wasm")) |wasm_ref| {
        const wasm_call_name = resolveIdentifierOrReference(e, wasm_ref) orelse return;
        try wasm.emitWasmCallForBuffer(e, wasm_call_name, buffer_id, offset);
    }
}

/// Emit write_buffer command with parsed data.
/// Supports:
/// - array: data=[1.0 2.0 3.0]
/// - string: literal hex bytes
/// - identifier: data=myDataName (references #data)
/// - uniform_access: data=code.inputs (references shader uniform)
fn emitWriteBufferData(e: *Emitter, buffer_id: u16, offset: u32, data_node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(data_node.toInt() < e.ast.nodes.len);

    const data_tag = e.ast.nodes.items(.tag)[data_node.toInt()];

    if (data_tag == .array) {
        try emitWriteBufferArray(e, buffer_id, offset, data_node);
    } else if (data_tag == .string_value) {
        try emitWriteBufferString(e, buffer_id, offset, data_node);
    } else if (data_tag == .uniform_access) {
        // Uniform access: data=code.inputs → write_time_uniform
        try emitUniformAccess(e, buffer_id, offset, data_node);
    } else if (data_tag == .identifier_value) {
        // Direct identifier reference: data=simParamsData
        const name_token = e.ast.nodes.items(.main_token)[data_node.toInt()];
        const data_name = utils.getTokenSlice(e, name_token);
        if (e.data_ids.get(data_name)) |data_entry_id| {
            try e.builder.getEmitter().writeBuffer(e.gpa, buffer_id, offset, data_entry_id);
        }
    }
}

/// Emit write_time_uniform for uniform_access nodes (code.inputs).
fn emitUniformAccess(e: *Emitter, buffer_id: u16, offset: u32, node: Node.Index) Emitter.Error!void {
    // Pre-condition: node is uniform_access
    std.debug.assert(node.toInt() < e.ast.nodes.len);
    std.debug.assert(e.ast.nodes.items(.tag)[node.toInt()] == .uniform_access);

    // Use pre-resolved metadata from Analyzer
    const uniform_info = e.analysis.resolved_uniforms.get(node.toInt()) orelse {
        // Fallback if not resolved (shouldn't happen if Analyzer ran)
        try e.builder.getEmitter().writeTimeUniform(e.gpa, buffer_id, offset, 12);
        return;
    };

    // Emit opcode with resolved size
    try e.builder.getEmitter().writeTimeUniform(
        e.gpa,
        buffer_id,
        offset,
        uniform_info.size,
    );
}

/// Emit write_buffer from an array of numbers (as f32 values).
fn emitWriteBufferArray(e: *Emitter, buffer_id: u16, offset: u32, array_node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(array_node.toInt() < e.ast.nodes.len);

    var data_bytes: std.ArrayListUnmanaged(u8) = .{};
    defer data_bytes.deinit(e.gpa);

    const array_data = e.ast.nodes.items(.data)[array_node.toInt()];
    const elements = e.ast.extraData(array_data.extra_range);

    // Bounded iteration over array elements
    const max_elements = @min(elements.len, MAX_ARRAY_ELEMENTS);
    for (0..max_elements) |i| {
        const elem_idx = elements[i];
        const elem: Node.Index = @enumFromInt(elem_idx);
        if (utils.parseFloatNumber(e, elem)) |num| {
            // Write as f32
            const f: f32 = @floatCast(num);
            const bytes = std.mem.asBytes(&f);
            data_bytes.appendSlice(e.gpa, bytes) catch continue;
        }
    }

    if (data_bytes.items.len > 0) {
        const data_id = try e.builder.addData(e.gpa, data_bytes.items);
        try e.builder.getEmitter().writeBuffer(
            e.gpa,
            buffer_id,
            offset,
            data_id.toInt(),
        );
    }

    // Post-condition: either we emitted data or array was empty/invalid
    std.debug.assert(data_bytes.items.len == 0 or data_bytes.items.len % 4 == 0);
}

/// Emit write_buffer from a string value (literal hex bytes only).
fn emitWriteBufferString(e: *Emitter, buffer_id: u16, offset: u32, string_node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(string_node.toInt() < e.ast.nodes.len);

    const data_str = utils.getStringContent(e, string_node);

    // Literal string data (hex bytes)
    if (data_str.len > 0) {
        const data_id = try e.builder.addData(e.gpa, data_str);
        try e.builder.getEmitter().writeBuffer(
            e.gpa,
            buffer_id,
            offset,
            data_id.toInt(),
        );
    }
}

/// Emit copyExternalImageToTexture queue command.
///
/// Maps WebGPU's copyExternalImageToTexture API which copies an ImageBitmap
/// to a GPU texture. This is the standard way to upload decoded image data.
///
/// Syntax: copyExternalImageToTexture={source={source=...} destination={texture=...}}
fn emitCopyExternalImageToTexture(e: *Emitter, obj_node: Node.Index) Emitter.Error!void {
    // Pre-condition: node must be valid object
    std.debug.assert(obj_node.toInt() < e.ast.nodes.len);

    // WebGPU requires source.source to be an ImageBitmap (our #imageBitmap resource)
    const source_obj = utils.findPropertyValueInObject(e, obj_node, "source") orelse return;
    const source_tag = e.ast.nodes.items(.tag)[source_obj.toInt()];
    if (source_tag != .object) return;

    const source_prop = utils.findPropertyValueInObject(e, source_obj, "source") orelse return;
    const bitmap_name = resolveIdentifierOrReference(e, source_prop) orelse return;

    // Bitmap must exist - silently skip if not (analyzer should catch this)
    const bitmap_id = e.image_bitmap_ids.get(bitmap_name) orelse return;

    // WebGPU requires destination.texture to be a GPUTexture
    const dest_obj = utils.findPropertyValueInObject(e, obj_node, "destination") orelse return;
    const dest_tag = e.ast.nodes.items(.tag)[dest_obj.toInt()];
    if (dest_tag != .object) return;

    const texture_prop = utils.findPropertyValueInObject(e, dest_obj, "texture") orelse return;
    const texture_name = resolveIdentifierOrReference(e, texture_prop) orelse return;

    // Texture must exist - silently skip if not (analyzer should catch this)
    const texture_id = e.texture_ids.get(texture_name) orelse return;

    // mipLevel defaults to 0 per WebGPU spec
    const mip_level: u8 = if (utils.findPropertyValueInObject(e, dest_obj, "mipLevel")) |ml|
        @intCast(utils.parseNumber(e, ml) orelse 0)
    else
        0;

    // origin defaults to [0, 0] per WebGPU spec
    var origin_x: u16 = 0;
    var origin_y: u16 = 0;
    if (utils.findPropertyValueInObject(e, dest_obj, "origin")) |origin_node| {
        const origin_tag = e.ast.nodes.items(.tag)[origin_node.toInt()];
        if (origin_tag == .array) {
            const array_data = e.ast.nodes.items(.data)[origin_node.toInt()];
            const elements = e.ast.extraData(array_data.extra_range);
            if (elements.len >= 1) {
                const x_elem: Node.Index = @enumFromInt(elements[0]);
                origin_x = @intCast(utils.parseNumber(e, x_elem) orelse 0);
            }
            if (elements.len >= 2) {
                const y_elem: Node.Index = @enumFromInt(elements[1]);
                origin_y = @intCast(utils.parseNumber(e, y_elem) orelse 0);
            }
        }
    }

    try e.builder.getEmitter().copyExternalImageToTexture(
        e.gpa,
        bitmap_id,
        texture_id,
        mip_level,
        origin_x,
        origin_y,
    );
}

/// Resolve an identifier or reference node to its name string.
/// Used for looking up resources by name when parsing queue operations.
fn resolveIdentifierOrReference(e: *Emitter, node: Node.Index) ?[]const u8 {
    // Pre-condition: node must be valid
    std.debug.assert(node.toInt() < e.ast.nodes.len);

    const tag = e.ast.nodes.items(.tag)[node.toInt()];

    if (tag == .identifier_value) {
        const token = e.ast.nodes.items(.main_token)[node.toInt()];
        return utils.getTokenSlice(e, token);
    } else if (tag == .reference) {
        if (utils.getReference(e, node)) |ref| {
            return ref.name;
        }
    }

    return null;
}

/// Emit #frame declarations.
pub fn emitFrames(e: *Emitter) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(e.ast.nodes.len > 0);

    const initial_frame_id = e.next_frame_id;

    var it = e.analysis.symbols.frame.iterator();
    for (0..MAX_QUEUE_ACTIONS) |_| {
        const entry = it.next() orelse break;
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        const frame_id = e.next_frame_id;
        e.next_frame_id += 1;
        try e.frame_ids.put(e.gpa, name, frame_id);

        // Intern frame name
        const name_id = try e.builder.internString(e.gpa, name);

        // Define frame
        try e.builder.getEmitter().defineFrame(e.gpa, frame_id, name_id.toInt());

        // Emit frame body
        try emitFrameBody(e, info.node);

        // Submit and end frame
        try e.builder.getEmitter().submit(e.gpa);
        try e.builder.getEmitter().endFrame(e.gpa);
    } else unreachable; // Exceeded MAX_QUEUE_ACTIONS

    // Post-condition: frame IDs were assigned sequentially
    std.debug.assert(e.next_frame_id >= initial_frame_id);
}

fn emitFrameBody(e: *Emitter, node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(node.toInt() < e.ast.nodes.len);

    // Emit 'before' array (queue actions before passes)
    if (utils.findPropertyValue(e, node, "before")) |before_value| {
        try emitActionArray(e, before_value);
    }

    // Emit 'perform' array (pass/queue actions)
    if (utils.findPropertyValue(e, node, "perform")) |perform_value| {
        try emitActionArray(e, perform_value);
    }

    // Emit 'after' array (queue actions after passes)
    if (utils.findPropertyValue(e, node, "after")) |after_value| {
        try emitActionArray(e, after_value);
    }
}

/// Emit an array of actions (passes or queues).
fn emitActionArray(e: *Emitter, array_node: Node.Index) Emitter.Error!void {
    const value_tag = e.ast.nodes.items(.tag)[array_node.toInt()];
    if (value_tag != .array) return;

    const array_data = e.ast.nodes.items(.data)[array_node.toInt()];
    const elements = e.ast.extraData(array_data.extra_range);

    // Bounded iteration over actions
    const max_elements = @min(elements.len, MAX_PERFORM_ACTIONS);
    for (0..max_elements) |i| {
        const elem_idx = elements[i];
        const elem: Node.Index = @enumFromInt(elem_idx);
        try emitPerformAction(e, elem);
    }
}

/// Emit a single perform action (pass or queue reference).
fn emitPerformAction(e: *Emitter, elem: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(elem.toInt() < e.ast.nodes.len);

    const elem_tag = e.ast.nodes.items(.tag)[elem.toInt()];

    if (elem_tag == .reference) {
        try emitReferenceAction(e, elem);
    } else if (elem_tag == .identifier_value) {
        try emitIdentifierAction(e, elem);
    }
}

/// Emit action from a reference node ($namespace.name).
fn emitReferenceAction(e: *Emitter, elem: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(elem.toInt() < e.ast.nodes.len);

    const ref = utils.getReference(e, elem) orelse return;

    // Check namespace to determine action type
    if (std.mem.eql(u8, ref.namespace, "queue")) {
        // Queue reference - inline the write_buffer commands
        if (e.queue_ids.get(ref.name) != null) {
            try emitQueueAction(e, ref.name);
        }
    } else {
        // Pass reference (renderPass, computePass)
        if (e.pass_ids.get(ref.name)) |pass_id| {
            try e.builder.getEmitter().execPass(e.gpa, pass_id);
        }
    }
}

/// Emit action from an identifier node.
fn emitIdentifierAction(e: *Emitter, elem: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(elem.toInt() < e.ast.nodes.len);

    const name_token = e.ast.nodes.items(.main_token)[elem.toInt()];
    const action_name = utils.getTokenSlice(e, name_token);

    if (e.pass_ids.get(action_name)) |pass_id| {
        try e.builder.getEmitter().execPass(e.gpa, pass_id);
    } else if (e.queue_ids.get(action_name) != null) {
        // Queue reference - inline the write_buffer commands
        try emitQueueAction(e, action_name);
    }

    // Post-condition: action_name was valid identifier
    std.debug.assert(action_name.len > 0);
}
