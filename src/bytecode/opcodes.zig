//! PNGB Opcode Definitions
//!
//! Defines the instruction set for the PNGine bytecode interpreter.
//! Opcodes are organized by category for easy extension.
//!
//! Categories:
//! - 0x00-0x0F: Resource Creation (buffers, textures, pipelines)
//! - 0x10-0x1F: Pass Operations (render/compute pass commands)
//! - 0x20-0x2F: Queue Operations (write, copy, submit)
//! - 0x30-0x3F: Frame Control (frame/pass definitions)
//! - 0x40-0x4F: Pool Operations (resource pooling)
//! - 0x50-0x7F: Data Generation (runtime array generation)
//!
//! Invariants:
//! - Opcode 0x00 is reserved (invalid/nop)
//! - Each opcode has fixed parameter count (no variadic)
//! - Parameters encoded as varints after opcode byte

const std = @import("std");
const assert = std.debug.assert;

/// Bytecode opcodes.
pub const OpCode = enum(u8) {
    // ========================================================================
    // Resource Creation (0x00-0x0F)
    // ========================================================================

    /// No operation / invalid.
    nop = 0x00,

    /// Create GPU buffer.
    /// Params: buffer_id, size, usage_flags
    create_buffer = 0x01,

    /// Create GPU texture.
    /// Params: texture_id, width, height, format, usage_flags
    create_texture = 0x02,

    /// Create sampler.
    /// Params: sampler_id, descriptor_data_id
    create_sampler = 0x03,

    /// Create shader module from data section.
    /// Params: shader_id, code_data_id
    create_shader_module = 0x04,

    /// Create shader by concatenating multiple data sections (WGSL composition).
    /// Params: shader_id, count, data_id_0, data_id_1, ...
    create_shader_concat = 0x05,

    /// Create bind group layout.
    /// Params: layout_id, descriptor_data_id
    create_bind_group_layout = 0x06,

    /// Create pipeline layout.
    /// Params: layout_id, descriptor_data_id
    create_pipeline_layout = 0x07,

    /// Create render pipeline.
    /// Params: pipeline_id, descriptor_data_id
    create_render_pipeline = 0x08,

    /// Create compute pipeline.
    /// Params: pipeline_id, descriptor_data_id
    create_compute_pipeline = 0x09,

    /// Create bind group.
    /// Params: group_id, layout_id, entry_count, entries...
    create_bind_group = 0x0A,

    // ========================================================================
    // Pass Operations (0x10-0x1F)
    // ========================================================================

    /// Begin render pass.
    /// Params: color_texture_id, load_op, store_op, depth_texture_id (0xFFFF = none)
    begin_render_pass = 0x10,

    /// Begin compute pass.
    /// Params: (none)
    begin_compute_pass = 0x11,

    /// Set current pipeline.
    /// Params: pipeline_id
    set_pipeline = 0x12,

    /// Set bind group.
    /// Params: slot, group_id
    set_bind_group = 0x13,

    /// Set vertex buffer.
    /// Params: slot, buffer_id
    set_vertex_buffer = 0x14,

    /// Set index buffer.
    /// Params: buffer_id, format
    set_index_buffer = 0x15,

    /// Draw primitives.
    /// Params: vertex_count, instance_count
    draw = 0x16,

    /// Draw indexed primitives.
    /// Params: index_count, instance_count
    draw_indexed = 0x17,

    /// Dispatch compute workgroups.
    /// Params: x, y, z
    dispatch = 0x18,

    /// End current pass.
    /// Params: (none)
    end_pass = 0x19,

    // ========================================================================
    // Queue Operations (0x20-0x2F)
    // ========================================================================

    /// Write data to buffer.
    /// Params: buffer_id, offset, data_id
    write_buffer = 0x20,

    /// Write uniform data (runtime-resolved).
    /// Params: buffer_id, uniform_id
    write_uniform = 0x21,

    /// Copy buffer to buffer.
    /// Params: src_buffer, src_offset, dst_buffer, dst_offset, size
    copy_buffer_to_buffer = 0x22,

    /// Copy texture to texture.
    /// Params: src_texture, dst_texture
    copy_texture_to_texture = 0x23,

    /// Submit command buffer to queue.
    /// Params: (none)
    submit = 0x24,

    // ========================================================================
    // Frame Control (0x30-0x3F)
    // ========================================================================

    /// Define a frame.
    /// Params: frame_id, name_string_id
    define_frame = 0x30,

    /// End frame definition.
    /// Params: (none)
    end_frame = 0x31,

    /// Execute a pass within a frame.
    /// Params: pass_id
    exec_pass = 0x32,

    /// Define a pass.
    /// Params: pass_id, pass_type, descriptor_data_id
    define_pass = 0x33,

    /// End pass definition.
    /// Params: (none)
    end_pass_def = 0x34,

    // ========================================================================
    // Pool Operations (0x40-0x4F)
    // ========================================================================

    /// Select resource from pool (ping-pong).
    /// Params: dest_slot, pool_id, frame_offset
    select_from_pool = 0x40,

    // ========================================================================
    // Data Generation (0x50-0x7F) - Runtime Data Generation
    // ========================================================================

    /// Create typed array.
    /// Params: array_id, element_type, element_count
    create_typed_array = 0x50,

    /// Fill with constant value.
    /// Params: array_id, offset, count, stride, value
    fill_constant = 0x51,

    /// Fill with random values.
    /// Params: array_id, offset, count, stride, seed, min, max
    fill_random = 0x52,

    /// Fill with linear sequence.
    /// Params: array_id, offset, count, stride, start, step
    fill_linear = 0x53,

    /// Fill with element index.
    /// Params: array_id, offset, count, stride, scale, bias
    fill_element_index = 0x54,

    /// Fill with expression result.
    /// Params: array_id, offset, count, stride, expr_data_id
    fill_expression = 0x55,

    _,

    /// Check if opcode is valid.
    pub fn isValid(self: OpCode) bool {
        return switch (self) {
            .nop,
            .create_buffer,
            .create_texture,
            .create_sampler,
            .create_shader_module,
            .create_shader_concat,
            .create_bind_group_layout,
            .create_pipeline_layout,
            .create_render_pipeline,
            .create_compute_pipeline,
            .create_bind_group,
            .begin_render_pass,
            .begin_compute_pass,
            .set_pipeline,
            .set_bind_group,
            .set_vertex_buffer,
            .set_index_buffer,
            .draw,
            .draw_indexed,
            .dispatch,
            .end_pass,
            .write_buffer,
            .write_uniform,
            .copy_buffer_to_buffer,
            .copy_texture_to_texture,
            .submit,
            .define_frame,
            .end_frame,
            .exec_pass,
            .define_pass,
            .end_pass_def,
            .select_from_pool,
            .create_typed_array,
            .fill_constant,
            .fill_random,
            .fill_linear,
            .fill_element_index,
            .fill_expression,
            => true,
            _ => false,
        };
    }
};

