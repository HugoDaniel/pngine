//! Pool Operations Handler
//!
//! Handles ping-pong buffer pool operations:
//! - set_vertex_buffer_pool
//! - set_bind_group_pool
//!
//! ## Design
//!
//! Pool operations enable double-buffering for compute simulations.
//! The actual resource ID is calculated as:
//!   actual_id = base_id + (frame_counter + offset) % pool_size
//!
//! ## Invariants
//!
//! - pool_size must be > 0
//! - Base resource IDs must reference previously created resources

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const bytecode_mod = @import("bytecode");
const OpCode = bytecode_mod.opcodes.OpCode;

/// Handle pool operation opcodes.
///
/// Returns true if the opcode was handled, false if it should be handled elsewhere.
pub fn handle(
    comptime Self: type,
    self: *Self,
    op: OpCode,
    allocator: Allocator,
) !bool {
    // Pre-condition: valid opcode for this handler
    assert(is_pool_opcode(op));

    switch (op) {
        .set_vertex_buffer_pool => {
            const slot = try self.read_byte();
            const base_buffer_id = try self.read_varint();
            const pool_size = try self.read_byte();
            const offset = try self.read_byte();

            // Pre-condition: pool_size > 0 to avoid division by zero
            if (pool_size == 0) return error.InvalidResourceId;

            // Calculate actual buffer ID: base + (frame_counter + offset) % pool_size
            const actual_id: u16 = @intCast(base_buffer_id + (self.frame_counter + offset) % pool_size);
            try self.backend.set_vertex_buffer(allocator, slot, actual_id);
        },

        .set_bind_group_pool => {
            const slot = try self.read_byte();
            const base_group_id = try self.read_varint();
            const pool_size = try self.read_byte();
            const offset = try self.read_byte();

            // Pre-condition: pool_size > 0 to avoid division by zero
            if (pool_size == 0) return error.InvalidResourceId;

            // Calculate actual bind group ID: base + (frame_counter + offset) % pool_size
            const actual_id: u16 = @intCast(base_group_id + (self.frame_counter + offset) % pool_size);
            try self.backend.set_bind_group(allocator, slot, actual_id);
        },

        else => return false,
    }

    return true;
}

/// Check if opcode is a pool operation opcode.
pub fn is_pool_opcode(op: OpCode) bool {
    return switch (op) {
        .set_vertex_buffer_pool,
        .set_bind_group_pool,
        => true,
        else => false,
    };
}
