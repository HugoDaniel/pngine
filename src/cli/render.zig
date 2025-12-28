//! Render command: compile and embed PNGine shader in PNG image.
//!
//! ## Usage
//! ```
//! pngine shader.pngine -o output.png           # PNG with bytecode + WASM runtime
//! pngine shader.pngine --frame --size 512x512  # Render actual frame at 512x512
//! pngine shader.pngine --no-runtime            # PNG without embedded WASM
//! ```
//!
//! ## Design
//! By default, output is a 1x1 transparent pixel PNG with embedded bytecode
//! AND the WASM runtime (pNGb + pNGr chunks). This creates a self-contained
//! executable image that can run in any browser without external dependencies.
//! Use --frame to render an actual preview image at the specified size.
//! Use --no-runtime to create a smaller PNG without the WASM interpreter.
//!
//! ## Invariants
//! - Input must be valid .pngine or .pbsf source
//! - Output is always a valid PNG file
//! - Embedded bytecode (--embed) creates self-contained executable images

const std = @import("std");
const pngine = @import("pngine");
const format = pngine.format;
const types_gen = @import("types_gen.zig");

// Build-time embedded WASM runtime
const embedded_wasm: []const u8 = @embedFile("embedded_wasm");

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
    /// true to embed WASM runtime in PNG (pNGr chunk) - creates self-contained executable
    embed_runtime: bool,
    /// true to embed WASM executor in bytecode payload (v5 format)
    embed_executor: bool,
    /// Optional scene/frame name to render (null = render all frames)
    scene_name: ?[]const u8,
    /// true to generate TypeScript type definitions (.d.ts file)
    generate_types: bool = false,
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
        .embed_bytecode = true, // Embed bytecode by default
        .embed_explicit = false,
        .render_frame = false, // 1x1 transparent pixel by default
        .embed_runtime = true, // Embed WASM runtime by default for self-contained PNG
        .embed_executor = false, // Don't embed executor in bytecode by default
        .scene_name = null, // Render all frames by default
        .generate_types = false, // Don't generate TypeScript types by default
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
    return executePipeline(allocator, opts.input_path, output, opts.width, opts.height, opts.time, opts.embed_bytecode, opts.render_frame, opts.embed_runtime, opts.embed_executor, opts.scene_name, opts.generate_types);
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
        } else if (std.mem.eql(u8, arg, "--no-runtime")) {
            opts.embed_runtime = false;
        } else if (std.mem.eql(u8, arg, "--embed-executor")) {
            opts.embed_executor = true;
        } else if (std.mem.eql(u8, arg, "--types")) {
            opts.generate_types = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--scene")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: -n requires a scene/frame name\n", .{});
                return 1;
            }
            opts.scene_name = args[i + 1];
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
    embed_runtime: bool,
    embed_executor: bool,
    scene_name: ?[]const u8,
    generate_types: bool,
) !u8 {
    // Pre-conditions
    std.debug.assert(input.len > 0);
    std.debug.assert(output.len > 0);

    // Read and compile source (with plugin detection if embedding executor)
    var bytecode: []u8 = undefined;
    var plugins: ?pngine.dsl.PluginSet = null;

    if (embed_executor) {
        var result = compileFromFileWithPlugins(allocator, input) catch |compile_err| {
            return handleCompileError(compile_err, input);
        };
        bytecode = result.pngb;
        plugins = result.plugins;
    } else {
        bytecode = compileFromFile(allocator, input) catch |compile_err| {
            return handleCompileError(compile_err, input);
        };
    }
    defer allocator.free(bytecode);

    if (bytecode.len < format.HEADER_SIZE or !std.mem.eql(u8, bytecode[0..4], format.MAGIC)) {
        std.debug.print("Error: compilation produced invalid bytecode\n", .{});
        return 3;
    }

    // Optionally embed executor WASM in bytecode (creates v5 format)
    var final_bytecode = bytecode;
    var executor_embedded = false;
    if (embed_executor) {
        if (plugins) |p| {
            final_bytecode = embedExecutorInBytecode(allocator, bytecode, p) catch |err| {
                std.debug.print("Error: failed to embed executor: {}\n", .{err});
                return 4;
            };
            executor_embedded = true;
        }
    }
    defer if (executor_embedded) allocator.free(final_bytecode);

    // Generate PNG (either rendered frame or 1x1 transparent pixel)
    const png_result = generatePng(allocator, final_bytecode, width, height, time, render_frame, scene_name);
    if (png_result.exit_code != 0) return png_result.exit_code;

    var png_data = png_result.png_data;
    defer allocator.free(png_data);

    // Optionally embed bytecode in PNG (pNGb chunk)
    if (embed_bytecode) {
        png_data = embedBytecodeInPng(allocator, png_data, final_bytecode) catch |err| {
            std.debug.print("Error: failed to embed bytecode: {}\n", .{err});
            return 4;
        };
    }

    // Optionally embed WASM runtime in PNG (pNGr chunk) using build-time embedded WASM
    if (embed_runtime) {
        if (embedded_wasm.len == 0) {
            std.debug.print("Warning: WASM runtime not available in this build\n", .{});
        } else {
            png_data = embedRuntimeData(allocator, png_data, embedded_wasm) catch |err| {
                std.debug.print("Error: failed to embed runtime: {}\n", .{err});
                return 4;
            };
        }
    }

    // Write final output
    writeOutputFile(output, png_data) catch |err| {
        std.debug.print("Error: failed to write '{s}': {}\n", .{ output, err });
        return 2;
    };

    // Generate TypeScript type definitions if requested
    if (generate_types) {
        const types_path = types_gen.deriveTypesPath(allocator, output) catch |err| {
            std.debug.print("Error: failed to derive types path: {}\n", .{err});
            return 5;
        };
        defer allocator.free(types_path);

        const types_content = types_gen.generateFromBytecode(allocator, final_bytecode) catch |err| {
            std.debug.print("Error: failed to generate TypeScript types: {}\n", .{err});
            return 5;
        };
        defer allocator.free(types_content);

        types_gen.writeToFile(types_path, types_content) catch |err| {
            std.debug.print("Error: failed to write '{s}': {}\n", .{ types_path, err });
            return 5;
        };

        std.debug.print("Generated: {s}\n", .{types_path});
    }

    // Report success to user
    printSuccessMessage(input, output, png_data.len, width, height, time, embed_bytecode, render_frame, embed_runtime and embedded_wasm.len > 0, executor_embedded);
    return 0;
}

