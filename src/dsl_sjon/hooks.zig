//! PNGine lowering hooks — the whole sugar tier, and the only door it has into
//! a compile. Three are registered: `pngine/init-v1` and `pngine/pass-v1` live
//! here, `pngine/draw-v1` in `draw_graph.zig`. Every key each one reads is
//! written down in `schema/sugar-ledger.mjs` against the hand-written twin in
//! `examples/` that proves it lowers to core forms; `zig build drift` derives
//! the key set from the schema, so a new key on a lowered form fails the build
//! until it is recorded.
//!
//! Supported external surface (ask P6): the `pass_v1` / `init_v1` / `draw_v1`
//! values and `buildRegistry`. Every other `pub` decl in this module is
//! internal and may change without notice; a one-pass host also needs
//! `Compiler.buildLoweringEnv` so a define-ref `:workgroups` expression
//! resolves at lowering time.
//!
//! `(init …)` and `(pass …)` sugar become host-owned form-lowering hooks: SJON calls
//! them between default-materialization and final validation, and the canonical
//! forms they emit flow through the same emitter path as hand-written resources.
//! This retires `emitter/init.zig` (~325 LOC) and (Phase 2) `emitter/pass_sugar.zig`.
//!
//! `EmittedForm.children` is a positional `[]const EmittedValue` (SJON 2026-06-07),
//! so a hook can synthesize child forms like `(entry :binding 0 :buffer b)`. The render
//! pipeline hooks below emit the canonical `(vertex :module … :entry …)(fragment
//! :module … :entry … (color-target :format …))` form — the same shape a hand-authored
//! pipeline uses, so the emitter's single descriptor path serves both (§86 retired
//! the legacy flat `flat-module`/… kvpair shape and its parallel emitter branch).
//! `compute-pipeline` carries a `(compute …)` stage, the same GPUProgrammableStage
//! the other two are (docs/plans/overhaul/02 R2).

const std = @import("std");
const Allocator = std.mem.Allocator;
const sjon = @import("sjon");
const wgsl_scan = @import("wgsl_scan");

const Lowering = sjon.Lowering;
const EffectiveView = sjon.EffectiveView.EffectiveView;
const values = @import("values.zig");
const draw_graph = @import("draw_graph.zig");
const type_agree = @import("type_agree.zig");
const fragments = @import("fragments.zig");
const Reader = values.Reader;
const Ast = sjon.Ast;
const EmittedForm = Lowering.EmittedForm;
const EmittedKvpair = Lowering.EmittedKvpair;
const EmittedValue = Lowering.EmittedValue;

/// Shared linear sampler name (legacy `ensureSharedSampler`: created once,
/// unconditionally, before any pass — even passes that never sample). Its
/// filters are authored explicitly at the emission site, not defaulted.
const PASS_SAMPLER = "__pass_sampler";

/// The auto-injected fullscreen-triangle vertex shader (entry `vs`), shared by
/// the main and post-processing pass preludes (port of `pass_sugar.buildPrelude`).
const FULLSCREEN_VS =
    \\@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    \\  let x = f32(i & 1u) * 4.0 - 1.0;
    \\  let y = f32((i >> 1u) & 1u) * 4.0 - 1.0;
    \\  return vec4f(x, y, 0, 1);
    \\}
    \\
;

/// Reference resolution for a compute main's dispatch grid. The executor resizes
/// for real at runtime; the bytecode just needs a deterministic grid so the two
/// paths agree. Matches the legacy `pass_sugar.REF_WIDTH/REF_HEIGHT`.
const REF_WIDTH: u32 = 512;
const REF_HEIGHT: u32 = 512;

/// The auto-generated blit shader for a compute main: a fullscreen triangle that
/// samples the compute output (`screen`) → canvas. Verbatim from
/// `pass_sugar.BLIT_WGSL` so the normalized-WGSL parity compare matches.
const BLIT_WGSL =
    \\struct VSOut { @builtin(position) pos: vec4f, @location(0) uv: vec2f }
    \\@vertex fn vs(@builtin(vertex_index) i: u32) -> VSOut {
    \\  var o: VSOut;
    \\  let x = f32(i & 1u) * 4.0 - 1.0;
    \\  let y = f32((i >> 1u) & 1u) * 4.0 - 1.0;
    \\  o.pos = vec4f(x, y, 0, 1);
    \\  o.uv = vec2f(x * .5 + .5, .5 - y * .5);
    \\  return o;
    \\}
    \\@group(0) @binding(0) var tex: texture_2d<f32>;
    \\@group(0) @binding(1) var smp: sampler;
    \\@fragment fn fs(in: VSOut) -> @location(0) vec4f {
    \\  return textureSample(tex, smp, in.uv);
    \\}
;

/// A lowered pass's outward-facing identity, threaded to the passes that follow
/// so a later pass can sample an earlier one's output — the cross-pass dependency
/// that justifies a *container* hook (a per-form hook cannot see its siblings).
/// `name` is the WGSL binding identifier a dependent uses (`textureSample(name,…)`);
/// `tex` is the output texture form to wire; `pool_size` is 2 for a feedback pass
/// (ping-pong output, read by a dependent through `ping-pong`), else 1.
/// `scalar` and `filterable` are its `:format`'s two consequences for whoever
/// reads it: the `texture_2d<T>` a dependent's prelude declares, and whether the
/// shared linear sampler may touch it at all.
/// `intermediate` says whether `tex` names an emitted form: a pass that draws
/// straight to the canvas (§425) carries the name but no texture, so `:expose`
/// has to refuse it rather than blit a form that does not exist.
const PassRef = struct {
    name: []const u8,
    tex: []const u8,
    pool_size: u8,
    scalar: []const u8 = "f32",
    filterable: bool = true,
    intermediate: bool = true,
};

/// The default `(pass …)` intermediate format, unchanged since the sugar
/// existed: renderable, filterable, blendable, and the same eight bits per
/// channel the canvas has. `:format` overrides it.
const DEFAULT_PASS_FORMAT = "rgba8unorm";

/// What a `(pass … :format …)` means to everything downstream of the texture it
/// names: the WGSL scalar a reader's `texture_2d<T>` carries, and whether a
/// filtering sampler may read it.
const FormatFacts = struct {
    scalar: []const u8,
    filterable: bool,
};

/// Read a color format's two consequences. `scalar` follows the format's sample
/// class, which is the same join R4 makes between a `(texture :format …)` and
/// the `texture_2d<T>` a shader declares — here the hook WRITES that declaration,
/// so it reads the class instead of checking it.
///
/// `filterable` is false for exactly the three 32-bit float formats: WebGPU
/// types them `unfilterable-float` without the `float32-filterable` feature, and
/// the pass sampler is `linear`. Integer formats are unfilterable too and need
/// no entry — `textureSample` of a `texture_2d<u32>` is a WGSL error wgslender
/// already reports, so nothing reaches the runtime to be refused.
/// Pure.
fn formatFacts(fmt: values.TextureFormat) FormatFacts {
    const scalar: []const u8 = switch (type_agree.textureFormatClass(fmt) orelse .float) {
        .float => "f32",
        .uint => "u32",
        .sint => "i32",
    };
    const filterable = switch (fmt) {
        .r32float, .rg32float, .rgba32float => false,
        else => true,
    };
    return .{ .scalar = scalar, .filterable = filterable };
}

/// `pngine/pass-v1` — `(pass …)` shader-art sugar as a container-lowering hook.
///
/// Reads every `(pass …)` child of the `(pass-graph …)` container through the
/// whole-document `EffectiveView`, and emits the canonical PNGine forms a single
/// fullscreen-shader pass expands to (mirroring `dsl/emitter/pass_sugar.zig`):
/// a shared sampler (once), then per pass a uniform buffer (if the WGSL refs
/// `pngine`), a canvas-sized output texture, a `(shader-module …)` with the
/// auto-injected prelude, a `(render-pipeline …)`, a `(bind-group …)`, and a
/// `(render-pass …)`; finally an auto `(frame …)`.
///
/// Emission ORDER matters: the emitter walks lowered forms in emitted order
/// (`emitLowered`), so the resulting MockGPU create sequence is
/// `sampler, buffer, texture, shader, pipeline, bind-group` — the `(pass …)`
/// order the golden traces pin position-by-position.
///
/// Scope: fullscreen fragment passes with optional `pngine`/`pointer` uniforms,
/// `@fragment fn post()` post-processing (main → intermediate texture → canvas),
/// `:feedback true` ping-pong (a `:pool 2` output texture + `prev_<name>` binding,
/// rendered via begin_render_pass_pool), cross-pass dependencies (a later pass
/// samples an earlier pass's output, ping-ponged when that output is pooled),
/// `:file […]` WASM data buffers (`D0`, `D1`, …), and `@compute` mains (a storage
/// `screen` texture + an auto-blit; `lowerComputePass`).
pub fn passV1(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    const view = input.view;
    const container = input.form_idx;
    const hdr = view.tree.formHeader(container);

    // Shared sampler first. The filters are SPELLED OUT rather than left to the
    // schema default: this sampler exists to read the previous pass's texture,
    // where smoothing is the whole point, and the default is nearest since
    // spec/09 step D. Riding the default here is how a feedback chain would have
    // gone blocky the day the default moved — the sugar authors on the user's
    // behalf, so it states what it means.
    try appendForm(arena, out, container, "sampler", &.{
        .{ .key = "name", .value = .{ .symbol = PASS_SAMPLER } },
        .{ .key = "mag-filter", .value = .{ .symbol = "linear" } },
        .{ .key = "min-filter", .value = .{ .symbol = "linear" } },
    }, &.{});

    // Collect the (pass …) children up front so each knows whether it is the
    // last — the "main" pass renders to the canvas and owns any post() stage.
    var passes: std.ArrayList(Ast.NodeIndex) = .empty;
    for (hdr.children) |child| {
        if (view.tree.tagOf(child) != .form) continue;
        if (!std.mem.eql(u8, view.tree.formHeader(child).head, "pass")) continue;
        try passes.append(arena, child);
    }
    if (passes.items.len == 0) return out.fail(
        arena,
        "`(pass-graph …)` declares no `(pass …)` — a pass graph needs at least one",
        .{},
    );

    // Named or not decides who owns the frame (`graphOwnsFrame`).
    const graph_name = try childSymbol(arena, view, container, "name");
    try checkGraphFrameOwnership(arena, out, view, container, "pass-graph", graph_name);

    // A named graph is a `(step-group …)`, and a group has no `:init` — only a
    // `(frame …)` does. Refused HERE, ahead of the loop, so the message names
    // the pass that carries the key rather than the container that could not
    // place it, and so nothing is emitted for a document that cannot run.
    if (graph_name) |gname| for (passes.items) |pass| {
        if (try childString(arena, view, pass, "init") == null) continue;
        const pname = (try childSymbol(arena, view, pass, "name")) orelse "?";
        return failSlot(
            arena,
            out,
            view,
            pass,
            "init",
            "pass `{s}`: `:init` is a one-shot seed and only a `(frame …)` has an `:init` list, but `(pass-graph :name {s} …)` is named, so this graph emits a `(step-group …)`. Drop the graph's `:name` (then it owns the frame), or seed a hand-written `(texture …)` with a top-level `(init …)`",
            .{ pname, gname },
        );
    };

    var frame_steps: std.ArrayList(EmittedValue) = .empty;
    var init_steps: std.ArrayList(EmittedValue) = .empty;
    var prior: std.ArrayList(PassRef) = .empty;
    for (passes.items, 0..) |pass, i| {
        const is_last = (i == passes.items.len - 1);
        // Read here rather than inside `lowerOnePass`: evaluating `:value`
        // needs the lowering env, and `input` is in scope only at this level.
        const constants = try readPassConstants(arena, out, input, pass);
        // Read here for the same reason the constants are: `:scale` may be an
        // expression over `(define …)`, and the lowering env lives on `input`.
        const scale = try readPassScale(arena, out, input, pass);
        const ref = try lowerOnePass(arena, out, container, view, pass, is_last, prior.items, constants, scale, &frame_steps, &init_steps);
        try prior.append(arena, ref);
    }

    // `:expose`: the passes a frame may put on the canvas. Emitted here, but
    // appended to NO step list, so nothing runs a blit until a frame names it.
    try lowerExposedBlits(arena, out, view, container, prior.items);

    // Named: a `(step-group …)` the document's own `(frame …)` runs, which is
    // how a pass graph and a draw graph share one frame. Unnamed: the auto-frame,
    // with `(pass-graph :before […])` as its `:perform` HEAD, byte-identical to
    // what this hook emitted before groups existed.
    if (graph_name) |gname| {
        std.debug.assert(init_steps.items.len == 0); // pre: refused above
        try appendForm(arena, out, container, "step-group", &.{
            .{ .key = "name", .value = .{ .symbol = gname } },
            .{ .key = "perform", .value = .{ .vector = try frame_steps.toOwnedSlice(arena) } },
        }, &.{});
        return;
    }
    var perform: std.ArrayList(EmittedValue) = .empty;
    try perform.appendSlice(arena, try readGraphBefore(arena, view, container));
    try perform.appendSlice(arena, frame_steps.items);
    // `:init` only when a pass carried one: an empty vector would be a key the
    // frames of every other graph document do not have, and 160 goldens say so.
    var kvs: std.ArrayList(EmittedKvpair) = .empty;
    try kvs.append(arena, .{ .key = "name", .value = .{ .symbol = "main" } });
    if (init_steps.items.len > 0)
        try kvs.append(arena, .{ .key = "init", .value = .{ .vector = try init_steps.toOwnedSlice(arena) } });
    try kvs.append(arena, .{ .key = "perform", .value = .{ .vector = try perform.toOwnedSlice(arena) } });
    try appendForm(arena, out, container, "frame", try kvs.toOwnedSlice(arena), &.{});
}

/// Who owns the document's `(frame …)`, and the four refusals that answer it.
///
/// A graph is several passes, so a hand-authored frame could not name one until
/// `(step-group …)` gave the SET a name. That is what `:name` selects:
///
/// - **Unnamed** — the graph emits the frame, as both containers always have.
///   The document may then hold no other `(frame …)` (two compile, the runtime
///   runs the first, and which one is not visible in the source) and no other
///   graph (same reason).
/// - **Named** — the graph emits a `(step-group …)` and nothing else, so the
///   document MUST hold a `(frame …)`; without one it compiles to a payload
///   that draws nothing. `:before` / `:after` are refused there: the frame
///   states the order, and a key that also did would be a second answer to one
///   question.
///
/// Every name here is the hook's own to check — a consumed form's keys are
/// never cross-ref-checked, and the container's siblings are not this hook's
/// sub-tree (CONTRIBUTING pitfall 112).
pub fn checkGraphFrameOwnership(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    view: EffectiveView,
    container: Ast.NodeIndex,
    head: []const u8,
    graph_name: ?[]const u8,
) Lowering.LoweringError!void {
    var frames: usize = 0;
    var other_graph: ?Ast.NodeIndex = null;
    for (view.tree.root) |idx| {
        if (view.tree.tagOf(idx) != .form) continue;
        const h = view.tree.formHeader(idx).head;
        if (std.mem.eql(u8, h, "frame")) {
            frames += 1;
            continue;
        }
        if (idx == container) continue;
        if (std.mem.eql(u8, h, "pass-graph") or std.mem.eql(u8, h, "draw-graph")) other_graph = idx;
    }

    if (graph_name == null) {
        for (view.tree.root) |idx| {
            if (view.tree.tagOf(idx) != .form) continue;
            if (!std.mem.eql(u8, view.tree.formHeader(idx).head, "frame")) continue;
            return out.failAt(
                arena,
                view.tree.formHeader(idx).head_span,
                "a `({s} …)` with no `:name` emits the document's `(frame …)` itself, so this one is a SECOND frame and the runtime runs only the first — give the graph a `:name` and run it as a step of this frame, or delete this form and use `({s} :before […])`",
                .{ head, head },
            );
        }
        if (other_graph) |o| return out.failAt(
            arena,
            view.tree.formHeader(o).head_span,
            "this `({s} …)` and the `({s} …)` beside it would each emit the document's `(frame …)`, so two compile and the runtime runs the first — give BOTH a `:name` and write one `(frame …)` that performs them in the order you want",
            .{ view.tree.formHeader(o).head, head },
        );
        return;
    }

    if (frames == 0) return out.failAt(
        arena,
        view.tree.formHeader(container).head_span,
        "`({s} :name {s} …)` is a `(step-group …)`, not a frame, and this document declares no `(frame …)` to perform it — so nothing it builds ever runs. Add `(frame :name main :perform [{s}])`, or drop the `:name` and let the graph own the frame",
        .{ head, graph_name.?, graph_name.? },
    );

    for ([_][]const u8{ "before", "after" }) |key| {
        const n = Reader.initFromView(view).authorNode(container, key) orelse continue;
        return out.failAt(
            arena,
            view.tree.spanOf(n),
            "`({s} :name {s} …)` does not emit the frame, so `:{s}` has nothing to sit before or after — put the step in the `(frame …)` that performs '{s}', on the side you want it",
            .{ head, graph_name.?, key, graph_name.? },
        );
    }
}

