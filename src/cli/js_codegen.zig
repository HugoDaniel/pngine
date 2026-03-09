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
const pngine = @import("pngine");
const format = pngine.format;
const mock_gpu = pngine.mock_gpu;
const MockGPU = mock_gpu.MockGPU;
const Call = mock_gpu.Call;
const CallType = mock_gpu.CallType;
const Dispatcher = pngine.Dispatcher;

pub const CodegenResult = struct {
    html: []u8,

    pub fn deinit(self: *CodegenResult, allocator: std.mem.Allocator) void {
        allocator.free(self.html);
    }
};

pub const CodegenError = error{
    InvalidBytecode,
    ExecutionFailed,
    OutOfMemory,
};

/// Generate self-contained HTML with inline WebGPU JavaScript.
/// When `compress` is true, large shaders are deflate-compressed and base64-encoded
/// inline, decompressed at runtime via `atob()` + `DecompressionStream('deflate-raw')`.
/// Multiple large shaders are concatenated with `\0`, compressed as one blob.
pub fn generate(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    width: u32,
    height: u32,
    audio_wasm: ?[]const u8,
    compress: bool,
) CodegenError!CodegenResult {
    // Pre-conditions
    std.debug.assert(width > 0 and height > 0);

    if (bytecode.len < format.HEADER_SIZE or !std.mem.eql(u8, bytecode[0..4], format.MAGIC)) {
        return CodegenError.InvalidBytecode;
    }

    var module = format.deserialize(allocator, bytecode) catch {
        return CodegenError.InvalidBytecode;
    };
    defer module.deinit(allocator);

    // Execute bytecode with MockGPU to capture call sequence
    var gpu: MockGPU = .empty;
    defer gpu.deinit(allocator);

    var dispatcher = Dispatcher(MockGPU).init(allocator, &gpu, &module);
    defer dispatcher.deinit();
    dispatcher.execute_all(allocator) catch {
        return CodegenError.ExecutionFailed;
    };

    const calls = gpu.get_calls();

    // Find split point: last resource creation call index + 1.
    // write_buffer for vertex data can appear between creation calls, so don't break early.
    var split_idx: usize = 0;
    for (calls, 0..) |call, i| {
        switch (call.call_type) {
            .create_buffer, .create_texture, .create_sampler, .create_shader_module, .create_render_pipeline, .create_compute_pipeline, .create_bind_group, .create_texture_view, .create_query_set, .create_bind_group_layout, .create_pipeline_layout, .create_image_bitmap, .create_render_bundle => {
                split_idx = i + 1;
            },
            else => {},
        }
    }

    // Detect animation by scanning raw PNGB bytecode for write_time_uniform opcode (0x2A).
    // MockGPU silently discards write_time_uniform, so we must scan bytecode directly.
    const time_uniform = scanForTimeUniform(module.bytecode);
    const has_animation = time_uniform != null;

    // Build texture format map: texture_id → format string from create_texture calls
    var tex_formats = std.AutoHashMapUnmanaged(u16, []const u8){};
    defer tex_formats.deinit(allocator);
    for (calls) |call| {
        if (call.call_type == .create_texture) {
            const p = call.params.create_texture;
            const data = module.data.get(@enumFromInt(p.descriptor_data_id));
            const fmt = parseTextureFormat(data);
            if (fmt) |f| tex_formats.put(allocator, p.texture_id, f) catch {};
        }
    }

    // Build pipeline→target format map by scanning frame calls:
    // begin_render_pass sets the color texture, then set_pipeline says which pipeline.
    var pipeline_formats = std.AutoHashMapUnmanaged(u16, []const u8){};
    defer pipeline_formats.deinit(allocator);
    {
        var current_color_tex: u16 = 0xFFFE;
        for (calls[split_idx..]) |call| {
            switch (call.call_type) {
                .begin_render_pass => {
                    current_color_tex = call.params.begin_render_pass.color_texture_id;
                },
                .set_pipeline => {
                    if (current_color_tex != 0xFFFE) {
                        if (tex_formats.get(current_color_tex)) |fmt| {
                            pipeline_formats.put(allocator, call.params.set_pipeline.pipeline_id, fmt) catch {};
                        }
                    }
                },
                else => {},
            }
        }
    }

    // Collect depth texture IDs that are never referenced by any render pass.
    // These can be skipped entirely from the output.
    var skip_textures = std.AutoHashMapUnmanaged(u16, void){};
    defer skip_textures.deinit(allocator);
    {
        // Mark all depth-format textures as candidates for skipping
        for (calls) |call| {
            if (call.call_type == .create_texture) {
                const p = call.params.create_texture;
                if (tex_formats.get(p.texture_id)) |fmt| {
                    if (std.mem.startsWith(u8, fmt, "depth")) {
                        skip_textures.put(allocator, p.texture_id, {}) catch {};
                    }
                }
            }
        }
        // Un-skip any depth texture actually used by a render pass
        for (calls) |call| {
            if (call.call_type == .begin_render_pass) {
                const dtid = call.params.begin_render_pass.depth_texture_id;
                if (dtid != 0xFFFF) _ = skip_textures.fetchRemove(dtid);
            }
        }
    }

    // --- Compress & concat: collect large shaders, deflate+base64 inline ---
    var concat_shaders = std.ArrayListUnmanaged([]u8){};
    defer {
        for (concat_shaders.items) |s| allocator.free(s);
        concat_shaders.deinit(allocator);
    }
    var shader_w_map = std.AutoHashMapUnmanaged(u16, u16){};
    defer shader_w_map.deinit(allocator);
    var concat_b64: ?[]u8 = null;
    defer if (concat_b64) |cb| allocator.free(cb);
    var use_concat = false;

    if (compress) {
        for (calls) |call| {
            if (call.call_type == .create_shader_module) {
                const p = call.params.create_shader_module;
                const wgsl = resolveWgslCode(allocator, p.code_data_id, &module) catch continue;
                const stripped = stripWgslWhitespace(allocator, wgsl) catch {
                    allocator.free(wgsl);
                    continue;
                };
                allocator.free(wgsl);
                // Only collect shaders large enough for compression to help
                if (stripped.len <= 512) {
                    allocator.free(stripped);
                    continue;
                }
                shader_w_map.put(allocator, p.shader_id, @intCast(concat_shaders.items.len)) catch {
                    allocator.free(stripped);
                    continue;
                };
                concat_shaders.append(allocator, stripped) catch {
                    allocator.free(stripped);
                    continue;
                };
            }
        }
        if (concat_shaders.items.len > 0) {
            var total_raw: usize = 0;
            for (concat_shaders.items, 0..) |s, i| {
                if (i > 0) total_raw += 1;
                total_raw += s.len;
            }
            const concat = allocator.alloc(u8, total_raw) catch null;
            if (concat) |buf| {
                defer allocator.free(buf);
                var pos: usize = 0;
                for (concat_shaders.items, 0..) |s, i| {
                    if (i > 0) {
                        buf[pos] = 0;
                        pos += 1;
                    }
                    @memcpy(buf[pos..][0..s.len], s);
                    pos += s.len;
                }
                if (deflateCompress(allocator, buf)) |compressed| {
                    defer allocator.free(compressed);
                    // base64 size = ceil(compressed.len * 4/3)
                    const b64_size = (compressed.len + 2) / 3 * 4;
                    // D() helper ~148B + call overhead ~20B per shader
                    const overhead: usize = 148 + concat_shaders.items.len * 20;
                    if (b64_size + overhead < total_raw) {
                        var b64 = std.ArrayListUnmanaged(u8){};
                        base64Append(&b64, allocator, compressed) catch {};
                        if (b64.items.len > 0) {
                            concat_b64 = b64.toOwnedSlice(allocator) catch null;
                            if (concat_b64 != null) use_concat = true;
                        }
                        if (!use_concat) b64.deinit(allocator);
                    }
                } else |_| {}
            }
        }
    }

    // Build JS output
    var js = std.ArrayListUnmanaged(u8){};
    defer js.deinit(allocator);

    var data_map = std.AutoHashMapUnmanaged(u16, u32){};
    defer data_map.deinit(allocator);

    var used_compression = false;

    // Emit init calls
    var pass_idx: u16 = 0;
    var submit_start: u16 = 0;
    for (calls[0..split_idx]) |call| {
        // Skip unused depth textures
        if (call.call_type == .create_texture) {
            if (skip_textures.get(call.params.create_texture.texture_id) != null) continue;
        }
        // Concat mode: emit shader module with W[i] or await D('...') reference
        if (use_concat and call.call_type == .create_shader_module) {
            const p = call.params.create_shader_module;
            if (shader_w_map.get(p.shader_id)) |w_idx| {
                try js.appendSlice(allocator, "const s");
                try appendInt(&js, allocator, p.shader_id);
                if (concat_shaders.items.len == 1) {
                    try js.appendSlice(allocator, "=d.createShaderModule({code:await D('");
                    try js.appendSlice(allocator, concat_b64.?);
                    try js.appendSlice(allocator, "')});");
                } else {
                    try js.appendSlice(allocator, "=d.createShaderModule({code:W[");
                    try appendInt(&js, allocator, w_idx);
                    try js.appendSlice(allocator, "]});");
                }
                continue;
            }
        }
        try emitCall(allocator, &js, call, &module, &data_map, false, &pass_idx, &submit_start, &pipeline_formats, compress and !use_concat, &used_compression);
    }

    // Emit frame calls
    var frame_js = std.ArrayListUnmanaged(u8){};
    defer frame_js.deinit(allocator);

    // If animated, emit write_time_uniform for ALL uniform buffers
    const all_time_uniforms = scanAllTimeUniforms(module.bytecode);
    for (all_time_uniforms.items[0..all_time_uniforms.count]) |tu| {
        try frame_js.appendSlice(allocator, "d.queue.writeBuffer(b");
        try appendInt(&frame_js, allocator, tu.buffer_id);
        try frame_js.appendSlice(allocator, ",0,new Float32Array([t,");
        try appendInt(&frame_js, allocator, width);
        try frame_js.appendSlice(allocator, ",");
        try appendInt(&frame_js, allocator, height);
        try frame_js.appendSlice(allocator, ",");
        try appendInt(&frame_js, allocator, width);
        try frame_js.appendSlice(allocator, "/");
        try appendInt(&frame_js, allocator, height);
        try frame_js.appendSlice(allocator, "]));");
    }

    pass_idx = 0;
    submit_start = 0;
    for (calls[split_idx..]) |call| {
        try emitCall(allocator, &frame_js, call, &module, &data_map, true, &pass_idx, &submit_start, &pipeline_formats, compress, &used_compression);
    }

    // Build complete HTML
    var html = std.ArrayListUnmanaged(u8){};
    errdefer html.deinit(allocator);

    // HTML boilerplate
    try html.appendSlice(allocator, "<!DOCTYPE html><meta charset=utf-8><style>*{margin:0}body{background:#000;overflow:hidden;display:grid;place-items:center;height:100vh}</style><canvas id=c width=");
    try appendInt(&html, allocator, width);
    try html.appendSlice(allocator, " height=");
    try appendInt(&html, allocator, height);
    try html.appendSlice(allocator, "></canvas><script type=module>\n");

    // WebGPU init
    try html.appendSlice(allocator, "const a=await navigator.gpu.requestAdapter(),d=await a.requestDevice(),x=c.getContext('webgpu'),f=navigator.gpu.getPreferredCanvasFormat();x.configure({device:d,format:f});");

    // Decompression helper: atob → Uint8Array → DecompressionStream
    if (use_concat or used_compression) {
        try html.appendSlice(allocator, "let D=s=>new Response(new Blob([Uint8Array.from(atob(s),c=>c.charCodeAt(0))]).stream().pipeThrough(new DecompressionStream('deflate-raw'))).text();");
        if (use_concat and concat_shaders.items.len > 1) {
            try html.appendSlice(allocator, "let W=(await D('");
            try html.appendSlice(allocator, concat_b64.?);
            try html.appendSlice(allocator, "')).split('\\0');");
        }
    }

    // Init section
    try html.appendSlice(allocator, js.items);

    if (has_animation) {
        // Audio setup (before frame function)
        if (audio_wasm) |aw| {
            try emitAudioSetup(&html, allocator, aw);
        }

        // Animated: click-to-play with rAF loop (onclick=null prevents double-start)
        try html.appendSlice(allocator, "let t0;function F(){const t=(performance.now()-t0)/1e3;");
        try html.appendSlice(allocator, frame_js.items);
        try html.appendSlice(allocator, "requestAnimationFrame(F)}c.onclick=()=>{t0=performance.now();");
        if (audio_wasm != null) {
            try html.appendSlice(allocator, "if(ax){if(ax.state=='suspended')ax.resume();sr=ax.createBufferSource();sr.buffer=ab;sr.connect(ax.destination);sr.start(0,0)}");
        }
        try html.appendSlice(allocator, "F();c.onclick=0}");
    } else {
        // Static: just run frame once
        try html.appendSlice(allocator, frame_js.items);
    }

    try html.appendSlice(allocator, "</script>\n");

    const result = html.toOwnedSlice(allocator) catch return CodegenError.OutOfMemory;

    return CodegenResult{ .html = result };
}

