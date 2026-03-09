//! Pass Sugar Emission Module
//!
//! Expands `#pass` macros into synthetic bytecode resources.
//! Each `#pass` auto-detects its mode from WGSL annotations:
//! - `@fragment fn` → render pipeline + fullscreen triangle
//! - `@compute @workgroup_size fn` → compute pipeline(s) + optional blit
//!
//! ## Expansion
//!
//! A single `#pass` expands into:
//! - Uniform buffer + writeTimeUniform
//! - Output texture(s) (with feedback/ping-pong if enabled)
//! - Shared sampler (deduped)
//! - Shader module(s) (with auto-injected prelude)
//! - Pipeline(s) (one per entry point for compute)
//! - Bind group(s)
//! - Pass definition(s)
//! - Auto-blit (if main compute pass)
//! - Auto-generated frame (if no explicit #frame)
//!
//! ## Invariants
//!
//! * Pass macros are expanded after explicit resources but before frames.
//! * Synthetic resource IDs are assigned sequentially using emitter counters.
//! * Entry point extraction uses wgsl_scan (no full WGSL parser).
//! * Maximum 32 passes per file.
//! * Fragment and compute cannot coexist in the same #pass code block.

const std = @import("std");
const Emitter = @import("../Emitter.zig").Emitter;
const Node = @import("../Ast.zig").Node;
const DescriptorEncoder = @import("../DescriptorEncoder.zig").DescriptorEncoder;
const utils = @import("utils.zig");
const wgsl_scan = @import("wgsl_scan.zig");

const bytecode_mod = @import("bytecode");
const opcodes = bytecode_mod.opcodes;
const BufferUsage = opcodes.BufferUsage;
const passes_mod = @import("passes.zig");

/// Maximum #pass macros to process.
const MAX_PASSES: u32 = 32;

/// Reference canvas size for fixed dispatch (Phase 1).
const REF_WIDTH: u32 = 512;
const REF_HEIGHT: u32 = 512;

/// Canvas texture sentinel (render to screen).
const CANVAS_TEXTURE_ID: u16 = passes_mod.CANVAS_TEXTURE_ID;

/// Info tracked per expanded pass for dependency resolution and frame building.
const PassInfo = struct {
    name: []const u8,
    is_fragment: bool,
    is_main: bool,
    needs_uniform: bool, // whether shader references pngine
    output_texture_id: u16, // texture other passes can sample
    texture_pool_size: u8, // 1 = normal, 2 = feedback ping-pong
    uniform_buf_id: u16, // uniform buffer for writeTimeUniform
    pass_ids: [MAX_ENTRY_POINTS_PER_PASS]u16,
    pass_count: u32,
    init_pass_ids: [MAX_ENTRY_POINTS_PER_PASS]u16,
    init_pass_count: u32,
    blit_pass_id: ?u16, // auto-blit for compute main
};

const MAX_ENTRY_POINTS_PER_PASS = 16;

/// Expand all #pass macros into synthetic bytecode resources.
/// Called between pipeline emission and frame emission.
pub fn expandPassMacros(e: *Emitter) Emitter.Error!void {
    std.debug.assert(e.ast.nodes.len > 0);

    const pass_symbols = &e.analysis.symbols.pass;
    if (pass_symbols.count() == 0) return;

    // Collect pass names in declaration order from AST
    var ordered_names: [MAX_PASSES][]const u8 = undefined;
    var ordered_nodes: [MAX_PASSES]Node.Index = undefined;
    var pass_count: u32 = 0;

    const root_data = e.ast.nodes.items(.data)[0];
    const children = e.ast.extraData(root_data.extra_range);
    const tags = e.ast.nodes.items(.tag);
    const main_tokens = e.ast.nodes.items(.main_token);

    for (children) |child_idx| {
        if (pass_count >= MAX_PASSES) break;
        const node_idx: Node.Index = @enumFromInt(child_idx);
        if (tags[node_idx.toInt()] != .macro_pass) continue;

        const name_token = main_tokens[node_idx.toInt()] + 1;
        const name = utils.getTokenSlice(e, name_token);

        ordered_names[pass_count] = name;
        ordered_nodes[pass_count] = node_idx;
        pass_count += 1;
    }

    if (pass_count == 0) return;

    // Track expanded pass info for frame building
    var pass_infos: [MAX_PASSES]PassInfo = undefined;

    // Ensure we have a shared sampler
    const sampler_id = try ensureSharedSampler(e);

    // Expand each pass in declaration order
    for (0..pass_count) |i| {
        const name = ordered_names[i];
        const node = ordered_nodes[i];
        const is_last = (i == pass_count - 1);

        pass_infos[i] = try expandPass(e, name, node, is_last, sampler_id, pass_infos[0..i]);
    }

    // Generate auto frame if no explicit #frame exists
    if (e.analysis.symbols.frame.count() == 0) {
        try emitAutoFrame(e, pass_infos[0..pass_count]);
    }
}

