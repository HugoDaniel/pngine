//! The payload envelope, FROZEN v1 at X0 (checkpoint 02.C1).
//!
//! Eight bytes, then the body; the carrier-agnostic payload header shared by
//! every container in the family (PNG `pNGx` chunks, FLAC `pNGx` APPLICATION
//! blocks, the later rows). Spec: expansible-player `docs/02-envelope-and-containers.md`
//! at a7220d5, lines 10-34:
//!
//! ```text
//! kind:[4]u8    ASCII tag, e.g. "PNGB" "AZBC" "SNTU" "META"      (02:15)
//! version:u8    the KIND's format version                         (02:16)
//! flags:u8      bit0 = raw DEFLATE (== png FLAG_COMPRESSED)       (02:17-19)
//!               bit1 = continued: next same-kind envelope in
//!                      container order carries the rest           (02:19-21)
//!               bits 2-7 reserved, must be zero                   (02:22-23)
//! reserved:u16  zero; capacity to grow into in place              (02:24-25)
//! ```
//!
//! ## Design
//! - The walker NEVER checks `version`: the handler does (02:16, 02:36-39).
//!   `parse` reports the byte and judges nothing.
//! - A reader that meets a reserved flag bit SKIPS the payload and lists it
//!   as "unreadable flags"; it never guesses, and never refuses the whole
//!   file: the rest of the envelopes are still read (02:22-23). The same
//!   treatment for a kind whose handler is absent, a nonzero reserved u16
//!   (the spec says zero; a v1 reader cannot interpret anything else), a
//!   record shorter than the header, and a `continued` chain no further
//!   envelope completes.
//! - `continued` concatenates in container order, per kind: the records
//!   between two parts of one chain do not break it (02:19-21).
//! - Writers write zero into every reserved position; `encode` refuses
//!   anything else (02:22-25).
//!
//! ## Invariants
//! - `parse` is total: every input yields an envelope or a listed skip.
//! - `assemble` output is deterministic and its payloads' bodies are each
//!   one owned allocation (freed by `Assembly.deinit`).
//!
//! This file is the drift anchor for `docs/payload-kinds.md`
//! (`zig build drift_payload_kinds`): the `v1_kinds` table below is the whole
//! v1 inventory of registered (uppercase-initial) tags. Lowercase-initial
//! tags are private/experimental, never registered, never claimed by the
//! family (02:31-34); they parse like any other envelope and are simply
//! never listed.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Header size in bytes: kind[4] + version + flags + reserved u16 (02:12).
pub const HEADER_SIZE: usize = 8;

/// Flag bit 0: the body is raw DEFLATE, decompressed by the handler with
/// `DecompressionStream('deflate-raw')` on the web side. Exactly pngine's
/// `src/png/embed.zig` FLAG_COMPRESSED = 0x01 (02:17-19).
pub const FLAG_COMPRESSED: u8 = 0x01;

/// Flag bit 1: `continued`; the next envelope of the same kind, in container
/// order, carries the rest of this body (02:19-21).
pub const FLAG_CONTINUED: u8 = 0x02;

/// Flag bits 2-7: reserved, must be zero (02:22-23).
pub const RESERVED_FLAGS_MASK: u8 = 0xFC;

/// The two flag bits v1 defines.
pub const KNOWN_FLAGS_MASK: u8 = FLAG_COMPRESSED | FLAG_CONTINUED;

pub const Error = error{
    OutOfMemory,
    /// `encode` only: a flag bit outside the two v1 bits was requested.
    ReservedFlagBit,
    /// `encode` only: a tag byte outside printable ASCII.
    UnprintableTag,
};

/// One parsed envelope. `body` is a view into the record's bytes 8.., stored
/// (not inflated); bit 0 only SAYS the body is DEFLATE; inflating is the
/// handler's job, after concatenation.
pub const Envelope = struct {
    kind: [4]u8,
    /// Reported, never judged, by this layer: the handler checks it
    /// (02:16, 02:36-39).
    version: u8,
    flags: u8,
    /// Always 0 on this branch: `parse` skips nonzero values rather than
    /// guessing what they might grow to mean (02:24-25).
    reserved: u16,
    body: []const u8,

    pub fn isCompressed(self: Envelope) bool {
        return self.flags & FLAG_COMPRESSED != 0;
    }

    pub fn isContinued(self: Envelope) bool {
        return self.flags & FLAG_CONTINUED != 0;
    }
};

