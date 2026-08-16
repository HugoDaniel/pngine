//! Bytecode Emitter
//!
//! Produces PNGB bytecode from high-level operations.
//! Uses variable-length encoding for compact output.
//!
//! ## Performance
//!
//! Use `initWithCapacity` for best performance when bytecode size is known.
//! Default capacity is 512 bytes (covers simple shaders without reallocation).
//! Typical sizes:
//! - Simple triangle: ~400 bytes
//! - Rotating cube: ~600 bytes
//! - Textured cube: ~800 bytes
//!
//! ## Invariants
//!
//! - Bytecode is appended sequentially, no backpatching
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

    /// Default capacity covers simple shaders without reallocation.
    /// Based on typical bytecode sizes (simple triangle: ~400 bytes).
    pub const DEFAULT_CAPACITY: usize = 512;

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

    /// Initialize emitter with pre-allocated capacity.
    /// Use this when bytecode size can be estimated to avoid reallocations.
    ///
    /// Complexity: O(1)
    pub fn initWithCapacity(allocator: Allocator, capacity: usize) Allocator.Error!Self {
        var self: Self = .empty;
        try self.bytes.ensureTotalCapacity(allocator, capacity);
        return self;
    }

    /// Initialize emitter with default capacity (512 bytes).
    /// Suitable for most simple to medium shaders.
    ///
    /// Complexity: O(1)
    pub fn initDefault(allocator: Allocator) Allocator.Error!Self {
        return initWithCapacity(allocator, DEFAULT_CAPACITY);
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.bytes.deinit(allocator);
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
    pub fn toOwnedSlice(self: *Self, allocator: Allocator) ![]u8 {
        return self.bytes.toOwnedSlice(allocator);
    }

    // ========================================================================
    // Low-level emission
    // ========================================================================

    /// Emit a single byte.
    fn emitByte(self: *Self, allocator: Allocator, byte: u8) !void {
        try self.bytes.append(allocator, byte);
    }

    /// Emit a varint.
    fn emitVarint(self: *Self, allocator: Allocator, value: u32) !void {
        var buffer: [4]u8 = undefined;
        const encoded_len = opcodes.encodeVarint(value, &buffer);
        try self.bytes.appendSlice(allocator, buffer[0..encoded_len]);
    }

    /// Emit a raw u32 (4 bytes, little-endian). Used for f32 bit patterns.
    fn emitRawU32(self: *Self, allocator: Allocator, value: u32) !void {
        const bytes: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, value));
        try self.bytes.appendSlice(allocator, &bytes);
    }

    /// Emit an opcode. Also records the plugin the opcode requires (if any) into
    /// `plugins_used` — the single chokepoint every emit method funnels through,
    /// so variant detection can never miss an emitted opcode (item 2.2).
    fn emitOpcode(self: *Self, allocator: Allocator, op: OpCode) !void {
        if (opcodes.pluginForOpcode(op)) |p| self.plugins_used.enable(p);
        try self.emitByte(allocator, @intFromEnum(op));
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
        allocator: Allocator,
        buffer_id: u16,
        size: u32,
        usage: BufferUsage,
    ) !void {
        // Pre-condition: must have at least one usage flag
        assert(@as(u16, @bitCast(usage)) != 0);

        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .create_buffer);
        try self.emitVarint(allocator, buffer_id);
        try self.emitVarint(allocator, size);
        const usage_bits: u16 = @bitCast(usage);
        try self.emitByte(allocator, @truncate(usage_bits));
        try self.emitByte(allocator, @truncate(usage_bits >> 8));

        // Post-condition: bytecode was appended (at least 5 bytes: opcode + 2 varints + 2 bytes)
        assert(self.bytes.items.len >= start_len + 5);
    }

    /// Emit create_shader_module instruction.
    /// Creates a shader module from data section.
    pub fn createShaderModule(
        self: *Self,
        allocator: Allocator,
        shader_id: u16,
        code_data_id: u16,
    ) !void {
        // Pre-condition: IDs are within valid range (implicitly u16)
        const start_len = self.bytes.items.len;

        try self.emitOpcode(allocator, .create_shader_module);
        try self.emitVarint(allocator, shader_id);
        try self.emitVarint(allocator, code_data_id);

        // Post-condition: at least 3 bytes emitted (opcode + 2 varints)
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit create_shader_concat instruction.
    /// Creates a shader module by concatenating multiple data sections (WGSL composition).
    /// Params: shader_id, count, data_id_0, data_id_1, ...
    pub fn createShaderConcat(
        self: *Self,
        allocator: Allocator,
        shader_id: u16,
        data_ids: []const u16,
    ) !void {
        // Pre-conditions
        assert(data_ids.len > 0);
        assert(data_ids.len <= 255);

        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .create_shader_concat);
        try self.emitVarint(allocator, shader_id);
        try self.emitByte(allocator, @intCast(data_ids.len));
        for (data_ids) |data_id| {
            try self.emitVarint(allocator, data_id);
        }

        // Post-condition: opcode + shader_id varint + count byte + one varint per id.
        assert(self.bytes.items.len >= start_len + 3 + data_ids.len);
    }

    /// Emit create_render_pipeline instruction.
    /// Creates a render pipeline from descriptor data.
    pub fn createRenderPipeline(
        self: *Self,
        allocator: Allocator,
        pipeline_id: u16,
        descriptor_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;

        try self.emitOpcode(allocator, .create_render_pipeline);
        try self.emitVarint(allocator, pipeline_id);
        try self.emitVarint(allocator, descriptor_data_id);

        // Post-condition: bytecode was appended
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit create_compute_pipeline instruction.
    pub fn createComputePipeline(
        self: *Self,
        allocator: Allocator,
        pipeline_id: u16,
        descriptor_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;

        try self.emitOpcode(allocator, .create_compute_pipeline);
        try self.emitVarint(allocator, pipeline_id);
        try self.emitVarint(allocator, descriptor_data_id);

        // Post-condition: bytecode was appended
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit create_bind_group instruction.
    pub fn createBindGroup(
        self: *Self,
        allocator: Allocator,
        group_id: u16,
        layout_id: u16,
        entry_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;

        try self.emitOpcode(allocator, .create_bind_group);
        try self.emitVarint(allocator, group_id);
        try self.emitVarint(allocator, layout_id);
        try self.emitVarint(allocator, entry_data_id);

        // Post-condition: at least 4 bytes emitted
        assert(self.bytes.items.len >= start_len + 4);
    }

    /// Emit create_texture instruction.
    /// Creates a GPU texture with specified dimensions and format.
    pub fn createTexture(
        self: *Self,
        allocator: Allocator,
        texture_id: u16,
        descriptor_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .create_texture);
        try self.emitVarint(allocator, texture_id);
        try self.emitVarint(allocator, descriptor_data_id);
        // Post-condition: at least 3 bytes emitted (opcode + 2 varints).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit create_sampler instruction.
    /// Creates a texture sampler with specified filtering/wrapping.
    pub fn createSampler(
        self: *Self,
        allocator: Allocator,
        sampler_id: u16,
        descriptor_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .create_sampler);
        try self.emitVarint(allocator, sampler_id);
        try self.emitVarint(allocator, descriptor_data_id);
        // Post-condition: at least 3 bytes emitted (opcode + 2 varints).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit create_bind_group_layout instruction.
    pub fn createBindGroupLayout(
        self: *Self,
        allocator: Allocator,
        layout_id: u16,
        descriptor_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .create_bind_group_layout);
        try self.emitVarint(allocator, layout_id);
        try self.emitVarint(allocator, descriptor_data_id);
        // Post-condition: at least 3 bytes emitted (opcode + 2 varints).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit create_pipeline_layout instruction.
    pub fn createPipelineLayout(
        self: *Self,
        allocator: Allocator,
        layout_id: u16,
        descriptor_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .create_pipeline_layout);
        try self.emitVarint(allocator, layout_id);
        try self.emitVarint(allocator, descriptor_data_id);
        // Post-condition: at least 3 bytes emitted (opcode + 2 varints).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit create_render_bundle instruction.
    /// Creates a pre-recorded render bundle for efficient draw command replay.
    pub fn createRenderBundle(
        self: *Self,
        allocator: Allocator,
        bundle_id: u16,
        descriptor_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .create_render_bundle);
        try self.emitVarint(allocator, bundle_id);
        try self.emitVarint(allocator, descriptor_data_id);
        // Post-condition: at least 3 bytes emitted (opcode + 2 varints).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit create_image_bitmap instruction.
    /// Creates an ImageBitmap from blob data in data section.
    /// blob_data_id points to entry with format: [mime_len:u8][mime:bytes][data:bytes]
    pub fn createImageBitmap(
        self: *Self,
        allocator: Allocator,
        bitmap_id: u16,
        blob_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .create_image_bitmap);
        try self.emitVarint(allocator, bitmap_id);
        try self.emitVarint(allocator, blob_data_id);
        // Post-condition: at least 3 bytes emitted (opcode + 2 varints).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit create_texture_view instruction.
    /// Creates a GPUTextureView from an existing texture.
    pub fn createTextureView(
        self: *Self,
        allocator: Allocator,
        view_id: u16,
        texture_id: u16,
        descriptor_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .create_texture_view);
        try self.emitVarint(allocator, view_id);
        try self.emitVarint(allocator, texture_id);
        try self.emitVarint(allocator, descriptor_data_id);
        // Post-condition: at least 4 bytes emitted (opcode + 3 varints).
        assert(self.bytes.items.len >= start_len + 4);
    }

    /// Emit create_query_set instruction.
    /// Creates a GPUQuerySet for occlusion or timestamp queries.
    pub fn createQuerySet(
        self: *Self,
        allocator: Allocator,
        query_set_id: u16,
        descriptor_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .create_query_set);
        try self.emitVarint(allocator, query_set_id);
        try self.emitVarint(allocator, descriptor_data_id);
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
        allocator: Allocator,
        color_texture_id: u16,
        load_op: LoadOp,
        store_op: StoreOp,
        depth_texture_id: u16,
        clear_r: u8,
        clear_g: u8,
        clear_b: u8,
        clear_a: u8,
        resolve_texture_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .begin_render_pass);
        try self.emitVarint(allocator, color_texture_id);
        try self.emitByte(allocator, @intFromEnum(load_op));
        try self.emitByte(allocator, @intFromEnum(store_op));
        try self.emitVarint(allocator, depth_texture_id);
        try self.emitByte(allocator, clear_r);
        try self.emitByte(allocator, clear_g);
        try self.emitByte(allocator, clear_b);
        try self.emitByte(allocator, clear_a);
        try self.emitVarint(allocator, resolve_texture_id);
        // Post-condition: opcode + 3 varints (≥1 each) + 6 bytes = at least 10.
        assert(self.bytes.items.len >= start_len + 10);
    }

    /// Emit begin_render_pass_pool instruction.
    /// Pool variant of begin_render_pass that alternates render target texture each frame.
    /// Runtime computes: actual_tex_id = base_tex_id + (frame_counter + offset) % pool_size
    /// depth_texture_id: use 0xFFFF for no depth attachment.
    pub fn beginRenderPassPool(
        self: *Self,
        allocator: Allocator,
        base_texture_id: u16,
        pool_size: u8,
        offset: u8,
        load_op: LoadOp,
        store_op: StoreOp,
        depth_texture_id: u16,
        clear_r: u8,
        clear_g: u8,
        clear_b: u8,
        clear_a: u8,
    ) !void {
        // Pre-conditions
        assert(pool_size > 0); // Pool must have at least 1 texture
        assert(offset < pool_size); // Offset must be within pool

        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .begin_render_pass_pool);
        try self.emitVarint(allocator, base_texture_id);
        try self.emitByte(allocator, pool_size);
        try self.emitByte(allocator, offset);
        try self.emitByte(allocator, @intFromEnum(load_op));
        try self.emitByte(allocator, @intFromEnum(store_op));
        try self.emitVarint(allocator, depth_texture_id);
        try self.emitByte(allocator, clear_r);
        try self.emitByte(allocator, clear_g);
        try self.emitByte(allocator, clear_b);
        try self.emitByte(allocator, clear_a);
        // Post-condition: opcode + 2 varints (≥1 each) + 8 bytes = at least 11.
        assert(self.bytes.items.len >= start_len + 11);
    }

    /// Color attachment for MRT render passes.
    pub const ColorAttachment = struct {
        texture_id: u16,
        load_op: LoadOp,
        store_op: StoreOp,
        clear_r: u8,
        clear_g: u8,
        clear_b: u8,
        clear_a: u8,
    };

    /// Emit begin_render_pass_mrt instruction for multiple color attachments.
    /// depth_texture_id: use 0xFFFF for no depth attachment.
    pub fn beginRenderPassMRT(
        self: *Self,
        allocator: Allocator,
        attachments: []const ColorAttachment,
        depth_texture_id: u16,
    ) !void {
        // Pre-conditions
        assert(attachments.len > 0 and attachments.len <= MAX_MRT);

        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .begin_render_pass_mrt);
        try self.emitByte(allocator, @intCast(attachments.len));

        for (attachments) |att| {
            try self.emitVarint(allocator, att.texture_id);
            try self.emitByte(allocator, @intFromEnum(att.load_op));
            try self.emitByte(allocator, @intFromEnum(att.store_op));
            try self.emitByte(allocator, att.clear_r);
            try self.emitByte(allocator, att.clear_g);
            try self.emitByte(allocator, att.clear_b);
            try self.emitByte(allocator, att.clear_a);
        }

        try self.emitVarint(allocator, depth_texture_id);
        // Post-condition: opcode + count byte + depth varint + 7 bytes per attachment
        // (texture_id varint ≥1 + 6 clear/op bytes).
        assert(self.bytes.items.len >= start_len + 3 + 7 * attachments.len);
    }

    /// Emit begin_compute_pass instruction.
    pub fn beginComputePass(self: *Self, allocator: Allocator) !void {
        try self.emitOpcode(allocator, .begin_compute_pass);
    }

    /// Emit set_pipeline instruction.
    pub fn setPipeline(self: *Self, allocator: Allocator, pipeline_id: u16) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .set_pipeline);
        try self.emitVarint(allocator, pipeline_id);
        // Post-condition: at least 2 bytes emitted (opcode + 1 varint).
        assert(self.bytes.items.len >= start_len + 2);
    }

    /// Emit set_bind_group instruction.
    pub fn setBindGroup(
        self: *Self,
        allocator: Allocator,
        slot: u8,
        group_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .set_bind_group);
        try self.emitByte(allocator, slot);
        try self.emitVarint(allocator, group_id);
        // Post-condition: at least 3 bytes emitted (opcode + slot byte + varint).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit set_vertex_buffer instruction.
    pub fn setVertexBuffer(
        self: *Self,
        allocator: Allocator,
        slot: u8,
        buffer_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .set_vertex_buffer);
        try self.emitByte(allocator, slot);
        try self.emitVarint(allocator, buffer_id);
        // Post-condition: at least 3 bytes emitted (opcode + slot byte + varint).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit set_vertex_buffer_pool instruction for pooled buffers.
    /// Runtime computes: actual_id = base_id + (frame_counter + offset) % pool_size
    pub fn setVertexBufferPool(
        self: *Self,
        allocator: Allocator,
        slot: u8,
        base_buffer_id: u16,
        pool_size: u8,
        offset: u8,
    ) !void {
        // Pre-conditions
        assert(pool_size > 0); // Pool must have at least 1 buffer
        assert(offset < pool_size); // Offset must be within pool

        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .set_vertex_buffer_pool);
        try self.emitByte(allocator, slot);
        try self.emitVarint(allocator, base_buffer_id);
        try self.emitByte(allocator, pool_size);
        try self.emitByte(allocator, offset);

        // Post-condition: at least 5 bytes emitted
        assert(self.bytes.items.len >= start_len + 5);
    }

    /// Emit set_bind_group_pool instruction for pooled bind groups.
    /// Runtime computes: actual_id = base_id + (frame_counter + offset) % pool_size
    pub fn setBindGroupPool(
        self: *Self,
        allocator: Allocator,
        slot: u8,
        base_group_id: u16,
        pool_size: u8,
        offset: u8,
    ) !void {
        // Pre-conditions
        assert(pool_size > 0); // Pool must have at least 1 bind group
        assert(offset < pool_size); // Offset must be within pool

        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .set_bind_group_pool);
        try self.emitByte(allocator, slot);
        try self.emitVarint(allocator, base_group_id);
        try self.emitByte(allocator, pool_size);
        try self.emitByte(allocator, offset);

        // Post-condition: at least 5 bytes emitted
        assert(self.bytes.items.len >= start_len + 5);
    }

    /// Emit set_index_buffer instruction.
    pub fn setIndexBuffer(
        self: *Self,
        allocator: Allocator,
        buffer_id: u16,
        format_id: u8,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .set_index_buffer);
        try self.emitVarint(allocator, buffer_id);
        try self.emitByte(allocator, format_id);
        // Post-condition: at least 3 bytes emitted (opcode + varint + format byte).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit draw instruction with full WebGPU parameters.
    /// Params: vertex_count, instance_count, first_vertex, first_instance
    pub fn draw(
        self: *Self,
        allocator: Allocator,
        vertex_count: u32,
        instance_count: u32,
        first_vertex: u32,
        first_instance: u32,
    ) !void {
        // Pre-conditions
        assert(vertex_count > 0); // Must draw at least 1 vertex
        assert(instance_count > 0); // Must draw at least 1 instance

        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .draw);
        try self.emitVarint(allocator, vertex_count);
        try self.emitVarint(allocator, instance_count);
        try self.emitVarint(allocator, first_vertex);
        try self.emitVarint(allocator, first_instance);

        // Post-condition: at least 5 bytes emitted
        assert(self.bytes.items.len >= start_len + 5);
    }

    /// Emit draw_indexed instruction with full WebGPU parameters.
    /// Params: index_count, instance_count, first_index, base_vertex, first_instance
    pub fn drawIndexed(
        self: *Self,
        allocator: Allocator,
        index_count: u32,
        instance_count: u32,
        first_index: u32,
        base_vertex: u32,
        first_instance: u32,
    ) !void {
        // Pre-conditions
        assert(index_count > 0); // Must draw at least 1 index
        assert(instance_count > 0); // Must draw at least 1 instance

        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .draw_indexed);
        try self.emitVarint(allocator, index_count);
        try self.emitVarint(allocator, instance_count);
        try self.emitVarint(allocator, first_index);
        try self.emitVarint(allocator, base_vertex);
        try self.emitVarint(allocator, first_instance);

        // Post-condition: at least 6 bytes emitted
        assert(self.bytes.items.len >= start_len + 6);
    }

    /// Emit dispatch instruction.
    pub fn dispatch(
        self: *Self,
        allocator: Allocator,
        x: u32,
        y: u32,
        z: u32,
    ) !void {
        // Pre-conditions: workgroup dimensions must be positive
        assert(x > 0);
        assert(y > 0);
        assert(z > 0);

        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .dispatch);
        try self.emitVarint(allocator, x);
        try self.emitVarint(allocator, y);
        try self.emitVarint(allocator, z);

        // Post-condition: at least 4 bytes emitted
        assert(self.bytes.items.len >= start_len + 4);
    }

    /// Emit draw_indirect instruction.
    /// Params: buffer_id, offset
    pub fn drawIndirect(
        self: *Self,
        allocator: Allocator,
        buffer_id: u16,
        offset: u32,
    ) !void {
        assert(buffer_id < 0xFFFF);

        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .draw_indirect);
        try self.emitVarint(allocator, buffer_id);
        try self.emitVarint(allocator, offset);

        // Post-condition: at least 3 bytes emitted
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit draw_indexed_indirect instruction.
    /// Params: buffer_id, offset
    pub fn drawIndexedIndirect(
        self: *Self,
        allocator: Allocator,
        buffer_id: u16,
        offset: u32,
    ) !void {
        assert(buffer_id < 0xFFFF);

        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .draw_indexed_indirect);
        try self.emitVarint(allocator, buffer_id);
        try self.emitVarint(allocator, offset);

        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit dispatch_indirect instruction.
    /// Params: buffer_id, offset
    pub fn dispatchIndirect(
        self: *Self,
        allocator: Allocator,
        buffer_id: u16,
        offset: u32,
    ) !void {
        assert(buffer_id < 0xFFFF);

        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .dispatch_indirect);
        try self.emitVarint(allocator, buffer_id);
        try self.emitVarint(allocator, offset);

        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit set_viewport instruction.
    /// Params: x, y, width, height (varints), minDepth, maxDepth (raw f32 as u32 bits)
    pub fn setViewport(
        self: *Self,
        allocator: Allocator,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        min_depth_bits: u32,
        max_depth_bits: u32,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .set_viewport);
        try self.emitVarint(allocator, x);
        try self.emitVarint(allocator, y);
        try self.emitVarint(allocator, width);
        try self.emitVarint(allocator, height);
        try self.emitRawU32(allocator, min_depth_bits);
        try self.emitRawU32(allocator, max_depth_bits);

        // Post-condition: opcode + 4 varints (min 4) + 8 raw bytes = at least 13
        assert(self.bytes.items.len >= start_len + 13);
    }

    /// Emit set_pass_occlusion_query_set instruction (state before beginRenderPass).
    pub fn setPassOcclusionQuerySet(self: *Self, allocator: Allocator, query_set_id: u16) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .set_pass_occlusion_query_set);
        try self.emitVarint(allocator, query_set_id);
        // Post-condition: at least 2 bytes emitted (opcode + 1 varint).
        assert(self.bytes.items.len >= start_len + 2);
    }

    /// Emit set_pass_depth_stencil_ops instruction (state before beginRenderPass).
    /// Overrides the default depth/stencil load/store ops for the next render pass.
    pub fn setPassDepthStencilOps(self: *Self, allocator: Allocator, depth_load_op: LoadOp, depth_store_op: StoreOp, stencil_load_op: LoadOp, stencil_store_op: StoreOp) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .set_pass_depth_stencil_ops);
        try self.emitByte(allocator, @intFromEnum(depth_load_op));
        try self.emitByte(allocator, @intFromEnum(depth_store_op));
        try self.emitByte(allocator, @intFromEnum(stencil_load_op));
        try self.emitByte(allocator, @intFromEnum(stencil_store_op));
        // Post-condition: exactly 5 bytes emitted (opcode + 4 op bytes).
        assert(self.bytes.items.len == start_len + 5);
    }

    /// Emit set_pass_timestamp_writes instruction (state before beginRenderPass/ComputePass).
    pub fn setPassTimestampWrites(self: *Self, allocator: Allocator, query_set_id: u16, begin_idx: u32, end_idx: u32) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .set_pass_timestamp_writes);
        try self.emitVarint(allocator, query_set_id);
        try self.emitVarint(allocator, begin_idx);
        try self.emitVarint(allocator, end_idx);
        // Post-condition: at least 4 bytes emitted (opcode + 3 varints).
        assert(self.bytes.items.len >= start_len + 4);
    }

    /// Emit begin_occlusion_query instruction.
    pub fn beginOcclusionQuery(self: *Self, allocator: Allocator, query_index: u32) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .begin_occlusion_query);
        try self.emitVarint(allocator, query_index);
        // Post-condition: at least 2 bytes emitted (opcode + 1 varint).
        assert(self.bytes.items.len >= start_len + 2);
    }

    /// Emit end_occlusion_query instruction.
    pub fn endOcclusionQuery(self: *Self, allocator: Allocator) !void {
        try self.emitOpcode(allocator, .end_occlusion_query);
    }

    /// Emit resolve_query_set instruction.
    pub fn resolveQuerySet(self: *Self, allocator: Allocator, query_set_id: u16, first_query: u32, query_count: u32, dest_buffer_id: u16, dest_offset: u32) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .resolve_query_set);
        try self.emitVarint(allocator, query_set_id);
        try self.emitVarint(allocator, first_query);
        try self.emitVarint(allocator, query_count);
        try self.emitVarint(allocator, dest_buffer_id);
        try self.emitVarint(allocator, dest_offset);
        // Post-condition: at least 6 bytes emitted (opcode + 5 varints).
        assert(self.bytes.items.len >= start_len + 6);
    }

    /// Emit set_stencil_reference instruction.
    /// Params: reference (varint)
    pub fn setStencilReference(
        self: *Self,
        allocator: Allocator,
        reference: u32,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .set_stencil_reference);
        try self.emitVarint(allocator, reference);

        assert(self.bytes.items.len >= start_len + 2);
    }

    /// Emit set_blend_constant instruction.
    /// Params: r, g, b, a — each an f32 bit pattern (raw u32 LE).
    pub fn setBlendConstant(
        self: *Self,
        allocator: Allocator,
        r_bits: u32,
        g_bits: u32,
        b_bits: u32,
        a_bits: u32,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .set_blend_constant);
        try self.emitRawU32(allocator, r_bits);
        try self.emitRawU32(allocator, g_bits);
        try self.emitRawU32(allocator, b_bits);
        try self.emitRawU32(allocator, a_bits);

        // Post-condition: opcode + 16 raw bytes = exactly 17.
        assert(self.bytes.items.len == start_len + 17);
    }

    /// Emit set_pass_clear_values instruction (state before beginRenderPass).
    /// Overrides the default depth/stencil clear values (1.0 / 0) for the next
    /// render pass. Params: depth as an f32 bit pattern, stencil as u32.
    pub fn setPassClearValues(
        self: *Self,
        allocator: Allocator,
        depth_bits: u32,
        stencil_value: u32,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .set_pass_clear_values);
        try self.emitRawU32(allocator, depth_bits);
        try self.emitRawU32(allocator, stencil_value);

        // Post-condition: opcode + 8 raw bytes = exactly 9.
        assert(self.bytes.items.len == start_len + 9);
    }

    /// Emit set_scissor_rect instruction.
    /// Params: x, y, width, height (varints)
    pub fn setScissorRect(
        self: *Self,
        allocator: Allocator,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .set_scissor_rect);
        try self.emitVarint(allocator, x);
        try self.emitVarint(allocator, y);
        try self.emitVarint(allocator, width);
        try self.emitVarint(allocator, height);

        assert(self.bytes.items.len >= start_len + 5);
    }

    /// Emit execute_bundles instruction.
    /// Replays pre-recorded render bundles in the current render pass.
    /// Params: bundle_count, bundle_id_0, bundle_id_1, ...
    pub fn executeBundles(
        self: *Self,
        allocator: Allocator,
        bundle_ids: []const u16,
    ) !void {
        // Pre-conditions
        assert(bundle_ids.len > 0);
        assert(bundle_ids.len <= MAX_BUNDLES);

        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .execute_bundles);
        try self.emitVarint(allocator, @intCast(bundle_ids.len));
        for (bundle_ids) |id| {
            try self.emitVarint(allocator, id);
        }

        // Post-condition: opcode + count varint + one varint per bundle id.
        assert(self.bytes.items.len >= start_len + 2 + bundle_ids.len);
    }

    /// Emit end_pass instruction.
    pub fn endPass(self: *Self, allocator: Allocator) !void {
        try self.emitOpcode(allocator, .end_pass);
    }

    // ========================================================================
    // Queue Operations
    // ========================================================================

    /// Emit write_buffer instruction.
    pub fn writeBuffer(
        self: *Self,
        allocator: Allocator,
        buffer_id: u16,
        offset: u32,
        data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .write_buffer);
        try self.emitVarint(allocator, buffer_id);
        try self.emitVarint(allocator, offset);
        try self.emitVarint(allocator, data_id);
        // Post-condition: at least 4 bytes emitted (opcode + 3 varints).
        assert(self.bytes.items.len >= start_len + 4);
    }

    /// Emit submit instruction.
    pub fn submit(self: *Self, allocator: Allocator) !void {
        try self.emitOpcode(allocator, .submit);
    }

    /// Emit write_uniform instruction.
    /// Writes runtime-resolved uniform data to buffer.
    /// Params: buffer_id, uniform_id (selects data source)
    pub fn writeUniform(
        self: *Self,
        allocator: Allocator,
        buffer_id: u16,
        uniform_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .write_uniform);
        try self.emitVarint(allocator, buffer_id);
        try self.emitVarint(allocator, uniform_id);
        // Post-condition: at least 3 bytes emitted (opcode + 2 varints).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit copy_buffer_to_buffer instruction.
    /// Copies data from source buffer to destination buffer.
    /// Params: src_buffer, src_offset, dst_buffer, dst_offset, size
    pub fn copyBufferToBuffer(
        self: *Self,
        allocator: Allocator,
        src_buffer: u16,
        src_offset: u32,
        dst_buffer: u16,
        dst_offset: u32,
        size: u32,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .copy_buffer_to_buffer);
        try self.emitVarint(allocator, src_buffer);
        try self.emitVarint(allocator, src_offset);
        try self.emitVarint(allocator, dst_buffer);
        try self.emitVarint(allocator, dst_offset);
        try self.emitVarint(allocator, size);
        // Post-condition: at least 6 bytes emitted (opcode + 5 varints).
        assert(self.bytes.items.len >= start_len + 6);
    }

    /// Emit copy_texture_to_texture instruction.
    /// Copies pixels from source texture to destination texture.
    /// Params: src_texture, dst_texture
    pub fn copyTextureToTexture(
        self: *Self,
        allocator: Allocator,
        src_texture: u16,
        dst_texture: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .copy_texture_to_texture);
        try self.emitVarint(allocator, src_texture);
        try self.emitVarint(allocator, dst_texture);
        // Post-condition: at least 3 bytes emitted (opcode + 2 varints).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit copy_external_image_to_texture instruction.
    /// Copies an ImageBitmap to a GPU texture.
    pub fn copyExternalImageToTexture(
        self: *Self,
        allocator: Allocator,
        bitmap_id: u16,
        texture_id: u16,
        mip_level: u8,
        origin_x: u16,
        origin_y: u16,
        origin_z: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .copy_external_image_to_texture);
        try self.emitVarint(allocator, bitmap_id);
        try self.emitVarint(allocator, texture_id);
        try self.emitByte(allocator, mip_level);
        try self.emitVarint(allocator, origin_x);
        try self.emitVarint(allocator, origin_y);
        try self.emitVarint(allocator, origin_z);
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
        allocator: Allocator,
        module_id: u16,
        wasm_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .init_wasm_module);
        try self.emitVarint(allocator, module_id);
        try self.emitVarint(allocator, wasm_data_id);
        // Post-condition: at least 3 bytes emitted (opcode + 2 varints).
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit call_wasm_func instruction.
    /// Calls an exported WASM function with arguments.
    /// Args are encoded as: [arg_type:u8][value:varies (0-4 bytes)]
    pub fn callWasmFunc(
        self: *Self,
        allocator: Allocator,
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
        try self.emitOpcode(allocator, .call_wasm_func);
        try self.emitVarint(allocator, call_id);
        try self.emitVarint(allocator, module_id);
        try self.emitVarint(allocator, func_name_id);
        // Args are pre-encoded: [count][arg_type, value?]...
        try self.bytes.appendSlice(allocator, args);
        // Post-condition: opcode + 3 varints (≥1 each) + the exact args blob.
        assert(self.bytes.items.len >= start_len + 4 + args.len);
    }

    /// Emit write_buffer_from_wasm instruction.
    /// Copies bytes from WASM memory (at call result pointer) to GPU buffer.
    pub fn writeBufferFromWasm(
        self: *Self,
        allocator: Allocator,
        call_id: u16,
        buffer_id: u16,
        offset: u32,
        byte_len: u32,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .write_buffer_from_wasm);
        try self.emitVarint(allocator, call_id);
        try self.emitVarint(allocator, buffer_id);
        try self.emitVarint(allocator, offset);
        try self.emitVarint(allocator, byte_len);
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
        allocator: Allocator,
        frame_id: u16,
        name_string_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;

        try self.emitOpcode(allocator, .define_frame);
        try self.emitVarint(allocator, frame_id);
        try self.emitVarint(allocator, name_string_id);

        // Post-condition: at least 3 bytes emitted
        assert(self.bytes.items.len >= start_len + 3);
    }

    /// Emit end_frame instruction.
    /// Must be paired with a preceding defineFrame.
    pub fn endFrame(self: *Self, allocator: Allocator) !void {
        // Pre-condition: bytecode has content (from defineFrame)
        assert(self.bytes.items.len > 0);

        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .end_frame);

        // Post-condition: 1 byte emitted
        assert(self.bytes.items.len == start_len + 1);
    }

    /// Emit exec_pass instruction.
    pub fn execPass(self: *Self, allocator: Allocator, pass_id: u16) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .exec_pass);
        try self.emitVarint(allocator, pass_id);
        // Post-condition: at least 2 bytes emitted (opcode + 1 varint).
        assert(self.bytes.items.len >= start_len + 2);
    }

    /// Emit exec_pass_once instruction (run-once semantics for init passes).
    /// The executor tracks which passes have been executed and skips duplicates.
    pub fn execPassOnce(self: *Self, allocator: Allocator, pass_id: u16) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .exec_pass_once);
        try self.emitVarint(allocator, pass_id);
        // Post-condition: at least 2 bytes emitted (opcode + 1 varint).
        assert(self.bytes.items.len >= start_len + 2);
    }

    /// Emit define_pass instruction.
    pub fn definePass(
        self: *Self,
        allocator: Allocator,
        pass_id: u16,
        pass_type: PassType,
        descriptor_data_id: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .define_pass);
        try self.emitVarint(allocator, pass_id);
        try self.emitByte(allocator, @intFromEnum(pass_type));
        try self.emitVarint(allocator, descriptor_data_id);
        // Post-condition: opcode + 2 varints (≥1 each) + pass_type byte = at least 4.
        assert(self.bytes.items.len >= start_len + 4);
    }

    /// Emit end_pass_def instruction.
    pub fn endPassDef(self: *Self, allocator: Allocator) !void {
        try self.emitOpcode(allocator, .end_pass_def);
    }

    /// Emit write_time_uniform instruction.
    /// Writes time/canvas uniform data to buffer.
    /// Runtime provides: f32 time, f32 width, f32 height[, f32 aspect_ratio]
    pub fn writeTimeUniform(
        self: *Self,
        allocator: Allocator,
        buffer_id: u16,
        offset: u32,
        size: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .write_time_uniform);
        try self.emitVarint(allocator, buffer_id);
        try self.emitVarint(allocator, offset);
        try self.emitVarint(allocator, size);
        // Post-condition: at least 4 bytes emitted (opcode + 3 varints).
        assert(self.bytes.items.len >= start_len + 4);
    }

    /// Emit write_pointer_uniform instruction.
    /// Writes pointer/input uniform data to buffer.
    /// Runtime provides: f32 x, y, clickX, clickY, dx, dy, buttons, pressure
    pub fn writePointerUniform(
        self: *Self,
        allocator: Allocator,
        buffer_id: u16,
        offset: u32,
        size: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .write_pointer_uniform);
        try self.emitVarint(allocator, buffer_id);
        try self.emitVarint(allocator, offset);
        try self.emitVarint(allocator, size);
        // Post-condition: at least 4 bytes emitted (opcode + 3 varints).
        assert(self.bytes.items.len >= start_len + 4);
    }

    /// Emit write_audio_data instruction.
    /// Writes audio analysis data (e.g., FFT) to buffer.
    /// Runtime provides: array of f32 values from audio JS.
    pub fn writeAudioData(
        self: *Self,
        allocator: Allocator,
        buffer_id: u16,
        offset: u32,
        size: u16,
    ) !void {
        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .write_audio_data);
        try self.emitVarint(allocator, buffer_id);
        try self.emitVarint(allocator, offset);
        try self.emitVarint(allocator, size);
        // Post-condition: at least 4 bytes emitted (opcode + 3 varints).
        assert(self.bytes.items.len >= start_len + 4);
    }
};

// ============================================================================
// Tests
// ============================================================================
