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
    DecompressionFailed,
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

    // Check compression flag
    const is_compressed = (flags & embed.FLAG_COMPRESSED) != 0;

    if (is_compressed) {
        // Decompress deflate-raw payload
        return decompressDeflateRaw(allocator, payload) catch {
            return Error.DecompressionFailed;
        };
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

/// Decompress deflate-raw (store blocks) data.
///
/// This handles the simple store block format used by embed.zig.
/// Store blocks have format: [BFINAL|BTYPE=00] [LEN] [NLEN] [DATA...]
///
/// Pre-conditions:
/// - data contains valid deflate store blocks
///
/// Post-conditions:
/// - Returns decompressed data
/// - Caller owns returned slice
fn decompressDeflateRaw(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // Pre-condition: need at least one block header
    if (data.len < 5) {
        return error.InvalidFormat;
    }
    std.debug.assert(data.len >= 5);

    // First pass: calculate total decompressed size
    var total_size: usize = 0;
    var pos: usize = 0;

    // Upper bound: each block is at least 5 bytes (header), so max blocks = data.len / 5
    const max_blocks = (data.len / 5) + 1;

    for (0..max_blocks) |_| {
        if (pos >= data.len) break;

        const header = data[pos];
        const is_final = (header & 0x01) != 0;
        const btype = (header >> 1) & 0x03;

        // Only store blocks (BTYPE=00) supported
        if (btype != 0) {
            return error.UnsupportedBlockType;
        }

        if (pos + 5 > data.len) {
            return error.InvalidFormat;
        }

        const len = std.mem.readInt(u16, data[pos + 1 ..][0..2], .little);
        const nlen = std.mem.readInt(u16, data[pos + 3 ..][0..2], .little);

        // Verify NLEN is one's complement of LEN
        if (nlen != ~len) {
            return error.InvalidFormat;
        }

        const block_len: usize = len;
        total_size += block_len;
        pos += 5 + block_len;

        if (is_final) break;
    } else {
        // Exceeded max blocks without finding final - malformed input
        return error.InvalidFormat;
    }

    // Allocate result buffer
    const result = try allocator.alloc(u8, total_size);
    errdefer allocator.free(result);

    // Second pass: extract data
    pos = 0;
    var out_pos: usize = 0;

    for (0..max_blocks) |_| {
        if (pos >= data.len) break;

        const header = data[pos];
        const is_final = (header & 0x01) != 0;

        const len = std.mem.readInt(u16, data[pos + 1 ..][0..2], .little);
        const block_len: usize = len;

        // Copy block data
        @memcpy(result[out_pos..][0..block_len], data[pos + 5 ..][0..block_len]);
        out_pos += block_len;
        pos += 5 + block_len;

        if (is_final) break;
    } else {
        // Should not reach here - first pass validated the data
        unreachable;
    }

    // Post-condition: filled entire buffer
    std.debug.assert(out_pos == total_size);

    return result;
}

/// Check if PNG data contains a pNGb chunk.
///
/// Quick check without allocation.
///
/// Pre-condition: png_data is a valid slice.
/// Post-condition: returns true iff png_data contains a valid pNGb chunk.
pub fn hasPngb(png_data: []const u8) bool {
    // Early return for invalid PNG (too short or wrong signature)
    if (png_data.len < 8 or !std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE)) {
        return false;
    }

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
    // Now embedded bytecode is compressed by default
    try std.testing.expect(info.compressed);
    // Compressed payload: store_header(5) + data(32) = 37 bytes
    try std.testing.expectEqual(@as(usize, 37), info.payload_size);
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

test "extract: multi-block roundtrip (>65535 bytes)" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Large bytecode spanning multiple deflate blocks
    const large_size: usize = 70000;
    const bytecode = try allocator.alloc(u8, large_size);
    defer allocator.free(bytecode);

    @memcpy(bytecode[0..4], "PNGB");
    // Fill with pattern for verification
    for (4..large_size) |i| {
        bytecode[i] = @intCast(i & 0xFF);
    }

    // Embed
    const embedded = try embed.embed(allocator, png_data, bytecode);
    defer allocator.free(embedded);

    // Extract
    const extracted = try extract(allocator, embedded);
    defer allocator.free(extracted);

    // Verify exact roundtrip
    try std.testing.expectEqual(large_size, extracted.len);
    try std.testing.expectEqualSlices(u8, bytecode, extracted);
}

test "extract: exact 65535 byte roundtrip" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Exactly max single block size
    const bytecode = try allocator.alloc(u8, 65535);
    defer allocator.free(bytecode);

    @memcpy(bytecode[0..4], "PNGB");
    for (4..65535) |i| {
        bytecode[i] = @intCast((i * 7) & 0xFF);
    }

    const embedded = try embed.embed(allocator, png_data, bytecode);
    defer allocator.free(embedded);

    const extracted = try extract(allocator, embedded);
    defer allocator.free(extracted);

    try std.testing.expectEqualSlices(u8, bytecode, extracted);
}

