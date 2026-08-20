//! Opcode Scanner
//!
//! Unified bytecode scanning for pass definitions and opcode skipping.
//! Eliminates duplication between skip_opcode_params_at and skipOpcodeParams.
//!
//! ## Design
//!
//! - Single OpcodeScanner type works with external pc pointer
//! - Used by scan_pass_definitions for pass range discovery
//! - Used by define_pass handler for skipping during execution
//! - Operand widths come from bytecode/wire_schema.zig (the single source of
//!   truth locked to the emitter), NOT a hand-written per-opcode switch.
//!
//! ## Invariants
//!
//! - pc never exceeds bytecode.len after skip operations
//! - All opcode parameter structures match emitter exactly (via wire_schema)

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const bytecode_mod = @import("bytecode");
const opcodes = bytecode_mod.opcodes;
const wire_schema = bytecode_mod.wire_schema;
const OpCode = opcodes.OpCode;

/// Pass bytecode range (start and end offsets within bytecode).
pub const PassRange = struct {
    start: u32,
    end: u32,
};

/// Maximum iterations for scanning loops.
const MAX_SCAN_ITERATIONS: u32 = 50000;

/// Opcode scanner for pass definition discovery and parameter skipping.
pub const OpcodeScanner = struct {
    const Self = @This();

    bytecode: []const u8,
    pc: u32,

    /// Initialize scanner at given position.
    pub fn init(bytecode: []const u8, start_pc: u32) Self {
        // Pre-conditions
        assert(start_pc <= bytecode.len);

        return .{
            .bytecode = bytecode,
            .pc = start_pc,
        };
    }

    /// Check if scanner has more bytes to read.
    pub fn has_more(self: *const Self) bool {
        return self.pc < self.bytecode.len;
    }

    /// Read current opcode and advance pc.
    pub fn read_opcode(self: *Self) ?OpCode {
        if (self.pc >= self.bytecode.len) return null;
        const op: OpCode = @enumFromInt(self.bytecode[self.pc]);
        self.pc += 1;
        return op;
    }

    /// Skip a single varint parameter. Length-tolerant: a multi-byte lead at
    /// the end of the buffer leaves pc where it is (the caller's bounded loop
    /// ends) instead of asserting on hostile bytecode.
    fn skip_varint(self: *Self) void {
        if (self.pc >= self.bytecode.len) return;
        const result = opcodes.decode_varint_safe(self.bytecode[self.pc..]);
        self.pc += result.len;
    }

    /// Skip a single byte parameter.
    fn skip_byte(self: *Self) void {
        if (self.pc < self.bytecode.len) {
            self.pc += 1;
        }
    }

    /// Skip opcode parameters based on opcode type, delegating to the wire
    /// schema — the single source of truth for operand layouts, locked to the
    /// emitter by the wire-conformance round-trip tests. See
    /// src/bytecode/wire_schema.zig.
    ///
    /// INVARIANT: skip_params must consume exactly the bytes the emitter wrote;
    /// under-counting desyncs the scanner into misreading operand data as
    /// opcodes (the historical copy_external_image_to_texture mip>=0x80 bug).
    pub fn skip_params(self: *Self, op: OpCode) void {
        // Pre-condition: pc is at or before this opcode's operand region.
        assert(self.pc <= self.bytecode.len);

        self.pc = wire_schema.skipParams(self.bytecode, self.pc, op);

        // Post-condition: never advanced past the buffer.
        assert(self.pc <= self.bytecode.len);
    }

    /// Scan bytecode for all pass definitions and return their ranges.
    ///
    /// Fallible by design: a dropped range turns the pass's later `exec_pass`
    /// into a silent no-op — a wrong render that still exits 0. Callers must
    /// handle OOM rather than inherit a half-populated map.
    ///
    /// ACCEPTED RESIDUAL — this scan runs before any frame executes, so on an
    /// over-cap stream it can build wrong ranges from bytes the decoders will
    /// later refuse: `skipParams` clamps a rep group to the schema's cap, and
    /// the surplus operand bytes are then read as opcodes. It stays in bounds
    /// (every `skipKind` clamps) and every opcode it reaches goes through the
    /// same clamped decoders and the latch, so the outcome is a REFUSED frame,
    /// never a mis-executed one. Teaching the scanner to fail is a wider change
    /// than §320 was willing to make, and r2-07 re-accepted it — but as a gate
    /// rather than an argument: "the §320 over-cap mis-scan ends in a refused
    /// frame" in tests/zig/executor/malformed_corpus_test.zig drives a stream
    /// that provably desyncs here and asserts zero GPU calls come out.
    ///
    /// Complexity: O(bytecode.len)
    pub fn scan_pass_definitions(
        bytecode: []const u8,
        allocator: Allocator,
    ) Allocator.Error!std.AutoHashMap(u16, PassRange) {
        // Pre-conditions
        assert(bytecode.len <= 1024 * 1024); // 1MB max

        var pass_ranges = std.AutoHashMap(u16, PassRange).init(allocator);
        errdefer pass_ranges.deinit();
        var scanner = OpcodeScanner.init(bytecode, 0);

        for (0..MAX_SCAN_ITERATIONS) |_| {
            const op = scanner.read_opcode() orelse break;

            if (op == .define_pass) {
                // Read pass_id — length-tolerant, and narrowed: a lead byte at
                // EOF or an id past u16 ends the scan rather than asserting or
                // `@intCast`-trapping on a hostile stream (the stream is a PNG
                // off the network; `pngine inspect` runs it).
                if (scanner.pc >= bytecode.len) break;
                const pass_id_result = opcodes.decode_varint_safe(bytecode[scanner.pc..]);
                if (pass_id_result.len == 0) break;
                scanner.pc += pass_id_result.len;
                const pass_id: u16 = std.math.cast(u16, pass_id_result.value) orelse break;

                // Skip pass_type byte
                scanner.skip_byte();

                // Skip descriptor_data_id
                scanner.skip_varint();

                const pass_start = scanner.pc;

                // Scan for end_pass_def
                for (0..MAX_SCAN_ITERATIONS) |_| {
                    const scan_op = scanner.read_opcode() orelse break;
                    if (scan_op == .end_pass_def) {
                        try pass_ranges.put(pass_id, .{
                            .start = pass_start,
                            .end = scanner.pc - 1,
                        });
                        break;
                    }
                    scanner.skip_params(scan_op);
                }
            } else {
                scanner.skip_params(op);
            }
        }

        // Post-condition: scanner didn't exceed bytecode
        assert(scanner.pc <= bytecode.len);

        return pass_ranges;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const format = bytecode_mod.format;
const Builder = format.Builder;
