//! Compile command: compile DSL/PBSF source to PNGB bytecode.
//!
//! Usage:
//!   pngine compile input.pngine [-o output.pngb]
//!   pngine compile input.pbsf [-o output.pngb]

const std = @import("std");
const pngine = @import("pngine");
const utils = @import("utils.zig");

/// Execute the compile command.
///
/// Pre-condition: args is the slice after "compile" command.
/// Post-condition: Returns exit code (0 = success, non-zero = error).
pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    // Parse arguments with bounded iteration
    const args_len: u32 = @intCast(args.len);
    var skip_next = false;
    for (0..args_len) |idx| {
        if (skip_next) {
            skip_next = false;
            continue;
        }
        const i: u32 = @intCast(idx);
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: -o requires an output path\n", .{});
                return 1;
            }
            output_path = args[i + 1];
            skip_next = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return 1;
        } else {
            if (input_path != null) {
                std.debug.print("Error: multiple input files specified\n", .{});
                return 1;
            }
            input_path = arg;
        }
    }

    if (input_path == null) {
        std.debug.print("Error: no input file specified\n\n", .{});
        std.debug.print("Usage: pngine compile <input.pngine> [-o output.pngb]\n", .{});
        return 1;
    }

    const input = input_path.?;

    // Derive output path if not specified
    const output = output_path orelse utils.deriveOutputPath(allocator, input) catch |err| {
        std.debug.print("Error: failed to derive output path: {}\n", .{err});
        return 2;
    };
    defer if (output_path == null) allocator.free(output);

    // Read input file
    const source = utils.readSourceFile(allocator, input) catch |err| {
        std.debug.print("Error: failed to read '{s}': {}\n", .{ input, err });
        return 2;
    };
    defer allocator.free(source);

    // Compile using appropriate compiler based on file extension
    const bytecode = compileSource(allocator, input, source) catch |err| {
        std.debug.print("Error: compilation failed: {}\n", .{err});
        return 3;
    };
    defer allocator.free(bytecode);

    // Post-condition: valid PNGB output
    std.debug.assert(bytecode.len >= pngine.format.HEADER_SIZE);
    std.debug.assert(std.mem.eql(u8, bytecode[0..4], pngine.format.MAGIC));

    // Write output file
    utils.writeOutputFile(output, bytecode) catch |err| {
        std.debug.print("Error: failed to write '{s}': {}\n", .{ output, err });
        return 2;
    };

    std.debug.print("Compiled {s} -> {s} ({d} bytes)\n", .{ input, output, bytecode.len });
    return 0;
}

/// Compile source using appropriate compiler based on file extension.
///
/// - `.pngine` files use the DSL compiler (macro-based syntax)
/// - `.pbsf` files use the legacy PBSF compiler (S-expression syntax)
pub fn compileSource(allocator: std.mem.Allocator, path: []const u8, source: [:0]const u8) ![]u8 {
    const extension = std.fs.path.extension(path);

    if (std.mem.eql(u8, extension, ".pbsf")) {
        return pngine.compile(allocator, source);
    } else {
        const base_dir = std.fs.path.dirname(path) orelse ".";
        const miniray_path = findMinirayPath();

        return pngine.dsl.compileWithOptions(allocator, source, .{
            .base_dir = base_dir,
            .file_path = path,
            .miniray_path = miniray_path,
        });
    }
}

/// Find miniray binary for WGSL reflection.
fn findMinirayPath() ?[]const u8 {
    if (std.posix.getenv("PNGINE_MINIRAY_PATH")) |path| {
        if (path.len > 0) return path;
    }

    const dev_paths = [_][]const u8{
        "/Users/hugo/Development/miniray/miniray",
        "../miniray/miniray",
    };

    for (dev_paths) |dev_path| {
        if (std.fs.cwd().access(dev_path, .{})) |_| {
            return dev_path;
        } else |_| {}
    }

    return null;
}
