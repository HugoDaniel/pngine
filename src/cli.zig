//! PNGine CLI - Compile DSL/PBSF source to PNGB bytecode.
//!
//! A command-line interface for compiling PNGine source files into PNGB bytecode.
//! Supports both the new DSL format (.pngine) and legacy PBSF format (.pbsf).
//!
//! Usage:
//!   pngine compile input.pngine -o output.pngb   (DSL format)
//!   pngine compile input.pbsf -o output.pngb     (legacy PBSF)
//!   pngine compile input.pngine                  (outputs to input.pngb)
//!   pngine embed image.png bytecode.pngb -o output.png
//!   pngine extract input.png -o output.pngb
//!
//! Exit codes:
//!   0 - Success
//!   1 - Invalid arguments
//!   2 - File I/O error
//!   3 - Compilation error
//!   4 - PNG error
//!
//! Invariants:
//!   - All file reads are bounded by max_file_size (16 MiB)
//!   - Output files always contain valid PNGB with correct magic bytes
//!   - All allocations are freed on both success and error paths
//!   - File extension determines compiler: .pngine → DSL, .pbsf → PBSF

const std = @import("std");
const pngine = @import("pngine");
const format = pngine.format;
const mock_gpu = pngine.mock_gpu;
const MockGPU = mock_gpu.MockGPU;
const Call = mock_gpu.Call;
const Dispatcher = pngine.Dispatcher;
const DescriptorEncoder = pngine.DescriptorEncoder;
const zip = pngine.zip;

// Build-time options and embedded WASM runtime
const build_options = @import("build_options");
const embedded_wasm: []const u8 = @embedFile("embedded_wasm");

// Subcommand modules
const render_cmd = @import("cli/render.zig");

/// Maximum input file size (16 MiB).
/// Prevents DoS via memory exhaustion from malicious inputs.
const max_file_size: u32 = 16 * 1024 * 1024;

/// CLI entry point.
/// Initializes allocator, runs main logic, returns exit code.
pub fn main() !u8 {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = run(allocator) catch |err| {
        return handleError(err);
    };

    return result;
}

/// Parse arguments and dispatch to appropriate command.
/// Returns exit code (0 = success, non-zero = error).
fn run(allocator: std.mem.Allocator) !u8 {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Pre-condition: args[0] is always the program name
    std.debug.assert(args.len >= 1);

    if (args.len < 2) {
        printUsage();
        return 1;
    }

    const command = args[1];

    // Check if first arg is a .pngine file - treat as implicit render command
    const extension = std.fs.path.extension(command);
    if (std.mem.eql(u8, extension, ".pngine") or std.mem.eql(u8, extension, ".pbsf")) {
        // Implicit render: pngine file.pngine == pngine render file.pngine
        return render_cmd.run(allocator, args[1..]);
    }

    if (std.mem.eql(u8, command, "compile")) {
        return runCompile(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "check")) {
        return runCheck(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "embed")) {
        return runEmbed(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "extract")) {
        return runExtract(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "bundle")) {
        return runBundle(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "list")) {
        return runList(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "render")) {
        return render_cmd.run(allocator, args[2..]);
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

/// Execute the compile command.
/// Parses compile-specific args, reads input, compiles, writes output.
/// Returns exit code.
fn runCompile(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
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
        printUsage();
        return 1;
    }

    const input = input_path.?;

    // Derive output path if not specified: input.pbsf -> input.pngb
    const output = output_path orelse deriveOutputPath(allocator, input) catch |err| {
        std.debug.print("Error: failed to derive output path: {}\n", .{err});
        return 2;
    };
    defer if (output_path == null) allocator.free(output);

    // Read input file
    const source = readSourceFile(allocator, input) catch |err| {
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
    writeOutputFile(output, bytecode) catch |err| {
        std.debug.print("Error: failed to write '{s}': {}\n", .{ output, err });
        return 2;
    };

    // Success message
    std.debug.print("Compiled {s} -> {s} ({d} bytes)\n", .{ input, output, bytecode.len });

    return 0;
}

/// Execute the check command.
/// Compiles source (or loads PNGB) and validates by running through MockGPU.
/// Returns exit code.
fn runCheck(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    // Pre-condition: args slice is valid
    std.debug.assert(args.len <= 1024);

    if (args.len == 0) {
        std.debug.print("Error: no input file specified\n\n", .{});
        printUsage();
        return 1;
    }

    const input = args[0];

    // Load or compile bytecode
    const bytecode = loadOrCompileBytecode(allocator, input) catch |err| {
        return handleLoadError(err, input);
    };
    defer allocator.free(bytecode);

    // Validate and deserialize
    var module = validateAndDeserialize(allocator, bytecode) catch |err| {
        return handleDeserializeError(err);
    };
    defer module.deinit(allocator);

    // Print module info
    printModuleInfo(input, &module);

    // Execute with MockGPU to validate bytecode
    var gpu: MockGPU = .empty;
    defer gpu.deinit(allocator);

    var dispatcher = Dispatcher(MockGPU).init(allocator, &gpu, &module);
    defer dispatcher.deinit();
    dispatcher.executeAll(allocator) catch |err| {
        std.debug.print("\nExecution error: {}\n", .{err});
        return 5;
    };

    // Print execution summary and validate
    const calls = gpu.getCalls();
    return printExecutionSummary(calls, &module);
}

/// Load bytecode from file or compile from source.
fn loadOrCompileBytecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Pre-condition: input path is non-empty
    std.debug.assert(input.len > 0);

    const extension = std.fs.path.extension(input);

    if (std.mem.eql(u8, extension, ".pngb")) {
        return readBinaryFile(allocator, input);
    }

    if (std.mem.eql(u8, extension, ".png")) {
        // Extract bytecode from PNG with embedded pNGb chunk
        const png_data = try readBinaryFile(allocator, input);
        defer allocator.free(png_data);

        const bytecode = pngine.png.extractBytecode(allocator, png_data) catch |err| {
            std.debug.print("Error: failed to extract bytecode from PNG: {}\n", .{err});
            return error.InvalidFormat;
        };

        // Post-condition: bytecode is non-empty
        std.debug.assert(bytecode.len > 0);
        return bytecode;
    }

    if (std.mem.eql(u8, extension, ".zip")) {
        // Extract bytecode from ZIP bundle
        const zip_data = try readBinaryFile(allocator, input);
        defer allocator.free(zip_data);

        const bytecode = extractFromZip(allocator, zip_data) catch |err| {
            std.debug.print("Error: failed to extract bytecode from ZIP: {}\n", .{err});
            return error.InvalidFormat;
        };

        // Post-condition: bytecode is non-empty
        std.debug.assert(bytecode.len > 0);
        return bytecode;
    }

    // Compile source file
    const source = try readSourceFile(allocator, input);
    defer allocator.free(source);

    const bytecode = try compileSource(allocator, input, source);

    // Post-condition: bytecode is non-empty
    std.debug.assert(bytecode.len > 0);

    return bytecode;
}

/// Handle errors from loadOrCompileBytecode.
fn handleLoadError(err: anyerror, input: []const u8) u8 {
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

/// Validate PNGB header and deserialize module.
fn validateAndDeserialize(allocator: std.mem.Allocator, bytecode: []const u8) !format.Module {
    // Pre-condition: bytecode is non-empty
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

    // Post-condition: module has bytecode
    std.debug.assert(module.bytecode.len > 0);

    return module;
}

/// Handle errors from validateAndDeserialize.
fn handleDeserializeError(err: anyerror) u8 {
    if (err == error.InvalidFormat) {
        return 4;
    }
    std.debug.print("Error: failed to deserialize PNGB: {}\n", .{err});
    return 4;
}

/// Print module information.
fn printModuleInfo(input: []const u8, module: *const format.Module) void {
    // Pre-condition: input is non-empty
    std.debug.assert(input.len > 0);

    std.debug.print("PNGB: {s}\n", .{input});
    std.debug.print("  Bytecode:     {d} bytes\n", .{module.bytecode.len});
    std.debug.print("  Strings:      {d} entries\n", .{module.strings.count()});
    std.debug.print("  Data section: {d} entries\n", .{module.data.count()});
}

/// GPU call type counts for summary reporting.
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

/// Count GPU calls by type.
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

/// Print call counts summary.
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

/// Print execution summary and validate. Returns exit code.
fn printExecutionSummary(calls: []const Call, module: *const format.Module) u8 {
    std.debug.print("\nExecution OK: {d} GPU calls\n", .{calls.len});

    const counts = countCallTypes(calls);
    printCallCounts(counts);

    // Validate descriptor formats (catches issues before web runtime)
    const desc_errors = validateDescriptors(calls, module);
    if (desc_errors > 0) {
        std.debug.print("\nWarning: {d} invalid descriptor(s) detected\n", .{desc_errors});
        std.debug.print("  These may cause errors in the web runtime\n", .{});
        return 6;
    }

    // Report entry points for user verification
    reportEntryPoints(calls, module);

    // Report buffer usage for user verification
    reportBufferUsage(calls);

    // Validate bind group setup before draw calls
    const bind_group_warnings = validateBindGroupSetup(calls);
    if (bind_group_warnings > 0) {
        std.debug.print(
            "\nWarning: {d} draw call(s) may have missing bind groups\n",
            .{bind_group_warnings},
        );
        std.debug.print("  Ensure bindGroups=[...] is set in render passes\n", .{});
    }

    return 0;
}

/// Embed command arguments.
const EmbedArgs = struct {
    png_path: []const u8,
    pngb_path: []const u8,
    output_path: ?[]const u8,
};

/// Parse embed command arguments.
/// Returns null on error (error message already printed).
fn parseEmbedArgs(args: []const []const u8) ?EmbedArgs {
    var png_path: ?[]const u8 = null;
    var pngb_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    const args_len: u32 = @intCast(args.len);
    for (0..args_len) |idx| {
        const i: u32 = @intCast(idx);
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: -o requires an output path\n", .{});
                return null;
            }
            output_path = args[i + 1];
        } else if (arg.len > 0 and arg[0] == '-') {
            // Skip -o's value (already processed above)
            const prev = if (idx > 0) args[idx - 1] else "";
            const is_output_val = std.mem.eql(u8, prev, "-o") or
                std.mem.eql(u8, prev, "--output");
            if (is_output_val) continue;
            std.debug.print("Unknown option: {s}\n", .{arg});
            return null;
        } else {
            // First positional arg is PNG, second is PNGB
            if (png_path == null) {
                png_path = arg;
            } else if (pngb_path == null) {
                pngb_path = arg;
            } else {
                std.debug.print("Error: too many arguments\n", .{});
                return null;
            }
        }
    }

    if (png_path == null or pngb_path == null) {
        std.debug.print("Error: embed requires PNG file and PNGB bytecode file\n\n", .{});
        std.debug.print("Usage: pngine embed <image.png> <bytecode.pngb> [-o output.png]\n", .{});
        return null;
    }

    return .{ .png_path = png_path.?, .pngb_path = pngb_path.?, .output_path = output_path };
}

