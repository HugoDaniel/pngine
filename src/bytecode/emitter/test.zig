//! Emitter Tests
//!
//! Tests for the bytecode emitter, covering:
//! - Basic opcode emission
//! - Resource creation (buffers, textures, shaders, pipelines)
//! - Pass operations (render, compute)
//! - Queue operations (copy, write)
//! - Pre-allocation and capacity
//!
//! ## Test Categories
//!
//! - Basic emission: single opcode tests
//! - Image operations: createImageBitmap, copyExternalImageToTexture
//! - Pre-allocation: capacity and reallocation tests
//! - Shader concat: multi-source shader composition
//! - Copy operations: buffer-to-buffer, texture-to-texture

const std = @import("std");
const testing = std.testing;
const opcodes = @import("../opcodes.zig");
const OpCode = opcodes.OpCode;
const Emitter = @import("../emitter.zig").Emitter;

// ============================================================================
// Basic Emission Tests
// ============================================================================

test "emit create_buffer" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    try emitter.createBuffer(
        testing.allocator,
        0, // buffer_id
        1024, // size
        .{ .uniform = true, .copy_dst = true }, // usage
    );

    const bc = emitter.bytecode();
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_buffer)), bc[0]);
    // buffer_id = 0 (1 byte varint)
    try testing.expectEqual(@as(u8, 0), bc[1]);
    // size = 1024 (2 byte varint: 0x84 0x00)
    // Actually 1024 = 0x400, which is >= 128 so 2 bytes: 0x84 0x00
    try testing.expect(bc.len > 3);
}

test "emit create_shader_module" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    try emitter.createShaderModule(testing.allocator, 0, 5);

    const bc = emitter.bytecode();
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_shader_module)), bc[0]);
}

test "emit draw" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    try emitter.draw(testing.allocator, 3, 1, 0, 0);

    const bc = emitter.bytecode();
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.draw)), bc[0]);
    try testing.expectEqual(@as(u8, 3), bc[1]); // vertex_count = 3
    try testing.expectEqual(@as(u8, 1), bc[2]); // instance_count = 1
    try testing.expectEqual(@as(u8, 0), bc[3]); // first_vertex = 0
    try testing.expectEqual(@as(u8, 0), bc[4]); // first_instance = 0
}

test "emit simple triangle sequence" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    // Emit a simple triangle rendering sequence:
    // 1. Create shader module
    // 2. Create render pipeline
    // 3. Define frame
    // 4. Define pass with render commands
    // 5. End frame

    try emitter.createShaderModule(testing.allocator, 0, 0); // shader $shd:0 from data $d:0
    try emitter.createRenderPipeline(testing.allocator, 0, 1); // pipeline $pipe:0 from descriptor $d:1

    try emitter.defineFrame(testing.allocator, 0, 0); // frame $frm:0 "simpleTriangle"
    try emitter.definePass(testing.allocator, 0, .render, 2); // pass $pass:0 render from descriptor $d:2

    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPass(testing.allocator);

    try emitter.endPassDef(testing.allocator);
    try emitter.execPass(testing.allocator, 0);
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    // Verify we got some bytecode
    try testing.expect(emitter.len() > 10);

    // Verify first opcode is create_shader_module
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_shader_module)), emitter.bytecode()[0]);
}

test "emit submit" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    try emitter.submit(testing.allocator);

    const bc = emitter.bytecode();
    try testing.expectEqual(@as(usize, 1), bc.len);
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.submit)), bc[0]);
}

// ============================================================================
// Image Bitmap Tests (createImageBitmap, copyExternalImageToTexture)
// ============================================================================

test "emit createImageBitmap" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    try emitter.createImageBitmap(testing.allocator, 0, 5);

    const bc = emitter.bytecode();

    // Property: first byte is the opcode
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_image_bitmap)), bc[0]);

    // Property: bitmap_id (0) encoded as 1-byte varint
    try testing.expectEqual(@as(u8, 0), bc[1]);

    // Property: blob_data_id (5) encoded as 1-byte varint
    try testing.expectEqual(@as(u8, 5), bc[2]);

    // Property: total length = opcode(1) + bitmap_id(1) + blob_data_id(1) = 3
    try testing.expectEqual(@as(usize, 3), bc.len);
}

