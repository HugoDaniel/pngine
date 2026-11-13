//! JS Codegen: Emit WebGPU JavaScript directly from PNGB bytecode.
//!
//! Instead of serializing to pNGf binary and interpreting at runtime,
//! this module runs the dispatcher with MockGPU to capture all GPU calls,
//! then emits the calls directly as JavaScript statements.
//!
//! This eliminates: PNG parsing, base64 encoding, decompression,
//! and the entire command dispatcher switch statement from the HTML output.
//!
//! ## Limitations
//!
//! - Same as flat.zig: no ping-pong, no WASM-in-WASM, single frame
//! - Only write_time_uniform as dynamic data source
//!
//! ## Invariants
//!
//! - Output is valid JavaScript (ES module)
//! - All WGSL strings are properly escaped for template literals

const std = @import("std");
const flate = std.compress.flate;
const Allocator = std.mem.Allocator;
const pngine = @import("pngine");
const format = pngine.format;
const descriptors = pngine.types.descriptors;
const opcodes = pngine.opcodes;
const mock_gpu = pngine.mock_gpu;
const MockGPU = mock_gpu.MockGPU;
const Call = mock_gpu.Call;
const CallType = mock_gpu.CallType;
const Dispatcher = pngine.Dispatcher;
const frag = @import("js_fragments.zig");
const call_split = @import("call_split.zig");
const desc = @import("js_descriptors.zig");
const js_emit = @import("js_emit.zig");

// The primitive appenders are used on nearly every line of this file, so they
// keep their bare names; the descriptor emitters are called a dozen times and
// read better with their module in front of them (`desc.emitTextureDesc`).
const appendInt = js_emit.appendInt;
const appendCompactFloat = js_emit.appendCompactFloat;
const appendEscapedWgsl = js_emit.appendEscapedWgsl;
const base64Append = js_emit.base64Append;

/// Texture-id sentinels, the same two the executor's command-buffer form uses:
/// the swapchain's current texture, and "this attachment is absent".
const CANVAS_TEXTURE_ID: u16 = 0xFFFE;
const NO_TEXTURE_ID: u16 = 0xFFFF;

pub const CodegenResult = struct {
    html: []u8,

    pub fn deinit(self: *CodegenResult, gpa: Allocator) void {
        gpa.free(self.html);
    }
};

pub const CodegenError = error{
    InvalidBytecode,
    ExecutionFailed,
    /// The bytecode uses a command the `--html` single-file codegen cannot emit
    /// (MRT, copies, query sets, render bundles, image bitmap, viewport/scissor,
    /// occlusion/timestamp). We refuse loudly rather than emit a silently-broken
    /// player — `diag.unsupported` names the offending command. The default
    /// viewer runtime plays every command; re-export without `--html`.
    UnsupportedByHtml,
    /// A descriptor blob nests deeper than `js_emit.MAX_JSON_DEPTH`. Real
    /// descriptors are five levels at most; this is a hand-crafted payload, and
    /// refusing it is what keeps the emitter's walk on a fixed-size stack.
    DescriptorTooDeep,
    OutOfMemory,
};

/// Out-param carrying the first `--html`-unsupported command back to the caller
/// so it can name it in the refusal message (mirrors flat.zig's Diag for mini,
/// and is distinct from the compiler's diagnostics sink for the reason given
/// there).
pub const Diag = struct {
    unsupported: ?CallType = null,
    /// Set instead of (well, alongside) `unsupported` when the command itself is
    /// emittable and its POSITION is the problem — mirrors flat.zig's field of
    /// the same name, so render.zig's refusal printer reads the same both ways.
    unsupported_feature: ?[]const u8 = null,
    /// Which captured call, for a message that can be acted on. The call log has
    /// no source spans, so the index is the only locator there is.
    unsupported_index: ?usize = null,
};

/// Which resources the frame calls actually reach — the dead-code-elimination
/// analysis, kept apart from emission because it is pure inspection of the
/// MockGPU call log and answers exactly one question: may this creation call be
/// dropped from the generated JS?
///
/// Pass order is load-bearing and is documented at each pass below; several
/// consumers have a LOWER call index than the resource they keep alive, so a
/// single in-order scan reads the wrong sets empty.
const Usage = struct {
    buffers: std.AutoHashMapUnmanaged(u16, void) = .{},
    textures: std.AutoHashMapUnmanaged(u16, void) = .{},
    samplers: std.AutoHashMapUnmanaged(u16, void) = .{},
    shaders: std.AutoHashMapUnmanaged(u16, void) = .{},
    pipelines: std.AutoHashMapUnmanaged(u16, void) = .{},
    bind_groups: std.AutoHashMapUnmanaged(u16, void) = .{},
    wasm_modules: std.AutoHashMapUnmanaged(u16, void) = .{},
    views: std.AutoHashMapUnmanaged(u16, void) = .{},
    pipeline_layouts: std.AutoHashMapUnmanaged(u16, void) = .{},
    bgls: std.AutoHashMapUnmanaged(u16, void) = .{},

    fn deinit(self: *Usage, gpa: Allocator) void {
        inline for (@typeInfo(Usage).@"struct".fields) |field| {
            @field(self, field.name).deinit(gpa);
        }
    }

    /// Build the live sets. `calls[0..split_idx]` are resource creations,
    /// `calls[split_idx..]` are the per-frame calls that consume them.
    fn compute(
        gpa: Allocator,
        calls: []const Call,
        split_idx: usize,
        module: *const format.Module,
    ) Allocator.Error!Usage {
        std.debug.assert(split_idx <= calls.len);
        var u: Usage = .{};
        errdefer u.deinit(gpa);

        try u.markFrameConsumers(gpa, calls[split_idx..], module);
        try u.markPipelineAndGroupDeps(gpa, calls[0..split_idx], module);
        try u.markViewSources(gpa, calls[0..split_idx]);
        try u.markLayoutBGLs(gpa, calls[0..split_idx], module);
        try u.markBindGroupBGLs(gpa, calls[0..split_idx]);
        try u.markWasmProducers(gpa, calls[0..split_idx]);
        return u;
    }

    /// Pass 1 — what the frame itself touches, plus the three side-channel
    /// buffers the frame writes through opcodes MockGPU discards.
    fn markFrameConsumers(
        u: *Usage,
        gpa: Allocator,
        frame_calls: []const Call,
        module: *const format.Module,
    ) Allocator.Error!void {
        for (frame_calls) |call| {
            switch (call.call_type) {
                .set_pipeline => try u.pipelines.put(gpa, call.params.set_pipeline.pipeline_id, {}),
                .set_bind_group => try u.bind_groups.put(gpa, call.params.set_bind_group.group_id, {}),
                .set_vertex_buffer => try u.buffers.put(gpa, call.params.set_vertex_buffer.buffer_id, {}),
                .set_index_buffer => try u.buffers.put(gpa, call.params.set_index_buffer.buffer_id, {}),
                .begin_render_pass => {
                    const p = call.params.begin_render_pass;
                    if (p.color_texture_id != CANVAS_TEXTURE_ID) try u.textures.put(gpa, p.color_texture_id, {});
                    if (p.depth_texture_id != NO_TEXTURE_ID) try u.textures.put(gpa, p.depth_texture_id, {});
                },
                .write_buffer => try u.buffers.put(gpa, call.params.write_buffer.buffer_id, {}),
                else => {},
            }
        }
        // Also mark uniform buffers from bytecode scan (write_time_uniform)
        const all_tu = scanAllTimeUniforms(module.bytecode);
        for (all_tu.items[0..all_tu.count]) |tu| {
            try u.buffers.put(gpa, tu.buffer_id, {});
        }
        // Also mark pointer buffers from bytecode scan (write_pointer_uniform)
        const all_pu_scan = scanAllPointerUniforms(module.bytecode);
        for (all_pu_scan.items[0..all_pu_scan.count]) |pu| {
            try u.buffers.put(gpa, pu.buffer_id, {});
        }
        // Also mark dark-uniform buffers from the uniform table, so the
        // per-frame `dk` write never references an eliminated buffer var.
        const all_du = scanDarkUniforms(module);
        for (all_du.items[0..all_du.count]) |du| {
            try u.buffers.put(gpa, du.buffer_id, {});
        }
    }

    /// Pass 2 — a live pipeline keeps its shaders and its explicit layout; a
    /// live bind group keeps every resource it binds.
    fn markPipelineAndGroupDeps(
        u: *Usage,
        gpa: Allocator,
        init_calls: []const Call,
        module: *const format.Module,
    ) Allocator.Error!void {
        for (init_calls) |call| {
            switch (call.call_type) {
                .create_render_pipeline => {
                    const p = call.params.create_render_pipeline;
                    if (u.pipelines.contains(p.pipeline_id)) {
                        const data = module.data.get(@enumFromInt(p.descriptor_data_id));
                        try desc.extractRenderPipelineShaders(gpa, data, &u.shaders);
                        if (desc.extractRenderPipelineLayoutId(gpa, data)) |lid|
                            try u.pipeline_layouts.put(gpa, lid, {});
                    }
                },
                .create_compute_pipeline => {
                    const p = call.params.create_compute_pipeline;
                    if (u.pipelines.contains(p.pipeline_id)) {
                        const data = module.data.get(@enumFromInt(p.descriptor_data_id));
                        try desc.extractComputePipelineShader(gpa, data, &u.shaders);
                        if (desc.extractComputePipelineLayoutId(data)) |lid|
                            try u.pipeline_layouts.put(gpa, lid, {});
                    }
                },
                .create_bind_group => {
                    const p = call.params.create_bind_group;
                    if (u.bind_groups.contains(p.group_id)) {
                        const data = module.data.get(@enumFromInt(p.entry_data_id));
                        try desc.extractBindGroupResources(gpa, data, &u.buffers, &u.samplers, &u.textures, &u.views);
                    }
                },
                else => {},
            }
        }
    }

    /// Pass 2b — a used explicit (texture-view …) keeps its source texture alive.
    /// Runs AFTER pass 2 so `views` is fully populated by the bind-group scan:
    /// create_texture_view has a LOWER call index than create_bind_group (its
    /// phase runs before bind-groups), so an in-order scan would read views
    /// empty and drop the view and its texture.
    fn markViewSources(
        u: *Usage,
        gpa: Allocator,
        init_calls: []const Call,
    ) Allocator.Error!void {
        for (init_calls) |call| {
            if (call.call_type == .create_texture_view) {
                const p = call.params.create_texture_view;
                if (u.views.contains(p.view_id)) {
                    try u.textures.put(gpa, p.texture_id, {});
                }
            }
        }
    }

    /// Pass 2c — a used explicit (pipeline-layout …) keeps its composed
    /// bind-group-layouts alive. Runs AFTER Pass 2 populates pipeline_layouts —
    /// create_pipeline_layout has a LOWER call index than create_render_pipeline
    /// (its phase runs before pipelines), so an in-order scan would read
    /// pipeline_layouts empty and drop the layout + its BGLs.
    fn markLayoutBGLs(
        u: *Usage,
        gpa: Allocator,
        init_calls: []const Call,
        module: *const format.Module,
    ) Allocator.Error!void {
        for (init_calls) |call| {
            if (call.call_type == .create_pipeline_layout) {
                const p = call.params.create_pipeline_layout;
                if (u.pipeline_layouts.contains(p.layout_id)) {
                    const data = module.data.get(@enumFromInt(p.descriptor_data_id));
                    try desc.extractPipelineLayoutBGLs(gpa, data, &u.bgls);
                }
            }
        }
    }

    /// Pass 2d — a live bind group keeps the explicit (bind-group-layout …) it
    /// binds through alive. Until §339 the ONLY thing that could mark a BGL live
    /// was `markLayoutBGLs` (a pipeline-layout citing it), so a group naming a BGL
    /// directly emitted a reference to a `BGL<n>` the page never declared — and
    /// before the layout_id tag existed, the reference was to a pipeline instead
    /// and the dead BGL went unnoticed.
    fn markBindGroupBGLs(
        u: *Usage,
        gpa: Allocator,
        init_calls: []const Call,
    ) Allocator.Error!void {
        for (init_calls) |call| {
            if (call.call_type == .create_bind_group) {
                const p = call.params.create_bind_group;
                if (!opcodes.layoutIdIsBindGroupLayout(p.layout_id)) continue;
                if (u.bind_groups.contains(p.group_id)) {
                    try u.bgls.put(gpa, opcodes.layoutIdValue(p.layout_id), {});
                }
            }
        }
    }

    /// Pass 3 — a WASM module is live iff the buffer it writes into is.
    fn markWasmProducers(
        u: *Usage,
        gpa: Allocator,
        init_calls: []const Call,
    ) Allocator.Error!void {
        for (init_calls) |call| {
            if (call.call_type == .write_buffer_from_wasm) {
                const p = call.params.write_buffer_from_wasm;
                if (u.buffers.contains(p.buffer_id)) {
                    try u.wasm_modules.put(gpa, p.call_id, {});
                }
            }
        }
    }

    /// True if this creation call must be emitted. Calls with no resource of
    /// their own (draws, passes, submits) are always live.
    fn isLive(self: *const Usage, call: Call) bool {
        return switch (call.call_type) {
            .create_buffer => self.buffers.contains(call.params.create_buffer.buffer_id),
            .create_texture => self.textures.contains(call.params.create_texture.texture_id),
            .create_sampler => self.samplers.contains(call.params.create_sampler.sampler_id),
            .create_shader_module => self.shaders.contains(call.params.create_shader_module.shader_id),
            .create_render_pipeline => self.pipelines.contains(call.params.create_render_pipeline.pipeline_id),
            .create_compute_pipeline => self.pipelines.contains(call.params.create_compute_pipeline.pipeline_id),
            .create_bind_group => self.bind_groups.contains(call.params.create_bind_group.group_id),
            .create_texture_view => self.views.contains(call.params.create_texture_view.view_id),
            .create_pipeline_layout => self.pipeline_layouts.contains(call.params.create_pipeline_layout.layout_id),
            .create_bind_group_layout => self.bgls.contains(call.params.create_bind_group_layout.layout_id),
            .write_buffer => self.buffers.contains(call.params.write_buffer.buffer_id),
            .init_wasm_module => self.wasm_modules.contains(call.params.init_wasm_module.module_id),
            .call_wasm_func => self.wasm_modules.contains(call.params.call_wasm_func.module_id),
            .write_buffer_from_wasm => self.buffers.contains(call.params.write_buffer_from_wasm.buffer_id),
            else => true,
        };
    }
};

