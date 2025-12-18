//! Render command: compile and embed PNGine shader in PNG image.
//!
//! ## Usage
//! ```
//! pngine shader.pngine -o output.png           # 1x1 transparent PNG with bytecode
//! pngine shader.pngine --frame --size 512x512  # Render actual frame at 512x512
//! ```
//!
//! ## Design
//! By default, output is a 1x1 transparent pixel PNG with embedded bytecode.
//! This keeps file sizes minimal (~400 bytes) while maintaining executability.
//! Use --frame to render an actual preview image at the specified size.
//!
//! ## Invariants
//! - Input must be valid .pngine or .pbsf source
//! - Output is always a valid PNG file
//! - Embedded bytecode (--embed) creates self-contained executable images

const std = @import("std");
const pngine = @import("pngine");
const format = pngine.format;

/// Render command options parsed from CLI arguments.
pub const Options = struct {
    input_path: []const u8,
    output_path: ?[]const u8,
    width: u32,
    height: u32,
    time: f32,
    embed_bytecode: bool,
    /// true if user explicitly set --embed or --no-embed
    embed_explicit: bool,
    /// true to render actual frame via GPU, false for 1x1 transparent pixel
    render_frame: bool,
    /// Path to WASM runtime to embed (pNGr chunk)
    runtime_path: ?[]const u8,
};

/// Execute the render command.
///
/// Pre-condition: args is the slice after "render" command.
/// Post-condition: Returns exit code (0 = success).
pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    // Parse arguments
    var opts = Options{
        .input_path = "",
        .output_path = null,
        .width = 512,
        .height = 512,
        .time = 0.0,
        .embed_bytecode = true, // Embed by default
        .embed_explicit = false,
        .render_frame = false, // 1x1 transparent pixel by default
        .runtime_path = null, // No runtime embedded by default
    };

    const parse_result = parseArgs(args, &opts);
    if (parse_result == 255) return 0; // Help was shown
    if (parse_result != 0) return parse_result;

    // Pre-condition: valid options after parsing
    std.debug.assert(opts.input_path.len > 0);
    std.debug.assert(opts.width > 0 and opts.height > 0);

    // Derive output path if not specified
    const output = opts.output_path orelse deriveOutputPath(allocator, opts.input_path) catch |err| {
        std.debug.print("Error: failed to derive output path: {}\n", .{err});
        return 2;
    };
    defer if (opts.output_path == null) allocator.free(output);

    // Execute render pipeline
    return executePipeline(allocator, opts.input_path, output, opts.width, opts.height, opts.time, opts.embed_bytecode, opts.render_frame, opts.runtime_path);
}

/// Parse render command arguments.
///
/// Returns 255 if help was requested, >0 on error, 0 on success.
fn parseArgs(args: []const []const u8, opts: *Options) u8 {
    // Pre-conditions
    std.debug.assert(opts.width == 512);

    var input_path: ?[]const u8 = null;
    const args_len: u32 = @intCast(args.len);
    var skip_count: u32 = 0;

    for (0..args_len) |idx| {
        // Skip arguments consumed by previous options (e.g., -o value)
        if (skip_count > 0) {
            skip_count -= 1;
            continue;
        }
        const i: u32 = @intCast(idx);
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: -o requires an output path\n", .{});
                return 1;
            }
            opts.output_path = args[i + 1];
            skip_count = 1;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--size")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: -s requires dimensions (e.g., 512x512)\n", .{});
                return 1;
            }
            const result = parseSizeValue(args[i + 1], opts);
            if (result != 0) return result;
            skip_count = 1;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--time")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: -t requires a time value (e.g., 2.5)\n", .{});
                return 1;
            }
            const result = parseTimeValue(args[i + 1], opts);
            if (result != 0) return result;
            skip_count = 1;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--frame")) {
            opts.render_frame = true;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--embed")) {
            opts.embed_bytecode = true;
            opts.embed_explicit = true;
        } else if (std.mem.eql(u8, arg, "--no-embed")) {
            opts.embed_bytecode = false;
            opts.embed_explicit = true;
        } else if (std.mem.eql(u8, arg, "--embed-runtime")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: --embed-runtime requires a WASM file path\n", .{});
                return 1;
            }
            opts.runtime_path = args[i + 1];
            skip_count = 1;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return 255;
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
        printUsage();
        return 1;
    }

    opts.input_path = input_path.?;

    // Post-condition: input_path is set
    std.debug.assert(opts.input_path.len > 0);
    return 0;
}