test "emit createImageBitmap with larger IDs" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    // Use IDs that require 2-byte varint encoding (>= 128)
    try emitter.createImageBitmap(testing.allocator, 200, 300);

    const bc = emitter.bytecode();

    // Property: first byte is the opcode
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_image_bitmap)), bc[0]);

    // Property: bytecode should be longer due to 2-byte varints
    // opcode(1) + bitmap_id(2) + blob_data_id(2) = 5 bytes
    try testing.expectEqual(@as(usize, 5), bc.len);

    // Decode and verify values
    const bitmap_id_result = opcodes.decode_varint(bc[1..]);
    try testing.expectEqual(@as(u32, 200), bitmap_id_result.value);
    try testing.expectEqual(@as(u8, 2), bitmap_id_result.len);

    const blob_id_result = opcodes.decode_varint(bc[1 + bitmap_id_result.len ..]);
    try testing.expectEqual(@as(u32, 300), blob_id_result.value);
}

test "emit copyExternalImageToTexture" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    try emitter.copyExternalImageToTexture(testing.allocator, 0, 1, 0, 0, 0);

    const bc = emitter.bytecode();

    // Property: first byte is the opcode
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.copy_external_image_to_texture)), bc[0]);

    // Property: bitmap_id (0) as 1-byte varint
    try testing.expectEqual(@as(u8, 0), bc[1]);

    // Property: texture_id (1) as 1-byte varint
    try testing.expectEqual(@as(u8, 1), bc[2]);

    // Property: mip_level (0) as single byte
    try testing.expectEqual(@as(u8, 0), bc[3]);

    // Property: origin_x (0) as 1-byte varint
    try testing.expectEqual(@as(u8, 0), bc[4]);

    // Property: origin_y (0) as 1-byte varint
    try testing.expectEqual(@as(u8, 0), bc[5]);

    // Property: total length = opcode(1) + bitmap_id(1) + texture_id(1) + mip_level(1) + origin_x(1) + origin_y(1) = 6
    try testing.expectEqual(@as(usize, 6), bc.len);
}

test "emit copyExternalImageToTexture with non-zero origin" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    // Test with origin offset (128, 256) which requires 2-byte varints
    try emitter.copyExternalImageToTexture(testing.allocator, 0, 1, 2, 128, 256);

    const bc = emitter.bytecode();

    // Property: first byte is the opcode
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.copy_external_image_to_texture)), bc[0]);

    // Decode values to verify
    var offset: usize = 1;

    // bitmap_id
    const bitmap_result = opcodes.decode_varint(bc[offset..]);
    try testing.expectEqual(@as(u32, 0), bitmap_result.value);
    offset += bitmap_result.len;

    // texture_id
    const texture_result = opcodes.decode_varint(bc[offset..]);
    try testing.expectEqual(@as(u32, 1), texture_result.value);
    offset += texture_result.len;

    // mip_level (single byte, not varint)
    try testing.expectEqual(@as(u8, 2), bc[offset]);
    offset += 1;

    // origin_x (128 requires 2 bytes)
    const origin_x_result = opcodes.decode_varint(bc[offset..]);
    try testing.expectEqual(@as(u32, 128), origin_x_result.value);
    try testing.expectEqual(@as(u8, 2), origin_x_result.len);
    offset += origin_x_result.len;

    // origin_y (256 requires 2 bytes)
    const origin_y_result = opcodes.decode_varint(bc[offset..]);
    try testing.expectEqual(@as(u32, 256), origin_y_result.value);
}

