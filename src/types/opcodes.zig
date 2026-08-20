//! PNGB Opcode Definitions
//!
//! Defines the instruction set for the PNGine bytecode interpreter.
//! This module contains ONLY type definitions - no encoding utilities.
//!
//! Categories:
//! - 0x00-0x0F: Resource Creation (buffers, textures, pipelines)
//! - 0x10-0x1F: Pass Operations (render/compute pass commands)
//! - 0x20-0x2F: Queue Operations (write, copy, submit)
//! - 0x30-0x3F: Frame Control (frame/pass definitions)
//! - 0x40-0x4F: Pool Operations (resource pooling) + pass state (0x4A-0x4F:
//!   timestamp/occlusion query, stencil ref, scissor)
//! - 0x50-0x52: extended pass state (depth/stencil ops, blend constant,
//!   depth/stencil clear values)
//! - 0x53-0x7F: Reserved (formerly data generation, use compute shaders)
//!
//! Invariants:
//! - Opcode 0x00 is reserved (invalid/nop)
//! - Most opcodes have a fixed parameter count; a few are count-prefixed
//!   (rep-group / variadic): MRT color attachments, execute_bundles, and
//!   wasm-call args. Operand layouts are the single source of truth in
//!   `bytecode/wire_schema.zig` (fixed-shape ops there; count-prefixed and
//!   control-flow ops decode manually in the emitter/scanner/dispatcher).

const std = @import("std");
const plugins = @import("plugins.zig");

