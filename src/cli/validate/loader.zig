//! Bytecode and file loading for validate command.
//!
//! Handles loading bytecode from various input formats.

const std = @import("std");
const pngine = @import("pngine");
const types = @import("types.zig");

/// Load bytecode from source file (compiles if needed).
///
/// Pre-condition: path is non-empty
/// Post-condition: Returns owned bytecode slice (caller must free)
pub fn loadBytecode(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    // Pre-condition: path is non-empty
    std.debug.assert(path.len > 0);

    const extension = std.fs.path.extension(path);

    // For .pngb files, just read directly
    if (std.mem.eql(u8, extension, ".pngb")) {
        return readFile(allocator, io, path);
    }

    // For .png files, extract embedded bytecode
    if (std.mem.eql(u8, extension, ".png")) {
        const png_data = try readFile(allocator, io, path);
        defer allocator.free(png_data);

        const extracted = try pngine.png.extract.extract(allocator, png_data);
        return extracted;
    }

    // For .pngine or .pbsf, compile first
    const source = try readFile(allocator, io, path);
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

/// Read file with size limit.
///
/// Pre-condition: path is non-empty
/// Post-condition: Returns owned buffer (caller must free)
pub fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const size: u32 = if (stat.size > types.max_file_size)
        return error.FileTooLarge
    else
        @intCast(stat.size);

    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    // Read file in bounded loop
    var bytes_read: u32 = 0;
    for (0..size + 1) |_| {
        if (bytes_read >= size) break;
        const n: u32 = @intCast(try file.readStreaming(io, &.{buffer[bytes_read..]}));
        if (n == 0) break;
        bytes_read += n;
    }

    return buffer;
}