/// Parse size value in WxH format.
fn parseSizeValue(size_str: []const u8, opts: *Options) u8 {
    const x_pos = std.mem.indexOf(u8, size_str, "x") orelse {
        std.debug.print("Error: invalid size format '{s}' (expected WxH)\n", .{size_str});
        return 1;
    };

    opts.width = std.fmt.parseInt(u32, size_str[0..x_pos], 10) catch {
        std.debug.print("Error: invalid width in '{s}'\n", .{size_str});
        return 1;
    };
    opts.height = std.fmt.parseInt(u32, size_str[x_pos + 1 ..], 10) catch {
        std.debug.print("Error: invalid height in '{s}'\n", .{size_str});
        return 1;
    };

    if (opts.width == 0 or opts.height == 0) {
        std.debug.print("Error: width and height must be > 0\n", .{});
        return 1;
    }
    return 0;
}

/// Parse time value as float.
fn parseTimeValue(time_str: []const u8, opts: *Options) u8 {
    opts.time = std.fmt.parseFloat(f32, time_str) catch {
        std.debug.print("Error: invalid time value '{s}'\n", .{time_str});
        return 1;
    };
    return 0;
}

/// Execute the render pipeline: compile -> (optionally execute) -> encode -> write.
fn executePipeline(
    allocator: std.mem.Allocator,
    input: []const u8,
    output: []const u8,
    width: u32,
    height: u32,
    time: f32,
    embed_bytecode: bool,
    render_frame: bool,
    runtime_path: ?[]const u8,
) !u8 {
    // Pre-conditions
    std.debug.assert(input.len > 0);
    std.debug.assert(output.len > 0);

    // Read and compile source
    const bytecode = compileFromFile(allocator, input) catch |compile_err| {
        return handleCompileError(compile_err, input);
    };
    defer allocator.free(bytecode);

    if (bytecode.len < format.HEADER_SIZE or !std.mem.eql(u8, bytecode[0..4], format.MAGIC)) {
        std.debug.print("Error: compilation produced invalid bytecode\n", .{});
        return 3;
    }

    // Generate PNG (either rendered frame or 1x1 transparent pixel)
    const png_result = generatePng(allocator, bytecode, width, height, time, render_frame);
    if (png_result.exit_code != 0) return png_result.exit_code;

    var png_data = png_result.png_data;
    defer allocator.free(png_data);

    // Optionally embed bytecode in PNG (pNGb chunk)
    if (embed_bytecode) {
        png_data = embedBytecodeInPng(allocator, png_data, bytecode) catch |err| {
            std.debug.print("Error: failed to embed bytecode: {}\n", .{err});
            return 4;
        };
    }

    // Optionally embed WASM runtime in PNG (pNGr chunk)
    const runtime_embedded = if (runtime_path) |path| blk: {
        png_data = embedRuntimeInPng(allocator, png_data, path) catch |err| {
            std.debug.print("Error: failed to embed runtime: {}\n", .{err});
            return 4;
        };
        break :blk true;
    } else false;

    // Write final output
    writeOutputFile(output, png_data) catch |err| {
        std.debug.print("Error: failed to write '{s}': {}\n", .{ output, err });
        return 2;
    };

    // Report success to user
    printSuccessMessage(input, output, png_data.len, width, height, time, embed_bytecode, render_frame, runtime_embedded);
    return 0;
}

/// Compile source file to bytecode.
fn compileFromFile(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const source = try readSourceFile(allocator, input);
    defer allocator.free(source);
    return compileSource(allocator, input, source);
}

