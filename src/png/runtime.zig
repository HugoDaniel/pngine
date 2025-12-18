//! Embed and extract WASM runtime from PNG files.
//!
//! Creates a pNGr ancillary chunk containing the compressed WASM runtime
//! for self-contained distribution of PNGine animations.
//!
//! ## pNGr Chunk Format
//! ```
//! Offset  Size  Description
//! ------  ----  -----------
//! 0       1     Version (0x01)
//! 1       1     Flags (bit 0: compressed with DEFLATE)
//! 2       N     Payload (WASM binary, optionally compressed)
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
//! - pNGr chunk is inserted immediately before IEND
//! - Can coexist with pNGb chunk (runtime + bytecode)
//! - Original image data is preserved unchanged

const std = @import("std");
const chunk = @import("chunk.zig");
const crc32 = @import("crc32.zig");
const flate = std.compress.flate;

/// pNGr chunk type identifier.
pub const PNGR_CHUNK_TYPE = chunk.ChunkType.pNGr;

/// Current pNGr format version.
pub const PNGR_VERSION: u8 = 0x01;

/// Flag: payload is deflate-compressed.
pub const FLAG_COMPRESSED: u8 = 0x01;

/// Minimum WASM module size (8 bytes for magic + version).
const MIN_WASM_SIZE: u32 = 8;

/// WASM magic bytes (0x00 0x61 0x73 0x6D = "\0asm").
const WASM_MAGIC = [4]u8{ 0x00, 0x61, 0x73, 0x6D };

// Comptime verification of format constants.
// The pNGr header is version (1) + flags (1) = 2 bytes.
// This ensures the header fits in the minimum chunk data size.
comptime {
    std.debug.assert(PNGR_VERSION == 0x01); // Current version
    std.debug.assert(FLAG_COMPRESSED == 0x01); // Bit 0 for compression
    std.debug.assert(MIN_WASM_SIZE == 8); // Magic (4) + version (4)
    std.debug.assert(WASM_MAGIC[0] == 0x00 and WASM_MAGIC[1] == 0x61); // "\0a"
}

pub const Error = error{
    InvalidPng,
    MissingIEND,
    OutOfMemory,
    RuntimeTooSmall,
    InvalidWasm,
    CompressionFailed,
    DecompressionFailed,
    NoPngrChunk,
    InvalidPngrVersion,
    InvalidPngrFormat,
};

/// Embed WASM runtime into a PNG image.
///
/// Inserts a pNGr chunk containing the compressed runtime immediately
/// before the IEND chunk. Uses real DEFLATE compression for size reduction.
///
/// Pre-conditions:
/// - png_data starts with valid PNG signature
/// - png_data contains IEND chunk
/// - runtime is valid WASM (>= 8 bytes with correct magic)
///
/// Post-conditions:
/// - Returns valid PNG with embedded pNGr chunk
/// - Original image data is preserved
/// - Caller owns returned slice
///
/// Complexity: O(png_data.len + runtime.len)
pub fn embedRuntime(
    allocator: std.mem.Allocator,
    png_data: []const u8,
    runtime: []const u8,
) Error![]u8 {
    // Pre-condition: valid PNG signature
    if (png_data.len < 8 or !std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE)) {
        return Error.InvalidPng;
    }

    // Pre-condition: runtime is minimum WASM size
    if (runtime.len < MIN_WASM_SIZE) {
        return Error.RuntimeTooSmall;
    }

    // Pre-condition: valid WASM magic
    if (!std.mem.eql(u8, runtime[0..4], &WASM_MAGIC)) {
        return Error.InvalidWasm;
    }

    // Pre-condition assertions (after validation)
    std.debug.assert(png_data.len >= 8);
    std.debug.assert(runtime.len >= MIN_WASM_SIZE);

    // Find IEND chunk position
    const iend_pos = findIEND(png_data) orelse return Error.MissingIEND;

    // Post-condition: IEND must be after signature
    std.debug.assert(iend_pos >= 8);

    // Compress runtime using real DEFLATE (raw format for browser compatibility)
    const compressed = compressDeflateRaw(allocator, runtime) catch {
        return Error.CompressionFailed;
    };
    defer allocator.free(compressed);

    // Build pNGr chunk data: version + flags + compressed payload
    const pngr_data_size = 2 + compressed.len;
    const pngr_data = allocator.alloc(u8, pngr_data_size) catch {
        return Error.OutOfMemory;
    };
    defer allocator.free(pngr_data);

    pngr_data[0] = PNGR_VERSION;
    pngr_data[1] = FLAG_COMPRESSED; // Compressed with deflate-raw
    @memcpy(pngr_data[2..], compressed);

    // Calculate output size
    const pngr_chunk_size = chunk.chunkSize(pngr_data_size);
    const result_size = iend_pos + pngr_chunk_size + (png_data.len - iend_pos);

    // Allocate result buffer
    const result = allocator.alloc(u8, result_size) catch {
        return Error.OutOfMemory;
    };
    errdefer allocator.free(result);

    // Assemble: [original up to IEND] + [pNGr chunk] + [IEND chunk]
    @memcpy(result[0..iend_pos], png_data[0..iend_pos]);

    // Write pNGr chunk directly to buffer
    _ = chunk.writeChunkToBuffer(result[iend_pos..], PNGR_CHUNK_TYPE, pngr_data);

    // Copy IEND chunk
    @memcpy(result[iend_pos + pngr_chunk_size ..], png_data[iend_pos..]);

    // Post-condition: result starts with PNG signature
    std.debug.assert(std.mem.eql(u8, result[0..8], &chunk.PNG_SIGNATURE));
    // Post-condition: result is larger than original (contains pNGr)
    std.debug.assert(result.len > png_data.len);

    return result;
}

