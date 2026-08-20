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
const createMinimalPng = @import("test_png.zig").createMinimalPng;
const crc32 = @import("crc32.zig");
const flate = std.compress.flate;

/// pNGb chunk type identifier.
pub const PNGB_CHUNK_TYPE = chunk.ChunkType.pNGb;

/// pNGm chunk type identifier for metadata.
pub const PNGM_CHUNK_TYPE = chunk.ChunkType.pNGm;

/// pNGa chunk type identifier for audio.
pub const PNGA_CHUNK_TYPE = chunk.ChunkType.pNGa;

/// pNGf chunk type identifier for flat command buffers.
pub const PNGF_CHUNK_TYPE = chunk.ChunkType.pNGf;

/// Current pNGm format version.
pub const PNGM_VERSION: u8 = 0x01;

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

/// How a chunk's payload is wrapped before it is written.
pub const ChunkEncoding = enum {
    /// `[version, FLAG_COMPRESSED, deflate_raw(payload)]` — pNGb, pNGa, pNGf.
    versioned_deflate,
    /// `[version, payload]` — pNGm metadata JSON, stored uncompressed.
    versioned_raw,
};

/// One chunk to insert before IEND.
pub const ChunkSpec = struct {
    /// A 4-byte PNG chunk type, e.g. `chunk.ChunkType.pNGb`. (ChunkType is a
    /// namespace of `[4]u8` constants, not an enum.)
    chunk_type: [4]u8,
    payload: []const u8,
    encoding: ChunkEncoding,
    version: u8 = PNGB_VERSION,
};

/// Upper bound on chunks per embed call. The public entry points use at most
/// two (pNGm + pNGb); the array below is sized so a bounded loop can build
/// them without a heap list.
pub const MAX_EMBED_CHUNKS: usize = 4;

/// Reject anything that is not a PNG.
///
/// Split out so the public wrappers can run it BEFORE their own payload
/// checks: callers rely on InvalidPng taking precedence over
/// BytecodeTooSmall when both apply.
fn checkPngSignature(png_data: []const u8) Error!void {
    if (png_data.len < 8 or !std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE)) {
        return Error.InvalidPng;
    }
}

/// Wrap a spec's payload into its on-disk chunk data. Caller owns the result.
fn encodeChunkData(allocator: std.mem.Allocator, spec: ChunkSpec) Error![]u8 {
    switch (spec.encoding) {
        .versioned_deflate => {
            const compressed = compressDeflateRaw(allocator, spec.payload) catch {
                return Error.CompressionFailed;
            };
            defer allocator.free(compressed);

            const data = allocator.alloc(u8, 2 + compressed.len) catch {
                return Error.OutOfMemory;
            };
            data[0] = spec.version;
            data[1] = FLAG_COMPRESSED;
            @memcpy(data[2..], compressed);
            return data;
        },
        .versioned_raw => {
            const data = allocator.alloc(u8, 1 + spec.payload.len) catch {
                return Error.OutOfMemory;
            };
            data[0] = spec.version;
            @memcpy(data[1..], spec.payload);
            return data;
        },
    }
}

/// Insert `specs` into `png_data` immediately before IEND, in order.
///
/// The single implementation behind embed / embedWithMetadata / embedAudio /
/// embedFlat, which previously repeated this whole skeleton (validate →
/// findIEND → deflate → build payload → size math → alloc → copy/write/copy)
/// four times, so every bounds or CRC fix had to land four times.
///
/// Pre-conditions:
/// - png_data starts with a valid PNG signature and contains IEND
/// - 1 <= specs.len <= MAX_EMBED_CHUNKS
///
/// Post-conditions:
/// - Returns a valid PNG with every spec present, original image data intact
/// - Caller owns the returned slice
///
/// Complexity: O(png_data.len + total payload len)
fn embedChunks(
    allocator: std.mem.Allocator,
    png_data: []const u8,
    specs: []const ChunkSpec,
) Error![]u8 {
    // Pre-conditions
    std.debug.assert(specs.len >= 1);
    std.debug.assert(specs.len <= MAX_EMBED_CHUNKS);

    try checkPngSignature(png_data);
    std.debug.assert(png_data.len >= 8);

    const iend_pos = findIEND(png_data) orelse return Error.MissingIEND;
    std.debug.assert(iend_pos >= 8);

    // Encode every chunk first: sizes are needed before the result is sized.
    var encoded: [MAX_EMBED_CHUNKS][]u8 = undefined;
    var encoded_len: usize = 0;
    defer for (encoded[0..encoded_len]) |data| allocator.free(data);

    var chunks_size: usize = 0;
    for (specs) |spec| {
        const data = try encodeChunkData(allocator, spec);
        encoded[encoded_len] = data;
        encoded_len += 1;
        chunks_size += chunk.chunkSize(data.len);
    }
    std.debug.assert(encoded_len == specs.len);

    const result_size = iend_pos + chunks_size + (png_data.len - iend_pos);
    const result = allocator.alloc(u8, result_size) catch {
        return Error.OutOfMemory;
    };
    errdefer allocator.free(result);

    // Assemble: [original up to IEND] + [chunks, in order] + [IEND chunk]
    @memcpy(result[0..iend_pos], png_data[0..iend_pos]);

    var write_pos = iend_pos;
    for (specs, encoded[0..encoded_len]) |spec, data| {
        _ = chunk.writeChunkToBuffer(result[write_pos..], spec.chunk_type, data);
        write_pos += chunk.chunkSize(data.len);
    }
    std.debug.assert(write_pos == iend_pos + chunks_size);

    @memcpy(result[write_pos..], png_data[iend_pos..]);

    // Post-conditions
    std.debug.assert(std.mem.eql(u8, result[0..8], &chunk.PNG_SIGNATURE));
    std.debug.assert(result.len > png_data.len);

    return result;
}

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
    // Byte-for-byte the metadata-less case: with an empty metadata string
    // embedWithMetadata emits a pNGb chunk and nothing else.
    return embedWithMetadata(allocator, png_data, bytecode, "");
}

