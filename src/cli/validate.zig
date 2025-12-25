//! Validate command: runtime validation via wasm3 command buffer inspection.
//!
//! ## Usage
//! ```
//! pngine validate shader.pngine                    # Human-readable validation
//! pngine validate shader.pngine --json             # JSON output for LLM consumption
//! pngine validate shader.pngine --json --phase init  # Only resource creation
//! pngine validate shader.pngine --json --phase frame # Only first frame commands
//! pngine validate shader.pngine --symptom black    # Diagnose "black screen"
//! ```
//!
//! ## Design
//! Uses wasm3 to execute the WASM executor, captures command buffer output,
//! and validates it for correctness. Provides structured JSON output for
//! LLM-based debugging workflows.
//!
//! ## Invariants
//! - Input must be valid .pngine, .pbsf, .pngb, or .png with embedded bytecode
//! - Output is either human-readable or JSON (--json flag)
//! - wasm3 execution is sandboxed with memory limits

const std = @import("std");
const pngine = @import("pngine");
const format = pngine.format;
const command_buffer = pngine.command_buffer;
const Cmd = command_buffer.Cmd;
const build_options = @import("build_options");
const wasm3 = @import("wasm3.zig");
const Wasm3Runtime = wasm3.Wasm3Runtime;

// Embedded WASM executor (from build)
const embedded_wasm = if (build_options.has_embedded_wasm)
    @embedFile("embedded_wasm")
else
    @as([]const u8, &.{});

/// Maximum input file size (16 MiB).
const max_file_size: u32 = 16 * 1024 * 1024;

/// Validation phase to inspect.
pub const Phase = enum {
    init, // Resource creation only
    frame, // First frame only
    both, // Both init and frame
};

/// Known symptom categories for diagnosis.
pub const Symptom = enum {
    black, // Black screen / nothing renders
    colors, // Wrong colors
    blend, // Blending/transparency issues
    flicker, // Flickering / strobing
    geometry, // Wrong geometry / distortion
    none, // No specific symptom
};

/// Validate command options parsed from CLI arguments.
pub const Options = struct {
    input_path: []const u8,
    json_output: bool,
    verbose: bool,
    phase: Phase,
    symptom: Symptom,
    frames: []const u32, // Frame indices to test
    time: f32,
    time_step: f32,
    width: u32,
    height: u32,
    strict: bool,
    extract_wgsl: bool,
    quiet: bool,
};

/// Validation result for a single command.
pub const CommandInfo = struct {
    index: u32,
    cmd: Cmd,
    // Additional fields will be added as we implement parsing
};

/// Validation error or warning.
pub const ValidationIssue = struct {
    code: []const u8,
    severity: enum { err, warning },
    message: []const u8,
    command_index: ?u32,
};

/// Bytecode module info for output.
pub const ModuleInfo = struct {
    version: u16,
    has_executor: bool,
    executor_size: u32,
    bytecode_size: u32,
    strings_count: u32,
    data_blobs_count: u32,
    wgsl_entries_count: u32,
    uniform_entries_count: u32,
    has_animation: bool,
    scene_count: u32,
};

/// Complete validation result.
pub const ValidationResult = struct {
    status: enum { ok, warning, err },
    init_commands: std.ArrayListUnmanaged(CommandInfo),
    frame_commands: std.ArrayListUnmanaged(CommandInfo),
    errors: std.ArrayListUnmanaged(ValidationIssue),
    warnings: std.ArrayListUnmanaged(ValidationIssue),
    module_info: ?ModuleInfo,

    pub fn init() ValidationResult {
        return .{
            .status = .ok,
            .init_commands = .{},
            .frame_commands = .{},
            .errors = .{},
            .warnings = .{},
            .module_info = null,
        };
    }

    pub fn deinit(self: *ValidationResult, allocator: std.mem.Allocator) void {
        self.init_commands.deinit(allocator);
        self.frame_commands.deinit(allocator);
        self.errors.deinit(allocator);
        self.warnings.deinit(allocator);
    }
};