/// Execute the embed command.
/// Embeds PNGB bytecode into a PNG file.
/// Returns exit code.
fn runEmbed(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    const parsed = parseEmbedArgs(args) orelse return 1;

    // Derive output path if not specified
    const derived = deriveEmbedOutputPath(allocator, parsed.png_path);
    const output = parsed.output_path orelse derived catch |err| {
        std.debug.print("Error: failed to derive output path: {}\n", .{err});
        return 2;
    };
    defer if (parsed.output_path == null) allocator.free(output);

    // Read and validate inputs, then embed
    return executeEmbed(allocator, parsed.png_path, parsed.pngb_path, output);
}

/// Execute the embed operation after argument parsing.
fn executeEmbed(
    allocator: std.mem.Allocator,
    png_input: []const u8,
    pngb_input: []const u8,
    output: []const u8,
) u8 {
    // Pre-conditions
    std.debug.assert(png_input.len > 0);
    std.debug.assert(pngb_input.len > 0);

    // Read PNG file
    const png_data = readBinaryFile(allocator, png_input) catch |err| {
        std.debug.print("Error: failed to read PNG '{s}': {}\n", .{ png_input, err });
        return 2;
    };
    defer allocator.free(png_data);

    // Read and validate PNGB bytecode
    const bytecode = readBinaryFile(allocator, pngb_input) catch |err| {
        std.debug.print("Error: failed to read PNGB '{s}': {}\n", .{ pngb_input, err });
        return 2;
    };
    defer allocator.free(bytecode);

    // Validate PNGB magic bytes to catch invalid files early
    if (bytecode.len < format.HEADER_SIZE or !std.mem.eql(u8, bytecode[0..4], format.MAGIC)) {
        std.debug.print("Error: '{s}' is not a valid PNGB file\n", .{pngb_input});
        return 4;
    }

    // Embed bytecode into PNG
    const embedded = pngine.png.embedBytecode(allocator, png_data, bytecode) catch |err| {
        std.debug.print("Error: failed to embed bytecode: {}\n", .{err});
        return 4;
    };
    defer allocator.free(embedded);

    // Write output file
    writeOutputFile(output, embedded) catch |err| {
        std.debug.print("Error: failed to write '{s}': {}\n", .{ output, err });
        return 2;
    };

    std.debug.print("Embedded {s} ({d} bytes) into {s} -> {s} ({d} bytes)\n", .{
        pngb_input, bytecode.len, png_input, output, embedded.len,
    });

    return 0;
}

/// Execute the extract command.
/// Extracts PNGB bytecode from a PNG or ZIP file.
/// Returns exit code.
fn runExtract(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
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
        std.debug.print("Usage: pngine extract <file.png|file.zip> [-o output.pngb]\n", .{});
        return 1;
    }

    const input = input_path.?;

    // Derive output path if not specified: input.png -> input.pngb
    const output = output_path orelse deriveExtractOutputPath(allocator, input) catch |err| {
        std.debug.print("Error: failed to derive output path: {}\n", .{err});
        return 2;
    };
    defer if (output_path == null) allocator.free(output);

    // Read file
    const file_data = readBinaryFile(allocator, input) catch |err| {
        std.debug.print("Error: failed to read '{s}': {}\n", .{ input, err });
        return 2;
    };
    defer allocator.free(file_data);

    // Detect format and extract bytecode
    const bytecode = blk: {
        if (zip.isZip(file_data)) {
            // Extract from ZIP bundle
            break :blk extractFromZip(allocator, file_data) catch |err| {
                std.debug.print("Error: failed to extract from ZIP: {}\n", .{err});
                return 4;
            };
        } else if (file_data.len >= 8 and
            std.mem.eql(u8, file_data[0..8], &pngine.png.PNG_SIGNATURE))
        {
            // Extract from PNG
            if (!pngine.png.hasPngb(file_data)) {
                std.debug.print(
                    "Error: '{s}' has no embedded bytecode (missing pNGb chunk)\n",
                    .{input},
                );
                return 4;
            }
            break :blk pngine.png.extractBytecode(allocator, file_data) catch |err| {
                std.debug.print("Error: failed to extract bytecode: {}\n", .{err});
                return 4;
            };
        } else {
            std.debug.print("Error: '{s}' is not a valid PNG or ZIP file\n", .{input});
            return 4;
        }
    };
    defer allocator.free(bytecode);

    // Validate extracted PNGB
    if (bytecode.len < format.HEADER_SIZE or !std.mem.eql(u8, bytecode[0..4], format.MAGIC)) {
        std.debug.print("Error: extracted data is not valid PNGB\n", .{});
        return 4;
    }

    // Write output file
    writeOutputFile(output, bytecode) catch |err| {
        std.debug.print("Error: failed to write '{s}': {}\n", .{ output, err });
        return 2;
    };

    // Success message
    std.debug.print("Extracted {s} -> {s} ({d} bytes)\n", .{ input, output, bytecode.len });

    return 0;
}

