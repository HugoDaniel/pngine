//! `pngine/draw-v1` — the `(draw-graph …)` stage × geometry fan-out.
//!
//! ## Design
//! - The author writes a table: `(stage …)` says what to draw INTO and which
//!   pipeline state every geometry in it shares; `(geometry …)` says what to
//!   draw and, through one `(in …)` per stage, which entry points draw it.
//!   The hook emits the cross product.
//! - Every child form the author writes is the GLOBAL form of that name — the
//!   same `(depth-stencil …)`, `(primitive …)`, `(bind-group …)`,
//!   `(vertex-buffer …)`, `(color-attachment …)` a pipeline, a group and a pass
//!   already take. `cloneForm` copies it into what is emitted, so a key added
//!   to one of those forms reaches the graph with no edit here. The exceptions
//!   are the three forms the graph itself fills a key of, declared slot-local
//!   so the head-set states the narrowing rather than this file: `(vertex …)`
//!   and `(fragment …)` under `(in …)` (no vertex layout, no color-target list),
//!   and `(color-target …)` under `(stage …)` (no `:format` — it is the
//!   attachment's).
//! - The carrier is one `(render-pass …)` per (stage, geometry), not a render
//!   bundle: this wire cannot express a depth-only bundle (docs/abi.md §6.5 —
//!   `cf_count` 0 is the frozen "guess the canvas" sentinel) and the native
//!   backend stubs bundles, which would leave the feature with no `test-render`
//!   gate. See docs/plans/polymorphism/05-draw-graph.md D1.
//!
//! ## Invariants
//! - Emission is grouped by head — every pipeline, then every bind group, then
//!   every pass, then the frame — and stage-major within each group, so the
//!   create sequence equals the one the same document hand-written produces.
//! - The load/store rewrite is recomputed from the stage on every compile: the
//!   stage's load ops and clear values land on the FIRST pass of the stage, its
//!   store ops on the LAST, and every pass between them loads and stores.
//! - A consumed form's keys are never cross-ref-checked, so every name this
//!   hook reads out of its own children is refused here or nowhere. Both halves
//!   are load-bearing: the sub-tree pass defers names (SJON ask 19), and a
//!   container that lowers is replaced by what it emitted, taking its children
//!   and their unresolved names with it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sjon = @import("sjon");

const Lowering = sjon.Lowering;
const EffectiveView = sjon.EffectiveView.EffectiveView;
const hooks = @import("hooks.zig");
const values = @import("values.zig");
const Reader = values.Reader;
const Ast = sjon.Ast;
const EmittedForm = Lowering.EmittedForm;
const EmittedKvpair = Lowering.EmittedKvpair;
const EmittedValue = Lowering.EmittedValue;

/// Bounds. A graph is a table an author writes by hand; these are two orders of
/// magnitude above the largest corpus document and exist so every loop below is
/// `for (0..MAX)` rather than open.
const MAX_STAGES: usize = 32;
const MAX_GEOMETRIES: usize = 128;
const MAX_DRAWS: usize = 512;
/// Attachments and groups per stage. `maxColorAttachments` is a WebGPU spec fact
/// shared with the emitter and the native backend, so it is read from the one
/// declaration rather than restated; the group ceiling is the wire's `:group`
/// index space.
const MAX_COLOR_ATTACHMENTS: usize = @import("bytecode").resource_limits.MAX_COLOR_ATTACHMENTS;
const MAX_STAGE_GROUPS: usize = 4;
/// Nodes one `cloneValue` may walk. `Lowering.MAX_LOWERED_DEPTH` bounds the
/// emitted side's nesting; this bounds the explicit stack that produces it.
/// The largest form a graph clones is a `(bind-group …)` of 16 entries, around
/// 100 nodes.
const MAX_CLONE_NODES: usize = 1024;

/// One `(stage …)` child, read once.
const Stage = struct {
    idx: Ast.NodeIndex,
    name: []const u8,
    /// `(color-attachment …)` children, in order.
    color: []const Ast.NodeIndex,
    /// The `(depth-stencil-attachment …)` child, if any.
    depth: ?Ast.NodeIndex,
    /// The pipeline state every geometry in this stage shares.
    depth_stencil: ?Ast.NodeIndex,
    primitive: ?Ast.NodeIndex,
    /// `(bind-group …)` children sorted by `:group`, which the checks below
    /// force to be `0..len-1`.
    groups: []const Ast.NodeIndex,
    /// `(color-target :format …)` derived from `color`, one per attachment.
    targets: []const []const u8,
    /// The stage's own `(color-target …)` children, in order, or empty. When it
    /// has them there is exactly one per colour attachment (`readStage` refuses
    /// any other count), and each is cloned into the emitted color-target with the
    /// derived format written in front of what the author put there.
    blends: []const Ast.NodeIndex,
    /// How many geometries draw in this stage — the load/store rewrite needs
    /// to know which pass is the last one.
    draws: u32 = 0,
    /// How many have been emitted so far, during the pass walk.
    emitted: u32 = 0,
};

/// One `(geometry …)` child, read once.
const Geometry = struct {
    idx: Ast.NodeIndex,
    name: []const u8,
    /// `(vertex-buffer …)` children, in order — the vertex stage's buffers.
    layout: []const Ast.NodeIndex,
    /// The one `(draw …)` / `(draw-indexed …)` / `(draw-indirect …)` /
    /// `(draw-indexed-indirect …)` child.
    draw: Ast.NodeIndex,
    /// `(in …)` children, in order.
    ins: []const Ast.NodeIndex,
};

/// One (stage, geometry) pair: everything the three emitted forms need.
const Pair = struct {
    stage: u32,
    geom: u32,
    in: Ast.NodeIndex,
    /// `<stage>__<geometry>`.
    name: []const u8,
    /// `<stage>__<geometry>__pipe`.
    pipe: []const u8,
};