/// Execute the validate command.
///
/// Pre-condition: args is the slice after "validate" command.
/// Post-condition: Returns exit code (0 = success, 1 = validation errors).
pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    // Parse arguments
    var opts = Options{
        .input_path = "",
        .json_output = false,
        .verbose = false,
        .phase = .both,
        .symptom = .none,
        .frames = &[_]u32{0},
        .time = 0.0,
        .time_step = 0.016,
        .width = 512,
        .height = 512,
        .strict = false,
        .extract_wgsl = false,
        .quiet = false,
    };

    const parse_result = parseArgs(args, &opts);
    if (parse_result == 255) return 0; // Help was shown
    if (parse_result != 0) return parse_result;

    // Pre-condition: valid options after parsing
    std.debug.assert(opts.input_path.len > 0);
    std.debug.assert(opts.width > 0 and opts.height > 0);

    // Load and compile source to bytecode
    const bytecode = loadBytecode(allocator, opts.input_path) catch |err| {
        if (opts.json_output) {
            try outputJsonError(allocator, "compile_error", @errorName(err));
        } else {
            std.debug.print("Error: failed to load '{s}': {s}\n", .{ opts.input_path, @errorName(err) });
        }
        return 3;
    };
    defer allocator.free(bytecode);

    // Run validation
    var result = ValidationResult.init();
    defer result.deinit(allocator);

    // TODO: wasm3 integration - for now, just parse the bytecode header
    validateBytecode(allocator, bytecode, &result, &opts) catch |err| {
        if (opts.json_output) {
            try outputJsonError(allocator, "validation_error", @errorName(err));
        } else {
            std.debug.print("Error: validation failed: {s}\n", .{@errorName(err)});
        }
        return 3;
    };

    // Output results
    if (opts.json_output) {
        try outputJson(allocator, &result, &opts);
    } else {
        try outputHuman(&result, &opts);
    }

    // Return exit code based on result
    if (result.status == .err) return 1;
    if (result.status == .warning and opts.strict) return 1;
    return 0;
}

/// Parse validate command arguments.
///
/// Returns 255 if help was requested, >0 on error, 0 on success.
fn parseArgs(args: []const []const u8, opts: *Options) u8 {
    var input_path: ?[]const u8 = null;
    const args_len: u32 = @intCast(args.len);
    var skip_count: u32 = 0;

    for (0..args_len) |idx| {
        if (skip_count > 0) {
            skip_count -= 1;
            continue;
        }
        const i: u32 = @intCast(idx);
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return 255;
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json_output = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            opts.verbose = true;
            opts.phase = .both;
        } else if (std.mem.eql(u8, arg, "--phase")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: --phase requires a value (init, frame, both)\n", .{});
                return 1;
            }
            const phase_str = args[i + 1];
            opts.phase = parsePhase(phase_str) orelse {
                std.debug.print("Error: invalid phase '{s}' (use init, frame, or both)\n", .{phase_str});
                return 1;
            };
            skip_count = 1;
        } else if (std.mem.eql(u8, arg, "--symptom")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: --symptom requires a value\n", .{});
                return 1;
            }
            opts.symptom = parseSymptom(args[i + 1]);
            skip_count = 1;
        } else if (std.mem.eql(u8, arg, "--time") or std.mem.eql(u8, arg, "-t")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: --time requires a value\n", .{});
                return 1;
            }
            opts.time = std.fmt.parseFloat(f32, args[i + 1]) catch {
                std.debug.print("Error: invalid time value\n", .{});
                return 1;
            };
            skip_count = 1;
        } else if (std.mem.eql(u8, arg, "--size") or std.mem.eql(u8, arg, "-s")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: --size requires WxH\n", .{});
                return 1;
            }
            const size = parseSize(args[i + 1]) orelse {
                std.debug.print("Error: invalid size format (use WxH)\n", .{});
                return 1;
            };
            opts.width = size[0];
            opts.height = size[1];
            skip_count = 1;
        } else if (std.mem.eql(u8, arg, "--strict")) {
            opts.strict = true;
        } else if (std.mem.eql(u8, arg, "--extract-wgsl")) {
            opts.extract_wgsl = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            opts.quiet = true;
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
        printHelp();
        return 1;
    }

    opts.input_path = input_path.?;
    return 0;
}

fn parsePhase(s: []const u8) ?Phase {
    if (std.mem.eql(u8, s, "init")) return .init;
    if (std.mem.eql(u8, s, "frame")) return .frame;
    if (std.mem.eql(u8, s, "both")) return .both;
    return null;
}

fn parseSymptom(s: []const u8) Symptom {
    if (std.mem.eql(u8, s, "black")) return .black;
    if (std.mem.eql(u8, s, "colors")) return .colors;
    if (std.mem.eql(u8, s, "blend")) return .blend;
    if (std.mem.eql(u8, s, "flicker")) return .flicker;
    if (std.mem.eql(u8, s, "geometry")) return .geometry;
    return .none;
}

