//! Embed PNGB bytecode into PNG files.
//!
//! Creates a pNGb ancillary chunk containing bytecode and inserts it
//! before the IEND chunk in a valid PNG file.
//!
//! ## pNGb Chunk Format
//! ```
//! Offset  Size  Description
//! ------  ----  -----------
//! 0       1     Version (0x01)
//! 1       1     Flags (bit 0: compressed - reserved for future)
//! 2       N     Payload (PNGB bytecode)
//! ```
//!
//! ## Invariants
//! - Output is always a valid PNG file
//! - pNGb chunk is inserted immediately before IEND
//! - Original image data is preserved unchanged

const std = @import("std");
const chunk = @import("chunk.zig");
const crc32 = @import("crc32.zig");

/// pNGb chunk type identifier.
pub const PNGB_CHUNK_TYPE = chunk.ChunkType.pNGb;

/// Current pNGb format version.
pub const PNGB_VERSION: u8 = 0x01;

/// Flag: payload is deflate-compressed.
pub const FLAG_COMPRESSED: u8 = 0x01;

pub const Error = error{
    InvalidPng,
    MissingIEND,
    OutOfMemory,
    BytecodeTooSmall,
};

/// Embed PNGB bytecode into a PNG image.
///
/// Inserts a pNGb chunk containing the bytecode immediately before
/// the IEND chunk.
///
/// Pre-conditions:
/// - png_data starts with valid PNG signature
/// - png_data contains IEND chunk
/// - bytecode is valid PNGB (>= 16 bytes with correct magic)
///
/// Post-conditions:
/// - Returns valid PNG with embedded pNGb chunk
/// - Original image data is preserved
/// - Caller owns returned slice
///
/// Complexity: O(png_data.len + bytecode.len)
pub fn embed(
    allocator: std.mem.Allocator,
    png_data: []const u8,
    bytecode: []const u8,
) Error![]u8 {
    // Pre-condition: valid PNG signature
    if (png_data.len < 8 or !std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE)) {
        return Error.InvalidPng;
    }

    // Pre-condition: bytecode is minimum PNGB size
    if (bytecode.len < 16) {
        return Error.BytecodeTooSmall;
    }

    // Pre-condition assertions (after validation)
    std.debug.assert(png_data.len >= 8);
    std.debug.assert(bytecode.len >= 16);

    // Find IEND chunk position
    const iend_pos = findIEND(png_data) orelse return Error.MissingIEND;

    // Post-condition: IEND must be after signature
    std.debug.assert(iend_pos >= 8);

    // Build pNGb chunk data: version + flags + payload (no compression for now)
    const pngb_data_size = 2 + bytecode.len;
    const pngb_data = allocator.alloc(u8, pngb_data_size) catch {
        return Error.OutOfMemory;
    };
    defer allocator.free(pngb_data);

    pngb_data[0] = PNGB_VERSION;
    pngb_data[1] = 0; // No compression
    @memcpy(pngb_data[2..], bytecode);

    // Calculate output size
    const pngb_chunk_size = chunk.chunkSize(pngb_data_size);
    const result_size = iend_pos + pngb_chunk_size + (png_data.len - iend_pos);

    // Allocate result buffer
    const result = allocator.alloc(u8, result_size) catch {
        return Error.OutOfMemory;
    };
    errdefer allocator.free(result);

    // Assemble: [original up to IEND] + [pNGb chunk] + [IEND chunk]
    @memcpy(result[0..iend_pos], png_data[0..iend_pos]);

    // Write pNGb chunk directly to buffer
    _ = chunk.writeChunkToBuffer(result[iend_pos..], PNGB_CHUNK_TYPE, pngb_data);

    // Copy IEND chunk
    @memcpy(result[iend_pos + pngb_chunk_size ..], png_data[iend_pos..]);

    // Post-condition: result starts with PNG signature
    std.debug.assert(std.mem.eql(u8, result[0..8], &chunk.PNG_SIGNATURE));
    // Post-condition: result is larger than original (contains pNGb)
    std.debug.assert(result.len > png_data.len);

    return result;
}

/// Find the byte offset of the IEND chunk in PNG data.
///
/// IEND chunks have 0-length data, so we look for the pattern:
/// 00 00 00 00 (length) + 49 45 4E 44 ("IEND")
///
/// Returns null if IEND not found.
fn findIEND(png_data: []const u8) ?usize {
    // Pre-condition: need at least signature + minimal chunk
    std.debug.assert(png_data.len >= 8);

    const iend_pattern = [8]u8{ 0, 0, 0, 0, 'I', 'E', 'N', 'D' };

    // Search from end of file (IEND is always last)
    // Start at minimum position: signature (8) + IHDR (25) = 33
    if (png_data.len < 33 + 12) return null;

    // IEND chunk is 12 bytes total (4 len + 4 type + 0 data + 4 crc)
    // Search backwards for efficiency (bounded by data length)
    const max_iterations = png_data.len - 8;
    var pos: usize = png_data.len - 12;

    for (0..max_iterations) |_| {
        if (std.mem.eql(u8, png_data[pos..][0..8], &iend_pattern)) {
            // Post-condition: found position is valid
            std.debug.assert(pos >= 8);
            std.debug.assert(pos + 12 <= png_data.len);
            return pos;
        }
        if (pos == 8) break;
        pos -= 1;
    }

    // Forward search as fallback (std.mem.indexOf is bounded)
    return std.mem.indexOf(u8, png_data, &iend_pattern);
}

