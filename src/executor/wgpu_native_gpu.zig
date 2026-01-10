//! WgpuNative GPU Backend
//!
//! Native GPU backend using wgpu-native C API.
//! Works on iOS (Metal), Android (Vulkan), macOS, Windows, Linux.
//!
//! ## Architecture
//!
//! This backend implements the same interface as WasmGPU but calls
//! wgpu-native's C API directly via @cImport instead of JS externs.
//!
//! ## Invariants
//!
//! - Context must be initialized before creating WgpuNativeGPU instances
//! - Module must be set before any GPU calls that reference data IDs
//! - Resource IDs map to internal wgpu handles
//! - All resource arrays use static allocation (no runtime malloc)

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const wgpu = @import("../gpu/wgpu_c.zig");
const c = wgpu.c;

// Use bytecode module import
const bytecode_mod = @import("bytecode");
const format = bytecode_mod.format;
const Module = format.Module;
const DataSection = bytecode_mod.DataSection;
const DataId = bytecode_mod.DataId;

// ============================================================================
// Shared GPU Context
// ============================================================================

/// Shared GPU context - one instance per application.
/// Manages wgpu instance, adapter, device, and queue.
pub const Context = struct {
    const Self = @This();

    instance: wgpu.Instance,
    adapter: wgpu.Adapter,
    device: wgpu.Device,
    queue: wgpu.Queue,
    initialized: bool,

    /// Initialize the GPU context.
    /// This should be called once at application startup.
    pub fn init() !Self {
        // Create wgpu instance
        const instance = wgpu.createInstance(null);
        if (instance == null) {
            return error.InstanceCreationFailed;
        }

        // Request adapter (synchronous)
        const adapter_result = wgpu.requestAdapterSync(instance, null);
        if (adapter_result.adapter == null) {
            wgpu.instanceRelease(instance);
            return error.AdapterRequestFailed;
        }
        const adapter = adapter_result.adapter.?;

        // Request device (synchronous) - v27+ API requires instance for wait
        const device_result = wgpu.requestDeviceSync(instance, adapter, null);
        if (device_result.device == null) {
            wgpu.adapterRelease(adapter);
            wgpu.instanceRelease(instance);
            return error.DeviceRequestFailed;
        }
        const device = device_result.device.?;

        // Get queue
        const queue = wgpu.deviceGetQueue(device);

        return Self{
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            .initialized = true,
        };
    }

    /// Release all GPU resources.
    pub fn deinit(self: *Self) void {
        assert(self.initialized);

        wgpu.deviceRelease(self.device);
        wgpu.adapterRelease(self.adapter);
        wgpu.instanceRelease(self.instance);

        self.* = undefined;
    }
};

// ============================================================================
// WgpuNativeGPU Backend
// ============================================================================