fn parseSize(s: []const u8) ?[2]u32 {
    const x_pos = std.mem.indexOfAny(u8, s, "xX") orelse return null;
    const width = std.fmt.parseInt(u32, s[0..x_pos], 10) catch return null;
    const height = std.fmt.parseInt(u32, s[x_pos + 1 ..], 10) catch return null;
    if (width == 0 or height == 0) return null;
    return .{ width, height };
}

/// Load bytecode from source file (compiles if needed).
fn loadBytecode(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // Pre-condition: path is non-empty
    std.debug.assert(path.len > 0);

    const extension = std.fs.path.extension(path);

    // For .pngb files, just read directly
    if (std.mem.eql(u8, extension, ".pngb")) {
        return readFile(allocator, path);
    }

    // For .png files, extract embedded bytecode
    if (std.mem.eql(u8, extension, ".png")) {
        const png_data = try readFile(allocator, path);
        defer allocator.free(png_data);

        const extracted = try pngine.png.extract.extract(allocator, png_data);
        return extracted;
    }

    // For .pngine or .pbsf, compile first
    const source = try readFile(allocator, path);
    defer allocator.free(source);

    // Add null terminator for DSL parser
    const source_z = try allocator.alloc(u8, source.len + 1);
    defer allocator.free(source_z);
    @memcpy(source_z[0..source.len], source);
    source_z[source.len] = 0;

    if (std.mem.eql(u8, extension, ".pngine")) {
        // DSL compiler returns bytecode directly
        return try pngine.dsl.Compiler.compile(allocator, source_z[0..source.len :0]);
    } else if (std.mem.eql(u8, extension, ".pbsf")) {
        // Legacy PBSF format
        return try pngine.compile(allocator, source_z[0..source.len :0]);
    }

    return error.UnsupportedFormat;
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const size: u32 = if (stat.size > max_file_size)
        return error.FileTooLarge
    else
        @intCast(stat.size);

    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    // Read file in bounded loop
    var bytes_read: u32 = 0;
    for (0..size + 1) |_| {
        if (bytes_read >= size) break;
        const n: u32 = @intCast(try file.read(buffer[bytes_read..]));
        if (n == 0) break;
        bytes_read += n;
    }

    return buffer;
}

/// Validate bytecode structure and content.
fn validateBytecode(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    result: *ValidationResult,
    opts: *const Options,
) !void {
    // Pre-condition: bytecode has minimum header size
    if (bytecode.len < format.HEADER_SIZE_V4) {
        try result.errors.append(allocator, .{
            .code = "E001",
            .severity = .err,
            .message = "Bytecode too small - missing header",
            .command_index = null,
        });
        result.status = .err;
        return;
    }

    // Verify magic bytes
    if (!std.mem.eql(u8, bytecode[0..4], format.MAGIC)) {
        try result.errors.append(allocator, .{
            .code = "E002",
            .severity = .err,
            .message = "Invalid magic bytes - not a PNGB file",
            .command_index = null,
        });
        result.status = .err;
        return;
    }

    // Read version
    const version = std.mem.readInt(u16, bytecode[4..6], .little);

    // Validate version
    if (version != format.VERSION and version != format.VERSION_V4) {
        try result.errors.append(allocator, .{
            .code = "E003",
            .severity = .err,
            .message = "Unsupported PNGB version",
            .command_index = null,
        });
        result.status = .err;
        return;
    }

    // Deserialize the full module for analysis
    const module = format.deserialize(allocator, bytecode) catch |err| {
        try result.errors.append(allocator, .{
            .code = "E004",
            .severity = .err,
            .message = switch (err) {
                error.InvalidMagic => "Invalid magic bytes",
                error.InvalidFormat => "Invalid bytecode format",
                error.OutOfMemory => "Out of memory during parsing",
                else => "Failed to parse bytecode",
            },
            .command_index = null,
        });
        result.status = .err;
        return;
    };
    defer @constCast(&module).deinit(allocator);

    // Build module info for output
    result.module_info = .{
        .version = version,
        .has_executor = module.hasEmbeddedExecutor(),
        .executor_size = @intCast(module.executor.len),
        .bytecode_size = @intCast(module.bytecode.len),
        .strings_count = @intCast(module.strings.strings.items.len),
        .data_blobs_count = @intCast(module.data.blobs.items.len),
        .wgsl_entries_count = @intCast(module.wgsl.entries.items.len),
        .uniform_entries_count = @intCast(module.uniforms.bindings.items.len),
        .has_animation = module.animation.hasAnimation(),
        .scene_count = if (module.animation.info) |info| @intCast(info.scenes.len) else 0,
    };

    // Validation checks
    if (module.bytecode.len == 0) {
        try result.warnings.append(allocator, .{
            .code = "W001",
            .severity = .warning,
            .message = "Empty bytecode section",
            .command_index = null,
        });
        if (result.status == .ok) result.status = .warning;
    }

    if (module.wgsl.entries.items.len == 0) {
        try result.warnings.append(allocator, .{
            .code = "W002",
            .severity = .warning,
            .message = "No WGSL shaders defined",
            .command_index = null,
        });
        if (result.status == .ok) result.status = .warning;
    }

    // Execute WASM to capture command buffer
    if (Wasm3Runtime.isAvailable() and embedded_wasm.len > 0) {
        executeWasm(allocator, bytecode, result, opts) catch |err| {
            try result.warnings.append(allocator, .{
                .code = "W100",
                .severity = .warning,
                .message = switch (err) {
                    error.InitFailed => "wasm3 init failed",
                    error.ParseFailed => "WASM parse failed",
                    error.LoadFailed => "WASM load failed",
                    error.CompileFailed => "WASM compile failed",
                    error.FunctionNotFound => "WASM function not found",
                    error.CallFailed => "WASM call failed",
                    error.MemoryAccessFailed => "WASM memory access failed",
                    else => "WASM execution failed",
                },
                .command_index = null,
            });
            if (result.status == .ok) result.status = .warning;
        };
    } else if (!opts.quiet and opts.verbose) {
        try result.warnings.append(allocator, .{
            .code = "W100",
            .severity = .warning,
            .message = if (!Wasm3Runtime.isAvailable())
                "wasm3 not available at compile time"
            else
                "no embedded WASM executor",
            .command_index = null,
        });
        if (result.status == .ok) result.status = .warning;
    }
}

