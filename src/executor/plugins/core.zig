//! Core Plugin - Always Enabled
//!
//! Handles basic resource creation and buffer operations.
//! This plugin is always included in the executor.
//!
//! ## Commands Handled
//!
//! - CREATE_BUFFER
//! - CREATE_SAMPLER
//! - CREATE_BIND_GROUP
//! - CREATE_BIND_GROUP_LAYOUT
//! - CREATE_PIPELINE_LAYOUT
//! - CREATE_SHADER
//! - WRITE_BUFFER
//! - WRITE_TIME_UNIFORM
//! - COPY_BUFFER_TO_BUFFER
//! - SUBMIT
//! - END
//!
//! ## Invariants
//!
//! - Command buffer must have capacity for commands
//! - Resource IDs must be unique per type
//! - Data pointers must be valid within WASM memory

const std = @import("std");
const assert = std.debug.assert;

const CommandBuffer = @import("../command_buffer.zig").CommandBuffer;
const Cmd = @import("../command_buffer.zig").Cmd;

/// Core plugin state.
/// Tracks allocated resources for validation.
pub const CorePlugin = struct {
    const Self = @This();

    /// Command buffer to write to.
    cmd_buffer: *CommandBuffer,

    /// Initialize core plugin with command buffer.
    pub fn init(cmd_buffer: *CommandBuffer) Self {
        // Pre-condition: command buffer initialized
        assert(cmd_buffer.buffer.len >= 8);

        return .{
            .cmd_buffer = cmd_buffer,
        };
    }

    // ========================================================================
    // Resource Creation
    // ========================================================================

    /// Create a GPU buffer.
    ///
    /// Args:
    ///   id: Resource ID (must be unique)
    ///   size: Buffer size in bytes
    ///   usage: WebGPU buffer usage flags
    pub fn createBuffer(self: *Self, id: u16, size: u32, usage: u8) void {
        // Pre-conditions
        assert(size > 0);

        self.cmd_buffer.createBuffer(id, size, usage);
    }

    /// Create a sampler.
    ///
    /// Args:
    ///   id: Resource ID
    ///   desc_ptr: Pointer to descriptor in WASM memory
    ///   desc_len: Descriptor length
    pub fn createSampler(self: *Self, id: u16, desc_ptr: u32, desc_len: u32) void {
        // Pre-condition: descriptor present
        assert(desc_len > 0);

        self.cmd_buffer.createSampler(id, desc_ptr, desc_len);
    }

    /// Create a shader module.
    ///
    /// Args:
    ///   id: Resource ID
    ///   code_ptr: Pointer to WGSL code in WASM memory
    ///   code_len: Code length
    pub fn createShader(self: *Self, id: u16, code_ptr: u32, code_len: u32) void {
        // Pre-condition: code present
        assert(code_len > 0);

        self.cmd_buffer.createShader(id, code_ptr, code_len);
    }

    /// Create a bind group.
    ///
    /// Args:
    ///   id: Resource ID
    ///   layout_id: Bind group layout ID
    ///   entries_ptr: Pointer to entries descriptor
    ///   entries_len: Entries descriptor length
    pub fn createBindGroup(self: *Self, id: u16, layout_id: u16, entries_ptr: u32, entries_len: u32) void {
        self.cmd_buffer.createBindGroup(id, layout_id, entries_ptr, entries_len);
    }

    /// Create a bind group layout.
    ///
    /// Args:
    ///   id: Resource ID
    ///   entries_ptr: Pointer to layout entries descriptor
    ///   entries_len: Entries descriptor length
    pub fn createBindGroupLayout(self: *Self, id: u16, entries_ptr: u32, entries_len: u32) void {
        self.cmd_buffer.createBindGroupLayout(id, entries_ptr, entries_len);
    }

    /// Create a pipeline layout.
    ///
    /// Args:
    ///   id: Resource ID
    ///   layouts_ptr: Pointer to bind group layout IDs
    ///   layouts_len: Number of layouts
    pub fn createPipelineLayout(self: *Self, id: u16, layouts_ptr: u32, layouts_len: u32) void {
        self.cmd_buffer.createPipelineLayout(id, layouts_ptr, layouts_len);
    }

    // ========================================================================
    // Queue Operations
    // ========================================================================

    /// Write data to a buffer.
    ///
    /// Args:
    ///   id: Buffer resource ID
    ///   offset: Offset into buffer
    ///   data_ptr: Pointer to data in WASM memory
    ///   data_len: Data length
    pub fn writeBuffer(self: *Self, id: u16, offset: u32, data_ptr: u32, data_len: u32) void {
        self.cmd_buffer.writeBuffer(id, offset, data_ptr, data_len);
    }

    /// Write time uniform data (pngineInputs).
    ///
    /// Args:
    ///   id: Buffer resource ID
    ///   offset: Offset into buffer
    ///   size: Size of uniform data
    pub fn writeTimeUniform(self: *Self, id: u16, offset: u32, size: u32) void {
        self.cmd_buffer.writeTimeUniform(id, offset, size);
    }

    /// Copy data between buffers.
    ///
    /// Args:
    ///   src_id: Source buffer ID
    ///   src_offset: Source offset
    ///   dst_id: Destination buffer ID
    ///   dst_offset: Destination offset
    ///   size: Bytes to copy
    pub fn copyBufferToBuffer(
        self: *Self,
        src_id: u16,
        src_offset: u32,
        dst_id: u16,
        dst_offset: u32,
        size: u32,
    ) void {
        // Pre-conditions
        assert(size > 0);

        self.cmd_buffer.copyBufferToBuffer(src_id, src_offset, dst_id, dst_offset, size);
    }

    // ========================================================================
    // Control
    // ========================================================================

    /// Submit queued commands to GPU.
    pub fn submit(self: *Self) void {
        self.cmd_buffer.submit();
    }

    /// End command buffer.
    pub fn end(self: *Self) void {
        self.cmd_buffer.end();
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "CorePlugin: create buffer" {
    var buffer: [1024]u8 = undefined;
    var cmd_buffer = CommandBuffer.init(&buffer);
    var core = CorePlugin.init(&cmd_buffer);

    core.createBuffer(1, 256, 0x21); // VERTEX | COPY_DST

    const result = cmd_buffer.finish();
    try testing.expect(result.len > 8); // Header + command

    // Verify command was written
    try testing.expectEqual(@intFromEnum(Cmd.create_buffer), result[8]);
}

test "CorePlugin: write buffer" {
    var buffer: [1024]u8 = undefined;
    var cmd_buffer = CommandBuffer.init(&buffer);
    var core = CorePlugin.init(&cmd_buffer);

    core.writeBuffer(1, 0, 0x1000, 64);

    const result = cmd_buffer.finish();
    try testing.expect(result.len > 8);
    try testing.expectEqual(@intFromEnum(Cmd.write_buffer), result[8]);
}

test "CorePlugin: submit" {
    var buffer: [1024]u8 = undefined;
    var cmd_buffer = CommandBuffer.init(&buffer);
    var core = CorePlugin.init(&cmd_buffer);

    core.submit();

    const result = cmd_buffer.finish();
    try testing.expect(result.len > 8);
    try testing.expectEqual(@intFromEnum(Cmd.submit), result[8]);
}
