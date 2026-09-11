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
//! - **No `bufPrint` here falls back.** Everything these functions format is a
//!   VALUE the page computes with, not a message a human reads, so a degraded
//!   result is a wrong answer wearing the costume of a right one. Buffers are
//!   sized from the type (`decimalLen`) or from a measured bound, and the
//!   format `catch unreachable`s. The `catch "0"` this replaced silently
//!   shipped a literal zero for every float `{d}` needed more than 24
//!   characters for — every magnitude past ~1e23 and every one below ~1e-7
//!   (§440).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Out = std.ArrayList(u8);

/// Characters `{d}` needs for the widest value of an integer type, computed
/// from the type instead of guessed.
///
/// The guess this replaces was `[20]u8` — exactly wide enough for `i64` min and
/// `u64` max, and silently wrong for anything wider. `appendInt` takes
/// `anytype`, so nothing but this function stops a caller passing a `u128`.
fn decimalLen(comptime T: type) comptime_int {
    return @max(
        std.fmt.count("{d}", .{@as(T, std.math.minInt(T))}),
        std.fmt.count("{d}", .{@as(T, std.math.maxInt(T))}),
    );
}

/// Characters `{d}` needs for the widest `f32`: the negative subnormal minimum,
/// `-0.000000000000000000000000000000000000000000001`, is 48. `{d}` prints the
/// full decimal expansion, never scientific notation, so the bound is set by
/// the smallest magnitude rather than the largest. Measured against this
/// standard library (Zig 0.16), not estimated.
const F32_DECIMAL_LEN = 64;

/// The same bound for `f64`, whose subnormal minimum needs 327 characters with
/// its sign. Descriptor floats are author-supplied — `:depth-bias-clamp` and
/// the sampler lod clamps both land here — so this is not hypothetical.
const F64_DECIMAL_LEN = 344;

/// Emit the three values `{d}` spells as bare identifiers JavaScript does not
/// define. Returns true when it emitted one, so the caller skips formatting.
///
/// A payload can legitimately carry any of them — a compute shader writes
/// `inf` — so refusing is wrong; emitting `{d}`'s own `inf`/`nan` is worse,
/// because the exported page then throws `inf is not defined` at load.
fn appendNonFinite(out: *Out, gpa: Allocator, val: anytype) !bool {
    if (std.math.isNan(val)) {
        try out.appendSlice(gpa, "NaN");
        return true;
    }
    if (std.math.isInf(val)) {
        try out.appendSlice(gpa, if (val < 0) "-Infinity" else "Infinity");
        return true;
    }
    return false;
}

/// Append an integer in its shortest decimal form.
///
/// The buffer is sized from the type and the format cannot fail, so there is no
/// fallback: this appends a VALUE the page computes with, and every fallback is
/// a wrong answer. (The previous `catch return` emitted nothing, turning
/// `f(a,b)` into `f(,)` — a syntax error rather than a bad number, but a page
/// that does not parse either way.)
pub fn appendInt(out: *Out, gpa: Allocator, value: anytype) !void {
    var buf: [decimalLen(@TypeOf(value))]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable; // buffer sized from the type
    std.debug.assert(s.len > 0); // {d} of any integer is at least one digit
    try out.appendSlice(gpa, s);
}

/// Emit a float in compact JS form: 0.5 → .5, -0.5 → -.5, 1.0 → 1
///
/// Same rule as `appendInt`: no fallback. The `catch "0"` this replaces turned
/// every value `{d}` needed more than 24 characters for — which is every
/// magnitude past ~1e23 and every one below ~1e-7 — into a literal zero in the
/// exported page, with nothing anywhere saying so.
pub fn appendCompactFloat(out: *Out, gpa: Allocator, val: f32) !void {
    if (try appendNonFinite(out, gpa, val)) return;
    var buf: [F32_DECIMAL_LEN]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{val}) catch unreachable; // 48 chars max, measured
    std.debug.assert(s.len > 0);
    // Strip leading zero: "0.5" → ".5", "-0.5" → "-.5"
    if (s.len >= 2 and s[0] == '0' and s[1] == '.') {
        try out.appendSlice(gpa, s[1..]);
    } else if (s.len >= 3 and s[0] == '-' and s[1] == '0' and s[2] == '.') {
        try out.append(gpa, '-');
        try out.appendSlice(gpa, s[2..]);
    } else {
        try out.appendSlice(gpa, s);
    }
}

