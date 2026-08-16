//! Frame Control Handler
//!
//! Handles frame control and pass definition opcodes:
//! - define_frame, end_frame
//! - define_pass, end_pass_def, exec_pass
//!
//! ## Design
//!
//! Frame control opcodes are structural and don't generate GPU calls directly.
//! They manage the execution flow and pass definitions.
//!
//! Unlike the other handlers, these read operands INLINE rather than through
//! `wire_schema.readOperands`: they discard most operands (define_frame keeps
//! neither id; define_pass keeps only pass_id) and their "effect" is control
//! flow — frame counting, pass-range scanning via OpcodeScanner, deferred
//! exec_pass — not a backend call. The decode/effect split doesn't apply, so
//! there is no typed operand struct to build. The wire schema still governs
//! the widths the inline reads consume (define_pass's scan delegates to it).
//!
//! ## Invariants
//!
//! - define_frame must be followed by end_frame
//! - define_pass must be followed by end_pass_def
//! - exec_pass must reference a previously defined pass

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const bytecode_mod = @import("bytecode");
const opcodes = bytecode_mod.opcodes;
const OpCode = opcodes.OpCode;
const wire = bytecode_mod.wire_schema;

const scanner_mod = @import("scanner.zig");
const OpcodeScanner = scanner_mod.OpcodeScanner;

/// Maximum iterations for pass execution loop.
const PASS_MAX_ITERATIONS: u32 = 1000;

/// Maximum iterations for scanning within define_pass.
const SCAN_MAX_ITERATIONS: u32 = 10000;

/// Maximum nesting depth of executePass. Passes legitimately nest (a frame runs
/// several passes, and a pass body may exec_pass another), but a cyclic
/// exec_pass — a pass that runs itself directly or through a cycle — recurses
/// without bound and overflows the stack. This cap turns that into a clean
/// error. Real documents nest only a handful deep. (Arc-3 §2.2b)
const PASS_MAX_DEPTH: u32 = 64;

/// Handle frame control opcodes.
///
/// Returns true if the opcode was handled, false if it should be handled elsewhere.
pub fn handle(
    comptime Self: type,
    self: *Self,
    op: OpCode,
    allocator: Allocator,
) !bool {
    // Pre-condition: valid opcode for this handler
    assert(is_frame_opcode(op));

    switch (op) {
        .define_frame => {
            _ = try self.read_varint(); // frame_id
            _ = try self.read_varint(); // name_string_id
            self.in_frame_def = true;
        },

        .end_frame => {
            self.in_frame_def = false;
            self.frame_counter += 1;
        },

        .exec_pass => {
            const pass_id: u16 = try wire.narrowU16(try self.read_varint());
            try executePass(Self, self, pass_id, allocator);
        },

        .exec_pass_once => {
            const pass_id: u16 = try wire.narrowU16(try self.read_varint());
            // Only execute if not already executed
            if (self.executed_once.get(pass_id) == null) {
                try executePass(Self, self, pass_id, allocator);
                try self.executed_once.put(pass_id, {});
            }
        },

        .define_pass => {
            const pass_id: u16 = try wire.narrowU16(try self.read_varint());
            _ = try self.read_byte(); // pass_type
            _ = try self.read_varint(); // descriptor_data_id

            // Record pass start position
            const pass_start = self.pc;

            // Skip ahead to find end_pass_def - don't execute pass body during definition
            try scanToEndPassDef(Self, self, pass_id, pass_start);
        },

        .end_pass_def => {
            // Should not be reached - handled by define_pass scanning
        },

        else => return false,
    }

    return true;
}

/// Execute a pass by its ID using the pass_ranges map.
fn executePass(
    comptime Self: type,
    self: *Self,
    pass_id: u16,
    allocator: Allocator,
) !void {
    // Pre-condition: pass must exist in pass_ranges
    const range = self.pass_ranges.get(pass_id) orelse return;

    // Guard against a cyclic exec_pass (a pass body that runs itself). The
    // per-pass loop below is bounded, but the recursion through step is not.
    if (self.pass_exec_depth >= PASS_MAX_DEPTH) return error.PassRecursionTooDeep;
    self.pass_exec_depth += 1;
    defer self.pass_exec_depth -= 1;

    // Debug logging for WASM builds
    if (@import("builtin").target.cpu.arch == .wasm32) {
        const debug_log = @import("debug_log.zig");
        debug_log.gpuDebugLog(10, pass_id);
        debug_log.gpuDebugLog(11, @intCast(range.start));
        debug_log.gpuDebugLog(12, @intCast(range.end));
    }

    // Save/restore the PC around the nested execution via defer: a step inside
    // the pass body can fail (e.g. PassRecursionTooDeep unwinding a cyclic
    // exec_pass), and restoring on error too keeps step()'s monotonic-pc
    // post-condition intact all the way up the stack. (Arc-3 §2.2b)
    const saved_pc = self.pc;
    defer self.pc = saved_pc;

    // Execute pass bytecode
    self.pc = range.start;
    for (0..PASS_MAX_ITERATIONS) |_| {
        if (self.pc >= range.end) break;
        try self.step(allocator);
    }
}

/// Scan from current position to end_pass_def and record the pass range.
fn scanToEndPassDef(
    comptime Self: type,
    self: *Self,
    pass_id: u16,
    pass_start: u32,
) !void {
    const bytecode = self.module.bytecode;
    var scanner = OpcodeScanner.init(bytecode, self.pc);

    for (0..SCAN_MAX_ITERATIONS) |_| {
        const scan_op = scanner.read_opcode() orelse break;

        if (scan_op == .end_pass_def) {
            // Store the pass range (excluding end_pass_def).
            //
            // Dev/reference path: `pass_ranges` is an UNBOUNDED heap map, so this
            // interpreter (native `--frame`, MockGPU tests) executes any number
            // of passes. The shipping browser executor (wasm_entry.zig) instead
            // keeps a FIXED table of bytecode.DEFAULT_MAX_PASSES entries and
            // silently drops passes beyond it — the item-1.5 divergence. The
            // frontend rejects over-cap documents up front (Emitter.allocPassId),
            // so a compiled PNG never reaches that drop; this map stays unbounded
            // deliberately (dev tooling analyses arbitrary bytecode).
            //
            // OOM propagates rather than being swallowed: a dropped range makes
            // the pass's later exec_pass a silent no-op, i.e. a wrong render with
            // a zero exit code. Failing the execution is the honest outcome.
            try self.pass_ranges.put(pass_id, .{
                .start = pass_start,
                .end = scanner.pc - 1,
            });
            break;
        }

        scanner.skip_params(scan_op);
    }

    // Update dispatcher's pc to match scanner
    self.pc = scanner.pc;
}

/// Check if opcode is a frame control opcode.
pub fn is_frame_opcode(op: OpCode) bool {
    return switch (op) {
        .define_frame,
        .end_frame,
        .define_pass,
        .end_pass_def,
        .exec_pass,
        .exec_pass_once,
        => true,
        else => false,
    };
}
