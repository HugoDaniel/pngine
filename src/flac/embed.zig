//! The FLAC payload writer (checkpoint 02.C3): `packFlac`, the twin of
//! `packPng`. Spec: expansible-player `docs/02-envelope-and-containers.md`
//! at 02:129-138.
//!
//! ## Design
//! - The carrier is one APPLICATION block per payload part, ID `pNGx`
//!   (02:121-131): data = the u32 ID + one envelope record. FLAC has no
//!   legacy letters; every kind, `META` included, rides `pNGx`, so a FLAC
//!   never carries the museum promise a PNG owes its old players (02:77-83).
//! - Insertion: after the last existing metadata block and before the first
//!   frame (02:132-134). The previous last block's flag is cleared and ours
//!   is set, so the chain stays legal RFC 9639.
//! - PADDING in place: "a PADDING block's whole purpose is to be overwritten
//!   without moving the frames" (02:134-135). The first PADDING block whose
//!   body is at least as large as our blocks' whole wire size is replaced in
//!   place; whatever room is left becomes a (possibly zero-length) PADDING
//!   block, whose header takes the last-block flag when the padding it
//!   replaced was last. The output is the same length as the input and the
//!   frames do not move.
//! - Frames are copied byte-for-byte in every route, so STREAMINFO's MD5
//!   stays valid and SEEKTABLE offsets, which are relative to the first
//!   frame (§8.5, 02:136-138), stay valid too. This byte-identity is what
//!   the tests pin: no `flac` CLI exists on this host (verified 2026-10-05),
//!   so the round-trip pin replaces `flac -t`, which 02:193 asks for "where
//!   the CLI exists". It does not exist here; that substitution is recorded
//!   as a gap, not as compliance.
//! - Splitting: a stored body over `MAX_APPLICATION_BODY` bytes cannot fit
//!   one block (the 24-bit length bounds data at 16 777 215 bytes; minus
//!   the u32 ID and the 8-byte envelope header leaves 16 777 203 = 16 MiB -
//!   13, the exact arithmetic behind the spec's rounded "over 16 MiB minus
//!   12 bytes" at 02:129-130), so it is written across consecutive
//!   APPLICATION blocks with the envelope's `continued` flag set on all but
//!   the last (02:129-131). The reader concatenates them the way the PNG
//!   side concatenates `pNGx` chains.
//! - DEFLATE by default, `,raw` verbatim (02:107), compressed by the same
//!   raw-DEFLATE writer the PNG carrier uses (`src/png/embed.zig`), so both
//!   containers produce the same stored bytes for the same body.
//! - The writer accepts exactly what the reader accepts: an input whose
//!   chain is malformed or carries a type-127 block is refused, never
//!   patched (02:117-118, and the reader's trust policy).
//!
//! ## Invariants
//! - The frames region of the output equals the frames region of the input
//!   byte-for-byte, in every route.
//! - The output's block chain re-parses as legal: exactly one last flag, on
//!   the final metadata block.
//! - Caller owns the returned buffer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const blocks = @import("blocks.zig");
/// The FROZEN v1 envelope (02.C1); reached by module name like everywhere
/// else in the family.
const payload = @import("payload");
/// The family's raw-DEFLATE writer: one compressor, same stored bytes in
/// both containers (02:107). Imported by file; see blocks.zig's note.
const png_embed = @import("../png/embed.zig");
const fixtures = @import("test_flac.zig");

/// The most block DATA RFC 9639's 24-bit length allows (§8.1).
pub const MAX_BLOCK_DATA: usize = 0xFF_FF_FF;

/// The largest stored body one `pNGx` APPLICATION block can carry: the
/// block data ceiling minus the u32 application ID and the 8-byte envelope
/// header (02:129-131). A body over this splits.
pub const MAX_APPLICATION_BODY: usize = MAX_BLOCK_DATA - 4 - payload.envelope.HEADER_SIZE;

pub const Error = error{
    /// The input is not a FLAC stream (no `fLaC` marker where it must be).
    InvalidFlac,
    /// The input's block chain framing is broken (the reader's trust
    /// policy; the writer never patches what the reader refuses).
    MalformedBlocks,
    /// The input carries a type-127 block (02:117-118).
    ForbiddenBlockType,
    /// A kind tag byte outside printable ASCII (02:15).
    InvalidKind,
    CompressionFailed,
    OutOfMemory,
};

/// One payload for `packFlac`: the kind tag, its body, and how to store it.
/// Mirrors `png.packPng`'s `PackSpec` field for field; every kind rides a
/// `pNGx` APPLICATION block (no legacy letters in FLAC, 02:129).
pub const PackSpec = struct {
    kind: [4]u8,
    body: []const u8,
    version: u8 = 1,
    /// `,raw`: store verbatim instead of DEFLATE (02:107).
    raw: bool = false,
};