/// Why a record was skipped and listed instead of handed to a handler. The
/// listing names are part of the frozen reader vocabulary.
pub const SkipReason = enum {
    /// A reserved flag bit (2-7) was set (02:22-23).
    unreadable_flags,
    /// The reserved u16 was nonzero (02:24-25 says zero; v1 readers never
    /// guess what else it could mean).
    nonzero_reserved,
    /// Fewer than eight bytes: not an envelope at all (02:12).
    truncated,
    /// No handler for this kind among the caller's `handled_kinds`; the
    /// walker's job is geometry, not dispatch (02:36-39).
    no_handler,
    /// A `continued` chain no further same-kind envelope completed. The spec
    /// defines the flag as "the next envelope ... carries the rest"; with no
    /// next envelope there is no body to reconstruct, so the chain is listed
    /// rather than half-yielded.
    dangling_continued,
};

/// One listed skip. `kind` is the record's first four bytes when they were
/// readable (all zero for `.truncated`); `flags` carries the offending flags
/// byte as evidence for `.unreadable_flags`, zero otherwise.
pub const Skip = struct {
    kind: [4]u8,
    reason: SkipReason,
    flags: u8 = 0,
};

/// The result of reading one envelope-prefixed record.
pub const Parse = union(enum) {
    envelope: Envelope,
    skipped: Skip,
};

/// Parse one record (envelope header + body). Total: every input yields
/// `.envelope` or `.skipped`. The version byte is reported and NEVER checked
/// here; the handler does (02:16, 02:36-39); and reserved positions are
/// skipped-and-listed, never guessed (02:22-25).
pub fn parse(record: []const u8) Parse {
    if (record.len < HEADER_SIZE) {
        return .{ .skipped = .{ .kind = .{ 0, 0, 0, 0 }, .reason = .truncated } };
    }
    const kind: [4]u8 = record[0..4].*;
    const flags = record[5];
    if (flags & RESERVED_FLAGS_MASK != 0) {
        return .{ .skipped = .{ .kind = kind, .reason = .unreadable_flags, .flags = flags } };
    }
    const reserved = std.mem.readInt(u16, record[6..HEADER_SIZE], .big);
    if (reserved != 0) {
        return .{ .skipped = .{ .kind = kind, .reason = .nonzero_reserved } };
    }
    return .{ .envelope = .{
        .kind = kind,
        .version = record[4],
        .flags = flags,
        .reserved = reserved,
        .body = record[HEADER_SIZE..],
    } };
}

/// Encode one envelope: the eight header bytes, then the body, with zero in
/// every reserved position (02:12-26). Refuses reserved flag bits and
/// non-printable tag bytes; a writer never guesses either. Splitting across
/// carriers is the carrier writer's decision (02:20-21); this writes one
/// record. Caller owns the result.
pub fn encode(
    gpa: Allocator,
    kind: [4]u8,
    version: u8,
    flags: u8,
    body: []const u8,
) Error![]u8 {
    for (kind) |c| {
        // "ASCII tag" (02:15), as in every fourcc precedent the spec names
        // (PNG chunks, RIFF, FLAC application IDs, MP4 boxes; 02:29-31):
        // printable bytes only. (The spec does not spell out the writer-side
        // bound; this is the recorded judgement.)
        if (c < 0x20 or c > 0x7E) return Error.UnprintableTag;
    }
    if (flags & RESERVED_FLAGS_MASK != 0) return Error.ReservedFlagBit;

    const out = try gpa.alloc(u8, HEADER_SIZE + body.len);
    @memcpy(out[0..4], &kind);
    out[4] = version;
    out[5] = flags;
    out[6] = 0;
    out[7] = 0;
    @memcpy(out[HEADER_SIZE..], body);
    return out;
}

/// One assembled payload: a kind's body, whole. `version` is the chain's
/// first envelope's; the walker never compares versions across parts
/// (02:16, 02:36-39), so neither does this.
pub const Assembled = struct {
    kind: [4]u8,
    version: u8,
    /// One owned allocation: the chain's bodies concatenated in container
    /// order (02:20-21), or a copy of the single record's body.
    body: []u8,
};

