//! The FLAC payload walker (checkpoint 02.C3): a bounded walk over the
//! metadata block chain, yielding every `pNGx` APPLICATION block as a
//! payload (02:121-131) and walking a PICTURE block's PNG at depth 1
//! (02:145-151). The JS twin is `npm/pngine/src/flac-blocks.js`
//! (`payloadsOfFlac`); the two must list the same inventory for the same
//! bytes, and the fixtures behind that agreement are spelled identically in
//! this file's tests and in `tests/npm/flac-blocks.test.js`.
//!
//! ## The format (RFC 9639, as 02:114-131 summarizes it)
//!
//! A stream is the `fLaC` marker, a mandatory-first STREAMINFO block, any
//! number of other metadata blocks, then audio frames. Each block header is
//! 4 bytes: 1 bit last-block flag, 7 bits type (0-126; 127 is forbidden),
//! 24-bit big-endian length, maximum 16 777 215 bytes. The carrier is an
//! APPLICATION block whose u32 ID is `pNGx` = 0x704E4778 (02:121-122), data
//! = envelope + body, one payload per block; bodies too large for one block
//! split across consecutive blocks with the envelope's `continued` flag set
//! on all but the last (02:129-131).
//!
//! ## Design
//! - The block walk (`parseBlocks`) is bounded and allocation-free: it
//!   yields views into the input and nothing else, the way `chunk.parseChunks`
//!   underlies `walkPng`. Only the payload assembly (`walkFlac`) allocates:
//!   one owned copy per payload body (or chain), freed by `Walk.deinit`.
//! - An ID3v2 tag before `fLaC` is tolerated and skipped by its syncsafe
//!   size (02:140-143, non-normative; common in the wild). The size bytes
//!   are masked to 7 bits each; a prefix that does not land on the marker
//!   refuses the file.
//! - Type 127 refuses the file (02:117-118). Reserved types 7-126 are
//!   skipped by length, never listed (02:118).
//! - The walker never checks `version` and never inflates (02:16, 02:36-39);
//!   bit 0 only SAYS the body is raw DEFLATE.
//! - PICTURE nesting is decided by the picture BYTES carrying the PNG
//!   signature, not by the MIME string (taggers lie; the bytes are what a
//!   decoder would read). Depth stops at 1: a `PNGI` payload found there is
//!   yielded as a payload and never recursed (02:207-208). The nested walk
//!   reuses `walkPng`, so the mapping (legacy letters, `pNGx` envelopes,
//!   skip vocabulary) is the PNG carrier's own, with a `PICTURE→<chunk>`
//!   carrier label.
//! - `continued` chains complete among `pNGx` APPLICATION blocks at the
//!   FLAC level only; a nested picture's chains are internal to that
//!   picture. No writer in the family splits a body across a PICTURE
//!   boundary, and letting a cover-art PNG's chunks complete a FLAC's chain
//!   would couple two unrelated payload streams (recorded judgement on
//!   02:19-21, "in container order").
//! - STREAMINFO-first is not enforced: RFC 9639 §8.2 makes it mandatory, but
//!   the walker's job is geometry, and a chain that starts elsewhere still
//!   has walkable payloads (recorded judgement; the writer accepts what the
//!   reader accepts).
//!
//! ## Trust policy
//!
//! FLAC metadata blocks carry no CRC (RFC 9639 §8.1), so the chain's length
//! framing is the only integrity it has: a block header that reads past the
//! end of the buffer and a declared length past the buffer refuse the whole
//! walk (`MalformedBlocks`); a stream without the `fLaC` marker, and an
//! ID3v2 prefix that does not land on it, refuse with `InvalidFlac`. There
//! is no separate "the chain never sets the last-block flag" verdict,
//! because nothing in the format marks where the frames start: such a chain
//! walks into the frames, where the 14-bit frame sync (0xFF, RFC 9639 §6.1)
//! reads as a forbidden type-127 block and refuses the file that way. Block
//! CONTENT gets the skip-and-list treatment instead: a PICTURE whose field
//! lengths overrun its own block, and an envelope record that is short or
//! carries reserved bits set, are listed and the walk continues (02:22-23:
//! never guess, never refuse the file for a payload's sake). The JS twin
//! applies the same two tiers and preflights the whole chain before its
//! first yield, so its refusal is atomic exactly as this walk's is (it
//! returns a complete `Walk` or an error, never half of one).
//!
//! The two twins cannot disagree on any input: FLAC's 24-bit length bounds
//! every block under pngine's 16 MiB chunk ceiling, so the one declared
//! resource difference between the PNG twins (`walkPng` caps in-memory
//! chunk data, `payloadsOf` applies no ceiling) is unreachable at nesting
//! depth 1, and each side pins the other's cases. The fixtures and expected
//! inventory strings below are duplicated verbatim in
//! `tests/npm/flac-blocks.test.js`.

