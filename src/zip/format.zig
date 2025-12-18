//! ZIP file format structures (PKWARE APPNOTE.TXT)
//!
//! ## Layout
//! ```
//! [Local File Header 1][File Data 1]
//! [Local File Header 2][File Data 2]
//! ...
//! [Central Directory Header 1]
//! [Central Directory Header 2]
//! ...
//! [End of Central Directory]
//! ```
//!
//! ## Invariants
//! - All multi-byte values are little-endian
//! - CRC-32 uses IEEE 802.3 polynomial (same as PNG)
//! - Compression method 0 = store, 8 = deflate

const std = @import("std");

/// Local file header signature
pub const LOCAL_FILE_SIGNATURE: u32 = 0x04034b50;

/// Central directory header signature
pub const CENTRAL_DIR_SIGNATURE: u32 = 0x02014b50;

/// End of central directory signature
pub const END_OF_CENTRAL_DIR_SIGNATURE: u32 = 0x06054b50;

/// Compression methods
pub const Compression = enum(u16) {
    store = 0,
    deflate = 8,
};

/// Local file header (30 bytes fixed + variable filename/extra)
pub const LocalFileHeader = struct {
    signature: u32 = LOCAL_FILE_SIGNATURE,
    version_needed: u16 = 20, // 2.0 for deflate
    flags: u16 = 0,
    compression: u16,
    mod_time: u16 = 0,
    mod_date: u16 = 0,
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    filename_len: u16,
    extra_len: u16 = 0,

    pub const FIXED_SIZE: usize = 30;

    pub fn totalSize(self: LocalFileHeader) usize {
        return FIXED_SIZE + self.filename_len + self.extra_len;
    }

    /// Write header directly to a buffer slice.
    ///
    /// Pre-condition: buf.len >= FIXED_SIZE
    pub fn writeToBuffer(self: LocalFileHeader, buf: *[FIXED_SIZE]u8) void {
        std.debug.assert(buf.len >= FIXED_SIZE);

        std.mem.writeInt(u32, buf[0..4], self.signature, .little);
        std.mem.writeInt(u16, buf[4..6], self.version_needed, .little);
        std.mem.writeInt(u16, buf[6..8], self.flags, .little);
        std.mem.writeInt(u16, buf[8..10], self.compression, .little);
        std.mem.writeInt(u16, buf[10..12], self.mod_time, .little);
        std.mem.writeInt(u16, buf[12..14], self.mod_date, .little);
        std.mem.writeInt(u32, buf[14..18], self.crc32, .little);
        std.mem.writeInt(u32, buf[18..22], self.compressed_size, .little);
        std.mem.writeInt(u32, buf[22..26], self.uncompressed_size, .little);
        std.mem.writeInt(u16, buf[26..28], self.filename_len, .little);
        std.mem.writeInt(u16, buf[28..30], self.extra_len, .little);
    }

    pub fn write(self: LocalFileHeader, writer: anytype) !void {
        var buf: [FIXED_SIZE]u8 = undefined;
        self.writeToBuffer(&buf);
        try writer.writeAll(&buf);
    }

    pub fn read(data: []const u8) !LocalFileHeader {
        if (data.len < FIXED_SIZE) return error.InvalidZip;

        const sig = std.mem.readInt(u32, data[0..4], .little);
        if (sig != LOCAL_FILE_SIGNATURE) return error.InvalidSignature;

        return LocalFileHeader{
            .signature = sig,
            .version_needed = std.mem.readInt(u16, data[4..6], .little),
            .flags = std.mem.readInt(u16, data[6..8], .little),
            .compression = std.mem.readInt(u16, data[8..10], .little),
            .mod_time = std.mem.readInt(u16, data[10..12], .little),
            .mod_date = std.mem.readInt(u16, data[12..14], .little),
            .crc32 = std.mem.readInt(u32, data[14..18], .little),
            .compressed_size = std.mem.readInt(u32, data[18..22], .little),
            .uncompressed_size = std.mem.readInt(u32, data[22..26], .little),
            .filename_len = std.mem.readInt(u16, data[26..28], .little),
            .extra_len = std.mem.readInt(u16, data[28..30], .little),
        };
    }
};