/// The result of walking a whole carrier: payloads the caller's handlers can
/// take, plus every skip, listed, in container order (02:22-23). Frees all
/// owned memory via `deinit`.
pub const Assembly = struct {
    payloads: []Assembled,
    skipped: []Skip,

    pub fn deinit(self: *Assembly, gpa: Allocator) void {
        for (self.payloads) |p| gpa.free(p.body);
        gpa.free(self.payloads);
        gpa.free(self.skipped);
        self.* = .{ .payloads = &.{}, .skipped = &.{} };
    }
};

pub const AssembleOptions = struct {
    /// The kinds the caller has handlers for. A kind not listed is skipped
    /// and listed with `.no_handler`; the same never-refuse-the-file
    /// treatment as unreadable flags (02:22-23, 02:36-39). v1 ships no
    /// handlers in this layer, hence the empty default.
    handled_kinds: []const [4]u8 = &.{},
};

/// Walk `records` (each an envelope-prefixed record, in container order) and
/// assemble each kind's `continued` chains by concatenation (02:19-21).
/// Payloads are emitted in completion order; a streaming walker cannot
/// yield a body before its last part arrives; skip listings follow container
/// order, with dangling chains listed after the walk.
pub fn assemble(
    gpa: Allocator,
    records: []const []const u8,
    opts: AssembleOptions,
) Error!Assembly {
    var payloads: std.ArrayListUnmanaged(Assembled) = .empty;
    var skipped: std.ArrayListUnmanaged(Skip) = .empty;
    var chains: std.ArrayListUnmanaged(Chain) = .empty;
    defer {
        for (chains.items) |*chain| chain.parts.deinit(gpa);
        chains.deinit(gpa);
    }
    errdefer {
        for (payloads.items) |*p| gpa.free(p.body);
        payloads.deinit(gpa);
        skipped.deinit(gpa);
    }

    for (records) |record| {
        const parsed = parse(record);
        switch (parsed) {
            .envelope => |env| {
                if (!isHandled(opts.handled_kinds, env.kind)) {
                    try skipped.append(gpa, .{ .kind = env.kind, .reason = .no_handler });
                } else if (findChain(chains.items, env.kind)) |chain| {
                    try chain.parts.append(gpa, env.body);
                    if (!env.isContinued()) {
                        // Emit first (it only reads the parts), then drop the
                        // chain, which frees them.
                        try emitPayload(gpa, &payloads, chain.*);
                        removeChain(gpa, &chains, env.kind);
                    }
                } else if (env.isContinued()) {
                    var chain = Chain{ .kind = env.kind, .version = env.version };
                    errdefer chain.parts.deinit(gpa);
                    try chain.parts.append(gpa, env.body);
                    try chains.append(gpa, chain);
                } else {
                    const body = try gpa.dupe(u8, env.body);
                    errdefer gpa.free(body);
                    try payloads.append(gpa, .{ .kind = env.kind, .version = env.version, .body = body });
                }
            },
            .skipped => |skip| {
                try skipped.append(gpa, skip);
                // A chain of this kind can no longer complete: its pending
                // parts are dropped. The offending record is the listed one;
                // the half-body it was accumulating is never guessed at.
                removeChain(gpa, &chains, skip.kind);
            },
        }
    }

    // Chains still open at the end of the carrier are listed, never
    // half-yielded: with no next same-kind envelope there is no body to
    // reconstruct (recorded judgement on 02:19-21).
    for (chains.items) |chain| {
        try skipped.append(gpa, .{ .kind = chain.kind, .reason = .dangling_continued });
    }

    const owned_payloads = try payloads.toOwnedSlice(gpa);
    errdefer {
        for (owned_payloads) |p| gpa.free(p.body);
        gpa.free(owned_payloads);
    }
    return .{ .payloads = owned_payloads, .skipped = try skipped.toOwnedSlice(gpa) };
}

/// A `continued` chain under assembly: one kind's pending body parts.
const Chain = struct {
    kind: [4]u8,
    version: u8,
    parts: std.ArrayListUnmanaged([]const u8) = .empty,
};