/// Expand a single `(pass …)` child into its canonical resource forms, appending
/// the render-pass name(s) to `frame_steps` for the auto-frame's `:perform` and
/// returning a `PassRef` so the passes after it can sample its output. `is_last`
/// marks the final pass — the "main" pass (also true for a pass literally named
/// `main`), which renders to the canvas and may carry a `post()` stage.
/// `prior_passes` are the already-lowered passes this one may depend on.
fn lowerOnePass(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    view: EffectiveView,
    pass: Ast.NodeIndex,
    is_last: bool,
    prior_passes: []const PassRef,
    constants: []const PassConstant,
    scale: ?f64,
    frame_steps: *std.ArrayList(EmittedValue),
    init_steps: *std.ArrayList(EmittedValue),
) Lowering.LoweringError!PassRef {
    // Everything below blames the `(pass …)` child, never the `(pass-graph …)`
    // this hook was called on: a container hook that reports at its own head
    // underlines the whole document's worth of passes for one broken shader.
    const pass_span = view.tree.formHeader(pass).head_span;
    const name = (try childSymbol(arena, view, pass, "name")) orelse
        return out.failAt(arena, pass_span, "`(pass …)` has no `:name`", .{});
    // `:code` is required in the schema (audit 09 D26), so this is the
    // "internal:" shape — reachable only by a registry-less caller.
    const code = (try childString(arena, view, pass, "code")) orelse
        return out.failAt(arena, pass_span, "internal: pass `{s}` has no `:code`", .{name});
    std.debug.assert(name.len > 0); // pre: named pass

    // Detect entry-point kind via the reused scanner. A compute main lowers to a
    // different shape (a storage `screen` texture + compute pipeline/pass + an
    // auto-blit to canvas), so branch to its own path before any fragment-only
    // resource is emitted. A mixed @fragment+@compute block is invalid.
    const scan = wgsl_scan.scanEntryPoints(code);
    if (scan.count == 0) return out.failAt(
        arena,
        pass_span,
        "pass `{s}`: its WGSL declares no entry point — a pass needs an `@fragment` or a `@compute` function",
        .{name},
    );
    // A truncated scan cannot be lowered honestly: `lowerComputePass` emits one
    // pipeline+pass per entry, so a prefix silently drops passes, and the
    // fragment/compute classification below is only as complete as the prefix.
    // Fail rather than lower a partial reading of the pass.
    if (scan.truncated) return out.failAt(
        arena,
        pass_span,
        "pass `{s}`: more than {d} entry points — the scan stops there, and lowering a prefix would silently drop the rest",
        .{ name, scan.count },
    );
    if (scan.has_fragment and scan.has_compute) return out.failAt(
        arena,
        pass_span,
        "pass `{s}`: its WGSL declares both `@fragment` and `@compute` entry points — a pass must be one or the other",
        .{name},
    );
    // A `@workgroup_size(…)` this scanner cannot read leaves the DEFAULT [1,1,1]
    // on the entry, and `getDispatchSize` would then divide the reference extent
    // by 1 — a grid hundreds of times too large, silently. Refuse instead. The
    // unreadable forms are const-expressions (`@workgroup_size(WG)`), which need
    // const-evaluation this lowering phase cannot do: the pass's WGSL does not
    // parse standalone (its prelude, which declares `screen`/`pngine`, is chosen
    // BY this scan), so reflection cannot answer here either (§325).
    for (scan.slice()) |e| {
        if (e.type == .compute and !e.workgroup_known) return out.failAt(
            arena,
            pass_span,
            "pass `{s}`: `@workgroup_size` on `{s}` is not literal numbers — lowering cannot const-evaluate it here (§325), so write the sizes out",
            .{ name, e.name },
        );
    }
    // Read ONCE, for both paths and for the refusal below.
    const imports = try readImports(arena, view, pass);
    // With no fragments in play this hook knows every declaration the pass's
    // modules can hold, so a constant naming an override the code does not
    // declare is refused HERE, where the message can name the pass and the
    // override the author wrote. With `:imports` the declaration may sit in a
    // fragment this hook never reads — only the emitter assembles those — so
    // that judgement is left to it, at the cost of a message naming a synthesized
    // module (`<pass>__shader`) instead of the pass.
    if (imports.len == 0) for (constants) |c| {
        if (fragments.declaresName(code, c.name)) continue;
        return out.failAt(
            arena,
            pass_span,
            "pass `{s}`: `(constant :name {s} …)` names an override its WGSL does not declare — the pass imports no fragments, so there is nowhere else it could be declared",
            .{ name, c.name },
        );
    };
    // `:format` names the texel format of the intermediate this pass renders
    // into. Two refusals belong here, before either path emits anything; the
    // third (a pass that draws straight to the canvas, which has no
    // intermediate) needs the post() probe and sits in `lowerFragmentPass`.
    const format = try readPassFormat(arena, out, view, pass, name, scan.has_compute);
    // `:scale` is the same question one key over: the intermediate's SIZE. A
    // compute pass is refused for its own reason — its `screen` is a storage
    // texture the auto-blit samples at canvas resolution, and the dispatch grid
    // is the reference extent, neither of which this key resizes.
    if (scale != null and scan.has_compute) return failSlot(
        arena,
        out,
        view,
        pass,
        "scale",
        "pass `{s}`: `:scale` sizes the texture a FRAGMENT pass renders into, and this pass is a compute one — its `screen` is a storage texture written at the dispatch grid pngine chooses and blitted to the canvas, so a fraction here would size nothing the shader knows about",
        .{name},
    );
    // `:init` is the one-shot seed for the texture this pass renders into. Read
    // here so both paths get it and neither reads the key twice.
    const init_code = try childString(arena, view, pass, "init");
    const is_main = is_last or std.mem.eql(u8, name, "main");
    if (scan.has_compute)
        return lowerComputePass(arena, out, container, view, pass, name, code, scan, is_main, imports, constants, init_code, frame_steps, init_steps);
    return lowerFragmentPass(arena, out, container, view, pass, name, code, format, scale, is_main, prior_passes, imports, constants, init_code, frame_steps, init_steps);
}

/// Read `(pass … :format …)`, refusing the two shapes that cannot honor it, and
/// returning the format symbol (absent → `rgba8unorm`, the sugar's own default).
///
/// A COMPUTE pass is refused rather than served: its `screen` is a storage
/// texture, so the format would have to appear inside the prelude's
/// `texture_storage_2d<FMT, write>` — a narrower set than `texture-format` — and
/// pngine's own blit samples that texture as `texture_2d<f32>` through a linear
/// sampler, which rules out most of what survives the first cut.
///
/// A DEPTH or STENCIL format is refused because a `(pass …)` writes a color
/// attachment; a depth target is a `(depth-stencil-attachment …)` on a
/// hand-authored `(render-pass …)`, which the sugar does not emit.
fn readPassFormat(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    view: EffectiveView,
    pass: Ast.NodeIndex,
    name: []const u8,
    has_compute: bool,
) Lowering.LoweringError!?[]const u8 {
    const sym = (try childSymbol(arena, view, pass, "format")) orelse return null;
    if (has_compute) return failSlot(
        arena,
        out,
        view,
        pass,
        "format",
        "pass `{s}`: `:format` names the format of the texture a FRAGMENT pass renders into, and this pass is a compute one — its `screen` is a storage texture, whose format the prelude writes into `texture_storage_2d<…, write>` and pngine's blit reads as `texture_2d<f32>`",
        .{name},
    );
    const fmt = values.mapTextureFormat(sym);
    if (fmt.hasDepth() or fmt.hasStencil()) return failSlot(
        arena,
        out,
        view,
        pass,
        "format",
        "pass `{s}`: `:format {s}` is a depth/stencil format, and a `(pass …)` renders a COLOR attachment — a depth target is a `(depth-stencil-attachment …)` on a hand-authored `(render-pass …)`",
        .{ name, sym },
    );
    return sym;
}

/// One `(pass … :reads [tex …])` entry: a texture the graph did not produce,
/// bound by its own name after the prior-pass dependencies. `wgsl_type` is the
/// whole binding type the prelude declares (`texture_depth_2d`, or
/// `texture_2d<T>` for T from the format's sample class), so the two sites that
/// write it cannot spell it differently.
const ReadRef = struct {
    name: []const u8,
    wgsl_type: []const u8,
};

/// Ceiling on `:reads` entries, matching the schema's `:max-len 16`
/// (`maxSampledTexturesPerShaderStage`). Stated here too so every loop over the
/// list is bounded by a constant this file owns.
const MAX_PASS_READS: usize = 16;

/// Find a top-level `(texture :name N …)` in the document.
///
/// This is the sanctioned sibling-form lookup the analysis filed as ask 2
/// (polymorphism-analysis §6): the hook receives the WHOLE-document
/// `EffectiveView`, not a view of its own container, so a top-level form is
/// readable. `:reads` is the first key that needs it — every other key a
/// `(pass …)` carries is answerable from the pass itself.
/// Complexity: O(top-level forms).
fn findTexture(view: EffectiveView, name: []const u8) ?Ast.NodeIndex {
    std.debug.assert(name.len > 0); // pre: a name to look for
    const r = Reader.initFromView(view);
    for (view.tree.root) |idx| {
        if (view.tree.tagOf(idx) != .form) continue;
        if (!std.mem.eql(u8, view.tree.formHeader(idx).head, "texture")) continue;
        const n = r.symbol(idx, "name") orelse continue;
        if (std.mem.eql(u8, n, name)) return idx;
    }
    return null;
}

/// Read `(pass … :reads [tex …])` into the bindings the prelude and the bind
/// group both walk, refusing every texture this sugar cannot honestly bind.
///
/// The prelude declares a plain `texture_2d` (or `texture_depth_2d`), which a
/// default view gives for exactly one shape: a single-layer, unmultisampled 2d
/// texture carrying `texture-binding` usage. Each of the others is refused
/// where the author can read it, rather than left to WebGPU, which reports it
/// as a bind-group failure with no mention of the key that caused it.
///
/// The last refusal is the one pitfall 37 is about: an entry the pass's WGSL
/// never names is a binding the pipeline's `:layout auto` does not hold, and a
/// bind group with an entry its layout lacks is refused at render time, with a
/// blank canvas as the only symptom. `main_code` is the post-stripped body, so
/// naming the texture only inside `post()` does not count — the post pass has
/// its own bind group and this one is not in it.
fn readPassReads(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    view: EffectiveView,
    pass: Ast.NodeIndex,
    name: []const u8,
    main_code: []const u8,
    prior_passes: []const PassRef,
) Lowering.LoweringError![]const ReadRef {
    const elems = Reader.initFromView(view).vectorNodes(pass, "reads") orelse return &.{};
    std.debug.assert(elems.len >= 1 and elems.len <= MAX_PASS_READS); // schema: texture-ref-list bounds
    const refs = try arena.alloc(ReadRef, elems.len);
    for (elems, 0..) |e, i| {
        // A hook runs BEFORE final validation, so the element's TYPE is not
        // settled yet: a `:reads [1]` reaches here as a number. Drop the list
        // and let the validator refuse it a moment later with the type error,
        // exactly as `readImports` does — `symbolText` asserts, and the
        // mutation sweep found the assert.
        if (view.tree.tagOf(e) != .symbol) return &.{};
        const tex_name = view.tree.symbolText(e);
        // A name no top-level `(texture …)` declares. The validator does NOT
        // catch this one: the `(pass …)` is consumed by this hook, so its own
        // kvpairs never reach the cross-ref pass, and without a refusal here
        // the only symptom is "use of undeclared identifier" against a line of
        // the assembled module the author never wrote.
        const form = findTexture(view, tex_name) orelse return out.failAt(
            arena,
            view.tree.spanOf(e),
            "pass `{s}`: `:reads` names `{s}`, and no `(texture :name {s} …)` is declared in this document",
            .{ name, tex_name, tex_name },
        );
        for (prior_passes) |dep| if (std.mem.eql(u8, dep.name, tex_name)) return out.failAt(
            arena,
            view.tree.spanOf(e),
            "pass `{s}`: `:reads` names `{s}`, and a pass in this graph is called `{s}` too — the prelude binds a prior pass by its name, so one of the two would shadow the other. Rename the texture or the pass",
            .{ name, tex_name, tex_name },
        );
        if (!namesIdent(main_code, tex_name)) return out.failAt(
            arena,
            view.tree.spanOf(e),
            "pass `{s}`: `:reads` names `{s}` and this pass's WGSL never uses it — the pipeline's `:layout auto` holds only the bindings its entry points reach, so binding one they do not is a bind group WebGPU refuses (a blank canvas, at render time). Use it or drop it from the list",
            .{ name, tex_name },
        );
        const wgsl_type = try readTextureBindingType(arena, out, view, form, name, tex_name);
        if (std.mem.eql(u8, wgsl_type, "texture_depth_2d") and sampledByName(main_code, tex_name)) return out.failAt(
            arena,
            view.tree.spanOf(e),
            "pass `{s}`: `{s}` is a depth texture and this pass SAMPLES it — a sampler used with a depth texture is `non-filtering` in the pipeline's auto layout, and the one this prelude binds (`samp`) is linear, which Chrome refuses at bind-group creation. Read it with `textureLoad({s}, vec2i(pos.xy), 0)`, which needs no sampler",
            .{ name, tex_name, tex_name },
        );
        refs[i] = .{ .name = try arena.dupe(u8, tex_name), .wgsl_type = wgsl_type };
    }
    return refs;
}

/// The WGSL binding type for one `:reads` texture, refusing the four shapes a
/// default 2d view cannot serve. Split out of `readPassReads` so each stays
/// within the ≤70-line budget; every refusal here blames the `(texture …)`,
/// because the texture is what has to change.
fn readTextureBindingType(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    view: EffectiveView,
    form: Ast.NodeIndex,
    pass_name: []const u8,
    tex_name: []const u8,
) Lowering.LoweringError![]const u8 {
    const r = Reader.initFromView(view);
    const span = view.tree.formHeader(form).head_span;
    var usage: values.TextureUsage = .{};
    if (r.vectorNodes(form, "usage")) |flags| for (flags) |f| {
        if (r.elemSymbol(f)) |sym| values.applyTextureUsage(&usage, sym);
    };
    if (!usage.texture_binding) return out.failAt(
        arena,
        span,
        "texture `{s}` is read by pass `{s}` and its `:usage` has no `texture-binding` — a texture a shader samples must be created with it",
        .{ tex_name, pass_name },
    );
    if (r.authorNode(form, "sample-count") != null and (r.number(form, "sample-count") orelse 0) != 1) return out.failAt(
        arena,
        span,
        "texture `{s}` is read by pass `{s}` and is multisampled — the prelude declares a plain `texture_2d`, and a multisampled texture needs `texture_multisampled_2d`, which cannot be sampled at all. Resolve it first",
        .{ tex_name, pass_name },
    );
    // `:dimension` is `1d`/`2d`/`3d`, which LEX as number-with-unit rather than
    // symbols (§227), so `Reader.symbol` returns null for every one of them and
    // a 3d texture would sail through. `memberSpelling` is the reader for a
    // digit-leading member, the same one `Emitter.dimensionCode` uses.
    var dim_buf: [32]u8 = undefined;
    if (r.authorNode(form, "dimension") != null) if (r.memberSpelling(form, "dimension", &dim_buf)) |dim| if (!std.mem.eql(u8, dim, "2d")) return out.failAt(
        arena,
        span,
        "texture `{s}` is read by pass `{s}` and is `{s}` — the prelude declares a plain `texture_2d`, whose default view a 1d or 3d texture does not give",
        .{ tex_name, pass_name, dim },
    );
    if (r.vectorNodes(form, "size")) |extent| if (extent.len > 2 and (r.elemNumber(extent[2]) orelse 0) != 1) return out.failAt(
        arena,
        span,
        "texture `{s}` is read by pass `{s}` and has more than one layer — the prelude declares a plain `texture_2d`, and an array texture's default view is `2d-array`",
        .{ tex_name, pass_name },
    );
    // `:format` is required by the schema, so the fallback is unreachable from
    // a validated document.
    const fmt = values.mapTextureFormat(r.symbol(form, "format") orelse DEFAULT_PASS_FORMAT);
    // A depth texture samples as `texture_depth_2d` and returns a bare f32 —
    // WebGPU's `depth` sample type, which a filtering sampler may read (that is
    // how bilinear PCF works), so the shared linear sampler is fine here.
    if (fmt.hasDepth()) return "texture_depth_2d";
    if (fmt.hasStencil()) return out.failAt(
        arena,
        span,
        "texture `{s}` is read by pass `{s}` and is a stencil-only format — WGSL samples stencil as `texture_2d<u32>` through a view whose `:aspect` is stencil-only, which this prelude does not build",
        .{ tex_name, pass_name },
    );
    return std.fmt.allocPrint(arena, "texture_2d<{s}>", .{formatFacts(fmt).scalar}) catch return error.OutOfMemory;
}

