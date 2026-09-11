//! The WGSL preprocessor's pure half: a fragment table, an assembler, and a
//! line table that maps assembled text back to what the author wrote.
//!
//! A **fragment** is `(wgsl :name … :code|:file …)`: named WGSL that is not a
//! GPU object. A **root** is a `(shader-module …)` or a `(pass …)`, which owns
//! entry points and bindings. An **assembled module** is the root's transitive
//! imports in dependency order, each exactly once, followed by the root's own
//! text — and it is the only thing wgslender ever sees, minifies or ships.
//!
//! ## Design
//!
//! - **Assembly is concatenation, plus a directive hoist.** WGSL does not care
//!   what order module-scope *declarations* appear in, so the assembled text is
//!   one unit and a fragment may call something a sibling or the root declares.
//!   The holes that make one library serve several variants come free from
//!   that; nothing here implements them. Directives are the exception that
//!   sentence does not cover: `enable`, `requires` and module-scope
//!   `diagnostic` must precede every declaration in the module, so each part's
//!   leading directives are lifted to the assembled text's first lines and
//!   blanked where they were written. Without that, a root opening with
//!   `enable` could not import at all (CONTRIBUTING pitfall 104).
//! - **The hoist also serves text that never reaches `assemble`.** `(pass …)`
//!   composes a generated prelude with the author's code in `hooks.zig`, and
//!   that prelude always declares something, so a pass could not enable
//!   anything either. `appendHoistingDirectives` / `prependDirectivesOf` are
//!   the same scan, blanking and deduplication applied to a buffer that
//!   already holds generated text — pitfall 104's other half.
//! - **The line table carries LINES, never byte offsets.** Two rewrites run
//!   between assembly and validation — math-constant substitution and
//!   `(constant …)` specialisation — and both are line-preserving but neither
//!   is length-preserving. A line number survives them; a byte offset does not.
//!   (`analyzeModule` then minifies, which preserves neither, so a reflected
//!   span describes the minified text and must never be mapped through here.)
//! - **A root with no imports allocates nothing.** Its assembled text is its
//!   own slice. That is what keeps every existing golden byte-identical and
//!   every existing OOM window unchanged, and there is a test that asserts it
//!   with a `FailingAllocator` that fails on its first request.
//!
//! ## Invariants
//!
//! - The import graph is acyclic; `assemble` reports the cycle path rather than
//!   looping.
//! - Each fragment contributes its text exactly once per assembled module,
//!   however many paths reach it.
//! - Every fragment's text is newline-terminated in the output, so a line of
//!   assembled text belongs to exactly one line-table row.
//! - The hoist is line- and column-preserving inside each part: a directive is
//!   overwritten with spaces, never deleted, so every other position in that
//!   part is exactly where it was.
//! - No recursion: the walk is an explicit stack with a bounded loop.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Fragments per document. Matches `MAX_WGSL_MODULES` so every loop over the
/// table is bounded by a number the payload already lives under.
pub const MAX_FRAGMENTS: u32 = 1024;

/// Imports per form. `MAX_WGSL_DEPS` in `bytecode/format.zig`, and the schema's
/// `wgsl-ref-list` bound, so the three cannot drift.
pub const MAX_IMPORTS: u32 = 64;

/// Depth of the assembly walk. The legacy `#wgsl` emitter used the same number
/// for the same reason: a chain longer than this is a document problem.
pub const MAX_DEPTH: u32 = 64;

/// Module-scope directives hoisted into one assembled module. WGSL has three
/// (`enable`, `requires`, `diagnostic`) and a module needs a handful at most;
/// the bound is what makes the hoist's scan a bounded loop.
pub const MAX_DIRECTIVES: u32 = 64;

pub const Error = error{
    /// The import graph has a cycle. `cyclePath` names it.
    ImportCycle,
    /// An `:imports` entry names no fragment. The validator normally catches
    /// this as `not_cross_ref`; the assembler refuses it again because it is
    /// also reachable from a lowered form, where no cross-ref check ran.
    UnknownFragment,
    /// More than `MAX_DEPTH` levels, or more than `MAX_FRAGMENTS` in one
    /// assembled module.
    TooDeep,
    OutOfMemory,
};

/// Where a piece of assembled text came from, for diagnostics. A wgslender
/// `line:col` on the assembled module is mapped back to one of these.
pub const Origin = union(enum) {
    /// Inline text: the root's own `:code`, or a `(wgsl … :code …)`.
    /// `name` is the form's `:name`, which is what the diagnostic's `shader`
    /// tag carries so the editor can find the region.
    inline_code: []const u8,
    /// A `:file`. There is no document position for the text, so the path goes
    /// in the message and the diagnostic's location points at the `:file` value
    /// of the form that named it.
    file: []const u8,

    pub fn name(self: Origin) []const u8 {
        return switch (self) {
            .inline_code => |n| n,
            .file => |p| p,
        };
    }

    pub fn isFile(self: Origin) bool {
        return self == .file;
    }
};