/// Extract bytecode from a ZIP bundle.
/// Reads manifest.json to find the entry point.
fn extractFromZip(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var reader = zip.ZipReader.init(allocator, data) catch {
        return error.InvalidZip;
    };
    defer reader.deinit();

    // Try to read manifest.json to find entry point
    var entry_name_buf: [256]u8 = undefined;
    const entry_name: []const u8 = blk: {
        if (reader.extract("manifest.json")) |manifest_data| {
            defer allocator.free(manifest_data);

            // Parse JSON to find "entry" field
            if (findJsonValue(manifest_data, "\"entry\"")) |entry_value| {
                // Copy entry_value to buffer before manifest_data is freed
                if (entry_value.len <= entry_name_buf.len) {
                    @memcpy(entry_name_buf[0..entry_value.len], entry_value);
                    break :blk entry_name_buf[0..entry_value.len];
                }
            }
        } else |_| {
            // No manifest, try default name
        }
        break :blk "main.pngb";
    };

    // Extract the bytecode file
    return reader.extract(entry_name) catch {
        return error.FileNotFound;
    };
}

/// Find a JSON string value (simple parser for single field).
fn findJsonValue(data: []const u8, field: []const u8) ?[]const u8 {
    const field_start = std.mem.indexOf(u8, data, field) orelse return null;
    const after_field = field_start + field.len;

    // Skip : and whitespace
    var pos = after_field;
    while (pos < data.len and (data[pos] == ':' or data[pos] == ' ' or data[pos] == '"')) {
        pos += 1;
    }

    if (pos >= data.len) return null;

    // Back up to include the quote
    if (pos > 0 and data[pos - 1] == '"') {
        const start = pos;
        // Find closing quote
        while (pos < data.len and data[pos] != '"') {
            pos += 1;
        }
        return data[start..pos];
    }

    return null;
}

/// Execute the bundle command.
/// Creates a ZIP bundle containing bytecode, manifest, and optional WASM runtime.
/// Returns exit code.
fn runBundle(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var assets_dir: ?[]const u8 = null;
    var include_runtime = true;

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
        } else if (std.mem.eql(u8, arg, "--assets")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: --assets requires a directory path\n", .{});
                return 1;
            }
            assets_dir = args[i + 1];
            skip_next = true;
        } else if (std.mem.eql(u8, arg, "--no-runtime")) {
            include_runtime = false;
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
        std.debug.print(
            "Usage: pngine bundle <input> [-o output.zip] [--assets dir]\n",
            .{},
        );
        return 1;
    }

    const input = input_path.?;

    // Derive output path if not specified: input.pngine -> input.zip
    const output = output_path orelse deriveBundleOutputPath(allocator, input) catch |err| {
        std.debug.print("Error: failed to derive output path: {}\n", .{err});
        return 2;
    };
    defer if (output_path == null) allocator.free(output);

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

    // Create ZIP bundle
    var writer = zip.ZipWriter.init(allocator);
    defer writer.deinit();

    // Add manifest.json
    const manifest = if (include_runtime)
        "{\"version\":1,\"entry\":\"main.pngb\",\"runtime\":\"pngine.wasm\"}"
    else
        "{\"version\":1,\"entry\":\"main.pngb\"}";

    writer.addFile("manifest.json", manifest, .store) catch |err| {
        std.debug.print("Error: failed to add manifest: {}\n", .{err});
        return 4;
    };

    // Add bytecode
    writer.addFile("main.pngb", bytecode, .deflate) catch |err| {
        std.debug.print("Error: failed to add bytecode: {}\n", .{err});
        return 4;
    };

    // Add assets from directory if specified
    var assets_count: u32 = 0;
    if (assets_dir) |dir_path| {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            std.debug.print(
                "Error: failed to open assets directory '{s}': {}\n",
                .{ dir_path, err },
            );
            return 2;
        };
        defer dir.close();

        var walker = dir.walk(allocator) catch |err| {
            std.debug.print("Error: failed to walk assets directory: {}\n", .{err});
            return 2;
        };
        defer walker.deinit();

        // Walk directory with bounded iteration (max 10000 files)
        for (0..10000) |_| {
            const entry = walker.next() catch |err| {
                std.debug.print("Error: failed to iterate assets: {}\n", .{err});
                return 2;
            };

            if (entry) |e| {
                if (e.kind == .file) {
                    // Build path: assets/<relative_path>
                    const asset_path = std.fmt.allocPrint(
                        allocator,
                        "assets/{s}",
                        .{e.path},
                    ) catch |err| {
                        std.debug.print("Error: out of memory: {}\n", .{err});
                        return 4;
                    };
                    defer allocator.free(asset_path);

                    // Read file content using the walker's directory handle
                    const content = dir.readFileAlloc(e.path, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
                        std.debug.print(
                            "Error: failed to read asset '{s}': {}\n",
                            .{ e.path, err },
                        );
                        return 2;
                    };
                    defer allocator.free(content);

                    // Add to ZIP (store for already-compressed files, deflate otherwise)
                    const compressed = isCompressedExtension(e.basename);
                    const method: zip.CompressionMethod = if (compressed) .store else .deflate;
                    writer.addFile(asset_path, content, method) catch |err| {
                        std.debug.print("Error: failed to add asset '{s}': {}\n", .{ e.path, err });
                        return 4;
                    };

                    assets_count += 1;
                }
            } else {
                break; // No more entries
            }
        }
    }

    // Add WASM runtime if requested and available
    if (include_runtime) {
        if (embedded_wasm.len > 0) {
            // WASM is already compressed, use store method
            writer.addFile("pngine.wasm", embedded_wasm, .store) catch |err| {
                std.debug.print("Error: failed to add WASM runtime: {}\n", .{err});
                return 4;
            };
        } else {
            std.debug.print("Warning: WASM runtime not available in this build\n", .{});
        }
    }

    // Finalize and write
    const zip_data = writer.finish() catch |err| {
        std.debug.print("Error: failed to create ZIP: {}\n", .{err});
        return 4;
    };
    defer allocator.free(zip_data);

    writeOutputFile(output, zip_data) catch |err| {
        std.debug.print("Error: failed to write '{s}': {}\n", .{ output, err });
        return 2;
    };

    if (assets_count > 0) {
        std.debug.print(
            "Bundled {s} -> {s} ({d} bytes, {d} assets)\n",
            .{ input, output, zip_data.len, assets_count },
        );
    } else {
        std.debug.print(
            "Bundled {s} -> {s} ({d} bytes)\n",
            .{ input, output, zip_data.len },
        );
    }
    return 0;
}

/// Execute the list command.
/// Lists contents of a ZIP or PNG file.
/// Returns exit code.
fn runList(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len == 0) {
        std.debug.print("Error: no input file specified\n\n", .{});
        std.debug.print("Usage: pngine list <file.zip|file.png>\n", .{});
        return 1;
    }

    const input = args[0];

    // Read file
    const data = readBinaryFile(allocator, input) catch |err| {
        std.debug.print("Error: failed to read '{s}': {}\n", .{ input, err });
        return 2;
    };
    defer allocator.free(data);

    // Detect format by magic bytes
    if (zip.isZip(data)) {
        return listZipContents(allocator, input, data);
    } else if (data.len >= 8 and std.mem.eql(u8, data[0..8], &pngine.png.PNG_SIGNATURE)) {
        return listPngContents(allocator, input, data);
    } else {
        std.debug.print("Error: '{s}' is not a ZIP or PNG file\n", .{input});
        return 4;
    }
}

