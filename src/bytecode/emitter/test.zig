//! Emitter Tests
//!
//! Tests for the bytecode emitter, covering:
//! - Basic opcode emission
//! - Resource creation (buffers, textures, shaders, pipelines)
//! - Pass operations (render, compute)
//! - Queue operations (copy, write)
//! - Data generation (fill patterns, typed arrays)
//! - Pre-allocation and capacity
//!
//! ## Test Categories
//!
//! - Basic emission: single opcode tests
//! - Image operations: createImageBitmap, copyExternalImageToTexture
//! - Pre-allocation: capacity and reallocation tests
//! - Shader concat: multi-source shader composition
//! - Copy operations: buffer-to-buffer, texture-to-texture
//! - Fill operations: linear, element index, random patterns
//! - Data generation sequences: particle system initialization
//! - Random distribution: PRNG uniformity and determinism

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
    const bitmap_id_result = opcodes.decodeVarint(bc[1..]);
    try testing.expectEqual(@as(u32, 200), bitmap_id_result.value);
    try testing.expectEqual(@as(u8, 2), bitmap_id_result.len);

    const blob_id_result = opcodes.decodeVarint(bc[1 + bitmap_id_result.len ..]);
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
    const bitmap_result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 0), bitmap_result.value);
    offset += bitmap_result.len;

    // texture_id
    const texture_result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 1), texture_result.value);
    offset += texture_result.len;

    // mip_level (single byte, not varint)
    try testing.expectEqual(@as(u8, 2), bc[offset]);
    offset += 1;

    // origin_x (128 requires 2 bytes)
    const origin_x_result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 128), origin_x_result.value);
    try testing.expectEqual(@as(u8, 2), origin_x_result.len);
    offset += origin_x_result.len;

    // origin_y (256 requires 2 bytes)
    const origin_y_result = opcodes.decodeVarint(bc[offset..]);
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
    offset += opcodes.decodeVarint(bc[offset..]).len; // texture_id
    offset += opcodes.decodeVarint(bc[offset..]).len; // desc_id
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_image_bitmap)), bc[offset]);

    // Find third opcode
    offset += 1;
    offset += opcodes.decodeVarint(bc[offset..]).len; // bitmap_id
    offset += opcodes.decodeVarint(bc[offset..]).len; // blob_id
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
    var result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 0), result.value); // bitmap_id 0
    offset += result.len;
    result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 0), result.value); // blob_id 0
    offset += result.len;

    // Second instruction
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_image_bitmap)), bc[offset]);
    offset += 1;
    result = opcodes.decodeVarint(bc[offset..]);
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
    const shader_result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 10), shader_result.value);
    offset += shader_result.len;

    // count
    try testing.expectEqual(@as(u8, 4), bc[offset]);
    offset += 1;

    // data_ids
    for (0..4) |i| {
        const data_result = opcodes.decodeVarint(bc[offset..]);
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
    const shader_result = opcodes.decodeVarint(bc[1..]);
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
    var result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 0), result.value);
    offset += result.len;

    // src_offset
    result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 0), result.value);
    offset += result.len;

    // dst_buffer
    result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 1), result.value);
    offset += result.len;

    // dst_offset
    result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 0), result.value);
    offset += result.len;

    // size
    result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 1024), result.value);
}