/// The runtime side-channels written at the top of every frame: the
/// time/resolution uniform, the pointer state block, the audio FFT array, and
/// the dark-mode flag.
///
/// None of them come from the MockGPU call log — the first three are written
/// through opcodes MockGPU discards and are scanned out of the raw PNGB; the
/// dark flag has no opcode at all and comes from the uniform table — so they
/// are emitted here rather than falling out of `emitCall`.
fn emitFrameUniformWrites(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    scans: struct {
        time: TimeUniformScanResult,
        pointer: PointerUniformScanResult,
        audio: AudioUniformScanResult,
        dark: DarkUniformScanResult,
    },
    width: u32,
    height: u32,
    fullscreen: bool,
) !void {
    std.debug.assert(width > 0 and height > 0);

    // In fullscreen the canvas is the source of truth for resolution, so the
    // emitted JS reads c.width/c.height live instead of baking the numbers in.
    for (scans.time.items[0..scans.time.count]) |tu| {
        // Write exactly the source's own byte count. `scene-time-inputs` is 12
        // bytes and has no aspect member; emitting the fourth float regardless
        // overran a buffer sized to it, and WebGPU rejects the whole
        // writeBuffer rather than truncating — so the SHORT source was as
        // silently dead as the long one (§438).
        const with_aspect = tu.size >= 16;
        try out.appendSlice(gpa, "d.queue.writeBuffer(b");
        try appendInt(out, gpa, tu.buffer_id);
        if (fullscreen) {
            try out.appendSlice(gpa, if (with_aspect)
                ",0,new Float32Array([t,c.width,c.height,c.width/c.height]));"
            else
                ",0,new Float32Array([t,c.width,c.height]));");
        } else {
            try out.appendSlice(gpa, ",0,new Float32Array([t,");
            try appendInt(out, gpa, width);
            try out.appendSlice(gpa, ",");
            try appendInt(out, gpa, height);
            if (with_aspect) {
                try out.appendSlice(gpa, ",");
                try appendInt(out, gpa, width);
                try out.appendSlice(gpa, "/");
                try appendInt(out, gpa, height);
            }
            try out.appendSlice(gpa, "]));");
        }
        // `pngine-frame-inputs` is those 16 bytes plus the frame counter as a
        // u32 — a second write rather than a wider Float32Array, because the
        // trailing member is an integer and a float bit pattern is not it.
        if (tu.size >= 20) {
            try out.appendSlice(gpa, "d.queue.writeBuffer(b");
            try appendInt(out, gpa, tu.buffer_id);
            try out.appendSlice(gpa, ",16,new Uint32Array([_n]));");
        }
    }

    // Deltas reset after each read, so the write and the reset must stay one unit.
    for (scans.pointer.items[0..scans.pointer.count]) |pu| {
        try out.appendSlice(gpa, "d.queue.writeBuffer(b");
        try appendInt(out, gpa, pu.buffer_id);
        try out.appendSlice(gpa, ",0,new Float32Array([px,py,pcx,pcy,pdx,pdy,pbt,ppr,pm,psx,psy,0]));pdx=0;pdy=0;psx=0;psy=0;");
    }

    // `_af` is the shared analyser array from s(); absent until audio starts.
    for (scans.audio.items[0..scans.audio.count]) |au| {
        try out.appendSlice(gpa, "if(_af)d.queue.writeBuffer(b");
        try appendInt(out, gpa, au.buffer_id);
        try out.appendSlice(gpa, ",0,_af);");
    }

    // `dk` is module-scope state from frag.dark_setup; written at the member's
    // own offset, so it composes with the 16-byte time write into one buffer.
    for (scans.dark.items[0..scans.dark.count]) |du| {
        try out.appendSlice(gpa, "d.queue.writeBuffer(b");
        try appendInt(out, gpa, du.buffer_id);
        try out.appendSlice(gpa, ",");
        try appendInt(out, gpa, du.offset);
        try out.appendSlice(gpa, ",new Float32Array([dk]));");
    }
}

/// The page-shape decisions, threaded through the assembly phases below so they
/// take one parameter instead of nine. Everything here is fixed before a single
/// byte of the page is written.
const Page = struct {
    width: u32,
    height: u32,
    /// Canvas fills the viewport (and, packed, is sized by devicePixelRatio).
    fullscreen: bool,
    /// Deflate the JS into a `fetch('#')` bootstrap instead of an inline
    /// `<script type=module>`.
    pack: bool,
    audio_wasm: ?[]const u8,
    audio_js: ?[]const u8,
    has_animation: bool,
    has_audio_data: bool,
    has_pointer: bool,
    has_dark: bool,
    /// A `pngine-frame-inputs` write needs a frame counter (`_n`) in scope.
    has_frame_counter: bool,

    /// A play prompt is shown iff there is audio to unlock: browsers refuse to
    /// start an AudioContext without a gesture.
    fn hasAudio(self: Page) bool {
        return self.audio_wasm != null or self.audio_js != null;
    }
};

/// The index one past the last resource-creation call: `calls[0..split]` build
/// the scene, `calls[split..]` are the frame.
///
/// Deliberately not an early-exit scan — a `write_buffer` carrying vertex data
/// sits between creation calls, so the split is the LAST creation, not the first
/// non-creation.
///
/// That rule is only safe while every create precedes the frame's first pass
/// command, which is why it starts by REFUSING the logs where it isn't true.
/// The pNGf writer answers the same question with the first frame call, so on a
/// log with a create after a pass the two writers failed in opposite directions
/// — flat replaying a create at 60Hz, this one hoisting the pass commands into
/// module scope so the page rendered exactly once — and neither said anything.
/// `call_split.zig` holds the shared invariant; both writers refuse on it.
pub fn findSplitIndex(calls: []const Call, diag: *Diag) CodegenError!usize {
    if (call_split.createAtOrAfterFrameStart(calls)) |i| {
        diag.unsupported = calls[i].call_type;
        diag.unsupported_index = i;
        diag.unsupported_feature = "a resource created after the frame's first pass command";
        return CodegenError.UnsupportedByHtml;
    }

    var split_idx: usize = 0;
    for (calls, 0..) |call, i| {
        if (call_split.isCreateCall(call.call_type)) split_idx = i + 1;
    }
    std.debug.assert(split_idx <= calls.len);
    std.debug.assert(split_idx <= call_split.firstFrameCall(calls));
    return split_idx;
}

