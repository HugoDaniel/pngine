//! Animation Table for PNGB Format
//!
//! Stores animation metadata for runtime scene/timeline management.
//! This enables automatic scene transitions during playback.
//!
//! ## Format (serialized)
//!
//! ```
//! flags: u8 (bit 0: has_animation, bit 1: loop)
//! If has_animation:
//!   name_string_id: varint
//!   duration_ms: u32 (milliseconds, fixed-point for precision)
//!   end_behavior: u8 (0=hold, 1=stop, 2=restart)
//!   scene_count: varint
//!   scenes: [scene_count] {
//!     id_string_id: varint
//!     frame_string_id: varint
//!     start_ms: u32
//!     end_ms: u32
//!   }
//! ```
//!
//! ## Invariants
//!
//! - At most one animation per module
//! - Scene start times must be < end times
//! - Scenes should not overlap (not enforced, but recommended)

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const opcodes = @import("opcodes.zig");

/// Maximum scenes per animation.
const MAX_SCENES: u16 = 256;

/// End behavior when animation completes.
pub const EndBehavior = enum(u8) {
    hold = 0, // Keep last frame
    stop = 1, // Stop playback
    restart = 2, // Loop back to start
};

/// Scene within an animation timeline.
pub const Scene = struct {
    /// Scene identifier (string table ID).
    id_string_id: u16,
    /// Frame name reference (string table ID).
    frame_string_id: u16,
    /// Start time in milliseconds.
    start_ms: u32,
    /// End time in milliseconds.
    end_ms: u32,

    /// Get duration in milliseconds.
    pub fn durationMs(self: Scene) u32 {
        return self.end_ms - self.start_ms;
    }
};

/// Animation metadata.
pub const AnimationInfo = struct {
    /// Animation name (string table ID).
    name_string_id: u16,
    /// Total duration in milliseconds.
    duration_ms: u32,
    /// Whether animation loops.
    loop: bool,
    /// Behavior when animation ends.
    end_behavior: EndBehavior,
    /// Scenes in the timeline.
    scenes: []const Scene,
};

/// Animation table for a module.
pub const AnimationTable = struct {
    /// Animation info if present.
    info: ?AnimationInfo,
    /// Owned scenes array (for deserialized data).
    owned_scenes: ?[]Scene,

    pub const empty: AnimationTable = .{
        .info = null,
        .owned_scenes = null,
    };

    pub fn deinit(self: *AnimationTable, allocator: Allocator) void {
        if (self.owned_scenes) |scenes| {
            allocator.free(scenes);
        }
        self.* = undefined;
    }

    /// Check if animation is defined.
    pub fn hasAnimation(self: *const AnimationTable) bool {
        return self.info != null;
    }

    /// Get scene count.
    pub fn sceneCount(self: *const AnimationTable) u16 {
        const info = self.info orelse return 0;
        return @intCast(info.scenes.len);
    }

    /// Get scene by index.
    pub fn getScene(self: *const AnimationTable, index: u16) ?Scene {
        const info = self.info orelse return null;
        if (index >= info.scenes.len) return null;
        return info.scenes[index];
    }

    /// Find scene at a given time (in milliseconds).
    /// Returns scene index or null if time is past all scenes.
    pub fn findSceneAtTime(self: *const AnimationTable, time_ms: u32) ?u16 {
        const info = self.info orelse return null;
        const idx = findSceneAtTimeStatic(info, time_ms) orelse return null;
        return @intCast(idx);
    }

    /// Static version for use without AnimationTable wrapper.
    /// Returns scene index or null if time is past all scenes.
    pub fn findSceneAtTimeStatic(info: AnimationInfo, time_ms: u32) ?u32 {
        for (info.scenes, 0..) |scene, i| {
            if (time_ms >= scene.start_ms and time_ms < scene.end_ms) {
                return @intCast(i);
            }
        }

        // If past all scenes, return last scene if hold behavior
        if (info.end_behavior == .hold and info.scenes.len > 0) {
            return @intCast(info.scenes.len - 1);
        }

        return null;
    }

    /// Serialize to bytes.
    pub fn serialize(self: *const AnimationTable, allocator: Allocator) ![]u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(allocator);

        var buf: [4]u8 = undefined;

        const info = self.info orelse {
            // No animation - just write flags byte with bit 0 = 0
            try result.append(allocator, 0);
            return result.toOwnedSlice(allocator);
        };

        // Flags: bit 0 = has_animation, bit 1 = loop
        var flags: u8 = 1; // has_animation
        if (info.loop) flags |= 2;
        try result.append(allocator, flags);

        // name_string_id
        const name_len = opcodes.encodeVarint(info.name_string_id, &buf);
        try result.appendSlice(allocator, buf[0..name_len]);

        // duration_ms (fixed u32)
        try result.appendSlice(allocator, std.mem.asBytes(&info.duration_ms));

        // end_behavior
        try result.append(allocator, @intFromEnum(info.end_behavior));

        // scene_count
        const count_len = opcodes.encodeVarint(@intCast(info.scenes.len), &buf);
        try result.appendSlice(allocator, buf[0..count_len]);

        // scenes (bounded loop)
        for (info.scenes, 0..) |scene, i| {
            if (i >= MAX_SCENES) break;

            // id_string_id
            const id_len = opcodes.encodeVarint(scene.id_string_id, &buf);
            try result.appendSlice(allocator, buf[0..id_len]);

            // frame_string_id
            const frame_len = opcodes.encodeVarint(scene.frame_string_id, &buf);
            try result.appendSlice(allocator, buf[0..frame_len]);

            // start_ms (fixed u32)
            try result.appendSlice(allocator, std.mem.asBytes(&scene.start_ms));

            // end_ms (fixed u32)
            try result.appendSlice(allocator, std.mem.asBytes(&scene.end_ms));
        }

        return result.toOwnedSlice(allocator);
    }
};