test "emit copyBufferToBuffer with offsets" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    try emitter.copyBufferToBuffer(testing.allocator, 5, 256, 10, 512, 2048);

    const bc = emitter.bytecode();

    var offset: usize = 1;

    // src_buffer
    var result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 5), result.value);
    offset += result.len;

    // src_offset (256 requires 2 bytes)
    result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 256), result.value);
    offset += result.len;

    // dst_buffer
    result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 10), result.value);
    offset += result.len;

    // dst_offset (512 requires 2 bytes)
    result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 512), result.value);
    offset += result.len;

    // size (2048 requires 2 bytes)
    result = opcodes.decodeVarint(bc[offset..]);
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
        const result = opcodes.decodeVarint(bc[offset..]);
        offset += result.len;
    }

    // size should be decoded correctly
    const size_result = opcodes.decodeVarint(bc[offset..]);
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
    const src_result = opcodes.decodeVarint(bc[1..]);
    try testing.expectEqual(@as(u32, 200), src_result.value);
    try testing.expectEqual(@as(u8, 2), src_result.len);

    const dst_result = opcodes.decodeVarint(bc[1 + src_result.len ..]);
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
        const result = opcodes.decodeVarint(bc[offset..]);
        offset += result.len;
    }

    // Property: second opcode is copy_texture_to_texture
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.copy_texture_to_texture)), bc[offset]);
}

// ============================================================================
// fillLinear Tests
// ============================================================================

test "emit fillLinear basic" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    try emitter.fillLinear(testing.allocator, 0, 0, 100, 1, 10, 11);

    const bc = emitter.bytecode();

    // Property: first byte is the opcode
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.fill_linear)), bc[0]);

    // Decode and verify
    var offset: usize = 1;

    // array_id
    var result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 0), result.value);
    offset += result.len;

    // offset
    result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 0), result.value);
    offset += result.len;

    // count
    result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 100), result.value);
    offset += result.len;

    // stride (single byte)
    try testing.expectEqual(@as(u8, 1), bc[offset]);
    offset += 1;

    // start_data_id
    result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 10), result.value);
    offset += result.len;

    // step_data_id
    result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 11), result.value);
}

test "emit fillLinear with stride" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    // Fill every 4th element (vec4 stride)
    try emitter.fillLinear(testing.allocator, 0, 0, 256, 4, 0, 1);

    const bc = emitter.bytecode();

    // Find stride byte (after array_id, offset, count)
    var offset: usize = 1;
    for (0..3) |_| {
        const result = opcodes.decodeVarint(bc[offset..]);
        offset += result.len;
    }

    // Property: stride is 4
    try testing.expectEqual(@as(u8, 4), bc[offset]);
}

test "emit fillLinear large count" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    // Large count for particle systems
    try emitter.fillLinear(testing.allocator, 0, 0, 100000, 1, 0, 1);

    const bc = emitter.bytecode();

    // Find count varint (after array_id, offset)
    var offset: usize = 1;
    for (0..2) |_| {
        const result = opcodes.decodeVarint(bc[offset..]);
        offset += result.len;
    }

    const count_result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 100000), count_result.value);
    try testing.expectEqual(@as(u8, 4), count_result.len); // 4-byte varint
}

// ============================================================================
// fillElementIndex Tests
// ============================================================================

test "emit fillElementIndex basic" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    try emitter.fillElementIndex(testing.allocator, 0, 0, 100, 1, 10, 11);

    const bc = emitter.bytecode();

    // Property: first byte is the opcode
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.fill_element_index)), bc[0]);

    // Decode and verify
    var offset: usize = 1;

    // array_id
    var result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 0), result.value);
    offset += result.len;

    // offset
    result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 0), result.value);
    offset += result.len;

    // count
    result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 100), result.value);
    offset += result.len;

    // stride (single byte)
    try testing.expectEqual(@as(u8, 1), bc[offset]);
    offset += 1;

    // scale_data_id
    result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 10), result.value);
    offset += result.len;

    // bias_data_id
    result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 11), result.value);
}

test "emit fillElementIndex with stride" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    // Fill x-component of vec3 with index
    try emitter.fillElementIndex(testing.allocator, 0, 0, 256, 3, 0, 1);

    const bc = emitter.bytecode();

    // Find stride byte
    var offset: usize = 1;
    for (0..3) |_| {
        const result = opcodes.decodeVarint(bc[offset..]);
        offset += result.len;
    }

    // Property: stride is 3
    try testing.expectEqual(@as(u8, 3), bc[offset]);
}

