//! Data Section Builder
//!
//! Builds the data section for the PNGB binary format.
//! Stores raw binary data like shader code, uniform layouts, vertex data, etc.
//!
//! Format:
//! │ count: u16                      │ number of data entries
//! │ entries: [count]{offset, len}   │ u32 offset, u32 length for each
//! │ data: raw bytes                 │ concatenated data blobs
//!
//! Invariants:
//! - Data IDs are dense indices starting from 0
//! - Each distinct blob has exactly one ID (content deduplication, §348)
//! - Total data must fit in u32 offset range (4GB)

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

// Import DataId from shared types
pub const DataId = @import("types").DataId;

/// Data entry metadata.
pub const Entry = struct {
    offset: u32,
    len: u32,
};

/// Data section builder.
pub const DataSection = struct {
    const Self = @This();

    /// List of data blobs by ID.
    blobs: std.ArrayList([]const u8),
    /// Content → ID, for deduplication. Keys are the owned blobs themselves, so
    /// the map costs one entry per DISTINCT blob and no extra bytes of content.
    /// Only `add` populates it — `deserialize` deliberately does not (see there).
    index: std.StringHashMapUnmanaged(DataId),
    /// Total size of all data in bytes.
    total_size: usize,

    pub const empty: Self = .{
        .blobs = .empty,
        .index = .{},
        .total_size = 0,
    };

    pub fn deinit(self: *Self, allocator: Allocator) void {
        // Free all owned blob copies. `blobs` is the sole owner — `index` keys
        // alias the same buffers, so it must not free through them.
        for (self.blobs.items) |blob| {
            allocator.free(blob);
        }
        self.index.deinit(allocator);
        self.blobs.deinit(allocator);
        self.* = undefined;
    }

    /// Add a data blob, returning its ID. Identical content returns the ID it
    /// already has — the blob is stored once.
    ///
    /// Makes a copy of the data - caller can free their buffer after this returns.
    ///
    /// **Why dedupe here and not in the callers.** The section is the payload's
    /// bulk, and its callers are ~20 scattered `builder.addData(…)` sites that
    /// cannot see each other: a generated mesh, a descriptor JSON, an embedded
    /// image, a WGSL module. Two `(data :name a (dragon …))` forms produce
    /// byte-identical 860 KB blobs from ~110 bytes of source each (~7,800×), and
    /// nothing upstream compares them. Making every caller "responsible", as the
    /// old comment here did, meant no caller was (LEAK-11-D).
    ///
    /// Dedupe collapses STORAGE, never resources: the emitter still emits one
    /// `create_buffer` per `(buffer …)` form — they just name the same blob.
    /// That is already how the string table behaves for entry-point names.
    ///
    /// Complexity: O(n) in data.len — one hash, plus one copy on a miss.
    pub fn add(self: *Self, allocator: Allocator, data: []const u8) !DataId {
        // Content already present: return its id without touching the caps
        // below. A duplicate costs no id and no bytes, which is the point.
        if (self.index.get(data)) |existing| {
            assert(existing.toInt() < self.blobs.items.len);
            return existing;
        }

        // Pre-condition: data fits in u32 range
        if (self.total_size + data.len > std.math.maxInt(u32)) {
            return error.DataSectionOverflow;
        }
        if (self.blobs.items.len >= std.math.maxInt(u16)) {
            return error.TooManyDataEntries;
        }

        const id: DataId = @enumFromInt(@as(u16, @intCast(self.blobs.items.len)));

        // Make owned copy of data
        const owned = try allocator.dupe(u8, data);
        errdefer allocator.free(owned);

        // Order matters, and it is the LEAK-10 lesson from `StringTable.intern`:
        // `blobs` owns the buffer, so it takes it FIRST. Putting the key in the
        // map first lets a failing append free a buffer the map still holds as a
        // key — a use-after-free on the next `add` that hashes into that bucket.
        try self.blobs.append(allocator, owned);
        errdefer _ = self.blobs.pop();
        try self.index.put(allocator, owned, id);
        self.total_size += data.len;

        // Post-condition: ID is valid and the index agrees with the list
        assert(id.toInt() < self.blobs.items.len);
        assert(self.index.count() <= self.blobs.items.len);

        return id;
    }

    /// Get data blob by ID. An id past the end yields an EMPTY slice.
    ///
    /// Total, not asserting. Every one of this function's ~50 call sites feeds
    /// it an id read straight out of bytecode — `module.data.get(@enumFromInt(
    /// descriptor_data_id))` and friends — so "the id is in range" is a claim
    /// about UNTRUSTED INPUT, not an invariant the callers establish. As an
    /// `assert` it was a Debug panic in `pngine inspect`/the native viewer and,
    /// once stripped in ReleaseFast/ReleaseSmall, an unchecked
    /// `blobs.items[id]` — an out-of-bounds READ on the exact path r1's threat
    /// model is about (a native viewer playing a PNG from the internet).
    ///
    /// Found by r2-07's `duplicate create_texture id` corpus case, which
    /// referenced data id 0 of an empty section and aborted the native render
    /// harness; the same clamp-don't-trap contract as `wire_schema.skipKind`
    /// and MockGPU's MAX_* id caps. Callers all treat the blob as opaque bytes
    /// to search or parse, so empty degrades to "no descriptor / no source" —
    /// visible in a trace, never memory-unsafe.
    ///
    /// **Lifetime**: The returned slice is valid until the DataSection is
    /// deinitialized via `deinit()`. Slices remain valid across `add()` calls
    /// because each blob is independently allocated.
    ///
    /// Complexity: O(1).
    pub fn get(self: *const Self, id: DataId) []const u8 {
        if (id.toInt() >= self.blobs.items.len) return &.{};
        return self.blobs.items[id.toInt()];
    }

    /// Number of data entries.
    pub fn count(self: *const Self) u16 {
        return @intCast(self.blobs.items.len);
    }

    /// Serialize to binary format.
    /// Returns: count (u16) + entries ([]{offset: u32, len: u32}) + data
    pub fn serialize(self: *const Self, allocator: Allocator) ![]u8 {
        const data_count = self.count();

        // Calculate sizes
        const header_size = @sizeOf(u16); // count
        const entries_size = @as(usize, data_count) * (2 * @sizeOf(u32)); // offset + len
        const total = header_size + entries_size + self.total_size;

        const buffer = try allocator.alloc(u8, total);
        errdefer allocator.free(buffer);

        var offset: usize = 0;

        // Write count
        std.mem.writeInt(u16, buffer[offset..][0..2], data_count, .little);
        offset += 2;

        // Write entries (offset, length pairs)
        var data_offset: u32 = 0;
        for (self.blobs.items) |blob| {
            std.mem.writeInt(u32, buffer[offset..][0..4], data_offset, .little);
            offset += 4;
            std.mem.writeInt(u32, buffer[offset..][0..4], @intCast(blob.len), .little);
            offset += 4;
            data_offset += @intCast(blob.len);
        }

        // Write data blobs
        for (self.blobs.items) |blob| {
            @memcpy(buffer[offset..][0..blob.len], blob);
            offset += blob.len;
        }

        // Post-condition: wrote exactly the expected amount
        assert(offset == total);

        return buffer;
    }
};

