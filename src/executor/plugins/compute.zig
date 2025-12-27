//! Compute Plugin
//!
//! Handles compute pipelines and dispatch commands.
//! Only included when `#computePipeline` or `#computePass` is used.
//!
//! ## Commands Handled
//!
//! - CREATE_COMPUTE_PIPELINE
//! - BEGIN_COMPUTE_PASS
//! - SET_PIPELINE (shared with render)
//! - SET_BIND_GROUP (shared with render)
//! - DISPATCH
//! - END_PASS (shared with render)
//!
//! ## Invariants
//!
//! - Must call beginComputePass before dispatch
//! - Must call endPass before submit
//! - Pipeline must be set before dispatching

const std = @import("std");
const assert = std.debug.assert;

const CommandBuffer = @import("../command_buffer.zig").CommandBuffer;
const Cmd = @import("../command_buffer.zig").Cmd;

/// Compute plugin state.
pub const ComputePlugin = struct {
    const Self = @This();

    /// Command buffer to write to.
    cmd_buffer: *CommandBuffer,

    /// Whether currently in a compute pass.
    in_pass: bool,

    /// Initialize compute plugin with command buffer.
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

    /// Create a compute pipeline.
    ///
    /// Args:
    ///   id: Resource ID
    ///   desc_ptr: Pointer to descriptor in WASM memory
    ///   desc_len: Descriptor length
    pub fn createComputePipeline(self: *Self, id: u16, desc_ptr: u32, desc_len: u32) void {
        // Pre-condition: descriptor present
        assert(desc_len > 0);

        self.cmd_buffer.createComputePipeline(id, desc_ptr, desc_len);
    }

    // ========================================================================
    // Pass Operations
    // ========================================================================

    /// Begin a compute pass.
    pub fn beginComputePass(self: *Self) void {
        // Pre-condition: not already in a pass
        assert(!self.in_pass);

        self.cmd_buffer.beginComputePass();
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

    /// Dispatch compute workgroups.
    ///
    /// Args:
    ///   x: Workgroup count in X dimension
    ///   y: Workgroup count in Y dimension
    ///   z: Workgroup count in Z dimension
    pub fn dispatch(self: *Self, x: u32, y: u32, z: u32) void {
        // Pre-conditions
        assert(self.in_pass);
        assert(x > 0);
        assert(y > 0);
        assert(z > 0);

        self.cmd_buffer.dispatch(x, y, z);
    }

    /// End the current compute pass.
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

test "ComputePlugin: create compute pipeline" {
    var buffer: [1024]u8 = undefined;
    var cmd_buffer = CommandBuffer.init(&buffer);
    var compute = ComputePlugin.init(&cmd_buffer);

    compute.createComputePipeline(1, 0x1000, 64);

    const result = cmd_buffer.finish();
    try testing.expect(result.len > 8);
    try testing.expectEqual(@intFromEnum(Cmd.create_compute_pipeline), result[8]);
}

test "ComputePlugin: compute pass flow" {
    var buffer: [1024]u8 = undefined;
    var cmd_buffer = CommandBuffer.init(&buffer);
    var compute = ComputePlugin.init(&cmd_buffer);

    // Not in pass initially
    try testing.expect(!compute.in_pass);

    compute.beginComputePass();
    try testing.expect(compute.in_pass);

    compute.setPipeline(1);
    compute.setBindGroup(0, 2);
    compute.dispatch(64, 1, 1);

    compute.endPass();
    try testing.expect(!compute.in_pass);

    const result = cmd_buffer.finish();
    // Should have multiple commands
    try testing.expect(result.len > 20);
}

test "ComputePlugin: multiple dispatches" {
    var buffer: [1024]u8 = undefined;
    var cmd_buffer = CommandBuffer.init(&buffer);
    var compute = ComputePlugin.init(&cmd_buffer);

    compute.beginComputePass();
    compute.setPipeline(1);
    compute.dispatch(32, 32, 1);
    compute.dispatch(16, 16, 4);
    compute.endPass();

    const result = cmd_buffer.finish();
    try testing.expect(result.len > 30);
}
