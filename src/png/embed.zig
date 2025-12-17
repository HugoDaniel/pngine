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
    CompressionFailed,
};

/// Embed PNGB bytecode into a PNG image.
///
/// Inserts a pNGb chunk containing the compressed bytecode immediately
/// before the IEND chunk. Uses deflate-raw compression by default.
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

    // Compress bytecode using deflate-raw (compatible with browser DecompressionStream)
    const compressed = compressDeflateRaw(allocator, bytecode) catch {
        return Error.CompressionFailed;
    };
    defer allocator.free(compressed);

    // Build pNGb chunk data: version + flags + compressed payload
    const pngb_data_size = 2 + compressed.len;
    const pngb_data = allocator.alloc(u8, pngb_data_size) catch {
        return Error.OutOfMemory;
    };
    defer allocator.free(pngb_data);

    pngb_data[0] = PNGB_VERSION;
    pngb_data[1] = FLAG_COMPRESSED; // Compressed with deflate-raw
    @memcpy(pngb_data[2..], compressed);

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

    // Minimum valid PNG: signature (8) + IHDR (25) + IEND (12) = 45
    if (png_data.len < 45) return null;

    // IEND chunk is 12 bytes total (4 len + 4 type + 0 data + 4 crc)
    // Search backwards for efficiency (IEND is always last chunk)
    const min_pos: usize = 8; // After PNG signature
    var pos: usize = png_data.len - 12;

    // Bounded backward search - max iterations is data length
    for (0..png_data.len) |_| {
        if (std.mem.eql(u8, png_data[pos..][0..8], &iend_pattern)) {
            // Post-condition: found position is valid
            std.debug.assert(pos >= min_pos);
            std.debug.assert(pos + 12 <= png_data.len);
            return pos;
        }
        if (pos <= min_pos) break;
        pos -= 1;
    } else {
        // Loop completed without finding - should not happen for valid PNG
        // Fall through to forward search
    }

    // Forward search as fallback (std.mem.indexOf is bounded internally)
    return std.mem.indexOf(u8, png_data, &iend_pattern);
}

/// Compress data using raw DEFLATE store blocks (no zlib header/footer).
///
/// This produces raw DEFLATE output compatible with browser's
/// DecompressionStream('deflate-raw'). Uses store blocks (BTYPE=00)
/// for simplicity and universal compatibility.
///
/// Pre-conditions:
/// - data.len > 0
///
/// Post-conditions:
/// - Returns valid raw DEFLATE stream
/// - Caller owns returned slice
fn compressDeflateRaw(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // Pre-condition: data is not empty
    std.debug.assert(data.len > 0);

    // Calculate output size:
    // - For each 65535-byte block: 5 bytes header + block data
    // - No header or footer (raw deflate)
    const max_block_size: usize = 65535;
    const num_full_blocks = data.len / max_block_size;
    const last_block_size = data.len % max_block_size;
    const num_blocks = num_full_blocks + @as(usize, if (last_block_size > 0) 1 else 0);

    const output_size = (num_blocks * 5) + data.len;
    const output = try allocator.alloc(u8, output_size);
    errdefer allocator.free(output);

    var pos: usize = 0;
    var data_pos: usize = 0;

    // Write store blocks
    for (0..num_blocks) |i| {
        const remaining = data.len - data_pos;
        const block_size: u16 = @intCast(@min(remaining, max_block_size));
        const is_final = (i == num_blocks - 1);

        // Block header: BFINAL (1 bit) + BTYPE (2 bits) = 00 for stored
        // If final: 0x01, else: 0x00
        output[pos] = if (is_final) 0x01 else 0x00;
        pos += 1;

        // LEN (2 bytes, little-endian)
        std.mem.writeInt(u16, output[pos..][0..2], block_size, .little);
        pos += 2;

        // NLEN (2 bytes, little-endian) = one's complement of LEN
        std.mem.writeInt(u16, output[pos..][0..2], ~block_size, .little);
        pos += 2;

        // Block data
        @memcpy(output[pos..][0..block_size], data[data_pos..][0..block_size]);
        pos += block_size;
        data_pos += block_size;
    }

    // Post-condition: wrote expected amount
    std.debug.assert(pos == output_size);

    return output;
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

test "embed: small bytecode is compressed" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Small bytecode (minimum size 16 bytes)
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
            // Verify compression flag is set
            try std.testing.expectEqual(FLAG_COMPRESSED, flags & FLAG_COMPRESSED);
            // Compressed size: version(1) + flags(1) + store_header(5) + data(32)
            // Store block adds 5 bytes overhead for small data
            try std.testing.expectEqual(@as(usize, 39), c.data.len);
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

test "embed: large bytecode is compressed" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Large bytecode
    var bytecode: [1024]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    @memset(bytecode[4..], 'A');

    const embedded = try embed(allocator, png_data, &bytecode);
    defer allocator.free(embedded);

    // Find pNGb and verify compression flag
    var iter = try chunk.parseChunks(embedded);
    while (try iter.next()) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &chunk.ChunkType.pNGb)) {
            const flags = c.data[1];
            try std.testing.expectEqual(FLAG_COMPRESSED, flags & FLAG_COMPRESSED);
            // Compressed size: version(1) + flags(1) + store_header(5) + data(1024)
            try std.testing.expectEqual(@as(usize, 1031), c.data.len);
            break;
        }
    }
}

