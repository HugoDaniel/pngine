//! Minimal PNG decoder for render-test pixel assertions.
//!
//! ## Scope (deliberately narrow)
//! This is an inspection/test decoder, not a general PNG reader. It handles
//! exactly what `pngine --frame` (and this crate's `encoder.zig`) can emit or
//! what a browser screenshot round-trips to:
//! - 8-bit channels only
//! - truecolor RGB (color type 2) or truecolor+alpha RGBA (color type 6)
//! - non-interlaced (interlace method 0)
//! - all five scanline filters (None/Sub/Up/Average/Paeth)
//!
//! Output is ALWAYS RGBA8 (`width*height*4` bytes); RGB inputs get alpha 255.
//!
//! ## Invariants
//! - Anything outside the scope above is a TYPED error, never a guess — a
//!   silently-wrong decode would make a snapshot test lie. Palette, grayscale,
//!   16-bit, and interlaced streams are all rejected.
//! - `chunk.parseChunks` validates each chunk's CRC, so a corrupt stream is
//!   caught before we ever inflate it.

const std = @import("std");
const chunk = @import("chunk.zig");

const inflate = @import("inflate.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// Guard against a malformed IHDR asking for an absurd allocation. 1<<28 pixels
/// is 256M px (1 GiB of RGBA) — far above any real render, far below overflow.
const MAX_PIXELS: u64 = 1 << 28;

pub const Error = error{
    InvalidSignature,
    InvalidFormat,
    UnsupportedBitDepth,
    UnsupportedColorType,
    UnsupportedInterlace,
    InvalidFilter,
    DimensionsTooLarge,
    DecompressionFailed,
    OutOfMemory,
};

/// A decoded image. Pixels are RGBA8, row-major, top-to-bottom. Caller owns.
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(self: *Image, allocator: Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

/// Parsed IHDR fields relevant to decoding.
const Header = struct {
    width: u32,
    height: u32,
    channels: u8, // 3 (RGB) or 4 (RGBA)
};

/// Decode a PNG into RGBA8 pixels.
///
/// Pre-condition: `png_data` is a candidate PNG (checked, not assumed).
/// Post-condition: on success, `pixels.len == width*height*4`.
pub fn decode(allocator: Allocator, png_data: []const u8) Error!Image {
    // Pre-condition
    if (png_data.len < chunk.PNG_SIGNATURE.len) return Error.InvalidSignature;
    if (!std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE)) return Error.InvalidSignature;
    assert(png_data.len >= 8);

    var iter = chunk.parseChunks(png_data) catch return Error.InvalidFormat;

    var header: ?Header = null;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(allocator);

    // A bounded walk over the chunk stream — parseChunks yields at most one
    // chunk per 12+ input bytes, so `png_data.len` is a hard upper bound.
    while (iter.next() catch return Error.InvalidFormat) |c| {
        if (std.mem.eql(u8, &c.chunk_type, "IHDR")) {
            header = try parseHeader(c.data);
        } else if (std.mem.eql(u8, &c.chunk_type, "IDAT")) {
            idat.appendSlice(allocator, c.data) catch return Error.OutOfMemory;
        } else if (std.mem.eql(u8, &c.chunk_type, "IEND")) {
            break;
        }
    }

    const hdr = header orelse return Error.InvalidFormat;
    if (idat.items.len == 0) return Error.InvalidFormat;

    // The IHDR is already validated (dims <= MAX_PIXELS), so the exact raw
    // scanline size is known: one filter byte + width*channels per row. Cap the
    // inflate at that so an IDAT bomb can't expand past what the header claims.
    // (Arc-3 §2.3)
    const expected_raw: usize =
        (@as(usize, hdr.width) * hdr.channels + 1) * @as(usize, hdr.height);
    const raw = inflateZlib(allocator, idat.items, expected_raw) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.DecompressionFailed,
    };
    defer allocator.free(raw);

    const pixels = try unfilter(allocator, raw, hdr);

    // Post-condition
    assert(pixels.len == @as(usize, hdr.width) * @as(usize, hdr.height) * 4);
    return .{ .width = hdr.width, .height = hdr.height, .pixels = pixels };
}

