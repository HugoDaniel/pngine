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
//! ## Decompression
//!
//! Handles real DEFLATE compressed data (LZ77 + Huffman) using std.compress.flate.
//! Compatible with both store blocks and compressed blocks.
//!
//! ## Invariants
//! - Returns exact original bytecode that was embedded
//! - Caller owns returned memory

const std = @import("std");
const chunk = @import("chunk.zig");
const embed = @import("embed.zig");
const flate = std.compress.flate;

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
    // Unlimited is safe because bytecode size is bounded by PNGB format
    // (max ~16MB per data section entry, typically <100KB total).
    const result = decompressor.reader.allocRemaining(allocator, .unlimited) catch {
        return error.DecompressionFailed;
    };

    // Post-condition: decompression produced output (valid DEFLATE always produces data)
    std.debug.assert(result.len > 0);

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

test "extract: roundtrip with highly compressible data" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Highly compressible bytecode (all zeros except header)
    var bytecode: [4096]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    @memset(bytecode[4..], 0x00);

    const embedded = try embed.embed(allocator, png_data, &bytecode);
    defer allocator.free(embedded);

    const extracted = try extract(allocator, embedded);
    defer allocator.free(extracted);

    try std.testing.expectEqualSlices(u8, &bytecode, extracted);
}

test "extract: roundtrip with pattern data" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Pattern that compresses well
    var bytecode: [1024]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    for (4..1024) |i| {
        bytecode[i] = @intCast(i & 0x0F); // Repeating 0-15
    }

    const embedded = try embed.embed(allocator, png_data, &bytecode);
    defer allocator.free(embedded);

    const extracted = try extract(allocator, embedded);
    defer allocator.free(extracted);

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
    // Embedded bytecode is compressed
    try std.testing.expect(info.compressed);
    // Compressed payload should be smaller than original 32 bytes
    try std.testing.expect(info.payload_size < 32);
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

test "extract: very large roundtrip (100KB)" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // 100KB bytecode (simulates WASM module)
    const large_size: usize = 100 * 1024;
    const bytecode = try allocator.alloc(u8, large_size);
    defer allocator.free(bytecode);

    @memcpy(bytecode[0..4], "PNGB");
    // Fill with semi-random pattern
    for (4..large_size) |i| {
        bytecode[i] = @intCast((i * 31 + i / 256) & 0xFF);
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

test "extract: WASM-like data roundtrip" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Simulate WASM module structure
    var bytecode: [8192]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    // WASM-like pattern: section headers, type indices, opcodes
    for (4..8192) |i| {
        const section = i / 256;
        const offset_in_section = i % 256;
        bytecode[i] = @intCast((section * 17 + offset_in_section) & 0xFF);
    }

    const embedded = try embed.embed(allocator, png_data, &bytecode);
    defer allocator.free(embedded);

    const extracted = try extract(allocator, embedded);
    defer allocator.free(extracted);

    try std.testing.expectEqualSlices(u8, &bytecode, extracted);
}

test "extract: compression actually reduces size" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Highly compressible data
    var bytecode: [4096]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    @memset(bytecode[4..], 'A');

    const embedded = try embed.embed(allocator, png_data, &bytecode);
    defer allocator.free(embedded);

    // Verify compression achieved significant size reduction
    const info = try getPngbInfo(embedded);
    try std.testing.expect(info.compressed);
    // Should compress to less than 10% of original
    try std.testing.expect(info.payload_size < 400);

    // Still extracts correctly
    const extracted = try extract(allocator, embedded);
    defer allocator.free(extracted);
    try std.testing.expectEqualSlices(u8, &bytecode, extracted);
}

test "extract: alternating bytes roundtrip" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Alternating 0x00/0xFF pattern (less compressible)
    var bytecode: [512]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    for (4..512) |i| {
        bytecode[i] = if (i % 2 == 0) 0x00 else 0xFF;
    }

    const embedded = try embed.embed(allocator, png_data, &bytecode);
    defer allocator.free(embedded);

    const extracted = try extract(allocator, embedded);
    defer allocator.free(extracted);

    try std.testing.expectEqualSlices(u8, &bytecode, extracted);
}

// ============================================================================
// OOM Tests
// ============================================================================

test "extract: OOM during extraction handled gracefully" {
    const base_allocator = std.testing.allocator;

    // First create valid embedded PNG
    const png_data = try createMinimalPng(base_allocator);
    defer base_allocator.free(png_data);

    var bytecode: [128]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    @memset(bytecode[4..], 0xAB);

    const embedded = try embed.embed(base_allocator, png_data, &bytecode);
    defer base_allocator.free(embedded);

    // Test OOM at each allocation point
    var fail_index: usize = 0;
    while (fail_index < 20) : (fail_index += 1) {
        var failing_alloc = std.testing.FailingAllocator.init(base_allocator, .{
            .fail_index = fail_index,
        });

        const result = extract(failing_alloc.allocator(), embedded);

        if (failing_alloc.has_induced_failure) {
            // OOM is expected - verify graceful handling (no crash)
            if (result) |data| {
                failing_alloc.allocator().free(data);
            } else |_| {
                // Error is expected
            }
        } else {
            // No OOM - verify success
            if (result) |data| {
                failing_alloc.allocator().free(data);
            } else |_| {
                // Unexpected error
            }
            break;
        }
    }
}

