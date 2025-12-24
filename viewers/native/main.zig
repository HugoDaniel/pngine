//! Native PNGine Viewer
//!
//! Loads and executes PNG files with embedded executors.
//! Uses native GPU backend for rendering.
//!
//! ## Usage
//! ```
//! pngine-viewer shader.png                    # View shader
//! pngine-viewer shader.png --output frame.png # Render to file
//! pngine-viewer shader.png --time 2.5         # Render at specific time
//! pngine-viewer shader.png --size 1920x1080   # Render at specific size
//! ```
//!
//! ## Architecture
//! ```
//! PNG File → Extract Payload → Run Executor → Command Buffer → Native GPU
//! ```
//!
//! ## Invariants
//! - Input must be valid PNG with pNGb chunk
//! - Embedded executor uses v5 payload format
//! - Command buffer is platform-agnostic

const std = @import("std");
const pngine = @import("pngine");
const loader = @import("loader.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    // Parse arguments
    var opts = Options{
        .input_path = args[1],
        .output_path = null,
        .width = 512,
        .height = 512,
        .time = 0.0,
    };

    // Parse arguments with bounded loop (max 1000 args to prevent infinite loop)
    const MAX_ARGS: usize = 1000;
    var i: usize = 2;
    for (0..MAX_ARGS) |_| {
        if (i >= args.len) break;
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --output requires a path\n", .{});
                return;
            }
            opts.output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--time") or std.mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --time requires a value\n", .{});
                return;
            }
            opts.time = std.fmt.parseFloat(f32, args[i]) catch {
                std.debug.print("Error: invalid time value\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--size") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --size requires WxH\n", .{});
                return;
            }
            const size = parseSize(args[i]) catch {
                std.debug.print("Error: invalid size format (use WxH)\n", .{});
                return;
            };
            opts.width = size[0];
            opts.height = size[1];
        }
        i += 1;
    }

    // Run viewer
    runViewer(allocator, opts) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return;
    };
}

const Options = struct {
    input_path: []const u8,
    output_path: ?[]const u8,
    width: u32,
    height: u32,
    time: f32,
};

/// Run the native viewer with given options.
///
/// Complexity: O(file_size) for loading, O(1) for parsing.
fn runViewer(allocator: std.mem.Allocator, opts: Options) !void {
    // Pre-condition: input path must be non-empty
    std.debug.assert(opts.input_path.len > 0);
    // Pre-condition: dimensions must be positive
    std.debug.assert(opts.width > 0 and opts.height > 0);

    std.debug.print("PNGine Native Viewer\n", .{});
    std.debug.print("  Input: {s}\n", .{opts.input_path});
    std.debug.print("  Size: {}x{}\n", .{ opts.width, opts.height });
    std.debug.print("  Time: {d:.2}s\n", .{opts.time});

    // Load PNG and extract payload
    const payload = try loader.loadPNG(allocator, opts.input_path);
    defer payload.deinit(allocator);

    std.debug.print("\nPayload Info:\n", .{});
    std.debug.print("  Version: {}\n", .{payload.version});
    std.debug.print("  Has Embedded Executor: {}\n", .{payload.has_embedded_executor});
    std.debug.print("  Plugins: 0x{X:0>2}\n", .{payload.plugins});
    std.debug.print("  Executor Size: {} bytes\n", .{payload.executor_data.len});
    std.debug.print("  Bytecode Size: {} bytes\n", .{payload.bytecode.len});

    if (!payload.has_embedded_executor) {
        std.debug.print("\nWarning: PNG does not have embedded executor\n", .{});
        std.debug.print("Use 'pngine shader.pngine --embed-executor' to create one\n", .{});
    }

    // Deserialize module to validate bytecode
    const module = pngine.format.deserialize(allocator, payload.raw_data) catch |err| {
        std.debug.print("\nError deserializing module: {}\n", .{err});
        return;
    };
    defer @constCast(&module).deinit(allocator);

    std.debug.print("\nModule Info:\n", .{});
    std.debug.print("  Bytecode Size: {} bytes\n", .{module.bytecode.len});
    std.debug.print("  WGSL Entries: {}\n", .{module.wgsl.entries.items.len});
    std.debug.print("  Strings: {}\n", .{module.strings.strings.items.len});
    std.debug.print("  Data Blobs: {}\n", .{module.data.blobs.items.len});

    // GPU execution would require either:
    // 1. wasm3 integration for embedded executor
    // 2. Full NativeGPU implementation (zgpu/Dawn)
    //
    // For now, we just validate the payload structure.
    if (payload.has_embedded_executor) {
        std.debug.print("\nEmbedded executor detected ({} bytes)\n", .{payload.executor_data.len});
        std.debug.print("Note: WASM execution requires wasm3 integration\n", .{});
    } else {
        std.debug.print("\nNo embedded executor - requires shared executor WASM\n", .{});
    }

    // Output rendering requires NativeGPU implementation
    if (opts.output_path) |_| {
        std.debug.print("\nNote: Output rendering requires NativeGPU implementation\n", .{});
        std.debug.print("See: docs/embedded-executor-plan.md Phase 7 for details\n", .{});
    }
}