/// List contents of a ZIP file.
fn listZipContents(allocator: std.mem.Allocator, input: []const u8, data: []const u8) u8 {
    var reader = zip.ZipReader.init(allocator, data) catch |err| {
        std.debug.print("Error: failed to read ZIP: {}\n", .{err});
        return 4;
    };
    defer reader.deinit();

    const entries = reader.getEntries();

    std.debug.print("ZIP: {s}\n", .{input});
    std.debug.print("  {d} file(s)\n\n", .{entries.len});

    if (entries.len == 0) {
        std.debug.print("  (empty archive)\n", .{});
        return 0;
    }

    // Print header
    std.debug.print("  {s:<40} {s:>12} {s:>12}\n", .{ "Name", "Compressed", "Size" });
    std.debug.print("  {s:-<40} {s:->12} {s:->12}\n", .{ "", "", "" });

    // Print entries
    var total_compressed: u64 = 0;
    var total_uncompressed: u64 = 0;

    for (entries) |entry| {
        const comp_method: []const u8 = if (entry.compression == 8) "deflate" else "store";
        _ = comp_method;

        std.debug.print("  {s:<40} {d:>12} {d:>12}\n", .{
            entry.filename,
            entry.compressed_size,
            entry.uncompressed_size,
        });

        total_compressed += entry.compressed_size;
        total_uncompressed += entry.uncompressed_size;
    }

    // Print totals
    std.debug.print("  {s:-<40} {s:->12} {s:->12}\n", .{ "", "", "" });
    std.debug.print(
        "  {s:<40} {d:>12} {d:>12}\n",
        .{ "Total", total_compressed, total_uncompressed },
    );

    return 0;
}

/// List contents of a PNG file (check for embedded bytecode and runtime).
fn listPngContents(allocator: std.mem.Allocator, input: []const u8, data: []const u8) u8 {
    _ = allocator;

    std.debug.print("PNG: {s}\n", .{input});

    // Check for pNGb (bytecode) chunk
    if (pngine.png.hasPngb(data)) {
        const info = pngine.png.getPngbInfo(data) catch |err| {
            std.debug.print("  Error reading pNGb chunk: {}\n", .{err});
            return 4;
        };

        std.debug.print("  Embedded bytecode (pNGb): yes\n", .{});
        std.debug.print("    Version: {d}\n", .{info.version});
        std.debug.print("    Compressed: {s}\n", .{if (info.compressed) "yes" else "no"});
        std.debug.print("    Payload size: {d} bytes\n", .{info.payload_size});
    } else {
        std.debug.print("  Embedded bytecode (pNGb): no\n", .{});
    }

    // Check for pNGr (runtime) chunk
    if (pngine.png.hasPngr(data)) {
        const info = pngine.png.getPngrInfo(data) catch |err| {
            std.debug.print("  Error reading pNGr chunk: {}\n", .{err});
            return 4;
        };

        std.debug.print("  Embedded runtime (pNGr): yes\n", .{});
        std.debug.print("    Version: {d}\n", .{info.version});
        std.debug.print("    Compressed: {s}\n", .{if (info.compressed) "yes" else "no"});
        std.debug.print("    Payload size: {d} bytes\n", .{info.payload_bytes});
    } else {
        std.debug.print("  Embedded runtime (pNGr): no\n", .{});
    }

    return 0;
}

/// Check if file extension indicates already-compressed content.
/// Used to skip redundant DEFLATE compression in ZIP bundles.
fn isCompressedExtension(filename: []const u8) bool {
    const ext = std.fs.path.extension(filename);
    const compressed_exts = [_][]const u8{
        ".png", ".jpg", ".jpeg", ".gif", ".webp", // Images
        ".zip", ".gz", ".zst", ".br", ".xz", // Archives
        ".mp3", ".mp4", ".webm", ".ogg", // Media
        ".woff", ".woff2", // Fonts
    };
    for (compressed_exts) |cext| {
        if (std.ascii.eqlIgnoreCase(ext, cext)) return true;
    }
    return false;
}

/// Derive output path for bundle: input.pngine -> input.zip
fn deriveBundleOutputPath(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    std.debug.assert(input.len > 0);

    const stem = std.fs.path.stem(input);
    const dir = std.fs.path.dirname(input);

    const result = if (dir) |d|
        try std.fmt.allocPrint(allocator, "{s}/{s}.zip", .{ d, stem })
    else
        try std.fmt.allocPrint(allocator, "{s}.zip", .{stem});

    return result;
}

/// Derive output path for embed: input.png -> input_embedded.png
fn deriveEmbedOutputPath(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    std.debug.assert(input.len > 0);

    const stem = std.fs.path.stem(input);
    const dir = std.fs.path.dirname(input);

    const result = if (dir) |d|
        try std.fmt.allocPrint(allocator, "{s}/{s}_embedded.png", .{ d, stem })
    else
        try std.fmt.allocPrint(allocator, "{s}_embedded.png", .{stem});

    return result;
}

/// Derive output path for extract: input.png -> input.pngb
fn deriveExtractOutputPath(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    std.debug.assert(input.len > 0);

    const stem = std.fs.path.stem(input);
    const dir = std.fs.path.dirname(input);

    const result = if (dir) |d|
        try std.fmt.allocPrint(allocator, "{s}/{s}.pngb", .{ d, stem })
    else
        try std.fmt.allocPrint(allocator, "{s}.pngb", .{stem});

    return result;
}

/// Report shader entry points for user verification.
/// Extracts entry point names from pipeline descriptors and displays them.
/// Users can verify these match their shader function names.
fn reportEntryPoints(calls: []const Call, module: *const format.Module) void {
    var reported_any = false;

    for (calls) |call| {
        switch (call.call_type) {
            .create_render_pipeline => {
                const data_id = call.params.create_render_pipeline.descriptor_data_id;
                const data = module.data.get(@enumFromInt(data_id));

                // Parse JSON to find entry points
                if (findJsonString(data, "\"vertex\"") != null) {
                    if (!reported_any) {
                        std.debug.print(
                            "\nEntry points (verify these match shader functions):\n",
                            .{},
                        );
                        reported_any = true;
                    }

                    // Extract vertex entry point
                    if (findEntryPointVertex(data)) |ep| {
                        const pid = call.params.create_render_pipeline.pipeline_id;
                        std.debug.print("  Pipeline {d} vertex: {s}\n", .{ pid, ep });
                    }
                    // Extract fragment entry point
                    if (findEntryPointFragment(data)) |ep| {
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
                        std.debug.print(
                            "\nEntry points (verify these match shader functions):\n",
                            .{},
                        );
                        reported_any = true;
                    }

                    if (findEntryPointCompute(data)) |ep| {
                        const pid = call.params.create_compute_pipeline.pipeline_id;
                        std.debug.print("  Pipeline {d} compute: {s}\n", .{ pid, ep });
                    }
                }
            },
            else => {},
        }
    }
}

/// Report buffer usage flags for user verification.
/// Displays buffer IDs and their usage flags in readable format.
///
/// Pre-condition: calls is a valid slice from MockGPU.
/// Post-condition: output is written to stderr (no return value to assert).
fn reportBufferUsage(calls: []const Call) void {
    // Maximum flag string: "UNIFORM|STORAGE|VERTEX|INDEX|COPY_SRC|COPY_DST|MAP_READ|MAP_WRITE"
    // = 7 + 7 + 6 + 5 + 8 + 8 + 8 + 9 + 7 separators = 65 chars max
    const max_flags_len = 65;
    var flags_buf: [128]u8 = undefined;

    // Pre-condition: buffer is large enough for all flags.
    comptime std.debug.assert(flags_buf.len >= max_flags_len);

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

            // Build usage string
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

            // Post-condition: flags_len never exceeds buffer.
            std.debug.assert(flags_len <= flags_buf.len);

            const flags_str = if (flags_len > 0) flags_buf[0..flags_len] else "(none)";
            std.debug.print("  Buffer {d}: size={d}, usage={s}\n", .{ buffer_id, size, flags_str });
        }
    }
}

/// Find a string in JSON data.
fn findJsonString(data: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, data, needle);
}

/// Extract entry point from JSON for a given stage.
/// Returns the entry point name or null if not found.
fn findEntryPointVertex(data: []const u8) ?[]const u8 {
    return findEntryPointForStage(data, "\"vertex\"");
}

fn findEntryPointFragment(data: []const u8) ?[]const u8 {
    return findEntryPointForStage(data, "\"fragment\"");
}

fn findEntryPointCompute(data: []const u8) ?[]const u8 {
    return findEntryPointForStage(data, "\"compute\"");
}

