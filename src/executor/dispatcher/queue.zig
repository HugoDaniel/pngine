//! Queue Operations Handler
//!
//! Handles GPU queue operations:
//! - write_buffer, write_uniform, write_time_uniform, write_pointer_uniform
//! - copy_buffer_to_buffer, copy_texture_to_texture, copy_external_image_to_texture
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
const wire = bytecode_mod.wire_schema;

/// Handle queue operation opcodes.
///
/// Decodes operands through the shared wire schema (`wire.readOperands`) then
/// forwards them to the backend — the decode/effect split.
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
            const p = try wire.readOperands(wire.layoutOf(.write_buffer), self);
            try self.backend.write_buffer(allocator, try wire.narrowU16(p.v0), p.v1, try wire.narrowU16(p.v2));
        },

        .write_time_uniform => {
            const p = try wire.readOperands(wire.layoutOf(.write_time_uniform), self);
            try self.backend.write_time_uniform(allocator, try wire.narrowU16(p.v0), p.v1, try wire.narrowU16(p.v2));
        },

        .write_pointer_uniform => {
            const p = try wire.readOperands(wire.layoutOf(.write_pointer_uniform), self);
            try self.backend.write_pointer_uniform(allocator, try wire.narrowU16(p.v0), p.v1, try wire.narrowU16(p.v2));
        },

        .write_audio_data => {
            const p = try wire.readOperands(wire.layoutOf(.write_audio_data), self);
            try self.backend.write_audio_data(allocator, try wire.narrowU16(p.v0), p.v1, try wire.narrowU16(p.v2));
        },

        .copy_external_image_to_texture => {
            const p = try wire.readOperands(wire.layoutOf(.copy_external_image_to_texture), self);
            try self.backend.copy_external_image_to_texture(
                allocator,
                try wire.narrowU16(p.bitmap_id),
                try wire.narrowU16(p.texture_id),
                p.mip_level,
                try wire.narrowU16(p.origin_x),
                try wire.narrowU16(p.origin_y),
                try wire.narrowU16(p.origin_z),
            );
        },

        .copy_buffer_to_buffer => {
            const p = try wire.readOperands(wire.layoutOf(.copy_buffer_to_buffer), self);
            try self.backend.copy_buffer_to_buffer(
                allocator,
                try wire.narrowU16(p.v0),
                p.v1,
                try wire.narrowU16(p.v2),
                p.v3,
                p.v4,
            );
        },

        .copy_texture_to_texture => {
            const p = try wire.readOperands(wire.layoutOf(.copy_texture_to_texture), self);
            try self.backend.copy_texture_to_texture(allocator, try wire.narrowU16(p.v0), try wire.narrowU16(p.v1));
        },

        .write_uniform => {
            const p = try wire.readOperands(wire.layoutOf(.write_uniform), self);
            try self.backend.write_uniform(allocator, try wire.narrowU16(p.v0), try wire.narrowU16(p.v1));
        },

        .resolve_query_set => {
            const p = try wire.readOperands(wire.layoutOf(.resolve_query_set), self);
            try self.backend.resolve_query_set(allocator, try wire.narrowU16(p.v0), p.v1, p.v2, try wire.narrowU16(p.v3), p.v4);
        },

        .submit => {
            // L_NONE: no operands to decode.
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
        .write_pointer_uniform,
        .write_audio_data,
        .copy_external_image_to_texture,
        .copy_buffer_to_buffer,
        .copy_texture_to_texture,
        .write_uniform,
        .resolve_query_set,
        .submit,
        => true,
        else => false,
    };
}
