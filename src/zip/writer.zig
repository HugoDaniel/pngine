//! ZIP archive writer
//!
//! ## Usage
//! ```zig
//! var writer = ZipWriter.init(allocator);
//! defer writer.deinit();
//!
//! try writer.addFile("manifest.json", json_data, .deflate);
//! try writer.addFile("main.pngb", bytecode, .deflate);
//! try writer.addFile("texture.png", image_data, .store);
//!
//! const zip_data = try writer.finish();
//! defer allocator.free(zip_data);
//! ```
//!
//! ## Invariants
//! - Files are written in order of addFile calls
//! - Central directory is written at the end
//! - All filenames must be valid UTF-8 without null bytes

const std = @import("std");
const format = @import("format.zig");

pub const Error = error{
    InvalidFilename,
    CompressionFailed,
    TooManyFiles,
    OutOfMemory,
};

/// Compression method for files
pub const CompressionMethod = enum {
    store,
    deflate,
};

/// Entry for tracking written files
/// Note: filename is stored as offset+len to avoid slice invalidation on realloc
const WrittenEntry = struct {
    filename_offset: u32,
    filename_len: u16,
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    compression: u16,
    local_header_offset: u32,
};

/// ZIP archive writer
pub const ZipWriter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    entries: std.ArrayList(WrittenEntry),
    filenames: std.ArrayList(u8),

    const MAX_ENTRIES: usize = 65535;
    const MAX_FILENAME_LEN: usize = 4096;

    pub fn init(allocator: std.mem.Allocator) ZipWriter {
        return ZipWriter{
            .allocator = allocator,
            .buffer = .empty,
            .entries = .empty,
            .filenames = .empty,
        };
    }

    pub fn deinit(self: *ZipWriter) void {
        self.buffer.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.filenames.deinit(self.allocator);
    }

    /// Add a file to the archive
    pub fn addFile(
        self: *ZipWriter,
        filename: []const u8,
        data: []const u8,
        method: CompressionMethod,
    ) Error!void {
        // Validate filename
        if (filename.len == 0 or filename.len > MAX_FILENAME_LEN) {
            return Error.InvalidFilename;
        }
        for (filename) |c| {
            if (c == 0) return Error.InvalidFilename;
        }

        // Check entry limit
        if (self.entries.items.len >= MAX_ENTRIES) {
            return Error.TooManyFiles;
        }

        // Calculate CRC before compression
        const crc32 = std.hash.Crc32.hash(data);

        // Compress if requested
        const compressed_data: []const u8 = switch (method) {
            .store => data,
            .deflate => blk: {
                const compressed = compressDeflate(self.allocator, data) catch
                    return Error.CompressionFailed;
                break :blk compressed;
            },
        };
        defer if (method == .deflate) self.allocator.free(compressed_data);

        // Record local header offset
        const local_header_offset: u32 = @intCast(self.buffer.items.len);

        // Store filename (as offset+len to avoid slice invalidation on realloc)
        const filename_offset: u32 = @intCast(self.filenames.items.len);
        self.filenames.appendSlice(self.allocator, filename) catch return Error.OutOfMemory;

        // Write local file header
        const local_header = format.LocalFileHeader{
            .compression = if (method == .deflate) @intFromEnum(format.Compression.deflate) else @intFromEnum(format.Compression.store),
            .crc32 = crc32,
            .compressed_size = @intCast(compressed_data.len),
            .uncompressed_size = @intCast(data.len),
            .filename_len = @intCast(filename.len),
        };

        var header_buf: [format.LocalFileHeader.FIXED_SIZE]u8 = undefined;
        local_header.writeToBuffer(&header_buf);

        self.buffer.appendSlice(self.allocator, &header_buf) catch return Error.OutOfMemory;
        self.buffer.appendSlice(self.allocator, filename) catch return Error.OutOfMemory;
        self.buffer.appendSlice(self.allocator, compressed_data) catch return Error.OutOfMemory;

        // Record entry
        self.entries.append(self.allocator, WrittenEntry{
            .filename_offset = filename_offset,
            .filename_len = @intCast(filename.len),
            .crc32 = crc32,
            .compressed_size = @intCast(compressed_data.len),
            .uncompressed_size = @intCast(data.len),
            .compression = local_header.compression,
            .local_header_offset = local_header_offset,
        }) catch return Error.OutOfMemory;
    }

    /// Finish writing and return the complete ZIP data
    /// Caller owns the returned memory
    pub fn finish(self: *ZipWriter) Error![]u8 {
        const central_dir_offset: u32 = @intCast(self.buffer.items.len);

        // Write central directory headers
        for (self.entries.items) |entry| {
            // Reconstruct filename slice from offset+len
            const filename = self.filenames.items[entry.filename_offset..][0..entry.filename_len];

            const header = format.CentralDirHeader{
                .compression = entry.compression,
                .crc32 = entry.crc32,
                .compressed_size = entry.compressed_size,
                .uncompressed_size = entry.uncompressed_size,
                .filename_len = entry.filename_len,
                .local_header_offset = entry.local_header_offset,
            };

            var header_buf: [format.CentralDirHeader.FIXED_SIZE]u8 = undefined;
            header.writeToBuffer(&header_buf);

            self.buffer.appendSlice(self.allocator, &header_buf) catch return Error.OutOfMemory;
            self.buffer.appendSlice(self.allocator, filename) catch return Error.OutOfMemory;
        }

        const central_dir_size: u32 = @intCast(self.buffer.items.len - central_dir_offset);

        // Write end of central directory
        const eocd = format.EndOfCentralDir{
            .entries_on_disk = @intCast(self.entries.items.len),
            .total_entries = @intCast(self.entries.items.len),
            .central_dir_size = central_dir_size,
            .central_dir_offset = central_dir_offset,
        };

        var eocd_buf: [format.EndOfCentralDir.FIXED_SIZE]u8 = undefined;
        eocd.writeToBuffer(&eocd_buf);

        self.buffer.appendSlice(self.allocator, &eocd_buf) catch return Error.OutOfMemory;

        // Return owned copy
        const result = self.allocator.dupe(u8, self.buffer.items) catch return Error.OutOfMemory;
        return result;
    }

    /// Compress data using DEFLATE (raw format).
    ///
    /// Uses std.compress.flate for real LZ77+Huffman compression.
    /// Produces raw DEFLATE (no zlib header) as required by ZIP.
    fn compressDeflate(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        const flate = std.compress.flate;

        // Allocate output buffer - compressed size may be larger for incompressible data
        // Even empty data needs at least 2 bytes for deflate end marker
        const initial_capacity = @max(data.len, 64) + 1024;
        var output_buf = try allocator.alloc(u8, initial_capacity);
        errdefer allocator.free(output_buf);

        // Window buffer for compression (32KB history window)
        var window_buf: [flate.max_window_len]u8 = undefined;

        // Create output writer
        var output_writer: std.Io.Writer = .fixed(output_buf);

        // Create compressor for raw deflate (no zlib header)
        // Use level 6 - good balance of speed and compression
        var compressor = flate.Compress.init(
            &output_writer,
            &window_buf,
            .raw,
            .level_6,
        ) catch {
            return error.CompressionFailed;
        };

        // Write all data through the compressor
        compressor.writer.writeAll(data) catch {
            return error.CompressionFailed;
        };

        // Finish to finalize compression with BFINAL block
        compressor.finish() catch {
            return error.CompressionFailed;
        };

        const compressed_len = output_writer.end;

        // Create result with exact size
        const result = try allocator.alloc(u8, compressed_len);
        @memcpy(result, output_buf[0..compressed_len]);
        allocator.free(output_buf);

        return result;
    }
};
