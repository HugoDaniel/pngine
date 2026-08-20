//! Render command: compile and embed PNGine shader in PNG image.
//!
//! ## Usage
//! ```
//! pngine shader.sjon -o output.png             # Self-contained PNG with executor
//! pngine shader.sjon --frame --size 512x512    # Render actual frame at 512x512
//! pngine shader.sjon --no-executor             # PNG without embedded executor
//! ```
//!
//! ## Design
//! By default, output is a 1x1 transparent pixel PNG with embedded bytecode
//! AND a tailored WASM executor. This creates a self-contained executable
//! image that can run in any browser without external dependencies.
//! Use --frame to render an actual preview image at the specified size.
//! Use --no-executor for dev builds that use a shared pngine.wasm file.
//!
//! ## Invariants
//! - Input must be valid .sjon source
//! - Output is always a valid PNG file
//! - Embedded bytecode + executor creates self-contained executable images

const std = @import("std");
const pngine = @import("pngine");
const format = pngine.format;
const types_gen = @import("types_gen.zig");
const flat = @import("flat.zig");
const js_codegen = @import("js_codegen.zig");
const utils = @import("utils.zig");
const stdio = @import("stdio.zig");
const arg_reader = @import("arg_reader.zig");
const test_utils = @import("../test_utils.zig");

const build_options = @import("build_options");

// Build-time embedded WASM runtime
const embedded_wasm: []const u8 = if (build_options.has_embedded_wasm) @embedFile("embedded_wasm") else "";

// Build-time embedded executor variants (all targets, WASM is target-independent)
const embedded_executors = if (build_options.has_embedded_wasm) struct {
    const core: []const u8 = @embedFile("executor_core");
    const render: []const u8 = @embedFile("executor_render");
    const compute: []const u8 = @embedFile("executor_compute");
    const render_compute: []const u8 = @embedFile("executor_render-compute");
    const render_anim: []const u8 = @embedFile("executor_render-anim");
    const render_compute_anim: []const u8 = @embedFile("executor_render-compute-anim");
    const render_wasm: []const u8 = @embedFile("executor_render-wasm");
    const full: []const u8 = @embedFile("executor_full");

    fn get(name: []const u8) ?[]const u8 {
        const map = std.StaticStringMap([]const u8).initComptime(.{
            .{ "core", core },
            .{ "render", render },
            .{ "compute", compute },
            .{ "render-compute", render_compute },
            .{ "render-anim", render_anim },
            .{ "render-compute-anim", render_compute_anim },
            .{ "render-wasm", render_wasm },
            .{ "full", full },
        });
        return map.get(name);
    }
} else struct {
    fn get(_: []const u8) ?[]const u8 {
        return null;
    }
};

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
    /// true to embed WASM executor in bytecode payload (default: true for self-contained PNGs)
    embed_executor: bool,
    /// Optional scene/frame name to render (null = render all frames)
    scene_name: ?[]const u8,
    /// true to generate TypeScript type definitions (.d.ts file)
    generate_types: bool = false,
    /// true to minify WGSL shaders for smaller payload
    minify_shaders: bool = false,
    /// R3: the CLI validates WGSL shaders by default; --no-validate opts out
    validate_shaders: bool = true,
    /// Optional path to audio WASM file (e.g., sointu compiled song) to embed as pNGa chunk
    audio_path: ?[]const u8 = null,
    /// Optional path to audio JS file (WebAudio API code defining s() function)
    audio_js_path: ?[]const u8 = null,
    /// true to produce flat command buffer (pNGf) instead of WASM executor
    flat_mode: bool = false,
    /// true to produce self-contained HTML file
    html_mode: bool = false,
    /// true to use fullscreen canvas with devicePixelRatio scaling (HTML mode only)
    fullscreen: bool = true,
    /// true to output unpacked HTML (no deflate compression, larger but debuggable)
    unpack: bool = false,
    /// Arc-3 §1.2: treat an unimplemented native opcode reached during --frame as
    /// a failure (exit 9) instead of a silent no-op. Off for normal renders (which
    /// still warn-once); the render-coverage gate sets it to reclassify OK→stub.
    strict_native_stubs: bool = false,
};

/// Execute the render command.
///
/// Pre-condition: args is the slice after "render" command.
/// Post-condition: Returns exit code (0 = success).
pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
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
        .embed_executor = true, // Embed executor by default for self-contained PNG
        .scene_name = null, // Render all frames by default
        .generate_types = false, // Don't generate TypeScript type definitions by default
        .minify_shaders = false,
    };

    const parse_result = parseArgs(args, &opts);
    if (parse_result == 255) return 0; // Help was shown
    if (parse_result != 0) return parse_result;

    // Pre-condition: valid options after parsing
    std.debug.assert(opts.input_path.len > 0);
    std.debug.assert(opts.width > 0 and opts.height > 0);

    // Derive output path if not specified. Piped source has no name to derive
    // from, so it goes to stdout rather than a file called `-.png`.
    const dest: stdio.Output = if (opts.output_path) |p|
        .borrowed(p)
    else if (stdio.isStd(opts.input_path))
        .borrowed(stdio.std_path)
    else
        .owned(deriveOutputPath(allocator, opts.input_path) catch |err| {
            std.debug.print("Error: failed to derive output path: {}\n", .{err});
            return 2;
        });
    defer dest.deinit(allocator);
    const output = dest.path;

    // `--types` names its sidecar after the output file, so there is nowhere to
    // put it when the output is a stream. Reject here, before any compiling or
    // rendering: the pipeline writes the artifact before it reaches the types
    // step, so refusing down there means stdout already carries a complete PNG
    // by the time we exit non-zero — a consumer left holding a valid-looking
    // file and a failure at once.
    if (opts.generate_types and stdio.isStd(output)) {
        std.debug.print("Error: --types needs a named output file (-o <path>); it cannot accompany stdout\n", .{});
        return 1;
    }

    // Execute render pipeline
    return executePipeline(allocator, io, opts, output);
}

