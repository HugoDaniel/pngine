//! WGSL Entry Point Scanner
//!
//! Scans WGSL source code for entry point annotations without full parsing.
//! Extracts @fragment and @compute entry points with workgroup sizes.
//!
//! ## Design
//!
//! Uses simple pattern matching on WGSL annotations:
//! - `@fragment fn NAME(` → fragment entry point
//! - `@compute @workgroup_size(X[,Y[,Z]]) fn NAME(` → compute entry point
//!
//! No full WGSL parser — just annotation scanning (same approach as compute.toys).
//!
//! ## Invariants
//!
//! - Scan is O(n) where n = source length
//! - Entry points are returned in source order
//! - Workgroup sizes default to 1 for omitted dimensions
//! - Maximum 16 entry points per scan

const std = @import("std");

/// Maximum entry points to extract from a single code block.
const MAX_ENTRY_POINTS: u32 = 16;

/// Entry point type detected from WGSL annotations.
pub const EntryPointType = enum {
    fragment,
    compute,
};

/// Extracted entry point information.
pub const EntryPoint = struct {
    /// Function name (e.g., "main_image", "physics", "seed").
    name: []const u8,
    /// Whether this is a fragment or compute entry point.
    type: EntryPointType,
    /// Workgroup size for compute shaders [X, Y, Z].
    /// Defaults to [1, 1, 1]. Only meaningful for compute.
    workgroup_size: [3]u32,
};

/// Scan result from WGSL source analysis.
pub const ScanResult = struct {
    /// Extracted entry points in source order.
    entries: [MAX_ENTRY_POINTS]EntryPoint,
    /// Number of valid entries.
    count: u32,
    /// Whether any @fragment entry points were found.
    has_fragment: bool,
    /// Whether any @compute entry points were found.
    has_compute: bool,

    pub fn slice(self: *const ScanResult) []const EntryPoint {
        return self.entries[0..self.count];
    }
};

/// Scan WGSL source for entry point annotations.
///
/// Returns extracted entry points in source order.
/// Does not allocate — uses fixed-size result buffer.
///
/// Complexity: O(n) where n = source.len
pub fn scanEntryPoints(source: []const u8) ScanResult {
    var result = ScanResult{
        .entries = undefined,
        .count = 0,
        .has_fragment = false,
        .has_compute = false,
    };

    var i: u32 = 0;
    const len: u32 = @intCast(source.len);

    while (i < len) {
        if (result.count >= MAX_ENTRY_POINTS) break;

        // Look for '@' character
        if (source[i] != '@') {
            i += 1;
            continue;
        }

        // Try @fragment
        if (matchAt(source, i, "@fragment")) {
            const after_attr = i + @as(u32, @intCast("@fragment".len));
            if (findFnName(source, after_attr)) |name| {
                result.entries[result.count] = .{
                    .name = name,
                    .type = .fragment,
                    .workgroup_size = .{ 1, 1, 1 },
                };
                result.count += 1;
                result.has_fragment = true;
            }
            i = after_attr;
            continue;
        }

        // Try @compute
        if (matchAt(source, i, "@compute")) {
            const after_compute = i + @as(u32, @intCast("@compute".len));
            // Look for @workgroup_size after @compute
            const wg_pos = findNextAnnotation(source, after_compute, "@workgroup_size(");
            if (wg_pos) |wg_start| {
                const wg_args_start = wg_start + @as(u32, @intCast("@workgroup_size(".len));
                const wg_size = parseWorkgroupSize(source, wg_args_start);
                // Find the fn name after workgroup_size
                const after_wg = findCloseParen(source, wg_args_start);
                if (after_wg) |after| {
                    if (findFnName(source, after)) |name| {
                        result.entries[result.count] = .{
                            .name = name,
                            .type = .compute,
                            .workgroup_size = wg_size,
                        };
                        result.count += 1;
                        result.has_compute = true;
                    }
                }
                i = wg_args_start;
            } else {
                i = after_compute;
            }
            continue;
        }

        i += 1;
    }

    return result;
}

/// Check if `pattern` matches at position `pos` in `source`.
fn matchAt(source: []const u8, pos: u32, pattern: []const u8) bool {
    const end = pos + @as(u32, @intCast(pattern.len));
    if (end > source.len) return false;
    return std.mem.eql(u8, source[pos..end], pattern);
}

/// Find the next occurrence of `pattern` starting from `start`,
/// skipping whitespace. Returns position of pattern start, or null.
fn findNextAnnotation(source: []const u8, start: u32, pattern: []const u8) ?u32 {
    var i = start;
    const len: u32 = @intCast(source.len);
    // Skip whitespace, then look for pattern
    while (i < len and isWhitespace(source[i])) : (i += 1) {}
    if (matchAt(source, i, pattern)) return i;
    return null;
}

