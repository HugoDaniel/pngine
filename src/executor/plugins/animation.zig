//! Animation Plugin
//!
//! Handles scene timeline and transitions for multi-scene animations.
//! Only included when `#animation` is used.
//!
//! ## Purpose
//!
//! The animation plugin enables:
//! - Scene-based timeline with defined start/end times
//! - Automatic scene selection based on current time
//! - Scene-local time computation
//! - Loop and end behavior handling
//!
//! ## How It Works
//!
//! 1. Animation metadata is embedded in the bytecode's animation table
//! 2. Each frame, the plugin determines which scene is active
//! 3. The executor uses the scene's frame definition
//! 4. Scene-local time is computed as: time - scene.start
//!
//! ## Commands
//!
//! Animation doesn't emit GPU commands directly.
//! Instead, it affects which frame bytecode is executed.
//!
//! ## Invariants
//!
//! - Animation table must be present in bytecode
//! - Scene times must not overlap
//! - Each scene must reference a valid frame definition

const std = @import("std");
const assert = std.debug.assert;

// Use bytecode module for animation table access
const bytecode_mod = @import("bytecode");
const AnimationTable = bytecode_mod.AnimationTable;
const AnimationInfo = bytecode_mod.animation_table.AnimationInfo;

/// Scene timing information.
pub const SceneInfo = struct {
    /// Scene ID (index).
    id: u16,
    /// Frame string ID (reference to frame definition name).
    frame_string_id: u16,
    /// Start time in milliseconds.
    start_ms: u32,
    /// End time in milliseconds.
    end_ms: u32,
};

/// Scene time data for shader uniforms.
pub const SceneTimeData = struct {
    /// Time since scene started (seconds).
    scene_time: f32,
    /// Total scene duration (seconds).
    duration: f32,
    /// Normalized time (0.0 to 1.0).
    normalized: f32,
};

/// Animation plugin state.
pub const AnimationPlugin = struct {
    const Self = @This();

    /// Animation table from bytecode.
    table: *const AnimationTable,

    /// Current scene index.
    current_scene: ?u16,

    /// Initialize animation plugin with animation table.
    pub fn init(table: *const AnimationTable) Self {
        return .{
            .table = table,
            .current_scene = null,
        };
    }

    /// Get animation info if present.
    fn getInfo(self: *const Self) ?AnimationInfo {
        return self.table.info;
    }

    /// Get animation duration in milliseconds.
    pub fn getDurationMs(self: *const Self) u32 {
        const info = self.getInfo() orelse return 0;
        return info.duration_ms;
    }

    /// Check if animation loops.
    pub fn loops(self: *const Self) bool {
        const info = self.getInfo() orelse return false;
        return info.loop;
    }

    /// Find the active scene at a given time.
    ///
    /// Args:
    ///   time_ms: Current time in milliseconds
    ///
    /// Returns:
    ///   Scene info if found, null if no scene at this time
    pub fn findScene(self: *Self, time_ms: u32) ?SceneInfo {
        const info = self.getInfo() orelse return null;
        const duration_ms = info.duration_ms;

        const effective_time = if (info.loop and duration_ms > 0)
            time_ms % duration_ms
        else
            time_ms;

        const idx = self.table.findSceneAtTime(effective_time);
        if (idx) |scene_idx| {
            self.current_scene = scene_idx;

            if (self.table.getScene(scene_idx)) |scene| {
                return .{
                    .id = scene_idx,
                    .frame_string_id = scene.frame_string_id,
                    .start_ms = scene.start_ms,
                    .end_ms = scene.end_ms,
                };
            }
        }

        return null;
    }

    /// Get scene time data for the current scene.
    ///
    /// Args:
    ///   global_time_ms: Global animation time in milliseconds
    ///
    /// Returns:
    ///   Scene time data for shader uniforms
    pub fn getSceneTime(self: *const Self, global_time_ms: u32) SceneTimeData {
        const info = self.getInfo() orelse return .{
            .scene_time = 0.0,
            .duration = 0.0,
            .normalized = 0.0,
        };

        if (self.current_scene) |scene_idx| {
            if (self.table.getScene(scene_idx)) |scene| {
                const effective_time = if (info.loop and info.duration_ms > 0)
                    global_time_ms % info.duration_ms
                else
                    global_time_ms;

                const scene_duration = scene.end_ms - scene.start_ms;
                const scene_time_ms = if (effective_time >= scene.start_ms)
                    effective_time - scene.start_ms
                else
                    0;

                const scene_time = @as(f32, @floatFromInt(scene_time_ms)) / 1000.0;
                const duration = @as(f32, @floatFromInt(scene_duration)) / 1000.0;
                const normalized = if (scene_duration > 0)
                    @as(f32, @floatFromInt(scene_time_ms)) / @as(f32, @floatFromInt(scene_duration))
                else
                    0.0;

                return .{
                    .scene_time = scene_time,
                    .duration = duration,
                    .normalized = std.math.clamp(normalized, 0.0, 1.0),
                };
            }
        }

        // No active scene - return defaults
        return .{
            .scene_time = 0.0,
            .duration = 0.0,
            .normalized = 0.0,
        };
    }

    /// Check if animation has ended (for non-looping animations).
    pub fn hasEnded(self: *const Self, time_ms: u32) bool {
        const info = self.getInfo() orelse return true;
        if (info.loop) return false;
        return time_ms >= info.duration_ms;
    }

    /// Check if animation is defined.
    pub fn hasAnimation(self: *const Self) bool {
        return self.table.hasAnimation();
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "AnimationPlugin: empty table" {
    const empty_table = AnimationTable.empty;
    var anim = AnimationPlugin.init(&empty_table);

    try testing.expectEqual(@as(?u16, null), anim.current_scene);
    try testing.expect(!anim.hasAnimation());
    try testing.expectEqual(@as(u32, 0), anim.getDurationMs());

    const scene = anim.findScene(1000);
    try testing.expectEqual(@as(?SceneInfo, null), scene);
}

test "AnimationPlugin: scene time defaults" {
    const empty_table = AnimationTable.empty;
    const anim = AnimationPlugin.init(&empty_table);

    const time_data = anim.getSceneTime(5000);
    try testing.expectEqual(@as(f32, 0.0), time_data.scene_time);
    try testing.expectEqual(@as(f32, 0.0), time_data.duration);
    try testing.expectEqual(@as(f32, 0.0), time_data.normalized);
}

test "AnimationPlugin: has ended with no animation" {
    const empty_table = AnimationTable.empty;
    const anim = AnimationPlugin.init(&empty_table);

    // No animation = always "ended"
    try testing.expect(anim.hasEnded(0));
    try testing.expect(anim.hasEnded(5000));
}