/// Extract WASM runtime from PNG data.
///
/// Finds the pNGr chunk and returns the decompressed runtime.
///
/// Pre-conditions:
/// - png_data starts with valid PNG signature
/// - png_data contains a pNGr chunk
///
/// Post-conditions:
/// - Returns exact runtime that was originally embedded
/// - Caller owns returned slice and must free it
///
/// Complexity: O(png_data.len) to find chunk
pub fn extractRuntime(allocator: std.mem.Allocator, png_data: []const u8) Error![]u8 {
    // Validate PNG signature
    if (png_data.len < 8 or !std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE)) {
        return Error.InvalidPng;
    }

    // Pre-condition: valid PNG after signature check
    std.debug.assert(png_data.len >= 8);
    std.debug.assert(std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE));

    // Find pNGr chunk
    var iter = chunk.parseChunks(png_data) catch {
        return Error.InvalidPng;
    };

    while (iter.next() catch { return Error.InvalidPng; }) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &PNGR_CHUNK_TYPE)) {
            return parsePngrChunk(allocator, c.data);
        }
    }

    return Error.NoPngrChunk;
}

/// Parse pNGr chunk data.
fn parsePngrChunk(allocator: std.mem.Allocator, data: []const u8) Error![]u8 {
    // Minimum: version (1) + flags (1) + some payload
    if (data.len < 3) {
        return Error.InvalidPngrFormat;
    }

    // Pre-condition: data has header
    std.debug.assert(data.len >= 3);

    const version = data[0];
    const flags = data[1];
    const payload = data[2..];

    // Check version
    if (version != PNGR_VERSION) {
        return Error.InvalidPngrVersion;
    }

    // Check compression flag
    const is_compressed = (flags & FLAG_COMPRESSED) != 0;

    if (is_compressed) {
        // Decompress raw DEFLATE payload
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

/// Check if PNG data contains a pNGr chunk.
///
/// Quick check without allocation.
///
/// Pre-condition: png_data is a valid slice.
/// Post-condition: returns true iff png_data contains a valid pNGr chunk.
pub fn hasPngr(png_data: []const u8) bool {
    // Early return for invalid PNG (too short or wrong signature)
    if (png_data.len < 8 or !std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE)) {
        return false;
    }

    var iter = chunk.parseChunks(png_data) catch return false;

    while (iter.next() catch null) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &PNGR_CHUNK_TYPE)) {
            return true;
        }
    }

    return false;
}

/// Get pNGr chunk info without extracting.
///
/// Returns chunk metadata for inspection.
///
/// Field invariants:
/// - version: Currently always 0x01
/// - compressed: true if payload uses DEFLATE
/// - payload_bytes: Size of compressed payload (< 16MB per PNG spec)
pub const PngrInfo = struct {
    /// pNGr format version (currently 0x01).
    version: u8,
    /// true if payload is DEFLATE-compressed.
    compressed: bool,
    /// Size of payload in bytes (compressed if compressed=true).
    /// Uses u32 per PNG spec limit of ~16MB per chunk.
    payload_bytes: u32,
};

