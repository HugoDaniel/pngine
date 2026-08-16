//! RGBA8 pixel-buffer comparator.
//!
//! A Zig port of the Swift `SnapshotComparator` that shipped with the iOS
//! bindings (`native/ios/PngineKit/`, removed in the 2026-08 lean sweep —
//! `git log -- native/ios` for the source). Kept faithful to that algorithm:
//! it is now the single tolerance model behind native `--frame` snapshots and
//! `pngine diff`, and it stays portable back if the bindings return.
//!
//! ## Model
//! A pixel "matches" when all four channels are within `max_pixel_difference`
//! (absolute per-channel delta). The overall compare passes when the fraction
//! of matching pixels is at least `precision`. GPU output varies slightly
//! across drivers/devices, so exact equality is deliberately NOT the bar.

const std = @import("std");
const assert = std.debug.assert;

/// Tolerance configuration. Presets mirror the Swift ones one-for-one.
pub const Config = struct {
    /// Fraction of pixels that must match, 0..1.
    precision: f32 = 0.985,
    /// Maximum allowed per-channel absolute difference (0..255). A channel delta
    /// STRICTLY greater than this makes the whole pixel count as differing.
    max_pixel_difference: u8 = 5,

    /// Default — tolerates minor GPU differences.
    pub const default: Config = .{};
    /// Near-exact — for output that should barely move across devices.
    pub const high_precision: Config = .{ .precision = 0.99, .max_pixel_difference = 2 };
    /// Loose — for compute shaders with floating-point variance.
    pub const compute_tolerant: Config = .{ .precision = 0.95, .max_pixel_difference = 10 };
};

/// Outcome of a comparison, with enough detail to make a failure legible.
pub const Result = struct {
    passed: bool,
    /// Fraction of pixels that matched, 0..1.
    match_percentage: f32,
    differing_pixel_count: u32,
    total_pixel_count: u32,
    /// Largest per-channel absolute difference seen anywhere, 0..255.
    max_difference: u8,
};

/// Compare two RGBA8 buffers under `config`.
///
/// A size mismatch (different lengths, empty, or not a whole number of RGBA
/// pixels) is a hard fail — match 0, every pixel differing, max_difference 255 —
/// rather than a crash, so a wrong-sized render fails the test loudly.
///
/// Pre-condition: buffers are RGBA8 (`len % 4 == 0`) — enforced, not assumed.
/// Post-condition: `match_percentage` is in [0, 1].
pub fn compare(actual: []const u8, expected: []const u8, config: Config) Result {
    if (actual.len != expected.len or actual.len == 0 or actual.len % 4 != 0) {
        const total: u32 = @intCast(@max(actual.len, expected.len) / 4);
        return .{
            .passed = false,
            .match_percentage = 0,
            .differing_pixel_count = total,
            .total_pixel_count = total,
            .max_difference = 255,
        };
    }

    const total_pixels: u32 = @intCast(actual.len / 4);
    assert(total_pixels > 0);
    assert(actual.len == expected.len);

    var differing: u32 = 0;
    var max_diff: u8 = 0;

    for (0..total_pixels) |i| {
        const base = i * 4;
        var pixel_differs = false;
        for (0..4) |ch| {
            const idx = base + ch;
            const d: i16 = @as(i16, actual[idx]) - @as(i16, expected[idx]);
            const ad: u8 = @intCast(@abs(d)); // 0..255, fits u8
            if (ad > config.max_pixel_difference) pixel_differs = true;
            if (ad > max_diff) max_diff = ad;
        }
        if (pixel_differs) differing += 1;
    }

    const matched: f32 = @floatFromInt(total_pixels - differing);
    const match_percentage: f32 = matched / @as(f32, @floatFromInt(total_pixels));

    // Post-condition
    assert(match_percentage >= 0.0 and match_percentage <= 1.0);
    return .{
        .passed = match_percentage >= config.precision,
        .match_percentage = match_percentage,
        .differing_pixel_count = differing,
        .total_pixel_count = total_pixels,
        .max_difference = max_diff,
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