/// Expand a single #pass macro into synthetic resources.
fn expandPass(
    e: *Emitter,
    name: []const u8,
    node: Node.Index,
    is_last: bool,
    sampler_id: u16,
    prior_passes: []const PassInfo,
) Emitter.Error!PassInfo {
    std.debug.assert(name.len > 0);
    std.debug.assert(node.toInt() < e.ast.nodes.len);

    var info = PassInfo{
        .name = name,
        .is_fragment = false,
        .is_main = is_last or std.mem.eql(u8, name, "main"),
        .needs_uniform = false,
        .output_texture_id = 0,
        .texture_pool_size = 1,
        .uniform_buf_id = 0,
        .pass_ids = undefined,
        .pass_count = 0,
        .init_pass_ids = undefined,
        .init_pass_count = 0,
        .blit_pass_id = null,
    };

    // 1. Extract code string and scan for entry points
    const code = getStringProperty(e, node, "code") orelse return info;
    const scan = wgsl_scan.scanEntryPoints(code);

    if (scan.count == 0) return info;

    // Validate: can't have both @fragment and @compute in same code block
    if (scan.has_fragment and scan.has_compute) return info;

    info.is_fragment = scan.has_fragment;

    // 2. Check for feedback
    const feedback = getBoolProperty(e, node, "feedback");

    // Determine if uniform buffer is needed: shader references pngine.time/width/etc.
    const needs_uniform = std.mem.indexOf(u8, code, "pngine") != null;
    info.needs_uniform = needs_uniform;

    // Determine if sampler is needed: user code references textureSample/samp,
    // or has dependencies/feedback that bring in textures requiring sampling.
    const needs_sampler = scan.has_fragment and
        (prior_passes.len > 0 or feedback or
        std.mem.indexOf(u8, code, "textureSample") != null or
        std.mem.indexOf(u8, code, "samp") != null);

    // 3. Create uniform buffer (16 bytes: time, width, height, aspect) if needed
    var uniform_buf_id: u16 = 0;
    if (needs_uniform) {
        uniform_buf_id = e.next_buffer_id;
        info.uniform_buf_id = uniform_buf_id;
        e.next_buffer_id += 1;
        try e.builder.getEmitter().createBuffer(
            e.gpa,
            uniform_buf_id,
            16,
            BufferUsage.uniform_copy_dst,
        );
    }

    // 4. Create output texture(s)
    const texture_pool_size: u8 = if (feedback) 2 else 1;
    const output_tex_id = e.next_texture_id;
    info.output_texture_id = output_tex_id;
    info.texture_pool_size = texture_pool_size;

    for (0..texture_pool_size) |_| {
        const tex_id = e.next_texture_id;
        e.next_texture_id += 1;
        try emitCanvasTexture(e, tex_id, info.is_fragment);
    }

    // 5. Build WGSL prelude and create shader module
    const prelude = try buildPrelude(e, info.is_fragment, needs_uniform, needs_sampler, prior_passes, feedback, name);
    defer e.gpa.free(prelude);

    const full_code = try std.mem.concat(e.gpa, u8, &.{ prelude, code });
    defer e.gpa.free(full_code);

    const shader_data_id = try e.builder.addData(e.gpa, full_code);
    const shader_id = e.next_shader_id;
    e.next_shader_id += 1;

    // Use WGSL table for runtime deduplication
    _ = try e.builder.addWgsl(e.gpa, shader_data_id.toInt(), &.{});

    try e.builder.getEmitter().createShaderModule(
        e.gpa,
        shader_id,
        shader_data_id.toInt(),
    );

    // 6. Create pipeline(s) and pass(es) per entry point
    const entries = scan.slice();

    if (info.is_fragment) {
        // Fragment: one render pipeline with auto vertex shader
        try emitFragmentPipeline(e, &info, shader_id, uniform_buf_id, sampler_id, needs_uniform, needs_sampler, output_tex_id, texture_pool_size, prior_passes, feedback, name, node);
    } else {
        // Compute: one pipeline per entry point
        try emitComputePipelines(e, &info, shader_id, entries, uniform_buf_id, needs_uniform, output_tex_id, texture_pool_size, prior_passes, feedback, name);

        // If this is the main pass, add auto-blit
        if (info.is_main) {
            try emitBlitPass(e, &info, output_tex_id, sampler_id);
        }
    }

    // 7. Handle init code
    const init_code = getStringProperty(e, node, "init");
    if (init_code) |ic| {
        try emitInitCode(e, &info, ic, uniform_buf_id, output_tex_id, prior_passes, feedback, name);
    }

    return info;
}

// ============================================================================
// Fragment Pass Emission
// ============================================================================

