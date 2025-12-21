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
    pub fn createBuffer(
        self: *Self,
        allocator: Allocator,
        buffer_id: u16,
        size: u32,
        usage: BufferUsage,
    ) !void {
        try self.emitOpcode(allocator, .create_buffer);
        try self.emitVarint(allocator, buffer_id);
        try self.emitVarint(allocator, size);
        try self.emitByte(allocator, @bitCast(usage));
    }

    /// Emit create_shader_module instruction.
    /// Creates a shader module from data section.
    pub fn createShaderModule(
        self: *Self,
        allocator: Allocator,
        shader_id: u16,
        code_data_id: u16,
    ) !void {
        try self.emitOpcode(allocator, .create_shader_module);
        try self.emitVarint(allocator, shader_id);
        try self.emitVarint(allocator, code_data_id);
    }

    /// Emit create_render_pipeline instruction.
    /// Creates a render pipeline from descriptor data.
    pub fn createRenderPipeline(
        self: *Self,
        allocator: Allocator,
        pipeline_id: u16,
        descriptor_data_id: u16,
    ) !void {
        try self.emitOpcode(allocator, .create_render_pipeline);
        try self.emitVarint(allocator, pipeline_id);
        try self.emitVarint(allocator, descriptor_data_id);
    }

    /// Emit create_compute_pipeline instruction.
    pub fn createComputePipeline(
        self: *Self,
        allocator: Allocator,
        pipeline_id: u16,
        descriptor_data_id: u16,
    ) !void {
        try self.emitOpcode(allocator, .create_compute_pipeline);
        try self.emitVarint(allocator, pipeline_id);
        try self.emitVarint(allocator, descriptor_data_id);
    }

    /// Emit create_bind_group instruction.
    pub fn createBindGroup(
        self: *Self,
        allocator: Allocator,
        group_id: u16,
        layout_id: u16,
        entry_data_id: u16,
    ) !void {
        try self.emitOpcode(allocator, .create_bind_group);
        try self.emitVarint(allocator, group_id);
        try self.emitVarint(allocator, layout_id);
        try self.emitVarint(allocator, entry_data_id);
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
        try self.emitOpcode(allocator, .set_vertex_buffer_pool);
        try self.emitByte(allocator, slot);
        try self.emitVarint(allocator, base_buffer_id);
        try self.emitByte(allocator, pool_size);
        try self.emitByte(allocator, offset);
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
        try self.emitOpcode(allocator, .set_bind_group_pool);
        try self.emitByte(allocator, slot);
        try self.emitVarint(allocator, base_group_id);
        try self.emitByte(allocator, pool_size);
        try self.emitByte(allocator, offset);
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
        try self.emitOpcode(allocator, .draw);
        try self.emitVarint(allocator, vertex_count);
        try self.emitVarint(allocator, instance_count);
        try self.emitVarint(allocator, first_vertex);
        try self.emitVarint(allocator, first_instance);
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
        try self.emitOpcode(allocator, .draw_indexed);
        try self.emitVarint(allocator, index_count);
        try self.emitVarint(allocator, instance_count);
        try self.emitVarint(allocator, first_index);
        try self.emitVarint(allocator, base_vertex);
        try self.emitVarint(allocator, first_instance);
    }

    /// Emit dispatch instruction.
    pub fn dispatch(
        self: *Self,
        allocator: Allocator,
        x: u32,
        y: u32,
        z: u32,
    ) !void {
        try self.emitOpcode(allocator, .dispatch);
        try self.emitVarint(allocator, x);
        try self.emitVarint(allocator, y);
        try self.emitVarint(allocator, z);
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
    pub fn defineFrame(
        self: *Self,
        allocator: Allocator,
        frame_id: u16,
        name_string_id: u16,
    ) !void {
        try self.emitOpcode(allocator, .define_frame);
        try self.emitVarint(allocator, frame_id);
        try self.emitVarint(allocator, name_string_id);
    }

    /// Emit end_frame instruction.
    pub fn endFrame(self: *Self, allocator: Allocator) !void {
        try self.emitOpcode(allocator, .end_frame);
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
    /// Fills array elements with random values in [min, max].
    pub fn fillRandom(
        self: *Self,
        allocator: Allocator,
        array_id: u16,
        offset: u32,
        count: u32,
        stride: u8,
        min_data_id: u16,
        max_data_id: u16,
    ) !void {
        try self.emitOpcode(allocator, .fill_random);
        try self.emitVarint(allocator, array_id);
        try self.emitVarint(allocator, offset);
        try self.emitVarint(allocator, count);
        try self.emitByte(allocator, stride);
        try self.emitVarint(allocator, min_data_id);
        try self.emitVarint(allocator, max_data_id);
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

const testing = std.testing;

test "emit create_buffer" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    try emitter.createBuffer(
        testing.allocator,
        0, // buffer_id
        1024, // size
        .{ .uniform = true, .copy_dst = true }, // usage
    );

    const bc = emitter.bytecode();
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_buffer)), bc[0]);
    // buffer_id = 0 (1 byte varint)
    try testing.expectEqual(@as(u8, 0), bc[1]);
    // size = 1024 (2 byte varint: 0x84 0x00)
    // Actually 1024 = 0x400, which is >= 128 so 2 bytes: 0x84 0x00
    try testing.expect(bc.len > 3);
}

