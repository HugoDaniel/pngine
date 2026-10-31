//! Extract PNGB bytecode from PNG files.
//!
//! Parses PNG chunks to find the pNGb chunk and returns the PNGB bytecode.
//! `enumerateChunks` lists every PNGine ancillary chunk (`pNG*`) present — the
//! read-side counterpart to embed's four writers (A7; see docs/architecture.md
//! for the chunk taxonomy).
//!
//! ## Usage
//! ```zig
//! const bytecode = try extract.extract(gpa, png_data);
//! defer gpa.free(bytecode);
//! // bytecode is now valid PNGB that can be executed
//! ```
//!
//! ## Decompression
//!
//! Handles real DEFLATE compressed data (LZ77 + Huffman) using std.compress.flate.
//! Compatible with both store blocks and compressed blocks.
//!
//! ## Invariants
//! - Returns exact original bytecode that was embedded
//! - Caller owns returned memory

const std = @import("std");
const Allocator = std.mem.Allocator;
const chunk = @import("chunk.zig");
const createMinimalPng = @import("test_png.zig").createMinimalPng;
const embed = @import("embed.zig");
const inflate = @import("inflate.zig");
/// The FROZEN v1 envelope (02.C1). walkPng maps every carrier chunk onto it;
/// the module comes in by name from build.zig because a relative hop would
/// leave src/png's module root.
const payload = @import("payload");

pub const Error = error{
    InvalidPng,
    /// `walkPng` only: a chunk's declared data length exceeds pngine's
    /// 16 MiB in-memory ceiling. A resource limit, not corruption: the PNG
    /// format allows chunk data up to 2^31-1 (02:87-88), and the CLI's own
    /// whole-file cap (16 MiB, utils.max_file_size) fires before this can on
    /// a file input; this binds the public in-memory walkers.
    ChunkTooLarge,
    NoPngbChunk,
    InvalidPngbVersion,
    InvalidPngbFormat,
    DecompressionFailed,
    OutOfMemory,
};

/// Extract PNGB bytecode from PNG data.
///
/// Finds the pNGb chunk and returns the bytecode.
///
/// Pre-conditions:
/// - png_data starts with valid PNG signature
/// - png_data contains a pNGb chunk
///
/// Post-conditions:
/// - Returns exact bytecode that was originally embedded
/// - Caller owns returned slice and must free it
///
/// Complexity: O(png_data.len) to find chunk
pub fn extract(gpa: Allocator, png_data: []const u8) Error![]u8 {
    // Validate PNG signature
    if (png_data.len < 8 or !std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE)) {
        return Error.InvalidPng;
    }

    // Pre-condition: valid PNG after signature check
    std.debug.assert(png_data.len >= 8);
    std.debug.assert(std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE));

    // Find pNGb chunk
    var iter = chunk.parseChunks(png_data) catch {
        return Error.InvalidPng;
    };

    while (iter.next() catch {
        return Error.InvalidPng;
    }) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &embed.PNGB_CHUNK_TYPE)) {
            return parsePngbChunk(gpa, c.data);
        }
    }

    return Error.NoPngbChunk;
}

/// Parse pNGb chunk data.
fn parsePngbChunk(gpa: Allocator, data: []const u8) Error![]u8 {
    // Minimum: version (1) + flags (1) + some payload
    if (data.len < 3) {
        return Error.InvalidPngbFormat;
    }

    // Pre-condition: data has header
    std.debug.assert(data.len >= 3);

    const version = data[0];
    const flags = data[1];
    const stored = data[2..];

    // Check version
    if (version != embed.PNGB_VERSION) {
        return Error.InvalidPngbVersion;
    }

    // Check compression flag
    const is_compressed = (flags & embed.FLAG_COMPRESSED) != 0;

    if (is_compressed) {
        // Decompress raw DEFLATE payload. A stream that inflates to nothing
        // (`03 00`, valid DEFLATE of zero bytes) is refused HERE, by the path
        // that owns the PNGB contract: this legacy reader promises bytecode,
        // and empty bytecode is not a payload it can hand back. The public
        // failure is DecompressionFailed, the same verdict a broken stream
        // gets through the catch below.
        const inflated = decompressDeflateRaw(gpa, stored) catch {
            return Error.DecompressionFailed;
        };
        if (inflated.len == 0) {
            gpa.free(inflated);
            return Error.DecompressionFailed;
        }
        return inflated;
    }

    // Return copy of raw payload
    const result = gpa.alloc(u8, stored.len) catch {
        return Error.OutOfMemory;
    };
    @memcpy(result, stored);

    // Post-condition: result matches the stored payload exactly
    std.debug.assert(result.len == stored.len);

    return result;
}

