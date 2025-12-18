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
extern "env" fn gpuCreateImageBitmap(bitmap_id: u16, blob_ptr: [*]const u8, blob_len: u32) void;
extern "env" fn gpuCreateTextureView(view_id: u16, texture_id: u16, desc_ptr: [*]const u8, desc_len: u32) void;
extern "env" fn gpuCreateQuerySet(query_set_id: u16, desc_ptr: [*]const u8, desc_len: u32) void;
extern "env" fn gpuCreateBindGroupLayout(layout_id: u16, desc_ptr: [*]const u8, desc_len: u32) void;
extern "env" fn gpuCreatePipelineLayout(layout_id: u16, desc_ptr: [*]const u8, desc_len: u32) void;
extern "env" fn gpuBeginRenderPass(color_texture_id: u16, load_op: u8, store_op: u8, depth_texture_id: u16) void;
extern "env" fn gpuBeginComputePass() void;
extern "env" fn gpuSetPipeline(pipeline_id: u16) void;
extern "env" fn gpuSetBindGroup(slot: u8, group_id: u16) void;
extern "env" fn gpuSetVertexBuffer(slot: u8, buffer_id: u16) void;
extern "env" fn gpuDraw(vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void;
extern "env" fn gpuDrawIndexed(index_count: u32, instance_count: u32, first_index: u32, base_vertex: u32, first_instance: u32) void;
extern "env" fn gpuDispatch(x: u32, y: u32, z: u32) void;
extern "env" fn gpuEndPass() void;
extern "env" fn gpuWriteBuffer(buffer_id: u16, offset: u32, data_ptr: [*]const u8, data_len: u32) void;
extern "env" fn gpuSubmit() void;
extern "env" fn gpuCopyExternalImageToTexture(bitmap_id: u16, texture_id: u16, mip_level: u8, origin_x: u16, origin_y: u16) void;
extern "env" fn gpuInitWasmModule(module_id: u16, data_ptr: [*]const u8, data_len: u32) void;
extern "env" fn gpuCallWasmFunc(call_id: u16, module_id: u16, func_name_ptr: [*]const u8, func_name_len: u32, args_ptr: [*]const u8, args_len: u32) void;
extern "env" fn gpuWriteBufferFromWasm(call_id: u16, buffer_id: u16, offset: u32, byte_len: u32) void;

// Data generation extern functions
extern "env" fn gpuCreateTypedArray(array_id: u16, element_type: u8, element_count: u32) void;
extern "env" fn gpuFillRandom(array_id: u16, offset: u32, count: u32, stride: u8, min_ptr: [*]const u8, max_ptr: [*]const u8) void;
extern "env" fn gpuFillExpression(array_id: u16, offset: u32, count: u32, stride: u8, total_count: u32, expr_ptr: [*]const u8, expr_len: u32) void;
extern "env" fn gpuFillConstant(array_id: u16, offset: u32, count: u32, stride: u8, value_ptr: [*]const u8) void;
extern "env" fn gpuWriteBufferFromArray(buffer_id: u16, buffer_offset: u32, array_id: u16) void;

// Debug logging
extern "env" fn gpuDebugLog(msg_type: u8, value: u32) void;

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

    /// Create an ImageBitmap from blob data in the data section.
    /// Blob format: [mime_len:u8][mime:bytes][data:bytes]
    pub fn createImageBitmap(self: *Self, allocator: Allocator, bitmap_id: u16, blob_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.getDataOrPanic(blob_data_id);
        gpuCreateImageBitmap(bitmap_id, data.ptr, @intCast(data.len));
    }

    /// Create a texture view from an existing texture.
    pub fn createTextureView(self: *Self, allocator: Allocator, view_id: u16, texture_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.getDataOrPanic(descriptor_data_id);
        gpuCreateTextureView(view_id, texture_id, data.ptr, @intCast(data.len));
    }

    /// Create a query set for occlusion or timestamp queries.
    pub fn createQuerySet(self: *Self, allocator: Allocator, query_set_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.getDataOrPanic(descriptor_data_id);
        gpuCreateQuerySet(query_set_id, data.ptr, @intCast(data.len));
    }

    /// Create a bind group layout defining binding slot types.
    pub fn createBindGroupLayout(self: *Self, allocator: Allocator, layout_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.getDataOrPanic(descriptor_data_id);
        gpuCreateBindGroupLayout(layout_id, data.ptr, @intCast(data.len));
    }

    /// Create a pipeline layout from bind group layouts.
    pub fn createPipelineLayout(self: *Self, allocator: Allocator, layout_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.getDataOrPanic(descriptor_data_id);
        gpuCreatePipelineLayout(layout_id, data.ptr, @intCast(data.len));
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
    pub fn draw(self: *Self, allocator: Allocator, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) !void {
        _ = self;
        _ = allocator;
        gpuDraw(vertex_count, instance_count, first_vertex, first_instance);
    }

    /// Draw indexed primitives.
    pub fn drawIndexed(self: *Self, allocator: Allocator, index_count: u32, instance_count: u32, first_index: u32, base_vertex: u32, first_instance: u32) !void {
        _ = self;
        _ = allocator;
        gpuDrawIndexed(index_count, instance_count, first_index, base_vertex, first_instance);
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

    /// Copy an ImageBitmap to a texture.
    pub fn copyExternalImageToTexture(self: *Self, allocator: Allocator, bitmap_id: u16, texture_id: u16, mip_level: u8, origin_x: u16, origin_y: u16) !void {
        _ = self;
        _ = allocator;
        gpuCopyExternalImageToTexture(bitmap_id, texture_id, mip_level, origin_x, origin_y);
    }

    // ========================================================================
    // WASM Module Operations
    // ========================================================================

    /// Initialize a WASM module from embedded data.
    pub fn initWasmModule(self: *Self, allocator: Allocator, module_id: u16, wasm_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.getDataOrPanic(wasm_data_id);
        gpuInitWasmModule(module_id, data.ptr, @intCast(data.len));
    }

    /// Call a WASM exported function.
    /// The function name comes from string table, args are pre-encoded.
    pub fn callWasmFunc(self: *Self, allocator: Allocator, call_id: u16, module_id: u16, func_name_id: u16, args: []const u8) !void {
        _ = allocator;
        assert(self.module != null);

        // Get function name from string table
        const func_name = self.module.?.strings.get(@enumFromInt(func_name_id));

        // Pass encoded args to JS for runtime resolution
        gpuCallWasmFunc(call_id, module_id, func_name.ptr, @intCast(func_name.len), args.ptr, @intCast(args.len));
    }

    /// Write bytes from WASM memory to a GPU buffer.
    pub fn writeBufferFromWasm(self: *Self, allocator: Allocator, call_id: u16, buffer_id: u16, offset: u32, byte_len: u32) !void {
        _ = self;
        _ = allocator;
        gpuWriteBufferFromWasm(call_id, buffer_id, offset, byte_len);
    }

    // ========================================================================
    // Data Generation Operations
    // ========================================================================

    /// Create a typed array for runtime data generation.
    pub fn createTypedArray(self: *Self, allocator: Allocator, array_id: u16, element_type: u8, element_count: u32) !void {
        _ = self;
        _ = allocator;
        gpuCreateTypedArray(array_id, element_type, element_count);
    }

    /// Fill array with random values.
    pub fn fillRandom(self: *Self, allocator: Allocator, array_id: u16, offset: u32, count: u32, stride: u8, min_data_id: u16, max_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);
        const min_data = self.getDataOrPanic(min_data_id);
        const max_data = self.getDataOrPanic(max_data_id);
        gpuFillRandom(array_id, offset, count, stride, min_data.ptr, max_data.ptr);
    }

    /// Fill array by evaluating expression for each element.
    pub fn fillExpression(self: *Self, allocator: Allocator, array_id: u16, offset: u32, count: u32, stride: u8, total_count: u32, expr_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);
        const expr_data = self.getDataOrPanic(expr_data_id);
        gpuFillExpression(array_id, offset, count, stride, total_count, expr_data.ptr, @intCast(expr_data.len));
    }

    /// Fill array with constant value.
    pub fn fillConstant(self: *Self, allocator: Allocator, array_id: u16, offset: u32, count: u32, stride: u8, value_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);
        const value_data = self.getDataOrPanic(value_data_id);
        gpuFillConstant(array_id, offset, count, stride, value_data.ptr);
    }

    /// Write generated array data to GPU buffer.
    pub fn writeBufferFromArray(self: *Self, allocator: Allocator, buffer_id: u16, buffer_offset: u32, array_id: u16) !void {
        _ = self;
        _ = allocator;
        gpuWriteBufferFromArray(buffer_id, buffer_offset, array_id);
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