/// The two `:format` rules that need the post() and dependency probes, and the
/// facts the rest of the lowering reads off the format. `format` is the
/// authored symbol or null (absent → `rgba8unorm`).
///
/// A pass that draws straight to the canvas has no intermediate: its target is
/// the context's texture, in the context's format, so an authored `:format`
/// there would be silently dropped. Refused instead (the §409 class).
///
/// The other rule is the one WebGPU would abort on at bind-group creation: the
/// shared pass sampler is `linear`, and a 32-bit float target is
/// unfilterable-float. Three sites can hit it — this pass sampling a dependency,
/// this pass sampling its own feedback pair, and a `post()` sampling the
/// intermediate this pass just wrote.
fn checkPassFormat(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    view: EffectiveView,
    pass: Ast.NodeIndex,
    name: []const u8,
    format: ?[]const u8,
    feat: PassFeatures,
    is_canvas_format: bool,
) Lowering.LoweringError!FormatFacts {
    const facts = formatFacts(values.mapTextureFormat(format orelse DEFAULT_PASS_FORMAT));
    if (format) |sym| {
        if (is_canvas_format) return failSlot(
            arena,
            out,
            view,
            pass,
            "format",
            "pass `{s}`: `:format {s}` names the intermediate this pass renders into, and this pass renders to the CANVAS — its format is the context's. Add a `post()` (which makes this pass write an intermediate) or move the key to an earlier pass",
            .{ name, sym },
        );
        if (!facts.filterable and feat.needs_sampler and feat.feedback) return failSlot(
            arena,
            out,
            view,
            pass,
            "format",
            "pass `{s}`: `:format {s}` is unfilterable-float, and this pass samples its own feedback pair through `samp`, which is a linear sampler — read it with `textureLoad(prev_{s}, …)` or pick a filterable format",
            .{ name, sym, name },
        );
        if (!facts.filterable) if (feat.post_fn) |pf| if (namesIdent(pf, "samp")) return failSlot(
            arena,
            out,
            view,
            pass,
            "format",
            "pass `{s}`: `:format {s}` is unfilterable-float, and this pass's `post()` samples the intermediate through `samp`, which is a linear sampler — read it with `textureLoad(postTex, …)` or pick a filterable format",
            .{ name, sym },
        );
    }
    if (feat.needs_sampler) for (feat.deps) |dep| {
        if (dep.filterable) continue;
        return out.failAt(
            arena,
            view.tree.formHeader(pass).head_span,
            "pass `{s}`: it samples pass `{s}` through `samp`, a linear sampler, and `{s}` renders an unfilterable-float `:format` — read it with `textureLoad({s}, …)` or give `{s}` a filterable format",
            .{ name, dep.name, dep.name, dep.name, dep.name },
        );
    };
    return facts;
}

/// Feature-detected inputs a fragment `(pass …)` lowers from — the `:feedback` flag,
/// an optional `@fragment fn post()` split off the main pass, and which runtime
/// resources the (post-stripped) main WGSL needs. Mirrors pass_sugar's probes.
const PassFeatures = struct {
    feedback: bool,
    post_fn: ?[]const u8,
    has_post: bool,
    needs_uniform: bool,
    needs_pointer: bool,
    needs_sampler: bool,
    /// The prior passes this one's WGSL names (`namesIdent`), in graph order:
    /// the prelude declares a `texture_2d` per entry and the bind group binds
    /// the same set. A fan-in graph (three producers, one consumer) has
    /// siblings that read nothing — binding every prior pass gave them entries
    /// their `:layout auto` had dropped, and wgpu refused the bind group.
    deps: []const PassRef,
    /// The pass's own WGSL with any `post()` cut off — the text every feature
    /// above was detected in. `:reads` is checked against the same slice, so
    /// naming a texture only inside `post()` does not bind it in this module
    /// (`post()` has its own bind group, and this texture is not in it).
    main_code: []const u8,
};

/// Detect a fragment pass's features from its user WGSL. Detection runs on the
/// post-stripped code so post()'s refs (samp, textureSample) don't leak into the
/// main pass's prelude/bindings.
///
/// Every feature here is read with `namesIdent`, so a mention inside a comment
/// is not a use. The same rule holds at the other two sites that read a pass
/// body (`lowerComputePass`, `lowerPostPass`); all three used `indexOf` until
/// hook-binding-table step 3, and all three aborted the render for it.
///
/// The sampler is bound iff the WGSL names `samp`. It used to be forced by a
/// dependency or `:feedback true` as well — but the bind group is laid out by
/// the pipeline's `:layout auto`, and an auto layout holds only the bindings
/// the entry point statically uses: a pass that read its feedback texture with
/// `textureLoad` got a `samp` entry in the bind group that the layout did not
/// have, and WebGPU refused the group (wgpu: "Number of bindings in bind group
/// descriptor (2) does not match … (1)"; lint W0003 was the only compile-time
/// sign). Overhaul/09 §8's doc-fence gate found it.
fn detectPassFeatures(
    arena: Allocator,
    view: EffectiveView,
    pass: Ast.NodeIndex,
    code: []const u8,
    is_main: bool,
    prior_passes: []const PassRef,
) Lowering.LoweringError!PassFeatures {
    std.debug.assert(code.len > 0); // pre: pass has WGSL (scanner already found an entry)
    const feedback = (try childBoolean(view, pass, "feedback")) orelse false;
    const post_fn: ?[]const u8 = if (is_main) extractPostFunction(code) else null;
    const main_code = if (post_fn) |pf| code[0 .. @intFromPtr(pf.ptr) - @intFromPtr(code.ptr)] else code;
    // `textureSample` was a second disjunct here and is redundant under
    // `namesIdent`: its sampler argument is a binding, and the only sampler
    // this prelude declares is `samp`, so nothing can sample without naming it.
    const needs_sampler = namesIdent(main_code, "samp");
    var deps: std.ArrayList(PassRef) = .empty;
    for (prior_passes) |dep| {
        if (namesIdent(main_code, dep.name)) try deps.append(arena, dep);
    }
    std.debug.assert(deps.items.len <= prior_passes.len); // post: a subset, in graph order
    return .{
        .feedback = feedback,
        .post_fn = post_fn,
        .has_post = post_fn != null,
        .needs_uniform = namesIdent(main_code, "pngine"),
        .needs_pointer = namesIdent(main_code, "pointer"),
        .needs_sampler = needs_sampler,
        .deps = try deps.toOwnedSlice(arena),
        .main_code = main_code,
    };
}

/// Does `code` name `ident` as a whole identifier outside comments? WGSL
/// identifier characters on either side make it part of a longer name, a
/// leading `.` makes it a member access, a trailing `:` makes it a
/// declaration (struct member, `var`/`let`, parameter — never a read), `//`
/// runs to the end of the line and `/* */` nests (WGSL block comments do).
/// WGSL has no string literals, so nothing else can hide an identifier.
/// Complexity: O(code.len).
fn namesIdent(code: []const u8, ident: []const u8) bool {
    std.debug.assert(ident.len > 0); // pre: a name to look for
    std.debug.assert(!isIdentChar('.')); // pre: `.` is a boundary, never a name char
    var depth: u32 = 0; // block-comment nesting
    var i: usize = 0;
    // Every branch advances `i` by at least one, so `code.len` iterations suffice.
    for (0..code.len + 1) |_| {
        if (i >= code.len) break;
        const rest = code[i..];
        if (depth > 0) {
            if (std.mem.startsWith(u8, rest, "/*")) {
                depth += 1;
                i += 2;
            } else if (std.mem.startsWith(u8, rest, "*/")) {
                depth -= 1;
                i += 2;
            } else i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "//")) {
            i = std.mem.indexOfScalarPos(u8, code, i, '\n') orelse code.len;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "/*")) {
            depth = 1;
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, rest, ident)) {
            const before_ok = i == 0 or (!isIdentChar(code[i - 1]) and code[i - 1] != '.');
            const end = i + ident.len;
            const after_ok = end == code.len or !isIdentChar(code[end]);
            if (before_ok and after_ok and !isDeclared(code, end)) return true;
        }
        i += 1;
    } else unreachable;
    return false;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Is the identifier ending at `end` followed (after blanks) by `:`?
fn isDeclared(code: []const u8, end: usize) bool {
    std.debug.assert(end <= code.len); // pre: `end` is a position in `code`
    var k = end;
    for (0..code.len) |_| {
        if (k >= code.len) return false;
        if (code[k] != ' ' and code[k] != '\t') return code[k] == ':';
        k += 1;
    } else unreachable;
}

/// Data storage buffers (`:file ["a.wasm" …]`) → D0, D1, …, emitted between the
/// pointer buffer and the output texture (legacy `loadDataWasm` create position).
/// The emitter reads each WASM file, sizes the buffer, and fills it; the prelude
/// declares `D{i}: array<f32>` and the bind group binds them (after deps/feedback).
fn emitPassDataBuffers(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    view: EffectiveView,
    pass: Ast.NodeIndex,
    name: []const u8,
) Lowering.LoweringError!std.ArrayList([]const u8) {
    std.debug.assert(name.len > 0); // pre: named pass (data buffer names derive from it)
    // `:file [paths]` — the pass's WASM data files, spelled like every other
    // file on disk (F12; audit 09 D18 — it was `:data [paths]`, the one key
    // that names a `(data …)` reference everywhere else).
    const data_files = (try childStringVector(arena, out, view, pass, "file")) orelse &.{};
    var data_bufs: std.ArrayList([]const u8) = .empty;
    for (data_files, 0..) |wasm_path, di| {
        const dname = try std.fmt.allocPrint(arena, "{s}__d{d}", .{ name, di });
        try appendDataBuffer(arena, out, container, dname, wasm_path);
        try data_bufs.append(arena, dname);
    }
    return data_bufs;
}

/// Lower a fragment `(pass …)` (the non-compute branch of lowerOnePass): emit its
/// resources in legacy `(pass …)` order — ubuf, [pbuf], data buffers, texture(s),
/// shader, pipeline, bind-group, render-pass, uniform writes — then, if the main
/// pass carried an `@fragment fn post()`, a trailing post pass.
fn lowerFragmentPass(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    view: EffectiveView,
    pass: Ast.NodeIndex,
    name: []const u8,
    code: []const u8,
    format: ?[]const u8,
    scale: ?f64,
    is_main: bool,
    prior_passes: []const PassRef,
    imports: []const EmittedValue,
    constants: []const PassConstant,
    init_code: ?[]const u8,
    frame_steps: *std.ArrayList(EmittedValue),
    init_steps: *std.ArrayList(EmittedValue),
) Lowering.LoweringError!PassRef {
    std.debug.assert(name.len > 0); // pre: named pass
    std.debug.assert(code.len > 0); // pre: pass has WGSL

    // `imports` are the pass's fragments, read by the caller and forwarded onto
    // every module built from the author's text. Feature detection below still
    // reads the pass BODY only — a fragment mentioning `pngine.time` does not
    // make the prelude declare the uniform, and the assembled module then fails
    // with an ordinary unresolved identifier. Documented rather than fixed: the
    // prelude's binding numbering is the pass's own, and a fragment cannot be
    // allowed to change it.

    const feat = try detectPassFeatures(arena, view, pass, code, is_main, prior_passes);
    // The last pass renders to the canvas, and WebGPU keeps no previous canvas
    // texture to read: `:feedback true` there has nothing to feed from. This
    // used to lower anyway — a pooled rgba8unorm target under a canvas-format
    // pipeline, which the GPU refuses at the first set_pipeline and nothing
    // reaches the canvas. Refuse at the pass, naming the shape that works
    // (pass_bloom.sjon: an earlier pass feeds back, the last one reads it).
    if (is_main and feat.feedback) return out.failAt(
        arena,
        view.tree.formHeader(pass).head_span,
        "pass `{s}`: the last pass of a (pass-graph …) renders to the canvas and cannot feed back — " ++
            "feed back in an earlier pass and read it from this one (`textureLoad({s}, …)` or `textureSample({s}, samp, uv)`)",
        .{ name, name, name },
    );
    // Pipeline target format depends only on `is_main and !has_post` (legacy
    // `target_fmt`); the *render target* additionally routes a feedback pass to
    // its own ping-pong pool, so the two conditions are kept separate.
    const is_canvas_format = is_main and !feat.has_post;
    // Where this pass DRAWS, needed here rather than at the render pass because
    // it also decides whether the output texture is emitted at all.
    const renders_to_canvas = is_canvas_format and !feat.feedback;
    // `:scale`'s third refusal, and the sibling of `:format`'s first below: both
    // keys describe the intermediate this pass renders into, and a pass drawing
    // to the canvas has none. The other two live in `lowerOnePass` (a compute
    // pass) and on the texture itself (an explicit `:size`). Since §425 the
    // texture is not even emitted here, so honoring the key is impossible and
    // ignoring it would leave `PASS_SCALE` declared against nothing.
    if (scale) |sc| if (renders_to_canvas) return failSlot(
        arena,
        out,
        view,
        pass,
        "scale",
        "pass `{s}`: `:scale {d}` sizes the intermediate this pass renders into, and this pass renders to the CANVAS — its size is the one the page gives it. Add a `post()` (which makes this pass write an intermediate) or move the key to an earlier pass",
        .{ name, sc },
    );
    const facts = try checkPassFormat(arena, out, view, pass, name, format, feat, is_canvas_format);
    const tex_format = format orelse DEFAULT_PASS_FORMAT;
    // Textures no pass in this graph produced, bound the way the dependencies
    // are. Read after `feat` because the check runs against its `main_code`.
    const reads = try readPassReads(arena, out, view, pass, name, feat.main_code, feat.deps);

    const ubuf = try std.fmt.allocPrint(arena, "{s}__ubuf", .{name});
    const pbuf = try std.fmt.allocPrint(arena, "{s}__pbuf", .{name});
    const tex = try std.fmt.allocPrint(arena, "{s}__tex", .{name});
    const shader = try std.fmt.allocPrint(arena, "{s}__shader", .{name});
    const pipe = try std.fmt.allocPrint(arena, "{s}__pipe", .{name});
    const bg = try std.fmt.allocPrint(arena, "{s}__bg", .{name});

    // Resources in legacy `(pass …)` order: ubuf, [pbuf], texture(s), shader,
    // pipeline, bind-group, render-pass. A feedback pass's output is a `:pool 2`
    // ping-pong pair (this frame renders one, samples the other).
    if (feat.needs_uniform) try appendBuffer(arena, out, container, ubuf, 16);
    if (feat.needs_pointer) try appendBuffer(arena, out, container, pbuf, 48);

    const data_bufs = try emitPassDataBuffers(arena, out, container, view, pass, name);

    const tex_pool: u8 = if (feat.feedback) 2 else 1;
    // A pass that draws to the canvas has no output texture, and until now got
    // one anyway: `renders_to_canvas` means last pass, no `post()`, no
    // feedback, so nothing renders into `tex`, nothing binds it (only feedback
    // does, via `own_tex`), and no later pass can sample it because there is no
    // later pass. It was a canvas-sized rgba8unorm render attachment created
    // and resized for nothing — 8.29 MB at 1920x1080, paid by 15 of the 19
    // `(pass-graph …)` examples, `pass_shader_art` (one pass, straight to the
    // canvas) included. Found by hand-writing the twin of `pass_half_res`:
    // deleting this one form from the twin rendered pixel-identical.
    // `:init`'s refusal, and `:scale`'s sibling one form up: both keys describe
    // the intermediate this pass renders into, and a pass drawing to the canvas
    // has none — there is no texture to seed and WebGPU keeps no handle on the
    // canvas one that a compute shader could store into.
    if (init_code != null and renders_to_canvas) return failSlot(
        arena,
        out,
        view,
        pass,
        "init",
        "pass `{s}`: `:init` seeds the texture this pass renders into, and this pass renders to the CANVAS — there is nothing to seed. Add a `post()` (which makes this pass write an intermediate), turn `:feedback true` on, or seed a hand-written `(texture …)` with a top-level `(init …)`",
        .{name},
    );
    if (!renders_to_canvas) try appendOutputTexture(arena, out, container, tex, tex_pool, tex_format, scale, init_code != null);

    // Main shader carries the full user code (fs + any post()); the prelude gains
    // `samp` when post() shares the module (WGSL validates all functions at module
    // creation) — even though the main pass never binds it — plus a `texture_2d`
    // binding per prior pass the WGSL names (`feat.deps`, never every prior
    // pass: an unread one is a bind-group entry its auto layout lacks) and a
    // `prev_<name>` binding when feedback is on.
    const full_code = try buildPrelude(arena, feat.needs_uniform, feat.needs_pointer, feat.needs_sampler, feat.has_post, feat.deps, reads, feat.feedback, name, facts.scalar, scale, data_bufs.items, code);
    try appendShader(arena, out, container, shader, full_code, imports);

    const target_fmt: ?[]const u8 = if (is_canvas_format) null else tex_format;
    try appendPipeline(arena, out, container, pipe, shader, "fs", target_fmt, try constantChildren(arena, container, constants));
    try appendBindGroup(arena, out, container, bg, pipe, ubuf, feat.needs_uniform, pbuf, feat.needs_pointer, feat.needs_sampler, feat.has_post, feat.deps, reads, feat.feedback, tex, data_bufs.items);

    // Feedback → render to the pooled output texture (emitter detects the pool →
    // begin_render_pass_pool); a plain main pass → canvas; otherwise → the pass's
    // own (intermediate / dependency-source) texture.
    const target_view = if (renders_to_canvas) "context-current-texture" else tex;
    try appendRenderPass(arena, out, container, name, pipe, bg, target_view);
    // Write the runtime uniform(s) before the pass runs (legacy emitAutoFrame order).
    try appendUniformWriteSteps(arena, out, container, name, feat.needs_uniform, ubuf, feat.needs_pointer, pbuf, frame_steps);
    try frame_steps.append(arena, .{ .symbol = name });

    if (feat.post_fn) |pf|
        try lowerPostPass(arena, out, container, name, pf, code, scale, tex, facts.scalar, feat.needs_uniform, ubuf, imports, try postConstants(arena, constants, code), frame_steps);

    // The seed LAST, as legacy `pass_sugar` emitted it (step 7 of the pass
    // expansion), so its resource ids sit after everything the pass itself
    // builds. Phase 1 on a feedback pass: frame 0 reads `base + (1 + 0) % 2`
    // as `prev_<name>`, so that is the instance the seed has to write.
    if (init_code) |ic|
        try lowerInitPasses(arena, out, container, view, pass, name, ic, tex, tex_format, if (feat.feedback) 1 else 0, init_steps);

    // post: the returned `tex` names a form this pass emitted, EXCEPT when it
    // drew to the canvas — and a canvas-drawing pass is the last one, so the
    // `PassRef` a later pass would read it through is never built.
    std.debug.assert(!renders_to_canvas or is_main);
    return .{ .name = name, .tex = tex, .pool_size = tex_pool, .scalar = facts.scalar, .filterable = facts.filterable, .intermediate = !renders_to_canvas };
}