/// `pngine/draw-v1` — expand `(draw-graph …)` into the cross product of its
/// stages and geometries.
pub fn drawV1(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    const view = input.view;
    const container = input.form_idx;

    // Named or not decides who owns the frame; the shared check is in hooks.zig
    // so the two containers cannot answer it differently. Refused before any work.
    const graph_name = Reader.initFromView(view).symbol(container, "name");
    try hooks.checkGraphFrameOwnership(arena, out, view, container, "draw-graph", graph_name);

    var stages = try collectStages(arena, out, input);
    const geoms = try collectGeometries(arena, out, input);

    // The pair table, stage-major: this order IS the frame's step order and the
    // id order of every emitted resource.
    const pairs = try buildPairs(arena, out, view, stages, geoms);
    try checkGeneratedNames(arena, out, view, pairs, stages, geoms);

    // Grouped by head, so the create sequence matches the hand-written twin's
    // (source phases emit all pipelines, then all groups, then all passes).
    for (pairs) |p| try emitPipeline(arena, out, input, container, &stages[p.stage], geoms[p.geom], p);
    for (pairs) |p| try emitBindGroups(arena, out, input, stages[p.stage], geoms[p.geom], p);

    var steps: std.ArrayList(EmittedValue) = .empty;
    try steps.appendSlice(arena, try readStepList(arena, view, container, "before"));
    for (pairs) |p| {
        try emitPass(arena, out, input, container, &stages[p.stage], geoms[p.geom], p);
        try steps.append(arena, .{ .symbol = p.name });
    }
    try steps.appendSlice(arena, try readStepList(arena, view, container, "after"));

    // Named: a `(step-group …)` the document's own frame performs, which is how
    // this graph composes with a `(pass-graph …)`. Unnamed: the frame itself,
    // with `:before` / `:after` around the graph's steps, byte-identical to what
    // this hook emitted before groups existed.
    try hooks.appendForm(arena, out, container, if (graph_name == null) "frame" else "step-group", &.{
        .{ .key = "name", .value = .{ .symbol = graph_name orelse "main" } },
        .{ .key = "perform", .value = .{ .vector = try steps.toOwnedSlice(arena) } },
    }, &.{});
}

// ============================================================================
// Reading the graph
// ============================================================================

fn collectStages(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    input: *const Lowering.LoweringInput,
) Lowering.LoweringError![]Stage {
    const view = input.view;
    var list: std.ArrayList(Stage) = .empty;
    for (view.tree.formHeader(input.form_idx).children) |child| {
        if (view.tree.tagOf(child) != .form) continue;
        if (!std.mem.eql(u8, view.tree.formHeader(child).head, "stage")) continue;
        if (list.items.len == MAX_STAGES) return out.failAt(
            arena,
            view.tree.formHeader(child).head_span,
            "`(draw-graph …)` holds more than {d} `(stage …)` children",
            .{MAX_STAGES},
        );
        try list.append(arena, try readStage(arena, out, input, child));
    }
    if (list.items.len == 0) return out.fail(
        arena,
        "`(draw-graph …)` declares no `(stage …)` — a draw graph needs at least one stage to draw into",
        .{},
    );
    // Also a backstop: two `(stage :name …)` children are
    // `duplicate_cross_ref_target` to the validator, since `stage` is a
    // cross-ref target.
    for (list.items, 0..) |s, i| {
        for (list.items[0..i]) |prior| {
            if (!std.mem.eql(u8, prior.name, s.name)) continue;
            return out.failAt(arena, view.tree.spanOf(s.idx), "`(draw-graph …)` declares two stages named '{s}' — an `(in :stage {s})` could not say which", .{ s.name, s.name });
        }
    }
    return list.items;
}

fn readStage(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    input: *const Lowering.LoweringInput,
    idx: Ast.NodeIndex,
) Lowering.LoweringError!Stage {
    const view = input.view;
    const r = Reader.initFromView(view);
    const name = r.symbol(idx, "name") orelse
        return out.failAt(arena, view.tree.spanOf(idx), "a `(stage …)` of this `(draw-graph …)` has no `:name`", .{});

    var color: std.ArrayList(Ast.NodeIndex) = .empty;
    var blends: std.ArrayList(Ast.NodeIndex) = .empty;
    var groups: std.ArrayList(Ast.NodeIndex) = .empty;
    var depth: ?Ast.NodeIndex = null;
    var depth_stencil: ?Ast.NodeIndex = null;
    var primitive: ?Ast.NodeIndex = null;
    for (view.tree.formHeader(idx).children) |c| {
        if (view.tree.tagOf(c) != .form) continue;
        const head = view.tree.formHeader(c).head;
        if (std.mem.eql(u8, head, "color-attachment")) {
            if (color.items.len == MAX_COLOR_ATTACHMENTS) return out.failAt(arena, view.tree.spanOf(c), "stage '{s}' has more than {d} `(color-attachment …)` children", .{ name, MAX_COLOR_ATTACHMENTS });
            try color.append(arena, c);
        } else if (std.mem.eql(u8, head, "color-target")) {
            if (blends.items.len == MAX_COLOR_ATTACHMENTS) return out.failAt(arena, view.tree.spanOf(c), "stage '{s}' has more than {d} `(color-target …)` children", .{ name, MAX_COLOR_ATTACHMENTS });
            try blends.append(arena, c);
        } else if (std.mem.eql(u8, head, "depth-stencil-attachment")) {
            depth = c;
        } else if (std.mem.eql(u8, head, "depth-stencil")) {
            depth_stencil = c;
        } else if (std.mem.eql(u8, head, "primitive")) {
            primitive = c;
        } else if (std.mem.eql(u8, head, "bind-group")) {
            if (groups.items.len == MAX_STAGE_GROUPS) return out.failAt(arena, view.tree.spanOf(c), "stage '{s}' has more than {d} `(bind-group …)` children", .{ name, MAX_STAGE_GROUPS });
            try groups.append(arena, c);
        }
    }
    if (color.items.len == 0 and depth == null) return out.failAt(
        arena,
        view.tree.spanOf(idx),
        "stage '{s}' has no attachment — a render pass writes somewhere, so a stage needs a `(color-attachment …)` or a `(depth-stencil-attachment …)`",
        .{name},
    );
    // Positional pairing, so the two lists are the same length or the pairing
    // is a guess. Zero color-targets is the whole feature staying out of the
    // way: every color-target is then the derived format alone, as it was
    // before the key existed.
    if (blends.items.len > 0 and blends.items.len != color.items.len) return out.failAt(
        arena,
        view.tree.spanOf(blends.items[0]),
        "stage '{s}' declares {d} `(color-target …)` child(ren) and {d} `(color-attachment …)` child(ren) — a stage's color-targets pair with its attachments by POSITION, so it needs one color-target per attachment or none at all",
        .{ name, blends.items.len, color.items.len },
    );
    const sorted = try sortStageGroups(arena, out, view, name, groups.items);
    // Every attachment, both kinds: the graph builds no `(multisample …)`, so
    // a multisampled attachment would face a single-sampled pipeline.
    for (color.items) |att| try checkAttachmentTexture(arena, out, view, name, att);
    if (depth) |att| try checkAttachmentTexture(arena, out, view, name, att);
    const targets = try deriveTargets(arena, out, input, name, color.items);
    return .{
        .idx = idx,
        .name = name,
        .color = color.items,
        .depth = depth,
        .depth_stencil = depth_stencil,
        .primitive = primitive,
        .groups = sorted,
        .targets = targets,
        .blends = blends.items,
    };
}