/// One fragment, as collected from the document.
pub const Fragment = struct {
    name: []const u8,
    /// The WGSL. Borrowed from the tree for `:code`, owned for `:file`.
    text: []const u8,
    /// True when `text` was read from a file and this table must free it.
    owns_text: bool,
    origin: Origin,
    /// `:imports`, by name. Borrowed from the tree.
    imports: []const []const u8,
    /// `:requires`, by name — the holes this fragment leaves for its importer.
    /// Borrowed from the tree.
    requires: []const []const u8,
    /// Set once per compile when a diagnostic has been attributed to this
    /// fragment. A broken fragment imported by N roots would otherwise spend N
    /// of `Diag`'s 64 entries saying the same thing; the sink does not
    /// deduplicate and `reportShaderError` reports one error per module.
    reported: bool = false,
    /// Set when any root imports it. Drives the "never imported" advisory.
    imported: bool = false,
    /// How many `@group`/`@binding` variables this fragment declares, from
    /// reflecting it ALONE at collect time. Zero for almost every fragment;
    /// non-zero is legal under a `(shader-module …)` root, whose bind groups
    /// the author writes, and refused under a `(pass …)` root, whose prelude
    /// numbers group 0 itself (R12).
    binding_count: u32 = 0,
};

/// One row of the assembled text: which origin wrote lines
/// `[first_line, first_line + line_count)`.
pub const LineRow = struct {
    origin: Origin,
    /// The fragment's or root's own name, for the diagnostic's `shader` tag.
    name: []const u8,
    /// 1-based, in the assembled text.
    first_line: u32,
    line_count: u32,
    /// The line, in the origin's OWN text, that `first_line` came from. A part
    /// contributes its lines in order from its first, so it is 1 there and the
    /// field costs nothing. A hoisted directive sets it to the line the author
    /// wrote the directive on, which is the whole reason the field exists: the
    /// hoist block sits at the top of the assembled text but its lines belong
    /// to whatever part they were lifted out of, at whatever line they held
    /// there.
    src_line: u32 = 1,
    /// True for the row holding the ROOT module's own text (its `:code`, its
    /// `:file`, or a directive hoisted out of it). Recorded here rather than
    /// re-derived by the reader, because the only signals a reader has are the
    /// name and the origin: a `:file`-backed root is a `.file` origin exactly
    /// like a `:file` fragment, and the "is this the root?" test in
    /// `Emitter.zig` used to answer NO for one — which suppressed the root's own
    /// `W0001`/`W0002` findings as if they were a library's (§438).
    is_root: bool = false,
};

/// An assembled module: the text wgslender sees, and how to get back from it.
pub const Assembled = struct {
    text: []const u8,
    /// True when `text` was built here and the caller must free it. False for
    /// the no-imports fast path, where `text` is the root's own slice.
    owned: bool,
    /// One row per contributing fragment, then the root. Empty on the fast
    /// path: with one origin there is nothing to disambiguate, and `locate`
    /// answers with the root.
    rows: []const LineRow,
    /// The root's own name and origin, so `locate` can answer on the fast path
    /// without a row.
    root_name: []const u8,
    root_origin: Origin,

    pub fn deinit(self: *Assembled, gpa: Allocator) void {
        if (self.owned) gpa.free(@constCast(self.text));
        if (self.rows.len > 0) gpa.free(@constCast(self.rows));
        self.* = undefined;
    }

    /// Map a 1-based line of the assembled text back to its origin and the
    /// line number local to that origin's own text.
    ///
    /// Complexity: O(rows), bounded by `MAX_FRAGMENTS + 1`.
    pub fn locate(self: Assembled, line: u32) struct { origin: Origin, name: []const u8, line: u32, is_root: bool } {
        std.debug.assert(line >= 1);
        if (self.rows.len == 0) {
            // No rows means nothing was assembled: the text IS the root's own.
            return .{ .origin = self.root_origin, .name = self.root_name, .line = line, .is_root = true };
        }
        for (self.rows) |row| {
            if (line < row.first_line) continue;
            if (line >= row.first_line + row.line_count) continue;
            return .{ .origin = row.origin, .name = row.name, .line = line - row.first_line + row.src_line, .is_root = row.is_root };
        }
        // Past the end: a diagnostic on the line after the last one (wgslender
        // reports an unterminated block there). Attribute it to the root, which
        // is where the text ran out.
        const last = self.rows[self.rows.len - 1];
        return .{ .origin = last.origin, .name = last.name, .line = line - last.first_line + last.src_line, .is_root = last.is_root };
    }
};

/// The document's fragments, by name.
pub const Table = struct {
    items: std.ArrayList(Fragment) = .empty,

    pub fn deinit(self: *Table, gpa: Allocator) void {
        for (self.items.items) |f| {
            if (f.owns_text) gpa.free(@constCast(f.text));
        }
        self.items.deinit(gpa);
        self.* = undefined;
    }

    pub fn add(self: *Table, gpa: Allocator, f: Fragment) Error!void {
        std.debug.assert(f.name.len > 0);
        if (self.items.items.len >= MAX_FRAGMENTS) return error.TooDeep;
        self.items.append(gpa, f) catch return error.OutOfMemory;
    }

    /// Bounded linear scan. A document has a handful of fragments; a map would
    /// cost an allocation to save nothing.
    pub fn find(self: *const Table, name: []const u8) ?*Fragment {
        std.debug.assert(name.len > 0);
        for (self.items.items) |*f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }

    pub fn len(self: *const Table) usize {
        return self.items.items.len;
    }
};

