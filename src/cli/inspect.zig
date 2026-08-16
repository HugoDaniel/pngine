//! Inspect command: bytecode-level inspection via MockGPU and optional WAMR deep analysis.
//!
//! ## Usage
//! ```
//! pngine inspect shader.sjon                       # MockGPU summary (default)
//! pngine inspect shader.sjon --verbose             # Full GPU call trace
//! pngine inspect shader.sjon --deep --json         # WAMR deep analysis with JSON
//! pngine inspect shader.sjon --symptom black       # Diagnose symptom (auto-enables deep)
//! ```
//!
//! ## Design
//! Default mode runs MockGPU dispatch for a fast summary of GPU calls, entry points,
//! and buffer usage. Deep mode (--deep or auto-enabled by --json, --symptom, --phase,
//! --frames, --extract-wgsl) uses WAMR for full runtime validation with state machine
//! analysis. `--json` always emits the structured deep report to stdout.
//!
//! ## Module Organization
//!
//! - `inspect/types.zig` - Shared types (Options, ValidationResult, etc.)
//! - `inspect/args.zig` - CLI argument parsing (deep mode flags)
//! - `inspect/loader.zig` - Bytecode loading from various formats
//! - `inspect/executor.zig` - WASM execution and validation
//! - `inspect/output.zig` - JSON and human-readable output
//! - `inspect/wamr.zig` - WAMR runtime wrapper
//! - `inspect/cmd_validator.zig` - Command buffer state machine
//! - `inspect/symptom_diagnosis.zig` - Symptom-based diagnosis

const std = @import("std");
const pngine = @import("pngine");
const format = pngine.format;
const mock_gpu = pngine.mock_gpu;
const MockGPU = mock_gpu.MockGPU;
const Call = mock_gpu.Call;
const Dispatcher = pngine.Dispatcher;
const DescriptorEncoder = pngine.DescriptorEncoder;
const utils = @import("utils.zig");
const stdio = @import("stdio.zig");
const arg_reader = @import("arg_reader.zig");

// Deep mode submodules (pub for test access via module import)
pub const types = @import("inspect/types.zig");
const args_mod = @import("inspect/args.zig");
pub const loader = @import("inspect/loader.zig");
pub const executor = @import("inspect/executor.zig");
const output = @import("inspect/output.zig");
pub const wgsl_reflect = @import("inspect/wgsl_reflect.zig");

// Re-export types for external use
pub const Phase = types.Phase;
pub const Symptom = types.Symptom;
pub const DeepOptions = types.Options;
pub const ValidationResult = types.ValidationResult;

/// Execute the inspect command.
///
/// Pre-condition: args is the slice after "inspect" command.
/// Post-condition: Returns exit code (0 = success, non-zero = error).
pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    std.debug.assert(args.len <= 1024);

    // Parse arguments
    var opts = InspectOptions{};
    var deep_opts = DeepOptions.init();

    const parse_result = parseInspectArgs(args, &opts, &deep_opts);
    if (parse_result == 255) return 0; // Help was shown
    if (parse_result != 0) return parse_result;

    if (opts.input.len == 0) {
        std.debug.print("Error: no input file specified\n\n", .{});
        printHelp();
        return 1;
    }

    // Auto-enable deep mode for flags that require WAMR. `--json` is included so
    // the structured report has a single owner (the deep-mode writeReportJson);
    // the fast MockGPU summary is human-only.
    const deep = opts.deep or opts.json_output or deep_opts.symptom != .none or
        deep_opts.phase != .both or deep_opts.extract_wgsl or
        deep_opts.frame_indices.len > 1;

    if (deep) {
        return runDeep(allocator, io, opts, &deep_opts, args);
    }

    return runMockGpu(allocator, io, opts);
}

/// Command options parsed from arguments.
const InspectOptions = struct {
    input: []const u8 = "",
    verbose: bool = false,
    deep: bool = false,
    json_output: bool = false,
    strict: bool = false,
    quiet: bool = false,
};

// ============================================================================
// Default mode: MockGPU inspection (fast)
// ============================================================================