test "emit create_shader_module" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    try emitter.createShaderModule(testing.allocator, 0, 5);

    const bc = emitter.bytecode();
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_shader_module)), bc[0]);
}

test "emit draw" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    try emitter.draw(testing.allocator, 3, 1, 0, 0);

    const bc = emitter.bytecode();
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.draw)), bc[0]);
    try testing.expectEqual(@as(u8, 3), bc[1]); // vertex_count = 3
    try testing.expectEqual(@as(u8, 1), bc[2]); // instance_count = 1
    try testing.expectEqual(@as(u8, 0), bc[3]); // first_vertex = 0
    try testing.expectEqual(@as(u8, 0), bc[4]); // first_instance = 0
}

test "emit simple triangle sequence" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    // Emit a simple triangle rendering sequence:
    // 1. Create shader module
    // 2. Create render pipeline
    // 3. Define frame
    // 4. Define pass with render commands
    // 5. End frame

    try emitter.createShaderModule(testing.allocator, 0, 0); // shader $shd:0 from data $d:0
    try emitter.createRenderPipeline(testing.allocator, 0, 1); // pipeline $pipe:0 from descriptor $d:1

    try emitter.defineFrame(testing.allocator, 0, 0); // frame $frm:0 "simpleTriangle"
    try emitter.definePass(testing.allocator, 0, .render, 2); // pass $pass:0 render from descriptor $d:2

    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPass(testing.allocator);

    try emitter.endPassDef(testing.allocator);
    try emitter.execPass(testing.allocator, 0);
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    // Verify we got some bytecode
    try testing.expect(emitter.len() > 10);

    // Verify first opcode is create_shader_module
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_shader_module)), emitter.bytecode()[0]);
}

test "emit submit" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    try emitter.submit(testing.allocator);

    const bc = emitter.bytecode();
    try testing.expectEqual(@as(usize, 1), bc.len);
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.submit)), bc[0]);
}

// ============================================================================
// New Emitter Tests (createImageBitmap, copyExternalImageToTexture)
// ============================================================================

test "emit createImageBitmap" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    try emitter.createImageBitmap(testing.allocator, 0, 5);

    const bc = emitter.bytecode();

    // Property: first byte is the opcode
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_image_bitmap)), bc[0]);

    // Property: bitmap_id (0) encoded as 1-byte varint
    try testing.expectEqual(@as(u8, 0), bc[1]);

    // Property: blob_data_id (5) encoded as 1-byte varint
    try testing.expectEqual(@as(u8, 5), bc[2]);

    // Property: total length = opcode(1) + bitmap_id(1) + blob_data_id(1) = 3
    try testing.expectEqual(@as(usize, 3), bc.len);
}