/// A pass's `:bind-groups` is a dense positional list, so the stage's groups
/// must carry `:group` `0..N-1`, each exactly once. Returns them in that order.
fn sortStageGroups(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    view: EffectiveView,
    stage: []const u8,
    groups: []const Ast.NodeIndex,
) Lowering.LoweringError![]const Ast.NodeIndex {
    const r = Reader.initFromView(view);
    const sorted = try arena.alloc(Ast.NodeIndex, groups.len);
    var seen = [_]bool{false} ** MAX_STAGE_GROUPS;
    for (groups) |g| {
        // The graph supplies both keys, so authoring either is a claim the
        // hook would silently overrule (the §409 class).
        if (r.authorNode(g, "layout")) |n| return out.failAt(arena, view.tree.spanOf(n), "stage '{s}': a `(bind-group …)` here may not name a `:layout` — the graph derives one instance per (stage, geometry) pipeline and fills the layout in", .{stage});
        if (r.authorNode(g, "prune-unused")) |n| return out.failAt(arena, view.tree.spanOf(n), "stage '{s}': a `(bind-group …)` here may not set `:prune-unused` — the graph sets it on every instance it emits, so the key is redundant", .{stage});
        const gname = r.symbol(g, "name") orelse
            return out.failAt(arena, view.tree.spanOf(g), "stage '{s}': a `(bind-group …)` here has no `:name` — the graph names its instances after it", .{stage});
        const index = groupIndexOf(r, g);
        if (index >= groups.len) return out.failAt(
            arena,
            view.tree.spanOf(g),
            "stage '{s}': bind group '{s}' is `:group {d}`, but the stage declares {d} group(s) — a pass binds groups 0..N-1 as a dense list, so the indices must be 0 to {d}",
            .{ stage, gname, index, groups.len, groups.len - 1 },
        );
        if (seen[index]) return out.failAt(arena, view.tree.spanOf(g), "stage '{s}': two `(bind-group …)` children are `:group {d}`", .{ stage, index });
        seen[index] = true;
        sorted[index] = g;
    }
    return sorted;
}

/// One `(color-target :format …)` per color attachment: the canvas format for
/// `context-current-texture`, otherwise the named `(texture …)`'s own `:format`.
///
/// This is the pairing 04 pinned as its first question, and it is not a pairing
/// any more: the format is stated once, on the texture, and read here through
/// the same whole-document lookup `(pass … :reads …)` uses (§419).
fn deriveTargets(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    input: *const Lowering.LoweringInput,
    stage: []const u8,
    color: []const Ast.NodeIndex,
) Lowering.LoweringError![]const []const u8 {
    const view = input.view;
    const r = Reader.initFromView(view);
    const formats = try arena.alloc([]const u8, color.len);
    for (color, 0..) |att, i| {
        const target_view = r.symbol(att, "view") orelse
            return out.failAt(arena, view.tree.spanOf(att), "stage '{s}': a `(color-attachment …)` has no `:view`", .{stage});
        if (std.mem.eql(u8, target_view, "context-current-texture")) {
            formats[i] = "preferred-canvas-format";
            continue;
        }
        const tex = try findTexture(arena, out, view, stage, att, target_view);
        formats[i] = r.symbol(tex, "format") orelse
            return out.failAt(arena, view.tree.spanOf(att), "stage '{s}': texture '{s}' is a color attachment here but declares no `:format`, so the pipeline's color target has none to take", .{ stage, target_view });
    }
    return formats;
}

/// The `(texture :name …)` a stage attaches, for either kind of attachment.
///
/// This refusal is the only one there is. The sub-tree SJON validates before
/// calling a hook does not adjudicate names at all (`defer_cross_refs`), and a
/// container that lowers is replaced by what it emitted — its children go with
/// it, so the final forest never sees this `:view` either. A missing texture is
/// caught here or nowhere.
fn findTexture(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    view: EffectiveView,
    stage: []const u8,
    att: Ast.NodeIndex,
    name: []const u8,
) Lowering.LoweringError!Ast.NodeIndex {
    return findTextureOpt(view, name) orelse
        out.failAt(arena, view.tree.spanOf(att), "stage '{s}': attachment `:view {s}` names no `(texture …)` in this document", .{ stage, name });
}

fn findTextureOpt(view: EffectiveView, name: []const u8) ?Ast.NodeIndex {
    const r = Reader.initFromView(view);
    for (view.tree.root) |idx| {
        if (view.tree.tagOf(idx) != .form) continue;
        if (!std.mem.eql(u8, view.tree.formHeader(idx).head, "texture")) continue;
        const tname = r.symbol(idx, "name") orelse continue;
        if (std.mem.eql(u8, tname, name)) return idx;
    }
    return null;
}

