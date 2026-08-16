//! Command Buffer for GPU Operations
//!
//! Instead of calling extern JS functions directly, accumulates GPU commands
//! into a binary buffer that JS can execute. This reduces the JS bundle size
//! significantly by moving the dispatch logic from 2000 lines of JS to a
//! simple ~200 line switch statement.
//!
//! ## Format
//!
//! ```
//! Header (8 bytes):
//!   [total_len: u32]    Total buffer size including header
//!   [cmd_count: u16]    Number of commands
//!   [flags: u16]        Reserved for future use
//!
//! Commands (variable):
//!   [cmd: u8]           Command opcode
//!   [args: ...]         Fixed-size arguments per command type
//! ```
//!
//! ## Invariants
//!
//! - Buffer is pre-allocated with fixed capacity (64KB default)
//! - All writes are bounds-checked
//! - Pointers into WASM memory are passed as u32 offsets
//! - JS must read data from WASM memory using these pointers

const std = @import("std");
const assert = std.debug.assert;

// Use bytecode module import
const bytecode_mod = @import("bytecode");
const format = bytecode_mod.format;
const Module = format.Module;
const bytecode_emitter_types = bytecode_mod.emitter.Emitter;

/// Command opcodes for JS dispatcher.
/// Grouped by category, matching the plan's command set.
pub const Cmd = enum(u8) {
    // Resource Creation (0x01-0x0F)
    create_buffer = 0x01,
    create_texture = 0x02,
    create_sampler = 0x03,
    create_shader = 0x04,
    create_render_pipeline = 0x05,
    create_compute_pipeline = 0x06,
    create_bind_group = 0x07,
    create_texture_view = 0x08,
    create_query_set = 0x09,
    create_bind_group_layout = 0x0A,
    create_image_bitmap = 0x0B,
    create_pipeline_layout = 0x0C,
    create_render_bundle = 0x0D,

    // Pass Operations (0x10-0x1F)
    begin_render_pass = 0x10,
    begin_compute_pass = 0x11,
    set_pipeline = 0x12,
    set_bind_group = 0x13,
    set_vertex_buffer = 0x14,
    draw = 0x15,
    draw_indexed = 0x16,
    end_pass = 0x17,
    dispatch = 0x18,
    set_index_buffer = 0x19,
    execute_bundles = 0x1A,
    begin_render_pass_mrt = 0x1B,
    draw_indirect = 0x1C,
    draw_indexed_indirect = 0x1D,
    dispatch_indirect = 0x1E,
    set_viewport = 0x1F,

    // Extended pass operations
    set_pass_timestamp_writes = 0x4A,
    set_pass_occlusion_query_set = 0x4B,
    end_occlusion_query = 0x4C,
    begin_occlusion_query = 0x4D,
    set_stencil_reference = 0x4E,
    set_scissor_rect = 0x4F,
    set_pass_depth_stencil_ops = 0x50,
    set_blend_constant = 0x51,
    set_pass_clear_values = 0x52,

    // Queue Operations (0x20-0x2F)
    write_buffer = 0x20,
    write_time_uniform = 0x21,
    copy_buffer_to_buffer = 0x22,
    copy_texture_to_texture = 0x23,
    write_buffer_from_wasm = 0x24,
    copy_external_image_to_texture = 0x25,
    write_pointer_uniform = 0x26,
    resolve_query_set = 0x27,

    // WASM Module Operations (0x30-0x3F)
    init_wasm_module = 0x30,
    call_wasm_func = 0x31,

    // Reserved (0x40-0x4F) - formerly data-gen, now use compute shaders

    // Control (0xF0-0xFF)
    submit = 0xF0,
    end = 0xFF,
};

/// Header size in bytes.
pub const HEADER_SIZE: usize = 8;

/// Default buffer capacity (64KB should be plenty for most frames).
pub const DEFAULT_CAPACITY: usize = 64 * 1024;