/// Deserialize animation table from bytes.
pub fn deserialize(allocator: Allocator, data: []const u8) !AnimationTable {
    if (data.len == 0) return AnimationTable.empty;

    var pos: usize = 0;

    // Read flags
    const flags = data[pos];
    pos += 1;

    const has_animation = (flags & 1) != 0;
    if (!has_animation) {
        return AnimationTable.empty;
    }

    const loop = (flags & 2) != 0;

    // Read name_string_id
    if (pos >= data.len) return AnimationTable.empty;
    const name_result = opcodes.decodeVarint(data[pos..]);
    pos += name_result.len;
    const name_string_id: u16 = @intCast(name_result.value);

    // Read duration_ms
    if (pos + 4 > data.len) return AnimationTable.empty;
    const duration_ms = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;

    // Read end_behavior
    if (pos >= data.len) return AnimationTable.empty;
    const end_behavior: EndBehavior = @enumFromInt(data[pos]);
    pos += 1;

    // Read scene_count
    if (pos >= data.len) return AnimationTable.empty;
    const count_result = opcodes.decodeVarint(data[pos..]);
    pos += count_result.len;
    const scene_count: u16 = @intCast(@min(count_result.value, MAX_SCENES));

    // Read scenes
    var scenes = try allocator.alloc(Scene, scene_count);
    errdefer allocator.free(scenes);

    for (0..scene_count) |i| {
        // id_string_id
        if (pos >= data.len) break;
        const id_result = opcodes.decodeVarint(data[pos..]);
        pos += id_result.len;

        // frame_string_id
        if (pos >= data.len) break;
        const frame_result = opcodes.decodeVarint(data[pos..]);
        pos += frame_result.len;

        // start_ms
        if (pos + 4 > data.len) break;
        const start_ms = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        // end_ms
        if (pos + 4 > data.len) break;
        const end_ms = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        scenes[i] = .{
            .id_string_id = @intCast(id_result.value),
            .frame_string_id = @intCast(frame_result.value),
            .start_ms = start_ms,
            .end_ms = end_ms,
        };
    }

    return AnimationTable{
        .info = .{
            .name_string_id = name_string_id,
            .duration_ms = duration_ms,
            .loop = loop,
            .end_behavior = end_behavior,
            .scenes = scenes,
        },
        .owned_scenes = scenes,
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "empty animation table" {
    var table = AnimationTable.empty;
    defer table.deinit(testing.allocator);

    try testing.expect(!table.hasAnimation());
    try testing.expectEqual(@as(u16, 0), table.sceneCount());
    try testing.expect(table.getScene(0) == null);
}

test "serialize empty table" {
    var table = AnimationTable.empty;
    defer table.deinit(testing.allocator);

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    try testing.expectEqual(@as(usize, 1), bytes.len);
    try testing.expectEqual(@as(u8, 0), bytes[0]); // flags = 0 (no animation)
}

test "serialize and deserialize animation" {
    const scenes = [_]Scene{
        .{ .id_string_id = 1, .frame_string_id = 2, .start_ms = 0, .end_ms = 5000 },
        .{ .id_string_id = 3, .frame_string_id = 4, .start_ms = 5000, .end_ms = 15000 },
    };

    var table = AnimationTable{
        .info = .{
            .name_string_id = 0,
            .duration_ms = 15000,
            .loop = true,
            .end_behavior = .hold,
            .scenes = &scenes,
        },
        .owned_scenes = null,
    };

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    // Deserialize
    var restored = try deserialize(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    try testing.expect(restored.hasAnimation());
    const info = restored.info.?;
    try testing.expectEqual(@as(u16, 0), info.name_string_id);
    try testing.expectEqual(@as(u32, 15000), info.duration_ms);
    try testing.expect(info.loop);
    try testing.expectEqual(EndBehavior.hold, info.end_behavior);
    try testing.expectEqual(@as(usize, 2), info.scenes.len);

    const s0 = info.scenes[0];
    try testing.expectEqual(@as(u16, 1), s0.id_string_id);
    try testing.expectEqual(@as(u16, 2), s0.frame_string_id);
    try testing.expectEqual(@as(u32, 0), s0.start_ms);
    try testing.expectEqual(@as(u32, 5000), s0.end_ms);

    const s1 = info.scenes[1];
    try testing.expectEqual(@as(u16, 3), s1.id_string_id);
    try testing.expectEqual(@as(u16, 4), s1.frame_string_id);
    try testing.expectEqual(@as(u32, 5000), s1.start_ms);
    try testing.expectEqual(@as(u32, 15000), s1.end_ms);
}

test "findSceneAtTime" {
    const scenes = [_]Scene{
        .{ .id_string_id = 0, .frame_string_id = 0, .start_ms = 0, .end_ms = 5000 },
        .{ .id_string_id = 1, .frame_string_id = 1, .start_ms = 5000, .end_ms = 10000 },
        .{ .id_string_id = 2, .frame_string_id = 2, .start_ms = 10000, .end_ms = 15000 },
    };

    const table = AnimationTable{
        .info = .{
            .name_string_id = 0,
            .duration_ms = 15000,
            .loop = false,
            .end_behavior = .hold,
            .scenes = &scenes,
        },
        .owned_scenes = null,
    };

    // In first scene
    try testing.expectEqual(@as(u16, 0), table.findSceneAtTime(0).?);
    try testing.expectEqual(@as(u16, 0), table.findSceneAtTime(2500).?);
    try testing.expectEqual(@as(u16, 0), table.findSceneAtTime(4999).?);

    // In second scene
    try testing.expectEqual(@as(u16, 1), table.findSceneAtTime(5000).?);
    try testing.expectEqual(@as(u16, 1), table.findSceneAtTime(7500).?);

    // In third scene
    try testing.expectEqual(@as(u16, 2), table.findSceneAtTime(10000).?);
    try testing.expectEqual(@as(u16, 2), table.findSceneAtTime(14999).?);

    // Past end with hold behavior - returns last scene
    try testing.expectEqual(@as(u16, 2), table.findSceneAtTime(15000).?);
    try testing.expectEqual(@as(u16, 2), table.findSceneAtTime(20000).?);
}

test "Scene.durationMs" {
    const scene = Scene{
        .id_string_id = 0,
        .frame_string_id = 0,
        .start_ms = 5000,
        .end_ms = 15000,
    };

    try testing.expectEqual(@as(u32, 10000), scene.durationMs());
}