/// The graph builds no `(multisample …)`, so a multisampled attachment would
/// give the pipeline sample count 1 and the pass count N, with nothing said at
/// compile time and a validation error at the first draw.
///
/// Skips `context-current-texture` (never multisampled) and any name that does
/// not resolve — an unresolved attachment is the schema's to report, and it
/// does, on the `:view` value itself.
fn checkAttachmentTexture(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    view: EffectiveView,
    stage: []const u8,
    att: Ast.NodeIndex,
) Lowering.LoweringError!void {
    const r = Reader.initFromView(view);
    const name = r.symbol(att, "view") orelse return;
    if (std.mem.eql(u8, name, "context-current-texture")) return;
    const tex = findTextureOpt(view, name) orelse return;
    // The schema's `:repr u32` check on `:sample-count` runs AFTER lowering, so
    // a number it will refuse — out of u32 range, negative, NaN — reaches this
    // hook first. `@intFromFloat` traps on every one of those, which turned a
    // bad `:sample-count` into a compiler panic; range-test before the cast,
    // the way `groupIndexOf` below already does (§437). A value that fails
    // `> 1` is left to the schema, which refuses it with the better message.
    const raw = r.number(tex, "sample-count") orelse 1;
    if (!(raw > 1)) return;
    const count: u32 = if (raw >= @as(f64, std.math.maxInt(u32)))
        std.math.maxInt(u32)
    else
        @intFromFloat(@round(raw));
    return out.failAt(
        arena,
        view.tree.spanOf(att),
        "stage '{s}': texture '{s}' is `:sample-count {d}`, and a `(draw-graph …)` emits no `(multisample …)` — the generated pipeline would be single-sampled against a multisampled attachment; write this stage as hand-authored passes",
        .{ stage, name, count },
    );
}

fn collectGeometries(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    input: *const Lowering.LoweringInput,
) Lowering.LoweringError![]const Geometry {
    const view = input.view;
    var list: std.ArrayList(Geometry) = .empty;
    for (view.tree.formHeader(input.form_idx).children) |child| {
        if (view.tree.tagOf(child) != .form) continue;
        if (!std.mem.eql(u8, view.tree.formHeader(child).head, "geometry")) continue;
        if (list.items.len == MAX_GEOMETRIES) return out.failAt(
            arena,
            view.tree.formHeader(child).head_span,
            "`(draw-graph …)` holds more than {d} `(geometry …)` children",
            .{MAX_GEOMETRIES},
        );
        try list.append(arena, try readGeometry(arena, out, view, child));
    }
    if (list.items.len == 0) return out.fail(
        arena,
        "`(draw-graph …)` declares no `(geometry …)` — a draw graph needs at least one thing to draw",
        .{},
    );
    for (list.items, 0..) |g, i| {
        for (list.items[0..i]) |prior| {
            if (!std.mem.eql(u8, prior.name, g.name)) continue;
            return out.failAt(arena, view.tree.spanOf(g.idx), "`(draw-graph …)` declares two geometries named '{s}' — the forms they generate would collide", .{g.name});
        }
    }
    return list.items;
}

fn readGeometry(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    view: EffectiveView,
    idx: Ast.NodeIndex,
) Lowering.LoweringError!Geometry {
    const name = Reader.initFromView(view).symbol(idx, "name") orelse
        return out.failAt(arena, view.tree.spanOf(idx), "a `(geometry …)` of this `(draw-graph …)` has no `:name`", .{});

    var layout: std.ArrayList(Ast.NodeIndex) = .empty;
    var ins: std.ArrayList(Ast.NodeIndex) = .empty;
    var draw: ?Ast.NodeIndex = null;
    for (view.tree.formHeader(idx).children) |c| {
        if (view.tree.tagOf(c) != .form) continue;
        const head = view.tree.formHeader(c).head;
        if (std.mem.eql(u8, head, "vertex-buffer")) {
            try layout.append(arena, c);
        } else if (std.mem.eql(u8, head, "in")) {
            try ins.append(arena, c);
        } else if (isDrawHead(head)) {
            // The head-set caps each of the four at one; that they are one
            // between them is this check.
            if (draw) |prior| return out.failAt(arena, view.tree.spanOf(c), "geometry '{s}' has two draw commands, `({s} …)` and `({s} …)` — a geometry is one draw", .{ name, view.tree.formHeader(prior).head, head });
            draw = c;
        }
    }
    if (draw == null) return out.failAt(arena, view.tree.spanOf(idx), "geometry '{s}' has no draw command — add a `(draw …)`, `(draw-indexed …)`, `(draw-indirect …)` or `(draw-indexed-indirect …)`", .{name});
    if (ins.items.len == 0) return out.failAt(arena, view.tree.spanOf(idx), "geometry '{s}' names no `(in :stage …)`, so it is drawn nowhere and emits nothing", .{name});
    return .{ .idx = idx, .name = name, .layout = layout.items, .draw = draw.?, .ins = ins.items };
}

fn isDrawHead(head: []const u8) bool {
    return std.mem.eql(u8, head, "draw") or
        std.mem.eql(u8, head, "draw-indexed") or
        std.mem.eql(u8, head, "draw-indirect") or
        std.mem.eql(u8, head, "draw-indexed-indirect");
}

/// The (stage, geometry) table in stage-major order, which is the frame's step
/// order and the id order of everything emitted.
fn buildPairs(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    view: EffectiveView,
    stages: []Stage,
    geoms: []const Geometry,
) Lowering.LoweringError![]const Pair {
    const r = Reader.initFromView(view);
    // A backstop: `stage-ref` is a real cross-ref and the validator resolves
    // it against the `(stage :name …)` children, so a typo is refused before
    // this runs. It stays because a registry-less caller reaches the hook with
    // nothing checked, and because naming the stages that DO exist is worth a
    // sentence.
    for (geoms) |g| {
        for (g.ins) |in| {
            const want = r.symbol(in, "stage") orelse
                return out.failAt(arena, view.tree.spanOf(in), "geometry '{s}': an `(in …)` has no `:stage`", .{g.name});
            if (stageIndex(stages, want) != null) continue;
            return out.failAt(arena, view.tree.spanOf(in), "geometry '{s}': `(in :stage {s})` names no stage of this graph — it declares {s}", .{ g.name, want, try stageList(arena, stages) });
        }
    }

    var pairs: std.ArrayList(Pair) = .empty;
    for (stages, 0..) |*s, si| {
        for (geoms, 0..) |g, gi| {
            const in = inForStage(r, g, s.name) orelse continue;
            if (pairs.items.len == MAX_DRAWS) return out.failAt(arena, view.tree.spanOf(g.idx), "`(draw-graph …)` expands to more than {d} draws", .{MAX_DRAWS});
            const name = try std.fmt.allocPrint(arena, "{s}__{s}", .{ s.name, g.name });
            try pairs.append(arena, .{
                .stage = @intCast(si),
                .geom = @intCast(gi),
                .in = in,
                .name = name,
                .pipe = try std.fmt.allocPrint(arena, "{s}__pipe", .{name}),
            });
            s.draws += 1;
        }
        if (s.draws == 0) return out.failAt(
            arena,
            view.tree.spanOf(s.idx),
            "stage '{s}' is named by no `(in …)`, so no geometry draws in it and it emits no pass — its attachments are never cleared",
            .{s.name},
        );
    }
    return pairs.items;
}