test "extract: 65536 byte roundtrip (two blocks)" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // One byte over max block triggers second block
    const bytecode = try allocator.alloc(u8, 65536);
    defer allocator.free(bytecode);

    @memcpy(bytecode[0..4], "PNGB");
    for (4..65536) |i| {
        bytecode[i] = @intCast((i * 13) & 0xFF);
    }

    const embedded = try embed.embed(allocator, png_data, bytecode);
    defer allocator.free(embedded);

    const extracted = try extract(allocator, embedded);
    defer allocator.free(extracted);

    try std.testing.expectEqualSlices(u8, bytecode, extracted);
}

test "extract: all byte values roundtrip" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Create bytecode with all 256 byte values
    var bytecode: [256 + 16]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    @memset(bytecode[4..16], 0);
    for (0..256) |i| {
        bytecode[16 + i] = @intCast(i);
    }

    const embedded = try embed.embed(allocator, png_data, &bytecode);
    defer allocator.free(embedded);

    const extracted = try extract(allocator, embedded);
    defer allocator.free(extracted);

    try std.testing.expectEqualSlices(u8, &bytecode, extracted);

    // Verify all byte values are preserved
    for (0..256) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), extracted[16 + i]);
    }
}

test "extract: minimum size bytecode roundtrip" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Minimum valid bytecode (16 bytes)
    var bytecode: [16]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    @memset(bytecode[4..], 0xFF);

    const embedded = try embed.embed(allocator, png_data, &bytecode);
    defer allocator.free(embedded);

    const extracted = try extract(allocator, embedded);
    defer allocator.free(extracted);

    try std.testing.expectEqualSlices(u8, &bytecode, extracted);
}

test "extract: decompressDeflateRaw single block" {
    const allocator = std.testing.allocator;

    // Manually construct a valid single-block deflate stream
    const data = "Hello, World!";
    const data_len: u16 = @intCast(data.len);

    var compressed: [5 + data.len]u8 = undefined;
    compressed[0] = 0x01; // BFINAL=1, BTYPE=00
    std.mem.writeInt(u16, compressed[1..3], data_len, .little);
    std.mem.writeInt(u16, compressed[3..5], ~data_len, .little);
    @memcpy(compressed[5..], data);

    const decompressed = try decompressDeflateRaw(allocator, &compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(data, decompressed);
}

test "extract: decompressDeflateRaw multi-block" {
    const allocator = std.testing.allocator;

    // Construct two-block deflate stream
    const block1_data = "First block data";
    const block2_data = "Second block!";
    const len1: u16 = @intCast(block1_data.len);
    const len2: u16 = @intCast(block2_data.len);

    var compressed: [5 + block1_data.len + 5 + block2_data.len]u8 = undefined;

    // Block 1 (not final)
    compressed[0] = 0x00; // BFINAL=0, BTYPE=00
    std.mem.writeInt(u16, compressed[1..3], len1, .little);
    std.mem.writeInt(u16, compressed[3..5], ~len1, .little);
    @memcpy(compressed[5..][0..block1_data.len], block1_data);

    // Block 2 (final)
    const b2_start = 5 + block1_data.len;
    compressed[b2_start] = 0x01; // BFINAL=1, BTYPE=00
    std.mem.writeInt(u16, compressed[b2_start + 1 ..][0..2], len2, .little);
    std.mem.writeInt(u16, compressed[b2_start + 3 ..][0..2], ~len2, .little);
    @memcpy(compressed[b2_start + 5 ..][0..block2_data.len], block2_data);

    const decompressed = try decompressDeflateRaw(allocator, &compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqual(block1_data.len + block2_data.len, decompressed.len);
    try std.testing.expectEqualStrings(block1_data, decompressed[0..block1_data.len]);
    try std.testing.expectEqualStrings(block2_data, decompressed[block1_data.len..]);
}

test "extract: decompressDeflateRaw invalid header rejected" {
    const allocator = std.testing.allocator;

    // Too short
    const short = [_]u8{ 0x01, 0x00 };
    try std.testing.expectError(error.InvalidFormat, decompressDeflateRaw(allocator, &short));

    // Invalid NLEN (not one's complement of LEN)
    var bad_nlen: [10]u8 = undefined;
    bad_nlen[0] = 0x01;
    std.mem.writeInt(u16, bad_nlen[1..3], 5, .little);
    std.mem.writeInt(u16, bad_nlen[3..5], 0x1234, .little); // Wrong NLEN
    @memset(bad_nlen[5..], 0);
    try std.testing.expectError(error.InvalidFormat, decompressDeflateRaw(allocator, &bad_nlen));
}

test "extract: decompressDeflateRaw unsupported block type rejected" {
    const allocator = std.testing.allocator;

    // BTYPE=01 (fixed Huffman)
    var huffman: [10]u8 = undefined;
    huffman[0] = 0x03; // BFINAL=1, BTYPE=01
    @memset(huffman[1..], 0);
    try std.testing.expectError(error.UnsupportedBlockType, decompressDeflateRaw(allocator, &huffman));

    // BTYPE=10 (dynamic Huffman)
    var dynamic: [10]u8 = undefined;
    dynamic[0] = 0x05; // BFINAL=1, BTYPE=10
    @memset(dynamic[1..], 0);
    try std.testing.expectError(error.UnsupportedBlockType, decompressDeflateRaw(allocator, &dynamic));
}