test "emit createImageBitmap with larger IDs" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    // Use IDs that require 2-byte varint encoding (>= 128)
    try emitter.createImageBitmap(testing.allocator, 200, 300);

    const bc = emitter.bytecode();

    // Property: first byte is the opcode
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_image_bitmap)), bc[0]);

    // Property: bytecode should be longer due to 2-byte varints
    // opcode(1) + bitmap_id(2) + blob_data_id(2) = 5 bytes
    try testing.expectEqual(@as(usize, 5), bc.len);

    // Decode and verify values
    const bitmap_id_result = opcodes.decodeVarint(bc[1..]);
    try testing.expectEqual(@as(u32, 200), bitmap_id_result.value);
    try testing.expectEqual(@as(u8, 2), bitmap_id_result.len);

    const blob_id_result = opcodes.decodeVarint(bc[1 + bitmap_id_result.len ..]);
    try testing.expectEqual(@as(u32, 300), blob_id_result.value);
}

test "emit copyExternalImageToTexture" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    try emitter.copyExternalImageToTexture(testing.allocator, 0, 1, 0, 0, 0);

    const bc = emitter.bytecode();

    // Property: first byte is the opcode
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.copy_external_image_to_texture)), bc[0]);

    // Property: bitmap_id (0) as 1-byte varint
    try testing.expectEqual(@as(u8, 0), bc[1]);

    // Property: texture_id (1) as 1-byte varint
    try testing.expectEqual(@as(u8, 1), bc[2]);

    // Property: mip_level (0) as single byte
    try testing.expectEqual(@as(u8, 0), bc[3]);

    // Property: origin_x (0) as 1-byte varint
    try testing.expectEqual(@as(u8, 0), bc[4]);

    // Property: origin_y (0) as 1-byte varint
    try testing.expectEqual(@as(u8, 0), bc[5]);

    // Property: total length = opcode(1) + bitmap_id(1) + texture_id(1) + mip_level(1) + origin_x(1) + origin_y(1) = 6
    try testing.expectEqual(@as(usize, 6), bc.len);
}

test "emit copyExternalImageToTexture with non-zero origin" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    // Test with origin offset (128, 256) which requires 2-byte varints
    try emitter.copyExternalImageToTexture(testing.allocator, 0, 1, 2, 128, 256);

    const bc = emitter.bytecode();

    // Property: first byte is the opcode
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.copy_external_image_to_texture)), bc[0]);

    // Decode values to verify
    var offset: usize = 1;

    // bitmap_id
    const bitmap_result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 0), bitmap_result.value);
    offset += bitmap_result.len;

    // texture_id
    const texture_result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 1), texture_result.value);
    offset += texture_result.len;

    // mip_level (single byte, not varint)
    try testing.expectEqual(@as(u8, 2), bc[offset]);
    offset += 1;

    // origin_x (128 requires 2 bytes)
    const origin_x_result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 128), origin_x_result.value);
    try testing.expectEqual(@as(u8, 2), origin_x_result.len);
    offset += origin_x_result.len;

    // origin_y (256 requires 2 bytes)
    const origin_y_result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 256), origin_y_result.value);
}

test "emit copyExternalImageToTexture mip level preserved" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    // Test with mip_level = 5
    try emitter.copyExternalImageToTexture(testing.allocator, 0, 1, 5, 0, 0);

    const bc = emitter.bytecode();

    // mip_level is at offset 3 (after opcode + bitmap_id + texture_id, each 1 byte for small values)
    try testing.expectEqual(@as(u8, 5), bc[3]);
}