fn findEntryPointForStage(data: []const u8, stage_pattern: []const u8) ?[]const u8 {
    const stage_start = std.mem.indexOf(u8, data, stage_pattern) orelse return null;

    // Find entryPoint within this stage block
    const entry_pattern = "\"entryPoint\":\"";
    const ep_start = std.mem.indexOfPos(u8, data, stage_start, entry_pattern) orelse return null;

    const name_start = ep_start + entry_pattern.len;
    if (name_start >= data.len) return null;

    // Find closing quote
    const name_end = std.mem.indexOfPos(u8, data, name_start, "\"") orelse return null;

    return data[name_start..name_end];
}

/// Validate descriptor binary formats in GPU calls.
/// Returns count of invalid descriptors found.
///
/// Pre-condition: calls and module must be valid.
/// Post-condition: returns 0 if all descriptors valid.
fn validateDescriptors(calls: []const Call, module: *const format.Module) u32 {
    var error_count: u32 = 0;

    for (calls) |call| {
        switch (call.call_type) {
            .create_texture => {
                const data_id = call.params.create_texture.descriptor_data_id;
                const data = module.data.get(@enumFromInt(data_id));

                if (data.len < 2) {
                    std.debug.print(
                        "  Error: texture descriptor too short ({d} bytes)\n",
                        .{data.len},
                    );
                    error_count += 1;
                    continue;
                }

                // Validate type tag
                const type_tag = data[0];
                if (type_tag != @intFromEnum(DescriptorEncoder.DescriptorType.texture)) {
                    std.debug.print(
                        "  Error: texture descriptor has invalid type tag 0x{X:0>2}\n",
                        .{type_tag},
                    );
                    error_count += 1;
                }
            },
            .create_sampler => {
                const data_id = call.params.create_sampler.descriptor_data_id;
                const data = module.data.get(@enumFromInt(data_id));

                if (data.len < 2) {
                    std.debug.print(
                        "  Error: sampler descriptor too short ({d} bytes)\n",
                        .{data.len},
                    );
                    error_count += 1;
                    continue;
                }

                // Validate type tag
                const type_tag = data[0];
                if (type_tag != @intFromEnum(DescriptorEncoder.DescriptorType.sampler)) {
                    std.debug.print(
                        "  Error: sampler descriptor has invalid type tag 0x{X:0>2}\n",
                        .{type_tag},
                    );
                    error_count += 1;
                }
            },
            .create_bind_group => {
                const data_id = call.params.create_bind_group.entry_data_id;
                const data = module.data.get(@enumFromInt(data_id));

                if (data.len < 2) {
                    std.debug.print(
                        "  Error: bind group descriptor too short ({d} bytes)\n",
                        .{data.len},
                    );
                    error_count += 1;
                    continue;
                }

                // Validate type tag
                const type_tag = data[0];
                if (type_tag != @intFromEnum(DescriptorEncoder.DescriptorType.bind_group)) {
                    std.debug.print(
                        "  Error: bind group descriptor has invalid type tag 0x{X:0>2}\n",
                        .{type_tag},
                    );
                    error_count += 1;
                    continue;
                }

                // Validate field count is at least 2 (layout + entries)
                const field_count = data[1];
                if (field_count < 2) {
                    std.debug.print(
                        "  Error: bind group has invalid field count {d} (expected >= 2)\n",
                        .{field_count},
                    );
                    error_count += 1;
                }
            },
            else => {},
        }
    }

    return error_count;
}

/// Validate that bind groups are set before draw calls.
/// Returns count of draw calls that may have missing bind group setup.
///
/// Checks the call sequence for each render pass to verify that set_bind_group
/// appears between set_pipeline and draw/draw_indexed calls. This catches the
/// common mistake of forgetting bindGroups=[...] in render pass definitions.
fn validateBindGroupSetup(calls: []const Call) u32 {
    // Pre-condition: calls slice is valid.
    comptime std.debug.assert(@sizeOf(Call) > 0);

    var warning_count: u32 = 0;

    // Track state within each render pass
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
            .end_pass => {
                in_render_pass = false;
            },
            .set_pipeline => {
                if (in_render_pass) {
                    pipeline_set = true;
                }
            },
            .set_bind_group => {
                if (in_render_pass) {
                    bind_group_set = true;
                }
            },
            .draw, .draw_indexed => {
                // Check if pipeline uses bind groups but none were set
                if (in_render_pass and pipeline_set and !bind_group_set) {
                    // This is a heuristic - we warn but don't error since some
                    // pipelines legitimately don't use bind groups
                    warning_count += 1;
                    std.debug.print(
                        "  Warning: draw call without set_bind_group\n",
                        .{},
                    );
                }
            },
            else => {},
        }
    }

    // Post-condition: warning_count is bounded by number of draw calls.
    std.debug.assert(warning_count <= calls.len);

    return warning_count;
}

/// Read binary file into buffer.
/// Caller owns returned memory.
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

/// Compile source using appropriate compiler based on file extension.
///
/// - `.pngine` files use the new DSL compiler (macro-based syntax)
/// - `.pbsf` files use the legacy PBSF compiler (S-expression syntax)
/// - Other extensions default to DSL compiler
///
/// Returns owned PNGB bytecode that caller must free.
fn compileSource(allocator: std.mem.Allocator, path: []const u8, source: [:0]const u8) ![]u8 {
    const extension = std.fs.path.extension(path);

    if (std.mem.eql(u8, extension, ".pbsf")) {
        // Legacy PBSF format (S-expressions)
        return pngine.compile(allocator, source);
    } else {
        // DSL format (.pngine or unknown)
        // Pass base_dir for asset embedding and file_path for import resolution
        // Use "." when path has no directory component (e.g., "file.pngine")
        const base_dir = std.fs.path.dirname(path) orelse ".";

        // Find miniray for WGSL reflection
        const miniray_path = findMinirayPath();

        return pngine.dsl.compileWithOptions(allocator, source, .{
            .base_dir = base_dir,
            .file_path = path,
            .miniray_path = miniray_path,
        });
    }
}

