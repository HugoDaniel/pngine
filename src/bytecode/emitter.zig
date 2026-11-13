//! Bytecode Emitter
//!
//! Produces PNGB bytecode from high-level operations.
//! Uses variable-length encoding for compact output.
//!
//! ## Sizing
//!
//! The buffer starts empty and grows by `ArrayList` doubling. There is no
//! capacity hint, deliberately: measured over `examples/**/*.sjon` (169
//! documents, r3-06) the bytecode section has a median of 112 bytes and a p95
//! of 371, with the largest — `webgpu_stress_bundles.sjon` — at 1287. Under
//! `ArrayList`'s growth (`m + m/2 + 64` for `u8`), growing from zero costs
//! **two** allocations for the median document and six for the largest, on a
//! build-time path. A `DEFAULT_CAPACITY` of 512 used to live here with a
//! header claiming a simple triangle was ~400 bytes; it is 57. Nothing in the
//! tree ever called the capacity constructors, and the numbers that justified
//! them were wrong, so they are gone.
//!
//! ## Invariants
//!
//! - Bytecode is appended sequentially; the one backpatch is `patchSkip`,
//!   a guarded arm's skip distance over already-emitted bytes
//! - Each instruction is self-contained (no cross-references)
//! - All IDs are validated before emission

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const opcodes = @import("opcodes.zig");
const wire_schema = @import("wire_schema.zig");
const OpCode = opcodes.OpCode;
const BufferUsage = opcodes.BufferUsage;
const LoadOp = opcodes.LoadOp;
const StoreOp = opcodes.StoreOp;
const PassType = opcodes.PassType;
const ControlComparison = opcodes.ControlComparison;

// Rep-group caps, from the wire schema. These are the FIRST place the contract
// can be checked — every consumer downstream can only refuse a stream that
// breaks it — so each count-prefixed emit asserts its own. They were previously
// two hand-written literals and one missing check. (§320)
const MAX_MRT: usize = wire_schema.repMaxOf(.begin_render_pass_mrt);
const MAX_BUNDLES: usize = wire_schema.repMaxOf(.execute_bundles);
const MAX_WASM_ARGS: u8 = @intCast(wire_schema.repMaxOf(.call_wasm_func));

