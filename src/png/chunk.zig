//! PNG chunk parsing and serialization.
//!
//! PNG files consist of a signature followed by chunks. Each chunk has:
//! - Length (4 bytes, big-endian): size of data field only
//! - Type (4 bytes): ASCII chunk type identifier
//! - Data (variable): chunk payload
//! - CRC (4 bytes, big-endian): CRC-32 over type + data
//!
//! ## Chunk Type Encoding
//! Each byte's bit 5 encodes properties:
//! - Byte 0: 0=critical, 1=ancillary
//! - Byte 1: 0=public, 1=private
//! - Byte 2: must be 0 (reserved)
//! - Byte 3: 0=unsafe to copy, 1=safe to copy
//!
//! ## Invariants
//! - PNG signature must be exactly 8 bytes: 89 50 4E 47 0D 0A 1A 0A
//! - Chunk length field does not include type (4B) or CRC (4B)
//! - All multi-byte integers are big-endian

const std = @import("std");
const crc32 = @import("crc32.zig");

/// PNG file signature (8 bytes).
pub const PNG_SIGNATURE = [8]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

/// Standard chunk types.
pub const ChunkType = struct {
    pub const IHDR = [4]u8{ 'I', 'H', 'D', 'R' };
    pub const PLTE = [4]u8{ 'P', 'L', 'T', 'E' };
    pub const IDAT = [4]u8{ 'I', 'D', 'A', 'T' };
    pub const IEND = [4]u8{ 'I', 'E', 'N', 'D' };
    /// PNGine bytecode chunk (ancillary, public, safe-to-copy)
    pub const pNGb = [4]u8{ 'p', 'N', 'G', 'b' };
    /// PNGine metadata chunk (ancillary, public, safe-to-copy)
    /// Contains animation metadata as JSON for JS runtime consumption
    pub const pNGm = [4]u8{ 'p', 'N', 'G', 'm' };
    /// PNGine audio chunk (ancillary, public, safe-to-copy)
    /// Contains audio WASM module (e.g., sointu compiled song)
    pub const pNGa = [4]u8{ 'p', 'N', 'G', 'a' };
    /// PNGine flat command buffer chunk (ancillary, public, safe-to-copy)
    /// Contains pre-flattened init + frame command buffers with inline data
    pub const pNGf = [4]u8{ 'p', 'N', 'G', 'f' };
    /// PNGine WGSL source chunk (ancillary, public, safe-to-copy)
    /// Contains deflate-compressed WGSL shader code for --html compression
    pub const pNGw = [4]u8{ 'p', 'N', 'G', 'w' };
};

/// A parsed PNG chunk (references original data, no allocation).
pub const Chunk = struct {
    chunk_type: [4]u8,
    data: []const u8,
    /// Offset in original PNG data where this chunk starts (at length field).
    offset: usize,
    /// Total chunk size including length, type, data, and CRC.
    total_size: usize,

    /// Check if this chunk is critical (must be understood by decoder).
    pub fn isCritical(self: Chunk) bool {
        return (self.chunk_type[0] & 0x20) == 0;
    }

    /// Check if this chunk is ancillary (can be ignored by decoder).
    pub fn isAncillary(self: Chunk) bool {
        return !self.isCritical();
    }

    /// Check if this chunk is a standard public chunk.
    pub fn isPublic(self: Chunk) bool {
        return (self.chunk_type[1] & 0x20) == 0;
    }

    /// Check if this chunk is safe to copy when image is modified.
    pub fn isSafeToCopy(self: Chunk) bool {
        return (self.chunk_type[3] & 0x20) != 0;
    }
};

/// Error types for PNG parsing.
pub const ParseError = error{
    InvalidSignature,
    UnexpectedEof,
    InvalidCrc,
    ChunkTooLarge,
};