/// Find miniray binary for WGSL reflection.
///
/// Checks in order:
/// 1. PNGINE_MINIRAY_PATH environment variable
/// 2. Development path (../miniray/miniray relative to pngine repo)
/// 3. Default: null (uses PATH lookup)
fn findMinirayPath() ?[]const u8 {
    // Check environment variable
    if (std.posix.getenv("PNGINE_MINIRAY_PATH")) |path| {
        if (path.len > 0) {
            return path;
        }
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

    // Fall back to PATH lookup (may not work if miniray in PATH is minifier-only)
    return null;
}

/// Read entire file into sentinel-terminated buffer.
///
/// Caller owns returned memory and must free with same allocator.
/// Returns error.FileTooLarge if file exceeds max_file_size.
///
/// Post-condition: returned slice is null-terminated at index [len].
fn readSourceFile(allocator: std.mem.Allocator, path: []const u8) ![:0]const u8 {
    // Pre-condition: path is non-empty
    std.debug.assert(path.len > 0);

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const size: u32 = if (stat.size > max_file_size)
        return error.FileTooLarge
    else
        @intCast(stat.size);

    // Allocate buffer with sentinel
    const buffer = try allocator.allocSentinel(u8, size, 0);
    errdefer allocator.free(buffer);

    // Read entire file with bounded loop
    var bytes_read: u32 = 0;
    for (0..size + 1) |_| {
        if (bytes_read >= size) break;
        const n: u32 = @intCast(try file.read(buffer[bytes_read..]));
        if (n == 0) break; // EOF
        bytes_read += n;
    }

    // Post-condition: buffer is sentinel-terminated
    std.debug.assert(buffer[size] == 0);

    return buffer;
}

/// Write data to file, creating or truncating as needed.
///
/// Pre-condition: path is non-empty, data is valid.
/// Post-condition: file contains exactly data bytes.
fn writeOutputFile(path: []const u8, data: []const u8) !void {
    // Pre-conditions
    std.debug.assert(path.len > 0);
    std.debug.assert(data.len > 0);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
}

/// Derive output path from input path by replacing extension with .pngb.
///
/// Caller owns returned memory and must free with same allocator.
/// Examples:
///   "input.pbsf" -> "input.pngb"
///   "path/to/file.pbsf" -> "path/to/file.pngb"
///   "noext" -> "noext.pngb"
fn deriveOutputPath(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    // Pre-condition: input path is non-empty
    std.debug.assert(input.len > 0);

    const stem = std.fs.path.stem(input);
    const dir = std.fs.path.dirname(input);

    const result = if (dir) |d|
        try std.fmt.allocPrint(allocator, "{s}/{s}.pngb", .{ d, stem })
    else
        try std.fmt.allocPrint(allocator, "{s}.pngb", .{stem});

    // Post-condition: result ends with .pngb
    std.debug.assert(std.mem.endsWith(u8, result, ".pngb"));

    return result;
}

/// Map error to exit code and print message.
/// Returns appropriate exit code for the error type.
fn handleError(err: anyerror) u8 {
    std.debug.print("Fatal error: {}\n", .{err});
    return switch (err) {
        error.OutOfMemory => 2,
        error.FileNotFound => 2,
        error.AccessDenied => 2,
        else => 1,
    };
}

/// Print usage information to stderr.
fn printUsage() void {
    std.debug.print(
        \\PNGine - DSL/PBSF to PNGB compiler
        \\
        \\Usage:
        \\  pngine <input.pngine> [-o <output.png>]          Create self-contained PNG
        \\  pngine <input.pngine> --frame [-s WxH] [-t time] Render actual frame
        \\  pngine compile <input> [-o <output.pngb>]        Compile to bytecode only
        \\  pngine check <input>                             Validate bytecode
        \\  pngine embed <image.png> <bytecode.pngb>         Embed into existing PNG
        \\  pngine extract <file.png|file.zip>               Extract bytecode
        \\  pngine bundle <input.pngine> [-o <output.zip>]   Create ZIP bundle
        \\  pngine list <file.png|file.zip>                  List contents
        \\
        \\Commands:
        \\  compile     Compile source to PNGB bytecode
        \\  check       Validate bytecode (supports .pngine, .pngb, .png, .zip)
        \\  render      Create self-contained PNG with bytecode + WASM runtime
        \\  embed       Embed PNGB bytecode into a PNG image
        \\  extract     Extract PNGB bytecode from PNG or ZIP
        \\  bundle      Create ZIP bundle with bytecode and manifest
        \\  list        List contents of PNG or ZIP file
        \\  help        Show this help message
        \\  version     Show version information
        \\
        \\Render Options (use 'pngine render -h' for details):
        \\  -o, --output <path>   Output file path (default: <input>.png)
        \\  -f, --frame           Render actual frame via GPU (default: 1x1 transparent)
        \\  -s, --size <WxH>      Output dimensions with --frame (default: 512x512)
        \\  -t, --time <seconds>  Time value for animation (default: 0.0)
        \\  --no-embed            Don't embed bytecode in PNG
        \\  --no-runtime          Don't embed WASM runtime (smaller PNG)
        \\
        \\Bundle Options:
        \\  --assets <dir>        Include assets directory in bundle
        \\  --no-runtime          Don't include pngine.wasm in bundle
        \\
        \\Supported formats:
        \\  .pngine     DSL format (macro-based syntax)
        \\  .pbsf       Legacy PBSF format (S-expressions)
        \\  .pngb       Compiled bytecode
        \\  .png        PNG images (with optional embedded bytecode + runtime)
        \\  .zip        ZIP bundles (manifest.json + main.pngb)
        \\
        \\Examples:
        \\  pngine shader.pngine                      # Self-contained PNG (~30KB)
        \\  pngine shader.pngine --no-runtime         # Smaller PNG (~500 bytes)
        \\  pngine shader.pngine --frame              # 512x512 rendered preview
        \\  pngine shader.pngine --frame -s 1920x1080 # 1080p rendered frame
        \\  pngine check output.png                   # Verify embedded bytecode
        \\  pngine extract output.png -o shader.pngb  # Extract bytecode from PNG
        \\  pngine bundle shader.pngine               # Create ZIP bundle
        \\  pngine list bundle.zip                    # List ZIP contents
        \\
    , .{});
}

/// Print version information to stderr.
fn printVersion() void {
    std.debug.print(
        \\pngine 0.1.0
        \\DSL/PBSF to PNGB compiler for WebGPU bytecode
        \\
    , .{});
}

// ============================================================================
// Tests
// ============================================================================

test "deriveOutputPath: simple filename" {
    const allocator = std.testing.allocator;
    const result = try deriveOutputPath(allocator, "input.pbsf");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("input.pngb", result);
}

test "deriveOutputPath: with directory" {
    const allocator = std.testing.allocator;
    const result = try deriveOutputPath(allocator, "path/to/file.pbsf");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("path/to/file.pngb", result);
}

test "deriveOutputPath: no extension" {
    const allocator = std.testing.allocator;
    const result = try deriveOutputPath(allocator, "noext");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("noext.pngb", result);
}

test "deriveOutputPath: handles OOM gracefully" {
    var fail_index: usize = 0;
    while (fail_index < 10) : (fail_index += 1) {
        var failing_alloc = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });

        const result = deriveOutputPath(failing_alloc.allocator(), "test.pbsf");

        if (failing_alloc.has_induced_failure) {
            try std.testing.expectError(error.OutOfMemory, result);
        } else {
            const path = try result;
            failing_alloc.allocator().free(path);
            break;
        }
    }
}

test "deriveOutputPath: multiple extensions" {
    const allocator = std.testing.allocator;
    const result = try deriveOutputPath(allocator, "file.tar.pbsf");
    defer allocator.free(result);
    // stem returns "file.tar", so result is "file.tar.pngb"
    try std.testing.expectEqualStrings("file.tar.pngb", result);
}

test "deriveOutputPath: hidden file" {
    const allocator = std.testing.allocator;
    const result = try deriveOutputPath(allocator, ".hidden");
    defer allocator.free(result);
    try std.testing.expectEqualStrings(".hidden.pngb", result);
}

test "fuzz deriveOutputPath" {
    // Property-based fuzz test for path derivation.
    // Properties verified:
    // 1. Output always ends with ".pngb"
    // 2. Output length is bounded (stem + dir + ".pngb")
    // 3. No memory leaks (testing.allocator detects)
    try std.testing.fuzz({}, testDeriveOutputPathProperties, .{});
}

fn testDeriveOutputPathProperties(_: @TypeOf({}), input: []const u8) anyerror!void {
    // Skip empty inputs (pre-condition violation)
    if (input.len == 0) return;

    // Skip inputs with null bytes (invalid path)
    for (input) |c| {
        if (c == 0) return;
    }

    const allocator = std.testing.allocator;
    const result = deriveOutputPath(allocator, input) catch |err| {
        // OOM is acceptable for very long inputs
        if (err == error.OutOfMemory) return;
        return err;
    };
    defer allocator.free(result);

    // Property 1: Output always ends with ".pngb"
    try std.testing.expect(std.mem.endsWith(u8, result, ".pngb"));

    // Property 2: Output contains stem from input
    const input_stem = std.fs.path.stem(input);
    try std.testing.expect(std.mem.indexOf(u8, result, input_stem) != null);

    // Property 3: Output length is reasonable
    // stem + "/" + ".pngb" should not exceed input.len + 5
    try std.testing.expect(result.len <= input.len + 5);
}

// ============================================================================
// isCompressedExtension Tests
// ============================================================================

test "isCompressedExtension: image formats" {
    try std.testing.expect(isCompressedExtension("photo.png"));
    try std.testing.expect(isCompressedExtension("photo.PNG"));
    try std.testing.expect(isCompressedExtension("photo.Png"));
    try std.testing.expect(isCompressedExtension("image.jpg"));
    try std.testing.expect(isCompressedExtension("image.jpeg"));
    try std.testing.expect(isCompressedExtension("animation.gif"));
    try std.testing.expect(isCompressedExtension("modern.webp"));
}

test "isCompressedExtension: archive formats" {
    try std.testing.expect(isCompressedExtension("data.zip"));
    try std.testing.expect(isCompressedExtension("data.gz"));
    try std.testing.expect(isCompressedExtension("data.zst"));
    try std.testing.expect(isCompressedExtension("data.br"));
    try std.testing.expect(isCompressedExtension("data.xz"));
}