/// Names of the fragments on the walk's current path when a cycle was found,
/// filled by `assemble` on `error.ImportCycle`. A caller formats it as
/// `mesh → material → mesh`.
pub const CyclePath = struct {
    pub const MAX = MAX_DEPTH + 1;
    names: [MAX][]const u8 = undefined,
    len: u32 = 0,

    pub fn slice(self: *const CyclePath) []const []const u8 {
        return self.names[0..self.len];
    }
};

/// Build the assembled module for one root.
///
/// `root_imports` is the root's `:imports`; `root_text` its own WGSL. The
/// output is the imports' text in **post-order** (a fragment's own imports
/// before itself), each fragment once, then the root's text last.
///
/// Post-order is not required by WGSL — declaration order does not matter — but
/// it is what makes the assembled text readable, matches what the pre-SJON
/// `#wgsl` emitter did, and gives a stable byte-for-byte output that goldens
/// can pin.
///
/// On `error.ImportCycle`, `cycle` (when non-null) holds the path.
///
/// Complexity: O(fragments reached × MAX_IMPORTS). No recursion.
pub fn assemble(
    gpa: Allocator,
    table: *Table,
    root_name: []const u8,
    root_origin: Origin,
    root_text: []const u8,
    root_imports: []const []const u8,
    cycle: ?*CyclePath,
) Error!Assembled {
    std.debug.assert(root_name.len > 0);
    std.debug.assert(root_imports.len <= MAX_IMPORTS);

    // THE FAST PATH. A root with no imports is its own assembled module, with
    // no allocation and no line table — which is every document that existed
    // before this feature, so their goldens and OOM windows cannot move.
    if (root_imports.len == 0) {
        return .{
            .text = root_text,
            .owned = false,
            .rows = &.{},
            .root_name = root_name,
            .root_origin = root_origin,
        };
    }

    var order: std.ArrayList(*Fragment) = .empty;
    defer order.deinit(gpa);
    try postOrder(gpa, table, root_imports, &order, cycle);

    // THE DIRECTIVE HOIST. WGSL wants `enable`, `requires` and module-scope
    // `diagnostic` before every declaration in the module, and assembly puts
    // other parts' declarations above each part's own text. Without this pass a
    // root that opens with a directive could not import anything at all, and
    // neither could any fragment that was not first in post-order: the
    // directive would land below a declaration and naga would refuse the
    // module. So each part's leading directives are lifted to the assembled
    // text's first lines and blanked where they were written.
    var hoisted: std.ArrayList(Directive) = .empty;
    defer hoisted.deinit(gpa);
    for (order.items, 0..) |f, pi| try scanDirectives(gpa, f.text, @intCast(pi), &hoisted);
    try scanDirectives(gpa, root_text, @intCast(order.items.len), &hoisted);

    // Size the output: each fragment's text plus a newline it may not end with,
    // then the root's, then the hoist block. Blanking is length-preserving, so
    // a part still costs exactly its own bytes.
    var size: usize = root_text.len;
    for (order.items) |f| size += f.text.len + 1;
    for (hoisted.items) |d| {
        if (d.first) size += d.text.len + 1;
    }

    var out = std.ArrayList(u8).initCapacity(gpa, size) catch return error.OutOfMemory;
    errdefer out.deinit(gpa);
    var rows = std.ArrayList(LineRow).initCapacity(
        gpa,
        order.items.len + 1 + hoisted.items.len,
    ) catch return error.OutOfMemory;
    errdefer rows.deinit(gpa);

    var line: u32 = 1;

    // The hoist block, in the order the parts were walked. WGSL lets the three
    // directive kinds interleave, so nothing is sorted: what the author wrote
    // is what ships, minus the repeats.
    for (hoisted.items) |d| {
        if (!d.first) continue;
        const is_root = d.part == order.items.len;
        out.appendSlice(gpa, d.text) catch return error.OutOfMemory;
        out.append(gpa, '\n') catch return error.OutOfMemory;
        rows.append(gpa, .{
            .origin = if (is_root) root_origin else order.items[d.part].origin,
            .name = if (is_root) root_name else order.items[d.part].name,
            .first_line = line,
            .line_count = d.lines,
            .src_line = d.line,
            .is_root = is_root,
        }) catch return error.OutOfMemory;
        line += d.lines;
    }

    for (order.items, 0..) |f, pi| {
        const n = appendTerminated(gpa, &out, f.text, hoisted.items, @intCast(pi)) catch return error.OutOfMemory;
        rows.append(gpa, .{
            .origin = f.origin,
            .name = f.name,
            .first_line = line,
            .line_count = n,
        }) catch return error.OutOfMemory;
        line += n;
    }
    const root_lines = appendTerminated(
        gpa,
        &out,
        root_text,
        hoisted.items,
        @intCast(order.items.len),
    ) catch return error.OutOfMemory;
    rows.append(gpa, .{
        .origin = root_origin,
        .name = root_name,
        .first_line = line,
        .line_count = root_lines,
        .is_root = true,
    }) catch return error.OutOfMemory;

    // Taken one at a time, not as two struct fields: fields evaluate in order,
    // and `out.toOwnedSlice` EMPTIES `out`, so the `errdefer out.deinit` above
    // is already a no-op by the time `rows.toOwnedSlice` runs. When that second
    // one failed, the assembled text had no owner left and leaked. `rows` only
    // reallocates when it has slack, which is exactly one directive repeated
    // across two parts — two libraries both writing `enable f16;` (§437).
    const text = out.toOwnedSlice(gpa) catch return error.OutOfMemory;
    errdefer gpa.free(text);
    const row_slice = rows.toOwnedSlice(gpa) catch return error.OutOfMemory;

    return .{
        .text = text,
        .owned = true,
        .rows = row_slice,
        .root_name = root_name,
        .root_origin = root_origin,
    };
}