pub fn getPngrInfo(png_data: []const u8) Error!PngrInfo {
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
        if (std.mem.eql(u8, &c.chunk_type, &PNGR_CHUNK_TYPE)) {
            if (c.data.len < 2) {
                return Error.InvalidPngrFormat;
            }

            const version = c.data[0];
            const flags = c.data[1];
            const payload_len: u32 = @intCast(c.data.len - 2);
            const is_compressed = (flags & FLAG_COMPRESSED) != 0;

            return PngrInfo{
                .version = version,
                .compressed = is_compressed,
                .payload_bytes = payload_len,
            };
        }
    }

    return Error.NoPngrChunk;
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
    // covers worst case for typical WASM sizes (<1MB).
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

/// Decompress raw DEFLATE data using std.compress.flate.
///
/// Handles real LZ77+Huffman compressed data, not just store blocks.
///
/// Pre-conditions:
/// - data contains valid raw DEFLATE stream
/// - data.len >= 1 (empty streams are invalid)
///
/// Post-conditions:
/// - Returns decompressed data with len > 0
/// - Caller owns returned slice
fn decompressDeflateRaw(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // Pre-condition: need at least minimal deflate data (header byte)
    if (data.len < 1) {
        return error.InvalidFormat;
    }
    std.debug.assert(data.len >= 1);

    // Window buffer for decompression (32KB history window for back-references)
    var window_buf: [flate.max_window_len]u8 = undefined;

    // Create input reader from compressed data
    var input_reader: std.Io.Reader = .fixed(data);

    // Create decompressor for raw deflate (no zlib header/footer)
    var decompressor: flate.Decompress = .init(&input_reader, .raw, &window_buf);

    // Read all decompressed data into allocated buffer.
    // Unlimited is safe because WASM size is bounded by PNG format
    // (max ~16MB per chunk, typically ~30KB for WASM runtime).
    const result = decompressor.reader.allocRemaining(allocator, .unlimited) catch {
        return error.DecompressionFailed;
    };

    // Post-condition: decompression produced output (valid DEFLATE always produces data)
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

fn createFakeWasm(comptime size: usize) [size]u8 {
    var wasm: [size]u8 = undefined;
    // WASM magic
    @memcpy(wasm[0..4], &WASM_MAGIC);
    // Version 1
    wasm[4] = 0x01;
    wasm[5] = 0x00;
    wasm[6] = 0x00;
    wasm[7] = 0x00;
    // Fill rest with pattern
    for (8..size) |i| {
        wasm[i] = @intCast((i * 17 + i / 256) & 0xFF);
    }
    return wasm;
}

test "pNGr roundtrip preserves WASM binary exactly" {
    const allocator = std.testing.allocator;

    // Create minimal valid PNG
    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Create test WASM (fake module with valid magic)
    const wasm = createFakeWasm(128);

    // Embed
    const embedded = try embedRuntime(allocator, png_data, &wasm);
    defer allocator.free(embedded);

    // Verify result is larger (has pNGr chunk)
    try std.testing.expect(embedded.len > png_data.len);

    // Verify PNG signature preserved
    try std.testing.expectEqualSlices(u8, &chunk.PNG_SIGNATURE, embedded[0..8]);

    // Parse and find pNGr chunk
    var iter = try chunk.parseChunks(embedded);
    var found_pngr = false;
    var found_iend = false;

    while (try iter.next()) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &chunk.ChunkType.pNGr)) {
            found_pngr = true;
            // Verify version
            try std.testing.expectEqual(PNGR_VERSION, c.data[0]);
            // Verify compression flag
            try std.testing.expectEqual(FLAG_COMPRESSED, c.data[1] & FLAG_COMPRESSED);
        }
        if (std.mem.eql(u8, &c.chunk_type, &chunk.ChunkType.IEND)) {
            found_iend = true;
            // IEND must come after pNGr
            try std.testing.expect(found_pngr);
        }
    }

    try std.testing.expect(found_pngr);
    try std.testing.expect(found_iend);
}

test "extract returns identical WASM after embed" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Create test WASM
    const wasm = createFakeWasm(256);

    // Embed
    const embedded = try embedRuntime(allocator, png_data, &wasm);
    defer allocator.free(embedded);

    // Extract
    const extracted = try extractRuntime(allocator, embedded);
    defer allocator.free(extracted);

    // Verify roundtrip
    try std.testing.expectEqualSlices(u8, &wasm, extracted);
}