/// texture_id → format string, read out of each `create_texture` descriptor.
/// Caller owns the map. A texture whose descriptor carries no format is absent
/// rather than defaulted — the consumer below distinguishes the two.
fn buildTextureFormats(
    gpa: Allocator,
    calls: []const Call,
    module: *const format.Module,
) Allocator.Error!std.AutoHashMapUnmanaged(u16, []const u8) {
    var tex_formats = std.AutoHashMapUnmanaged(u16, []const u8){};
    errdefer tex_formats.deinit(gpa);

    for (calls) |call| {
        if (call.call_type == .create_texture) {
            const p = call.params.create_texture;
            const data = module.data.get(@enumFromInt(p.descriptor_data_id));
            const fmt = desc.parseTextureFormat(data);
            if (fmt) |f| try tex_formats.put(gpa, p.texture_id, f);
        }
    }
    return tex_formats;
}

/// pipeline_id → the colour format it actually renders into, recovered by
/// replaying the frame: `begin_render_pass` names the target texture, and every
/// `set_pipeline` until the next pass inherits it.
///
/// Pipelines drawing to the canvas keep no entry — `f` (the preferred canvas
/// format, resolved at runtime) is the right answer there, and baking a concrete
/// format would break on a device that prefers the other one.
fn buildPipelineFormats(
    gpa: Allocator,
    calls: []const Call,
    split_idx: usize,
    tex_formats: *const std.AutoHashMapUnmanaged(u16, []const u8),
) Allocator.Error!std.AutoHashMapUnmanaged(u16, []const u8) {
    std.debug.assert(split_idx <= calls.len);
    var pipeline_formats = std.AutoHashMapUnmanaged(u16, []const u8){};
    errdefer pipeline_formats.deinit(gpa);

    var current_color_tex: u16 = CANVAS_TEXTURE_ID;
    for (calls[split_idx..]) |call| {
        switch (call.call_type) {
            .begin_render_pass => current_color_tex = call.params.begin_render_pass.color_texture_id,
            .set_pipeline => {
                if (current_color_tex == CANVAS_TEXTURE_ID) continue;
                if (tex_formats.get(current_color_tex)) |fmt| {
                    try pipeline_formats.put(gpa, call.params.set_pipeline.pipeline_id, fmt);
                }
            },
            else => {},
        }
    }
    return pipeline_formats;
}

/// Emit the style rules, the canvas element and the optional play prompt —
/// everything between an opening `<style>` and the JS.
///
/// Shared verbatim by both wrappers: packed mode assigns it to
/// `document.body.innerHTML`, unpacked mode writes it as literal HTML. They
/// differ only in what surrounds this, which is why it is one function — the two
/// spellings drifted apart before (see the fullscreen sizing note in generate).
fn emitCanvasMarkup(out: *std.ArrayList(u8), gpa: Allocator, page: Page) !void {
    const body_rules = if (page.fullscreen)
        "*{margin:0}body{background:#000;overflow:hidden}canvas{display:block}"
    else
        "*{margin:0}body{background:#000;overflow:hidden;display:grid;place-items:center;height:100vh}";
    try out.appendSlice(gpa, body_rules);

    if (page.hasAudio()) {
        try out.appendSlice(gpa, "#p{position:fixed;inset:0;display:grid;place-items:center;cursor:pointer;color:#fff;font:15vmin sans-serif}");
    }

    if (page.fullscreen) {
        try out.appendSlice(gpa, "</style><canvas id=c style=width:100vw;height:100vh></canvas>");
    } else {
        try out.appendSlice(gpa, "</style><canvas id=c width=");
        try appendInt(out, gpa, page.width);
        try out.appendSlice(gpa, " height=");
        try appendInt(out, gpa, page.height);
        try out.appendSlice(gpa, "></canvas>");
    }

    if (page.hasAudio()) try out.appendSlice(gpa, "<div id=p>&#9654;</div>");
}

/// Deflate the assembled JS and prepend the bootstrap that fetches the page
/// back off itself (`fetch('#')`) and evals it.
///
/// Two shapes, because audio bytes have to ride along uncompressed-by-base64:
/// without audio the bootstrap is a fixed 159 bytes and slices past itself;
/// with audio the blob is `[u32 LE js_len][JS][raw wasm]` and the bootstrap
/// carries its own offset, which makes its length self-referential — hence the
/// fixed-point loop below.
fn emitPackedBootstrap(
    html: *std.ArrayList(u8),
    gpa: Allocator,
    js_bytes: []const u8,
    audio_wasm: ?[]const u8,
) CodegenError!void {
    std.debug.assert(js_bytes.len > 0); // an empty page is a bug upstream

    const aw = audio_wasm orelse {
        // No-audio pack: simple fixed-size bootstrap
        const compressed = deflateCompress(gpa, js_bytes) catch return CodegenError.OutOfMemory;
        defer gpa.free(compressed);

        const bootstrap = "<body onload=\"fetch('#').then(t=>t.blob()).then(b=>new Response(b.slice(159).stream().pipeThrough(new DecompressionStream('deflate-raw'))).text()).then(eval)\">";
        comptime std.debug.assert(bootstrap.len == 159);

        try html.appendSlice(gpa, bootstrap);
        try html.appendSlice(gpa, compressed);
        return;
    };

    return emitAudioPackBootstrap(html, gpa, js_bytes, aw);
}

/// Emit whatever runs the frame: for an animated payload the audio setup, the
/// rAF loop and the click-to-start handler; for a static one, the frame body,
/// once.
fn emitFrameDriver(
    payload: *std.ArrayList(u8),
    gpa: Allocator,
    page: Page,
    frame_js: []const u8,
) !void {
    // Declared outside the loop so it survives between frames, and before the
    // static path too: a one-shot render IS frame 0, and the write reads `_n`
    // either way.
    if (page.has_frame_counter) try payload.appendSlice(gpa, "let _n=0;");

    if (!page.has_animation) {
        // Static: just run the frame once.
        try payload.appendSlice(gpa, frame_js);
        return;
    }

    // Audio JS: append user-provided JS code (defines s() function)
    if (page.audio_js) |ajs| {
        if (page.has_audio_data) {
            try payload.appendSlice(gpa, "let _af;");
        }
        try payload.appendSlice(gpa, ajs);
    }

    // Audio WASM setup (before frame function)
    if (page.audio_wasm) |aw| {
        if (page.pack) {
            // Pack mode: raw audio binary in deflate blob, bootstrap sets _a global
            try emitAudioSetupFromGlobal(payload, gpa);
        } else {
            try emitAudioSetup(payload, gpa, aw);
        }
    }

    // Animated: click-to-play with rAF loop, Esc reloads page
    try payload.appendSlice(gpa, frag.anim_start);
    try payload.appendSlice(gpa, frame_js);
    if (page.has_frame_counter) try payload.appendSlice(gpa, "_n++;");
    try payload.appendSlice(gpa, frag.anim_end);
    try payload.appendSlice(gpa, frag.esc_handler);
    if (page.audio_js != null) {
        // Use FFT variant if bytecode has write_audio_data opcodes (captures return value)
        if (page.has_audio_data) {
            try payload.appendSlice(gpa, frag.click_handler_audiojs_fft_pre);
        } else {
            try payload.appendSlice(gpa, frag.click_handler_audiojs_pre);
        }
        try payload.appendSlice(gpa, frag.click_handler_audiojs_post);
    } else if (page.audio_wasm != null) {
        try payload.appendSlice(gpa, frag.click_handler_audio_pre);
        try payload.appendSlice(gpa, frag.click_audio_start);
        try payload.appendSlice(gpa, frag.click_handler_audio_post);
    } else {
        try payload.appendSlice(gpa, frag.click_handler);
    }
}

/// The audio-carrying variant of the packed bootstrap. The blob is
/// `[u32 LE js_len][JS][raw wasm]`, and because the bootstrap has to name the
/// byte offset at which the blob starts — which is its own length — its length
/// is self-referential. Two formatting passes reach the fixed point; a third
/// covers the case where the digit count changed between them.
fn emitAudioPackBootstrap(
    html: *std.ArrayList(u8),
    gpa: Allocator,
    js_bytes: []const u8,
    aw: []const u8,
) CodegenError!void {
    // Audio pack: deflate blob = [u32 LE JS length][JS text][raw audio WASM]
    // Bootstrap decompresses as ArrayBuffer, splits at length prefix,
    // sets _a global for audio bytes, eval's JS text.
    const js_len: u32 = @intCast(js_bytes.len);
    const blob_size = 4 + js_bytes.len + aw.len;
    const blob = gpa.alloc(u8, blob_size) catch return CodegenError.OutOfMemory;
    defer gpa.free(blob);

    std.mem.writeInt(u32, blob[0..4], js_len, .little);
    @memcpy(blob[4..][0..js_bytes.len], js_bytes);
    @memcpy(blob[4 + js_bytes.len ..][0..aw.len], aw);

    const compressed = deflateCompress(gpa, blob) catch return CodegenError.OutOfMemory;
    defer gpa.free(compressed);

    const audio_bootstrap_fmt =
        "<body onload=\"fetch('#').then(t=>t.arrayBuffer()).then(b=>{{let h={d},j={d};" ++
        "new Response(new Blob([new Uint8Array(b,h,j)]).stream().pipeThrough(" ++
        "new DecompressionStream('deflate-raw'))).arrayBuffer().then(d=>{{" ++
        "let n=new DataView(d).getUint32(0,!0);" ++
        "_a=new Uint8Array(d,4+n);" ++
        "eval(new TextDecoder().decode(new Uint8Array(d,4,n)))" ++
        "}})}})\">";

    var hdr_buf: [512]u8 = undefined;
    const compressed_len: u32 = @intCast(compressed.len);

    // Estimate header with h=0, then correct with actual length
    const est = std.fmt.bufPrint(&hdr_buf, audio_bootstrap_fmt, .{
        @as(u32, 0), compressed_len,
    }) catch return CodegenError.OutOfMemory;

    const h1: u32 = @intCast(est.len);
    const pass2 = std.fmt.bufPrint(&hdr_buf, audio_bootstrap_fmt, .{
        h1, compressed_len,
    }) catch return CodegenError.OutOfMemory;

    // Stabilize if digit count changed
    var stable: []const u8 = pass2;
    if (pass2.len != h1) {
        stable = std.fmt.bufPrint(&hdr_buf, audio_bootstrap_fmt, .{
            @as(u32, @intCast(pass2.len)), compressed_len,
        }) catch return CodegenError.OutOfMemory;
    }

    // Post: the offset baked into the bootstrap must be its own length, or the
    // page slices the compressed blob at the wrong byte and decompresses noise.
    std.debug.assert(stable.len == h1 or stable.len == pass2.len);

    try html.appendSlice(gpa, stable);
    try html.appendSlice(gpa, compressed);
}