/// Append `text` with `part`'s hoisted directives blanked out, guaranteeing it
/// ends with a newline, and return how many lines of the output it occupies.
///
/// The termination is what makes a line of assembled text belong to exactly one
/// row: without it, a fragment with no trailing newline would share its last
/// line with the next fragment's first, and a diagnostic there would be
/// attributed to the wrong author.
///
/// Blanking writes a space over every byte of a hoisted directive and keeps the
/// newlines inside it, so the part occupies the same lines AND the same columns
/// it did before the hoist. That is stronger than the line table needs and it
/// is deliberate: wgslender's column is passed through untouched, so a
/// diagnostic sharing a line with a directive — `enable f16; fn f() {}` — must
/// still point at the right character. The cost is the directive's own bytes,
/// in the unminified text only, for the documents that have directives at all.
fn appendTerminated(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    hoisted: []const Directive,
    part: u32,
) !u32 {
    if (text.len == 0) {
        try out.append(gpa, '\n');
        return 1;
    }

    try appendBlanked(gpa, out, text, hoisted, part);

    // Counted from `text`, not from what was appended: blanking is
    // length-preserving and newline-preserving, so the two agree by
    // construction.
    var lines: u32 = 1;
    for (text) |c| {
        if (c == '\n') lines += 1;
    }
    if (text[text.len - 1] == '\n') {
        // A trailing newline already closed the last line; it started no new one.
        lines -= 1;
    } else {
        try out.append(gpa, '\n');
    }
    std.debug.assert(lines >= 1);
    return lines;
}

/// Write `text` into `out` with `part`'s hoisted directives overwritten by
/// spaces — the blanking half of `appendTerminated`, on its own because the
/// pass path (`appendHoistingDirectives`) needs it without the termination.
///
/// A space per byte, and the directive's own newlines kept, so the text
/// occupies the same lines AND the same columns it did before the hoist.
fn appendBlanked(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    hoisted: []const Directive,
    part: u32,
) !void {
    var cursor: usize = 0;
    for (hoisted) |d| {
        if (d.part != part) continue;
        std.debug.assert(d.start >= cursor); // scanned left to right, once
        std.debug.assert(d.end <= text.len);
        try out.appendSlice(gpa, text[cursor..d.start]);
        for (text[d.start..d.end]) |c| try out.append(gpa, if (c == '\n') '\n' else ' ');
        cursor = d.end;
    }
    std.debug.assert(cursor <= text.len);
    try out.appendSlice(gpa, text[cursor..]);
}

// ============================================================================
// The directive hoist
// ============================================================================

/// One module-scope directive, lifted out of one part of an assembled module.
const Directive = struct {
    /// Which part it came from: an index into the post-order fragment list, or
    /// that list's length for the root.
    part: u32,
    /// The directive itself, a slice of that part's own text — from the keyword
    /// through the terminating `;`.
    text: []const u8,
    /// Its byte span in that part's text, which is what `appendTerminated`
    /// blanks.
    start: usize,
    end: usize,
    /// 1-based line of `start` in that part's own text, and how many lines the
    /// directive spans there.
    line: u32,
    lines: u32,
    /// False when an identical directive was already hoisted from an earlier
    /// part. It is still blanked where it was written — it must not be left
    /// sitting below another part's declarations — but it contributes no line
    /// to the hoist block. Repeating a `diagnostic` filter is a WGSL
    /// shader-creation error, so emitting both copies would turn two libraries
    /// that legally agree into a module that does not compile.
    first: bool,
};

/// Collect one part's leading module-scope directives, appending them to
/// `hoisted`.
///
/// WGSL admits `enable`, `requires` and `diagnostic` directives, in any order,
/// before the first declaration and nowhere else. The scan walks that region
/// only: the first token that is not one of the three ends it, so a part with
/// no directives — which is almost every part — costs one identifier read.
///
/// A directive with no terminating `;` is left exactly where it is. It is a
/// WGSL error, and naga reports it against the author's own line far better
/// than a hoist that guessed at where it ended.
///
/// Complexity: O(leading trivia + directives). No recursion.
fn scanDirectives(
    gpa: Allocator,
    text: []const u8,
    part: u32,
    hoisted: *std.ArrayList(Directive),
) Error!void {
    var i: usize = 0;
    var line: u32 = 1;

    // Bound: every iteration appends a directive or returns, and appending is
    // capped at `MAX_DIRECTIVES` — so the iteration after the last possible
    // append is the one that reports it.
    for (0..MAX_DIRECTIVES + 1) |_| {
        i = skipTrivia(text, i, &line);
        if (i >= text.len) return;

        const kw_end = identEnd(text, i);
        if (kw_end == i) return; // punctuation, an attribute: a declaration
        if (!isDirectiveKeyword(text[i..kw_end])) return;

        const start = i;
        const start_line = line;
        const end = scanToSemicolon(text, kw_end, &line) orelse return;
        i = end;

        if (hoisted.items.len >= MAX_DIRECTIVES) return error.TooDeep;
        const d = text[start..end];
        var first = true;
        for (hoisted.items) |prev| {
            if (directiveEql(prev.text, d)) {
                first = false;
                break;
            }
        }
        hoisted.append(gpa, .{
            .part = part,
            .text = d,
            .start = start,
            .end = end,
            .line = start_line,
            .lines = line - start_line + 1,
            .first = first,
        }) catch return error.OutOfMemory;
    } else unreachable;
}