fn emitFragmentPipeline(
    e: *Emitter,
    info: *PassInfo,
    shader_id: u16,
    uniform_buf_id: u16,
    sampler_id: u16,
    needs_uniform: bool,
    needs_sampler: bool,
    output_tex_id: u16,
    texture_pool_size: u8,
    prior_passes: []const PassInfo,
    feedback: bool,
    name: []const u8,
    node: Node.Index,
) Emitter.Error!void {
    // Create render pipeline with auto layout
    const pipeline_id = e.next_pipeline_id;
    e.next_pipeline_id += 1;

    // Non-main passes render to rgba8unorm textures; main renders to canvas (use default format)
    const target_fmt: ?[]const u8 = if (info.is_main) null else "rgba8unorm";
    const desc = try buildRenderPipelineDescriptor(e, shader_id, target_fmt);
    defer e.gpa.free(desc);
    const desc_id = try e.builder.addData(e.gpa, desc);

    try e.builder.getEmitter().createRenderPipeline(
        e.gpa,
        pipeline_id,
        desc_id.toInt(),
    );

    // Create bind group(s)
    // Need pool bind groups when: own feedback OR any dep has feedback
    var any_dep_has_pool = false;
    for (prior_passes) |dep| {
        if (dep.texture_pool_size > 1) {
            any_dep_has_pool = true;
            break;
        }
    }
    const needs_pool_bg = feedback or any_dep_has_pool;

    const bg_id = e.next_bind_group_id;
    e.next_bind_group_id += 1;

    // bg_A (phase 0): dep reads tex+0, self feedback reads tex+1
    const feedback_read_tex_a = if (feedback) output_tex_id + 1 else output_tex_id;
    const bg_desc = try buildBindGroupDescriptor(e, uniform_buf_id, sampler_id, needs_uniform, needs_sampler, prior_passes, feedback, feedback_read_tex_a, name, 0);
    defer e.gpa.free(bg_desc);
    const bg_desc_id = try e.builder.addData(e.gpa, bg_desc);
    try e.builder.getEmitter().createBindGroup(e.gpa, bg_id, pipeline_id, bg_desc_id.toInt());

    // bg_B (phase 1): dep reads tex+1, self feedback reads tex+0
    if (needs_pool_bg) {
        const bg_id_b = e.next_bind_group_id;
        e.next_bind_group_id += 1;

        const feedback_read_tex_b: u16 = if (feedback) output_tex_id else output_tex_id;
        const bg_desc_b = try buildBindGroupDescriptor(e, uniform_buf_id, sampler_id, needs_uniform, needs_sampler, prior_passes, feedback, feedback_read_tex_b, name, 1);
        defer e.gpa.free(bg_desc_b);
        const bg_desc_id_b = try e.builder.addData(e.gpa, bg_desc_b);
        try e.builder.getEmitter().createBindGroup(e.gpa, bg_id_b, pipeline_id, bg_desc_id_b.toInt());
    }

    // Parse clear color
    const clear_color = getClearColor(e, node);

    // Create render pass definition
    const pass_id = e.next_pass_id;
    e.next_pass_id += 1;
    info.pass_ids[info.pass_count] = pass_id;
    info.pass_count += 1;

    const pass_desc = "{}";
    const pass_desc_id = try e.builder.addData(e.gpa, pass_desc);

    try e.builder.getEmitter().definePass(e.gpa, pass_id, .render, pass_desc_id.toInt());

    // Begin render pass — use pool variant for feedback to alternate render targets
    if (feedback and texture_pool_size > 1) {
        try e.builder.getEmitter().beginRenderPassPool(
            e.gpa,
            output_tex_id, // base texture id
            texture_pool_size,
            0, // offset: frame 0 → tex0, frame 1 → tex1
            opcodes.LoadOp.clear,
            opcodes.StoreOp.store,
            0xFFFF,
        );
    } else {
        const render_target = if (info.is_main) CANVAS_TEXTURE_ID else output_tex_id;
        try e.builder.getEmitter().beginRenderPass(
            e.gpa,
            render_target,
            opcodes.LoadOp.clear,
            opcodes.StoreOp.store,
            0xFFFF,
        );
    }

    // Set pipeline and bind group
    try e.builder.getEmitter().setPipeline(e.gpa, pipeline_id);

    if (needs_pool_bg) {
        try e.builder.getEmitter().setBindGroupPool(e.gpa, 0, bg_id, 2, 0);
    } else {
        try e.builder.getEmitter().setBindGroup(e.gpa, 0, bg_id);
    }

    // Draw fullscreen triangle
    try e.builder.getEmitter().draw(e.gpa, 3, 1, 0, 0);

    // End pass
    try e.builder.getEmitter().endPass(e.gpa);
    try e.builder.getEmitter().endPassDef(e.gpa);

    _ = clear_color;
}

// ============================================================================
// Compute Pass Emission
// ============================================================================

