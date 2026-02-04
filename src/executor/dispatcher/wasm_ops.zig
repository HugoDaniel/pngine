//! WASM Operations Handler
//!
//! Handles nested WASM module operations:
//! - init_wasm_module
//! - call_wasm_func
//! - write_buffer_from_wasm
//!
//! ## Design
//!
//! These opcodes support running embedded WASM modules within payloads.
//! The WASM modules can generate data or perform computations.
//!
//! ## Invariants
//!
//! - Module IDs must be unique
//! - Function names must be valid strings in the string table
//! - Call IDs are used to correlate call results with buffer writes

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const bytecode_mod = @import("bytecode");
const OpCode = bytecode_mod.opcodes.OpCode;

/// Maximum arguments per WASM function call.
const MAX_WASM_ARGS: usize = 32;

/// Maximum argument buffer size.
const ARGS_BUFFER_SIZE: usize = 256;

/// Handle WASM operation opcodes.
///
/// Returns true if the opcode was handled, false if it should be handled elsewhere.
pub fn handle(
    comptime Self: type,
    self: *Self,
    op: OpCode,
    allocator: Allocator,
) !bool {
    // Pre-condition: valid opcode for this handler
    assert(is_wasm_opcode(op));

    switch (op) {
        .init_wasm_module => {
            const module_id = try self.read_varint();
            const wasm_data_id = try self.read_varint();
            try self.backend.init_wasm_module(allocator, @intCast(module_id), @intCast(wasm_data_id));
        },

        .call_wasm_func => {
            const call_id = try self.read_varint();
            const module_id = try self.read_varint();
            const func_name_id = try self.read_varint();
            const arg_count = try self.read_byte();

            // Collect encoded args into buffer
            // Format: [arg_count][arg_type, value?]...
            var args_buf: [ARGS_BUFFER_SIZE]u8 = undefined;
            var args_len: usize = 0;
            args_buf[args_len] = arg_count;
            args_len += 1;

            for (0..@min(arg_count, MAX_WASM_ARGS)) |_| {
                const arg_type = try self.read_byte();
                if (args_len < args_buf.len) {
                    args_buf[args_len] = arg_type;
                    args_len += 1;
                }
                // Read value bytes based on arg type
                const value_size: u8 = switch (arg_type) {
                    0x00, 0x04, 0x05 => 4, // literal f32/i32/u32
                    else => 0, // runtime resolved
                };
                for (0..value_size) |_| {
                    const byte = try self.read_byte();
                    if (args_len < args_buf.len) {
                        args_buf[args_len] = byte;
                        args_len += 1;
                    }
                }
            }

            try self.backend.call_wasm_func(
                allocator,
                @intCast(call_id),
                @intCast(module_id),
                @intCast(func_name_id),
                args_buf[0..args_len],
            );
        },

        .write_buffer_from_wasm => {
            const call_id = try self.read_varint();
            const buffer_id = try self.read_varint();
            const offset = try self.read_varint();
            const byte_len = try self.read_varint();
            try self.backend.write_buffer_from_wasm(
                allocator,
                @intCast(call_id),
                @intCast(buffer_id),
                offset,
                byte_len,
            );
        },

        else => return false,
    }

    return true;
}

/// Check if opcode is a WASM operation opcode.
pub fn is_wasm_opcode(op: OpCode) bool {
    return switch (op) {
        .init_wasm_module,
        .call_wasm_func,
        .write_buffer_from_wasm,
        => true,
        else => false,
    };
}
