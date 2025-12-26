//! PNGB Opcode Definitions and Varint Encoding
//!
//! Re-exports type definitions from types/opcodes.zig and provides
//! varint encoding utilities for bytecode serialization.
//!
//! For type definitions only, import types/opcodes.zig directly.

const std = @import("std");
const assert = std.debug.assert;

// Re-export all types from the types module
const types = @import("../types/opcodes.zig");
pub const OpCode = types.OpCode;
pub const BufferUsage = types.BufferUsage;
pub const LoadOp = types.LoadOp;
pub const StoreOp = types.StoreOp;
pub const PassType = types.PassType;
pub const ElementType = types.ElementType;
pub const WasmArgType = types.WasmArgType;
pub const WasmReturnType = types.WasmReturnType;

// ============================================================================
// Variable-Length Integer Encoding (LEB128-style)
// ============================================================================

/// Encode a varint to buffer.
///
/// Returns number of bytes written (1, 2, or 4).
///
/// Encoding scheme (LEB128-style with 2/4 byte alignment):
/// - 0-127: 0xxxxxxx (1 byte, values 0x00-0x7F)
/// - 128-16383: 10xxxxxx xxxxxxxx (2 bytes, big-endian payload)
/// - 16384+: 11xxxxxx xxxxxxxx xxxxxxxx xxxxxxxx (4 bytes, big-endian payload)
///
/// Complexity: O(1).
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
///
/// Returns value and number of bytes consumed (1, 2, or 4).
/// Pre-condition: buffer.len >= 1 (at minimum).
/// Pre-condition: buffer.len >= encoded length (asserted at runtime).
///
/// Complexity: O(1).
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
        .create_image_bitmap,
        .create_texture_view,
        .create_query_set,
        .create_render_bundle,
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

test "WasmArgType encoding: all runtime types have zero bytes" {
    // Property: all runtime types should have zero additional value bytes
    // because they're resolved at execution time
    const runtime_types = [_]WasmArgType{
        .canvas_width,
        .canvas_height,
        .time_total,
        .time_delta,
    };

    for (runtime_types) |arg_type| {
        try testing.expectEqual(@as(u8, 0), arg_type.valueByteSize());
    }
}

test "WasmArgType encoding: all literal types have 4 bytes" {
    // Property: all literal types encode 4-byte values
    const literal_types = [_]WasmArgType{
        .literal_f32,
        .literal_i32,
        .literal_u32,
    };

    for (literal_types) |arg_type| {
        try testing.expectEqual(@as(u8, 4), arg_type.valueByteSize());
    }
}

test "WasmArgType encoding: calculate total args buffer size" {
    // Test calculating the total buffer size needed for a list of args
    // Format: [arg_count:u8] + for each arg: [type:u8][value:0-4]

    // Test case 1: 2 runtime args (canvas_width, canvas_height)
    // = 1 (count) + 2 * (1 type + 0 value) = 3 bytes
    {
        const args = [_]WasmArgType{ .canvas_width, .canvas_height };
        var total: usize = 1; // arg count
        for (args) |arg| {
            total += 1 + arg.valueByteSize();
        }
        try testing.expectEqual(@as(usize, 3), total);
    }

    // Test case 2: 2 literal args (literal_f32 x 2)
    // = 1 (count) + 2 * (1 type + 4 value) = 11 bytes
    {
        const args = [_]WasmArgType{ .literal_f32, .literal_f32 };
        var total: usize = 1;
        for (args) |arg| {
            total += 1 + arg.valueByteSize();
        }
        try testing.expectEqual(@as(usize, 11), total);
    }

    // Test case 3: mixed args (runtime, literal, runtime)
    // = 1 (count) + (1+0) + (1+4) + (1+0) = 8 bytes
    {
        const args = [_]WasmArgType{ .canvas_width, .literal_f32, .time_total };
        var total: usize = 1;
        for (args) |arg| {
            total += 1 + arg.valueByteSize();
        }
        try testing.expectEqual(@as(usize, 8), total);
    }
}

test "WasmArgType encoding: decode arg stream" {
    // Simulate decoding an encoded arg stream
    // Format: [arg_count:u8][type:u8][value?]...

    // Encoded: 3 args - canvas_width, literal_f32(1.0), time_total
    const encoded = [_]u8{
        3, // arg count
        0x01, // canvas_width (0 value bytes)
        0x00, 0x00, 0x00, 0x80, 0x3F, // literal_f32 + 1.0f
        0x03, // time_total (0 value bytes)
    };

    var pos: usize = 0;
    const arg_count = encoded[pos];
    pos += 1;
    try testing.expectEqual(@as(u8, 3), arg_count);

    // Decode arg 0: canvas_width
    const arg0_type: WasmArgType = @enumFromInt(encoded[pos]);
    pos += 1;
    try testing.expectEqual(WasmArgType.canvas_width, arg0_type);
    pos += arg0_type.valueByteSize();

    // Decode arg 1: literal_f32
    const arg1_type: WasmArgType = @enumFromInt(encoded[pos]);
    pos += 1;
    try testing.expectEqual(WasmArgType.literal_f32, arg1_type);
    const value_bytes = encoded[pos..][0..4];
    const f32_value: f32 = @bitCast(std.mem.readInt(u32, value_bytes, .little));
    try testing.expectApproxEqAbs(@as(f32, 1.0), f32_value, 0.001);
    pos += arg1_type.valueByteSize();

    // Decode arg 2: time_total
    const arg2_type: WasmArgType = @enumFromInt(encoded[pos]);
    pos += 1;
    try testing.expectEqual(WasmArgType.time_total, arg2_type);
    pos += arg2_type.valueByteSize();

    // Property: consumed entire buffer
    try testing.expectEqual(encoded.len, pos);
}

test "WasmArgType encoding: empty args" {
    // Encoded: 0 args
    const encoded = [_]u8{0}; // just arg count

    const arg_count = encoded[0];
    try testing.expectEqual(@as(u8, 0), arg_count);
}
