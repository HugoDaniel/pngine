//! Dawn GPU Backend for Headless Rendering
//!
//! Provides actual WebGPU rendering via Dawn for CLI tools.
//! Renders to an offscreen texture that can be read back to CPU.
//!
//! ## Design
//! - Uses zgpu/Dawn for cross-platform GPU access
//! - Headless mode: no window/surface required
//! - Resource tracking via fixed-size arrays (no dynamic allocation after init)
//! - Pixel readback via buffer mapping
//!
//! ## Invariants
//! - Implements same interface as NativeGPU/MockGPU
//! - Resource IDs map to actual GPU resources
//! - Pixel data can be read back after rendering

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

// Use bytecode module import
const bytecode_mod = @import("bytecode");
const format = bytecode_mod.format;

// Check if zgpu is available via build options
const gpu_build_options = @import("gpu_build_options");
pub const has_zgpu = gpu_build_options.has_zgpu;

pub const Error = error{
    GpuNotAvailable,
    InitializationFailed,
    RenderFailed,
    AdapterRequestFailed,
    DeviceRequestFailed,
    ShaderCompilationFailed,
    OutOfMemory,
};

// Import wgpu only when zgpu is available
const wgpu = if (has_zgpu) @import("zgpu").wgpu else struct {};

/// Dawn GPU backend for headless rendering.
///
/// Pre-condition: init() must be called before any operations.
/// Post-condition: deinit() must be called to release resources.
pub const DawnGPU = struct {
    const Self = @This();

    /// Maximum resources per category.
    pub const MAX_BUFFERS: u16 = 256;
    pub const MAX_TEXTURES: u16 = 256;
    pub const MAX_SHADERS: u16 = 64;
    pub const MAX_PIPELINES: u16 = 64;
    pub const MAX_BIND_GROUPS: u16 = 64;
    pub const MAX_BIND_GROUP_LAYOUTS: u16 = 64;

    /// Render target dimensions.
    width: u32,
    height: u32,

    /// Module reference for data lookups.
    module: ?*const format.Module,

    /// Time uniform for animations.
    time: f32,

    /// Initialization state.
    initialized: bool,

    /// Allocator for resource management.
    allocator: Allocator,

    /// Dawn/wgpu handles.
    instance: wgpu.Instance,
    adapter: wgpu.Adapter,
    device: wgpu.Device,
    queue: wgpu.Queue,

    /// Render target texture and view.
    render_texture: wgpu.Texture,
    render_view: wgpu.TextureView,

    /// Readback buffer for pixel data.
    readback_buffer: wgpu.Buffer,

    /// Resource storage.
    buffers: [MAX_BUFFERS]?wgpu.Buffer,
    textures: [MAX_TEXTURES]?wgpu.Texture,
    texture_views: [MAX_TEXTURES]?wgpu.TextureView,
    samplers: [MAX_TEXTURES]?wgpu.Sampler,
    shaders: [MAX_SHADERS]?wgpu.ShaderModule,
    render_pipelines: [MAX_PIPELINES]?wgpu.RenderPipeline,
    compute_pipelines: [MAX_PIPELINES]?wgpu.ComputePipeline,
    bind_groups: [MAX_BIND_GROUPS]?wgpu.BindGroup,
    bind_group_layouts: [MAX_BIND_GROUP_LAYOUTS]?wgpu.BindGroupLayout,

    /// Pass state.
    in_render_pass: bool,
    in_compute_pass: bool,
    current_pipeline: ?u16,
    command_encoder: ?wgpu.CommandEncoder,
    render_pass: ?wgpu.RenderPassEncoder,
    compute_pass: ?wgpu.ComputePassEncoder,

    /// Initialize headless GPU rendering via Dawn.
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

        // Create wgpu instance
        const instance = wgpu.createInstance(.{});
        if (instance == null) return Error.GpuNotAvailable;

        // Request adapter (headless - no surface)
        var adapter: ?wgpu.Adapter = null;
        var adapter_ready = false;
        instance.?.requestAdapter(.{
            .power_preference = .high_performance,
            .compatible_surface = null, // Headless
        }, &adapter_callback, @ptrCast(&adapter), @ptrCast(&adapter_ready));

        // Wait for adapter (Dawn is synchronous on native)
        if (!adapter_ready or adapter == null) return Error.AdapterRequestFailed;

        // Request device
        var device: ?wgpu.Device = null;
        var device_ready = false;
        adapter.?.requestDevice(.{}, &device_callback, @ptrCast(&device), @ptrCast(&device_ready));

        if (!device_ready or device == null) return Error.DeviceRequestFailed;

        const queue = device.?.getQueue();

        // Create render target texture (RGBA8)
        const render_texture = device.?.createTexture(.{
            .size = .{ .width = width, .height = height, .depth_or_array_layers = 1 },
            .format = .rgba8_unorm,
            .usage = .{ .render_attachment = true, .copy_src = true },
            .mip_level_count = 1,
            .sample_count = 1,
        });

        const render_view = render_texture.createView(.{});

        // Create readback buffer (for copying pixels from texture)
        const bytes_per_row = align_to_256(width * 4);
        const readback_size = bytes_per_row * height;
        const readback_buffer = device.?.createBuffer(.{
            .size = readback_size,
            .usage = .{ .map_read = true, .copy_dst = true },
        });

        var self = Self{
            .width = width,
            .height = height,
            .module = null,
            .time = 0.0,
            .initialized = true,
            .allocator = allocator,
            .instance = instance.?,
            .adapter = adapter.?,
            .device = device.?,
            .queue = queue,
            .render_texture = render_texture,
            .render_view = render_view,
            .readback_buffer = readback_buffer,
            .buffers = [_]?wgpu.Buffer{null} ** MAX_BUFFERS,
            .textures = [_]?wgpu.Texture{null} ** MAX_TEXTURES,
            .texture_views = [_]?wgpu.TextureView{null} ** MAX_TEXTURES,
            .samplers = [_]?wgpu.Sampler{null} ** MAX_TEXTURES,
            .shaders = [_]?wgpu.ShaderModule{null} ** MAX_SHADERS,
            .render_pipelines = [_]?wgpu.RenderPipeline{null} ** MAX_PIPELINES,
            .compute_pipelines = [_]?wgpu.ComputePipeline{null} ** MAX_PIPELINES,
            .bind_groups = [_]?wgpu.BindGroup{null} ** MAX_BIND_GROUPS,
            .bind_group_layouts = [_]?wgpu.BindGroupLayout{null} ** MAX_BIND_GROUP_LAYOUTS,
            .in_render_pass = false,
            .in_compute_pass = false,
            .current_pipeline = null,
            .command_encoder = null,
            .render_pass = null,
            .compute_pass = null,
        };

        // Store render target in textures[0] for contextCurrentTexture
        self.textures[0] = render_texture;
        self.texture_views[0] = render_view;

        return self;
    }

    /// Align to 256 bytes (wgpu requirement for buffer copies).
    fn align_to_256(value: u32) u32 {
        return (value + 255) & ~@as(u32, 255);
    }

    fn adapter_callback(status: wgpu.RequestAdapterStatus, adapter: ?wgpu.Adapter, message: ?[*:0]const u8, userdata1: ?*anyopaque, userdata2: ?*anyopaque) void {
        _ = message;
        if (status == .success) {
            const adapter_ptr: *?wgpu.Adapter = @ptrCast(@alignCast(userdata1));
            adapter_ptr.* = adapter;
        }
        const ready_ptr: *bool = @ptrCast(@alignCast(userdata2));
        ready_ptr.* = true;
    }

    fn device_callback(status: wgpu.RequestDeviceStatus, device: ?wgpu.Device, message: ?[*:0]const u8, userdata1: ?*anyopaque, userdata2: ?*anyopaque) void {
        _ = message;
        if (status == .success) {
            const device_ptr: *?wgpu.Device = @ptrCast(@alignCast(userdata1));
            device_ptr.* = device;
        }
        const ready_ptr: *bool = @ptrCast(@alignCast(userdata2));
        ready_ptr.* = true;
    }

    pub fn deinit(self: *Self, _: Allocator) void {
        assert(self.initialized);
        assert(!self.in_render_pass and !self.in_compute_pass);

        // Release resources in reverse order of creation
        self.readback_buffer.destroy();
        self.render_view.release();
        self.render_texture.destroy();

        // Release created resources
        for (&self.buffers) |*buf| {
            if (buf.*) |b| b.destroy();
            buf.* = null;
        }
        for (&self.bind_groups) |*bg| {
            if (bg.*) |g| g.release();
            bg.* = null;
        }
        for (&self.render_pipelines) |*p| {
            if (p.*) |pipe| pipe.release();
            p.* = null;
        }
        for (&self.compute_pipelines) |*p| {
            if (p.*) |pipe| pipe.release();
            p.* = null;
        }
        for (&self.shaders) |*s| {
            if (s.*) |shader| shader.release();
            s.* = null;
        }

        self.device.release();
        self.adapter.release();
        self.instance.release();

        self.* = undefined;
    }

    /// Set module reference for data lookups.
    pub fn set_module(self: *Self, module: *const format.Module) void {
        assert(self.initialized);
        assert(module.bytecode.len > 0);
        self.module = module;
    }

    /// Set time uniform for animations.
    pub fn set_time(self: *Self, time_value: f32) void {
        assert(self.initialized);
        assert(!std.math.isNan(time_value));
        self.time = time_value;
    }

    /// Read rendered pixels back to CPU.
    ///
    /// Pre-condition: GPU is initialized and rendering is complete.
    /// Post-condition: Returns RGBA pixel data (width * height * 4 bytes).
    pub fn read_pixels(self: *Self, allocator: Allocator) Error![]u8 {
        assert(self.initialized);

        // Copy render texture to readback buffer
        const encoder = self.device.createCommandEncoder(.{});
        const bytes_per_row = align_to_256(self.width * 4);

        encoder.copyTextureToBuffer(
            .{ .texture = self.render_texture },
            .{
                .buffer = self.readback_buffer,
                .layout = .{
                    .bytes_per_row = bytes_per_row,
                    .rows_per_image = self.height,
                },
            },
            .{ .width = self.width, .height = self.height, .depth_or_array_layers = 1 },
        );

        const commands = encoder.finish(.{});
        self.queue.submit(&[_]wgpu.CommandBuffer{commands});

        // Map buffer and read data
        var mapped = false;
        self.readback_buffer.mapAsync(.{ .read = true }, 0, bytes_per_row * self.height, &map_callback, @ptrCast(&mapped));

        // Wait for map (Dawn is synchronous)
        // In a real implementation, we'd poll the device
        var wait_count: u32 = 0;
        while (!mapped and wait_count < 1000) : (wait_count += 1) {
            // Dawn processes callbacks during tick
            _ = self.device.tick();
        }

        if (!mapped) return Error.RenderFailed;

        // Copy data
        const mapped_ptr = self.readback_buffer.getConstMappedRange(0, bytes_per_row * self.height);
        if (mapped_ptr == null) return Error.RenderFailed;

        const mapped_data: [*]const u8 = @ptrCast(mapped_ptr);

        // Allocate output buffer (without padding)
        const pixel_count = self.width * self.height;
        const result = allocator.alloc(u8, pixel_count * 4) catch return Error.OutOfMemory;

        // Copy rows (removing padding)
        for (0..self.height) |y| {
            const src_offset = y * bytes_per_row;
            const dst_offset = y * self.width * 4;
            @memcpy(result[dst_offset..][0 .. self.width * 4], mapped_data[src_offset..][0 .. self.width * 4]);
        }

        self.readback_buffer.unmap();

        assert(result.len == pixel_count * 4);
        return result;
    }

    fn map_callback(status: wgpu.BufferMapAsyncStatus, userdata: ?*anyopaque) void {
        if (status == .success) {
            const mapped_ptr: *bool = @ptrCast(@alignCast(userdata));
            mapped_ptr.* = true;
        }
    }

    /// Check if Dawn GPU rendering is available.
    pub fn is_available() bool {
        // Try to create an instance
        const instance = wgpu.createInstance(.{});
        if (instance) |inst| {
            inst.release();
            return true;
        }
        return false;
    }

    // ========================================================================
    // GPU Backend Interface (required by Dispatcher)
    // ========================================================================

    pub fn create_buffer(self: *Self, _: Allocator, buffer_id: u16, size: u32, usage: u8) !void {
        assert(buffer_id < MAX_BUFFERS);
        assert(self.initialized);

        // Map usage flags
        var wgpu_usage: wgpu.BufferUsage = .{};
        if (usage & 0x01 != 0) wgpu_usage.map_read = true;
        if (usage & 0x02 != 0) wgpu_usage.map_write = true;
        if (usage & 0x04 != 0) wgpu_usage.copy_src = true;
        if (usage & 0x08 != 0) wgpu_usage.copy_dst = true;
        if (usage & 0x10 != 0) wgpu_usage.index = true;
        if (usage & 0x20 != 0) wgpu_usage.vertex = true;
        if (usage & 0x40 != 0) wgpu_usage.uniform = true;
        if (usage & 0x80 != 0) wgpu_usage.storage = true;

        const buffer = self.device.createBuffer(.{
            .size = size,
            .usage = wgpu_usage,
        });

        self.buffers[buffer_id] = buffer;
    }

    pub fn create_texture(self: *Self, _: Allocator, texture_id: u16, descriptor_data_id: u16) !void {
        _ = descriptor_data_id;
        assert(texture_id < MAX_TEXTURES);
        assert(self.initialized);

        // TODO: Parse descriptor from data section
        // For now, create a default texture
        const texture = self.device.createTexture(.{
            .size = .{ .width = 256, .height = 256, .depth_or_array_layers = 1 },
            .format = .rgba8_unorm,
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .mip_level_count = 1,
            .sample_count = 1,
        });

        self.textures[texture_id] = texture;
    }

    pub fn create_texture_view(self: *Self, _: Allocator, view_id: u16, texture_id: u16, _: u16) !void {
        assert(view_id < MAX_TEXTURES);
        assert(self.initialized);

        if (self.textures[texture_id]) |texture| {
            self.texture_views[view_id] = texture.createView(.{});
        }
    }

    pub fn create_sampler(self: *Self, _: Allocator, sampler_id: u16, _: u16) !void {
        assert(sampler_id < MAX_TEXTURES);
        assert(self.initialized);

        const sampler = self.device.createSampler(.{
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
            .mag_filter = .linear,
            .min_filter = .linear,
        });

        self.samplers[sampler_id] = sampler;
    }

    pub fn create_shader_module(self: *Self, _: Allocator, shader_id: u16, code_data_id: u16) !void {
        assert(shader_id < MAX_SHADERS);
        assert(self.initialized);

        // Get WGSL code from module
        const module = self.module orelse return;
        const code = module.wgsl.get(@enumFromInt(code_data_id));

        const shader = self.device.createShaderModule(.{
            .code = .{ .wgsl = code.ptr },
        });

        self.shaders[shader_id] = shader;
    }

    pub fn create_render_pipeline(self: *Self, _: Allocator, pipeline_id: u16, descriptor_data_id: u16) !void {
        _ = descriptor_data_id;
        assert(pipeline_id < MAX_PIPELINES);
        assert(self.initialized);

        // TODO: Parse full descriptor from data section
        // For now, this is a placeholder - real implementation needs vertex/fragment info
    }

    pub fn create_compute_pipeline(self: *Self, _: Allocator, pipeline_id: u16, descriptor_data_id: u16) !void {
        _ = descriptor_data_id;
        assert(pipeline_id < MAX_PIPELINES);
        assert(self.initialized);

        // TODO: Parse descriptor from data section
    }

    pub fn create_bind_group(self: *Self, _: Allocator, group_id: u16, layout_id: u16, _: u16) !void {
        _ = layout_id;
        assert(group_id < MAX_BIND_GROUPS);
        assert(self.initialized);

        // TODO: Parse entries from data section
    }

    pub fn create_bind_group_layout(self: *Self, _: Allocator, layout_id: u16, _: u16) !void {
        assert(layout_id < MAX_BIND_GROUP_LAYOUTS);
        assert(self.initialized);
        // TODO: Implement
    }

    pub fn create_pipeline_layout(self: *Self, _: Allocator, _: u16, _: u16) !void {
        assert(self.initialized);
        // TODO: Implement
    }

    pub fn create_query_set(self: *Self, _: Allocator, _: u16, _: u16) !void {
        assert(self.initialized);
        // TODO: Implement
    }

    pub fn create_image_bitmap(self: *Self, _: Allocator, _: u16, _: u16) !void {
        assert(self.initialized);
        // TODO: Implement
    }

    pub fn create_render_bundle(self: *Self, _: Allocator, _: u16, _: u16) !void {
        assert(self.initialized);
        // TODO: Implement
    }

    pub fn execute_bundles(self: *Self, _: Allocator, _: []const u16) !void {
        assert(self.in_render_pass);
        assert(self.initialized);
        // TODO: Implement
    }

    // ========================================================================
    // Pass Operations
    // ========================================================================

    pub fn begin_render_pass(self: *Self, _: Allocator, color_texture_id: u16, load_op: u8, _: u8, _: u16) !void {
        assert(!self.in_render_pass and !self.in_compute_pass);
        assert(self.initialized);

        // Get or create command encoder
        if (self.command_encoder == null) {
            self.command_encoder = self.device.createCommandEncoder(.{});
        }

        // Get render target view
        const view = if (color_texture_id == 0xFFFF)
            self.render_view
        else if (self.texture_views[color_texture_id]) |v|
            v
        else
            self.render_view;

        const load: wgpu.LoadOp = if (load_op == 1) .clear else .load;

        self.render_pass = self.command_encoder.?.beginRenderPass(.{
            .color_attachments = &[_]wgpu.RenderPassColorAttachment{.{
                .view = view,
                .load_op = load,
                .store_op = .store,
                .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
            }},
        });

        self.in_render_pass = true;
        self.current_pipeline = null;
    }

    pub fn begin_compute_pass(self: *Self, _: Allocator) !void {
        assert(!self.in_render_pass and !self.in_compute_pass);
        assert(self.initialized);

        if (self.command_encoder == null) {
            self.command_encoder = self.device.createCommandEncoder(.{});
        }

        self.compute_pass = self.command_encoder.?.beginComputePass(.{});
        self.in_compute_pass = true;
        self.current_pipeline = null;
    }

    pub fn set_pipeline(self: *Self, _: Allocator, pipeline_id: u16) !void {
        assert(self.in_render_pass or self.in_compute_pass);
        assert(self.initialized);

        if (self.in_render_pass) {
            if (self.render_pipelines[pipeline_id]) |pipeline| {
                self.render_pass.?.setPipeline(pipeline);
            }
        } else {
            if (self.compute_pipelines[pipeline_id]) |pipeline| {
                self.compute_pass.?.setPipeline(pipeline);
            }
        }
        self.current_pipeline = pipeline_id;
    }

    pub fn set_bind_group(self: *Self, _: Allocator, slot: u8, group_id: u16) !void {
        assert(self.in_render_pass or self.in_compute_pass);
        assert(self.initialized);

        if (self.bind_groups[group_id]) |group| {
            if (self.in_render_pass) {
                self.render_pass.?.setBindGroup(slot, group, null);
            } else {
                self.compute_pass.?.setBindGroup(slot, group, null);
            }
        }
    }

    pub fn set_vertex_buffer(self: *Self, _: Allocator, slot: u8, buffer_id: u16) !void {
        assert(self.in_render_pass);
        assert(self.initialized);

        if (self.buffers[buffer_id]) |buffer| {
            self.render_pass.?.setVertexBuffer(slot, buffer, 0, buffer.getSize());
        }
    }

    pub fn set_index_buffer(self: *Self, _: Allocator, buffer_id: u16, index_format: u8) !void {
        assert(self.in_render_pass);
        assert(self.initialized);

        if (self.buffers[buffer_id]) |buffer| {
            const format_enum: wgpu.IndexFormat = if (index_format == 0) .uint16 else .uint32;
            self.render_pass.?.setIndexBuffer(buffer, format_enum, 0, buffer.getSize());
        }
    }

    pub fn draw(self: *Self, _: Allocator, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) !void {
        assert(self.in_render_pass);
        assert(self.initialized);

        self.render_pass.?.draw(vertex_count, instance_count, first_vertex, first_instance);
    }

    pub fn draw_indexed(self: *Self, _: Allocator, index_count: u32, instance_count: u32, first_index: u32, base_vertex: u32, first_instance: u32) !void {
        assert(self.in_render_pass);
        assert(self.initialized);

        self.render_pass.?.drawIndexed(index_count, instance_count, first_index, @intCast(base_vertex), first_instance);
    }

    pub fn dispatch(self: *Self, _: Allocator, x: u32, y: u32, z: u32) !void {
        assert(self.in_compute_pass);
        assert(self.initialized);

        self.compute_pass.?.dispatchWorkgroups(x, y, z);
    }

    pub fn end_pass(self: *Self, _: Allocator) !void {
        assert(self.in_render_pass or self.in_compute_pass);
        assert(self.initialized);

        if (self.in_render_pass) {
            self.render_pass.?.end();
            self.render_pass = null;
        } else {
            self.compute_pass.?.end();
            self.compute_pass = null;
        }

        self.in_render_pass = false;
        self.in_compute_pass = false;
        self.current_pipeline = null;
    }

    // ========================================================================
    // Queue Operations
    // ========================================================================

    pub fn write_buffer(self: *Self, _: Allocator, buffer_id: u16, offset: u32, data_id: u16) !void {
        assert(self.initialized);

        if (self.buffers[buffer_id]) |buffer| {
            const module = self.module orelse return;
            const data = module.data.get(@enumFromInt(data_id));
            self.queue.writeBuffer(buffer, offset, data);
        }
    }

    pub fn submit(self: *Self, _: Allocator) !void {
        assert(!self.in_render_pass and !self.in_compute_pass);
        assert(self.initialized);

        if (self.command_encoder) |encoder| {
            const commands = encoder.finish(.{});
            self.queue.submit(&[_]wgpu.CommandBuffer{commands});
            self.command_encoder = null;
        }
    }

    pub fn copy_external_image_to_texture(self: *Self, _: Allocator, _: u16, _: u16, _: u8, _: u16, _: u16) !void {
        assert(self.initialized);
        // TODO: Implement
    }

    // ========================================================================
    // WASM Module Operations (stub - Dawn doesn't run WASM)
    // ========================================================================

    pub fn init_wasm_module(self: *Self, _: Allocator, _: u16, _: u16) !void {
        assert(self.initialized);
        // WASM is not supported in Dawn backend
    }

    pub fn call_wasm_func(self: *Self, _: Allocator, _: u16, _: u16, _: u16, _: []const u8) !void {
        assert(self.initialized);
        // WASM is not supported in Dawn backend
    }

    pub fn write_buffer_from_wasm(self: *Self, _: Allocator, _: u16, _: u16, _: u32, _: u32) !void {
        assert(self.initialized);
        // WASM is not supported in Dawn backend
    }

    /// Write time/canvas uniform data to GPU buffer.
    /// Runtime provides f32 values: time, canvas_width, canvas_height, aspect_ratio.
    pub fn write_time_uniform(self: *Self, _: Allocator, buffer_id: u16, buffer_offset: u32, size: u16) !void {
        assert(self.initialized);

        if (self.buffers[buffer_id]) |buffer| {
            // Pack uniform data: [time, width, height, aspect]
            const data = [4]f32{
                self.time,
                @floatFromInt(self.width),
                @floatFromInt(self.height),
                @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(self.height)),
            };

            const bytes_to_write = @min(size, 16);
            self.queue.writeBuffer(buffer, buffer_offset, std.mem.sliceAsBytes(&data)[0..bytes_to_write]);
        }
    }
};