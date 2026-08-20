//! PNGine lowering hooks — `pngine/init-v1` (real) and `pngine/pass-v1` (Phase 2).
//!
//! `(init …)` and `(pass …)` sugar become host-owned form-lowering hooks: SJON calls
//! them between default-materialization and final validation, and the canonical
//! forms they emit flow through the same emitter path as hand-written resources.
//! This retires `emitter/init.zig` (~325 LOC) and (Phase 2) `emitter/pass_sugar.zig`.
//!
//! `EmittedForm.children` is a positional `[]const EmittedValue` (SJON 2026-06-07),
//! so a hook can synthesize child forms like `(entry :binding 0 :buffer b)`. The render
//! pipeline hooks below emit the canonical `(vertex :module … :entry …)(fragment
//! :module … :entry … (target :format …))` form — the same shape a hand-authored
//! pipeline uses, so the emitter's single descriptor path serves both (§86 retired
//! the legacy flat `flat-module`/… kvpair shape and its parallel emitter branch).
//! `compute-pipeline` carries a `(compute …)` stage, the same GPUProgrammableStage
//! the other two are (docs/plans/overhaul/02 R2).

const std = @import("std");
const sjon = @import("sjon");
const wgsl_scan = @import("wgsl_scan");

const Lowering = sjon.Lowering;
const EffectiveView = sjon.EffectiveView.EffectiveView;
const values = @import("values.zig");
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
const PassRef = struct {
    name: []const u8,
    tex: []const u8,
    pool_size: u8,
};

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
    arena: std.mem.Allocator,
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

    var frame_steps: std.ArrayList(EmittedValue) = .empty;
    var prior: std.ArrayList(PassRef) = .empty;
    for (passes.items, 0..) |pass, i| {
        const is_last = (i == passes.items.len - 1);
        const ref = try lowerOnePass(arena, out, container, view, pass, is_last, prior.items, &frame_steps);
        try prior.append(arena, ref);
    }

    // Auto-frame (legacy emits one when no explicit #frame exists; pass-graph
    // files never author a frame).
    try appendForm(arena, out, container, "frame", &.{
        .{ .key = "name", .value = .{ .symbol = "main" } },
        .{ .key = "perform", .value = .{ .vector = try frame_steps.toOwnedSlice(arena) } },
    }, &.{});
}

/// Expand a single `(pass …)` child into its canonical resource forms, appending
/// the render-pass name(s) to `frame_steps` for the auto-frame's `:perform` and
/// returning a `PassRef` so the passes after it can sample its output. `is_last`
/// marks the final pass — the "main" pass (also true for a pass literally named
/// `main`), which renders to the canvas and may carry a `post()` stage.
/// `prior_passes` are the already-lowered passes this one may depend on.
fn lowerOnePass(
    arena: std.mem.Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    view: EffectiveView,
    pass: Ast.NodeIndex,
    is_last: bool,
    prior_passes: []const PassRef,
    frame_steps: *std.ArrayList(EmittedValue),
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
    const is_main = is_last or std.mem.eql(u8, name, "main");
    if (scan.has_compute)
        return lowerComputePass(arena, out, container, name, code, scan, is_main, frame_steps);
    return lowerFragmentPass(arena, out, container, view, pass, name, code, is_main, prior_passes, frame_steps);
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
};

/// Detect a fragment pass's features from its user WGSL. Detection runs on the
/// post-stripped code so post()'s refs (samp, textureSample) don't leak into the
/// main pass's prelude/bindings.
///
/// The sampler is bound iff the WGSL names it (`samp` / `textureSample`). It
/// used to be forced by a dependency or `:feedback true` as well — but the bind
/// group is laid out by the pipeline's `:layout auto`, and an auto layout holds
/// only the bindings the entry point statically uses: a pass that read its
/// feedback texture with `textureLoad` got a `samp` entry in the bind group
/// that the layout did not have, and WebGPU refused the group (wgpu: "Number
/// of bindings in bind group descriptor (2) does not match … (1)"; lint W0003
/// was the only compile-time sign). Overhaul/09 §8's doc-fence gate found it.
fn detectPassFeatures(
    view: EffectiveView,
    pass: Ast.NodeIndex,
    code: []const u8,
    is_main: bool,
) Lowering.LoweringError!PassFeatures {
    std.debug.assert(code.len > 0); // pre: pass has WGSL (scanner already found an entry)
    const feedback = (try childBoolean(view, pass, "feedback")) orelse false;
    const post_fn: ?[]const u8 = if (is_main) extractPostFunction(code) else null;
    const main_code = if (post_fn) |pf| code[0 .. @intFromPtr(pf.ptr) - @intFromPtr(code.ptr)] else code;
    const needs_sampler = std.mem.indexOf(u8, main_code, "textureSample") != null or
        std.mem.indexOf(u8, main_code, "samp") != null;
    return .{
        .feedback = feedback,
        .post_fn = post_fn,
        .has_post = post_fn != null,
        .needs_uniform = std.mem.indexOf(u8, main_code, "pngine") != null,
        .needs_pointer = std.mem.indexOf(u8, main_code, "pointer") != null,
        .needs_sampler = needs_sampler,
    };
}