test "emit copyExternalImageToTexture mip level preserved" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    // Test with mip_level = 5
    try emitter.copyExternalImageToTexture(testing.allocator, 0, 1, 5, 0, 0);

    const bc = emitter.bytecode();

    // mip_level is at offset 3 (after opcode + bitmap_id + texture_id, each 1 byte for small values)
    try testing.expectEqual(@as(u8, 5), bc[3]);
}

test "emit image sequence (create then copy)" {
    // Typical usage: create ImageBitmap then copy to texture
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    // Create texture first
    try emitter.createTexture(testing.allocator, 0, 10); // texture_id=0, desc_id=10

    // Create ImageBitmap from blob
    try emitter.createImageBitmap(testing.allocator, 0, 20); // bitmap_id=0, blob_id=20

    // Copy ImageBitmap to texture
    try emitter.copyExternalImageToTexture(testing.allocator, 0, 0, 0, 0, 0);

    const bc = emitter.bytecode();

    // Property: three opcodes emitted in sequence
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_texture)), bc[0]);

    // Find second opcode (after create_texture params)
    var offset: usize = 1;
    offset += opcodes.decode_varint(bc[offset..]).len; // texture_id
    offset += opcodes.decode_varint(bc[offset..]).len; // desc_id
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_image_bitmap)), bc[offset]);

    // Find third opcode
    offset += 1;
    offset += opcodes.decode_varint(bc[offset..]).len; // bitmap_id
    offset += opcodes.decode_varint(bc[offset..]).len; // blob_id
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.copy_external_image_to_texture)), bc[offset]);
}

test "emit multiple image bitmaps" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    // Create multiple ImageBitmaps (e.g., for sprite atlas textures)
    try emitter.createImageBitmap(testing.allocator, 0, 0);
    try emitter.createImageBitmap(testing.allocator, 1, 1);
    try emitter.createImageBitmap(testing.allocator, 2, 2);

    const bc = emitter.bytecode();

    // Property: all three opcodes are create_image_bitmap
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_image_bitmap)), bc[0]);

    // Decode first instruction
    var offset: usize = 1;
    var result = opcodes.decode_varint(bc[offset..]);
    try testing.expectEqual(@as(u32, 0), result.value); // bitmap_id 0
    offset += result.len;
    result = opcodes.decode_varint(bc[offset..]);
    try testing.expectEqual(@as(u32, 0), result.value); // blob_id 0
    offset += result.len;

    // Second instruction
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_image_bitmap)), bc[offset]);
    offset += 1;
    result = opcodes.decode_varint(bc[offset..]);
    try testing.expectEqual(@as(u32, 1), result.value); // bitmap_id 1
}

// ============================================================================
// Pre-allocation Tests
// ============================================================================

test "initWithCapacity pre-allocates buffer" {
    var emitter = try Emitter.initWithCapacity(testing.allocator, 1024);
    defer emitter.deinit(testing.allocator);

    // Property: capacity is at least what we requested
    try testing.expect(emitter.bytes.capacity >= 1024);

    // Property: length starts at 0
    try testing.expectEqual(@as(usize, 0), emitter.len());
}

test "initDefault uses DEFAULT_CAPACITY" {
    var emitter = try Emitter.initDefault(testing.allocator);
    defer emitter.deinit(testing.allocator);

    // Property: capacity is at least DEFAULT_CAPACITY
    try testing.expect(emitter.bytes.capacity >= Emitter.DEFAULT_CAPACITY);
}

test "pre-allocated emitter avoids reallocation for typical shader" {
    var emitter = try Emitter.initDefault(testing.allocator);
    defer emitter.deinit(testing.allocator);

    const initial_capacity = emitter.bytes.capacity;

    // Emit operations that fit within DEFAULT_CAPACITY (512 bytes)
    // Using simple operations with known signatures
    for (0..20) |i| {
        try emitter.createBuffer(testing.allocator, @intCast(i), 1024, .{ .vertex = true });
        try emitter.createShaderModule(testing.allocator, @intCast(i), @intCast(i));
    }
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPass(testing.allocator);
    try emitter.submit(testing.allocator);

    // Property: no reallocation occurred (capacity unchanged)
    try testing.expectEqual(initial_capacity, emitter.bytes.capacity);

    // Property: bytecode was actually emitted
    try testing.expect(emitter.len() > 0);
    try testing.expect(emitter.len() < Emitter.DEFAULT_CAPACITY);
}

