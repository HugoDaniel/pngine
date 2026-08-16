//! Shared argument-reader for the CLI subcommands.
//!
//! ## Design
//! Every subcommand hand-rolled the same option loop: a `for (0..len)` with a
//! `skip_next`/`skip_count` cursor, an `if (i + 1 >= len) { print; return }`
//! guard repeated at every value-taking flag, a duplicate-input `if (x != null)`
//! block, and an unknown-`-x` catch-all. `ArgReader` owns exactly that plumbing
//! — cursor advance, value lookahead, single-positional capture — and nothing
//! else. Flag *matching* stays in each command (each keeps its own options
//! struct); only the mechanics are shared.
//!
//! ## Invariants
//! - Pure: no stderr. Methods return typed errors; the caller renders them via
//!   the `missingValue` / `duplicateInput` / `unknownOption` helpers below so
//!   the messages stay uniform across commands.
//! - Bounded: `init` asserts `args.len <= max_args`; `next()` advances one slot
//!   per call, so any `while (reader.next())` loop runs at most `max_args` times.

const std = @import("std");

/// Upper bound on argv length (matches the existing per-command asserts).
pub const max_args: u32 = 1024;

pub const ArgReader = struct {
    args: []const []const u8,
    index: u32 = 0,
    /// First positional captured via `addPositional` (the single-input case).
    positional: ?[]const u8 = null,

    pub const Error = error{
        MissingValue,
        DuplicatePositional,
    };

    /// Pre-condition: args length is bounded (keeps every consuming loop bounded).
    pub fn init(args: []const []const u8) ArgReader {
        std.debug.assert(args.len <= max_args);
        return .{ .args = args };
    }

    /// Advance and return the next raw argument, or null at end.
    /// Post-condition: index never exceeds args.len.
    pub fn next(self: *ArgReader) ?[]const u8 {
        std.debug.assert(self.index <= self.args.len);
        if (self.index >= self.args.len) return null;
        const arg = self.args[self.index];
        self.index += 1;
        return arg;
    }

    /// Consume the value that must follow the current flag. Matches the legacy
    /// `if (i + 1 >= len)` guard: takes the next token unconditionally (even a
    /// flag-shaped one), erroring only when the argument list is exhausted.
    pub fn value(self: *ArgReader) Error![]const u8 {
        std.debug.assert(self.index <= self.args.len);
        if (self.index >= self.args.len) return error.MissingValue;
        const v = self.args[self.index];
        self.index += 1;
        return v;
    }

    /// Record the sole positional argument, rejecting a second one.
    pub fn addPositional(self: *ArgReader, arg: []const u8) Error!void {
        if (self.positional != null) return error.DuplicatePositional;
        self.positional = arg;
    }

    /// True if `arg` looks like an option (leading '-', and more than that).
    ///
    /// A bare `-` is deliberately NOT a flag: it is the stdin/stdout path, so
    /// it must reach `addPositional` like any other input. Before this, every
    /// command answered `pngine compile -` with "Unknown option: -".
    pub fn isFlag(arg: []const u8) bool {
        return arg.len > 1 and arg[0] == '-';
    }
};

// -- Uniform error renderers (the caller's stderr side) ----------------------
// Kept beside ArgReader so all commands share one message each; the reader core
// stays stderr-free and unit-testable. Every legacy site returned exit code 1
// for these three failures, so the helpers bake that in.

/// Render the uniform "requires a value" error; returns exit code 1.
pub fn missingValue(flag: []const u8) u8 {
    std.debug.print("Error: {s} requires a value\n", .{flag});
    return 1;
}

/// Render the uniform "multiple input files" error; returns exit code 1.
pub fn duplicateInput() u8 {
    std.debug.print("Error: multiple input files specified\n", .{});
    return 1;
}

/// Render the uniform "Unknown option" error; returns exit code 1.
pub fn unknownOption(flag: []const u8) u8 {
    std.debug.print("Unknown option: {s}\n", .{flag});
    return 1;
}

/// True if `-h`/`--help` appears anywhere in `args`.
///
/// Scanned up-front rather than matched inside the option loop so `--help`
/// answers even when required positionals are missing — `pngine embed --help`
/// must print help, not "embed requires both <image.png> and <bytecode.pngb>".
pub fn wantsHelp(args: []const []const u8) bool {
    std.debug.assert(args.len <= max_args);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return true;
    }
    return false;
}

/// Print a command's usage text; returns exit code 0.
///
/// Help that was explicitly asked for is a success, not a usage error — the
/// same code `inspect`/`diff`/`render`/`validate` already return.
pub fn printHelp(usage: []const u8) u8 {
    std.debug.assert(usage.len > 0);
    std.debug.print("{s}", .{usage});
    return 0;
}