/// Data storage buffers (`:file ["a.wasm" …]`) → D0, D1, …, emitted between the
/// pointer buffer and the output texture (legacy `loadDataWasm` create position).
/// The emitter reads each WASM file, sizes the buffer, and fills it; the prelude
/// declares `D{i}: array<f32>` and the bind group binds them (after deps/feedback).
fn emitPassDataBuffers(
    arena: std.mem.Allocator,
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
    arena: std.mem.Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    view: EffectiveView,
    pass: Ast.NodeIndex,
    name: []const u8,
    code: []const u8,
    is_main: bool,
    prior_passes: []const PassRef,
    frame_steps: *std.ArrayList(EmittedValue),
) Lowering.LoweringError!PassRef {
    std.debug.assert(name.len > 0); // pre: named pass
    std.debug.assert(code.len > 0); // pre: pass has WGSL

    const feat = try detectPassFeatures(view, pass, code, is_main);
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
    try appendOutputTexture(arena, out, container, tex, tex_pool);

    // Main shader carries the full user code (fs + any post()); the prelude gains
    // `samp` when post() shares the module (WGSL validates all functions at module
    // creation) — even though the main pass never binds it — plus a `texture_2d`
    // binding per dependency and a `prev_<name>` binding when feedback is on.
    const full_code = try buildPrelude(arena, feat.needs_uniform, feat.needs_pointer, feat.needs_sampler, feat.has_post, prior_passes, feat.feedback, name, data_bufs.items, code);
    try appendShader(arena, out, container, shader, full_code);

    // Pipeline target format depends only on `is_main and !has_post` (legacy
    // `target_fmt`); the *render target* additionally routes a feedback pass to its
    // own ping-pong pool, so the two conditions are kept separate.
    const is_canvas_format = is_main and !feat.has_post;
    const target_fmt: ?[]const u8 = if (is_canvas_format) null else "rgba8unorm";
    try appendPipeline(arena, out, container, pipe, shader, "fs", target_fmt);
    try appendBindGroup(arena, out, container, bg, pipe, ubuf, feat.needs_uniform, pbuf, feat.needs_pointer, feat.needs_sampler, feat.has_post, prior_passes, feat.feedback, tex, data_bufs.items);

    // Feedback → render to the pooled output texture (emitter detects the pool →
    // begin_render_pass_pool); a plain main pass → canvas; otherwise → the pass's
    // own (intermediate / dependency-source) texture.
    const renders_to_canvas = is_canvas_format and !feat.feedback;
    const target_view = if (renders_to_canvas) "context-current-texture" else tex;
    try appendRenderPass(arena, out, container, name, pipe, bg, target_view);
    // Write the runtime uniform(s) before the pass runs (legacy emitAutoFrame order).
    try appendUniformWriteSteps(arena, out, container, name, feat.needs_uniform, ubuf, feat.needs_pointer, pbuf, frame_steps);
    try frame_steps.append(arena, .{ .symbol = name });

    if (feat.post_fn) |pf|
        try lowerPostPass(arena, out, container, name, pf, tex, feat.needs_uniform, ubuf, frame_steps);

    return .{ .name = name, .tex = tex, .pool_size = tex_pool };
}

