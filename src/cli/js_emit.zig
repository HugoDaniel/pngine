//! Primitive JS-text appenders shared by the `--html` codegen.
//!
//! These are the leaves of the emission tree: they turn one scalar (an int, a
//! float, a JSON value, a blob) into the shortest valid JavaScript spelling of
//! it. Everything above them — `js_descriptors.zig` for descriptor blobs,
//! `js_codegen.zig` for the page — composes these.
//!
//! ## Invariants
//!
//! - Output is valid JavaScript in expression position.
//! - Nothing here allocates on its own account: every function appends to the
//!   caller's list with the caller's allocator.
//! - Nothing here recurses. `emitJsonValue` walks nested values with an
//!   explicit stack, because the values come from payload data (§336).

const std = @import("std");

const Out = std.ArrayList(u8);

/// Append an integer in its shortest decimal form.
pub fn appendInt(out: *Out, allocator: std.mem.Allocator, value: anytype) !void {
    var buf: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
    std.debug.assert(s.len > 0); // {d} of any integer is at least one digit
    try out.appendSlice(allocator, s);
}

/// Emit a float in compact JS form: 0.5 → .5, -0.5 → -.5, 1.0 → 1
pub fn appendCompactFloat(out: *Out, allocator: std.mem.Allocator, val: f32) !void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{val}) catch "0";
    std.debug.assert(s.len > 0);
    // Strip leading zero: "0.5" → ".5", "-0.5" → "-.5"
    if (s.len >= 2 and s[0] == '0' and s[1] == '.') {
        try out.appendSlice(allocator, s[1..]);
    } else if (s.len >= 3 and s[0] == '-' and s[1] == '0' and s[2] == '.') {
        try out.append(allocator, '-');
        try out.appendSlice(allocator, s[2..]);
    } else {
        try out.appendSlice(allocator, s);
    }
}

/// Escape WGSL code for use in JS template literals.
/// Also strips leading whitespace and empty lines (WGSL whitespace is not significant).
pub fn appendEscapedWgsl(out: *Out, allocator: std.mem.Allocator, wgsl: []const u8) !void {
    var it = std.mem.splitScalar(u8, wgsl, '\n');
    var first = true;
    while (it.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0) continue; // skip empty/whitespace-only lines
        if (!first) try out.append(allocator, '\n');
        first = false;
        for (trimmed) |ch| {
            switch (ch) {
                '`' => try out.appendSlice(allocator, "\\`"),
                '\\' => try out.appendSlice(allocator, "\\\\"),
                else => try out.append(allocator, ch),
            }
        }
    }
}

/// How deep a JSON value may nest before `emitJsonValue` refuses it.
///
/// Descriptor JSON is machine-written and shallow — the deepest real shape is
/// `{fragment:{targets:[{blend:{color:{…}}}]}}`, five levels. The cap exists
/// for the *other* input: a hand-crafted PNGB whose descriptor blob nests a
/// thousand arrays deep. std.json parses that happily (its own nesting stack is
/// heap-allocated), so the depth guard has to live here.
pub const MAX_JSON_DEPTH = 32;

/// One frame of `emitJsonValue`'s walk: a container and how far into it we are.
const Frame = struct {
    value: std.json.Value,
    /// Next child index to emit (object: entry ordinal, array: item index).
    idx: usize,
};