/// Emit a single MockGPU call as JavaScript.
fn emitCall(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    call: Call,
    module: *const format.Module,
    data_map: *std.AutoHashMapUnmanaged(u16, u32),
    _: bool,
    pass_idx: *u16,
    submit_start: *u16,
    pipeline_formats: *const std.AutoHashMapUnmanaged(u16, []const u8),
    do_compress: bool,
    used_compression: *bool,
) !void {
    _ = data_map;
    switch (call.call_type) {
        .create_shader_module => {
            const p = call.params.create_shader_module;
            const wgsl = resolveWgslCode(allocator, p.code_data_id, module) catch return;
            defer allocator.free(wgsl);

            // Measure raw WGSL size (after whitespace stripping)
            var raw_size: usize = 0;
            {
                var it = std.mem.splitScalar(u8, wgsl, '\n');
                var first = true;
                while (it.next()) |line| {
                    const trimmed = std.mem.trimStart(u8, line, " \t");
                    if (trimmed.len == 0) continue;
                    if (!first) raw_size += 1; // newline
                    first = false;
                    raw_size += trimmed.len;
                }
            }

            // Try compression for shaders > 512B when enabled
            var compressed_emitted = false;
            if (do_compress and raw_size > 512) {
                const stripped_wgsl = stripWgslWhitespace(allocator, wgsl) catch null;
                if (stripped_wgsl) |sw| {
                    defer allocator.free(sw);
                    if (deflateCompress(allocator, sw)) |compressed| {
                        defer allocator.free(compressed);
                        var b64 = std.ArrayListUnmanaged(u8){};
                        defer b64.deinit(allocator);
                        base64Append(&b64, allocator, compressed) catch {};
                        // await D('...') + overhead = ~20B
                        if (b64.items.len > 0 and b64.items.len + 20 < raw_size) {
                            try out.appendSlice(allocator, "const s");
                            try appendInt(out, allocator, p.shader_id);
                            try out.appendSlice(allocator, "=d.createShaderModule({code:await D('");
                            try out.appendSlice(allocator, b64.items);
                            try out.appendSlice(allocator, "')});");
                            used_compression.* = true;
                            compressed_emitted = true;
                        }
                    } else |_| {}
                }
            }

            if (!compressed_emitted) {
                try out.appendSlice(allocator, "const s");
                try appendInt(out, allocator, p.shader_id);
                try out.appendSlice(allocator, "=d.createShaderModule({code:`");
                try appendEscapedWgsl(out, allocator, wgsl);
                try out.appendSlice(allocator, "`});");
            }
        },
        .create_buffer => {
            const p = call.params.create_buffer;
            try out.appendSlice(allocator, "const b");
            try appendInt(out, allocator, p.buffer_id);
            try out.appendSlice(allocator, "=d.createBuffer({size:");
            try appendInt(out, allocator, p.size);
            try out.appendSlice(allocator, ",usage:");
            try appendInt(out, allocator, p.usage);
            try out.appendSlice(allocator, "});");
        },
        .create_render_pipeline => {
            const p = call.params.create_render_pipeline;
            const data = module.data.get(@enumFromInt(p.descriptor_data_id));
            const target_fmt = pipeline_formats.get(p.pipeline_id);
            try out.appendSlice(allocator, "const p");
            try appendInt(out, allocator, p.pipeline_id);
            try out.appendSlice(allocator, "=d.createRenderPipeline(");
            try emitRenderPipelineDesc(out, allocator, data, target_fmt);
            try out.appendSlice(allocator, ");");
        },
        .create_compute_pipeline => {
            const p = call.params.create_compute_pipeline;
            const data = module.data.get(@enumFromInt(p.descriptor_data_id));
            try out.appendSlice(allocator, "const p");
            try appendInt(out, allocator, p.pipeline_id);
            try out.appendSlice(allocator, "=d.createComputePipeline(");
            try emitComputePipelineDesc(out, allocator, data);
            try out.appendSlice(allocator, ");");
        },
        .create_bind_group => {
            const p = call.params.create_bind_group;
            const data = module.data.get(@enumFromInt(p.entry_data_id));
            try out.appendSlice(allocator, "const g");
            try appendInt(out, allocator, p.group_id);
            try out.appendSlice(allocator, "=d.createBindGroup(");
            try emitBindGroupDesc(out, allocator, data, p.layout_id);
            try out.appendSlice(allocator, ");");
        },
        .create_texture => {
            const p = call.params.create_texture;
            const data = module.data.get(@enumFromInt(p.descriptor_data_id));
            try out.appendSlice(allocator, "const T");
            try appendInt(out, allocator, p.texture_id);
            try out.appendSlice(allocator, "=d.createTexture(");
            try emitTextureDesc(out, allocator, data);
            try out.appendSlice(allocator, ");");
        },
        .create_sampler => {
            const p = call.params.create_sampler;
            const data = module.data.get(@enumFromInt(p.descriptor_data_id));
            try out.appendSlice(allocator, "const m");
            try appendInt(out, allocator, p.sampler_id);
            try out.appendSlice(allocator, "=d.createSampler(");
            try emitSamplerDesc(out, allocator, data);
            try out.appendSlice(allocator, ");");
        },
        .create_texture_view => {
            const p = call.params.create_texture_view;
            try out.appendSlice(allocator, "const V");
            try appendInt(out, allocator, p.view_id);
            try out.appendSlice(allocator, "=T");
            try appendInt(out, allocator, p.texture_id);
            try out.appendSlice(allocator, ".createView();");
        },
        .begin_render_pass => {
            const p = call.params.begin_render_pass;
            const pi = pass_idx.*;
            pass_idx.* += 1;
            const load_str: []const u8 = if (p.load_op == 1) "clear" else "load";
            const store_str: []const u8 = if (p.store_op == 0) "store" else "discard";

            // Encoder + pass with indexed names: e0/r0, e1/r1, ...
            try out.appendSlice(allocator, "const e");
            try appendInt(out, allocator, pi);
            try out.appendSlice(allocator, "=d.createCommandEncoder(),r");
            try appendInt(out, allocator, pi);
            try out.appendSlice(allocator, "=e");
            try appendInt(out, allocator, pi);
            try out.appendSlice(allocator, ".beginRenderPass({colorAttachments:[{view:");

            // Color target: 0xFFFE = canvas/surface, otherwise texture
            if (p.color_texture_id == 0xFFFE) {
                try out.appendSlice(allocator, "x.getCurrentTexture().createView()");
            } else {
                try out.appendSlice(allocator, "T");
                try appendInt(out, allocator, p.color_texture_id);
                try out.appendSlice(allocator, ".createView()");
            }

            try out.appendSlice(allocator, ",loadOp:'");
            try out.appendSlice(allocator, load_str);
            try out.appendSlice(allocator, "',storeOp:'");
            try out.appendSlice(allocator, store_str);
            try out.appendSlice(allocator, "',clearValue:[0,0,0,1]}]");

            // Depth stencil attachment (0xFFFF = no depth)
            if (p.depth_texture_id != 0xFFFF) {
                try out.appendSlice(allocator, ",depthStencilAttachment:{view:T");
                try appendInt(out, allocator, p.depth_texture_id);
                try out.appendSlice(allocator, ".createView(),depthClearValue:1,depthLoadOp:'clear',depthStoreOp:'store'}");
            }

            try out.appendSlice(allocator, "});");
        },
        .begin_compute_pass => {
            const pi = pass_idx.*;
            pass_idx.* += 1;
            try out.appendSlice(allocator, "const e");
            try appendInt(out, allocator, pi);
            try out.appendSlice(allocator, "=d.createCommandEncoder(),r");
            try appendInt(out, allocator, pi);
            try out.appendSlice(allocator, "=e");
            try appendInt(out, allocator, pi);
            try out.appendSlice(allocator, ".beginComputePass();");
        },
        .set_pipeline => {
            const p = call.params.set_pipeline;
            try out.appendSlice(allocator, "r");
            try appendInt(out, allocator, pass_idx.* -| 1);
            try out.appendSlice(allocator, ".setPipeline(p");
            try appendInt(out, allocator, p.pipeline_id);
            try out.appendSlice(allocator, ");");
        },
        .set_bind_group => {
            const p = call.params.set_bind_group;
            try out.appendSlice(allocator, "r");
            try appendInt(out, allocator, pass_idx.* -| 1);
            try out.appendSlice(allocator, ".setBindGroup(");
            try appendInt(out, allocator, p.slot);
            try out.appendSlice(allocator, ",g");
            try appendInt(out, allocator, p.group_id);
            try out.appendSlice(allocator, ");");
        },
        .set_vertex_buffer => {
            const p = call.params.set_vertex_buffer;
            try out.appendSlice(allocator, "r");
            try appendInt(out, allocator, pass_idx.* -| 1);
            try out.appendSlice(allocator, ".setVertexBuffer(");
            try appendInt(out, allocator, p.slot);
            try out.appendSlice(allocator, ",b");
            try appendInt(out, allocator, p.buffer_id);
            try out.appendSlice(allocator, ");");
        },
        .set_index_buffer => {
            const p = call.params.set_index_buffer;
            try out.appendSlice(allocator, "r");
            try appendInt(out, allocator, pass_idx.* -| 1);
            try out.appendSlice(allocator, ".setIndexBuffer(b");
            try appendInt(out, allocator, p.buffer_id);
            try out.appendSlice(allocator, ",'");
            try out.appendSlice(allocator, if (p.index_format == 0) "uint16" else "uint32");
            try out.appendSlice(allocator, "');");
        },
        .draw => {
            const p = call.params.draw;
            try out.appendSlice(allocator, "r");
            try appendInt(out, allocator, pass_idx.* -| 1);
            try out.appendSlice(allocator, ".draw(");
            try appendInt(out, allocator, p.vertex_count);
            if (p.instance_count != 1 or p.first_vertex != 0 or p.first_instance != 0) {
                try out.appendSlice(allocator, ",");
                try appendInt(out, allocator, p.instance_count);
                if (p.first_vertex != 0 or p.first_instance != 0) {
                    try out.appendSlice(allocator, ",");
                    try appendInt(out, allocator, p.first_vertex);
                    if (p.first_instance != 0) {
                        try out.appendSlice(allocator, ",");
                        try appendInt(out, allocator, p.first_instance);
                    }
                }
            }
            try out.appendSlice(allocator, ");");
        },
        .draw_indexed => {
            const p = call.params.draw_indexed;
            try out.appendSlice(allocator, "r");
            try appendInt(out, allocator, pass_idx.* -| 1);
            try out.appendSlice(allocator, ".drawIndexed(");
            try appendInt(out, allocator, p.index_count);
            if (p.instance_count != 1 or p.first_index != 0 or p.base_vertex != 0 or p.first_instance != 0) {
                try out.appendSlice(allocator, ",");
                try appendInt(out, allocator, p.instance_count);
            }
            try out.appendSlice(allocator, ");");
        },
        .dispatch => {
            const p = call.params.dispatch;
            try out.appendSlice(allocator, "r");
            try appendInt(out, allocator, pass_idx.* -| 1);
            try out.appendSlice(allocator, ".dispatchWorkgroups(");
            try appendInt(out, allocator, p.x);
            try out.appendSlice(allocator, ",");
            try appendInt(out, allocator, p.y);
            try out.appendSlice(allocator, ",");
            try appendInt(out, allocator, p.z);
            try out.appendSlice(allocator, ");");
        },
        .end_pass => {
            try out.appendSlice(allocator, "r");
            try appendInt(out, allocator, pass_idx.* -| 1);
            try out.appendSlice(allocator, ".end();");
        },
        .submit => {
            // Submit all encoders since the last submit
            try out.appendSlice(allocator, "d.queue.submit([");
            var i = submit_start.*;
            while (i < pass_idx.*) : (i += 1) {
                if (i > submit_start.*) try out.appendSlice(allocator, ",");
                try out.appendSlice(allocator, "e");
                try appendInt(out, allocator, i);
                try out.appendSlice(allocator, ".finish()");
            }
            try out.appendSlice(allocator, "]);");
            submit_start.* = pass_idx.*;
        },
        .write_buffer => {
            // Static data write (vertex data, etc.) - inline the data as a typed array
            const p = call.params.write_buffer;
            const data = module.data.get(@enumFromInt(p.data_id));
            if (data.len > 0) {
                try out.appendSlice(allocator, "d.queue.writeBuffer(b");
                try appendInt(out, allocator, p.buffer_id);
                try out.appendSlice(allocator, ",");
                try appendInt(out, allocator, p.offset);
                try out.appendSlice(allocator, ",new Float32Array([");
                // Emit data as float32 values (compact: .5 instead of 0.5)
                const float_count = data.len / 4;
                for (0..float_count) |fi| {
                    if (fi > 0) try out.appendSlice(allocator, ",");
                    const bytes = data[fi * 4 ..][0..4];
                    const val: f32 = @bitCast(bytes.*);
                    try appendCompactFloat(out, allocator, val);
                }
                try out.appendSlice(allocator, "]));");
            }
        },
        // Unsupported - skip
        .create_query_set, .create_bind_group_layout, .create_pipeline_layout, .create_image_bitmap, .create_render_bundle, .execute_bundles, .copy_external_image_to_texture, .init_wasm_module, .call_wasm_func, .write_buffer_from_wasm => {},
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

/// Scan PNGB bytecode for all write_time_uniform opcodes (0x2A).
/// Returns the count of unique occurrences found (up to MAX_TIME_UNIFORMS).
const MAX_TIME_UNIFORMS = 16;
const TimeUniformScanResult = struct { items: [MAX_TIME_UNIFORMS]TimeUniformInfo, count: u8 };

fn scanAllTimeUniforms(bytecode: []const u8) TimeUniformScanResult {
    const OPCODE: u8 = 0x2A; // write_time_uniform
    var result: TimeUniformScanResult = .{ .items = undefined, .count = 0 };

    for (0..bytecode.len) |i| {
        if (bytecode[i] == OPCODE and i + 1 < bytecode.len) {
            const rest = bytecode[i + 1 ..];
            if (rest.len < 3) continue;

            const r1 = decodeVarint(rest);
            if (r1.len == 0) continue;
            const r2 = decodeVarint(rest[r1.len..]);
            if (r2.len == 0) continue;
            const r3 = decodeVarint(rest[r1.len + r2.len ..]);
            if (r3.len == 0) continue;

            // Sanity check: buffer_id should be small, size should be 12 or 16
            if (r1.value < 256 and (r3.value == 12 or r3.value == 16)) {
                const info = TimeUniformInfo{
                    .buffer_id = @intCast(r1.value),
                    .offset = r2.value,
                    .size = @intCast(r3.value),
                };
                // Deduplicate by buffer_id
                var dup = false;
                for (result.items[0..result.count]) |existing| {
                    if (existing.buffer_id == info.buffer_id) { dup = true; break; }
                }
                if (!dup and result.count < MAX_TIME_UNIFORMS) {
                    result.items[result.count] = info;
                    result.count += 1;
                }
            }
        }
    }
    return result;
}

/// Backward-compatible wrapper: returns first time uniform or null.
fn scanForTimeUniform(bytecode: []const u8) ?TimeUniformInfo {
    const result = scanAllTimeUniforms(bytecode);
    if (result.count > 0) return result.items[0];
    return null;
}

/// Decode a varint from buffer (same encoding as opcodes.decode_varint).
fn decodeVarint(buf: []const u8) struct { value: u32, len: u8 } {
    if (buf.len == 0) return .{ .value = 0, .len = 0 };
    const first = buf[0];
    if (first & 0x80 == 0) {
        return .{ .value = first, .len = 1 };
    } else if (first & 0xC0 == 0x80) {
        if (buf.len < 2) return .{ .value = 0, .len = 0 };
        return .{ .value = (@as(u32, first & 0x3F) << 8) | buf[1], .len = 2 };
    } else {
        if (buf.len < 4) return .{ .value = 0, .len = 0 };
        return .{ .value = (@as(u32, first & 0x3F) << 24) | (@as(u32, buf[1]) << 16) | (@as(u32, buf[2]) << 8) | buf[3], .len = 4 };
    }
}

// ============================================================================
// Descriptor emission helpers
// ============================================================================

/// Emit render pipeline descriptor from JSON data.
fn emitRenderPipelineDesc(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, data: []const u8, override_format: ?[]const u8) !void {
    // Data is JSON like: {"vertex":{"shader":0,"entryPoint":"vs"},"fragment":{"shader":0,"entryPoint":"fs"},...}
    // We need to replace "shader":N with actual sN references and add layout:'auto' + format
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
        // Fallback: emit raw JSON wrapped
        try out.appendSlice(allocator, "JSON.parse('");
        try out.appendSlice(allocator, data);
        try out.appendSlice(allocator, "')");
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    const obj = switch (root) {
        .object => |o| o,
        else => return,
    };

    try out.appendSlice(allocator, "{layout:'auto',vertex:{module:s");

    // Vertex shader
    const vertex = obj.get("vertex");
    var vs_id: u16 = 0;
    if (vertex) |v| {
        if (v == .object) {
            if (v.object.get("shader")) |s| {
                if (s == .integer) vs_id = @as(u16, @intCast(s.integer));
            }
        }
    }
    try appendInt(out, allocator, vs_id);

    // Vertex buffers
    if (vertex) |v| {
        if (v == .object) {
            if (v.object.get("buffers")) |b| {
                if (b == .array and b.array.items.len > 0) {
                    try out.appendSlice(allocator, ",buffers:");
                    try emitJsonValue(out, allocator, b);
                }
            }
        }
    }

    try out.appendSlice(allocator, "},fragment:{module:s");

    // Fragment shader
    const fragment = obj.get("fragment");
    var fs_id: u16 = 0;
    var target_format: ?[]const u8 = null;
    if (fragment) |f| {
        if (f == .object) {
            if (f.object.get("shader")) |s| {
                if (s == .integer) fs_id = @as(u16, @intCast(s.integer));
            }
            if (f.object.get("targetFormat")) |tf| {
                if (tf == .string) target_format = tf.string;
            }
        }
    } else {
        fs_id = vs_id;
    }
    try appendInt(out, allocator, fs_id);
    // Format priority: override (from render pass target) > JSON descriptor > canvas
    const effective_format = override_format orelse target_format;
    if (effective_format) |fmt| {
        try out.appendSlice(allocator, ",targets:[{format:'");
        try out.appendSlice(allocator, fmt);
        try out.appendSlice(allocator, "'}]}");
    } else {
        try out.appendSlice(allocator, ",targets:[{format:f}]}");
    }

    // Primitive — omit entirely when all defaults (topology=triangle-list, cullMode=none)
    const primitive = obj.get("primitive");
    if (primitive) |prim| {
        if (prim == .object) {
            const topo = prim.object.get("topology");
            const topo_str = if (topo != null and topo.? == .string) topo.?.string else "triangle-list";
            const is_default_topo = std.mem.eql(u8, topo_str, "triangle-list");

            const ff = prim.object.get("frontFace");
            const cm = prim.object.get("cullMode");
            const has_ff = ff != null and ff.? == .string;
            const has_cm = cm != null and cm.? == .string;

            if (!is_default_topo or has_ff or has_cm) {
                try out.appendSlice(allocator, ",primitive:{");
                var prim_first = true;
                if (!is_default_topo) {
                    try out.appendSlice(allocator, "topology:'");
                    try out.appendSlice(allocator, topo_str);
                    try out.appendSlice(allocator, "'");
                    prim_first = false;
                }
                if (has_ff) {
                    if (!prim_first) try out.appendSlice(allocator, ",");
                    try out.appendSlice(allocator, "frontFace:'");
                    try out.appendSlice(allocator, ff.?.string);
                    try out.appendSlice(allocator, "'");
                    prim_first = false;
                }
                if (has_cm) {
                    if (!prim_first) try out.appendSlice(allocator, ",");
                    try out.appendSlice(allocator, "cullMode:'");
                    try out.appendSlice(allocator, cm.?.string);
                    try out.appendSlice(allocator, "'");
                }
                try out.appendSlice(allocator, "}");
            }
        }
    }

    // Depth stencil
    if (obj.get("depthStencil")) |ds| {
        if (ds == .object) {
            try out.appendSlice(allocator, ",depthStencil:");
            try emitJsonValue(out, allocator, ds);
        }
    }

    try out.appendSlice(allocator, "}");
}

/// Emit compute pipeline descriptor from JSON data.
fn emitComputePipelineDesc(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    // Binary format: [type_tag:0x06][shader_id:u16 LE][entry_len:u8][entry_bytes]
    if (data.len >= 4 and data[0] == 0x06) {
        const shader_id: u16 = @as(u16, data[1]) | (@as(u16, data[2]) << 8);
        const entry_len = data[3];
        const has_entry = entry_len > 0 and data.len >= 4 + entry_len;
        const entry_point = if (has_entry) data[4 .. 4 + entry_len] else "main";

        try out.appendSlice(allocator, "{layout:'auto',compute:{module:s");
        try appendInt(out, allocator, shader_id);
        if (!std.mem.eql(u8, entry_point, "main")) {
            try out.appendSlice(allocator, ",entryPoint:'");
            try out.appendSlice(allocator, entry_point);
            try out.appendSlice(allocator, "'");
        }
        try out.appendSlice(allocator, "}}");
        return;
    }

    // Fallback: try JSON (legacy/manual descriptors)
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
        try out.appendSlice(allocator, "{layout:'auto',compute:{module:s0}}");
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    const obj = switch (root) {
        .object => |o| o,
        else => return,
    };

    var cs_id: u16 = 0;

    if (obj.get("compute")) |comp| {
        if (comp == .object) {
            if (comp.object.get("shader")) |s| {
                if (s == .integer) cs_id = @as(u16, @intCast(s.integer));
            }
        }
    }

    try out.appendSlice(allocator, "{layout:'auto',compute:{module:s");
    try appendInt(out, allocator, cs_id);
    try out.appendSlice(allocator, "}}");
}

/// Emit bind group descriptor from binary data.
fn emitBindGroupDesc(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, data: []const u8, layout_id: u16) !void {
    // Binary format: [type_tag:u8][field_count:u8] then fields
    // field_id=0x01 (layout): [0x01][0x07][group_index:u8]
    // field_id=0x02 (entries): [0x02][0x03][count:u8] then per entry:
    //   [binding:u8][resource_type:u8][resource_id:u16 LE]
    //   if buffer: +[offset:u32 LE][size:u32 LE]

    if (data.len < 2) return;

    var q: usize = 2; // skip type_tag + field_count
    var group_index: u8 = 0;
    const field_count = data[1];

    // First pass: find group_index
    var tmp_q: usize = 2;
    for (0..field_count) |_| {
        if (tmp_q + 2 > data.len) break;
        const fi = data[tmp_q];
        const vt = data[tmp_q + 1];
        tmp_q += 2;
        if (fi == 0x01 and vt == 0x07) {
            // layout field: group_index
            if (tmp_q < data.len) {
                group_index = data[tmp_q];
                tmp_q += 1;
            }
        } else if (fi == 0x02 and vt == 0x03) {
            // entries array - skip for now
            if (tmp_q < data.len) {
                var ec = data[tmp_q];
                tmp_q += 1;
                while (ec > 0) : (ec -= 1) {
                    if (tmp_q + 4 > data.len) break;
                    const rt = data[tmp_q + 1];
                    tmp_q += 4; // binding + resource_type + resource_id(u16)
                    if (rt == 0x00) tmp_q += 8; // buffer: offset + size
                }
            }
        }
    }

    try out.appendSlice(allocator, "{layout:p");
    try appendInt(out, allocator, layout_id);
    try out.appendSlice(allocator, ".getBindGroupLayout(");
    try appendInt(out, allocator, group_index);
    try out.appendSlice(allocator, "),entries:[");

    // Second pass: emit entries
    q = 2;
    var first_entry = true;
    for (0..field_count) |_| {
        if (q + 2 > data.len) break;
        const fi = data[q];
        const vt = data[q + 1];
        q += 2;
        if (fi == 0x01 and vt == 0x07) {
            q += 1; // skip group_index
        } else if (fi == 0x02 and vt == 0x03) {
            if (q >= data.len) break;
            var ec = data[q];
            q += 1;
            while (ec > 0) : (ec -= 1) {
                if (q + 4 > data.len) break;
                const binding = data[q];
                const rt = data[q + 1];
                const ri = std.mem.readInt(u16, data[q + 2 ..][0..2], .little);
                q += 4;

                if (!first_entry) try out.appendSlice(allocator, ",");
                first_entry = false;

                try out.appendSlice(allocator, "{binding:");
                try appendInt(out, allocator, binding);
                try out.appendSlice(allocator, ",resource:");

                if (rt == 0x00) {
                    // buffer
                    try out.appendSlice(allocator, "{buffer:b");
                    try appendInt(out, allocator, ri);
                    try out.appendSlice(allocator, "}");
                    q += 8; // skip offset + size
                } else if (rt == 0x02) {
                    // sampler
                    try out.appendSlice(allocator, "m");
                    try appendInt(out, allocator, ri);
                } else if (rt == 0x03 or rt == 0x01) {
                    // texture_view
                    try out.appendSlice(allocator, "T");
                    try appendInt(out, allocator, ri);
                    try out.appendSlice(allocator, ".createView()");
                }

                try out.appendSlice(allocator, "}");
            }
        }
    }

    try out.appendSlice(allocator, "]}");
}

/// Emit texture descriptor from binary data.
fn emitTextureDesc(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    if (data.len < 2) {
        try out.appendSlice(allocator, "{}");
        return;
    }

    // Parse binary descriptor fields
    var q: usize = 2; // skip type_tag + field_count
    const field_count = data[1];
    var tex_width: u32 = 0;
    var tex_height: u32 = 0;
    var has_width = false;
    var has_height = false;
    var tex_format: ?[]const u8 = null;
    var tex_usage: u8 = 0;

    for (0..field_count) |_| {
        if (q + 2 > data.len) break;
        const fi = data[q];
        const vt = data[q + 1];
        q += 2;
        switch (fi) {
            0x01 => { // width
                if (vt == 0x00 and q + 4 <= data.len) {
                    tex_width = std.mem.readInt(u32, data[q..][0..4], .little);
                    has_width = true;
                    q += 4;
                }
            },
            0x02 => { // height
                if (vt == 0x00 and q + 4 <= data.len) {
                    tex_height = std.mem.readInt(u32, data[q..][0..4], .little);
                    has_height = true;
                    q += 4;
                }
            },
            0x07 => { // format
                if (vt == 0x07 and q < data.len) {
                    tex_format = textureFormatStr(data[q]);
                    q += 1;
                }
            },
            0x08 => { // usage
                if (vt == 0x07 and q < data.len) {
                    tex_usage = data[q];
                    q += 1;
                } else if (vt == 0x00 and q + 4 <= data.len) {
                    tex_usage = @intCast(std.mem.readInt(u32, data[q..][0..4], .little));
                    q += 4;
                }
            },
            else => {
                // Skip unknown fields based on value type
                q = skipValue(data, q, vt);
            },
        }
    }

    // Canvas-size textures omit width/height fields — use canvas dimensions
    try out.appendSlice(allocator, "{size:[");
    if (has_width) {
        try appendInt(out, allocator, tex_width);
    } else {
        try out.appendSlice(allocator, "c.width");
    }
    try out.appendSlice(allocator, ",");
    if (has_height) {
        try appendInt(out, allocator, tex_height);
    } else {
        try out.appendSlice(allocator, "c.height");
    }
    try out.appendSlice(allocator, "],format:'");
    try out.appendSlice(allocator, tex_format orelse "rgba8unorm");
    try out.appendSlice(allocator, "',usage:");
    try appendInt(out, allocator, tex_usage);
    try out.appendSlice(allocator, "}");
}

/// Parse texture format string from binary descriptor data.
fn parseTextureFormat(data: []const u8) ?[]const u8 {
    if (data.len < 2) return null;
    var q: usize = 2;
    const field_count = data[1];
    for (0..field_count) |_| {
        if (q + 2 > data.len) break;
        const fi = data[q];
        const vt = data[q + 1];
        q += 2;
        if (fi == 0x07 and vt == 0x07 and q < data.len) {
            return textureFormatStr(data[q]);
        }
        q = skipValue(data, q, vt);
    }
    return null;
}

/// Emit sampler descriptor from binary data.
fn emitSamplerDesc(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    if (data.len < 2) {
        try out.appendSlice(allocator, "{}");
        return;
    }

    var q: usize = 2;
    const field_count = data[1];
    var has_fields = false;

    try out.appendSlice(allocator, "{");

    for (0..field_count) |_| {
        if (q + 2 > data.len) break;
        const fi = data[q];
        const vt = data[q + 1];
        q += 2;

        const name: ?[]const u8 = switch (fi) {
            0x01 => "addressModeU",
            0x02 => "addressModeV",
            0x03 => "addressModeW",
            0x04 => "magFilter",
            0x05 => "minFilter",
            0x06 => "mipmapFilter",
            0x09 => "compare",
            else => null,
        };

        if (name) |n| {
            if (vt == 0x07 and q < data.len) {
                if (has_fields) try out.appendSlice(allocator, ",");
                has_fields = true;
                try out.appendSlice(allocator, n);
                try out.appendSlice(allocator, ":'");
                const val_str: []const u8 = switch (fi) {
                    0x01, 0x02, 0x03 => addressModeStr(data[q]),
                    0x04, 0x05, 0x06 => filterModeStr(data[q]),
                    0x09 => compareFnStr(data[q]),
                    else => "nearest",
                };
                try out.appendSlice(allocator, val_str);
                try out.appendSlice(allocator, "'");
                q += 1;
            } else {
                q = skipValue(data, q, vt);
            }
        } else {
            q = skipValue(data, q, vt);
        }
    }

    try out.appendSlice(allocator, "}");
}

// ============================================================================
// Helpers
// ============================================================================

fn skipValue(data: []const u8, pos: usize, vt: u8) usize {
    var q = pos;
    switch (vt) {
        0x00 => q += 4, // u32
        0x01 => q += 4, // f32
        0x02 => q += 2, // string_id
        0x05 => q += 1, // bool
        0x06 => q += 2, // u16
        0x07 => q += 1, // enum
        0x03 => { // array
            if (q < data.len) {
                var ec = data[q];
                q += 1;
                while (ec > 0) : (ec -= 1) {
                    if (q + 2 > data.len) break;
                    const inner_vt = data[q + 1];
                    q += 2;
                    q = skipValue(data, q, inner_vt);
                }
            }
        },
        0x04 => { // nested
            if (q + 2 <= data.len) {
                const nested_fc = data[q + 1];
                q += 2;
                for (0..nested_fc) |_| {
                    if (q + 2 > data.len) break;
                    const inner_vt = data[q + 1];
                    q += 2;
                    q = skipValue(data, q, inner_vt);
                }
            }
        },
        else => q += 1,
    }
    return q;
}

/// Resolve WGSL code with imports.
///
/// The code_data_id from MockGPU is a data section index (not wgsl_id).
/// First try direct data section lookup. If the WGSL table has entries whose
/// data_id matches, resolve imports via DFS. Otherwise return raw data.
fn resolveWgslCode(allocator: std.mem.Allocator, code_data_id: u16, module: *const format.Module) ![]u8 {
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
            return resolveWgslWithDeps(allocator, wid, module);
        }
    }

    // Fallback: read directly from data section
    const data = module.data.get(@enumFromInt(code_data_id));
    const result = try allocator.alloc(u8, data.len);
    @memcpy(result, data);
    return result;
}

