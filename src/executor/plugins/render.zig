//! Render Plugin
//!
//! Handles render pipelines, render passes, and draw commands.
//! Only included when `#renderPipeline` or `#renderPass` is used.
//!
//! ## Commands Handled
//!
//! - CREATE_RENDER_PIPELINE
//! - CREATE_RENDER_BUNDLE
//! - BEGIN_RENDER_PASS
//! - SET_PIPELINE
//! - SET_BIND_GROUP
//! - SET_VERTEX_BUFFER
//! - SET_INDEX_BUFFER
//! - DRAW
//! - DRAW_INDEXED
//! - END_PASS
//! - EXECUTE_BUNDLES
//!
//! ## Invariants
//!
//! - Must call beginRenderPass before draw commands
//! - Must call endPass before submit
//! - Pipeline must be set before drawing

const std = @import("std");
const assert = std.debug.assert;

const CommandBuffer = @import("../command_buffer.zig").CommandBuffer;
const Cmd = @import("../command_buffer.zig").Cmd;

/// Render plugin state.
pub const RenderPlugin = struct {
    const Self = @This();

    /// Command buffer to write to.
    cmd_buffer: *CommandBuffer,

    /// Whether currently in a render pass.
    in_pass: bool,

    /// Initialize render plugin with command buffer.
    pub fn init(cmd_buffer: *CommandBuffer) Self {
        // Pre-condition: command buffer initialized
        assert(cmd_buffer.buffer.len >= 8);

        return .{
            .cmd_buffer = cmd_buffer,
            .in_pass = false,
        };
    }

    // ========================================================================
    // Pipeline Creation
    // ========================================================================

    /// Create a render pipeline.
    ///
    /// Args:
    ///   id: Resource ID
    ///   desc_ptr: Pointer to descriptor in WASM memory
    ///   desc_len: Descriptor length
    pub fn createRenderPipeline(self: *Self, id: u16, desc_ptr: u32, desc_len: u32) void {
        // Pre-condition: descriptor present
        assert(desc_len > 0);

        self.cmd_buffer.createRenderPipeline(id, desc_ptr, desc_len);
    }

    /// Create a render bundle.
    ///
    /// Args:
    ///   id: Resource ID
    ///   desc_ptr: Pointer to descriptor in WASM memory
    ///   desc_len: Descriptor length
    pub fn createRenderBundle(self: *Self, id: u16, desc_ptr: u32, desc_len: u32) void {
        // Pre-condition: descriptor present
        assert(desc_len > 0);

        self.cmd_buffer.createRenderBundle(id, desc_ptr, desc_len);
    }

    // ========================================================================
    // Pass Operations
    // ========================================================================

    /// Begin a render pass.
    ///
    /// Args:
    ///   color_id: Color attachment texture ID
    ///   load_op: Load operation (0=clear, 1=load)
    ///   store_op: Store operation (0=store, 1=discard)
    ///   depth_id: Depth attachment texture ID (0xFFFF for none)
    pub fn beginRenderPass(self: *Self, color_id: u16, load_op: u8, store_op: u8, depth_id: u16) void {
        // Pre-condition: not already in a pass
        assert(!self.in_pass);

        self.cmd_buffer.beginRenderPass(color_id, load_op, store_op, depth_id);
        self.in_pass = true;
    }

    /// Set the current pipeline.
    ///
    /// Args:
    ///   id: Pipeline resource ID
    pub fn setPipeline(self: *Self, id: u16) void {
        // Pre-condition: in a pass
        assert(self.in_pass);

        self.cmd_buffer.setPipeline(id);
    }

    /// Set a bind group.
    ///
    /// Args:
    ///   slot: Bind group slot (0-3)
    ///   id: Bind group resource ID
    pub fn setBindGroup(self: *Self, slot: u8, id: u16) void {
        // Pre-conditions
        assert(self.in_pass);
        assert(slot < 4);

        self.cmd_buffer.setBindGroup(slot, id);
    }

    /// Set a vertex buffer.
    ///
    /// Args:
    ///   slot: Vertex buffer slot
    ///   id: Buffer resource ID
    pub fn setVertexBuffer(self: *Self, slot: u8, id: u16) void {
        // Pre-condition: in a pass
        assert(self.in_pass);

        self.cmd_buffer.setVertexBuffer(slot, id);
    }

    /// Set the index buffer.
    ///
    /// Args:
    ///   id: Buffer resource ID
    ///   format: Index format (0=uint16, 1=uint32)
    pub fn setIndexBuffer(self: *Self, id: u16, format: u8) void {
        // Pre-condition: in a pass
        assert(self.in_pass);

        self.cmd_buffer.setIndexBuffer(id, format);
    }

    /// Draw vertices.
    ///
    /// Args:
    ///   vertex_count: Number of vertices
    ///   instance_count: Number of instances
    ///   first_vertex: First vertex index
    ///   first_instance: First instance index
    pub fn draw(
        self: *Self,
        vertex_count: u32,
        instance_count: u32,
        first_vertex: u32,
        first_instance: u32,
    ) void {
        // Pre-conditions
        assert(self.in_pass);
        assert(vertex_count > 0);
        assert(instance_count > 0);

        self.cmd_buffer.draw(vertex_count, instance_count, first_vertex, first_instance);
    }

    /// Draw indexed vertices.
    ///
    /// Args:
    ///   index_count: Number of indices
    ///   instance_count: Number of instances
    ///   first_index: First index
    ///   base_vertex: Base vertex offset
    ///   first_instance: First instance index
    pub fn drawIndexed(
        self: *Self,
        index_count: u32,
        instance_count: u32,
        first_index: u32,
        base_vertex: u32,
        first_instance: u32,
    ) void {
        // Pre-conditions
        assert(self.in_pass);
        assert(index_count > 0);
        assert(instance_count > 0);

        self.cmd_buffer.drawIndexed(index_count, instance_count, first_index, base_vertex, first_instance);
    }

    /// Execute render bundles.
    ///
    /// Args:
    ///   bundles_ptr: Pointer to bundle ID array
    ///   bundles_len: Number of bundles
    pub fn executeBundles(self: *Self, bundles_ptr: u32, bundles_len: u32) void {
        // Pre-condition: in a pass
        assert(self.in_pass);

        self.cmd_buffer.executeBundles(bundles_ptr, bundles_len);
    }

    /// End the current render pass.
    pub fn endPass(self: *Self) void {
        // Pre-condition: in a pass
        assert(self.in_pass);

        self.cmd_buffer.endPass();
        self.in_pass = false;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "RenderPlugin: create render pipeline" {
    var buffer: [1024]u8 = undefined;
    var cmd_buffer = CommandBuffer.init(&buffer);
    var render = RenderPlugin.init(&cmd_buffer);

    render.createRenderPipeline(1, 0x1000, 128);

    const result = cmd_buffer.finish();
    try testing.expect(result.len > 8);
    try testing.expectEqual(@intFromEnum(Cmd.create_render_pipeline), result[8]);
}

test "RenderPlugin: render pass flow" {
    var buffer: [1024]u8 = undefined;
    var cmd_buffer = CommandBuffer.init(&buffer);
    var render = RenderPlugin.init(&cmd_buffer);

    // Not in pass initially
    try testing.expect(!render.in_pass);

    render.beginRenderPass(0xFFFE, 0, 0, 0xFFFF);
    try testing.expect(render.in_pass);

    render.setPipeline(1);
    render.setBindGroup(0, 2);
    render.setVertexBuffer(0, 3);
    render.draw(3, 1, 0, 0);

    render.endPass();
    try testing.expect(!render.in_pass);

    const result = cmd_buffer.finish();
    // Should have multiple commands
    try testing.expect(result.len > 20);
}

test "RenderPlugin: draw indexed" {
    var buffer: [1024]u8 = undefined;
    var cmd_buffer = CommandBuffer.init(&buffer);
    var render = RenderPlugin.init(&cmd_buffer);

    render.beginRenderPass(0xFFFE, 0, 0, 0xFFFF);
    render.setPipeline(1);
    render.setIndexBuffer(4, 0); // uint16
    render.drawIndexed(6, 1, 0, 0, 0);
    render.endPass();

    const result = cmd_buffer.finish();
    try testing.expect(result.len > 8);
}