/// A flag whose whole effect is setting boolean fields.
///
/// `render` has fourteen of these, and written as `else if` arms they are
/// fourteen near-identical three-line blocks — the shape where a copy-paste
/// assigns the neighbouring field and nothing looks wrong. As a table the
/// flag→field mapping is one readable column, which is also what makes the
/// pairs auditable: `--embed`/`--no-embed` both stamp `embed_explicit`, and
/// `--html` implies `--flat`.
const BoolFlag = struct {
    names: []const []const u8,
    sets: []const Set,

    const Set = struct { field: []const u8, value: bool };
};

const bool_flags = [_]BoolFlag{
    .{ .names = &.{ "-f", "--frame" }, .sets = &.{.{ .field = "render_frame", .value = true }} },
    .{ .names = &.{ "-e", "--embed" }, .sets = &.{
        .{ .field = "embed_bytecode", .value = true },
        .{ .field = "embed_explicit", .value = true },
    } },
    .{ .names = &.{"--no-embed"}, .sets = &.{
        .{ .field = "embed_bytecode", .value = false },
        .{ .field = "embed_explicit", .value = true },
    } },
    .{ .names = &.{"--no-executor"}, .sets = &.{.{ .field = "embed_executor", .value = false }} },
    .{ .names = &.{ "-m", "--minify" }, .sets = &.{.{ .field = "minify_shaders", .value = true }} },
    .{ .names = &.{"--validate"}, .sets = &.{.{ .field = "validate_shaders", .value = true }} },
    .{ .names = &.{"--no-validate"}, .sets = &.{.{ .field = "validate_shaders", .value = false }} },
    .{ .names = &.{"--types"}, .sets = &.{.{ .field = "generate_types", .value = true }} },
    .{ .names = &.{"--flat"}, .sets = &.{.{ .field = "flat_mode", .value = true }} },
    // HTML implies flat: the codegen consumes the same flattened call log.
    .{ .names = &.{"--html"}, .sets = &.{
        .{ .field = "html_mode", .value = true },
        .{ .field = "flat_mode", .value = true },
    } },
    .{ .names = &.{"--fullscreen"}, .sets = &.{.{ .field = "fullscreen", .value = true }} },
    .{ .names = &.{ "--no-fullscreen", "--fixed" }, .sets = &.{.{ .field = "fullscreen", .value = false }} },
    .{ .names = &.{"--unpack"}, .sets = &.{.{ .field = "unpack", .value = true }} },
    .{ .names = &.{"--strict-native-stubs"}, .sets = &.{.{ .field = "strict_native_stubs", .value = true }} },
};

/// Apply `arg` if it is one of the boolean flags; false means "not mine".
fn applyBoolFlag(arg: []const u8, opts: *Options) bool {
    std.debug.assert(arg.len > 0);
    inline for (bool_flags) |flag| {
        for (flag.names) |name| {
            if (std.mem.eql(u8, arg, name)) {
                inline for (flag.sets) |s| @field(opts, s.field) = s.value;
                return true;
            }
        }
    }
    return false;
}

/// Parse render command arguments.
///
/// Returns 255 if help was requested, >0 on error, 0 on success.
fn parseArgs(args: []const []const u8, opts: *Options) u8 {
    // Pre-conditions
    std.debug.assert(opts.width == 512);

    var reader = arg_reader.ArgReader.init(args);
    while (reader.next()) |arg| {
        if (applyBoolFlag(arg, opts)) {
            continue;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            opts.output_path = reader.value() catch return arg_reader.missingValue(arg);
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--size")) {
            const size_str = reader.value() catch return arg_reader.missingValue(arg);
            const result = parseSizeValue(size_str, opts);
            if (result != 0) return result;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--time")) {
            const time_str = reader.value() catch return arg_reader.missingValue(arg);
            const result = parseTimeValue(time_str, opts);
            if (result != 0) return result;
        } else if (std.mem.eql(u8, arg, "--audio") or std.mem.eql(u8, arg, "-a")) {
            opts.audio_path = reader.value() catch return arg_reader.missingValue(arg);
        } else if (std.mem.eql(u8, arg, "--audio-js")) {
            opts.audio_js_path = reader.value() catch return arg_reader.missingValue(arg);
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--scene")) {
            opts.scene_name = reader.value() catch return arg_reader.missingValue(arg);
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return 255;
        } else if (arg_reader.ArgReader.isFlag(arg)) {
            return arg_reader.unknownOption(arg);
        } else {
            reader.addPositional(arg) catch return arg_reader.duplicateInput();
        }
    }

    if (reader.positional == null) {
        std.debug.print("Error: no input file specified\n\n", .{});
        printUsage();
        return 1;
    }

    opts.input_path = reader.positional.?;

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
    io: std.Io,
    opts: Options,
    output: []const u8,
) !u8 {
    // Pre-conditions
    std.debug.assert(opts.input_path.len > 0);
    std.debug.assert(output.len > 0);

    // Read and compile source (with plugin detection if embedding executor)
    var plugins: ?pngine.PluginSet = null;
    const bytecode = compileForRender(allocator, io, opts, &plugins) catch |compile_err| {
        return handleCompileError(compile_err, opts.input_path);
    };
    defer allocator.free(bytecode);

    if (bytecode.len < format.HEADER_SIZE or !std.mem.eql(u8, bytecode[0..4], format.MAGIC)) {
        std.debug.print("Error: compilation produced invalid bytecode\n", .{});
        return 3;
    }

    // Optionally embed executor WASM in bytecode (creates v5 format)
    const embedded = embedExecutorIfRequested(allocator, io, bytecode, opts, plugins);
    if (embedded.exit_code != 0) return embedded.exit_code;
    const final_bytecode = embedded.bytes;
    const executor_embedded = embedded.owned;
    defer if (executor_embedded) allocator.free(final_bytecode);

    // HTML mode: JS codegen with raw WGSL strings (no base64 for shaders in pack mode)
    if (opts.html_mode) {
        return executeHtmlCodegen(allocator, io, output, opts.width, opts.height, bytecode, opts.audio_path, opts.audio_js_path, opts.fullscreen, opts.unpack);
    }

    // Flat mode: flatten bytecode into pNGf format
    if (opts.flat_mode) {
        return executeFlatPipeline(allocator, io, opts.input_path, output, opts.width, opts.height, bytecode, opts.audio_path);
    }

    // Render (or stub) the PNG and attach the pNGb chunk.
    const png_result = producePng(allocator, final_bytecode, opts);
    if (png_result.exit_code != 0) return png_result.exit_code;
    var png_data = png_result.png_data;
    defer allocator.free(png_data);

    // Optionally embed audio WASM in PNG (pNGa chunk)
    if (opts.audio_path) |apath| {
        const audio_code = attachAudio(allocator, io, &png_data, apath);
        if (audio_code != 0) return audio_code;
    }

    // Write final output. PNG bytes are binary, so a bare terminal is refused.
    stdio.writeOutput(io, output, png_data, true) catch |err| return stdio.reportWriteError(err, output);

    if (opts.generate_types) {
        const types_code = writeTypesSidecar(allocator, io, output, final_bytecode);
        if (types_code != 0) return types_code;
    }

    // Report success to user
    printSuccessMessage(opts.input_path, output, png_data.len, opts.width, opts.height, opts.time, opts.embed_bytecode, opts.render_frame, executor_embedded);
    return 0;
}