/// Escape WGSL code for use in JS template literals.
/// Also strips leading whitespace and empty lines (WGSL whitespace is not significant).
pub fn appendEscapedWgsl(out: *Out, gpa: Allocator, wgsl: []const u8) !void {
    var it = std.mem.splitScalar(u8, wgsl, '\n');
    var first = true;
    while (it.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0) continue; // skip empty/whitespace-only lines
        if (!first) try out.append(gpa, '\n');
        first = false;
        for (trimmed) |ch| {
            switch (ch) {
                '`' => try out.appendSlice(gpa, "\\`"),
                '\\' => try out.appendSlice(gpa, "\\\\"),
                else => try out.append(gpa, ch),
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
pub fn emitJsonValue(out: *Out, gpa: Allocator, value: std.json.Value) !void {
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
                    try out.appendSlice(gpa, "{");
                    stack[depth] = .{ .value = v, .idx = 0 };
                    depth += 1;
                },
                .array => {
                    if (depth == MAX_JSON_DEPTH) return error.DescriptorTooDeep;
                    try out.appendSlice(gpa, "[");
                    stack[depth] = .{ .value = v, .idx = 0 };
                    depth += 1;
                },
                else => try appendJsonScalar(out, gpa, v),
            }
            continue;
        }

        if (depth == 0) return; // the root value is fully emitted
        const top = &stack[depth - 1];
        switch (top.value) {
            .object => |obj| {
                if (top.idx == obj.count()) {
                    try out.appendSlice(gpa, "}");
                    depth -= 1;
                    continue;
                }
                if (top.idx > 0) try out.appendSlice(gpa, ",");
                // ObjectMap preserves insertion order, so indexing its keys/values
                // reproduces the iterator order the recursive version emitted.
                try out.appendSlice(gpa, obj.keys()[top.idx]);
                try out.appendSlice(gpa, ":");
                pending = obj.values()[top.idx];
                top.idx += 1;
            },
            .array => |arr| {
                if (top.idx == arr.items.len) {
                    try out.appendSlice(gpa, "]");
                    depth -= 1;
                    continue;
                }
                if (top.idx > 0) try out.appendSlice(gpa, ",");
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
fn appendJsonScalar(out: *Out, gpa: Allocator, value: std.json.Value) !void {
    switch (value) {
        .integer => |n| try appendInt(out, gpa, n),
        .float => |n| {
            // f64 here, not f32: `depthBiasClamp` and `depthBiasSlopeScale`
            // reach this arm carrying whatever the author wrote.
            if (try appendNonFinite(out, gpa, n)) return;
            var buf: [F64_DECIMAL_LEN]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable; // 327 chars max, measured
            try out.appendSlice(gpa, s);
        },
        .string => |s| {
            try out.appendSlice(gpa, "'");
            try out.appendSlice(gpa, s);
            try out.appendSlice(gpa, "'");
        },
        .bool => |b| try out.appendSlice(gpa, if (b) "!0" else "!1"),
        .null => try out.appendSlice(gpa, "null"),
        .number_string => |s| try out.appendSlice(gpa, s),
        .object, .array => unreachable, // containers are handled by the walk
    }
}

/// Append base64-encoded data.
pub fn base64Append(out: *Out, gpa: Allocator, data: []const u8) !void {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const before = out.items.len;

    var i: usize = 0;
    while (i + 2 < data.len) : (i += 3) {
        const n: u32 = @as(u32, data[i]) << 16 | @as(u32, data[i + 1]) << 8 | @as(u32, data[i + 2]);
        try out.append(gpa, alphabet[@intCast((n >> 18) & 63)]);
        try out.append(gpa, alphabet[@intCast((n >> 12) & 63)]);
        try out.append(gpa, alphabet[@intCast((n >> 6) & 63)]);
        try out.append(gpa, alphabet[@intCast(n & 63)]);
    }

    if (i < data.len) {
        var n: u32 = @as(u32, data[i]) << 16;
        if (i + 1 < data.len) n |= @as(u32, data[i + 1]) << 8;
        try out.append(gpa, alphabet[@intCast((n >> 18) & 63)]);
        try out.append(gpa, alphabet[@intCast((n >> 12) & 63)]);
        if (i + 1 < data.len) {
            try out.append(gpa, alphabet[@intCast((n >> 6) & 63)]);
        } else {
            try out.append(gpa, '=');
        }
        try out.append(gpa, '=');
    }

    // Post: base64 is 4 chars per 3 input bytes, padded up.
    std.debug.assert(out.items.len - before == (data.len + 2) / 3 * 4);
}