/// Decompress raw DEFLATE data using std.compress.flate.
///
/// Handles real LZ77+Huffman compressed data, not just store blocks.
///
/// Pre-conditions:
/// - data contains valid raw DEFLATE stream
/// - data.len >= 1 (empty streams are invalid)
///
/// Post-conditions:
/// - Returns the decompressed bytes; a stream that inflates to nothing is a
///   legal empty result, and whether an empty payload is acceptable is the
///   CALLER's contract, not the decoder's (parsePngbChunk refuses it for the
///   legacy PNGB route; inflatePayload hands it through for extract --kind)
/// - Caller owns returned slice
fn decompressDeflateRaw(gpa: Allocator, data: []const u8) ![]u8 {
    // Pre-condition: need at least minimal deflate data (header byte)
    if (data.len < 1) {
        return error.InvalidFormat;
    }
    std.debug.assert(data.len >= 1);

    // Inflate the raw-DEFLATE payload, capped so a crafted pNGb chunk cannot
    // expand into a multi-GB OOM (the old `.unlimited` here claimed to be
    // "bounded by format" — it was not). No externally-known size for this
    // chunk, so use the module's absolute cap. (Arc-3 §2.3)
    const result = inflate.decompressCapped(gpa, data, .raw, inflate.MAX_DECOMPRESSED) catch {
        return error.DecompressionFailed;
    };
    return result;
}

/// Check if PNG data contains a pNGb chunk.
///
/// Quick check without allocation.
///
/// Pre-condition: png_data is a valid slice.
/// Post-condition: returns true iff png_data contains a valid pNGb chunk.
pub fn hasPngb(png_data: []const u8) bool {
    // Early return for invalid PNG (too short or wrong signature)
    if (png_data.len < 8 or !std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE)) {
        return false;
    }

    var iter = chunk.parseChunks(png_data) catch return false;

    while (iter.next() catch null) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &embed.PNGB_CHUNK_TYPE)) {
            return true;
        }
    }

    return false;
}

/// Get pNGb chunk info without extracting.
///
/// Returns chunk metadata for inspection.
pub const PngbInfo = struct {
    version: u8,
    compressed: bool,
    payload_size: usize,
};

pub fn getPngbInfo(png_data: []const u8) Error!PngbInfo {
    if (png_data.len < 8 or !std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE)) {
        return Error.InvalidPng;
    }

    // Pre-condition: valid PNG
    std.debug.assert(png_data.len >= 8);
    std.debug.assert(std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE));

    var iter = chunk.parseChunks(png_data) catch {
        return Error.InvalidPng;
    };

    while (iter.next() catch {
        return Error.InvalidPng;
    }) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &embed.PNGB_CHUNK_TYPE)) {
            if (c.data.len < 2) {
                return Error.InvalidPngbFormat;
            }

            const version = c.data[0];
            const flags = c.data[1];
            const payload_size = c.data.len - 2;
            const is_compressed = (flags & embed.FLAG_COMPRESSED) != 0;

            return PngbInfo{
                .version = version,
                .compressed = is_compressed,
                .payload_size = payload_size,
            };
        }
    }

    return Error.NoPngbChunk;
}