/// Bytecode opcodes.
///
/// Operand wire layouts are defined authoritatively in bytecode/wire_schema.zig
/// (the single source of truth the emitter, scanner, and dispatcher share). The
/// `Params:` comments below are a human summary; wire_schema.zig is normative.
pub const OpCode = enum(u8) {
    // ========================================================================
    // Resource Creation (0x00-0x0F)
    // ========================================================================

    /// No operation / invalid.
    nop = 0x00,

    /// Create GPU buffer.
    /// Params: buffer_id (varint), size (varint), usage_flags (2 bytes: lo, hi)
    create_buffer = 0x01,

    /// Create GPU texture.
    /// Params: texture_id, width, height, format, usage_flags
    create_texture = 0x02,

    /// Create sampler.
    /// Params: sampler_id, descriptor_data_id
    create_sampler = 0x03,

    /// Create shader module from data section.
    /// Params: shader_id, code_data_id
    create_shader_module = 0x04,

    /// Create shader by concatenating multiple data sections (WGSL composition).
    /// Params: shader_id, count, data_id_0, data_id_1, ...
    /// STATUS: never emitted by the SJON frontend and the dispatcher errors on
    /// it by design (superseded by single-module WGSL). The layout stays in
    /// wire_schema so decoders skip it forever; do not "finish" or remove it.
    create_shader_concat = 0x05,

    /// Create bind group layout.
    /// Params: layout_id, descriptor_data_id
    create_bind_group_layout = 0x06,

    /// Create pipeline layout.
    /// Params: layout_id, descriptor_data_id
    create_pipeline_layout = 0x07,

    /// Create render pipeline.
    /// Params: pipeline_id, descriptor_data_id
    create_render_pipeline = 0x08,

    /// Create compute pipeline.
    /// Params: pipeline_id, descriptor_data_id
    create_compute_pipeline = 0x09,

    /// Create bind group.
    /// Params: group_id, layout_id, entry_count, entries...
    /// `layout_id` names one of two id spaces — see `BIND_GROUP_LAYOUT_TAG`.
    create_bind_group = 0x0A,

    /// Create image bitmap from blob data.
    /// Params: bitmap_id, blob_data_id
    create_image_bitmap = 0x0B,

    /// Create texture view.
    /// Params: view_id, texture_id, descriptor_data_id
    create_texture_view = 0x0C,

    /// Create query set.
    /// Params: query_set_id, descriptor_data_id
    create_query_set = 0x0D,

    /// Create render bundle from pre-recorded draw commands.
    /// Params: bundle_id, descriptor_data_id
    create_render_bundle = 0x0E,

    // ========================================================================
    // Pass Operations (0x10-0x1F)
    // ========================================================================

    /// Begin render pass.
    /// Params: color_texture_id (varint), load_op, store_op (bytes),
    ///   depth_texture_id (varint, 0xFFFF = none), clear_r/g/b/a (4 bytes),
    ///   resolve_texture_id (varint, 0xFFFF = none)
    begin_render_pass = 0x10,

    /// Begin compute pass.
    begin_compute_pass = 0x11,

    /// Set current pipeline.
    /// Params: pipeline_id
    set_pipeline = 0x12,

    /// Set bind group.
    /// Params: slot, group_id
    set_bind_group = 0x13,

    /// Set vertex buffer.
    /// Params: slot, buffer_id
    set_vertex_buffer = 0x14,

    /// Set index buffer.
    /// Params: buffer_id, format
    set_index_buffer = 0x15,

    /// Draw primitives.
    /// Params: vertex_count, instance_count, first_vertex, first_instance (varints)
    draw = 0x16,

    /// Draw indexed primitives.
    /// Params: index_count, instance_count, first_index, base_vertex, first_instance (varints)
    draw_indexed = 0x17,

    /// Dispatch compute workgroups.
    /// Params: x, y, z
    dispatch = 0x18,

    /// End current pass.
    end_pass = 0x19,

    /// Execute pre-recorded render bundles.
    /// Params: bundle_count, bundle_id_0, bundle_id_1, ...
    execute_bundles = 0x1A,

    /// Begin render pass with multiple color attachments (MRT).
    /// Params: attachment_count, [texture_id, load_op, store_op, clear_r/g/b/a] × N, depth_texture_id
    begin_render_pass_mrt = 0x1B,

    /// Draw indirect from buffer.
    /// Params: buffer_id (varint), offset (varint)
    draw_indirect = 0x1C,

    /// Draw indexed indirect from buffer.
    /// Params: buffer_id (varint), offset (varint)
    draw_indexed_indirect = 0x1D,

    /// Dispatch compute workgroups indirect from buffer.
    /// Params: buffer_id (varint), offset (varint)
    dispatch_indirect = 0x1E,

    /// Set viewport for render pass.
    /// Params: x (varint), y (varint), width (varint), height (varint), minDepth (u32 f32-bits), maxDepth (u32 f32-bits)
    set_viewport = 0x1F,

    // ========================================================================
    // Queue Operations (0x20-0x2F)
    // ========================================================================

    /// Write data to buffer.
    /// Params: buffer_id, offset, data_id
    write_buffer = 0x20,

    /// Write uniform data (runtime-resolved).
    /// Params: buffer_id, uniform_id
    ///
    /// RESERVED-INERT (C4). The SJON frontend emits NO write_uniform; only the
    /// wire-conformance fixtures (which keep Emitter.writeUniform alive) do. The
    /// reference dispatcher executes it (backend.write_uniform in mock/headless/
    /// native), but the shipping browser executor (wasm_entry.zig) decodes and
    /// SKIPS it — there is no command-buffer counterpart, so it has no effect in
    /// a browser. Kept as a reserved slot forever: an old payload that encoded it
    /// must still decode without desync. Never delete or renumber (append-only).
    write_uniform = 0x21,

    /// Copy buffer to buffer.
    /// Params: src_buffer, src_offset, dst_buffer, dst_offset, size
    copy_buffer_to_buffer = 0x22,

    /// Copy texture to texture.
    copy_texture_to_texture = 0x23,

    /// Submit command buffer to queue.
    submit = 0x24,

    /// Copy external image (ImageBitmap) to texture.
    /// Params: bitmap_id, texture_id, mip_level, origin_x, origin_y, origin_z
    copy_external_image_to_texture = 0x25,

    /// Initialize WASM module from embedded data.
    /// Params: module_id, wasm_data_id
    init_wasm_module = 0x26,

    /// Call WASM exported function.
    /// Params: call_id, module_id, func_name_id, arg_count, [args...]
    call_wasm_func = 0x27,

    /// Write WASM memory to GPU buffer.
    /// Params: call_id, buffer_id, offset, byte_len
    write_buffer_from_wasm = 0x28,

    /// Resolve query set results to a buffer.
    /// Params: query_set_id, first_query, query_count, dest_buffer_id, dest_offset (5 varints)
    resolve_query_set = 0x29,

    /// Write time/canvas uniform data to buffer.
    /// Params: buffer_id, offset, size
    write_time_uniform = 0x2A,

    /// Write pointer/input uniform data to buffer.
    /// Params: buffer_id, offset, size
    write_pointer_uniform = 0x2B,

    /// Write audio analysis data to buffer.
    /// Params: buffer_id, offset, size
    ///
    /// RESERVED-INERT (C4), like write_uniform (0x21). No frontend path emits it
    /// — the studio's audio-track feature plays via an AudioWorklet + a separate
    /// pNGa PNG chunk, not this opcode; only the wire-conformance fixtures emit
    /// it (keeping Emitter.writeAudioData alive). The reference dispatcher
    /// executes it (backend.write_audio_data); wasm_entry decodes and SKIPS it
    /// (no command-buffer counterpart). Reserved slot — never delete or renumber.
    write_audio_data = 0x2C,

    // ========================================================================
    // Frame Control (0x30-0x3F)
    // ========================================================================

    /// Define a frame.
    /// Params: frame_id, name_string_id
    define_frame = 0x30,

    /// End frame definition.
    end_frame = 0x31,

    /// Execute a pass within a frame.
    /// Params: pass_id
    exec_pass = 0x32,

    /// Define a pass.
    /// Params: pass_id, pass_type, descriptor_data_id
    define_pass = 0x33,

    /// End pass definition.
    end_pass_def = 0x34,

    /// Execute a pass once (run-once semantics for init passes).
    /// Params: pass_id
    /// The executor tracks which passes have been executed and skips duplicates.
    exec_pass_once = 0x35,

    // ========================================================================
    // Pool Operations (0x40-0x4F)
    // ========================================================================

    /// Select resource from pool (ping-pong).
    /// Params: dest_slot, pool_id, frame_offset
    /// STATUS: never emitted by the SJON frontend and the dispatcher errors on
    /// it by design — pool selection is inlined into the set_*_pool opcodes
    /// (0x41-0x43). The layout stays in wire_schema so decoders skip it
    /// forever; do not "finish" or remove it.
    select_from_pool = 0x40,

    /// Set vertex buffer from pool.
    /// Params: slot, base_buffer_id, pool_size, offset
    set_vertex_buffer_pool = 0x41,

    /// Set bind group from pool.
    /// Params: slot, base_group_id, pool_size, offset
    set_bind_group_pool = 0x42,

    /// Begin render pass with pool texture (ping-pong render targets).
    /// Params: base_texture_id, pool_size, offset, load_op, store_op, depth_texture_id
    /// Runtime computes: actual_tex_id = base_tex_id + (frame_counter + offset) % pool_size
    begin_render_pass_pool = 0x43,

    // ========================================================================
    // Extended Pass Operations (0x4A-0x4F)
    // ========================================================================

    /// Set timestamp writes for NEXT render/compute pass.
    /// Params: query_set_id (varint), begin_write_index (varint), end_write_index (varint)
    set_pass_timestamp_writes = 0x4A,

    /// Set occlusion query set for NEXT render pass.
    /// Params: query_set_id (varint)
    set_pass_occlusion_query_set = 0x4B,

    /// End current occlusion query in render pass.
    end_occlusion_query = 0x4C,

    /// Begin occlusion query at index in render pass.
    /// Params: query_index (varint)
    begin_occlusion_query = 0x4D,

    /// Set stencil reference value for render pass.
    /// Params: reference (varint)
    set_stencil_reference = 0x4E,

    /// Set scissor rect for render pass.
    /// Params: x (varint), y (varint), width (varint), height (varint)
    set_scissor_rect = 0x4F,

    /// Set depth/stencil load/store ops for NEXT render pass.
    /// Params: depth_load_op (u8), depth_store_op (u8), stencil_load_op (u8), stencil_store_op (u8)
    /// Values: 0=load, 1=clear (matching LoadOp enum). Store: 0=store, 1=discard.
    set_pass_depth_stencil_ops = 0x50,

    /// Set the blend constant for the render pass (setBlendConstant).
    /// Params: r, g, b, a — each an f32 bit pattern (raw u32 LE, 4 bytes).
    /// The value the `constant`/`one-minus-constant` blend factors multiply by.
    set_blend_constant = 0x51,

    /// Set depth/stencil clear values for the NEXT render pass (pre-pass state,
    /// like set_pass_depth_stencil_ops). Only emitted when the depth attachment
    /// authors a non-default :depth-clear-value / :stencil-clear-value; absent,
    /// the runtime defaults apply (depth 1.0, stencil 0).
    /// Params: depth_bits (f32 bit pattern, raw u32 LE), stencil_value (u32 LE).
    set_pass_clear_values = 0x52,

    // ========================================================================
    // Reserved (0x53-0x7F) - formerly data generation
    // Use compute shaders or WASM calls for buffer initialization
    // ========================================================================

    _,

    /// Check if opcode is valid.
    pub fn isValid(self: OpCode) bool {
        return switch (self) {
            .nop,
            .create_buffer,
            .create_texture,
            .create_sampler,
            .create_shader_module,
            .create_shader_concat,
            .create_bind_group_layout,
            .create_pipeline_layout,
            .create_render_pipeline,
            .create_compute_pipeline,
            .create_bind_group,
            .create_image_bitmap,
            .create_texture_view,
            .create_query_set,
            .create_render_bundle,
            .begin_render_pass,
            .begin_compute_pass,
            .set_pipeline,
            .set_bind_group,
            .set_vertex_buffer,
            .set_index_buffer,
            .draw,
            .draw_indexed,
            .dispatch,
            .execute_bundles,
            .begin_render_pass_mrt,
            .draw_indirect,
            .draw_indexed_indirect,
            .dispatch_indirect,
            .set_viewport,
            .resolve_query_set,
            .set_pass_timestamp_writes,
            .set_pass_occlusion_query_set,
            .end_occlusion_query,
            .begin_occlusion_query,
            .set_stencil_reference,
            .set_scissor_rect,
            .set_pass_depth_stencil_ops,
            .set_blend_constant,
            .set_pass_clear_values,
            .end_pass,
            .write_buffer,
            .write_uniform,
            .copy_buffer_to_buffer,
            .copy_texture_to_texture,
            .submit,
            .copy_external_image_to_texture,
            .init_wasm_module,
            .call_wasm_func,
            .write_buffer_from_wasm,
            .define_frame,
            .end_frame,
            .exec_pass,
            .exec_pass_once,
            .define_pass,
            .end_pass_def,
            .select_from_pool,
            .set_vertex_buffer_pool,
            .set_bind_group_pool,
            .begin_render_pass_pool,
            .write_time_uniform,
            .write_pointer_uniform,
            .write_audio_data,
            => true,
            _ => false,
        };
    }
};