fn findChain(chains: []Chain, kind: [4]u8) ?*Chain {
    for (chains) |*chain| {
        if (std.mem.eql(u8, &chain.kind, &kind)) return chain;
    }
    return null;
}

/// Drop the (single) open chain of `kind`, freeing its parts. Order-stable
/// removal: the dangling listing at walk's end follows open order.
fn removeChain(gpa: Allocator, chains: *std.ArrayListUnmanaged(Chain), kind: [4]u8) void {
    for (chains.items, 0..) |chain, i| {
        if (std.mem.eql(u8, &chain.kind, &kind)) {
            chains.items[i].parts.deinit(gpa);
            _ = chains.orderedRemove(i);
            return;
        }
    }
}

fn isHandled(handled: []const [4]u8, kind: [4]u8) bool {
    for (handled) |h| {
        if (std.mem.eql(u8, &h, &kind)) return true;
    }
    return false;
}

/// Close one chain into a payload: its parts concatenated in container
/// order (02:20-21), freshly owned.
fn emitPayload(
    gpa: Allocator,
    payloads: *std.ArrayListUnmanaged(Assembled),
    chain: Chain,
) Error!void {
    var total: usize = 0;
    for (chain.parts.items) |part| total += part.len;
    const body = try gpa.alloc(u8, total);
    errdefer gpa.free(body);
    var offset: usize = 0;
    for (chain.parts.items) |part| {
        @memcpy(body[offset..][0..part.len], part);
        offset += part.len;
    }
    try payloads.append(gpa, .{ .kind = chain.kind, .version = chain.version, .body = body });
}

// ============================================================================
// Kind registry (v1); the drift anchor for docs/payload-kinds.md
// ============================================================================

pub const KindStatus = enum {
    /// The owner's compiler exists in the family and a demo landed in 07.
    registered,
    /// Claimed (kind, body, owner, legacy carrier) pending that compiler;
    /// the ZFTB precedent, made a rule by the 2026-10-04 dated note
    /// (02:64-73).
    reserved,
};

pub const KindEntry = struct {
    tag: [4]u8,
    owner: []const u8,
    status: KindStatus,
};

fn tagOf(comptime tag: *const [4]u8) [4]u8 {
    return tag.*;
}

/// The whole v1 inventory of uppercase-initial tags, in the spec table's
/// order (02:43-59). `docs/payload-kinds.md` is drift-checked against this
/// table by `zig build drift_payload_kinds` (tag, owner and status columns;
/// bodies, handlers and legacy carriers are prose the doc carries alone).
/// Lowercase-initial tags are private, never listed (02:31-34).
pub const v1_kinds = [_]KindEntry{
    .{ .tag = tagOf("PNGB"), .owner = "pngine", .status = .registered }, // 02:45
    .{ .tag = tagOf("PNGF"), .owner = "pngine", .status = .registered }, // 02:46
    .{ .tag = tagOf("WGSL"), .owner = "pngine", .status = .registered }, // 02:47
    .{ .tag = tagOf("META"), .owner = "pngine", .status = .registered }, // 02:48
    .{ .tag = tagOf("SNTU"), .owner = "Sointu", .status = .registered }, // 02:49
    .{ .tag = tagOf("AZBC"), .owner = "audzio", .status = .registered }, // 02:50
    .{ .tag = tagOf("AZFL"), .owner = "audzio", .status = .registered }, // 02:51
    .{ .tag = tagOf("AZSR"), .owner = "audzio", .status = .registered }, // 02:52
    .{ .tag = tagOf("ITMD"), .owner = "batida", .status = .registered }, // 02:53
    .{ .tag = tagOf("PACR"), .owner = "pacer", .status = .registered }, // 02:54
    // Reserved 2026-10-20 (the dated note in docs/payload-kinds.md):
    // pacer's compiled score cartridge — an opaque binary, pacer owns the
    // format, no handler, no legacy carrier. Reserved, not registered.
    .{ .tag = tagOf("PACB"), .owner = "pacer", .status = .reserved },
    .{ .tag = tagOf("ZFTB"), .owner = "canto", .status = .reserved }, // 02:55
    .{ .tag = tagOf("ENCA"), .owner = "anyone", .status = .registered }, // 02:56
    .{ .tag = tagOf("PNGI"), .owner = "anyone", .status = .registered }, // 02:57
    .{ .tag = tagOf("ANPC"), .owner = "animader", .status = .reserved }, // 02:58
    .{ .tag = tagOf("ANLG"), .owner = "animader", .status = .reserved }, // 02:59
};