/// One PNGine ancillary chunk found by `enumerateChunks`. Every `pNG*` chunk the
/// `embed*` writers produce shares a 2-byte header (`version:u8`, `flags:u8`)
/// ahead of its payload, so those are surfaced uniformly; `version`/`flags` read
/// `null` only for a chunk too short to carry them (never for a well-formed
/// PNGine chunk). `total_size` is the on-wire size (length + type + data + CRC).
/// `kind` is the payload kind the chunk maps to (b→PNGB f→PNGF a→SNTU m→META
/// w→WGSL; a `pNGx` chunk reports the kind its envelope carries); `pNGm`'s
/// header is `[version]` with NO flags byte (the one irregular legacy header),
/// so its `flags` reads null and `payload_size` excludes only the version —
/// the mapping fixes the old misread of byte 1 as flags.
pub const ChunkEntry = struct {
    chunk_type: [4]u8,
    total_size: usize,
    payload_size: usize,
    version: ?u8,
    flags: ?u8,
    /// 02.C2: the mapped payload kind, or null for a family letter with no
    /// kind (the retired `pNGr`, a future letter) and for a `pNGx` chunk too
    /// short to carry a kind at all.
    kind: ?[4]u8 = null,

    /// True iff the chunk's `FLAG_COMPRESSED` bit is set (DEFLATE payload).
    pub fn isCompressed(self: ChunkEntry) bool {
        return if (self.flags) |f| (f & embed.FLAG_COMPRESSED) != 0 else false;
    }
};

/// Enumerate every PNGine ancillary chunk (`pNG*`) present in `png_data`, in file
/// order — the read-side counterpart to the writers, closing the
/// embed/extract asymmetry (A7). `embed` can write pNGb (bytecode), pNGm
/// (metadata), pNGa (audio), and pNGf (flat command buffer); before this, only
/// pNGb could be read back. This lets a caller (the CLI `extract --list`) SEE the
/// full inventory of whatever `embed` produced, regardless of which chunks a given
/// runtime later consumes (pNGb here, pNGa/pNGf in the JS runtime, pNGm/pNGw
/// reserved — see docs/architecture.md). Matches the `pNG` namespace prefix, so a
/// future `pNG*` chunk is enumerated without a code change here.
///
/// 02.C2: every entry also reports the payload KIND its chunk maps to
/// (`b→PNGB f→PNGF a→SNTU m→META w→WGSL`, a `pNGx` chunk the kind its envelope
/// carries — 02:81-87), which fixes the old misread of `pNGm`'s byte 1 as a
/// flags byte (02:82-83): pNGm's header is the version byte alone.
///
/// Pre-condition: `png_data` starts with the PNG signature.
/// Post-condition: caller owns the returned slice (empty if no PNGine chunks).
/// Complexity: O(png_data.len).
pub fn enumerateChunks(gpa: Allocator, png_data: []const u8) Error![]ChunkEntry {
    if (png_data.len < 8 or !std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE)) {
        return Error.InvalidPng;
    }
    std.debug.assert(std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE));

    var list: std.ArrayList(ChunkEntry) = .empty;
    errdefer list.deinit(gpa);

    var iter = chunk.parseChunks(png_data) catch return Error.InvalidPng;
    while (iter.next() catch return Error.InvalidPng) |c| {
        // The PNGine namespace: `pNG` + a family letter. Skip standard PNG chunks
        // (IHDR/IDAT/IEND/…) — only our ancillary chunks are enumerated.
        if (!std.mem.eql(u8, c.chunk_type[0..3], "pNG")) continue;

        var entry = ChunkEntry{
            .chunk_type = c.chunk_type,
            .total_size = c.total_size,
            .payload_size = c.data.len,
            .version = null,
            .flags = null,
            .kind = null,
        };

        if (std.mem.eql(u8, &c.chunk_type, &chunk.ChunkType.pNGx)) {
            // The envelope the chunk carries names the kind (02:85-86); its
            // payload is the envelope's body, after the eight header bytes.
            if (c.data.len >= 8) {
                entry.kind = c.data[0..4].*;
                entry.version = c.data[4];
                entry.flags = c.data[5];
                entry.payload_size = c.data.len - 8;
            } else if (c.data.len >= 4) {
                entry.kind = c.data[0..4].*;
            }
        } else if (legacyKind(c.chunk_type[3])) |kind| {
            const no_flags = c.chunk_type[3] == 'm';
            const header_len: usize = if (no_flags) 1 else 2;
            if (c.data.len >= header_len) {
                entry.kind = kind;
                entry.version = c.data[0];
                if (!no_flags and c.data.len >= 2) entry.flags = c.data[1];
                entry.payload_size = c.data.len - header_len;
            }
        }

        list.append(gpa, entry) catch return Error.OutOfMemory;
    }

    return list.toOwnedSlice(gpa) catch return Error.OutOfMemory;
}

