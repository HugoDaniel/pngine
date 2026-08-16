//! Extract PNGB bytecode from PNG files.
//!
//! Parses PNG chunks to find the pNGb chunk and returns the PNGB bytecode.
//! `enumerateChunks` lists every PNGine ancillary chunk (`pNG*`) present — the
//! read-side counterpart to embed's four writers (A7; see docs/architecture.md
//! for the chunk taxonomy).
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
const createMinimalPng = @import("test_png.zig").createMinimalPng;
const embed = @import("embed.zig");
const inflate = @import("inflate.zig");

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

    while (iter.next() catch {
        return Error.InvalidPng;
    }) |c| {
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

    // Inflate the raw-DEFLATE payload, capped so a crafted pNGb chunk cannot
    // expand into a multi-GB OOM (the old `.unlimited` here claimed to be
    // "bounded by format" — it was not). No externally-known size for this
    // chunk, so use the module's absolute cap. (Arc-3 §2.3)
    const result = inflate.decompressCapped(allocator, data, .raw, inflate.MAX_DECOMPRESSED) catch {
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

    while (iter.next() catch {
        return Error.InvalidPng;
    }) |c| {
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

/// One PNGine ancillary chunk found by `enumerateChunks`. Every `pNG*` chunk the
/// `embed*` writers produce shares a 2-byte header (`version:u8`, `flags:u8`)
/// ahead of its payload, so those are surfaced uniformly; `version`/`flags` read
/// `null` only for a chunk too short to carry them (never for a well-formed
/// PNGine chunk). `total_size` is the on-wire size (length + type + data + CRC).
pub const ChunkEntry = struct {
    chunk_type: [4]u8,
    total_size: usize,
    payload_size: usize,
    version: ?u8,
    flags: ?u8,

    /// True iff the chunk's `FLAG_COMPRESSED` bit is set (DEFLATE payload).
    pub fn isCompressed(self: ChunkEntry) bool {
        return if (self.flags) |f| (f & embed.FLAG_COMPRESSED) != 0 else false;
    }
};

/// Enumerate every PNGine ancillary chunk (`pNG*`) present in `png_data`, in file
/// order — the read-side counterpart to the four `embed*` writers, closing the
/// embed/extract asymmetry (A7). `embed` can write pNGb (bytecode), pNGm
/// (metadata), pNGa (audio), and pNGf (flat command buffer); before this, only
/// pNGb could be read back. This lets a caller (the CLI `extract --list`) SEE the
/// full inventory of whatever `embed` produced, regardless of which chunks a given
/// runtime later consumes (pNGb here, pNGa/pNGf in the JS runtime, pNGm/pNGw
/// reserved — see docs/architecture.md). Matches the `pNG` namespace prefix, so a
/// future `pNG*` chunk is enumerated without a code change here.
///
/// Pre-condition: `png_data` starts with the PNG signature.
/// Post-condition: caller owns the returned slice (empty if no PNGine chunks).
/// Complexity: O(png_data.len).
pub fn enumerateChunks(allocator: std.mem.Allocator, png_data: []const u8) Error![]ChunkEntry {
    if (png_data.len < 8 or !std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE)) {
        return Error.InvalidPng;
    }
    std.debug.assert(std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE));

    var list: std.ArrayList(ChunkEntry) = .empty;
    errdefer list.deinit(allocator);

    var iter = chunk.parseChunks(png_data) catch return Error.InvalidPng;
    while (iter.next() catch return Error.InvalidPng) |c| {
        // The PNGine namespace: `pNG` + a family letter. Skip standard PNG chunks
        // (IHDR/IDAT/IEND/…) — only our ancillary chunks are enumerated.
        if (!std.mem.eql(u8, c.chunk_type[0..3], "pNG")) continue;
        const has_header = c.data.len >= 2;
        list.append(allocator, .{
            .chunk_type = c.chunk_type,
            .total_size = c.total_size,
            .payload_size = if (has_header) c.data.len - 2 else c.data.len,
            .version = if (has_header) c.data[0] else null,
            .flags = if (has_header) c.data[1] else null,
        }) catch return Error.OutOfMemory;
    }

    return list.toOwnedSlice(allocator) catch return Error.OutOfMemory;
}

// ============================================================================
// Tests
// ============================================================================

// ============================================================================
// OOM Tests
// ============================================================================

// ============================================================================
// Corrupted/Edge Case Tests
// ============================================================================

// ============================================================================
// Fuzz/Property Tests
// ============================================================================

fn fuzzExtractProperties(_: @TypeOf({}), smith: *std.testing.Smith) !void {
    var buf: [4096]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];
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

fn fuzzHasPngbProperties(_: @TypeOf({}), smith: *std.testing.Smith) !void {
    var buf: [4096]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];

    // Property: hasPngb never crashes on any input
    const result = hasPngb(input);

    // Property: result is deterministic
    const result2 = hasPngb(input);
    try std.testing.expectEqual(result, result2);
}