/// Emit the post-processing pass: a separate shader (prelude of pngine? / samp? /
/// `postTex` / `PASS_SCALE`?, then the extracted `post()` fn), a render pipeline
/// (fragment entry `post`, canvas target), a bind group ([uniform?, sampler?,
/// intermediate texture]), and a render pass → canvas. Appended after the main
/// pass so the lowered create order matches legacy `emitPostPass`.
/// `intermediate_tex` is the main pass's output texture (post()'s `postTex`).
fn lowerPostPass(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    pass_name: []const u8,
    post_fn: []const u8,
    code: []const u8,
    scale: ?f64,
    intermediate_tex: []const u8,
    intermediate_scalar: []const u8,
    main_needs_uniform: bool,
    ubuf: []const u8,
    imports: []const EmittedValue,
    constants: []const PassConstant,
    frame_steps: *std.ArrayList(EmittedValue),
) Lowering.LoweringError!void {
    const post_needs_samp = namesIdent(post_fn, "samp");
    // post() uses the main pass's uniform buffer; require it to actually exist so
    // the bind-group cross-ref never dangles (true for the corpus — post() and the
    // main fs() both reference `pngine`).
    const post_uniform = main_needs_uniform and namesIdent(post_fn, "pngine");
    // `PASS_SCALE` on the post stage's own terms: the value, but only when the
    // post fn names it. The MAIN prelude declares it whenever `:scale` is
    // authored; this one cannot — the prelude is the ROOT's own text, so a
    // const this module never reads is a W0001 (pitfall 102), and a scaled
    // pass whose post() ignores its own extent is the ordinary case, not a
    // mistake. `namesIdent`, so a mention inside a comment does not declare
    // the const either. Until this, a post() that wanted its texel grid had
    // to restate the fraction by hand, and the restatement silently broke the
    // day `:scale` changed.
    const post_scale: ?f64 = if (namesIdent(post_fn, "PASS_SCALE")) scale else null;

    const shader = try std.fmt.allocPrint(arena, "{s}__post_shader", .{pass_name});
    const pipe = try std.fmt.allocPrint(arena, "{s}__post_pipe", .{pass_name});
    const bg = try std.fmt.allocPrint(arena, "{s}__post_bg", .{pass_name});
    const pass = try std.fmt.allocPrint(arena, "{s}__post", .{pass_name});

    const post_code = try buildPostShader(arena, post_uniform, post_needs_samp, post_scale, intermediate_scalar, post_fn, code);
    try appendShader(arena, out, container, shader, post_code, imports);

    // Renders to canvas → fragment entry `post`, no explicit target format.
    try appendPipeline(arena, out, container, pipe, shader, "post", null, try constantChildren(arena, container, constants));

    // Entries in prelude binding order (uniform?, sampler?, postTex) — contiguous,
    // no gap (unlike the main bind group's has_post sampler slot).
    var entries: std.ArrayList(EmittedForm) = .empty;
    var binding: f64 = 0;
    if (post_uniform) {
        try entries.append(arena, try beEntry(arena, container, binding, ubuf));
        binding += 1;
    }
    if (post_needs_samp) {
        try entries.append(arena, try beSampler(arena, container, binding, PASS_SAMPLER));
        binding += 1;
    }
    try entries.append(arena, try beTexture(arena, container, binding, intermediate_tex));
    try appendForm(arena, out, container, "bind-group", &.{
        .{ .key = "name", .value = .{ .symbol = bg } },
        .{ .key = "layout", .value = .{ .symbol = pipe } },
        .{ .key = "group", .value = .{ .number = 0 } },
    }, try entries.toOwnedSlice(arena));

    try appendRenderPass(arena, out, container, pass, pipe, bg, "context-current-texture");
    try frame_steps.append(arena, .{ .symbol = pass });
}

// ============================================================================
// Compute pass lowering (compute `(pass …)` main → storage `screen` + auto-blit)
// ============================================================================

/// Expand a single compute `(pass …)` into its canonical forms (mirroring
/// `pass_sugar.emitComputePipelines` + `emitBlitPass`): a uniform / pointer buffer
/// (when referenced), a `screen` storage texture (texture_binding|storage_binding),
/// the compute shader (its prelude injects `screen`), then per `@compute` entry
/// point a compute pipeline + a compute pass over the reference dispatch grid (the
/// first entry's bind group is shared by the rest, as the legacy path does). The
/// main pass also gets an auto-blit: a fullscreen render pass sampling `screen` →
/// canvas. Returns a `PassRef` so a later pass could sample this one's output.
///
/// Scope: compute mains with optional `pngine`/`pointer` uniforms (pass_compute_rainbow).
/// Compute feedback / cross-pass deps (pass_game_of_life) land in a later iteration.
fn lowerComputePass(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    view: EffectiveView,
    pass: Ast.NodeIndex,
    name: []const u8,
    code: []const u8,
    scan: wgsl_scan.ScanResult,
    is_main: bool,
    imports: []const EmittedValue,
    constants: []const PassConstant,
    init_code: ?[]const u8,
    frame_steps: *std.ArrayList(EmittedValue),
    init_steps: *std.ArrayList(EmittedValue),
) Lowering.LoweringError!PassRef {
    std.debug.assert(scan.has_compute and !scan.has_fragment);

    const needs_uniform = namesIdent(code, "pngine");
    const needs_pointer = namesIdent(code, "pointer");

    const ubuf = try std.fmt.allocPrint(arena, "{s}__ubuf", .{name});
    const pbuf = try std.fmt.allocPrint(arena, "{s}__pbuf", .{name});
    const tex = try std.fmt.allocPrint(arena, "{s}__tex", .{name});
    const shader = try std.fmt.allocPrint(arena, "{s}__shader", .{name});

    // Resources in legacy compute order: ubuf?, pbuf?, screen texture, shader.
    if (needs_uniform) try appendBuffer(arena, out, container, ubuf, 16);
    if (needs_pointer) try appendBuffer(arena, out, container, pbuf, 48);
    try appendScreenTexture(arena, out, container, tex, 1);

    const full_code = try buildComputePrelude(arena, needs_uniform, needs_pointer, DEFAULT_PASS_FORMAT, code);
    try appendShader(arena, out, container, shader, full_code, imports);

    // Write the runtime uniform(s) once before the compute pass(es) run (legacy
    // emitAutoFrame writes per pass_info, before its sub-passes execute).
    try appendUniformWriteSteps(arena, out, container, name, needs_uniform, ubuf, needs_pointer, pbuf, frame_steps);

    // One pipeline + compute pass per @compute entry point. The first entry's bind
    // group (same layout for all entries of a module) is reused by the rest.
    // Every entry is the SAME module, so every stage carries the same
    // specialisations — built once, which is also what keeps the emitter's
    // per-module agreement check trivially satisfied.
    const const_children = try constantChildren(arena, container, constants);
    var bg: []const u8 = "";
    var ep: u32 = 0;
    for (scan.slice()) |entry| {
        if (entry.type != .compute) continue;
        const pipe = try std.fmt.allocPrint(arena, "{s}__pipe{d}", .{ name, ep });
        try appendComputePipelineEntry(arena, out, container, pipe, shader, entry.name, const_children);
        if (ep == 0) {
            bg = try std.fmt.allocPrint(arena, "{s}__bg", .{name});
            try appendComputeBindGroup(arena, out, container, bg, pipe, ubuf, needs_uniform, pbuf, needs_pointer, tex);
        }
        std.debug.assert(bg.len > 0);
        const c_pass = try std.fmt.allocPrint(arena, "{s}__c{d}", .{ name, ep });
        try appendComputePassDispatch(arena, out, container, c_pass, pipe, bg, getDispatchSize(entry.workgroup_size));
        try frame_steps.append(arena, .{ .symbol = c_pass });
        ep += 1;
    }

    // The main compute pass blits its `screen` output to the canvas.
    if (is_main) try lowerBlitPass(arena, out, container, name, tex, frame_steps);

    // The seed writes the same `screen` this pass does, so it needs no usage
    // change here — `appendScreenTexture` already asks for `storage-binding`.
    // A compute pass's `screen` is never pooled, hence phase 0.
    if (init_code) |ic|
        try lowerInitPasses(arena, out, container, view, pass, name, ic, tex, DEFAULT_PASS_FORMAT, 0, init_steps);

    return .{ .name = name, .tex = tex, .pool_size = 1 };
}

/// Emit the auto-blit for a compute main (port of `pass_sugar.emitBlitPass`): a
/// blit shader (`BLIT_WGSL`), a canvas render pipeline (vertex `vs`, fragment `fs`),
/// a bind group [`screen` texture, shared sampler], and a render pass → canvas.
/// Appended after the compute pass(es) so the lowered create order matches legacy.
///
/// `frame_steps` is where the blit's own step name lands when the blit is part
/// of an auto-performed list (a compute main's frame). `:expose` calls this with
/// null: the blit is emitted, but appended to NO list, so only a frame that
/// names `<pass>__blit` runs it.
fn lowerBlitPass(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    pass_name: []const u8,
    screen_tex: []const u8,
    frame_steps: ?*std.ArrayList(EmittedValue),
) Lowering.LoweringError!void {
    std.debug.assert(pass_name.len > 0); // pre: a pass has a name
    std.debug.assert(screen_tex.len > 0); // pre: the texture to sample
    const shader = try std.fmt.allocPrint(arena, "{s}__blit_shader", .{pass_name});
    const pipe = try std.fmt.allocPrint(arena, "{s}__blit_pipe", .{pass_name});
    const bg = try std.fmt.allocPrint(arena, "{s}__blit_bg", .{pass_name});
    const blit = try std.fmt.allocPrint(arena, "{s}__blit", .{pass_name});

    // NO imports. This is pngine's own blit, not the author's code — a
    // fragment has no business being validated as part of it, and a fragment
    // that failed to compile here would name a shader the author never wrote.
    try appendShader(arena, out, container, shader, BLIT_WGSL, &.{});
    // NO constants either, for the same reason: `BLIT_WGSL` declares no
    // `override`, so forwarding the author's specialisations here would refuse
    // every compute pass that carries one.
    try appendPipeline(arena, out, container, pipe, shader, "fs", null, &.{});

    const entries = try arena.alloc(EmittedForm, 2);
    entries[0] = try beTexture(arena, container, 0, screen_tex);
    entries[1] = try beSampler(arena, container, 1, PASS_SAMPLER);
    try appendForm(arena, out, container, "bind-group", &.{
        .{ .key = "name", .value = .{ .symbol = bg } },
        .{ .key = "layout", .value = .{ .symbol = pipe } },
        .{ .key = "group", .value = .{ .number = 0 } },
    }, entries);

    try appendRenderPass(arena, out, container, blit, pipe, bg, "context-current-texture");
    if (frame_steps) |steps| try steps.append(arena, .{ .symbol = blit });
}

/// `(pass-graph :expose [name …])`: for each name, emit `<pass>__blit`, the
/// compute-main blit machinery over that pass's intermediate, and add it to NO
/// step list. The document's frame performs `[<pass>__uq <pass> <pass>__blit]`
/// to solo the pass (the queue is the pass's uniform write, present when the
/// pass names `pngine`); restoring the frame to the group runs the whole graph
/// again, and the pass itself is never muted by this key.
///
/// Every entry is the hook's own to check: the `(pass …)` children are consumed
/// by this container, so their names never enter the validator's index, and
/// `:expose` cannot be a cross-ref for the same reason (CONTRIBUTING pitfall
/// 112). The refusals are the passes the blit cannot serve: a name no pass
/// carries; a pass with no intermediate (it draws straight to the canvas, which
/// is what solo wants already); and a pass whose format pngine's own blit
/// shader cannot sample (it declares `texture_2d<f32>` and binds the shared
/// linear sampler).
fn lowerExposedBlits(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    view: EffectiveView,
    container: Ast.NodeIndex,
    refs: []const PassRef,
) Lowering.LoweringError!void {
    const elems = Reader.initFromView(view).vectorNodes(container, "expose") orelse return;
    std.debug.assert(elems.len <= 32); // schema: pass-name-list :max-len 32
    for (elems) |e| {
        // The slot's element kind is `pass-name`, a named symbol; a non-symbol
        // cannot reach here from a validated document, and skipping it lets
        // validation report the type error rather than asserting here.
        if (view.tree.tagOf(e) != .symbol) continue;
        const name = view.tree.symbolText(e);
        var found: ?*const PassRef = null;
        for (refs) |*r| {
            if (std.mem.eql(u8, r.name, name)) {
                found = r;
                break;
            }
        }
        const ref = found orelse return out.failAt(
            arena,
            view.tree.spanOf(e),
            "`:expose` names `{s}`, and no `(pass …)` in this graph carries that name: the list names the graph's own passes, and only one of those has an intermediate to blit",
            .{name},
        );
        if (!ref.intermediate) return out.failAt(
            arena,
            view.tree.spanOf(e),
            "pass `{s}`: `:expose` blits a pass's intermediate to the canvas, and this pass draws straight to the CANVAS already. A frame performing `{s}` puts it on the canvas, and there is no intermediate to blit",
            .{ name, name },
        );
        if (!ref.filterable or !std.mem.eql(u8, ref.scalar, "f32")) return out.failAt(
            arena,
            view.tree.spanOf(e),
            "pass `{s}`: `:expose` blits this pass's intermediate through pngine's own blit shader, which declares `texture_2d<f32>` and samples it with the shared linear sampler. This pass's `:format` is neither filterable nor float, so the bind group it would build is one WebGPU refuses. Give the pass a filterable float `:format` (rgba8unorm, rgba16float, …) or drop it from `:expose`",
            .{name},
        );
        try lowerBlitPass(arena, out, container, ref.name, ref.tex, null);
    }
}

/// The WGSL texel formats a `texture_storage_2d<…, write>` may name without a
/// device feature — WebGPU's core storage list, which is narrower than
/// `texture-format` and narrower again than what a render attachment accepts.
/// `bgra8unorm` is deliberately absent: it is storage-capable only under the
/// `bgra8unorm-storage` feature, which pngine never requests.
fn storageCapable(format: []const u8) bool {
    const core = [_][]const u8{
        "rgba8unorm", "rgba8snorm", "rgba8uint",   "rgba8sint",
        "rgba16uint", "rgba16sint", "rgba16float", "r32uint",
        "r32sint",    "r32float",   "rg32uint",    "rg32sint",
        "rg32float",  "rgba32uint", "rgba32sint",  "rgba32float",
    };
    for (core) |f| if (std.mem.eql(u8, f, format)) return true;
    return false;
}