/// Handle compilation errors with appropriate messages.
fn handleCompileError(err: anyerror, input: []const u8) u8 {
    switch (err) {
        error.FileNotFound, error.AccessDenied, error.FileTooLarge => {
            std.debug.print("Error: failed to read '{s}': {}\n", .{ input, err });
            return 2;
        },
        else => {
            std.debug.print("Error: compilation failed: {}\n", .{err});
            return 3;
        },
    }
}

/// PNG generation result.
const PngResult = struct {
    png_data: []u8,
    exit_code: u8,
};

/// Generate PNG data - either rendered frame or 1x1 transparent pixel.
fn generatePng(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    width: u32,
    height: u32,
    time: f32,
    render_frame: bool,
) PngResult {
    if (render_frame) {
        return renderWithGpu(allocator, bytecode, width, height, time);
    }
    // 1x1 transparent pixel - minimal PNG container for bytecode
    const png_data = createTransparentPixel(allocator) catch |err| {
        std.debug.print("Error: failed to create PNG: {}\n", .{err});
        return .{ .png_data = undefined, .exit_code = 4 };
    };
    return .{ .png_data = png_data, .exit_code = 0 };
}

/// Embed bytecode in PNG, freeing original PNG data.
fn embedBytecodeInPng(allocator: std.mem.Allocator, png_data: []u8, bytecode: []const u8) ![]u8 {
    const embedded = try pngine.png.embedBytecode(allocator, png_data, bytecode);
    allocator.free(png_data);
    return embedded;
}

/// Embed WASM runtime in PNG from file, freeing original PNG data.
fn embedRuntimeInPng(allocator: std.mem.Allocator, png_data: []u8, runtime_path: []const u8) ![]u8 {
    // Pre-condition: path is valid
    std.debug.assert(runtime_path.len > 0);

    // Read runtime file
    const runtime = readBinaryFile(allocator, runtime_path) catch |err| {
        std.debug.print("Error: failed to read runtime '{s}': {}\n", .{ runtime_path, err });
        return err;
    };
    defer allocator.free(runtime);

    // Embed runtime in PNG (pNGr chunk)
    const embedded = pngine.png.embedRuntime(allocator, png_data, runtime) catch |err| {
        std.debug.print("Error: failed to embed runtime: {}\n", .{err});
        return err;
    };
    allocator.free(png_data);

    // Post-condition: result is larger
    std.debug.assert(embedded.len > png_data.len);

    return embedded;
}

/// Read binary file into buffer.
fn readBinaryFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    std.debug.assert(path.len > 0);

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const size: u32 = if (stat.size > max_file_size)
        return error.FileTooLarge
    else
        @intCast(stat.size);

    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    var bytes_read: u32 = 0;
    for (0..size + 1) |_| {
        if (bytes_read >= size) break;
        const n: u32 = @intCast(try file.read(buffer[bytes_read..]));
        if (n == 0) break;
        bytes_read += n;
    }

    return buffer;
}

/// Print success message after render completes.
fn printSuccessMessage(
    input: []const u8,
    output: []const u8,
    size: usize,
    width: u32,
    height: u32,
    time: f32,
    embed_bytecode: bool,
    render_frame: bool,
    runtime_embedded: bool,
) void {
    // Build flags string
    var flags_buf: [64]u8 = undefined;
    var flags_len: usize = 0;

    if (embed_bytecode) {
        const text = "bytecode";
        @memcpy(flags_buf[flags_len..][0..text.len], text);
        flags_len += text.len;
    }
    if (runtime_embedded) {
        if (flags_len > 0) {
            flags_buf[flags_len] = '+';
            flags_len += 1;
        }
        const text = "runtime";
        @memcpy(flags_buf[flags_len..][0..text.len], text);
        flags_len += text.len;
    }

    const flags_str = if (flags_len > 0) flags_buf[0..flags_len] else "image only";

    if (render_frame) {
        std.debug.print("Rendered {s} -> {s} ({d}x{d}, t={d:.2}, {s}, {d} bytes)\n", .{
            input, output, width, height, time, flags_str, size,
        });
    } else {
        std.debug.print("Created {s} -> {s} (1x1, {s}, {d} bytes)\n", .{ input, output, flags_str, size });
    }
}