/// Buffer usage flags (matches WebGPU GPUBufferUsage).
pub const BufferUsage = packed struct(u8) {
    map_read: bool = false,
    map_write: bool = false,
    copy_src: bool = false,
    copy_dst: bool = false,
    index: bool = false,
    vertex: bool = false,
    uniform: bool = false,
    storage: bool = false,

    pub const uniform_copy_dst: BufferUsage = .{ .uniform = true, .copy_dst = true };
    pub const vertex_copy_dst: BufferUsage = .{ .vertex = true, .copy_dst = true };
    pub const storage_copy_dst: BufferUsage = .{ .storage = true, .copy_dst = true };
};

/// Load operation for render pass attachments.
pub const LoadOp = enum(u8) {
    load = 0,
    clear = 1,
};

/// Store operation for render pass attachments.
pub const StoreOp = enum(u8) {
    store = 0,
    discard = 1,
};

/// Pass type.
pub const PassType = enum(u8) {
    render = 0,
    compute = 1,
};

/// Element type for typed arrays.
pub const ElementType = enum(u8) {
    f32 = 0,
    i32 = 1,
    u32 = 2,
    f16 = 3,
    vec2f = 4,
    vec3f = 5,
    vec4f = 6,
    mat4x4f = 7,
};

// ============================================================================
// Variable-Length Integer Encoding (LEB128-style)
// ============================================================================

