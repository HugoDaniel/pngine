//! Bytecode Emitter
//!
//! Produces PNGB bytecode from high-level operations.
//! Uses variable-length encoding for compact output.
//!
//! Invariants:
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

    /// Output bytecode buffer.
    bytes: std.ArrayListUnmanaged(u8),

    pub const empty: Self = .{
        .bytes = .{},
    };

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

    /// Emit draw instruction.
    pub fn draw(
        self: *Self,
        allocator: Allocator,
        vertex_count: u32,
        instance_count: u32,
    ) !void {
        try self.emitOpcode(allocator, .draw);
        try self.emitVarint(allocator, vertex_count);
        try self.emitVarint(allocator, instance_count);
    }

    /// Emit draw_indexed instruction.
    pub fn drawIndexed(
        self: *Self,
        allocator: Allocator,
        index_count: u32,
        instance_count: u32,
    ) !void {
        try self.emitOpcode(allocator, .draw_indexed);
        try self.emitVarint(allocator, index_count);
        try self.emitVarint(allocator, instance_count);
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

    try emitter.draw(testing.allocator, 3, 1);

    const bc = emitter.bytecode();
    try testing.expectEqual(@as(u8, @intFromEnum(OpCode.draw)), bc[0]);
    try testing.expectEqual(@as(u8, 3), bc[1]); // vertex_count = 3
    try testing.expectEqual(@as(u8, 1), bc[2]); // instance_count = 1
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
    try emitter.draw(testing.allocator, 3, 1);
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