/// Parse + validate the 13-byte IHDR payload, rejecting everything outside the
/// decoder's supported scope with a distinct typed error.
fn parseHeader(data: []const u8) Error!Header {
    if (data.len < 13) return Error.InvalidFormat;

    const width = std.mem.readInt(u32, data[0..4], .big);
    const height = std.mem.readInt(u32, data[4..8], .big);
    const bit_depth = data[8];
    const color_type = data[9];
    const compression = data[10];
    const filter_method = data[11];
    const interlace = data[12];

    if (width == 0 or height == 0) return Error.InvalidFormat;
    if (compression != 0 or filter_method != 0) return Error.InvalidFormat;
    if (bit_depth != 8) return Error.UnsupportedBitDepth;
    if (interlace != 0) return Error.UnsupportedInterlace;

    const channels: u8 = switch (color_type) {
        2 => 3, // truecolor RGB
        6 => 4, // truecolor + alpha
        else => return Error.UnsupportedColorType,
    };

    // Overflow / sanity guard before any size math downstream.
    const px_count = @as(u64, width) * @as(u64, height);
    if (px_count > MAX_PIXELS) return Error.DimensionsTooLarge;

    assert(channels == 3 or channels == 4);
    assert(px_count > 0);
    return .{ .width = width, .height = height, .channels = channels };
}

/// Inflate a zlib stream (RFC 1950) — PNG IDAT uses zlib-wrapped DEFLATE, unlike
/// the raw-DEFLATE pNGb chunk in `extract.zig`. Mirrors that file's decompressor
/// setup but with the `.zlib` container.
fn inflateZlib(allocator: Allocator, data: []const u8, max_out: usize) ![]u8 {
    if (data.len < 2) return error.InvalidFormat;
    return inflate.decompressCapped(allocator, data, .zlib, max_out);
}

/// Reconstruct the filtered scanline stream into RGBA8 pixels.
///
/// The PNG spec defines each filter over the *reconstructed* neighbours a
/// (left), b (up), c (up-left). We reconstruct in place, channel-by-channel,
/// into an RGBA output buffer; for RGB inputs the 4th channel is forced to 255.
fn unfilter(allocator: Allocator, raw: []const u8, hdr: Header) Error![]u8 {
    const bpp: usize = hdr.channels; // bytes per pixel = channels at 8-bit
    const width: usize = hdr.width;
    const height: usize = hdr.height;
    const src_stride = width * bpp; // bytes per unfiltered scanline (source channels)
    const filtered_stride = src_stride + 1; // + 1 filter byte

    // A truncated IDAT (fewer bytes than the header implies) must not be
    // silently accepted — that would decode garbage into a snapshot.
    if (raw.len < filtered_stride * height) return Error.InvalidFormat;

    const dst_stride = width * 4; // RGBA output is always 4 channels
    const pixels = allocator.alloc(u8, dst_stride * height) catch return Error.OutOfMemory;
    errdefer allocator.free(pixels);

    // Reconstructed source-channel bytes for the previous row (for Up/Paeth).
    const prev = allocator.alloc(u8, src_stride) catch return Error.OutOfMemory;
    defer allocator.free(prev);
    @memset(prev, 0);

    const cur = allocator.alloc(u8, src_stride) catch return Error.OutOfMemory;
    defer allocator.free(cur);

    for (0..height) |y| {
        const row = raw[y * filtered_stride ..];
        const filter = row[0];
        if (filter > 4) return Error.InvalidFilter;

        for (0..src_stride) |x| {
            const fv = row[1 + x];
            const a: u8 = if (x >= bpp) cur[x - bpp] else 0;
            const b: u8 = prev[x];
            const c: u8 = if (x >= bpp) prev[x - bpp] else 0;
            cur[x] = switch (filter) {
                0 => fv,
                1 => fv +% a,
                2 => fv +% b,
                3 => fv +% @as(u8, @intCast((@as(u16, a) + @as(u16, b)) / 2)),
                4 => fv +% paeth(a, b, c),
                else => unreachable, // guarded above
            };
        }

        // Expand this reconstructed row into the RGBA output.
        const dst_row = pixels[y * dst_stride ..][0..dst_stride];
        for (0..width) |px| {
            const s = px * bpp;
            const d = px * 4;
            dst_row[d + 0] = cur[s + 0];
            dst_row[d + 1] = cur[s + 1];
            dst_row[d + 2] = cur[s + 2];
            dst_row[d + 3] = if (bpp == 4) cur[s + 3] else 255;
        }

        @memcpy(prev, cur);
    }

    assert(pixels.len == dst_stride * height);
    return pixels;
}