/// Emit a JSON value as JS.
///
/// Iterative by construction: `value` comes from a payload descriptor blob, and
/// a recursive walker over attacker-supplied nesting is a stack overflow with
/// extra steps (mastery rule 1; CONTRIBUTING pitfall 55). Values deeper than
/// `MAX_JSON_DEPTH` are refused rather than truncated — a silently-shortened
/// descriptor would emit valid JS that means something else.
pub fn emitJsonValue(out: *Out, allocator: std.mem.Allocator, value: std.json.Value) !void {
    var stack: [MAX_JSON_DEPTH]Frame = undefined;
    var depth: usize = 0;

    // `pending` is the value to emit next; scalars finish immediately, while
    // containers push a frame and set `pending` to their first child.
    var pending: ?std.json.Value = value;

    // Bounded: every iteration either consumes a scalar, opens a container, or
    // closes one, and both counts are bounded by the (finite) parsed value.
    for (0..MAX_JSON_NODES) |_| {
        if (pending) |v| {
            pending = null;
            switch (v) {
                .object => {
                    if (depth == MAX_JSON_DEPTH) return error.DescriptorTooDeep;
                    try out.appendSlice(allocator, "{");
                    stack[depth] = .{ .value = v, .idx = 0 };
                    depth += 1;
                },
                .array => {
                    if (depth == MAX_JSON_DEPTH) return error.DescriptorTooDeep;
                    try out.appendSlice(allocator, "[");
                    stack[depth] = .{ .value = v, .idx = 0 };
                    depth += 1;
                },
                else => try appendJsonScalar(out, allocator, v),
            }
            continue;
        }

        if (depth == 0) return; // the root value is fully emitted
        const top = &stack[depth - 1];
        switch (top.value) {
            .object => |obj| {
                if (top.idx == obj.count()) {
                    try out.appendSlice(allocator, "}");
                    depth -= 1;
                    continue;
                }
                if (top.idx > 0) try out.appendSlice(allocator, ",");
                // ObjectMap preserves insertion order, so indexing its keys/values
                // reproduces the iterator order the recursive version emitted.
                try out.appendSlice(allocator, obj.keys()[top.idx]);
                try out.appendSlice(allocator, ":");
                pending = obj.values()[top.idx];
                top.idx += 1;
            },
            .array => |arr| {
                if (top.idx == arr.items.len) {
                    try out.appendSlice(allocator, "]");
                    depth -= 1;
                    continue;
                }
                if (top.idx > 0) try out.appendSlice(allocator, ",");
                pending = arr.items[top.idx];
                top.idx += 1;
            },
            else => unreachable, // only containers are ever pushed
        }
    } else return error.DescriptorTooDeep;
}

/// Upper bound on nodes visited by one `emitJsonValue` call. Descriptor JSON is
/// a few dozen nodes; anything near this is not a descriptor.
const MAX_JSON_NODES = 1 << 16;

/// The non-container arms, split out so the walk above stays a control-flow
/// skeleton with no formatting in it.
fn appendJsonScalar(out: *Out, allocator: std.mem.Allocator, value: std.json.Value) !void {
    switch (value) {
        .integer => |n| {
            var buf: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
            try out.appendSlice(allocator, s);
        },
        .float => |n| {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
            try out.appendSlice(allocator, s);
        },
        .string => |s| {
            try out.appendSlice(allocator, "'");
            try out.appendSlice(allocator, s);
            try out.appendSlice(allocator, "'");
        },
        .bool => |b| try out.appendSlice(allocator, if (b) "!0" else "!1"),
        .null => try out.appendSlice(allocator, "null"),
        .number_string => |s| try out.appendSlice(allocator, s),
        .object, .array => unreachable, // containers are handled by the walk
    }
}

/// Append base64-encoded data.
pub fn base64Append(out: *Out, allocator: std.mem.Allocator, data: []const u8) !void {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const before = out.items.len;

    var i: usize = 0;
    while (i + 2 < data.len) : (i += 3) {
        const n: u32 = @as(u32, data[i]) << 16 | @as(u32, data[i + 1]) << 8 | @as(u32, data[i + 2]);
        try out.append(allocator, alphabet[@intCast((n >> 18) & 63)]);
        try out.append(allocator, alphabet[@intCast((n >> 12) & 63)]);
        try out.append(allocator, alphabet[@intCast((n >> 6) & 63)]);
        try out.append(allocator, alphabet[@intCast(n & 63)]);
    }

    if (i < data.len) {
        var n: u32 = @as(u32, data[i]) << 16;
        if (i + 1 < data.len) n |= @as(u32, data[i + 1]) << 8;
        try out.append(allocator, alphabet[@intCast((n >> 18) & 63)]);
        try out.append(allocator, alphabet[@intCast((n >> 12) & 63)]);
        if (i + 1 < data.len) {
            try out.append(allocator, alphabet[@intCast((n >> 6) & 63)]);
        } else {
            try out.append(allocator, '=');
        }
        try out.append(allocator, '=');
    }

    // Post: base64 is 4 chars per 3 input bytes, padded up.
    std.debug.assert(out.items.len - before == (data.len + 2) / 3 * 4);
}
