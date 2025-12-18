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
//! - Entries are not deduplicated (unlike strings) - caller is responsible
//! - Total data must fit in u32 offset range (4GB)

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// Index into the data section.
pub const DataId = enum(u16) {
    _,

    pub fn toInt(self: DataId) u16 {
        return @intFromEnum(self);
    }
};

/// Data entry metadata.
pub const Entry = struct {
    offset: u32,
    len: u32,
};

/// Data section builder.
pub const DataSection = struct {
    const Self = @This();

    /// List of data blobs by ID.
    blobs: std.ArrayListUnmanaged([]const u8),
    /// Total size of all data in bytes.
    total_size: usize,

    pub const empty: Self = .{
        .blobs = .{},
        .total_size = 0,
    };

    pub fn deinit(self: *Self, allocator: Allocator) void {
        // Free all owned blob copies
        for (self.blobs.items) |blob| {
            allocator.free(blob);
        }
        self.blobs.deinit(allocator);
        self.* = undefined;
    }

    /// Add a data blob, returning its ID.
    /// Makes a copy of the data - caller can free their buffer after this returns.
    /// Note: Does NOT deduplicate - caller should handle deduplication if needed.
    /// Complexity: O(n) where n is data.len (for copy).
    pub fn add(self: *Self, allocator: Allocator, data: []const u8) !DataId {
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

        try self.blobs.append(allocator, owned);
        self.total_size += data.len;

        // Post-condition: ID is valid
        assert(id.toInt() < self.blobs.items.len);

        return id;
    }

    /// Get data blob by ID.
    ///
    /// **Lifetime**: The returned slice is valid until the DataSection is
    /// deinitialized via `deinit()`. Slices remain valid across `add()` calls
    /// because each blob is independently allocated.
    ///
    /// Complexity: O(1).
    pub fn get(self: *const Self, id: DataId) []const u8 {
        // Pre-condition: ID is valid
        assert(id.toInt() < self.blobs.items.len);

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

test "empty data section" {
    var section: DataSection = .empty;
    defer section.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 0), section.count());
}

test "add single data blob" {
    var section: DataSection = .empty;
    defer section.deinit(testing.allocator);

    const shader_code = "@vertex fn main() {}";
    const id = try section.add(testing.allocator, shader_code);

    try testing.expectEqual(@as(u16, 0), id.toInt());
    try testing.expectEqualStrings(shader_code, section.get(id));
    try testing.expectEqual(@as(u16, 1), section.count());
}

test "add multiple data blobs" {
    var section: DataSection = .empty;
    defer section.deinit(testing.allocator);

    const shader1 = "@vertex fn vs() {}";
    const shader2 = "@fragment fn fs() {}";
    const binary_data = &[_]u8{ 0x00, 0x01, 0x02, 0xFF };

    const id0 = try section.add(testing.allocator, shader1);
    const id1 = try section.add(testing.allocator, shader2);
    const id2 = try section.add(testing.allocator, binary_data);

    try testing.expectEqual(@as(u16, 0), id0.toInt());
    try testing.expectEqual(@as(u16, 1), id1.toInt());
    try testing.expectEqual(@as(u16, 2), id2.toInt());

    try testing.expectEqualStrings(shader1, section.get(id0));
    try testing.expectEqualStrings(shader2, section.get(id1));
    try testing.expectEqualSlices(u8, binary_data, section.get(id2));
}

test "serialize and deserialize" {
    var section: DataSection = .empty;
    defer section.deinit(testing.allocator);

    const shader1 = "@vertex fn vertexMain() {}";
    const shader2 = "@fragment fn fragMain() { return vec4f(1,0,0,1); }";

    _ = try section.add(testing.allocator, shader1);
    _ = try section.add(testing.allocator, shader2);

    const serialized = try section.serialize(testing.allocator);
    defer testing.allocator.free(serialized);

    var loaded = try deserialize(testing.allocator, serialized);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(section.count(), loaded.count());
    try testing.expectEqualStrings(shader1, loaded.get(@enumFromInt(0)));
    try testing.expectEqualStrings(shader2, loaded.get(@enumFromInt(1)));
}

test "empty data blob" {
    var section: DataSection = .empty;
    defer section.deinit(testing.allocator);

    const id = try section.add(testing.allocator, "");
    try testing.expectEqual(@as(u16, 0), id.toInt());
    try testing.expectEqualStrings("", section.get(id));
}

test "large data blob" {
    var section: DataSection = .empty;
    defer section.deinit(testing.allocator);

    // Create a large shader code blob
    const large_shader = "// " ++ ("x" ** 10000) ++ "\n@vertex fn main() {}";
    const id = try section.add(testing.allocator, large_shader);

    try testing.expectEqualStrings(large_shader, section.get(id));
}

