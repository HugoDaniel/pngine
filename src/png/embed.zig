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
//! 1       1     Flags (bit 0: compressed with DEFLATE)
//! 2       N     Payload (PNGB bytecode, optionally compressed)
//! ```
//!
//! ## Compression
//!
//! Uses real DEFLATE compression (LZ77 + Huffman) for significant size
//! reduction. WASM modules typically compress 30-50%. Output is raw DEFLATE
//! (no zlib header) compatible with browser's DecompressionStream('deflate-raw').
//!
//! ## Invariants
//! - Output is always a valid PNG file
//! - pNGb chunk is inserted immediately before IEND
//! - Original image data is preserved unchanged

const std = @import("std");
const chunk = @import("chunk.zig");
const crc32 = @import("crc32.zig");
const flate = std.compress.flate;

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
/// before the IEND chunk. Uses real DEFLATE compression for size reduction.
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

    // Compress bytecode using real DEFLATE (raw format for browser compatibility)
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

/// Compress data using raw DEFLATE (no zlib header/footer).
///
/// Uses real LZ77+Huffman compression for significant size reduction.
/// Output is raw DEFLATE compatible with browser's DecompressionStream('deflate-raw').
///
/// Pre-conditions:
/// - data.len > 0
///
/// Post-conditions:
/// - Returns valid raw DEFLATE stream with len > 0
/// - Caller owns returned slice
fn compressDeflateRaw(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // Pre-condition: data is not empty
    std.debug.assert(data.len > 0);

    // Allocate output buffer larger than input because incompressible data
    // expands slightly (~0.1%) plus DEFLATE block headers. 1KB overhead
    // covers worst case for typical bytecode sizes (<1MB).
    const initial_capacity = data.len + 1024;
    var output_buf = try allocator.alloc(u8, initial_capacity);
    errdefer allocator.free(output_buf);

    // 32KB window enables back-references up to 32KB ago, standard for DEFLATE.
    var window_buf: [flate.max_window_len]u8 = undefined;

    // Fixed writer streams compressed bytes directly into output_buf.
    var output_writer: std.Io.Writer = .fixed(output_buf);

    // Raw format omits zlib header/footer for browser DecompressionStream compatibility.
    // Level 6 balances compression ratio (~2-3x) with speed (<100ms for 100KB).
    var compressor = flate.Compress.init(
        &output_writer,
        &window_buf,
        .raw,
        flate.Compress.Options.level_6,
    ) catch {
        return error.CompressionFailed;
    };

    // Stream all input through LZ77+Huffman encoder.
    compressor.writer.writeAll(data) catch {
        return error.CompressionFailed;
    };

    // Flush writes final DEFLATE block with BFINAL=1 marker.
    compressor.writer.flush() catch {
        return error.CompressionFailed;
    };

    const compressed_len = output_writer.end;

    // Copy to exact-size allocation (avoids wasting ~1KB slack space).
    const result = try allocator.alloc(u8, compressed_len);
    @memcpy(result, output_buf[0..compressed_len]);
    allocator.free(output_buf);

    // Post-condition: DEFLATE always produces at least block header bytes.
    std.debug.assert(result.len > 0);

    return result;
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
            // Verify compression flag
            try std.testing.expectEqual(FLAG_COMPRESSED, c.data[1] & FLAG_COMPRESSED);
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

test "embed: compression reduces size for repetitive data" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Create highly compressible bytecode (all same bytes)
    var bytecode: [1024]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    @memset(bytecode[4..], 'A'); // Very compressible

    const embedded = try embed(allocator, png_data, &bytecode);
    defer allocator.free(embedded);

    // Find pNGb and check compression
    var iter = try chunk.parseChunks(embedded);
    while (try iter.next()) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &chunk.ChunkType.pNGb)) {
            const flags = c.data[1];
            try std.testing.expectEqual(FLAG_COMPRESSED, flags & FLAG_COMPRESSED);

            // Payload should be much smaller than 1024 bytes (highly compressible)
            // With real DEFLATE, repetitive data compresses very well
            const payload_size = c.data.len - 2;
            try std.testing.expect(payload_size < 100); // Should compress to <10%
            break;
        }
    }
}

