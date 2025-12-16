//! Extract PNGB bytecode from PNG files.
//!
//! Parses PNG chunks to find the pNGb chunk and returns the PNGB bytecode.
//!
//! ## Usage
//! ```zig
//! const bytecode = try extract.extract(allocator, png_data);
//! defer allocator.free(bytecode);
//! // bytecode is now valid PNGB that can be executed
//! ```
//!
//! ## Invariants
//! - Returns exact original bytecode that was embedded
//! - Caller owns returned memory

const std = @import("std");
const chunk = @import("chunk.zig");
const embed = @import("embed.zig");

pub const Error = error{
    InvalidPng,
    NoPngbChunk,
    InvalidPngbVersion,
    InvalidPngbFormat,
    UnsupportedCompression,
    OutOfMemory,
};

/// Extract PNGB bytecode from PNG data.
///
/// Finds the pNGb chunk and returns the bytecode.
///
/// Pre-conditions:
/// - png_data starts with valid PNG signature
/// - png_data contains a pNGb chunk
///
/// Post-conditions:
/// - Returns exact bytecode that was originally embedded
/// - Caller owns returned slice and must free it
///
/// Complexity: O(png_data.len) to find chunk
pub fn extract(allocator: std.mem.Allocator, png_data: []const u8) Error![]u8 {
    // Validate PNG signature
    if (png_data.len < 8 or !std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE)) {
        return Error.InvalidPng;
    }

    // Pre-condition: valid PNG after signature check
    std.debug.assert(png_data.len >= 8);
    std.debug.assert(std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE));

    // Find pNGb chunk
    var iter = chunk.parseChunks(png_data) catch {
        return Error.InvalidPng;
    };

    while (iter.next() catch { return Error.InvalidPng; }) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &embed.PNGB_CHUNK_TYPE)) {
            return parsePngbChunk(allocator, c.data);
        }
    }

    return Error.NoPngbChunk;
}

/// Parse pNGb chunk data.
fn parsePngbChunk(allocator: std.mem.Allocator, data: []const u8) Error![]u8 {
    // Minimum: version (1) + flags (1) + some payload
    if (data.len < 3) {
        return Error.InvalidPngbFormat;
    }

    // Pre-condition: data has header
    std.debug.assert(data.len >= 3);

    const version = data[0];
    const flags = data[1];
    const payload = data[2..];

    // Check version
    if (version != embed.PNGB_VERSION) {
        return Error.InvalidPngbVersion;
    }

    // Check compression flag (not supported yet)
    const is_compressed = (flags & embed.FLAG_COMPRESSED) != 0;
    if (is_compressed) {
        return Error.UnsupportedCompression;
    }

    // Return copy of raw payload
    const result = allocator.alloc(u8, payload.len) catch {
        return Error.OutOfMemory;
    };
    @memcpy(result, payload);

    // Post-condition: result matches payload exactly
    std.debug.assert(result.len == payload.len);

    return result;
}

/// Check if PNG data contains a pNGb chunk.
///
/// Quick check without allocation.
pub fn hasPngb(png_data: []const u8) bool {
    if (png_data.len < 8 or !std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE)) {
        return false;
    }

    // Post-condition: at this point we have valid PNG signature
    std.debug.assert(png_data.len >= 8);
    std.debug.assert(std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE));

    var iter = chunk.parseChunks(png_data) catch return false;

    while (iter.next() catch null) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &embed.PNGB_CHUNK_TYPE)) {
            return true;
        }
    }

    return false;
}

/// Get pNGb chunk info without extracting.
///
/// Returns chunk metadata for inspection.
pub const PngbInfo = struct {
    version: u8,
    compressed: bool,
    payload_size: usize,
};