/// Discriminates the TWO id spaces `create_bind_group`'s `layout_id` can name.
/// Set ⇒ the low bits are a `create_bind_group_layout` id (the group targets an
/// explicitly authored layout, `:bind-group-layout`); clear ⇒ a pipeline id (the
/// group targets that pipeline's auto-derived layout: `:layout <pipeline>`).
///
/// Both spaces are numbered from 0 and both are capped at 64 entries, so without
/// this bit the operand is ambiguous and every consumer guessed differently
/// (journal §339). The guesses agreed only because the corpus' two explicit-BGL
/// fixtures happened to have BGL id 0 *and* pipeline id 0.
///
/// A tag, and not one merged id space, because the two layouts are NOT
/// interchangeable: WebGPU makes an auto-derived layout exclusive to its own
/// pipeline and an explicitly created one incompatible with any auto-layout
/// pipeline (verified in Chrome; see docs/journal.md §339). Resolving one to the
/// other is a silent layout substitution, not a lookup detail — so the wire has
/// to say which was authored.
pub const BIND_GROUP_LAYOUT_TAG: u16 = 0x8000;

/// True when `layout_id` names a standalone bind-group-layout id.
pub fn layoutIdIsBindGroupLayout(layout_id: u16) bool {
    return (layout_id & BIND_GROUP_LAYOUT_TAG) != 0;
}