fn stageIndex(stages: []const Stage, name: []const u8) ?usize {
    for (stages, 0..) |s, i| {
        if (std.mem.eql(u8, s.name, name)) return i;
    }
    return null;
}

fn inForStage(r: Reader, g: Geometry, stage: []const u8) ?Ast.NodeIndex {
    for (g.ins) |in| {
        const want = r.symbol(in, "stage") orelse continue;
        if (std.mem.eql(u8, want, stage)) return in;
    }
    return null;
}

fn stageList(arena: Allocator, stages: []const Stage) Lowering.LoweringError![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (stages, 0..) |s, i| {
        if (i > 0) try buf.appendSlice(arena, ", ");
        try buf.print(arena, "'{s}'", .{s.name});
    }
    return buf.items;
}

/// A generated name equal to a top-level form's `:name` would intern to the
/// same id and alias two resources without a word — `checkNameNamespace` in the
/// emitter walks the SOURCE forest only, so this collision is nobody else's.
fn checkGeneratedNames(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    view: EffectiveView,
    pairs: []const Pair,
    stages: []const Stage,
    geoms: []const Geometry,
) Lowering.LoweringError!void {
    const r = Reader.initFromView(view);
    var generated: std.ArrayList([]const u8) = .empty;
    for (pairs) |p| {
        try generated.append(arena, p.name);
        try generated.append(arena, p.pipe);
        for (stages[p.stage].groups) |g| {
            const gname = r.symbol(g, "name") orelse continue;
            try generated.append(arena, try std.fmt.allocPrint(arena, "{s}__{s}", .{ gname, geoms[p.geom].name }));
        }
    }
    for (view.tree.root) |idx| {
        if (view.tree.tagOf(idx) != .form) continue;
        const head = view.tree.formHeader(idx).head;
        const name = r.symbol(idx, "name") orelse continue;
        for (generated.items) |gen| {
            if (!std.mem.eql(u8, name, gen)) continue;
            return out.failAt(arena, view.tree.spanOf(idx), "this ({s} …) is named '{s}', which is also a name `(draw-graph …)` gives one of the forms it generates — the two would intern to one id; rename one of them", .{ head, name });
        }
    }
}

/// `:before` / `:after`, as frame-step symbols. The emitted `(frame …)` IS in
/// the final forest, so its steps are cross-ref-checked there.
fn readStepList(
    arena: Allocator,
    view: EffectiveView,
    container: Ast.NodeIndex,
    key: []const u8,
) Lowering.LoweringError![]const EmittedValue {
    const elems = Reader.initFromView(view).vectorNodes(container, key) orelse return &.{};
    const list = try arena.alloc(EmittedValue, elems.len);
    for (elems, 0..) |e, i| {
        // The element kind is `frame-step`, a symbol, so nothing else reaches
        // here after validation.
        if (view.tree.tagOf(e) != .symbol) return &.{};
        list[i] = .{ .symbol = try arena.dupe(u8, view.tree.symbolText(e)) };
    }
    return list;
}

// ============================================================================
// Emission
// ============================================================================

/// `(render-pipeline :name <stage>__<geom>__pipe :layout auto …)`.
fn emitPipeline(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    input: *const Lowering.LoweringInput,
    container: Ast.NodeIndex,
    stage: *const Stage,
    geom: Geometry,
    p: Pair,
) Lowering.LoweringError!void {
    const view = input.view;
    var children: std.ArrayList(EmittedForm) = .empty;

    // Vertex stage: the `(in …)`'s module + entry, its `(constant …)` children,
    // and the GEOMETRY's vertex layout — which is why the slot-local `(vertex …)`
    // admits no `(vertex-buffer …)` of its own.
    const vs = childForm(view, p.in, "vertex") orelse
        return out.failAt(arena, view.tree.spanOf(p.in), "geometry '{s}': the `(in :stage {s})` has no `(vertex …)`", .{ geom.name, stage.name });
    var vs_form = try cloneForm(arena, out, input, vs);
    var vs_children: std.ArrayList(EmittedValue) = .empty;
    try vs_children.appendSlice(arena, vs_form.children);
    for (geom.layout) |vb| try vs_children.append(arena, .{ .form = try cloneForm(arena, out, input, vb) });
    vs_form.children = try vs_children.toOwnedSlice(arena);
    try children.append(arena, vs_form);

    // Fragment stage: absent for a depth-only draw. Its targets come from the
    // stage's color attachments, one each, in order.
    if (childForm(view, p.in, "fragment")) |fs| {
        if (stage.targets.len == 0) return out.failAt(
            arena,
            view.tree.spanOf(fs),
            "geometry '{s}': the `(in :stage {s})` has a `(fragment …)`, but stage '{s}' has no `(color-attachment …)` for it to write — drop the fragment stage, or give the stage a color attachment",
            .{ geom.name, stage.name, stage.name },
        );
        var fs_form = try cloneForm(arena, out, input, fs);
        var fs_children: std.ArrayList(EmittedValue) = .empty;
        for (stage.targets, 0..) |fmt, i| {
            // With no `(color-target …)` on the stage this is the derived format and
            // nothing else — the shape every graph emitted before the key
            // existed, which is what keeps it additive. With one, the author's
            // blend state and write mask ride along and the format is still
            // the attachment's.
            var t: EmittedForm = if (stage.blends.len > 0)
                try cloneForm(arena, out, input, stage.blends[i])
            else
                .{ .head = "color-target", .kvpairs = &.{}, .source_form_idx = container };
            var kvs: std.ArrayList(EmittedKvpair) = .empty;
            try kvs.append(arena, .{ .key = "format", .value = .{ .symbol = fmt } });
            try kvs.appendSlice(arena, t.kvpairs);
            t.kvpairs = try kvs.toOwnedSlice(arena);
            try fs_children.append(arena, .{ .form = t });
        }
        try fs_children.appendSlice(arena, fs_form.children);
        fs_form.children = try fs_children.toOwnedSlice(arena);
        try children.append(arena, fs_form);
    }

    // The `(in …)`'s `(primitive …)` replaces the stage's; `(depth-stencil …)`
    // is the stage's alone (a stage whose geometries wanted different depth
    // state would be two stages).
    const prim = childForm(view, p.in, "primitive") orelse stage.primitive;
    if (prim) |n| try children.append(arena, try cloneForm(arena, out, input, n));
    if (stage.depth_stencil) |n| try children.append(arena, try cloneForm(arena, out, input, n));

    try hooks.appendForm(arena, out, container, "render-pipeline", &.{
        .{ .key = "name", .value = .{ .symbol = p.pipe } },
        .{ .key = "layout", .value = .{ .symbol = "auto" } },
    }, children.items);
}

