//! String Table Builder
//!
//! Builds a deduplicated string table for the PNGB binary format.
//! Strings are stored with u16 offsets for compact encoding.
//!
//! Format:
//! │ count: u16              │ number of strings
//! │ offsets: [count]u16     │ byte offset of each string's start
//! │ lengths: [count]u16     │ byte length of each string
//! │ data: UTF-8 bytes       │ concatenated string data
//!
//! Invariants:
//! - String IDs are dense indices starting from 0
//! - Each unique string has exactly one ID (deduplication)
//! - Total string data must fit in u16 offset range (65535 bytes)

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

// Import StringId from shared types
pub const StringId = @import("types").StringId;

/// String table builder with deduplication.
pub const StringTable = struct {
    const Self = @This();

    /// Map from string content to string ID for deduplication.
    map: std.StringHashMapUnmanaged(StringId),
    /// Ordered list of strings by ID.
    strings: std.ArrayList([]const u8),
    /// Total size of string data in bytes.
    total_size: usize,
    /// Whether this table owns its strings (true for intern(), false for deserialize()).
    owns_strings: bool,

    pub const empty: Self = .{
        .map = .{},
        .strings = .empty,
        .total_size = 0,
        .owns_strings = true,
    };

    pub fn deinit(self: *Self, allocator: Allocator) void {
        // Free string copies only if we own them (intern() copies, deserialize() borrows)
        if (self.owns_strings) {
            for (self.strings.items) |str| {
                allocator.free(str);
            }
        }
        self.map.deinit(allocator);
        self.strings.deinit(allocator);
        self.* = undefined;
    }

    /// Intern a string, returning its ID. Deduplicates identical strings.
    /// The string is copied, so caller can free their copy after this returns.
    /// Complexity: O(1) average, O(n) on hash collision.
    pub fn intern(self: *Self, allocator: Allocator, str: []const u8) !StringId {
        // Pre-condition: string data fits in u16 range
        if (self.total_size + str.len > std.math.maxInt(u16)) {
            return error.StringTableOverflow;
        }

        // Check for existing entry first
        if (self.map.get(str)) |existing_id| {
            return existing_id;
        }

        // Copy the string so we own it
        const owned_str = try allocator.dupe(u8, str);
        errdefer allocator.free(owned_str);

        // New string - allocate ID
        const id: StringId = @enumFromInt(@as(u16, @intCast(self.strings.items.len)));

        // Order matters: `strings` owns the buffer (deinit frees through it
        // alone), so it takes the string FIRST. The old order put the key in the
        // map first, and a failing append then let the errdefer free a buffer
        // the map still held as a key — a use-after-free on the next intern that
        // hashed into that bucket, silent because callers `catch continue`
        // (LEAK-10).
        try self.strings.append(allocator, owned_str);
        errdefer _ = self.strings.pop();
        try self.map.put(allocator, owned_str, id);
        self.total_size += str.len;

        // Post-condition: ID is valid
        assert(id.toInt() < self.strings.items.len);

        return id;
    }

    /// Get string by ID.
    /// Complexity: O(1).
    pub fn get(self: *const Self, id: StringId) []const u8 {
        // Pre-condition: ID is valid
        assert(id.toInt() < self.strings.items.len);
        return self.strings.items[id.toInt()];
    }

    /// Find string ID by content.
    /// Returns null if the string is not in the table.
    /// Complexity: O(1) average (hash lookup).
    ///
    /// Note: This method is used for runtime uniform lookup by name.
    /// The uniform table stores string IDs, so we need reverse lookup.
    pub fn findId(self: *const Self, str: []const u8) ?StringId {
        return self.map.get(str);
    }

    /// Number of unique strings.
    pub fn count(self: *const Self) u16 {
        return @intCast(self.strings.items.len);
    }

    /// Serialize to binary format.
    /// Returns: count (u16) + offsets (u16 each) + lengths (u16 each) + data
    pub fn serialize(self: *const Self, allocator: Allocator) ![]u8 {
        const str_count = self.count();

        // Calculate sizes
        const header_size = @sizeOf(u16); // count
        const offsets_size = @as(usize, str_count) * @sizeOf(u16);
        const lengths_size = @as(usize, str_count) * @sizeOf(u16);
        const total = header_size + offsets_size + lengths_size + self.total_size;

        const buffer = try allocator.alloc(u8, total);
        errdefer allocator.free(buffer);

        var offset: usize = 0;

        // Write count
        std.mem.writeInt(u16, buffer[offset..][0..2], str_count, .little);
        offset += 2;

        // Write offsets
        var data_offset: u16 = 0;
        for (self.strings.items) |str| {
            std.mem.writeInt(u16, buffer[offset..][0..2], data_offset, .little);
            offset += 2;
            data_offset += @intCast(str.len);
        }

        // Write lengths
        for (self.strings.items) |str| {
            std.mem.writeInt(u16, buffer[offset..][0..2], @intCast(str.len), .little);
            offset += 2;
        }

        // Write string data
        for (self.strings.items) |str| {
            @memcpy(buffer[offset..][0..str.len], str);
            offset += str.len;
        }

        // Post-condition: wrote exactly the expected amount
        assert(offset == total);

        return buffer;
    }
};

/// Deserialize string table from binary format.
pub fn deserialize(allocator: Allocator, data: []const u8) !StringTable {
    // Pre-condition: at least header present
    if (data.len < 2) return error.InvalidStringTable;

    const str_count = std.mem.readInt(u16, data[0..2], .little);

    // Validate minimum size
    const header_size = 2;
    const offsets_size = @as(usize, str_count) * 2;
    const lengths_size = @as(usize, str_count) * 2;
    const metadata_size = header_size + offsets_size + lengths_size;

    if (data.len < metadata_size) return error.InvalidStringTable;

    var table: StringTable = .empty;
    table.owns_strings = false; // Deserialize borrows slices from input data
    errdefer table.deinit(allocator);

    try table.strings.ensureTotalCapacity(allocator, str_count);
    try table.map.ensureTotalCapacity(allocator, str_count);

    // Read offsets and lengths
    const offsets_start = header_size;
    const lengths_start = offsets_start + offsets_size;
    const data_start = lengths_start + lengths_size;

    for (0..str_count) |i| {
        const offset_pos = offsets_start + i * 2;
        const length_pos = lengths_start + i * 2;

        const str_offset = std.mem.readInt(u16, data[offset_pos..][0..2], .little);
        const str_len = std.mem.readInt(u16, data[length_pos..][0..2], .little);

        const str_start = data_start + str_offset;
        const str_end = str_start + str_len;

        if (str_end > data.len) return error.InvalidStringTable;

        const str = data[str_start..str_end];
        const id: StringId = @enumFromInt(@as(u16, @intCast(i)));

        table.strings.appendAssumeCapacity(str);
        table.map.putAssumeCapacity(str, id);
        table.total_size += str.len;
    }

    return table;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
