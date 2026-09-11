//! `(import :file "./other.sjon" (define …)* (wgsl …)*)` — one document is
//! another document plus a rebinding of its consumed forms: its constants and
//! its fragments.
//!
//! This pass runs ABOVE SJON, before `validateDocument` sees anything: it reads
//! the `(import …)` forms out of a source, fetches what they name through the
//! `FileResolver` seam, and hands back ONE composed source plus a map saying
//! which byte came from which file. By the time the validator runs there are no
//! import forms left, which is why `Emitter.checkImportsComposed` treats a
//! surviving one as a caller bug rather than an author error.
//!
//! ## Design
//!
//! - **Blank, do not delete.** Every span this pass consumes — an overridden
//!   `(define …)`, an `(import …)`'s head and `:file` — is overwritten with
//!   spaces, EXCEPT `\n`, which is copied through. Offsets are preserved, so
//!   every surviving byte sits at the offset its author wrote it at; newlines
//!   are preserved, so every line number is the line they typed. That is F3's
//!   whole cost gone: the pre-SJON `ImportResolver` spliced text and every
//!   position after a splice belonged to a file the parser did not know about.
//!   §405 established the technique for WGSL directives; the one rule it did
//!   not need is `\n`, because it only ever blanked inside a single line.
//!
//! - **One region per document, not one entry per splice.** The composed source
//!   is the documents' texts in dependency order, so the offset→file map is a
//!   short list of `(start, end, path)`. `localise` is a bounded scan.
//!
//! - **The import's children are not moved.** Blanking the form and then
//!   copying each child's original bytes back leaves the bindings at top
//!   level, at the exact offsets the author wrote them. Nothing is
//!   synthesised, so nothing has a made-up position. Copying back (rather than
//!   blanking around the children) is also what makes key/positional
//!   interleaving — `(import (define …) :file "x")` — come out right.
//!
//! - **Two phases, because the order is a graph property.** Phase 1 fetches
//!   every document breadth-first and records who imports whom; phase 2 walks
//!   that graph POST-ORDER, which is the only order in which a document
//!   precedes everything that extends it while siblings stay in written order.
//!   Cycle detection falls out of phase 2 for free: a document re-entered
//!   before it has been emitted is, by definition, importing itself.
//!
//! - **Only a CONSUMED form is rebindable, and that is not enforced here.**
//!   `rebindable_heads` lists them: `(define …)` since 05, `(wgsl …)` since
//!   §417. A form belongs there when it has no emission position — moving one
//!   compiles byte-identical, which was probed for both — so rebinding it
//!   changes the value or the text and moves nothing. Two documents declaring
//!   one texture is `duplicate_cross_ref_target` from SJON's own validator,
//!   reported on the second declaration with a real span. There is no
//!   shadowing rule in this file because shadowing is not expressible.
//!
//! ## Invariants
//!
//! - `compose` returns `null` for a source with no `(import …)` form, having
//!   allocated nothing that outlives the call. 122 of the corpus's 123
//!   documents take that path.
//! - Every region is non-empty, they tile `[0, source.len)` in order, and there
//!   is exactly one per composed document.
//! - A document is included at most once per composition (by normalised path),
//!   so a diamond costs one copy, not two.

const std = @import("std");
const builtin = @import("builtin");
const sjon = @import("sjon");