/// The bytecode to ship, and whether it is a second allocation.
///
/// `owned` is the caller's free obligation: false means `bytes` aliases the
/// compiler's buffer, which is already on a `defer`, so freeing it here would
/// be the double free.
const FinalBytecode = struct {
    bytes: []u8,
    owned: bool,
    exit_code: u8 = 0,
};

/// Splice the executor WASM into the payload when asked and a plugin set was
/// detected — the two conditions together, since the variant to embed is
/// chosen from the plugins.
fn embedExecutorIfRequested(
    allocator: std.mem.Allocator,
    io: std.Io,
    bytecode: []u8,
    opts: Options,
    plugins: ?pngine.PluginSet,
) FinalBytecode {
    std.debug.assert(bytecode.len >= format.HEADER_SIZE);

    if (!opts.embed_executor) return .{ .bytes = bytecode, .owned = false };
    const p = plugins orelse return .{ .bytes = bytecode, .owned = false };

    const with_executor = embedExecutorInBytecode(allocator, io, bytecode, p) catch |err| {
        std.debug.print("Error: failed to embed executor: {}\n", .{err});
        return .{ .bytes = bytecode, .owned = false, .exit_code = 4 };
    };
    std.debug.assert(with_executor.len >= bytecode.len);
    return .{ .bytes = with_executor, .owned = true };
}

/// Produce the PNG bytes: a rendered frame or the 1x1 transparent stub, with
/// the pNGb chunk attached unless `--no-embed`.
fn producePng(allocator: std.mem.Allocator, final_bytecode: []const u8, opts: Options) PngResult {
    std.debug.assert(final_bytecode.len >= format.HEADER_SIZE);
    std.debug.assert(opts.width > 0 and opts.height > 0);

    const rendered = generatePng(allocator, final_bytecode, opts.width, opts.height, opts.time, opts.render_frame, opts.scene_name, opts.strict_native_stubs);
    if (rendered.exit_code != 0) return rendered;
    if (!opts.embed_bytecode) return rendered;

    const with_bytecode = embedBytecodeInPng(allocator, rendered.png_data, final_bytecode) catch |err| {
        std.debug.print("Error: failed to embed bytecode: {}\n", .{err});
        allocator.free(rendered.png_data);
        return .{ .png_data = undefined, .exit_code = 4 };
    };
    return .{ .png_data = with_bytecode, .exit_code = 0 };
}

/// Compile the render input, capturing the plugin set when one is detected.
///
/// Plugin detection is only run when the executor is going to be embedded —
/// that is the only consumer of the set, and detecting costs a second pass.
fn compileForRender(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: Options,
    plugins: *?pngine.PluginSet,
) ![]u8 {
    std.debug.assert(opts.input_path.len > 0);
    std.debug.assert(plugins.* == null);

    if (!opts.embed_executor) {
        return compileFromFile(allocator, io, opts.input_path, opts.minify_shaders, opts.validate_shaders);
    }
    const result = try compileFromFileWithPlugins(allocator, io, opts.input_path, opts.minify_shaders, opts.validate_shaders);
    plugins.* = result.plugins;
    return result.pngb;
}

/// Re-wrap `png_data` with a pNGa audio chunk. Returns 0, or an exit code
/// after printing its own message.
fn attachAudio(allocator: std.mem.Allocator, io: std.Io, png_data: *[]u8, audio_path: []const u8) u8 {
    std.debug.assert(png_data.*.len > 0);
    std.debug.assert(audio_path.len > 0);

    const audio_wasm = utils.readBinaryFile(allocator, io, audio_path) catch |err| {
        std.debug.print("Error: failed to read audio '{s}': {}\n", .{ audio_path, err });
        return 2;
    };
    defer allocator.free(audio_wasm);

    const with_audio = pngine.png.embedAudio(allocator, png_data.*, audio_wasm) catch |err| {
        std.debug.print("Error: failed to embed audio: {}\n", .{err});
        return 4;
    };
    allocator.free(png_data.*);
    png_data.* = with_audio;

    std.debug.print("  Audio: {s} ({d} bytes)\n", .{ audio_path, audio_wasm.len });
    return 0;
}

