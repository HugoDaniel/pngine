//! Shared argument-value parsers for the inspect command's deep-mode flags
//! (phase / symptom / size / frame-index list). Consumed by inspect.zig.

const std = @import("std");
const types = @import("types.zig");
const Phase = types.Phase;
const Symptom = types.Symptom;

pub fn parsePhase(s: []const u8) ?Phase {
    if (std.mem.eql(u8, s, "init")) return .init;
    if (std.mem.eql(u8, s, "frame")) return .frame;
    if (std.mem.eql(u8, s, "both")) return .both;
    return null;
}

pub fn parseSymptom(s: []const u8) Symptom {
    if (std.mem.eql(u8, s, "black")) return .black;
    if (std.mem.eql(u8, s, "colors")) return .colors;
    if (std.mem.eql(u8, s, "blend")) return .blend;
    if (std.mem.eql(u8, s, "flicker")) return .flicker;
    if (std.mem.eql(u8, s, "geometry")) return .geometry;
    return .none;
}

pub fn parseSize(s: []const u8) ?[2]u32 {
    const x_pos = std.mem.indexOfAny(u8, s, "xX") orelse return null;
    const width = std.fmt.parseInt(u32, s[0..x_pos], 10) catch return null;
    const height = std.fmt.parseInt(u32, s[x_pos + 1 ..], 10) catch return null;
    if (width == 0 or height == 0) return null;
    return .{ width, height };
}

/// Parse comma-separated frame indices (e.g., "0,1,10,60").
///
/// Complexity: O(n) where n = s.len
///
/// `s` is argv — an empty `--frames ""` or a kilometre-long list is INPUT, so
/// both are `error.InvalidFormat` (they used to be asserts, a Debug panic from
/// the command line).
///
/// Post-condition: Returns owned slice with 1..100 frame indices (caller must free)
pub fn parseFrameIndices(allocator: std.mem.Allocator, s: []const u8) ![]u32 {
    if (s.len == 0 or s.len >= 1000) return error.InvalidFormat;

    // Count commas to estimate capacity (avoids reallocation)
    var comma_count: u32 = 0;
    for (s) |c| {
        if (c == ',') comma_count += 1;
    }

    var indices = try allocator.alloc(u32, comma_count + 1);
    errdefer allocator.free(indices);

    var idx: u32 = 0;
    var start: u32 = 0;

    // Bounded loop: max 100 frame indices to prevent DoS
    for (0..100) |_| {
        var end: u32 = start;
        while (end < s.len and s[end] != ',') : (end += 1) {}

        if (end > start) {
            indices[idx] = std.fmt.parseInt(u32, s[start..end], 10) catch {
                return error.InvalidFormat; // errdefer handles free
            };
            idx += 1;
        }

        if (end >= s.len) break;
        start = end + 1;
    }

    // Post-condition: at least one index parsed
    if (idx == 0) {
        return error.InvalidFormat; // errdefer handles free
    }

    // Shrink to actual size
    if (idx < indices.len) {
        const result = try allocator.realloc(indices, idx);
        // Post-condition: bounded result
        std.debug.assert(result.len > 0 and result.len <= 100);
        return result;
    }

    // Post-condition: bounded result
    std.debug.assert(indices.len > 0 and indices.len <= 100);
    return indices;
}

// ============================================================================
// Tests
// ============================================================================