test "DEFLATE compression significantly reduces zeros-heavy WASM" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Create highly compressible WASM (mostly zeros)
    var wasm: [4096]u8 = undefined;
    @memcpy(wasm[0..4], &WASM_MAGIC);
    wasm[4] = 0x01;
    @memset(wasm[5..], 0x00);

    const embedded = try embedRuntime(allocator, png_data, &wasm);
    defer allocator.free(embedded);

    // Find pNGr and check compression
    var iter = try chunk.parseChunks(embedded);
    while (try iter.next()) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &chunk.ChunkType.pNGr)) {
            const flags = c.data[1];
            try std.testing.expectEqual(FLAG_COMPRESSED, flags & FLAG_COMPRESSED);

            // Payload should be much smaller than 4096 bytes (highly compressible)
            const payload_size = c.data.len - 2;
            try std.testing.expect(payload_size < 200); // Should compress very well
            break;
        }
    }
}

test "hasPngr returns false for PNG without pNGr chunk" {
    const allocator = std.testing.allocator;

    // Create PNG without pNGr
    const png_without = try createMinimalPng(allocator);
    defer allocator.free(png_without);

    try std.testing.expect(!hasPngr(png_without));

    // Create PNG with pNGr
    const wasm = createFakeWasm(64);

    const png_with = try embedRuntime(allocator, png_without, &wasm);
    defer allocator.free(png_with);

    try std.testing.expect(hasPngr(png_with));
}

test "getPngrInfo reports version and compression correctly" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Use highly compressible data (zeros) to ensure compression works
    var wasm: [1024]u8 = undefined;
    @memcpy(wasm[0..4], &WASM_MAGIC);
    wasm[4] = 0x01;
    wasm[5] = 0x00;
    wasm[6] = 0x00;
    wasm[7] = 0x00;
    @memset(wasm[8..], 0x00); // Zeros compress very well

    const embedded = try embedRuntime(allocator, png_data, &wasm);
    defer allocator.free(embedded);

    const info = try getPngrInfo(embedded);
    try std.testing.expectEqual(PNGR_VERSION, info.version);
    try std.testing.expect(info.compressed);
    // 1KB of zeros should compress to much less than original size
    try std.testing.expect(info.payload_bytes < 200);
}

test "embedRuntime rejects data without PNG signature" {
    const allocator = std.testing.allocator;

    const bad_png = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    const wasm = createFakeWasm(32);

    try std.testing.expectError(Error.InvalidPng, embedRuntime(allocator, &bad_png, &wasm));
}

test "embedRuntime rejects WASM with wrong magic bytes" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Invalid WASM (wrong magic)
    const bad_wasm = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };

    try std.testing.expectError(Error.InvalidWasm, embedRuntime(allocator, png_data, &bad_wasm));
}

test "embedRuntime rejects WASM smaller than 8 bytes" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // 7 bytes - one less than minimum
    const small_wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00 };

    try std.testing.expectError(Error.RuntimeTooSmall, embedRuntime(allocator, png_data, &small_wasm));
}

test "extractRuntime returns NoPngrChunk for plain PNG" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    try std.testing.expectError(Error.NoPngrChunk, extractRuntime(allocator, png_data));
}

test "32KB WASM roundtrips through embed and extract" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // 32KB WASM (typical runtime size)
    const large_size: usize = 32 * 1024;
    const wasm = try allocator.alloc(u8, large_size);
    defer allocator.free(wasm);

    @memcpy(wasm[0..4], &WASM_MAGIC);
    wasm[4] = 0x01;
    wasm[5] = 0x00;
    wasm[6] = 0x00;
    wasm[7] = 0x00;
    // Fill with semi-random pattern (simulates real WASM)
    for (8..large_size) |i| {
        wasm[i] = @intCast((i * 31 + i / 256) & 0xFF);
    }

    // Embed
    const embedded = try embedRuntime(allocator, png_data, wasm);
    defer allocator.free(embedded);

    // Extract
    const extracted = try extractRuntime(allocator, embedded);
    defer allocator.free(extracted);

    // Verify exact roundtrip
    try std.testing.expectEqual(large_size, extracted.len);
    try std.testing.expectEqualSlices(u8, wasm, extracted);
}

test "all 256 byte values preserved through compression roundtrip" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Create WASM with all 256 byte values
    var wasm: [256 + 8]u8 = undefined;
    @memcpy(wasm[0..4], &WASM_MAGIC);
    wasm[4] = 0x01;
    wasm[5] = 0x00;
    wasm[6] = 0x00;
    wasm[7] = 0x00;
    // All byte values 0x00-0xFF
    for (0..256) |i| {
        wasm[8 + i] = @intCast(i);
    }

    const embedded = try embedRuntime(allocator, png_data, &wasm);
    defer allocator.free(embedded);

    const extracted = try extractRuntime(allocator, embedded);
    defer allocator.free(extracted);

    try std.testing.expectEqualSlices(u8, &wasm, extracted);

    // Verify all byte values are preserved
    for (0..256) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), extracted[8 + i]);
    }
}

