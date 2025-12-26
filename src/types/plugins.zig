//! Plugin Types
//!
//! Plugin flags and enums for the PNGB format.
//! Zero external dependencies.

const std = @import("std");

/// Plugin feature flags packed into a single byte.
/// Used in PNGB header to indicate required runtime features.
pub const PluginSet = packed struct(u8) {
    /// Core plugin (always included): bytecode parsing, command emission.
    core: bool = true,
    /// Render plugin: render pipelines, render passes, draw commands.
    render: bool = false,
    /// Compute plugin: compute pipelines, dispatch commands.
    compute: bool = false,
    /// WASM-in-WASM plugin: nested WASM execution for physics engines, etc.
    wasm: bool = false,
    /// Animation plugin: scene table, timeline, transitions.
    animation: bool = false,
    /// Texture plugin: image/video texture loading.
    texture: bool = false,
    /// Reserved for future use.
    reserved: u2 = 0,

    /// Create empty plugin set (core only).
    pub const core_only: PluginSet = .{};

    /// Create full plugin set (all features).
    pub const full: PluginSet = .{
        .render = true,
        .compute = true,
        .wasm = true,
        .animation = true,
        .texture = true,
    };

    /// Convert to u8 for serialization.
    pub fn toU8(self: PluginSet) u8 {
        return @bitCast(self);
    }

    /// Create from u8 (deserialization).
    pub fn fromU8(value: u8) PluginSet {
        return @bitCast(value);
    }

    /// Check if a specific plugin is enabled.
    pub fn has(self: PluginSet, plugin: Plugin) bool {
        return switch (plugin) {
            .core => self.core,
            .render => self.render,
            .compute => self.compute,
            .wasm => self.wasm,
            .animation => self.animation,
            .texture => self.texture,
        };
    }

    /// Alias for has() - used by format.zig tests.
    pub const hasPlugin = has;

    /// Enable a specific plugin.
    pub fn enable(self: *PluginSet, plugin: Plugin) void {
        switch (plugin) {
            .core => self.core = true,
            .render => self.render = true,
            .compute => self.compute = true,
            .wasm => self.wasm = true,
            .animation => self.animation = true,
            .texture => self.texture = true,
        }
    }
};

/// Individual plugin identifier.
pub const Plugin = enum(u3) {
    core = 0,
    render = 1,
    compute = 2,
    wasm = 3,
    animation = 4,
    texture = 5,
};

// ============================================================================
// Tests
// ============================================================================

test "PluginSet core_only" {
    const ps = PluginSet.core_only;
    try std.testing.expect(ps.core);
    try std.testing.expect(!ps.render);
    try std.testing.expect(!ps.compute);
}

test "PluginSet full" {
    const ps = PluginSet.full;
    try std.testing.expect(ps.core);
    try std.testing.expect(ps.render);
    try std.testing.expect(ps.compute);
    try std.testing.expect(ps.wasm);
    try std.testing.expect(ps.animation);
    try std.testing.expect(ps.texture);
}

test "PluginSet serialization roundtrip" {
    const original = PluginSet{ .render = true, .compute = true };
    const serialized = original.toU8();
    const restored = PluginSet.fromU8(serialized);
    try std.testing.expectEqual(original, restored);
}

test "PluginSet.has" {
    const ps = PluginSet{ .render = true, .wasm = true };
    try std.testing.expect(ps.has(.core));
    try std.testing.expect(ps.has(.render));
    try std.testing.expect(!ps.has(.compute));
    try std.testing.expect(ps.has(.wasm));
}
