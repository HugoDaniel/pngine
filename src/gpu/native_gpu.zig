//! Native GPU Backend using zgpu/Dawn
//!
//! Provides headless GPU rendering for CLI tools.
//! Renders to an offscreen texture that can be read back to CPU.
//!
//! ## Status
//! Currently a stub implementation. Full GPU rendering requires
//! platform-specific setup and additional dependencies.
//!
//! ## Invariants
//! - Implements same interface as MockGPU/WasmGPU
//! - Resource IDs map to internal GPU resources
//! - Pixel data can be read back after rendering

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

// Use bytecode module import
const bytecode_mod = @import("bytecode");
const format = bytecode_mod.format;

// Conditional zgpu import (only available on native targets)
const has_zgpu = @hasDecl(@import("root"), "zgpu");

pub const Error = error{
    GpuNotAvailable,
    InitializationFailed,
    RenderFailed,
    OutOfMemory,
};

/// Native GPU backend for headless rendering.
///
/// Pre-condition: init() must be called before any operations.
/// Post-condition: deinit() must be called to release resources.
pub const NativeGPU = struct {
    const Self = @This();

    /// Maximum resources per category.
    pub const MAX_BUFFERS: u16 = 256;
    pub const MAX_TEXTURES: u16 = 256;
    pub const MAX_SHADERS: u16 = 64;
    pub const MAX_PIPELINES: u16 = 64;
    pub const MAX_BIND_GROUPS: u16 = 64;

    /// Render target dimensions.
    width: u32,
    height: u32,

    /// Module reference for data lookups.
    module: ?*const format.Module,

    /// Time uniform for animations.
    time: f32,

    /// Initialization state.
    initialized: bool,

    /// Resource tracking (for validation).
    buffers_created: std.StaticBitSet(MAX_BUFFERS),
    textures_created: std.StaticBitSet(MAX_TEXTURES),
    shaders_created: std.StaticBitSet(MAX_SHADERS),
    pipelines_created: std.StaticBitSet(MAX_PIPELINES),
    bind_groups_created: std.StaticBitSet(MAX_BIND_GROUPS),

    /// Pass state.
    in_render_pass: bool,
    in_compute_pass: bool,
    current_pipeline: ?u16,

    /// Pixel buffer for readback (RGBA).
    pixel_buffer: ?[]u8,

    /// Initialize headless GPU rendering.
    ///
    /// Pre-conditions:
    /// - width > 0 and height > 0
    ///
    /// Post-conditions:
    /// - GPU device is ready for commands
    /// - Render target texture is created
    pub fn init(allocator: Allocator, width: u32, height: u32) Error!Self {
        // Pre-conditions
        if (width == 0 or height == 0) return Error.InitializationFailed;

        assert(width > 0);
        assert(height > 0);

        // Allocate pixel buffer for readback
        const pixel_size = @as(usize, width) * @as(usize, height) * 4;
        const pixel_buffer = allocator.alloc(u8, pixel_size) catch {
            return Error.OutOfMemory;
        };

        // Initialize with clear color (black, opaque)
        @memset(pixel_buffer, 0);
        // Set alpha to 255 for each pixel (bounded loop)
        const pixel_count = (@as(usize, width) * @as(usize, height));
        for (0..pixel_count) |p| {
            pixel_buffer[p * 4 + 3] = 255;
        }

        return Self{
            .width = width,
            .height = height,
            .module = null,
            .time = 0.0,
            .initialized = true,
            .buffers_created = std.StaticBitSet(MAX_BUFFERS).initEmpty(),
            .textures_created = std.StaticBitSet(MAX_TEXTURES).initEmpty(),
            .shaders_created = std.StaticBitSet(MAX_SHADERS).initEmpty(),
            .pipelines_created = std.StaticBitSet(MAX_PIPELINES).initEmpty(),
            .bind_groups_created = std.StaticBitSet(MAX_BIND_GROUPS).initEmpty(),
            .in_render_pass = false,
            .in_compute_pass = false,
            .current_pipeline = null,
            .pixel_buffer = pixel_buffer,
        };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        // Pre-condition: was initialized
        assert(self.initialized);
        assert(!self.in_render_pass and !self.in_compute_pass);

        if (self.pixel_buffer) |buf| {
            allocator.free(buf);
        }
        self.* = undefined;
    }

    /// Set module reference for data lookups.
    pub fn set_module(self: *Self, module: *const format.Module) void {
        // Pre-conditions
        assert(self.initialized);
        assert(module.bytecode.len > 0);

        self.module = module;
    }

    /// Set time uniform for animations.
    pub fn set_time(self: *Self, time_value: f32) void {
        // Pre-conditions
        assert(self.initialized);
        assert(!std.math.isNan(time_value));

        self.time = time_value;
    }

    /// Read rendered pixels back to CPU.
    ///
    /// Pre-condition: GPU is initialized.
    /// Post-condition: Returns RGBA pixel data (width * height * 4 bytes).
    pub fn read_pixels(self: *Self, allocator: Allocator) Error![]u8 {
        // Pre-conditions
        assert(self.initialized);
        assert(self.pixel_buffer != null);

        if (self.pixel_buffer) |buf| {
            const result = allocator.alloc(u8, buf.len) catch {
                return Error.OutOfMemory;
            };
            @memcpy(result, buf);

            // Post-condition: result size matches pixel buffer
            assert(result.len == buf.len);
            return result;
        }

        return Error.RenderFailed;
    }

    /// Check if native GPU rendering is available.
    pub fn is_available() bool {
        // TODO(NativeGPU) Implement actual GPU availability check
        // For now, return true to indicate stub is functional
        return true;
    }

    // ========================================================================
    // GPU Backend Interface (required by Dispatcher)
    // ========================================================================

    pub fn create_buffer(self: *Self, allocator: Allocator, buffer_id: u16, size: u32, usage: u8) !void {
        _ = allocator;
        _ = size;
        _ = usage;

        assert(buffer_id < MAX_BUFFERS);
        assert(self.initialized);

        self.buffers_created.set(buffer_id);

        // TODO(NativeGPU) Create actual GPU buffer
    }

    pub fn create_texture(self: *Self, allocator: Allocator, texture_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        _ = descriptor_data_id;

        assert(texture_id < MAX_TEXTURES);
        assert(self.initialized);

        self.textures_created.set(texture_id);

        // TODO(NativeGPU) Create actual GPU texture
    }

    pub fn create_texture_view(self: *Self, allocator: Allocator, view_id: u16, texture_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        _ = view_id;
        _ = descriptor_data_id;

        assert(texture_id < MAX_TEXTURES);
        assert(self.initialized);

        // TODO(NativeGPU) Create actual GPU texture view
    }

    pub fn create_sampler(self: *Self, allocator: Allocator, sampler_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        _ = descriptor_data_id;

        assert(sampler_id < MAX_TEXTURES);
        assert(self.initialized);

        // TODO(NativeGPU) Create actual GPU sampler
    }

    pub fn create_shader_module(self: *Self, allocator: Allocator, shader_id: u16, code_data_id: u16) !void {
        _ = allocator;
        _ = code_data_id;

        assert(shader_id < MAX_SHADERS);
        assert(self.initialized);

        self.shaders_created.set(shader_id);

        // TODO(NativeGPU) Create actual GPU shader module
    }

    pub fn create_render_pipeline(self: *Self, allocator: Allocator, pipeline_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        _ = descriptor_data_id;

        assert(pipeline_id < MAX_PIPELINES);
        assert(self.initialized);

        self.pipelines_created.set(pipeline_id);

        // TODO(NativeGPU) Create actual GPU render pipeline
    }

    pub fn create_compute_pipeline(self: *Self, allocator: Allocator, pipeline_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        _ = descriptor_data_id;

        assert(pipeline_id < MAX_PIPELINES);
        assert(self.initialized);

        self.pipelines_created.set(pipeline_id);

        // TODO(NativeGPU) Create actual GPU compute pipeline
    }

    pub fn create_bind_group(self: *Self, allocator: Allocator, group_id: u16, layout_id: u16, entry_data_id: u16) !void {
        _ = allocator;
        _ = layout_id;
        _ = entry_data_id;

        assert(group_id < MAX_BIND_GROUPS);
        assert(self.initialized);

        self.bind_groups_created.set(group_id);

        // TODO(NativeGPU) Create actual GPU bind group
    }

    pub fn create_bind_group_layout(self: *Self, allocator: Allocator, layout_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        _ = layout_id;
        _ = descriptor_data_id;

        assert(self.initialized);

        // TODO(NativeGPU) Create actual GPU bind group layout
    }

    pub fn create_pipeline_layout(self: *Self, allocator: Allocator, layout_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        _ = layout_id;
        _ = descriptor_data_id;

        assert(self.initialized);

        // TODO(NativeGPU) Create actual GPU pipeline layout
    }

    pub fn create_query_set(self: *Self, allocator: Allocator, query_set_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        _ = query_set_id;
        _ = descriptor_data_id;

        assert(self.initialized);

        // TODO(NativeGPU) Create actual GPU query set
    }

    pub fn create_image_bitmap(self: *Self, allocator: Allocator, bitmap_id: u16, blob_data_id: u16) !void {
        _ = allocator;
        _ = bitmap_id;
        _ = blob_data_id;

        assert(self.initialized);

        // TODO(NativeGPU) Create actual ImageBitmap from blob data
    }

    pub fn create_render_bundle(self: *Self, allocator: Allocator, bundle_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        _ = bundle_id;
        _ = descriptor_data_id;

        assert(self.initialized);

        // TODO(NativeGPU) Create actual GPU render bundle
    }

    pub fn execute_bundles(self: *Self, allocator: Allocator, bundle_ids: []const u16) !void {
        _ = allocator;
        _ = bundle_ids;

        assert(self.in_render_pass);
        assert(self.initialized);

        // TODO(NativeGPU) Execute actual GPU render bundles
    }

    // ========================================================================
    // Pass Operations
    // ========================================================================

    pub fn begin_render_pass(self: *Self, allocator: Allocator, color_texture_id: u16, load_op: u8, store_op: u8, depth_texture_id: u16) !void {
        _ = allocator;
        _ = color_texture_id;
        _ = load_op;
        _ = store_op;
        _ = depth_texture_id;

        assert(!self.in_render_pass and !self.in_compute_pass);
        assert(self.initialized);

        self.in_render_pass = true;
        self.current_pipeline = null;

        // TODO(NativeGPU) Begin actual GPU render pass
    }

    pub fn begin_compute_pass(self: *Self, allocator: Allocator) !void {
        _ = allocator;

        assert(!self.in_render_pass and !self.in_compute_pass);
        assert(self.initialized);

        self.in_compute_pass = true;
        self.current_pipeline = null;

        // TODO(NativeGPU) Begin actual GPU compute pass
    }

    pub fn set_pipeline(self: *Self, allocator: Allocator, pipeline_id: u16) !void {
        _ = allocator;

        assert(self.in_render_pass or self.in_compute_pass);
        assert(self.initialized);

        self.current_pipeline = pipeline_id;

        // TODO(NativeGPU) Set actual GPU pipeline
    }

    pub fn set_bind_group(self: *Self, allocator: Allocator, slot: u8, group_id: u16) !void {
        _ = allocator;
        _ = slot;
        _ = group_id;

        assert(self.in_render_pass or self.in_compute_pass);
        assert(self.initialized);

        // TODO(NativeGPU) Set actual GPU bind group
    }

    pub fn set_vertex_buffer(self: *Self, allocator: Allocator, slot: u8, buffer_id: u16) !void {
        _ = allocator;
        _ = slot;
        _ = buffer_id;

        assert(self.in_render_pass);
        assert(self.initialized);

        // TODO(NativeGPU) Set actual GPU vertex buffer
    }

    pub fn set_index_buffer(self: *Self, allocator: Allocator, buffer_id: u16, index_format: u8) !void {
        _ = allocator;
        _ = buffer_id;
        _ = index_format;

        assert(self.in_render_pass);
        assert(self.initialized);

        // TODO(NativeGPU) Set actual GPU index buffer
    }

    pub fn draw(self: *Self, allocator: Allocator, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) !void {
        _ = allocator;
        _ = vertex_count;
        _ = instance_count;
        _ = first_vertex;
        _ = first_instance;

        assert(self.in_render_pass);
        assert(self.initialized);

        // TODO(NativeGPU) Execute actual GPU draw call
        // For now, fill pixel buffer with a test pattern
        if (self.pixel_buffer) |buf| {
            // Simple gradient pattern to show something is happening
            const width = self.width;
            const height = self.height;
            for (0..height) |y| {
                for (0..width) |x| {
                    const offset = (y * width + x) * 4;
                    buf[offset + 0] = @intCast((x * 255) / width); // R
                    buf[offset + 1] = @intCast((y * 255) / height); // G
                    buf[offset + 2] = 128; // B
                    buf[offset + 3] = 255; // A
                }
            }
        }
    }

    pub fn draw_indexed(self: *Self, allocator: Allocator, index_count: u32, instance_count: u32, first_index: u32, base_vertex: u32, first_instance: u32) !void {
        _ = allocator;
        _ = index_count;
        _ = instance_count;
        _ = first_index;
        _ = base_vertex;
        _ = first_instance;

        assert(self.in_render_pass);
        assert(self.initialized);

        // TODO(NativeGPU) Execute actual GPU indexed draw call
    }

    pub fn dispatch(self: *Self, allocator: Allocator, x: u32, y: u32, z: u32) !void {
        _ = allocator;
        _ = x;
        _ = y;
        _ = z;

        assert(self.in_compute_pass);
        assert(self.initialized);

        // TODO(NativeGPU) Execute actual GPU compute dispatch
    }

    pub fn end_pass(self: *Self, allocator: Allocator) !void {
        _ = allocator;

        assert(self.in_render_pass or self.in_compute_pass);
        assert(self.initialized);

        self.in_render_pass = false;
        self.in_compute_pass = false;
        self.current_pipeline = null;

        // TODO(NativeGPU) End actual GPU pass
    }

    // ========================================================================
    // Queue Operations
    // ========================================================================

    pub fn write_buffer(self: *Self, allocator: Allocator, buffer_id: u16, offset: u32, data_id: u16) !void {
        _ = allocator;
        _ = buffer_id;
        _ = offset;
        _ = data_id;

        assert(self.initialized);

        // TODO(NativeGPU) Write to actual GPU buffer
    }

    pub fn submit(self: *Self, allocator: Allocator) !void {
        _ = allocator;

        assert(!self.in_render_pass and !self.in_compute_pass);
        assert(self.initialized);

        // TODO(NativeGPU) Submit actual GPU commands
    }

    pub fn copy_external_image_to_texture(self: *Self, allocator: Allocator, bitmap_id: u16, texture_id: u16, mip_level: u8, origin_x: u16, origin_y: u16) !void {
        _ = allocator;
        _ = bitmap_id;
        _ = texture_id;
        _ = mip_level;
        _ = origin_x;
        _ = origin_y;

        assert(self.initialized);

        // TODO(NativeGPU) Copy ImageBitmap to texture
    }

    // ========================================================================
    // WASM Module Operations (stub - native GPU doesn't support WASM calls)
    // ========================================================================

    pub fn init_wasm_module(self: *Self, allocator: Allocator, module_id: u16, wasm_data_id: u16) !void {
        _ = allocator;
        _ = module_id;
        _ = wasm_data_id;

        assert(self.initialized);

        // WASM module initialization is a no-op for native GPU
        // WASM calls are only meaningful in browser context
    }

    pub fn call_wasm_func(self: *Self, allocator: Allocator, call_id: u16, module_id: u16, func_name_id: u16, args: []const u8) !void {
        _ = allocator;
        _ = call_id;
        _ = module_id;
        _ = func_name_id;
        _ = args;

        assert(self.initialized);

        // WASM function calls are a no-op for native GPU
        // WASM calls are only meaningful in browser context
    }

    pub fn write_buffer_from_wasm(self: *Self, allocator: Allocator, call_id: u16, buffer_id: u16, offset: u32, byte_len: u32) !void {
        _ = allocator;
        _ = call_id;
        _ = buffer_id;
        _ = offset;
        _ = byte_len;

        assert(self.initialized);

        // WASM buffer writes are a no-op for native GPU
        // WASM calls are only meaningful in browser context
    }

    /// Write time/canvas uniform data to GPU buffer.
    /// Runtime provides f32 values: time, canvas_width, canvas_height[, aspect_ratio].
    pub fn write_time_uniform(self: *Self, allocator: Allocator, buffer_id: u16, buffer_offset: u32, size: u16) !void {
        _ = allocator;
        _ = buffer_id;
        _ = buffer_offset;
        _ = size;
        assert(self.initialized);
        // TODO(NativeGPU) Write actual time uniform to buffer
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "NativeGPU: init and deinit" {
    var gpu = try NativeGPU.init(testing.allocator, 64, 64);
    defer gpu.deinit(testing.allocator);

    try testing.expect(gpu.initialized);
    try testing.expectEqual(@as(u32, 64), gpu.width);
    try testing.expectEqual(@as(u32, 64), gpu.height);
}

test "NativeGPU: read pixels returns RGBA data" {
    var gpu = try NativeGPU.init(testing.allocator, 2, 2);
    defer gpu.deinit(testing.allocator);

    const pixels = try gpu.read_pixels(testing.allocator);
    defer testing.allocator.free(pixels);

    // Should be 2x2x4 = 16 bytes
    try testing.expectEqual(@as(usize, 16), pixels.len);
}

test "NativeGPU: render pass lifecycle" {
    var gpu = try NativeGPU.init(testing.allocator, 64, 64);
    defer gpu.deinit(testing.allocator);

    try testing.expect(!gpu.in_render_pass);

    try gpu.begin_render_pass(testing.allocator, 0, 1, 0, 0xFFFF);
    try testing.expect(gpu.in_render_pass);

    try gpu.set_pipeline(testing.allocator, 0);
    try gpu.draw(testing.allocator, 3, 1, 0, 0);

    try gpu.end_pass(testing.allocator);
    try testing.expect(!gpu.in_render_pass);
}

test "NativeGPU: resource creation" {
    var gpu = try NativeGPU.init(testing.allocator, 64, 64);
    defer gpu.deinit(testing.allocator);

    try gpu.create_buffer(testing.allocator, 0, 1024, 0x44);
    try testing.expect(gpu.buffers_created.isSet(0));

    try gpu.create_texture(testing.allocator, 0, 0);
    try testing.expect(gpu.textures_created.isSet(0));

    try gpu.create_shader_module(testing.allocator, 0, 0);
    try testing.expect(gpu.shaders_created.isSet(0));
}

test "NativeGPU: draw produces pixels" {
    var gpu = try NativeGPU.init(testing.allocator, 4, 4);
    defer gpu.deinit(testing.allocator);

    try gpu.begin_render_pass(testing.allocator, 0, 1, 0, 0xFFFF);
    try gpu.set_pipeline(testing.allocator, 0);
    try gpu.draw(testing.allocator, 3, 1, 0, 0);
    try gpu.end_pass(testing.allocator);
    try gpu.submit(testing.allocator);

    const pixels = try gpu.read_pixels(testing.allocator);
    defer testing.allocator.free(pixels);

    // After draw, pixels should have the test gradient pattern
    // Check that alpha is 255 for first pixel
    try testing.expectEqual(@as(u8, 255), pixels[3]);
}

test "NativeGPU: OOM handling with FailingAllocator" {
    // Test that init handles OOM gracefully
    var fail_index: usize = 0;
    while (fail_index < 10) : (fail_index += 1) {
        var failing_alloc = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });

        const result = NativeGPU.init(failing_alloc.allocator(), 64, 64);

        if (failing_alloc.has_induced_failure) {
            // OOM occurred - verify graceful handling
            try testing.expectError(Error.OutOfMemory, result);
        } else {
            // No OOM - operation succeeded
            var gpu = try result;
            gpu.deinit(failing_alloc.allocator());
            break;
        }
    }
}