fn isDirectiveKeyword(tok: []const u8) bool {
    const kw = std.StaticStringMap(void).initComptime(.{
        .{"enable"}, .{"requires"}, .{"diagnostic"},
    });
    return kw.has(tok);
}

/// End of the identifier starting at `from`, or `from` when there is none.
fn identEnd(text: []const u8, from: usize) usize {
    if (from >= text.len) return from;
    const c = text[from];
    if (!std.ascii.isAlphabetic(c) and c != '_') return from;
    var i = from + 1;
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) : (i += 1) {}
    return i;
}

/// Index just past the `;` that ends a directive, or null when the text runs
/// out first. Comments are skipped rather than searched, so a `;` inside one
/// does not end the directive early.
fn scanToSemicolon(text: []const u8, from: usize, line: *u32) ?usize {
    var i = from;
    // Each iteration consumes at least one byte, so this terminates at len.
    while (i < text.len) {
        const c = text[i];
        if (c == ';') return i + 1;
        if (c == '/' and i + 1 < text.len and (text[i + 1] == '/' or text[i + 1] == '*')) {
            const next = skipTrivia(text, i, line);
            std.debug.assert(next > i);
            i = next;
            continue;
        }
        if (c == '\n') line.* += 1;
        i += 1;
    }
    return null;
}

/// Skip whitespace and comments from `from`, counting the newlines crossed.
/// WGSL block comments nest, which is why this is not a search for `*/`.
fn skipTrivia(text: []const u8, from: usize, line: *u32) usize {
    var i = from;
    // Each iteration consumes at least one byte, so this terminates at len.
    while (i < text.len) {
        const c = text[i];
        if (c == '\n') {
            line.* += 1;
            i += 1;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\r') {
            i += 1;
            continue;
        }
        if (c != '/' or i + 1 >= text.len) break;
        if (text[i + 1] == '/') {
            i += 2;
            while (i < text.len and text[i] != '\n') : (i += 1) {}
            continue;
        }
        if (text[i + 1] == '*') {
            i += 2;
            var depth: u32 = 1;
            while (i < text.len and depth > 0) {
                if (i + 1 < text.len and text[i] == '/' and text[i + 1] == '*') {
                    depth += 1;
                    i += 2;
                } else if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '/') {
                    depth -= 1;
                    i += 2;
                } else {
                    if (text[i] == '\n') line.* += 1;
                    i += 1;
                }
            }
            // An unterminated block comment swallows the rest of the part,
            // which is also what the WGSL compiler will do with it.
            continue;
        }
        break; // a lone '/' is division: a declaration has begun
    }
    std.debug.assert(i >= from); // post: never rewinds
    return i;
}

/// Are these the same directive, ignoring whitespace? `enable  f16;` and
/// `enable f16;` are one directive written twice, and only the first is
/// hoisted.
///
/// Comments inside a directive defeat it, and deliberately: two spellings that
/// differ only in a comment are then hoisted twice, which is legal for `enable`
/// and `requires` and an author error for `diagnostic` that WGSL already names.
fn directiveEql(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    // Bound: every iteration consumes a byte of `a`, or returns.
    for (0..a.len + 1) |_| {
        while (i < a.len and std.ascii.isWhitespace(a[i])) i += 1;
        while (j < b.len and std.ascii.isWhitespace(b[j])) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (a[i] != b[j]) return false;
        i += 1;
        j += 1;
    } else unreachable;
}

// ============================================================================
// The same hoist, over a GENERATED prelude
// ============================================================================
//
// `assemble` hoists across the parts of an assembled module. `(pass …)` never
// reaches it: the sugar composes its prelude and the author's code into one
// `:code` string in `hooks.zig`, before any root exists, and that prelude
// always declares something (`FULLSCREEN_VS`, at minimum). So an author's
// `enable` was never in a leading position for the assembler to find, and a
// pass could not enable anything at all — the other half of CONTRIBUTING
// pitfall 104, and the half §405 left open.
//
// The two calls below are that half: the same scanner, the same blanking, the
// same deduplication, applied to a buffer that already holds generated text.
// A pass with imports then meets the assembler's hoist as well, and the two
// compose — the block these leave at the front of the composed text is exactly
// what `scanDirectives` recognises as leading, so it is lifted once more, once,
// above the fragments' declarations.

/// How a hoist over a generated prelude fails. `TooManyDirectives` is the
/// scanner's `MAX_DIRECTIVES` cap, reported rather than silently truncated: a
/// hoist that dropped the 65th directive would leave it sitting below the
/// prelude, which is the exact defect this exists to fix.
pub const HoistError = error{ OutOfMemory, TooManyDirectives };