/// Compile source file to bytecode.
fn compileFromFile(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const source = try readSourceFile(allocator, input);
    defer allocator.free(source);
    return compileSource(allocator, input, source);
}

/// Compile source file and return bytecode with detected plugins.
fn compileFromFileWithPlugins(allocator: std.mem.Allocator, input: []const u8) !pngine.dsl.Compiler.CompileWithPluginsResult {
    const source = try readSourceFile(allocator, input);
    defer allocator.free(source);

    const base_dir = std.fs.path.dirname(input);
    const miniray_path = findMinirayPath();

    return pngine.dsl.Compiler.compileWithPlugins(allocator, source, .{
        .base_dir = base_dir,
        .miniray_path = miniray_path,
    });
}

/// Embed executor WASM in bytecode, creating v5 format.
///
/// Loads the appropriate pre-built executor based on detected plugins,
/// then re-serializes the bytecode with the executor embedded.
fn embedExecutorInBytecode(allocator: std.mem.Allocator, bytecode: []const u8, plugins: pngine.dsl.PluginSet) ![]u8 {
    // Pre-conditions
    std.debug.assert(bytecode.len >= format.HEADER_SIZE);
    std.debug.assert(std.mem.eql(u8, bytecode[0..4], format.MAGIC));

    // Determine executor variant name based on plugins
    const variant_name = getExecutorVariantName(plugins);

    // Load executor WASM from filesystem
    const executor_wasm = loadExecutorWasm(allocator, variant_name) catch |err| {
        std.debug.print("Error: failed to load executor variant '{s}': {}\n", .{ variant_name, err });
        std.debug.print("Hint: Run 'zig build executors' to build executor variants\n", .{});
        return err;
    };
    defer allocator.free(executor_wasm);

    // Validate WASM magic
    if (executor_wasm.len < 8 or !std.mem.eql(u8, executor_wasm[0..4], &[_]u8{ 0x00, 0x61, 0x73, 0x6d })) {
        std.debug.print("Error: invalid WASM file for executor '{s}'\n", .{variant_name});
        return error.InvalidFormat;
    }

    // Deserialize original bytecode
    var module = format.deserialize(allocator, bytecode) catch |err| {
        std.debug.print("Error: failed to deserialize bytecode: {}\n", .{err});
        return err;
    };
    defer module.deinit(allocator);

    // Re-serialize with executor embedded
    const result = format.serializeWithOptions(
        allocator,
        module.bytecode,
        &module.strings,
        &module.data,
        &module.wgsl,
        &module.uniforms,
        &module.animation,
        .{
            .executor = executor_wasm,
            .plugins = plugins,
        },
    ) catch |err| {
        std.debug.print("Error: failed to serialize with executor: {}\n", .{err});
        return err;
    };

    // Post-condition: result is v5 format with executor
    std.debug.assert(result.len > bytecode.len);

    return result;
}

