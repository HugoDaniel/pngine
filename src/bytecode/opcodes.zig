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

    /// Create image bitmap from blob data.
    /// Params: bitmap_id, blob_data_id
    /// blob_data_id points to data section entry with format: [mime_len:u8][mime:bytes][data:bytes]
    create_image_bitmap = 0x0B,

    /// Create texture view.
    /// Params: view_id, texture_id, descriptor_data_id
    create_texture_view = 0x0C,

    /// Create query set.
    /// Params: query_set_id, descriptor_data_id
    create_query_set = 0x0D,

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

    /// Copy external image (ImageBitmap) to texture.
    /// Params: bitmap_id, texture_id, mip_level, origin_x, origin_y
    copy_external_image_to_texture = 0x25,

    /// Initialize WASM module from embedded data.
    /// Params: module_id, wasm_data_id
    /// wasm_data_id points to data section entry containing raw .wasm bytes
    init_wasm_module = 0x26,

    /// Call WASM exported function.
    /// Params: call_id, module_id, func_name_id, arg_count, [args...]
    /// Each arg is: [arg_type:u8][value:varies]
    /// Returns pointer stored by call_id for later read
    call_wasm_func = 0x27,

    /// Write WASM memory to GPU buffer.
    /// Params: call_id, buffer_id, offset, byte_len
    /// Reads byte_len bytes from WASM memory at pointer from call_id
    write_buffer_from_wasm = 0x28,

    /// Write runtime-generated array to GPU buffer.
    /// Params: buffer_id, buffer_offset, array_id
    /// Copies typed array data to buffer at specified offset.
    write_buffer_from_array = 0x29,

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

    /// Set vertex buffer from pool.
    /// Params: slot, base_buffer_id, pool_size, offset
    /// Actual buffer ID = base_buffer_id + (frame_counter + offset) % pool_size
    set_vertex_buffer_pool = 0x41,

    /// Set bind group from pool.
    /// Params: slot, base_group_id, pool_size, offset
    /// Actual group ID = base_group_id + (frame_counter + offset) % pool_size
    set_bind_group_pool = 0x42,

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
            .create_image_bitmap,
            .create_texture_view,
            .create_query_set,
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
            .copy_external_image_to_texture,
            .init_wasm_module,
            .call_wasm_func,
            .write_buffer_from_wasm,
            .write_buffer_from_array,
            .define_frame,
            .end_frame,
            .exec_pass,
            .define_pass,
            .end_pass_def,
            .select_from_pool,
            .set_vertex_buffer_pool,
            .set_bind_group_pool,
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

/// WASM function argument types for call_wasm_func opcode.
///
/// Each argument in a WASM call is encoded as:
/// - 1 byte: WasmArgType
/// - 0-4 bytes: value (depends on type)
///
/// Runtime-resolved types (canvas_width, etc.) have no value bytes.
pub const WasmArgType = enum(u8) {
    /// Literal f32 value (4 bytes follow)
    literal_f32 = 0x00,
    /// Runtime: canvas.width (u32, no value bytes)
    canvas_width = 0x01,
    /// Runtime: canvas.height (u32, no value bytes)
    canvas_height = 0x02,
    /// Runtime: time in seconds (f32, no value bytes)
    time_total = 0x03,
    /// Literal i32 value (4 bytes follow)
    literal_i32 = 0x04,
    /// Literal u32 value (4 bytes follow)
    literal_u32 = 0x05,
    /// Runtime: delta time since last frame (f32, no value bytes)
    time_delta = 0x06,

    /// Returns byte size of value following the type byte.
    /// Runtime types return 0 (resolved at execution time).
    pub fn valueByteSize(self: WasmArgType) u8 {
        return switch (self) {
            .literal_f32, .literal_i32, .literal_u32 => 4,
            .canvas_width, .canvas_height, .time_total, .time_delta => 0,
        };
    }
};