/// Emit the post-processing pass: a separate shader (prelude of pngine? / samp? /
/// `postTex`, then the extracted `post()` fn), a render pipeline (fragment entry
/// `post`, canvas target), a bind group ([uniform?, sampler?, intermediate texture]),
/// and a render pass → canvas. Appended after the main pass so the lowered create
/// order matches legacy `emitPostPass`. `intermediate_tex` is the main pass's
/// output texture (post()'s `postTex`).
fn lowerPostPass(
    arena: std.mem.Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    pass_name: []const u8,
    post_fn: []const u8,
    intermediate_tex: []const u8,
    main_needs_uniform: bool,
    ubuf: []const u8,
    frame_steps: *std.ArrayList(EmittedValue),
) Lowering.LoweringError!void {
    const post_needs_samp = std.mem.indexOf(u8, post_fn, "samp") != null or
        std.mem.indexOf(u8, post_fn, "textureSample") != null;
    // post() uses the main pass's uniform buffer; require it to actually exist so
    // the bind-group cross-ref never dangles (true for the corpus — post() and the
    // main fs() both reference `pngine`).
    const post_uniform = main_needs_uniform and std.mem.indexOf(u8, post_fn, "pngine") != null;

    const shader = try std.fmt.allocPrint(arena, "{s}__post_shader", .{pass_name});
    const pipe = try std.fmt.allocPrint(arena, "{s}__post_pipe", .{pass_name});
    const bg = try std.fmt.allocPrint(arena, "{s}__post_bg", .{pass_name});
    const pass = try std.fmt.allocPrint(arena, "{s}__post", .{pass_name});

    const post_code = try buildPostShader(arena, post_uniform, post_needs_samp, post_fn);
    try appendShader(arena, out, container, shader, post_code);

    // Renders to canvas → fragment entry `post`, no explicit target format.
    try appendPipeline(arena, out, container, pipe, shader, "post", null);

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
    arena: std.mem.Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    name: []const u8,
    code: []const u8,
    scan: wgsl_scan.ScanResult,
    is_main: bool,
    frame_steps: *std.ArrayList(EmittedValue),
) Lowering.LoweringError!PassRef {
    std.debug.assert(scan.has_compute and !scan.has_fragment);

    const needs_uniform = std.mem.indexOf(u8, code, "pngine") != null;
    const needs_pointer = std.mem.indexOf(u8, code, "pointer") != null;

    const ubuf = try std.fmt.allocPrint(arena, "{s}__ubuf", .{name});
    const pbuf = try std.fmt.allocPrint(arena, "{s}__pbuf", .{name});
    const tex = try std.fmt.allocPrint(arena, "{s}__tex", .{name});
    const shader = try std.fmt.allocPrint(arena, "{s}__shader", .{name});

    // Resources in legacy compute order: ubuf?, pbuf?, screen texture, shader.
    if (needs_uniform) try appendBuffer(arena, out, container, ubuf, 16);
    if (needs_pointer) try appendBuffer(arena, out, container, pbuf, 48);
    try appendScreenTexture(arena, out, container, tex, 1);

    const full_code = try buildComputePrelude(arena, needs_uniform, needs_pointer, code);
    try appendShader(arena, out, container, shader, full_code);

    // Write the runtime uniform(s) once before the compute pass(es) run (legacy
    // emitAutoFrame writes per pass_info, before its sub-passes execute).
    try appendUniformWriteSteps(arena, out, container, name, needs_uniform, ubuf, needs_pointer, pbuf, frame_steps);

    // One pipeline + compute pass per @compute entry point. The first entry's bind
    // group (same layout for all entries of a module) is reused by the rest.
    var bg: []const u8 = "";
    var ep: u32 = 0;
    for (scan.slice()) |entry| {
        if (entry.type != .compute) continue;
        const pipe = try std.fmt.allocPrint(arena, "{s}__pipe{d}", .{ name, ep });
        try appendComputePipelineEntry(arena, out, container, pipe, shader, entry.name);
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

    return .{ .name = name, .tex = tex, .pool_size = 1 };
}

/// Emit the auto-blit for a compute main (port of `pass_sugar.emitBlitPass`): a
/// blit shader (`BLIT_WGSL`), a canvas render pipeline (vertex `vs`, fragment `fs`),
/// a bind group [`screen` texture, shared sampler], and a render pass → canvas.
/// Appended after the compute pass(es) so the lowered create order matches legacy.
fn lowerBlitPass(
    arena: std.mem.Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    pass_name: []const u8,
    screen_tex: []const u8,
    frame_steps: *std.ArrayList(EmittedValue),
) Lowering.LoweringError!void {
    const shader = try std.fmt.allocPrint(arena, "{s}__blit_shader", .{pass_name});
    const pipe = try std.fmt.allocPrint(arena, "{s}__blit_pipe", .{pass_name});
    const bg = try std.fmt.allocPrint(arena, "{s}__blit_bg", .{pass_name});
    const blit = try std.fmt.allocPrint(arena, "{s}__blit", .{pass_name});

    try appendShader(arena, out, container, shader, BLIT_WGSL);
    try appendPipeline(arena, out, container, pipe, shader, "fs", null);

    const entries = try arena.alloc(EmittedForm, 2);
    entries[0] = try beTexture(arena, container, 0, screen_tex);
    entries[1] = try beSampler(arena, container, 1, PASS_SAMPLER);
    try appendForm(arena, out, container, "bind-group", &.{
        .{ .key = "name", .value = .{ .symbol = bg } },
        .{ .key = "layout", .value = .{ .symbol = pipe } },
        .{ .key = "group", .value = .{ .number = 0 } },
    }, entries);

    try appendRenderPass(arena, out, container, blit, pipe, bg, "context-current-texture");
    try frame_steps.append(arena, .{ .symbol = blit });
}

/// Build the compute-pass WGSL prelude (port of the `is_fragment=false` branch of
/// `pass_sugar.buildPrelude`): the pngine / pointer uniform structs, then the
/// `screen` storage-texture binding, then the user code. No fullscreen vertex
/// shader (compute does not draw).
fn buildComputePrelude(
    arena: std.mem.Allocator,
    needs_uniform: bool,
    needs_pointer: bool,
    code: []const u8,
) Lowering.LoweringError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    const binding: u32 = try appendUniformStructs(arena, &buf, needs_uniform, needs_pointer);
    try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "@group(0) @binding({d}) var screen: texture_storage_2d<rgba8unorm, write>;\n", .{binding}));
    try buf.appendSlice(arena, code);
    return buf.toOwnedSlice(arena);
}