/// `(pass … :init "<wgsl compute>")` — the one-shot seed, and the whole of what
/// the key means: a compute program that writes the pass's own target ONCE per
/// loaded payload, before the first frame's steps run, so a pass whose every
/// frame reads what the previous one wrote has something to read on frame 0.
///
/// It lowers to what `(init …)` lowers to, one resource kind over: a module
/// whose prelude binds that target as `screen`, a compute pipeline per `@compute`
/// entry point, one bind group, and one compute pass per entry — named into the
/// emitted frame's `:init` list, which `Emitter.emitFrameInit` runs ahead of
/// `:before` and `:perform`.
///
/// That ordering is also why the seed may not name `pngine`: the uniform buffer
/// is filled by a `(queue …)` step in `:perform`, so at `:init` time it is still
/// zeroes and `pngine.width` would be 0. `textureDimensions(screen)` is the
/// extent a seed actually wants, and it needs no binding.
///
/// History: this is `pass_sugar.emitInitCode` (28556d9), which Phase 2f
/// (2f4d68e) carried into the schema and left out of the hook. For two releases
/// `:init` validated, was taught by `docs/sjon-reference.md` and `docs/llms.txt`,
/// and compiled to a byte-identical payload — the same shape as the `--minify`
/// flag min1 resurrected.
fn lowerInitPasses(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    view: EffectiveView,
    pass: Ast.NodeIndex,
    name: []const u8,
    init_code: []const u8,
    tex: []const u8,
    format: []const u8,
    phase: f64,
    init_steps: *std.ArrayList(EmittedValue),
) Lowering.LoweringError!void {
    std.debug.assert(name.len > 0); // pre: named pass
    std.debug.assert(tex.len > 0); // pre: a target to seed

    if (!storageCapable(format)) return failSlot(
        arena,
        out,
        view,
        pass,
        "init",
        "pass `{s}`: `:init` writes this pass's target as a storage texture, and `{s}` is not one of WebGPU's core storage formats — seed a pass whose `:format` is (rgba8unorm, rgba16float, r32float, rgba32float, …), or drop the key",
        .{ name, format },
    );
    // `pngine` is refused rather than served; see the ordering note above.
    if (namesIdent(init_code, "pngine")) return failSlot(
        arena,
        out,
        view,
        pass,
        "init",
        "pass `{s}`: `:init` names `pngine`, and a one-shot seed runs BEFORE the frame step that writes the uniform buffer — every field would read 0. Use `textureDimensions(screen)` for the extent; there is no time yet",
        .{name},
    );

    const scan = wgsl_scan.scanEntryPoints(init_code);
    if (scan.count == 0) return failSlot(
        arena,
        out,
        view,
        pass,
        "init",
        "pass `{s}`: `:init` declares no entry point — a seed is `@compute` WGSL that stores into `screen`",
        .{name},
    );
    // Same reasoning as the pass's own scan: one pipeline+pass per entry, so a
    // truncated reading silently drops seeds.
    if (scan.truncated) return failSlot(
        arena,
        out,
        view,
        pass,
        "init",
        "pass `{s}`: `:init` declares more than {d} entry points — the scan stops there, and lowering a prefix would silently drop the rest",
        .{ name, scan.count },
    );
    if (scan.has_fragment) return failSlot(
        arena,
        out,
        view,
        pass,
        "init",
        "pass `{s}`: `:init` declares an `@fragment` entry point — a seed is a one-shot COMPUTE program, and it has no pipeline to draw with",
        .{name},
    );
    // Not implied by the two above: a `@vertex`-only block scans clean, declares
    // no fragment, and would lower to a shader module and nothing else.
    if (!scan.has_compute) return failSlot(
        arena,
        out,
        view,
        pass,
        "init",
        "pass `{s}`: `:init` declares no `@compute` entry point — a seed is compute WGSL that stores into `screen`",
        .{name},
    );
    for (scan.slice()) |e| {
        if (e.type == .compute and !e.workgroup_known) return failSlot(
            arena,
            out,
            view,
            pass,
            "init",
            "pass `{s}`: `@workgroup_size` on `:init`'s `{s}` is not literal numbers — lowering cannot const-evaluate it here (§325), so write the sizes out",
            .{ name, e.name },
        );
    }

    const shader = try std.fmt.allocPrint(arena, "{s}__init_shader", .{name});
    // NO imports and NO constants, for `lowerBlitPass`'s reason one step over:
    // the seed is its own module, and a fragment or an override forwarded here
    // would be validated against text the author did not write it for.
    const full_code = try buildComputePrelude(arena, false, false, format, init_code);
    try appendShader(arena, out, container, shader, full_code, &.{});

    var bg: []const u8 = "";
    var ep: u32 = 0;
    for (scan.slice()) |entry| {
        if (entry.type != .compute) continue;
        const pipe = try std.fmt.allocPrint(arena, "{s}__init_pipe{d}", .{ name, ep });
        try appendComputePipelineEntry(arena, out, container, pipe, shader, entry.name, &.{});
        if (ep == 0) {
            // One group for every entry: same module, so same auto layout.
            bg = try std.fmt.allocPrint(arena, "{s}__init_bg", .{name});
            const entries = try arena.dupe(EmittedForm, &.{try bePingPongTexture(arena, container, 0, tex, phase)});
            try appendForm(arena, out, container, "bind-group", &.{
                .{ .key = "name", .value = .{ .symbol = bg } },
                .{ .key = "layout", .value = .{ .symbol = pipe } },
                .{ .key = "group", .value = .{ .number = 0 } },
            }, entries);
        }
        std.debug.assert(bg.len > 0); // post: the first entry named the group
        const c_pass = try std.fmt.allocPrint(arena, "{s}__init{d}", .{ name, ep });
        try appendComputePassDispatch(arena, out, container, c_pass, pipe, bg, getDispatchSize(entry.workgroup_size));
        try init_steps.append(arena, .{ .symbol = c_pass });
        ep += 1;
    }
    std.debug.assert(ep > 0); // post: at least one seed pass (scan had a compute entry)
}

/// Build the compute-pass WGSL prelude (port of the `is_fragment=false` branch of
/// `pass_sugar.buildPrelude`): the pngine / pointer uniform structs, then the
/// `screen` storage-texture binding, then the user code (through `appendHoisted`,
/// which lifts its leading directives above both). No fullscreen vertex shader
/// (compute does not draw).
///
/// `format` is the texel format of the texture bound as `screen`, written into
/// the declaration because WGSL demands it and the emitter cross-checks the two
/// (`examples/invalid/storage_texture_format_mismatch.sjon`). A compute main's
/// `screen` is always `DEFAULT_PASS_FORMAT`; a `:init` seed's is whatever the
/// pass it seeds renders into, which is the only reason this is a parameter.
fn buildComputePrelude(
    arena: Allocator,
    needs_uniform: bool,
    needs_pointer: bool,
    format: []const u8,
    code: []const u8,
) Lowering.LoweringError![]u8 {
    std.debug.assert(format.len > 0); // pre: a texel format to declare
    var buf: std.ArrayList(u8) = .empty;
    const binding: u32 = try appendUniformStructs(arena, &buf, needs_uniform, needs_pointer);
    try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "@group(0) @binding({d}) var screen: texture_storage_2d<{s}, write>;\n", .{ binding, format }));
    try appendHoisted(arena, &buf, code);
    return buf.toOwnedSlice(arena);
}

/// A compute pipeline with an explicit entry point (compute mains use named
/// entries like `main_image`, not the default `main`).
fn appendComputePipelineEntry(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    name: []const u8,
    module: []const u8,
    entry: []const u8,
    constants: []const EmittedValue,
) Lowering.LoweringError!void {
    try appendForm(arena, out, container, "compute-pipeline", &.{
        .{ .key = "name", .value = .{ .symbol = name } },
        // GPUPipelineDescriptorBase.layout is required, and a lowered pass always
        // derives it from the WGSL. A kvpair is emittable where the old
        // positional `(layout auto)` was not — which is why it was never stated
        // here, and why nothing enforced it (spec/09 C.2).
        .{ .key = "layout", .value = .{ .symbol = "auto" } },
    }, &.{try stageForm(arena, container, "compute", module, entry, null, constants)});
}

/// The compute bind group (port of `buildComputeBindGroupDescriptor`): uniform?,
/// pointer?, then the `screen` storage texture (bound as a texture-view).
fn appendComputeBindGroup(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    name: []const u8,
    pipe: []const u8,
    ubuf: []const u8,
    needs_uniform: bool,
    pbuf: []const u8,
    needs_pointer: bool,
    screen_tex: []const u8,
) Lowering.LoweringError!void {
    var entries: std.ArrayList(EmittedForm) = .empty;
    var binding: f64 = 0;
    if (needs_uniform) {
        try entries.append(arena, try beEntry(arena, container, binding, ubuf));
        binding += 1;
    }
    if (needs_pointer) {
        try entries.append(arena, try beEntry(arena, container, binding, pbuf));
        binding += 1;
    }
    try entries.append(arena, try beTexture(arena, container, binding, screen_tex));
    try appendForm(arena, out, container, "bind-group", &.{
        .{ .key = "name", .value = .{ .symbol = name } },
        .{ .key = "layout", .value = .{ .symbol = pipe } },
        .{ .key = "group", .value = .{ .number = 0 } },
    }, try entries.toOwnedSlice(arena));
}

/// A compute pass dispatched over an explicit 3D grid `[x y z]` (a compute main's
/// blit grid, pre-computed from @workgroup_size).
fn appendComputePassDispatch(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    name: []const u8,
    pipe: []const u8,
    bg: []const u8,
    dispatch: [3]u32,
) Lowering.LoweringError!void {
    const dvec = try arena.dupe(EmittedValue, &.{
        .{ .number = @floatFromInt(dispatch[0]) },
        .{ .number = @floatFromInt(dispatch[1]) },
        .{ .number = @floatFromInt(dispatch[2]) },
    });
    const bgs = try arena.dupe(EmittedValue, &.{.{ .symbol = bg }});
    const dispatch_child = try arena.dupe(EmittedForm, &.{.{
        .head = "dispatch",
        .kvpairs = try arena.dupe(EmittedKvpair, &.{.{ .key = "workgroups", .value = .{ .vector = dvec } }}),
        .source_form_idx = container,
    }});
    try appendForm(arena, out, container, "compute-pass", &.{
        .{ .key = "name", .value = .{ .symbol = name } },
        .{ .key = "pipeline", .value = .{ .symbol = pipe } },
        .{ .key = "bind-groups", .value = .{ .vector = bgs } },
    }, dispatch_child);
}

/// Compute the dispatch grid from a workgroup size (port of
/// `pass_sugar.getDispatchSize`): ceil(REF / wg) per axis, z forced to 1.
fn getDispatchSize(wg: [3]u32) [3]u32 {
    return .{
        (REF_WIDTH + wg[0] - 1) / wg[0],
        (REF_HEIGHT + wg[1] - 1) / wg[1],
        1,
    };
}

// ---------------------------------------------------------------------------
// pass-v1 form builders
// ---------------------------------------------------------------------------

/// Wrap nested forms as positional `.form` children. SJON's `EmittedForm.children`
/// is `[]const EmittedValue`; every PNGine hook child is a nested form (entry entries,
/// color-attachment, draw, write-buffer), never a bare atom — so each maps to the
/// `.form` arm. Copies into a fresh arena slice (an `EmittedForm` value-copy keeps
/// its arena/static-owned head/kvpairs pointers).
///
/// `pub` because `draw_graph.zig` lowers into the same `LoweringOutput` and used
/// to carry a verbatim copy of this and `appendForm`; hooks.zig is where the two
/// hook modules already share code (see `checkGraphFrameOwnership`).
pub fn formChildren(
    arena: Allocator,
    forms: []const EmittedForm,
) Lowering.LoweringError![]const EmittedValue {
    const vals = try arena.alloc(EmittedValue, forms.len);
    for (forms, 0..) |f, i| vals[i] = .{ .form = f };
    return vals;
}

/// Append a form with the given kvpairs + child forms, stamping the container as
/// provenance. The slices are copied into the arena.
pub fn appendForm(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    head: []const u8,
    kvpairs: []const EmittedKvpair,
    children: []const EmittedForm,
) Lowering.LoweringError!void {
    try out.append(arena, .{
        .head = head,
        .kvpairs = try arena.dupe(EmittedKvpair, kvpairs),
        .children = try formChildren(arena, children),
        .source_form_idx = container,
    });
}

/// A uniform+copy-dst buffer of `size` bytes (the pngine / pointer uniforms).
fn appendBuffer(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    name: []const u8,
    size: f64,
) Lowering.LoweringError!void {
    const usage = try arena.dupe(EmittedValue, &.{ .{ .symbol = "uniform" }, .{ .symbol = "copy-dst" } });
    try appendForm(arena, out, container, "buffer", &.{
        .{ .key = "name", .value = .{ .symbol = name } },
        .{ .key = "size", .value = .{ .number = size } },
        .{ .key = "usage", .value = .{ .vector = usage } },
    }, &.{});
}

/// A `(queue (write-buffer :buffer B :offset 0 :data S))` lowered form: a per-frame
/// write of a built-in runtime data source (`pngine-inputs` / `pointer-inputs`) into
/// a uniform buffer. The emitter's `emitQueueWrite` maps the data source to
/// `writeTimeUniform` / `writePointerUniform` (same path as a hand-authored
/// `(queue …)`, e.g. moving_triangle). The queue form creates no GPU resource; it is
/// collected by name and inlined when the auto-frame's `:perform` references it.
fn appendUniformQueue(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    queue_name: []const u8,
    buffer_name: []const u8,
    data_source: []const u8,
) Lowering.LoweringError!void {
    const wb = EmittedForm{
        .head = "write-buffer",
        .kvpairs = try arena.dupe(EmittedKvpair, &.{
            .{ .key = "buffer", .value = .{ .symbol = buffer_name } },
            .{ .key = "offset", .value = .{ .number = 0 } },
            .{ .key = "data", .value = .{ .symbol = data_source } },
        }),
        .children = &.{},
        .source_form_idx = container,
    };
    try appendForm(arena, out, container, "queue", &.{
        .{ .key = "name", .value = .{ .symbol = queue_name } },
    }, &.{wb});
}

/// Emit the per-frame uniform-write queues for a pass and splice their step names
/// into `frame_steps` so they run BEFORE the pass executes — mirroring legacy
/// `pass_sugar.emitAutoFrame` (writeTimeUniform then writePointerUniform, then the
/// pass). A `(pass …)` that references `pngine`/`pointer` must restream its uniform
/// buffer every frame; without this the buffer holds only its (zero) creation state.
fn appendUniformWriteSteps(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    pass_name: []const u8,
    needs_uniform: bool,
    ubuf: []const u8,
    needs_pointer: bool,
    pbuf: []const u8,
    frame_steps: *std.ArrayList(EmittedValue),
) Lowering.LoweringError!void {
    if (needs_uniform) {
        const q = try std.fmt.allocPrint(arena, "{s}__uq", .{pass_name});
        try appendUniformQueue(arena, out, container, q, ubuf, "pngine-inputs");
        try frame_steps.append(arena, .{ .symbol = q });
    }
    if (needs_pointer) {
        const q = try std.fmt.allocPrint(arena, "{s}__pq", .{pass_name});
        try appendUniformQueue(arena, out, container, q, pbuf, "pointer-inputs");
        try frame_steps.append(arena, .{ .symbol = q });
    }
}

/// A `(pass … :file …)` storage buffer (`storage|copy-dst`) whose size + initial bytes
/// the emitter derives from the WASM file at `wasm_path` (no `:size`). The emitter's
/// `:file` branch (`emitWasmDataBuffer`) reads/parses the file and emits the WASM
/// init/copy opcodes.
fn appendDataBuffer(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    name: []const u8,
    wasm_path: []const u8,
) Lowering.LoweringError!void {
    const usage = try arena.dupe(EmittedValue, &.{ .{ .symbol = "storage" }, .{ .symbol = "copy-dst" } });
    try appendForm(arena, out, container, "buffer", &.{
        .{ .key = "name", .value = .{ .symbol = name } },
        .{ .key = "file", .value = .{ .string = wasm_path } },
        .{ .key = "usage", .value = .{ .vector = usage } },
    }, &.{});
}

/// A canvas-sized rgba8unorm texture with the given `usage` symbols. `pool > 1`
/// makes it a ping-pong pair: `pool` sequential ids the render pass alternates.
fn appendTextureForm(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    name: []const u8,
    pool: u8,
    format: []const u8,
    scale: ?f64,
    usage: []const EmittedValue,
) Lowering.LoweringError!void {
    var kvs: [6]EmittedKvpair = undefined;
    var n: usize = 0;
    kvs[n] = .{ .key = "name", .value = .{ .symbol = name } };
    n += 1;
    kvs[n] = .{ .key = "size", .value = .{ .symbol = "canvas" } };
    n += 1;
    kvs[n] = .{ .key = "format", .value = .{ .symbol = format } };
    n += 1;
    kvs[n] = .{ .key = "usage", .value = .{ .vector = usage } };
    n += 1;
    // `(pass … :scale …)` is spelled on the texture it lowers to, so the
    // emitter reads ONE key and the sugar has nothing of its own to resolve.
    if (scale) |sc| {
        kvs[n] = .{ .key = "scale", .value = .{ .number = sc } };
        n += 1;
    }
    if (pool > 1) {
        kvs[n] = .{ .key = "pool", .value = .{ .number = @floatFromInt(pool) } };
        n += 1;
    }
    try appendForm(arena, out, container, "texture", kvs[0..n], &.{});
}