const std = @import("std");
const Allocator = std.mem.Allocator;
/// The FROZEN v1 envelope (02.C1), reached the same way `src/png/extract.zig`
/// reaches it: by module name, because a relative hop would leave the
/// module's root.
const payload = @import("payload");
/// The PNG walker this reader nests inside PICTURE blocks (02:145-151);
/// imported by file, so both live in one module and share one envelope
/// instance (the discipline build.zig documents for `payload`).
const png_extract = @import("../png/extract.zig");
const fixtures = @import("test_flac.zig");

/// The FLAC stream marker, "fLaC" (RFC 9639 §3).
pub const MARKER = [4]u8{ 'f', 'L', 'a', 'C' };

/// The registered FLAC APPLICATION block ID: `pNGx` = 0x704E4778, "the same
/// four bytes as the PNG chunk type" (02:121-122). Registration is First
/// Come First Served at IANA (RFC 9639 §8.4); the filing artifact is
/// `docs/iana-flac-application-id.md`, prepared and pending.
pub const APP_ID = [4]u8{ 'p', 'N', 'G', 'x' };

/// Metadata block types (RFC 9639 §8.1).
pub const BLOCK_STREAMINFO: u8 = 0;
pub const BLOCK_PADDING: u8 = 1;
pub const BLOCK_APPLICATION: u8 = 2;
pub const BLOCK_SEEKTABLE: u8 = 3;
pub const BLOCK_VORBIS_COMMENT: u8 = 4;
pub const BLOCK_CUESHEET: u8 = 5;
pub const BLOCK_PICTURE: u8 = 6;
/// 7-126 are reserved; 127 is forbidden and refuses the file (02:117-118).
pub const BLOCK_FORBIDDEN: u8 = 127;

pub const Error = error{
    /// No `fLaC` marker where the stream must carry it, or an ID3v2 prefix
    /// that does not land on one.
    InvalidFlac,
    /// The block chain's framing is broken: a truncated header, a declared
    /// length past the buffer, or a chain that never sets the last-block
    /// flag. The chain's lengths are its only integrity (no per-block CRC),
    /// so this refuses the whole walk.
    MalformedBlocks,
    /// A type-127 block (RFC 9639 §8.1: forbidden).
    ForbiddenBlockType,
    OutOfMemory,
};

/// One metadata block: its header's flags, its type, the offset of its
/// 4-byte header in the stream, and a view of its body.
pub const Block = struct {
    last: bool,
    block_type: u8,
    header_offset: usize,
    data: []const u8,
};

/// The bounded, allocation-free walk over the metadata block chain.
/// `next` yields each block in stream order, `null` after the last-flagged
/// one, and refuses the whole chain on the framing defects the trust policy
/// names. The bytes after the last block are audio frames and are never
/// read here.
pub const BlockIterator = struct {
    bytes: []const u8,
    pos: usize,
    saw_last: bool = false,

    pub fn next(self: *BlockIterator) Error!?Block {
        if (self.saw_last) return null;
        if (self.pos + 4 > self.bytes.len) return Error.MalformedBlocks;
        const flags = self.bytes[self.pos];
        const last = flags & 0x80 != 0;
        const block_type = flags & 0x7F;
        if (block_type == BLOCK_FORBIDDEN) return Error.ForbiddenBlockType;
        const len: usize = (@as(usize, self.bytes[self.pos + 1]) << 16) |
            (@as(usize, self.bytes[self.pos + 2]) << 8) |
            @as(usize, self.bytes[self.pos + 3]);
        const data_start = self.pos + 4;
        if (data_start + len > self.bytes.len) return Error.MalformedBlocks;
        const blk = Block{
            .last = last,
            .block_type = block_type,
            .header_offset = self.pos,
            .data = self.bytes[data_start..][0..len],
        };
        if (last) {
            self.saw_last = true;
        } else {
            self.pos = data_start + len;
        }
        return blk;
    }
};

