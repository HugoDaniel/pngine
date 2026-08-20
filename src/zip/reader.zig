//! ZIP archive reader
//!
//! ## Usage
//! ```zig
//! var reader = try ZipReader.init(allocator, zip_data);
//! defer reader.deinit();
//!
//! // List files
//! for (reader.entries()) |entry| {
//!     std.debug.print("{s}\n", .{entry.filename});
//! }
//!
//! // Extract file
//! const data = try reader.extract("manifest.json");
//! defer allocator.free(data);
//! ```
//!
//! ## Invariants
//! - Central directory is parsed on init
//! - File extraction decompresses on demand
//! - Filenames are validated (no null bytes, reasonable length)

const std = @import("std");
const format = @import("format.zig");

pub const Error = error{
    InvalidZip,
    InvalidSignature,
    FileNotFound,
    UnsupportedCompression,
    DecompressionFailed,
    InvalidCrc,
    OutOfMemory,
};

/// Absolute ceiling on a single entry's decompressed size — a decompression-bomb
/// guard. A crafted entry can claim up to a 4 GB `uncompressed_size`; capping the
/// inflate here turns "tiny archive → multi-GB alloc" into a clean
/// DecompressionFailed. Generous vs any real bundled `.sjon`/asset. (Arc-3 §2.3)
const MAX_DECOMPRESSED: usize = 64 * 1024 * 1024;

/// Entry in the ZIP archive
pub const Entry = struct {
    filename: []const u8,
    compressed_size: u32,
    uncompressed_size: u32,
    compression: u16,
    crc32: u32,
    local_header_offset: u32,
};