/// Assemble the module-scope JS: DOM setup (packed only), WebGPU init, the
/// resource-creation section, pointer wiring, and either the animation loop or a
/// single static frame.
///
/// Returns the buffer; the caller owns it and decides how to wrap it.
fn buildPayload(
    gpa: Allocator,
    page: Page,
    module: *const format.Module,
    init_js: []const u8,
    frame_js: []const u8,
) CodegenError!std.ArrayList(u8) {
    std.debug.assert(page.width > 0 and page.height > 0);

    var payload = std.ArrayList(u8).empty;
    errdefer payload.deinit(gpa);

    if (page.pack) {
        // Pack mode: wrap in async IIFE for top-level await support (eval can't do modules)
        try payload.appendSlice(gpa, "(async()=>{");
    }

    // Before anything else, including this run's own DOM: stop the previous run.
    // In packed mode the `innerHTML=` below detaches the canvas an abandoned
    // loop is still rendering into, so the order is load-bearing rather than
    // tidy — and it must precede requestAdapter either way, or two devices are
    // live at once with the first unreachable.
    try payload.appendSlice(gpa, frag.stop_prev);

    if (page.pack) {
        // DOM setup is part of the JS (no HTML boilerplate around it)
        try payload.appendSlice(gpa, "document.body.innerHTML='<style>");
        try emitCanvasMarkup(&payload, gpa, page);
        try payload.appendSlice(gpa, "';");
    }

    // A fullscreen canvas is stretched to the viewport by CSS, so its drawing
    // buffer has to be sized in JS or it stays at the HTML default 300×150 and
    // the page renders upscaled. This used to sit inside the `pack` branch
    // above, which meant --unpack — the mode whose whole purpose is to be a
    // readable equivalent of the packed page — rendered at a different
    // resolution than the page it mirrors (§336).
    if (page.fullscreen) try payload.appendSlice(gpa, frag.fs_setup);

    // WebGPU init. Authored device limits (Arc-3 §5.3b) → emit
    // `let L={requiredLimits:{…}}` and request them via the _limits init variant
    // (`requestDevice(L)`). Limit names are interned as EXACT WebGPU camelCase =
    // valid JS identifier keys. Legacy modules (no limits form) take the original
    // fragment → byte-identical output.
    if (module.limits.count() > 0) {
        try payload.appendSlice(gpa, "let L={requiredLimits:{");
        for (module.limits.entries.items, 0..) |entry, i| {
            if (i > 0) try payload.append(gpa, ',');
            try payload.appendSlice(gpa, module.strings.get(@enumFromInt(entry.name_string_id)));
            try payload.append(gpa, ':');
            try appendInt(&payload, gpa, entry.value);
        }
        try payload.appendSlice(gpa, "}};");
        try payload.appendSlice(gpa, frag.webgpu_init_limits);
    } else {
        try payload.appendSlice(gpa, frag.webgpu_init);
    }

    // An authored `(canvas :alpha-mode premultiplied)` re-configures the context.
    // Both init fragments configure with the WebGPU default (opaque) and no
    // alphaMode key, which is why this is a second call rather than a third and
    // fourth fragment variant: an opaque page — every page until one asks
    // otherwise — pays zero bytes.
    //
    // Before spec/09 step D this path had NO alphaMode at all and no way to
    // express one, so it composited opaque while gpu.js/mini.js/core.js all
    // composited premultiplied. The same document rendered two ways depending on
    // which runtime opened it, and the flag the author set was ignored here.
    if (module.header.flags.canvas_alpha_premultiplied) {
        try payload.appendSlice(gpa, frag.canvas_premultiplied);
    }

    // Init section
    try payload.appendSlice(gpa, init_js);

    // Pointer setup: state vars + pointer/keyboard/wheel listeners, at MODULE
    // scope so they run exactly once (canvas `c` exists after webgpu_init). This
    // is deliberately outside F(): §223 — inside the loop the state resets every
    // frame and the wheel addEventListener leaks a handler per frame. The
    // per-frame writeBuffer that consumes this state stays in frame_js.
    if (page.has_pointer) {
        try payload.appendSlice(gpa, frag.pointer);
    }

    // Dark-mode flag state, same once-only reasoning as the pointer block.
    // Needs only `window`, so its position relative to webgpu_init is free.
    if (page.has_dark) {
        try payload.appendSlice(gpa, frag.dark_setup);
    }

    try emitFrameDriver(&payload, gpa, page, frame_js);

    // Teardown, published last because it closes over the device and the loop
    // handle. Static pages get it too: they have no loop to cancel, but a re-run
    // still strands a GPUDevice and everything reachable from it.
    try payload.appendSlice(gpa, frag.stop_reg);
    if (page.has_animation) try payload.appendSlice(gpa, frag.device_lost);

    // Close async IIFE if packing
    if (page.pack) {
        try payload.appendSlice(gpa, "})()");
    }

    return payload;
}

/// The read-only facts about a payload that emission needs: where the scene
/// stops and the frame starts, which resources survive dead-code elimination,
/// which pipeline renders into which format, and the three runtime side-channels
/// MockGPU never sees.
///
/// One phase, so `generate` reads as analyse → emit → assemble rather than as
/// twelve interleaved locals.
const Analysis = struct {
    /// calls[0..split_idx] build the scene; calls[split_idx..] are the frame.
    split_idx: usize,
    usage: Usage,
    pipeline_formats: std.AutoHashMapUnmanaged(u16, []const u8),
    time: TimeUniformScanResult,
    pointer: PointerUniformScanResult,
    audio: AudioUniformScanResult,
    dark: DarkUniformScanResult,

    fn of(gpa: Allocator, calls: []const Call, module: *const format.Module, diag: *Diag) CodegenError!Analysis {
        const split_idx = try findSplitIndex(calls, diag);

        // The texture→format map exists only to resolve pipeline targets, and
        // the strings it holds are static (descriptors.toWebGPU), so it can be
        // freed the moment pipeline_formats is built.
        var tex_formats = try buildTextureFormats(gpa, calls, module);
        defer tex_formats.deinit(gpa);

        // Bound separately rather than inline in the literal: `usage` owns six
        // maps by the time `pipeline_formats` is built, and a struct literal
        // has nowhere to hang the errdefer that frees them.
        var usage = try Usage.compute(gpa, calls, split_idx, module);
        errdefer usage.deinit(gpa);

        return .{
            .split_idx = split_idx,
            .usage = usage,
            .pipeline_formats = try buildPipelineFormats(gpa, calls, split_idx, &tex_formats),
            // The three side channels are written by opcodes MockGPU discards,
            // so they are read from the raw PNGB rather than from the call log.
            .time = scanAllTimeUniforms(module.bytecode),
            .pointer = scanAllPointerUniforms(module.bytecode),
            .audio = scanAllAudioUniforms(module.bytecode),
            // Unlike the three above this is a uniform-table scan, not a
            // bytecode scan: no opcode carries the dark flag.
            .dark = scanDarkUniforms(module),
        };
    }

    fn deinit(self: *Analysis, gpa: Allocator) void {
        self.usage.deinit(gpa);
        self.pipeline_formats.deinit(gpa);
    }
};

/// Emit the resource creations, skipping the ones nothing in the frame reaches.
fn emitInitSection(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    calls: []const Call,
    analysis: *const Analysis,
    module: *const format.Module,
    diag: *Diag,
) !void {
    std.debug.assert(analysis.split_idx <= calls.len);
    var pass_idx: u16 = 0;
    var submit_start: u16 = 0;
    for (calls[0..analysis.split_idx]) |call| {
        if (!analysis.usage.isLive(call)) continue;
        try emitCall(gpa, out, call, module, &pass_idx, &submit_start, &analysis.pipeline_formats, diag);
    }
}

/// Emit the body of the frame function: the runtime side-channel writes first,
/// then every per-frame call.
///
/// Pointer state + listeners (frag.pointer) are NOT emitted here — they go once
/// at module scope (see buildPayload). This buffer is spliced inside the F()
/// loop, so state decls would reset every frame and the wheel addEventListener
/// would stack a fresh handler per frame (§223). Only the per-frame pointer
/// writeBuffer, which reads px,py,… and resets pdx/pdy/…, belongs here.
fn emitFrameSection(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    calls: []const Call,
    analysis: *const Analysis,
    module: *const format.Module,
    width: u32,
    height: u32,
    fullscreen: bool,
    diag: *Diag,
) !void {
    std.debug.assert(analysis.split_idx <= calls.len);
    std.debug.assert(width > 0 and height > 0);

    try emitFrameUniformWrites(gpa, out, .{
        .time = analysis.time,
        .pointer = analysis.pointer,
        .audio = analysis.audio,
        .dark = analysis.dark,
    }, width, height, fullscreen);

    var pass_idx: u16 = 0;
    var submit_start: u16 = 0;
    for (calls[analysis.split_idx..]) |call| {
        try emitCall(gpa, out, call, module, &pass_idx, &submit_start, &analysis.pipeline_formats, diag);
    }
}

