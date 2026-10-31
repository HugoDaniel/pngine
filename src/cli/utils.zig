//! Shared CLI utilities for file I/O and path handling.
//!
//! Provides common functionality used across all CLI subcommands.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Maximum input file size (16 MiB).
/// Prevents DoS via memory exhaustion from malicious inputs.
pub const max_file_size: u32 = 16 * 1024 * 1024;

/// Read a file from an explicit directory into a buffer.
/// Caller owns returned memory.
///
/// The general form behind `readBinaryFile`; the render command's executor
/// lookup uses it to probe several candidate directories.
///
/// Complexity: O(n) where n = file size
/// Post-condition: Returns owned slice with file contents
pub fn readFileFromDir(gpa: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) ![]u8 {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const size: u32 = if (stat.size > max_file_size)
        return error.FileTooLarge
    else
        @intCast(stat.size);

    const buffer = try gpa.alloc(u8, size);
    errdefer gpa.free(buffer);

    var bytes_read: u32 = 0;
    for (0..size + 1) |_| {
        if (bytes_read >= size) break;
        const n: u32 = @intCast(try file.readStreaming(io, &.{buffer[bytes_read..]}));
        if (n == 0) break;
        bytes_read += n;
    }

    std.debug.assert(buffer.len == size);
    return buffer;
}

/// Read binary file (from CWD) into buffer.
/// Caller owns returned memory.
///
/// Complexity: O(n) where n = file size
///
/// Pre-condition: path.len > 0
/// Post-condition: Returns owned slice with file contents
pub fn readBinaryFile(gpa: Allocator, io: std.Io, path: []const u8) ![]u8 {
    std.debug.assert(path.len > 0);
    return readFileFromDir(gpa, io, std.Io.Dir.cwd(), path);
}

/// Read entire file into sentinel-terminated buffer.
///
/// Caller owns returned memory and must free with same allocator.
/// Returns error.FileTooLarge if file exceeds max_file_size.
///
/// Pre-condition: path.len > 0
/// Post-condition: returned slice is null-terminated at index [len]
pub fn readSourceFile(gpa: Allocator, io: std.Io, path: []const u8) ![:0]const u8 {
    std.debug.assert(path.len > 0);

    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const size: u32 = if (stat.size > max_file_size)
        return error.FileTooLarge
    else
        @intCast(stat.size);

    const buffer = try gpa.allocSentinel(u8, size, 0);
    errdefer gpa.free(buffer);

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

/// Create or truncate `path` as an empty file: the empty-artifact twin of
/// `writeOutputFile`, whose `data.len > 0` assert is right for every artifact
/// an empty one is not. The error path is the same one, so the caller's
/// `reportWriteError` maps both identically.
///
/// Pre-condition: path.len > 0
/// Post-condition: file exists and is empty
pub fn writeEmptyFile(io: std.Io, path: []const u8) !void {
    std.debug.assert(path.len > 0);

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
}

/// Write bytes to stdout. Machine-readable output (`--json`) routes here so it
/// is cleanly pipeable (`| jq`, `| python3 -m json.tool`); human-facing status
/// lines and diagnostics stay on stderr via `std.debug.print`. Callers swallow
/// the error on a closed pipe (`| head`) rather than exiting non-zero.
///
/// Pre-condition: data.len > 0
pub fn writeStdout(io: std.Io, data: []const u8) !void {
    std.debug.assert(data.len > 0);
    try std.Io.File.stdout().writeStreamingAll(io, data);
}

/// `<dir>/<stem><suffix>` — the sibling of `input` with a new ending.
///
/// The one place the stem+dirname+suffix shape lives. Six near-identical
/// `derive*Path` functions across three files collapsed into this call with a
/// literal suffix: `".pngb"` (compile, extract), `"_embedded.png"` (embed),
/// `".zip"` (bundle), `".png"` (render), `".d.ts"` (the `--types` sidecar).
///
/// Caller owns the returned path.
/// Complexity: O(n) where n = input.len
/// Examples:
///   ("input.sjon", ".pngb")   -> "input.pngb"
///   ("path/to/x.png", ".zip") -> "path/to/x.zip"
pub fn deriveSiblingPath(gpa: Allocator, input: []const u8, suffix: []const u8) ![]u8 {
    // Pre-conditions
    std.debug.assert(input.len > 0);
    std.debug.assert(suffix.len > 0);

    const stem = std.fs.path.stem(input);
    const dir = std.fs.path.dirname(input);

    const result = if (dir) |d|
        try std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ d, stem, suffix })
    else
        try std.fmt.allocPrint(gpa, "{s}{s}", .{ stem, suffix });

    // Post-condition: the caller's suffix is what the path ends in. Three of
    // the six originals had this assert (`.pngb`, `.png`, `.d.ts`); the three
    // that did not are exactly the three suffixes it now also covers.
    std.debug.assert(std.mem.endsWith(u8, result, suffix));
    return result;
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