/// Iterator over PNG chunks.
/// Does not allocate; references original PNG data.
pub const ChunkIterator = struct {
    data: []const u8,
    pos: usize,

    /// Maximum chunk data size (16 MiB).
    const MAX_CHUNK_SIZE: u32 = 16 * 1024 * 1024;

    /// Get next chunk, or null if at end.
    /// Returns error if chunk is malformed.
    pub fn next(self: *ChunkIterator) ParseError!?Chunk {
        // Pre-condition: position is valid
        std.debug.assert(self.pos >= 8); // Always past signature
        std.debug.assert(self.pos <= self.data.len);

        // Need at least 12 bytes for a chunk (4 length + 4 type + 0 data + 4 CRC)
        if (self.pos + 12 > self.data.len) {
            return null;
        }

        const chunk_start = self.pos;

        // Read length (4 bytes, big-endian)
        const length = std.mem.readInt(u32, self.data[self.pos..][0..4], .big);

        // Sanity check length
        if (length > MAX_CHUNK_SIZE) {
            return ParseError.ChunkTooLarge;
        }

        // Check we have enough data for this chunk
        const total_size = 4 + 4 + length + 4; // length + type + data + crc
        if (self.pos + total_size > self.data.len) {
            return ParseError.UnexpectedEof;
        }

        // Extract type and data
        const chunk_type = self.data[self.pos + 4 ..][0..4].*;
        const chunk_data = self.data[self.pos + 8 ..][0..length];

        // Verify CRC
        const stored_crc = std.mem.readInt(u32, self.data[self.pos + 8 + length ..][0..4], .big);
        var computed_crc: u32 = 0xFFFFFFFF;
        computed_crc = crc32.update(computed_crc, &chunk_type);
        computed_crc = crc32.update(computed_crc, chunk_data);
        computed_crc = crc32.finalize(computed_crc);

        if (stored_crc != computed_crc) {
            return ParseError.InvalidCrc;
        }

        // Advance position
        self.pos += total_size;

        // Post-condition: chunk is valid
        std.debug.assert(chunk_data.len == length);

        return Chunk{
            .chunk_type = chunk_type,
            .data = chunk_data,
            .offset = chunk_start,
            .total_size = total_size,
        };
    }
};

/// Validate PNG signature and create chunk iterator.
///
/// Pre-condition: png_data contains at least PNG signature.
/// Post-condition: iterator starts at first chunk after signature.
pub fn parseChunks(png_data: []const u8) ParseError!ChunkIterator {
    if (png_data.len < 8) {
        return ParseError.InvalidSignature;
    }

    if (!std.mem.eql(u8, png_data[0..8], &PNG_SIGNATURE)) {
        return ParseError.InvalidSignature;
    }

    // Post-conditions after validation
    std.debug.assert(png_data.len >= 8);
    std.debug.assert(std.mem.eql(u8, png_data[0..8], &PNG_SIGNATURE));

    return ChunkIterator{
        .data = png_data,
        .pos = 8,
    };
}

/// Serialize a chunk to a buffer at specified offset.
/// Returns number of bytes written.
///
/// Pre-condition: buffer has enough space (use chunkSize() to calculate).
pub fn writeChunkToBuffer(buffer: []u8, chunk_type: [4]u8, data: []const u8) usize {
    // Pre-condition: data size fits in u32
    std.debug.assert(data.len <= std.math.maxInt(u32));
    std.debug.assert(buffer.len >= chunkSize(data.len));

    var offset: usize = 0;

    // Length (4 bytes, big-endian)
    std.mem.writeInt(u32, buffer[offset..][0..4], @intCast(data.len), .big);
    offset += 4;

    // Type (4 bytes)
    @memcpy(buffer[offset..][0..4], &chunk_type);
    offset += 4;

    // Data
    @memcpy(buffer[offset..][0..data.len], data);
    offset += data.len;

    // CRC over type + data
    var crc: u32 = 0xFFFFFFFF;
    crc = crc32.update(crc, &chunk_type);
    crc = crc32.update(crc, data);
    crc = crc32.finalize(crc);
    std.mem.writeInt(u32, buffer[offset..][0..4], crc, .big);
    offset += 4;

    return offset;
}

/// Serialize a chunk using ArrayList writer.
pub fn writeChunk(list: *std.ArrayList(u8), allocator: std.mem.Allocator, chunk_type: [4]u8, data: []const u8) !void {
    // Pre-condition: data size fits in u32
    std.debug.assert(data.len <= std.math.maxInt(u32));

    const total_size = chunkSize(data.len);
    try list.ensureUnusedCapacity(allocator, total_size);

    // Length (4 bytes, big-endian)
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(data.len), .big);
    list.appendSliceAssumeCapacity(&len_bytes);

    // Type (4 bytes)
    list.appendSliceAssumeCapacity(&chunk_type);

    // Data
    list.appendSliceAssumeCapacity(data);

    // CRC over type + data
    var crc: u32 = 0xFFFFFFFF;
    crc = crc32.update(crc, &chunk_type);
    crc = crc32.update(crc, data);
    crc = crc32.finalize(crc);

    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc, .big);
    list.appendSliceAssumeCapacity(&crc_bytes);
}

/// Calculate total size of a serialized chunk.
pub fn chunkSize(data_len: usize) usize {
    // Pre-condition: data_len must fit in u32 (PNG limit)
    std.debug.assert(data_len <= std.math.maxInt(u32));

    const result = 4 + 4 + data_len + 4; // length + type + data + crc

    // Post-condition: minimum chunk is 12 bytes
    std.debug.assert(result >= 12);

    return result;
}

// ============================================================================
// Tests
// ============================================================================