/// One `(bind-group … :layout <this pipeline> :prune-unused true)` per group the
/// stage declares.
///
/// `:prune-unused` unconditionally: the entry list is written once, on the
/// stage, and each pipeline's auto-layout decides what survives. That is what
/// makes CONTRIBUTING pitfall 37 unexpressible here rather than merely avoided.
fn emitBindGroups(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    input: *const Lowering.LoweringInput,
    stage: Stage,
    geom: Geometry,
    p: Pair,
) Lowering.LoweringError!void {
    for (stage.groups) |g| {
        var form = try cloneForm(arena, out, input, g);
        const base = Reader.initFromView(input.view).symbol(g, "name").?; // checked in sortStageGroups
        var kvs: std.ArrayList(EmittedKvpair) = .empty;
        for (form.kvpairs) |kv| {
            if (std.mem.eql(u8, kv.key, "name")) continue;
            try kvs.append(arena, kv);
        }
        try kvs.append(arena, .{ .key = "name", .value = .{ .symbol = try std.fmt.allocPrint(arena, "{s}__{s}", .{ base, geom.name }) } });
        try kvs.append(arena, .{ .key = "layout", .value = .{ .symbol = p.pipe } });
        try kvs.append(arena, .{ .key = "prune-unused", .value = .{ .boolean = true } });
        form.kvpairs = try kvs.toOwnedSlice(arena);
        try out.append(arena, form);
    }
}

/// `(render-pass :name <stage>__<geom> …)` — the stage's attachments with the
/// load/store rewrite, the geometry's buffers and draw, the groups above.
fn emitPass(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    input: *const Lowering.LoweringInput,
    container: Ast.NodeIndex,
    stage: *Stage,
    geom: Geometry,
    p: Pair,
) Lowering.LoweringError!void {
    const view = input.view;
    const r = Reader.initFromView(view);
    const first = stage.emitted == 0;
    const last = stage.emitted + 1 == stage.draws;
    stage.emitted += 1;

    var children: std.ArrayList(EmittedForm) = .empty;
    for (stage.color) |att| try children.append(arena, try rewriteAttachment(arena, out, input, att, first, last, &.{ "load-op", "store-op", "clear-value" }));
    if (stage.depth) |att| try children.append(arena, try rewriteAttachment(arena, out, input, att, first, last, &.{ "depth-load-op", "depth-store-op", "depth-clear-value", "stencil-load-op", "stencil-store-op", "stencil-clear-value" }));
    try children.append(arena, try cloneForm(arena, out, input, geom.draw));

    var kvs: std.ArrayList(EmittedKvpair) = .empty;
    try kvs.append(arena, .{ .key = "name", .value = .{ .symbol = p.name } });
    try kvs.append(arena, .{ .key = "pipeline", .value = .{ .symbol = p.pipe } });
    if (r.authorNode(geom.idx, "vertex-buffers")) |n| try kvs.append(arena, .{ .key = "vertex-buffers", .value = try cloneValue(arena, out, input, n, false) });
    if (r.authorNode(geom.idx, "index-buffer")) |n| try kvs.append(arena, .{ .key = "index-buffer", .value = try cloneValue(arena, out, input, n, false) });
    if (stage.groups.len > 0) {
        const names = try arena.alloc(EmittedValue, stage.groups.len);
        for (stage.groups, 0..) |g, i| {
            const base = r.symbol(g, "name").?; // checked in sortStageGroups
            names[i] = .{ .symbol = try std.fmt.allocPrint(arena, "{s}__{s}", .{ base, geom.name }) };
        }
        try kvs.append(arena, .{ .key = "bind-groups", .value = .{ .vector = names } });
    }

    try out.append(arena, .{
        .head = "render-pass",
        .kvpairs = try kvs.toOwnedSlice(arena),
        .children = try hooks.formChildren(arena, children.items),
        .source_form_idx = container,
    });
}