/// A fragment pass's output texture (texture_binding|render_attachment), mirroring
/// legacy `emitCanvasTexture(is_fragment=true)`. Feedback passes the `:pool 2` pair.
/// `format` is the pass's `:format` or the sugar's `rgba8unorm` default.
fn appendOutputTexture(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    name: []const u8,
    pool: u8,
    format: []const u8,
    scale: ?f64,
    seeded: bool,
) Lowering.LoweringError!void {
    // `seeded` is `(pass … :init …)`: the one-shot compute stores into this same
    // texture, which a render attachment may not do without the usage saying so.
    // It is the one place `:init` reaches a GPU descriptor, and therefore the
    // reason the key owes a fixture (CONTRIBUTING, "the sugar tier pays the
    // core's toll").
    const usage = if (seeded)
        try arena.dupe(EmittedValue, &.{ .{ .symbol = "texture-binding" }, .{ .symbol = "render-attachment" }, .{ .symbol = "storage-binding" } })
    else
        try arena.dupe(EmittedValue, &.{ .{ .symbol = "texture-binding" }, .{ .symbol = "render-attachment" } });
    try appendTextureForm(arena, out, container, name, pool, format, scale, usage);
}

/// A compute main's `screen` output texture (texture_binding|storage_binding — the
/// shader stores into it), mirroring `emitCanvasTexture(is_fragment=false)`.
fn appendScreenTexture(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    name: []const u8,
    pool: u8,
) Lowering.LoweringError!void {
    const usage = try arena.dupe(EmittedValue, &.{ .{ .symbol = "texture-binding" }, .{ .symbol = "storage-binding" } });
    try appendTextureForm(arena, out, container, name, pool, DEFAULT_PASS_FORMAT, null, usage);
}

/// A pipeline stage: `(vertex :module M :entry E)` or
/// `(fragment :module M :entry E (color-target :format F))`. `target_format` is read
/// on the fragment stage only, and null there means the canvas format.
/// `constants` are the pass's `(constant …)` children, already built by
/// `constantChildren` and shared by every stage over the same module.
fn stageForm(
    arena: Allocator,
    container: Ast.NodeIndex,
    head: []const u8,
    module: []const u8,
    entry: []const u8,
    target_format: ?[]const u8,
    constants: []const EmittedValue,
) Lowering.LoweringError!EmittedForm {
    var children: std.ArrayList(EmittedValue) = .empty;
    // Only a FRAGMENT stage carries targets; `GPUFragmentState.targets` is
    // required, so a null `target_format` now means "the canvas format", spelled
    // out as `preferred-canvas-format`, rather than omitting the child and
    // leaving gpu.js to substitute one. Same resulting pipeline — the emitter
    // encodes `preferred-canvas-format` as an empty target object, which every
    // runtime already resolves — but the descriptor now SAYS what it renders to.
    // (spec/09 step B). The `(targets …)` wrapper that held it went with 02 R3.
    if (std.mem.eql(u8, head, "fragment")) {
        const target = EmittedForm{
            .head = "color-target",
            .kvpairs = try arena.dupe(EmittedKvpair, &.{.{
                .key = "format",
                .value = .{ .symbol = target_format orelse "preferred-canvas-format" },
            }}),
            .source_form_idx = container,
        };
        try children.append(arena, .{ .form = target });
    }
    // After the color-target: a fragment stage's business is what it draws to, and
    // the emitter reads both by head, so the order is free.
    for (constants) |c| try children.append(arena, c);
    return .{
        .head = head,
        .kvpairs = try arena.dupe(EmittedKvpair, &.{
            .{ .key = "module", .value = .{ .symbol = module } },
            .{ .key = "entry", .value = .{ .symbol = entry } },
        }),
        .children = try children.toOwnedSlice(arena),
        .source_form_idx = container,
    };
}

/// A canonical render pipeline for a `(pass …)`: positional `(vertex :module M :entry vs)`
/// + `(fragment :module M :entry FE (color-target :format FMT))`. This is the
/// same shape a hand-authored pipeline uses, so the emitter's single authored
/// descriptor path builds it (§86 replaced the legacy flat `:flat-module` keys; the
/// runtime is unchanged — gpu.js normalizes the old `targetFormat` string and the
/// `targets` array to the identical GPURenderPipeline).
fn appendPipeline(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    name: []const u8,
    module: []const u8,
    fragment_entry: []const u8,
    target_format: ?[]const u8,
    constants: []const EmittedValue,
) Lowering.LoweringError!void {
    const vertex = try stageForm(arena, container, "vertex", module, "vs", null, constants);
    const fragment = try stageForm(arena, container, "fragment", module, fragment_entry, target_format, constants);
    try appendForm(arena, out, container, "render-pipeline", &.{
        .{ .key = "name", .value = .{ .symbol = name } },
        .{ .key = "layout", .value = .{ .symbol = "auto" } }, // required; see appendComputePipeline
    }, &.{ vertex, fragment });
}

/// A bind group in canonical pass binding order: uniform, pointer, the shared
/// sampler (when sampling), then a texture-view per dependency, then the feedback
/// texture, then the `(pass … :file …)` storage buffers (D0, D1, …). With `has_post` the
/// prelude declares `samp` without `needs_sampler` — that slot is a gap the bind
/// group skips (no entry), so bindings still line up.
///
/// When the pass feeds back, or samples a *pooled* dependency, the bind group
/// becomes a `:pool 2` A/B pair: dependency entries carry `:ping-pong 0` (read the
/// partner written this frame), the feedback entry `:ping-pong 1` (read last
/// frame's output). The emitter resolves each per pool instance; the render pass
/// alternates them via setBindGroupPool.
fn appendBindGroup(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    name: []const u8,
    pipe: []const u8,
    ubuf: []const u8,
    needs_uniform: bool,
    pbuf: []const u8,
    needs_pointer: bool,
    needs_sampler: bool,
    has_post: bool,
    prior_passes: []const PassRef,
    reads: []const ReadRef,
    feedback: bool,
    own_tex: []const u8,
    data_bufs: []const []const u8,
) Lowering.LoweringError!void {
    std.debug.assert(name.len > 0); // pre: named bind group
    std.debug.assert(pipe.len > 0); // pre: layout pipeline named
    var any_dep_pooled = false;
    for (prior_passes) |dep| {
        if (dep.pool_size > 1) {
            any_dep_pooled = true;
            break;
        }
    }
    const pool_size: u8 = if (feedback or any_dep_pooled) 2 else 1;

    var entries: std.ArrayList(EmittedForm) = .empty;
    var binding: f64 = 0;
    if (needs_uniform) {
        try entries.append(arena, try beEntry(arena, container, binding, ubuf));
        binding += 1;
    }
    if (needs_pointer) {
        try entries.append(arena, try beEntry(arena, container, binding, pbuf));
        binding += 1;
    }
    if (needs_sampler) {
        try entries.append(arena, try beSampler(arena, container, binding, PASS_SAMPLER));
        binding += 1;
    } else if (has_post) {
        binding += 1; // prelude `samp` for post(); fs() doesn't bind it (gap).
    }
    // Dependency textures (ping-pong 0 — the partner this frame wrote).
    for (prior_passes) |dep| {
        try entries.append(arena, try bePingPongTexture(arena, container, binding, dep.tex, 0));
        binding += 1;
    }
    // `:reads` textures — plain entries in a group that may be pooled, exactly
    // as the data buffers below are: nothing in this graph writes them, so
    // there is no partner to alternate with.
    for (reads) |rd| {
        try entries.append(arena, try beTexture(arena, container, binding, rd.name));
        binding += 1;
    }
    // Own feedback texture (ping-pong 1 — last frame's output).
    if (feedback) {
        try entries.append(arena, try bePingPongTexture(arena, container, binding, own_tex, 1));
        binding += 1;
    }
    // Data storage buffers (D0, D1, …) — bound after deps/feedback (legacy order).
    for (data_bufs) |dbuf| {
        try entries.append(arena, try beEntry(arena, container, binding, dbuf));
        binding += 1;
    }

    try appendBindGroupForm(arena, out, container, name, pipe, pool_size, try entries.toOwnedSlice(arena));
}

/// Assemble the `(bind-group …)` form from its computed entries: name /
/// layout / group kvpairs (+ a `pool` kvpair when ping-ponged);
/// the children are the entry forms. Split out of appendBindGroup to keep it
/// within the ≤70-line budget (item 4.1).
fn appendBindGroupForm(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    name: []const u8,
    pipe: []const u8,
    pool_size: u8,
    entries: []EmittedForm,
) Lowering.LoweringError!void {
    std.debug.assert(name.len > 0); // pre: named bind group
    var kvs: [4]EmittedKvpair = undefined;
    var n: usize = 0;
    kvs[n] = .{ .key = "name", .value = .{ .symbol = name } };
    n += 1;
    kvs[n] = .{ .key = "layout", .value = .{ .symbol = pipe } };
    n += 1;
    kvs[n] = .{ .key = "group", .value = .{ .number = 0 } };
    n += 1;
    if (pool_size > 1) {
        kvs[n] = .{ .key = "pool", .value = .{ .number = @floatFromInt(pool_size) } };
        n += 1;
    }
    try out.append(arena, .{
        .head = "bind-group",
        .kvpairs = try arena.dupe(EmittedKvpair, kvs[0..n]),
        .children = try formChildren(arena, entries),
        .source_form_idx = container,
    });
}

/// One `(entry :binding N :buffer B)` bind-group entry.
fn beEntry(arena: Allocator, container: Ast.NodeIndex, binding: f64, buffer: []const u8) Lowering.LoweringError!EmittedForm {
    return .{
        .head = "entry",
        .kvpairs = try arena.dupe(EmittedKvpair, &.{
            .{ .key = "binding", .value = .{ .number = binding } },
            .{ .key = "buffer", .value = .{ .symbol = buffer } },
        }),
        .source_form_idx = container,
    };
}

/// One `(entry :binding N :sampler S)` bind-group entry.
fn beSampler(arena: Allocator, container: Ast.NodeIndex, binding: f64, sampler: []const u8) Lowering.LoweringError!EmittedForm {
    return .{
        .head = "entry",
        .kvpairs = try arena.dupe(EmittedKvpair, &.{
            .{ .key = "binding", .value = .{ .number = binding } },
            .{ .key = "sampler", .value = .{ .symbol = sampler } },
        }),
        .source_form_idx = container,
    };
}

/// One `(entry :binding N :texture T)` bind-group entry (a texture-view binding).
fn beTexture(arena: Allocator, container: Ast.NodeIndex, binding: f64, texture: []const u8) Lowering.LoweringError!EmittedForm {
    return .{
        .head = "entry",
        .kvpairs = try arena.dupe(EmittedKvpair, &.{
            .{ .key = "binding", .value = .{ .number = binding } },
            .{ .key = "texture", .value = .{ .symbol = texture } },
        }),
        .source_form_idx = container,
    };
}

/// One `(entry :binding N :texture T :ping-pong P)` entry — a texture-view the emitter
/// resolves to the pooled instance `T.base + (P + pool_idx) % size` when `T` is a
/// ping-pong pool (else plain `T`). Feedback uses P=1, a pooled dependency P=0.
fn bePingPongTexture(arena: Allocator, container: Ast.NodeIndex, binding: f64, texture: []const u8, ping_pong: f64) Lowering.LoweringError!EmittedForm {
    return .{
        .head = "entry",
        .kvpairs = try arena.dupe(EmittedKvpair, &.{
            .{ .key = "binding", .value = .{ .number = binding } },
            .{ .key = "texture", .value = .{ .symbol = texture } },
            .{ .key = "ping-pong", .value = .{ .number = ping_pong } },
        }),
        .source_form_idx = container,
    };
}

/// A `(shader-module :name N :code …)` form.
fn appendShader(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    name: []const u8,
    code: []const u8,
    imports: []const EmittedValue,
) Lowering.LoweringError!void {
    if (imports.len == 0) {
        // No `:imports` key at all rather than an empty vector: the schema's
        // `wgsl-ref-list` has `:min-len 1`, and every pass that predates
        // fragments must keep lowering to exactly the forms it did — the golden
        // traces pin the create-call sequence.
        try appendForm(arena, out, container, "shader-module", &.{
            .{ .key = "name", .value = .{ .symbol = name } },
            .{ .key = "code", .value = .{ .string = code } },
        }, &.{});
        return;
    }
    try appendForm(arena, out, container, "shader-module", &.{
        .{ .key = "name", .value = .{ .symbol = name } },
        .{ .key = "code", .value = .{ .string = code } },
        .{ .key = "imports", .value = .{ .vector = imports } },
    }, &.{});
}

/// Read a pass's `:imports` into a vector of symbol values the emitted shader
/// modules can carry.
///
/// The pass's fragments go onto the THREE modules built from the author's text
/// — the main shader, the `post()` shader and the compute main — because any of
/// them may call a fragment function, and dead-code elimination removes what
/// each does not use. Never onto `BLIT_WGSL`: that is pngine's own code, and an
/// author's fragment has no business being validated as part of it.
/// Is `tex` the first argument of a `textureSample…` call in `code`?
///
/// The question is narrow on purpose: the only sampler this prelude binds is
/// `samp`, and `samp` is `linear`. A sampler a shader uses with a DEPTH texture
/// gets `non-filtering` in the pipeline's auto layout — WebGPU's rule, not
/// pngine's — so `textureSample(depthTex, samp, …)` asks for a bind group whose
/// sampler entry Chrome refuses ("Filtering sampler is incompatible with
/// non-filtering sampler binding"). wgpu-native accepts it, which is exactly the
/// kind of divergence a compile-time refusal should absorb.
///
/// Scans for `textureSample` as a whole identifier outside comments, then reads
/// the identifier after the `(`. Anything else (a variable holding the texture,
/// a helper taking it as a parameter) is not matched and not refused: the check
/// is here to catch the shape an author writes, not to prove a negative.
/// Complexity: O(code.len).
fn sampledByName(code: []const u8, tex: []const u8) bool {
    std.debug.assert(tex.len > 0); // pre: a name to look for
    const call = "textureSample";
    var i: u32 = 0;
    const len: u32 = @intCast(code.len);
    // Every branch advances `i` by at least one, so `code.len` iterations suffice.
    for (0..code.len + 1) |_| {
        if (i >= len) break;
        const after = wgsl_scan.skipTrivia(code, i);
        if (after != i) {
            i = after;
            continue;
        }
        if (!wgsl_scan.matchAt(code, i, call) or (i > 0 and isIdentChar(code[i - 1]))) {
            i += 1;
            continue;
        }
        // `textureSample`, `textureSampleLevel`, `textureSampleBias`, … — every
        // one of them takes the texture first and the sampler second.
        var j = i + @as(u32, @intCast(call.len));
        while (j < len and isIdentChar(code[j])) j += 1;
        j = wgsl_scan.skipTrivia(code, j);
        if (j >= len or code[j] != '(') {
            i += 1;
            continue;
        }
        j = wgsl_scan.skipTrivia(code, j + 1);
        const arg_start = j;
        while (j < len and isIdentChar(code[j])) j += 1;
        if (std.mem.eql(u8, code[arg_start..j], tex)) return true;
        i = j;
    }
    return false;
}

/// Read `(pass-graph … :before [step …])` — the frame steps that run ahead of
/// the graph's own. Same shape as `readImports`: a vector of cross-ref symbols
/// the validator has already resolved, copied through as symbols.
fn readGraphBefore(
    arena: Allocator,
    view: EffectiveView,
    container: Ast.NodeIndex,
) Lowering.LoweringError![]const EmittedValue {
    const elems = Reader.initFromView(view).vectorNodes(container, "before") orelse return &.{};
    const out = try arena.alloc(EmittedValue, elems.len);
    for (elems, 0..) |e, i| {
        // The element kind is `frame-step`, a symbol, so a non-symbol cannot
        // reach here after validation.
        if (view.tree.tagOf(e) != .symbol) return &.{};
        out[i] = .{ .symbol = try arena.dupe(u8, view.tree.symbolText(e)) };
    }
    return out;
}

fn readImports(
    arena: Allocator,
    view: EffectiveView,
    form_idx: Ast.NodeIndex,
) Lowering.LoweringError![]const EmittedValue {
    const elems = Reader.initFromView(view).vectorNodes(form_idx, "imports") orelse return &.{};
    const out = try arena.alloc(EmittedValue, elems.len);
    for (elems, 0..) |e, i| {
        // The schema's element kind is `wgsl-ref`, a symbol, so a non-symbol
        // cannot reach here after validation.
        if (view.tree.tagOf(e) != .symbol) return &.{};
        out[i] = .{ .symbol = try arena.dupe(u8, view.tree.symbolText(e)) };
    }
    return out;
}

/// One `(constant :name N :value V)` child of a `(pass …)`, with `:value`
/// already resolved to a number.
///
/// It has to BE a number by the time it leaves this hook: `EmittedValue` has no
/// expression variant (lowering produces data, never recursive computation),
/// which is the same reason `(init :workgroups …)` resolves its counts through
/// the lowering env instead of forwarding the expression to the emitter.
const PassConstant = struct {
    name: []const u8,
    value: f64,
};

/// Ceiling on the `(constant …)` children of one pass, so every loop over the
/// list is bounded. A pass specialises a handful of overrides — this is a
/// runaway guard, not a budget.
const MAX_PASS_CONSTANTS: usize = 64;