/// The offset of the `fLaC` marker: 0 for a bare stream, past the ID3v2 tag
/// for a prefixed one. Refuses with `InvalidFlac` when the bytes are too
/// short, the tag is malformed, or neither spelling lands on the marker.
/// The syncsafe size is masked to 7 bits per byte (ID3v2 §3.1), tolerating
/// sloppy taggers the way the spec's "common in the wild" asks (02:140-143).
pub fn markerOffset(bytes: []const u8) Error!usize {
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], &MARKER)) return 0;
    if (bytes.len >= 10 and std.mem.eql(u8, bytes[0..3], "ID3")) {
        const size: usize = (@as(usize, bytes[6] & 0x7F) << 21) |
            (@as(usize, bytes[7] & 0x7F) << 14) |
            (@as(usize, bytes[8] & 0x7F) << 7) |
            @as(usize, bytes[9] & 0x7F);
        const at = 10 + size;
        if (at + 4 <= bytes.len and std.mem.eql(u8, bytes[at..][0..4], &MARKER)) return at;
    }
    return Error.InvalidFlac;
}

/// Begin the block walk at the first metadata block after the marker
/// (skipping an ID3v2 prefix when present, 02:140-143).
pub fn parseBlocks(bytes: []const u8) Error!BlockIterator {
    const off = try markerOffset(bytes);
    return .{ .bytes = bytes, .pos = off + 4 };
}

/// Which carrier a payload rode: the nth `pNGx` APPLICATION block
/// (`APPLICATION#1`, 02:108), or a chunk of the PNG inside a PICTURE block
/// (`PICTURE→pNGf`, 02:108, 02:145-151). `.picture_block` names the PICTURE
/// block itself, for the one skip that has no nested chunk to name.
pub const Carrier = union(enum) {
    application: usize,
    picture: struct { chunk_type: [4]u8, nth: usize },
    picture_block,
};

/// One payload listed by `walkFlac`: the envelope's kind, version and flags
/// (reported, never judged), the STORED body (bit 0 says raw DEFLATE;
/// inflating is the consumer's job, after any concatenation), and the
/// carrier. `body` is owned by the `Walk` it came in.
///
/// `stored_overhead` is the header bytes the payload's carrier(s) put ahead
/// of its body: 12 per APPLICATION part (the u32 ID plus the envelope), and
/// for a nested payload whatever its own PNG carrier put there (8 for a
/// `pNGx` envelope, 2 for the legacy letters, 1 for `pNGm`), so
/// `body.len + stored_overhead` is the payload's stored size however many
/// carriers it took.
pub const Payload = struct {
    kind: [4]u8,
    version: u8,
    flags: u8,
    body: []u8,
    stored_overhead: usize,
    carrier: Carrier,
};

/// Why a record was listed instead of yielded. The first five are the
/// envelope layer's own vocabulary, passed through (`src/payload/envelope.zig`,
/// FROZEN v1); `malformed_picture` is this carrier's: a PICTURE block whose
/// field lengths overrun its own block data, or whose PNG fails its own
/// framing walk.
pub const WalkSkipReason = enum {
    unreadable_flags,
    nonzero_reserved,
    truncated,
    dangling_continued,
    unknown_letter,
    malformed_picture,
};

/// One listed skip, with the carrier that caused it.
pub const WalkSkip = struct {
    kind: [4]u8,
    reason: WalkSkipReason,
    /// Evidence for `.unreadable_flags`; zero otherwise.
    flags: u8 = 0,
    carrier: Carrier,
};

/// The result of walking a whole FLAC: payloads and skip listings. Payloads
/// are in completion order (a `continued` chain completes at its last part,
/// 02:19-21), skips in encounter order, dangling chains listed after the
/// walk. Frees every body via `deinit`.
pub const Walk = struct {
    payloads: []Payload = &.{},
    skipped: []WalkSkip = &.{},

    pub fn deinit(self: *Walk, gpa: Allocator) void {
        for (self.payloads) |p| gpa.free(p.body);
        gpa.free(self.payloads);
        gpa.free(self.skipped);
        self.* = .{};
    }
};