// ============================================================================
// createShaderConcat Tests
// ============================================================================

test "emit createShaderConcat with single data ID" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    const data_ids = [_]u16{5};
    try emitter.createShaderConcat(testing.allocator, 0, &data_ids);

    const bc = emitter.bytecode();

    // Property: first byte is the opcode
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_shader_concat)), bc[0]);

    // Property: shader_id (0) as 1-byte varint
    try testing.expectEqual(@as(u8, 0), bc[1]);

    // Property: count (1) as single byte
    try testing.expectEqual(@as(u8, 1), bc[2]);

    // Property: data_id (5) as 1-byte varint
    try testing.expectEqual(@as(u8, 5), bc[3]);

    // Property: total length = opcode(1) + shader_id(1) + count(1) + data_id(1) = 4
    try testing.expectEqual(@as(usize, 4), bc.len);
}

test "emit createShaderConcat with multiple data IDs" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    const data_ids = [_]u16{ 0, 1, 2, 3 };
    try emitter.createShaderConcat(testing.allocator, 10, &data_ids);

    const bc = emitter.bytecode();

    // Property: first byte is the opcode
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_shader_concat)), bc[0]);

    // Decode and verify
    var offset: usize = 1;

    // shader_id
    const shader_result = opcodes.decode_varint(bc[offset..]);
    try testing.expectEqual(@as(u32, 10), shader_result.value);
    offset += shader_result.len;

    // count
    try testing.expectEqual(@as(u8, 4), bc[offset]);
    offset += 1;

    // data_ids
    for (0..4) |i| {
        const data_result = opcodes.decode_varint(bc[offset..]);
        try testing.expectEqual(@as(u32, @intCast(i)), data_result.value);
        offset += data_result.len;
    }
}

test "emit createShaderConcat with large IDs" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    // Use IDs that require 2-byte varint encoding
    const data_ids = [_]u16{ 200, 300 };
    try emitter.createShaderConcat(testing.allocator, 150, &data_ids);

    const bc = emitter.bytecode();

    // Property: first byte is the opcode
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_shader_concat)), bc[0]);

    // Decode shader_id (150 requires 2 bytes)
    const shader_result = opcodes.decode_varint(bc[1..]);
    try testing.expectEqual(@as(u32, 150), shader_result.value);
    try testing.expectEqual(@as(u8, 2), shader_result.len);
}

// ============================================================================
// copyBufferToBuffer Tests
// ============================================================================

test "emit copyBufferToBuffer basic" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    try emitter.copyBufferToBuffer(testing.allocator, 0, 0, 1, 0, 1024);

    const bc = emitter.bytecode();

    // Property: first byte is the opcode
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.copy_buffer_to_buffer)), bc[0]);

    // Decode and verify all parameters
    var offset: usize = 1;

    // src_buffer
    var result = opcodes.decode_varint(bc[offset..]);
    try testing.expectEqual(@as(u32, 0), result.value);
    offset += result.len;

    // src_offset
    result = opcodes.decode_varint(bc[offset..]);
    try testing.expectEqual(@as(u32, 0), result.value);
    offset += result.len;

    // dst_buffer
    result = opcodes.decode_varint(bc[offset..]);
    try testing.expectEqual(@as(u32, 1), result.value);
    offset += result.len;

    // dst_offset
    result = opcodes.decode_varint(bc[offset..]);
    try testing.expectEqual(@as(u32, 0), result.value);
    offset += result.len;

    // size
    result = opcodes.decode_varint(bc[offset..]);
    try testing.expectEqual(@as(u32, 1024), result.value);
}