fn emitComputePipelines(
    e: *Emitter,
    info: *PassInfo,
    shader_id: u16,
    entries: []const wgsl_scan.EntryPoint,
    uniform_buf_id: u16,
    needs_uniform: bool,
    output_tex_id: u16,
    texture_pool_size: u8,
    prior_passes: []const PassInfo,
    feedback: bool,
    name: []const u8,
) Emitter.Error!void {

    // Create one pipeline per compute entry point
    var first_pipeline_id: u16 = 0;
    var first_bg_id: u16 = 0;

    for (entries, 0..) |entry, ep_idx| {
        if (entry.type != .compute) continue;

        const pipeline_id = e.next_pipeline_id;
        e.next_pipeline_id += 1;
        if (ep_idx == 0) first_pipeline_id = pipeline_id;

        // Build compute pipeline descriptor with specific entry point
        const desc = try buildComputePipelineDescriptor(e, shader_id, entry.name);
        defer e.gpa.free(desc);
        const desc_id = try e.builder.addData(e.gpa, desc);

        try e.builder.getEmitter().createComputePipeline(e.gpa, pipeline_id, desc_id.toInt());

        // Create bind group(s) for first entry point, reuse for others
        var bg_id: u16 = undefined;
        if (ep_idx == 0) {
            bg_id = e.next_bind_group_id;
            first_bg_id = bg_id;
            e.next_bind_group_id += 1;

            // bg_A (phase 0): writes to tex+0, reads prev from tex+1
            const bg_desc = try buildComputeBindGroupDescriptor(e, uniform_buf_id, needs_uniform, output_tex_id, prior_passes, feedback, name, 0);
            defer e.gpa.free(bg_desc);
            const bg_desc_id = try e.builder.addData(e.gpa, bg_desc);

            try e.builder.getEmitter().createBindGroup(e.gpa, bg_id, pipeline_id, bg_desc_id.toInt());

            // bg_B (phase 1): writes to tex+1, reads prev from tex+0
            if (feedback and texture_pool_size > 1) {
                const bg_id_b = e.next_bind_group_id;
                e.next_bind_group_id += 1;

                const bg_desc_b = try buildComputeBindGroupDescriptor(e, uniform_buf_id, needs_uniform, output_tex_id, prior_passes, feedback, name, 1);
                defer e.gpa.free(bg_desc_b);
                const bg_desc_id_b = try e.builder.addData(e.gpa, bg_desc_b);
                try e.builder.getEmitter().createBindGroup(e.gpa, bg_id_b, pipeline_id, bg_desc_id_b.toInt());
            }
        } else {
            // Reuse first bind group (same layout for all entry points in same shader)
            bg_id = first_bg_id;
        }

        // Calculate dispatch size
        const dispatch = getDispatchSize(entry.workgroup_size);

        // Create compute pass definition
        const pass_id = e.next_pass_id;
        e.next_pass_id += 1;
        info.pass_ids[info.pass_count] = pass_id;
        info.pass_count += 1;

        const pass_desc = "{}";
        const pass_desc_id = try e.builder.addData(e.gpa, pass_desc);

        try e.builder.getEmitter().definePass(e.gpa, pass_id, .compute, pass_desc_id.toInt());
        try e.builder.getEmitter().beginComputePass(e.gpa);
        try e.builder.getEmitter().setPipeline(e.gpa, pipeline_id);

        if (feedback and texture_pool_size > 1) {
            try e.builder.getEmitter().setBindGroupPool(e.gpa, 0, bg_id, texture_pool_size, 0);
        } else {
            try e.builder.getEmitter().setBindGroup(e.gpa, 0, bg_id);
        }

        try e.builder.getEmitter().dispatch(e.gpa, dispatch[0], dispatch[1], dispatch[2]);
        try e.builder.getEmitter().endPass(e.gpa);
        try e.builder.getEmitter().endPassDef(e.gpa);
    }
}

/// Calculate dispatch size from workgroup size (Phase 1: fixed reference resolution).
fn getDispatchSize(wg_size: [3]u32) [3]u32 {
    return .{
        (REF_WIDTH + wg_size[0] - 1) / wg_size[0],
        (REF_HEIGHT + wg_size[1] - 1) / wg_size[1],
        if (wg_size[2] > 1) 1 else 1,
    };
}

// ============================================================================
// Blit Pass (auto-generated for compute main)
// ============================================================================

/// Blit shader: samples compute's screen texture → canvas with sRGB.
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

fn emitBlitPass(e: *Emitter, info: *PassInfo, screen_tex_id: u16, sampler_id: u16) Emitter.Error!void {
    const has_pool = info.texture_pool_size > 1;

    // Create blit shader
    const blit_data_id = try e.builder.addData(e.gpa, BLIT_WGSL);
    const blit_shader_id = e.next_shader_id;
    e.next_shader_id += 1;
    _ = try e.builder.addWgsl(e.gpa, blit_data_id.toInt(), &.{});
    try e.builder.getEmitter().createShaderModule(e.gpa, blit_shader_id, blit_data_id.toInt());

    // Create blit render pipeline (renders to canvas, so no explicit target format)
    const blit_pipeline_id = e.next_pipeline_id;
    e.next_pipeline_id += 1;
    const desc = try buildRenderPipelineDescriptor(e, blit_shader_id, null);
    defer e.gpa.free(desc);
    const desc_id = try e.builder.addData(e.gpa, desc);
    try e.builder.getEmitter().createRenderPipeline(e.gpa, blit_pipeline_id, desc_id.toInt());

    // Create blit bind group(s): [tex, sampler]
    // bg_A reads screen_tex_id + 0 (phase 0)
    const blit_bg_id = e.next_bind_group_id;
    e.next_bind_group_id += 1;
    {
        var entries_buf: [2]DescriptorEncoder.BindGroupEntry = undefined;
        entries_buf[0] = .{ .binding = 0, .resource_type = .texture_view, .resource_id = screen_tex_id, .offset = 0, .size = 0 };
        entries_buf[1] = .{ .binding = 1, .resource_type = .sampler, .resource_id = sampler_id, .offset = 0, .size = 0 };
        const bg_desc = try DescriptorEncoder.encodeBindGroupDescriptor(e.gpa, 0, &entries_buf);
        defer e.gpa.free(bg_desc);
        const bg_desc_id = try e.builder.addData(e.gpa, bg_desc);
        try e.builder.getEmitter().createBindGroup(e.gpa, blit_bg_id, blit_pipeline_id, bg_desc_id.toInt());
    }

    // bg_B reads screen_tex_id + 1 (phase 1) — for feedback pool
    if (has_pool) {
        const blit_bg_id_b = e.next_bind_group_id;
        e.next_bind_group_id += 1;
        var entries_buf: [2]DescriptorEncoder.BindGroupEntry = undefined;
        entries_buf[0] = .{ .binding = 0, .resource_type = .texture_view, .resource_id = screen_tex_id + 1, .offset = 0, .size = 0 };
        entries_buf[1] = .{ .binding = 1, .resource_type = .sampler, .resource_id = sampler_id, .offset = 0, .size = 0 };
        const bg_desc_b = try DescriptorEncoder.encodeBindGroupDescriptor(e.gpa, 0, &entries_buf);
        defer e.gpa.free(bg_desc_b);
        const bg_desc_id_b = try e.builder.addData(e.gpa, bg_desc_b);
        try e.builder.getEmitter().createBindGroup(e.gpa, blit_bg_id_b, blit_pipeline_id, bg_desc_id_b.toInt());
    }

    // Create blit render pass
    const blit_pass_id = e.next_pass_id;
    e.next_pass_id += 1;
    info.blit_pass_id = blit_pass_id;

    const pass_desc = "{}";
    const pass_desc_id = try e.builder.addData(e.gpa, pass_desc);
    try e.builder.getEmitter().definePass(e.gpa, blit_pass_id, .render, pass_desc_id.toInt());
    try e.builder.getEmitter().beginRenderPass(e.gpa, CANVAS_TEXTURE_ID, opcodes.LoadOp.clear, opcodes.StoreOp.store, 0xFFFF);
    try e.builder.getEmitter().setPipeline(e.gpa, blit_pipeline_id);

    if (has_pool) {
        try e.builder.getEmitter().setBindGroupPool(e.gpa, 0, blit_bg_id, 2, 0);
    } else {
        try e.builder.getEmitter().setBindGroup(e.gpa, 0, blit_bg_id);
    }

    try e.builder.getEmitter().draw(e.gpa, 3, 1, 0, 0);
    try e.builder.getEmitter().endPass(e.gpa);
    try e.builder.getEmitter().endPassDef(e.gpa);
}