/// Execute WASM to capture command buffer output.
fn executeWasm(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    result: *ValidationResult,
    opts: *const Options,
) !void {
    // Initialize wasm3 runtime with 1MB stack
    var runtime = try Wasm3Runtime.init(allocator, 1024 * 1024);
    defer runtime.deinit();

    // Load the embedded WASM executor
    try runtime.loadModule(embedded_wasm);

    // Link host functions (log is optional)
    runtime.linkLogFunction() catch {};

    // Get memory pointers
    const bytecode_ptr = try runtime.callGetPtr("getBytecodePtr");
    const data_ptr = try runtime.callGetPtr("getDataPtr");

    // Write bytecode to WASM memory
    try runtime.writeMemory(bytecode_ptr, bytecode);
    try runtime.callSetLen("setBytecodeLen", @intCast(bytecode.len));

    // Parse bytecode to get data section
    const module = try format.deserialize(allocator, bytecode);
    defer @constCast(&module).deinit(allocator);

    // Write data section to WASM memory
    const data_offset = module.header.data_section_offset;
    const data_end = if (module.header.wgsl_table_offset > 0)
        module.header.wgsl_table_offset
    else
        @as(u32, @intCast(bytecode.len));

    if (data_end > data_offset) {
        const data_section = bytecode[data_offset..data_end];
        try runtime.writeMemory(data_ptr, data_section);
        try runtime.callSetLen("setDataLen", @intCast(data_section.len));
    }

    // Execute init phase
    if (opts.phase == .init or opts.phase == .both) {
        const init_result = try runtime.callInit();
        if (init_result != 0) {
            try result.errors.append(allocator, .{
                .code = "E010",
                .severity = .err,
                .message = "WASM init() returned error",
                .command_index = null,
            });
            result.status = .err;
            return;
        }

        // Read command buffer
        const cmd_ptr = try runtime.callGetPtr("getCommandPtr");
        const cmd_len = try runtime.callGetPtr("getCommandLen");

        if (cmd_len > 0) {
            const cmd_data = try runtime.readMemory(cmd_ptr, cmd_len);
            try parseCommandBuffer(allocator, cmd_data, &result.init_commands);
        }
    }

    // Execute frame phase
    if (opts.phase == .frame or opts.phase == .both) {
        const frame_result = try runtime.callFrame(opts.time, opts.width, opts.height);
        if (frame_result != 0) {
            try result.errors.append(allocator, .{
                .code = "E011",
                .severity = .err,
                .message = "WASM frame() returned error",
                .command_index = null,
            });
            result.status = .err;
            return;
        }

        // Read command buffer
        const cmd_ptr = try runtime.callGetPtr("getCommandPtr");
        const cmd_len = try runtime.callGetPtr("getCommandLen");

        if (cmd_len > 0) {
            const cmd_data = try runtime.readMemory(cmd_ptr, cmd_len);
            try parseCommandBuffer(allocator, cmd_data, &result.frame_commands);
        }
    }
}