// ============================================================================
// walkPng — the payload walker over both carrier generations (02.C2)
// ============================================================================

/// Which chunk carried a payload: its type and its 1-based occurrence among
/// the chunks of that type (the `pNGx#2` of the spec's `ls` carrier column,
/// 02:108). Legacy letters are unique in practice, so only `pNGx` numbers.
pub const Carrier = struct {
    chunk_type: [4]u8,
    nth: usize,
};

/// One payload listed by `walkPng` (02:97-98): the kind the chunk maps to,
/// the envelope's version/flags (reported, never judged — the handler checks
/// version, 02:36-39), the STORED body (bit 0 says it is raw DEFLATE;
/// inflating is the consumer's job, after any concatenation), and the
/// carrier chunk. `body` is owned by the `Walk` it came in.
///
/// `stored_overhead` is the header bytes the payload's carrier(s) put ahead
/// of its body on the wire: 8 for a `pNGx` envelope, 2 for the legacy
/// letters' `[version][flags]`, 1 for `pNGm`'s version byte; a `continued`
/// chain accumulates one per part, so `body.len + stored_overhead` is the
/// payload's stored size however many carriers it took.
pub const Payload = struct {
    kind: [4]u8,
    version: u8,
    flags: u8,
    body: []u8,
    stored_overhead: usize,
    carrier: Carrier,
};

/// Why a chunk was listed instead of yielded. The first four are the
/// envelope layer's own reasons (src/payload/envelope.zig, FROZEN v1),
/// passed through; the fifth is the carrier layer's: a family letter that
/// maps to no kind (the retired `pNGr` still living in museum PNGs) is
/// LISTED, never silently dropped — the museum promise (02:77-79).
pub const WalkSkipReason = enum {
    unreadable_flags,
    nonzero_reserved,
    truncated,
    dangling_continued,
    unknown_letter,
};

/// One listed skip, with the carrier that caused it.
pub const WalkSkip = struct {
    kind: [4]u8,
    reason: WalkSkipReason,
    /// Evidence for `.unreadable_flags`; zero otherwise.
    flags: u8 = 0,
    carrier: Carrier,
};

/// The result of walking a whole PNG: payloads and skip listings, in file
/// order (payloads in chain-completion order, 02:19-21). Frees every body
/// via `deinit`.
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