/// Walk `bytes` (a whole FLAC stream, ID3v2-prefixed or bare) and list every
/// payload it carries: each `pNGx` APPLICATION block as one envelope record
/// (02:121-131), and each PICTURE block's PNG walked at depth 1 with
/// `PICTURE→<chunk>` carriers (02:145-151). Reserved positions skip-and-list;
/// `continued` chains concatenate in container order among APPLICATION
/// blocks; the trust policy above decides refusals.
///
/// Pre-condition: `bytes` is a whole FLAC stream.
/// Post-condition: caller owns the result via `Walk.deinit`.
/// Complexity: O(bytes.len) plus one owned copy per payload body.
pub fn walkFlac(gpa: Allocator, bytes: []const u8) Error!Walk {
    var payloads: std.ArrayListUnmanaged(Payload) = .empty;
    errdefer {
        for (payloads.items) |p| gpa.free(p.body);
        payloads.deinit(gpa);
    }
    var skipped: std.ArrayListUnmanaged(WalkSkip) = .empty;
    errdefer skipped.deinit(gpa);
    var chains: std.ArrayListUnmanaged(OpenChain) = .empty;
    defer {
        for (chains.items) |*chain| chain.parts.deinit(gpa);
        chains.deinit(gpa);
    }

    var iter = try parseBlocks(bytes);
    var app_nth: usize = 0;
    while (try iter.next()) |blk| {
        switch (blk.block_type) {
            BLOCK_APPLICATION => {
                // An APPLICATION block shorter than its u32 ID names no
                // application at all, so it is not a carrier attempt.
                if (blk.data.len < 4) continue;
                if (!std.mem.eql(u8, blk.data[0..4], &APP_ID)) continue;
                app_nth += 1;
                try takeRecord(gpa, &payloads, &skipped, &chains, blk.data[4..], .{ .application = app_nth });
            },
            BLOCK_PICTURE => try takePicture(gpa, &payloads, &skipped, blk.data),
            // STREAMINFO, PADDING, SEEKTABLE, VORBIS_COMMENT, CUESHEET and
            // the reserved types: skipped by length, never listed (02:118).
            else => {},
        }
    }

    // Chains still open at the end of the chain are listed, never
    // half-yielded (02:19-21).
    for (chains.items) |chain| {
        try skipped.append(gpa, .{ .kind = chain.kind, .reason = .dangling_continued, .carrier = chain.carrier });
    }

    return .{
        .payloads = try payloads.toOwnedSlice(gpa),
        .skipped = try skipped.toOwnedSlice(gpa),
    };
}

/// The stored-size overhead one APPLICATION part puts ahead of a body: the
/// u32 application ID plus the envelope header (02:121-131).
const APPLICATION_OVERHEAD: usize = 4 + payload.envelope.HEADER_SIZE;

/// A `continued` chain under assembly (02:19-21), the png walker's twin:
/// identity fields are the chain's FIRST part's, `stored_overhead`
/// accumulates one carrier's overhead per part.
const OpenChain = struct {
    kind: [4]u8,
    version: u8,
    flags: u8,
    carrier: Carrier,
    stored_overhead: usize = 0,
    parts: std.ArrayListUnmanaged([]const u8) = .empty,
};

/// Take one envelope-prefixed record (a `pNGx` APPLICATION block's data
/// after the ID) into the walk: envelope or listed skip, chain or payload.
fn takeRecord(
    gpa: Allocator,
    payloads: *std.ArrayListUnmanaged(Payload),
    skipped: *std.ArrayListUnmanaged(WalkSkip),
    chains: *std.ArrayListUnmanaged(OpenChain),
    record: []const u8,
    carrier: Carrier,
) Error!void {
    const parsed = payload.envelope.parse(record);
    switch (parsed) {
        .envelope => |env| {
            if (findChain(chains, env.kind)) |chain| {
                try chain.parts.append(gpa, env.body);
                chain.stored_overhead += APPLICATION_OVERHEAD;
                if (!env.isContinued()) {
                    // Emit first (it only reads the parts), then drop the chain.
                    try emitChain(gpa, payloads, chain);
                    removeChain(gpa, chains, env.kind);
                }
            } else if (env.isContinued()) {
                var chain = OpenChain{
                    .kind = env.kind,
                    .version = env.version,
                    .flags = env.flags,
                    .carrier = carrier,
                    .stored_overhead = APPLICATION_OVERHEAD,
                };
                try chain.parts.append(gpa, env.body);
                try chains.append(gpa, chain);
            } else {
                const body = gpa.dupe(u8, env.body) catch return Error.OutOfMemory;
                try payloads.append(gpa, .{
                    .kind = env.kind,
                    .version = env.version,
                    .flags = env.flags,
                    .body = body,
                    .stored_overhead = APPLICATION_OVERHEAD,
                    .carrier = carrier,
                });
            }
        },
        .skipped => |skip| {
            try skipped.append(gpa, .{
                .kind = skip.kind,
                .reason = switch (skip.reason) {
                    .unreadable_flags => .unreadable_flags,
                    .nonzero_reserved => .nonzero_reserved,
                    .truncated => .truncated,
                    // `parse` never yields these; the switch stays total for
                    // the frozen vocabulary's sake (the png twin's note).
                    .no_handler, .dangling_continued => .truncated,
                },
                .flags = skip.flags,
                .carrier = carrier,
            });
            // A chain of this kind can no longer complete: its pending parts
            // are dropped, silently, exactly as the frozen envelope reader
            // treats a skipped chain member.
            dropChain(gpa, chains, skip.kind);
        },
    }
}

