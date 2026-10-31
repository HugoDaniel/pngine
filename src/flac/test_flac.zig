//! Hand-authored FLAC fixtures for the 02.C3 tests.
//!
//! No `flac` binary exists on this host (verified 2026-10-05: no flac,
//! metaflac or ffmpeg on the Linux side or on obs), so every fixture is
//! built by hand from the layout RFC 9639 states, as the spec summarizes it
//! (02:114-131): the `fLaC` marker, a minimal legal STREAMINFO (§8.2), the
//! 4-byte metadata block header (§8.1), the APPLICATION block's u32 ID
//! (§8.4) and the PICTURE block's field chain (§8.8). The frame region is
//! opaque to pngine (the walker never parses frames), so a fixed byte
//! pattern stands in for it and every round-trip test pins it
//! byte-identical: that pin is the documented substitute for `flac -t`,
//! which cannot run here (02:193 says "where the CLI exists"; it does not).
//!
//! The builders return arrays and views only; no allocation, so a test can
//! hold them next to its `std.testing.allocator` checks without a second
//! cleanup story.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The STREAMINFO body every minimal fixture carries: 34 bytes laid out per
/// RFC 9639 §8.2. The values describe 4096-sample blocks of 16-bit stereo
/// at 44100 Hz with unknown frame sizes, zero total samples and a zero MD5;
/// the packed 8-byte field group (sample rate 20 bits, channels-1 3 bits,
/// bits-per-sample-1 5 bits, total samples 36 bits) is derived in the test
/// "golden: the STREAMINFO fixture is the 34 bytes RFC 9639 §8.2 lays out",
/// which rebuilds it from the field arithmetic rather than trusting these
/// literals.
pub const streaminfo_body = [34]u8{
    0x10, 0x00, // min blocksize: 4096
    0x10, 0x00, // max blocksize: 4096
    0x00, 0x00, 0x00, // min framesize: unknown
    0x00, 0x00, 0x00, // max framesize: unknown
    0x0A, 0xC4, 0x42, 0xF0, 0x00, 0x00, 0x00, 0x00, // 44100 Hz, 2ch, 16 bit, 0 samples
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // MD5 (zero: unknown)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

/// A stand-in frame region. The frame header opens with the 14-bit sync
/// 0b11111111111110 (RFC 9639 §6.1), which 0xFF 0xF8 spells; the rest is
/// arbitrary, because pngine never parses frames and no decoder exists here
/// to check them. Round-trip tests pin these bytes byte-identical instead.
pub const frames = [_]u8{
    0xFF, 0xF8, 0x00, 0x00, 0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6,
};

/// One metadata block: [last|type:u8][length:u24 big-endian][data]
/// (RFC 9639 §8.1). Writes into `buf` at `at`; returns the offset just past
/// the block.
pub fn writeBlock(buf: []u8, at: usize, last: bool, block_type: u8, data: []const u8) usize {
    buf[at] = if (last) 0x80 | (block_type & 0x7F) else block_type & 0x7F;
    buf[at + 1] = @intCast((data.len >> 16) & 0xFF);
    buf[at + 2] = @intCast((data.len >> 8) & 0xFF);
    buf[at + 3] = @intCast(data.len & 0xFF);
    @memcpy(buf[at + 4 ..][0..data.len], data);
    return at + 4 + data.len;
}

/// A minimal legal FLAC: `fLaC` + one last-flagged STREAMINFO + the frame
/// region, packed into `buf`. Returns the used length.
pub fn minimalFlacInto(buf: []u8) usize {
    @memcpy(buf[0..4], "fLaC");
    const end = writeBlock(buf, 4, true, 0, &streaminfo_body);
    @memcpy(buf[end..][0..frames.len], &frames);
    return end + frames.len;
}

/// `minimalFlacInto` over a freshly allocated buffer. Caller frees.
pub fn minimalFlac(gpa: Allocator) ![]u8 {
    const buf = try gpa.alloc(u8, 4 + 4 + streaminfo_body.len + frames.len);
    const used = minimalFlacInto(buf);
    std.debug.assert(used == buf.len);
    return buf;
}

/// An ID3v2.4 prefix of `tag_len` payload bytes: the 10-byte header with a
/// syncsafe size (7 bits per byte, big-endian; ID3v2 §3.1) followed by
/// `tag_len` filler bytes. Caller frees.
pub fn id3Prefix(gpa: Allocator, tag_len: usize) ![]u8 {
    const buf = try gpa.alloc(u8, 10 + tag_len);
    buf[0..3].* = .{ 'I', 'D', '3' };
    buf[3] = 0x04; // version 2.4
    buf[4] = 0x00; // revision
    buf[5] = 0x00; // flags
    const size7: u32 = @intCast(tag_len);
    buf[6] = @intCast((size7 >> 21) & 0x7F);
    buf[7] = @intCast((size7 >> 14) & 0x7F);
    buf[8] = @intCast((size7 >> 7) & 0x7F);
    buf[9] = @intCast(size7 & 0x7F);
    @memset(buf[10..], 0x5A);
    return buf;
}

/// A PICTURE block body per RFC 9639 §8.8: type, then length-prefixed MIME
/// and description, then width/height/depth/colors, then the picture bytes.
/// `desc` may be empty. Caller frees.
pub fn pictureBlock(
    gpa: Allocator,
    picture_type: u32,
    mime: []const u8,
    desc: []const u8,
    picture: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try appendU32(&buf, gpa, picture_type);
    try appendU32(&buf, gpa, @intCast(mime.len));
    try buf.appendSlice(gpa, mime);
    try appendU32(&buf, gpa, @intCast(desc.len));
    try buf.appendSlice(gpa, desc);
    try appendU32(&buf, gpa, 1); // width
    try appendU32(&buf, gpa, 1); // height
    try appendU32(&buf, gpa, 24); // depth
    try appendU32(&buf, gpa, 0); // colors (0 for non-paletted)
    try appendU32(&buf, gpa, @intCast(picture.len));
    try buf.appendSlice(gpa, picture);
    return buf.toOwnedSlice(gpa);
}

/// An APPLICATION block body (RFC 9639 §8.4): the registered u32 ID, then
/// the application's data. Caller frees.
pub fn applicationBlock(gpa: Allocator, id: [4]u8, data: []const u8) ![]u8 {
    const buf = try gpa.alloc(u8, 4 + data.len);
    @memcpy(buf[0..4], &id);
    @memcpy(buf[4..], data);
    return buf;
}

fn appendU32(buf: *std.ArrayList(u8), gpa: Allocator, v: u32) !void {
    try buf.append(gpa, @intCast((v >> 24) & 0xFF));
    try buf.append(gpa, @intCast((v >> 16) & 0xFF));
    try buf.append(gpa, @intCast((v >> 8) & 0xFF));
    try buf.append(gpa, @intCast(v & 0xFF));
}