/// Write the `--types` TypeScript sidecar beside `output`. Returns 0, or an
/// exit code after printing its own message.
fn writeTypesSidecar(allocator: std.mem.Allocator, io: std.Io, output: []const u8, bytecode: []const u8) u8 {
    // `run` has already rejected `--types` with a stream destination, so
    // `output` is a real path to hang the sidecar off.
    std.debug.assert(!stdio.isStd(output));
    std.debug.assert(bytecode.len > 0);

    const types_path = types_gen.deriveTypesPath(allocator, output) catch |err| {
        std.debug.print("Error: failed to derive types path: {}\n", .{err});
        return 5;
    };
    defer allocator.free(types_path);

    const types_content = types_gen.generateFromBytecode(allocator, bytecode) catch |err| {
        std.debug.print("Error: failed to generate TypeScript types: {}\n", .{err});
        return 5;
    };
    defer allocator.free(types_content);

    types_gen.writeToFile(io, types_path, types_content) catch |err| {
        std.debug.print("Error: failed to write '{s}': {}\n", .{ types_path, err });
        return 5;
    };

    std.debug.print("Generated: {s}\n", .{types_path});
    return 0;
}

/// Execute HTML codegen pipeline: compile → MockGPU → emit JS directly.
fn executeHtmlCodegen(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: []const u8,
    width: u32,
    height: u32,
    bytecode: []const u8,
    audio_path: ?[]const u8,
    audio_js_path: ?[]const u8,
    fullscreen: bool,
    unpack: bool,
) !u8 {
    // Read audio WASM if present
    var audio_wasm_data: ?[]const u8 = null;
    if (audio_path) |apath| {
        audio_wasm_data = utils.readBinaryFile(allocator, io, apath) catch |err| {
            std.debug.print("Error: failed to read audio '{s}': {}\n", .{ apath, err });
            return 2;
        };
    }
    defer if (audio_wasm_data) |awd| allocator.free(awd);

    // Read audio JS if present
    var audio_js_data: ?[]const u8 = null;
    if (audio_js_path) |jpath| {
        audio_js_data = utils.readBinaryFile(allocator, io, jpath) catch |err| {
            std.debug.print("Error: failed to read audio JS '{s}': {}\n", .{ jpath, err });
            return 2;
        };
    }
    defer if (audio_js_data) |ajd| allocator.free(ajd);

    var diag: js_codegen.Diag = .{};
    var codegen_result = js_codegen.generate(allocator, bytecode, width, height, audio_wasm_data, audio_js_data, fullscreen, !unpack, &diag) catch |err| {
        if (err == error.UnsupportedByHtml) {
            const cmd = if (diag.unsupported) |ct| @tagName(ct) else "unknown";
            // A command this codegen cannot emit at all, versus one it emits
            // fine in the wrong place: same refusal, different remedy, so the
            // positional case says where (the call log has no source spans, so
            // its index is the only locator there is).
            if (diag.unsupported_feature) |feature| {
                std.debug.print(
                    "Error: cannot export a single-file (--html) player — {s} ('{s}', captured call #{d}).\n" ++
                        "  Re-export without --html: the default viewer runtime plays every command.\n",
                    .{ feature, cmd, diag.unsupported_index orelse 0 },
                );
            } else {
                std.debug.print(
                    "Error: cannot export a single-file (--html) player — command '{s}' is not emitted by the HTML codegen.\n" ++
                        "  Re-export without --html: the default viewer runtime plays every command.\n",
                    .{cmd},
                );
            }
        } else {
            std.debug.print("Error: failed to generate HTML: {}\n", .{err});
        }
        return 4;
    };
    defer codegen_result.deinit(allocator);

    // Write HTML. Text, so `--html -o -` may go to a terminal — piping a page
    // into a browser or a static-site build is a reasonable thing to want.
    stdio.writeOutput(io, output, codegen_result.html, false) catch |err| return stdio.reportWriteError(err, output);

    std.debug.print("Created: {s} ({d} bytes, self-contained HTML)\n", .{ stdio.outName(output), codegen_result.html.len });
    return 0;
}

/// Execute flat pipeline: compile → flatten → embed pNGf.
fn executeFlatPipeline(
    allocator: std.mem.Allocator,
    io: std.Io,
    _: []const u8,
    output: []const u8,
    width: u32,
    height: u32,
    bytecode: []const u8,
    audio_path: ?[]const u8,
) !u8 {
    // Flatten bytecode into pNGf format
    var diag: flat.Diag = .{};
    var flat_payload = flat.flattenPayload(allocator, bytecode, &diag) catch |err| {
        if (err == error.UnsupportedByMini) {
            // A non-command feature (authored device limits, §5.3b) is named
            // directly; otherwise the offending command's tag.
            const what = if (diag.unsupported_feature) |feat| feat else if (diag.unsupported) |ct| @tagName(ct) else "unknown";
            std.debug.print(
                "Error: cannot export a flat (--flat) pNGf — '{s}' is not playable by the minimal runtime.\n" ++
                    "  Re-export without --flat: the default viewer runtime plays every command.\n",
                .{what},
            );
        } else {
            std.debug.print("Error: failed to flatten bytecode: {}\n", .{err});
        }
        return 4;
    };
    defer flat_payload.deinit(allocator);

    // Generate 1x1 transparent pixel PNG (no GPU render → strict-stub flag moot)
    const png_result = generatePng(allocator, bytecode, width, height, 0.0, false, null, false);
    if (png_result.exit_code != 0) return png_result.exit_code;

    // Embed pNGf chunk instead of pNGb. `png_data` is owned from here to the
    // end — one `defer`, tracking the audio swap below, the same shape as
    // `executePipeline`. It used to be freed only on the success path, so a
    // missing audio file, a refused audio chunk or a failed write leaked it.
    var png_data = pngine.png.embedFlat(allocator, png_result.png_data, flat_payload.data) catch |err| {
        std.debug.print("Error: failed to embed flat data: {}\n", .{err});
        allocator.free(png_result.png_data);
        return 4;
    };
    allocator.free(png_result.png_data);
    defer allocator.free(png_data);

    // Optionally embed audio
    if (audio_path) |apath| {
        const audio_wasm = utils.readBinaryFile(allocator, io, apath) catch |err| {
            std.debug.print("Error: failed to read audio '{s}': {}\n", .{ apath, err });
            return 2;
        };
        defer allocator.free(audio_wasm);

        const with_audio = pngine.png.embedAudio(allocator, png_data, audio_wasm) catch |err| {
            std.debug.print("Error: failed to embed audio: {}\n", .{err});
            return 4;
        };
        allocator.free(png_data);
        png_data = with_audio;

        std.debug.print("  Audio: {s} ({d} bytes)\n", .{ apath, audio_wasm.len });
    }

    // Write PNG output
    stdio.writeOutput(io, output, png_data, true) catch |err| return stdio.reportWriteError(err, output);

    std.debug.print("Created: {s} ({d} bytes, flat pNGf format)\n", .{ stdio.outName(output), png_data.len });
    std.debug.print("  pNGf payload: {d} bytes\n", .{flat_payload.data.len});
    return 0;
}

