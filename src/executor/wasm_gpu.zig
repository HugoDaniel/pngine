//! WASM WebGPU Backend
//!
//! Calls out to JavaScript WebGPU implementation via extern functions.
//! Used when running in the browser via WASM.
//!
//! ## Data Flow
//!
//! 1. Bytecode calls create_shader_module(shader_id, wgsl_id)
//! 2. WasmGPU resolves wgsl_id from Module.wgsl table:
//!    - Walk dependencies in topological order (iterative DFS)
//!    - Concatenate raw code from data section with deduplication
//! 3. Passes resolved code pointer + length to JS
//! 4. JS reads string from WASM memory, calls device.createShaderModule
//!
//! ## Invariants
//!
//! - Module must be set before any GPU calls
//! - All data IDs must reference valid module data
//! - JS is responsible for resource tracking and error handling
//! - Resolution uses bounded iteration (MAX_WGSL_MODULES × MAX_WGSL_DEPS)

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

// Use bytecode module import
const bytecode_mod = @import("bytecode");
const format = bytecode_mod.format;
const Module = format.Module;
const DataSection = bytecode_mod.DataSection;
const DataId = bytecode_mod.DataId;

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
extern "env" fn gpuCreateRenderBundle(bundle_id: u16, desc_ptr: [*]const u8, desc_len: u32) void;
extern "env" fn gpuBeginRenderPass(color_texture_id: u16, load_op: u8, store_op: u8, depth_texture_id: u16) void;
extern "env" fn gpuBeginComputePass() void;
extern "env" fn gpuSetPipeline(pipeline_id: u16) void;
extern "env" fn gpuSetBindGroup(slot: u8, group_id: u16) void;
extern "env" fn gpuSetVertexBuffer(slot: u8, buffer_id: u16) void;
extern "env" fn gpuSetIndexBuffer(buffer_id: u16, index_format: u8) void;
extern "env" fn gpuDraw(vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void;
extern "env" fn gpuDrawIndexed(index_count: u32, instance_count: u32, first_index: u32, base_vertex: u32, first_instance: u32) void;
extern "env" fn gpuDispatch(x: u32, y: u32, z: u32) void;
extern "env" fn gpuExecuteBundles(bundle_ids_ptr: [*]const u16, bundle_count: u16) void;
extern "env" fn gpuEndPass() void;
pub extern "env" fn gpuWriteBuffer(buffer_id: u16, offset: u32, data_ptr: [*]const u8, data_len: u32) void;
extern "env" fn gpuSubmit() void;
extern "env" fn gpuCopyExternalImageToTexture(bitmap_id: u16, texture_id: u16, mip_level: u8, origin_x: u16, origin_y: u16) void;
extern "env" fn gpuInitWasmModule(module_id: u16, data_ptr: [*]const u8, data_len: u32) void;
extern "env" fn gpuCallWasmFunc(call_id: u16, module_id: u16, func_name_ptr: [*]const u8, func_name_len: u32, args_ptr: [*]const u8, args_len: u32) void;
extern "env" fn gpuWriteBufferFromWasm(call_id: u16, buffer_id: u16, offset: u32, byte_len: u32) void;

extern "env" fn gpuWriteTimeUniform(buffer_id: u16, buffer_offset: u32, size: u16) void;

// Debug logging
pub extern "env" fn gpuDebugLog(msg_type: u8, value: u32) void;
extern "env" fn jsConsoleLog(ptr: [*]const u8, len: u32) void;

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
    pub fn set_module(self: *Self, module: *const Module) void {
        self.module = module;
    }

    // ======================================================================== 
    // Debug Logging
    // ======================================================================== 

    /// Log a message to the console.
    pub fn console_log(_: *Self, prefix: []const u8, msg: []const u8) void {
        // Concatenate prefix and msg (simple approach using stack buffer)
        var buf: [512]u8 = undefined;
        const total_len = @min(prefix.len + msg.len, buf.len);
        @memcpy(buf[0..prefix.len], prefix);
        if (msg.len > 0 and prefix.len + msg.len <= buf.len) {
            @memcpy(buf[prefix.len .. prefix.len + msg.len], msg);
        }
        jsConsoleLog(&buf, @intCast(total_len));
    }

    // ======================================================================== 
    // Resource Creation
    // ======================================================================== 

    /// Create a GPU buffer.
    /// Allocator unused - no WASM-side allocation needed.
    pub fn create_buffer(self: *Self, allocator: Allocator, buffer_id: u16, size: u32, usage: u8) !void {
        _ = self;
        _ = allocator;
        gpuCreateBuffer(buffer_id, size, usage);
    }

    /// Create a GPU texture from descriptor in the data section.
    pub fn create_texture(self: *Self, allocator: Allocator, texture_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.get_data_or_panic(descriptor_data_id);
        gpuCreateTexture(texture_id, data.ptr, @intCast(data.len));
    }

    /// Create a texture sampler from descriptor in the data section.
    pub fn create_sampler(self: *Self, allocator: Allocator, sampler_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.get_data_or_panic(descriptor_data_id);
        gpuCreateSampler(sampler_id, data.ptr, @intCast(data.len));
    }

    /// Create a shader module from WGSL code.
    /// Resolves wgsl_id from the WGSL table, walking dependencies and concatenating code.
    pub fn create_shader_module(self: *Self, allocator: Allocator, shader_id: u16, wgsl_id: u16) !void {
        // Debug: log entry into create_shader_module
        gpuDebugLog(2, 0xAAAA); // Marker: entering create_shader_module
        gpuDebugLog(2, shader_id);
        gpuDebugLog(2, wgsl_id);

        // Pre-condition: module must be set
        if (self.module == null) {
            gpuDebugLog(2, 0xDEAD); // Marker: module is null!
            return error.OutOfMemory;
        }

        // Resolve from WGSL table (deduplicates transitive imports)
        const resolved = self.resolve_wgsl(allocator, wgsl_id) catch |err| {
            gpuDebugLog(2, 0xBEEF); // Marker: resolve_wgsl failed
            return err;
        };
        defer allocator.free(resolved);

        gpuDebugLog(2, 0xCCCC); // Marker: about to call gpuCreateShaderModule
        gpuDebugLog(2, @intCast(resolved.len));

        gpuCreateShaderModule(shader_id, resolved.ptr, @intCast(resolved.len));
    }

    /// Resolve a WGSL module by ID, concatenating all dependencies.
    /// Uses iterative DFS with deduplication (no recursion).
    /// Memory: Caller owns returned slice.
    fn resolve_wgsl(self: *Self, allocator: Allocator, wgsl_id: u16) ![]u8 {
        const module = self.module orelse return error.OutOfMemory;
        const wgsl_table = &module.wgsl;

        // Debug: log WGSL table info
        gpuDebugLog(2, wgsl_table.count()); // Log WGSL table count
        gpuDebugLog(2, wgsl_id); // Log requested wgsl_id

        // Maximum iterations for bounded execution
        const max_iterations: u32 = @as(u32, format.MAX_WGSL_MODULES) * @as(u32, format.MAX_WGSL_DEPS);

        // Track included modules and order
        var included = std.AutoHashMapUnmanaged(u16, void){};
        defer included.deinit(allocator);

        var order = std.ArrayListUnmanaged(u16){};
        defer order.deinit(allocator);

        var stack = std.ArrayListUnmanaged(u16){};
        defer stack.deinit(allocator);

        try stack.append(allocator, wgsl_id);

        // Iterative DFS
        for (0..max_iterations) |_| {
            if (stack.items.len == 0) break;

            const current = stack.pop() orelse break;

            // Skip if already included
            if (included.contains(current)) continue;

            // Get WGSL entry
            const entry = wgsl_table.get(current) orelse {
                gpuDebugLog(2, 0xFFFF); // Log: entry not found
                gpuDebugLog(2, current); // Log which ID was not found
                continue;
            };

            // Check if all deps are included
            var all_deps_ready = true;
            for (entry.deps) |dep| {
                if (!included.contains(dep)) {
                    all_deps_ready = false;
                    try stack.append(allocator, current); // Re-push current
                    try stack.append(allocator, dep); // Process dep first
                    break;
                }
            }

            if (all_deps_ready) {
                try included.put(allocator, current, {});
                try order.append(allocator, current);
            }
        }

        // Debug: log how many modules will be concatenated
        gpuDebugLog(2, @intCast(order.items.len));

        // Calculate total size
        var total_size: usize = 0;
        for (order.items) |id| {
            const entry = wgsl_table.get(id) orelse continue;
            const data = module.data.get(@enumFromInt(entry.data_id));
            total_size += data.len + 1; // +1 for newline
        }

        // Debug: log total code size
        gpuDebugLog(2, @intCast(total_size));

        // Allocate and concatenate
        const result = try allocator.alloc(u8, total_size);
        var pos: usize = 0;

        for (order.items) |id| {
            const entry = wgsl_table.get(id) orelse continue;
            const data = module.data.get(@enumFromInt(entry.data_id));
            if (data.len > 0) {
                @memcpy(result[pos..][0..data.len], data);
                pos += data.len;
                result[pos] = '\n';
                pos += 1;
            }
        }

        // Post-condition: filled buffer
        assert(pos == total_size);

        return result;
    }

    /// Create a render pipeline from descriptor in the data section.
    pub fn create_render_pipeline(self: *Self, allocator: Allocator, pipeline_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.get_data_or_panic(descriptor_data_id);
        gpuCreateRenderPipeline(pipeline_id, data.ptr, @intCast(data.len));
    }

    /// Create a compute pipeline from descriptor in the data section.
    pub fn create_compute_pipeline(self: *Self, allocator: Allocator, pipeline_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.get_data_or_panic(descriptor_data_id);
        gpuCreateComputePipeline(pipeline_id, data.ptr, @intCast(data.len));
    }

    /// Create a bind group from entries in the data section.
    pub fn create_bind_group(self: *Self, allocator: Allocator, group_id: u16, layout_id: u16, entry_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.get_data_or_panic(entry_data_id);
        gpuCreateBindGroup(group_id, layout_id, data.ptr, @intCast(data.len));
    }

    /// Create an ImageBitmap from blob data in the data section.
    /// Blob format: [mime_len:u8][mime:bytes][data:bytes]
    pub fn create_image_bitmap(self: *Self, allocator: Allocator, bitmap_id: u16, blob_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.get_data_or_panic(blob_data_id);
        gpuCreateImageBitmap(bitmap_id, data.ptr, @intCast(data.len));
    }

    /// Create a texture view from an existing texture.
    pub fn create_texture_view(self: *Self, allocator: Allocator, view_id: u16, texture_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.get_data_or_panic(descriptor_data_id);
        gpuCreateTextureView(view_id, texture_id, data.ptr, @intCast(data.len));
    }

    /// Create a query set for occlusion or timestamp queries.
    pub fn create_query_set(self: *Self, allocator: Allocator, query_set_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.get_data_or_panic(descriptor_data_id);
        gpuCreateQuerySet(query_set_id, data.ptr, @intCast(data.len));
    }

    /// Create a bind group layout defining binding slot types.
    pub fn create_bind_group_layout(self: *Self, allocator: Allocator, layout_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.get_data_or_panic(descriptor_data_id);
        gpuCreateBindGroupLayout(layout_id, data.ptr, @intCast(data.len));
    }

    /// Create a pipeline layout from bind group layouts.
    pub fn create_pipeline_layout(self: *Self, allocator: Allocator, layout_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.get_data_or_panic(descriptor_data_id);
        gpuCreatePipelineLayout(layout_id, data.ptr, @intCast(data.len));
    }

    /// Create a render bundle from pre-recorded draw commands.
    pub fn create_render_bundle(self: *Self, allocator: Allocator, bundle_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.get_data_or_panic(descriptor_data_id);
        gpuCreateRenderBundle(bundle_id, data.ptr, @intCast(data.len));
    }

    // ======================================================================== 
    // Pass Operations
    // ======================================================================== 

    /// Begin a render pass.
    pub fn begin_render_pass(self: *Self, allocator: Allocator, color_texture_id: u16, load_op: u8, store_op: u8, depth_texture_id: u16) !void {
        _ = self;
        _ = allocator;
        gpuBeginRenderPass(color_texture_id, load_op, store_op, depth_texture_id);
    }

    /// Begin a compute pass.
    pub fn begin_compute_pass(self: *Self, allocator: Allocator) !void {
        _ = self;
        _ = allocator;
        gpuBeginComputePass();
    }

    /// Set the current pipeline.
    pub fn set_pipeline(self: *Self, allocator: Allocator, pipeline_id: u16) !void {
        _ = self;
        _ = allocator;
        gpuSetPipeline(pipeline_id);
    }

    /// Set a bind group.
    pub fn set_bind_group(self: *Self, allocator: Allocator, slot: u8, group_id: u16) !void {
        _ = self;
        _ = allocator;
        gpuSetBindGroup(slot, group_id);
    }

    /// Set a vertex buffer.
    pub fn set_vertex_buffer(self: *Self, allocator: Allocator, slot: u8, buffer_id: u16) !void {
        _ = self;
        _ = allocator;
        gpuSetVertexBuffer(slot, buffer_id);
    }

    /// Set an index buffer.
    pub fn set_index_buffer(self: *Self, allocator: Allocator, buffer_id: u16, index_format: u8) !void {
        _ = self;
        _ = allocator;
        gpuSetIndexBuffer(buffer_id, index_format);
    }

    /// Draw primitives.
    pub fn draw(self: *Self, allocator: Allocator, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) !void {
        _ = self;
        _ = allocator;
        gpuDraw(vertex_count, instance_count, first_vertex, first_instance);
    }

    /// Draw indexed primitives.
    pub fn draw_indexed(self: *Self, allocator: Allocator, index_count: u32, instance_count: u32, first_index: u32, base_vertex: u32, first_instance: u32) !void {
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

    /// Execute pre-recorded render bundles.
    pub fn execute_bundles(self: *Self, allocator: Allocator, bundle_ids: []const u16) !void {
        _ = self;
        _ = allocator;
        gpuExecuteBundles(bundle_ids.ptr, @intCast(bundle_ids.len));
    }

    /// End the current pass.
    pub fn end_pass(self: *Self, allocator: Allocator) !void {
        _ = self;
        _ = allocator;
        gpuEndPass();
    }

    // ======================================================================== 
    // Queue Operations
    // ======================================================================== 

    /// Write data to a buffer.
    pub fn write_buffer(self: *Self, allocator: Allocator, buffer_id: u16, offset: u32, data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.get_data_or_panic(data_id);
        gpuWriteBuffer(buffer_id, offset, data.ptr, @intCast(data.len));
    }

    /// Submit command buffer to queue.
    pub fn submit(self: *Self, allocator: Allocator) !void {
        _ = self;
        _ = allocator;
        gpuSubmit();
    }

    /// Copy an ImageBitmap to a texture.
    pub fn copy_external_image_to_texture(self: *Self, allocator: Allocator, bitmap_id: u16, texture_id: u16, mip_level: u8, origin_x: u16, origin_y: u16) !void {
        _ = self;
        _ = allocator;
        gpuCopyExternalImageToTexture(bitmap_id, texture_id, mip_level, origin_x, origin_y);
    }

    // ======================================================================== 
    // WASM Module Operations
    // ======================================================================== 

    /// Initialize a WASM module from embedded data.
    pub fn init_wasm_module(self: *Self, allocator: Allocator, module_id: u16, wasm_data_id: u16) !void {
        _ = allocator;
        assert(self.module != null);

        const data = self.get_data_or_panic(wasm_data_id);
        gpuInitWasmModule(module_id, data.ptr, @intCast(data.len));
    }

    /// Call a WASM exported function.
    /// The function name comes from string table, args are pre-encoded.
    pub fn call_wasm_func(self: *Self, allocator: Allocator, call_id: u16, module_id: u16, func_name_id: u16, args: []const u8) !void {
        _ = allocator;
        assert(self.module != null);

        // Get function name from string table
        const func_name = self.module.?.strings.get(@enumFromInt(func_name_id));

        // Pass encoded args to JS for runtime resolution
        gpuCallWasmFunc(call_id, module_id, func_name.ptr, @intCast(func_name.len), args.ptr, @intCast(args.len));
    }

    /// Write bytes from WASM memory to a GPU buffer.
    pub fn write_buffer_from_wasm(self: *Self, allocator: Allocator, call_id: u16, buffer_id: u16, offset: u32, byte_len: u32) !void {
        _ = self;
        _ = allocator;
        gpuWriteBufferFromWasm(call_id, buffer_id, offset, byte_len);
    }

    /// Write time/canvas uniform data to GPU buffer.
    /// Runtime provides f32 values: time, canvas_width, canvas_height[, aspect_ratio].
    pub fn write_time_uniform(self: *Self, allocator: Allocator, buffer_id: u16, buffer_offset: u32, size: u16) !void {
        _ = self;
        _ = allocator;
        gpuWriteTimeUniform(buffer_id, buffer_offset, size);
    }

    // ======================================================================== 
    // Internal Helpers
    // ======================================================================== 

    /// Get data from module by ID.
    /// Panics if module not set or ID invalid (programming error).
    fn get_data_or_panic(self: *const Self, data_id: u16) []const u8 {
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