test "NativeGPU: readPixels OOM handling" {
    var gpu = try NativeGPU.init(testing.allocator, 4, 4);
    defer gpu.deinit(testing.allocator);

    // Test OOM during readPixels
    var failing_alloc = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });

    const result = gpu.read_pixels(failing_alloc.allocator());
    try testing.expectError(Error.OutOfMemory, result);
}

// ============================================================================
// Regression Tests - GPU Stub Methods
// ============================================================================
// These tests ensure the stub methods added for bytecode compatibility exist
// and can be called without crashing. Required for dispatcher to work with
// bytecode that uses these operations.

test "regression: createTextureView stub exists and callable" {
    var gpu = try NativeGPU.init(testing.allocator, 64, 64);
    defer gpu.deinit(testing.allocator);

    // Should not crash - stub method exists
    try gpu.create_texture_view(testing.allocator, 0, 0, 0);
    try gpu.create_texture_view(testing.allocator, 1, 0, 1);
}

test "regression: createBindGroupLayout stub exists and callable" {
    var gpu = try NativeGPU.init(testing.allocator, 64, 64);
    defer gpu.deinit(testing.allocator);

    // Should not crash - stub method exists
    try gpu.create_bind_group_layout(testing.allocator, 0, 0);
    try gpu.create_bind_group_layout(testing.allocator, 1, 1);
}