/// Compile source file to bytecode.
fn compileFromFile(allocator: std.mem.Allocator, io: std.Io, input: []const u8, minify_shaders: bool, validate_shaders: bool) ![]u8 {
    const in = try stdio.readInput(allocator, io, input);
    defer in.deinit(allocator);
    if (in.kind != .sjon) return error.UnsupportedFormat;
    return compileSource(allocator, io, input, in.bytes, minify_shaders, validate_shaders);
}

/// Bytecode + detected plugins — the only two fields the render pipeline reads
/// off a plugin-detecting compile (variant name/size are unused here). A small
/// local struct lets the legacy and `.sjon` branches share one return type
/// even though their compilers return distinct `CompileWithPluginsResult` structs.
/// `plugins` is `pngine.PluginSet` (== `bytecode.format.PluginSet`), so it
/// threads straight into `embedExecutorInBytecode`.
const CompiledWithPlugins = struct {
    pngb: []u8,
    plugins: pngine.PluginSet,
};

/// Compile source file and return bytecode with detected plugins.
fn compileFromFileWithPlugins(allocator: std.mem.Allocator, io: std.Io, input: []const u8, minify_shaders: bool, validate_shaders: bool) !CompiledWithPlugins {
    const in = try stdio.readInput(allocator, io, input);
    defer in.deinit(allocator);
    const source = in.bytes;

    const base_dir = stdio.baseDir(input);

    if (in.kind == .sjon) {
        // SJON-backed compiler (PNGine as a SJON host). Plain bytecode + plugins;
        // the executor is embedded afterwards by embedExecutorInBytecode.
        const result = try pngine.dsl_sjon.compileWithPlugins(allocator, source, .{
            .base_dir = base_dir,
            .minify_shaders = minify_shaders,
            .validate_shaders = validate_shaders,
            .io = io,
        });
        return .{ .pngb = result.pngb, .plugins = result.plugins };
    }

    // Only `.sjon` produces a plugin-detecting compile for the self-contained
    // (executor-embedding) path. The legacy `.pngine` macro DSL and `.pbsf`
    // assembler frontends were retired.
    return error.UnsupportedFormat;
}

/// Embed executor WASM in bytecode, creating v5 format.
///
/// Loads the appropriate pre-built executor based on detected plugins,
/// then re-serializes the bytecode with the executor embedded.
fn embedExecutorInBytecode(allocator: std.mem.Allocator, io: std.Io, bytecode: []const u8, plugins: pngine.PluginSet) ![]u8 {
    // Pre-conditions
    std.debug.assert(bytecode.len >= format.HEADER_SIZE);
    std.debug.assert(std.mem.eql(u8, bytecode[0..4], format.MAGIC));

    // Determine executor variant name based on plugins (canonical selection
    // logic lives in executor/variant.zig — no hand-transcribed ladder here).
    const variant_name = pngine.variant.selectVariant(plugins).name;

    // Load executor WASM: try embedded variant first, then filesystem, then embedded fallback
    const executor_wasm, const executor_is_embedded = blk: {
        // Best case: exact variant embedded at compile time
        if (embedded_executors.get(variant_name)) |wasm| {
            break :blk .{ wasm, true };
        }
        // Try filesystem (development builds, custom executor dirs)
        if (loadExecutorWasm(allocator, io, variant_name)) |wasm| {
            break :blk .{ wasm, false };
        } else |_| {}
        // Last resort: generic embedded WASM
        if (embedded_wasm.len > 0) {
            break :blk .{ embedded_wasm, true };
        }
        std.debug.print("Error: no executor available (no variant '{s}' embedded or on disk)\n", .{variant_name});
        std.debug.print("Hint: Run 'zig build executors' to build executor variants\n", .{});
        return error.FileNotFound;
    };
    defer if (!executor_is_embedded) allocator.free(executor_wasm);

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
            // Preserve the authored device-limits table (§5.3b) — without this the
            // executor-embedded payload (what every PNG ships, and what the
            // browser viewer parses for requiredLimits) would silently drop it.
            .limits = &module.limits,
        },
    ) catch |err| {
        std.debug.print("Error: failed to serialize with executor: {}\n", .{err});
        return err;
    };

    // Post-condition: result is v5 format with executor
    std.debug.assert(result.len > bytecode.len);

    return result;
}