/// A parsed PICTURE block body: the reported fields plus the picture bytes.
const Picture = struct {
    mime: []const u8,
    description: []const u8,
    data: []const u8,
};

fn readU32be(data: []const u8, pos: *usize) ?u32 {
    if (pos.* + 4 > data.len) return null;
    const v = std.mem.readInt(u32, data[pos.*..][0..4], .big);
    pos.* += 4;
    return v;
}

fn readBytes(data: []const u8, pos: *usize, len: usize) ?[]const u8 {
    if (pos.* + len > data.len) return null;
    const s = data[pos.*..][0..len];
    pos.* += len;
    return s;
}

/// Parse a PICTURE block body per RFC 9639 §8.8. Null when any field length
/// overruns the block, or when the picture is not exactly the rest of the
/// block as the format says it is (the picture is the last field; trailing
/// bytes mean the block lies about itself).
fn parsePicture(data: []const u8) ?Picture {
    var pos: usize = 0;
    _ = readU32be(data, &pos) orelse return null; // picture type (§8.8 table)
    const mime_len = readU32be(data, &pos) orelse return null;
    const mime = readBytes(data, &pos, mime_len) orelse return null;
    const desc_len = readU32be(data, &pos) orelse return null;
    const description = readBytes(data, &pos, desc_len) orelse return null;
    // width, height, depth, colors.
    var i: usize = 0;
    while (i < 4) : (i += 1) _ = readU32be(data, &pos) orelse return null;
    const data_len = readU32be(data, &pos) orelse return null;
    const pic = readBytes(data, &pos, data_len) orelse return null;
    if (pos != data.len) return null;
    return .{ .mime = mime, .description = description, .data = pic };
}

/// Take one PICTURE block: a malformed one is listed; a non-PNG one is
/// ordinary metadata; a PNG is walked at depth 1 through `walkPng`, its
/// payloads re-carriered `PICTURE→<chunk>` and its skips listed the same
/// way (02:145-151). Nested bodies are duplicated into this walk: the PNG
/// walk underneath owns and frees its own.
fn takePicture(
    gpa: Allocator,
    payloads: *std.ArrayListUnmanaged(Payload),
    skipped: *std.ArrayListUnmanaged(WalkSkip),
    data: []const u8,
) Error!void {
    const pic = parsePicture(data) orelse {
        try skipped.append(gpa, .{
            .kind = .{ 0, 0, 0, 0 },
            .reason = .malformed_picture,
            .carrier = .picture_block,
        });
        return;
    };
    // Nesting is decided by the bytes, not the MIME: taggers lie, and the
    // bytes are what a decoder would read (recorded judgement).
    const png_signature = @import("../png/chunk.zig").PNG_SIGNATURE;
    if (pic.data.len < 8 or !std.mem.eql(u8, pic.data[0..8], &png_signature)) return;

    var png_walk = png_extract.walkPng(gpa, pic.data) catch {
        // The FLAC's own chain is fine; the picture's framing is not. List
        // it and keep walking (trust policy).
        try skipped.append(gpa, .{
            .kind = .{ 0, 0, 0, 0 },
            .reason = .malformed_picture,
            .carrier = .picture_block,
        });
        return;
    };
    defer png_walk.deinit(gpa);

    for (png_walk.payloads) |p| {
        const body = gpa.dupe(u8, p.body) catch return Error.OutOfMemory;
        try payloads.append(gpa, .{
            .kind = p.kind,
            .version = p.version,
            .flags = p.flags,
            .body = body,
            .stored_overhead = p.stored_overhead,
            .carrier = .{ .picture = .{ .chunk_type = p.carrier.chunk_type, .nth = p.carrier.nth } },
        });
    }
    for (png_walk.skipped) |s| {
        try skipped.append(gpa, .{
            .kind = s.kind,
            .reason = switch (s.reason) {
                .unreadable_flags => .unreadable_flags,
                .nonzero_reserved => .nonzero_reserved,
                .truncated => .truncated,
                .dangling_continued => .dangling_continued,
                .unknown_letter => .unknown_letter,
            },
            .flags = s.flags,
            .carrier = .{ .picture = .{ .chunk_type = s.carrier.chunk_type, .nth = s.carrier.nth } },
        });
    }
}