/// Command buffer that accumulates GPU commands.
pub const CommandBuffer = struct {
    const Self = @This();

    /// Backing buffer for commands.
    buffer: []u8,

    /// Current write position (after header).
    pos: usize,

    /// Number of commands written.
    cmd_count: u16,

    /// A command did not fit whole, so it and everything after it were dropped.
    /// Reported in the header's flags word and turned into a nonzero `frame()`
    /// status. (LEAK-09 C)
    truncated: bool,

    /// End of the last command that fit WHOLE, and how many those were. The
    /// header is written from these, never from `pos`/`cmd_count` mid-command.
    sealed_pos: usize,
    sealed_count: u16,

    /// Initialize with pre-allocated buffer.
    pub fn init(buffer: []u8) Self {
        assert(buffer.len >= HEADER_SIZE);
        return .{
            .buffer = buffer,
            .pos = HEADER_SIZE,
            .cmd_count = 0,
            .truncated = false,
            .sealed_pos = HEADER_SIZE,
            .sealed_count = 0,
        };
    }

    /// Commit the command just finished, or roll it back if any of its writes
    /// was short.
    ///
    /// Called from `writeCmd` (the previous command is complete once the next
    /// one starts) and from `finish` (for the last one). Commands are written
    /// field by field with no end-of-command seam of their own, so the START of
    /// the next command is the seam — which is why this is a commit point rather
    /// than a size check per emitter.
    ///
    /// Computing each command's size up front instead would mean a second size
    /// table beside the emitters, kept in step with ~50 of them by hand. This
    /// needs no table and cannot disagree with what was actually written.
    fn seal(self: *Self) void {
        if (self.truncated) {
            // Nothing more will fit, so nothing more is kept: rewind to the last
            // whole command and leave the fragment out of the header's reach.
            self.pos = self.sealed_pos;
            self.cmd_count = self.sealed_count;
            return;
        }
        self.sealed_pos = self.pos;
        self.sealed_count = self.cmd_count;
    }

    /// Set in the header's flags word when `truncated`. The word was reserved
    /// and always zero, so this is an append-only ABI addition (docs/abi.md §8).
    pub const FLAG_TRUNCATED: u16 = 1;

    /// Finalize and write header. Returns slice of used buffer.
    pub fn finish(self: *Self) []const u8 {
        self.seal();

        // Write header
        const total_len: u32 = @intCast(self.pos);
        std.mem.writeInt(u32, self.buffer[0..4], total_len, .little);
        std.mem.writeInt(u16, self.buffer[4..6], self.cmd_count, .little);
        std.mem.writeInt(u16, self.buffer[6..8], if (self.truncated) FLAG_TRUNCATED else 0, .little);

        // Post-condition: the two header numbers describe the same buffer — a
        // consumer walking cmd_count commands ends exactly at total_len.
        assert(self.pos == self.sealed_pos);
        assert(self.cmd_count == self.sealed_count);

        return self.buffer[0..self.pos];
    }

    /// Get pointer to buffer start (for WASM export).
    pub fn ptr(self: *const Self) [*]const u8 {
        return self.buffer.ptr;
    }

    // ========================================================================
    // Low-level write methods
    // ========================================================================

    // Every short write LATCHES `truncated`. A no-op that says nothing is what
    // let the header overcount: the bytes were dropped and the count was not.

    fn writeU8(self: *Self, value: u8) void {
        if (self.pos < self.buffer.len) {
            self.buffer[self.pos] = value;
            self.pos += 1;
        } else self.truncated = true;
    }

    fn writeU16(self: *Self, value: u16) void {
        if (self.pos + 2 <= self.buffer.len) {
            std.mem.writeInt(u16, self.buffer[self.pos..][0..2], value, .little);
            self.pos += 2;
        } else self.truncated = true;
    }

    fn writeU32(self: *Self, value: u32) void {
        if (self.pos + 4 <= self.buffer.len) {
            std.mem.writeInt(u32, self.buffer[self.pos..][0..4], value, .little);
            self.pos += 4;
        } else self.truncated = true;
    }

    fn writeF32(self: *Self, value: f32) void {
        self.writeU32(@bitCast(value));
    }

    fn writeCmd(self: *Self, cmd: Cmd) void {
        self.seal();
        // Past the first short write nothing is emitted at all. The alternative
        // — keep trying — would let a LATER, smaller command squeeze in after a
        // dropped one, reordering the frame rather than shortening it.
        if (self.truncated) return;
        self.writeU8(@intFromEnum(cmd));
        self.cmd_count += 1;
    }

    fn writeSlice(self: *Self, data: []const u8) void {
        const max_to_write = @min(data.len, self.buffer.len -| self.pos);
        if (max_to_write < data.len) self.truncated = true;
        if (max_to_write > 0) {
            @memcpy(self.buffer[self.pos..][0..max_to_write], data[0..max_to_write]);
            self.pos += max_to_write;
        }
    }

    // ========================================================================
    // Command emission methods
    // ========================================================================

    /// CREATE_BUFFER: [id:u16] [size:u32] [usage:u16]
    pub fn createBuffer(self: *Self, id: u16, size: u32, usage: u16) void {
        self.writeCmd(.create_buffer);
        self.writeU16(id);
        self.writeU32(size);
        self.writeU16(usage);
    }

    /// CREATE_TEXTURE: [id:u16] [desc_ptr:u32] [desc_len:u32]
    pub fn createTexture(self: *Self, id: u16, desc_ptr: u32, desc_len: u32) void {
        self.writeCmd(.create_texture);
        self.writeU16(id);
        self.writeU32(desc_ptr);
        self.writeU32(desc_len);
    }

    /// CREATE_SAMPLER: [id:u16] [desc_ptr:u32] [desc_len:u32]
    pub fn createSampler(self: *Self, id: u16, desc_ptr: u32, desc_len: u32) void {
        self.writeCmd(.create_sampler);
        self.writeU16(id);
        self.writeU32(desc_ptr);
        self.writeU32(desc_len);
    }

    /// CREATE_SHADER: [id:u16] [code_ptr:u32] [code_len:u32]
    pub fn createShader(self: *Self, id: u16, code_ptr: u32, code_len: u32) void {
        self.writeCmd(.create_shader);
        self.writeU16(id);
        self.writeU32(code_ptr);
        self.writeU32(code_len);
    }

    /// CREATE_RENDER_PIPELINE: [id:u16] [desc_ptr:u32] [desc_len:u32]
    pub fn createRenderPipeline(self: *Self, id: u16, desc_ptr: u32, desc_len: u32) void {
        self.writeCmd(.create_render_pipeline);
        self.writeU16(id);
        self.writeU32(desc_ptr);
        self.writeU32(desc_len);
    }

    /// CREATE_COMPUTE_PIPELINE: [id:u16] [desc_ptr:u32] [desc_len:u32]
    pub fn createComputePipeline(self: *Self, id: u16, desc_ptr: u32, desc_len: u32) void {
        self.writeCmd(.create_compute_pipeline);
        self.writeU16(id);
        self.writeU32(desc_ptr);
        self.writeU32(desc_len);
    }

    /// CREATE_BIND_GROUP: [id:u16] [layout_id:u16] [entries_ptr:u32] [entries_len:u32]
    pub fn createBindGroup(self: *Self, id: u16, layout_id: u16, entries_ptr: u32, entries_len: u32) void {
        self.writeCmd(.create_bind_group);
        self.writeU16(id);
        self.writeU16(layout_id);
        self.writeU32(entries_ptr);
        self.writeU32(entries_len);
    }

    /// BEGIN_RENDER_PASS: [color_id:u16] [load:u8] [store:u8] [depth_id:u16] [r:u8] [g:u8] [b:u8] [a:u8] [resolve_id:u16]
    pub fn beginRenderPass(self: *Self, color_id: u16, load_op: u8, store_op: u8, depth_id: u16, clear_r: u8, clear_g: u8, clear_b: u8, clear_a: u8, resolve_id: u16) void {
        self.writeCmd(.begin_render_pass);
        self.writeU16(color_id);
        self.writeU8(load_op);
        self.writeU8(store_op);
        self.writeU16(depth_id);
        self.writeU8(clear_r);
        self.writeU8(clear_g);
        self.writeU8(clear_b);
        self.writeU8(clear_a);
        self.writeU16(resolve_id);
    }

    /// BEGIN_RENDER_PASS_MRT: [count:u8] [att0: tex_id:u16 load:u8 store:u8 r:u8 g:u8 b:u8 a:u8] ... [depth_id:u16]
    pub fn beginRenderPassMRT(self: *Self, attachments: []const bytecode_emitter_types.ColorAttachment, depth_id: u16) void {
        self.writeCmd(.begin_render_pass_mrt);
        self.writeU8(@intCast(attachments.len));
        for (attachments) |att| {
            self.writeU16(att.texture_id);
            self.writeU8(@intFromEnum(att.load_op));
            self.writeU8(@intFromEnum(att.store_op));
            self.writeU8(att.clear_r);
            self.writeU8(att.clear_g);
            self.writeU8(att.clear_b);
            self.writeU8(att.clear_a);
        }
        self.writeU16(depth_id);
    }

    /// BEGIN_COMPUTE_PASS: (no args)
    pub fn beginComputePass(self: *Self) void {
        self.writeCmd(.begin_compute_pass);
    }

    /// SET_PIPELINE: [id:u16]
    pub fn setPipeline(self: *Self, id: u16) void {
        self.writeCmd(.set_pipeline);
        self.writeU16(id);
    }

    /// SET_BIND_GROUP: [slot:u8] [id:u16]
    pub fn setBindGroup(self: *Self, slot: u8, id: u16) void {
        self.writeCmd(.set_bind_group);
        self.writeU8(slot);
        self.writeU16(id);
    }

    /// SET_VERTEX_BUFFER: [slot:u8] [id:u16]
    pub fn setVertexBuffer(self: *Self, slot: u8, id: u16) void {
        self.writeCmd(.set_vertex_buffer);
        self.writeU8(slot);
        self.writeU16(id);
    }

    /// SET_INDEX_BUFFER: [id:u16] [format:u8]
    pub fn setIndexBuffer(self: *Self, id: u16, index_format: u8) void {
        self.writeCmd(.set_index_buffer);
        self.writeU16(id);
        self.writeU8(index_format);
    }

    /// DRAW: [vtx:u32] [inst:u32] [first_vtx:u32] [first_inst:u32]
    pub fn draw(self: *Self, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        self.writeCmd(.draw);
        self.writeU32(vertex_count);
        self.writeU32(instance_count);
        self.writeU32(first_vertex);
        self.writeU32(first_instance);
    }

    /// DRAW_INDEXED: [idx:u32] [inst:u32] [first_idx:u32] [base_vtx:u32] [first_inst:u32]
    pub fn drawIndexed(self: *Self, index_count: u32, instance_count: u32, first_index: u32, base_vertex: u32, first_instance: u32) void {
        self.writeCmd(.draw_indexed);
        self.writeU32(index_count);
        self.writeU32(instance_count);
        self.writeU32(first_index);
        self.writeU32(base_vertex);
        self.writeU32(first_instance);
    }

    /// DISPATCH: [x:u32] [y:u32] [z:u32]
    pub fn dispatch(self: *Self, x: u32, y: u32, z: u32) void {
        self.writeCmd(.dispatch);
        self.writeU32(x);
        self.writeU32(y);
        self.writeU32(z);
    }

    /// DRAW_INDIRECT: [buffer_id:u16] [offset:u32]
    pub fn drawIndirect(self: *Self, buffer_id: u16, offset: u32) void {
        self.writeCmd(.draw_indirect);
        self.writeU16(buffer_id);
        self.writeU32(offset);
    }

    /// DRAW_INDEXED_INDIRECT: [buffer_id:u16] [offset:u32]
    pub fn drawIndexedIndirect(self: *Self, buffer_id: u16, offset: u32) void {
        self.writeCmd(.draw_indexed_indirect);
        self.writeU16(buffer_id);
        self.writeU32(offset);
    }

    /// DISPATCH_INDIRECT: [buffer_id:u16] [offset:u32]
    pub fn dispatchIndirect(self: *Self, buffer_id: u16, offset: u32) void {
        self.writeCmd(.dispatch_indirect);
        self.writeU16(buffer_id);
        self.writeU32(offset);
    }

    /// SET_VIEWPORT: [x:u32] [y:u32] [w:u32] [h:u32] [minDepth:f32] [maxDepth:f32]
    pub fn setViewport(self: *Self, x: u32, y: u32, w: u32, h: u32, min_depth: f32, max_depth: f32) void {
        self.writeCmd(.set_viewport);
        self.writeU32(x);
        self.writeU32(y);
        self.writeU32(w);
        self.writeU32(h);
        self.writeF32(min_depth);
        self.writeF32(max_depth);
    }

    /// SET_PASS_OCCLUSION_QUERY_SET: [query_set_id:u16]
    pub fn setPassOcclusionQuerySet(self: *Self, query_set_id: u16) void {
        self.writeCmd(.set_pass_occlusion_query_set);
        self.writeU16(query_set_id);
    }

    /// SET_PASS_TIMESTAMP_WRITES: [query_set_id:u16] [begin_idx:u16] [end_idx:u16]
    pub fn setPassTimestampWrites(self: *Self, query_set_id: u16, begin_idx: u16, end_idx: u16) void {
        self.writeCmd(.set_pass_timestamp_writes);
        self.writeU16(query_set_id);
        self.writeU16(begin_idx);
        self.writeU16(end_idx);
    }

    /// BEGIN_OCCLUSION_QUERY: [query_index:u32]
    pub fn beginOcclusionQuery(self: *Self, query_index: u32) void {
        self.writeCmd(.begin_occlusion_query);
        self.writeU32(query_index);
    }

    /// END_OCCLUSION_QUERY: (no args)
    pub fn endOcclusionQuery(self: *Self) void {
        self.writeCmd(.end_occlusion_query);
    }

    /// RESOLVE_QUERY_SET: [query_set_id:u16] [first:u32] [count:u32] [dest_buf:u16] [dest_offset:u32]
    pub fn resolveQuerySet(self: *Self, query_set_id: u16, first: u32, count: u32, dest_buf: u16, dest_offset: u32) void {
        self.writeCmd(.resolve_query_set);
        self.writeU16(query_set_id);
        self.writeU32(first);
        self.writeU32(count);
        self.writeU16(dest_buf);
        self.writeU32(dest_offset);
    }

    /// SET_STENCIL_REFERENCE: [reference:u32]
    pub fn setStencilReference(self: *Self, reference: u32) void {
        self.writeCmd(.set_stencil_reference);
        self.writeU32(reference);
    }

    /// SET_PASS_DEPTH_STENCIL_OPS: [depth_load:u8] [depth_store:u8] [stencil_load:u8] [stencil_store:u8]
    pub fn setPassDepthStencilOps(self: *Self, depth_load_op: u8, depth_store_op: u8, stencil_load_op: u8, stencil_store_op: u8) void {
        self.writeCmd(.set_pass_depth_stencil_ops);
        self.writeU8(depth_load_op);
        self.writeU8(depth_store_op);
        self.writeU8(stencil_load_op);
        self.writeU8(stencil_store_op);
    }

    /// SET_BLEND_CONSTANT: [r:f32] [g:f32] [b:f32] [a:f32]
    pub fn setBlendConstant(self: *Self, r: f32, g: f32, b: f32, a: f32) void {
        self.writeCmd(.set_blend_constant);
        self.writeF32(r);
        self.writeF32(g);
        self.writeF32(b);
        self.writeF32(a);
    }

    /// SET_PASS_CLEAR_VALUES: [depth:f32] [stencil:u32]
    pub fn setPassClearValues(self: *Self, depth: f32, stencil: u32) void {
        self.writeCmd(.set_pass_clear_values);
        self.writeF32(depth);
        self.writeU32(stencil);
    }

    /// SET_SCISSOR_RECT: [x:u32] [y:u32] [w:u32] [h:u32]
    pub fn setScissorRect(self: *Self, x: u32, y: u32, w: u32, h: u32) void {
        self.writeCmd(.set_scissor_rect);
        self.writeU32(x);
        self.writeU32(y);
        self.writeU32(w);
        self.writeU32(h);
    }

    /// END_PASS: (no args)
    pub fn endPass(self: *Self) void {
        self.writeCmd(.end_pass);
    }

    /// WRITE_BUFFER: [id:u16] [offset:u32] [data_ptr:u32] [data_len:u32]
    pub fn writeBuffer(self: *Self, id: u16, offset: u32, data_ptr: u32, data_len: u32) void {
        self.writeCmd(.write_buffer);
        self.writeU16(id);
        self.writeU32(offset);
        self.writeU32(data_ptr);
        self.writeU32(data_len);
    }

    /// WRITE_TIME_UNIFORM: [id:u16] [offset:u32] [size:u16]
    pub fn writeTimeUniform(self: *Self, id: u16, offset: u32, size: u16) void {
        self.writeCmd(.write_time_uniform);
        self.writeU16(id);
        self.writeU32(offset);
        self.writeU16(size);
    }

    /// WRITE_POINTER_UNIFORM: [id:u16] [offset:u32] [size:u16]
    pub fn writePointerUniform(self: *Self, id: u16, offset: u32, size: u16) void {
        self.writeCmd(.write_pointer_uniform);
        self.writeU16(id);
        self.writeU32(offset);
        self.writeU16(size);
    }

    /// CREATE_IMAGE_BITMAP: [id:u16] [data_ptr:u32] [data_len:u32]
    pub fn createImageBitmap(self: *Self, id: u16, data_ptr: u32, data_len: u32) void {
        self.writeCmd(.create_image_bitmap);
        self.writeU16(id);
        self.writeU32(data_ptr);
        self.writeU32(data_len);
    }

    /// COPY_EXTERNAL_IMAGE_TO_TEXTURE: [bitmap_id:u16] [texture_id:u16] [mip_level:u8] [origin_x:u16] [origin_y:u16] [origin_z:u16]
    pub fn copyExternalImageToTexture(self: *Self, bitmap_id: u16, texture_id: u16, mip_level: u8, origin_x: u16, origin_y: u16, origin_z: u16) void {
        self.writeCmd(.copy_external_image_to_texture);
        self.writeU16(bitmap_id);
        self.writeU16(texture_id);
        self.writeU8(mip_level);
        self.writeU16(origin_x);
        self.writeU16(origin_y);
        self.writeU16(origin_z);
    }

    /// CREATE_TEXTURE_VIEW: [id:u16] [texture_id:u16] [desc_ptr:u32] [desc_len:u32]
    pub fn createTextureView(self: *Self, id: u16, texture_id: u16, desc_ptr: u32, desc_len: u32) void {
        self.writeCmd(.create_texture_view);
        self.writeU16(id);
        self.writeU16(texture_id);
        self.writeU32(desc_ptr);
        self.writeU32(desc_len);
    }

    /// CREATE_QUERY_SET: [id:u16] [desc_ptr:u32] [desc_len:u32]
    pub fn createQuerySet(self: *Self, id: u16, desc_ptr: u32, desc_len: u32) void {
        self.writeCmd(.create_query_set);
        self.writeU16(id);
        self.writeU32(desc_ptr);
        self.writeU32(desc_len);
    }

    /// CREATE_BIND_GROUP_LAYOUT: [id:u16] [desc_ptr:u32] [desc_len:u32]
    pub fn createBindGroupLayout(self: *Self, id: u16, desc_ptr: u32, desc_len: u32) void {
        self.writeCmd(.create_bind_group_layout);
        self.writeU16(id);
        self.writeU32(desc_ptr);
        self.writeU32(desc_len);
    }

    /// CREATE_PIPELINE_LAYOUT: [id:u16] [desc_ptr:u32] [desc_len:u32]
    pub fn createPipelineLayout(self: *Self, id: u16, desc_ptr: u32, desc_len: u32) void {
        self.writeCmd(.create_pipeline_layout);
        self.writeU16(id);
        self.writeU32(desc_ptr);
        self.writeU32(desc_len);
    }

    /// CREATE_RENDER_BUNDLE: [id:u16] [desc_ptr:u32] [desc_len:u32]
    pub fn createRenderBundle(self: *Self, id: u16, desc_ptr: u32, desc_len: u32) void {
        self.writeCmd(.create_render_bundle);
        self.writeU16(id);
        self.writeU32(desc_ptr);
        self.writeU32(desc_len);
    }

    /// EXECUTE_BUNDLES: [count:u8] [bundle_ids:u16...]
    pub fn executeBundles(self: *Self, bundle_ids: []const u16) void {
        self.writeCmd(.execute_bundles);
        self.writeU8(@intCast(bundle_ids.len));
        for (bundle_ids) |id| {
            self.writeU16(id);
        }
    }

    /// COPY_BUFFER_TO_BUFFER: [src_id:u16] [src_offset:u32] [dst_id:u16] [dst_offset:u32] [size:u32]
    pub fn copyBufferToBuffer(self: *Self, src_id: u16, src_offset: u32, dst_id: u16, dst_offset: u32, size: u32) void {
        self.writeCmd(.copy_buffer_to_buffer);
        self.writeU16(src_id);
        self.writeU32(src_offset);
        self.writeU16(dst_id);
        self.writeU32(dst_offset);
        self.writeU32(size);
    }

    /// COPY_TEXTURE_TO_TEXTURE: [src_id:u16] [dst_id:u16] [width:u16] [height:u16]
    pub fn copyTextureToTexture(self: *Self, src_id: u16, dst_id: u16, width: u16, height: u16) void {
        self.writeCmd(.copy_texture_to_texture);
        self.writeU16(src_id);
        self.writeU16(dst_id);
        self.writeU16(width);
        self.writeU16(height);
    }

    /// WRITE_BUFFER_FROM_WASM: [buffer_id:u16] [buffer_offset:u32] [wasm_ptr:u32] [size:u32]
    pub fn writeBufferFromWasm(self: *Self, buffer_id: u16, buffer_offset: u32, wasm_ptr: u32, size: u32) void {
        self.writeCmd(.write_buffer_from_wasm);
        self.writeU16(buffer_id);
        self.writeU32(buffer_offset);
        self.writeU32(wasm_ptr);
        self.writeU32(size);
    }

    /// INIT_WASM_MODULE: [module_id:u16] [data_ptr:u32] [data_len:u32]
    pub fn initWasmModule(self: *Self, module_id: u16, data_ptr: u32, data_len: u32) void {
        self.writeCmd(.init_wasm_module);
        self.writeU16(module_id);
        self.writeU32(data_ptr);
        self.writeU32(data_len);
    }

    /// CALL_WASM_FUNC: [call_id:u16] [module_id:u16] [func_name_ptr:u32] [func_name_len:u32] [args_len:u8] [args bytes...]
    /// Note: args are copied inline to avoid dangling stack pointers.
    pub fn callWasmFunc(self: *Self, call_id: u16, module_id: u16, func_name_ptr: u32, func_name_len: u32, args: []const u8) void {
        self.writeCmd(.call_wasm_func);
        self.writeU16(call_id);
        self.writeU16(module_id);
        self.writeU32(func_name_ptr);
        self.writeU32(func_name_len);
        self.writeU8(@intCast(@min(args.len, 255)));
        self.writeSlice(args);
    }

    /// SUBMIT: (no args)
    pub fn submit(self: *Self) void {
        self.writeCmd(.submit);
    }

    /// END: (no args) - marks end of command buffer
    pub fn end(self: *Self) void {
        self.writeCmd(.end);
    }
};

// Dedicated tests moved to tests/zig/executor/command_buffer_test.zig