/// Native GPU backend for wgpu-native.
/// Implements the same interface as WasmGPU/MockGPU.
pub const WgpuNativeGPU = struct {
    const Self = @This();

    /// Maximum resources per category.
    pub const MAX_BUFFERS: u16 = 256;
    pub const MAX_TEXTURES: u16 = 256;
    pub const MAX_TEXTURE_VIEWS: u16 = 256;
    pub const MAX_SAMPLERS: u16 = 64;
    pub const MAX_SHADERS: u16 = 64;
    pub const MAX_RENDER_PIPELINES: u16 = 64;
    pub const MAX_COMPUTE_PIPELINES: u16 = 64;
    pub const MAX_BIND_GROUPS: u16 = 128;
    pub const MAX_BIND_GROUP_LAYOUTS: u16 = 64;
    pub const MAX_PIPELINE_LAYOUTS: u16 = 64;

    /// Shared context reference
    ctx: *Context,

    /// Surface for rendering (optional - null for headless)
    surface: ?wgpu.Surface,

    /// Current surface texture view (for render passes targeting surface)
    current_surface_view: ?wgpu.TextureView,

    /// Resource arrays (static allocation)
    buffers: [MAX_BUFFERS]?wgpu.Buffer,
    textures: [MAX_TEXTURES]?wgpu.Texture,
    texture_views: [MAX_TEXTURE_VIEWS]?wgpu.TextureView,
    samplers: [MAX_SAMPLERS]?wgpu.Sampler,
    shaders: [MAX_SHADERS]?wgpu.ShaderModule,
    render_pipelines: [MAX_RENDER_PIPELINES]?wgpu.RenderPipeline,
    compute_pipelines: [MAX_COMPUTE_PIPELINES]?wgpu.ComputePipeline,
    bind_groups: [MAX_BIND_GROUPS]?wgpu.BindGroup,
    bind_group_layouts: [MAX_BIND_GROUP_LAYOUTS]?wgpu.BindGroupLayout,
    pipeline_layouts: [MAX_PIPELINE_LAYOUTS]?wgpu.PipelineLayout,

    /// Current encoder state
    encoder: ?wgpu.CommandEncoder,
    render_pass: ?wgpu.RenderPassEncoder,
    compute_pass: ?wgpu.ComputePassEncoder,

    /// Bytecode module reference
    module: ?*const Module,

    /// Render target dimensions
    width: u32,
    height: u32,

    /// Time uniform for animations
    time: f32,

    /// Create a new WgpuNativeGPU instance.
    pub fn init(ctx: *Context, surface: ?wgpu.Surface, width: u32, height: u32) Self {
        assert(ctx.initialized);
        assert(width > 0 and height > 0);

        const self = Self{
            .ctx = ctx,
            .surface = surface,
            .current_surface_view = null,
            .buffers = [_]?wgpu.Buffer{null} ** MAX_BUFFERS,
            .textures = [_]?wgpu.Texture{null} ** MAX_TEXTURES,
            .texture_views = [_]?wgpu.TextureView{null} ** MAX_TEXTURE_VIEWS,
            .samplers = [_]?wgpu.Sampler{null} ** MAX_SAMPLERS,
            .shaders = [_]?wgpu.ShaderModule{null} ** MAX_SHADERS,
            .render_pipelines = [_]?wgpu.RenderPipeline{null} ** MAX_RENDER_PIPELINES,
            .compute_pipelines = [_]?wgpu.ComputePipeline{null} ** MAX_COMPUTE_PIPELINES,
            .bind_groups = [_]?wgpu.BindGroup{null} ** MAX_BIND_GROUPS,
            .bind_group_layouts = [_]?wgpu.BindGroupLayout{null} ** MAX_BIND_GROUP_LAYOUTS,
            .pipeline_layouts = [_]?wgpu.PipelineLayout{null} ** MAX_PIPELINE_LAYOUTS,
            .encoder = null,
            .render_pass = null,
            .compute_pass = null,
            .module = null,
            .width = width,
            .height = height,
            .time = 0.0,
        };

        // Configure surface if provided
        if (surface) |s| {
            const config = c.WGPUSurfaceConfiguration{
                .device = ctx.device,
                .format = c.WGPUTextureFormat_BGRA8Unorm,
                .usage = c.WGPUTextureUsage_RenderAttachment,
                .width = width,
                .height = height,
                .presentMode = c.WGPUPresentMode_Fifo,
                .alphaMode = c.WGPUCompositeAlphaMode_Auto,
                .viewFormatCount = 0,
                .viewFormats = null,
                .nextInChain = null,
            };
            wgpu.surfaceConfigure(s, &config);
        }

        return self;
    }

    /// Release all resources.
    pub fn deinit(self: *Self) void {
        // Release all created resources
        for (&self.buffers) |*buf| {
            if (buf.*) |b| wgpu.bufferRelease(b);
            buf.* = null;
        }
        for (&self.textures) |*tex| {
            if (tex.*) |t| wgpu.textureRelease(t);
            tex.* = null;
        }
        for (&self.texture_views) |*view| {
            if (view.*) |v| wgpu.textureViewRelease(v);
            view.* = null;
        }
        for (&self.samplers) |*samp| {
            if (samp.*) |s| wgpu.samplerRelease(s);
            samp.* = null;
        }
        for (&self.shaders) |*shader| {
            if (shader.*) |s| wgpu.shaderModuleRelease(s);
            shader.* = null;
        }
        for (&self.render_pipelines) |*pipeline| {
            if (pipeline.*) |p| wgpu.renderPipelineRelease(p);
            pipeline.* = null;
        }
        for (&self.compute_pipelines) |*pipeline| {
            if (pipeline.*) |p| wgpu.computePipelineRelease(p);
            pipeline.* = null;
        }
        for (&self.bind_groups) |*group| {
            if (group.*) |g| wgpu.bindGroupRelease(g);
            group.* = null;
        }
        for (&self.bind_group_layouts) |*layout| {
            if (layout.*) |l| wgpu.bindGroupLayoutRelease(l);
            layout.* = null;
        }
        for (&self.pipeline_layouts) |*layout| {
            if (layout.*) |l| wgpu.pipelineLayoutRelease(l);
            layout.* = null;
        }

        if (self.current_surface_view) |v| {
            wgpu.textureViewRelease(v);
        }

        self.* = undefined;
    }

    /// Set the module for data lookups.
    pub fn setModule(self: *Self, module: *const Module) void {
        self.module = module;
    }

    /// Set time uniform for animations.
    pub fn setTime(self: *Self, time_value: f32) void {
        assert(!std.math.isNan(time_value));
        self.time = time_value;
    }

    // ========================================================================
    // Resource Creation
    // ========================================================================

    pub fn createBuffer(self: *Self, allocator: Allocator, buffer_id: u16, size: u32, usage: u8) !void {
        _ = allocator;
        assert(buffer_id < MAX_BUFFERS);

        const descriptor = c.WGPUBufferDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },
            .size = size,
            .usage = wgpu.mapBufferUsage(usage),
            .mappedAtCreation = @intFromBool(false),
        };

        self.buffers[buffer_id] = wgpu.deviceCreateBuffer(self.ctx.device, &descriptor);
    }

    pub fn createTexture(self: *Self, allocator: Allocator, texture_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        assert(texture_id < MAX_TEXTURES);
        assert(self.module != null);

        // For now, create a default RGBA texture
        // TODO: Parse descriptor from data section
        _ = descriptor_data_id;

        const descriptor = c.WGPUTextureDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },
            .usage = c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst,
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = 256, .height = 256, .depthOrArrayLayers = 1 },
            .format = c.WGPUTextureFormat_RGBA8Unorm,
            .mipLevelCount = 1,
            .sampleCount = 1,
            .viewFormatCount = 0,
            .viewFormats = null,
        };

        self.textures[texture_id] = wgpu.deviceCreateTexture(self.ctx.device, &descriptor);
    }

    pub fn createTextureView(self: *Self, allocator: Allocator, view_id: u16, texture_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        _ = descriptor_data_id;
        assert(view_id < MAX_TEXTURE_VIEWS);
        assert(texture_id < MAX_TEXTURES);

        if (self.textures[texture_id]) |texture| {
            self.texture_views[view_id] = wgpu.textureCreateView(texture, null);
        }
    }

    pub fn createSampler(self: *Self, allocator: Allocator, sampler_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        _ = descriptor_data_id;
        assert(sampler_id < MAX_SAMPLERS);

        // Default sampler
        const descriptor = c.WGPUSamplerDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },
            .addressModeU = c.WGPUAddressMode_ClampToEdge,
            .addressModeV = c.WGPUAddressMode_ClampToEdge,
            .addressModeW = c.WGPUAddressMode_ClampToEdge,
            .magFilter = c.WGPUFilterMode_Linear,
            .minFilter = c.WGPUFilterMode_Linear,
            .mipmapFilter = c.WGPUMipmapFilterMode_Linear,
            .lodMinClamp = 0.0,
            .lodMaxClamp = 32.0,
            .compare = c.WGPUCompareFunction_Undefined,
            .maxAnisotropy = 1,
        };

        self.samplers[sampler_id] = wgpu.deviceCreateSampler(self.ctx.device, &descriptor);
    }

    pub fn createShaderModule(self: *Self, allocator: Allocator, shader_id: u16, wgsl_id: u16) !void {
        assert(shader_id < MAX_SHADERS);
        assert(self.module != null);

        // Resolve WGSL code from module
        const code = try self.resolveWgsl(allocator, wgsl_id);
        defer allocator.free(code);

        // Create null-terminated string for wgpu
        const code_z = try allocator.allocSentinel(u8, code.len, 0);
        defer allocator.free(code_z);
        @memcpy(code_z, code);

        const wgsl_desc = c.WGPUShaderSourceWGSL{
            .chain = .{
                .next = null,
                .sType = c.WGPUSType_ShaderSourceWGSL,
            },
            .code = c.WGPUStringView{
                .data = code_z.ptr,
                .length = code_z.len,
            },
        };

        const descriptor = c.WGPUShaderModuleDescriptor{
            .nextInChain = @ptrCast(&wgsl_desc),
            .label = .{ .data = null, .length = 0 },
        };

        self.shaders[shader_id] = wgpu.deviceCreateShaderModule(self.ctx.device, &descriptor);
    }

    /// Resolve WGSL module by ID, concatenating all dependencies.
    fn resolveWgsl(self: *Self, allocator: Allocator, wgsl_id: u16) ![]u8 {
        const module = self.module orelse return error.ModuleNotSet;
        const wgsl_table = &module.wgsl;

        const max_iterations: u32 = @as(u32, format.MAX_WGSL_MODULES) * @as(u32, format.MAX_WGSL_DEPS);

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

            if (included.contains(current)) continue;
            try included.put(allocator, current, {});

            const entry = wgsl_table.get(current) orelse continue;

            // Push dependencies (will be processed first due to stack)
            for (entry.deps) |dep| {
                if (dep == 0xFFFF) break;
                if (!included.contains(dep)) {
                    try stack.append(allocator, dep);
                }
            }

            try order.append(allocator, current);
        }

        // Concatenate code in order
        var total_len: usize = 0;
        for (order.items) |id| {
            if (wgsl_table.get(id)) |entry| {
                const data = module.data.get(DataId.fromInt(entry.data_id));
                total_len += data.len + 1; // +1 for newline
            }
        }

        const result = try allocator.alloc(u8, total_len);
        var offset: usize = 0;

        for (order.items) |id| {
            if (wgsl_table.get(id)) |entry| {
                const data = module.data.get(DataId.fromInt(entry.data_id));
                @memcpy(result[offset .. offset + data.len], data);
                offset += data.len;
                result[offset] = '\n';
                offset += 1;
            }
        }

        return result;
    }

    pub fn createRenderPipeline(self: *Self, allocator: Allocator, pipeline_id: u16, descriptor_data_id: u16) !void {
        _ = self;
        _ = allocator;
        _ = descriptor_data_id;
        assert(pipeline_id < MAX_RENDER_PIPELINES);

        // TODO: Parse descriptor from data section
        // For now, this is a placeholder
    }

    pub fn createComputePipeline(self: *Self, allocator: Allocator, pipeline_id: u16, descriptor_data_id: u16) !void {
        _ = self;
        _ = allocator;
        _ = descriptor_data_id;
        assert(pipeline_id < MAX_COMPUTE_PIPELINES);

        // TODO: Parse descriptor from data section
    }

    pub fn createBindGroup(self: *Self, allocator: Allocator, group_id: u16, layout_id: u16, entry_data_id: u16) !void {
        _ = self;
        _ = allocator;
        _ = layout_id;
        _ = entry_data_id;
        assert(group_id < MAX_BIND_GROUPS);

        // TODO: Parse entries from data section
    }

    pub fn createBindGroupLayout(self: *Self, allocator: Allocator, layout_id: u16, descriptor_data_id: u16) !void {
        _ = self;
        _ = allocator;
        _ = descriptor_data_id;
        assert(layout_id < MAX_BIND_GROUP_LAYOUTS);

        // TODO: Parse descriptor from data section
    }

    pub fn createPipelineLayout(self: *Self, allocator: Allocator, layout_id: u16, descriptor_data_id: u16) !void {
        _ = self;
        _ = allocator;
        _ = descriptor_data_id;
        assert(layout_id < MAX_PIPELINE_LAYOUTS);

        // TODO: Parse descriptor from data section
    }

    pub fn createQuerySet(self: *Self, allocator: Allocator, query_set_id: u16, descriptor_data_id: u16) !void {
        _ = self;
        _ = allocator;
        _ = query_set_id;
        _ = descriptor_data_id;

        // TODO: Implement query sets
    }

    pub fn createImageBitmap(self: *Self, allocator: Allocator, bitmap_id: u16, blob_data_id: u16) !void {
        _ = self;
        _ = allocator;
        _ = bitmap_id;
        _ = blob_data_id;

        // TODO: Implement image loading
    }

    pub fn createRenderBundle(self: *Self, allocator: Allocator, bundle_id: u16, descriptor_data_id: u16) !void {
        _ = self;
        _ = allocator;
        _ = bundle_id;
        _ = descriptor_data_id;

        // TODO: Implement render bundles
    }

    pub fn executeBundles(self: *Self, allocator: Allocator, bundle_ids: []const u16) !void {
        _ = self;
        _ = allocator;
        _ = bundle_ids;

        // TODO: Implement bundle execution
    }

    // ========================================================================
    // Pass Operations
    // ========================================================================

    pub fn beginRenderPass(self: *Self, allocator: Allocator, color_texture_id: u16, load_op: u8, store_op: u8, depth_texture_id: u16) !void {
        _ = allocator;
        _ = depth_texture_id;

        // Get target view
        var view: wgpu.TextureView = undefined;

        if (color_texture_id == 0) {
            // Render to surface
            if (self.surface) |surface| {
                var surface_texture: wgpu.SurfaceTexture = undefined;
                wgpu.surfaceGetCurrentTexture(surface, &surface_texture);

                if (surface_texture.texture != null) {
                    view = wgpu.textureCreateView(surface_texture.texture, null);
                    self.current_surface_view = view;
                } else {
                    return error.SurfaceTextureUnavailable;
                }
            } else {
                return error.NoSurfaceConfigured;
            }
        } else {
            // Render to custom texture
            if (self.texture_views[color_texture_id]) |v| {
                view = v;
            } else if (self.textures[color_texture_id]) |t| {
                view = wgpu.textureCreateView(t, null);
            } else {
                return error.TextureNotFound;
            }
        }

        // Create command encoder
        self.encoder = wgpu.deviceCreateCommandEncoder(self.ctx.device, null);

        // Begin render pass
        const color_attachment = c.WGPURenderPassColorAttachment{
            .view = view,
            .depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED,
            .resolveTarget = null,
            .loadOp = @intFromEnum(wgpu.mapLoadOp(load_op)),
            .storeOp = @intFromEnum(wgpu.mapStoreOp(store_op)),
            .clearValue = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
        };

        const render_pass_desc = c.WGPURenderPassDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },
            .colorAttachmentCount = 1,
            .colorAttachments = &color_attachment,
            .depthStencilAttachment = null,
            .occlusionQuerySet = null,
            .timestampWrites = null,
        };

        self.render_pass = wgpu.commandEncoderBeginRenderPass(self.encoder.?, &render_pass_desc);
    }

    pub fn beginComputePass(self: *Self, allocator: Allocator) !void {
        _ = allocator;

        self.encoder = wgpu.deviceCreateCommandEncoder(self.ctx.device, null);
        self.compute_pass = wgpu.commandEncoderBeginComputePass(self.encoder.?, null);
    }

    pub fn setPipeline(self: *Self, allocator: Allocator, pipeline_id: u16) !void {
        _ = allocator;

        if (self.render_pass) |pass| {
            if (self.render_pipelines[pipeline_id]) |pipeline| {
                wgpu.renderPassEncoderSetPipeline(pass, pipeline);
            }
        } else if (self.compute_pass) |pass| {
            if (self.compute_pipelines[pipeline_id]) |pipeline| {
                wgpu.computePassEncoderSetPipeline(pass, pipeline);
            }
        }
    }

    pub fn setBindGroup(self: *Self, allocator: Allocator, slot: u8, group_id: u16) !void {
        _ = allocator;

        if (self.bind_groups[group_id]) |group| {
            if (self.render_pass) |pass| {
                wgpu.renderPassEncoderSetBindGroup(pass, slot, group, &[_]u32{});
            } else if (self.compute_pass) |pass| {
                wgpu.computePassEncoderSetBindGroup(pass, slot, group, &[_]u32{});
            }
        }
    }

    pub fn setVertexBuffer(self: *Self, allocator: Allocator, slot: u8, buffer_id: u16) !void {
        _ = allocator;

        if (self.render_pass) |pass| {
            if (self.buffers[buffer_id]) |buffer| {
                const size = wgpu.bufferGetSize(buffer);
                wgpu.renderPassEncoderSetVertexBuffer(pass, slot, buffer, 0, size);
            }
        }
    }

    pub fn setIndexBuffer(self: *Self, allocator: Allocator, buffer_id: u16, index_format: u8) !void {
        _ = allocator;

        if (self.render_pass) |pass| {
            if (self.buffers[buffer_id]) |buffer| {
                const format_enum: c.WGPUIndexFormat = if (index_format == 0)
                    c.WGPUIndexFormat_Uint16
                else
                    c.WGPUIndexFormat_Uint32;
                const size = wgpu.bufferGetSize(buffer);
                wgpu.renderPassEncoderSetIndexBuffer(pass, buffer, format_enum, 0, size);
            }
        }
    }

    pub fn draw(self: *Self, allocator: Allocator, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) !void {
        _ = allocator;

        if (self.render_pass) |pass| {
            wgpu.renderPassEncoderDraw(pass, vertex_count, instance_count, first_vertex, first_instance);
        }
    }

    pub fn drawIndexed(self: *Self, allocator: Allocator, index_count: u32, instance_count: u32, first_index: u32, base_vertex: u32, first_instance: u32) !void {
        _ = allocator;

        if (self.render_pass) |pass| {
            wgpu.renderPassEncoderDrawIndexed(pass, index_count, instance_count, first_index, @intCast(base_vertex), first_instance);
        }
    }

    pub fn dispatch(self: *Self, allocator: Allocator, x: u32, y: u32, z: u32) !void {
        _ = allocator;

        if (self.compute_pass) |pass| {
            wgpu.computePassEncoderDispatchWorkgroups(pass, x, y, z);
        }
    }

    pub fn endPass(self: *Self, allocator: Allocator) !void {
        _ = allocator;

        if (self.render_pass) |pass| {
            wgpu.renderPassEncoderEnd(pass);
            wgpu.renderPassEncoderRelease(pass);
            self.render_pass = null;
        }
        if (self.compute_pass) |pass| {
            wgpu.computePassEncoderEnd(pass);
            wgpu.computePassEncoderRelease(pass);
            self.compute_pass = null;
        }
    }

    // ========================================================================
    // Queue Operations
    // ========================================================================

    pub fn writeBuffer(self: *Self, allocator: Allocator, buffer_id: u16, offset: u32, data_id: u16) !void {
        _ = allocator;

        if (self.buffers[buffer_id]) |buffer| {
            if (self.module) |module| {
                const data = module.data.get(DataId.fromInt(data_id));
                wgpu.queueWriteBuffer(self.ctx.queue, buffer, offset, data);
            }
        }
    }

    pub fn submit(self: *Self, allocator: Allocator) !void {
        _ = allocator;

        if (self.encoder) |encoder| {
            const cmd = wgpu.commandEncoderFinish(encoder, null);
            wgpu.queueSubmit(self.ctx.queue, &[_]wgpu.CommandBuffer{cmd});
            wgpu.commandBufferRelease(cmd);
            wgpu.commandEncoderRelease(encoder);
            self.encoder = null;
        }

        // Present surface if we rendered to it
        if (self.surface) |surface| {
            wgpu.surfacePresent(surface);
        }

        // Release surface view
        if (self.current_surface_view) |view| {
            wgpu.textureViewRelease(view);
            self.current_surface_view = null;
        }
    }

    pub fn copyExternalImageToTexture(self: *Self, allocator: Allocator, bitmap_id: u16, texture_id: u16, mip_level: u8, origin_x: u16, origin_y: u16) !void {
        _ = self;
        _ = allocator;
        _ = bitmap_id;
        _ = texture_id;
        _ = mip_level;
        _ = origin_x;
        _ = origin_y;

        // TODO: Implement external image copy
    }

    // ========================================================================
    // WASM Module Operations (no-op for native)
    // ========================================================================

    pub fn initWasmModule(self: *Self, allocator: Allocator, module_id: u16, wasm_data_id: u16) !void {
        _ = self;
        _ = allocator;
        _ = module_id;
        _ = wasm_data_id;
        // No-op for native - WASM calls are browser-only
    }

    pub fn callWasmFunc(self: *Self, allocator: Allocator, call_id: u16, module_id: u16, func_name_id: u16, args: []const u8) !void {
        _ = self;
        _ = allocator;
        _ = call_id;
        _ = module_id;
        _ = func_name_id;
        _ = args;
        // No-op for native
    }

    pub fn writeBufferFromWasm(self: *Self, allocator: Allocator, call_id: u16, buffer_id: u16, offset: u32, byte_len: u32) !void {
        _ = self;
        _ = allocator;
        _ = call_id;
        _ = buffer_id;
        _ = offset;
        _ = byte_len;
        // No-op for native
    }

    pub fn writeTimeUniform(self: *Self, allocator: Allocator, buffer_id: u16, buffer_offset: u32, size: u16) !void {
        _ = allocator;

        if (self.buffers[buffer_id]) |buffer| {
            // Write time + canvas dimensions
            var data: [16]u8 = undefined;
            const time_bytes = std.mem.asBytes(&self.time);
            const width_f: f32 = @floatFromInt(self.width);
            const height_f: f32 = @floatFromInt(self.height);
            const aspect: f32 = width_f / height_f;

            @memcpy(data[0..4], time_bytes);
            @memcpy(data[4..8], std.mem.asBytes(&width_f));
            @memcpy(data[8..12], std.mem.asBytes(&height_f));
            @memcpy(data[12..16], std.mem.asBytes(&aspect));

            const write_size = @min(size, 16);
            wgpu.queueWriteBuffer(self.ctx.queue, buffer, buffer_offset, data[0..write_size]);
        }
    }
};

// ============================================================================
// Dispatcher Type Alias
// ============================================================================

const dispatcher_mod = @import("dispatcher.zig");
pub const NativeDispatcher = dispatcher_mod.Dispatcher(WgpuNativeGPU);