/// Resolve WGSL with import dependencies (iterative DFS).
fn resolveWgslWithDeps(allocator: std.mem.Allocator, wgsl_id: u16, module: *const format.Module) ![]u8 {
    const wgsl_table = &module.wgsl;

    var included = std.AutoHashMapUnmanaged(u16, void){};
    defer included.deinit(allocator);
    var order = std.ArrayListUnmanaged(u16){};
    defer order.deinit(allocator);
    var stack = std.ArrayListUnmanaged(u16){};
    defer stack.deinit(allocator);

    try stack.append(allocator, wgsl_id);

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
            try included.put(allocator, current, {});
            try order.append(allocator, current);
        } else {
            try stack.append(allocator, current);
            for (entry.deps) |dep| {
                if (!included.contains(dep)) {
                    try stack.append(allocator, dep);
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

    const result = try allocator.alloc(u8, total_size);
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

/// Escape WGSL code for use in JS template literals.
/// Also strips leading whitespace and empty lines (WGSL whitespace is not significant).
fn appendEscapedWgsl(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, wgsl: []const u8) !void {
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

/// Emit a JSON value as JS.
fn emitJsonValue(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: std.json.Value) !void {
    switch (value) {
        .object => |obj| {
            try out.appendSlice(allocator, "{");
            var first = true;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (!first) try out.appendSlice(allocator, ",");
                first = false;
                try out.appendSlice(allocator, entry.key_ptr.*);
                try out.appendSlice(allocator, ":");
                try emitJsonValue(out, allocator, entry.value_ptr.*);
            }
            try out.appendSlice(allocator, "}");
        },
        .array => |arr| {
            try out.appendSlice(allocator, "[");
            for (arr.items, 0..) |item, i| {
                if (i > 0) try out.appendSlice(allocator, ",");
                try emitJsonValue(out, allocator, item);
            }
            try out.appendSlice(allocator, "]");
        },
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
        .bool => |b| {
            try out.appendSlice(allocator, if (b) "!0" else "!1");
        },
        .null => {
            try out.appendSlice(allocator, "null");
        },
        .number_string => |s| {
            try out.appendSlice(allocator, s);
        },
    }
}

/// Emit a float in compact JS form: 0.5 → .5, -0.5 → -.5, 1.0 → 1
fn appendCompactFloat(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, val: f32) !void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{val}) catch "0";
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

fn appendInt(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: anytype) !void {
    var buf: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
    try out.appendSlice(allocator, s);
}

fn textureFormatStr(val: u8) []const u8 {
    return switch (val) {
        0x00 => "rgba8unorm",
        0x01 => "rgba8snorm",
        0x04 => "bgra8unorm",
        0x05 => "rgba16float",
        0x06 => "rgba32float",
        0x10 => "depth24plus",
        0x11 => "depth24plus-stencil8",
        0x12 => "depth32float",
        0x20 => "r32float",
        0x21 => "rg32float",
        else => "rgba8unorm",
    };
}

fn filterModeStr(val: u8) []const u8 {
    return switch (val) {
        0x00 => "nearest",
        0x01 => "linear",
        else => "nearest",
    };
}

fn addressModeStr(val: u8) []const u8 {
    return switch (val) {
        0x00 => "clamp-to-edge",
        0x01 => "repeat",
        0x02 => "mirror-repeat",
        else => "clamp-to-edge",
    };
}

fn compareFnStr(val: u8) []const u8 {
    return switch (val) {
        0x00 => "never",
        0x01 => "less",
        0x02 => "equal",
        0x03 => "less-equal",
        0x04 => "greater",
        0x05 => "not-equal",
        0x06 => "greater-equal",
        0x07 => "always",
        else => "never",
    };
}

/// Strip leading whitespace and empty lines from WGSL source.
/// Returns an owned slice. Caller must free.
fn stripWgslWhitespace(allocator: std.mem.Allocator, wgsl: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, wgsl, '\n');
    var first = true;
    while (it.next()) |line| {
        var trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0) continue;
        // Strip full-line comments
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        // Strip trailing comments (but not inside strings)
        if (std.mem.indexOf(u8, trimmed, "//")) |ci| {
            // Only strip if not preceded by ':' (e.g. "http://") and not inside a string
            if (ci == 0 or trimmed[ci - 1] != ':') {
                const before = std.mem.trimEnd(u8, trimmed[0..ci], " \t");
                if (before.len > 0) trimmed = before;
            }
        }
        if (!first) try out.append(allocator, '\n');
        first = false;
        try out.appendSlice(allocator, trimmed);
    }
    return out.toOwnedSlice(allocator);
}