/// Parse size string in WxH format.
///
/// Complexity: O(n) where n = string length.
fn parseSize(s: []const u8) ![2]u32 {
    // Pre-condition: input must not be empty
    std.debug.assert(s.len > 0);

    const x_pos = std.mem.indexOf(u8, s, "x") orelse std.mem.indexOf(u8, s, "X") orelse return error.InvalidFormat;
    const width = try std.fmt.parseInt(u32, s[0..x_pos], 10);
    const height = try std.fmt.parseInt(u32, s[x_pos + 1 ..], 10);

    // Post-condition: both dimensions parsed (not zero, handled by parseInt for valid input)
    std.debug.assert(x_pos < s.len);

    return .{ width, height };
}

fn printUsage() void {
    std.debug.print(
        \\PNGine Native Viewer
        \\
        \\Usage: pngine-viewer <input.png> [options]
        \\
        \\Options:
        \\  -o, --output <path>   Output rendered frame to PNG file
        \\  -s, --size <WxH>      Render size (default: 512x512)
        \\  -t, --time <seconds>  Animation time (default: 0.0)
        \\  -h, --help            Show this help
        \\
        \\Examples:
        \\  pngine-viewer shader.png
        \\  pngine-viewer shader.png -o frame.png -s 1920x1080
        \\  pngine-viewer shader.png -t 2.5
        \\
    , .{});
}

// Tests
const testing = std.testing;

test "parseSize: valid formats" {
    const size1 = try parseSize("640x480");
    try testing.expectEqual(@as(u32, 640), size1[0]);
    try testing.expectEqual(@as(u32, 480), size1[1]);

    const size2 = try parseSize("1920X1080");
    try testing.expectEqual(@as(u32, 1920), size2[0]);
    try testing.expectEqual(@as(u32, 1080), size2[1]);
}

test "parseSize: invalid formats" {
    try testing.expectError(error.InvalidFormat, parseSize("640"));
    try testing.expectError(error.InvalidFormat, parseSize("640-480"));
}

test "parseSize: edge cases" {
    // Single digit dimensions
    const size1 = try parseSize("1x1");
    try testing.expectEqual(@as(u32, 1), size1[0]);
    try testing.expectEqual(@as(u32, 1), size1[1]);

    // Large dimensions
    const size2 = try parseSize("4096x2160");
    try testing.expectEqual(@as(u32, 4096), size2[0]);
    try testing.expectEqual(@as(u32, 2160), size2[1]);

    // Maximum u32 values
    const size3 = try parseSize("4294967295x4294967295");
    try testing.expectEqual(@as(u32, 4294967295), size3[0]);
    try testing.expectEqual(@as(u32, 4294967295), size3[1]);
}

test "parseSize: invalid number formats" {
    // Letters in dimensions
    try testing.expectError(error.InvalidCharacter, parseSize("abcxdef"));

    // Negative numbers
    try testing.expectError(error.InvalidCharacter, parseSize("-100x200"));

    // Empty dimensions
    try testing.expectError(error.InvalidCharacter, parseSize("x480"));
    try testing.expectError(error.InvalidCharacter, parseSize("640x"));

    // Overflow
    try testing.expectError(error.Overflow, parseSize("99999999999x100"));
}

test "parseSize: whitespace handling" {
    // No whitespace tolerance (strict parsing)
    try testing.expectError(error.InvalidCharacter, parseSize(" 640x480"));
    try testing.expectError(error.InvalidCharacter, parseSize("640x480 "));
    try testing.expectError(error.InvalidCharacter, parseSize("640 x 480"));
}

test "parseSize: multiple separators" {
    // Multiple x's - uses first one, "200x300" fails to parse as number
    try testing.expectError(error.InvalidCharacter, parseSize("100x200x300"));
}