/// Embed PNGB bytecode and metadata into a PNG image.
///
/// Similar to embed(), but also embeds animation metadata in a pNGm chunk.
/// Both chunks are inserted before IEND: pNGm first, then pNGb.
///
/// Pre-conditions:
/// - png_data starts with valid PNG signature
/// - png_data contains IEND chunk
/// - bytecode is valid PNGB (>= 16 bytes with correct magic)
/// - metadata is valid JSON (can be empty string to skip)
///
/// Post-conditions:
/// - Returns valid PNG with embedded pNGb and optionally pNGm chunks
/// - Original image data is preserved
/// - Caller owns returned slice
pub fn embedWithMetadata(
    allocator: std.mem.Allocator,
    png_data: []const u8,
    bytecode: []const u8,
    metadata: []const u8,
) Error![]u8 {
    // Signature first: InvalidPng outranks BytecodeTooSmall when both apply.
    try checkPngSignature(png_data);

    if (bytecode.len < 16) {
        return Error.BytecodeTooSmall;
    }
    std.debug.assert(bytecode.len >= 16);

    const pngb = ChunkSpec{
        .chunk_type = PNGB_CHUNK_TYPE,
        .payload = bytecode,
        .encoding = .versioned_deflate,
    };

    if (metadata.len == 0) {
        return embedChunks(allocator, png_data, &.{pngb});
    }

    return embedChunks(allocator, png_data, &.{
        .{
            .chunk_type = PNGM_CHUNK_TYPE,
            .payload = metadata,
            .encoding = .versioned_raw,
            .version = PNGM_VERSION,
        },
        pngb,
    });
}

/// Embed audio WASM into a PNG image as a pNGa chunk.
///
/// Inserts a pNGa chunk containing compressed audio WASM immediately
/// before the IEND chunk. The audio WASM (e.g., sointu compiled song)
/// is compressed with DEFLATE for size reduction.
///
/// Pre-conditions:
/// - png_data starts with valid PNG signature
/// - png_data contains IEND chunk
/// - audio_wasm is a valid WASM module
///
/// Post-conditions:
/// - Returns valid PNG with embedded pNGa chunk
/// - Original image data and other chunks preserved
/// - Caller owns returned slice
pub fn embedAudio(
    allocator: std.mem.Allocator,
    png_data: []const u8,
    audio_wasm: []const u8,
) Error![]u8 {
    std.debug.assert(audio_wasm.len > 0);

    return embedChunks(allocator, png_data, &.{.{
        .chunk_type = PNGA_CHUNK_TYPE,
        .payload = audio_wasm,
        .encoding = .versioned_deflate,
    }});
}

/// Embed flat command buffer data into a PNG image as a pNGf chunk.
///
/// The flat data contains pre-flattened init + frame command buffers with
/// inline data section. No WASM executor needed at runtime.
///
/// Pre-conditions:
/// - png_data starts with valid PNG signature
/// - png_data contains IEND chunk
/// - flat_data is a valid flat command buffer
///
/// Post-conditions:
/// - Returns valid PNG with embedded pNGf chunk
/// - Original image data and other chunks preserved
/// - Caller owns returned slice
pub fn embedFlat(
    allocator: std.mem.Allocator,
    png_data: []const u8,
    flat_data: []const u8,
) Error![]u8 {
    std.debug.assert(flat_data.len > 0);

    return embedChunks(allocator, png_data, &.{.{
        .chunk_type = PNGF_CHUNK_TYPE,
        .payload = flat_data,
        .encoding = .versioned_deflate,
    }});
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
/// Output capacity for a DEFLATE of `len` bytes: the input, 1.5% for the
/// expansion incompressible input suffers, and 1 KiB of block headers.
/// Shared by the three fixed-writer compressors (here, the PNG encoder's zlib
/// stream, the ZIP writer) in spirit — each spells the same sum.
pub fn compressedCapacity(len: usize) usize {
    return len + len / 64 + 1024;
}

fn compressDeflateRaw(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // Pre-condition: data is not empty
    std.debug.assert(data.len > 0);

    // Allocate output buffer larger than input because incompressible data
    // expands. Measured against std's flate at level 6: +1,738 B for 1 MiB of
    // random bytes, +7,079 B for 4 MiB (~0.17%) — so `len + 1024` overflowed
    // the fixed writer from ~600 KiB up, and an embedded JPEG/PNG texture made
    // `render` fail with CompressionFailed. `len / 64` (1.5%) is ~9× that
    // measurement, plus the 1 KiB of headers. (Third leak pass)
    const initial_capacity = compressedCapacity(data.len);
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
        .level_6,
    ) catch {
        return error.CompressionFailed;
    };

    // Stream all input through LZ77+Huffman encoder.
    compressor.writer.writeAll(data) catch {
        return error.CompressionFailed;
    };

    // Finish writes final DEFLATE block with BFINAL=1 marker.
    compressor.finish() catch {
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