/// Find 'fn NAME(' pattern starting from `start`, skipping whitespace/annotations.
/// Returns the function name slice, or null.
fn findFnName(source: []const u8, start: u32) ?[]const u8 {
    var i = start;
    const len: u32 = @intCast(source.len);

    // Skip whitespace and additional annotations (like @workgroup_size)
    var skip_count: u32 = 0;
    while (i < len and skip_count < 256) : (skip_count += 1) {
        // Skip whitespace
        while (i < len and isWhitespace(source[i])) : (i += 1) {}

        // Skip annotations we don't care about
        if (i < len and source[i] == '@') {
            // Skip past the annotation
            i += 1;
            while (i < len and (isIdentChar(source[i]) or source[i] == '(')) {
                if (source[i] == '(') {
                    // Skip past balanced parens
                    i = findCloseParen(source, i + 1) orelse return null;
                    break;
                }
                i += 1;
            }
            continue;
        }

        // Look for 'fn'
        if (matchAt(source, i, "fn") and i + 2 < len and isWhitespace(source[i + 2])) {
            i += 2;
            // Skip whitespace after 'fn'
            while (i < len and isWhitespace(source[i])) : (i += 1) {}
            // Extract name
            const name_start = i;
            while (i < len and isIdentChar(source[i])) : (i += 1) {}
            if (i > name_start) {
                return source[name_start..i];
            }
            return null;
        }

        break;
    }

    return null;
}

/// Parse workgroup_size(X[,Y[,Z]]) arguments.
/// `start` points to first char after opening '('.
fn parseWorkgroupSize(source: []const u8, start: u32) [3]u32 {
    var size: [3]u32 = .{ 1, 1, 1 };
    var i = start;
    const len: u32 = @intCast(source.len);
    var dim: u32 = 0;

    while (i < len and dim < 3) {
        // Skip whitespace
        while (i < len and isWhitespace(source[i])) : (i += 1) {}

        if (i >= len or source[i] == ')') break;

        // Parse number
        const num_start = i;
        while (i < len and isDigit(source[i])) : (i += 1) {}
        if (i > num_start) {
            size[dim] = std.fmt.parseInt(u32, source[num_start..i], 10) catch 1;
            dim += 1;
        }

        // Skip whitespace and comma
        while (i < len and (isWhitespace(source[i]) or source[i] == ',')) : (i += 1) {}
    }

    return size;
}

/// Find the position after the matching close paren.
/// `start` points to first char after opening '('.
fn findCloseParen(source: []const u8, start: u32) ?u32 {
    var i = start;
    const len: u32 = @intCast(source.len);
    var depth: u32 = 1;

    while (i < len and depth > 0) {
        if (source[i] == '(') depth += 1;
        if (source[i] == ')') depth -= 1;
        i += 1;
    }

    return if (depth == 0) i else null;
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

// ============================================================================
// Tests
// ============================================================================

test "scanEntryPoints: single fragment" {
    const source =
        \\@fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
        \\  return vec4f(1, 0, 0, 1);
        \\}
    ;
    const result = scanEntryPoints(source);
    try std.testing.expectEqual(@as(u32, 1), result.count);
    try std.testing.expect(result.has_fragment);
    try std.testing.expect(!result.has_compute);
    try std.testing.expectEqualStrings("fs", result.entries[0].name);
    try std.testing.expectEqual(EntryPointType.fragment, result.entries[0].type);
}

test "scanEntryPoints: single compute" {
    const source =
        \\@compute @workgroup_size(16, 16)
        \\fn main_image(@builtin(global_invocation_id) id: vec3u) {
        \\  // ...
        \\}
    ;
    const result = scanEntryPoints(source);
    try std.testing.expectEqual(@as(u32, 1), result.count);
    try std.testing.expect(!result.has_fragment);
    try std.testing.expect(result.has_compute);
    try std.testing.expectEqualStrings("main_image", result.entries[0].name);
    try std.testing.expectEqual(EntryPointType.compute, result.entries[0].type);
    try std.testing.expectEqual(@as(u32, 16), result.entries[0].workgroup_size[0]);
    try std.testing.expectEqual(@as(u32, 16), result.entries[0].workgroup_size[1]);
    try std.testing.expectEqual(@as(u32, 1), result.entries[0].workgroup_size[2]);
}

test "scanEntryPoints: multiple compute entry points" {
    const source =
        \\@compute @workgroup_size(64)
        \\fn physics(@builtin(global_invocation_id) id: vec3u) { }
        \\
        \\@compute @workgroup_size(16, 16)
        \\fn render(@builtin(global_invocation_id) id: vec3u) { }
    ;
    const result = scanEntryPoints(source);
    try std.testing.expectEqual(@as(u32, 2), result.count);
    try std.testing.expectEqualStrings("physics", result.entries[0].name);
    try std.testing.expectEqual([3]u32{ 64, 1, 1 }, result.entries[0].workgroup_size);
    try std.testing.expectEqualStrings("render", result.entries[1].name);
    try std.testing.expectEqual([3]u32{ 16, 16, 1 }, result.entries[1].workgroup_size);
}

test "scanEntryPoints: workgroup_size with 3 dims" {
    const source =
        \\@compute @workgroup_size(4, 4, 4)
        \\fn volume(@builtin(global_invocation_id) id: vec3u) { }
    ;
    const result = scanEntryPoints(source);
    try std.testing.expectEqual(@as(u32, 1), result.count);
    try std.testing.expectEqual([3]u32{ 4, 4, 4 }, result.entries[0].workgroup_size);
}

test "scanEntryPoints: empty source" {
    const result = scanEntryPoints("");
    try std.testing.expectEqual(@as(u32, 0), result.count);
    try std.testing.expect(!result.has_fragment);
    try std.testing.expect(!result.has_compute);
}

test "scanEntryPoints: no entry points" {
    const source =
        \\fn helper(x: f32) -> f32 { return x * 2.0; }
    ;
    const result = scanEntryPoints(source);
    try std.testing.expectEqual(@as(u32, 0), result.count);
}
