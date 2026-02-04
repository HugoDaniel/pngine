//! Queue Operations Handler
//!
//! Handles GPU queue operations:
//! - write_buffer, write_time_uniform
//! - copy_external_image_to_texture
//! - submit
//!
//! ## Invariants
//!
//! - Buffer IDs must reference previously created buffers
//! - Data IDs must reference valid data section entries

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const bytecode_mod = @import("bytecode");
const OpCode = bytecode_mod.opcodes.OpCode;

/// Handle queue operation opcodes.
///
/// Returns true if the opcode was handled, false if it should be handled elsewhere.
pub fn handle(
    comptime Self: type,
    self: *Self,
    op: OpCode,
    allocator: Allocator,
) !bool {
    // Pre-condition: valid opcode for this handler
    assert(is_queue_opcode(op));

    switch (op) {
        .write_buffer => {
            const buffer_id = try self.read_varint();
            const offset = try self.read_varint();
            const data_id = try self.read_varint();
            try self.backend.write_buffer(allocator, @intCast(buffer_id), offset, @intCast(data_id));
        },

        .write_time_uniform => {
            const buffer_id = try self.read_varint();
            const buffer_offset = try self.read_varint();
            const size = try self.read_varint();
            try self.backend.write_time_uniform(allocator, @intCast(buffer_id), buffer_offset, @intCast(size));
        },

        .copy_external_image_to_texture => {
            const bitmap_id = try self.read_varint();
            const texture_id = try self.read_varint();
            const mip_level = try self.read_byte();
            const origin_x = try self.read_varint();
            const origin_y = try self.read_varint();
            try self.backend.copy_external_image_to_texture(
                allocator,
                @intCast(bitmap_id),
                @intCast(texture_id),
                mip_level,
                @intCast(origin_x),
                @intCast(origin_y),
            );
        },

        .submit => {
            try self.backend.submit(allocator);
        },

        else => return false,
    }

    return true;
}

/// Check if opcode is a queue operation opcode.
pub fn is_queue_opcode(op: OpCode) bool {
    return switch (op) {
        .write_buffer,
        .write_time_uniform,
        .copy_external_image_to_texture,
        .submit,
        => true,
        else => false,
    };
}