test "emit image sequence (create then copy)" {
    // Typical usage: create ImageBitmap then copy to texture
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    // Create texture first
    try emitter.createTexture(testing.allocator, 0, 10); // texture_id=0, desc_id=10

    // Create ImageBitmap from blob
    try emitter.createImageBitmap(testing.allocator, 0, 20); // bitmap_id=0, blob_id=20

    // Copy ImageBitmap to texture
    try emitter.copyExternalImageToTexture(testing.allocator, 0, 0, 0, 0, 0);

    const bc = emitter.bytecode();

    // Property: three opcodes emitted in sequence
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_texture)), bc[0]);

    // Find second opcode (after create_texture params)
    var offset: usize = 1;
    offset += opcodes.decodeVarint(bc[offset..]).len; // texture_id
    offset += opcodes.decodeVarint(bc[offset..]).len; // desc_id
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_image_bitmap)), bc[offset]);

    // Find third opcode
    offset += 1;
    offset += opcodes.decodeVarint(bc[offset..]).len; // bitmap_id
    offset += opcodes.decodeVarint(bc[offset..]).len; // blob_id
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.copy_external_image_to_texture)), bc[offset]);
}

test "emit multiple image bitmaps" {
    var emitter: Emitter = .empty;
    defer emitter.deinit(testing.allocator);

    // Create multiple ImageBitmaps (e.g., for sprite atlas textures)
    try emitter.createImageBitmap(testing.allocator, 0, 0);
    try emitter.createImageBitmap(testing.allocator, 1, 1);
    try emitter.createImageBitmap(testing.allocator, 2, 2);

    const bc = emitter.bytecode();

    // Property: all three opcodes are create_image_bitmap
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_image_bitmap)), bc[0]);

    // Decode first instruction
    var offset: usize = 1;
    var result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 0), result.value); // bitmap_id 0
    offset += result.len;
    result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 0), result.value); // blob_id 0
    offset += result.len;

    // Second instruction
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_image_bitmap)), bc[offset]);
    offset += 1;
    result = opcodes.decodeVarint(bc[offset..]);
    try testing.expectEqual(@as(u32, 1), result.value); // bitmap_id 1
}

// ============================================================================
// Pre-allocation Tests
// ============================================================================

test "initWithCapacity pre-allocates buffer" {
    var emitter = try Emitter.initWithCapacity(testing.allocator, 1024);
    defer emitter.deinit(testing.allocator);

    // Property: capacity is at least what we requested
    try testing.expect(emitter.bytes.capacity >= 1024);

    // Property: length starts at 0
    try testing.expectEqual(@as(usize, 0), emitter.len());
}

test "initDefault uses DEFAULT_CAPACITY" {
    var emitter = try Emitter.initDefault(testing.allocator);
    defer emitter.deinit(testing.allocator);

    // Property: capacity is at least DEFAULT_CAPACITY
    try testing.expect(emitter.bytes.capacity >= Emitter.DEFAULT_CAPACITY);
}

test "pre-allocated emitter avoids reallocation for typical shader" {
    var emitter = try Emitter.initDefault(testing.allocator);
    defer emitter.deinit(testing.allocator);

    const initial_capacity = emitter.bytes.capacity;

    // Emit operations that fit within DEFAULT_CAPACITY (512 bytes)
    // Using simple operations with known signatures
    for (0..20) |i| {
        try emitter.createBuffer(testing.allocator, @intCast(i), 1024, .{ .vertex = true });
        try emitter.createShaderModule(testing.allocator, @intCast(i), @intCast(i));
    }
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPass(testing.allocator);
    try emitter.submit(testing.allocator);

    // Property: no reallocation occurred (capacity unchanged)
    try testing.expectEqual(initial_capacity, emitter.bytes.capacity);

    // Property: bytecode was actually emitted
    try testing.expect(emitter.len() > 0);
    try testing.expect(emitter.len() < Emitter.DEFAULT_CAPACITY);
}