/// The id inside a `layout_id`, with the space tag removed.
pub fn layoutIdValue(layout_id: u16) u16 {
    return layout_id & ~BIND_GROUP_LAYOUT_TAG;
}

/// Tag `id` as a standalone bind-group-layout id.
/// Pre-condition: `id` fits below the tag bit (ids are capped far below it).
pub fn tagBindGroupLayoutId(id: u16) u16 {
    std.debug.assert(id < BIND_GROUP_LAYOUT_TAG);
    const tagged = id | BIND_GROUP_LAYOUT_TAG;
    std.debug.assert(layoutIdIsBindGroupLayout(tagged) and layoutIdValue(tagged) == id);
    return tagged;
}

/// The executor plugin an opcode REQUIRES to have an effect, or null if it runs
/// in every variant (core, structure, pool, and the render/compute-shared
/// pipeline-state ops). This drives executor-variant selection: the compiler
/// unions `pluginForOpcode` over the opcodes it emits (bytecode/emitter.zig's
/// `plugins_used`) to pick the smallest variant that covers the payload.
///
/// The classification mirrors the ACTUAL `plugins.isEnabled(...)` gating inside
/// wasm_entry.zig's handlers, NOT merely `executeOpcode`'s handler grouping:
/// `set_pipeline`/`set_bind_group`/`end_pass` route to `execRender` but execute
/// UNGATED (compute uses them too), so they are null — otherwise a compute-only
/// document would over-select a render variant. Pool ops (`execPool`) are ungated
/// and always co-occur with a render/compute pipeline, so they are null too.
/// Keep this in lockstep with those handlers; a wrong `null` under-selects and
/// silently ships an executor that SKIPS the opcode (blank render). Item 2.2.
pub fn pluginForOpcode(op: OpCode) ?plugins.Plugin {
    return switch (op) {
        // Render-GATED: skipped (or no-op) when the render plugin is absent.
        .create_render_pipeline,
        .begin_render_pass,
        .begin_render_pass_mrt,
        .set_vertex_buffer,
        .set_index_buffer,
        .draw,
        .draw_indexed,
        .draw_indirect,
        .draw_indexed_indirect,
        .set_viewport,
        .set_scissor_rect,
        .set_stencil_reference,
        .set_blend_constant,
        .set_pass_occlusion_query_set,
        .set_pass_timestamp_writes,
        .set_pass_depth_stencil_ops,
        .set_pass_clear_values,
        .begin_occlusion_query,
        .end_occlusion_query,
        .create_render_bundle,
        .execute_bundles,
        => .render,

        // Compute-GATED.
        .create_compute_pipeline,
        .begin_compute_pass,
        .dispatch,
        .dispatch_indirect,
        => .compute,

        // Texture-GATED.
        .create_texture,
        .create_texture_view,
        .create_image_bitmap,
        .copy_texture_to_texture,
        .copy_external_image_to_texture,
        => .texture,

        // WASM-GATED.
        .init_wasm_module,
        .call_wasm_func,
        .write_buffer_from_wasm,
        => .wasm,

        // Everything else runs in every variant: core resource/queue ops, the
        // render/compute-shared pipeline-state ops (set_pipeline/set_bind_group/
        // end_pass), frame/pass structure, pool ops, and the reserved-inert
        // write_uniform/write_audio_data. No `else` so a NEW opcode forces an
        // explicit classification decision here (and the animation plugin has no
        // opcodes of its own).
        .nop,
        .create_buffer,
        .create_sampler,
        .create_shader_module,
        .create_shader_concat,
        .create_bind_group_layout,
        .create_pipeline_layout,
        .create_bind_group,
        .create_query_set,
        .set_pipeline,
        .set_bind_group,
        .end_pass,
        .write_buffer,
        .write_uniform,
        .copy_buffer_to_buffer,
        .submit,
        .resolve_query_set,
        .write_time_uniform,
        .write_pointer_uniform,
        .write_audio_data,
        .define_frame,
        .end_frame,
        .exec_pass,
        .exec_pass_once,
        .define_pass,
        .end_pass_def,
        .select_from_pool,
        .set_vertex_buffer_pool,
        .set_bind_group_pool,
        .begin_render_pass_pool,
        => null,

        _ => null, // unknown/reserved opcode
    };
}