test "emit fillElementIndex for instance ID generation" {
    // Common use: fill buffer with 0, 1, 2, 3, ... for instance IDs
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    // scale=1, bias=0 gives pure index values
    try emitter.fillElementIndex(testing.allocator, 0, 0, 1000, 1, 0, 0);

    const bc = emitter.bytecode();

    // Verify opcode
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.fill_element_index)), bc[0]);

    // Verify count
    var offset: usize = 1;
    _ = opcodes.decodeVarint(bc[offset..]); // array_id
    offset += 1;
    _ = opcodes.decodeVarint(bc[offset..]); // offset
    offset += 1;
    const count_result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 1000), count_result.value);
}

// ============================================================================
// Data Generation Sequence Tests
// ============================================================================

test "emit data generation sequence for particles" {
    // Typical particle system init: create array, fill with random positions
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    // Create float32 array for 1000 particles, 3 components each
    try emitter.createTypedArray(testing.allocator, 0, .f32, 3000);

    // Fill x-coordinates with random [0, 1] using seed=42
    try emitter.fillRandom(testing.allocator, 0, 0, 1000, 3, 42, 0, 1);

    // Fill y-coordinates with linear 0 to 1
    try emitter.fillLinear(testing.allocator, 0, 1, 1000, 3, 2, 3);

    // Fill z-coordinates with element index (particle ID)
    try emitter.fillElementIndex(testing.allocator, 0, 2, 1000, 3, 4, 5);

    // Write to GPU buffer
    try emitter.writeBufferFromArray(testing.allocator, 0, 0, 0);

    const bc = emitter.bytecode();

    // Verify sequence of opcodes
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_typed_array)), bc[0]);

    // Find subsequent opcodes
    var offset: usize = 1;
    for (0..3) |_| {
        const result = opcodes.decodeVarint(bc[offset..]);
        offset += result.len;
    }
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.fill_random)), bc[offset]);
}

test "emit fill operations produce consistent encoding" {
    // All fill operations have same parameter structure
    var emitter_linear: Emitter = .empty;
    defer emitter_linear.deinit(testing.allocator);

    var emitter_index: Emitter = .empty;
    defer emitter_index.deinit(testing.allocator);

    // Same parameters except last two (different meanings but same encoding)
    try emitter_linear.fillLinear(testing.allocator, 0, 0, 100, 1, 10, 11);
    try emitter_index.fillElementIndex(testing.allocator, 0, 0, 100, 1, 10, 11);

    const bc_linear = emitter_linear.bytecode();
    const bc_index = emitter_index.bytecode();

    // Property: same length (same parameter encoding)
    try testing.expectEqual(bc_linear.len, bc_index.len);

    // Property: only opcode differs
    try testing.expect(bc_linear[0] != bc_index[0]);
    try testing.expect(std.mem.eql(u8, bc_linear[1..], bc_index[1..]));
}

test "emit fillRandom with seed parameter" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    // fillRandom(array_id, offset, count, stride, seed_data_id, min_data_id, max_data_id)
    try emitter.fillRandom(testing.allocator, 0, 0, 100, 4, 42, 0, 1);

    const bc = emitter.bytecode();

    // Verify opcode
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.fill_random)), bc[0]);

    // Decode all 7 parameters: array_id, offset, count, stride, seed, min, max
    var pos: usize = 1;
    const array_id = opcodes.decodeVarint(bc[pos..]);
    pos += array_id.len;
    try testing.expectEqual(@as(u32, 0), array_id.value);

    const offset_val = opcodes.decodeVarint(bc[pos..]);
    pos += offset_val.len;
    try testing.expectEqual(@as(u32, 0), offset_val.value);

    const count = opcodes.decodeVarint(bc[pos..]);
    pos += count.len;
    try testing.expectEqual(@as(u32, 100), count.value);

    const stride = bc[pos];
    pos += 1;
    try testing.expectEqual(@as(u8, 4), stride);

    const seed = opcodes.decodeVarint(bc[pos..]);
    pos += seed.len;
    try testing.expectEqual(@as(u32, 42), seed.value);

    const min_data_id = opcodes.decodeVarint(bc[pos..]);
    pos += min_data_id.len;
    try testing.expectEqual(@as(u32, 0), min_data_id.value);

    const max_data_id = opcodes.decodeVarint(bc[pos..]);
    pos += max_data_id.len;
    try testing.expectEqual(@as(u32, 1), max_data_id.value);

    // Verify all bytes consumed
    try testing.expectEqual(bc.len, pos);
}