/// Wrap the assembled JS in its delivery vehicle: a deflate blob behind a
/// self-fetching bootstrap (packed), or literal HTML with an inline module
/// script (unpacked). Returns the page; the caller owns it.
fn wrapHtml(gpa: Allocator, page: Page, payload: []const u8) CodegenError![]u8 {
    var html = std.ArrayList(u8).empty;
    errdefer html.deinit(gpa);

    if (page.pack) {
        try emitPackedBootstrap(&html, gpa, payload, page.audio_wasm);
    } else {
        try html.appendSlice(gpa, "<!DOCTYPE html><meta charset=utf-8><style>");
        try emitCanvasMarkup(&html, gpa, page);
        try html.appendSlice(gpa, "<script type=module>\n");
        try html.appendSlice(gpa, payload);
        try html.appendSlice(gpa, "</script>\n");
    }

    std.debug.assert(html.items.len > 0);
    return html.toOwnedSlice(gpa) catch CodegenError.OutOfMemory;
}

/// Generate self-contained HTML with inline WebGPU JavaScript.
/// Shaders are emitted as raw WGSL template literals; see the note below for
/// why inner per-shader compression is deliberately absent.
pub fn generate(
    gpa: Allocator,
    bytecode: []const u8,
    width: u32,
    height: u32,
    audio_wasm: ?[]const u8,
    audio_js: ?[]const u8,
    fullscreen: bool,
    pack: bool,
    diag: *Diag,
) CodegenError!CodegenResult {
    // Pre-conditions
    std.debug.assert(width > 0 and height > 0);

    if (bytecode.len < format.HEADER_SIZE or !std.mem.eql(u8, bytecode[0..4], format.MAGIC)) {
        return CodegenError.InvalidBytecode;
    }

    var module = format.deserialize(gpa, bytecode) catch {
        return CodegenError.InvalidBytecode;
    };
    defer module.deinit(gpa);

    // Execute bytecode with MockGPU to capture call sequence
    var gpu: MockGPU = .empty;
    defer gpu.deinit(gpa);

    var dispatcher = Dispatcher(MockGPU).init(gpa, &gpu, &module);
    defer dispatcher.deinit();
    dispatcher.execute_all(gpa) catch {
        return CodegenError.ExecutionFailed;
    };

    const calls = gpu.get_calls();

    var analysis = try Analysis.of(gpa, calls, &module, diag);
    defer analysis.deinit(gpa);

    var js = std.ArrayList(u8).empty;
    defer js.deinit(gpa);
    try emitInitSection(gpa, &js, calls, &analysis, &module, diag);

    var frame_js = std.ArrayList(u8).empty;
    defer frame_js.deinit(gpa);
    try emitFrameSection(gpa, &frame_js, calls, &analysis, &module, width, height, fullscreen, diag);

    const page = Page{
        .width = width,
        .height = height,
        .fullscreen = fullscreen,
        .pack = pack,
        .audio_wasm = audio_wasm,
        .audio_js = audio_js,
        .has_animation = analysis.time.count > 0,
        .has_audio_data = analysis.audio.count > 0,
        .has_pointer = analysis.pointer.count > 0,
        .has_dark = analysis.dark.count > 0,
        .has_frame_counter = blk: {
            for (analysis.time.items[0..analysis.time.count]) |tu| {
                if (tu.size >= 20) break :blk true;
            }
            break :blk false;
        },
    };

    var payload = try buildPayload(gpa, page, &module, js.items, frame_js.items);
    defer payload.deinit(gpa);

    const html = try wrapHtml(gpa, page, payload.items);
    return CodegenResult{ .html = html };
}

/// Emit a single MockGPU call as JavaScript.
/// Emit one `beginRenderPass`: the encoder, the colour attachment (canvas or
/// texture), its clear value, and the optional depth attachment.
///
/// The only arm of `emitCall` long enough to obscure the dispatch table around
/// it — the rest are a handful of lines each and read better inline.
fn emitBeginRenderPass(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    call: Call,
    pass_idx: *u16,
) !void {
    const p = call.params.begin_render_pass;
    const pi = pass_idx.*;
    pass_idx.* += 1;
    const load_str: []const u8 = if (p.load_op == 1) "clear" else "load";
    const store_str: []const u8 = if (p.store_op == 0) "store" else "discard";

    // Encoder + pass with indexed names: e0/r0, e1/r1, ...
    try out.appendSlice(gpa, "let e");
    try appendInt(out, gpa, pi);
    try out.appendSlice(gpa, "=d.createCommandEncoder(),r");
    try appendInt(out, gpa, pi);
    try out.appendSlice(gpa, "=e");
    try appendInt(out, gpa, pi);
    try out.appendSlice(gpa, ".beginRenderPass({colorAttachments:[{view:");

    // Color target: the canvas sentinel resolves to the swapchain view
    if (p.color_texture_id == CANVAS_TEXTURE_ID) {
        try out.appendSlice(gpa, "x.getCurrentTexture().createView()");
    } else {
        // The texture's default view, made once beside the texture itself. Only
        // the canvas attachment above is per-frame, and only because the swap
        // chain hands out a different GPUTexture every frame.
        try out.appendSlice(gpa, "T");
        try appendInt(out, gpa, p.color_texture_id);
        try out.appendSlice(gpa, "v");
    }

    try out.appendSlice(gpa, ",loadOp:'");
    try out.appendSlice(gpa, load_str);
    try out.appendSlice(gpa, "',storeOp:'");
    try out.appendSlice(gpa, store_str);
    // The clear color arrives as four f32 bit patterns and goes out as the same
    // four floats. It used to be four u8s printed as `n/255`, which is why a
    // --html page could not reproduce a clear the browser runtime rendered.
    try out.appendSlice(gpa, "',clearValue:[");
    var cv_buf: [96]u8 = undefined;
    const cv_str = std.fmt.bufPrint(&cv_buf, "{d},{d},{d},{d}", .{
        @as(f32, @bitCast(p.clear_r_bits)),
        @as(f32, @bitCast(p.clear_g_bits)),
        @as(f32, @bitCast(p.clear_b_bits)),
        @as(f32, @bitCast(p.clear_a_bits)),
    }) catch "0,0,0,0";
    try out.appendSlice(gpa, cv_str);
    try out.appendSlice(gpa, "]}]");

    // Depth stencil attachment (the sentinel means none)
    if (p.depth_texture_id != NO_TEXTURE_ID) {
        try out.appendSlice(gpa, ",depthStencilAttachment:{view:T");
        try appendInt(out, gpa, p.depth_texture_id);
        try out.appendSlice(gpa, "v,depthClearValue:1,depthLoadOp:'clear',depthStoreOp:'store'}");
    }

    try out.appendSlice(gpa, "});");
}

/// Which family a MockGPU call belongs to. Exhaustive on purpose: a new
/// CallType is a compile error here, and the four emitters below assume they
/// only ever see their own tags.
const Family = enum { resource, pass, queue, wasm, unsupported };

fn familyOf(t: CallType) Family {
    return switch (t) {
        .create_shader_module,
        .create_buffer,
        .create_render_pipeline,
        .create_compute_pipeline,
        .create_bind_group,
        .create_texture,
        .create_sampler,
        .create_texture_view,
        .create_bind_group_layout,
        .create_pipeline_layout,
        => .resource,

        .begin_render_pass,
        .begin_compute_pass,
        .set_pipeline,
        .set_bind_group,
        .set_vertex_buffer,
        .set_index_buffer,
        .set_blend_constant,
        .draw,
        .draw_indexed,
        .dispatch,
        .end_pass,
        .draw_indirect,
        .draw_indexed_indirect,
        .dispatch_indirect,
        => .pass,

        .submit, .write_buffer => .queue,

        .init_wasm_module, .call_wasm_func, .write_buffer_from_wasm => .wasm,

        // Everything the single-file player cannot express. Refusing loudly is
        // the honest "use the viewer tier" boundary (Arc-3 §5.4, the §240 analog
        // for --html); the viewer runtime plays every one of these.
        .begin_render_pass_mrt,
        .copy_buffer_to_buffer,
        .copy_texture_to_texture,
        .write_uniform,
        .create_query_set,
        .create_image_bitmap,
        .create_render_bundle,
        .execute_bundles,
        .copy_external_image_to_texture,
        .set_viewport,
        .set_stencil_reference,
        .set_scissor_rect,
        .set_pass_occlusion_query_set,
        .set_pass_timestamp_writes,
        .set_pass_depth_stencil_ops,
        .set_pass_clear_values,
        .begin_occlusion_query,
        .end_occlusion_query,
        .resolve_query_set,
        // The declared controls (frame program §7.1). The single-file player
        // has no control table to read, so a write of them is functionality
        // it cannot express — the same refusal mini gives the call, and the
        // per-call shape of the §9 rule that a guarded payload refuses --html
        // outright once the exporter check lands.
        .write_controls,
        => .unsupported,
    };
}

/// Emit a single MockGPU call as JavaScript, routing to its family — the same
/// resource/pass/queue/wasm split the executor's dispatcher handlers use.
fn emitCall(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    call: Call,
    module: *const format.Module,
    pass_idx: *u16,
    submit_start: *u16,
    pipeline_formats: *const std.AutoHashMapUnmanaged(u16, []const u8),
    diag: *Diag,
) !void {
    const before = out.items.len;
    switch (familyOf(call.call_type)) {
        .resource => try emitResourceCall(gpa, out, call, module, pipeline_formats),
        .pass => try emitPassCall(gpa, out, call, pass_idx),
        .queue => try emitQueueCall(gpa, out, call, module, pass_idx, submit_start),
        .wasm => try emitWasmCall(gpa, out, call, module),
        .unsupported => {
            diag.unsupported = call.call_type;
            return CodegenError.UnsupportedByHtml;
        },
    }
    // Post: every emitted statement is terminated, so the next one can be
    // concatenated straight on. (write_buffer of an empty blob emits nothing.)
    std.debug.assert(out.items.len == before or out.items[out.items.len - 1] == ';');
}