/// Render bytecode using GPU and return PNG data.
fn renderWithGpu(allocator: std.mem.Allocator, bytecode: []const u8, width: u32, height: u32, time: f32) PngResult {
    const NativeGPU = pngine.gpu_backends.NativeGPU;

    // Pre-conditions
    std.debug.assert(bytecode.len >= format.HEADER_SIZE);
    std.debug.assert(width > 0 and height > 0);

    var module = format.deserialize(allocator, bytecode) catch |err| {
        std.debug.print("Error: failed to load bytecode: {}\n", .{err});
        return .{ .png_data = undefined, .exit_code = 3 };
    };
    defer module.deinit(allocator);

    var gpu = NativeGPU.init(allocator, width, height) catch |err| {
        std.debug.print("Error: failed to initialize GPU: {}\n", .{err});
        return .{ .png_data = undefined, .exit_code = 5 };
    };
    defer gpu.deinit(allocator);

    gpu.setModule(&module);
    gpu.setTime(time);

    var dispatcher = pngine.Dispatcher(NativeGPU).init(allocator, &gpu, &module);
    dispatcher.executeAll(allocator) catch |err| {
        std.debug.print("Error: execution failed: {}\n", .{err});
        return .{ .png_data = undefined, .exit_code = 5 };
    };

    const pixels = gpu.readPixels(allocator) catch |err| {
        std.debug.print("Error: failed to read pixels: {}\n", .{err});
        return .{ .png_data = undefined, .exit_code = 5 };
    };
    defer allocator.free(pixels);

    const png_data = pngine.png.encode(allocator, pixels, width, height) catch |err| {
        std.debug.print("Error: failed to encode PNG: {}\n", .{err});
        return .{ .png_data = undefined, .exit_code = 4 };
    };

    // Post-condition
    std.debug.assert(png_data.len > 0);
    return .{ .png_data = png_data, .exit_code = 0 };
}

/// Create a 1x1 transparent PNG image.
fn createTransparentPixel(allocator: std.mem.Allocator) ![]u8 {
    // Single RGBA pixel: transparent (0, 0, 0, 0)
    const pixels = [_]u8{ 0, 0, 0, 0 };
    const result = try pngine.png.encode(allocator, &pixels, 1, 1);

    // Post-condition
    std.debug.assert(result.len > 0);
    return result;
}

/// Print render command usage.
pub fn printUsage() void {
    std.debug.print(
        \\pngine render - Compile and embed shader in PNG image
        \\
        \\Usage:
        \\  pngine <input.pngine> [options]
        \\  pngine render <input.pngine> [options]
        \\
        \\Options:
        \\  -o, --output <path>       Output PNG path (default: <input>.png)
        \\  -f, --frame               Render actual frame via GPU (default: 1x1 transparent)
        \\  -s, --size <WxH>          Output dimensions when using --frame (default: 512x512)
        \\  -t, --time <seconds>      Time value for animation (default: 0.0)
        \\  -e, --embed               Embed bytecode in output PNG (default: on)
        \\  --no-embed                Do not embed bytecode
        \\  --embed-runtime <path>    Embed WASM runtime for self-contained PNG (pNGr chunk)
        \\  -h, --help                Show this help
        \\
        \\Examples:
        \\  pngine shader.pngine                             # 1x1 PNG with bytecode (~500 bytes)
        \\  pngine shader.pngine --frame                     # Render 512x512 preview
        \\  pngine shader.pngine --frame -s 1920x1080        # Render at 1080p
        \\  pngine shader.pngine --frame -t 2.5              # Render at t=2.5 seconds
        \\  pngine shader.pngine --no-embed                  # 1x1 PNG without bytecode
        \\  pngine shader.pngine --embed-runtime pngine.wasm # Self-contained (~31KB)
        \\
    , .{});
}