// ============================================================================
// Init Code Emission
// ============================================================================

fn emitInitCode(
    e: *Emitter,
    info: *PassInfo,
    init_code: []const u8,
    uniform_buf_id: u16,
    output_tex_id: u16,
    prior_passes: []const PassInfo,
    feedback: bool,
    name: []const u8,
) Emitter.Error!void {
    const init_scan = wgsl_scan.scanEntryPoints(init_code);
    if (init_scan.count == 0) return;

    // Build prelude for init (compute, never needs sampler)
    // Only include feedback binding if init code actually references prev_<name>
    const init_needs_uniform = std.mem.indexOf(u8, init_code, "pngine") != null;
    const init_needs_feedback = feedback and std.mem.indexOf(u8, init_code, "prev_") != null;
    const prelude = try buildPrelude(e, false, init_needs_uniform, false, prior_passes, init_needs_feedback, name);
    defer e.gpa.free(prelude);

    const full_init = try std.mem.concat(e.gpa, u8, &.{ prelude, init_code });
    defer e.gpa.free(full_init);

    const init_data_id = try e.builder.addData(e.gpa, full_init);
    const init_shader_id = e.next_shader_id;
    e.next_shader_id += 1;
    _ = try e.builder.addWgsl(e.gpa, init_data_id.toInt(), &.{});
    try e.builder.getEmitter().createShaderModule(e.gpa, init_shader_id, init_data_id.toInt());

    const init_entries = init_scan.slice();

    for (init_entries) |entry| {
        if (entry.type != .compute) continue;
        if (info.init_pass_count >= MAX_ENTRY_POINTS_PER_PASS) break;

        // Create pipeline
        const pipeline_id = e.next_pipeline_id;
        e.next_pipeline_id += 1;
        const desc = try buildComputePipelineDescriptor(e, init_shader_id, entry.name);
        defer e.gpa.free(desc);
        const desc_id = try e.builder.addData(e.gpa, desc);
        try e.builder.getEmitter().createComputePipeline(e.gpa, pipeline_id, desc_id.toInt());

        // Create bind group
        const bg_id = e.next_bind_group_id;
        e.next_bind_group_id += 1;
        // Init writes to tex[1] so frame 0 sim (which reads tex[1]) sees the seeded data.
        // Without feedback, there's only one texture, so phase=0 is correct.
        const init_phase: u8 = if (feedback) 1 else 0;
        const bg_desc = try buildComputeBindGroupDescriptor(e, uniform_buf_id, init_needs_uniform, output_tex_id, prior_passes, init_needs_feedback, name, init_phase);
        defer e.gpa.free(bg_desc);
        const bg_desc_id = try e.builder.addData(e.gpa, bg_desc);
        try e.builder.getEmitter().createBindGroup(e.gpa, bg_id, pipeline_id, bg_desc_id.toInt());

        // Create compute pass
        const pass_id = e.next_pass_id;
        e.next_pass_id += 1;
        info.init_pass_ids[info.init_pass_count] = pass_id;
        info.init_pass_count += 1;

        const dispatch = getDispatchSize(entry.workgroup_size);

        const pass_desc = "{}";
        const pass_desc_id = try e.builder.addData(e.gpa, pass_desc);
        try e.builder.getEmitter().definePass(e.gpa, pass_id, .compute, pass_desc_id.toInt());
        try e.builder.getEmitter().beginComputePass(e.gpa);
        try e.builder.getEmitter().setPipeline(e.gpa, pipeline_id);
        try e.builder.getEmitter().setBindGroup(e.gpa, 0, bg_id);
        try e.builder.getEmitter().dispatch(e.gpa, dispatch[0], dispatch[1], dispatch[2]);
        try e.builder.getEmitter().endPass(e.gpa);
        try e.builder.getEmitter().endPassDef(e.gpa);
    }
}