/// A compute pipeline with an explicit entry point (compute mains use named
/// entries like `main_image`, not the default `main`).
fn appendComputePipelineEntry(
    arena: std.mem.Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    name: []const u8,
    module: []const u8,
    entry: []const u8,
) Lowering.LoweringError!void {
    try appendForm(arena, out, container, "compute-pipeline", &.{
        .{ .key = "name", .value = .{ .symbol = name } },
        // GPUPipelineDescriptorBase.layout is required, and a lowered pass always
        // derives it from the WGSL. A kvpair is emittable where the old
        // positional `(layout auto)` was not — which is why it was never stated
        // here, and why nothing enforced it (spec/09 C.2).
        .{ .key = "layout", .value = .{ .symbol = "auto" } },
    }, &.{try stageForm(arena, container, "compute", module, entry, null)});
}

/// The compute bind group (port of `buildComputeBindGroupDescriptor`): uniform?,
/// pointer?, then the `screen` storage texture (bound as a texture-view).
fn appendComputeBindGroup(
    arena: std.mem.Allocator,
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
    arena: std.mem.Allocator,
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
fn formChildren(
    arena: std.mem.Allocator,
    forms: []const EmittedForm,
) Lowering.LoweringError![]const EmittedValue {
    const vals = try arena.alloc(EmittedValue, forms.len);
    for (forms, 0..) |f, i| vals[i] = .{ .form = f };
    return vals;
}

/// Append a form with the given kvpairs + child forms, stamping the container as
/// provenance. The slices are copied into the arena.
fn appendForm(
    arena: std.mem.Allocator,
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
    arena: std.mem.Allocator,
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
    arena: std.mem.Allocator,
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
    arena: std.mem.Allocator,
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
    arena: std.mem.Allocator,
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
    arena: std.mem.Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    name: []const u8,
    pool: u8,
    usage: []const EmittedValue,
) Lowering.LoweringError!void {
    var kvs: [5]EmittedKvpair = undefined;
    var n: usize = 0;
    kvs[n] = .{ .key = "name", .value = .{ .symbol = name } };
    n += 1;
    kvs[n] = .{ .key = "size", .value = .{ .symbol = "canvas" } };
    n += 1;
    kvs[n] = .{ .key = "format", .value = .{ .symbol = "rgba8unorm" } };
    n += 1;
    kvs[n] = .{ .key = "usage", .value = .{ .vector = usage } };
    n += 1;
    if (pool > 1) {
        kvs[n] = .{ .key = "pool", .value = .{ .number = @floatFromInt(pool) } };
        n += 1;
    }
    try appendForm(arena, out, container, "texture", kvs[0..n], &.{});
}

/// A fragment pass's output texture (texture_binding|render_attachment), mirroring
/// legacy `emitCanvasTexture(is_fragment=true)`. Feedback passes the `:pool 2` pair.
fn appendOutputTexture(
    arena: std.mem.Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    name: []const u8,
    pool: u8,
) Lowering.LoweringError!void {
    const usage = try arena.dupe(EmittedValue, &.{ .{ .symbol = "texture-binding" }, .{ .symbol = "render-attachment" } });
    try appendTextureForm(arena, out, container, name, pool, usage);
}

/// A compute main's `screen` output texture (texture_binding|storage_binding — the
/// shader stores into it), mirroring `emitCanvasTexture(is_fragment=false)`.
fn appendScreenTexture(
    arena: std.mem.Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    name: []const u8,
    pool: u8,
) Lowering.LoweringError!void {
    const usage = try arena.dupe(EmittedValue, &.{ .{ .symbol = "texture-binding" }, .{ .symbol = "storage-binding" } });
    try appendTextureForm(arena, out, container, name, pool, usage);
}

/// A pipeline stage: `(vertex :module M :entry E)` or
/// `(fragment :module M :entry E (target :format F))`. `target_format` is read
/// on the fragment stage only, and null there means the canvas format.
fn stageForm(
    arena: std.mem.Allocator,
    container: Ast.NodeIndex,
    head: []const u8,
    module: []const u8,
    entry: []const u8,
    target_format: ?[]const u8,
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
            .head = "target",
            .kvpairs = try arena.dupe(EmittedKvpair, &.{.{
                .key = "format",
                .value = .{ .symbol = target_format orelse "preferred-canvas-format" },
            }}),
            .source_form_idx = container,
        };
        try children.append(arena, .{ .form = target });
    }
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
/// + `(fragment :module M :entry FE (target :format FMT))`. This is the
/// same shape a hand-authored pipeline uses, so the emitter's single authored
/// descriptor path builds it (§86 replaced the legacy flat `:flat-module` keys; the
/// runtime is unchanged — gpu.js normalizes the old `targetFormat` string and the
/// `targets` array to the identical GPURenderPipeline).
fn appendPipeline(
    arena: std.mem.Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    name: []const u8,
    module: []const u8,
    fragment_entry: []const u8,
    target_format: ?[]const u8,
) Lowering.LoweringError!void {
    const vertex = try stageForm(arena, container, "vertex", module, "vs", null);
    const fragment = try stageForm(arena, container, "fragment", module, fragment_entry, target_format);
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
    arena: std.mem.Allocator,
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
    arena: std.mem.Allocator,
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
fn beEntry(arena: std.mem.Allocator, container: Ast.NodeIndex, binding: f64, buffer: []const u8) Lowering.LoweringError!EmittedForm {
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
fn beSampler(arena: std.mem.Allocator, container: Ast.NodeIndex, binding: f64, sampler: []const u8) Lowering.LoweringError!EmittedForm {
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
fn beTexture(arena: std.mem.Allocator, container: Ast.NodeIndex, binding: f64, texture: []const u8) Lowering.LoweringError!EmittedForm {
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
fn bePingPongTexture(arena: std.mem.Allocator, container: Ast.NodeIndex, binding: f64, texture: []const u8, ping_pong: f64) Lowering.LoweringError!EmittedForm {
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
    arena: std.mem.Allocator,
    out: *Lowering.LoweringOutput,
    container: Ast.NodeIndex,
    name: []const u8,
    code: []const u8,
) Lowering.LoweringError!void {
    try appendForm(arena, out, container, "shader-module", &.{
        .{ .key = "name", .value = .{ .symbol = name } },
        .{ .key = "code", .value = .{ .string = code } },
    }, &.{});
}

/// A render pass (clear [0,0,0,1] → store) drawing the fullscreen triangle
/// (3 vertices) to `view` — `context-current-texture` for canvas passes or a
/// declared texture name for the post-processing intermediate target. Named
/// `name` so the auto-frame's :perform resolves it.
fn appendRenderPass(
    arena: std.mem.Allocator,
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
    arena: std.mem.Allocator,
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
fn buildPrelude(
    arena: std.mem.Allocator,
    needs_uniform: bool,
    needs_pointer: bool,
    needs_sampler: bool,
    has_post: bool,
    prior_passes: []const PassRef,
    feedback: bool,
    name: []const u8,
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
    // Dependency textures (one per prior pass, bound by that pass's name so the
    // user WGSL reads it as `textureSample(<dep>, samp, uv)`).
    for (prior_passes) |dep| {
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "@group(0) @binding({d}) var {s}: texture_2d<f32>;\n", .{ binding, dep.name }));
        binding += 1;
    }
    // Feedback texture (`prev_<name>` — the previous frame's own output).
    if (feedback) {
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "@group(0) @binding({d}) var prev_{s}: texture_2d<f32>;\n", .{ binding, name }));
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
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "@group(0) @binding({d}) var postTex: texture_2d<f32>;\n", .{binding}));
        binding += 1;
    }
    try buf.appendSlice(arena, code);
    return buf.toOwnedSlice(arena);
}