/// Central directory header (46 bytes fixed + variable filename/extra/comment)
pub const CentralDirHeader = struct {
    signature: u32 = CENTRAL_DIR_SIGNATURE,
    version_made_by: u16 = 20,
    version_needed: u16 = 20,
    flags: u16 = 0,
    compression: u16,
    mod_time: u16 = 0,
    mod_date: u16 = 0,
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    filename_len: u16,
    extra_len: u16 = 0,
    comment_len: u16 = 0,
    disk_start: u16 = 0,
    internal_attrs: u16 = 0,
    external_attrs: u32 = 0,
    local_header_offset: u32,

    pub const FIXED_SIZE: usize = 46;

    pub fn totalSize(self: CentralDirHeader) usize {
        return FIXED_SIZE + self.filename_len + self.extra_len + self.comment_len;
    }

    /// Write header directly to a buffer slice.
    ///
    /// Pre-condition: buf.len >= FIXED_SIZE
    pub fn writeToBuffer(self: CentralDirHeader, buf: *[FIXED_SIZE]u8) void {
        std.debug.assert(buf.len >= FIXED_SIZE);

        std.mem.writeInt(u32, buf[0..4], self.signature, .little);
        std.mem.writeInt(u16, buf[4..6], self.version_made_by, .little);
        std.mem.writeInt(u16, buf[6..8], self.version_needed, .little);
        std.mem.writeInt(u16, buf[8..10], self.flags, .little);
        std.mem.writeInt(u16, buf[10..12], self.compression, .little);
        std.mem.writeInt(u16, buf[12..14], self.mod_time, .little);
        std.mem.writeInt(u16, buf[14..16], self.mod_date, .little);
        std.mem.writeInt(u32, buf[16..20], self.crc32, .little);
        std.mem.writeInt(u32, buf[20..24], self.compressed_size, .little);
        std.mem.writeInt(u32, buf[24..28], self.uncompressed_size, .little);
        std.mem.writeInt(u16, buf[28..30], self.filename_len, .little);
        std.mem.writeInt(u16, buf[30..32], self.extra_len, .little);
        std.mem.writeInt(u16, buf[32..34], self.comment_len, .little);
        std.mem.writeInt(u16, buf[34..36], self.disk_start, .little);
        std.mem.writeInt(u16, buf[36..38], self.internal_attrs, .little);
        std.mem.writeInt(u32, buf[38..42], self.external_attrs, .little);
        std.mem.writeInt(u32, buf[42..46], self.local_header_offset, .little);
    }

    pub fn write(self: CentralDirHeader, writer: anytype) !void {
        var buf: [FIXED_SIZE]u8 = undefined;
        self.writeToBuffer(&buf);
        try writer.writeAll(&buf);
    }

    pub fn read(data: []const u8) !CentralDirHeader {
        if (data.len < FIXED_SIZE) return error.InvalidZip;

        const sig = std.mem.readInt(u32, data[0..4], .little);
        if (sig != CENTRAL_DIR_SIGNATURE) return error.InvalidSignature;

        return CentralDirHeader{
            .signature = sig,
            .version_made_by = std.mem.readInt(u16, data[4..6], .little),
            .version_needed = std.mem.readInt(u16, data[6..8], .little),
            .flags = std.mem.readInt(u16, data[8..10], .little),
            .compression = std.mem.readInt(u16, data[10..12], .little),
            .mod_time = std.mem.readInt(u16, data[12..14], .little),
            .mod_date = std.mem.readInt(u16, data[14..16], .little),
            .crc32 = std.mem.readInt(u32, data[16..20], .little),
            .compressed_size = std.mem.readInt(u32, data[20..24], .little),
            .uncompressed_size = std.mem.readInt(u32, data[24..28], .little),
            .filename_len = std.mem.readInt(u16, data[28..30], .little),
            .extra_len = std.mem.readInt(u16, data[30..32], .little),
            .comment_len = std.mem.readInt(u16, data[32..34], .little),
            .disk_start = std.mem.readInt(u16, data[34..36], .little),
            .internal_attrs = std.mem.readInt(u16, data[36..38], .little),
            .external_attrs = std.mem.readInt(u32, data[38..42], .little),
            .local_header_offset = std.mem.readInt(u32, data[42..46], .little),
        };
    }
};