/// Walk `png_data` and list every payload it carries, legacy letters and
/// `pNGx` envelopes alike, in file order (02:97-99). Legacy chunks are mapped
/// onto the envelope (`b→PNGB f→PNGF a→SNTU m→META w→WGSL`, `pNGm`'s missing
/// flags byte supplied as zero — 02:81-83); `pNGx` chunk data IS the envelope
/// record (02:85-87). Reserved positions skip-and-list, never refusing the
/// file; `continued` chains concatenate in container order (02:19-23).
///
/// The walker never checks `version` — the handler does (02:36-39) — and
/// never inflates: bit 0 only SAYS the body is raw DEFLATE, after any
/// concatenation.
///
/// The 16 MiB chunk-data ceiling is pngine policy (src/png/chunk.zig caps
/// in-memory walks), aligned with the CLI's whole-file cap
/// (src/cli/utils.zig max_file_size): the PNG format itself allows chunk
/// data up to 2^31-1 (02:87-88), so a file input big enough to trip this
/// hits the CLI's file cap first at exit 2, and the chunk ceiling binds the
/// public in-memory walkers, which are real inputs too. Over it the walk
/// refuses with its own ChunkTooLarge error rather than a corruption
/// verdict.
///
/// Framing policy: a CRC mismatch, a declared length past the buffer, and a
/// chunk over pngine's 16 MiB ceiling each refuse the whole walk; a record
/// shorter than an envelope header is skipped-and-listed with kind
/// {0,0,0,0}. The JS twin (payloadsOf) matches the first two and applies no
/// ceiling: a declared, owner-approved resource difference (02's ask 02
/// verdict, 2026-10-05), bounded by the conditions it names.
///
/// Pre-condition: `png_data` starts with the PNG signature.
/// Post-condition: caller owns the result via `Walk.deinit`.
/// Complexity: O(png_data.len) plus one owned copy per payload body.
pub fn walkPng(gpa: Allocator, png_data: []const u8) Error!Walk {
    if (png_data.len < 8 or !std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE)) {
        return Error.InvalidPng;
    }

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
    // Legacy chunks have their envelope record synthesized (kind + header +
    // zero reserved); the synthesized bytes must outlive the loop, because a
    // `continued` chain holds its body as a view until the chain completes.
    var synth: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (synth.items) |r| gpa.free(r);
        synth.deinit(gpa);
    }
    // 1-based occurrence of each chunk type, for the carrier column.
    var counters: std.ArrayListUnmanaged(Counter) = .empty;
    defer counters.deinit(gpa);

    var iter = chunk.parseChunks(png_data) catch |err| return mapWalkError(err);
    while (iter.next() catch |err| return mapWalkError(err)) |c| {
        // The PNGine namespace: `pNG` + a family letter (or `pNGx`). Standard
        // PNG chunks are not carriers.
        if (!std.mem.eql(u8, c.chunk_type[0..3], "pNG")) continue;
        const carrier = Carrier{
            .chunk_type = c.chunk_type,
            .nth = bumpCounter(gpa, &counters, c.chunk_type) catch return Error.OutOfMemory,
        };

        if (std.mem.eql(u8, &c.chunk_type, &chunk.ChunkType.pNGx)) {
            // "body = envelope + bytes" (02:85-86): the chunk data IS the
            // record, a view into the PNG itself.
            try takeRecord(gpa, &payloads, &skipped, &chains, c.data, carrier);
        } else if (legacyKind(c.chunk_type[3])) |kind| {
            // The legacy letters' `[version][flags]` header "maps 1:1 onto
            // the envelope's version/flags" (02:80); pNGm's header is the
            // version byte alone — "the one irregular legacy header" (02:48).
            const no_flags = c.chunk_type[3] == 'm';
            const header_len: usize = if (no_flags) 1 else 2;
            if (c.data.len < header_len) {
                // Shorter than its own header: not an envelope at all
                // (02:12) — listed, never guessed.
                dropChain(gpa, &chains, kind);
                try skipped.append(gpa, .{ .kind = kind, .reason = .truncated, .carrier = carrier });
                continue;
            }
            const record = gpa.alloc(u8, 8 + c.data.len - header_len) catch return Error.OutOfMemory;
            @memcpy(record[0..4], &kind);
            record[4] = c.data[0];
            record[5] = if (no_flags) 0 else c.data[1];
            record[6] = 0;
            record[7] = 0;
            @memcpy(record[8..], c.data[header_len..]);
            try synth.append(gpa, record);
            try takeRecord(gpa, &payloads, &skipped, &chains, record, carrier);
        } else {
            // A family letter with no kind (the retired pNGr still living in
            // museum PNGs): listed so the inventory never silently drops a
            // legacy chunk (02:77-79).
            try skipped.append(gpa, .{ .kind = c.chunk_type, .reason = .unknown_letter, .carrier = carrier });
        }
    }

    // Chains still open at the end of the file are listed, never
    // half-yielded (02:19-21): with no next same-kind envelope there is no
    // body to reconstruct.
    for (chains.items) |chain| {
        try skipped.append(gpa, .{ .kind = chain.kind, .reason = .dangling_continued, .carrier = chain.carrier });
    }

    return .{
        .payloads = try payloads.toOwnedSlice(gpa),
        .skipped = try skipped.toOwnedSlice(gpa),
    };
}