test "embed: compressDeflateRaw produces valid output" {
    const allocator = std.testing.allocator;

    const data = "Hello, deflate-raw compression test!";
    const compressed = try compressDeflateRaw(allocator, data);
    defer allocator.free(compressed);

    // Compressed output should exist
    try std.testing.expect(compressed.len > 0);

    // First byte should be 0x01 (BFINAL=1, BTYPE=00 for stored)
    try std.testing.expectEqual(@as(u8, 0x01), compressed[0]);

    // LEN should match data length
    const len = std.mem.readInt(u16, compressed[1..3], .little);
    try std.testing.expectEqual(@as(u16, @intCast(data.len)), len);

    // NLEN should be one's complement
    const nlen = std.mem.readInt(u16, compressed[3..5], .little);
    try std.testing.expectEqual(~len, nlen);

    // Data should be stored verbatim
    try std.testing.expectEqualStrings(data, compressed[5..][0..data.len]);
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

test "embed: multi-block compression (>65535 bytes)" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Create bytecode larger than one deflate block (65535 bytes)
    // Use 70000 bytes to test multi-block
    const large_size: usize = 70000;
    const bytecode = try allocator.alloc(u8, large_size);
    defer allocator.free(bytecode);

    @memcpy(bytecode[0..4], "PNGB");
    // Fill with pattern for verification
    for (4..large_size) |i| {
        bytecode[i] = @intCast(i & 0xFF);
    }

    const embedded = try embed(allocator, png_data, bytecode);
    defer allocator.free(embedded);

    // Find pNGb and verify structure
    var iter = try chunk.parseChunks(embedded);
    while (try iter.next()) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &chunk.ChunkType.pNGb)) {
            const flags = c.data[1];
            try std.testing.expectEqual(FLAG_COMPRESSED, flags & FLAG_COMPRESSED);

            // Should have 2 blocks: one full (65535) + one partial (4465)
            // Overhead: version(1) + flags(1) + 2*store_header(10) = 12 bytes
            // Total: 12 + 70000 = 70012 bytes
            try std.testing.expectEqual(@as(usize, 70012), c.data.len);
            break;
        }
    }
}