const file_resolver = @import("file_resolver.zig");
const diag_mod = @import("diag.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const FileResolver = file_resolver.FileResolver;
const Needs = file_resolver.Needs;
const Tree = sjon.Ast.Tree;
const NodeIndex = sjon.Ast.NodeIndex;

/// How many distinct documents one composition may pull in.
///
/// This is the only cap, and it subsumes the depth cap the pre-SJON
/// `ImportResolver` needed (README F3 records 64). Include-once means a
/// document is fetched at most once, so a chain cannot be longer than the graph
/// is wide: bounding the graph bounds the depth, and a second constant would
/// only be a second thing to keep in step.
pub const MAX_DOCUMENTS: u32 = 64;

/// The byte ceiling on one imported document, matching the cap the CLI applies
/// to piped source and to every other referenced file.
pub const MAX_DOCUMENT_BYTES: u32 = 16 * 1024 * 1024;

pub const Error = error{
    OutOfMemory,
    /// The composition could not be built. A message has been written to the
    /// caller's `Diag` when one was supplied; the caller turns this into its
    /// own error class.
    ImportError,
};

/// Which range of the composed source came from which file. `path` is the
/// normalised path the document was fetched by, or empty for the root document
/// (which may have arrived on stdin and have no path at all).
pub const Region = struct {
    start: u32,
    end: u32,
    path: []const u8,
};

/// A composed document: one source, and the map back to where its bytes were
/// written. Every allocation is `gpa`-owned.
pub const Composed = struct {
    source: [:0]u8,
    regions: []Region,
    /// Backing store for every `Region.path`, so a region outlives the tree its
    /// path was read from.
    paths: []u8,

    pub fn deinit(self: *Composed, gpa: Allocator) void {
        gpa.free(self.source);
        gpa.free(self.regions);
        gpa.free(self.paths);
        self.* = undefined;
    }

    /// Translate a composed-source offset into the file it came from and the
    /// offset WITHIN that file. An empty path is the root document, which is
    /// the caller's signal to leave `Diag.Located.file` unset — a position in
    /// the author's own source needs no file to explain it.
    ///
    /// Complexity: O(regions.len), bounded by `MAX_DOCUMENTS`.
    pub fn localise(self: *const Composed, offset: u32) struct { path: []const u8, offset: u32 } {
        std.debug.assert(self.regions.len > 0);
        for (self.regions) |r| {
            std.debug.assert(r.end > r.start);
            if (offset >= r.start and offset < r.end) {
                return .{ .path = r.path, .offset = offset - r.start };
            }
        }
        // Past the last region: the sentinel, or a caller's own bug. Report it
        // against the root rather than inventing a file.
        return .{ .path = "", .offset = offset };
    }

    /// The bytes of the region an offset falls in, for a caller that needs to
    /// compute a line and column inside that file rather than the composition.
    ///
    /// Complexity: O(regions.len).
    pub fn regionText(self: *const Composed, offset: u32) []const u8 {
        for (self.regions) |r| {
            if (offset >= r.start and offset < r.end) return self.source[r.start..r.end];
        }
        return self.source;
    }
};

/// What `compose` needs besides the bytes.
pub const Options = struct {
    diag: ?*Diag = null,
    needs: ?*Needs = null,
    /// The root document's own path RELATIVE TO THE RESOLVER'S ROOT, when the
    /// caller knows it. Supplying it is what lets a document that imports
    /// ITSELF, directly or through a chain, be reported as the cycle it is;
    /// without it the self-import is fetched as a second copy and surfaces
    /// later as a duplicate declaration — terminating, but with a message
    /// about names rather than about the cycle.
    root_path: ?[]const u8 = null,
    /// Whether `resolver` is an INJECTED table (the browser) rather than a
    /// filesystem. It changes one sentence: a file that is missing from a table
    /// was never handed over, where a file missing from a disk is not there.
    /// The resolver is a vtable pair and cannot be asked, so the caller says.
    injected: bool = false,
};

// --- internal document graph ------------------------------------------------

const Doc = struct {
    /// Offsets into the composition's path buffer. `len == 0` is the root.
    path_off: u32,
    path_len: u32,
    /// Source bytes. Owned by this pass and freed on the way out; the root is a
    /// copy, so the caller's source is never written to.
    text: []u8,
    /// Range in `edges` naming the documents this one imports, in written
    /// order. Filled when the document is expanded.
    child_off: u32 = 0,
    child_len: u32 = 0,
};

/// A path's place in the composition's path buffer. Offsets, not a slice: the
/// buffer grows, and a slice into it would dangle after the next append.
const PathRef = struct { off: u32, len: u32 };

/// One `(import …)` read out of a document, before anything is fetched.
const ImportForm = struct {
    span: sjon.Ast.Span,
    file: []const u8,
    file_node: NodeIndex,
    /// The import's rebinding children, in written order: every child form
    /// whose head is in `rebindable_heads`.
    bindings: []const NodeIndex,
    /// Whether the form holds anything this pass cannot act on — a key other
    /// than `:file`, a child form with a head outside `rebindable_heads`, a
    /// bare value. Such a form is left in the text, untouched, for the
    /// validator to refuse against the schema: blanking it would delete the
    /// offending child along with the diagnostic it deserves. (Before §417 an
    /// `(import … (texture …))` validated clean with the texture gone.)
    malformed: bool,

    /// Whether the pass fetches, rebinds and blanks this form. The two ways to
    /// fail are the two the validator can explain: no `:file` ("missing
    /// required keyword") and something the schema does not admit.
    fn actionable(self: ImportForm) bool {
        return self.file.len != 0 and !self.malformed;
    }
};

/// The heads an `(import …)` may rebind. The schema's `import-section` admits
/// exactly these; keep the two in step. Every one must be a CONSUMED form (it
/// lowers to nothing and emits nothing), which is what makes rebinding it
/// byte-neutral — see the design note at the top of this file.
const rebindable_heads = [_][]const u8{ "define", "wgsl" };

/// An EMPTY head is a real input here, not a caller bug: the parser recovers
/// an unclosed `(` — a document truncated mid-form, which is most of what the
/// mutation sweep generates — as a form with no head, and the answer for it is
/// "no", which makes the import malformed and leaves it for the validator. An
/// assertion here crashed the sweep (§417).
fn isRebindable(head: []const u8) bool {
    if (head.len == 0) return false;
    for (rebindable_heads) |h| {
        if (std.mem.eql(u8, h, head)) return true;
    }
    return false;
}

/// Everything one composition needs to carry between its two phases.
///
/// Stores BOTH allocators, and they are not interchangeable: `gpa` owns the
/// three growable lists below, which `compose` frees by hand; `arena` owns
/// everything that has to outlive this struct and live as long as the composed
/// document. Allocate from the wrong one and it either leaks or dangles.
const Builder = struct {
    gpa: Allocator,
    arena: Allocator,
    options: Options,
    resolver: ?FileResolver,
    docs: std.ArrayList(Doc) = .empty,
    edges: std.ArrayList(u32) = .empty,
    paths: std.ArrayList(u8) = .empty,

    fn pathOf(self: *const Builder, d: Doc) []const u8 {
        if (d.path_len == 0) return "";
        return self.paths.items[d.path_off..][0..d.path_len];
    }

    /// Normalise and store a path, returning its offset/length in `paths`.
    /// Offsets, not slices: `paths` grows, and a slice into it would dangle.
    fn internPath(self: *Builder, path: []const u8) Error!PathRef {
        var buf: [file_resolver.MAX_PATH]u8 = undefined;
        // An unnormalisable path is stored verbatim; `FileResolver.read`
        // refuses it a moment later with the sentence that explains why.
        const clean = file_resolver.normalise(path, &buf) catch path;
        const off: u32 = @intCast(self.paths.items.len);
        try self.paths.appendSlice(self.gpa, clean);
        return .{ .off = off, .len = @intCast(clean.len) };
    }

    fn findDoc(self: *const Builder, path: []const u8) ?u32 {
        if (path.len == 0) return null;
        for (self.docs.items, 0..) |d, i| {
            if (d.path_len == 0) continue;
            if (std.mem.eql(u8, self.pathOf(d), path)) return @intCast(i);
        }
        return null;
    }
};

// --- the pass ---------------------------------------------------------------

/// Compose `root` with everything it imports, transitively.
///
/// Returns `null` — having allocated nothing that outlives the call — when
/// `root` declares no `(import …)`. That is the fast path, it is the one every
/// existing document takes, and it is why every golden stays byte-identical.
///
/// `resolver` is 01's seam: the filesystem in the CLI, an injected table in the
/// browser. A null resolver with imports present is a refusal, not a silent
/// skip — the alternative compiles a document missing everything it imports.
///
/// Complexity: O(total bytes) plus one parse per distinct document.
pub fn compose(
    gpa: Allocator,
    root: [:0]const u8,
    resolver: ?FileResolver,
    options: Options,
) Error!?Composed {
    // Cheapest possible rejection of the common case: a document with no
    // `import` anywhere in its bytes cannot declare one. A false positive (the
    // word inside a shader or a comment) only costs the parse below.
    if (std.mem.indexOf(u8, root, "import") == null) return null;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var b: Builder = .{
        .gpa = gpa,
        .arena = arena_state.allocator(),
        .options = options,
        .resolver = resolver,
    };
    // Defers run last-declared-first, so the text loop is declared AFTER the
    // list it walks: freeing the documents must happen while `docs` is still a
    // list. (Declared the other way round it reads correctly and is a
    // use-after-free.)
    defer b.paths.deinit(gpa);
    defer b.edges.deinit(gpa);
    defer b.docs.deinit(gpa);
    // Owns every fetched document AND the root's copy, on every exit path.
    defer for (b.docs.items) |d| gpa.free(d.text);

    const root_path: PathRef = if (options.root_path) |p| try b.internPath(p) else .{ .off = 0, .len = 0 };
    // Capacity FIRST, then the copy: an `append` that allocates can fail, and a
    // buffer duped as its argument would be lost before the list could own it
    // (the defer above walks `docs`, so what never lands there never gets
    // freed). Found by the OOM sweep, which is exactly what it is for.
    try b.docs.ensureUnusedCapacity(gpa, 1);
    b.docs.appendAssumeCapacity(.{
        .path_off = root_path.off,
        .path_len = root_path.len,
        .text = try gpa.dupe(u8, root),
    });

    // --- phase 1: fetch, breadth-first over a growing list ---
    var cursor: u32 = 0;
    var found_any = false;
    // Bound: the cursor only advances, and `docs` is capped at MAX_DOCUMENTS.
    for (0..MAX_DOCUMENTS + 1) |_| {
        if (cursor >= b.docs.items.len) break;
        if (try expandOne(&b, cursor)) found_any = true;
        cursor += 1;
    } else {
        report(options, "a composition may pull in at most {d} documents", .{MAX_DOCUMENTS}, null);
        return error.ImportError;
    }

    // The sniff above fires on the word `import` inside a shader too, and a
    // malformed import resolves to nothing. Either way: nothing was fetched and
    // nothing was blanked, so hand back null and let the caller keep the source
    // it already has — which is what puts a half-written `(import)` in front of
    // the validator that can explain it.
    if (!found_any) return null;

    // --- phase 2: post-order, which is the composition order ---
    const order = try postOrder(&b);

    return try build(&b, order);
}

/// Parse one document, read its `(import …)` forms, fetch what they name, apply
/// their rebindings, record the edges, and blank the resolved forms out of the
/// text. Returns whether any import actually RESOLVED — not whether one was
/// written, because a document whose only import is malformed must reach the
/// validator with that form still in it.
fn expandOne(b: *Builder, doc_index: u32) Error!bool {
    std.debug.assert(doc_index < b.docs.items.len);

    // Parse a pristine COPY: blanking edits the real buffer underneath, and the
    // define children are copied back out of this one.
    const text = b.docs.items[doc_index].text;
    const pristine = try b.arena.allocSentinel(u8, text.len, 0);
    @memcpy(pristine, text);
    var tree = sjon.parse(b.arena, pristine) catch {
        // Not this pass's failure to report: handing the source on unchanged
        // lets SJON's own validator produce the real diagnostic, with its span
        // and its code.
        return false;
    };

    const imports = try readImports(b, &tree);
    if (imports.len == 0) return false;

    const child_off: u32 = @intCast(b.edges.items.len);
    var resolved: u32 = 0;
    for (imports) |imp| {
        const child = try resolveImport(b, doc_index, &tree, imp) orelse continue;
        try b.edges.append(b.gpa, child);
        resolved += 1;
    }
    b.docs.items[doc_index].child_off = child_off;
    b.docs.items[doc_index].child_len = @intCast(b.edges.items.len - child_off);

    // Blank last, so a refusal above leaves the buffer untouched — and blank
    // ONLY what resolved. A malformed `(import)` with no `:file` is left in the
    // text on purpose: the validator is the one that says "missing required
    // keyword `:file`", and blanking it here would delete the form and the
    // diagnostic with it. (Found by the mutation sweep, which is exactly the
    // kind of half-written form it generates.)
    for (imports) |imp| {
        if (!imp.actionable()) continue;
        blank(text, imp.span.start, imp.span.end);
        // …and put the bindings back where their author wrote them.
        for (imp.bindings) |d| {
            const s = tree.spanOf(d);
            @memcpy(text[s.start..s.end], pristine[s.start..s.end]);
        }
    }
    return resolved != 0;
}

/// Every `(import …)` at the root of `tree`, in written order.
fn readImports(b: *Builder, tree: *const Tree) Error![]const ImportForm {
    var out: std.ArrayList(ImportForm) = .empty;
    for (tree.root) |idx| {
        if (tree.tagOf(idx) != .form) continue;
        const hdr = tree.formHeader(idx);
        if (!std.mem.eql(u8, hdr.head, "import")) continue;

        var file: []const u8 = "";
        var file_node = idx;
        var bindings: std.ArrayList(NodeIndex) = .empty;
        var malformed = false;
        for (hdr.children) |c| {
            switch (tree.tagOf(c)) {
                .kvpair => {
                    const kv = tree.kvpairHeader(c);
                    if (!std.mem.eql(u8, kv.key, "file") or tree.tagOf(kv.value) != .string) {
                        malformed = true;
                        continue;
                    }
                    file = tree.stringText(kv.value);
                    file_node = kv.value;
                },
                .form => {
                    const ch = tree.formHeader(c);
                    if (isRebindable(ch.head)) {
                        try bindings.append(b.arena, c);
                    } else {
                        malformed = true;
                    }
                },
                else => malformed = true,
            }
        }
        try out.append(b.arena, .{
            .span = tree.spanOf(idx),
            .file = file,
            .file_node = file_node,
            .bindings = try bindings.toOwnedSlice(b.arena),
            .malformed = malformed,
        });
    }
    return out.toOwnedSlice(b.arena);
}

/// Turn one `(import …)` into a document index, fetching it if this is the
/// first time it has been named. Null when the form is malformed enough that
/// the validator should answer instead.
fn resolveImport(b: *Builder, importer: u32, tree: *const Tree, imp: ImportForm) Error!?u32 {
    // No `:file`, or a child the schema does not admit: the validator names
    // the missing required keyword, the unknown key or the unexpected head,
    // with a span — and it can only do that if the form is still in the text,
    // so `expandOne` leaves it there.
    if (!imp.actionable()) return null;

    const r = b.resolver orelse {
        reportAt(b, importer, tree, imp.file_node, "cannot read '{s}': this host has no file resolver, so it cannot follow an import — compiling the source directly would silently drop every form the imported document declares", .{imp.file});
        return error.ImportError;
    };

    const stored = try b.internPath(imp.file);
    const norm = b.paths.items[stored.off..][0..stored.len];

    // Include-once: a diamond costs one copy. A SECOND import of the same
    // document that also rebinds is refused rather than resolved last-one-wins,
    // because either answer is a silent one.
    if (b.findDoc(norm)) |seen| {
        if (imp.bindings.len != 0) {
            reportAt(b, importer, tree, imp.file_node, "'{s}' is imported more than once and this import rebinds something in it — a document is composed once, so a second binding could only silently win or silently lose", .{imp.file});
            return error.ImportError;
        }
        return seen;
    }

    if (b.docs.items.len >= MAX_DOCUMENTS) {
        report(b.options, "a composition may pull in at most {d} documents", .{MAX_DOCUMENTS}, null);
        return error.ImportError;
    }

    // Room for the entry BEFORE the read, for the reason `compose` explains:
    // bytes that never reach `docs` are never freed.
    try b.docs.ensureUnusedCapacity(b.gpa, 1);
    const bytes = r.read(b.gpa, imp.file, MAX_DOCUMENT_BYTES) catch |err| {
        if (b.options.needs) |n| n.add(imp.file, err);
        reportRead(b, importer, tree, imp.file_node, imp.file, err);
        return error.ImportError;
    };
    // From here the bytes belong to `docs`, which frees them.
    b.docs.appendAssumeCapacity(.{
        .path_off = stored.off,
        .path_len = stored.len,
        .text = bytes,
    });
    const index: u32 = @intCast(b.docs.items.len - 1);
    try rebind(b, importer, tree, index, imp.bindings);
    return index;
}

/// Blank the imported document's `(<head> :name N …)` for every binding this
/// import carries — the same head AND the same name — and refuse one the
/// document does not declare that way.
///
/// The refusal is the typo guard, and it is why the imported side needs no
/// `:requires`-style list: a `(define …)` or a `(wgsl …)` is already a
/// declaration, so "is this name open" has an answer without a second form.
/// The head is part of the key: a `(wgsl :name N …)` does not rebind a
/// `(define :name N …)`, it is refused, because a binding that changes what
/// KIND of thing a name is would be a shadowing rule in disguise.
fn rebind(b: *Builder, importer_doc: u32, importer: *const Tree, doc_index: u32, bindings: []const NodeIndex) Error!void {
    if (bindings.len == 0) return;
    const text = b.docs.items[doc_index].text;
    const path = b.pathOf(b.docs.items[doc_index]);

    const pristine = try b.arena.allocSentinel(u8, text.len, 0);
    @memcpy(pristine, text);
    var tree = sjon.parse(b.arena, pristine) catch {
        report(b.options, "'{s}' cannot be parsed, so nothing in it can be rebound", .{path}, null);
        return error.ImportError;
    };

    for (bindings) |d| {
        const head = importer.formHeader(d).head;
        std.debug.assert(isRebindable(head));
        // A binding with no `:name` is copied back at top level as it is, and
        // the validator names the missing required keyword there.
        const want = nameOf(importer, d) orelse continue;
        var found = false;
        for (tree.root) |idx| {
            if (tree.tagOf(idx) != .form) continue;
            if (!std.mem.eql(u8, tree.formHeader(idx).head, head)) continue;
            const have = nameOf(&tree, idx) orelse continue;
            if (!std.mem.eql(u8, have, want)) continue;
            const s = tree.spanOf(idx);
            blank(text, s.start, s.end);
            found = true;
            break;
        }
        if (!found) {
            reportAt(b, importer_doc, importer, d, "'{s}' declares no `({s} :name {s} …)` — an import may only rebind constants and fragments the imported document declares, under the same head", .{ path, head, want });
            return error.ImportError;
        }
    }
}

/// The document order the composition is written in: every document before
/// everything that imports it, siblings in written order.
///
/// Post-order depth-first over the graph phase 1 built, with an explicit stack
/// (no recursion, per the repo's Zig rules). A document re-entered before it
/// has been emitted is a cycle, which is the whole cycle check.
fn postOrder(b: *Builder) Error![]const u32 {
    const State = enum { unseen, entered, emitted };
    var state = [_]State{.unseen} ** MAX_DOCUMENTS;
    const Frame = struct { doc: u32, exit: bool };

    var stack: std.ArrayList(Frame) = .empty;
    var order: std.ArrayList(u32) = .empty;
    try stack.append(b.arena, .{ .doc = 0, .exit = false });

    // Bound: every frame pushed is the root's (1), an exit frame (one per
    // document, pushed on the unseen→entered transition), or a child frame
    // (one per EDGE, pushed when its parent expands). A document reached by
    // several importers is pushed once per incoming edge and pops through the
    // `.emitted` arm each time, so the bound is edge-shaped, not node-shaped:
    // a diamond of 44 documents already pops more than 2·MAX_DOCUMENTS, which
    // used to walk off the end of this loop into `unreachable` (§437).
    for (0..b.docs.items.len + b.edges.items.len + 2) |_| {
        const f = stack.pop() orelse break;
        std.debug.assert(f.doc < b.docs.items.len);
        if (f.exit) {
            if (state[f.doc] != .emitted) {
                state[f.doc] = .emitted;
                try order.append(b.arena, f.doc);
            }
            continue;
        }
        switch (state[f.doc]) {
            .emitted => continue, // a diamond's second edge; already placed
            .entered => {
                reportCycle(b, f.doc);
                return error.ImportError;
            },
            .unseen => state[f.doc] = .entered,
        }
        try stack.append(b.arena, .{ .doc = f.doc, .exit = true });
        // Children pushed in REVERSE so they pop in written order, which is
        // what puts siblings into the composition the way the author listed
        // them.
        const d = b.docs.items[f.doc];
        var k: u32 = d.child_len;
        for (0..d.child_len) |_| {
            k -= 1;
            try stack.append(b.arena, .{ .doc = b.edges.items[d.child_off + k], .exit = false });
        }
    } else {
        // Unreachable by the bound above, which counts every push there is.
        // It refuses rather than asserting anyway: this walk runs on a graph
        // the DOCUMENT shapes, and a cap the input can reach is the input's to
        // be refused for, named, not a panic in a shipped compiler (pitfall 89).
        report(b.options, "a composition's import graph is too large to walk", .{}, null);
        return error.ImportError;
    }

    // Every fetched document is reachable from the root, so a short order means
    // the walk lost one.
    std.debug.assert(order.items.len == b.docs.items.len);
    return order.toOwnedSlice(b.arena);
}

/// Concatenate the documents in `order` and build the region map.
fn build(b: *Builder, order: []const u32) Error!Composed {
    // A lone root would have returned null: `compose` only reaches here when at
    // least one import resolved, and a resolved import is a second document.
    std.debug.assert(order.len >= 2);

    var total: usize = 0;
    for (order) |i| total += b.docs.items[i].text.len + 1; // +1 separating newline

    const source = try b.gpa.allocSentinel(u8, total, 0);
    errdefer b.gpa.free(source);
    const regions = try b.gpa.alloc(Region, order.len);
    errdefer b.gpa.free(regions);
    const paths = try b.gpa.dupe(u8, b.paths.items);
    errdefer b.gpa.free(paths);

    var off: u32 = 0;
    for (order, 0..) |doc_index, n| {
        const d = b.docs.items[doc_index];
        @memcpy(source[off..][0..d.text.len], d.text);
        source[off + d.text.len] = '\n';
        const len: u32 = @intCast(d.text.len + 1);
        regions[n] = .{
            .start = off,
            .end = off + len,
            // Rebased onto the copy, so the region outlives this pass.
            .path = if (d.path_len == 0) "" else paths[d.path_off..][0..d.path_len],
        };
        off += len;
    }
    std.debug.assert(off == total);
    return .{ .source = source, .regions = regions, .paths = paths };
}

// --- small helpers ----------------------------------------------------------

/// The `:name` symbol of a form, or null if it has none (or it is not a
/// symbol — the validator's finding, not this pass's).
fn nameOf(tree: *const Tree, idx: NodeIndex) ?[]const u8 {
    std.debug.assert(tree.tagOf(idx) == .form);
    for (tree.formHeader(idx).children) |c| {
        if (tree.tagOf(c) != .kvpair) continue;
        const kv = tree.kvpairHeader(c);
        if (!std.mem.eql(u8, kv.key, "name")) continue;
        if (tree.tagOf(kv.value) != .symbol) return null;
        return tree.symbolText(kv.value);
    }
    return null;
}

/// Overwrite `[start, end)` with spaces, copying newlines through.
///
/// The newline rule is the whole point: spaces alone keep every byte at its
/// offset, and keeping `\n` keeps every LINE at its number. Delete instead and
/// both go, which is precisely how the pre-SJON importer earned its reputation.
fn blank(text: []u8, start: u32, end: u32) void {
    std.debug.assert(end >= start);
    std.debug.assert(end <= text.len);
    for (text[start..end]) |*c| {
        if (c.* != '\n') c.* = ' ';
    }
}

// --- reporting --------------------------------------------------------------

/// The one refusal channel, split exactly the way `Emitter.diagnose` splits it:
/// stderr for the CLI human when no sink is attached (`pngine compile` and
/// `render` attach none, and without this they would print only the caller's
/// generic "could not be composed" line), and the structured sink when one is.
/// Freestanding-guarded, because the browser compiler has no stderr and always
/// supplies a sink.
///
/// `loc` is null for the refusals that are properties of the GRAPH rather than
/// of a form — the cycle and the document cap. Neither has a node to point at:
/// the cycle is found in phase 2, after the tree that wrote the edge is gone,
/// and the cap is about the composition as a whole. Those stay headlines, which
/// is the path `cli/validate.zig`'s `reportFailure` documents for a genuinely
/// unlocatable check.
fn report(options: Options, comptime fmt: []const u8, args: anytype, loc: ?Diag.Located) void {
    comptime std.debug.assert(fmt.len > 0);
    if (builtin.target.os.tag != .freestanding and options.diag == null)
        std.debug.print("error: " ++ fmt ++ "\n", args);
    if (options.diag) |d| d.reportAt(.sjon, loc, "", fmt, args);
}

/// Report against a node of the IMPORTING document, with that document's own
/// line and column.
///
/// The position is measured in `importer`'s text rather than in the composition
/// — which does not exist yet when these refusals fire, and never will for the
/// ones that stop it. That is sound only because of the blanking rule at the top
/// of this file: an already-expanded document has had spans overwritten, but
/// every `\n` was copied through, so line numbers in the mutated buffer are
/// still the ones its author typed.
///
/// `file` is the importer's path, empty for the root — which is exactly the
/// convention `Diag.Located.file` wants: empty means "the document the user
/// named", and the CLI leaves those positions unlabelled.
///
/// The stderr line (the no-sink case, `pngine compile` and `render`) stays the
/// bare sentence. Every message routed here already spells the path or the name
/// it is about, so a reader without an editor is not missing anything; the
/// location is what makes it a squiggle rather than a sentence.
fn reportAt(
    b: *Builder,
    importer: u32,
    tree: *const Tree,
    node: NodeIndex,
    comptime fmt: []const u8,
    args: anytype,
) void {
    std.debug.assert(importer < b.docs.items.len);
    const doc = b.docs.items[importer];
    const lc = Diag.lineColOf(doc.text, tree.spanOf(node).start);
    report(b.options, fmt, args, .{ .line = lc.line, .col = lc.col, .file = b.pathOf(doc) });
}

fn reportCycle(b: *Builder, doc_index: u32) void {
    const path = b.pathOf(b.docs.items[doc_index]);
    const named = if (path.len == 0) "the root document" else path;
    report(b.options, "'{s}' imports itself, directly or through a chain — a document cannot extend something that extends it", .{named}, null);
}

/// The resolver's refusals, one sentence per `ReadError`, matching
/// `Emitter.unreadableFile` word for word where the case is the same.
///
/// ⚠️ The not-found wording is load-bearing beyond this file:
/// `scripts/check-doc-fences.mjs` admits `cannot read '<path>': no such file`
/// as fragment-explainable, which is what lets a documentation fence
/// illustrate `(import …)` without the gate failing.
fn reportRead(
    b: *Builder,
    importer: u32,
    tree: *const Tree,
    node: NodeIndex,
    path: []const u8,
    err: file_resolver.ReadError,
) void {
    switch (err) {
        error.NotFound => if (b.options.injected) {
            reportAt(b, importer, tree, node, "cannot read '{s}': it is not in the file table given to the compiler — a host with no filesystem must supply every document an import names", .{path});
        } else {
            reportAt(b, importer, tree, node, "cannot read '{s}': no such file — the path is resolved against the document's directory (the cwd for piped source)", .{path});
        },
        error.InvalidPath => reportAt(b, importer, tree, node, "cannot read '{s}': the path must be relative and stay inside the document's directory — no leading '/', no drive letter, no '..' that climbs out", .{path}),
        error.Symlink => reportAt(b, importer, tree, node, "cannot read '{s}': a directory or file on that path is a symbolic link — the path rules are text-only, so a link is refused rather than followed out of the document's directory", .{path}),
        error.TooLarge => reportAt(b, importer, tree, node, "cannot read '{s}': the document reaches the {d} byte limit for a referenced file", .{ path, MAX_DOCUMENT_BYTES }),
        error.ReadFailed => reportAt(b, importer, tree, node, "cannot read '{s}': the host would not hand the bytes over — a permission bit, a directory named as a file, or a host with no IO at all", .{path}),
        error.OutOfMemory => report(b.options, "out of memory reading '{s}'", .{path}, null),
    }
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;

/// A resolver over a fixed name→bytes table, so these tests need no filesystem
/// and no `std.Io`. Deliberately NOT `TableResolver`: that one is the browser's
/// wire format, and building it here would test the wire rather than the pass.
const StubResolver = struct {
    const Entry = struct { path: []const u8, text: []const u8 };
    entries: []const Entry,

    fn resolver(self: *StubResolver) FileResolver {
        return .{ .ctx = @ptrCast(self), .readFn = readFn };
    }

    fn readFn(ctx: *anyopaque, gpa: Allocator, path: []const u8, limit: u32) file_resolver.ReadError![]u8 {
        const self: *StubResolver = @ptrCast(@alignCast(ctx));
        std.debug.assert(path.len > 0);
        std.debug.assert(limit > 0);
        for (self.entries) |e| {
            if (!std.mem.eql(u8, e.path, path)) continue;
            if (e.text.len >= limit) return error.TooLarge;
            return gpa.dupe(u8, e.text);
        }
        return error.NotFound;
    }
};

fn composeStub(
    gpa: Allocator,
    root: [:0]const u8,
    entries: []const StubResolver.Entry,
) Error!?Composed {
    var stub = StubResolver{ .entries = entries };
    return compose(gpa, root, stub.resolver(), .{});
}
