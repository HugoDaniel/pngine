//! Shared PNG fixtures for the png/ unit tests.
//!
//! `createMinimalPng` previously existed as two copies — one in embed.zig, one
//! in extract.zig — that differed only in comments and emitted identical bytes.
//! Both are test-only, and a fixture that two suites disagree about is a
//! fixture that can silently drift, so it lives here once.

const std = @import("std");
const chunk = @import("chunk.zig");

/// Build the smallest valid PNG: signature + IHDR + IDAT + IEND.
///
/// 1x1 8-bit grayscale. Enough for embed/extract round-trips, which only care
/// that the file is well-formed and ends in IEND.
///
/// Caller owns the returned slice.
pub fn createMinimalPng(allocator: std.mem.Allocator) ![]u8 {
    var png_buf: std.ArrayList(u8) = .empty;
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