test "embed: exact 65535 byte bytecode (single max block)" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Exactly one max-size block
    const bytecode = try allocator.alloc(u8, 65535);
    defer allocator.free(bytecode);

    @memcpy(bytecode[0..4], "PNGB");
    @memset(bytecode[4..], 0xAB);

    const embedded = try embed(allocator, png_data, bytecode);
    defer allocator.free(embedded);

    // Find pNGb and verify structure
    var iter = try chunk.parseChunks(embedded);
    while (try iter.next()) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &chunk.ChunkType.pNGb)) {
            // Single block: version(1) + flags(1) + store_header(5) + data(65535) = 65542
            try std.testing.expectEqual(@as(usize, 65542), c.data.len);
            break;
        }
    }
}

test "embed: 65536 byte bytecode (triggers second block)" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // One byte over max block size
    const bytecode = try allocator.alloc(u8, 65536);
    defer allocator.free(bytecode);

    @memcpy(bytecode[0..4], "PNGB");
    @memset(bytecode[4..], 0xCD);

    const embedded = try embed(allocator, png_data, bytecode);
    defer allocator.free(embedded);

    // Find pNGb and verify structure
    var iter = try chunk.parseChunks(embedded);
    while (try iter.next()) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &chunk.ChunkType.pNGb)) {
            // Two blocks: version(1) + flags(1) + 2*store_header(10) + data(65536) = 65548
            try std.testing.expectEqual(@as(usize, 65548), c.data.len);
            break;
        }
    }
}

test "embed: bytecode with all byte values" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Create bytecode with all 256 byte values
    var bytecode: [256 + 16]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    // Fill version/header bytes
    @memset(bytecode[4..16], 0);
    // All byte values 0x00-0xFF
    for (0..256) |i| {
        bytecode[16 + i] = @intCast(i);
    }

    const embedded = try embed(allocator, png_data, &bytecode);
    defer allocator.free(embedded);

    // Verify PNG is valid and contains pNGb
    var iter = try chunk.parseChunks(embedded);
    var found = false;
    while (try iter.next()) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &chunk.ChunkType.pNGb)) {
            found = true;
            // Verify compression flag
            try std.testing.expectEqual(FLAG_COMPRESSED, c.data[1] & FLAG_COMPRESSED);
            break;
        }
    }
    try std.testing.expect(found);
}

test "embed: compressDeflateRaw multi-block output" {
    const allocator = std.testing.allocator;

    // Create data spanning multiple blocks
    const data = try allocator.alloc(u8, 70000);
    defer allocator.free(data);
    @memset(data, 'X');

    const compressed = try compressDeflateRaw(allocator, data);
    defer allocator.free(compressed);

    // Should have 2 blocks
    // Block 1: header(5) + data(65535) = 65540
    // Block 2: header(5) + data(4465) = 4470
    // Total: 70010 bytes
    try std.testing.expectEqual(@as(usize, 70010), compressed.len);

    // Verify first block header
    try std.testing.expectEqual(@as(u8, 0x00), compressed[0]); // Not final
    const len1 = std.mem.readInt(u16, compressed[1..3], .little);
    try std.testing.expectEqual(@as(u16, 65535), len1);
    const nlen1 = std.mem.readInt(u16, compressed[3..5], .little);
    try std.testing.expectEqual(~len1, nlen1);

    // Verify second block header (at offset 65540)
    try std.testing.expectEqual(@as(u8, 0x01), compressed[65540]); // Final block
    const len2 = std.mem.readInt(u16, compressed[65541..65543], .little);
    try std.testing.expectEqual(@as(u16, 4465), len2);
    const nlen2 = std.mem.readInt(u16, compressed[65543..65545], .little);
    try std.testing.expectEqual(~len2, nlen2);
}

test "embed: minimum 16 byte bytecode" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Exactly minimum size
    var bytecode: [16]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    @memset(bytecode[4..], 0);

    const embedded = try embed(allocator, png_data, &bytecode);
    defer allocator.free(embedded);

    try std.testing.expect(embedded.len > png_data.len);
}

test "embed: bytecode too small rejected" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // 15 bytes - one less than minimum
    var bytecode: [15]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    @memset(bytecode[4..], 0);

    try std.testing.expectError(Error.BytecodeTooSmall, embed(allocator, png_data, &bytecode));
}