test "add makes owned copy - caller can free immediately" {
    // Regression test: DataSection must own copies of data.
    // Caller should be able to free their buffer right after add().
    // If DataSection only stored slices, this would cause use-after-free.
    //
    // testing.allocator detects:
    // - Memory leaks (if we don't free properly)
    // - Use-after-free (if we access freed memory)

    var section: DataSection = .empty;
    defer section.deinit(testing.allocator);

    // Allocate a buffer, add to section, then FREE IT
    const temp_data = try testing.allocator.dupe(u8, "temporary descriptor JSON");
    const id = try section.add(testing.allocator, temp_data);

    // Free caller's buffer immediately - this is the key part of the test
    testing.allocator.free(temp_data);

    // DataSection must still have valid data (its own copy)
    try testing.expectEqualStrings("temporary descriptor JSON", section.get(id));

    // Serialize should also work with valid data
    const serialized = try section.serialize(testing.allocator);
    defer testing.allocator.free(serialized);

    // Deserialize and verify
    var loaded = try deserialize(testing.allocator, serialized);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqualStrings("temporary descriptor JSON", loaded.get(@enumFromInt(0)));
}

test "multiple adds with caller frees - no leaks" {
    // Verify no memory leaks when adding multiple blobs and freeing caller buffers.
    // testing.allocator will fail the test if any memory leaks.

    var section: DataSection = .empty;
    defer section.deinit(testing.allocator);

    // Simulate what Emitter does: allocate, add, free
    for (0..10) |i| {
        const temp = try std.fmt.allocPrint(
            testing.allocator,
            "{{\"shader\":{d},\"entryPoint\":\"main\"}}",
            .{i},
        );
        _ = try section.add(testing.allocator, temp);
        testing.allocator.free(temp); // Caller frees immediately
    }

    // All 10 entries should be valid
    try testing.expectEqual(@as(u16, 10), section.count());

    // Verify data integrity
    const first = section.get(@enumFromInt(0));
    try testing.expect(std.mem.indexOf(u8, first, "\"shader\":0") != null);

    const last = section.get(@enumFromInt(9));
    try testing.expect(std.mem.indexOf(u8, last, "\"shader\":9") != null);
}

test "deserialize makes owned copies - input buffer can be freed" {
    // Regression test: deserialize() must make owned copies of blobs.
    // If it stored slices into the input buffer, freeing the input would
    // cause use-after-free when accessing deserialized data.
    //
    // testing.allocator detects:
    // - Invalid free (if we try to free non-owned memory)
    // - Use-after-free (if we access freed memory)

    // First, create and serialize a section
    var original: DataSection = .empty;
    _ = try original.add(testing.allocator, "shader code here");
    _ = try original.add(testing.allocator, "more data");

    const serialized = try original.serialize(testing.allocator);
    original.deinit(testing.allocator);

    // Deserialize into a new section
    var loaded = try deserialize(testing.allocator, serialized);

    // FREE the serialized buffer - this is the key part of the test
    testing.allocator.free(serialized);

    // Loaded section must still have valid data (its own copies)
    try testing.expectEqualStrings("shader code here", loaded.get(@enumFromInt(0)));
    try testing.expectEqualStrings("more data", loaded.get(@enumFromInt(1)));

    // Re-serialize should work (proves data is still valid)
    const reserialized = try loaded.serialize(testing.allocator);
    defer testing.allocator.free(reserialized);

    // Clean up - deinit must not crash (no double-free or invalid free)
    loaded.deinit(testing.allocator);
}

test "roundtrip with immediate buffer frees - full ownership test" {
    // End-to-end regression test combining all ownership scenarios:
    // 1. add() with caller free
    // 2. serialize() produces owned buffer
    // 3. deserialize() makes owned copies
    // 4. All deinit() calls succeed without invalid frees
    //
    // This simulates the full Emitter → serialize → load → execute flow.

    // Step 1: Build section, freeing caller buffers immediately
    var section: DataSection = .empty;
    for (0..5) |i| {
        const temp = try std.fmt.allocPrint(testing.allocator, "blob_{d}", .{i});
        _ = try section.add(testing.allocator, temp);
        testing.allocator.free(temp);
    }

    // Step 2: Serialize and free original section
    const serialized = try section.serialize(testing.allocator);
    section.deinit(testing.allocator);

    // Step 3: Deserialize and free serialized buffer
    var loaded = try deserialize(testing.allocator, serialized);
    testing.allocator.free(serialized);

    // Step 4: Verify all data intact
    try testing.expectEqual(@as(u16, 5), loaded.count());
    try testing.expectEqualStrings("blob_0", loaded.get(@enumFromInt(0)));
    try testing.expectEqualStrings("blob_4", loaded.get(@enumFromInt(4)));

    // Step 5: Re-serialize from loaded (proves data ownership)
    const final = try loaded.serialize(testing.allocator);
    defer testing.allocator.free(final);

    // Step 6: Clean up loaded section
    loaded.deinit(testing.allocator);

    // If we reach here without crashes or leaks, ownership is correct
}
