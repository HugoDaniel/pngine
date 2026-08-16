//! Compile diagnostics sink for the SJON frontend.
//!
//! Lifted out of `Emitter.zig` because it is the frontend's *published* error
//! type, not emitter internals: `wasm_compiler.zig` (the editor's WASM entry)
//! and `cli/validate.zig` both hold a `Diag` and read nothing else from the
//! emitter, yet importing it dragged in the whole ~5,900-line walk.
//!
//! `Emitter.Diag` and `Compiler.Diag` remain as re-exports, so every existing
//! call site — and the negative-test suite that asserts on domains and entry
//! shapes — is untouched by the move.
//!
//! ## Invariants
//! - Freestanding-safe: fixed capacity, one packed message arena, NO heap. The
//!   editor's WASM build depends on this.
//! - Overflow is surfaced (`dropped`), never a silent cap.

const std = @import("std");

/// Sink for domain-labeled compile diagnostics — two overlaid views:
///
///  1. **First-writer headline** (`.set`/`.message()`/`.domain`). The DEEPEST,
///     most-specific Emitter check that fires first wins this slot. The CLI human
///     output + the WASM `error_buffer` read it so the editor can say "WGSL error
///     in shader 'X': …" instead of the opaque error-class string. A SJON-
///     structural reject is resolved earlier (in `Host.validateDocument`, before
///     the Emitter) and DOES NOT touch this headline — so `.set` stays false for
///     structural rejects, keeping "WGSL ⇒ .wgsl, SJON ⇒ .sjon" honest and the
///     negative-test invariant (`!diag.set` for a schema reject) intact.
///
///  2. **Collect-all list** (`entries`) — every reported diagnostic, structured
///     (severity + optional 1-based line/col + optional code/shader) for the JSON
///     squiggle channel (`writeJson`). Fed by BOTH the Emitter's `report()` (as an
///     UNLOCATED entry — its span lands in R2b) and `addLocated()` (the SJON
///     structural stream, which already carries real spans). Freestanding-safe:
///     fixed capacity, one packed message arena, NO heap. Overflow bumps
///     `dropped` (surfaced, never a silent cap).
///
/// Null on the golden/parity paths (unused there).
pub const Diag = struct {
    // ---- First-writer headline (unchanged public surface) ----
    /// The failing domain. Meaningful only when `set`.
    domain: Domain = .sjon,
    /// Length of the captured headline message in `buf`.
    len: usize = 0,
    /// True once an Emitter check has reported — first (deepest) writer wins.
    set: bool = false,
    /// Inline headline storage — one line is far under 512 bytes; an over-long
    /// message is truncated cleanly (no heap, freestanding-safe).
    buf: [512]u8 = undefined,

    // ---- Collect-all list (R2 diagnostics infrastructure) ----
    entries: [MAX_ENTRIES]Entry = undefined,
    count: u32 = 0,
    arena: [ARENA_BYTES]u8 = undefined,
    arena_len: u32 = 0,
    /// Diagnostics dropped on capacity/arena overflow (surfaced, not silent).
    dropped: u32 = 0,

    pub const Domain = enum { sjon, wgsl };
    pub const Severity = enum { err, warning };
    pub const MAX_ENTRIES = 64;
    pub const ARENA_BYTES = 16 * 1024;

    /// A resolved 1-based source location handed to `reportAt` (the Emitter
    /// cross-validation checks in R2b). `end_line == 0` marks a point diagnostic.
    /// The Emitter's `locate` produces these from a `tree.spanOf` byte span,
    /// rebased into user coordinates; a WGSL-internal check passes shader-relative
    /// line/col directly (paired with a `shader` tag that routes to the WGSL view).
    pub const Located = struct {
        line: u32,
        col: u32,
        end_line: u32 = 0,
        end_col: u32 = 0,
    };

    /// One collected diagnostic. `line == 0` means UNLOCATED — surfaced via the
    /// headline/`error_buffer`, omitted from the JSON squiggle channel (an Emitter
    /// cross-validation message keeps `line == 0` until R2b threads its span). All
    /// text (message/code/shader) is copied into `arena` — the source `[]const u8`
    /// may be borrowed from a to-be-freed validation arena, so it cannot be
    /// referenced later.
    pub const Entry = struct {
        domain: Domain,
        severity: Severity,
        line: u32 = 0, // 1-based; 0 == unlocated
        col: u32 = 0, // 1-based
        end_line: u32 = 0, // 0 == point diagnostic (omit endLine/endColumn)
        end_col: u32 = 0,
        code_off: u32 = 0,
        code_len: u32 = 0, // 0 == absent
        shader_off: u32 = 0,
        shader_len: u32 = 0, // 0 == absent (WGSL module name, routes to WGSL view)
        msg_off: u32 = 0,
        msg_len: u32 = 0,
    };

    pub fn message(self: *const Diag) []const u8 {
        return self.buf[0..self.len];
    }

    /// Copy `s` into the message arena; returns `(off, len)`. Overflow → len 0
    /// (the field reads as absent) — never partial/garbage.
    fn intern(self: *Diag, s: []const u8) struct { off: u32, len: u32 } {
        if (s.len == 0) return .{ .off = 0, .len = 0 };
        if (self.arena_len + s.len > ARENA_BYTES) return .{ .off = 0, .len = 0 };
        const off = self.arena_len;
        @memcpy(self.arena[off..][0..s.len], s);
        self.arena_len += @intCast(s.len);
        return .{ .off = off, .len = @intCast(s.len) };
    }

    fn sliceOf(self: *const Diag, off: u32, len: u32) []const u8 {
        return self.arena[off..][0..len];
    }

    fn append(self: *Diag, e: Entry) void {
        std.debug.assert(self.count <= MAX_ENTRIES);
        if (self.count >= MAX_ENTRIES) {
            self.dropped += 1;
            return;
        }
        self.entries[self.count] = e;
        self.count += 1;
    }

    /// Record a domain-tagged headline message with NO source location — the
    /// unlocated, no-shader special case of `reportAt`. First writer wins the
    /// `.message()` headline; the collect-all entry stays `line == 0` (omitted from
    /// the JSON squiggle channel). Signature unchanged so existing call sites — and
    /// the genuinely-unlocatable check (a used-but-unbound binding has no SJON node)
    /// — compile untouched.
    pub fn report(self: *Diag, domain: Domain, comptime fmt: []const u8, args: anytype) void {
        self.reportAt(domain, null, "", fmt, args);
    }

    /// Record a domain-tagged headline message WITH an optional source location
    /// (the R2b Emitter cross-validation checks). Same first-writer headline as
    /// `report` (the CLI human line + WASM `error_buffer` read `.message()`), plus a
    /// collect-all entry that is LOCATED when `loc` is non-null (→ an editor
    /// squiggle) and carries an optional `shader` tag — a non-empty tag (a WGSL
    /// module name) routes the entry to the editor's WGSL view with shader-relative
    /// line/col; an empty tag squiggles the SJON source at `loc`.
    pub fn reportAt(
        self: *Diag,
        domain: Domain,
        loc: ?Located,
        shader: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        if (loc) |l| {
            std.debug.assert(l.line >= 1);
            std.debug.assert(l.col >= 1);
        }
        var tmp: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, fmt, args) catch "diagnostic message too long";
        // First-writer headline (unchanged semantics — the deepest check wins).
        if (!self.set) {
            @memcpy(self.buf[0..s.len], s);
            self.len = s.len;
            self.domain = domain;
            self.set = true;
        }
        self.collect(domain, .err, loc, shader, s);
    }

    /// Record a WARNING-severity diagnostic (advisory — the uniform-table
    /// collision/drop notes). Appends a collect-all entry only; NEVER touches
    /// the first-writer headline — `.set`/`.buf` are the ERROR channel
    /// (validate.zig prints `message()` only on failure and the WASM
    /// `error_buffer` reads it as the compile error), so a warning must not
    /// claim it. Surfaces via `writeJson` (`"severity":"warning"`) when located,
    /// and via the caller's own rendering otherwise.
    pub fn warnAt(
        self: *Diag,
        domain: Domain,
        loc: ?Located,
        shader: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        if (loc) |l| {
            std.debug.assert(l.line >= 1);
            std.debug.assert(l.col >= 1);
        }
        var tmp: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, fmt, args) catch "diagnostic message too long";
        self.collect(domain, .warning, loc, shader, s);
    }

    /// Shared collect-all append for `reportAt`/`warnAt`: intern the formatted
    /// message + shader tag, entry located iff `loc` is present.
    fn collect(self: *Diag, domain: Domain, severity: Severity, loc: ?Located, shader: []const u8, s: []const u8) void {
        const m = self.intern(s);
        const sh = self.intern(shader);
        var e: Entry = .{
            .domain = domain,
            .severity = severity,
            .shader_off = sh.off,
            .shader_len = sh.len,
            .msg_off = m.off,
            .msg_len = m.len,
        };
        if (loc) |l| {
            e.line = l.line;
            e.col = l.col;
            e.end_line = l.end_line;
            e.end_col = l.end_col;
        }
        self.append(e);
    }

    /// The interned message text of a collect-all `Entry` (structured read surface
    /// for a consumer that walks `entries` directly rather than via `writeJson`).
    pub fn entryMessage(self: *const Diag, e: Entry) []const u8 {
        return self.sliceOf(e.msg_off, e.msg_len);
    }

    /// The interned WGSL-module tag of a collect-all `Entry` (empty when the entry
    /// squiggles the SJON source rather than the WGSL view).
    pub fn entryShader(self: *const Diag, e: Entry) []const u8 {
        return self.sliceOf(e.shader_off, e.shader_len);
    }

    /// The interned diagnostic code of a collect-all `Entry` — the SJON
    /// `Ast.Diagnostic.Code` tag name for a structural entry, empty for an
    /// Emitter-phase one (those carry no code). The read side of what
    /// `writeJson` already emits, for a consumer walking `entries` directly.
    pub fn entryCode(self: *const Diag, e: Entry) []const u8 {
        return self.sliceOf(e.code_off, e.code_len);
    }

    /// Record a LOCATED diagnostic (the SJON structural stream today; the Emitter
    /// checks in R2b). 1-based line/col into the USER source; `end_line == 0` marks
    /// a point diagnostic. Appends to the collect-all list only — does NOT touch
    /// the first-writer headline (structural rejects keep `.set == false`).
    pub fn addLocated(
        self: *Diag,
        domain: Domain,
        severity: Severity,
        line: u32,
        col: u32,
        end_line: u32,
        end_col: u32,
        code: []const u8,
        shader: []const u8,
        msg: []const u8,
    ) void {
        std.debug.assert(line >= 1);
        std.debug.assert(col >= 1);
        const c = self.intern(code);
        const sh = self.intern(shader);
        const m = self.intern(msg);
        self.append(.{
            .domain = domain,
            .severity = severity,
            .line = line,
            .col = col,
            .end_line = end_line,
            .end_col = end_col,
            .code_off = c.off,
            .code_len = c.len,
            .shader_off = sh.off,
            .shader_len = sh.len,
            .msg_off = m.off,
            .msg_len = m.len,
        });
    }

    /// 1-based (line, column) of byte `offset` within `source`. Column counts
    /// UTF-8 bytes from the line start (the editor consumes 1-based line/col and
    /// clamps). Bounded scan; an offset past the end clamps to the final position.
    pub fn lineColOf(source: []const u8, offset: u32) struct { line: u32, col: u32 } {
        var line: u32 = 1;
        var col: u32 = 1;
        const end: u32 = @min(offset, @as(u32, @intCast(source.len)));
        var i: u32 = 0;
        while (i < end) : (i += 1) {
            if (source[i] == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }
        }
        return .{ .line = line, .col = col };
    }

    /// Serialize the LOCATED collect-all entries as an `InputDiagnostic[]` JSON
    /// array — the editor's codemirror-setup.ts shape: 1-based
    /// `{severity, line, column, endLine?, endColumn?, code?, shader?, message}`.
    /// Unlocated entries (`line == 0`) are omitted (they surface via the headline).
    /// Writes into `out`; returns bytes written, never exceeding `out.len`. On tight
    /// space it degrades to a clean empty array (`[]`) rather than truncated
    /// (invalid) JSON — the editor's `JSON.parse` catch also tolerates it.
    pub fn writeJson(self: *const Diag, out: []u8) u32 {
        std.debug.assert(out.len >= 2);
        var w = JsonWriter{ .out = out };
        w.byte('[');
        var first = true;
        var idx: u32 = 0;
        while (idx < self.count) : (idx += 1) {
            const e = self.entries[idx];
            if (e.line == 0) continue; // unlocated → not a squiggle
            if (!first) w.byte(',');
            first = false;
            w.raw("{\"severity\":\"");
            w.raw(if (e.severity == .warning) "warning" else "error");
            w.raw("\",\"line\":");
            w.num(e.line);
            w.raw(",\"column\":");
            w.num(e.col);
            if (e.end_line != 0) {
                w.raw(",\"endLine\":");
                w.num(e.end_line);
                w.raw(",\"endColumn\":");
                w.num(e.end_col);
            }
            if (e.code_len != 0) {
                w.raw(",\"code\":\"");
                w.jsonStr(self.sliceOf(e.code_off, e.code_len));
                w.byte('"');
            }
            if (e.shader_len != 0) {
                w.raw(",\"shader\":\"");
                w.jsonStr(self.sliceOf(e.shader_off, e.shader_len));
                w.byte('"');
            }
            w.raw(",\"message\":\"");
            w.jsonStr(self.sliceOf(e.msg_off, e.msg_len));
            w.raw("\"}");
        }
        w.byte(']');
        if (w.overflowed) {
            out[0] = '[';
            out[1] = ']';
            return 2;
        }
        return w.pos;
    }

    /// Bounded JSON emitter over a fixed `out` buffer. Never writes past `out.len`;
    /// records `overflowed` so `writeJson` can fall back to a valid empty array.
    const JsonWriter = struct {
        out: []u8,
        pos: u32 = 0,
        overflowed: bool = false,

        fn byte(self: *JsonWriter, c: u8) void {
            if (self.pos < self.out.len) {
                self.out[self.pos] = c;
                self.pos += 1;
            } else self.overflowed = true;
        }
        fn raw(self: *JsonWriter, s: []const u8) void {
            for (s) |c| self.byte(c);
        }
        fn num(self: *JsonWriter, n: u32) void {
            var b: [10]u8 = undefined;
            const s = std.fmt.bufPrint(&b, "{d}", .{n}) catch return;
            self.raw(s);
        }
        fn jsonStr(self: *JsonWriter, s: []const u8) void {
            for (s) |c| switch (c) {
                '"' => self.raw("\\\""),
                '\\' => self.raw("\\\\"),
                '\n' => self.raw("\\n"),
                '\r' => self.raw("\\r"),
                '\t' => self.raw("\\t"),
                else => if (c < 0x20) {
                    var b: [8]u8 = undefined;
                    const esc = std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch return;
                    self.raw(esc);
                } else self.byte(c),
            };
        }
    };
};
