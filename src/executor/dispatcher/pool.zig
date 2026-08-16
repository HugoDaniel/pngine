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
const wire = bytecode_mod.wire_schema;

/// Handle pool operation opcodes.
///
/// Decodes the fixed-shape operands through the shared wire schema, then derives
/// the actual resource ID from `frame_counter` for double-buffering — the effect
/// side the schema does not describe.
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
            const p = try wire.readOperands(wire.layoutOf(.set_vertex_buffer_pool), self);
            if (p.pool_size == 0) return error.InvalidResourceId; // avoid division by zero
            // Actual buffer ID: base + (frame_counter + offset) % pool_size
            const actual_id: u16 = @intCast(p.base_id + (self.frame_counter + p.offset) % p.pool_size);
            try self.backend.set_vertex_buffer(allocator, p.slot, actual_id);
        },

        .set_bind_group_pool => {
            const p = try wire.readOperands(wire.layoutOf(.set_bind_group_pool), self);
            if (p.pool_size == 0) return error.InvalidResourceId; // avoid division by zero
            // Actual bind group ID: base + (frame_counter + offset) % pool_size
            const actual_id: u16 = @intCast(p.base_id + (self.frame_counter + p.offset) % p.pool_size);
            try self.backend.set_bind_group(allocator, p.slot, actual_id);
        },

        .begin_render_pass_pool => {
            const p = try wire.readOperands(wire.layoutOf(.begin_render_pass_pool), self);
            if (p.pool_size == 0) return error.InvalidResourceId; // avoid division by zero
            // Actual texture ID: base + (frame_counter + offset) % pool_size
            const actual_id: u16 = @intCast(p.base_tex_id + (self.frame_counter + p.offset) % p.pool_size);
            try self.backend.begin_render_pass(allocator, actual_id, p.load_op, p.store_op, @intCast(p.depth_tex_id), p.clear_r, p.clear_g, p.clear_b, p.clear_a, 0xFFFF);
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
        .begin_render_pass_pool,
        => true,
        else => false,
    };
}
