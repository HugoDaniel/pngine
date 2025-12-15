//! PNGine CLI - Compile PBSF source to PNGB bytecode.
//!
//! A simple command-line interface for compiling PBSF (PNGine Bytecode Source Format)
//! files into PNGB (PNGine Binary) bytecode.
//!
//! Usage:
//!   pngine compile input.pbsf -o output.pngb
//!   pngine compile input.pbsf              (outputs to input.pngb)
//!
//! Exit codes:
//!   0 - Success
//!   1 - Invalid arguments
//!   2 - File I/O error
//!   3 - Compilation error
//!
//! Invariants:
//!   - All file reads are bounded by max_file_size (16 MiB)
//!   - Output files always contain valid PNGB with correct magic bytes
//!   - All allocations are freed on both success and error paths

const std = @import("std");
const pngine = @import("pngine");

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

    if (std.mem.eql(u8, command, "compile")) {
        return runCompile(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
        return 0;
    } else if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
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
            output_path = args[i];
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

    // Compile
    const bytecode = pngine.compile(allocator, source) catch |err| {
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
        \\PNGine - PBSF to PNGB compiler
        \\
        \\Usage:
        \\  pngine compile <input.pbsf> [-o <output.pngb>]
        \\  pngine help
        \\  pngine version
        \\
        \\Commands:
        \\  compile     Compile PBSF source to PNGB bytecode
        \\  help        Show this help message
        \\  version     Show version information
        \\
        \\Options:
        \\  -o, --output <path>   Output file path (default: input with .pngb extension)
        \\
        \\Examples:
        \\  pngine compile triangle.pbsf -o triangle.pngb
        \\  pngine compile shader.pbsf
        \\
    , .{});
}

/// Print version information to stderr.
fn printVersion() void {
    std.debug.print(
        \\pngine 0.1.0
        \\PBSF to PNGB compiler for WebGPU bytecode
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
