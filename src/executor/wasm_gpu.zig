//! WASM WebGPU Backend
//!
//! Calls out to JavaScript WebGPU implementation via extern functions.
//! Used when running in the browser via WASM.
//!
//! Data Flow:
//! 1. Bytecode calls createShaderModule(shader_id, code_data_id)
//! 2. WasmGPU looks up code_data_id in Module.data section
//! 3. Passes pointer + length to JS via extern gpuCreateShaderModule
//! 4. JS reads string from WASM memory, calls device.createShaderModule
//!
//! Invariants:
//! - Module must be set before any GPU calls
//! - All data IDs must reference valid module data
//! - JS is responsible for resource tracking and error handling

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const format = @import("../bytecode/format.zig");
const Module = format.Module;
const DataSection = @import("../bytecode/data_section.zig").DataSection;
const DataId = @import("../bytecode/data_section.zig").DataId;

// ============================================================================
// JS Extern Declarations (imported from JavaScript)
// ============================================================================

extern "env" fn gpuCreateBuffer(buffer_id: u16, size: u32, usage: u8) void;
extern "env" fn gpuCreateTexture(texture_id: u16, desc_ptr: [*]const u8, desc_len: u32) void;
extern "env" fn gpuCreateSampler(sampler_id: u16, desc_ptr: [*]const u8, desc_len: u32) void;
extern "env" fn gpuCreateShaderModule(shader_id: u16, code_ptr: [*]const u8, code_len: u32) void;
extern "env" fn gpuCreateRenderPipeline(pipeline_id: u16, desc_ptr: [*]const u8, desc_len: u32) void;
extern "env" fn gpuCreateComputePipeline(pipeline_id: u16, desc_ptr: [*]const u8, desc_len: u32) void;
extern "env" fn gpuCreateBindGroup(group_id: u16, layout_id: u16, entries_ptr: [*]const u8, entries_len: u32) void;
extern "env" fn gpuBeginRenderPass(color_texture_id: u16, load_op: u8, store_op: u8, depth_texture_id: u16) void;
extern "env" fn gpuBeginComputePass() void;
extern "env" fn gpuSetPipeline(pipeline_id: u16) void;
extern "env" fn gpuSetBindGroup(slot: u8, group_id: u16) void;
extern "env" fn gpuSetVertexBuffer(slot: u8, buffer_id: u16) void;
extern "env" fn gpuDraw(vertex_count: u32, instance_count: u32) void;
extern "env" fn gpuDrawIndexed(index_count: u32, instance_count: u32) void;
extern "env" fn gpuDispatch(x: u32, y: u32, z: u32) void;
extern "env" fn gpuEndPass() void;
extern "env" fn gpuWriteBuffer(buffer_id: u16, offset: u32, data_ptr: [*]const u8, data_len: u32) void;
extern "env" fn gpuSubmit() void;

// ============================================================================
// WasmGPU Backend
// ============================================================================