/// The `d.create*` calls: one `let <var><id>=…` statement each.
///
/// Over the 70-line rule by design: it is a dispatch table, one arm per
/// CallType, and every arm is a handful of appends. The rule's purpose is to
/// stop a function hiding several jobs inside one; a table hides nothing, and
/// splitting it further would put a `switch` in front of a `switch`. Same
/// judgement as dispatcher/pass.zig's handle.
fn emitResourceCall(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    call: Call,
    module: *const format.Module,
    pipeline_formats: *const std.AutoHashMapUnmanaged(u16, []const u8),
) !void {
    switch (call.call_type) {
        // Shaders go out as raw WGSL template literals. Inner per-shader
        // compression (deflate→base64) is deliberately absent — it is always
        // counterproductive: packed mode already deflates the whole page, so an
        // inner deflate is base64'd back up ~33%, and unpacked mode exists so
        // the WGSL is readable.
        .create_shader_module => {
            const p = call.params.create_shader_module;
            const wgsl = resolveWgslCode(gpa, p.code_data_id, module) catch return;
            defer gpa.free(wgsl);

            try out.appendSlice(gpa, "let s");
            try appendInt(out, gpa, p.shader_id);
            try out.appendSlice(gpa, "=d.createShaderModule({code:`");
            try appendEscapedWgsl(out, gpa, wgsl);
            try out.appendSlice(gpa, "`});");
        },
        .create_buffer => {
            const p = call.params.create_buffer;
            try out.appendSlice(gpa, "let b");
            try appendInt(out, gpa, p.buffer_id);
            try out.appendSlice(gpa, "=d.createBuffer({size:");
            try appendInt(out, gpa, p.size);
            try out.appendSlice(gpa, ",usage:");
            try appendInt(out, gpa, p.usage);
            try out.appendSlice(gpa, "});");
        },
        .create_render_pipeline => {
            const p = call.params.create_render_pipeline;
            const data = module.data.get(@enumFromInt(p.descriptor_data_id));
            const target_fmt = pipeline_formats.get(p.pipeline_id);
            try out.appendSlice(gpa, "let p");
            try appendInt(out, gpa, p.pipeline_id);
            try out.appendSlice(gpa, "=d.createRenderPipeline(");
            try desc.emitRenderPipelineDesc(out, gpa, data, target_fmt);
            try out.appendSlice(gpa, ");");
        },
        .create_compute_pipeline => {
            const p = call.params.create_compute_pipeline;
            const data = module.data.get(@enumFromInt(p.descriptor_data_id));
            try out.appendSlice(gpa, "let p");
            try appendInt(out, gpa, p.pipeline_id);
            try out.appendSlice(gpa, "=d.createComputePipeline(");
            try desc.emitComputePipelineDesc(out, gpa, data);
            try out.appendSlice(gpa, ");");
        },
        .create_bind_group => {
            const p = call.params.create_bind_group;
            const data = module.data.get(@enumFromInt(p.entry_data_id));
            try out.appendSlice(gpa, "let g");
            try appendInt(out, gpa, p.group_id);
            try out.appendSlice(gpa, "=d.createBindGroup(");
            try desc.emitBindGroupDesc(out, gpa, data, p.layout_id);
            try out.appendSlice(gpa, ");");
        },
        .create_texture => {
            const p = call.params.create_texture;
            const data = module.data.get(@enumFromInt(p.descriptor_data_id));
            try out.appendSlice(gpa, "let T");
            try appendInt(out, gpa, p.texture_id);
            try out.appendSlice(gpa, "=d.createTexture(");
            try desc.emitTextureDesc(out, gpa, data);
            // …and its default view, installed WITH the texture. Attachments
            // used to spell `T0.createView()` inline, which for an animated page
            // meant one driver-side view per attachment per pass per FRAME, and
            // WebGPU has no destroy for a view (the §351 bug, in this tier's
            // spelling). Eager rather than lazy for the same reason it is eager
            // in gpu.js: a cache filled on first use fills inside frame 0, which
            // is exactly what the purity gate forbids. The page has no resize
            // handler, so the texture — and therefore this view — lives as long
            // as the run does.
            try out.appendSlice(gpa, "),T");
            try appendInt(out, gpa, p.texture_id);
            try out.appendSlice(gpa, "v=T");
            try appendInt(out, gpa, p.texture_id);
            try out.appendSlice(gpa, ".createView();");
        },
        .create_sampler => {
            const p = call.params.create_sampler;
            const data = module.data.get(@enumFromInt(p.descriptor_data_id));
            try out.appendSlice(gpa, "let m");
            try appendInt(out, gpa, p.sampler_id);
            try out.appendSlice(gpa, "=d.createSampler(");
            try desc.emitSamplerDesc(out, gpa, data);
            try out.appendSlice(gpa, ");");
        },
        .create_texture_view => {
            const p = call.params.create_texture_view;
            const data = module.data.get(@enumFromInt(p.descriptor_data_id));
            try out.appendSlice(gpa, "let V");
            try appendInt(out, gpa, p.view_id);
            try out.appendSlice(gpa, "=T");
            try appendInt(out, gpa, p.texture_id);
            try out.appendSlice(gpa, ".createView(");
            try desc.emitTextureViewDesc(out, gpa, data);
            try out.appendSlice(gpa, ");");
        },
        .create_bind_group_layout => {
            const p = call.params.create_bind_group_layout;
            const data = module.data.get(@enumFromInt(p.descriptor_data_id));
            try out.appendSlice(gpa, "let BGL");
            try appendInt(out, gpa, p.layout_id);
            try out.appendSlice(gpa, "=d.createBindGroupLayout(");
            // The descriptor is already the browser-shape JSON `{"entries":[…]}`;
            // hand it to the device verbatim (visibility/type are wgpu-native names).
            try out.appendSlice(gpa, data);
            try out.appendSlice(gpa, ");");
        },
        .create_pipeline_layout => {
            const p = call.params.create_pipeline_layout;
            const data = module.data.get(@enumFromInt(p.descriptor_data_id));
            try out.appendSlice(gpa, "let PL");
            try appendInt(out, gpa, p.layout_id);
            try out.appendSlice(gpa, "=d.createPipelineLayout(");
            try desc.emitPipelineLayoutDesc(out, gpa, data);
            try out.appendSlice(gpa, ");");
        },
        else => unreachable, // familyOf routes every other tag elsewhere
    }
}

/// The pass-scoped commands: `beginRenderPass`/`beginComputePass` open an
/// encoder pair (`eN`/`rN`), everything after targets `r<pass_idx-1>` until the
/// next pass.
///
/// Over the 70-line rule by design — a dispatch table, same as emitResourceCall
/// above; see its note.
fn emitPassCall(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    call: Call,
    pass_idx: *u16,
) !void {
    switch (call.call_type) {
        .begin_render_pass => try emitBeginRenderPass(gpa, out, call, pass_idx),
        .begin_compute_pass => {
            const pi = pass_idx.*;
            pass_idx.* += 1;
            try out.appendSlice(gpa, "let e");
            try appendInt(out, gpa, pi);
            try out.appendSlice(gpa, "=d.createCommandEncoder(),r");
            try appendInt(out, gpa, pi);
            try out.appendSlice(gpa, "=e");
            try appendInt(out, gpa, pi);
            try out.appendSlice(gpa, ".beginComputePass();");
        },
        .set_pipeline => {
            const p = call.params.set_pipeline;
            try out.appendSlice(gpa, "r");
            try appendInt(out, gpa, pass_idx.* -| 1);
            try out.appendSlice(gpa, ".setPipeline(p");
            try appendInt(out, gpa, p.pipeline_id);
            try out.appendSlice(gpa, ");");
        },
        .set_bind_group => {
            const p = call.params.set_bind_group;
            try out.appendSlice(gpa, "r");
            try appendInt(out, gpa, pass_idx.* -| 1);
            try out.appendSlice(gpa, ".setBindGroup(");
            try appendInt(out, gpa, p.slot);
            try out.appendSlice(gpa, ",g");
            try appendInt(out, gpa, p.group_id);
            try out.appendSlice(gpa, ");");
        },
        .set_vertex_buffer => {
            const p = call.params.set_vertex_buffer;
            try out.appendSlice(gpa, "r");
            try appendInt(out, gpa, pass_idx.* -| 1);
            try out.appendSlice(gpa, ".setVertexBuffer(");
            try appendInt(out, gpa, p.slot);
            try out.appendSlice(gpa, ",b");
            try appendInt(out, gpa, p.buffer_id);
            try out.appendSlice(gpa, ");");
        },
        .set_index_buffer => {
            const p = call.params.set_index_buffer;
            try out.appendSlice(gpa, "r");
            try appendInt(out, gpa, pass_idx.* -| 1);
            try out.appendSlice(gpa, ".setIndexBuffer(b");
            try appendInt(out, gpa, p.buffer_id);
            try out.appendSlice(gpa, ",'");
            try out.appendSlice(gpa, if (p.index_format == 0) "uint16" else "uint32");
            try out.appendSlice(gpa, "');");
        },
        .set_blend_constant => {
            const p = call.params.set_blend_constant;
            try out.appendSlice(gpa, "r");
            try appendInt(out, gpa, pass_idx.* -| 1);
            try out.appendSlice(gpa, ".setBlendConstant([");
            var bc_buf: [64]u8 = undefined;
            const bc_str = std.fmt.bufPrint(&bc_buf, "{d},{d},{d},{d}", .{
                @as(f32, @bitCast(p.r_bits)), @as(f32, @bitCast(p.g_bits)), @as(f32, @bitCast(p.b_bits)), @as(f32, @bitCast(p.a_bits)),
            }) catch "0,0,0,0";
            try out.appendSlice(gpa, bc_str);
            try out.appendSlice(gpa, "]);");
        },
        .draw => {
            const p = call.params.draw;
            try out.appendSlice(gpa, "r");
            try appendInt(out, gpa, pass_idx.* -| 1);
            try out.appendSlice(gpa, ".draw(");
            try appendInt(out, gpa, p.vertex_count);
            if (p.instance_count != 1 or p.first_vertex != 0 or p.first_instance != 0) {
                try out.appendSlice(gpa, ",");
                try appendInt(out, gpa, p.instance_count);
                if (p.first_vertex != 0 or p.first_instance != 0) {
                    try out.appendSlice(gpa, ",");
                    try appendInt(out, gpa, p.first_vertex);
                    if (p.first_instance != 0) {
                        try out.appendSlice(gpa, ",");
                        try appendInt(out, gpa, p.first_instance);
                    }
                }
            }
            try out.appendSlice(gpa, ");");
        },
        .draw_indexed => {
            const p = call.params.draw_indexed;
            try out.appendSlice(gpa, "r");
            try appendInt(out, gpa, pass_idx.* -| 1);
            try out.appendSlice(gpa, ".drawIndexed(");
            try appendInt(out, gpa, p.index_count);
            if (p.instance_count != 1 or p.first_index != 0 or p.base_vertex != 0 or p.first_instance != 0) {
                try out.appendSlice(gpa, ",");
                try appendInt(out, gpa, p.instance_count);
            }
            try out.appendSlice(gpa, ");");
        },
        .dispatch => {
            const p = call.params.dispatch;
            try out.appendSlice(gpa, "r");
            try appendInt(out, gpa, pass_idx.* -| 1);
            try out.appendSlice(gpa, ".dispatchWorkgroups(");
            try appendInt(out, gpa, p.x);
            try out.appendSlice(gpa, ",");
            try appendInt(out, gpa, p.y);
            try out.appendSlice(gpa, ",");
            try appendInt(out, gpa, p.z);
            try out.appendSlice(gpa, ");");
        },
        .end_pass => {
            try out.appendSlice(gpa, "r");
            try appendInt(out, gpa, pass_idx.* -| 1);
            try out.appendSlice(gpa, ".end();");
        },
        .draw_indirect => {
            const p = call.params.draw_indirect;
            try out.appendSlice(gpa, "r");
            try appendInt(out, gpa, pass_idx.* -| 1);
            try out.appendSlice(gpa, ".drawIndirect(b");
            try appendInt(out, gpa, p.buffer_id);
            try out.appendSlice(gpa, ",");
            try appendInt(out, gpa, p.offset);
            try out.appendSlice(gpa, ");");
        },
        .draw_indexed_indirect => {
            const p = call.params.draw_indexed_indirect;
            try out.appendSlice(gpa, "r");
            try appendInt(out, gpa, pass_idx.* -| 1);
            try out.appendSlice(gpa, ".drawIndexedIndirect(b");
            try appendInt(out, gpa, p.buffer_id);
            try out.appendSlice(gpa, ",");
            try appendInt(out, gpa, p.offset);
            try out.appendSlice(gpa, ");");
        },
        .dispatch_indirect => {
            const p = call.params.dispatch_indirect;
            try out.appendSlice(gpa, "r");
            try appendInt(out, gpa, pass_idx.* -| 1);
            try out.appendSlice(gpa, ".dispatchWorkgroupsIndirect(b");
            try appendInt(out, gpa, p.buffer_id);
            try out.appendSlice(gpa, ",");
            try appendInt(out, gpa, p.offset);
            try out.appendSlice(gpa, ");");
        },
        else => unreachable, // familyOf routes every other tag elsewhere
    }
}