/// The stage's attachment as this pass needs it: the authored load ops and
/// clear values only on the FIRST pass of the stage, the authored store ops
/// only on the LAST, `load` / `store` in between.
///
/// `ops` is `{load-op, store-op, clear-value}` triples — one for a color
/// attachment, two (depth and stencil) for a depth-stencil one — and each
/// triple is rewritten only if the stage authored its load op, so a stencil
/// pair the author left out stays out.
fn rewriteAttachment(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    input: *const Lowering.LoweringInput,
    att: Ast.NodeIndex,
    first: bool,
    last: bool,
    ops: []const []const u8,
) Lowering.LoweringError!EmittedForm {
    std.debug.assert(ops.len % 3 == 0); // pre: (load, store, clear) triples
    var form = try cloneForm(arena, out, input, att);
    if (first and last) return form;

    var kvs: std.ArrayList(EmittedKvpair) = .empty;
    for (form.kvpairs) |kv| {
        var replaced = false;
        var t: usize = 0;
        while (t < ops.len) : (t += 3) {
            if (std.mem.eql(u8, kv.key, ops[t]) and !first) {
                try kvs.append(arena, .{ .key = kv.key, .value = .{ .symbol = "load" } });
                replaced = true;
            } else if (std.mem.eql(u8, kv.key, ops[t + 1]) and !last) {
                // Not the stage's store op: an earlier pass of the stage must
                // keep what it drew, or the next one loads nothing.
                try kvs.append(arena, .{ .key = kv.key, .value = .{ .symbol = "store" } });
                replaced = true;
            } else if (std.mem.eql(u8, kv.key, ops[t + 2]) and !first) {
                // A clear value beside `load` is refused by the emitter, and
                // WebGPU would ignore it — drop it with the clear.
                replaced = true;
            }
        }
        if (!replaced) try kvs.append(arena, kv);
    }
    form.kvpairs = try kvs.toOwnedSlice(arena);
    return form;
}

// ============================================================================
// Cloning a source form into an emitted one
// ============================================================================

/// Copy `node`'s kvpairs and positional children verbatim. This is what lets
/// the graph's children BE the global forms: nothing here knows which keys
/// `(depth-stencil …)` has.
///
/// Complexity: O(nodes in the subtree). No recursion — see `cloneValue`.
fn cloneForm(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    input: *const Lowering.LoweringInput,
    node: Ast.NodeIndex,
) Lowering.LoweringError!EmittedForm {
    std.debug.assert(input.view.tree.tagOf(node) == .form); // pre: a form to clone
    const v = try cloneValue(arena, out, input, node, false);
    std.debug.assert(v == .form); // post: a form node clones to a form value
    return v.form;
}

/// One value, and everything under it.
///
/// Two passes over an explicit stack rather than a recursive descent (the
/// repo's Zig rules). Pass one collects the subtree in PRE-order, which puts
/// every parent ahead of its descendants; pass two walks that list backwards,
/// so a node's children are already built when it is reached and can be looked
/// up by node index.
///
/// `in_kvpair` decides what a `.form` node means: in VALUE position a form is
/// an expression (`:array-stride (* 4 6)`), folded through the lowering env
/// because `EmittedValue` has no expression variant; as a positional child of
/// another form it is a nested data form and is cloned. An expression's own
/// children are never walked — the fold consumes the whole subtree.
///
/// A vector PROPAGATES value position to its elements, because every vector the
/// schema declares holds a scalar, symbol or cross-ref element kind — never a
/// nested form. So a form inside one can only be an expression, and
/// `:workgroups [(ceil (/ N 64))]` is as ordinary in a cloned child as
/// `:array-stride (* 4 6)` is. Treating those elements as positional children
/// cloned `(ceil …)` through as a data form with the head `ceil`, which the
/// emitter then refused — a legal document, refused for its arithmetic (§438).
fn cloneValue(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    input: *const Lowering.LoweringInput,
    root: Ast.NodeIndex,
    root_in_kvpair: bool,
) Lowering.LoweringError!EmittedValue {
    const view = input.view;
    const Item = struct { node: Ast.NodeIndex, in_kvpair: bool };

    var order: std.ArrayList(Item) = .empty;
    var stack: std.ArrayList(Item) = .empty;
    try stack.append(arena, .{ .node = root, .in_kvpair = root_in_kvpair });
    for (0..MAX_CLONE_NODES) |_| {
        const item = stack.pop() orelse break;
        try order.append(arena, item);
        // An expression is folded whole, so its operands are not values to build.
        const is_expression = view.tree.tagOf(item.node) == .form and item.in_kvpair;
        if (is_expression) continue;
        switch (view.tree.tagOf(item.node)) {
            .form => for (view.tree.formHeader(item.node).children) |c| {
                if (view.tree.tagOf(c) == .kvpair) {
                    try stack.append(arena, .{ .node = view.tree.kvpairHeader(c).value, .in_kvpair = true });
                } else {
                    try stack.append(arena, .{ .node = c, .in_kvpair = false });
                }
            },
            .vector => for (view.tree.vectorElements(item.node)) |e| {
                try stack.append(arena, .{ .node = e, .in_kvpair = item.in_kvpair });
            },
            else => {},
        }
    } else return out.failAt(arena, view.tree.spanOf(root), "`(draw-graph …)`: this form holds more than {d} nodes", .{MAX_CLONE_NODES});

    var built: std.AutoHashMapUnmanaged(u32, EmittedValue) = .empty;
    var i = order.items.len;
    while (i > 0) {
        i -= 1;
        const item = order.items[i];
        try built.put(arena, @intFromEnum(item.node), try buildValue(arena, out, input, item.node, item.in_kvpair, &built));
    }
    return built.get(@intFromEnum(root)).?; // the root was the first item pushed
}