/// Return type size mapping for WASM call results.
/// Maps type names to byte sizes for buffer writes.
pub const WasmReturnType = struct {
    /// Get byte size for a return type name.
    /// Returns null for unknown types.
    pub fn byteSize(type_name: []const u8) ?u32 {
        const map = std.StaticStringMap(u32).initComptime(.{
            .{ "f32", 4 },
            .{ "i32", 4 },
            .{ "u32", 4 },
            .{ "vec2", 8 },
            .{ "vec3", 12 },
            .{ "vec4", 16 },
            .{ "mat3x3", 36 },
            .{ "mat4x4", 64 },
        });
        return map.get(type_name);
    }
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

// ============================================================================
// New Opcode Tests (create_image_bitmap, copy_external_image_to_texture)
// ============================================================================

test "create_image_bitmap opcode validity" {
    // Pre-condition: opcode is a valid u8
    const op = OpCode.create_image_bitmap;
    try testing.expectEqual(@as(u8, 0x0B), @intFromEnum(op));

    // Post-condition: isValid returns true for this opcode
    try testing.expect(op.isValid());
}

test "copy_external_image_to_texture opcode validity" {
    // Pre-condition: opcode is a valid u8
    const op = OpCode.copy_external_image_to_texture;
    try testing.expectEqual(@as(u8, 0x25), @intFromEnum(op));

    // Post-condition: isValid returns true for this opcode
    try testing.expect(op.isValid());
}

test "image-related opcodes in correct category ranges" {
    // create_image_bitmap in Resource Creation (0x00-0x0F)
    const create_bitmap = @intFromEnum(OpCode.create_image_bitmap);
    try testing.expect(create_bitmap >= 0x00 and create_bitmap <= 0x0F);

    // copy_external_image_to_texture in Queue Operations (0x20-0x2F)
    const copy_op = @intFromEnum(OpCode.copy_external_image_to_texture);
    try testing.expect(copy_op >= 0x20 and copy_op <= 0x2F);
}

test "varint roundtrip for image bitmap IDs" {
    // Test typical bitmap/texture ID values (small IDs common)
    var buffer: [4]u8 = undefined;
    const test_ids = [_]u32{ 0, 1, 10, 127, 128, 255, 1000 };

    for (test_ids) |id| {
        const len = encodeVarint(id, &buffer);
        const decoded = decodeVarint(buffer[0..len]);

        // Property: roundtrip preserves value and length
        try testing.expectEqual(id, decoded.value);
        try testing.expectEqual(len, decoded.len);
    }
}

test "varint encoding boundary cases for origin coordinates" {
    // Test origin_x, origin_y values for copyExternalImageToTexture
    var buffer: [4]u8 = undefined;

    // Small values: 1 byte encoding (< 128)
    const len_small = encodeVarint(64, &buffer);
    try testing.expectEqual(@as(u8, 1), len_small);
    try testing.expectEqual(@as(u8, 64), buffer[0]);

    // Boundary at 127: still 1 byte
    const len_127 = encodeVarint(127, &buffer);
    try testing.expectEqual(@as(u8, 1), len_127);

    // At 128: switches to 2 bytes
    const len_128 = encodeVarint(128, &buffer);
    try testing.expectEqual(@as(u8, 2), len_128);

    // Typical texture dimensions (512, 1024, 2048)
    const len_512 = encodeVarint(512, &buffer);
    try testing.expectEqual(@as(u8, 2), len_512);
    const decoded_512 = decodeVarint(buffer[0..len_512]);
    try testing.expectEqual(@as(u32, 512), decoded_512.value);
}

test "all resource creation opcodes valid" {
    // Verify complete coverage of resource creation opcodes
    const resource_ops = [_]OpCode{
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
        .create_image_bitmap, // New opcode
    };

    for (resource_ops) |op| {
        try testing.expect(op.isValid());
    }
}

test "all queue operation opcodes valid" {
    // Verify complete coverage of queue operation opcodes
    const queue_ops = [_]OpCode{
        .write_buffer,
        .write_uniform,
        .copy_buffer_to_buffer,
        .copy_texture_to_texture,
        .submit,
        .copy_external_image_to_texture,
        .init_wasm_module,
        .call_wasm_func,
        .write_buffer_from_wasm,
    };

    for (queue_ops) |op| {
        try testing.expect(op.isValid());
    }
}

// ============================================================================
// WASM Opcode Tests
// ============================================================================

test "init_wasm_module opcode validity" {
    const op = OpCode.init_wasm_module;
    try testing.expectEqual(@as(u8, 0x26), @intFromEnum(op));
    try testing.expect(op.isValid());
}

test "call_wasm_func opcode validity" {
    const op = OpCode.call_wasm_func;
    try testing.expectEqual(@as(u8, 0x27), @intFromEnum(op));
    try testing.expect(op.isValid());
}

test "write_buffer_from_wasm opcode validity" {
    const op = OpCode.write_buffer_from_wasm;
    try testing.expectEqual(@as(u8, 0x28), @intFromEnum(op));
    try testing.expect(op.isValid());
}

test "WASM opcodes in Queue Operations range (0x20-0x2F)" {
    const wasm_ops = [_]OpCode{
        .init_wasm_module,
        .call_wasm_func,
        .write_buffer_from_wasm,
    };

    for (wasm_ops) |op| {
        const code = @intFromEnum(op);
        try testing.expect(code >= 0x20 and code <= 0x2F);
    }
}

test "WasmArgType value byte sizes" {
    // Literal types have 4 bytes of value
    try testing.expectEqual(@as(u8, 4), WasmArgType.literal_f32.valueByteSize());
    try testing.expectEqual(@as(u8, 4), WasmArgType.literal_i32.valueByteSize());
    try testing.expectEqual(@as(u8, 4), WasmArgType.literal_u32.valueByteSize());

    // Runtime types have no value bytes (resolved at execution)
    try testing.expectEqual(@as(u8, 0), WasmArgType.canvas_width.valueByteSize());
    try testing.expectEqual(@as(u8, 0), WasmArgType.canvas_height.valueByteSize());
    try testing.expectEqual(@as(u8, 0), WasmArgType.time_total.valueByteSize());
    try testing.expectEqual(@as(u8, 0), WasmArgType.time_delta.valueByteSize());
}

test "WasmArgType enum values" {
    try testing.expectEqual(@as(u8, 0x00), @intFromEnum(WasmArgType.literal_f32));
    try testing.expectEqual(@as(u8, 0x01), @intFromEnum(WasmArgType.canvas_width));
    try testing.expectEqual(@as(u8, 0x02), @intFromEnum(WasmArgType.canvas_height));
    try testing.expectEqual(@as(u8, 0x03), @intFromEnum(WasmArgType.time_total));
    try testing.expectEqual(@as(u8, 0x06), @intFromEnum(WasmArgType.time_delta));
}

test "WasmReturnType byte sizes" {
    // Scalar types
    try testing.expectEqual(@as(u32, 4), WasmReturnType.byteSize("f32").?);
    try testing.expectEqual(@as(u32, 4), WasmReturnType.byteSize("i32").?);
    try testing.expectEqual(@as(u32, 4), WasmReturnType.byteSize("u32").?);

    // Vector types
    try testing.expectEqual(@as(u32, 8), WasmReturnType.byteSize("vec2").?);
    try testing.expectEqual(@as(u32, 12), WasmReturnType.byteSize("vec3").?);
    try testing.expectEqual(@as(u32, 16), WasmReturnType.byteSize("vec4").?);

    // Matrix types
    try testing.expectEqual(@as(u32, 36), WasmReturnType.byteSize("mat3x3").?);
    try testing.expectEqual(@as(u32, 64), WasmReturnType.byteSize("mat4x4").?);

    // Unknown type returns null
    try testing.expect(WasmReturnType.byteSize("unknown") == null);
}