// ============================================================================
// Auto Frame Generation
// ============================================================================

fn emitAutoFrame(e: *Emitter, pass_infos: []const PassInfo) Emitter.Error!void {
    const frame_id = e.next_frame_id;
    e.next_frame_id += 1;

    const name_id = try e.builder.internString(e.gpa, "main");
    try e.builder.getEmitter().defineFrame(e.gpa, frame_id, name_id.toInt());

    // Emit init passes (execPassOnce)
    for (pass_infos) |info| {
        for (0..info.init_pass_count) |i| {
            try e.builder.getEmitter().execPassOnce(e.gpa, info.init_pass_ids[i]);
        }
    }

    // Emit writeTimeUniform for each pass's uniform buffer
    // (uniform buf is always first buffer created per pass, at offset 0)
    // We rely on the frame perform order to handle uniform writes.
    // For now, emit a single writeTimeUniform for the first pass.
    // TODO: In a future iteration, track uniform buffer IDs per pass.

    // Emit per-frame passes
    for (pass_infos) |info| {
        // Write uniforms before passes (only if pass uses pngine uniform)
        if (info.needs_uniform) {
            try e.builder.getEmitter().writeTimeUniform(e.gpa, info.uniform_buf_id, 0, 16);
        }

        for (0..info.pass_count) |i| {
            try e.builder.getEmitter().execPass(e.gpa, info.pass_ids[i]);
        }

        // Blit pass for compute main
        if (info.blit_pass_id) |blit_id| {
            try e.builder.getEmitter().execPass(e.gpa, blit_id);
        }
    }

    try e.builder.getEmitter().submit(e.gpa);
    try e.builder.getEmitter().endFrame(e.gpa);
}

// ============================================================================
// WGSL Prelude Generation
// ============================================================================

/// Build the auto-injected WGSL prelude for a pass.
fn buildPrelude(
    e: *Emitter,
    is_fragment: bool,
    needs_uniform: bool,
    needs_sampler: bool,
    prior_passes: []const PassInfo,
    feedback: bool,
    name: []const u8,
) Emitter.Error![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(e.gpa);

    var next_binding: u32 = 0;

    // Uniform struct (only if shader references pngine)
    if (needs_uniform) {
        try buf.appendSlice(e.gpa,
            \\struct PngineInputs { time: f32, width: f32, height: f32, aspect: f32 }
            \\@group(0) @binding(0) var<uniform> pngine: PngineInputs;
            \\
        );
        next_binding = 1;
    }

    if (is_fragment) {
        // Fragment: sampler at next binding if needed
        if (needs_sampler) {
            var samp_str: [64]u8 = undefined;
            const ss = std.fmt.bufPrint(&samp_str, "@group(0) @binding({d}) var samp: sampler;\n", .{next_binding}) catch unreachable;
            try buf.appendSlice(e.gpa, ss);
            next_binding += 1;
        }

        // Vertex shader (fullscreen triangle)
        try buf.appendSlice(e.gpa,
            \\@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
            \\  let x = f32(i & 1u) * 4.0 - 1.0;
            \\  let y = f32((i >> 1u) & 1u) * 4.0 - 1.0;
            \\  return vec4f(x, y, 0, 1);
            \\}
            \\
        );

        // Dependency textures
        for (prior_passes) |dep| {
            var binding_str: [128]u8 = undefined;
            const s = std.fmt.bufPrint(&binding_str, "@group(0) @binding({d}) var {s}: texture_2d<f32>;\n", .{ next_binding, dep.name }) catch unreachable;
            try buf.appendSlice(e.gpa, s);
            next_binding += 1;
        }

        // Feedback texture
        if (feedback) {
            var binding_str: [128]u8 = undefined;
            const s = std.fmt.bufPrint(&binding_str, "@group(0) @binding({d}) var prev_{s}: texture_2d<f32>;\n", .{ next_binding, name }) catch unreachable;
            try buf.appendSlice(e.gpa, s);
            next_binding += 1;
        }
    } else {
        // Compute: screen texture at next binding
        var screen_str: [80]u8 = undefined;
        const scr = std.fmt.bufPrint(&screen_str, "@group(0) @binding({d}) var screen: texture_storage_2d<rgba8unorm, write>;\n", .{next_binding}) catch unreachable;
        try buf.appendSlice(e.gpa, scr);
        next_binding += 1;

        // Dependency textures
        for (prior_passes) |dep| {
            var binding_str: [128]u8 = undefined;
            const s = std.fmt.bufPrint(&binding_str, "@group(0) @binding({d}) var {s}: texture_2d<f32>;\n", .{ next_binding, dep.name }) catch unreachable;
            try buf.appendSlice(e.gpa, s);
            next_binding += 1;
        }

        // Feedback texture (read from previous frame's screen)
        if (feedback) {
            var binding_str: [128]u8 = undefined;
            const s = std.fmt.bufPrint(&binding_str, "@group(0) @binding({d}) var prev_{s}: texture_2d<f32>;\n", .{ next_binding, name }) catch unreachable;
            try buf.appendSlice(e.gpa, s);
            next_binding += 1;
        }
    }

    return buf.toOwnedSlice(e.gpa);
}