/// The queue-level commands: static buffer writes and the submit that flushes
/// every encoder opened since the last one.
fn emitQueueCall(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    call: Call,
    module: *const format.Module,
    pass_idx: *u16,
    submit_start: *u16,
) !void {
    switch (call.call_type) {
        .submit => {
            // Submit all encoders since the last submit
            try out.appendSlice(gpa, "d.queue.submit([");
            var i = submit_start.*;
            while (i < pass_idx.*) : (i += 1) {
                if (i > submit_start.*) try out.appendSlice(gpa, ",");
                try out.appendSlice(gpa, "e");
                try appendInt(out, gpa, i);
                try out.appendSlice(gpa, ".finish()");
            }
            try out.appendSlice(gpa, "]);");
            submit_start.* = pass_idx.*;
        },
        .write_buffer => {
            // Static data write (vertex data, etc.) - inline the data as a typed array
            const p = call.params.write_buffer;
            const data = module.data.get(@enumFromInt(p.data_id));
            if (data.len > 0) {
                try out.appendSlice(gpa, "d.queue.writeBuffer(b");
                try appendInt(out, gpa, p.buffer_id);
                try out.appendSlice(gpa, ",");
                try appendInt(out, gpa, p.offset);
                try out.appendSlice(gpa, ",new Float32Array([");
                // Emit data as float32 values (compact: .5 instead of 0.5)
                const float_count = data.len / 4;
                for (0..float_count) |fi| {
                    if (fi > 0) try out.appendSlice(gpa, ",");
                    const bytes = data[fi * 4 ..][0..4];
                    const val: f32 = @bitCast(bytes.*);
                    try appendCompactFloat(out, gpa, val);
                }
                try out.appendSlice(gpa, "]));");
            }
        },
        else => unreachable, // familyOf routes every other tag elsewhere
    }
}

/// The [wasm] plugin's three commands: instantiate a module, call an export,
/// and copy a slice of its linear memory into a GPU buffer.
fn emitWasmCall(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    call: Call,
    module: *const format.Module,
) !void {
    switch (call.call_type) {
        .init_wasm_module => {
            const p = call.params.init_wasm_module;
            const wasm_bytes = module.data.get(@enumFromInt(p.wasm_data_id));
            // Emit: let wN=await WebAssembly.instantiate(Uint8Array.from(atob('...'),c=>c.charCodeAt(0)))
            try out.appendSlice(gpa, "let w");
            try appendInt(out, gpa, p.module_id);
            try out.appendSlice(gpa, "=await WebAssembly.instantiate(Uint8Array.from(atob('");
            try base64Append(out, gpa, wasm_bytes);
            try out.appendSlice(gpa, "'),c=>c.charCodeAt(0)));");
        },
        .call_wasm_func => {
            const p = call.params.call_wasm_func;
            const func_name = module.strings.get(@enumFromInt(p.func_name_id));
            // Emit: wN.instance.exports.funcName()
            try out.appendSlice(gpa, "w");
            try appendInt(out, gpa, p.module_id);
            try out.appendSlice(gpa, ".instance.exports.");
            try out.appendSlice(gpa, func_name);
            try out.appendSlice(gpa, "();");
        },
        .write_buffer_from_wasm => {
            const p = call.params.write_buffer_from_wasm;
            // Emit: d.queue.writeBuffer(bN,0,new Uint8Array(wM.instance.exports.m.buffer,S,L))
            try out.appendSlice(gpa, "d.queue.writeBuffer(b");
            try appendInt(out, gpa, p.buffer_id);
            try out.appendSlice(gpa, ",0,new Uint8Array(w");
            try appendInt(out, gpa, p.call_id); // module_id used as call_id
            try out.appendSlice(gpa, ".instance.exports.m.buffer,");
            try appendInt(out, gpa, p.offset);
            try out.appendSlice(gpa, ",");
            try appendInt(out, gpa, p.byte_len);
            try out.appendSlice(gpa, "));");
        },
        else => unreachable, // familyOf routes every other tag elsewhere
    }
}

// ============================================================================
// Bytecode scanning
// ============================================================================

const TimeUniformInfo = struct {
    buffer_id: u16,
    offset: u32,
    size: u16,
};

/// The three per-frame runtime-uniform writes `--html` has to reproduce:
/// `write_time_uniform` (0x2A), `write_pointer_uniform` (0x2B),
/// `write_audio_data` (0x2C). MockGPU records them outside its call log, so
/// the generator recovers them from the bytecode — by WALKING it.
///
/// This used to be three raw-byte scans for 0x2A/0x2B/0x2C with no notion of
/// where an instruction starts (the defect flat.zig's `injectUniformWrites`
/// names): any OPERAND byte holding one of those values fabricated a record —
/// a `(draw :vertex-count 42 …)` (42 = 0x2A) made the page write
/// [time, w, h, aspect] into an unrelated buffer sixty times a second, a
/// `:first-instance 70000` beside a 44 made the audio scan `@intCast` a
/// 4-byte varint into its u16 `size` and PANIC `pngine render --html` on a
/// valid document. Stepping through `wire_schema.skipParams` (the single
/// source of truth the emitter and both dispatchers follow) is what makes
/// 0x2A mean the opcode. (Third leak pass)
const MAX_TIME_UNIFORMS = 16;
const MAX_POINTER_UNIFORMS = 16;
const MAX_AUDIO_UNIFORMS = 16;
const TimeUniformScanResult = struct { items: [MAX_TIME_UNIFORMS]TimeUniformInfo, count: u8 };
const PointerUniformScanResult = struct { items: [MAX_POINTER_UNIFORMS]TimeUniformInfo, count: u8 };
const AudioUniformScanResult = struct { items: [MAX_AUDIO_UNIFORMS]TimeUniformInfo, count: u8 };

/// Upper bound on the bytecode walk. Every iteration consumes at least the
/// opcode byte, so only a stream past the 1 MB the scanner already refuses
/// could reach it.
const MAX_BYTECODE_WALK: u32 = 1 << 20;

const RuntimeUniformKind = enum { time, pointer, audio };