/// ZIP archive reader
pub const ZipReader = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    entries: []Entry,
    filenames: []u8,

    const MAX_ENTRIES: usize = 65535;
    const MAX_FILENAME_LEN: usize = 4096;
    const MAX_SEARCH_OFFSET: usize = 65536 + 22; // Max comment + EOCD size

    pub fn init(allocator: std.mem.Allocator, data: []const u8) Error!ZipReader {
        // Input validation - data must be at least EOCD size
        if (data.len < format.EndOfCentralDir.FIXED_SIZE) return Error.InvalidZip;

        // Find end of central directory
        const eocd_offset = findEocd(data) orelse return Error.InvalidZip;
        const eocd = format.EndOfCentralDir.read(data[eocd_offset..]) catch return Error.InvalidZip;

        // Validate offsets
        if (eocd.central_dir_offset >= data.len) return Error.InvalidZip;
        if (eocd.total_entries > MAX_ENTRIES) return Error.InvalidZip;

        // Parse central directory
        var entries = allocator.alloc(Entry, eocd.total_entries) catch return Error.OutOfMemory;
        errdefer allocator.free(entries);

        // Allocate space for all filenames - first pass to calculate total length
        // Note: These use usize for slice indexing compatibility, but values are
        // bounded by ZIP format limits (u32 max for offsets, u16 max for entries).
        var total_filename_len: usize = 0;
        var offset: usize = eocd.central_dir_offset;

        for (0..eocd.total_entries) |_| {
            if (offset + format.CentralDirHeader.FIXED_SIZE > data.len) {
                return Error.InvalidZip;
            }
            const header = format.CentralDirHeader.read(data[offset..]) catch {
                return Error.InvalidZip;
            };
            if (header.filename_len > MAX_FILENAME_LEN) {
                return Error.InvalidZip;
            }
            // The fixed header fits (checked above), but the variable-length
            // filename must ALSO stay in-buffer — the second pass @memcpy's it
            // straight out of `data`. Without this a header near the buffer end
            // claiming a long filename overruns into an OOB read. (Arc-3 §2.4)
            if (offset + format.CentralDirHeader.FIXED_SIZE + header.filename_len > data.len) {
                return Error.InvalidZip;
            }
            total_filename_len += header.filename_len;
            offset += header.totalSize();
        }

        var filenames = allocator.alloc(u8, total_filename_len) catch return Error.OutOfMemory;
        errdefer allocator.free(filenames);

        // Second pass: populate entries
        offset = eocd.central_dir_offset;
        var filename_offset: usize = 0;

        for (0..eocd.total_entries) |i| {
            // The first pass already proved every header reads and every
            // filename fits; a clean error (never `unreachable`/UB) if that
            // somehow does not hold keeps a hostile archive from tripping the
            // stripped assert in a ReleaseFast build. (Arc-3 §2.4)
            const header = format.CentralDirHeader.read(data[offset..]) catch return Error.InvalidZip;
            const filename_start = offset + format.CentralDirHeader.FIXED_SIZE;
            const filename_end = filename_start + header.filename_len;

            // Copy filename
            const filename_slice = filenames[filename_offset..][0..header.filename_len];
            @memcpy(filename_slice, data[filename_start..filename_end]);

            entries[i] = Entry{
                .filename = filename_slice,
                .compressed_size = header.compressed_size,
                .uncompressed_size = header.uncompressed_size,
                .compression = header.compression,
                .crc32 = header.crc32,
                .local_header_offset = header.local_header_offset,
            };

            filename_offset += header.filename_len;
            offset += header.totalSize();
        }

        // Post-conditions: verify both passes produced consistent results
        std.debug.assert(entries.len == eocd.total_entries);
        // Ensure filename buffer was fully populated (second pass matched first pass calculation)
        std.debug.assert(filename_offset == total_filename_len);

        return ZipReader{
            .allocator = allocator,
            .data = data,
            .entries = entries,
            .filenames = filenames,
        };
    }

    pub fn deinit(self: *ZipReader) void {
        self.allocator.free(self.entries);
        self.allocator.free(self.filenames);
    }

    /// Get all entries in the archive
    pub fn getEntries(self: *const ZipReader) []const Entry {
        return self.entries;
    }

    /// Find entry by filename
    pub fn findEntry(self: *const ZipReader, filename: []const u8) ?*const Entry {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.filename, filename)) {
                return entry;
            }
        }
        return null;
    }

    /// Extract file contents by filename
    pub fn extract(self: *const ZipReader, filename: []const u8) Error![]u8 {
        const entry = self.findEntry(filename) orelse return Error.FileNotFound;
        return self.extractEntry(entry);
    }

    /// Extract file contents from entry
    pub fn extractEntry(self: *const ZipReader, entry: *const Entry) Error![]u8 {
        // Read local file header
        if (entry.local_header_offset + format.LocalFileHeader.FIXED_SIZE > self.data.len) {
            return Error.InvalidZip;
        }

        const local = format.LocalFileHeader.read(self.data[entry.local_header_offset..]) catch
            return Error.InvalidZip;

        // Calculate data offset
        const data_offset = entry.local_header_offset + local.totalSize();
        if (data_offset + entry.compressed_size > self.data.len) {
            return Error.InvalidZip;
        }

        const compressed_data = self.data[data_offset..][0..entry.compressed_size];

        // Decompress based on method
        const result = switch (entry.compression) {
            @intFromEnum(format.Compression.store) => blk: {
                // A stored entry IS its bytes: the two sizes must agree, or the
                // central directory is lying — `alloc(uncompressed_size)` +
                // `@memcpy(compressed_size)` was a length-mismatch trap, and at
                // 0xFFFFFFFF a 4 GiB allocation, from a field nothing checked.
                if (entry.uncompressed_size != entry.compressed_size) return Error.InvalidZip;
                const copy = self.allocator.dupe(u8, compressed_data) catch
                    return Error.OutOfMemory;
                break :blk copy;
            },
            @intFromEnum(format.Compression.deflate) => blk: {
                break :blk decompressDeflate(self.allocator, compressed_data, entry.uncompressed_size) catch
                    return Error.DecompressionFailed;
            },
            else => return Error.UnsupportedCompression,
        };

        // Verify CRC
        const computed_crc = std.hash.Crc32.hash(result);
        if (computed_crc != entry.crc32) {
            self.allocator.free(result);
            return Error.InvalidCrc;
        }

        return result;
    }

    /// Find End of Central Directory by scanning backwards
    fn findEocd(data: []const u8) ?usize {
        if (data.len < format.EndOfCentralDir.FIXED_SIZE) return null;

        // EOCD is at end of file (possibly preceded by a comment): scan
        // backwards from the last place a 22-byte EOCD fits, down to the
        // earliest position the maximum comment allows — and never below 0.
        // The old loop subtracted a 0..65558 offset from `len - 22` and
        // underflowed on any buffer shorter than that with no EOCD in it.
        const start_offset = data.len - format.EndOfCentralDir.FIXED_SIZE;
        const lowest = start_offset -| MAX_SEARCH_OFFSET;

        var pos = start_offset;
        for (0..MAX_SEARCH_OFFSET + 1) |_| {
            const sig = std.mem.readInt(u32, data[pos..][0..4], .little);
            if (sig == format.END_OF_CENTRAL_DIR_SIGNATURE) {
                return pos;
            }
            if (pos == lowest) break;
            pos -= 1;
        }

        return null;
    }

    /// Decompress DEFLATE data using std.compress.flate.
    ///
    /// Uses raw DEFLATE format (no zlib header) as required by ZIP.
    fn decompressDeflate(allocator: std.mem.Allocator, compressed: []const u8, uncompressed_size: u32) ![]u8 {
        // Minimum valid deflate stream is 2 bytes (final stored block with 0 bytes)
        if (compressed.len < 2) {
            return error.DecompressionFailed;
        }

        const flate = std.compress.flate;

        // Window buffer for decompression (32KB history window)
        var window_buf: [flate.max_window_len]u8 = undefined;

        // Create input reader from compressed data
        var input_reader: std.Io.Reader = .fixed(compressed);

        // Create decompressor for raw deflate (no zlib header)
        var decompressor: flate.Decompress = .init(&input_reader, .raw, &window_buf);

        // Cap the inflate so a crafted entry cannot expand into a multi-GB OOM.
        // A malicious central directory can claim up to a 4 GB uncompressed_size,
        // so reject anything past the absolute ceiling before allocating. Then
        // allow exactly the declared size (+1 for Limit's reached-or-exceeded
        // rule): a longer stream → StreamTooLong, a shorter one → the exact-size
        // check below. (Arc-3 §2.3)
        if (uncompressed_size > MAX_DECOMPRESSED) return error.DecompressionFailed;
        const result = decompressor.reader.allocRemaining(allocator, .limited(@as(usize, uncompressed_size) + 1)) catch {
            return error.DecompressionFailed;
        };

        // Verify size matches expected
        if (result.len != uncompressed_size) {
            allocator.free(result);
            return error.DecompressionFailed;
        }

        // Post-condition: decompressed size matches expected
        std.debug.assert(result.len == uncompressed_size);

        return result;
    }
};