test "isCompressedExtension: media formats" {
    try std.testing.expect(isCompressedExtension("audio.mp3"));
    try std.testing.expect(isCompressedExtension("video.mp4"));
    try std.testing.expect(isCompressedExtension("video.webm"));
    try std.testing.expect(isCompressedExtension("audio.ogg"));
}

test "isCompressedExtension: font formats" {
    try std.testing.expect(isCompressedExtension("font.woff"));
    try std.testing.expect(isCompressedExtension("font.woff2"));
}

test "isCompressedExtension: uncompressed formats return false" {
    try std.testing.expect(!isCompressedExtension("code.zig"));
    try std.testing.expect(!isCompressedExtension("data.json"));
    try std.testing.expect(!isCompressedExtension("readme.txt"));
    try std.testing.expect(!isCompressedExtension("shader.wgsl"));
    try std.testing.expect(!isCompressedExtension("noextension"));
    try std.testing.expect(!isCompressedExtension(""));
    try std.testing.expect(!isCompressedExtension(".hidden"));
}

test "isCompressedExtension: edge cases" {
    // Hidden file with compressed extension
    try std.testing.expect(isCompressedExtension(".backup.png"));
    // Multiple extensions - only last extension matters
    try std.testing.expect(isCompressedExtension("archive.tar.gz"));
    // Path with extension
    try std.testing.expect(isCompressedExtension("path/to/file.png"));
    // Hidden file with no extension (dot is filename, not extension separator)
    try std.testing.expect(!isCompressedExtension(".png"));
    // Case insensitive
    try std.testing.expect(isCompressedExtension("IMAGE.PNG"));
    try std.testing.expect(isCompressedExtension("Music.MP3"));
}

// ============================================================================
// deriveBundleOutputPath Tests
// ============================================================================

test "deriveBundleOutputPath: simple filename" {
    const allocator = std.testing.allocator;
    const result = try deriveBundleOutputPath(allocator, "shader.pngine");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("shader.zip", result);
}

test "deriveBundleOutputPath: with directory" {
    const allocator = std.testing.allocator;
    const result = try deriveBundleOutputPath(allocator, "shaders/effect.pngine");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("shaders/effect.zip", result);
}

test "deriveBundleOutputPath: no extension" {
    const allocator = std.testing.allocator;
    const result = try deriveBundleOutputPath(allocator, "shader");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("shader.zip", result);
}

test "deriveBundleOutputPath: hidden file" {
    const allocator = std.testing.allocator;
    const result = try deriveBundleOutputPath(allocator, ".shader");
    defer allocator.free(result);
    try std.testing.expectEqualStrings(".shader.zip", result);
}

test "deriveBundleOutputPath: OOM handling" {
    var fail_index: usize = 0;
    while (fail_index < 10) : (fail_index += 1) {
        var failing_alloc = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });

        const result = deriveBundleOutputPath(failing_alloc.allocator(), "test.pngine");

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
// extractFromZip Tests
// ============================================================================

test "extractFromZip: valid bundle with manifest" {
    const allocator = std.testing.allocator;

    // Create a valid ZIP bundle
    var writer = zip.ZipWriter.init(allocator);
    defer writer.deinit();

    try writer.addFile("manifest.json", "{\"version\":1,\"entry\":\"main.pngb\"}", .store);
    try writer.addFile("main.pngb", "PNGB\x01\x00bytecode", .store);

    const zip_data = try writer.finish();
    defer allocator.free(zip_data);

    // Extract bytecode
    const bytecode = try extractFromZip(allocator, zip_data);
    defer allocator.free(bytecode);

    try std.testing.expectEqualStrings("PNGB\x01\x00bytecode", bytecode);
}

test "extractFromZip: fallback to main.pngb when manifest missing" {
    const allocator = std.testing.allocator;

    var writer = zip.ZipWriter.init(allocator);
    defer writer.deinit();

    // No manifest.json, but main.pngb exists - should use fallback
    try writer.addFile("main.pngb", "PNGB\x01\x00bytecode", .store);

    const zip_data = try writer.finish();
    defer allocator.free(zip_data);

    // Should succeed with fallback to main.pngb
    const bytecode = try extractFromZip(allocator, zip_data);
    defer allocator.free(bytecode);

    try std.testing.expectEqualStrings("PNGB\x01\x00bytecode", bytecode);
}

test "extractFromZip: empty zip returns error" {
    const allocator = std.testing.allocator;

    var writer = zip.ZipWriter.init(allocator);
    defer writer.deinit();

    // Empty ZIP - no manifest, no main.pngb
    const zip_data = try writer.finish();
    defer allocator.free(zip_data);

    const result = extractFromZip(allocator, zip_data);
    try std.testing.expectError(error.FileNotFound, result);
}

test "extractFromZip: missing entry file returns error" {
    const allocator = std.testing.allocator;

    var writer = zip.ZipWriter.init(allocator);
    defer writer.deinit();

    // Manifest points to non-existent file
    try writer.addFile("manifest.json", "{\"version\":1,\"entry\":\"missing.pngb\"}", .store);

    const zip_data = try writer.finish();
    defer allocator.free(zip_data);

    const result = extractFromZip(allocator, zip_data);
    try std.testing.expectError(error.FileNotFound, result);
}

test "extractFromZip: nested entry path works" {
    const allocator = std.testing.allocator;

    var writer = zip.ZipWriter.init(allocator);
    defer writer.deinit();

    try writer.addFile("manifest.json", "{\"version\":1,\"entry\":\"shaders/main.pngb\"}", .store);
    try writer.addFile("shaders/main.pngb", "nested bytecode", .store);

    const zip_data = try writer.finish();
    defer allocator.free(zip_data);

    const bytecode = try extractFromZip(allocator, zip_data);
    defer allocator.free(bytecode);

    try std.testing.expectEqualStrings("nested bytecode", bytecode);
}

test "extractFromZip: deflate compressed entry" {
    const allocator = std.testing.allocator;

    var writer = zip.ZipWriter.init(allocator);
    defer writer.deinit();

    try writer.addFile("manifest.json", "{\"version\":1,\"entry\":\"main.pngb\"}", .store);
    // Use deflate for bytecode
    try writer.addFile("main.pngb", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", .deflate);

    const zip_data = try writer.finish();
    defer allocator.free(zip_data);

    const bytecode = try extractFromZip(allocator, zip_data);
    defer allocator.free(bytecode);

    try std.testing.expectEqualStrings("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", bytecode);
}

test "extractFromZip: OOM handling" {
    const allocator = std.testing.allocator;

    // First create valid ZIP
    var writer = zip.ZipWriter.init(allocator);
    defer writer.deinit();
    try writer.addFile("manifest.json", "{\"version\":1,\"entry\":\"main.pngb\"}", .store);
    try writer.addFile("main.pngb", "bytecode", .store);
    const zip_data = try writer.finish();
    defer allocator.free(zip_data);

    // Test OOM at each allocation point
    var fail_index: usize = 0;
    while (fail_index < 20) : (fail_index += 1) {
        var failing_alloc = std.testing.FailingAllocator.init(allocator, .{
            .fail_index = fail_index,
        });

        const result = extractFromZip(failing_alloc.allocator(), zip_data);

        if (failing_alloc.has_induced_failure) {
            // OOM is expected - verify graceful handling (no crash)
            if (result) |data| {
                failing_alloc.allocator().free(data);
            } else |_| {
                // Error is expected, just verify no crash
            }
        } else {
            // No OOM - verify success
            if (result) |data| {
                failing_alloc.allocator().free(data);
            } else |_| {
                // Unexpected error
            }
            break;
        }
    }
}

// ============================================================================
// Bundle Roundtrip Property Tests
// ============================================================================

test "bundle roundtrip: bytecode preserved" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();

    // Generate random bytecode
    var bytecode: [256]u8 = undefined;
    random.bytes(&bytecode);

    // Create bundle
    var writer = zip.ZipWriter.init(allocator);
    defer writer.deinit();
    try writer.addFile("manifest.json", "{\"version\":1,\"entry\":\"main.pngb\"}", .store);
    try writer.addFile("main.pngb", &bytecode, .deflate);
    const zip_data = try writer.finish();
    defer allocator.free(zip_data);

    // Extract and verify
    const extracted = try extractFromZip(allocator, zip_data);
    defer allocator.free(extracted);

    try std.testing.expectEqualSlices(u8, &bytecode, extracted);
}