/// One instruction walk, collecting the `kind` asked for. A record is kept
/// when its operands fit the emitter's widths (u16 buffer id, u16 size) and —
/// for time and pointer — name one of the sizes the host stages (12/16 and
/// 16/32/48); a wider value means the bytecode was not built by the emitter
/// and the record is skipped, never `@intCast`. Deduplicated by buffer id.
fn scanRuntimeUniforms(bytecode: []const u8, comptime kind: RuntimeUniformKind, items: []TimeUniformInfo) u8 {
    std.debug.assert(items.len > 0 and items.len <= 16);
    const want: pngine.opcodes.OpCode = switch (kind) {
        .time => .write_time_uniform,
        .pointer => .write_pointer_uniform,
        .audio => .write_audio_data,
    };
    var count: u8 = 0;
    var pc: u32 = 0;
    for (0..MAX_BYTECODE_WALK) |_| {
        if (pc >= bytecode.len) break;
        const op: pngine.opcodes.OpCode = @enumFromInt(bytecode[pc]);
        const operands = pc + 1;
        // `skipParams` never advances past the buffer and never below
        // `operands`, so the walk consumes at least the opcode byte and cannot
        // spin — even on a reserved opcode, which skips nothing.
        pc = pngine.wire_schema.skipParams(bytecode, operands, op);
        std.debug.assert(pc >= operands and pc <= bytecode.len);
        if (op != want) continue;

        const r1 = decodeVarint(bytecode[operands..]);
        if (r1.len == 0) continue;
        const r2 = decodeVarint(bytecode[operands + r1.len ..]);
        if (r2.len == 0) continue;
        const r3 = decodeVarint(bytecode[operands + r1.len + r2.len ..]);
        if (r3.len == 0) continue;
        if (r1.value > std.math.maxInt(u16) or r3.value > std.math.maxInt(u16)) continue;
        const size_ok = switch (kind) {
            // The three builtin time sources, by their ABI byte counts:
            // `scene-time-inputs` 12, `pngine-inputs` 16, `pngine-frame-inputs`
            // 20. A size this scan does not list is not emitted AT ALL, so
            // leaving 20 out did not degrade the page — it dropped the uniform
            // write, and the shader read a buffer nothing ever filled (§438).
            .time => r3.value == 12 or r3.value == 16 or r3.value == 20,
            .pointer => r3.value == 16 or r3.value == 32 or r3.value == 48,
            .audio => true,
        };
        if (!size_ok) continue;

        const info = TimeUniformInfo{
            .buffer_id = @intCast(r1.value),
            .offset = r2.value,
            .size = @intCast(r3.value),
        };
        var dup = false;
        for (items[0..count]) |existing| {
            if (existing.buffer_id == info.buffer_id) {
                dup = true;
                break;
            }
        }
        if (!dup and count < items.len) {
            items[count] = info;
            count += 1;
        }
    }
    std.debug.assert(count <= items.len);
    return count;
}

fn scanAllTimeUniforms(bytecode: []const u8) TimeUniformScanResult {
    var result: TimeUniformScanResult = .{ .items = undefined, .count = 0 };
    result.count = scanRuntimeUniforms(bytecode, .time, &result.items);
    return result;
}

fn scanAllPointerUniforms(bytecode: []const u8) PointerUniformScanResult {
    var result: PointerUniformScanResult = .{ .items = undefined, .count = 0 };
    result.count = scanRuntimeUniforms(bytecode, .pointer, &result.items);
    return result;
}

fn scanAllAudioUniforms(bytecode: []const u8) AudioUniformScanResult {
    var result: AudioUniformScanResult = .{ .items = undefined, .count = 0 };
    result.count = scanRuntimeUniforms(bytecode, .audio, &result.items);
    return result;
}

/// Scan the uniform TABLE (not the bytecode) for top-level f32 members named
/// `dark`. Bind-by-name is how pngine already resolves entry points,
/// @group/@binding variables and setUniform targets — and --minify preserves
/// member names for exactly that reason — so the generated page follows the
/// same convention: a `dark: f32` member receives the page's dark-mode flag
/// (see frag.dark_setup for where the value comes from).
const MAX_DARK_UNIFORMS = 8;
const DarkUniformScanResult = struct { items: [MAX_DARK_UNIFORMS]TimeUniformInfo, count: u8 };

fn scanDarkUniforms(module: *const format.Module) DarkUniformScanResult {
    var result: DarkUniformScanResult = .{ .items = undefined, .count = 0 };
    for (module.uniforms.bindings.items) |binding| {
        for (binding.fields) |field| {
            if (field.uniform_type != .f32 or field.elem_count != 0) continue;
            const name = module.strings.get(@enumFromInt(field.name_string_id));
            if (!std.mem.eql(u8, name, "dark")) continue;
            var dup = false;
            for (result.items[0..result.count]) |existing| {
                if (existing.buffer_id == binding.buffer_id and existing.offset == field.offset) {
                    dup = true;
                    break;
                }
            }
            if (!dup and result.count < MAX_DARK_UNIFORMS) {
                result.items[result.count] = .{
                    .buffer_id = binding.buffer_id,
                    .offset = field.offset,
                    .size = field.size,
                };
                result.count += 1;
            }
        }
    }
    return result;
}

/// Length-tolerant varint decode over possibly-truncated bytecode.
/// Single-sourced with the canonical decoder (opcodes.decode_varint_safe).
const decodeVarint = pngine.opcodes.decode_varint_safe;

/// Resolve WGSL code with imports.
///
/// The code_data_id from MockGPU is a data section index (not wgsl_id).
/// First try direct data section lookup. If the WGSL table has entries whose
/// data_id matches, resolve imports via DFS. Otherwise return raw data.
fn resolveWgslCode(gpa: Allocator, code_data_id: u16, module: *const format.Module) ![]u8 {
    const wgsl_table = &module.wgsl;

    // Find wgsl_id by matching data_id
    var wgsl_id: ?u16 = null;
    for (0..wgsl_table.count()) |i| {
        if (wgsl_table.get(@intCast(i))) |entry| {
            if (entry.data_id == code_data_id) {
                wgsl_id = @intCast(i);
                break;
            }
        }
    }

    // If found in WGSL table with deps, resolve imports
    if (wgsl_id) |wid| {
        const entry = wgsl_table.get(wid).?;
        if (entry.deps.len > 0) {
            return resolveWgslWithDeps(gpa, wid, module);
        }
    }

    // Fallback: read directly from data section
    const data = module.data.get(@enumFromInt(code_data_id));
    const result = try gpa.alloc(u8, data.len);
    @memcpy(result, data);
    return result;
}

/// Resolve WGSL with import dependencies (iterative DFS).
fn resolveWgslWithDeps(gpa: Allocator, wgsl_id: u16, module: *const format.Module) ![]u8 {
    const wgsl_table = &module.wgsl;

    var included = std.AutoHashMapUnmanaged(u16, void){};
    defer included.deinit(gpa);
    var order = std.ArrayList(u16).empty;
    defer order.deinit(gpa);
    var stack = std.ArrayList(u16).empty;
    defer stack.deinit(gpa);

    try stack.append(gpa, wgsl_id);

    for (0..1024) |_| {
        if (stack.items.len == 0) break;
        const current = stack.pop() orelse break;
        if (included.contains(current)) continue;

        const entry = wgsl_table.get(current) orelse continue;

        var all_deps_ready = true;
        for (entry.deps) |dep| {
            if (!included.contains(dep)) {
                all_deps_ready = false;
                break;
            }
        }

        if (all_deps_ready) {
            try included.put(gpa, current, {});
            try order.append(gpa, current);
        } else {
            try stack.append(gpa, current);
            for (entry.deps) |dep| {
                if (!included.contains(dep)) {
                    try stack.append(gpa, dep);
                }
            }
        }
    }

    var total_size: usize = 0;
    for (order.items) |id| {
        if (wgsl_table.get(id)) |entry| {
            const data = module.data.get(@enumFromInt(entry.data_id));
            total_size += data.len;
        }
    }

    const result = try gpa.alloc(u8, total_size);
    var pos: usize = 0;
    for (order.items) |id| {
        if (wgsl_table.get(id)) |entry| {
            const data = module.data.get(@enumFromInt(entry.data_id));
            @memcpy(result[pos..][0..data.len], data);
            pos += data.len;
        }
    }

    return result;
}

/// Raw deflate compression. Returns owned compressed bytes.
fn deflateCompress(gpa: Allocator, data: []const u8) ![]u8 {
    std.debug.assert(data.len > 0);

    const capacity = data.len + data.len / 10 + 1024;
    var output_buf = try gpa.alloc(u8, capacity);
    defer gpa.free(output_buf);

    var window_buf: [flate.max_window_len]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(output_buf);

    var compressor = flate.Compress.init(
        &output_writer,
        &window_buf,
        .raw,
        .level_9,
    ) catch return error.OutOfMemory;

    compressor.writer.writeAll(data) catch return error.OutOfMemory;
    compressor.finish() catch return error.OutOfMemory;

    const result = try gpa.alloc(u8, output_writer.end);
    @memcpy(result, output_buf[0..output_writer.end]);
    return result;
}

/// Emit audio WASM setup code (base64-encoded inline).
fn emitAudioSetup(html: *std.ArrayList(u8), gpa: Allocator, audio_wasm: []const u8) !void {
    try html.appendSlice(gpa, frag.audio_pre);
    // Base64 encode audio WASM
    try base64Append(html, gpa, audio_wasm);
    try html.appendSlice(gpa, frag.audio_post);
}

/// Emit audio WASM setup from _a global (raw binary, no base64).
fn emitAudioSetupFromGlobal(html: *std.ArrayList(u8), gpa: Allocator) !void {
    // _a is a Uint8Array set by the bootstrap, pointing to raw audio WASM bytes.
    // audio_post starts with "'),c=>c.charCodeAt(0)),{m:Math})..." — skip the
    // atob/charCodeAt prefix (23 chars) and prepend our own instantiate call.
    try html.appendSlice(gpa, "let{instance:ai}=await WebAssembly.instantiate(_a,");
    try html.appendSlice(gpa, frag.audio_post[23..]); // from "{m:Math}),am=..."
}

// ============================================================================
// Tests — the runtime-uniform walk (third leak pass)
// ============================================================================

const testing = std.testing;

/// A bytecode body with an honest time write and a draw whose operands spell
/// the three opcodes: `draw 42 1 0 70000` — 42 = 0x2A, and the trailing
/// 4-byte varint is what the old audio scan `@intCast` into a u16.
fn runtimeUniformProbe(gpa: Allocator) ![]u8 {
    var b = pngine.format.Builder.init();
    defer b.deinit(gpa);
    const name_id = try b.internString(gpa, "f");
    const e = b.getEmitter();
    try e.createBuffer(gpa, 0, 16, .{ .uniform = true, .copy_dst = true });
    try e.createBuffer(gpa, 1, 44, .{ .storage = true });
    try e.defineFrame(gpa, 0, name_id.toInt());
    try e.writeTimeUniform(gpa, 0, 0, 16);
    // Three draws whose operand bytes spell a time (0x2A), a pointer (0x2B)
    // and an audio (0x2C) write — with operands the old scans accepted: a
    // small buffer id, a staged size, and for audio a 4-byte varint.
    try e.draw(gpa, 42, 1, 0, 16);
    try e.draw(gpa, 43, 1, 0, 48);
    try e.draw(gpa, 44, 1, 0, 70000);
    try e.endFrame(gpa);
    return b.finalize(gpa);
}