/// Bytecode emitter.
pub const Emitter = struct {
    const Self = @This();

    /// Output bytecode buffer.
    bytes: std.ArrayList(u8),

    /// Union of the executor plugins the emitted opcodes require (item 2.2). Each
    /// `emitOpcode` ORs in `opcodes.pluginForOpcode(op)`, so after a full walk
    /// this is the DEFINITIVE plugin set — every opcode that will run is counted,
    /// no form-head heuristic can miss one. The compiler reads it to select the
    /// smallest covering executor variant (dsl_sjon/Compiler.zig).
    plugins_used: opcodes.PluginSet = .core_only,

    pub const empty: Self = .{
        .bytes = .empty,
    };

    pub fn deinit(self: *Self, gpa: Allocator) void {
        self.bytes.deinit(gpa);
        self.* = undefined;
    }

    /// Get current bytecode length.
    pub fn len(self: *const Self) usize {
        return self.bytes.items.len;
    }

    /// Get bytecode as slice.
    pub fn bytecode(self: *const Self) []const u8 {
        return self.bytes.items;
    }

    /// Take ownership of bytecode.
    ///
    /// Caller owns the returned bytes.
    pub fn toOwnedSlice(self: *Self, gpa: Allocator) ![]u8 {
        return self.bytes.toOwnedSlice(gpa);
    }

    // ========================================================================
    // Low-level emission
    // ========================================================================

    /// Emit a single byte.
    fn emitByte(self: *Self, gpa: Allocator, byte: u8) !void {
        try self.bytes.append(gpa, byte);
    }

    /// Emit a varint.
    fn emitVarint(self: *Self, gpa: Allocator, value: u32) !void {
        var buffer: [4]u8 = undefined;
        const encoded_len = opcodes.encodeVarint(value, &buffer);
        try self.bytes.appendSlice(gpa, buffer[0..encoded_len]);
    }

    /// Emit a raw u32 (4 bytes, little-endian). Used for f32 bit patterns.
    fn emitRawU32(self: *Self, gpa: Allocator, value: u32) !void {
        const bytes: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, value));
        try self.bytes.appendSlice(gpa, &bytes);
    }

    /// Emit an opcode. Also records the plugin the opcode requires (if any) into
    /// `plugins_used` — the single chokepoint every emit method funnels through,
    /// so variant detection can never miss an emitted opcode (item 2.2).
    fn emitOpcode(self: *Self, gpa: Allocator, op: OpCode) !void {
        if (opcodes.pluginForOpcode(op)) |p| self.plugins_used.enable(p);
        try self.emitByte(gpa, @intFromEnum(op));
    }

    // ========================================================================
    // Resource Creation Instructions
    // ========================================================================

    /// Emit create_buffer instruction.
    /// Creates a GPU buffer with specified size and usage.
    ///
    /// Note: size=0 is allowed for buffers sized from data references,
    /// where the runtime will patch in the actual size.
    pub fn createBuffer(
        self: *Self,
        gpa: Allocator,
        buffer_id: u16,
        size: u32,
        usage: BufferUsage,
    ) !void {
        // Pre-condition: must have at least one usage flag
        assert(@as(u16, @bitCast(usage)) != 0);

        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .create_buffer);
        try self.emitVarint(gpa, buffer_id);
        try self.emitVarint(gpa, size);
        const usage_bits: u16 = @bitCast(usage);
        try self.emitByte(gpa, @truncate(usage_bits));
        try self.emitByte(gpa, @truncate(usage_bits >> 8));

        // Post-condition: bytecode was appended (at least 5 bytes: opcode + 2 varints + 2 bytes)
        assert(self.bytes.items.len >= start_len + 5);
    }

    /// Emit create_shader_module instruction.
    /// Creates a shader module from data section.
    pub fn createShaderModule(
        self: *Self,
        gpa: Allocator,
        shader_id: u16,
        code_data_id: u16,
    ) !void {
        // Pre-condition: IDs are within valid range (implicitly u16)
        const start_len = self.bytes.items.len;

        try self.emitOpcode(gpa, .create_shader_module);
        try self.emitVarint(gpa, shader_id);
        try self.emitVarint(gpa, code_data_id);

        // Post-condition: at least 3 bytes emitted (opcode + 2 varints)
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit create_shader_concat instruction.
    /// Creates a shader module by concatenating multiple data sections (WGSL composition).
    /// Params: shader_id, count, data_id_0, data_id_1, ...
    pub fn createShaderConcat(
        self: *Self,
        gpa: Allocator,
        shader_id: u16,
        data_ids: []const u16,
    ) !void {
        // Pre-conditions
        assert(data_ids.len > 0);
        assert(data_ids.len <= 255);

        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .create_shader_concat);
        try self.emitVarint(gpa, shader_id);
        try self.emitByte(gpa, @intCast(data_ids.len));
        for (data_ids) |data_id| {
            try self.emitVarint(gpa, data_id);
        }

        // Post-condition: opcode + shader_id varint + count byte + one varint per id.
        assert(self.bytes.items.len >= start_len + 3 + data_ids.len);
    }

    /// Emit create_render_pipeline instruction.
    /// Creates a render pipeline from descriptor data.
    pub fn createRenderPipeline(
        self: *Self,
        gpa: Allocator,
        pipeline_id: u16,
        descriptor_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;

        try self.emitOpcode(gpa, .create_render_pipeline);
        try self.emitVarint(gpa, pipeline_id);
        try self.emitVarint(gpa, descriptor_data_id);

        // Post-condition: bytecode was appended
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit create_compute_pipeline instruction.
    pub fn createComputePipeline(
        self: *Self,
        gpa: Allocator,
        pipeline_id: u16,
        descriptor_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;

        try self.emitOpcode(gpa, .create_compute_pipeline);
        try self.emitVarint(gpa, pipeline_id);
        try self.emitVarint(gpa, descriptor_data_id);

        // Post-condition: bytecode was appended
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit create_bind_group instruction.
    pub fn createBindGroup(
        self: *Self,
        gpa: Allocator,
        group_id: u16,
        layout_id: u16,
        entry_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;

        try self.emitOpcode(gpa, .create_bind_group);
        try self.emitVarint(gpa, group_id);
        try self.emitVarint(gpa, layout_id);
        try self.emitVarint(gpa, entry_data_id);

        // Post-condition: at least 4 bytes emitted
        assert(self.bytes.items.len >= start_len + 4);
    }

    /// Emit create_texture instruction.
    /// Creates a GPU texture with specified dimensions and format.
    pub fn createTexture(
        self: *Self,
        gpa: Allocator,
        texture_id: u16,
        descriptor_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .create_texture);
        try self.emitVarint(gpa, texture_id);
        try self.emitVarint(gpa, descriptor_data_id);
        // Post-condition: at least 3 bytes emitted (opcode + 2 varints).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit create_sampler instruction.
    /// Creates a texture sampler with specified filtering/wrapping.
    pub fn createSampler(
        self: *Self,
        gpa: Allocator,
        sampler_id: u16,
        descriptor_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .create_sampler);
        try self.emitVarint(gpa, sampler_id);
        try self.emitVarint(gpa, descriptor_data_id);
        // Post-condition: at least 3 bytes emitted (opcode + 2 varints).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit create_bind_group_layout instruction.
    pub fn createBindGroupLayout(
        self: *Self,
        gpa: Allocator,
        layout_id: u16,
        descriptor_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .create_bind_group_layout);
        try self.emitVarint(gpa, layout_id);
        try self.emitVarint(gpa, descriptor_data_id);
        // Post-condition: at least 3 bytes emitted (opcode + 2 varints).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit create_pipeline_layout instruction.
    pub fn createPipelineLayout(
        self: *Self,
        gpa: Allocator,
        layout_id: u16,
        descriptor_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .create_pipeline_layout);
        try self.emitVarint(gpa, layout_id);
        try self.emitVarint(gpa, descriptor_data_id);
        // Post-condition: at least 3 bytes emitted (opcode + 2 varints).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit create_render_bundle instruction.
    /// Creates a pre-recorded render bundle for efficient draw command replay.
    pub fn createRenderBundle(
        self: *Self,
        gpa: Allocator,
        bundle_id: u16,
        descriptor_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .create_render_bundle);
        try self.emitVarint(gpa, bundle_id);
        try self.emitVarint(gpa, descriptor_data_id);
        // Post-condition: at least 3 bytes emitted (opcode + 2 varints).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit create_image_bitmap instruction.
    /// Creates an ImageBitmap from blob data in data section.
    /// blob_data_id points to entry with format: [mime_len:u8][mime:bytes][data:bytes]
    pub fn createImageBitmap(
        self: *Self,
        gpa: Allocator,
        bitmap_id: u16,
        blob_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .create_image_bitmap);
        try self.emitVarint(gpa, bitmap_id);
        try self.emitVarint(gpa, blob_data_id);
        // Post-condition: at least 3 bytes emitted (opcode + 2 varints).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit create_texture_view instruction.
    /// Creates a GPUTextureView from an existing texture.
    pub fn createTextureView(
        self: *Self,
        gpa: Allocator,
        view_id: u16,
        texture_id: u16,
        descriptor_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .create_texture_view);
        try self.emitVarint(gpa, view_id);
        try self.emitVarint(gpa, texture_id);
        try self.emitVarint(gpa, descriptor_data_id);
        // Post-condition: at least 4 bytes emitted (opcode + 3 varints).
        assert(self.bytes.items.len >= start_len + 4);
    }

    /// Emit create_query_set instruction.
    /// Creates a GPUQuerySet for occlusion or timestamp queries.
    pub fn createQuerySet(
        self: *Self,
        gpa: Allocator,
        query_set_id: u16,
        descriptor_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .create_query_set);
        try self.emitVarint(gpa, query_set_id);
        try self.emitVarint(gpa, descriptor_data_id);
        // Post-condition: at least 3 bytes emitted (opcode + 2 varints).
        assert(self.bytes.items.len >= start_len + 3);
    }

    // ========================================================================
    // Pass Operations
    // ========================================================================

    /// Emit begin_render_pass instruction.
    /// depth_texture_id: use 0xFFFF for no depth attachment.
    /// resolve_texture_id: use 0xFFFF for no resolve target (non-MSAA).
    pub fn beginRenderPass(
        self: *Self,
        gpa: Allocator,
        color_texture_id: u16,
        load_op: LoadOp,
        store_op: StoreOp,
        depth_texture_id: u16,
        clear_r_bits: u32,
        clear_g_bits: u32,
        clear_b_bits: u32,
        clear_a_bits: u32,
        resolve_texture_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .begin_render_pass);
        try self.emitVarint(gpa, color_texture_id);
        try self.emitByte(gpa, @intFromEnum(load_op));
        try self.emitByte(gpa, @intFromEnum(store_op));
        try self.emitVarint(gpa, depth_texture_id);
        try self.emitRawU32(gpa, clear_r_bits);
        try self.emitRawU32(gpa, clear_g_bits);
        try self.emitRawU32(gpa, clear_b_bits);
        try self.emitRawU32(gpa, clear_a_bits);
        try self.emitVarint(gpa, resolve_texture_id);
        // Post-condition: opcode + 3 varints (≥1 each) + 2 op bytes + 16 clear
        // bytes = at least 22.
        assert(self.bytes.items.len >= start_len + 22);
    }

    /// Emit begin_render_pass_pool instruction.
    /// Pool variant of begin_render_pass that alternates render target texture each frame.
    /// Runtime computes: actual_tex_id = base_tex_id + (frame_counter + offset) % pool_size
    /// depth_texture_id: use 0xFFFF for no depth attachment.
    pub fn beginRenderPassPool(
        self: *Self,
        gpa: Allocator,
        base_texture_id: u16,
        pool_size: u8,
        offset: u8,
        load_op: LoadOp,
        store_op: StoreOp,
        depth_texture_id: u16,
        clear_r_bits: u32,
        clear_g_bits: u32,
        clear_b_bits: u32,
        clear_a_bits: u32,
    ) !void {
        // Pre-conditions
        assert(pool_size > 0); // Pool must have at least 1 texture
        assert(offset < pool_size); // Offset must be within pool

        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .begin_render_pass_pool);
        try self.emitVarint(gpa, base_texture_id);
        try self.emitByte(gpa, pool_size);
        try self.emitByte(gpa, offset);
        try self.emitByte(gpa, @intFromEnum(load_op));
        try self.emitByte(gpa, @intFromEnum(store_op));
        try self.emitVarint(gpa, depth_texture_id);
        try self.emitRawU32(gpa, clear_r_bits);
        try self.emitRawU32(gpa, clear_g_bits);
        try self.emitRawU32(gpa, clear_b_bits);
        try self.emitRawU32(gpa, clear_a_bits);
        // Post-condition: opcode + 2 varints (≥1 each) + 4 op/pool bytes + 16
        // clear bytes = at least 23.
        assert(self.bytes.items.len >= start_len + 23);
    }

    /// Color attachment for MRT render passes.
    pub const ColorAttachment = struct {
        texture_id: u16,
        load_op: LoadOp,
        store_op: StoreOp,
        /// f32 bit patterns, not 0-255 bytes — see L_BEGIN_RP in wire_schema.zig.
        clear_r_bits: u32,
        clear_g_bits: u32,
        clear_b_bits: u32,
        clear_a_bits: u32,
    };

    /// Emit begin_render_pass_mrt instruction for multiple color attachments.
    /// depth_texture_id: use 0xFFFF for no depth attachment.
    pub fn beginRenderPassMRT(
        self: *Self,
        gpa: Allocator,
        attachments: []const ColorAttachment,
        depth_texture_id: u16,
    ) !void {
        // Pre-conditions
        assert(attachments.len > 0 and attachments.len <= MAX_MRT);

        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .begin_render_pass_mrt);
        try self.emitByte(gpa, @intCast(attachments.len));

        for (attachments) |att| {
            try self.emitVarint(gpa, att.texture_id);
            try self.emitByte(gpa, @intFromEnum(att.load_op));
            try self.emitByte(gpa, @intFromEnum(att.store_op));
            try self.emitRawU32(gpa, att.clear_r_bits);
            try self.emitRawU32(gpa, att.clear_g_bits);
            try self.emitRawU32(gpa, att.clear_b_bits);
            try self.emitRawU32(gpa, att.clear_a_bits);
        }

        try self.emitVarint(gpa, depth_texture_id);
        // Post-condition: opcode + count byte + depth varint + 19 bytes per
        // attachment (texture_id varint ≥1 + 2 op bytes + 16 clear bytes).
        assert(self.bytes.items.len >= start_len + 3 + 19 * attachments.len);
    }

    /// Emit begin_compute_pass instruction.
    pub fn beginComputePass(self: *Self, gpa: Allocator) !void {
        try self.emitOpcode(gpa, .begin_compute_pass);
    }

    /// Emit set_pipeline instruction.
    pub fn setPipeline(self: *Self, gpa: Allocator, pipeline_id: u16) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .set_pipeline);
        try self.emitVarint(gpa, pipeline_id);
        // Post-condition: at least 2 bytes emitted (opcode + 1 varint).
        assert(self.bytes.items.len >= start_len + 2);
    }

    /// Emit set_bind_group instruction.
    pub fn setBindGroup(
        self: *Self,
        gpa: Allocator,
        slot: u8,
        group_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .set_bind_group);
        try self.emitByte(gpa, slot);
        try self.emitVarint(gpa, group_id);
        // Post-condition: at least 3 bytes emitted (opcode + slot byte + varint).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit set_vertex_buffer instruction.
    pub fn setVertexBuffer(
        self: *Self,
        gpa: Allocator,
        slot: u8,
        buffer_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .set_vertex_buffer);
        try self.emitByte(gpa, slot);
        try self.emitVarint(gpa, buffer_id);
        // Post-condition: at least 3 bytes emitted (opcode + slot byte + varint).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit set_vertex_buffer_pool instruction for pooled buffers.
    /// Runtime computes: actual_id = base_id + (frame_counter + offset) % pool_size
    pub fn setVertexBufferPool(
        self: *Self,
        gpa: Allocator,
        slot: u8,
        base_buffer_id: u16,
        pool_size: u8,
        offset: u8,
    ) !void {
        // Pre-conditions
        assert(pool_size > 0); // Pool must have at least 1 buffer
        assert(offset < pool_size); // Offset must be within pool

        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .set_vertex_buffer_pool);
        try self.emitByte(gpa, slot);
        try self.emitVarint(gpa, base_buffer_id);
        try self.emitByte(gpa, pool_size);
        try self.emitByte(gpa, offset);

        // Post-condition: at least 5 bytes emitted
        assert(self.bytes.items.len >= start_len + 5);
    }

    /// Emit set_bind_group_pool instruction for pooled bind groups.
    /// Runtime computes: actual_id = base_id + (frame_counter + offset) % pool_size
    pub fn setBindGroupPool(
        self: *Self,
        gpa: Allocator,
        slot: u8,
        base_group_id: u16,
        pool_size: u8,
        offset: u8,
    ) !void {
        // Pre-conditions
        assert(pool_size > 0); // Pool must have at least 1 bind group
        assert(offset < pool_size); // Offset must be within pool

        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .set_bind_group_pool);
        try self.emitByte(gpa, slot);
        try self.emitVarint(gpa, base_group_id);
        try self.emitByte(gpa, pool_size);
        try self.emitByte(gpa, offset);

        // Post-condition: at least 5 bytes emitted
        assert(self.bytes.items.len >= start_len + 5);
    }

    /// Emit set_index_buffer instruction.
    pub fn setIndexBuffer(
        self: *Self,
        gpa: Allocator,
        buffer_id: u16,
        format_id: u8,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .set_index_buffer);
        try self.emitVarint(gpa, buffer_id);
        try self.emitByte(gpa, format_id);
        // Post-condition: at least 3 bytes emitted (opcode + varint + format byte).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit draw instruction with full WebGPU parameters.
    /// Params: vertex_count, instance_count, first_vertex, first_instance
    ///
    /// No lower bound on the counts: `draw(0, …)` and `draw(n, 0, …)` are legal
    /// WebGPU no-ops and schema-legal (`count-value` is `:min 0`). A `> 0` assert
    /// here once turned `(draw :vertex-count 0)` — validated clean — into an
    /// abort of `pngine validate`; this layer encodes what it is given.
    pub fn draw(
        self: *Self,
        gpa: Allocator,
        vertex_count: u32,
        instance_count: u32,
        first_vertex: u32,
        first_instance: u32,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .draw);
        try self.emitVarint(gpa, vertex_count);
        try self.emitVarint(gpa, instance_count);
        try self.emitVarint(gpa, first_vertex);
        try self.emitVarint(gpa, first_instance);

        // Post-conditions: the opcode landed, then at least four varint bytes.
        assert(self.bytes.items[start_len] == @intFromEnum(OpCode.draw));
        assert(self.bytes.items.len >= start_len + 5);
    }

    /// Emit draw_indexed instruction with full WebGPU parameters.
    /// Params: index_count, instance_count, first_index, base_vertex, first_instance
    pub fn drawIndexed(
        self: *Self,
        gpa: Allocator,
        index_count: u32,
        instance_count: u32,
        first_index: u32,
        base_vertex: u32,
        first_instance: u32,
    ) !void {
        // No lower bound on the counts — see `draw`.
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .draw_indexed);
        try self.emitVarint(gpa, index_count);
        try self.emitVarint(gpa, instance_count);
        try self.emitVarint(gpa, first_index);
        try self.emitVarint(gpa, base_vertex);
        try self.emitVarint(gpa, first_instance);

        // Post-conditions: the opcode landed, then at least five varint bytes.
        assert(self.bytes.items[start_len] == @intFromEnum(OpCode.draw_indexed));
        assert(self.bytes.items.len >= start_len + 6);
    }

    /// Emit dispatch instruction.
    pub fn dispatch(
        self: *Self,
        gpa: Allocator,
        x: u32,
        y: u32,
        z: u32,
    ) !void {
        // No lower bound on the workgroup counts — `dispatchWorkgroups(0, …)`
        // is a legal WebGPU no-op, like `draw(0)` above.
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .dispatch);
        try self.emitVarint(gpa, x);
        try self.emitVarint(gpa, y);
        try self.emitVarint(gpa, z);

        // Post-conditions: the opcode landed, then at least three varint bytes.
        assert(self.bytes.items[start_len] == @intFromEnum(OpCode.dispatch));
        assert(self.bytes.items.len >= start_len + 4);
    }

    /// Emit draw_indirect instruction.
    /// Params: buffer_id, offset
    pub fn drawIndirect(
        self: *Self,
        gpa: Allocator,
        buffer_id: u16,
        offset: u32,
    ) !void {
        assert(buffer_id < 0xFFFF);

        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .draw_indirect);
        try self.emitVarint(gpa, buffer_id);
        try self.emitVarint(gpa, offset);

        // Post-condition: at least 3 bytes emitted
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit draw_indexed_indirect instruction.
    /// Params: buffer_id, offset
    pub fn drawIndexedIndirect(
        self: *Self,
        gpa: Allocator,
        buffer_id: u16,
        offset: u32,
    ) !void {
        assert(buffer_id < 0xFFFF);

        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .draw_indexed_indirect);
        try self.emitVarint(gpa, buffer_id);
        try self.emitVarint(gpa, offset);

        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit dispatch_indirect instruction.
    /// Params: buffer_id, offset
    pub fn dispatchIndirect(
        self: *Self,
        gpa: Allocator,
        buffer_id: u16,
        offset: u32,
    ) !void {
        assert(buffer_id < 0xFFFF);

        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .dispatch_indirect);
        try self.emitVarint(gpa, buffer_id);
        try self.emitVarint(gpa, offset);

        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit set_viewport instruction.
    /// Params: x, y, width, height (varints), minDepth, maxDepth (raw f32 as u32 bits)
    pub fn setViewport(
        self: *Self,
        gpa: Allocator,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        min_depth_bits: u32,
        max_depth_bits: u32,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .set_viewport);
        try self.emitVarint(gpa, x);
        try self.emitVarint(gpa, y);
        try self.emitVarint(gpa, width);
        try self.emitVarint(gpa, height);
        try self.emitRawU32(gpa, min_depth_bits);
        try self.emitRawU32(gpa, max_depth_bits);

        // Post-condition: opcode + 4 varints (min 4) + 8 raw bytes = at least 13
        assert(self.bytes.items.len >= start_len + 13);
    }

    /// Emit set_pass_occlusion_query_set instruction (state before beginRenderPass).
    pub fn setPassOcclusionQuerySet(self: *Self, gpa: Allocator, query_set_id: u16) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .set_pass_occlusion_query_set);
        try self.emitVarint(gpa, query_set_id);
        // Post-condition: at least 2 bytes emitted (opcode + 1 varint).
        assert(self.bytes.items.len >= start_len + 2);
    }

    /// Emit set_pass_depth_stencil_ops instruction (state before beginRenderPass).
    /// Overrides the default depth/stencil load/store ops for the next render pass.
    pub fn setPassDepthStencilOps(self: *Self, gpa: Allocator, depth_load_op: LoadOp, depth_store_op: StoreOp, stencil_load_op: LoadOp, stencil_store_op: StoreOp) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .set_pass_depth_stencil_ops);
        try self.emitByte(gpa, @intFromEnum(depth_load_op));
        try self.emitByte(gpa, @intFromEnum(depth_store_op));
        try self.emitByte(gpa, @intFromEnum(stencil_load_op));
        try self.emitByte(gpa, @intFromEnum(stencil_store_op));
        // Post-condition: exactly 5 bytes emitted (opcode + 4 op bytes).
        assert(self.bytes.items.len == start_len + 5);
    }

    /// Emit set_pass_timestamp_writes instruction (state before beginRenderPass/ComputePass).
    pub fn setPassTimestampWrites(self: *Self, gpa: Allocator, query_set_id: u16, begin_idx: u32, end_idx: u32) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .set_pass_timestamp_writes);
        try self.emitVarint(gpa, query_set_id);
        try self.emitVarint(gpa, begin_idx);
        try self.emitVarint(gpa, end_idx);
        // Post-condition: at least 4 bytes emitted (opcode + 3 varints).
        assert(self.bytes.items.len >= start_len + 4);
    }

    /// Emit begin_occlusion_query instruction.
    pub fn beginOcclusionQuery(self: *Self, gpa: Allocator, query_index: u32) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .begin_occlusion_query);
        try self.emitVarint(gpa, query_index);
        // Post-condition: at least 2 bytes emitted (opcode + 1 varint).
        assert(self.bytes.items.len >= start_len + 2);
    }

    /// Emit end_occlusion_query instruction.
    pub fn endOcclusionQuery(self: *Self, gpa: Allocator) !void {
        try self.emitOpcode(gpa, .end_occlusion_query);
    }

    /// Emit resolve_query_set instruction.
    pub fn resolveQuerySet(self: *Self, gpa: Allocator, query_set_id: u16, first_query: u32, query_count: u32, dest_buffer_id: u16, dest_offset: u32) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .resolve_query_set);
        try self.emitVarint(gpa, query_set_id);
        try self.emitVarint(gpa, first_query);
        try self.emitVarint(gpa, query_count);
        try self.emitVarint(gpa, dest_buffer_id);
        try self.emitVarint(gpa, dest_offset);
        // Post-condition: at least 6 bytes emitted (opcode + 5 varints).
        assert(self.bytes.items.len >= start_len + 6);
    }

    /// Emit set_stencil_reference instruction.
    /// Params: reference (varint)
    pub fn setStencilReference(
        self: *Self,
        gpa: Allocator,
        reference: u32,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .set_stencil_reference);
        try self.emitVarint(gpa, reference);

        assert(self.bytes.items.len >= start_len + 2);
    }

    /// Emit set_blend_constant instruction.
    /// Params: r, g, b, a — each an f32 bit pattern (raw u32 LE).
    pub fn setBlendConstant(
        self: *Self,
        gpa: Allocator,
        r_bits: u32,
        g_bits: u32,
        b_bits: u32,
        a_bits: u32,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .set_blend_constant);
        try self.emitRawU32(gpa, r_bits);
        try self.emitRawU32(gpa, g_bits);
        try self.emitRawU32(gpa, b_bits);
        try self.emitRawU32(gpa, a_bits);

        // Post-condition: opcode + 16 raw bytes = exactly 17.
        assert(self.bytes.items.len == start_len + 17);
    }

    /// Emit set_pass_clear_values instruction (state before beginRenderPass).
    /// Overrides the default depth/stencil clear values (1.0 / 0) for the next
    /// render pass. Params: depth as an f32 bit pattern, stencil as u32.
    pub fn setPassClearValues(
        self: *Self,
        gpa: Allocator,
        depth_bits: u32,
        stencil_value: u32,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .set_pass_clear_values);
        try self.emitRawU32(gpa, depth_bits);
        try self.emitRawU32(gpa, stencil_value);

        // Post-condition: opcode + 8 raw bytes = exactly 9.
        assert(self.bytes.items.len == start_len + 9);
    }

    /// Emit set_scissor_rect instruction.
    /// Params: x, y, width, height (varints)
    pub fn setScissorRect(
        self: *Self,
        gpa: Allocator,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .set_scissor_rect);
        try self.emitVarint(gpa, x);
        try self.emitVarint(gpa, y);
        try self.emitVarint(gpa, width);
        try self.emitVarint(gpa, height);

        assert(self.bytes.items.len >= start_len + 5);
    }

    /// Emit execute_bundles instruction.
    /// Replays pre-recorded render bundles in the current render pass.
    /// Params: bundle_count, bundle_id_0, bundle_id_1, ...
    pub fn executeBundles(
        self: *Self,
        gpa: Allocator,
        bundle_ids: []const u16,
    ) !void {
        // Pre-conditions
        assert(bundle_ids.len > 0);
        assert(bundle_ids.len <= MAX_BUNDLES);

        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .execute_bundles);
        try self.emitVarint(gpa, @intCast(bundle_ids.len));
        for (bundle_ids) |id| {
            try self.emitVarint(gpa, id);
        }

        // Post-condition: opcode + count varint + one varint per bundle id.
        assert(self.bytes.items.len >= start_len + 2 + bundle_ids.len);
    }

    /// Emit end_pass instruction.
    pub fn endPass(self: *Self, gpa: Allocator) !void {
        try self.emitOpcode(gpa, .end_pass);
    }

    // ========================================================================
    // Queue Operations
    // ========================================================================

    /// Emit write_buffer instruction.
    pub fn writeBuffer(
        self: *Self,
        gpa: Allocator,
        buffer_id: u16,
        offset: u32,
        data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .write_buffer);
        try self.emitVarint(gpa, buffer_id);
        try self.emitVarint(gpa, offset);
        try self.emitVarint(gpa, data_id);
        // Post-condition: at least 4 bytes emitted (opcode + 3 varints).
        assert(self.bytes.items.len >= start_len + 4);
    }

    /// Emit submit instruction.
    pub fn submit(self: *Self, gpa: Allocator) !void {
        try self.emitOpcode(gpa, .submit);
    }

    /// Emit write_uniform instruction.
    /// Writes runtime-resolved uniform data to buffer.
    /// Params: buffer_id, uniform_id (selects data source)
    pub fn writeUniform(
        self: *Self,
        gpa: Allocator,
        buffer_id: u16,
        uniform_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .write_uniform);
        try self.emitVarint(gpa, buffer_id);
        try self.emitVarint(gpa, uniform_id);
        // Post-condition: at least 3 bytes emitted (opcode + 2 varints).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit copy_buffer_to_buffer instruction.
    /// Copies data from source buffer to destination buffer.
    /// Params: src_buffer, src_offset, dst_buffer, dst_offset, size
    pub fn copyBufferToBuffer(
        self: *Self,
        gpa: Allocator,
        src_buffer: u16,
        src_offset: u32,
        dst_buffer: u16,
        dst_offset: u32,
        size: u32,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .copy_buffer_to_buffer);
        try self.emitVarint(gpa, src_buffer);
        try self.emitVarint(gpa, src_offset);
        try self.emitVarint(gpa, dst_buffer);
        try self.emitVarint(gpa, dst_offset);
        try self.emitVarint(gpa, size);
        // Post-condition: at least 6 bytes emitted (opcode + 5 varints).
        assert(self.bytes.items.len >= start_len + 6);
    }

    /// Emit copy_texture_to_texture instruction.
    /// Copies pixels from source texture to destination texture.
    /// Params: src_texture, dst_texture
    pub fn copyTextureToTexture(
        self: *Self,
        gpa: Allocator,
        src_texture: u16,
        dst_texture: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .copy_texture_to_texture);
        try self.emitVarint(gpa, src_texture);
        try self.emitVarint(gpa, dst_texture);
        // Post-condition: at least 3 bytes emitted (opcode + 2 varints).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit copy_external_image_to_texture instruction.
    /// Copies an ImageBitmap to a GPU texture.
    pub fn copyExternalImageToTexture(
        self: *Self,
        gpa: Allocator,
        bitmap_id: u16,
        texture_id: u16,
        mip_level: u8,
        origin_x: u16,
        origin_y: u16,
        origin_z: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .copy_external_image_to_texture);
        try self.emitVarint(gpa, bitmap_id);
        try self.emitVarint(gpa, texture_id);
        try self.emitByte(gpa, mip_level);
        try self.emitVarint(gpa, origin_x);
        try self.emitVarint(gpa, origin_y);
        try self.emitVarint(gpa, origin_z);
        // Post-condition: opcode + 5 varints (≥1 each) + mip byte = at least 7.
        assert(self.bytes.items.len >= start_len + 7);
    }

    // ========================================================================
    // WASM Operations
    // ========================================================================

    /// Emit init_wasm_module instruction.
    /// Initializes a WASM module from embedded .wasm bytes in data section.
    pub fn initWasmModule(
        self: *Self,
        gpa: Allocator,
        module_id: u16,
        wasm_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .init_wasm_module);
        try self.emitVarint(gpa, module_id);
        try self.emitVarint(gpa, wasm_data_id);
        // Post-condition: at least 3 bytes emitted (opcode + 2 varints).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit call_wasm_func instruction.
    /// Calls an exported WASM function with arguments.
    /// Args are encoded as: [arg_type:u8][value:varies (0-4 bytes)]
    pub fn callWasmFunc(
        self: *Self,
        gpa: Allocator,
        call_id: u16,
        module_id: u16,
        func_name_id: u16,
        args: []const u8,
    ) !void {
        // Pre-conditions: the pre-encoded args blob is well-formed per the wire
        // schema ([count][type,value?]…) and exactly sized (no trailing bytes),
        // so the scanner/dispatcher skip it correctly.
        const blob_len = wire_schema.wasmArgsBlobLen(args);
        assert(blob_len != null);
        assert(blob_len.? == args.len);
        // …and within the rep-group cap. The two sibling emits above have always
        // asserted theirs; this one did not, so a caller could hand it a blob no
        // decoder will accept and learn about it only at playback. (§320)
        assert(args[0] <= MAX_WASM_ARGS);

        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .call_wasm_func);
        try self.emitVarint(gpa, call_id);
        try self.emitVarint(gpa, module_id);
        try self.emitVarint(gpa, func_name_id);
        // Args are pre-encoded: [count][arg_type, value?]...
        try self.bytes.appendSlice(gpa, args);
        // Post-condition: opcode + 3 varints (≥1 each) + the exact args blob.
        assert(self.bytes.items.len >= start_len + 4 + args.len);
    }

    /// Emit write_buffer_from_wasm instruction.
    /// Copies bytes from WASM memory (at call result pointer) to GPU buffer.
    pub fn writeBufferFromWasm(
        self: *Self,
        gpa: Allocator,
        call_id: u16,
        buffer_id: u16,
        offset: u32,
        byte_len: u32,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .write_buffer_from_wasm);
        try self.emitVarint(gpa, call_id);
        try self.emitVarint(gpa, buffer_id);
        try self.emitVarint(gpa, offset);
        try self.emitVarint(gpa, byte_len);
        // Post-condition: at least 5 bytes emitted (opcode + 4 varints).
        assert(self.bytes.items.len >= start_len + 5);
    }

    // ========================================================================
    // Frame Control
    // ========================================================================

    /// Emit define_frame instruction.
    /// Frame ID 0 is typically the main render frame.
    pub fn defineFrame(
        self: *Self,
        gpa: Allocator,
        frame_id: u16,
        name_string_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;

        try self.emitOpcode(gpa, .define_frame);
        try self.emitVarint(gpa, frame_id);
        try self.emitVarint(gpa, name_string_id);

        // Post-condition: at least 3 bytes emitted
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit end_frame instruction.
    /// Must be paired with a preceding defineFrame.
    pub fn endFrame(self: *Self, gpa: Allocator) !void {
        // Pre-condition: bytecode has content (from defineFrame)
        assert(self.bytes.items.len > 0);

        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .end_frame);

        // Post-condition: 1 byte emitted
        assert(self.bytes.items.len == start_len + 1);
    }

    /// Emit exec_pass instruction.
    pub fn execPass(self: *Self, gpa: Allocator, pass_id: u16) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .exec_pass);
        try self.emitVarint(gpa, pass_id);
        // Post-condition: at least 2 bytes emitted (opcode + 1 varint).
        assert(self.bytes.items.len >= start_len + 2);
    }

    /// Emit exec_pass_once instruction (run-once semantics for init passes).
    /// The executor tracks which passes have been executed and skips duplicates.
    pub fn execPassOnce(self: *Self, gpa: Allocator, pass_id: u16) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .exec_pass_once);
        try self.emitVarint(gpa, pass_id);
        // Post-condition: at least 2 bytes emitted (opcode + 1 varint).
        assert(self.bytes.items.len >= start_len + 2);
    }

    /// Emit define_pass instruction.
    pub fn definePass(
        self: *Self,
        gpa: Allocator,
        pass_id: u16,
        pass_type: PassType,
        descriptor_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .define_pass);
        try self.emitVarint(gpa, pass_id);
        try self.emitByte(gpa, @intFromEnum(pass_type));
        try self.emitVarint(gpa, descriptor_data_id);
        // Post-condition: opcode + 2 varints (≥1 each) + pass_type byte = at least 4.
        assert(self.bytes.items.len >= start_len + 4);
    }

    /// Emit end_pass_def instruction.
    pub fn endPassDef(self: *Self, gpa: Allocator) !void {
        try self.emitOpcode(gpa, .end_pass_def);
    }

    // ========================================================================
    // Frame Controls and Guards (0x36-0x39, frame program §7.1)
    // ========================================================================

    /// Emit define_control instruction.
    /// Appends a control; the slot is the order of appearance starting at 1.
    /// `default_value`'s bit pattern goes on the wire as a raw u32 LE.
    pub fn emitDefineControl(
        self: *Self,
        gpa: Allocator,
        default_value: f32,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .define_control);
        try self.emitRawU32(gpa, @bitCast(default_value));
        // Post-condition: exactly 5 bytes (opcode + 4 raw).
        assert(self.bytes.items.len == start_len + 5);
    }

    /// Emit write_controls instruction.
    /// Writes the declared controls (slot 1 up, in declaration order — slot 0
    /// is `time` and is not writable through this instruction) to a buffer.
    pub fn emitWriteControls(
        self: *Self,
        gpa: Allocator,
        buffer_id: u32,
        offset: u32,
        size: u32,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .write_controls);
        try self.emitVarint(gpa, buffer_id);
        try self.emitVarint(gpa, offset);
        try self.emitVarint(gpa, size);
        // Post-condition: at least 4 bytes emitted (opcode + 3 varints).
        assert(self.bytes.items.len >= start_len + 4);
    }

    /// Emit exec_if instruction with a PLACEHOLDER skip of 0.
    /// Returns the byte offset of the `skip_lo` field so the caller can patch
    /// the real distance once the arm's length is known (patchSkip).
    ///
    /// The skip is counted from the END of this instruction; this method must
    /// not guess it, because the arm has not been emitted yet.
    pub fn emitExecIf(
        self: *Self,
        gpa: Allocator,
        slot: u32,
        comparison: ControlComparison,
        constant: f32,
    ) !usize {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .exec_if);
        try self.emitVarint(gpa, slot);
        try self.emitByte(gpa, @intFromEnum(comparison));
        try self.emitRawU32(gpa, @bitCast(constant));
        const skip_lo_pos = self.bytes.items.len;
        try self.emitByte(gpa, 0); // skip_lo — placeholder until patchSkip
        try self.emitByte(gpa, 0); // skip_hi
        // Post-condition: opcode + slot varint + comparison byte + 4 constant
        // bytes + 2 skip bytes = at least 9.
        assert(self.bytes.items.len >= start_len + 9);
        assert(self.bytes.items[skip_lo_pos] == 0);
        return skip_lo_pos;
    }

    /// Emit exec_skip instruction with a PLACEHOLDER skip of 0.
    /// Returns the byte offset of the `skip_lo` field (see emitExecIf).
    pub fn emitExecSkip(self: *Self, gpa: Allocator) !usize {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .exec_skip);
        const skip_lo_pos = self.bytes.items.len;
        try self.emitByte(gpa, 0); // skip_lo — placeholder until patchSkip
        try self.emitByte(gpa, 0); // skip_hi
        // Post-condition: exactly 3 bytes (opcode + 2 skip bytes).
        assert(self.bytes.items.len == start_len + 3);
        return skip_lo_pos;
    }

    /// Patch a placeholder skip with the real distance.
    ///
    /// `lo_pos` is the offset emitExecIf/emitExecSkip returned. `skip` counts
    /// bytes from the END of that instruction (the next opcode's first byte)
    /// forward, and the CALLER computes it from positions it recorded — this
    /// method writes what it is given and never guesses.
    ///
    /// A skip that does not fit u16 is the caller's located error (the SJON
    /// emitter reports it with a source span); the parameter is u16 so the
    /// overflow is a caller-side narrowing, and this method's own guards are
    /// `assert`s — the shape every neighbour in this file uses — which fire in
    /// Debug and ReleaseSafe and compile out of ReleaseFast/ReleaseSmall.
    /// Note `lo_pos` may be at most `len - 2` here: both patch sites are
    /// already-emitted instruction bytes, and the patched target
    /// (`lo_pos + 2 + skip`) must land inside the emitted stream.
    pub fn patchSkip(self: *Self, lo_pos: usize, skip: u16) void {
        assert(lo_pos + 2 <= self.bytes.items.len); // pre: both skip bytes exist
        assert(lo_pos + 2 + skip <= self.bytes.items.len); // pre: target inside the stream
        self.bytes.items[lo_pos] = @truncate(skip);
        self.bytes.items[lo_pos + 1] = @truncate(skip >> 8);
    }

    /// Emit write_time_uniform instruction.
    /// Writes time/canvas uniform data to buffer.
    /// Runtime provides: f32 time, f32 width, f32 height[, f32 aspect_ratio]
    pub fn writeTimeUniform(
        self: *Self,
        gpa: Allocator,
        buffer_id: u16,
        offset: u32,
        size: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .write_time_uniform);
        try self.emitVarint(gpa, buffer_id);
        try self.emitVarint(gpa, offset);
        try self.emitVarint(gpa, size);
        // Post-condition: at least 4 bytes emitted (opcode + 3 varints).
        assert(self.bytes.items.len >= start_len + 4);
    }

    /// Emit write_pointer_uniform instruction.
    /// Writes pointer/input uniform data to buffer.
    /// Runtime provides: f32 x, y, clickX, clickY, dx, dy, buttons, pressure
    pub fn writePointerUniform(
        self: *Self,
        gpa: Allocator,
        buffer_id: u16,
        offset: u32,
        size: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .write_pointer_uniform);
        try self.emitVarint(gpa, buffer_id);
        try self.emitVarint(gpa, offset);
        try self.emitVarint(gpa, size);
        // Post-condition: at least 4 bytes emitted (opcode + 3 varints).
        assert(self.bytes.items.len >= start_len + 4);
    }

    /// Emit write_audio_data instruction.
    /// Writes audio analysis data (e.g., FFT) to buffer.
    /// Runtime provides: array of f32 values from audio JS.
    pub fn writeAudioData(
        self: *Self,
        gpa: Allocator,
        buffer_id: u16,
        offset: u32,
        size: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(gpa, .write_audio_data);
        try self.emitVarint(gpa, buffer_id);
        try self.emitVarint(gpa, offset);
        try self.emitVarint(gpa, size);
        // Post-condition: at least 4 bytes emitted (opcode + 3 varints).
        assert(self.bytes.items.len >= start_len + 4);
    }
};

// ============================================================================
// Tests
// ============================================================================
