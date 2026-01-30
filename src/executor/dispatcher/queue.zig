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
    assert(isQueueOpcode(op));

    switch (op) {
        .write_buffer => {
            const buffer_id = try self.readVarint();
            const offset = try self.readVarint();
            const data_id = try self.readVarint();
            try self.backend.write_buffer(allocator, @intCast(buffer_id), offset, @intCast(data_id));
        },

        .write_time_uniform => {
            const buffer_id = try self.readVarint();
            const buffer_offset = try self.readVarint();
            const size = try self.readVarint();
            try self.backend.write_time_uniform(allocator, @intCast(buffer_id), buffer_offset, @intCast(size));
        },

        .copy_external_image_to_texture => {
            const bitmap_id = try self.readVarint();
            const texture_id = try self.readVarint();
            const mip_level = try self.readByte();
            const origin_x = try self.readVarint();
            const origin_y = try self.readVarint();
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
pub fn isQueueOpcode(op: OpCode) bool {
    return switch (op) {
        .write_buffer,
        .write_time_uniform,
        .copy_external_image_to_texture,
        .submit,
        => true,
        else => false,
    };
}