/// Inflate one walked payload's stored body (the envelope's bit 0 set) —
/// the consumer's half of the walker's contract: `walkPng` never inflates
/// (02:17-19); the handler, or this convenience for the CLI's
/// `extract --kind`, does, capped like every other inflate here.
pub fn inflatePayload(gpa: Allocator, stored: []const u8) Error![]u8 {
    // The same wrap `extract` itself uses: an unreadable stream (or the
    // alloc behind its inflate) is a DecompressionFailed verdict.
    return decompressDeflateRaw(gpa, stored) catch Error.DecompressionFailed;
}

/// The walk's mapping of the chunk iterator's errors: an over-ceiling chunk
/// is pngine's own resource limit and reports as ChunkTooLarge; every other
/// framing defect (bad CRC, a declared length past the buffer) is corruption
/// and reports as InvalidPng.
fn mapWalkError(err: chunk.ParseError) Error {
    return switch (err) {
        error.ChunkTooLarge => Error.ChunkTooLarge,
        else => Error.InvalidPng,
    };
}

/// The family letter → kind map (02:81): which legacy `pNG<letter>` chunks
/// are envelope carriers, and the kind each maps to.
fn legacyKind(letter: u8) ?[4]u8 {
    return switch (letter) {
        'b' => .{ 'P', 'N', 'G', 'B' },
        'f' => .{ 'P', 'N', 'G', 'F' },
        'a' => .{ 'S', 'N', 'T', 'U' },
        'm' => .{ 'M', 'E', 'T', 'A' },
        'w' => .{ 'W', 'G', 'S', 'L' },
        else => null,
    };
}

/// The stored-size overhead a carrier puts ahead of a payload's body: 8 for
/// a `pNGx` envelope record, 1 for `pNGm`'s version-only header (02:48), 2
/// for the other legacy letters' `[version][flags]` (02:80). A chain carries
/// one per part.
fn carrierOverhead(chunk_type: [4]u8) usize {
    if (std.mem.eql(u8, &chunk_type, &chunk.ChunkType.pNGx)) return 8;
    if (std.mem.eql(u8, &chunk_type, &chunk.ChunkType.pNGm)) return 1;
    return 2;
}

/// A `continued` chain under assembly (02:19-21). Version, flags and carrier
/// are the chain's FIRST envelope's: the walker never compares them across
/// parts (02:16, 02:36-39) and a payload begins where its first part does.
/// `stored_overhead` accumulates one carrier's overhead per part.
const OpenChain = struct {
    kind: [4]u8,
    version: u8,
    flags: u8,
    carrier: Carrier,
    stored_overhead: usize = 0,
    parts: std.ArrayListUnmanaged([]const u8) = .empty,
};

const Counter = struct {
    chunk_type: [4]u8,
    n: usize,
};

fn bumpCounter(gpa: Allocator, counters: *std.ArrayListUnmanaged(Counter), chunk_type: [4]u8) !usize {
    for (counters.items) |*c| {
        if (std.mem.eql(u8, &c.chunk_type, &chunk_type)) {
            c.n += 1;
            return c.n;
        }
    }
    try counters.append(gpa, .{ .chunk_type = chunk_type, .n = 1 });
    return 1;
}

