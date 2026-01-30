//! PNGine CLI - Command-line interface for PNGine bytecode engine.
//!
//! ## Commands
//!
//! | Command | Description |
//! |---------|-------------|
//! | compile | Compile DSL/PBSF source to PNGB bytecode |
//! | check | Validate bytecode by running through MockGPU (--verbose for trace) |
//! | validate | Runtime validation via WAMR command buffer inspection |
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
//!
//! ## Module Organization
//!
//! - `cli/compile.zig` - Compile command
//! - `cli/check.zig` - Check command (MockGPU validation)
//! - `cli/validate.zig` - Validate command (WAMR runtime)
//! - `cli/render.zig` - Render command
//! - `cli/embed.zig` - Embed/extract commands
//! - `cli/bundle.zig` - Bundle/list commands
//! - `cli/utils.zig` - Shared utilities (file I/O, path handling)

const std = @import("std");

// Subcommand modules
const compile_cmd = @import("cli/compile.zig");
const check_cmd = @import("cli/check.zig");
const validate_cmd = @import("cli/validate.zig");
const render_cmd = @import("cli/render.zig");
const embed_cmd = @import("cli/embed.zig");
const bundle_cmd = @import("cli/bundle.zig");
const utils = @import("cli/utils.zig");

/// CLI entry point.
pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

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
        std.process.exit(io, 1);
    }

    const exit_code = try run(gpa, io);
    std.process.exit(io, exit_code);
}

/// Parse arguments and dispatch to appropriate command.
fn run(allocator: std.mem.Allocator, io: std.Io) !u8 {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    std.debug.assert(args.len >= 1);

    if (args.len < 2) {
        printUsage();
        return 1;
    }

    const command = args[1];

    // Check if first arg is a .pngine file - treat as implicit render command
    const extension = std.fs.path.extension(command);
    if (std.mem.eql(u8, extension, ".pngine") or std.mem.eql(u8, extension, ".pbsf")) {
        return render_cmd.run(allocator, io, args[1..]);
    }

    // Dispatch to subcommand
    if (std.mem.eql(u8, command, "compile")) {
        return compile_cmd.run(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, command, "check")) {
        return check_cmd.run(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, command, "validate")) {
        return validate_cmd.run(allocator, io, args[2..]);
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
        \\PNGine - DSL/PBSF to PNGB compiler
        \\
        \\Usage: pngine <command> [options]
        \\
        \\Commands:
        \\  compile   Compile source to bytecode
        \\  check     Validate bytecode (MockGPU)
        \\  validate  Runtime validation (WAMR)
        \\  render    Create PNG with bytecode (default)
        \\  embed     Embed bytecode into PNG
        \\  extract   Extract bytecode from PNG/ZIP
        \\  bundle    Create ZIP bundle
        \\  list      List contents of ZIP/PNG
        \\  help      Show this help
        \\  version   Show version
        \\
        \\Examples:
        \\  pngine shader.pngine                  Create PNG (implicit render)
        \\  pngine compile shader.pngine          Compile to .pngb
        \\  pngine check shader.pngine --verbose  GPU call trace (like browser debug)
        \\  pngine validate shader.pngine --json  Runtime validation
        \\  pngine embed img.png shader.pngb      Embed into existing PNG
        \\
        \\For command-specific help: pngine <command> --help
        \\
    , .{});
}

fn printVersion() void {
    std.debug.print("pngine 0.1.0\n", .{});
}

// ============================================================================
// Tests (reference submodule tests for discovery)
// ============================================================================

test {
    // Import submodules to discover their tests
    _ = @import("cli/utils.zig");
    _ = @import("cli/compile.zig");
    _ = @import("cli/check.zig");
    _ = @import("cli/validate.zig");
    _ = @import("cli/render.zig");
    _ = @import("cli/embed.zig");
    _ = @import("cli/bundle.zig");
}
