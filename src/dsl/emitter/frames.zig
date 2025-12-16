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
    }

    // Post-condition: IDs assigned match symbol count
    std.debug.assert(e.next_queue_id - initial_id == e.queue_ids.count());
}

/// Emit a queue's actions (write_buffer commands) inline.
/// Called when a frame references a queue in its perform array.
pub fn emitQueueAction(e: *Emitter, queue_name: []const u8) Emitter.Error!void {
    // Pre-conditions
    std.debug.assert(queue_name.len > 0);
    std.debug.assert(e.ast.nodes.len > 0);

    // Queue must exist in symbol table
    const info = e.analysis.symbols.queue.get(queue_name) orelse return;
    std.debug.assert(info.node.toInt() < e.ast.nodes.len);

    // Look for writeBuffer property in queue definition
    const write_buffer_value = utils.findPropertyValue(e, info.node, "writeBuffer") orelse return;
    const wb_tag = e.ast.nodes.items(.tag)[write_buffer_value.toInt()];

    if (wb_tag != .object) return;

    try emitWriteBufferFromObject(e, write_buffer_value);
}

/// Parse and emit a writeBuffer command from an object node.
fn emitWriteBufferFromObject(e: *Emitter, obj_node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(obj_node.toInt() < e.ast.nodes.len);

    // Parse writeBuffer object: { buffer=..., bufferOffset=..., data=... }
    const buffer_prop = utils.findPropertyValueInObject(e, obj_node, "buffer");
    const offset_prop = utils.findPropertyValueInObject(e, obj_node, "bufferOffset");
    const data_prop = utils.findPropertyValueInObject(e, obj_node, "data");

    // Resolve buffer reference
    const buffer_id = if (buffer_prop) |bp| passes.resolveBufferId(e, bp) else null;
    if (buffer_id == null) return;

    // Parse offset (default 0)
    const offset: u32 = if (offset_prop) |op|
        utils.parseNumber(e, op) orelse 0
    else
        0;

    // Handle data property
    if (data_prop) |dp| {
        try emitWriteBufferData(e, buffer_id.?, offset, dp);
    }
}

/// Emit write_buffer command with parsed data.
fn emitWriteBufferData(e: *Emitter, buffer_id: u16, offset: u32, data_node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(data_node.toInt() < e.ast.nodes.len);

    const data_tag = e.ast.nodes.items(.tag)[data_node.toInt()];

    if (data_tag == .array) {
        try emitWriteBufferArray(e, buffer_id, offset, data_node);
    } else if (data_tag == .string_value) {
        try emitWriteBufferString(e, buffer_id, offset, data_node);
    }
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

/// Emit write_buffer from a string value (hex bytes or skip for runtime refs).
fn emitWriteBufferString(e: *Emitter, buffer_id: u16, offset: u32, string_node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(string_node.toInt() < e.ast.nodes.len);

    const data_str = utils.getStringContent(e, string_node);

    // Check for runtime interpolation (starts with $)
    if (data_str.len > 0 and data_str[0] == '$') {
        // Runtime interpolation ($uniforms.x.y.data, $time, etc.)
        // Skip emitting write_buffer - JS will handle via writeTimeUniform
        return;
    }

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
    }

    // Post-condition: frame IDs were assigned sequentially
    std.debug.assert(e.next_frame_id >= initial_frame_id);
}

fn emitFrameBody(e: *Emitter, node: Node.Index) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(node.toInt() < e.ast.nodes.len);

    // Look for perform array
    const perform_value = utils.findPropertyValue(e, node, "perform") orelse return;
    const value_tag = e.ast.nodes.items(.tag)[perform_value.toInt()];

    if (value_tag != .array) return;

    const array_data = e.ast.nodes.items(.data)[perform_value.toInt()];
    const elements = e.ast.extraData(array_data.extra_range);

    // Bounded iteration over perform actions
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