/// Read a pass's `(constant …)` children, evaluating each `:value` through the
/// lowering env exactly as `(init :workgroups …)` evaluates its counts.
///
/// The slot is `override-number` — a literal, a bounded expression over
/// `(define …)` constants, or a bare `(define …)` name. What is NOT checked here
/// is the value's WIDTH, and it cannot be: an override's WGSL type lives inside
/// a `:code` string nothing has parsed at lowering time. The emitter type-checks
/// the number against the reflected `override` declaration instead, and refuses
/// a value that declaration cannot hold.
/// Read `(pass … :scale …)` — the fraction of the canvas this pass's
/// intermediate takes in each dimension, or null when absent.
///
/// Evaluated the way `(constant :value …)` and `(init :workgroups …)` are: a
/// literal fast path, otherwise `Expr.eval` against the lowering env, so
/// `(/ 1 2)` and a bare `(define …)` name both resolve here rather than
/// reaching the emitter as an expression `EmittedValue` cannot carry.
///
/// The RANGE is not checked here. The value lands on the `(texture :scale …)`
/// this pass lowers to, and the emitter checks that key for every texture,
/// authored or lowered — one rule, one message, one place.
fn readPassScale(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    input: *const Lowering.LoweringInput,
    pass: Ast.NodeIndex,
) Lowering.LoweringError!?f64 {
    const view = input.view;
    const r = Reader.initFromView(view);
    const node = r.authorNode(pass, "scale") orelse return null;
    const pass_name = r.symbol(pass, "name") orelse "?";
    const n: ?f64 = switch (view.tree.tagOf(node)) {
        .number, .number_i64, .number_u64 => view.tree.numberOf(node),
        else => blk: {
            var res = sjon.Expr.eval(input.arena, view.tree, node, input.env, input.schema.*) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => break :blk null,
            };
            defer res.deinit();
            break :blk switch (res.value) {
                .number => |v| v,
                else => null,
            };
        },
    };
    return n orelse out.failAt(
        arena,
        view.tree.spanOf(node),
        "pass `{s}`: `:scale` did not evaluate to a number — it is a literal, a `(define …)` constant, or a bounded expression over them",
        .{pass_name},
    );
}

fn readPassConstants(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    input: *const Lowering.LoweringInput,
    pass: Ast.NodeIndex,
) Lowering.LoweringError![]const PassConstant {
    const view = input.view;
    const r = Reader.initFromView(view);
    // Message-only read: `lowerOnePass` is the one that refuses a nameless pass.
    const pass_name = r.symbol(pass, "name") orelse "?";
    var list: std.ArrayList(PassConstant) = .empty;
    var it = r.childrenWithHead(pass, "constant");
    while (it.next()) |c| {
        const head_span = view.tree.formHeader(c).head_span;
        if (list.items.len >= MAX_PASS_CONSTANTS) return out.failAt(
            arena,
            head_span,
            "pass `{s}`: more than {d} `(constant …)` children",
            .{ pass_name, MAX_PASS_CONSTANTS },
        );
        // Both keys are schema-required on `(constant …)`, so an absent one is
        // the registry-less "internal:" shape, not something an author can write.
        const cname = r.symbol(c, "name") orelse return out.failAt(
            arena,
            head_span,
            "internal: pass `{s}` has a `(constant …)` with no `:name`",
            .{pass_name},
        );
        const vnode = r.authorNode(c, "value") orelse return out.failAt(
            arena,
            head_span,
            "internal: pass `{s}` has a `(constant :name {s} …)` with no `:value`",
            .{ pass_name, cname },
        );
        const n: ?f64 = switch (view.tree.tagOf(vnode)) {
            .number, .number_i64, .number_u64 => view.tree.numberOf(vnode),
            else => blk: {
                var res = sjon.Expr.eval(input.arena, view.tree, vnode, input.env, input.schema.*) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => break :blk null,
                };
                defer res.deinit();
                break :blk switch (res.value) {
                    .number => |v| v,
                    else => null,
                };
            },
        };
        // Blamed at the VALUE, not the form: the name resolved fine, and the
        // slot that did not is the one to edit.
        if (n == null) return out.failAt(
            arena,
            view.tree.spanOf(vnode),
            "pass `{s}`: `(constant :name {s} …)` did not evaluate to a number — a value is a literal, a `(define …)` constant, or a bounded expression over them",
            .{ pass_name, cname },
        );
        try list.append(arena, .{ .name = try arena.dupe(u8, cname), .value = n.? });
    }
    return list.toOwnedSlice(arena);
}

/// The `(constant …)` children one lowered pipeline stage carries.
///
/// The same slice goes on a render pipeline's vertex AND fragment stage, which
/// is deliberate rather than redundant: the emitter keys specialisations by
/// MODULE and treats the same name at the same value as idempotent, precisely
/// because WebGPU's own per-stage `constants` dict makes a shared module carry
/// it twice. A hand-authored pipeline over one module looks the same.
fn constantChildren(
    arena: Allocator,
    container: Ast.NodeIndex,
    consts: []const PassConstant,
) Lowering.LoweringError![]const EmittedValue {
    if (consts.len == 0) return &.{};
    std.debug.assert(consts.len <= MAX_PASS_CONSTANTS); // pre: bounded by readPassConstants
    const out = try arena.alloc(EmittedValue, consts.len);
    for (consts, 0..) |c, i| {
        out[i] = .{ .form = .{
            .head = "constant",
            .kvpairs = try arena.dupe(EmittedKvpair, &.{
                .{ .key = "name", .value = .{ .symbol = c.name } },
                .{ .key = "value", .value = .{ .number = c.value } },
            }),
            .source_form_idx = container,
        } };
    }
    return out;
}

/// The subset of a pass's constants the POST module can take.
///
/// That module is a prelude, the fullscreen vertex shader and the extracted
/// `post()` function — and a function body cannot hold a module-scope
/// `override`. So an override the post module declares came from `:imports`,
/// which both modules share, while one the pass's own `:code` declares exists in
/// the main module alone. Forwarding that second kind would specialise a
/// declaration that is not there, and the emitter would refuse a document that
/// is fine.
///
/// `declaresName` is the right instrument and a substring scan is not: it strips
/// comments and ignores everything inside a function body by brace depth, so a
/// pass that merely MENTIONS the override in a comment does not lose its post
/// specialisation (the §407 / §408 bug class, in the one place this feature
/// could have reintroduced it).
fn postConstants(
    arena: Allocator,
    consts: []const PassConstant,
    code: []const u8,
) Lowering.LoweringError![]const PassConstant {
    if (consts.len == 0) return &.{};
    var list: std.ArrayList(PassConstant) = .empty;
    for (consts) |c| {
        if (!fragments.declaresName(code, c.name)) try list.append(arena, c);
    }
    return list.toOwnedSlice(arena);
}

/// A render pass (clear [0,0,0,1] → store) drawing the fullscreen triangle
/// (3 vertices) to `view` — `context-current-texture` for canvas passes or a
/// declared texture name for the post-processing intermediate target. Named
/// `name` so the auto-frame's :perform resolves it.
fn appendRenderPass(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    name: []const u8,
    pipe: []const u8,
    bg: []const u8,
    view: []const u8,
) Lowering.LoweringError!void {
    const clear = try arena.dupe(EmittedValue, &.{ .{ .number = 0 }, .{ .number = 0 }, .{ .number = 0 }, .{ .number = 1 } });
    const color_att = EmittedForm{
        .head = "color-attachment",
        .kvpairs = try arena.dupe(EmittedKvpair, &.{
            .{ .key = "view", .value = .{ .symbol = view } },
            .{ .key = "clear-value", .value = .{ .vector = clear } },
            .{ .key = "load-op", .value = .{ .symbol = "clear" } },
            .{ .key = "store-op", .value = .{ .symbol = "store" } },
        }),
        .source_form_idx = container,
    };
    const draw = EmittedForm{
        .head = "draw",
        .kvpairs = try arena.dupe(EmittedKvpair, &.{
            .{ .key = "vertex-count", .value = .{ .number = 3 } },
        }),
        .source_form_idx = container,
    };
    const bgs = try arena.dupe(EmittedValue, &.{.{ .symbol = bg }});
    try appendForm(arena, out, container, "render-pass", &.{
        .{ .key = "name", .value = .{ .symbol = name } },
        .{ .key = "pipeline", .value = .{ .symbol = pipe } },
        .{ .key = "bind-groups", .value = .{ .vector = bgs } },
    }, &.{ color_att, draw });
}

/// Append the `pngine` (binding 0) and `pointer` (next) uniform struct declarations
/// when referenced, returning the next free binding index. Shared by the fragment
/// (`buildPrelude`) and compute (`buildComputePrelude`) preludes.
fn appendUniformStructs(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    needs_uniform: bool,
    needs_pointer: bool,
) Lowering.LoweringError!u32 {
    var binding: u32 = 0;
    if (needs_uniform) {
        try buf.appendSlice(arena,
            \\struct PngineInputs { time: f32, width: f32, height: f32, aspect: f32 }
            \\@group(0) @binding(0) var<uniform> pngine: PngineInputs;
            \\
        );
        binding += 1;
    }
    if (needs_pointer) {
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "struct PointerInputs {{ x: f32, y: f32, clickX: f32, clickY: f32, dx: f32, dy: f32, buttons: f32, pressure: f32, modifiers: f32, scrollX: f32, scrollY: f32, _pad: f32 }}\n@group(0) @binding({d}) var<uniform> pointer: PointerInputs;\n", .{binding}));
        binding += 1;
    }
    return binding;
}

/// Build the auto-injected WGSL prelude + user code (port of
/// `pass_sugar.buildPrelude`): the pngine / pointer uniform structs, an optional
/// `samp` binding, the fullscreen-triangle vertex shader, then a `texture_2d`
/// binding per dependency (by pass name) and a `prev_<name>` feedback binding.
/// `samp` is declared when the fragment samples (`needs_sampler`) OR a `post()`
/// stage shares the module (`has_post`) — the latter without the main pass binding
/// it (a gap the bind group skips). `postTex` (has_post) comes last, after the
/// deps / feedback, exactly where the legacy prelude places it. A single running
/// `binding` counter keeps the WGSL bindings in lockstep with `appendBindGroup`.
///
/// The user code goes in through `appendHoisted`, which lifts its leading
/// directives back above everything declared here — see there for why.
fn buildPrelude(
    arena: Allocator,
    needs_uniform: bool,
    needs_pointer: bool,
    needs_sampler: bool,
    has_post: bool,
    prior_passes: []const PassRef,
    reads: []const ReadRef,
    feedback: bool,
    name: []const u8,
    own_scalar: []const u8,
    scale: ?f64,
    data_bufs: []const []const u8,
    code: []const u8,
) Lowering.LoweringError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    var binding: u32 = try appendUniformStructs(arena, &buf, needs_uniform, needs_pointer);
    if (needs_sampler or has_post) {
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "@group(0) @binding({d}) var samp: sampler;\n", .{binding}));
        binding += 1;
    }
    try buf.appendSlice(arena, FULLSCREEN_VS);
    // Dependency textures (one per prior pass the WGSL names, bound by that
    // pass's name so the user WGSL reads it as `textureSample(<dep>, samp, uv)`).
    // The `<T>` follows each producer's `:format` sample class, so a pass that
    // renders `rgba8uint` is read as `texture_2d<u32>` — the prelude WRITES this
    // declaration, so it is the one place that cannot be left to agree by luck.
    for (prior_passes) |dep| {
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "@group(0) @binding({d}) var {s}: texture_2d<{s}>;\n", .{ binding, dep.name, dep.scalar }));
        binding += 1;
    }
    // `:reads` textures — the ones no pass produced — bound by their own names,
    // after the dependencies and before the feedback pair. Their type came from
    // each texture's `:format` (`readTextureBindingType`), which is why a depth
    // buffer reads as `texture_depth_2d` without the author saying so.
    for (reads) |rd| {
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "@group(0) @binding({d}) var {s}: {s};\n", .{ binding, rd.name, rd.wgsl_type }));
        binding += 1;
    }
    // Feedback texture (`prev_<name>` — the previous frame's own output, so its
    // scalar is this pass's own).
    if (feedback) {
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "@group(0) @binding({d}) var prev_{s}: texture_2d<{s}>;\n", .{ binding, name, own_scalar }));
        binding += 1;
    }
    // Data storage buffers (`D0`, `D1`, … — `(pass … :file …)`), declared after the
    // deps / feedback bindings, before `postTex` (legacy prelude order).
    for (data_bufs, 0..) |_, di| {
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "@group(0) @binding({d}) var<storage, read> D{d}: array<f32>;\n", .{ binding, di }));
        binding += 1;
    }
    // postTex (has_post): referenced by post(), declared so the shared module
    // compiles; fs() never binds it → auto-layout drops it (the gap).
    if (has_post) {
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "@group(0) @binding({d}) var postTex: texture_2d<{s}>;\n", .{ binding, own_scalar }));
        binding += 1;
    }
    // `PASS_SCALE` — declared ONLY when `:scale` is authored. The prelude is
    // the ROOT's own text, so an unreferenced declaration here is a W0001 on
    // every pass in the corpus (pitfall 102), and a const nobody asked for is
    // exactly that. `pngine.width`/`height` keep meaning the canvas, so this is
    // how a scaled pass finds its own extent. A scaled pass's `post()` gets its
    // own copy from `buildPostShader`, gated there on the post fn naming it —
    // same const, one more condition, for the same pitfall-102 reason.
    if (scale) |sc| try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "const PASS_SCALE: f32 = {d};\n", .{sc}));
    try appendHoisted(arena, &buf, code);
    return buf.toOwnedSlice(arena);
}

/// `fragments.appendHoistingDirectives` in the hook's error set: append the
/// author's code below the prelude, with its leading `enable` / `requires` /
/// module-scope `diagnostic` lifted above everything the prelude declares.
///
/// CONTRIBUTING pitfall 104's pass half. Every declaration the prelude writes
/// sits above the author's first line, so a directive left where it was written
/// is a directive below a declaration — which WGSL refuses, naming a line in
/// the prelude about a directive the author DID write.
///
/// `TooManyDirectives` (past `MAX_DIRECTIVES` leading directives in one pass)
/// refuses the lowering rather than shipping a module with the rest left below
/// the prelude. It is an unlocated `lowering_hook_failed`, and deliberately not
/// worth more: WGSL has three directive keywords and two extensions, so the cap
/// is 64 of something nobody writes twice.
fn appendHoisted(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    code: []const u8,
) Lowering.LoweringError!void {
    fragments.appendHoistingDirectives(arena, buf, code) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooManyDirectives => return error.HookFailed,
    };
}

/// Build the post-processing shader: a prelude of pngine? / samp? / `postTex`
/// (bindings 0,1,2… contiguous in that order) / `PASS_SCALE`? + the
/// fullscreen-triangle vertex shader + the extracted `post()` function (port of
/// `pass_sugar.emitPostPass`).
///
/// `code` is the pass's WHOLE `:code`, and it is here for its directives alone:
/// `post_fn` is a slice cut from below them, so without lifting them in, a pass
/// that enables an extension and uses it in `post()` compiles its main module
/// and fails its post one.
///
/// `scale` is `null` unless the pass authored `:scale` AND its `post()` names
/// `PASS_SCALE` (probed by the caller, like `has_uniform`/`has_samp`): this
/// prelude is root text, so a const the module never reads would be a W0001 on
/// every scaled pass with a post() — the same reason `buildPrelude` gates the
/// main module's copy on `:scale` being authored at all.
fn buildPostShader(arena: Allocator, has_uniform: bool, has_samp: bool, scale: ?f64, tex_scalar: []const u8, post_fn: []const u8, code: []const u8) Lowering.LoweringError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    if (has_uniform) {
        try buf.appendSlice(arena,
            \\struct PngineInputs { time: f32, width: f32, height: f32, aspect: f32 }
            \\@group(0) @binding(0) var<uniform> pngine: PngineInputs;
            \\
        );
    }
    if (has_samp) {
        const binding: u32 = if (has_uniform) 1 else 0;
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "@group(0) @binding({d}) var samp: sampler;\n", .{binding}));
    }
    const tex_binding: u32 = (if (has_uniform) @as(u32, 1) else 0) + (if (has_samp) @as(u32, 1) else 0);
    try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "@group(0) @binding({d}) var postTex: texture_2d<{s}>;\n", .{ tex_binding, tex_scalar }));
    // `PASS_SCALE`, on the same terms as the main prelude's (`buildPrelude`):
    // how a scaled pass's post() finds its own texel grid, `pngine.width` /
    // `height` still meaning the canvas. A const, not a binding — the value is
    // a compile-time fraction, and smuggling it through one would make post()
    // implicitly depend on a texture or buffer it never reads.
    if (scale) |sc| try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "const PASS_SCALE: f32 = {d};\n", .{sc}));
    try buf.appendSlice(arena, FULLSCREEN_VS);
    try buf.appendSlice(arena, post_fn);
    fragments.prependDirectivesOf(arena, &buf, code) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooManyDirectives => return error.HookFailed,
    };
    return buf.toOwnedSlice(arena);
}