/// Raw deflate compression. Returns owned compressed bytes.
fn deflateCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    std.debug.assert(data.len > 0);

    const capacity = data.len + data.len / 10 + 1024;
    var output_buf = try allocator.alloc(u8, capacity);
    defer allocator.free(output_buf);

    var window_buf: [flate.max_window_len]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(output_buf);

    var compressor = flate.Compress.init(
        &output_writer,
        &window_buf,
        .raw,
        .level_9,
    ) catch return error.OutOfMemory;

    compressor.writer.writeAll(data) catch return error.OutOfMemory;
    compressor.writer.flush() catch return error.OutOfMemory;

    const result = try allocator.alloc(u8, output_writer.end);
    @memcpy(result, output_buf[0..output_writer.end]);
    return result;
}


/// Emit audio WASM setup code.
fn emitAudioSetup(html: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, audio_wasm: []const u8) !void {
    try html.appendSlice(allocator, "const{instance:ai}=await WebAssembly.instantiate(Uint8Array.from(atob('");
    // Base64 encode audio WASM
    try base64Append(html, allocator, audio_wasm);
    try html.appendSlice(allocator, "'),c=>c.charCodeAt(0)),{m:Math});");
    try html.appendSlice(allocator, "const am=ai.exports.m,as=ai.exports.s.value,al=ai.exports.l.value,at=ai.exports.t.value==1;");
    try html.appendSlice(allocator, "const afr=at?al/4:al/8,asp=at?new Int16Array(am.buffer,as,afr*2):new Float32Array(am.buffer,as,afr*2);");
    try html.appendSlice(allocator, "const ax=new AudioContext({sampleRate:44100}),ab=ax.createBuffer(2,afr,44100);");
    try html.appendSlice(allocator, "for(let c=0;c<2;c++){const d=ab.getChannelData(c);for(let i=0;i<afr;i++)d[i]=at?asp[i*2+c]/32768:asp[i*2+c]}let sr;\n");
}

/// Append base64-encoded data.
fn base64Append(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

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
}
