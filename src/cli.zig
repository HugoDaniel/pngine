//! PNGine CLI - Command-line interface for PNGine bytecode engine.
//!
//! ## Commands
//!
//! | Command | Description |
//! |---------|-------------|
//! | compile | Compile SJON source to PNGB bytecode |
//! | validate | Source-level validation (parse, analyze, WGSL check) |
//! | inspect | Bytecode inspection via MockGPU, optional WAMR deep analysis |
//! | render | Create PNG with embedded bytecode (default command) |
//! | embed | Embed PNGB bytecode into an existing PNG |
//! | extract | Extract PNGB bytecode from a PNG or ZIP file |
//! | bundle | Create a ZIP bundle with bytecode and optional assets |
//! | list | List contents of a ZIP or PNG file |
//!
//! ## Exit Codes
//!
//! | Code | Meaning |
//! |------|---------|
//! | 0 | Success |
//! | 1 | Invalid arguments |
//! | 2 | File I/O error |
//! | 3 | Compilation error |
//! | 4 | Format error (PNG/PNGB) |
//! | 5 | Execution error |
//! | 6 | Validation warning |
//! | 99 | Internal: memory leaked (Debug/ReleaseSafe builds only — the leak report precedes it) |
//!
//! ## Module Organization
//!
//! - `cli/compile.zig` - Compile command
//! - `cli/validate.zig` - Validate command (source-level)
//! - `cli/inspect.zig` - Inspect command (bytecode-level, merges old check + validate)
//! - `cli/render.zig` - Render command
//! - `cli/embed.zig` - Embed/extract commands
//! - `cli/bundle.zig` - Bundle/list commands
//! - `cli/utils.zig` - Shared utilities (file I/O, path handling)

const std = @import("std");
const build_options = @import("build_options");

// Subcommand modules (pub for test access via module import)
const compile_cmd = @import("cli/compile.zig");
const validate_cmd = @import("cli/validate.zig");
pub const inspect_cmd = @import("cli/inspect.zig");
const render_cmd = @import("cli/render.zig");
const embed_cmd = @import("cli/embed.zig");
const bundle_cmd = @import("cli/bundle.zig");
const diff_cmd = @import("cli/diff.zig");
const utils = @import("cli/utils.zig");
const stdio = @import("cli/stdio.zig");
pub const test_utils = @import("test_utils.zig");

/// CLI entry point.
///
/// The exit code is RETURNED, never `std.process.exit`ed from inside the
/// command: `exit` skips every `defer`, and the old shape (`defer _ =
/// gpa_state.deinit(); … std.process.exit(code)`) meant the leak checker
/// never ran and its verdict was discarded when it did — so no spawned e2e
/// test could ever see a command leak. Now the command runs inside
/// `mainWithIo`, whose defers release the io context and argv before the
/// allocator is checked, and a leak in a Debug/ReleaseSafe build is exit 99
/// after the allocator's own report (ReleaseFast's allocator does not track,
/// so a shipping binary never pays for or reports this). (Third leak pass)
pub fn main(init: std.process.Init.Minimal) u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const code = mainWithIo(gpa_state.allocator(), init) catch |err| blk: {
        std.debug.print("Error: {s}\n", .{@errorName(err)});
        break :blk 1;
    };
    if (gpa_state.deinit() == .leak) {
        std.debug.print("pngine: internal error — memory leaked (report above); exit 99\n", .{});
        return LEAK_EXIT_CODE;
    }
    return code;
}

/// Exit code for a leak detected at exit (Debug/ReleaseSafe only). Outside the
/// 0..6 range the commands use, so a test that spawns the binary can tell a
/// leak from any command outcome.
pub const LEAK_EXIT_CODE: u8 = 99;

fn mainWithIo(gpa: std.mem.Allocator, init: std.process.Init.Minimal) !u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    const io = threaded.io();

    const args = try init.args.toSlice(gpa);
    defer gpa.free(args);

    if (args.len < 2) {
        printUsage();
        return 1;
    }
    return run(gpa, args, io);
}