/// Load executor WASM from filesystem (fallback when not embedded).
///
/// Looks for pre-built executors in:
/// 1. zig-out/executors/pngine-{variant}.wasm relative to CWD (development)
/// 2. ../wasm/pngine.wasm relative to binary (npm package)
/// 3. ../../pngine/wasm/pngine.wasm relative to binary (pnpm/hoisted)
fn loadExecutorWasm(allocator: std.mem.Allocator, io: std.Io, variant_name: []const u8) ![]u8 {
    // Pre-condition
    std.debug.assert(variant_name.len > 0);

    // Try development path: zig-out/executors/pngine-{variant}.wasm (relative to CWD)
    var path_buf: [256]u8 = undefined;
    const dev_path = std.fmt.bufPrint(&path_buf, "zig-out/executors/pngine-{s}.wasm", .{variant_name}) catch {
        return error.InvalidFormat;
    };

    const cwd = std.Io.Dir.cwd();

    if (utils.readFileFromDir(allocator, io, cwd, dev_path)) |buf| return buf else |_| {}

    // Try paths relative to the binary location (npm package layout)
    if (std.process.executableDirPath(io, &path_buf)) |len| {
        if (loadExecutorFromNpmPaths(allocator, io, cwd, path_buf[0..len])) |buf| return buf else |_| {}
    } else |_| {}

    return error.FileNotFound;
}