fn findChain(chains: *std.ArrayListUnmanaged(OpenChain), kind: [4]u8) ?*OpenChain {
    for (chains.items) |*chain| {
        if (std.mem.eql(u8, &chain.kind, &kind)) return chain;
    }
    return null;
}

/// Close one chain into a payload: its parts concatenated in container order
/// (02:20-21), freshly owned.
fn emitChain(
    gpa: Allocator,
    payloads: *std.ArrayListUnmanaged(Payload),
    chain: *OpenChain,
) Error!void {
    var total: usize = 0;
    for (chain.parts.items) |part| total += part.len;
    const body = gpa.alloc(u8, total) catch return Error.OutOfMemory;
    var offset: usize = 0;
    for (chain.parts.items) |part| {
        @memcpy(body[offset..][0..part.len], part);
        offset += part.len;
    }
    try payloads.append(gpa, .{
        .kind = chain.kind,
        .version = chain.version,
        .flags = chain.flags,
        .body = body,
        .stored_overhead = chain.stored_overhead,
        .carrier = chain.carrier,
    });
}

/// Drop the (single) open chain of `kind`, freeing its parts. Silent: the
/// record that broke the chain carries its own listing.
fn dropChain(gpa: Allocator, chains: *std.ArrayListUnmanaged(OpenChain), kind: [4]u8) void {
    for (chains.items, 0..) |chain, i| {
        if (std.mem.eql(u8, &chain.kind, &kind)) {
            chains.items[i].parts.deinit(gpa);
            _ = chains.orderedRemove(i);
            return;
        }
    }
}

/// Order-stable removal after a chain completes.
fn removeChain(gpa: Allocator, chains: *std.ArrayListUnmanaged(OpenChain), kind: [4]u8) void {
    for (chains.items, 0..) |chain, i| {
        if (std.mem.eql(u8, &chain.kind, &kind)) {
            chains.items[i].parts.deinit(gpa);
            _ = chains.orderedRemove(i);
            return;
        }
    }
}

// ============================================================================
// Tests; goldens authored from the spec and RFC 9639, never from this
// walker. The expected inventory strings ("KIND vF F LEN carrier; ...") are
// duplicated verbatim in tests/npm/flac-blocks.test.js so the Zig and JS
// readers are pinned to one inventory, the same way walk_test.zig and
// payloads.test.js share the museum table.
// ============================================================================

const testing = std.testing;
const png_chunk = @import("../png/chunk.zig");

/// One metadata block to assemble into a stream: either raw `data`, or
/// (`pngx` set) a `pNGx` APPLICATION block carrying that envelope record.
const BlockSpec = struct {
    last: bool = false,
    block_type: u8,
    data: []const u8 = "",
    pngx: ?[]const u8 = null,
};