/// Parse command buffer into CommandInfo array.
fn parseCommandBuffer(
    allocator: std.mem.Allocator,
    data: []const u8,
    commands: *std.ArrayListUnmanaged(CommandInfo),
) !void {
    // Header is 8 bytes: total_len(u32) + cmd_count(u16) + flags(u16)
    if (data.len < 8) return;

    const total_len = std.mem.readInt(u32, data[0..4], .little);
    const cmd_count = std.mem.readInt(u16, data[4..6], .little);
    _ = cmd_count; // We'll count commands as we parse

    if (total_len > data.len) return;

    var pos: u32 = 8; // Skip header
    var cmd_index: u32 = 0;
    const max_iterations: u32 = 10000; // Safety bound

    for (0..max_iterations) |_| {
        if (pos >= total_len) break;

        // Read command tag
        const tag = data[pos];
        pos += 1;

        const cmd: Cmd = @enumFromInt(tag);
        try commands.append(allocator, .{
            .index = cmd_index,
            .cmd = cmd,
        });

        cmd_index += 1;

        // Skip command payload based on type
        pos += getCommandPayloadSize(cmd, data[pos..]);

        // Stop at end command
        if (cmd == .end) break;
    }
}

/// Get payload size for a command based on command_buffer.zig format.
fn getCommandPayloadSize(cmd: Cmd, _: []const u8) u32 {
    return switch (cmd) {
        // Resource Creation
        .create_buffer => 7, // id(u16) + size(u32) + usage(u8)
        .create_texture => 10, // id(u16) + desc_ptr(u32) + desc_len(u32)
        .create_sampler => 10, // id(u16) + desc_ptr(u32) + desc_len(u32)
        .create_shader => 10, // id(u16) + code_ptr(u32) + code_len(u32)
        .create_render_pipeline => 10, // id(u16) + desc_ptr(u32) + desc_len(u32)
        .create_compute_pipeline => 10, // id(u16) + desc_ptr(u32) + desc_len(u32)
        .create_bind_group => 12, // id(u16) + layout_id(u16) + entries_ptr(u32) + entries_len(u32)
        .create_texture_view => 12, // id(u16) + texture_id(u16) + desc_ptr(u32) + desc_len(u32)
        .create_query_set => 10, // id(u16) + desc_ptr(u32) + desc_len(u32)
        .create_bind_group_layout => 10, // id(u16) + desc_ptr(u32) + desc_len(u32)
        .create_image_bitmap => 10, // id(u16) + data_ptr(u32) + data_len(u32)
        .create_pipeline_layout => 10, // id(u16) + desc_ptr(u32) + desc_len(u32)
        .create_render_bundle => 10, // id(u16) + desc_ptr(u32) + desc_len(u32)

        // Pass Operations
        .begin_render_pass => 6, // color_id(u16) + load(u8) + store(u8) + depth_id(u16)
        .begin_compute_pass => 0,
        .set_pipeline => 2, // id(u16)
        .set_bind_group => 3, // slot(u8) + id(u16)
        .set_vertex_buffer => 3, // slot(u8) + id(u16)
        .set_index_buffer => 3, // id(u16) + format(u8)
        .draw => 16, // vtx(u32) + inst(u32) + first_vtx(u32) + first_inst(u32)
        .draw_indexed => 20, // idx(u32) + inst(u32) + first_idx(u32) + base_vtx(u32) + first_inst(u32)
        .dispatch => 12, // x(u32) + y(u32) + z(u32)
        .end_pass => 0,
        .execute_bundles => 1, // count(u8) + bundle_ids... (variable, handled separately)

        // Queue Operations
        .write_buffer => 14, // id(u16) + offset(u32) + data_ptr(u32) + data_len(u32)
        .write_time_uniform => 8, // id(u16) + offset(u32) + size(u16)
        .copy_buffer_to_buffer => 16, // src_id(u16) + src_offset(u32) + dst_id(u16) + dst_offset(u32) + size(u32)
        .copy_texture_to_texture => 8, // src_id(u16) + dst_id(u16) + width(u16) + height(u16)
        .write_buffer_from_wasm => 14, // buffer_id(u16) + buffer_offset(u32) + wasm_ptr(u32) + size(u32)
        .copy_external_image_to_texture => 9, // bitmap_id(u16) + texture_id(u16) + mip_level(u8) + origin_x(u16) + origin_y(u16)

        // WASM Module Operations
        .init_wasm_module => 10, // module_id(u16) + data_ptr(u32) + data_len(u32)
        .call_wasm_func => 20, // call_id(u16) + module_id(u16) + func_name_ptr(u32) + func_name_len(u32) + args_ptr(u32) + args_len(u32)

        // Utility Operations
        .create_typed_array => 7, // id(u16) + type(u8) + size(u32)
        .fill_random => 15, // array_id(u16) + offset(u32) + count(u32) + stride(u8) + data_ptr(u32)
        .fill_expression => 17, // array_id(u16) + offset(u32) + count(u32) + stride(u8) + expr_ptr(u32) + expr_len(u16)
        .fill_constant => 15, // array_id(u16) + offset(u32) + count(u32) + stride(u8) + value_ptr(u32)
        .write_buffer_from_array => 8, // buffer_id(u16) + buffer_offset(u32) + array_id(u16)

        // Control
        .submit => 0,
        .end => 0,
    };
}