/// Build the post-processing shader: a prelude of pngine? / samp? / `postTex`
/// (bindings 0,1,2… contiguous in that order) + the fullscreen-triangle vertex
/// shader + the extracted `post()` function (port of `pass_sugar.emitPostPass`).
fn buildPostShader(arena: std.mem.Allocator, has_uniform: bool, has_samp: bool, post_fn: []const u8) Lowering.LoweringError![]u8 {
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
    try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "@group(0) @binding({d}) var postTex: texture_2d<f32>;\n", .{tex_binding}));
    try buf.appendSlice(arena, FULLSCREEN_VS);
    try buf.appendSlice(arena, post_fn);
    return buf.toOwnedSlice(arena);
}

/// Extract `@fragment fn post(...) { … }` from user WGSL via brace-counting
/// (port of `pass_sugar.extractPostFunction`). Returns a slice into `code`.
fn extractPostFunction(code: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 10 < code.len) {
        if (!std.mem.startsWith(u8, code[i..], "@fragment")) {
            i += 1;
            continue;
        }
        var j = i + "@fragment".len;
        while (j < code.len and (code[j] == ' ' or code[j] == '\n' or code[j] == '\r' or code[j] == '\t')) j += 1;
        if (j + 2 >= code.len or !std.mem.startsWith(u8, code[j..], "fn")) {
            i += 1;
            continue;
        }
        j += 2;
        while (j < code.len and (code[j] == ' ' or code[j] == '\n' or code[j] == '\r' or code[j] == '\t')) j += 1;
        if (j + 4 >= code.len or !std.mem.startsWith(u8, code[j..], "post")) {
            i += 1;
            continue;
        }
        const after_name = j + 4;
        if (after_name < code.len and code[after_name] != '(' and code[after_name] != ' ') {
            i += 1;
            continue;
        }
        var depth: i32 = 0;
        var k = i;
        while (k < code.len) : (k += 1) {
            if (code[k] == '{') depth += 1;
            if (code[k] == '}') {
                depth -= 1;
                if (depth == 0) return code[i .. k + 1];
            }
        }
        return null;
    }
    return null;
}

