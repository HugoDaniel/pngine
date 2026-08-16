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
const WasmArgType = bytecode_mod.opcodes.WasmArgType;
const wire = bytecode_mod.wire_schema;

/// Maximum arguments per WASM function call — the wire schema's cap, read from
/// it rather than re-typed. This constant used to spell `32` by hand, which is
/// how the emitter (no cap at all) and this decoder drifted apart.
const MAX_WASM_ARGS: usize = wire.repMaxOf(.call_wasm_func);

/// Maximum argument buffer size: the count byte plus the widest possible arg
/// encoding (tag + 4 value bytes) for every arg the cap allows.
const ARGS_BUFFER_SIZE: usize = 1 + MAX_WASM_ARGS * 5;

/// Handle WASM operation opcodes.
///
/// The two fixed-shape ops decode via the shared wire schema. call_wasm_func is
/// count-prefixed (a rep group), so it decodes manually — but its per-arg value
/// width comes from `WasmArgType.valueByteSize`, the same source the schema's
/// `wasm_arg` skip uses (no hand-transcribed size table).
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
            const p = try wire.readOperands(wire.layoutOf(.init_wasm_module), self);
            try self.backend.init_wasm_module(allocator, try wire.narrowU16(p.v0), try wire.narrowU16(p.v1));
        },

        .call_wasm_func => {
            const call_id = try self.read_varint();
            const module_id = try self.read_varint();
            const func_name_id = try self.read_varint();
            const arg_count = try self.read_byte();
            // Truncating to the cap would leave the surplus args' bytes in the
            // stream, where the next opcode read finds them: a legal-looking
            // 40-arg call used to decode 32 and then execute 8 arg bytes as
            // opcodes. Refuse the stream instead (journal §319).
            if (arg_count > MAX_WASM_ARGS) return error.RepCountOverCap;

            // Collect encoded args into buffer
            // Format: [arg_count][arg_type, value?]...
            var args_buf: [ARGS_BUFFER_SIZE]u8 = undefined;
            var args_len: usize = 0;
            args_buf[args_len] = arg_count;
            args_len += 1;

            for (0..arg_count) |_| {
                const arg_type = try self.read_byte();
                if (args_len < args_buf.len) {
                    args_buf[args_len] = arg_type;
                    args_len += 1;
                }
                // Value width = the schema's own wasm_arg width (literals 4B,
                // runtime-resolved 0B) — no duplicate size table here.
                const value_size = @as(WasmArgType, @enumFromInt(arg_type)).valueByteSize();
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
                try wire.narrowU16(call_id),
                try wire.narrowU16(module_id),
                try wire.narrowU16(func_name_id),
                args_buf[0..args_len],
            );
        },

        .write_buffer_from_wasm => {
            const p = try wire.readOperands(wire.layoutOf(.write_buffer_from_wasm), self);
            try self.backend.write_buffer_from_wasm(allocator, try wire.narrowU16(p.v0), try wire.narrowU16(p.v1), p.v2, p.v3);
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