fn runMockGpu(allocator: std.mem.Allocator, io: std.Io, opts: InspectOptions) !u8 {
    // Load or compile bytecode (shared format dispatcher)
    const bytecode = loader.loadBytecode(allocator, io, opts.input) catch |err| {
        return handleLoadError(err, opts.input);
    };
    defer allocator.free(bytecode);

    // Validate and deserialize
    var module = validateAndDeserialize(allocator, bytecode) catch |err| {
        return handleDeserializeError(err);
    };
    defer module.deinit(allocator);

    // Print module info (skip in verbose mode - we'll show call trace instead)
    if (!opts.verbose) {
        printModuleInfo(stdio.displayName(opts.input), &module);
    }

    // Execute with MockGPU to validate bytecode
    var gpu: MockGPU = .empty;
    defer gpu.deinit(allocator);

    var dispatcher = Dispatcher(MockGPU).init(allocator, &gpu, &module);
    defer dispatcher.deinit();
    dispatcher.execute_all(allocator) catch |err| {
        std.debug.print("\nExecution error: {}\n", .{err});
        return 5;
    };

    // Print execution summary and validate
    const calls = gpu.get_calls();

    // Verbose mode: print each GPU call with [GPU] prefix
    if (opts.verbose) {
        printVerboseTrace(calls);
    }

    return printExecutionSummary(calls, &module, gpu.pass_state_violations, opts.verbose, opts.strict);
}

// ============================================================================
// Deep mode: WAMR runtime validation
// ============================================================================

fn runDeep(allocator: std.mem.Allocator, io: std.Io, opts: InspectOptions, deep_opts: *DeepOptions, args: []const []const u8) !u8 {
    // Copy shared flags into deep opts
    deep_opts.input_path = opts.input;
    deep_opts.json_output = opts.json_output;
    deep_opts.verbose = opts.verbose;
    deep_opts.strict = opts.strict;
    deep_opts.quiet = opts.quiet;

    // Parse --frames argument (needs allocator, so done after arg parsing)
    var owned_frame_indices: ?[]u32 = null;
    defer if (owned_frame_indices) |fi| allocator.free(fi);

    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--frames") and i + 1 < args.len) {
            owned_frame_indices = args_mod.parseFrameIndices(allocator, args[i + 1]) catch |err| {
                std.debug.print("Error: invalid --frames format: {s}\n", .{@errorName(err)});
                return 1;
            };
            deep_opts.frame_indices = owned_frame_indices.?;
            break;
        }
    }

    // Pre-condition: valid options after parsing
    std.debug.assert(deep_opts.input_path.len > 0);
    std.debug.assert(deep_opts.width > 0 and deep_opts.height > 0);
    std.debug.assert(deep_opts.frame_indices.len > 0);

    // Load and compile source to bytecode
    const bytecode = loader.loadBytecode(allocator, io, deep_opts.input_path) catch |err| {
        if (deep_opts.json_output) {
            try output.outputJsonError(io, allocator, "compile_error", @errorName(err));
        } else {
            std.debug.print("Error: failed to load '{s}': {s}\n", .{ stdio.displayName(deep_opts.input_path), @errorName(err) });
        }
        return 3;
    };
    defer allocator.free(bytecode);

    // Run validation
    var result = ValidationResult.init();
    defer result.deinit(allocator);

    executor.validateBytecode(allocator, bytecode, &result, deep_opts) catch |err| {
        if (deep_opts.json_output) {
            try output.outputJsonError(io, allocator, "validation_error", @errorName(err));
        } else {
            std.debug.print("Error: validation failed: {s}\n", .{@errorName(err)});
        }
        return 3;
    };

    // Output results
    if (deep_opts.json_output) {
        try output.outputJson(io, allocator, &result, deep_opts);
    } else {
        try output.outputHuman(&result, deep_opts);
    }

    // Return exit code based on result
    if (result.status == .err) return 1;
    if (result.status == .warning and deep_opts.strict) return 1;
    return 0;
}

// ============================================================================
// Argument parsing
// ============================================================================