/// Derive output path: input.pngine -> input.png
fn deriveOutputPath(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    // Pre-condition
    std.debug.assert(input.len > 0);

    const stem = std.fs.path.stem(input);
    const dir = std.fs.path.dirname(input);

    const result = if (dir) |d|
        try std.fmt.allocPrint(allocator, "{s}/{s}.png", .{ d, stem })
    else
        try std.fmt.allocPrint(allocator, "{s}.png", .{stem});

    // Post-condition
    std.debug.assert(std.mem.endsWith(u8, result, ".png"));

    return result;
}

// ============================================================================
// File I/O helpers (duplicated from cli.zig for module independence)
// ============================================================================

const max_file_size: u32 = 16 * 1024 * 1024;

fn readSourceFile(allocator: std.mem.Allocator, path: []const u8) ![:0]const u8 {
    std.debug.assert(path.len > 0);

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const size: u32 = if (stat.size > max_file_size)
        return error.FileTooLarge
    else
        @intCast(stat.size);

    const buffer = try allocator.allocSentinel(u8, size, 0);
    errdefer allocator.free(buffer);

    var bytes_read: u32 = 0;
    for (0..size + 1) |_| {
        if (bytes_read >= size) break;
        const n: u32 = @intCast(try file.read(buffer[bytes_read..]));
        if (n == 0) break;
        bytes_read += n;
    }

    std.debug.assert(buffer[size] == 0);
    return buffer;
}

fn compileSource(allocator: std.mem.Allocator, path: []const u8, source: [:0]const u8) ![]u8 {
    const extension = std.fs.path.extension(path);

    if (std.mem.eql(u8, extension, ".pbsf")) {
        return pngine.compile(allocator, source);
    } else {
        // Pass base_dir for asset embedding (e.g., blob={file={url="..."}} )
        const base_dir = std.fs.path.dirname(path);
        return pngine.dsl.compileWithOptions(allocator, source, .{
            .base_dir = base_dir,
        });
    }
}

fn writeOutputFile(path: []const u8, data: []const u8) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(data.len > 0);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
}

// ============================================================================
// Tests
// ============================================================================

test "deriveOutputPath: simple filename" {
    const allocator = std.testing.allocator;
    const result = try deriveOutputPath(allocator, "shader.pngine");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("shader.png", result);
}

test "deriveOutputPath: with directory" {
    const allocator = std.testing.allocator;
    const result = try deriveOutputPath(allocator, "path/to/shader.pngine");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("path/to/shader.png", result);
}

test "deriveOutputPath: pbsf extension" {
    const allocator = std.testing.allocator;
    const result = try deriveOutputPath(allocator, "legacy.pbsf");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("legacy.png", result);
}

test "parseArgs: input file only" {
    var opts = Options{
        .input_path = "",
        .output_path = null,
        .width = 512,
        .height = 512,
        .time = 0.0,
        .embed_bytecode = true,
        .embed_explicit = false,
        .render_frame = false,
        .runtime_path = null,
    };

    const args = [_][]const u8{"shader.pngine"};
    const result = parseArgs(&args, &opts);

    try std.testing.expectEqual(@as(u8, 0), result);
    try std.testing.expectEqualStrings("shader.pngine", opts.input_path);
    try std.testing.expectEqual(@as(u32, 512), opts.width);
    try std.testing.expectEqual(@as(u32, 512), opts.height);
}

test "parseArgs: with output path" {
    var opts = Options{
        .input_path = "",
        .output_path = null,
        .width = 512,
        .height = 512,
        .time = 0.0,
        .embed_bytecode = true,
        .embed_explicit = false,
        .render_frame = false,
        .runtime_path = null,
    };

    const args = [_][]const u8{ "shader.pngine", "-o", "output.png" };
    const result = parseArgs(&args, &opts);

    try std.testing.expectEqual(@as(u8, 0), result);
    try std.testing.expectEqualStrings("shader.pngine", opts.input_path);
    try std.testing.expectEqualStrings("output.png", opts.output_path.?);
}