// ============================================================================
// Pipeline Descriptors
// ============================================================================

/// Build render pipeline descriptor (JSON format matching pipelines.zig pattern).
/// `target_format`: null = use canvas format at runtime, otherwise explicit format (e.g. "rgba8unorm").
fn buildRenderPipelineDescriptor(e: *Emitter, shader_id: u16, target_format: ?[]const u8) Emitter.Error![]u8 {
    var json: std.ArrayListUnmanaged(u8) = .{};
    errdefer json.deinit(e.gpa);

    var id_buf: [16]u8 = undefined;
    const shader_str = std.fmt.bufPrint(&id_buf, "{d}", .{shader_id}) catch "0";

    try json.appendSlice(e.gpa, "{\"vertex\":{\"shader\":");
    try json.appendSlice(e.gpa, shader_str);
    try json.appendSlice(e.gpa, ",\"entryPoint\":\"vs\"},\"fragment\":{\"shader\":");
    try json.appendSlice(e.gpa, shader_str);
    try json.appendSlice(e.gpa, ",\"entryPoint\":\"fs\"");

    // Explicit target format for non-canvas render targets (e.g. rgba8unorm)
    if (target_format) |fmt| {
        try json.appendSlice(e.gpa, ",\"targetFormat\":\"");
        try json.appendSlice(e.gpa, fmt);
        try json.appendSlice(e.gpa, "\"");
    }

    try json.appendSlice(e.gpa, "}}");

    const result = try json.toOwnedSlice(e.gpa);
    std.debug.assert(result.len >= 2);
    std.debug.assert(result[0] == '{' and result[result.len - 1] == '}');
    return result;
}

/// Build compute pipeline descriptor (binary format matching gpu.js expectations).
/// Binary format: [type_tag:0x06][shader_id:u16 LE][entry_len:u8][entry_bytes]
fn buildComputePipelineDescriptor(e: *Emitter, shader_id: u16, entry_point: []const u8) Emitter.Error![]u8 {
    const entry_len: u8 = @intCast(@min(entry_point.len, 255));
    const total_len: usize = 1 + 2 + 1 + entry_len;

    const result = try e.gpa.alloc(u8, total_len);
    errdefer e.gpa.free(result);

    result[0] = 0x06; // compute_pipeline type tag
    result[1] = @intCast(shader_id & 0xFF);
    result[2] = @intCast((shader_id >> 8) & 0xFF);
    result[3] = entry_len;
    @memcpy(result[4..][0..entry_len], entry_point[0..entry_len]);

    std.debug.assert(result.len >= 4);
    std.debug.assert(result[0] == 0x06);
    return result;
}

// ============================================================================
// Bind Group Descriptors
// ============================================================================

/// Build bind group descriptor for fragment pass.
/// `feedback_read_tex_id` is the texture to read as feedback (the ping-pong partner).
fn buildBindGroupDescriptor(
    e: *Emitter,
    uniform_buf_id: u16,
    sampler_id: u16,
    needs_uniform: bool,
    needs_sampler: bool,
    prior_passes: []const PassInfo,
    feedback: bool,
    feedback_read_tex_id: u16,
    name: []const u8,
    dep_tex_offset: u8, // 0 for phase A, 1 for phase B — applied to deps with pool > 1
) Emitter.Error![]u8 {
    _ = name;

    var entries: [16]DescriptorEncoder.BindGroupEntry = undefined;
    var count: usize = 0;

    // Binding 0: uniform buffer (only if shader uses pngine)
    if (needs_uniform) {
        entries[count] = .{
            .binding = @intCast(count),
            .resource_type = .buffer,
            .resource_id = uniform_buf_id,
            .offset = 0,
            .size = 0,
        };
        count += 1;
    }

    // Next binding: sampler (only if shader references it)
    if (needs_sampler) {
        entries[count] = .{
            .binding = @intCast(count),
            .resource_type = .sampler,
            .resource_id = sampler_id,
            .offset = 0,
            .size = 0,
        };
        count += 1;
    }

    // Dependency textures — offset by dep_tex_offset for deps with feedback pool
    for (prior_passes) |dep| {
        const dep_id = if (dep.texture_pool_size > 1)
            dep.output_texture_id + dep_tex_offset
        else
            dep.output_texture_id;
        entries[count] = .{
            .binding = @intCast(count),
            .resource_type = .texture_view,
            .resource_id = dep_id,
            .offset = 0,
            .size = 0,
        };
        count += 1;
    }

    // Feedback texture (previous frame's output from ping-pong partner)
    if (feedback) {
        entries[count] = .{
            .binding = @intCast(count),
            .resource_type = .texture_view,
            .resource_id = feedback_read_tex_id,
            .offset = 0,
            .size = 0,
        };
        count += 1;
    }

    return DescriptorEncoder.encodeBindGroupDescriptor(e.gpa, 0, entries[0..count]);
}