/// Deserialize data section from binary format.
/// Makes owned copies of all blobs - input data can be freed after this returns.
///
/// Entries are restored VERBATIM, duplicates included, and the dedupe index is
/// left empty. Ids are wire references — every `create_*` operand that names a
/// blob was encoded against this exact ordering, so collapsing equal blobs on
/// load would silently repoint them. Payloads compiled before §348 legitimately
/// carry duplicates; they must keep their ids. Nothing adds to a deserialized
/// section (the builder is the only `add` caller), so the empty index costs
/// nothing but a missed dedupe that could not happen.
pub fn deserialize(allocator: Allocator, data: []const u8) !DataSection {
    // Pre-condition: at least header present
    if (data.len < 2) return error.InvalidDataSection;

    const data_count = std.mem.readInt(u16, data[0..2], .little);

    // Validate minimum size
    const header_size = 2;
    const entries_size = @as(usize, data_count) * 8; // offset + len
    const metadata_size = header_size + entries_size;

    if (data.len < metadata_size) return error.InvalidDataSection;

    var section: DataSection = .empty;
    errdefer section.deinit(allocator);

    try section.blobs.ensureTotalCapacity(allocator, data_count);

    const entries_start = header_size;
    const data_start = metadata_size;

    // Read entries and extract blobs (making owned copies)
    for (0..data_count) |i| {
        const entry_pos = entries_start + i * 8;
        const blob_offset = std.mem.readInt(u32, data[entry_pos..][0..4], .little);
        const blob_len = std.mem.readInt(u32, data[entry_pos + 4 ..][0..4], .little);

        const blob_start = data_start + blob_offset;
        const blob_end = blob_start + blob_len;

        if (blob_end > data.len) return error.InvalidDataSection;

        // Make owned copy of blob data
        const owned = try allocator.dupe(u8, data[blob_start..blob_end]);
        section.blobs.appendAssumeCapacity(owned);
        section.total_size += owned.len;
    }

    // Post-condition: loaded correct number of entries
    assert(section.blobs.items.len == data_count);

    return section;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
