//! Compile command: compile SJON source to PNGB bytecode.
//!
//! Usage:
//!   pngine compile input.sjon [-o output.pngb]
//!
//! Shows detected plugins and selected executor variant for the embedded
//! executor feature.

const std = @import("std");
const pngine = @import("pngine");
const utils = @import("utils.zig");
const stdio = @import("stdio.zig");
const arg_reader = @import("arg_reader.zig");
const build_options = @import("build_options");
const embedded_wasm: []const u8 = if (build_options.has_embedded_wasm) @embedFile("embedded_wasm") else &.{};

/// Compile result with optional plugin/variant info for DSL files.
pub const CompileOutput = struct {
    bytecode: []u8,
    variant_name: ?[]const u8 = null,
    variant_size: u32 = 0,
    plugins: ?pngine.PluginSet = null,
};

pub const usage =
    \\pngine compile - Compile SJON source to PNGB bytecode
    \\
    \\Usage: pngine compile <input.sjon|-> [options]
    \\
    \\Options:
    \\  -o, --output <path>    Output .pngb path (default: <input>.pngb; stdout if
    \\                         the input is `-`). Use `-` to write stdout.
    \\  -m, --minify           Minify WGSL shaders (~30% smaller shader text
    \\                         after compression; no effect on mesh data)
    \\      --embed-executor   Embed the executor WASM in the payload
    \\      --executors-dir    Directory to load executor variants from
    \\                         (default: zig-out/executors)
    \\      --validate         Validate WGSL shaders (default)
    \\      --no-validate      Skip WGSL shader validation
    \\  -h, --help             Show this help
    \\
;

/// Compile command options parsed from CLI arguments.
const Options = struct {
    input_path: []const u8 = "",
    output_path: ?[]const u8 = null,
    embed_executor: bool = false,
    executors_dir: ?[]const u8 = null,
    minify_shaders: bool = false,
    /// R3: the CLI validates shaders by default; --no-validate opts out.
    validate_shaders: bool = true,
};

/// Execute the compile command.
///
/// Pre-condition: args is the slice after "compile" command.
/// Post-condition: Returns exit code (0 = success, non-zero = error).
pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (arg_reader.wantsHelp(args)) return arg_reader.printHelp(usage);

    var opts = Options{};
    const parse_result = parseArgs(args, &opts);
    if (parse_result != 0) return parse_result;
    std.debug.assert(opts.input_path.len > 0);

    const input = opts.input_path;

    // Derive output path if not specified. Piped input has no name to derive
    // from, so it defaults to stdout — otherwise `pngine compile -` would
    // write a file literally called `-.pngb`.
    const dest: stdio.Output = if (opts.output_path) |p|
        .borrowed(p)
    else if (stdio.isStd(input))
        .borrowed(stdio.std_path)
    else
        .owned(utils.deriveOutputPath(allocator, input) catch |err| {
            std.debug.print("Error: failed to derive output path: {}\n", .{err});
            return 2;
        });
    defer dest.deinit(allocator);
    const output = dest.path;

    // Read input (a real path by extension, stdin by content).
    const in = stdio.readInput(allocator, io, input) catch |err| return stdio.reportReadError(err, input);
    defer in.deinit(allocator);

    if (in.kind != .sjon) {
        std.debug.print("Error: compile expects SJON source, got {t} ({s})\n", .{ in.kind, stdio.displayName(input) });
        return 4;
    }

    // Compile using appropriate compiler based on file extension
    const fallback_wasm: ?[]const u8 = if (embedded_wasm.len > 0) embedded_wasm else null;
    const result = compileSourceWithPlugins(allocator, io, input, in.bytes, .{
        .embed_executor = opts.embed_executor,
        .executors_dir = opts.executors_dir,
        .minify_shaders = opts.minify_shaders,
        .validate_shaders = opts.validate_shaders,
        .embedded_executor_wasm = fallback_wasm,
    }) catch |err| {
        std.debug.print("Error: compilation failed: {}\n", .{err});
        return 3;
    };
    defer allocator.free(result.bytecode);

    // Post-condition: valid PNGB output
    std.debug.assert(result.bytecode.len >= pngine.format.HEADER_SIZE);
    std.debug.assert(std.mem.eql(u8, result.bytecode[0..4], pngine.format.MAGIC));

    // Write output (file, or stdout for `-o -`). PNGB is binary, so a bare
    // terminal is refused rather than filled with control bytes.
    stdio.writeOutput(io, output, result.bytecode, true) catch |err| return stdio.reportWriteError(err, output);

    reportResult(input, output, result, opts.embed_executor);
    return 0;
}