/// Encode a varint to buffer.
/// Returns number of bytes written.
///
/// Encoding:
/// - 0-127: 0xxxxxxx (1 byte)
/// - 128-16383: 10xxxxxx xxxxxxxx (2 bytes)
/// - 16384+: 11xxxxxx xxxxxxxx xxxxxxxx xxxxxxxx (4 bytes)
pub fn encodeVarint(value: u32, buffer: *[4]u8) u8 {
    if (value < 128) {
        buffer[0] = @intCast(value);
        return 1;
    } else if (value < 16384) {
        buffer[0] = 0x80 | @as(u8, @intCast(value >> 8));
        buffer[1] = @intCast(value & 0xFF);
        return 2;
    } else {
        buffer[0] = 0xC0 | @as(u8, @intCast(value >> 24));
        buffer[1] = @intCast((value >> 16) & 0xFF);
        buffer[2] = @intCast((value >> 8) & 0xFF);
        buffer[3] = @intCast(value & 0xFF);
        return 4;
    }
}

/// Decode a varint from buffer.
/// Returns value and number of bytes consumed.
pub fn decodeVarint(buffer: []const u8) struct { value: u32, len: u8 } {
    // Pre-condition: buffer has at least 1 byte
    assert(buffer.len >= 1);

    const first = buffer[0];

    if (first & 0x80 == 0) {
        // 1 byte: 0xxxxxxx
        return .{ .value = first, .len = 1 };
    } else if (first & 0xC0 == 0x80) {
        // 2 bytes: 10xxxxxx xxxxxxxx
        assert(buffer.len >= 2);
        const high: u32 = first & 0x3F;
        const low: u32 = buffer[1];
        return .{ .value = (high << 8) | low, .len = 2 };
    } else {
        // 4 bytes: 11xxxxxx xxxxxxxx xxxxxxxx xxxxxxxx
        assert(buffer.len >= 4);
        const b0: u32 = first & 0x3F;
        const b1: u32 = buffer[1];
        const b2: u32 = buffer[2];
        const b3: u32 = buffer[3];
        return .{ .value = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3, .len = 4 };
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "opcode validity" {
    try testing.expect(OpCode.create_buffer.isValid());
    try testing.expect(OpCode.draw.isValid());
    try testing.expect(OpCode.submit.isValid());

    const invalid: OpCode = @enumFromInt(0xFF);
    try testing.expect(!invalid.isValid());
}

test "varint encoding: 1 byte" {
    var buffer: [4]u8 = undefined;

    try testing.expectEqual(@as(u8, 1), encodeVarint(0, &buffer));
    try testing.expectEqual(@as(u8, 0), buffer[0]);

    try testing.expectEqual(@as(u8, 1), encodeVarint(127, &buffer));
    try testing.expectEqual(@as(u8, 127), buffer[0]);
}

test "varint encoding: 2 bytes" {
    var buffer: [4]u8 = undefined;

    try testing.expectEqual(@as(u8, 2), encodeVarint(128, &buffer));
    try testing.expectEqual(@as(u8, 0x80), buffer[0]);
    try testing.expectEqual(@as(u8, 128), buffer[1]);

    try testing.expectEqual(@as(u8, 2), encodeVarint(16383, &buffer));
}

test "varint encoding: 4 bytes" {
    var buffer: [4]u8 = undefined;

    try testing.expectEqual(@as(u8, 4), encodeVarint(16384, &buffer));
    try testing.expectEqual(@as(u8, 0xC0), buffer[0]);

    try testing.expectEqual(@as(u8, 4), encodeVarint(1000000, &buffer));
}

test "varint roundtrip" {
    var buffer: [4]u8 = undefined;

    const test_values = [_]u32{ 0, 1, 127, 128, 255, 16383, 16384, 65535, 1000000, 0xFFFFFF };

    for (test_values) |value| {
        const len = encodeVarint(value, &buffer);
        const decoded = decodeVarint(buffer[0..len]);
        try testing.expectEqual(value, decoded.value);
        try testing.expectEqual(len, decoded.len);
    }
}

test "buffer usage flags" {
    const usage = BufferUsage.uniform_copy_dst;
    try testing.expect(usage.uniform);
    try testing.expect(usage.copy_dst);
    try testing.expect(!usage.vertex);
    try testing.expect(!usage.storage);
}