/// Take one envelope-prefixed record (a `pNGx` view or a synthesized legacy
/// one) into the walk: envelope or listed skip, chain or payload.
fn takeRecord(
    gpa: Allocator,
    payloads: *std.ArrayListUnmanaged(Payload),
    skipped: *std.ArrayListUnmanaged(WalkSkip),
    chains: *std.ArrayListUnmanaged(OpenChain),
    record: []const u8,
    carrier: Carrier,
) !void {
    const parsed = payload.envelope.parse(record);
    switch (parsed) {
        .envelope => |env| {
            if (findChain(chains, env.kind)) |chain| {
                try chain.parts.append(gpa, env.body);
                chain.stored_overhead += carrierOverhead(carrier.chunk_type);
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
                    .stored_overhead = carrierOverhead(carrier.chunk_type),
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
                    .stored_overhead = carrierOverhead(carrier.chunk_type),
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
                    // the frozen vocabulary's sake.
                    .no_handler, .dangling_continued => .truncated,
                },
                .flags = skip.flags,
                .carrier = carrier,
            });
            // A chain of this kind can no longer complete: its pending parts
            // are dropped, silently, exactly as the frozen envelope reader
            // treats a skipped chain member — the offending record is the
            // listed one, and the half-body is never guessed at.
            dropChain(gpa, chains, skip.kind);
        },
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
) !void {
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
/// record that broke the chain carries its own listing; the half-body is
/// never guessed at (the frozen envelope reader's own treatment).
fn dropChain(
    gpa: Allocator,
    chains: *std.ArrayListUnmanaged(OpenChain),
    kind: [4]u8,
) void {
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
// Tests
// ============================================================================

// ============================================================================
// OOM Tests
// ============================================================================

// ============================================================================
// Corrupted/Edge Case Tests
// ============================================================================

// ============================================================================
// Fuzz/Property Tests
// ============================================================================

/// A corpus seed as `std.testing.fuzz` replays it OUTSIDE fuzz mode: each entry
/// is fed to the callback as the Smith's whole input, and `Smith.slice` reads a
/// u32 little-endian LENGTH PREFIX before the bytes. Bare seeds were therefore
/// replayed as inputs of 0–2 bytes (the first four bytes of "PNGB" read as a
/// length of ~1.1 G, clamped to what was left) — none of them reached the code
/// they were written to seed. (Third leak pass)
fn fuzzSeed(comptime bytes: []const u8) []const u8 {
    const len_le = std.mem.toBytes(std.mem.nativeToLittle(u32, @as(u32, @intCast(bytes.len))));
    return &(len_le ++ bytes[0..bytes.len].*);
}

fn fuzzExtractProperties(_: @TypeOf({}), smith: *std.testing.Smith) !void {
    var buf: [4096]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];
    const gpa = std.testing.allocator;

    // Property: extract never crashes on any input
    const result = extract(gpa, input);

    if (result) |data| {
        defer gpa.free(data);
        // Property: if extraction succeeds, result starts with PNGB
        try std.testing.expect(data.len >= 4);
    } else |_| {
        // Error is expected for random data
    }
}

fn fuzzHasPngbProperties(_: @TypeOf({}), smith: *std.testing.Smith) !void {
    var buf: [4096]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];

    // Property: hasPngb never crashes on any input
    const result = hasPngb(input);

    // Property: result is deterministic
    const result2 = hasPngb(input);
    try std.testing.expectEqual(result, result2);
}

// ============================================================================
// 02.C2 walkPng tests — goldens authored from the spec, never from this
// walker (expansible-player docs/02-envelope-and-containers.md @ a7220d5;
// citations like 02:81-87 name its lines).
// ============================================================================

/// A test PNG built from hand-authored chunk data: signature, IHDR, the
/// given chunks in order, IEND. The data bytes in each test ARE the golden.
fn buildTestPng(gpa: Allocator, chunks: []const struct { t: [4]u8, d: []const u8 }) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, &chunk.PNG_SIGNATURE);
    const ihdr = [13]u8{
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x00, 0x00, 0x00, 0x00,
    };
    try chunk.writeChunk(&buf, gpa, chunk.ChunkType.IHDR, &ihdr);
    for (chunks) |c| try chunk.writeChunk(&buf, gpa, c.t, c.d);
    try chunk.writeChunk(&buf, gpa, chunk.ChunkType.IEND, "");
    return buf.toOwnedSlice(gpa);
}

const TestChunk = struct { t: [4]u8, d: []const u8 };