test "parseArgs: with size" {
    var opts = Options{
        .input_path = "",
        .output_path = null,
        .width = 512,
        .height = 512,
        .time = 0.0,
        .embed_bytecode = true,
        .embed_explicit = false,
        .render_frame = false,
        .runtime_path = null,
    };

    const args = [_][]const u8{ "shader.pngine", "--size", "1920x1080" };
    const result = parseArgs(&args, &opts);

    try std.testing.expectEqual(@as(u8, 0), result);
    try std.testing.expectEqual(@as(u32, 1920), opts.width);
    try std.testing.expectEqual(@as(u32, 1080), opts.height);
}

test "parseArgs: with time" {
    var opts = Options{
        .input_path = "",
        .output_path = null,
        .width = 512,
        .height = 512,
        .time = 0.0,
        .embed_bytecode = true,
        .embed_explicit = false,
        .render_frame = false,
        .runtime_path = null,
    };

    const args = [_][]const u8{ "shader.pngine", "-t", "2.5" };
    const result = parseArgs(&args, &opts);

    try std.testing.expectEqual(@as(u8, 0), result);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), opts.time, 0.001);
}

test "parseArgs: embed flag" {
    var opts = Options{
        .input_path = "",
        .output_path = null,
        .width = 512,
        .height = 512,
        .time = 0.0,
        .embed_bytecode = false,
        .embed_explicit = false,
        .render_frame = false,
        .runtime_path = null,
    };

    const args = [_][]const u8{ "shader.pngine", "--embed" };
    const result = parseArgs(&args, &opts);

    try std.testing.expectEqual(@as(u8, 0), result);
    try std.testing.expect(opts.embed_bytecode);
    try std.testing.expect(opts.embed_explicit);
}

test "parseArgs: no-embed flag" {
    var opts = Options{
        .input_path = "",
        .output_path = null,
        .width = 512,
        .height = 512,
        .time = 0.0,
        .embed_bytecode = true,
        .embed_explicit = false,
        .render_frame = false,
        .runtime_path = null,
    };

    const args = [_][]const u8{ "shader.pngine", "--no-embed" };
    const result = parseArgs(&args, &opts);

    try std.testing.expectEqual(@as(u8, 0), result);
    try std.testing.expect(!opts.embed_bytecode);
    try std.testing.expect(opts.embed_explicit);
}

test "parseArgs: missing input file" {
    var opts = Options{
        .input_path = "",
        .output_path = null,
        .width = 512,
        .height = 512,
        .time = 0.0,
        .embed_bytecode = true,
        .embed_explicit = false,
        .render_frame = false,
        .runtime_path = null,
    };

    const args = [_][]const u8{};
    const result = parseArgs(&args, &opts);

    try std.testing.expectEqual(@as(u8, 1), result);
}

test "parseArgs: invalid size format" {
    var opts = Options{
        .input_path = "",
        .output_path = null,
        .width = 512,
        .height = 512,
        .time = 0.0,
        .embed_bytecode = true,
        .embed_explicit = false,
        .render_frame = false,
        .runtime_path = null,
    };

    const args = [_][]const u8{ "shader.pngine", "-s", "invalid" };
    const result = parseArgs(&args, &opts);

    try std.testing.expectEqual(@as(u8, 1), result);
}

test "parseArgs: zero size rejected" {
    var opts = Options{
        .input_path = "",
        .output_path = null,
        .width = 512,
        .height = 512,
        .time = 0.0,
        .embed_bytecode = true,
        .embed_explicit = false,
        .render_frame = false,
        .runtime_path = null,
    };

    const args = [_][]const u8{ "shader.pngine", "-s", "0x512" };
    const result = parseArgs(&args, &opts);

    try std.testing.expectEqual(@as(u8, 1), result);
}

test "parseArgs: help returns 255" {
    var opts = Options{
        .input_path = "",
        .output_path = null,
        .width = 512,
        .height = 512,
        .time = 0.0,
        .embed_bytecode = true,
        .embed_explicit = false,
        .render_frame = false,
        .runtime_path = null,
    };

    const args = [_][]const u8{"--help"};
    const result = parseArgs(&args, &opts);

    try std.testing.expectEqual(@as(u8, 255), result);
}