// ============================================================================
// Tests
// ============================================================================

fn createMinimalPng(allocator: std.mem.Allocator) ![]u8 {
    var png_buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer png_buf.deinit(allocator);

    try png_buf.appendSlice(allocator, &chunk.PNG_SIGNATURE);

    // IHDR chunk (1x1 grayscale)
    const ihdr_data = [13]u8{
        0x00, 0x00, 0x00, 0x01, // width = 1
        0x00, 0x00, 0x00, 0x01, // height = 1
        0x08, // bit depth = 8
        0x00, // color type = 0 (grayscale)
        0x00, // compression = 0
        0x00, // filter = 0
        0x00, // interlace = 0
    };
    try chunk.writeChunk(&png_buf, allocator, chunk.ChunkType.IHDR, &ihdr_data);

    // Minimal IDAT (compressed single gray pixel)
    const idat_data = [_]u8{ 0x08, 0xD7, 0x63, 0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01 };
    try chunk.writeChunk(&png_buf, allocator, chunk.ChunkType.IDAT, &idat_data);

    // IEND
    try chunk.writeChunk(&png_buf, allocator, chunk.ChunkType.IEND, "");

    return png_buf.toOwnedSlice(allocator);
}

test "embed: roundtrip with minimal PNG" {
    const allocator = std.testing.allocator;

    // Create minimal valid PNG
    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Create test bytecode (fake PNGB header + data)
    var bytecode: [128]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    @memset(bytecode[4..], 0x42);

    // Embed
    const embedded = try embed(allocator, png_data, &bytecode);
    defer allocator.free(embedded);

    // Verify result is larger (has pNGb chunk)
    try std.testing.expect(embedded.len > png_data.len);

    // Verify PNG signature preserved
    try std.testing.expectEqualSlices(u8, &chunk.PNG_SIGNATURE, embedded[0..8]);

    // Parse and find pNGb chunk
    var iter = try chunk.parseChunks(embedded);
    var found_pngb = false;
    var found_iend = false;

    while (try iter.next()) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &chunk.ChunkType.pNGb)) {
            found_pngb = true;
            // Verify version
            try std.testing.expectEqual(PNGB_VERSION, c.data[0]);
        }
        if (std.mem.eql(u8, &c.chunk_type, &chunk.ChunkType.IEND)) {
            found_iend = true;
            // IEND must come after pNGb
            try std.testing.expect(found_pngb);
        }
    }

    try std.testing.expect(found_pngb);
    try std.testing.expect(found_iend);
}

test "embed: small bytecode" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Small bytecode
    var bytecode: [32]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    @memset(bytecode[4..], 0x00);

    const embedded = try embed(allocator, png_data, &bytecode);
    defer allocator.free(embedded);

    // Find pNGb and verify structure
    var iter = try chunk.parseChunks(embedded);
    while (try iter.next()) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &chunk.ChunkType.pNGb)) {
            const flags = c.data[1];
            try std.testing.expectEqual(@as(u8, 0), flags & FLAG_COMPRESSED);
            // Payload should be exact size: version(1) + flags(1) + bytecode(32)
            try std.testing.expectEqual(@as(usize, 34), c.data.len);
            break;
        }
    }
}

test "embed: invalid PNG rejected" {
    const allocator = std.testing.allocator;

    const bad_png = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    var bytecode: [32]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");

    try std.testing.expectError(Error.InvalidPng, embed(allocator, &bad_png, &bytecode));
}

test "embed: missing IEND rejected" {
    const allocator = std.testing.allocator;

    // PNG with signature and IHDR but no IEND
    var png_buf: std.ArrayListUnmanaged(u8) = .{};
    defer png_buf.deinit(allocator);

    try png_buf.appendSlice(allocator, &chunk.PNG_SIGNATURE);
    const ihdr_data = [13]u8{
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x00, 0x00, 0x00, 0x00,
    };
    try chunk.writeChunk(&png_buf, allocator, chunk.ChunkType.IHDR, &ihdr_data);

    var bytecode: [32]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");

    try std.testing.expectError(Error.MissingIEND, embed(allocator, png_buf.items, &bytecode));
}

test "embed: large bytecode" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Large bytecode
    var bytecode: [1024]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    @memset(bytecode[4..], 'A');

    const embedded = try embed(allocator, png_data, &bytecode);
    defer allocator.free(embedded);

    // Find pNGb and verify it contains the full bytecode
    var iter = try chunk.parseChunks(embedded);
    while (try iter.next()) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &chunk.ChunkType.pNGb)) {
            // Payload should be: version(1) + flags(1) + bytecode(1024)
            try std.testing.expectEqual(@as(usize, 1026), c.data.len);
            break;
        }
    }
}

test "embed: findIEND finds correct position" {
    const allocator = std.testing.allocator;

    var png_buf: std.ArrayListUnmanaged(u8) = .{};
    defer png_buf.deinit(allocator);

    try png_buf.appendSlice(allocator, &chunk.PNG_SIGNATURE);
    const ihdr_data = [13]u8{
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x00, 0x00, 0x00, 0x00,
    };
    try chunk.writeChunk(&png_buf, allocator, chunk.ChunkType.IHDR, &ihdr_data);

    const expected_iend_pos = png_buf.items.len;
    try chunk.writeChunk(&png_buf, allocator, chunk.ChunkType.IEND, "");

    const found_pos = findIEND(png_buf.items);
    try std.testing.expectEqual(expected_iend_pos, found_pos.?);
}