/// Get executor variant name based on detected plugins.
///
/// Maps plugin combinations to pre-built executor variants.
/// Falls back to "full" if no exact match is found.
fn getExecutorVariantName(plugins: pngine.dsl.PluginSet) []const u8 {
    // Check for exact matches against known variants
    // Order matters: check more specific combinations first

    if (plugins.render and plugins.compute and plugins.wasm and plugins.animation and plugins.texture) {
        return "full";
    }
    if (plugins.render and plugins.compute and plugins.animation and !plugins.wasm and !plugins.texture) {
        return "render-compute-anim";
    }
    if (plugins.render and plugins.animation and !plugins.compute and !plugins.wasm and !plugins.texture) {
        return "render-anim";
    }
    if (plugins.render and plugins.wasm and !plugins.compute and !plugins.animation and !plugins.texture) {
        return "render-wasm";
    }
    if (plugins.render and plugins.compute and !plugins.wasm and !plugins.animation and !plugins.texture) {
        return "render-compute";
    }
    if (plugins.compute and !plugins.render and !plugins.wasm and !plugins.animation and !plugins.texture) {
        return "compute";
    }
    if (plugins.render and !plugins.compute and !plugins.wasm and !plugins.animation and !plugins.texture) {
        return "render";
    }
    if (!plugins.render and !plugins.compute and !plugins.wasm and !plugins.animation and !plugins.texture) {
        return "core";
    }

    // No exact match - fall back to full variant
    return "full";
}