test "parseArgs: unknown option rejected" {
    var opts = Options{
        .input_path = "",
        .output_path = null,
        .width = 512,
        .height = 512,
        .time = 0.0,
        .embed_bytecode = true,
        .embed_explicit = false,
        .render_frame = false,
        .runtime_path = null,
    };

    const args = [_][]const u8{ "shader.pngine", "--unknown" };
    const result = parseArgs(&args, &opts);

    try std.testing.expectEqual(@as(u8, 1), result);
}

test "parseArgs: multiple input files rejected" {
    var opts = Options{
        .input_path = "",
        .output_path = null,
        .width = 512,
        .height = 512,
        .time = 0.0,
        .embed_bytecode = true,
        .embed_explicit = false,
        .render_frame = false,
        .runtime_path = null,
    };

    const args = [_][]const u8{ "shader1.pngine", "shader2.pngine" };
    const result = parseArgs(&args, &opts);

    try std.testing.expectEqual(@as(u8, 1), result);
}

test "parseArgs: frame flag" {
    var opts = Options{
        .input_path = "",
        .output_path = null,
        .width = 512,
        .height = 512,
        .time = 0.0,
        .embed_bytecode = true,
        .embed_explicit = false,
        .render_frame = false,
        .runtime_path = null,
    };

    const args = [_][]const u8{ "shader.pngine", "--frame" };
    const result = parseArgs(&args, &opts);

    try std.testing.expectEqual(@as(u8, 0), result);
    try std.testing.expect(opts.render_frame);
}

test "parseArgs: frame flag short" {
    var opts = Options{
        .input_path = "",
        .output_path = null,
        .width = 512,
        .height = 512,
        .time = 0.0,
        .embed_bytecode = true,
        .embed_explicit = false,
        .render_frame = false,
        .runtime_path = null,
    };

    const args = [_][]const u8{ "shader.pngine", "-f" };
    const result = parseArgs(&args, &opts);

    try std.testing.expectEqual(@as(u8, 0), result);
    try std.testing.expect(opts.render_frame);
}

test "parseArgs: frame with size" {
    var opts = Options{
        .input_path = "",
        .output_path = null,
        .width = 512,
        .height = 512,
        .time = 0.0,
        .embed_bytecode = true,
        .embed_explicit = false,
        .render_frame = false,
        .runtime_path = null,
    };

    const args = [_][]const u8{ "shader.pngine", "--frame", "-s", "1920x1080" };
    const result = parseArgs(&args, &opts);

    try std.testing.expectEqual(@as(u8, 0), result);
    try std.testing.expect(opts.render_frame);
    try std.testing.expectEqual(@as(u32, 1920), opts.width);
    try std.testing.expectEqual(@as(u32, 1080), opts.height);
}

test "parseArgs: embed-runtime flag" {
    var opts = Options{
        .input_path = "",
        .output_path = null,
        .width = 512,
        .height = 512,
        .time = 0.0,
        .embed_bytecode = true,
        .embed_explicit = false,
        .render_frame = false,
        .runtime_path = null,
    };

    const args = [_][]const u8{ "shader.pngine", "--embed-runtime", "pngine.wasm" };
    const result = parseArgs(&args, &opts);

    try std.testing.expectEqual(@as(u8, 0), result);
    try std.testing.expectEqualStrings("pngine.wasm", opts.runtime_path.?);
}

test "deriveOutputPath: handles OOM gracefully" {
    var fail_index: usize = 0;
    while (fail_index < 10) : (fail_index += 1) {
        var failing_alloc = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });

        const result = deriveOutputPath(failing_alloc.allocator(), "test.pngine");

        if (failing_alloc.has_induced_failure) {
            try std.testing.expectError(error.OutOfMemory, result);
        } else {
            const path = try result;
            failing_alloc.allocator().free(path);
            break;
        }
    }
}