pub fn getPngbInfo(png_data: []const u8) Error!PngbInfo {
    if (png_data.len < 8 or !std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE)) {
        return Error.InvalidPng;
    }

    // Pre-condition: valid PNG
    std.debug.assert(png_data.len >= 8);
    std.debug.assert(std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE));

    var iter = chunk.parseChunks(png_data) catch {
        return Error.InvalidPng;
    };

    while (iter.next() catch { return Error.InvalidPng; }) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &embed.PNGB_CHUNK_TYPE)) {
            if (c.data.len < 2) {
                return Error.InvalidPngbFormat;
            }

            const version = c.data[0];
            const flags = c.data[1];
            const payload_size = c.data.len - 2;
            const is_compressed = (flags & embed.FLAG_COMPRESSED) != 0;

            return PngbInfo{
                .version = version,
                .compressed = is_compressed,
                .payload_size = payload_size,
            };
        }
    }

    return Error.NoPngbChunk;
}

// ============================================================================
// Tests
// ============================================================================

fn createMinimalPng(allocator: std.mem.Allocator) ![]u8 {
    var png_buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer png_buf.deinit(allocator);

    try png_buf.appendSlice(allocator, &chunk.PNG_SIGNATURE);

    const ihdr_data = [13]u8{
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x00, 0x00, 0x00, 0x00,
    };
    try chunk.writeChunk(&png_buf, allocator, chunk.ChunkType.IHDR, &ihdr_data);

    const idat_data = [_]u8{ 0x08, 0xD7, 0x63, 0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01 };
    try chunk.writeChunk(&png_buf, allocator, chunk.ChunkType.IDAT, &idat_data);

    try chunk.writeChunk(&png_buf, allocator, chunk.ChunkType.IEND, "");

    return png_buf.toOwnedSlice(allocator);
}

test "extract: roundtrip with embed" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Create test bytecode
    var bytecode: [128]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    for (4..128) |i| {
        bytecode[i] = @intCast(i & 0xFF);
    }

    // Embed
    const embedded = try embed.embed(allocator, png_data, &bytecode);
    defer allocator.free(embedded);

    // Extract
    const extracted = try extract(allocator, embedded);
    defer allocator.free(extracted);

    // Verify roundtrip
    try std.testing.expectEqualSlices(u8, &bytecode, extracted);
}

test "extract: roundtrip with large data" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Large bytecode
    var bytecode: [2048]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    @memset(bytecode[4..], 'X');

    // Embed
    const embedded = try embed.embed(allocator, png_data, &bytecode);
    defer allocator.free(embedded);

    // Extract
    const extracted = try extract(allocator, embedded);
    defer allocator.free(extracted);

    // Verify exact roundtrip
    try std.testing.expectEqualSlices(u8, &bytecode, extracted);
}

test "extract: hasPngb detection" {
    const allocator = std.testing.allocator;

    // Create PNG without pNGb
    const png_without = try createMinimalPng(allocator);
    defer allocator.free(png_without);

    try std.testing.expect(!hasPngb(png_without));

    // Create PNG with pNGb
    var bytecode: [32]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    @memset(bytecode[4..], 0);

    const png_with = try embed.embed(allocator, png_without, &bytecode);
    defer allocator.free(png_with);

    try std.testing.expect(hasPngb(png_with));
}

test "extract: getPngbInfo returns correct metadata" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Bytecode
    var bytecode: [32]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    @memset(bytecode[4..], 0);

    const embedded = try embed.embed(allocator, png_data, &bytecode);
    defer allocator.free(embedded);

    const info = try getPngbInfo(embedded);
    try std.testing.expectEqual(embed.PNGB_VERSION, info.version);
    try std.testing.expect(!info.compressed);
    try std.testing.expectEqual(@as(usize, 32), info.payload_size);
}

test "extract: invalid PNG rejected" {
    const allocator = std.testing.allocator;
    const bad_data = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expectError(Error.InvalidPng, extract(allocator, &bad_data));
}

test "extract: PNG without pNGb returns error" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    try std.testing.expectError(Error.NoPngbChunk, extract(allocator, png_data));
}