/// Output command summary statistics (command counts by category).
fn outputCommandSummary(commands: []const CommandInfo) void {
    var resource_count: u32 = 0;
    var pass_count: u32 = 0;
    var queue_count: u32 = 0;
    var draw_count: u32 = 0;
    var compute_count: u32 = 0;

    for (commands) |cmd_info| {
        const tag: u8 = @intFromEnum(cmd_info.cmd);
        if (tag >= 0x01 and tag <= 0x0F) {
            resource_count += 1;
        } else if (tag >= 0x10 and tag <= 0x1F) {
            pass_count += 1;
            if (cmd_info.cmd == .draw or cmd_info.cmd == .draw_indexed) {
                draw_count += 1;
            } else if (cmd_info.cmd == .dispatch) {
                compute_count += 1;
            }
        } else if (tag >= 0x20 and tag <= 0x2F) {
            queue_count += 1;
        }
    }

    std.debug.print("      \"resources_created\": {d},\n", .{resource_count});
    std.debug.print("      \"draw_calls\": {d},\n", .{draw_count});
    std.debug.print("      \"compute_dispatches\": {d},\n", .{compute_count});
    std.debug.print("      \"queue_operations\": {d}\n", .{queue_count});
}

/// Output validation result as JSON.
fn outputJson(allocator: std.mem.Allocator, result: *const ValidationResult, opts: *const Options) !void {
    _ = allocator;

    std.debug.print("{{\n", .{});
    std.debug.print("  \"status\": \"{s}\",\n", .{@tagName(result.status)});
    std.debug.print("  \"input\": \"{s}\",\n", .{opts.input_path});

    // Module info (if available)
    if (result.module_info) |info| {
        std.debug.print("  \"module\": {{\n", .{});
        std.debug.print("    \"version\": {d},\n", .{info.version});
        std.debug.print("    \"has_executor\": {s},\n", .{if (info.has_executor) "true" else "false"});
        std.debug.print("    \"executor_size\": {d},\n", .{info.executor_size});
        std.debug.print("    \"bytecode_size\": {d},\n", .{info.bytecode_size});
        std.debug.print("    \"strings_count\": {d},\n", .{info.strings_count});
        std.debug.print("    \"data_blobs_count\": {d},\n", .{info.data_blobs_count});
        std.debug.print("    \"wgsl_entries_count\": {d},\n", .{info.wgsl_entries_count});
        std.debug.print("    \"uniform_entries_count\": {d},\n", .{info.uniform_entries_count});
        std.debug.print("    \"has_animation\": {s},\n", .{if (info.has_animation) "true" else "false"});
        std.debug.print("    \"scene_count\": {d}\n", .{info.scene_count});
        std.debug.print("  }},\n", .{});
    }

    // Errors
    std.debug.print("  \"errors\": [", .{});
    for (result.errors.items, 0..) |err, i| {
        if (i > 0) std.debug.print(",", .{});
        std.debug.print("\n    {{\"code\": \"{s}\", \"severity\": \"error\", \"message\": \"{s}\"", .{ err.code, err.message });
        if (err.command_index) |idx| {
            std.debug.print(", \"command_index\": {d}", .{idx});
        }
        std.debug.print("}}", .{});
    }
    std.debug.print("\n  ],\n", .{});

    // Warnings
    std.debug.print("  \"warnings\": [", .{});
    for (result.warnings.items, 0..) |warn, i| {
        if (i > 0) std.debug.print(",", .{});
        std.debug.print("\n    {{\"code\": \"{s}\", \"severity\": \"warning\", \"message\": \"{s}\"", .{ warn.code, warn.message });
        if (warn.command_index) |idx| {
            std.debug.print(", \"command_index\": {d}", .{idx});
        }
        std.debug.print("}}", .{});
    }
    std.debug.print("\n  ]", .{});

    // Init commands (if verbose or phase includes init)
    if (opts.verbose or opts.phase == .init or opts.phase == .both) {
        std.debug.print(",\n  \"initialization\": {{\n", .{});
        std.debug.print("    \"phase\": \"init\",\n", .{});
        std.debug.print("    \"commands\": [", .{});
        for (result.init_commands.items, 0..) |cmd_info, i| {
            if (i > 0) std.debug.print(",", .{});
            std.debug.print("\n      {{\"index\": {d}, \"cmd\": \"{s}\"}}", .{ cmd_info.index, @tagName(cmd_info.cmd) });
        }
        if (result.init_commands.items.len > 0) std.debug.print("\n    ", .{});
        std.debug.print("],\n", .{});
        std.debug.print("    \"summary\": {{\n", .{});
        std.debug.print("      \"total_commands\": {d},\n", .{result.init_commands.items.len});
        outputCommandSummary(result.init_commands.items);
        std.debug.print("    }}\n", .{});
        std.debug.print("  }}", .{});
    }

    // Frame commands (if verbose or phase includes frame)
    if (opts.verbose or opts.phase == .frame or opts.phase == .both) {
        std.debug.print(",\n  \"first_frame\": {{\n", .{});
        std.debug.print("    \"phase\": \"frame\",\n", .{});
        std.debug.print("    \"time\": {d},\n", .{opts.time});
        std.debug.print("    \"canvas_size\": [{d}, {d}],\n", .{ opts.width, opts.height });
        std.debug.print("    \"commands\": [", .{});
        for (result.frame_commands.items, 0..) |cmd_info, i| {
            if (i > 0) std.debug.print(",", .{});
            std.debug.print("\n      {{\"index\": {d}, \"cmd\": \"{s}\"}}", .{ cmd_info.index, @tagName(cmd_info.cmd) });
        }
        if (result.frame_commands.items.len > 0) std.debug.print("\n    ", .{});
        std.debug.print("],\n", .{});
        std.debug.print("    \"summary\": {{\n", .{});
        std.debug.print("      \"total_commands\": {d},\n", .{result.frame_commands.items.len});
        outputCommandSummary(result.frame_commands.items);
        std.debug.print("    }}\n", .{});
        std.debug.print("  }}", .{});
    }

    std.debug.print("\n}}\n", .{});
}