/// Pack `specs` into `flac` as `pNGx` APPLICATION blocks, in order: inserted
/// after the last metadata block and before the first frame, or into the
/// first PADDING block large enough to hold them (02:132-135). Bodies over
/// `MAX_APPLICATION_BODY` split across consecutive blocks with `continued`
/// set on all but the last (02:129-131). The frames are copied
/// byte-for-byte; an ID3v2 prefix, if present, is preserved verbatim.
///
/// Pre-conditions:
/// - `flac` is a whole FLAC stream whose block chain the reader accepts
/// - 1 <= specs.len
///
/// Post-conditions:
/// - The output re-parses as a legal chain with exactly one last flag
/// - The frames region is byte-identical to the input's
/// - Caller owns the returned slice
pub fn packFlac(
    gpa: Allocator,
    flac: []const u8,
    specs: []const PackSpec,
) Error![]u8 {
    std.debug.assert(specs.len >= 1);

    // Encode every spec into one-or-more APPLICATION block bodies (ID +
    // envelope record), splitting over-ceiling bodies with the continued
    // flag (02:129-131). Sizes are needed before the route is chosen, so
    // this happens first, exactly as embedChunks encodes before it sizes.
    var datas: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (datas.items) |d| gpa.free(d);
        datas.deinit(gpa);
    }
    for (specs) |spec| {
        const stored: []const u8 = if (spec.raw)
            spec.body
        else
            png_embed.compressDeflateRaw(gpa, spec.body) catch return Error.CompressionFailed;
        defer if (!spec.raw) gpa.free(stored);
        const base_flags: u8 = if (spec.raw) 0 else payload.envelope.FLAG_COMPRESSED;

        if (stored.len <= MAX_APPLICATION_BODY) {
            try appendApplication(gpa, &datas, spec.kind, spec.version, base_flags, stored);
            continue;
        }
        var at: usize = 0;
        while (at < stored.len) {
            const take = @min(MAX_APPLICATION_BODY, stored.len - at);
            const final_part = at + take == stored.len;
            const flags = base_flags | (if (final_part) 0 else payload.envelope.FLAG_CONTINUED);
            try appendApplication(gpa, &datas, spec.kind, spec.version, flags, stored[at..][0..take]);
            at += take;
        }
    }

    var wire_size: usize = 0;
    for (datas.items) |d| wire_size += 4 + d.len;

    // Walk the chain: where it ends (the first frame), which block holds the
    // last flag, and whether a PADDING block can absorb the new blocks. The
    // writer parses with the reader, so it accepts exactly what the reader
    // accepts and never patches a chain the reader would refuse.
    var iter = try blocks.parseBlocks(flac);
    var insert_at: usize = 0;
    var last_header: ?usize = null;
    var padding: ?struct { off: usize, len: usize, was_last: bool } = null;
    while (try iter.next()) |blk| {
        insert_at = blk.header_offset + 4 + blk.data.len;
        if (blk.last) last_header = blk.header_offset;
        if (padding == null and blk.block_type == blocks.BLOCK_PADDING and blk.data.len >= wire_size)
            padding = .{ .off = blk.header_offset, .len = blk.data.len, .was_last = blk.last };
    }

    if (padding) |pad| {
        // In place (02:134-135): same length, frames unmoved. The leftover
        // room becomes a PADDING block (possibly zero-length) that carries
        // the last flag when the padding it replaced did; our blocks never
        // take it, because the leftover always follows them.
        const out = gpa.dupe(u8, flac) catch return Error.OutOfMemory;
        errdefer gpa.free(out);
        var at = writeApplicationBlocks(out, pad.off, datas.items, false);
        const leftover_body = pad.len - wire_size;
        out[at] = if (pad.was_last) 0x80 | blocks.BLOCK_PADDING else blocks.BLOCK_PADDING;
        out[at + 1] = @intCast((leftover_body >> 16) & 0xFF);
        out[at + 2] = @intCast((leftover_body >> 8) & 0xFF);
        out[at + 3] = @intCast(leftover_body & 0xFF);
        at += 4;
        // Only the leftover header is written: its body bytes are zeros in
        // the input copy and stay zeros. Together they fill the padding's
        // whole region, which is why the frames never move.
        std.debug.assert(at + leftover_body == pad.off + 4 + pad.len);
        // The leftover body bytes were zeros in the input and still are.
        return out;
    }

    // Insert after the last metadata block, before the first frame
    // (02:132-134): clear the previous last block's flag, set ours.
    const out = gpa.alloc(u8, flac.len + wire_size) catch return Error.OutOfMemory;
    errdefer gpa.free(out);
    @memcpy(out[0..insert_at], flac[0..insert_at]);
    if (last_header) |off| out[off] &= 0x7F;
    const at = writeApplicationBlocks(out, insert_at, datas.items, true);
    std.debug.assert(at == insert_at + wire_size);
    @memcpy(out[at..], flac[insert_at..]); // the frames, byte-for-byte
    return out;
}