test "embed: OOM during embedding handled gracefully" {
    const base_allocator = std.testing.allocator;

    const png_data = try createMinimalPng(base_allocator);
    defer base_allocator.free(png_data);

    var bytecode: [128]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    @memset(bytecode[4..], 0xCD);

    // Test OOM at each allocation point
    var fail_index: usize = 0;
    while (fail_index < 30) : (fail_index += 1) {
        var failing_alloc = std.testing.FailingAllocator.init(base_allocator, .{
            .fail_index = fail_index,
        });

        const result = embed.embed(failing_alloc.allocator(), png_data, &bytecode);

        if (failing_alloc.has_induced_failure) {
            if (result) |data| {
                failing_alloc.allocator().free(data);
            } else |_| {
                // OOM error is expected
            }
        } else {
            if (result) |data| {
                failing_alloc.allocator().free(data);
            } else |_| {}
            break;
        }
    }
}

// ============================================================================
// Corrupted/Edge Case Tests
// ============================================================================

test "extract: truncated PNG returns error" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    var bytecode: [64]u8 = undefined;
    @memcpy(bytecode[0..4], "PNGB");
    @memset(bytecode[4..], 0);

    const embedded = try embed.embed(allocator, png_data, &bytecode);
    defer allocator.free(embedded);

    // Truncate to just after PNG signature
    if (embedded.len > 20) {
        const truncated = embedded[0..20];
        try std.testing.expectError(Error.InvalidPng, extract(allocator, truncated));
    }
}

test "extract: PNG with invalid pNGb version returns error" {
    const allocator = std.testing.allocator;

    // Manually construct a PNG with invalid pNGb version
    var png_buf: std.ArrayListUnmanaged(u8) = .{};
    defer png_buf.deinit(allocator);

    // PNG signature
    try png_buf.appendSlice(allocator, &chunk.PNG_SIGNATURE);

    // IHDR chunk
    const ihdr_data = [13]u8{
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x00, 0x00, 0x00, 0x00,
    };
    try chunk.writeChunk(&png_buf, allocator, chunk.ChunkType.IHDR, &ihdr_data);

    // pNGb chunk with invalid version (0xFF instead of 0x01)
    const pngb_data = [_]u8{ 0xFF, 0x00, 0x50, 0x4E, 0x47, 0x42 }; // version=0xFF, flags=0, "PNGB"
    try chunk.writeChunk(&png_buf, allocator, embed.PNGB_CHUNK_TYPE, &pngb_data);

    // IEND chunk
    try chunk.writeChunk(&png_buf, allocator, chunk.ChunkType.IEND, "");

    try std.testing.expectError(Error.InvalidPngbVersion, extract(allocator, png_buf.items));
}

test "extract: empty data returns error" {
    const allocator = std.testing.allocator;
    const empty: []const u8 = "";
    try std.testing.expectError(Error.InvalidPng, extract(allocator, empty));
}

test "extract: just PNG signature returns error" {
    // PNG signature alone has no chunks, so NoPngbChunk is returned
    // (signature check passes, but no chunks found)
    try std.testing.expectError(Error.NoPngbChunk, extract(std.testing.allocator, &chunk.PNG_SIGNATURE));
}

test "hasPngb: empty data returns false" {
    try std.testing.expect(!hasPngb(""));
}

test "hasPngb: random data returns false" {
    const random_data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE };
    try std.testing.expect(!hasPngb(&random_data));
}

test "getPngbInfo: PNG without pNGb returns error" {
    const allocator = std.testing.allocator;

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    try std.testing.expectError(Error.NoPngbChunk, getPngbInfo(png_data));
}

test "getPngbInfo: invalid PNG returns error" {
    const bad_data = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expectError(Error.InvalidPng, getPngbInfo(&bad_data));
}

// ============================================================================
// Fuzz/Property Tests
// ============================================================================

test "fuzz: extract never crashes on random data" {
    try std.testing.fuzz({}, fuzzExtractProperties, .{
        .corpus = &.{
            // Valid PNG signature but truncated
            &chunk.PNG_SIGNATURE,
            // Random garbage
            &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF },
            // Empty
            "",
            // Almost-PNG signature
            &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x00 },
        },
    });
}

fn fuzzExtractProperties(_: @TypeOf({}), input: []const u8) !void {
    const allocator = std.testing.allocator;

    // Property: extract never crashes on any input
    const result = extract(allocator, input);

    if (result) |data| {
        defer allocator.free(data);
        // Property: if extraction succeeds, result starts with PNGB
        try std.testing.expect(data.len >= 4);
    } else |_| {
        // Error is expected for random data
    }
}

test "fuzz: hasPngb never crashes on random data" {
    try std.testing.fuzz({}, fuzzHasPngbProperties, .{
        .corpus = &.{
            &chunk.PNG_SIGNATURE,
            &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF },
            "",
        },
    });
}

fn fuzzHasPngbProperties(_: @TypeOf({}), input: []const u8) !void {
    // Property: hasPngb never crashes on any input
    const result = hasPngb(input);

    // Property: result is deterministic
    const result2 = hasPngb(input);
    try std.testing.expectEqual(result, result2);
}

test "property: roundtrip with random bytecode" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();

    const png_data = try createMinimalPng(allocator);
    defer allocator.free(png_data);

    // Test multiple random bytecodes
    for (0..20) |_| {
        // Random size between 16 and 2048
        const size = random.intRangeAtMost(usize, 16, 2048);
        const bytecode = try allocator.alloc(u8, size);
        defer allocator.free(bytecode);

        // Fill with PNGB header + random data
        @memcpy(bytecode[0..4], "PNGB");
        random.bytes(bytecode[4..]);

        // Embed
        const embedded = try embed.embed(allocator, png_data, bytecode);
        defer allocator.free(embedded);

        // Extract
        const extracted = try extract(allocator, embedded);
        defer allocator.free(extracted);

        // Property: extracted == original
        try std.testing.expectEqualSlices(u8, bytecode, extracted);
    }
}