/// Build bind group descriptor for compute pass (bg_A: writes to tex+0, reads from tex+1).
/// Build bind group descriptor for compute pass.
/// phase=0 (bg_A): writes to tex+0, reads prev from tex+1, deps at offset 0
/// phase=1 (bg_B): writes to tex+1, reads prev from tex+0, deps at offset 1
fn buildComputeBindGroupDescriptor(
    e: *Emitter,
    uniform_buf_id: u16,
    needs_uniform: bool,
    screen_tex_id: u16,
    prior_passes: []const PassInfo,
    feedback: bool,
    name: []const u8,
    phase: u8,
) Emitter.Error![]u8 {
    _ = name;

    var entries: [16]DescriptorEncoder.BindGroupEntry = undefined;
    var count: usize = 0;

    // Uniform buffer (only if shader references pngine)
    if (needs_uniform) {
        entries[count] = .{
            .binding = @intCast(count),
            .resource_type = .buffer,
            .resource_id = uniform_buf_id,
            .offset = 0,
            .size = 0,
        };
        count += 1;
    }

    // Screen (storage texture for write): phase 0 → tex+0, phase 1 → tex+1
    entries[count] = .{
        .binding = @intCast(count),
        .resource_type = .texture_view,
        .resource_id = screen_tex_id + phase,
        .offset = 0,
        .size = 0,
    };
    count += 1;

    // Dependency textures — offset by phase for deps with feedback pool
    for (prior_passes) |dep| {
        const dep_id = if (dep.texture_pool_size > 1)
            dep.output_texture_id + phase
        else
            dep.output_texture_id;
        entries[count] = .{
            .binding = @intCast(count),
            .resource_type = .texture_view,
            .resource_id = dep_id,
            .offset = 0,
            .size = 0,
        };
        count += 1;
    }

    // Feedback texture: phase 0 reads tex+1, phase 1 reads tex+0
    if (feedback) {
        entries[count] = .{
            .binding = @intCast(count),
            .resource_type = .texture_view,
            .resource_id = screen_tex_id + (1 - phase),
            .offset = 0,
            .size = 0,
        };
        count += 1;
    }

    return DescriptorEncoder.encodeBindGroupDescriptor(e.gpa, 0, entries[0..count]);
}

// ============================================================================
// Texture Emission
// ============================================================================

/// Emit a canvas-sized texture for pass output.
fn emitCanvasTexture(e: *Emitter, tex_id: u16, is_fragment: bool) Emitter.Error!void {
    const usage: DescriptorEncoder.TextureUsage = if (is_fragment)
        .{ .texture_binding = true, .render_attachment = true }
    else
        .{ .texture_binding = true, .storage_binding = true };

    const desc = try DescriptorEncoder.encodeTextureCanvasSize(
        e.gpa,
        .rgba8unorm,
        usage,
        1, // no MSAA
    );
    defer e.gpa.free(desc);

    const desc_data = try e.builder.addData(e.gpa, desc);
    try e.builder.getEmitter().createTexture(e.gpa, tex_id, desc_data.toInt());
}

// ============================================================================
// Sampler
// ============================================================================

/// Ensure a shared linear sampler exists, return its ID.
fn ensureSharedSampler(e: *Emitter) Emitter.Error!u16 {
    // Check if any sampler already exists
    if (e.sampler_ids.count() > 0) {
        // Return the first sampler's ID
        var it = e.sampler_ids.valueIterator();
        return it.next().?.*;
    }

    // Create a shared linear sampler
    const sampler_id = e.next_sampler_id;
    e.next_sampler_id += 1;

    const desc = try DescriptorEncoder.encodeSampler(
        e.gpa,
        .linear,
        .linear,
        .clamp_to_edge,
    );
    defer e.gpa.free(desc);

    const desc_data = try e.builder.addData(e.gpa, desc);
    try e.builder.getEmitter().createSampler(e.gpa, sampler_id, desc_data.toInt());

    return sampler_id;
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Get string content from a property.
fn getStringProperty(e: *Emitter, node: Node.Index, prop_name: []const u8) ?[]const u8 {
    const value_node = utils.findPropertyValue(e, node, prop_name) orelse return null;
    const tag = e.ast.nodes.items(.tag)[value_node.toInt()];
    if (tag != .string_value) return null;
    return utils.getStringContent(e, value_node);
}

/// Get boolean property value.
fn getBoolProperty(e: *Emitter, node: Node.Index, prop_name: []const u8) bool {
    const value_node = utils.findPropertyValue(e, node, prop_name) orelse return false;
    const tag = e.ast.nodes.items(.tag)[value_node.toInt()];
    if (tag != .boolean_value) return false;
    const text = utils.getNodeText(e, value_node);
    return std.mem.eql(u8, text, "true");
}

/// Get clear color from node.
fn getClearColor(e: *Emitter, node: Node.Index) [4]f32 {
    const color_node = utils.findPropertyValue(e, node, "clear") orelse return .{ 0, 0, 0, 1 };
    const tag = e.ast.nodes.items(.tag)[color_node.toInt()];
    if (tag != .array) return .{ 0, 0, 0, 1 };

    var color: [4]f32 = .{ 0, 0, 0, 1 };
    const array_data = e.ast.nodes.items(.data)[color_node.toInt()];
    const elements = e.ast.extraData(array_data.extra_range);

    const max_elements = @min(elements.len, 4);
    for (0..max_elements) |i| {
        const elem: Node.Index = @enumFromInt(elements[i]);
        color[i] = @floatCast(utils.parseFloatNumber(e, elem) orelse 0);
    }
    return color;
}
