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
const OpCode = opcodes.OpCode;
const BufferUsage = opcodes.BufferUsage;
const LoadOp = opcodes.LoadOp;
const StoreOp = opcodes.StoreOp;
const PassType = opcodes.PassType;
const ElementType = opcodes.ElementType;

/// Bytecode emitter.
pub const Emitter = struct {
    const Self = @This();

    /// Default capacity covers simple shaders without reallocation.
    /// Based on typical bytecode sizes (simple triangle: ~400 bytes).
    pub const DEFAULT_CAPACITY: usize = 512;

    /// Output bytecode buffer.
    bytes: std.ArrayListUnmanaged(u8),

    pub const empty: Self = .{
        .bytes = .{},
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

    /// Emit an opcode.
    fn emitOpcode(self: *Self, allocator: Allocator, op: OpCode) !void {
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
        assert(@as(u8, @bitCast(usage)) != 0);

        const start_len = self.bytes.items.len;
        try self.emitOpcode(allocator, .create_buffer);
        try self.emitVarint(allocator, buffer_id);
        try self.emitVarint(allocator, size);
        try self.emitByte(allocator, @bitCast(usage));

        // Post-condition: bytecode was appended (at least 4 bytes: opcode + 2 varints + 1 byte)
        assert(self.bytes.items.len >= start_len + 4);
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

        try self.emitOpcode(allocator, .create_shader_concat);
        try self.emitVarint(allocator, shader_id);
        try self.emitByte(allocator, @intCast(data_ids.len));
        for (data_ids) |data_id| {
            try self.emitVarint(allocator, data_id);
        }
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
        try self.emitOpcode(allocator, .create_texture);
        try self.emitVarint(allocator, texture_id);
        try self.emitVarint(allocator, descriptor_data_id);
    }

    /// Emit create_sampler instruction.
    /// Creates a texture sampler with specified filtering/wrapping.
    pub fn createSampler(
        self: *Self,
        allocator: Allocator,
        sampler_id: u16,
        descriptor_data_id: u16,
    ) !void {
        try self.emitOpcode(allocator, .create_sampler);
        try self.emitVarint(allocator, sampler_id);
        try self.emitVarint(allocator, descriptor_data_id);
    }

    /// Emit create_bind_group_layout instruction.
    pub fn createBindGroupLayout(
        self: *Self,
        allocator: Allocator,
        layout_id: u16,
        descriptor_data_id: u16,
    ) !void {
        try self.emitOpcode(allocator, .create_bind_group_layout);
        try self.emitVarint(allocator, layout_id);
        try self.emitVarint(allocator, descriptor_data_id);
    }

    /// Emit create_pipeline_layout instruction.
    pub fn createPipelineLayout(
        self: *Self,
        allocator: Allocator,
        layout_id: u16,
        descriptor_data_id: u16,
    ) !void {
        try self.emitOpcode(allocator, .create_pipeline_layout);
        try self.emitVarint(allocator, layout_id);
        try self.emitVarint(allocator, descriptor_data_id);
    }

    /// Emit create_render_bundle instruction.
    /// Creates a pre-recorded render bundle for efficient draw command replay.
    pub fn createRenderBundle(
        self: *Self,
        allocator: Allocator,
        bundle_id: u16,
        descriptor_data_id: u16,
    ) !void {
        try self.emitOpcode(allocator, .create_render_bundle);
        try self.emitVarint(allocator, bundle_id);
        try self.emitVarint(allocator, descriptor_data_id);
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
        try self.emitOpcode(allocator, .create_image_bitmap);
        try self.emitVarint(allocator, bitmap_id);
        try self.emitVarint(allocator, blob_data_id);
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
        try self.emitOpcode(allocator, .create_texture_view);
        try self.emitVarint(allocator, view_id);
        try self.emitVarint(allocator, texture_id);
        try self.emitVarint(allocator, descriptor_data_id);
    }

    /// Emit create_query_set instruction.
    /// Creates a GPUQuerySet for occlusion or timestamp queries.
    pub fn createQuerySet(
        self: *Self,
        allocator: Allocator,
        query_set_id: u16,
        descriptor_data_id: u16,
    ) !void {
        try self.emitOpcode(allocator, .create_query_set);
        try self.emitVarint(allocator, query_set_id);
        try self.emitVarint(allocator, descriptor_data_id);
    }

    // ========================================================================
    // Pass Operations
    // ========================================================================

    /// Emit begin_render_pass instruction.
    /// depth_texture_id: use 0xFFFF for no depth attachment.
    pub fn beginRenderPass(
        self: *Self,
        allocator: Allocator,
        color_texture_id: u16,
        load_op: LoadOp,
        store_op: StoreOp,
        depth_texture_id: u16,
    ) !void {
        try self.emitOpcode(allocator, .begin_render_pass);
        try self.emitVarint(allocator, color_texture_id);
        try self.emitByte(allocator, @intFromEnum(load_op));
        try self.emitByte(allocator, @intFromEnum(store_op));
        try self.emitVarint(allocator, depth_texture_id);
    }

    /// Emit begin_compute_pass instruction.
    pub fn beginComputePass(self: *Self, allocator: Allocator) !void {
        try self.emitOpcode(allocator, .begin_compute_pass);
    }

    /// Emit set_pipeline instruction.
    pub fn setPipeline(self: *Self, allocator: Allocator, pipeline_id: u16) !void {
        try self.emitOpcode(allocator, .set_pipeline);
        try self.emitVarint(allocator, pipeline_id);
    }

    /// Emit set_bind_group instruction.
    pub fn setBindGroup(
        self: *Self,
        allocator: Allocator,
        slot: u8,
        group_id: u16,
    ) !void {
        try self.emitOpcode(allocator, .set_bind_group);
        try self.emitByte(allocator, slot);
        try self.emitVarint(allocator, group_id);
    }

    /// Emit set_vertex_buffer instruction.
    pub fn setVertexBuffer(
        self: *Self,
        allocator: Allocator,
        slot: u8,
        buffer_id: u16,
    ) !void {
        try self.emitOpcode(allocator, .set_vertex_buffer);
        try self.emitByte(allocator, slot);
        try self.emitVarint(allocator, buffer_id);
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
        try self.emitOpcode(allocator, .set_index_buffer);
        try self.emitVarint(allocator, buffer_id);
        try self.emitByte(allocator, format_id);
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
        assert(bundle_ids.len <= 16);

        try self.emitOpcode(allocator, .execute_bundles);
        try self.emitVarint(allocator, @intCast(bundle_ids.len));
        for (bundle_ids) |id| {
            try self.emitVarint(allocator, id);
        }
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
        try self.emitOpcode(allocator, .write_buffer);
        try self.emitVarint(allocator, buffer_id);
        try self.emitVarint(allocator, offset);
        try self.emitVarint(allocator, data_id);
    }

    /// Emit submit instruction.
    pub fn submit(self: *Self, allocator: Allocator) !void {
        try self.emitOpcode(allocator, .submit);
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
        try self.emitOpcode(allocator, .copy_buffer_to_buffer);
        try self.emitVarint(allocator, src_buffer);
        try self.emitVarint(allocator, src_offset);
        try self.emitVarint(allocator, dst_buffer);
        try self.emitVarint(allocator, dst_offset);
        try self.emitVarint(allocator, size);
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
        try self.emitOpcode(allocator, .copy_texture_to_texture);
        try self.emitVarint(allocator, src_texture);
        try self.emitVarint(allocator, dst_texture);
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
    ) !void {
        try self.emitOpcode(allocator, .copy_external_image_to_texture);
        try self.emitVarint(allocator, bitmap_id);
        try self.emitVarint(allocator, texture_id);
        try self.emitByte(allocator, mip_level);
        try self.emitVarint(allocator, origin_x);
        try self.emitVarint(allocator, origin_y);
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
        try self.emitOpcode(allocator, .init_wasm_module);
        try self.emitVarint(allocator, module_id);
        try self.emitVarint(allocator, wasm_data_id);
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
        try self.emitOpcode(allocator, .call_wasm_func);
        try self.emitVarint(allocator, call_id);
        try self.emitVarint(allocator, module_id);
        try self.emitVarint(allocator, func_name_id);
        // Args are pre-encoded: [count][arg_type, value?]...
        try self.bytes.appendSlice(allocator, args);
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
        try self.emitOpcode(allocator, .write_buffer_from_wasm);
        try self.emitVarint(allocator, call_id);
        try self.emitVarint(allocator, buffer_id);
        try self.emitVarint(allocator, offset);
        try self.emitVarint(allocator, byte_len);
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
        try self.emitOpcode(allocator, .exec_pass);
        try self.emitVarint(allocator, pass_id);
    }

    /// Emit define_pass instruction.
    pub fn definePass(
        self: *Self,
        allocator: Allocator,
        pass_id: u16,
        pass_type: PassType,
        descriptor_data_id: u16,
    ) !void {
        try self.emitOpcode(allocator, .define_pass);
        try self.emitVarint(allocator, pass_id);
        try self.emitByte(allocator, @intFromEnum(pass_type));
        try self.emitVarint(allocator, descriptor_data_id);
    }

    /// Emit end_pass_def instruction.
    pub fn endPassDef(self: *Self, allocator: Allocator) !void {
        try self.emitOpcode(allocator, .end_pass_def);
    }

    // ========================================================================
    // Data Generation
    // ========================================================================

    /// Emit create_typed_array instruction.
    /// Creates a typed array in runtime memory for later filling.
    pub fn createTypedArray(
        self: *Self,
        allocator: Allocator,
        array_id: u16,
        element_type: ElementType,
        element_count: u32,
    ) !void {
        try self.emitOpcode(allocator, .create_typed_array);
        try self.emitVarint(allocator, array_id);
        try self.emitByte(allocator, @intFromEnum(element_type));
        try self.emitVarint(allocator, element_count);
    }

    /// Emit fill_constant instruction.
    /// Fills array elements with a constant value.
    pub fn fillConstant(
        self: *Self,
        allocator: Allocator,
        array_id: u16,
        offset: u32,
        count: u32,
        stride: u8,
        value_data_id: u16,
    ) !void {
        try self.emitOpcode(allocator, .fill_constant);
        try self.emitVarint(allocator, array_id);
        try self.emitVarint(allocator, offset);
        try self.emitVarint(allocator, count);
        try self.emitByte(allocator, stride);
        try self.emitVarint(allocator, value_data_id);
    }

    /// Emit fill_random instruction.
    /// Fills array elements with random values in [min, max] using seeded PRNG.
    /// Params: array_id, offset, count, stride, seed_data_id, min_data_id, max_data_id
    /// The seed enables deterministic random generation (same seed = same output).
    pub fn fillRandom(
        self: *Self,
        allocator: Allocator,
        array_id: u16,
        offset: u32,
        count: u32,
        stride: u8,
        seed_data_id: u16,
        min_data_id: u16,
        max_data_id: u16,
    ) !void {
        try self.emitOpcode(allocator, .fill_random);
        try self.emitVarint(allocator, array_id);
        try self.emitVarint(allocator, offset);
        try self.emitVarint(allocator, count);
        try self.emitByte(allocator, stride);
        try self.emitVarint(allocator, seed_data_id);
        try self.emitVarint(allocator, min_data_id);
        try self.emitVarint(allocator, max_data_id);
    }

    /// Emit fill_linear instruction.
    /// Fills array elements with linear sequence: start, start+step, start+2*step, ...
    /// Params: array_id, offset, count, stride, start_data_id, step_data_id
    pub fn fillLinear(
        self: *Self,
        allocator: Allocator,
        array_id: u16,
        offset: u32,
        count: u32,
        stride: u8,
        start_data_id: u16,
        step_data_id: u16,
    ) !void {
        try self.emitOpcode(allocator, .fill_linear);
        try self.emitVarint(allocator, array_id);
        try self.emitVarint(allocator, offset);
        try self.emitVarint(allocator, count);
        try self.emitByte(allocator, stride);
        try self.emitVarint(allocator, start_data_id);
        try self.emitVarint(allocator, step_data_id);
    }

    /// Emit fill_element_index instruction.
    /// Fills array elements with scaled/biased element index: index * scale + bias
    /// Params: array_id, offset, count, stride, scale_data_id, bias_data_id
    pub fn fillElementIndex(
        self: *Self,
        allocator: Allocator,
        array_id: u16,
        offset: u32,
        count: u32,
        stride: u8,
        scale_data_id: u16,
        bias_data_id: u16,
    ) !void {
        try self.emitOpcode(allocator, .fill_element_index);
        try self.emitVarint(allocator, array_id);
        try self.emitVarint(allocator, offset);
        try self.emitVarint(allocator, count);
        try self.emitByte(allocator, stride);
        try self.emitVarint(allocator, scale_data_id);
        try self.emitVarint(allocator, bias_data_id);
    }

    /// Emit fill_expression instruction.
    /// Fills array elements by evaluating expression for each element.
    /// Expression can use: i (element index), n (total count), PI, random(), sin(), cos(), sqrt()
    pub fn fillExpression(
        self: *Self,
        allocator: Allocator,
        array_id: u16,
        offset: u32,
        count: u32,
        stride: u8,
        expr_data_id: u16,
    ) !void {
        try self.emitOpcode(allocator, .fill_expression);
        try self.emitVarint(allocator, array_id);
        try self.emitVarint(allocator, offset);
        try self.emitVarint(allocator, count);
        try self.emitByte(allocator, stride);
        try self.emitVarint(allocator, expr_data_id);
    }

    /// Emit write_buffer_from_array instruction.
    /// Copies runtime-generated array data to GPU buffer.
    pub fn writeBufferFromArray(
        self: *Self,
        allocator: Allocator,
        buffer_id: u16,
        buffer_offset: u32,
        array_id: u16,
    ) !void {
        try self.emitOpcode(allocator, .write_buffer_from_array);
        try self.emitVarint(allocator, buffer_id);
        try self.emitVarint(allocator, buffer_offset);
        try self.emitVarint(allocator, array_id);
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
        try self.emitOpcode(allocator, .write_time_uniform);
        try self.emitVarint(allocator, buffer_id);
        try self.emitVarint(allocator, offset);
        try self.emitVarint(allocator, size);
    }
};

// ============================================================================
// Tests
// ============================================================================

test {
    // Import tests from emitter/test.zig
    _ = @import("emitter/test.zig");
}