/// Search npm package layouts for pngine.wasm relative to a binary directory.
///
/// npm layout:   node_modules/@pngine/darwin-arm64/bin/pngine
///               node_modules/pngine/wasm/pngine.wasm
///               → bin_dir/../wasm/pngine.wasm (co-located)
///               → bin_dir/../../pngine/wasm/pngine.wasm (sibling package)
fn loadExecutorFromNpmPaths(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, bin_dir: []const u8) ![]u8 {
    std.debug.assert(bin_dir.len > 0);

    var search_buf: [512]u8 = undefined;

    const npm_suffixes = [_][]const u8{
        "/../wasm/pngine.wasm",
        "/../../pngine/wasm/pngine.wasm",
    };

    for (npm_suffixes) |suffix| {
        if (bin_dir.len + suffix.len < search_buf.len) {
            @memcpy(search_buf[0..bin_dir.len], bin_dir);
            @memcpy(search_buf[bin_dir.len..][0..suffix.len], suffix);
            const full_path = search_buf[0 .. bin_dir.len + suffix.len];
            if (utils.readFileFromDir(allocator, io, cwd, full_path)) |buf| return buf else |_| {}
        }
    }

    return error.FileNotFound;
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
    strict_native_stubs: bool,
) PngResult {
    if (render_frame) {
        return renderWithGpu(allocator, bytecode, width, height, time, scene_name, strict_native_stubs);
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

    const flags_str = if (flags_len > 0) flags_buf[0..flags_len] else "image only";

    if (render_frame) {
        std.debug.print("Rendered {s} -> {s} ({d}x{d}, t={d:.2}, {s}, {d} bytes)\n", .{
            stdio.displayName(input), stdio.outName(output), width, height, time, flags_str, size,
        });
    } else {
        std.debug.print("Created {s} -> {s} (1x1, {s}, {d} bytes)\n", .{ stdio.displayName(input), stdio.outName(output), flags_str, size });
    }
}

/// Render a bytecode frame to a PNG via the native GPU backend.
///
/// Real pixels require a build with `-Dgpu-native` — the default on a macOS host
/// with the vendored wgpu-native lib. GPU-less builds (every `zig build npm`
/// cross binary, or any host build with `-Dgpu-native=false`) hard-error here
/// with a rebuild hint instead of emitting a placeholder, so `--frame` output is
/// always either a genuine render or an explicit failure — never a fake.
fn renderWithGpu(allocator: std.mem.Allocator, bytecode: []const u8, width: u32, height: u32, time: f32, scene_name: ?[]const u8, strict_native_stubs: bool) PngResult {
    // Pre-conditions
    std.debug.assert(bytecode.len >= format.HEADER_SIZE);
    std.debug.assert(width > 0 and height > 0);

    if (comptime !pngine.gpu_backends.has_wgpu_native) {
        std.debug.print(
            \\Error: --frame needs a native GPU backend that this build lacks.
            \\       Rebuild on a macOS host with the vendored wgpu-native lib:
            \\         scripts/download-wgpu-native.sh && zig build
            \\       (npm-distributed binaries are GPU-less by design.)
            \\
        , .{});
        return .{ .png_data = undefined, .exit_code = 7 };
    }

    return renderWithGpuNative(allocator, bytecode, width, height, time, scene_name, strict_native_stubs);
}

/// The real render path — only reachable (and only analyzed) when
/// `has_wgpu_native` is true, so it may freely use `WgpuNativeGPU`/`Context`.
fn renderWithGpuNative(allocator: std.mem.Allocator, bytecode: []const u8, width: u32, height: u32, time: f32, scene_name: ?[]const u8, strict_native_stubs: bool) PngResult {
    const NativeGPU = pngine.gpu_backends.NativeGPU;
    const Context = pngine.gpu_backends.Context;
    const RequiredLimits = pngine.gpu_backends.RequiredLimits;

    std.debug.assert(bytecode.len >= format.HEADER_SIZE);
    std.debug.assert(width > 0 and height > 0);

    var module = format.deserialize(allocator, bytecode) catch |err| {
        std.debug.print("Error: failed to load bytecode: {}\n", .{err});
        return .{ .png_data = undefined, .exit_code = 3 };
    };
    defer module.deinit(allocator);

    // Shared GPU context (blocks ~100-200ms acquiring adapter + device). Authored
    // device limits (Arc-3 §5.3b) become requestDevice's requiredLimits — the
    // native oracle for what the browser worker also requests. Only build the
    // struct when limits were authored so limit-less renders are unchanged.
    var required_limits: RequiredLimits = undefined;
    const required_limits_ptr: ?*const RequiredLimits = if (module.limits.count() > 0) blk: {
        required_limits = pngine.gpu_backends.buildRequiredLimits(&module);
        break :blk &required_limits;
    } else null;
    var ctx = Context.init(required_limits_ptr) catch |err| {
        std.debug.print("Error: no GPU adapter/device available: {}\n", .{err});
        return .{ .png_data = undefined, .exit_code = 5 };
    };
    defer ctx.deinit();

    // The device now carries an uncaptured-error callback (Arc-3 §1.1). Clear
    // any state from a prior render in this process before doing GPU work.
    pngine.gpu_backends.oracle.reset();
    pngine.gpu_backends.stub.reset(); // Arc-3 §1.2: per-render native-stub flag.

    // surface == null → the backend renders into its offscreen target.
    var gpu = NativeGPU.init(&ctx, null, width, height);
    defer gpu.deinit();

    gpu.setModule(&module);
    gpu.setTime(time);

    var dispatcher = pngine.Dispatcher(NativeGPU).init(allocator, &gpu, &module);
    defer dispatcher.deinit();

    const exec_code = runFrames(&dispatcher, &module, scene_name, allocator);
    if (exec_code != 0) return .{ .png_data = undefined, .exit_code = exec_code };

    const pixels = gpu.read_pixels(allocator) catch |err| {
        std.debug.print("Error: failed to read pixels: {}\n", .{err});
        return .{ .png_data = undefined, .exit_code = 5 };
    };
    defer allocator.free(pixels);

    const honesty = nativeHonestyCode(strict_native_stubs);
    if (honesty != 0) return .{ .png_data = undefined, .exit_code = honesty };

    const png_data = pngine.png.encode(allocator, pixels, width, height) catch |err| {
        std.debug.print("Error: failed to encode PNG: {}\n", .{err});
        return .{ .png_data = undefined, .exit_code = 4 };
    };

    // Post-condition
    std.debug.assert(png_data.len > 0);
    return .{ .png_data = png_data, .exit_code = 0 };
}

/// Run the module's frames: one named scene, or every frame in order.
/// Returns 0, or an exit code after printing its own message.
fn runFrames(
    dispatcher: anytype,
    module: *const format.Module,
    scene_name: ?[]const u8,
    allocator: std.mem.Allocator,
) u8 {
    std.debug.assert(module.bytecode.len > 0);

    if (scene_name) |name| {
        std.debug.assert(name.len > 0);
        return executeFrameByName(dispatcher, module, name, allocator);
    }
    dispatcher.execute_all(allocator) catch |err| {
        std.debug.print("Error: execution failed: {}\n", .{err});
        return 5;
    };
    return 0;
}

/// Whether the frame we just read back is honest ground truth. Returns 0 when
/// it is, or the exit code that says why it is not.
///
/// Must be called *after* `read_pixels`, which submits and polls the device:
/// only then has any GPU validation/OOM error fired its callback.
fn nativeHonestyCode(strict_native_stubs: bool) u8 {
    // Native oracle honesty (Arc-3 §1.1): if an error fired, the pixels are
    // blank/garbage — fail loud rather than write a PNG the snapshot/parity
    // gate would trust as ground truth.
    if (pngine.gpu_backends.oracle.hadError()) {
        std.debug.print("Error: GPU validation error during --frame: {s}\n", .{pngine.gpu_backends.oracle.message()});
        return 8;
    }

    // Native stub honesty (Arc-3 §1.2): in strict mode (the render-coverage gate)
    // a render that only "succeeded" because an unimplemented native opcode
    // no-op'd is a stub, not a real render — fail so coverage.txt records `stub`.
    // The per-op warn-once already fired; normal `--frame` renders keep exit 0.
    if (strict_native_stubs and pngine.gpu_backends.stub.anyHit()) {
        std.debug.print("Error: --frame reached an unimplemented native opcode (strict mode)\n", .{});
        return 9;
    }
    return 0;
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
    dispatcher.scan_pass_definitions() catch |err| {
        std.debug.print("Error: pass scan failed: {}\n", .{err});
        return 5;
    };

    // Execute only the specified frame
    dispatcher.pc = @intCast(frame_range.start);
    const max_iterations: usize = 10000;
    for (0..max_iterations) |_| {
        if (dispatcher.pc >= @as(@TypeOf(dispatcher.pc), @intCast(frame_range.end))) break;
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
            // Length-tolerant reads: a `define_frame` at the very end of a
            // hostile stream has no operands, and the asserting decoder on an
            // empty slice was a Debug panic / ReleaseFast over-read here.
            const frame_id_result = opcodes.decode_varint_safe(bytecode[pc..]);
            if (frame_id_result.len == 0) break;
            pc += frame_id_result.len;
            const name_result = opcodes.decode_varint_safe(bytecode[pc..]);
            if (name_result.len == 0) break;
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
                skip_opcode_params_at(bytecode, &pc, scan_op);
            }
        } else {
            skip_opcode_params_at(bytecode, &pc, op);
        }
    }

    return null;
}