/// Buffer usage flags (matches WebGPU GPUBufferUsage).
/// Bit positions are verified at comptime to match WebGPU spec.
pub const BufferUsage = packed struct(u16) {
    map_read: bool = false,
    map_write: bool = false,
    copy_src: bool = false,
    copy_dst: bool = false,
    index: bool = false,
    vertex: bool = false,
    uniform: bool = false,
    storage: bool = false,
    indirect: bool = false,
    query_resolve: bool = false,
    _padding: u6 = 0,

    pub const uniform_copy_dst: BufferUsage = .{ .uniform = true, .copy_dst = true };
    pub const vertex_copy_dst: BufferUsage = .{ .vertex = true, .copy_dst = true };
    pub const storage_copy_dst: BufferUsage = .{ .storage = true, .copy_dst = true };
    pub const indirect_storage: BufferUsage = .{ .indirect = true, .storage = true };
    pub const indirect_storage_copy_dst: BufferUsage = .{ .indirect = true, .storage = true, .copy_dst = true };

    /// WebGPU GPUBufferUsage constants (from W3C WebGPU spec §4.3.2)
    pub const WEBGPU_MAP_READ: u32 = 0x0001;
    pub const WEBGPU_MAP_WRITE: u32 = 0x0002;
    pub const WEBGPU_COPY_SRC: u32 = 0x0004;
    pub const WEBGPU_COPY_DST: u32 = 0x0008;
    pub const WEBGPU_INDEX: u32 = 0x0010;
    pub const WEBGPU_VERTEX: u32 = 0x0020;
    pub const WEBGPU_UNIFORM: u32 = 0x0040;
    pub const WEBGPU_STORAGE: u32 = 0x0080;
    pub const WEBGPU_INDIRECT: u32 = 0x0100;
    pub const WEBGPU_QUERY_RESOLVE: u32 = 0x0200;

    /// Convert to WebGPU-compatible u32 (identity since bits match).
    pub fn toWebGPU(self: BufferUsage) u32 {
        return @as(u16, @bitCast(self));
    }

    // Compile-time verification that packed struct bits match WebGPU values
    comptime {
        const assert = @import("std").debug.assert;
        assert(@as(u16, @bitCast(BufferUsage{ .map_read = true })) == WEBGPU_MAP_READ);
        assert(@as(u16, @bitCast(BufferUsage{ .map_write = true })) == WEBGPU_MAP_WRITE);
        assert(@as(u16, @bitCast(BufferUsage{ .copy_src = true })) == WEBGPU_COPY_SRC);
        assert(@as(u16, @bitCast(BufferUsage{ .copy_dst = true })) == WEBGPU_COPY_DST);
        assert(@as(u16, @bitCast(BufferUsage{ .index = true })) == WEBGPU_INDEX);
        assert(@as(u16, @bitCast(BufferUsage{ .vertex = true })) == WEBGPU_VERTEX);
        assert(@as(u16, @bitCast(BufferUsage{ .uniform = true })) == WEBGPU_UNIFORM);
        assert(@as(u16, @bitCast(BufferUsage{ .storage = true })) == WEBGPU_STORAGE);
        assert(@as(u16, @bitCast(BufferUsage{ .indirect = true })) == WEBGPU_INDIRECT);
        assert(@as(u16, @bitCast(BufferUsage{ .query_resolve = true })) == WEBGPU_QUERY_RESOLVE);
    }
};