fn outputJsonError(allocator: std.mem.Allocator, err_type: []const u8, message: []const u8) !void {
    _ = allocator;
    std.debug.print(
        \\{{
        \\  "status": "error",
        \\  "errors": [
        \\    {{"code": "E000", "type": "{s}", "message": "{s}"}}
        \\  ]
        \\}}
        \\
    , .{ err_type, message });
}

/// Output validation result as human-readable text.
fn outputHuman(result: *const ValidationResult, opts: *const Options) !void {
    // Header
    std.debug.print("Validating: {s}\n", .{opts.input_path});
    std.debug.print("Canvas size: {d}x{d}, Time: {d:.2}s\n\n", .{ opts.width, opts.height, opts.time });

    // Module info
    if (result.module_info) |info| {
        std.debug.print("Module Info:\n", .{});
        std.debug.print("  Format version: v{d}\n", .{info.version});
        std.debug.print("  Bytecode size: {d} bytes\n", .{info.bytecode_size});
        std.debug.print("  WGSL entries: {d}\n", .{info.wgsl_entries_count});
        std.debug.print("  Data blobs: {d}\n", .{info.data_blobs_count});
        std.debug.print("  Strings: {d}\n", .{info.strings_count});
        std.debug.print("  Uniforms: {d}\n", .{info.uniform_entries_count});
        if (info.has_executor) {
            std.debug.print("  Embedded executor: {d} bytes\n", .{info.executor_size});
        }
        if (info.has_animation) {
            std.debug.print("  Animation scenes: {d}\n", .{info.scene_count});
        }
        std.debug.print("\n", .{});
    }

    // Init commands (if verbose or phase includes init)
    if ((opts.verbose or opts.phase == .init or opts.phase == .both) and result.init_commands.items.len > 0) {
        std.debug.print("Initialization ({d} commands):\n", .{result.init_commands.items.len});
        outputHumanCommandList(result.init_commands.items, opts.verbose);
        std.debug.print("\n", .{});
    }

    // Frame commands (if verbose or phase includes frame)
    if ((opts.verbose or opts.phase == .frame or opts.phase == .both) and result.frame_commands.items.len > 0) {
        std.debug.print("Frame ({d} commands):\n", .{result.frame_commands.items.len});
        outputHumanCommandList(result.frame_commands.items, opts.verbose);
        std.debug.print("\n", .{});
    }

    // Errors
    if (result.errors.items.len > 0) {
        std.debug.print("Errors:\n", .{});
        for (result.errors.items) |err| {
            std.debug.print("  [{s}] {s}\n", .{ err.code, err.message });
        }
        std.debug.print("\n", .{});
    }

    // Warnings
    if (result.warnings.items.len > 0) {
        std.debug.print("Warnings:\n", .{});
        for (result.warnings.items) |warn| {
            std.debug.print("  [{s}] {s}\n", .{ warn.code, warn.message });
        }
        std.debug.print("\n", .{});
    }

    // Status
    const status_symbol: []const u8 = switch (result.status) {
        .ok => "OK",
        .warning => "WARNING",
        .err => "ERROR",
    };
    std.debug.print("Status: {s}\n", .{status_symbol});
}