fn parseInspectArgs(args: []const []const u8, opts: *InspectOptions, deep_opts: *DeepOptions) u8 {
    var reader = arg_reader.ArgReader.init(args);
    while (reader.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return 255;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            opts.verbose = true;
            deep_opts.phase = .both;
        } else if (std.mem.eql(u8, arg, "--deep")) {
            opts.deep = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json_output = true;
        } else if (std.mem.eql(u8, arg, "--strict")) {
            opts.strict = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            opts.quiet = true;
        } else if (std.mem.eql(u8, arg, "--phase")) {
            const phase_str = reader.value() catch return arg_reader.missingValue(arg);
            deep_opts.phase = args_mod.parsePhase(phase_str) orelse {
                std.debug.print("Error: invalid phase '{s}' (use init, frame, or both)\n", .{phase_str});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--frames")) {
            // Value validated here; indices are parsed in runDeep() (needs allocator).
            _ = reader.value() catch return arg_reader.missingValue(arg);
        } else if (std.mem.eql(u8, arg, "--symptom")) {
            const symptom_str = reader.value() catch return arg_reader.missingValue(arg);
            deep_opts.symptom = args_mod.parseSymptom(symptom_str);
        } else if (std.mem.eql(u8, arg, "--time") or std.mem.eql(u8, arg, "-t")) {
            const time_str = reader.value() catch return arg_reader.missingValue(arg);
            deep_opts.time = std.fmt.parseFloat(f32, time_str) catch {
                std.debug.print("Error: invalid time value\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--time-step")) {
            const step_str = reader.value() catch return arg_reader.missingValue(arg);
            deep_opts.time_step = std.fmt.parseFloat(f32, step_str) catch {
                std.debug.print("Error: invalid time-step value\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--size") or std.mem.eql(u8, arg, "-s")) {
            const size_str = reader.value() catch return arg_reader.missingValue(arg);
            const size = args_mod.parseSize(size_str) orelse {
                std.debug.print("Error: invalid size format (use WxH)\n", .{});
                return 1;
            };
            deep_opts.width = size[0];
            deep_opts.height = size[1];
        } else if (std.mem.eql(u8, arg, "--extract-wgsl")) {
            deep_opts.extract_wgsl = true;
        } else if (arg_reader.ArgReader.isFlag(arg)) {
            return arg_reader.unknownOption(arg);
        } else {
            reader.addPositional(arg) catch return arg_reader.duplicateInput();
        }
    }

    if (reader.positional) |p| opts.input = p;
    return 0;
}

// ============================================================================
// Help
// ============================================================================

fn printHelp() void {
    std.debug.print(
        \\PNGine Inspect - Bytecode inspection and runtime analysis
        \\
        \\Usage: pngine inspect <input> [options]
        \\
        \\Default mode (MockGPU):
        \\  -v, --verbose          Full GPU call trace (like browser debug mode)
        \\  --json                 Output JSON
        \\  --strict               Exit code 1 on warnings (for CI)
        \\  -q, --quiet            Only output errors
        \\
        \\Deep mode (WAMR runtime analysis):
        \\  --deep                 Enable WAMR execution (auto-enabled by flags below)
        \\  --phase <phase>        Show specific phase: init, frame, or both
        \\  --frames <list>        Test multiple frames (e.g., 0,1,10,60)
        \\  --symptom <desc>       Focus diagnosis: black, colors, blend, flicker, geometry
        \\  --time, -t <seconds>   Base time for frame 0 (default: 0.0)
        \\  --time-step <seconds>  Time between frames (default: 1/60)
        \\  --size, -s <WxH>       Canvas size (default: 512x512)
        \\  --extract-wgsl         Include WGSL source in output
        \\
        \\  -h, --help             Show this help
        \\
        \\Supported formats: .sjon, .pngb, .png, .zip
        \\
        \\Examples:
        \\  pngine inspect shader.sjon                    # Quick MockGPU summary
        \\  pngine inspect shader.sjon --verbose          # Full GPU call trace
        \\  pngine inspect shader.sjon --deep --json      # WAMR runtime analysis
        \\  pngine inspect shader.sjon --symptom black    # Diagnose black screen
        \\  pngine inspect output.png --frames 0,30,60      # Multi-frame analysis
        \\
    , .{});
}

// ============================================================================
// MockGPU helpers (from check.zig)
// ============================================================================

/// Print verbose GPU call trace (matches gpu.js debug output format).
fn printVerboseTrace(calls: []const Call) void {
    std.debug.assert(calls.len <= 65536);

    var buf: [256]u8 = undefined;
    for (calls) |call| {
        const desc = call.describe(&buf);
        std.debug.print("[GPU] {s}\n", .{desc});
    }
}

fn handleLoadError(err: anyerror, input: []const u8) u8 {
    switch (err) {
        error.FileNotFound, error.AccessDenied, error.FileTooLarge => {
            std.debug.print("Error: failed to read '{s}': {}\n", .{ stdio.displayName(input), err });
            return 2;
        },
        // Input-side rejections (unrecognized stdin, over-cap, bad extension)
        // are not compilation failures and must not be reported as one — the
        // shared renderer names the cause and the accepted formats.
        stdio.Error.UnrecognizedFormat,
        stdio.Error.StdinTooLarge,
        error.UnsupportedFormat,
        => return stdio.reportReadError(err, input),
        else => {
            std.debug.print("Error: compilation failed: {}\n", .{err});
            return 3;
        },
    }
}

fn validateAndDeserialize(allocator: std.mem.Allocator, bytecode: []const u8) !format.Module {
    std.debug.assert(bytecode.len > 0);

    if (bytecode.len < format.HEADER_SIZE) {
        std.debug.print("Error: file too small to be valid PNGB\n", .{});
        return error.InvalidFormat;
    }
    if (!std.mem.eql(u8, bytecode[0..4], format.MAGIC)) {
        std.debug.print("Error: invalid PNGB magic bytes\n", .{});
        return error.InvalidFormat;
    }

    const module = try format.deserialize(allocator, bytecode);
    std.debug.assert(module.bytecode.len > 0);
    return module;
}

fn handleDeserializeError(err: anyerror) u8 {
    if (err == error.InvalidFormat) return 4;
    std.debug.print("Error: failed to deserialize PNGB: {}\n", .{err});
    return 4;
}

fn printModuleInfo(input: []const u8, module: *const format.Module) void {
    std.debug.assert(input.len > 0);
    std.debug.print("PNGB: {s}\n", .{input});
    std.debug.print("  Bytecode:     {d} bytes\n", .{module.bytecode.len});
    std.debug.print("  Strings:      {d} entries\n", .{module.strings.count()});
    std.debug.print("  Data section: {d} entries\n", .{module.data.count()});
}

const CallCounts = struct {
    shader: u32 = 0,
    pipeline: u32 = 0,
    draw: u32 = 0,
    dispatch: u32 = 0,
    texture: u32 = 0,
    sampler: u32 = 0,
    buffer: u32 = 0,
    bind_group: u32 = 0,
};

fn countCallTypes(calls: []const Call) CallCounts {
    var counts: CallCounts = .{};
    for (calls) |call| {
        switch (call.call_type) {
            .create_shader_module => counts.shader += 1,
            .create_render_pipeline, .create_compute_pipeline => counts.pipeline += 1,
            .draw, .draw_indexed => counts.draw += 1,
            .dispatch => counts.dispatch += 1,
            .create_texture => counts.texture += 1,
            .create_sampler => counts.sampler += 1,
            .create_buffer => counts.buffer += 1,
            .create_bind_group => counts.bind_group += 1,
            else => {},
        }
    }
    return counts;
}

fn printCallCounts(counts: CallCounts) void {
    if (counts.shader > 0) std.debug.print("  Shaders:     {d}\n", .{counts.shader});
    if (counts.pipeline > 0) std.debug.print("  Pipelines:   {d}\n", .{counts.pipeline});
    if (counts.buffer > 0) std.debug.print("  Buffers:     {d}\n", .{counts.buffer});
    if (counts.texture > 0) std.debug.print("  Textures:    {d}\n", .{counts.texture});
    if (counts.sampler > 0) std.debug.print("  Samplers:    {d}\n", .{counts.sampler});
    if (counts.bind_group > 0) std.debug.print("  Bind groups: {d}\n", .{counts.bind_group});
    if (counts.draw > 0) std.debug.print("  Draw calls:  {d}\n", .{counts.draw});
    if (counts.dispatch > 0) std.debug.print("  Dispatches:  {d}\n", .{counts.dispatch});
}

fn printExecutionSummary(
    calls: []const Call,
    module: *const format.Module,
    pass_state_violations: u32,
    verbose: bool,
    strict: bool,
) u8 {
    // In verbose mode, print a separator before summary
    // In non-verbose mode, add newline after module info
    if (verbose) {
        std.debug.print("\n--- Summary ---\n", .{});
    } else {
        std.debug.print("\n", .{});
    }

    std.debug.print("Execution OK: {d} GPU calls\n", .{calls.len});

    const counts = countCallTypes(calls);
    printCallCounts(counts);

    // The backend's pass-sequencing verdict. Reported rather than asserted
    // because `inspect` runs arbitrary PNGB — see MockGPU.pass_state_violations.
    // Reaching this at all means the payload issued a draw or setter with no
    // pass open, nested a begin, or left a pass open at submit; the offending
    // calls are in the trace above (`--verbose`), recorded on purpose.
    if (pass_state_violations > 0) {
        std.debug.print("\nWarning: {d} pass-state violation(s) in the bytecode\n", .{pass_state_violations});
        std.debug.print("  A draw/setter outside a pass, a nested begin, or a pass left open\n", .{});
        std.debug.print("  Run with --verbose to see where in the call trace\n", .{});
        if (strict) return 1;
    }

    const desc_errors = validateDescriptors(calls, module);
    if (desc_errors > 0) {
        std.debug.print("\nWarning: {d} invalid descriptor(s) detected\n", .{desc_errors});
        std.debug.print("  These may cause errors in the web runtime\n", .{});
        return if (strict) 1 else 6;
    }

    // Skip detailed reports in verbose mode (trace already shows everything)
    if (!verbose) {
        reportEntryPoints(calls, module);
        reportBufferUsage(calls);
    }

    const bind_group_warnings = validateBindGroupSetup(calls);
    if (bind_group_warnings > 0) {
        std.debug.print("\nWarning: {d} draw call(s) may have missing bind groups\n", .{bind_group_warnings});
        std.debug.print("  Ensure bindGroups=[...] is set in render passes\n", .{});
        if (strict) return 1;
    }

    return 0;
}

fn reportEntryPoints(calls: []const Call, module: *const format.Module) void {
    var reported_any = false;

    for (calls) |call| {
        switch (call.call_type) {
            .create_render_pipeline => {
                const data_id = call.params.create_render_pipeline.descriptor_data_id;
                const data = module.data.get(@enumFromInt(data_id));

                if (findJsonString(data, "\"vertex\"") != null) {
                    if (!reported_any) {
                        std.debug.print("\nEntry points (verify these match shader functions):\n", .{});
                        reported_any = true;
                    }

                    if (findEntryPointForStage(data, "\"vertex\"")) |ep| {
                        const pid = call.params.create_render_pipeline.pipeline_id;
                        std.debug.print("  Pipeline {d} vertex: {s}\n", .{ pid, ep });
                    }
                    if (findEntryPointForStage(data, "\"fragment\"")) |ep| {
                        const pid = call.params.create_render_pipeline.pipeline_id;
                        std.debug.print("  Pipeline {d} fragment: {s}\n", .{ pid, ep });
                    }
                }
            },
            .create_compute_pipeline => {
                const data_id = call.params.create_compute_pipeline.descriptor_data_id;
                const data = module.data.get(@enumFromInt(data_id));

                if (findJsonString(data, "\"compute\"") != null) {
                    if (!reported_any) {
                        std.debug.print("\nEntry points (verify these match shader functions):\n", .{});
                        reported_any = true;
                    }

                    if (findEntryPointForStage(data, "\"compute\"")) |ep| {
                        const pid = call.params.create_compute_pipeline.pipeline_id;
                        std.debug.print("  Pipeline {d} compute: {s}\n", .{ pid, ep });
                    }
                }
            },
            else => {},
        }
    }
}

fn reportBufferUsage(calls: []const Call) void {
    var flags_buf: [128]u8 = undefined;
    var reported_any = false;

    for (calls) |call| {
        if (call.call_type == .create_buffer) {
            if (!reported_any) {
                std.debug.print("\nBuffer usage (verify these match shader bindings):\n", .{});
                reported_any = true;
            }

            const buffer_id = call.params.create_buffer.buffer_id;
            const size = call.params.create_buffer.size;
            const usage: pngine.opcodes.BufferUsage = @bitCast(call.params.create_buffer.usage);

            var flags_len: usize = 0;
            const flags_to_check = [_]struct { flag: bool, name: []const u8 }{
                .{ .flag = usage.uniform, .name = "UNIFORM" },
                .{ .flag = usage.storage, .name = "STORAGE" },
                .{ .flag = usage.vertex, .name = "VERTEX" },
                .{ .flag = usage.index, .name = "INDEX" },
                .{ .flag = usage.copy_src, .name = "COPY_SRC" },
                .{ .flag = usage.copy_dst, .name = "COPY_DST" },
                .{ .flag = usage.map_read, .name = "MAP_READ" },
                .{ .flag = usage.map_write, .name = "MAP_WRITE" },
                .{ .flag = usage.indirect, .name = "INDIRECT" },
            };

            for (flags_to_check) |f| {
                if (f.flag) {
                    if (flags_len > 0) {
                        flags_buf[flags_len] = '|';
                        flags_len += 1;
                    }
                    @memcpy(flags_buf[flags_len..][0..f.name.len], f.name);
                    flags_len += f.name.len;
                }
            }

            const flags_str = if (flags_len > 0) flags_buf[0..flags_len] else "(none)";
            std.debug.print("  Buffer {d}: size={d}, usage={s}\n", .{ buffer_id, size, flags_str });
        }
    }
}

fn findJsonString(data: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, data, needle);
}

fn findEntryPointForStage(data: []const u8, stage_pattern: []const u8) ?[]const u8 {
    const stage_start = std.mem.indexOf(u8, data, stage_pattern) orelse return null;
    const entry_pattern = "\"entryPoint\":\"";
    const ep_start = std.mem.indexOfPos(u8, data, stage_start, entry_pattern) orelse return null;
    const name_start = ep_start + entry_pattern.len;
    if (name_start >= data.len) return null;
    const name_end = std.mem.indexOfPos(u8, data, name_start, "\"") orelse return null;
    return data[name_start..name_end];
}

fn validateDescriptors(calls: []const Call, module: *const format.Module) u32 {
    var error_count: u32 = 0;

    for (calls) |call| {
        switch (call.call_type) {
            .create_texture => {
                const data_id = call.params.create_texture.descriptor_data_id;
                const data = module.data.get(@enumFromInt(data_id));

                if (data.len < 2) {
                    std.debug.print("  Error: texture descriptor too short ({d} bytes)\n", .{data.len});
                    error_count += 1;
                    continue;
                }

                const type_tag = data[0];
                if (type_tag != @intFromEnum(DescriptorEncoder.DescriptorType.texture)) {
                    std.debug.print("  Error: texture descriptor has invalid type tag 0x{X:0>2}\n", .{type_tag});
                    error_count += 1;
                }
            },
            .create_sampler => {
                const data_id = call.params.create_sampler.descriptor_data_id;
                const data = module.data.get(@enumFromInt(data_id));

                if (data.len < 2) {
                    std.debug.print("  Error: sampler descriptor too short ({d} bytes)\n", .{data.len});
                    error_count += 1;
                    continue;
                }

                const type_tag = data[0];
                if (type_tag != @intFromEnum(DescriptorEncoder.DescriptorType.sampler)) {
                    std.debug.print("  Error: sampler descriptor has invalid type tag 0x{X:0>2}\n", .{type_tag});
                    error_count += 1;
                }
            },
            .create_bind_group => {
                const data_id = call.params.create_bind_group.entry_data_id;
                const data = module.data.get(@enumFromInt(data_id));

                if (data.len < 2) {
                    std.debug.print("  Error: bind group descriptor too short ({d} bytes)\n", .{data.len});
                    error_count += 1;
                    continue;
                }

                const type_tag = data[0];
                if (type_tag != @intFromEnum(DescriptorEncoder.DescriptorType.bind_group)) {
                    std.debug.print("  Error: bind group descriptor has invalid type tag 0x{X:0>2}\n", .{type_tag});
                    error_count += 1;
                    continue;
                }

                const field_count = data[1];
                if (field_count < 2) {
                    std.debug.print("  Error: bind group has invalid field count {d} (expected >= 2)\n", .{field_count});
                    error_count += 1;
                }
            },
            else => {},
        }
    }

    return error_count;
}

fn validateBindGroupSetup(calls: []const Call) u32 {
    var warning_count: u32 = 0;
    var in_render_pass = false;
    var pipeline_set = false;
    var bind_group_set = false;

    for (calls) |call| {
        switch (call.call_type) {
            .begin_render_pass => {
                in_render_pass = true;
                pipeline_set = false;
                bind_group_set = false;
            },
            .end_pass => in_render_pass = false,
            .set_pipeline => if (in_render_pass) {
                pipeline_set = true;
            },
            .set_bind_group => if (in_render_pass) {
                bind_group_set = true;
            },
            .draw, .draw_indexed => {
                if (in_render_pass and pipeline_set and !bind_group_set) {
                    warning_count += 1;
                    std.debug.print("  Warning: draw call without set_bind_group\n", .{});
                }
            },
            else => {},
        }
    }

    return warning_count;
}

// ============================================================================
// Tests (reference submodule tests for discovery)
// ============================================================================