/// Encode one APPLICATION block body (u32 ID + envelope record) and append
/// it to `datas`. Caller owns every buffer through the list.
fn appendApplication(
    gpa: Allocator,
    datas: *std.ArrayListUnmanaged([]u8),
    kind: [4]u8,
    version: u8,
    flags: u8,
    piece: []const u8,
) Error!void {
    const record = payload.envelope.encode(gpa, kind, version, flags, piece) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        // A writer never guesses a control byte into a tag (02:15).
        error.UnprintableTag => return Error.InvalidKind,
        // Flags are built here from the two v1 bits alone.
        error.ReservedFlagBit => unreachable,
    };
    defer gpa.free(record);
    const data = gpa.alloc(u8, 4 + record.len) catch return Error.OutOfMemory;
    errdefer gpa.free(data);
    @memcpy(data[0..4], &blocks.APP_ID);
    @memcpy(data[4..], record);
    try datas.append(gpa, data);
}

/// Write `datas` as consecutive APPLICATION block headers+bodies at `at`;
/// `last` puts the last-block flag on the final block only. Returns the
/// offset just past the blocks.
fn writeApplicationBlocks(out: []u8, at0: usize, datas: []const []u8, last: bool) usize {
    var at = at0;
    for (datas, 0..) |data, i| {
        const is_last = last and i + 1 == datas.len;
        out[at] = if (is_last) 0x80 | blocks.BLOCK_APPLICATION else blocks.BLOCK_APPLICATION;
        out[at + 1] = @intCast((data.len >> 16) & 0xFF);
        out[at + 2] = @intCast((data.len >> 8) & 0xFF);
        out[at + 3] = @intCast(data.len & 0xFF);
        @memcpy(out[at + 4 ..][0..data.len], data);
        at += 4 + data.len;
    }
    return at;
}

// ============================================================================
// Tests; goldens authored from the spec and RFC 9639, never from this
// writer. The minimal fixture is src/flac/test_flac.zig's, whose own tests
// pin its bytes against the RFC's layout.
// ============================================================================

const testing = std.testing;

// Hand-authored envelope records (02:12-26), shared with blocks.zig's tests.
const meta_record = [_]u8{ 'M', 'E', 'T', 'A', 0x01, 0x00, 0x00, 0x00, 'm' };

/// One observed block of an output chain.
const Seen = struct { last: bool, block_type: u8, data_len: usize };

/// Re-parse `bytes`' block chain (through the reader, so the writer is
/// checked against it, never against itself) into `buf`; returns the count.
fn readBlocks(buf: []Seen, bytes: []const u8) !usize {
    var iter = try blocks.parseBlocks(bytes);
    var n: usize = 0;
    while (try iter.next()) |b| {
        buf[n] = .{ .last = b.last, .block_type = b.block_type, .data_len = b.data.len };
        n += 1;
    }
    return n;
}

/// One block to assemble (the reader file's assembler is test-local, so the
/// shape is spelled again here): raw `data`, or (`pngx` set) a `pNGx`
/// APPLICATION block carrying that record.
const BlockSpec = struct {
    block_type: u8,
    data: []const u8 = "",
    pngx: ?[]const u8 = null,
    last: bool = false,
};

/// A minimal FLAC with `extra` blocks ahead of the frame region; the last
/// block carries the last-block flag. Caller frees.
fn buildInput(gpa: Allocator, extra: []const BlockSpec) ![]u8 {
    var specs: [8]BlockSpec = undefined;
    specs[0] = .{ .block_type = blocks.BLOCK_STREAMINFO, .data = &fixtures.streaminfo_body };
    for (extra, 0..) |s, i| specs[i + 1] = s;
    specs[extra.len].last = true;
    var total: usize = 4 + fixtures.frames.len;
    for (specs[0 .. extra.len + 1]) |s| total += 4 + s.data.len + @as(usize, if (s.pngx) |record| 4 + record.len else 0);
    const buf = try gpa.alloc(u8, total);
    @memcpy(buf[0..4], &blocks.MARKER);
    var at: usize = 4;
    for (specs[0 .. extra.len + 1]) |s| {
        if (s.pngx) |record| {
            const data_len = 4 + record.len;
            buf[at] = if (s.last) 0x80 | blocks.BLOCK_APPLICATION else blocks.BLOCK_APPLICATION;
            buf[at + 1] = @intCast((data_len >> 16) & 0xFF);
            buf[at + 2] = @intCast((data_len >> 8) & 0xFF);
            buf[at + 3] = @intCast(data_len & 0xFF);
            @memcpy(buf[at + 4 ..][0..4], &blocks.APP_ID);
            @memcpy(buf[at + 8 ..][0..record.len], record);
            at += 4 + data_len;
        } else {
            at = fixtures.writeBlock(buf, at, s.last, s.block_type, s.data);
        }
    }
    @memcpy(buf[at..], &fixtures.frames);
    try testing.expectEqual(buf.len, at + fixtures.frames.len);
    return buf;
}