test "fuzz bundle roundtrip" {
    try std.testing.fuzz({}, testBundleRoundtripProperties, .{});
}

fn testBundleRoundtripProperties(_: @TypeOf({}), input: []const u8) anyerror!void {
    // Skip empty inputs
    if (input.len == 0) return;

    const allocator = std.testing.allocator;

    // Create bundle with input as bytecode
    var writer = zip.ZipWriter.init(allocator);
    defer writer.deinit();

    writer.addFile("manifest.json", "{\"version\":1,\"entry\":\"main.pngb\"}", .store) catch return;
    writer.addFile("main.pngb", input, .deflate) catch return;

    const zip_data = writer.finish() catch return;
    defer allocator.free(zip_data);

    // Extract and verify roundtrip property
    const extracted = extractFromZip(allocator, zip_data) catch return;
    defer allocator.free(extracted);

    // Property: extracted == original
    try std.testing.expectEqualSlices(u8, input, extracted);
}

// ============================================================================
// Embedded WASM Tests
// ============================================================================

test "embedded_wasm: is valid WASM" {
    // Property: embedded WASM starts with WASM magic bytes
    try std.testing.expect(embedded_wasm.len >= 8);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x61, 0x73, 0x6d }, embedded_wasm[0..4]);

    // Property: WASM version is 1
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x00, 0x00, 0x00 }, embedded_wasm[4..8]);
}

test "embedded_wasm: reasonable size" {
    // Property: WASM should be between 1KB and 200KB
    // Note: minimal executor can be quite small (~6KB for command-buffer mode)
    try std.testing.expect(embedded_wasm.len >= 1024);
    try std.testing.expect(embedded_wasm.len <= 200 * 1024);
}

// ============================================================================
// findJsonValue Tests
// ============================================================================

test "findJsonValue: basic extraction" {
    const result = findJsonValue("{\"entry\":\"main.pngb\"}", "\"entry\"");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("main.pngb", result.?);
}

test "findJsonValue: with whitespace" {
    const result = findJsonValue("{\"entry\" : \"file.pngb\"}", "\"entry\"");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("file.pngb", result.?);
}

test "findJsonValue: field not found" {
    const result = findJsonValue("{\"other\":\"value\"}", "\"entry\"");
    try std.testing.expect(result == null);
}

test "findJsonValue: empty JSON" {
    const result = findJsonValue("{}", "\"entry\"");
    try std.testing.expect(result == null);
}

test "findJsonValue: empty string" {
    const result = findJsonValue("", "\"entry\"");
    try std.testing.expect(result == null);
}

test "findJsonValue: nested path" {
    const result = findJsonValue("{\"entry\":\"shaders/main.pngb\"}", "\"entry\"");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("shaders/main.pngb", result.?);
}

test "findJsonValue: special characters in value" {
    const result = findJsonValue("{\"entry\":\"file-v1.2_test.pngb\"}", "\"entry\"");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("file-v1.2_test.pngb", result.?);
}

// ============================================================================
// Corrupted Data Tests
// ============================================================================

test "extractFromZip: corrupted ZIP signature" {
    // Invalid signature (not ZIP)
    const result = extractFromZip(std.testing.allocator, "NOT A ZIP FILE");
    try std.testing.expectError(error.InvalidZip, result);
}

test "extractFromZip: truncated ZIP" {
    const allocator = std.testing.allocator;

    var writer = zip.ZipWriter.init(allocator);
    defer writer.deinit();
    try writer.addFile("manifest.json", "{\"version\":1,\"entry\":\"main.pngb\"}", .store);
    try writer.addFile("main.pngb", "bytecode", .store);
    const zip_data = try writer.finish();
    defer allocator.free(zip_data);

    // Truncate the data
    if (zip_data.len > 20) {
        const truncated = zip_data[0..20];
        const result = extractFromZip(allocator, truncated);
        try std.testing.expectError(error.InvalidZip, result);
    }
}

test "extractFromZip: minimum valid ZIP" {
    // Minimum valid ZIP (end of central directory only - empty archive)
    const empty_zip = [_]u8{
        // End of central directory
        0x50, 0x4b, 0x05, 0x06, // Signature
        0x00, 0x00, // Disk number
        0x00, 0x00, // Central dir disk
        0x00, 0x00, // Entries on disk
        0x00, 0x00, // Total entries
        0x00, 0x00, 0x00, 0x00, // Central dir size
        0x00, 0x00, 0x00, 0x00, // Central dir offset
        0x00, 0x00, // Comment length
    };

    // Empty ZIP should fail because no manifest or main.pngb
    const result = extractFromZip(std.testing.allocator, &empty_zip);
    try std.testing.expectError(error.FileNotFound, result);
}

test "extractFromZip: manifest with missing quotes" {
    const allocator = std.testing.allocator;

    var writer = zip.ZipWriter.init(allocator);
    defer writer.deinit();
    // Malformed JSON - missing quotes around value
    try writer.addFile("manifest.json", "{\"entry\":main.pngb}", .store);
    try writer.addFile("main.pngb", "bytecode", .store);
    const zip_data = try writer.finish();
    defer allocator.free(zip_data);

    // Should fall back to main.pngb when JSON parsing fails
    const bytecode = try extractFromZip(allocator, zip_data);
    defer allocator.free(bytecode);
    try std.testing.expectEqualStrings("bytecode", bytecode);
}

// ============================================================================
// OOM Stress Tests
// ============================================================================

test "ZipWriter: OOM at various allocation points" {
    var fail_index: usize = 0;
    while (fail_index < 30) : (fail_index += 1) {
        var failing_alloc = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });

        var writer = zip.ZipWriter.init(failing_alloc.allocator());
        defer writer.deinit();

        const add_result = writer.addFile("test.txt", "test content", .store);
        if (add_result) |_| {
            const finish_result = writer.finish();
            if (finish_result) |data| {
                failing_alloc.allocator().free(data);
                if (!failing_alloc.has_induced_failure) break;
            } else |_| {
                // OOM during finish is expected
            }
        } else |_| {
            // OOM during addFile is expected
        }
    }
}

// ============================================================================
// Fuzz Tests with Corpus
// ============================================================================

test "fuzz findJsonValue" {
    try std.testing.fuzz({}, testFindJsonValueProperties, .{
        .corpus = &.{
            "{}",
            "{\"entry\":\"main.pngb\"}",
            "{\"entry\": \"file.pngb\"}",
            "{\"other\":\"value\"}",
            "{\"entry\":\"path/to/file.pngb\"}",
            "{\"entry\":\"\"}",
        },
    });
}

fn testFindJsonValueProperties(_: @TypeOf({}), input: []const u8) !void {
    // Property: findJsonValue never crashes on any input
    const result = findJsonValue(input, "\"entry\"");

    // Property: if result is found, it's a valid slice of the input
    if (result) |value| {
        // Find where value starts in input
        const value_ptr = @intFromPtr(value.ptr);
        const input_ptr = @intFromPtr(input.ptr);
        const input_end = input_ptr + input.len;

        // Value must be within input bounds
        try std.testing.expect(value_ptr >= input_ptr);
        try std.testing.expect(value_ptr + value.len <= input_end);
    }
}

test "fuzz isCompressedExtension" {
    try std.testing.fuzz({}, testIsCompressedExtensionProperties, .{
        .corpus = &.{
            "file.png",
            "file.jpg",
            "file.zip",
            "file.txt",
            ".hidden",
            "",
            "noextension",
            "path/to/file.gz",
        },
    });
}

fn testIsCompressedExtensionProperties(_: @TypeOf({}), input: []const u8) !void {
    // Property: isCompressedExtension never crashes on any input
    const result = isCompressedExtension(input);

    // Property: result is deterministic
    const result2 = isCompressedExtension(input);
    try std.testing.expectEqual(result, result2);
}