/// Load executor WASM from filesystem.
///
/// Looks for pre-built executors in:
/// 1. zig-out/executors/ (development)
/// 2. Relative to CLI binary location
fn loadExecutorWasm(allocator: std.mem.Allocator, variant_name: []const u8) ![]u8 {
    // Pre-condition
    std.debug.assert(variant_name.len > 0);

    // Try development path first: zig-out/executors/pngine-{variant}.wasm
    var path_buf: [256]u8 = undefined;
    const dev_path = std.fmt.bufPrint(&path_buf, "zig-out/executors/pngine-{s}.wasm", .{variant_name}) catch {
        return error.InvalidFormat;
    };

    const file = std.fs.cwd().openFile(dev_path, .{}) catch |err| {
        // Try alternate paths if development path doesn't exist
        if (err == error.FileNotFound) {
            // Could add more search paths here (e.g., relative to binary)
            return error.FileNotFound;
        }
        return err;
    };
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

    // Post-condition
    std.debug.assert(buffer.len == size);
    return buffer;
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
    scene_name: ?[]const u8,
) PngResult {
    if (render_frame) {
        return renderWithGpu(allocator, bytecode, width, height, time, scene_name);
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

/// Embed WASM runtime data in PNG, freeing original PNG data.
fn embedRuntimeData(allocator: std.mem.Allocator, png_data: []u8, runtime: []const u8) ![]u8 {
    // Pre-condition: runtime is valid WASM
    std.debug.assert(runtime.len >= 8);
    std.debug.assert(std.mem.eql(u8, runtime[0..4], &[_]u8{ 0x00, 0x61, 0x73, 0x6d })); // WASM magic

    const original_len = png_data.len;

    // Embed runtime in PNG (pNGr chunk)
    const embedded = pngine.png.embedRuntime(allocator, png_data, runtime) catch |err| {
        std.debug.print("Error: failed to embed runtime: {}\n", .{err});
        return err;
    };
    allocator.free(png_data);

    // Post-condition: result is larger
    std.debug.assert(embedded.len > original_len);

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
    executor_embedded: bool,
) void {
    // Build flags string
    var flags_buf: [64]u8 = undefined;
    var flags_len: usize = 0;

    if (embed_bytecode) {
        const text = "bytecode";
        @memcpy(flags_buf[flags_len..][0..text.len], text);
        flags_len += text.len;
    }
    if (executor_embedded) {
        if (flags_len > 0) {
            flags_buf[flags_len] = '+';
            flags_len += 1;
        }
        const text = "executor";
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
fn renderWithGpu(allocator: std.mem.Allocator, bytecode: []const u8, width: u32, height: u32, time: f32, scene_name: ?[]const u8) PngResult {
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
    defer dispatcher.deinit();

    if (scene_name) |name| {
        // Execute specific scene/frame by name
        const exec_result = executeFrameByName(&dispatcher, &module, name, allocator);
        if (exec_result != 0) {
            return .{ .png_data = undefined, .exit_code = exec_result };
        }
    } else {
        // Execute all frames
        dispatcher.executeAll(allocator) catch |err| {
            std.debug.print("Error: execution failed: {}\n", .{err});
            return .{ .png_data = undefined, .exit_code = 5 };
        };
    }

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

/// Execute a specific frame by name.
/// Returns 0 on success, error code on failure.
fn executeFrameByName(dispatcher: anytype, module: *const format.Module, name: []const u8, allocator: std.mem.Allocator) u8 {
    const opcodes = pngine.opcodes;

    // Find string ID for the name
    var target_string_id: ?u16 = null;
    for (0..module.strings.count()) |i| {
        const str = module.strings.get(@enumFromInt(@as(u16, @intCast(i))));
        if (std.mem.eql(u8, str, name)) {
            target_string_id = @intCast(i);
            break;
        }
    }

    const string_id = target_string_id orelse {
        std.debug.print("Error: scene '{s}' not found in module\n", .{name});
        return 6;
    };

    // Scan bytecode to find frame with this name
    const frame_range = scanForFrameByNameId(module.bytecode, string_id) orelse {
        std.debug.print("Error: frame definition for '{s}' not found\n", .{name});
        return 6;
    };

    // Scan for pass definitions before executing - exec_pass needs pass_ranges
    dispatcher.scanPassDefinitions();

    // Execute only the specified frame
    dispatcher.pc = frame_range.start;
    const max_iterations: usize = 10000;
    for (0..max_iterations) |_| {
        if (dispatcher.pc >= frame_range.end) break;
        dispatcher.step(allocator) catch |err| {
            std.debug.print("Error: execution failed: {}\n", .{err});
            return 5;
        };
    }

    _ = opcodes; // Used in scanForFrameByNameId
    return 0;
}

const FrameRange = struct {
    start: usize,
    end: usize,
};

/// Scan bytecode to find frame definition by name string ID.
fn scanForFrameByNameId(bytecode: []const u8, target_name_id: u16) ?FrameRange {
    const opcodes = pngine.opcodes;
    const OpCode = opcodes.OpCode;
    var pc: usize = 0;
    const max_scan: usize = 10000;

    for (0..max_scan) |_| {
        if (pc >= bytecode.len) break;

        const op: OpCode = @enumFromInt(bytecode[pc]);
        pc += 1;

        if (op == .define_frame) {
            const frame_id_result = opcodes.decodeVarint(bytecode[pc..]);
            pc += frame_id_result.len;
            const name_result = opcodes.decodeVarint(bytecode[pc..]);
            pc += name_result.len;

            // Scan for end_frame to find frame boundaries
            const frame_start = pc;
            for (0..max_scan) |_| {
                if (pc >= bytecode.len) break;
                const scan_op: OpCode = @enumFromInt(bytecode[pc]);
                if (scan_op == .end_frame) {
                    if (name_result.value == target_name_id) {
                        // This is the frame we're looking for
                        return .{ .start = frame_start, .end = pc + 1 }; // Include end_frame
                    }
                    // Skip past end_frame for the outer loop
                    pc += 1;
                    break;
                }
                pc += 1;
                skipOpcodeParamsAt(bytecode, &pc, scan_op);
            }
        } else {
            skipOpcodeParamsAt(bytecode, &pc, op);
        }
    }

    return null;
}

/// Skip opcode parameters (mirrors dispatcher.skipOpcodeParamsAt).
fn skipOpcodeParamsAt(bytecode: []const u8, pc: *usize, op: pngine.opcodes.OpCode) void {
    // Delegate to dispatcher's implementation
    pngine.Dispatcher(pngine.gpu_backends.NativeGPU).skipOpcodeParamsAt(bytecode, pc, op);
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
        \\  -n, --scene <name>        Render specific scene/frame by name (default: all frames)
        \\  -e, --embed               Embed bytecode in output PNG (default: on)
        \\  --no-embed                Do not embed bytecode
        \\  --no-runtime              Do not embed WASM runtime (smaller PNG, requires external pngine.wasm)
        \\  --embed-executor          Embed minimal WASM executor in bytecode (v5 format)
        \\  --types                   Generate TypeScript type definitions (.d.ts) for uniforms
        \\  -h, --help                Show this help
        \\
        \\By default, output PNG includes both bytecode (pNGb) and WASM runtime (pNGr),
        \\creating a self-contained executable image (~30KB). Use --no-runtime to create
        \\a smaller PNG (~500 bytes) that requires an external pngine.wasm file.
        \\
        \\The --embed-executor option embeds a minimal WASM executor directly in the
        \\bytecode payload. The executor variant is automatically selected based on
        \\which DSL features are used (render, compute, etc.). This creates a fully
        \\self-contained payload that doesn't require any external runtime.
        \\
        \\Examples:
        \\  pngine shader.pngine                       # Self-contained PNG with runtime (~30KB)
        \\  pngine shader.pngine --no-runtime          # Smaller PNG, needs external WASM (~500 bytes)
        \\  pngine shader.pngine --embed-executor      # Embed minimal executor in bytecode
        \\  pngine shader.pngine --frame               # Render 512x512 preview with runtime
        \\  pngine shader.pngine --frame -s 1920x1080  # Render at 1080p
        \\  pngine shader.pngine --frame -t 2.5        # Render at t=2.5 seconds
        \\  pngine shader.pngine --frame -n sceneE     # Render specific scene
        \\  pngine shader.pngine --no-embed            # 1x1 PNG without bytecode
        \\  pngine shader.pngine --types               # Generate shader.d.ts for TypeScript
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
        const miniray_path = findMinirayPath();
        return pngine.dsl.compileWithOptions(allocator, source, .{
            .base_dir = base_dir,
            .miniray_path = miniray_path,
        });
    }
}

/// Find miniray binary for WGSL reflection.
fn findMinirayPath() ?[]const u8 {
    // Check environment variable
    if (std.posix.getenv("PNGINE_MINIRAY_PATH")) |path| {
        if (path.len > 0) return path;
    }

    // Check common development paths
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
        .embed_runtime = true,
        .embed_executor = false,
        .scene_name = null,
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
        .embed_runtime = true,
        .embed_executor = false,
        .scene_name = null,
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
        .embed_runtime = true,
        .embed_executor = false,
        .scene_name = null,
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
        .embed_runtime = true,
        .embed_executor = false,
        .scene_name = null,
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
        .embed_runtime = true,
        .embed_executor = false,
        .scene_name = null,
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
        .embed_runtime = true,
        .embed_executor = false,
        .scene_name = null,
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
        .embed_runtime = true,
        .embed_executor = false,
        .scene_name = null,
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
        .embed_runtime = true,
        .embed_executor = false,
        .scene_name = null,
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
        .embed_runtime = true,
        .embed_executor = false,
        .scene_name = null,
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
        .embed_runtime = true,
        .embed_executor = false,
        .scene_name = null,
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
        .embed_runtime = true,
        .embed_executor = false,
        .scene_name = null,
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
        .embed_runtime = true,
        .embed_executor = false,
        .scene_name = null,
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
        .embed_runtime = true,
        .embed_executor = false,
        .scene_name = null,
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
        .embed_runtime = true,
        .embed_executor = false,
        .scene_name = null,
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
        .embed_runtime = true,
        .embed_executor = false,
        .scene_name = null,
    };

    const args = [_][]const u8{ "shader.pngine", "--frame", "-s", "1920x1080" };
    const result = parseArgs(&args, &opts);

    try std.testing.expectEqual(@as(u8, 0), result);
    try std.testing.expect(opts.render_frame);
    try std.testing.expectEqual(@as(u32, 1920), opts.width);
    try std.testing.expectEqual(@as(u32, 1080), opts.height);
}

test "parseArgs: no-runtime flag" {
    var opts = Options{
        .input_path = "",
        .output_path = null,
        .width = 512,
        .height = 512,
        .time = 0.0,
        .embed_bytecode = true,
        .embed_explicit = false,
        .render_frame = false,
        .embed_runtime = true,
        .embed_executor = false,
        .scene_name = null,
    };

    const args = [_][]const u8{ "shader.pngine", "--no-runtime" };
    const result = parseArgs(&args, &opts);

    try std.testing.expectEqual(@as(u8, 0), result);
    try std.testing.expect(!opts.embed_runtime);
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

// ============================================================================
// Phase 4 Tests: Executor Embedding
// ============================================================================

test "parseArgs: embed-executor flag" {
    var opts = Options{
        .input_path = "",
        .output_path = null,
        .width = 512,
        .height = 512,
        .time = 0.0,
        .embed_bytecode = true,
        .embed_explicit = false,
        .render_frame = false,
        .embed_runtime = true,
        .embed_executor = false,
        .scene_name = null,
    };

    const args = [_][]const u8{ "shader.pngine", "--embed-executor" };
    const result = parseArgs(&args, &opts);

    try std.testing.expectEqual(@as(u8, 0), result);
    try std.testing.expect(opts.embed_executor);
}

test "parseArgs: embed-executor combined with other flags" {
    var opts = Options{
        .input_path = "",
        .output_path = null,
        .width = 512,
        .height = 512,
        .time = 0.0,
        .embed_bytecode = true,
        .embed_explicit = false,
        .render_frame = false,
        .embed_runtime = true,
        .embed_executor = false,
        .scene_name = null,
    };

    const args = [_][]const u8{ "shader.pngine", "--embed-executor", "--no-runtime", "-o", "out.png" };
    const result = parseArgs(&args, &opts);

    try std.testing.expectEqual(@as(u8, 0), result);
    try std.testing.expect(opts.embed_executor);
    try std.testing.expect(!opts.embed_runtime);
    try std.testing.expectEqualStrings("out.png", opts.output_path.?);
}

test "getExecutorVariantName: core only (no plugins)" {
    const plugins = pngine.dsl.PluginSet{
        .core = true,
        .render = false,
        .compute = false,
        .wasm = false,
        .animation = false,
        .texture = false,
    };
    try std.testing.expectEqualStrings("core", getExecutorVariantName(plugins));
}

test "getExecutorVariantName: render only" {
    const plugins = pngine.dsl.PluginSet{
        .core = true,
        .render = true,
        .compute = false,
        .wasm = false,
        .animation = false,
        .texture = false,
    };
    try std.testing.expectEqualStrings("render", getExecutorVariantName(plugins));
}

test "getExecutorVariantName: compute only" {
    const plugins = pngine.dsl.PluginSet{
        .core = true,
        .render = false,
        .compute = true,
        .wasm = false,
        .animation = false,
        .texture = false,
    };
    try std.testing.expectEqualStrings("compute", getExecutorVariantName(plugins));
}

test "getExecutorVariantName: render-compute" {
    const plugins = pngine.dsl.PluginSet{
        .core = true,
        .render = true,
        .compute = true,
        .wasm = false,
        .animation = false,
        .texture = false,
    };
    try std.testing.expectEqualStrings("render-compute", getExecutorVariantName(plugins));
}

test "getExecutorVariantName: render-anim" {
    const plugins = pngine.dsl.PluginSet{
        .core = true,
        .render = true,
        .compute = false,
        .wasm = false,
        .animation = true,
        .texture = false,
    };
    try std.testing.expectEqualStrings("render-anim", getExecutorVariantName(plugins));
}

test "getExecutorVariantName: render-compute-anim" {
    const plugins = pngine.dsl.PluginSet{
        .core = true,
        .render = true,
        .compute = true,
        .wasm = false,
        .animation = true,
        .texture = false,
    };
    try std.testing.expectEqualStrings("render-compute-anim", getExecutorVariantName(plugins));
}

test "getExecutorVariantName: render-wasm" {
    const plugins = pngine.dsl.PluginSet{
        .core = true,
        .render = true,
        .compute = false,
        .wasm = true,
        .animation = false,
        .texture = false,
    };
    try std.testing.expectEqualStrings("render-wasm", getExecutorVariantName(plugins));
}

test "getExecutorVariantName: full (all plugins)" {
    const plugins = pngine.dsl.PluginSet{
        .core = true,
        .render = true,
        .compute = true,
        .wasm = true,
        .animation = true,
        .texture = true,
    };
    try std.testing.expectEqualStrings("full", getExecutorVariantName(plugins));
}

test "getExecutorVariantName: unknown combination falls back to full" {
    // Texture only - not a pre-built variant
    const plugins = pngine.dsl.PluginSet{
        .core = true,
        .render = false,
        .compute = false,
        .wasm = false,
        .animation = false,
        .texture = true,
    };
    try std.testing.expectEqualStrings("full", getExecutorVariantName(plugins));
}

test "getExecutorVariantName: deterministic for same input" {
    // Property: same plugins always produce same variant name
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();

    for (0..100) |_| {
        const plugins = pngine.dsl.PluginSet{
            .core = true,
            .render = random.boolean(),
            .compute = random.boolean(),
            .wasm = random.boolean(),
            .animation = random.boolean(),
            .texture = random.boolean(),
        };

        const name1 = getExecutorVariantName(plugins);
        const name2 = getExecutorVariantName(plugins);

        try std.testing.expectEqualStrings(name1, name2);
    }
}

test "getExecutorVariantName: result is always a valid variant name" {
    // Property: result is always one of the known variants
    const valid_names = [_][]const u8{
        "core",
        "render",
        "compute",
        "render-compute",
        "render-anim",
        "render-compute-anim",
        "render-wasm",
        "full",
    };

    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();

    for (0..100) |_| {
        const plugins = pngine.dsl.PluginSet{
            .core = true,
            .render = random.boolean(),
            .compute = random.boolean(),
            .wasm = random.boolean(),
            .animation = random.boolean(),
            .texture = random.boolean(),
        };

        const name = getExecutorVariantName(plugins);

        var found = false;
        for (valid_names) |valid| {
            if (std.mem.eql(u8, name, valid)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "loadExecutorWasm: returns error for missing file" {
    // Property: missing executor file returns FileNotFound
    const result = loadExecutorWasm(std.testing.allocator, "nonexistent-variant");
    try std.testing.expectError(error.FileNotFound, result);
}