/// WebGPU backend for WASM that calls out to JavaScript.
pub const WasmGPU = struct {
    const Self = @This();

    /// Reference to the current module for data lookups.
    module: ?*const Module,

    pub const empty: Self = .{
        .module = null,
    };

    /// Set the module for data lookups.
    /// Must be called before any GPU operations that reference data IDs.
    pub fn setModule(self: *Self, module: *const Module) void {
        self.module = module;
    }

    // ========================================================================
    // Resource Creation
    // ========================================================================

    /// Create a GPU buffer.
    /// Allocator unused - no WASM-side allocation needed.
    pub fn createBuffer(self: *Self, allocator: Allocator, buffer_id: u16, size: u32, usage: u8) !void {
        _ = self;
        _ = allocator;
        gpuCreateBuffer(buffer_id, size, usage);
    }

    /// Create a GPU texture from descriptor in the data section.
    pub fn createTexture(self: *Self, allocator: Allocator, texture_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.getDataOrPanic(descriptor_data_id);
        gpuCreateTexture(texture_id, data.ptr, @intCast(data.len));
    }

    /// Create a texture sampler from descriptor in the data section.
    pub fn createSampler(self: *Self, allocator: Allocator, sampler_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.getDataOrPanic(descriptor_data_id);
        gpuCreateSampler(sampler_id, data.ptr, @intCast(data.len));
    }

    /// Create a shader module from code in the data section.
    pub fn createShaderModule(self: *Self, allocator: Allocator, shader_id: u16, code_data_id: u16) !void {
        _ = allocator;

        // Pre-condition: module must be set
        assert(self.module != null);

        const data = self.getDataOrPanic(code_data_id);
        gpuCreateShaderModule(shader_id, data.ptr, @intCast(data.len));
    }

    /// Create a render pipeline from descriptor in the data section.
    pub fn createRenderPipeline(self: *Self, allocator: Allocator, pipeline_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.getDataOrPanic(descriptor_data_id);
        gpuCreateRenderPipeline(pipeline_id, data.ptr, @intCast(data.len));
    }

    /// Create a compute pipeline from descriptor in the data section.
    pub fn createComputePipeline(self: *Self, allocator: Allocator, pipeline_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.getDataOrPanic(descriptor_data_id);
        gpuCreateComputePipeline(pipeline_id, data.ptr, @intCast(data.len));
    }

    /// Create a bind group from entries in the data section.
    pub fn createBindGroup(self: *Self, allocator: Allocator, group_id: u16, layout_id: u16, entry_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.getDataOrPanic(entry_data_id);
        gpuCreateBindGroup(group_id, layout_id, data.ptr, @intCast(data.len));
    }

    // ========================================================================
    // Pass Operations
    // ========================================================================

    /// Begin a render pass.
    pub fn beginRenderPass(self: *Self, allocator: Allocator, color_texture_id: u16, load_op: u8, store_op: u8, depth_texture_id: u16) !void {
        _ = self;
        _ = allocator;
        gpuBeginRenderPass(color_texture_id, load_op, store_op, depth_texture_id);
    }

    /// Begin a compute pass.
    pub fn beginComputePass(self: *Self, allocator: Allocator) !void {
        _ = self;
        _ = allocator;
        gpuBeginComputePass();
    }

    /// Set the current pipeline.
    pub fn setPipeline(self: *Self, allocator: Allocator, pipeline_id: u16) !void {
        _ = self;
        _ = allocator;
        gpuSetPipeline(pipeline_id);
    }

    /// Set a bind group.
    pub fn setBindGroup(self: *Self, allocator: Allocator, slot: u8, group_id: u16) !void {
        _ = self;
        _ = allocator;
        gpuSetBindGroup(slot, group_id);
    }

    /// Set a vertex buffer.
    pub fn setVertexBuffer(self: *Self, allocator: Allocator, slot: u8, buffer_id: u16) !void {
        _ = self;
        _ = allocator;
        gpuSetVertexBuffer(slot, buffer_id);
    }

    /// Draw primitives.
    pub fn draw(self: *Self, allocator: Allocator, vertex_count: u32, instance_count: u32) !void {
        _ = self;
        _ = allocator;
        gpuDraw(vertex_count, instance_count);
    }

    /// Draw indexed primitives.
    pub fn drawIndexed(self: *Self, allocator: Allocator, index_count: u32, instance_count: u32) !void {
        _ = self;
        _ = allocator;
        gpuDrawIndexed(index_count, instance_count);
    }

    /// Dispatch compute workgroups.
    pub fn dispatch(self: *Self, allocator: Allocator, x: u32, y: u32, z: u32) !void {
        _ = self;
        _ = allocator;
        gpuDispatch(x, y, z);
    }

    /// End the current pass.
    pub fn endPass(self: *Self, allocator: Allocator) !void {
        _ = self;
        _ = allocator;
        gpuEndPass();
    }

    // ========================================================================
    // Queue Operations
    // ========================================================================

    /// Write data to a buffer.
    pub fn writeBuffer(self: *Self, allocator: Allocator, buffer_id: u16, offset: u32, data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.getDataOrPanic(data_id);
        gpuWriteBuffer(buffer_id, offset, data.ptr, @intCast(data.len));
    }

    /// Submit command buffer to queue.
    pub fn submit(self: *Self, allocator: Allocator) !void {
        _ = self;
        _ = allocator;
        gpuSubmit();
    }

    // ========================================================================
    // Internal Helpers
    // ========================================================================

    /// Get data from module by ID.
    /// Panics if module not set or ID invalid (programming error).
    fn getDataOrPanic(self: *const Self, data_id: u16) []const u8 {
        const module = self.module orelse unreachable;
        return module.data.get(@enumFromInt(data_id));
    }
};

// ============================================================================
// Tests (Native only - externs not available)
// ============================================================================

const testing = std.testing;
const builtin = @import("builtin");

test "wasm_gpu: backend interface compliance" {
    // Just verify the type has all required methods at comptime
    const dispatcher = @import("dispatcher.zig");
    dispatcher.Backend(WasmGPU).validate();
}

// Note: Actual execution tests require running in WASM with JS bindings.
// Use Playwright E2E tests for real WebGPU validation.