/// The Paeth predictor (PNG spec 6.6): pick the neighbour closest to `a+b-c`.
fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + @as(i16, b) - @as(i16, c);
    const pa = @abs(p - @as(i16, a));
    const pb = @abs(p - @as(i16, b));
    const pc = @abs(p - @as(i16, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const encoder = @import("encoder.zig");

// --- Synthetic-PNG helpers: exercise filters the encoder never emits ---------

/// Adler-32 checksum (RFC 1950) over the uncompressed data.
fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

/// Wrap raw bytes in a zlib stream using stored (uncompressed) DEFLATE blocks —
/// no compressor needed, so the test controls the exact filtered bytes.
fn zlibStore(allocator: Allocator, data: []const u8) ![]u8 {
    assert(data.len > 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, 0x78); // CMF: 32K window, deflate
    try out.append(allocator, 0x01); // FLG: FCHECK makes 0x7801 % 31 == 0

    var i: usize = 0;
    while (i < data.len) {
        const block_len: u16 = @intCast(@min(data.len - i, 65535));
        const final = (i + block_len == data.len);
        try out.append(allocator, if (final) 0x01 else 0x00); // BFINAL + BTYPE=stored
        try out.append(allocator, @intCast(block_len & 0xFF));
        try out.append(allocator, @intCast((block_len >> 8) & 0xFF));
        const nlen = ~block_len;
        try out.append(allocator, @intCast(nlen & 0xFF));
        try out.append(allocator, @intCast((nlen >> 8) & 0xFF));
        try out.appendSlice(allocator, data[i .. i + block_len]);
        i += block_len;
    }

    const adler = adler32(data);
    try out.append(allocator, @intCast((adler >> 24) & 0xFF));
    try out.append(allocator, @intCast((adler >> 16) & 0xFF));
    try out.append(allocator, @intCast((adler >> 8) & 0xFF));
    try out.append(allocator, @intCast(adler & 0xFF));
    return out.toOwnedSlice(allocator);
}

/// Assemble a full PNG from an already-filtered scanline stream.
fn buildPng(
    allocator: Allocator,
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    interlace: u8,
    filtered_stream: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &chunk.PNG_SIGNATURE);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = bit_depth;
    ihdr[9] = color_type;
    ihdr[10] = 0; // compression method
    ihdr[11] = 0; // filter method
    ihdr[12] = interlace;
    try chunk.writeChunk(&out, allocator, "IHDR".*, &ihdr);

    const idat = try zlibStore(allocator, filtered_stream);
    defer allocator.free(idat);
    try chunk.writeChunk(&out, allocator, "IDAT".*, idat);
    try chunk.writeChunk(&out, allocator, "IEND".*, "");
    return out.toOwnedSlice(allocator);
}

/// Forward-filter `raw` (unfiltered channel bytes) with `filter` per the PNG
/// spec, producing the on-disk filtered stream (filter byte + row). This is the
/// inverse of `unfilter`; testing them against each other proves both.
fn applyFilter(
    allocator: Allocator,
    raw: []const u8,
    width: u32,
    height: u32,
    channels: u8,
    filter: u8,
) ![]u8 {
    const bpp: usize = channels;
    const stride = @as(usize, width) * bpp;
    const out = try allocator.alloc(u8, (stride + 1) * height);
    for (0..height) |y| {
        const src = raw[y * stride ..][0..stride];
        const prev: []const u8 = if (y > 0) raw[(y - 1) * stride ..][0..stride] else &[_]u8{};
        const dst = out[y * (stride + 1) ..];
        dst[0] = filter;
        for (0..stride) |x| {
            const a: u8 = if (x >= bpp) src[x - bpp] else 0;
            const b: u8 = if (y > 0) prev[x] else 0;
            const c: u8 = if (y > 0 and x >= bpp) prev[x - bpp] else 0;
            dst[1 + x] = switch (filter) {
                0 => src[x],
                1 => src[x] -% a,
                2 => src[x] -% b,
                3 => src[x] -% @as(u8, @intCast((@as(u16, a) + @as(u16, b)) / 2)),
                4 => src[x] -% paeth(a, b, c),
                else => unreachable,
            };
        }
    }
    return out;
}