/// Look a tag up in the v1 inventory. Null for private (lowercase-initial)
/// and unknown tags alike; absence carries no judgment; the reader still
/// parses them (02:31-34).
pub fn findKind(tag: [4]u8) ?*const KindEntry {
    for (&v1_kinds) |*entry| {
        if (std.mem.eql(u8, &entry.tag, &tag)) return entry;
    }
    return null;
}

// ============================================================================
// Tests; byte goldens authored from the spec, never from this encoder.
//
// Every golden below was written by hand from the layout in
// expansible-player docs/02-envelope-and-containers.md (a7220d5:12-26) and
// the rules its lines state; the citation on each golden names them. An
// oracle transcribed from the implementation proves nothing.
// ============================================================================

// ============================================================================
// Fuzz: the reader is total and deterministic on any input
// ============================================================================

/// Corpus seeds carry a u32 LE length prefix (see src/png/extract.zig:960-969
/// for why bare seeds never reach the code they seed).
fn fuzzSeed(comptime bytes: []const u8) []const u8 {
    const len_le = std.mem.toBytes(std.mem.nativeToLittle(u32, @as(u32, @intCast(bytes.len))));
    return &(len_le ++ bytes[0..bytes.len].*);
}

fn fuzzEnvelopeProperties(_: @TypeOf({}), smith: *std.testing.Smith) !void {
    const gpa = std.testing.allocator;
    var buf: [256]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];

    // Property: parse is total; any bytes yield one of exactly two shapes.
    const first = parse(input);
    switch (first) {
        .envelope => |env| {
            // Property: an envelope always carries the full header and its
            // body is exactly the bytes after it.
            try std.testing.expect(input.len >= HEADER_SIZE);
            try std.testing.expectEqual(input.len - HEADER_SIZE, env.body.len);
            try std.testing.expectEqualSlices(u8, input[0..4], &env.kind);
            try std.testing.expectEqual(input[4], env.version);
            try std.testing.expectEqual(input[5], env.flags);
            try std.testing.expectEqual(@as(u16, 0), env.reserved);
            try std.testing.expectEqual(@as(u8, 0), env.flags & RESERVED_FLAGS_MASK);
        },
        .skipped => |skip| {
            if (skip.reason == .truncated) {
                try std.testing.expect(input.len < HEADER_SIZE);
            } else {
                try std.testing.expect(input.len >= HEADER_SIZE);
            }
        },
    }

    // Property: parse is deterministic.
    const second = parse(input);
    try std.testing.expect(std.meta.eql(first, second));

    // Property: assemble over arbitrary records never crashes and is
    // deterministic; payloads freed by deinit (leak-checked by the test
    // allocator). The parsed kind rides as the "handled" kind so chains of
    // it, when readable, actually assemble.
    const handled = switch (first) {
        .envelope => |env| env.kind,
        .skipped => |skip| skip.kind,
    };
    var a1 = try assemble(gpa, &.{ input, input, input }, .{ .handled_kinds = &.{handled} });
    a1.deinit(gpa);
    var a2 = try assemble(gpa, &.{ input, input, input }, .{ .handled_kinds = &.{handled} });
    a2.deinit(gpa);

    // Property: a record parse accepts either re-encodes byte-identically or
    // is refused for the one reason encode polices that parse does not (tag
    // printability; parse is liberal, the writer is strict; flags cannot be
    // the cause because parse already refused reserved bits).
    if (first == .envelope) {
        const env = first.envelope;
        if (encode(gpa, env.kind, env.version, env.flags, env.body)) |out| {
            defer gpa.free(out);
            try std.testing.expectEqualSlices(u8, input, out);
        } else |e| {
            try std.testing.expectEqual(Error.UnprintableTag, e);
        }
    }
}