test "emit fillRandom with large seed (2-byte varint)" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    // Use seed value > 127 to force 2-byte varint
    try emitter.fillRandom(testing.allocator, 0, 0, 100, 4, 12345, 0, 1);

    const bc = emitter.bytecode();

    // Skip to seed position
    var pos: usize = 1;
    pos += opcodes.decodeVarint(bc[pos..]).len; // array_id
    pos += opcodes.decodeVarint(bc[pos..]).len; // offset
    pos += opcodes.decodeVarint(bc[pos..]).len; // count
    pos += 1; // stride

    // Decode seed
    const seed = opcodes.decodeVarint(bc[pos..]);
    try testing.expectEqual(@as(u32, 12345), seed.value);
    try testing.expectEqual(@as(usize, 2), seed.len); // 2-byte encoding
}

test "emit fillRandom determinism - same seed produces same encoding" {
    var emitter1: Emitter = .empty;
    defer emitter1.deinit(testing.allocator);
    var emitter2: Emitter = .empty;
    defer emitter2.deinit(testing.allocator);

    // Same parameters including seed
    try emitter1.fillRandom(testing.allocator, 5, 100, 1000, 8, 999, 10, 20);
    try emitter2.fillRandom(testing.allocator, 5, 100, 1000, 8, 999, 10, 20);

    // Property: identical bytecode
    try testing.expect(std.mem.eql(u8, emitter1.bytecode(), emitter2.bytecode()));
}

test "emit fillRandom vs fillLinear - different parameter count" {
    var emitter_random: Emitter = .empty;
    defer emitter_random.deinit(testing.allocator);
    var emitter_linear: Emitter = .empty;
    defer emitter_linear.deinit(testing.allocator);

    // fillRandom has 7 params (including seed)
    try emitter_random.fillRandom(testing.allocator, 0, 0, 100, 4, 42, 0, 1);
    // fillLinear has 6 params (no seed)
    try emitter_linear.fillLinear(testing.allocator, 0, 0, 100, 4, 0, 1);

    // Property: fillRandom should be longer due to extra seed param
    try testing.expect(emitter_random.bytecode().len > emitter_linear.bytecode().len);
}

// ============================================================================
// Random Distribution Tests (using std.Random which is used in fill_random)
// ============================================================================

/// Helper to create seeded PRNG matching fill_random implementation.
fn createSeededPrng(seed: u32) std.Random.DefaultPrng {
    const seed64: u64 = @as(u64, seed) | (@as(u64, seed ^ 0x6D2B79F5) << 32);
    return std.Random.DefaultPrng.init(seed64);
}

test "seeded PRNG: uniform distribution - mean test" {
    // Generate 10000 random floats in [0, 1) and check mean is ~0.5
    var prng = createSeededPrng(12345);
    const random = prng.random();
    var sum: f64 = 0;
    const n: usize = 10000;

    for (0..n) |_| {
        sum += random.float(f32);
    }

    const mean = sum / @as(f64, @floatFromInt(n));
    // Expected mean: 0.5, tolerance: 0.02 (2%)
    try testing.expect(mean > 0.48);
    try testing.expect(mean < 0.52);
}