/// End of central directory record (22 bytes fixed + variable comment)
pub const EndOfCentralDir = struct {
    signature: u32 = END_OF_CENTRAL_DIR_SIGNATURE,
    disk_number: u16 = 0,
    central_dir_disk: u16 = 0,
    entries_on_disk: u16,
    total_entries: u16,
    central_dir_size: u32,
    central_dir_offset: u32,
    comment_len: u16 = 0,

    pub const FIXED_SIZE: usize = 22;

    /// Write header directly to a buffer slice.
    ///
    /// Pre-condition: buf.len >= FIXED_SIZE
    pub fn writeToBuffer(self: EndOfCentralDir, buf: *[FIXED_SIZE]u8) void {
        std.debug.assert(buf.len >= FIXED_SIZE);

        std.mem.writeInt(u32, buf[0..4], self.signature, .little);
        std.mem.writeInt(u16, buf[4..6], self.disk_number, .little);
        std.mem.writeInt(u16, buf[6..8], self.central_dir_disk, .little);
        std.mem.writeInt(u16, buf[8..10], self.entries_on_disk, .little);
        std.mem.writeInt(u16, buf[10..12], self.total_entries, .little);
        std.mem.writeInt(u32, buf[12..16], self.central_dir_size, .little);
        std.mem.writeInt(u32, buf[16..20], self.central_dir_offset, .little);
        std.mem.writeInt(u16, buf[20..22], self.comment_len, .little);
    }

    pub fn write(self: EndOfCentralDir, writer: anytype) !void {
        var buf: [FIXED_SIZE]u8 = undefined;
        self.writeToBuffer(&buf);
        try writer.writeAll(&buf);
    }

    pub fn read(data: []const u8) !EndOfCentralDir {
        if (data.len < FIXED_SIZE) return error.InvalidZip;

        const sig = std.mem.readInt(u32, data[0..4], .little);
        if (sig != END_OF_CENTRAL_DIR_SIGNATURE) return error.InvalidSignature;

        return EndOfCentralDir{
            .signature = sig,
            .disk_number = std.mem.readInt(u16, data[4..6], .little),
            .central_dir_disk = std.mem.readInt(u16, data[6..8], .little),
            .entries_on_disk = std.mem.readInt(u16, data[8..10], .little),
            .total_entries = std.mem.readInt(u16, data[10..12], .little),
            .central_dir_size = std.mem.readInt(u32, data[12..16], .little),
            .central_dir_offset = std.mem.readInt(u32, data[16..20], .little),
            .comment_len = std.mem.readInt(u16, data[20..22], .little),
        };
    }
};

/// Check if data starts with ZIP signature
pub fn isZip(data: []const u8) bool {
    if (data.len < 4) return false;
    const sig = std.mem.readInt(u32, data[0..4], .little);
    return sig == LOCAL_FILE_SIGNATURE;
}

test "LocalFileHeader size" {
    try std.testing.expectEqual(@as(usize, 30), LocalFileHeader.FIXED_SIZE);
}

test "CentralDirHeader size" {
    try std.testing.expectEqual(@as(usize, 46), CentralDirHeader.FIXED_SIZE);
}

test "EndOfCentralDir size" {
    try std.testing.expectEqual(@as(usize, 22), EndOfCentralDir.FIXED_SIZE);
}

test "LocalFileHeader roundtrip" {
    var buffer: [LocalFileHeader.FIXED_SIZE]u8 = undefined;

    const header = LocalFileHeader{
        .compression = @intFromEnum(Compression.deflate),
        .crc32 = 0x12345678,
        .compressed_size = 100,
        .uncompressed_size = 200,
        .filename_len = 10,
    };

    header.writeToBuffer(&buffer);

    const parsed = try LocalFileHeader.read(&buffer);
    try std.testing.expectEqual(header.crc32, parsed.crc32);
    try std.testing.expectEqual(header.compressed_size, parsed.compressed_size);
    try std.testing.expectEqual(header.filename_len, parsed.filename_len);
}