/// Assemble `fLaC` + `specs` + the fixture frame region. Caller frees.
fn buildFlac(gpa: Allocator, specs: []const BlockSpec) ![]u8 {
    var total: usize = 4 + fixtures.frames.len;
    for (specs) |s| total += 4 + s.data.len + @as(usize, if (s.pngx) |record| 4 + record.len else 0);
    const buf = try gpa.alloc(u8, total);
    @memcpy(buf[0..4], &MARKER);
    var at: usize = 4;
    for (specs) |s| {
        if (s.pngx) |record| {
            // A pNGx APPLICATION block: header declaring ID + record, then
            // both, the layout 02:121-131 spells.
            const data_len = 4 + record.len;
            buf[at] = if (s.last) 0x80 | BLOCK_APPLICATION else BLOCK_APPLICATION;
            buf[at + 1] = @intCast((data_len >> 16) & 0xFF);
            buf[at + 2] = @intCast((data_len >> 8) & 0xFF);
            buf[at + 3] = @intCast(data_len & 0xFF);
            @memcpy(buf[at + 4 ..][0..4], &APP_ID);
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

// Hand-authored envelope records (the same literals envelope.zig's goldens
// pin; layout 02:12-26).
const enca_record = [_]u8{ 'E', 'N', 'C', 'A', 0x01, 0x00, 0x00, 0x00, 'f', 'l', 'a', 'c' };
const azsr_record = [_]u8{ 'A', 'Z', 'S', 'R', 0x02, 0x00, 0x00, 0x00, 'a', 'b' };
const meta_record = [_]u8{ 'M', 'E', 'T', 'A', 0x01, 0x00, 0x00, 0x00, 'm' };
const sntu_a = [_]u8{ 'S', 'N', 'T', 'U', 0x01, 0x02, 0x00, 0x00, 'A', 'B' };
const sntu_b = [_]u8{ 'S', 'N', 'T', 'U', 0x01, 0x00, 0x00, 0x00, 'C', 'D' };

/// The carrier column, spelled as the JS twin's tests spell it: plain for
/// APPLICATION, `PICTURE→<chunk>` for nested chunks (`pNGx` numbered),
/// `PICTURE` for the block itself.
fn carrierLabel(buf: []u8, carrier: Carrier) []const u8 {
    return switch (carrier) {
        .application => |nth| std.fmt.bufPrint(buf, "APPLICATION#{d}", .{nth}) catch "APPLICATION",
        .picture => |pic| if (std.mem.eql(u8, &pic.chunk_type, "pNGx"))
            std.fmt.bufPrint(buf, "PICTURE\u{2192}pNGx#{d}", .{pic.nth}) catch "PICTURE"
        else
            std.fmt.bufPrint(buf, "PICTURE\u{2192}{s}", .{pic.chunk_type}) catch "PICTURE",
        .picture_block => "PICTURE",
    };
}

/// Render a walk exactly as the JS twin's tests spell it, so both sides pin
/// one inventory string: `KIND vF F LEN carrier` per payload, `KIND reason`
/// per skip, "; "-separated, payloads then skips.
fn renderWalk(gpa: Allocator, walk: Walk) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (walk.payloads, 0..) |p, i| {
        if (i > 0) try out.appendSlice(gpa, "; ");
        var carrier_buf: [24]u8 = undefined;
        var row_buf: [64]u8 = undefined;
        const row = try std.fmt.bufPrint(&row_buf, "{s} v{d} f{d} {d} {s}", .{
            p.kind, p.version, p.flags, p.body.len, carrierLabel(&carrier_buf, p.carrier),
        });
        try out.appendSlice(gpa, row);
    }
    for (walk.skipped) |s| {
        if (out.items.len > 0) try out.appendSlice(gpa, "; ");
        var row_buf: [64]u8 = undefined;
        const row = try std.fmt.bufPrint(&row_buf, "{s} {s}", .{ s.kind, @tagName(s.reason) });
        try out.appendSlice(gpa, row);
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Test-side PNG builders (the nested pictures the PICTURE cases carry).
// ---------------------------------------------------------------------------

const NestedChunk = struct { chunk_type: [4]u8, data: []const u8 };

/// A minimal PNG carrying `chunks` between IHDR and IEND. Caller frees.
fn buildNestedPng(gpa: Allocator, chunks: []const NestedChunk) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, &png_chunk.PNG_SIGNATURE);
    try png_chunk.writeChunk(&buf, gpa, png_chunk.ChunkType.IHDR, &[_]u8{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 0, 0, 0, 0 });
    for (chunks) |c| try png_chunk.writeChunk(&buf, gpa, c.chunk_type, c.data);
    try png_chunk.writeChunk(&buf, gpa, png_chunk.ChunkType.IEND, "");
    return buf.toOwnedSlice(gpa);
}

/// A PNG whose pNGx chunk fails its CRC: right signature, broken framing.
/// The pNGx chunk sits just before the 12-byte IEND, so its stored CRC is
/// the 4 bytes at len-12-4.
fn buildBrokenFramingPng(gpa: Allocator) ![]u8 {
    const png = try buildNestedPng(gpa, &.{.{ .chunk_type = .{ 'p', 'N', 'G', 'x' }, .data = &meta_record }});
    png[png.len - 12 - 4] ^= 0xFF;
    return png;
}