test "seeded PRNG: uniform distribution - range coverage" {
    // Check that values cover the full [0, 1) range
    var prng = createSeededPrng(42);
    const random = prng.random();
    var min_val: f32 = 1.0;
    var max_val: f32 = 0.0;
    const n: usize = 10000;

    for (0..n) |_| {
        const val = random.float(f32);
        if (val < min_val) min_val = val;
        if (val > max_val) max_val = val;
    }

    // Should cover most of the range
    try testing.expect(min_val < 0.01); // Close to 0
    try testing.expect(max_val > 0.99); // Close to 1
}

test "seeded PRNG: uniform distribution - bucket test (chi-squared proxy)" {
    // Divide [0, 1) into 10 buckets, check each has ~10% of samples
    var prng = createSeededPrng(99999);
    const random = prng.random();
    var buckets = [_]u32{0} ** 10;
    const n: usize = 10000;

    for (0..n) |_| {
        const val = random.float(f32);
        const bucket: usize = @min(9, @as(usize, @intFromFloat(val * 10.0)));
        buckets[bucket] += 1;
    }

    // Each bucket should have ~1000 samples (10%)
    // Allow 20% deviation: 800-1200
    for (buckets) |count| {
        try testing.expect(count >= 800);
        try testing.expect(count <= 1200);
    }
}

test "seeded PRNG: determinism - same seed produces same sequence" {
    var prng1 = createSeededPrng(777);
    var prng2 = createSeededPrng(777);
    const r1 = prng1.random();
    const r2 = prng2.random();

    for (0..100) |_| {
        try testing.expectEqual(r1.int(u32), r2.int(u32));
    }
}

test "seeded PRNG: different seeds produce different sequences" {
    var prng1 = createSeededPrng(111);
    var prng2 = createSeededPrng(222);
    const r1 = prng1.random();
    const r2 = prng2.random();

    var same_count: usize = 0;
    for (0..100) |_| {
        if (r1.int(u32) == r2.int(u32)) same_count += 1;
    }

    // Extremely unlikely to have more than a few matches by chance
    try testing.expect(same_count < 5);
}

test "seeded PRNG: range scaling works correctly" {
    var prng = createSeededPrng(555);
    const random = prng.random();
    const min_range: f32 = -10.0;
    const max_range: f32 = 10.0;
    const range = max_range - min_range;
    const n: usize = 1000;

    for (0..n) |_| {
        const val = min_range + random.float(f32) * range;
        try testing.expect(val >= min_range);
        try testing.expect(val < max_range);
    }
}

test "seeded PRNG: range scaling - mean test" {
    var prng = createSeededPrng(888);
    const random = prng.random();
    var sum: f64 = 0;
    const min_range: f32 = 5.0;
    const max_range: f32 = 15.0;
    const range = max_range - min_range;
    const n: usize = 10000;

    for (0..n) |_| {
        sum += min_range + random.float(f32) * range;
    }

    const mean = sum / @as(f64, @floatFromInt(n));
    // Expected mean: (5 + 15) / 2 = 10, tolerance: 0.2
    try testing.expect(mean > 9.8);
    try testing.expect(mean < 10.2);
}

test "seeded PRNG: variance test" {
    // For uniform [0, 1), variance should be 1/12 ≈ 0.0833
    var prng = createSeededPrng(31337);
    const random = prng.random();
    var sum: f64 = 0;
    var sum_sq: f64 = 0;
    const n: usize = 10000;

    for (0..n) |_| {
        const val: f64 = random.float(f32);
        sum += val;
        sum_sq += val * val;
    }

    const n_f = @as(f64, @floatFromInt(n));
    const mean = sum / n_f;
    const variance = (sum_sq / n_f) - (mean * mean);

    // Expected variance: 1/12 ≈ 0.0833, tolerance: 0.01
    try testing.expect(variance > 0.073);
    try testing.expect(variance < 0.093);
}