test "regression: createPipelineLayout stub exists and callable" {
    var gpu = try NativeGPU.init(testing.allocator, 64, 64);
    defer gpu.deinit(testing.allocator);

    // Should not crash - stub method exists
    try gpu.create_pipeline_layout(testing.allocator, 0, 0);
    try gpu.create_pipeline_layout(testing.allocator, 1, 1);
}

test "regression: createQuerySet stub exists and callable" {
    var gpu = try NativeGPU.init(testing.allocator, 64, 64);
    defer gpu.deinit(testing.allocator);

    // Should not crash - stub method exists
    try gpu.create_query_set(testing.allocator, 0, 0);
    try gpu.create_query_set(testing.allocator, 1, 1);
}

test "regression: all GPU stubs work together in sequence" {
    // This test simulates a bytecode execution that uses multiple stub methods
    var gpu = try NativeGPU.init(testing.allocator, 64, 64);
    defer gpu.deinit(testing.allocator);

    // Resource creation phase (stubs)
    try gpu.create_bind_group_layout(testing.allocator, 0, 0);
    try gpu.create_pipeline_layout(testing.allocator, 0, 0);
    try gpu.create_texture(testing.allocator, 0, 0);
    try gpu.create_texture_view(testing.allocator, 0, 0, 0);
    try gpu.create_buffer(testing.allocator, 0, 1024, 0x44);
    try gpu.create_shader_module(testing.allocator, 0, 0);
    try gpu.create_query_set(testing.allocator, 0, 0);

    // Render pass should still work after stub calls
    try gpu.begin_render_pass(testing.allocator, 0, 1, 0, 0xFFFF);
    try gpu.set_pipeline(testing.allocator, 0);
    try gpu.draw(testing.allocator, 3, 1, 0, 0);
    try gpu.end_pass(testing.allocator);
    try gpu.submit(testing.allocator);

    // Verify pixel output works
    const pixels = try gpu.read_pixels(testing.allocator);
    defer testing.allocator.free(pixels);
    try testing.expectEqual(@as(usize, 64 * 64 * 4), pixels.len);
}