/// Skip opcode parameters (mirrors dispatcher.skip_opcode_params_at).
fn skip_opcode_params_at(bytecode: []const u8, pc: *usize, op: pngine.opcodes.OpCode) void {
    // Delegate to dispatcher's implementation - need a u32 wrapper
    var pc32: u32 = @intCast(pc.*);
    pngine.Dispatcher(pngine.gpu_backends.NativeGPU).skip_opcode_params_at(bytecode, &pc32, op);
    pc.* = pc32;
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
        \\  pngine <input.sjon> [options]
        \\  pngine render <input.sjon> [options]
        \\
        \\Options:
        \\  -o, --output <path>       Output PNG path (default: <input>.png)
        \\  -f, --frame               Render actual frame via GPU (default: 1x1 transparent)
        \\  -s, --size <WxH>          Output dimensions when using --frame (default: 512x512)
        \\  -t, --time <seconds>      Time value for animation (default: 0.0)
        \\  -n, --scene <name>        Render specific scene/frame by name (default: all frames)
        \\  -e, --embed               Embed bytecode in output PNG (default: on)
        \\  --no-embed                Do not embed bytecode
        \\  --no-executor             Do not embed WASM executor (smaller PNG, requires external pngine.wasm)
        \\  -m, --minify              Minify WGSL shaders (~30% smaller shader text after
        \\                            compression; no effect on mesh data)
        \\  --validate                Validate WGSL shaders at compile time (default: on)
        \\  --no-validate             Skip WGSL shader validation (compile even if invalid)
        \\  --html                    Self-contained HTML player from generated WebGPU JS
        \\                            (no WASM executor; wider reach than --flat)
        \\  --fullscreen              Fullscreen canvas with devicePixelRatio scaling (default: on)
        \\  --no-fullscreen, --fixed  Fixed-size canvas using --size dimensions (HTML mode)
        \\  --unpack                  Output unpacked HTML (no deflate, larger but debuggable)
        \\  --flat                    Produce flat pNGf command buffer (no WASM executor)
        \\  -a, --audio <path>        Embed audio WASM (e.g., sointu compiled song)
        \\  --types                   Generate TypeScript type definitions (.d.ts) for uniforms
        \\  -h, --help                Show this help
        \\
        \\By default, output PNG is self-contained with embedded bytecode and WASM executor.
        \\The executor variant is automatically selected based on DSL features used
        \\(render, compute, etc.), creating minimal payloads (~15-20KB).
        \\
        \\Use --no-executor for development builds that use a shared pngine.wasm file.
        \\
        \\Examples:
        \\  pngine shader.sjon                       # Self-contained PNG with executor (~17KB)
        \\  pngine shader.sjon --no-executor         # Smaller PNG, needs pngine.wasm (~2KB)
        \\  pngine shader.sjon --frame               # Render 512x512 preview
        \\  pngine shader.sjon --frame -s 1920x1080  # Render at 1080p
        \\  pngine shader.sjon --frame -t 2.5        # Render at t=2.5 seconds
        \\  pngine shader.sjon --frame -n sceneE     # Render specific scene
        \\  pngine shader.sjon --no-embed            # 1x1 PNG without bytecode
        \\  pngine shader.sjon --types               # Generate shader.d.ts for TypeScript
        \\
    , .{});
}

/// Derive output path: input.sjon -> input.png
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

fn compileSource(allocator: std.mem.Allocator, io: std.Io, path: []const u8, source: [:0]const u8, minify_shaders: bool, validate_shaders: bool) ![]u8 {
    // `-` is source too — its kind came from sniffing, not from a name.
    if (stdio.isSjonPath(path)) {
        // SJON format (PNGine as a SJON host). Bytecode-only path (no executor),
        // reached on --no-executor; the self-contained path uses
        // compileFromFileWithPlugins above.
        const base_dir = stdio.baseDir(path);
        return pngine.dsl_sjon.compileWithOptions(allocator, source, .{
            .base_dir = base_dir,
            .minify_shaders = minify_shaders,
            .validate_shaders = validate_shaders,
            .io = io,
        });
    } else {
        // Legacy `.pngine` and `.pbsf` frontends were retired; only `.sjon`
        // remains.
        return error.UnsupportedFormat;
    }
}

// ============================================================================
// Tests
// ============================================================================

// ============================================================================
// Phase 4 Tests: Executor Embedding
// ============================================================================

// -- The boolean-flag table --------------------------------------------------
//
// `@field` makes a misspelled field name a compile error, so what these cover
// is the half the compiler can't: a flag wired to the wrong *existing* field,
// or to the wrong value. The tests above already pin -f/-e/--no-embed and
// --no-executor individually; these cover the remaining ten and, more usefully,
// the property no per-flag test can state — that a flag touches nothing else.

/// The Options fields the table is allowed to write, and the flag that owns each.
const flag_expectations = [_]struct { flag: []const u8, field: []const u8, value: bool }{
    .{ .flag = "--frame", .field = "render_frame", .value = true },
    .{ .flag = "--embed", .field = "embed_bytecode", .value = true },
    .{ .flag = "--no-embed", .field = "embed_bytecode", .value = false },
    .{ .flag = "--no-executor", .field = "embed_executor", .value = false },
    .{ .flag = "--minify", .field = "minify_shaders", .value = true },
    .{ .flag = "--validate", .field = "validate_shaders", .value = true },
    .{ .flag = "--no-validate", .field = "validate_shaders", .value = false },
    .{ .flag = "--types", .field = "generate_types", .value = true },
    .{ .flag = "--flat", .field = "flat_mode", .value = true },
    .{ .flag = "--html", .field = "html_mode", .value = true },
    .{ .flag = "--fullscreen", .field = "fullscreen", .value = true },
    .{ .flag = "--no-fullscreen", .field = "fullscreen", .value = false },
    .{ .flag = "--fixed", .field = "fullscreen", .value = false },
    .{ .flag = "--unpack", .field = "unpack", .value = true },
    .{ .flag = "--strict-native-stubs", .field = "strict_native_stubs", .value = true },
};

fn defaultOptions() Options {
    return .{
        .input_path = "",
        .output_path = null,
        .width = 512,
        .height = 512,
        .time = 0.0,
        .embed_bytecode = true,
        .embed_explicit = false,
        .render_frame = false,
        .embed_executor = true,
        .scene_name = null,
    };
}