/// Append `code` to `buf` — a module's generated prelude — lifting `code`'s
/// leading module-scope directives to the FRONT of `buf`, above everything the
/// prelude declares.
///
/// `code` is appended with those directives blanked, so it keeps its lines and
/// its columns; the block goes in at index 0, one directive per line, in the
/// order the author wrote them. The composed text therefore reads directives,
/// prelude, code, which is the order WGSL wants.
///
/// **A pass with no directives is byte-identical to a plain `appendSlice`, by
/// construction** — nothing is allocated, nothing is copied, and the composed
/// bytes are what they were before this function existed. That is what keeps
/// every golden trace in the corpus unmoved: `create_shader_module` records the
/// module's length and hash, and no `(pass …)` anywhere in the corpus opens
/// with a directive.
///
/// The lines below the block shift down by the block's height. That is right
/// rather than merely tolerable: a `.wgsl` diagnostic on a lowered pass is
/// SHADER-relative — its module tag routes it to the editor's WGSL view, which
/// shows this composed text — so the hoisted directive is at the line it is
/// reported at. There is no author-facing line table to correct against; a
/// pass's `:code` has no document position at all (`Emitter.locate` returns
/// null for a lowered tree).
///
/// Complexity: O(code). No recursion.
pub fn appendHoistingDirectives(
    gpa: Allocator,
    buf: *std.ArrayList(u8),
    code: []const u8,
) HoistError!void {
    var hoisted: std.ArrayList(Directive) = .empty;
    defer hoisted.deinit(gpa);
    try collectLeading(gpa, code, &hoisted);

    if (hoisted.items.len == 0) {
        // The common path, and the one the goldens pin.
        try buf.appendSlice(gpa, code);
        return;
    }

    const prelude_len = buf.items.len;
    appendBlanked(gpa, buf, code, hoisted.items, 0) catch return error.OutOfMemory;
    std.debug.assert(buf.items.len == prelude_len + code.len); // blanking preserves length
    try prependBlock(gpa, buf, hoisted.items);
}

/// Lift the leading directives of `code` to the front of `buf`, appending none
/// of `code` itself.
///
/// For the post-processing shader: `@fragment fn post(…)` is cut out of the
/// author's `:code` and compiled as its own module, and the cut starts below
/// any directive. The author wrote one module and the sugar split it in two, so
/// a directive at the top of `:code` governs both halves — without this, a pass
/// that enables an extension and writes a `post()` using it gets a main module
/// that compiles and a post module that does not.
///
/// Complexity: O(leading trivia + directives). No recursion.
pub fn prependDirectivesOf(
    gpa: Allocator,
    buf: *std.ArrayList(u8),
    code: []const u8,
) HoistError!void {
    var hoisted: std.ArrayList(Directive) = .empty;
    defer hoisted.deinit(gpa);
    try collectLeading(gpa, code, &hoisted);
    if (hoisted.items.len == 0) return;
    try prependBlock(gpa, buf, hoisted.items);
}

/// `scanDirectives` over one standalone text, in the hoist's error set.
fn collectLeading(
    gpa: Allocator,
    code: []const u8,
    hoisted: *std.ArrayList(Directive),
) HoistError!void {
    std.debug.assert(hoisted.items.len == 0);
    scanDirectives(gpa, code, 0, hoisted) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // `scanDirectives` reaches exactly one other error from one part.
        else => return error.TooManyDirectives,
    };
    std.debug.assert(hoisted.items.len <= MAX_DIRECTIVES);
}

/// Insert the hoist block at the front of `buf`, one directive per line.
/// Repeats are blanked where they were written but contribute no line, for the
/// reason `Directive.first` gives: two identical `diagnostic` filters in one
/// module are a WGSL shader-creation error.
fn prependBlock(
    gpa: Allocator,
    buf: *std.ArrayList(u8),
    hoisted: []const Directive,
) HoistError!void {
    std.debug.assert(hoisted.len > 0);
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(gpa);
    for (hoisted) |d| {
        if (!d.first) continue;
        block.appendSlice(gpa, d.text) catch return error.OutOfMemory;
        block.append(gpa, '\n') catch return error.OutOfMemory;
    }
    std.debug.assert(block.items.len > 0); // the first directive is always `first`
    buf.insertSlice(gpa, 0, block.items) catch return error.OutOfMemory;
}