/// Output human-readable command list.
fn outputHumanCommandList(commands: []const CommandInfo, verbose: bool) void {
    // Count commands by category
    var resource_count: u32 = 0;
    var draw_count: u32 = 0;
    var compute_count: u32 = 0;

    for (commands) |cmd_info| {
        const tag: u8 = @intFromEnum(cmd_info.cmd);
        if (tag >= 0x01 and tag <= 0x0F) {
            resource_count += 1;
        } else if (cmd_info.cmd == .draw or cmd_info.cmd == .draw_indexed) {
            draw_count += 1;
        } else if (cmd_info.cmd == .dispatch) {
            compute_count += 1;
        }
    }

    std.debug.print("  Resources: {d}, Draws: {d}, Computes: {d}\n", .{ resource_count, draw_count, compute_count });

    // If verbose, list all commands
    if (verbose) {
        for (commands) |cmd_info| {
            std.debug.print("  [{d:3}] {s}\n", .{ cmd_info.index, @tagName(cmd_info.cmd) });
        }
    }
}

fn printHelp() void {
    std.debug.print(
        \\PNGine Validate - Runtime validation via wasm3
        \\
        \\Usage: pngine validate <input> [options]
        \\
        \\Options:
        \\  --json                 Output JSON (default: human-readable)
        \\  --verbose, -v          Include full command trace (init + frame)
        \\  --phase <phase>        Show specific phase only: init, frame, or both
        \\  --symptom <desc>       Focus diagnosis on symptom:
        \\                         black, colors, blend, flicker, geometry
        \\  --time, -t <seconds>   Test at specific time (default: 0.0)
        \\  --size, -s <WxH>       Canvas size for validation (default: 512x512)
        \\  --strict               Exit code 1 on warnings (for CI)
        \\  --extract-wgsl         Include WGSL source in output
        \\  --quiet, -q            Only output errors
        \\  -h, --help             Show this help
        \\
        \\Examples:
        \\  pngine validate shader.pngine
        \\  pngine validate shader.pngine --json > report.json
        \\  pngine validate shader.pngine --json --phase init
        \\  pngine validate shader.pngine --symptom black --json
        \\
        \\Supported formats: .pngine, .pbsf, .pngb, .png (with embedded bytecode)
        \\
    , .{});
}

// ============================================================================
// Tests
// ============================================================================

test "parseSize: valid formats" {
    const size1 = parseSize("640x480").?;
    try std.testing.expectEqual(@as(u32, 640), size1[0]);
    try std.testing.expectEqual(@as(u32, 480), size1[1]);

    const size2 = parseSize("1920X1080").?;
    try std.testing.expectEqual(@as(u32, 1920), size2[0]);
    try std.testing.expectEqual(@as(u32, 1080), size2[1]);
}

test "parseSize: invalid formats" {
    try std.testing.expect(parseSize("640") == null);
    try std.testing.expect(parseSize("640-480") == null);
    try std.testing.expect(parseSize("0x480") == null);
    try std.testing.expect(parseSize("640x0") == null);
}

test "parsePhase: valid phases" {
    try std.testing.expectEqual(Phase.init, parsePhase("init").?);
    try std.testing.expectEqual(Phase.frame, parsePhase("frame").?);
    try std.testing.expectEqual(Phase.both, parsePhase("both").?);
}

test "parsePhase: invalid phase" {
    try std.testing.expect(parsePhase("invalid") == null);
}

test "parseSymptom: known symptoms" {
    try std.testing.expectEqual(Symptom.black, parseSymptom("black"));
    try std.testing.expectEqual(Symptom.colors, parseSymptom("colors"));
    try std.testing.expectEqual(Symptom.none, parseSymptom("unknown"));
}
