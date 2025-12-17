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
    return executePipeline(allocator, opts.input_path, output, opts.width, opts.height, opts.time, opts.embed_bytecode, opts.render_frame);
}

/// Parse render command arguments.
///
/// Returns 255 if help was requested, >0 on error, 0 on success.
fn parseArgs(args: []const []const u8, opts: *Options) u8 {
    // Pre-conditions
    std.debug.assert(opts.width == 512);

    var input_path: ?[]const u8 = null;
    var i: u32 = 0;
    const args_len: u32 = @intCast(args.len);

    while (i < args_len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: -o requires an output path\n", .{});
                return 1;
            }
            i += 1;
            opts.output_path = args[i];
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--size")) {
            const result = parseSize(args, &i, args_len, opts);
            if (result != 0) return result;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--time")) {
            const result = parseTime(args, &i, args_len, opts);
            if (result != 0) return result;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--frame")) {
            opts.render_frame = true;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--embed")) {
            opts.embed_bytecode = true;
            opts.embed_explicit = true;
        } else if (std.mem.eql(u8, arg, "--no-embed")) {
            opts.embed_bytecode = false;
            opts.embed_explicit = true;
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

/// Parse --size WxH argument.
fn parseSize(args: []const []const u8, i: *u32, args_len: u32, opts: *Options) u8 {
    if (i.* + 1 >= args_len) {
        std.debug.print("Error: -s requires dimensions (e.g., 512x512)\n", .{});
        return 1;
    }
    i.* += 1;
    const size_str = args[i.*];

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

/// Parse --time value argument.
fn parseTime(args: []const []const u8, i: *u32, args_len: u32, opts: *Options) u8 {
    if (i.* + 1 >= args_len) {
        std.debug.print("Error: -t requires a time value (e.g., 2.5)\n", .{});
        return 1;
    }
    i.* += 1;
    opts.time = std.fmt.parseFloat(f32, args[i.*]) catch {
        std.debug.print("Error: invalid time value '{s}'\n", .{args[i.*]});
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
) !u8 {
    // Pre-conditions
    std.debug.assert(input.len > 0);
    std.debug.assert(output.len > 0);

    // Read and compile source
    const source = readSourceFile(allocator, input) catch |err| {
        std.debug.print("Error: failed to read '{s}': {}\n", .{ input, err });
        return 2;
    };
    defer allocator.free(source);

    const bytecode = compileSource(allocator, input, source) catch |err| {
        std.debug.print("Error: compilation failed: {}\n", .{err});
        return 3;
    };
    defer allocator.free(bytecode);

    if (bytecode.len < format.HEADER_SIZE or !std.mem.eql(u8, bytecode[0..4], format.MAGIC)) {
        std.debug.print("Error: compilation produced invalid bytecode\n", .{});
        return 3;
    }

    // Choose pixel generation strategy
    var png_data: []u8 = undefined;
    var actual_width: u32 = undefined;
    var actual_height: u32 = undefined;

    if (render_frame) {
        // Full GPU rendering path
        const result = renderWithGpu(allocator, bytecode, width, height, time);
        if (result.exit_code != 0) return result.exit_code;
        png_data = result.png_data;
        actual_width = width;
        actual_height = height;
    } else {
        // 1x1 transparent pixel - minimal PNG container for bytecode
        png_data = createTransparentPixel(allocator) catch |err| {
            std.debug.print("Error: failed to create PNG: {}\n", .{err});
            return 4;
        };
        actual_width = 1;
        actual_height = 1;
    }
    defer allocator.free(png_data);

    if (embed_bytecode) {
        const embedded = pngine.png.embedBytecode(allocator, png_data, bytecode) catch |err| {
            std.debug.print("Error: failed to embed bytecode: {}\n", .{err});
            return 4;
        };
        allocator.free(png_data);
        png_data = embedded;
    }

    writeOutputFile(output, png_data) catch |err| {
        std.debug.print("Error: failed to write '{s}': {}\n", .{ output, err });
        return 2;
    };

    // Success message
    if (render_frame) {
        if (embed_bytecode) {
            std.debug.print("Rendered {s} -> {s} ({d}x{d}, t={d:.2}, embedded, {d} bytes)\n", .{
                input, output, actual_width, actual_height, time, png_data.len,
            });
        } else {
            std.debug.print("Rendered {s} -> {s} ({d}x{d}, t={d:.2}, {d} bytes)\n", .{
                input, output, actual_width, actual_height, time, png_data.len,
            });
        }
    } else {
        std.debug.print("Created {s} -> {s} (1x1, bytecode embedded, {d} bytes)\n", .{
            input, output, png_data.len,
        });
    }

    return 0;
}

/// Render bytecode using GPU and return PNG data.
const RenderResult = struct {
    png_data: []u8,
    exit_code: u8,
};

fn renderWithGpu(allocator: std.mem.Allocator, bytecode: []const u8, width: u32, height: u32, time: f32) RenderResult {
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

    var dispatcher = pngine.Dispatcher(NativeGPU).init(&gpu, &module);
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
        \\  -o, --output <path>    Output PNG path (default: <input>.png)
        \\  -f, --frame            Render actual frame via GPU (default: 1x1 transparent)
        \\  -s, --size <WxH>       Output dimensions when using --frame (default: 512x512)
        \\  -t, --time <seconds>   Time value for animation (default: 0.0)
        \\  -e, --embed            Embed bytecode in output PNG (default: on)
        \\  --no-embed             Do not embed bytecode
        \\  -h, --help             Show this help
        \\
        \\Examples:
        \\  pngine shader.pngine                      # 1x1 transparent PNG with bytecode (~500 bytes)
        \\  pngine shader.pngine --frame              # Render 512x512 preview with bytecode
        \\  pngine shader.pngine --frame -s 1920x1080 # Render at 1080p
        \\  pngine shader.pngine --frame -t 2.5       # Render frame at t=2.5 seconds
        \\  pngine shader.pngine --no-embed           # 1x1 PNG without bytecode
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
        return pngine.dsl.compile(allocator, source);
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
    };

    const args = [_][]const u8{ "shader.pngine", "--frame", "-s", "1920x1080" };
    const result = parseArgs(&args, &opts);

    try std.testing.expectEqual(@as(u8, 0), result);
    try std.testing.expect(opts.render_frame);
    try std.testing.expectEqual(@as(u32, 1920), opts.width);
    try std.testing.expectEqual(@as(u32, 1080), opts.height);
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