// ---------------------------------------------------------------------------
// child-form readers (the container reads its (pass …) children through the
// whole-document view; `LoweringInput.{symbol,string}` only read the container's
// own form_idx — mirror their author / default coercion, per the SJON template).
// ---------------------------------------------------------------------------

fn childSymbol(arena: std.mem.Allocator, view: EffectiveView, form_idx: Ast.NodeIndex, key: []const u8) Lowering.LoweringError!?[]const u8 {
    const s = Reader.initFromView(view).symbol(form_idx, key) orelse return null;
    return try arena.dupe(u8, s);
}

fn childString(arena: std.mem.Allocator, view: EffectiveView, form_idx: Ast.NodeIndex, key: []const u8) Lowering.LoweringError!?[]const u8 {
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
    arena: std.mem.Allocator,
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
    arena: std.mem.Allocator,
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
    arena: std.mem.Allocator,
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
    arena: std.mem.Allocator,
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

/// Build a registry with both PNGine hooks registered. The compiler passes
/// `&registry` as `HostOptions.lowering_registry`. Caller owns the registry and
/// must `deinit(gpa)` it.
pub fn buildRegistry(gpa: std.mem.Allocator) Lowering.RegisterError!Lowering.LoweringRegistry {
    var registry: Lowering.LoweringRegistry = .{};
    errdefer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "pngine/pass-v1", .lower = passV1 });
    try registry.register(gpa, .{ .id = "pngine/init-v1", .lower = initV1 });
    return registry;
}

// ============================================================================
// Tests
// ============================================================================