test "embed: compression works for random-like data" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Create less compressible bytecode (varying bytes)
    var bytecode: [256]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    for (4..256) |i| {
        // Pattern that's not fully random but not fully repetitive
        bytecode[i] = @intCast((i * 7 + 13) & 0xFF);
    }

    const embedded = try embed(allocator, png_data, &bytecode);
    defer allocator.free(embedded);

    // Should still work, even if compression ratio is lower
    var iter = try chunk.parseChunks(embedded);
    var found = false;
    while (try iter.next()) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &chunk.ChunkType.pNGb)) {
            found = true;
            try std.testing.expectEqual(FLAG_COMPRESSED, c.data[1] & FLAG_COMPRESSED);
            break;
        }
    }
    try std.testing.expect(found);
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

    // Large bytecode with pattern (compressible)
    var bytecode: [8192]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    // Fill with repeating pattern
    for (4..8192) |i| {
        bytecode[i] = @intCast(i & 0x0F); // Repeating 0-15 pattern
    }

    const embedded = try embed(allocator, png_data, &bytecode);
    defer allocator.free(embedded);

    // Find pNGb and verify compression achieved significant reduction
    var iter = try chunk.parseChunks(embedded);
    while (try iter.next()) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &chunk.ChunkType.pNGb)) {
            const flags = c.data[1];
            try std.testing.expectEqual(FLAG_COMPRESSED, flags & FLAG_COMPRESSED);

            // Payload should be much smaller than 8192 bytes
            const payload_size = c.data.len - 2;
            try std.testing.expect(payload_size < 4096); // At least 50% compression
            break;
        }
    }
}

test "embed: compressDeflateRaw produces valid output" {
    const allocator = std.testing.allocator;

    const data = "Hello, deflate-raw compression test! This string has some repetition. Hello, deflate-raw compression test!";
    const compressed = try compressDeflateRaw(allocator, data);
    defer allocator.free(compressed);

    // Compressed output should exist
    try std.testing.expect(compressed.len > 0);

    // With real DEFLATE, repetitive data should compress
    try std.testing.expect(compressed.len < data.len);
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

test "embed: very large bytecode (100KB)" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // 100KB bytecode (simulates WASM module)
    const large_size: usize = 100 * 1024;
    const bytecode = try allocator.alloc(u8, large_size);
    defer allocator.free(bytecode);

    @memcpy(bytecode[0..4], "PNGB");
    // Fill with semi-random pattern (simulates real bytecode)
    for (4..large_size) |i| {
        bytecode[i] = @intCast((i * 31 + i / 256) & 0xFF);
    }

    const embedded = try embed(allocator, png_data, bytecode);
    defer allocator.free(embedded);

    // Find pNGb and verify it exists
    var iter = try chunk.parseChunks(embedded);
    var found = false;
    while (try iter.next()) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &chunk.ChunkType.pNGb)) {
            found = true;
            try std.testing.expectEqual(FLAG_COMPRESSED, c.data[1] & FLAG_COMPRESSED);
            break;
        }
    }
    try std.testing.expect(found);
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

test "embed: compression ratio test with WASM-like data" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Simulate WASM module structure (has some patterns)
    // Real WASM has magic number, sections, and LEB128 encoded values
    var bytecode: [4096]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    // WASM-like pattern: section headers, type indices, opcodes
    for (4..4096) |i| {
        const section = i / 256;
        const offset_in_section = i % 256;
        bytecode[i] = @intCast((section * 17 + offset_in_section) & 0xFF);
    }

    const embedded = try embed(allocator, png_data, &bytecode);
    defer allocator.free(embedded);

    var iter = try chunk.parseChunks(embedded);
    while (try iter.next()) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &chunk.ChunkType.pNGb)) {
            const payload_size = c.data.len - 2;
            // Should achieve some compression
            try std.testing.expect(payload_size < 4096);
            break;
        }
    }
}
