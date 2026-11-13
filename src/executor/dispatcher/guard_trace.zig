//! Debug-only guard trace for the REFERENCE dispatcher (frame program §6.3).
//!
//! `pngine inspect --verbose` reports every guard it evaluates: the control,
//! the comparison, the constant and the outcome. That reporting must never
//! reach the browser executor (`src/wasm_entry.zig`), which has no byte budget
//! for it and is not where a developer reads an `inspect` trace. It lives here,
//! beside the one handler that evaluates a guard, behind a compile-time gate
//! and a nullable observer:
//!
//! - `enabled` is `builtin.mode == .Debug`, the same shape as
//!   `wasm_entry.dbg()`'s comptime-gated block: in ReleaseFast/ReleaseSafe the
//!   `if (comptime enabled)` at every call site is pruned before analysis, so
//!   the formatting, the name lookup and this entire module's code drop out.
//! - `observer` is null during normal execution; `pngine inspect` installs one
//!   for the duration of its run and clears it afterwards. Tests that never
//!   install one see the guard exactly as before.
//!
//! No allocation, no formatting here: the observer owns both, so the dispatcher
//! stays a leaf and the hook is one call to a nullable function pointer.

const std = @import("std");
const builtin = @import("builtin");
const opcodes = @import("bytecode").opcodes;

/// True only in a Debug build. Release modes compile every report out.
pub const enabled = builtin.mode == .Debug;

/// One evaluated `exec_if`. `frame` is the dispatcher's `frame_counter` while
/// the body runs (0 for the first frame). `name` points into the module's
/// string table, or the literal `"time"` for slot 0.
pub const Event = struct {
    frame: u32,
    slot: u16,
    name: []const u8,
    comparison: opcodes.ControlComparison,
    constant: f32,
    value: f32,
    holds: bool,
};

/// The current observer, if any. A plain function pointer keeps the dispatcher
/// free of generics and of a context parameter; the CLI's hook reads only the
/// event, and there is never more than one CLI run in a process.
pub var observer: ?*const fn (Event) void = null;

/// Report one evaluated guard. The comptime gate is repeated here so a caller
/// that forgets its own `if (comptime enabled)` still pays nothing in release.
pub inline fn report(event: Event) void {
    if (comptime enabled) {
        if (observer) |observe| observe(event);
    }
}