/// Parse arguments and dispatch to appropriate command. `pub` so the
/// in-process e2e (tests/zig/cli/inprocess_test.zig) can drive every command
/// under `std.testing.allocator` — the only leak-checked path through them.
pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8, io: std.Io) !u8 {
    std.debug.assert(args.len >= 1);

    if (args.len < 2) {
        printUsage();
        return 1;
    }

    const command = args[1];

    // Check if first arg is a source file - treat as implicit render command.
    // A bare `-` is the stdin spelling of the same thing: `pngine - < a.sjon`
    // must mean what `pngine a.sjon` means, not "unknown command".
    if (stdio.isSjonPath(command)) {
        return render_cmd.run(allocator, io, args[1..]);
    }

    // Dispatch to subcommand
    if (std.mem.eql(u8, command, "compile")) {
        return compile_cmd.run(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, command, "validate")) {
        return validate_cmd.run(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, command, "inspect")) {
        return inspect_cmd.run(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, command, "check")) {
        // Deprecated alias for inspect
        std.debug.print("Note: 'check' is now 'inspect'. This alias will be removed in a future version.\n\n", .{});
        return inspect_cmd.run(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, command, "render")) {
        return render_cmd.run(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, command, "embed")) {
        return embed_cmd.runEmbed(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, command, "extract")) {
        return embed_cmd.runExtract(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, command, "bundle")) {
        return bundle_cmd.runBundle(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, command, "list")) {
        return bundle_cmd.runList(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, command, "diff")) {
        return diff_cmd.run(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, command, "help") or
        std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h"))
    {
        printUsage();
        return 0;
    } else if (std.mem.eql(u8, command, "version") or
        std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v"))
    {
        printVersion();
        return 0;
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{command});
        printUsage();
        return 1;
    }
}

fn printUsage() void {
    std.debug.print(
        \\PNGine - SJON to PNGB compiler
        \\
        \\Usage: pngine <command> [options]
        \\
        \\Commands:
        \\  compile   Compile source to bytecode
        \\  validate  Validate source (syntax, semantics, WGSL)
        \\  inspect   Inspect bytecode (MockGPU summary, --deep for WAMR)
        \\  render    Create PNG with bytecode (default)
        \\  embed     Embed bytecode into PNG
        \\  extract   Extract bytecode from PNG/ZIP
        \\  bundle    Create ZIP bundle
        \\  list      List contents of ZIP/PNG
        \\  diff      Pixel-compare two PNGs (tolerance model)
        \\  help      Show this help
        \\  version   Show version
        \\
        \\Examples:
        \\  pngine shader.sjon                       Create PNG (implicit render)
        \\  pngine compile shader.sjon               Compile to .pngb
        \\  pngine validate shader.sjon              Check source for errors
        \\  pngine inspect shader.sjon --verbose     GPU call trace
        \\  pngine inspect shader.sjon --deep --json WAMR runtime analysis
        \\  pngine embed img.png shader.pngb         Embed into existing PNG
        \\  pngine diff a.png b.png                  Pixel-compare two PNGs
        \\
        \\Piping:
        \\  `-` reads stdin as an input and writes stdout as `-o`. stdin is
        \\  identified by its leading bytes, so a pipeline needs no filenames.
        \\  Diagnostics always go to stderr; binary output is refused on a
        \\  terminal. With `-` as input, `-o` defaults to stdout.
        \\
        \\  pngine extract art.png | pngine inspect -
        \\  pngine compile - < shader.sjon > out.pngb
        \\
        \\For command-specific help: pngine <command> --help
        \\
    , .{});
}

fn printVersion() void {
    std.debug.print("pngine {s}\n", .{build_options.version});
}

// ============================================================================
// Tests (reference submodule tests for discovery)
// ============================================================================