/// Extract `@fragment fn post(...) { … }` from user WGSL. Returns a slice into
/// `code` (port of `pass_sugar.extractPostFunction`).
///
/// The attribute, the `fn` keyword and the name are read through `wgsl_scan`'s
/// own `skipTrivia` / `matchAt` / `findFnName`, so this agrees entry point for
/// entry point with the scan that already decided this pass is a fragment pass.
/// It used to be a hand-rolled substring walk that skipped no trivia at all: a
/// `post()` the author had commented OUT still built a second pipeline, out of
/// disabled text, and that pass — not the main one — is what drew to the canvas
/// (§408, the sibling of §407's three feature reads).
/// Complexity: O(code.len).
fn extractPostFunction(code: []const u8) ?[]const u8 {
    std.debug.assert(code.len < std.math.maxInt(u32)); // pre: `wgsl_scan` indexes with u32
    const len: u32 = @intCast(code.len);
    var i: u32 = 0;
    // Every branch advances `i` by at least one, so `code.len` iterations suffice.
    for (0..code.len + 1) |_| {
        if (i >= len) break;
        const after_trivia = wgsl_scan.skipTrivia(code, i);
        if (after_trivia != i) {
            i = after_trivia;
            continue;
        }
        if (!wgsl_scan.matchAt(code, i, "@fragment")) {
            i += 1;
            continue;
        }
        const after_attr = i + @as(u32, "@fragment".len);
        const name = wgsl_scan.findFnName(code, after_attr) orelse {
            i = after_attr;
            continue;
        };
        if (!std.mem.eql(u8, name, "post")) {
            i = after_attr;
            continue;
        }
        return postBody(code, i);
    } else unreachable;
    return null;
}

/// The `@fragment fn post(…) { … }` beginning at `start`, sliced through the
/// brace that closes its body, or null when the braces never balance.
///
/// Trivia is skipped here too: a `{` or `}` inside a comment is prose, and
/// counting it either cuts the body short or swallows what follows it.
fn postBody(code: []const u8, start: u32) ?[]const u8 {
    std.debug.assert(start < code.len); // pre: `start` is the `@` of `@fragment`
    std.debug.assert(code[start] == '@');
    const len: u32 = @intCast(code.len);
    var depth: i32 = 0;
    var k = start;
    // Every branch advances `k` by at least one, so `code.len` iterations suffice.
    for (0..code.len + 1) |_| {
        k = wgsl_scan.skipTrivia(code, k);
        if (k >= len) break;
        if (code[k] == '{') depth += 1;
        if (code[k] == '}') {
            depth -= 1;
            if (depth <= 0) {
                // post: a balanced body, or a stray `}` ahead of the first `{`.
                return if (depth == 0) code[start .. k + 1] else null;
            }
        }
        k += 1;
    } else unreachable;
    return null;
}

// ---------------------------------------------------------------------------
// child-form readers (the container reads its (pass …) children through the
// whole-document view; `LoweringInput.{symbol,string}` only read the container's
// own form_idx — mirror their author / default coercion, per the SJON template).
// ---------------------------------------------------------------------------

fn childSymbol(arena: Allocator, view: EffectiveView, form_idx: Ast.NodeIndex, key: []const u8) Lowering.LoweringError!?[]const u8 {
    const s = Reader.initFromView(view).symbol(form_idx, key) orelse return null;
    return try arena.dupe(u8, s);
}

fn childString(arena: Allocator, view: EffectiveView, form_idx: Ast.NodeIndex, key: []const u8) Lowering.LoweringError!?[]const u8 {
    // `Reader.string` is author-only; the lowered keys it reads here (`:code`) carry
    // no schema `:default`, so there is no default-string branch to preserve.
    const s = Reader.initFromView(view).string(form_idx, key) orelse return null;
    return try arena.dupe(u8, s);
}

/// Read a vector-of-strings child key (`:file ["a.wasm" …]`) into a slice of file
/// paths. Returns null when the key is absent. A non-string element is a
/// hook error (the schema's `data-file-list` shape — a vector of `string` — should
/// already guarantee well-formedness; a non-vector reads as absent, since the shape
/// forbids it before lowering).
fn childStringVector(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    view: EffectiveView,
    form_idx: Ast.NodeIndex,
    key: []const u8,
) Lowering.LoweringError!?[]const []const u8 {
    const elems = Reader.initFromView(view).vectorNodes(form_idx, key) orelse return null;
    const paths = try arena.alloc([]const u8, elems.len);
    for (elems, 0..) |e, i| {
        if (view.tree.tagOf(e) != .string) return out.failAt(
            arena,
            view.tree.spanOf(e),
            "`:{s}` element {d} is not a string — each entry is a path to a `.wasm` file",
            .{ key, i },
        );
        paths[i] = try arena.dupe(u8, view.tree.stringText(e));
    }
    return paths;
}

/// Read `(init … :workgroups [x y z])` as a 1..3 grid, missing dimensions 1.
///
/// `LoweringInput.numberEval` reads a SCALAR key; D11 made `:workgroups` a
/// vector, so each element is evaluated the way `numberEval` evaluates a scalar
/// — literal fast path, otherwise `Expr.eval` against the host lowering env, so
/// `[(ceil (/ NUM 64))]` resolves at lowering time exactly as it did when the
/// key was a bare count.
///
/// A bad element is blamed AT THAT ELEMENT, not at the whole `:workgroups`
/// value: the vector is the reason there can be more than one, so the squiggle
/// has to say which. Returns null when the key is absent.
fn workgroupsVector(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    input: *const Lowering.LoweringInput,
    name: []const u8,
) Lowering.LoweringError!?[3]u32 {
    const elems = Reader.initFromView(input.view).vectorNodes(input.form_idx, "workgroups") orelse return null;
    std.debug.assert(elems.len >= 1 and elems.len <= 3); // schema: dispatch-size is 1..3
    var wg: [3]u32 = .{ 1, 1, 1 };
    for (elems, 0..) |e, i| {
        const n: ?f64 = switch (input.view.tree.tagOf(e)) {
            .number, .number_i64, .number_u64 => input.view.tree.numberOf(e),
            else => blk: {
                var r = sjon.Expr.eval(input.arena, input.view.tree, e, input.env, input.schema.*) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => break :blk null,
                };
                defer r.deinit();
                break :blk switch (r.value) {
                    .number => |v| v,
                    else => null,
                };
            },
        };
        // The same rule as every count slot (02 R7, `values.narrowF64`): a
        // non-negative integer, float noise forgiven — a fraction, a negative
        // and an over-u32 value are refused here with the span on the element.
        const ok = n != null and n.? >= 0 and n.? <= @as(f64, @floatFromInt(std.math.maxInt(u32))) and @abs(n.? - @round(n.?)) <= 1e-9 * @max(1.0, @abs(n.?));
        if (!ok) return out.failAt(
            arena,
            input.view.tree.spanOf(e),
            "init `{s}`: `:workgroups` element {d} did not evaluate to a workgroup count — each element is a literal, a `(define …)` constant, or a bounded expression over them, and it has to be a non-negative integer",
            .{ name, i },
        );
        wg[i] = @intFromFloat(@round(n.?));
    }
    return wg;
}

/// The span of `key`'s VALUE in `form_idx`, for a diagnostic that blames one
/// slot rather than the whole form. Null when the key has no source node — an
/// absent key, or one whose value came from a schema `:default` — in which
/// case the caller falls back to `fail`'s form-head span.
fn keySpan(view: EffectiveView, form_idx: Ast.NodeIndex, key: []const u8) ?Ast.Span {
    for (view.tree.formHeader(form_idx).children) |c| {
        if (view.tree.tagOf(c) != .kvpair) continue;
        const kv = view.tree.kvpairHeader(c);
        if (std.mem.eql(u8, kv.key, key)) return view.tree.spanOf(kv.value);
    }
    return null;
}

/// `out.failAt` on `key`'s value span, degrading to `out.fail` (the form head)
/// when the slot has no source node to point at.
fn failSlot(
    arena: Allocator,
    out: *Lowering.LoweringOutput,
    view: EffectiveView,
    form_idx: Ast.NodeIndex,
    key: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) Lowering.LoweringError {
    if (keySpan(view, form_idx, key)) |span| return out.failAt(arena, span, fmt, args);
    return out.fail(arena, fmt, args);
}

/// Read a boolean child key (e.g. `:feedback true`), honoring author value and
/// materialized default. Returns null when the key is absent (the caller defaults it).
fn childBoolean(view: EffectiveView, form_idx: Ast.NodeIndex, key: []const u8) Lowering.LoweringError!?bool {
    return Reader.initFromView(view).boolean(form_idx, key);
}

/// `pngine/init-v1` — `(init :name N :buffer B :module S :workgroups W)` lowers
/// to a one-shot compute init: a compute pipeline + a bind group wiring the
/// target storage buffer at binding 0 + a compute pass dispatched `W` workgroups.
///
/// The compute pass is named `N` (the init's own name) so a frame's
/// `:init [N]` resolves to it; the pipeline/bind-group get derived names. This
/// mirrors `emitter/init.zig`'s synthesis: createComputePipeline (auto layout) +
/// createBindGroup (layout = the synthetic pipeline) + a one-shot compute pass.
pub fn initV1(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    const name = (try input.symbol("name")) orelse
        return out.fail(arena, "`(init …)` has no `:name`", .{});
    const buffer = (try input.symbol("buffer")) orelse
        return out.fail(arena, "init `{s}` has no `:buffer` to initialize", .{name});
    // Unreachable through the schema (`:module` is required) — an "internal:"
    // shape, kept because a registry-less caller could reach it. It said
    // `:shader` until audit 09 C5, a spelling retired in 3.0.0.
    const shader = (try input.symbol("module")) orelse
        return out.fail(arena, "internal: init `{s}` has no `:module` to run", .{name});
    // Evaluated against the host lowering env (`Compiler.buildLoweringEnv`), so
    // `:workgroups [(ceil (/ NUM 64))]` works at lowering time — the same rule
    // the emitter applies to the `(dispatch :workgroups …)` this lowers to (§52).
    // A plain literal element takes the fast path.
    //
    // The failure authors actually hit is an element that does not evaluate (an
    // unbound name raises `UnknownBinding`, a non-numeric result folds the same
    // way); `workgroupsVector` blames that element, with its own span. The
    // `orelse` below is the other mistake — the key absent entirely — and says
    // so differently, because it IS different.
    const workgroups = (try workgroupsVector(arena, out, input, name)) orelse
        return out.fail(arena, "init `{s}` has no `:workgroups`", .{name});

    const pipe_name = try std.fmt.allocPrint(arena, "{s}-init-pipe", .{name});
    const bg_name = try std.fmt.allocPrint(arena, "{s}-init-bg", .{name});
    const src = input.form_idx;

    // (compute-pipeline :name <N>-init-pipe :layout auto (compute :module S))
    // No `:entry` on the stage: an init module names its own compute entry, and
    // the emitter infers the module's sole one (WebGPU's own rule for an absent
    // GPUProgrammableStage.entryPoint) rather than this hook guessing a name.
    {
        const stage_kvs = try arena.alloc(EmittedKvpair, 1);
        stage_kvs[0] = .{ .key = "module", .value = .{ .symbol = shader } };
        const stage = try arena.alloc(EmittedForm, 1);
        stage[0] = .{ .head = "compute", .kvpairs = stage_kvs, .source_form_idx = src };

        const kvs = try arena.alloc(EmittedKvpair, 2);
        kvs[0] = .{ .key = "name", .value = .{ .symbol = pipe_name } };
        kvs[1] = .{ .key = "layout", .value = .{ .symbol = "auto" } };
        try out.append(arena, .{
            .head = "compute-pipeline",
            .kvpairs = kvs,
            .children = try formChildren(arena, stage),
            .source_form_idx = src,
        });
    }

    // (bind-group :name <N>-init-bg :layout <N>-init-pipe :group 0
    //   (entry :binding 0 :buffer B))
    {
        const be_kvs = try arena.alloc(EmittedKvpair, 2);
        be_kvs[0] = .{ .key = "binding", .value = .{ .number = 0 } };
        be_kvs[1] = .{ .key = "buffer", .value = .{ .symbol = buffer } };
        const be_children = try arena.alloc(EmittedForm, 1);
        be_children[0] = .{ .head = "entry", .kvpairs = be_kvs, .source_form_idx = src };

        const kvs = try arena.alloc(EmittedKvpair, 3);
        kvs[0] = .{ .key = "name", .value = .{ .symbol = bg_name } };
        kvs[1] = .{ .key = "layout", .value = .{ .symbol = pipe_name } };
        kvs[2] = .{ .key = "group", .value = .{ .number = 0 } };
        try out.append(arena, .{
            .head = "bind-group",
            .kvpairs = kvs,
            .children = try formChildren(arena, be_children),
            .source_form_idx = src,
        });
    }

    // (compute-pass :name <N> :pipeline <N>-init-pipe :bind-groups [<N>-init-bg]
    //   (dispatch :workgroups [W]))
    {
        const bg_vec = try arena.alloc(EmittedValue, 1);
        bg_vec[0] = .{ .symbol = bg_name };
        const kvs = try arena.alloc(EmittedKvpair, 3);
        kvs[0] = .{ .key = "name", .value = .{ .symbol = name } };
        kvs[1] = .{ .key = "pipeline", .value = .{ .symbol = pipe_name } };
        kvs[2] = .{ .key = "bind-groups", .value = .{ .vector = bg_vec } };
        const wg_vec = try arena.alloc(EmittedValue, 3);
        for (workgroups, 0..) |n, i| wg_vec[i] = .{ .number = @floatFromInt(n) };
        const dispatch_child = try arena.dupe(EmittedForm, &.{.{
            .head = "dispatch",
            .kvpairs = try arena.dupe(EmittedKvpair, &.{.{ .key = "workgroups", .value = .{ .vector = wg_vec } }}),
            .source_form_idx = src,
        }});
        try out.append(arena, .{
            .head = "compute-pass",
            .kvpairs = kvs,
            .children = try formChildren(arena, dispatch_child),
            .source_form_idx = src,
        });
    }
}

/// The three PNGine hooks as registerable values — the supported external
/// surface (ask P6). A caller-owned `Lowering.LoweringRegistry` takes these
/// values by name and never spells an id; the ids live here, once, beside the
/// lowering fns they carry, and `buildRegistry` registers these same values.
///
/// `pub` in this module beyond these three constants and `buildRegistry` is
/// **internal and unsupported** (the lowering fns, the frame helpers, the
/// emitted-form builders): they are visible because Zig exposes a module's
/// `pub` decls, not because a host may depend on their names or shapes.
pub const pass_v1: Lowering.LoweringHook = .{ .id = "pngine/pass-v1", .lower = passV1 };
pub const init_v1: Lowering.LoweringHook = .{ .id = "pngine/init-v1", .lower = initV1 };
pub const draw_v1: Lowering.LoweringHook = .{ .id = "pngine/draw-v1", .lower = draw_graph.drawV1 };

// The ids are contract keys: each must appear in the embedded schema (the
// manifest is what binds a form to the id) and no two may collide. Both facts
// are static, so they are checked at compile time — a rename that outruns the
// manifest, or a copy-pasted id, fails the build rather than a test run.
comptime {
    // Three substring searches over the 83 KB manifest, plus the pairwise
    // id scan, blow past the default 1000-branch comptime quota.
    @setEvalBranchQuota(1_000_000);
    const manifest = @embedFile("pngine_schema");
    const all = [_]Lowering.LoweringHook{ pass_v1, init_v1, draw_v1 };
    for (all, 0..) |hook, i| {
        if (std.mem.indexOf(u8, manifest, hook.id) == null) {
            @compileError("pngine hook id is not in the embedded schema: " ++ hook.id);
        }
        for (all[0..i]) |prev| {
            if (std.mem.eql(u8, prev.id, hook.id)) {
                @compileError("duplicate pngine hook id: " ++ hook.id);
            }
        }
    }
}

/// Build a registry with every PNGine hook registered — the three constants
/// above, exactly. The compiler passes `&registry` as
/// `HostOptions.lowering_registry`. Caller owns the registry and must
/// `deinit(gpa)` it; the compiler never frees a caller-supplied one.
pub fn buildRegistry(gpa: Allocator) Lowering.RegisterError!Lowering.LoweringRegistry {
    var registry: Lowering.LoweringRegistry = .{};
    errdefer registry.deinit(gpa);
    try registry.register(gpa, pass_v1);
    try registry.register(gpa, init_v1);
    // `(draw-graph …)` lives in its own file: it shares no state with the two
    // above and is the size of both together. Its value still comes from here,
    // so the registry has one source of truth per id.
    try registry.register(gpa, draw_v1);
    return registry;
}

// ============================================================================
// Tests
// ============================================================================

/// A complete document that may use `(init …)`: every name the form and the
/// frame reference is declared, so a refusal test over it can only fail at the
/// hook, never at an undeclared cross-reference. Kept in one place so the
/// lowering and the refusal tests cannot drift into testing different sources.
fn completeInitDoc(gpa: Allocator) ![:0]u8 {
    const manifest = @embedFile("pngine_schema");
    return std.fmt.allocPrintSentinel(gpa, "{s}\n" ++
        \\(shader-module :name initShader :code "@compute @workgroup_size(64) fn main() {{}}")
        \\(buffer :name parts :size 1024 :usage [vertex storage] :pool 2)
        \\(init :name spawn :buffer parts :module initShader :workgroups [16])
        \\(frame :name main :init [spawn] :perform [spawn])
    , .{manifest}, 0);
}