/// Load operation for render pass attachments.
///
/// NON-EXHAUSTIVE for the same reason `OpCode` is: both decoders build one of
/// these with `@enumFromInt` straight off the wire, and a PNG carrying a byte
/// ≥ 2 is illegal behaviour on an exhaustive enum — undefined in ReleaseSmall,
/// which is the mode the embedded executor ships in. Consumers map the two
/// known tags and treat anything else as the safe default (`clear`/`store`).
pub const LoadOp = enum(u8) {
    load = 0,
    clear = 1,
    _,
};

/// Store operation for render pass attachments. Non-exhaustive — see `LoadOp`.
pub const StoreOp = enum(u8) {
    store = 0,
    discard = 1,
    _,
};

/// Pass type.
pub const PassType = enum(u8) {
    render = 0,
    compute = 1,
};

/// WASM function argument types for call_wasm_func opcode.
///
/// Non-exhaustive — see `LoadOp`. This one is load-bearing beyond safety: the
/// tag's `valueByteSize()` is what advances the pc across an arg, so an
/// unknown tag decides how the REST of the stream is read.
pub const WasmArgType = enum(u8) {
    literal_f32 = 0x00,
    canvas_width = 0x01,
    canvas_height = 0x02,
    time_total = 0x03,
    literal_i32 = 0x04,
    literal_u32 = 0x05,
    time_delta = 0x06,
    _,

    /// Value bytes that follow this tag on the wire.
    ///
    /// An unknown tag consumes NO value bytes, so a hostile stream stalls the
    /// walk instead of running it away — the same strategy `decode_varint_safe`
    /// picked for a truncated varint (returns len 0), and it works for the same
    /// reason: every caller loop is bounded, so a stationary pc terminates.
    /// Returning 4 here would let 255 unknown tags advance the pc ~1275 bytes
    /// past the buffer.
    pub fn valueByteSize(self: WasmArgType) u8 {
        return switch (self) {
            .literal_f32, .literal_i32, .literal_u32 => 4,
            .canvas_width, .canvas_height, .time_total, .time_delta => 0,
            _ => 0,
        };
    }
};

/// Return type size mapping for WASM call results.
pub const WasmReturnType = struct {
    pub fn byteSize(type_name: []const u8) ?u32 {
        const map = std.StaticStringMap(u32).initComptime(.{
            .{ "f32", 4 },
            .{ "i32", 4 },
            .{ "u32", 4 },
            .{ "vec2", 8 },
            .{ "vec3", 12 },
            .{ "vec4", 16 },
            .{ "mat3x3", 36 },
            .{ "mat4x4", 64 },
        });
        return map.get(type_name);
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