/// One node's `EmittedValue`, with every child already in `built`.
fn buildValue(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    input: *const Lowering.LoweringInput,
    node: Ast.NodeIndex,
    in_kvpair: bool,
    built: *const std.AutoHashMapUnmanaged(u32, EmittedValue),
) Lowering.LoweringError!EmittedValue {
    const view = input.view;
    return switch (view.tree.tagOf(node)) {
        .number => .{ .number = view.tree.numberOf(node) },
        .number_i64 => .{ .number = @floatFromInt(view.tree.numberI64Of(node)) },
        .number_u64 => .{ .number = @floatFromInt(view.tree.numberU64Of(node)) },
        .string => .{ .string = try arena.dupe(u8, view.tree.stringText(node)) },
        .symbol => .{ .symbol = try arena.dupe(u8, view.tree.symbolText(node)) },
        .keyword => .{ .keyword = try arena.dupe(u8, view.tree.keywordText(node)) },
        .boolean_true => .{ .boolean = true },
        .boolean_false => .{ .boolean = false },
        .nil => .nil,
        .vector => blk: {
            const elems = view.tree.vectorElements(node);
            const vals = try arena.alloc(EmittedValue, elems.len);
            for (elems, 0..) |e, i| vals[i] = built.get(@intFromEnum(e)).?;
            break :blk .{ .vector = vals };
        },
        .form => blk: {
            if (in_kvpair) break :blk .{ .number = try foldExpression(arena, out, input, node) };
            const hdr = view.tree.formHeader(node);
            var kvs: std.ArrayList(EmittedKvpair) = .empty;
            var children: std.ArrayList(EmittedValue) = .empty;
            for (hdr.children) |c| {
                if (view.tree.tagOf(c) == .kvpair) {
                    const kv = view.tree.kvpairHeader(c);
                    try kvs.append(arena, .{
                        .key = try arena.dupe(u8, kv.key),
                        .value = built.get(@intFromEnum(kv.value)).?,
                    });
                } else {
                    try children.append(arena, built.get(@intFromEnum(c)).?);
                }
            }
            break :blk .{ .form = .{
                .head = try arena.dupe(u8, hdr.head),
                .kvpairs = try kvs.toOwnedSlice(arena),
                .children = try children.toOwnedSlice(arena),
                .source_form_idx = input.form_idx,
            } };
        },
        // Everything else — a unit-bearing number, a date, a time — has no
        // `EmittedValue`. None appears in the forms a graph clones, and
        // guessing a spelling for one is how a wrong value gets shipped.
        else => out.failAt(arena, view.tree.spanOf(node), "`(draw-graph …)` cannot carry this value into the form it generates — it is not a number, string, symbol, keyword, boolean, vector or form", .{}),
    };
}

/// Fold `(* 4 6)` through the lowering env, the same way `(init :workgroups …)`
/// and `(pass … :scale …)` do. A bare `(define …)` NAME is a symbol, not a
/// form, and passes through uncloned for the emitter to resolve.
fn foldExpression(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    input: *const Lowering.LoweringInput,
    node: Ast.NodeIndex,
) Lowering.LoweringError!f64 {
    var r = sjon.Expr.eval(input.arena, input.view.tree, node, input.env, input.schema.*) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return out.failAt(arena, input.view.tree.spanOf(node), "`(draw-graph …)`: this expression did not evaluate — it must be a bounded expression over `(define …)` constants", .{}),
    };
    defer r.deinit();
    return switch (r.value) {
        .number => |v| v,
        else => out.failAt(arena, input.view.tree.spanOf(node), "`(draw-graph …)`: this expression evaluated to something that is not a number", .{}),
    };
}

// ============================================================================
// Small shared helpers
// ============================================================================

/// A `(bind-group …)`'s `:group`, which the schema bounds to a `binding-index`
/// and defaults to 0. Read as the number it is; `sortStageGroups` bounds it
/// against the stage's own group count immediately after.
fn groupIndexOf(r: Reader, form: Ast.NodeIndex) usize {
    const n = r.number(form, "group") orelse {
        // Authored, but not as a literal — a `(define …)` reference or an
        // expression. `Reader.number` reads literals only (its own doc comment
        // says NOT FOR EMIT SITES), and a hook has no `Env` to evaluate with,
        // so the old `orelse 0` silently called every such stage group 0. That
        // skipped the dense-index check below while the EMITTER, which does
        // evaluate the key, went on to emit at the real index: a bind group
        // set at slot 0 against the layout of slot N, from a document that
        // validated clean (§437, pitfall 82's shape). Out of range is the
        // sentinel `sortStageGroups` already refuses on, so hand it that.
        if (r.authorNode(form, "group") != null) return MAX_STAGE_GROUPS;
        return 0;
    };
    if (!(n >= 0 and n < @as(f64, MAX_STAGE_GROUPS))) return MAX_STAGE_GROUPS;
    return @intFromFloat(@round(n));
}

fn childForm(view: EffectiveView, form: Ast.NodeIndex, head: []const u8) ?Ast.NodeIndex {
    for (view.tree.formHeader(form).children) |c| {
        if (view.tree.tagOf(c) != .form) continue;
        if (std.mem.eql(u8, view.tree.formHeader(c).head, head)) return c;
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// A minimal manifest, deliberately NOT pngine's: one target form, one
/// container whose child carries a key of each shape, and a hook on the
/// container. It exists to state one upstream fact in the smallest terms that
/// can state it (see the two tests below).
const union_probe_manifest: [:0]const u8 =
    \\(plugin :name probe :version "0.1.0"
    \\  (value-kind :name target-ref
    \\    :underlying symbol
    \\    :cross-ref (cross-ref :target target))
    \\  (value-kind :name spot
    \\    :underlying symbol
    \\    :members (member-set (member :name here)))
    \\  (value-kind :name spot-or-target
    \\    :underlying union
    \\    :union (union-shape :alternatives [spot target-ref]))
    \\  (value-kind :name child-item :underlying form :heads (head-set :names [child]))
    \\  (form :name target
    \\    (key :name name :type symbol))
    \\  (form :name leaf
    \\    (key :name name :type symbol))
    \\  (form :name child
    \\    (key :name plain :type target-ref :optional true)
    \\    (key :name unioned :type spot-or-target :optional true))
    \\  (form :name box
    \\    :positional child-item
    \\    :lowering (lowering :hook probe/box-v1 :produces [leaf])))
    \\
;

var probe_ran: bool = false;

fn probeBoxV1(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    probe_ran = true;
    try out.append(arena, .{
        .head = "leaf",
        .kvpairs = try arena.dupe(EmittedKvpair, &.{.{ .key = "name", .value = .{ .symbol = "l" } }}),
        .source_form_idx = input.form_idx,
    });
}

/// Validate `body` against the probe manifest with the hook registered, and
/// report whether the hook ran and whether anything was said about it.
fn runProbe(gpa: Allocator, body: []const u8) !struct { ran: bool, errors: usize } {
    const src = try std.mem.concatWithSentinel(gpa, u8, &.{ union_probe_manifest, body }, 0);
    defer gpa.free(src);

    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "probe/box-v1", .lower = probeBoxV1 });

    probe_ran = false;
    var result = try sjon.validateDocument(gpa, src, .{ .lowering_registry = &registry });
    defer result.deinit();

    var errors: usize = 0;
    for (result.diagnostics) |d| {
        if (d.severity == .err) errors += 1;
    }
    return .{ .ran = probe_ran, .errors = errors };
}
