//! Shared CLI utilities for file I/O and path handling.
//!
//! Provides common functionality used across all CLI subcommands.

const std = @import("std");

/// Maximum input file size (16 MiB).
/// Prevents DoS via memory exhaustion from malicious inputs.
pub const max_file_size: u32 = 16 * 1024 * 1024;

/// Read binary file into buffer.
/// Caller owns returned memory.
///
/// Complexity: O(n) where n = file size
///
/// Pre-condition: path.len > 0
/// Post-condition: Returns owned slice with file contents
pub fn readBinaryFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    std.debug.assert(path.len > 0);

    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const size: u32 = if (stat.size > max_file_size)
        return error.FileTooLarge
    else
        @intCast(stat.size);

    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    var bytes_read: u32 = 0;
    for (0..size + 1) |_| {
        if (bytes_read >= size) break;
        const n: u32 = @intCast(try file.readStreaming(io, &.{buffer[bytes_read..]}));
        if (n == 0) break;
        bytes_read += n;
    }

    return buffer;
}

/// Read entire file into sentinel-terminated buffer.
///
/// Caller owns returned memory and must free with same allocator.
/// Returns error.FileTooLarge if file exceeds max_file_size.
///
/// Pre-condition: path.len > 0
/// Post-condition: returned slice is null-terminated at index [len]
pub fn readSourceFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]const u8 {
    std.debug.assert(path.len > 0);

    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const size: u32 = if (stat.size > max_file_size)
        return error.FileTooLarge
    else
        @intCast(stat.size);

    const buffer = try allocator.allocSentinel(u8, size, 0);
    errdefer allocator.free(buffer);

    var bytes_read: u32 = 0;
    for (0..size + 1) |_| {
        if (bytes_read >= size) break;
        const n: u32 = @intCast(try file.readStreaming(io, &.{buffer[bytes_read..]}));
        if (n == 0) break;
        bytes_read += n;
    }

    std.debug.assert(buffer[size] == 0);
    return buffer;
}

/// Write data to file, creating or truncating as needed.
///
/// Pre-condition: path.len > 0, data.len > 0
/// Post-condition: file contains exactly data bytes
pub fn writeOutputFile(io: std.Io, path: []const u8, data: []const u8) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(data.len > 0);

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

/// Derive output path from input path by replacing extension with .pngb.
///
/// Caller owns returned memory.
/// Examples:
///   "input.pbsf" -> "input.pngb"
///   "path/to/file.pngine" -> "path/to/file.pngb"
pub fn deriveOutputPath(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    std.debug.assert(input.len > 0);

    const stem = std.fs.path.stem(input);
    const dir = std.fs.path.dirname(input);

    const result = if (dir) |d|
        try std.fmt.allocPrint(allocator, "{s}/{s}.pngb", .{ d, stem })
    else
        try std.fmt.allocPrint(allocator, "{s}.pngb", .{stem});

    std.debug.assert(std.mem.endsWith(u8, result, ".pngb"));
    return result;
}

/// Derive output path for embed: input.png -> input_embedded.png
pub fn deriveEmbedOutputPath(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    std.debug.assert(input.len > 0);

    const stem = std.fs.path.stem(input);
    const dir = std.fs.path.dirname(input);

    return if (dir) |d|
        try std.fmt.allocPrint(allocator, "{s}/{s}_embedded.png", .{ d, stem })
    else
        try std.fmt.allocPrint(allocator, "{s}_embedded.png", .{stem});
}

/// Derive output path for extract: input.png -> input.pngb
pub fn deriveExtractOutputPath(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    std.debug.assert(input.len > 0);

    const stem = std.fs.path.stem(input);
    const dir = std.fs.path.dirname(input);

    return if (dir) |d|
        try std.fmt.allocPrint(allocator, "{s}/{s}.pngb", .{ d, stem })
    else
        try std.fmt.allocPrint(allocator, "{s}.pngb", .{stem});
}

/// Derive output path for bundle: input.pngine -> input.zip
pub fn deriveBundleOutputPath(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    std.debug.assert(input.len > 0);

    const stem = std.fs.path.stem(input);
    const dir = std.fs.path.dirname(input);

    return if (dir) |d|
        try std.fmt.allocPrint(allocator, "{s}/{s}.zip", .{ d, stem })
    else
        try std.fmt.allocPrint(allocator, "{s}.zip", .{stem});
}

/// Map error to exit code and print message.
pub fn handleError(err: anyerror) u8 {
    std.debug.print("Fatal error: {}\n", .{err});
    return switch (err) {
        error.OutOfMemory => 2,
        error.FileNotFound => 2,
        error.AccessDenied => 2,
        else => 1,
    };
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
    const result = try deriveOutputPath(allocator, "path/to/input.pbsf");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("path/to/input.pngb", result);
}

test "deriveOutputPath: no extension" {
    const allocator = std.testing.allocator;
    const result = try deriveOutputPath(allocator, "noext");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("noext.pngb", result);
}

test "deriveOutputPath: multiple extensions" {
    const allocator = std.testing.allocator;
    const result = try deriveOutputPath(allocator, "file.tar.gz");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("file.tar.pngb", result);
}

test "deriveBundleOutputPath: simple filename" {
    const allocator = std.testing.allocator;
    const result = try deriveBundleOutputPath(allocator, "shader.pngine");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("shader.zip", result);
}