/// Depth-first post-order over the import graph, visiting each fragment once.
/// Explicit stack, bounded loop, no recursion.
fn postOrder(
    gpa: Allocator,
    table: *Table,
    roots: []const []const u8,
    out: *std.ArrayList(*Fragment),
    cycle: ?*CyclePath,
) Error!void {
    const Frame = struct {
        frag: *Fragment,
        /// Index into `frag.imports` of the next child to descend into.
        next: u32,
    };
    var stack: [MAX_DEPTH]Frame = undefined;
    var depth: u32 = 0;

    // `on_path` mirrors the stack for the cycle test; `done` records what has
    // already been emitted so a diamond contributes its shared fragment once.
    var on_path: std.ArrayList(*Fragment) = .empty;
    defer on_path.deinit(gpa);
    var done: std.ArrayList(*Fragment) = .empty;
    defer done.deinit(gpa);

    for (roots) |root_import| {
        const start = table.find(root_import) orelse return error.UnknownFragment;
        start.imported = true;
        if (contains(done.items, start)) continue;

        depth = 1;
        stack[0] = .{ .frag = start, .next = 0 };
        on_path.append(gpa, start) catch return error.OutOfMemory;

        // Bound: each iteration either descends (bounded by MAX_DEPTH) or
        // advances a child index (bounded by MAX_IMPORTS per frame).
        for (0..MAX_DEPTH * MAX_IMPORTS * MAX_IMPORTS) |_| {
            if (depth == 0) break;
            const top = &stack[depth - 1];
            if (top.next < top.frag.imports.len) {
                const child_name = top.frag.imports[top.next];
                top.next += 1;
                const child = table.find(child_name) orelse return error.UnknownFragment;
                child.imported = true;
                if (contains(done.items, child)) continue;
                if (contains(on_path.items, child)) {
                    if (cycle) |c| fillCycle(c, on_path.items, child);
                    return error.ImportCycle;
                }
                if (depth == MAX_DEPTH) return error.TooDeep;
                stack[depth] = .{ .frag = child, .next = 0 };
                depth += 1;
                on_path.append(gpa, child) catch return error.OutOfMemory;
                continue;
            }
            // Children exhausted: emit this one and pop.
            if (out.items.len >= MAX_FRAGMENTS) return error.TooDeep;
            out.append(gpa, top.frag) catch return error.OutOfMemory;
            done.append(gpa, top.frag) catch return error.OutOfMemory;
            _ = on_path.pop();
            depth -= 1;
        } else return error.TooDeep;
    }
}

fn contains(haystack: []const *Fragment, needle: *Fragment) bool {
    for (haystack) |h| {
        if (h == needle) return true;
    }
    return false;
}

/// Record the cycle as the path from where `closing` first appears to the end,
/// plus `closing` again — so it reads `mesh → material → mesh`.
fn fillCycle(c: *CyclePath, path: []const *Fragment, closing: *Fragment) void {
    var start: usize = 0;
    for (path, 0..) |f, i| {
        if (f == closing) {
            start = i;
            break;
        }
    }
    c.len = 0;
    for (path[start..]) |f| {
        if (c.len == CyclePath.MAX) return;
        c.names[c.len] = f.name;
        c.len += 1;
    }
    if (c.len < CyclePath.MAX) {
        c.names[c.len] = closing.name;
        c.len += 1;
    }
}

// ============================================================================
// Tests
// ============================================================================

fn frag(name: []const u8, text: []const u8, imports: []const []const u8) Fragment {
    return .{
        .name = name,
        .text = text,
        .owns_text = false,
        .origin = .{ .inline_code = name },
        .imports = imports,
        .requires = &.{},
    };
}

// ── the same hoist over a generated prelude (pitfall 104's pass half) ────────

/// `buildPrelude`'s shape, small enough to read in an expectation: a
/// declaration, so the author's directive cannot stay where it was written.
const PRELUDE = "@group(0) @binding(0) var samp: sampler;\n@vertex fn vs() {}\n";

// --- Module-scope declaration scan (R10) ------------------------------------

/// Does `wgsl` declare `name` at module scope?
///
/// This exists because a fragment's holes have to be checked against what the
/// assembled module declares, and reflection is the wrong instrument for it in
/// two ways. pngine's `reflect.ReflectionData` carries bindings, structs, entry
/// points and overrides but not plain functions or aliases; and the reflection
/// `analyzeModule` returns describes the MINIFIED text when `--minify` is on,
/// where every name has been renamed. A declaration scan of the assembled
/// source answers the question the author asked, in the spelling they used.
///
/// Scanning for a DECLARATION is a very different proposition from scanning for
/// a use, which is why this is safe where the substring probes elsewhere in the
/// tree are not (journal §325): a module-scope declaration is a keyword
/// followed by an identifier, and WGSL has no string literals for one to hide
/// in. Comments are stripped, `var<storage, read_write>` templates are skipped,
/// and anything inside a function body is ignored by brace depth.
///
/// Complexity: O(wgsl.len). No allocation.
pub fn declaresName(wgsl: []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);
    var it = ModuleScopeTokens{ .src = wgsl };
    var expect_name = false;
    while (it.next()) |tok| {
        if (expect_name) {
            expect_name = false;
            if (std.mem.eql(u8, tok, name)) return true;
            continue;
        }
        if (isDeclKeyword(tok)) expect_name = true;
    }
    return false;
}

fn isDeclKeyword(tok: []const u8) bool {
    const kw = std.StaticStringMap(void).initComptime(.{
        .{"fn"}, .{"struct"}, .{"alias"}, .{"const"}, .{"override"}, .{"var"}, .{"let"},
    });
    return kw.has(tok);
}

