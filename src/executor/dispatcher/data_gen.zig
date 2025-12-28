//! Data Generation Handler
//!
//! Handles data generation opcodes:
//! - create_typed_array
//! - fill_constant, fill_random, fill_linear, fill_element_index, fill_expression
//! - write_buffer_from_array
//!
//! ## Invariants
//!
//! - Array IDs must be unique
//! - Fill operations must target previously created arrays

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const bytecode_mod = @import("bytecode");
const OpCode = bytecode_mod.opcodes.OpCode;

/// Handle data generation opcodes.
///
/// Returns true if the opcode was handled, false if it should be handled elsewhere.
pub fn handle(
    comptime Self: type,
    self: *Self,
    op: OpCode,
    allocator: Allocator,
) !bool {
    // Pre-condition: valid opcode for this handler
    assert(isDataGenOpcode(op));

    switch (op) {
        .create_typed_array => {
            const array_id = try self.readVarint();
            const element_type = try self.readByte();
            const element_count = try self.readVarint();
            try self.backend.createTypedArray(allocator, @intCast(array_id), element_type, element_count);
        },

        .fill_constant => {
            const array_id = try self.readVarint();
            const offset = try self.readVarint();
            const count = try self.readVarint();
            const stride = try self.readByte();
            const value_data_id = try self.readVarint();
            try self.backend.fillConstant(
                allocator,
                @intCast(array_id),
                offset,
                count,
                stride,
                @intCast(value_data_id),
            );
        },

        .fill_random => {
            const array_id = try self.readVarint();
            const offset = try self.readVarint();
            const count = try self.readVarint();
            const stride = try self.readByte();
            const seed_data_id = try self.readVarint();
            const min_data_id = try self.readVarint();
            const max_data_id = try self.readVarint();
            try self.backend.fillRandom(
                allocator,
                @intCast(array_id),
                offset,
                count,
                stride,
                @intCast(seed_data_id),
                @intCast(min_data_id),
                @intCast(max_data_id),
            );
        },

        .fill_linear, .fill_element_index => {
            // Skip for now - not used by boids
            _ = try self.readVarint(); // array_id
            _ = try self.readVarint(); // offset
            _ = try self.readVarint(); // count
            _ = try self.readByte(); // stride
            _ = try self.readVarint(); // start/scale
            _ = try self.readVarint(); // step/bias
        },

        .fill_expression => {
            const array_id = try self.readVarint();
            const offset = try self.readVarint();
            const count = try self.readVarint();
            const stride = try self.readByte();
            const expr_data_id = try self.readVarint();
            // count is used as total_count for NUM_PARTICLES substitution
            try self.backend.fillExpression(
                allocator,
                @intCast(array_id),
                offset,
                count,
                stride,
                count,
                @intCast(expr_data_id),
            );
        },

        .write_buffer_from_array => {
            const buffer_id = try self.readVarint();
            const buffer_offset = try self.readVarint();
            const array_id = try self.readVarint();
            try self.backend.writeBufferFromArray(
                allocator,
                @intCast(buffer_id),
                buffer_offset,
                @intCast(array_id),
            );
        },

        else => return false,
    }

    return true;
}

/// Check if opcode is a data generation opcode.
pub fn isDataGenOpcode(op: OpCode) bool {
    return switch (op) {
        .create_typed_array,
        .fill_constant,
        .fill_random,
        .fill_linear,
        .fill_element_index,
        .fill_expression,
        .write_buffer_from_array,
        => true,
        else => false,
    };
}
