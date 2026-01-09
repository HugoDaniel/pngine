//! Compile command: compile DSL/PBSF source to PNGB bytecode.
//!
//! Usage:
//!   pngine compile input.pngine [-o output.pngb]
//!   pngine compile input.pbsf [-o output.pngb]
//!
//! When compiling .pngine files, shows detected plugins and selected
//! executor variant for embedded executor feature.

const std = @import("std");
const pngine = @import("pngine");
const utils = @import("utils.zig");

/// Compile result with optional plugin/variant info for DSL files.
pub const CompileOutput = struct {
    bytecode: []u8,
    variant_name: ?[]const u8 = null,
    variant_size: u32 = 0,
    plugins: ?pngine.PluginSet = null,
};

/// Execute the compile command.
///
/// Pre-condition: args is the slice after "compile" command.
/// Post-condition: Returns exit code (0 = success, non-zero = error).
pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var embed_executor: bool = false;
    var executors_dir: ?[]const u8 = null;
    var minify_shaders: bool = false;

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
        } else if (std.mem.eql(u8, arg, "--embed-executor")) {
            embed_executor = true;
        } else if (std.mem.eql(u8, arg, "--executors-dir")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: --executors-dir requires a path\n", .{});
                return 1;
            }
            executors_dir = args[i + 1];
            skip_next = true;
        } else if (std.mem.eql(u8, arg, "--minify") or std.mem.eql(u8, arg, "-m")) {
            minify_shaders = true;
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
        std.debug.print("Usage: pngine compile <input.pngine> [-o output.pngb] [--embed-executor]\n", .{});
        return 1;
    }

    // Default executors dir for development
    if (embed_executor and executors_dir == null) {
        executors_dir = "zig-out/executors";
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
    const result = compileSourceWithPlugins(allocator, input, source, .{
        .embed_executor = embed_executor,
        .executors_dir = executors_dir,
        .minify_shaders = minify_shaders,
    }) catch |err| {
        std.debug.print("Error: compilation failed: {}\n", .{err});
        return 3;
    };
    defer allocator.free(result.bytecode);

    // Post-condition: valid PNGB output
    std.debug.assert(result.bytecode.len >= pngine.format.HEADER_SIZE);
    std.debug.assert(std.mem.eql(u8, result.bytecode[0..4], pngine.format.MAGIC));

    // Write output file
    utils.writeOutputFile(output, result.bytecode) catch |err| {
        std.debug.print("Error: failed to write '{s}': {}\n", .{ output, err });
        return 2;
    };

    // Print compilation result with variant info
    if (result.variant_name) |variant| {
        var plugins_buf: [128]u8 = undefined;
        const plugins_desc = if (result.plugins) |p|
            pngine.variant.describePlugins(p, &plugins_buf)
        else
            "(none)";

        std.debug.print("Compiled {s} -> {s} ({d} bytes)\n", .{ input, output, result.bytecode.len });
        std.debug.print("  Plugins: {s}\n", .{plugins_desc});
        if (embed_executor) {
            std.debug.print("  Executor: pngine-{s}.wasm (embedded)\n", .{variant});
        } else {
            std.debug.print("  Executor: pngine-{s}.wasm (~{d}KB)\n", .{ variant, result.variant_size / 1024 });
        }
    } else {
        std.debug.print("Compiled {s} -> {s} ({d} bytes)\n", .{ input, output, result.bytecode.len });
    }
    return 0;
}

/// Options for compiling with plugins.
pub const CompileOptions = struct {
    embed_executor: bool = false,
    executors_dir: ?[]const u8 = null,
    /// Minify WGSL shaders for smaller payload size.
    /// Requires libminiray.a to be linked.
    minify_shaders: bool = false,
};

/// Compile source using appropriate compiler based on file extension.
///
/// - `.pngine` files use the DSL compiler (macro-based syntax) with plugin detection
/// - `.pbsf` files use the legacy PBSF compiler (S-expression syntax)
pub fn compileSourceWithPlugins(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: [:0]const u8,
    options: CompileOptions,
) !CompileOutput {
    const extension = std.fs.path.extension(path);

    if (std.mem.eql(u8, extension, ".pbsf")) {
        // Legacy format - no plugin detection
        const bytecode = try pngine.compile(allocator, source);
        return .{ .bytecode = bytecode };
    } else {
        // DSL format - use compileWithPlugins for variant selection
        const base_dir = std.fs.path.dirname(path) orelse ".";

        const result = try pngine.dsl.compileWithPlugins(allocator, source, .{
            .base_dir = base_dir,
            .file_path = path,
            .minify_shaders = options.minify_shaders,
            .embed_executor = options.embed_executor,
            .executors_dir = options.executors_dir,
        });

        return .{
            .bytecode = result.pngb,
            .variant_name = result.variant_name,
            .variant_size = result.variant_size,
            .plugins = result.plugins,
        };
    }
}

/// Legacy compile function for backwards compatibility.
pub fn compileSource(allocator: std.mem.Allocator, path: []const u8, source: [:0]const u8) ![]u8 {
    const result = try compileSourceWithPlugins(allocator, path, source, .{});
    return result.bytecode;
}