test "minimum valid WASM (8 bytes) embeds and extracts correctly" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Exactly minimum size
    const wasm = createFakeWasm(8);

    const embedded = try embedRuntime(allocator, png_data, &wasm);
    defer allocator.free(embedded);

    const extracted = try extractRuntime(allocator, embedded);
    defer allocator.free(extracted);

    try std.testing.expectEqualSlices(u8, &wasm, extracted);
}

test "embedRuntime handles OOM gracefully" {
    // Systematically test OOM at each allocation point.
    // FailingAllocator fails on the Nth allocation, letting us verify
    // that partial allocations are cleaned up properly.
    const base_allocator = std.testing.allocator;

    // Create test data once with the real allocator
    const png_data = try createMinimalPng(base_allocator);
    defer base_allocator.free(png_data);

    const wasm = createFakeWasm(64);

    // Test OOM at each allocation point
    var fail_index: usize = 0;
    while (fail_index < 20) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(base_allocator, .{
            .fail_index = fail_index,
        });

        const result = embedRuntime(failing.allocator(), png_data, &wasm);

        if (failing.has_induced_failure) {
            // OOM occurred - verify we get an error (OOM or compression failure due to OOM)
            if (result) |embedded| {
                failing.allocator().free(embedded);
                // Unexpectedly succeeded despite induced failure
                try std.testing.expect(false);
            } else |err| {
                // Expected: either OutOfMemory or CompressionFailed (internal OOM)
                try std.testing.expect(err == Error.OutOfMemory or err == Error.CompressionFailed);
            }
        } else {
            // No OOM - operation should succeed
            const embedded = try result;
            failing.allocator().free(embedded);
            break; // Test complete - no more allocations to fail
        }
    }
}

test "extractRuntime handles OOM gracefully" {
    const base_allocator = std.testing.allocator;

    // Create embedded PNG first
    const png_data = try createMinimalPng(base_allocator);
    defer base_allocator.free(png_data);

    const wasm = createFakeWasm(64);

    const embedded = try embedRuntime(base_allocator, png_data, &wasm);
    defer base_allocator.free(embedded);

    // Test OOM during extraction
    var fail_index: usize = 0;
    while (fail_index < 10) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(base_allocator, .{
            .fail_index = fail_index,
        });

        const result = extractRuntime(failing.allocator(), embedded);

        if (failing.has_induced_failure) {
            // OOM or decompression failure due to OOM
            if (result) |extracted| {
                failing.allocator().free(extracted);
            } else |err| {
                try std.testing.expect(err == Error.OutOfMemory or err == Error.DecompressionFailed);
            }
        } else {
            // No OOM - operation should succeed
            const extracted = try result;
            failing.allocator().free(extracted);
            break;
        }
    }
}

test "fuzz embedRuntime properties" {
    // Property-based fuzz test for runtime embedding.
    // Properties verified:
    // 1. Output always larger than input PNG
    // 2. Output starts with PNG signature
    // 3. Output contains pNGr chunk
    // 4. No memory leaks (testing.allocator detects)
    try std.testing.fuzz({}, testEmbedProperties, .{});
}

fn testEmbedProperties(_: @TypeOf({}), input: []const u8) anyerror!void {
    // Skip inputs too small for valid WASM
    if (input.len < 8) return;

    const allocator = std.testing.allocator;

    // Create valid WASM from input by prepending magic
    const wasm_size = @min(input.len, 4096);
    const wasm = try allocator.alloc(u8, wasm_size);
    defer allocator.free(wasm);

    @memcpy(wasm[0..4], &WASM_MAGIC);
    wasm[4] = 0x01;
    wasm[5] = 0x00;
    wasm[6] = 0x00;
    wasm[7] = 0x00;
    if (wasm_size > 8) {
        @memcpy(wasm[8..], input[0..wasm_size - 8]);
    }

    // Create minimal PNG
    const png_data = createMinimalPng(allocator) catch return;
    defer allocator.free(png_data);

    // Embed
    const embedded = embedRuntime(allocator, png_data, wasm) catch return;
    defer allocator.free(embedded);

    // Property 1: Output larger than input
    try std.testing.expect(embedded.len > png_data.len);

    // Property 2: PNG signature preserved
    try std.testing.expect(std.mem.eql(u8, embedded[0..8], &chunk.PNG_SIGNATURE));

    // Property 3: Contains pNGr chunk
    try std.testing.expect(hasPngr(embedded));
}