/// Parse compile command arguments.
///
/// Returns 0 on success, >0 on error (the message is already printed).
fn parseArgs(args: []const []const u8, opts: *Options) u8 {
    std.debug.assert(opts.input_path.len == 0);
    std.debug.assert(opts.validate_shaders);

    // Shared cursor/value/positional plumbing via ArgReader.
    var reader = arg_reader.ArgReader.init(args);
    while (reader.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            opts.output_path = reader.value() catch return arg_reader.missingValue(arg);
        } else if (std.mem.eql(u8, arg, "--embed-executor")) {
            opts.embed_executor = true;
        } else if (std.mem.eql(u8, arg, "--executors-dir")) {
            opts.executors_dir = reader.value() catch return arg_reader.missingValue(arg);
        } else if (std.mem.eql(u8, arg, "--minify") or std.mem.eql(u8, arg, "-m")) {
            opts.minify_shaders = true;
        } else if (std.mem.eql(u8, arg, "--validate")) {
            opts.validate_shaders = true;
        } else if (std.mem.eql(u8, arg, "--no-validate")) {
            opts.validate_shaders = false;
        } else if (arg_reader.ArgReader.isFlag(arg)) {
            return arg_reader.unknownOption(arg);
        } else {
            reader.addPositional(arg) catch return arg_reader.duplicateInput();
        }
    }

    if (reader.positional == null) {
        std.debug.print("Error: no input file specified\n\n", .{});
        std.debug.print("Usage: pngine compile <input.sjon|-> [-o output.pngb|-] [--embed-executor] [--no-validate]\n", .{});
        return 1;
    }
    opts.input_path = reader.positional.?;

    // Default executors dir for development.
    if (opts.embed_executor and opts.executors_dir == null) {
        opts.executors_dir = "zig-out/executors";
    }

    std.debug.assert(opts.input_path.len > 0);
    return 0;
}

/// Print the compilation summary, with plugin/variant detail when the SJON
/// path reported one.
fn reportResult(input: []const u8, output: []const u8, result: CompileOutput, embed_executor: bool) void {
    std.debug.assert(input.len > 0);
    std.debug.assert(result.bytecode.len > 0);

    std.debug.print("Compiled {s} -> {s} ({d} bytes)\n", .{ stdio.displayName(input), stdio.outName(output), result.bytecode.len });

    const variant = result.variant_name orelse return;
    var plugins_buf: [128]u8 = undefined;
    const plugins_desc = if (result.plugins) |p|
        pngine.variant.describePlugins(p, &plugins_buf)
    else
        "(none)";

    std.debug.print("  Plugins: {s}\n", .{plugins_desc});
    if (embed_executor) {
        std.debug.print("  Executor: pngine-{s}.wasm (embedded)\n", .{variant});
    } else {
        std.debug.print("  Executor: pngine-{s}.wasm (not embedded)\n", .{variant});
    }
}

/// Options for compiling with plugins.
pub const CompileOptions = struct {
    embed_executor: bool = false,
    executors_dir: ?[]const u8 = null,
    /// Minify WGSL shaders for smaller payload size.
    /// Uses wgslender for WGSL shader minification.
    minify_shaders: bool = false,
    /// Validate WGSL shaders at compile time.
    validate_shaders: bool = false,
    /// Fallback executor WASM bytes when variant file not found on disk.
    embedded_executor_wasm: ?[]const u8 = null,
};

/// Compile source using appropriate compiler based on file extension.
///
/// - `.sjon` files use the SJON host (PNGine as a SJON host) with plugin detection
///
/// The legacy `.pngine` macro DSL was removed in Phase 5 (Stage B2) and the
/// legacy `.pbsf` S-expression assembler was retired after it; any other
/// extension is rejected with `error.UnsupportedFormat`.
pub fn compileSourceWithPlugins(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    source: [:0]const u8,
    options: CompileOptions,
) !CompileOutput {
    // `-` is source too: its kind came from sniffing rather than a name, and
    // its relative references resolve against the cwd (see stdio.baseDir).
    if (stdio.isSjonPath(path)) {
        // SJON format - PNGine as a SJON host; same plugin/variant + executor
        // embedding path as the DSL branch (identical CompileOutput shape).
        const base_dir = stdio.baseDir(path);

        const result = try pngine.dsl_sjon.compileWithPlugins(allocator, source, .{
            .base_dir = base_dir,
            .file_path = path,
            .minify_shaders = options.minify_shaders,
            .validate_shaders = options.validate_shaders,
            .embed_executor = options.embed_executor,
            .executors_dir = options.executors_dir,
            .embedded_executor_wasm = options.embedded_executor_wasm,
            .io = io,
        });

        return .{
            .bytecode = result.pngb,
            .variant_name = result.variant_name,
            .variant_size = result.variant_size,
            .plugins = result.plugins,
        };
    } else {
        // Legacy `.pngine` and `.pbsf` (and any other extension) are no longer
        // supported — use `.sjon`.
        return error.UnsupportedFormat;
    }
}

/// Legacy compile function for backwards compatibility.
pub fn compileSource(allocator: std.mem.Allocator, io: std.Io, path: []const u8, source: [:0]const u8) ![]u8 {
    const result = try compileSourceWithPlugins(allocator, io, path, source, .{});
    return result.bytecode;
}