/// Identifier tokens at brace depth 0, with comments and `var<…>` templates
/// removed. Everything else — punctuation, numbers, attributes, function
/// bodies — is skipped rather than returned.
const ModuleScopeTokens = struct {
    src: []const u8,
    i: usize = 0,
    depth: u32 = 0,

    fn next(self: *ModuleScopeTokens) ?[]const u8 {
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            // Comments.
            if (c == '/' and self.i + 1 < self.src.len) {
                if (self.src[self.i + 1] == '/') {
                    while (self.i < self.src.len and self.src[self.i] != '\n') self.i += 1;
                    continue;
                }
                if (self.src[self.i + 1] == '*') {
                    self.i += 2;
                    var nest: u32 = 1;
                    while (self.i < self.src.len and nest > 0) {
                        if (self.i + 1 < self.src.len and self.src[self.i] == '/' and self.src[self.i + 1] == '*') {
                            nest += 1;
                            self.i += 2;
                            continue;
                        }
                        if (self.i + 1 < self.src.len and self.src[self.i] == '*' and self.src[self.i + 1] == '/') {
                            nest -= 1;
                            self.i += 2;
                            continue;
                        }
                        self.i += 1;
                    }
                    continue;
                }
            }
            if (c == '{') {
                self.depth += 1;
                self.i += 1;
                continue;
            }
            if (c == '}') {
                if (self.depth > 0) self.depth -= 1;
                self.i += 1;
                continue;
            }
            // A template list — `var<storage, read_write>`, `array<vec2<f32>, 4>`.
            // Skipping it keeps `storage` and `read_write` from reading as
            // identifiers right where a declared name is expected. Which `<`
            // opens one is WGSL's own rule (spec §3.9, template-list discovery),
            // not "every `<` at module scope": `1u << 3u` and `1 < 2` in a
            // `const` initializer are operators, and taking them for a template
            // consumed to a `>` that never came — every declaration below them
            // vanished, and a `(pass …)` with its override there was refused.
            if (c == '<' and self.depth == 0) {
                self.i = self.templateEnd() orelse self.i + 1;
                continue;
            }
            if (isIdentStart(c)) {
                const start = self.i;
                while (self.i < self.src.len and isIdentPart(self.src[self.i])) self.i += 1;
                if (self.depth == 0) return self.src[start..self.i];
                continue;
            }
            self.i += 1;
        }
        return null;
    }

    /// The index just past the `>` closing the template list that opens at
    /// `self.i`, or null when the `<` there is an operator.
    ///
    /// WGSL's discovery rule, reduced to what a declaration scan needs: the `<`
    /// must immediately follow an identifier (no blankspace — `1u<<3u` still
    /// qualifies through the literal's suffix, and is then abandoned below),
    /// and the candidate is abandoned at `;`, `{`, `}`, a lone `=`, `&&`, `||`,
    /// a `)`/`]` that closes something opened before it, or the end of the
    /// text. Nested `<`/`>` count, so `array<vec2<f32>, 4>` closes on its own
    /// second `>`. Bounded by the text; every step advances.
    fn templateEnd(self: *const ModuleScopeTokens) ?usize {
        std.debug.assert(self.i < self.src.len);
        std.debug.assert(self.src[self.i] == '<');
        if (self.i == 0 or !isIdentPart(self.src[self.i - 1])) return null;
        var nest: u32 = 0;
        var brackets: u32 = 0;
        var i = self.i;
        while (i < self.src.len) : (i += 1) {
            const at = self.src[i];
            const following: u8 = if (i + 1 < self.src.len) self.src[i + 1] else 0;
            switch (at) {
                '<' => nest += 1,
                '>' => {
                    nest -= 1; // ≥ 1 here: the first byte was `<`, and 0 returns
                    if (nest == 0) return i + 1;
                },
                '(', '[' => brackets += 1,
                ')', ']' => {
                    if (brackets == 0) return null;
                    brackets -= 1;
                },
                ';', '{', '}' => return null,
                '=' => if (following != '=') return null,
                '&' => if (following == '&') return null,
                '|' => if (following == '|') return null,
                else => {},
            }
        }
        return null;
    }
};

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentPart(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

// --- Hole harvest (R11) -----------------------------------------------------

/// The identifier that starts at 1-based `line`:`col` of `text`, or null when
/// nothing identifier-shaped starts there.
///
/// This is how a fragment's holes are read off its own solo validation:
/// wgslender's three unresolved-name codes (`E0100`, `E0204`, `E0200` for an
/// unknown type) all anchor their range on the name they could not resolve —
/// for a call, on the callee, which is where a call expression begins — so the
/// identifier at the diagnostic's start IS the hole, in the author's spelling,
/// with no message parsing.
///
/// Complexity: O(text.len). No allocation.
pub fn identifierAt(text: []const u8, line: u32, col: u32) ?[]const u8 {
    std.debug.assert(line >= 1);
    std.debug.assert(col >= 1);
    var i: usize = 0;
    var at_line: u32 = 1;
    // Bounded by the text: every iteration consumes one byte.
    while (at_line < line) : (i += 1) {
        if (i >= text.len) return null;
        if (text[i] == '\n') at_line += 1;
    }
    const start = i + (col - 1);
    if (start >= text.len or !isIdentStart(text[start])) return null;
    var end = start;
    while (end < text.len and isIdentPart(text[end])) end += 1;
    std.debug.assert(end > start);
    return text[start..end];
}

/// Does `message` quote `name` — contain `'name'` exactly, quotes included?
///
/// The guard beside `identifierAt`: a diagnostic whose range starts on an
/// identifier but whose text does not name it is not talking about that
/// identifier, and the harvest must not invent a hole out of it.
///
/// Complexity: O(message.len × name.len). No allocation.
pub fn quotesName(message: []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);
    if (message.len < name.len + 2) return false;
    var i: usize = 0;
    // Bounded: each iteration advances `i` by at least one.
    while (i + name.len + 1 < message.len) : (i += 1) {
        if (message[i] != '\'') continue;
        if (!std.mem.eql(u8, message[i + 1 .. i + 1 + name.len], name)) continue;
        if (message[i + 1 + name.len] == '\'') return true;
    }
    return false;
}