test "emit copyBufferToBuffer with offsets" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    try emitter.copyBufferToBuffer(testing.allocator, 5, 256, 10, 512, 2048);

    const bc = emitter.bytecode();

    var offset: usize = 1;

    // src_buffer
    var result = opcodes.decode_varint(bc[offset..]);
    try testing.expectEqual(@as(u32, 5), result.value);
    offset += result.len;

    // src_offset (256 requires 2 bytes)
    result = opcodes.decode_varint(bc[offset..]);
    try testing.expectEqual(@as(u32, 256), result.value);
    offset += result.len;

    // dst_buffer
    result = opcodes.decode_varint(bc[offset..]);
    try testing.expectEqual(@as(u32, 10), result.value);
    offset += result.len;

    // dst_offset (512 requires 2 bytes)
    result = opcodes.decode_varint(bc[offset..]);
    try testing.expectEqual(@as(u32, 512), result.value);
    offset += result.len;

    // size (2048 requires 2 bytes)
    result = opcodes.decode_varint(bc[offset..]);
    try testing.expectEqual(@as(u32, 2048), result.value);
}

test "emit copyBufferToBuffer large size" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    // Test with large size that requires 4-byte varint
    try emitter.copyBufferToBuffer(testing.allocator, 0, 0, 1, 0, 1000000);

    const bc = emitter.bytecode();

    // Find size parameter (last one)
    var offset: usize = 1;
    for (0..4) |_| {
        const result = opcodes.decode_varint(bc[offset..]);
        offset += result.len;
    }

    // size should be decoded correctly
    const size_result = opcodes.decode_varint(bc[offset..]);
    try testing.expectEqual(@as(u32, 1000000), size_result.value);
    try testing.expectEqual(@as(u8, 4), size_result.len); // 4-byte varint
}

// ============================================================================
// copyTextureToTexture Tests
// ============================================================================

test "emit copyTextureToTexture basic" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    try emitter.copyTextureToTexture(testing.allocator, 0, 1);

    const bc = emitter.bytecode();

    // Property: first byte is the opcode
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.copy_texture_to_texture)), bc[0]);

    // Property: src_texture (0) as 1-byte varint
    try testing.expectEqual(@as(u8, 0), bc[1]);

    // Property: dst_texture (1) as 1-byte varint
    try testing.expectEqual(@as(u8, 1), bc[2]);

    // Property: total length = opcode(1) + src(1) + dst(1) = 3
    try testing.expectEqual(@as(usize, 3), bc.len);
}

test "emit copyTextureToTexture with large IDs" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    try emitter.copyTextureToTexture(testing.allocator, 200, 300);

    const bc = emitter.bytecode();

    // Property: first byte is the opcode
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.copy_texture_to_texture)), bc[0]);

    // Decode and verify
    const src_result = opcodes.decode_varint(bc[1..]);
    try testing.expectEqual(@as(u32, 200), src_result.value);
    try testing.expectEqual(@as(u8, 2), src_result.len);

    const dst_result = opcodes.decode_varint(bc[1 + src_result.len ..]);
    try testing.expectEqual(@as(u32, 300), dst_result.value);
    try testing.expectEqual(@as(u8, 2), dst_result.len);
}

test "emit copy sequence (buffer to buffer, texture to texture)" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    // Emit both copy operations
    try emitter.copyBufferToBuffer(testing.allocator, 0, 0, 1, 0, 512);
    try emitter.copyTextureToTexture(testing.allocator, 0, 1);

    const bc = emitter.bytecode();

    // Property: first opcode is copy_buffer_to_buffer
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.copy_buffer_to_buffer)), bc[0]);

    // Find second opcode
    var offset: usize = 1;
    for (0..5) |_| {
        const result = opcodes.decode_varint(bc[offset..]);
        offset += result.len;
    }

    // Property: second opcode is copy_texture_to_texture
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.copy_texture_to_texture)), bc[offset]);
}
