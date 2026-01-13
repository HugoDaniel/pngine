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

    /// Current depth view (released after submit)
    current_depth_view: ?wgpu.TextureView,

    /// Bytecode module reference
    module: ?*const Module,

    /// Render target dimensions
    width: u32,
    height: u32,

    /// Texture formats (for creating depth views with correct format)
    texture_formats: [MAX_TEXTURES]c_uint,

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
            .current_depth_view = null,
            .module = null,
            .width = width,
            .height = height,
            .texture_formats = [_]c_uint{c.WGPUTextureFormat_BGRA8Unorm} ** MAX_TEXTURES,
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
        if (self.current_depth_view) |v| {
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

        const module = self.module.?;
        const data = module.data.get(DataId.fromInt(descriptor_data_id));

        // Parse texture descriptor from bytecode
        // Format: [type_tag:u8][field_count:u8][fields...]
        // Field: [fid:u8][vt:u8][value:varies]
        var tex_width: u32 = self.width;
        var tex_height: u32 = self.height;
        var tex_format: c_uint = c.WGPUTextureFormat_RGBA8Unorm;
        var tex_usage: c_uint = c.WGPUTextureUsage_RenderAttachment;
        var sample_count: u32 = 1;

        if (data.len >= 2) {
            const field_count = data[1];
            var off: usize = 2;

            for (0..field_count) |_| {
                if (off + 2 > data.len) break;
                const fid = data[off];
                const vt = data[off + 1];
                off += 2;

                if (vt == 0x00) { // u32
                    if (off + 4 > data.len) break;
                    const val = std.mem.readInt(u32, data[off..][0..4], .little);
                    off += 4;
                    switch (fid) {
                        0x01 => tex_width = val,
                        0x02 => tex_height = val,
                        0x05 => sample_count = val,
                        else => {},
                    }
                } else if (vt == 0x07) { // enum
                    if (off >= data.len) break;
                    const val = data[off];
                    off += 1;
                    switch (fid) {
                        0x07 => tex_format = decodeTextureFormat(val),
                        0x08 => tex_usage = decodeTextureUsage(val),
                        else => {},
                    }
                }
            }
        }

        // Zero-initialize to avoid undefined memory issues
        var descriptor = std.mem.zeroes(c.WGPUTextureDescriptor);
        descriptor.nextInChain = null;
        descriptor.label = .{ .data = null, .length = 0 };
        descriptor.usage = tex_usage;
        descriptor.dimension = c.WGPUTextureDimension_2D;
        descriptor.size = .{ .width = tex_width, .height = tex_height, .depthOrArrayLayers = 1 };
        descriptor.format = tex_format;
        descriptor.mipLevelCount = 1;
        descriptor.sampleCount = sample_count;
        descriptor.viewFormatCount = 0;
        descriptor.viewFormats = null;

        self.textures[texture_id] = wgpu.deviceCreateTexture(self.ctx.device, &descriptor);
        self.texture_formats[texture_id] = tex_format;
    }

    fn decodeTextureFormat(val: u8) c_uint {
        return switch (val) {
            0x00 => c.WGPUTextureFormat_RGBA8Unorm,
            0x01 => c.WGPUTextureFormat_RGBA8Snorm,
            0x04 => c.WGPUTextureFormat_BGRA8Unorm,
            0x05 => c.WGPUTextureFormat_RGBA16Float,
            0x06 => c.WGPUTextureFormat_RGBA32Float,
            0x10 => c.WGPUTextureFormat_Depth24Plus,
            0x11 => c.WGPUTextureFormat_Depth24PlusStencil8,
            0x12 => c.WGPUTextureFormat_Depth32Float,
            else => c.WGPUTextureFormat_BGRA8Unorm, // Default to preferred canvas format
        };
    }

    fn decodeTextureUsage(val: u8) c_uint {
        var usage: c_uint = 0;
        if (val & 0x01 != 0) usage |= c.WGPUTextureUsage_CopySrc;
        if (val & 0x02 != 0) usage |= c.WGPUTextureUsage_CopyDst;
        if (val & 0x04 != 0) usage |= c.WGPUTextureUsage_TextureBinding;
        if (val & 0x08 != 0) usage |= c.WGPUTextureUsage_StorageBinding;
        if (val & 0x10 != 0) usage |= c.WGPUTextureUsage_RenderAttachment;
        if (usage == 0) usage = c.WGPUTextureUsage_RenderAttachment;
        return usage;
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

    pub fn createShaderModule(self: *Self, allocator: Allocator, shader_id: u16, code_data_id: u16) !void {
        assert(shader_id < MAX_SHADERS);
        assert(self.module != null);

        const module = self.module.?;

        // Get WGSL code directly from data section
        const code = module.data.get(DataId.fromInt(code_data_id));

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

        const shader = wgpu.deviceCreateShaderModule(self.ctx.device, &descriptor);
        if (shader == null) {
            return error.ShaderCompilationFailed;
        }
        self.shaders[shader_id] = shader;
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
        assert(pipeline_id < MAX_RENDER_PIPELINES);
        assert(self.module != null);

        const module = self.module.?;
        const desc_data = module.data.get(DataId.fromInt(descriptor_data_id));

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, desc_data, .{}) catch {
            return error.InvalidResourceId;
        };
        defer parsed.deinit();

        const root = parsed.value.object;

        // Get vertex stage info
        const vertex_obj = root.get("vertex").?.object;
        const vertex_shader_id: u16 = @intCast(vertex_obj.get("shader").?.integer);
        const vertex_entry = vertex_obj.get("entryPoint").?.string;
        const vertex_shader = self.shaders[vertex_shader_id] orelse return error.InvalidResourceId;

        const vertex_entry_z = try allocator.allocSentinel(u8, vertex_entry.len, 0);
        defer allocator.free(vertex_entry_z);
        @memcpy(vertex_entry_z, vertex_entry);

        // Parse vertex buffer layouts (max 4 buffers, 8 attributes each)
        var buffer_layouts: [4]c.WGPUVertexBufferLayout = undefined;
        var attributes: [4][8]c.WGPUVertexAttribute = undefined;
        var buffer_count: usize = 0;

        if (vertex_obj.get("buffers")) |buffers_val| {
            const buffers_arr = buffers_val.array;
            for (buffers_arr.items, 0..) |buf_val, bi| {
                if (bi >= 4) break;
                const buf_obj = buf_val.object;
                const stride = buf_obj.get("arrayStride").?.integer;

                var attr_count: usize = 0;
                if (buf_obj.get("attributes")) |attrs_val| {
                    for (attrs_val.array.items, 0..) |attr_val, ai| {
                        if (ai >= 8) break;
                        const attr_obj = attr_val.object;
                        attributes[bi][ai] = .{
                            .format = parseVertexFormat(attr_obj.get("format").?.string),
                            .offset = @intCast(attr_obj.get("offset").?.integer),
                            .shaderLocation = @intCast(attr_obj.get("shaderLocation").?.integer),
                        };
                        attr_count += 1;
                    }
                }

                buffer_layouts[bi] = .{
                    .arrayStride = @intCast(stride),
                    .stepMode = c.WGPUVertexStepMode_Vertex,
                    .attributeCount = attr_count,
                    .attributes = @ptrCast(&attributes[bi]),
                };
                buffer_count += 1;
            }
        }

        // Get fragment stage info
        var fragment_state: ?c.WGPUFragmentState = null;
        var fragment_entry_z: ?[:0]u8 = null;
        var blend_state: c.WGPUBlendState = undefined;
        var color_target: c.WGPUColorTargetState = undefined;

        if (root.get("fragment")) |frag_val| {
            const frag_obj = frag_val.object;
            const frag_shader_id: u16 = @intCast(frag_obj.get("shader").?.integer);
            const frag_entry = frag_obj.get("entryPoint").?.string;
            const frag_shader = self.shaders[frag_shader_id] orelse return error.InvalidResourceId;

            fragment_entry_z = try allocator.allocSentinel(u8, frag_entry.len, 0);
            @memcpy(fragment_entry_z.?, frag_entry);

            blend_state = c.WGPUBlendState{
                .color = .{ .srcFactor = c.WGPUBlendFactor_One, .dstFactor = c.WGPUBlendFactor_Zero, .operation = c.WGPUBlendOperation_Add },
                .alpha = .{ .srcFactor = c.WGPUBlendFactor_One, .dstFactor = c.WGPUBlendFactor_Zero, .operation = c.WGPUBlendOperation_Add },
            };

            color_target = c.WGPUColorTargetState{
                .nextInChain = null,
                .format = c.WGPUTextureFormat_BGRA8Unorm,
                .blend = &blend_state,
                .writeMask = c.WGPUColorWriteMask_All,
            };

            fragment_state = c.WGPUFragmentState{
                .nextInChain = null,
                .module = frag_shader,
                .entryPoint = .{ .data = fragment_entry_z.?.ptr, .length = fragment_entry_z.?.len },
                .constantCount = 0,
                .constants = null,
                .targetCount = 1,
                .targets = &color_target,
            };
        }
        defer if (fragment_entry_z) |z| allocator.free(z);

        // Parse primitive options
        var topology: u32 = c.WGPUPrimitiveTopology_TriangleList;
        var cull_mode: u32 = c.WGPUCullMode_None;
        if (root.get("primitive")) |prim_val| {
            const prim_obj = prim_val.object;
            if (prim_obj.get("topology")) |topo_val| {
                topology = parseTopology(topo_val.string);
            }
            if (prim_obj.get("cullMode")) |cull_val| {
                cull_mode = parseCullMode(cull_val.string);
            }
        }

        // Parse depth stencil state
        var depth_stencil_state: c.WGPUDepthStencilState = undefined;
        var has_depth_stencil = false;
        if (root.get("depthStencil")) |ds_val| {
            const ds_obj = ds_val.object;
            has_depth_stencil = true;

            depth_stencil_state = std.mem.zeroes(c.WGPUDepthStencilState);
            depth_stencil_state.format = if (ds_obj.get("format")) |fmt|
                parseDepthFormat(fmt.string)
            else
                c.WGPUTextureFormat_Depth24Plus;
            depth_stencil_state.depthWriteEnabled = if (ds_obj.get("depthWriteEnabled")) |dwe|
                @intFromBool(dwe.bool)
            else
                1;
            depth_stencil_state.depthCompare = if (ds_obj.get("depthCompare")) |dc|
                parseCompareFunction(dc.string)
            else
                c.WGPUCompareFunction_Less;
            depth_stencil_state.stencilFront = .{ .compare = c.WGPUCompareFunction_Always, .failOp = c.WGPUStencilOperation_Keep, .depthFailOp = c.WGPUStencilOperation_Keep, .passOp = c.WGPUStencilOperation_Keep };
            depth_stencil_state.stencilBack = .{ .compare = c.WGPUCompareFunction_Always, .failOp = c.WGPUStencilOperation_Keep, .depthFailOp = c.WGPUStencilOperation_Keep, .passOp = c.WGPUStencilOperation_Keep };
            depth_stencil_state.stencilReadMask = 0xFFFFFFFF;
            depth_stencil_state.stencilWriteMask = 0xFFFFFFFF;
            depth_stencil_state.depthBias = 0;
            depth_stencil_state.depthBiasSlopeScale = 0;
            depth_stencil_state.depthBiasClamp = 0;
        }

        // Create pipeline descriptor
        var descriptor = std.mem.zeroes(c.WGPURenderPipelineDescriptor);
        descriptor.label = .{ .data = null, .length = 0 };
        descriptor.layout = null;
        descriptor.vertex = .{
            .nextInChain = null,
            .module = vertex_shader,
            .entryPoint = .{ .data = vertex_entry_z.ptr, .length = vertex_entry_z.len },
            .constantCount = 0,
            .constants = null,
            .bufferCount = buffer_count,
            .buffers = if (buffer_count > 0) @as([*c]const c.WGPUVertexBufferLayout, @ptrCast(&buffer_layouts)) else null,
        };
        descriptor.primitive = .{
            .nextInChain = null,
            .topology = topology,
            .stripIndexFormat = c.WGPUIndexFormat_Undefined,
            .frontFace = c.WGPUFrontFace_CCW,
            .cullMode = cull_mode,
        };
        descriptor.depthStencil = if (has_depth_stencil) &depth_stencil_state else null;
        descriptor.multisample = .{
            .nextInChain = null,
            .count = 1,
            .mask = 0xFFFFFFFF,
            .alphaToCoverageEnabled = 0,
        };
        descriptor.fragment = if (fragment_state != null) &fragment_state.? else null;

        const pipeline = wgpu.deviceCreateRenderPipeline(self.ctx.device, &descriptor);
        if (pipeline == null) {
            return error.PipelineCreationFailed;
        }
        self.render_pipelines[pipeline_id] = pipeline;
    }

    fn parseVertexFormat(fmt: []const u8) c_uint {
        if (std.mem.eql(u8, fmt, "float32")) return c.WGPUVertexFormat_Float32;
        if (std.mem.eql(u8, fmt, "float32x2")) return c.WGPUVertexFormat_Float32x2;
        if (std.mem.eql(u8, fmt, "float32x3")) return c.WGPUVertexFormat_Float32x3;
        if (std.mem.eql(u8, fmt, "float32x4")) return c.WGPUVertexFormat_Float32x4;
        if (std.mem.eql(u8, fmt, "uint32")) return c.WGPUVertexFormat_Uint32;
        if (std.mem.eql(u8, fmt, "sint32")) return c.WGPUVertexFormat_Sint32;
        return c.WGPUVertexFormat_Float32x4;
    }

    fn parseTopology(topo: []const u8) c_uint {
        if (std.mem.eql(u8, topo, "point-list")) return c.WGPUPrimitiveTopology_PointList;
        if (std.mem.eql(u8, topo, "line-list")) return c.WGPUPrimitiveTopology_LineList;
        if (std.mem.eql(u8, topo, "line-strip")) return c.WGPUPrimitiveTopology_LineStrip;
        if (std.mem.eql(u8, topo, "triangle-strip")) return c.WGPUPrimitiveTopology_TriangleStrip;
        return c.WGPUPrimitiveTopology_TriangleList;
    }

    fn parseCullMode(mode: []const u8) c_uint {
        if (std.mem.eql(u8, mode, "front")) return c.WGPUCullMode_Front;
        if (std.mem.eql(u8, mode, "back")) return c.WGPUCullMode_Back;
        return c.WGPUCullMode_None;
    }

    fn parseDepthFormat(fmt: []const u8) c_uint {
        if (std.mem.eql(u8, fmt, "depth16unorm")) return c.WGPUTextureFormat_Depth16Unorm;
        if (std.mem.eql(u8, fmt, "depth24plus")) return c.WGPUTextureFormat_Depth24Plus;
        if (std.mem.eql(u8, fmt, "depth24plus-stencil8")) return c.WGPUTextureFormat_Depth24PlusStencil8;
        if (std.mem.eql(u8, fmt, "depth32float")) return c.WGPUTextureFormat_Depth32Float;
        return c.WGPUTextureFormat_Depth24Plus;
    }

    fn parseCompareFunction(cmp: []const u8) c_uint {
        if (std.mem.eql(u8, cmp, "never")) return c.WGPUCompareFunction_Never;
        if (std.mem.eql(u8, cmp, "less")) return c.WGPUCompareFunction_Less;
        if (std.mem.eql(u8, cmp, "equal")) return c.WGPUCompareFunction_Equal;
        if (std.mem.eql(u8, cmp, "less-equal")) return c.WGPUCompareFunction_LessEqual;
        if (std.mem.eql(u8, cmp, "greater")) return c.WGPUCompareFunction_Greater;
        if (std.mem.eql(u8, cmp, "not-equal")) return c.WGPUCompareFunction_NotEqual;
        if (std.mem.eql(u8, cmp, "greater-equal")) return c.WGPUCompareFunction_GreaterEqual;
        if (std.mem.eql(u8, cmp, "always")) return c.WGPUCompareFunction_Always;
        return c.WGPUCompareFunction_Less;
    }

    pub fn createComputePipeline(self: *Self, allocator: Allocator, pipeline_id: u16, descriptor_data_id: u16) !void {
        _ = self;
        _ = allocator;
        _ = descriptor_data_id;
        assert(pipeline_id < MAX_COMPUTE_PIPELINES);

        // TODO: Parse descriptor from data section
    }

    pub fn createBindGroup(self: *Self, allocator: Allocator, group_id: u16, layout_id: u16, entry_data_id: u16) !void {
        assert(group_id < MAX_BIND_GROUPS);
        assert(self.module != null);

        const module = self.module.?;
        const data = module.data.get(DataId.fromInt(entry_data_id));

        if (data.len < 2) return;

        // Parse bind group descriptor from bytecode
        // Format: [type_tag:u8][field_count:u8][fields...]
        // Field 0x01 (group_index): [fid:u8][vt:u8][value:u8]
        // Field 0x02 (entries): [fid:u8][vt:u8][entry_count:u8][entries...]
        // Entry: [binding:u8][rt:u8][rid:u16] + optional [offset:u32][size:u32] if rt=0
        var group_index: u32 = 0;
        var off: usize = 2;
        const field_count = data[1];

        // First pass: find group_index
        for (0..field_count) |_| {
            if (off + 2 > data.len) break;
            const fid = data[off];
            const vt = data[off + 1];
            off += 2;

            if (fid == 0x01 and vt == 0x07) {
                if (off < data.len) {
                    group_index = data[off];
                    off += 1;
                }
            } else if (fid == 0x02 and vt == 0x03) {
                // Skip entries array for now, we'll parse it in second pass
                if (off >= data.len) break;
                const ec = data[off];
                off += 1;
                for (0..ec) |_| {
                    if (off + 4 > data.len) break;
                    const rt = data[off + 1];
                    off += 4; // binding, rt, rid (u16)
                    if (rt == 0) off += 8; // buffer has offset + size
                }
            }
        }

        // Get layout from pipeline
        const pipeline = self.render_pipelines[layout_id] orelse return;
        const layout = wgpu.renderPipelineGetBindGroupLayout(pipeline, group_index);
        if (layout == null) return;

        // Second pass: parse and create entries
        off = 2;
        var entries: [16]c.WGPUBindGroupEntry = undefined;
        var entry_count: usize = 0;

        for (0..field_count) |_| {
            if (off + 2 > data.len) break;
            const fid = data[off];
            const vt = data[off + 1];
            off += 2;

            if (fid == 0x01 and vt == 0x07) {
                off += 1; // Skip group_index (already parsed)
            } else if (fid == 0x02 and vt == 0x03) {
                if (off >= data.len) break;
                const ec = data[off];
                off += 1;

                for (0..ec) |_| {
                    if (off + 4 > data.len) break;
                    if (entry_count >= 16) break;

                    const binding = data[off];
                    const rt = data[off + 1];
                    const rid = std.mem.readInt(u16, data[off + 2 ..][0..2], .little);
                    off += 4;

                    var entry = std.mem.zeroes(c.WGPUBindGroupEntry);
                    entry.binding = binding;
                    entry.buffer = null;
                    entry.textureView = null;
                    entry.sampler = null;

                    if (rt == 0) {
                        // Buffer binding
                        if (off + 8 > data.len) break;
                        const buf_offset = std.mem.readInt(u32, data[off..][0..4], .little);
                        const buf_size = std.mem.readInt(u32, data[off + 4 ..][0..4], .little);
                        off += 8;

                        if (rid < MAX_BUFFERS) {
                            if (self.buffers[rid]) |buffer| {
                                entry.buffer = buffer;
                                entry.offset = buf_offset;
                                entry.size = if (buf_size == 0) wgpu.bufferGetSize(buffer) else buf_size;
                            }
                        }
                    } else if (rt == 1) {
                        // Texture binding - reuse or create view
                        if (rid < MAX_TEXTURE_VIEWS) {
                            if (self.texture_views[rid]) |existing_view| {
                                // Reuse existing view
                                entry.textureView = existing_view;
                            } else if (self.textures[rid]) |texture| {
                                // Create view and store for reuse
                                var view_desc = std.mem.zeroes(c.WGPUTextureViewDescriptor);
                                view_desc.format = self.texture_formats[rid];
                                view_desc.dimension = c.WGPUTextureViewDimension_2D;
                                view_desc.baseMipLevel = 0;
                                view_desc.mipLevelCount = 1;
                                view_desc.baseArrayLayer = 0;
                                view_desc.arrayLayerCount = 1;
                                view_desc.aspect = c.WGPUTextureAspect_All;
                                const new_view = wgpu.textureCreateView(texture, &view_desc);
                                self.texture_views[rid] = new_view;
                                entry.textureView = new_view;
                            }
                        }
                    } else if (rt == 2) {
                        // Sampler binding
                        if (rid < MAX_SAMPLERS) {
                            if (self.samplers[rid]) |sampler| {
                                entry.sampler = sampler;
                            }
                        }
                    }

                    entries[entry_count] = entry;
                    entry_count += 1;
                }
            }
        }

        if (entry_count == 0) return;

        // Create bind group
        var desc = std.mem.zeroes(c.WGPUBindGroupDescriptor);
        desc.layout = layout;
        desc.entryCount = entry_count;
        desc.entries = &entries;

        self.bind_groups[group_id] = wgpu.deviceCreateBindGroup(self.ctx.device, &desc);
        _ = allocator; // Interface requirement - native backend doesn't need allocator
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

        // Get color target view
        var view: wgpu.TextureView = null;

        // 0xFFFE (65534) = render to surface/screen
        if (color_texture_id == 0xFFFE) {
            if (self.surface) |surface| {
                var surface_texture: wgpu.SurfaceTexture = undefined;
                wgpu.surfaceGetCurrentTexture(surface, &surface_texture);

                const status = surface_texture.status;
                if (status != c.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal and
                    status != c.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal)
                {
                    return error.SurfaceTextureUnavailable;
                }

                if (surface_texture.texture != null) {
                    view = wgpu.textureCreateView(surface_texture.texture, null);
                    if (view == null) {
                        return error.SurfaceTextureUnavailable;
                    }
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
                if (view == null) {
                    return error.TextureNotFound;
                }
            } else {
                return error.TextureNotFound;
            }
        }

        const valid_view = view orelse return error.SurfaceTextureUnavailable;

        // Create command encoder
        self.encoder = wgpu.deviceCreateCommandEncoder(self.ctx.device, null);
        const encoder = self.encoder orelse return error.SurfaceTextureUnavailable;

        // Map bytecode load/store ops to wgpu-native values
        const wgpu_load_op: c_uint = if (load_op == 0) c.WGPULoadOp_Load else c.WGPULoadOp_Clear;
        const wgpu_store_op: c_uint = if (store_op == 0) c.WGPUStoreOp_Store else c.WGPUStoreOp_Discard;

        // Color attachment
        var color_attachment = std.mem.zeroes(c.WGPURenderPassColorAttachment);
        color_attachment.view = valid_view;
        color_attachment.depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED;
        color_attachment.loadOp = wgpu_load_op;
        color_attachment.storeOp = wgpu_store_op;
        color_attachment.clearValue = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };

        // Depth stencil attachment (if depth texture provided)
        var depth_attachment: c.WGPURenderPassDepthStencilAttachment = undefined;
        var has_depth = false;

        if (depth_texture_id != 0xFFFF and depth_texture_id < MAX_TEXTURES) {
            if (self.textures[depth_texture_id]) |depth_tex| {
                // Release previous depth view if any
                if (self.current_depth_view) |old_view| {
                    wgpu.textureViewRelease(old_view);
                    self.current_depth_view = null;
                }

                // Create view for depth texture with correct aspect
                var depth_view_desc = std.mem.zeroes(c.WGPUTextureViewDescriptor);
                depth_view_desc.format = self.texture_formats[depth_texture_id];
                depth_view_desc.dimension = c.WGPUTextureViewDimension_2D;
                depth_view_desc.aspect = c.WGPUTextureAspect_DepthOnly;
                depth_view_desc.baseMipLevel = 0;
                depth_view_desc.mipLevelCount = 1;
                depth_view_desc.baseArrayLayer = 0;
                depth_view_desc.arrayLayerCount = 1;

                const depth_view = wgpu.textureCreateView(depth_tex, &depth_view_desc);
                if (depth_view != null) {
                    self.current_depth_view = depth_view; // Track for release in submit()
                    has_depth = true;
                    depth_attachment = std.mem.zeroes(c.WGPURenderPassDepthStencilAttachment);
                    depth_attachment.view = depth_view;
                    depth_attachment.depthLoadOp = c.WGPULoadOp_Clear;
                    depth_attachment.depthStoreOp = c.WGPUStoreOp_Store;
                    depth_attachment.depthClearValue = 1.0;
                    depth_attachment.stencilLoadOp = c.WGPULoadOp_Undefined;
                    depth_attachment.stencilStoreOp = c.WGPUStoreOp_Undefined;
                    depth_attachment.stencilClearValue = 0;
                    depth_attachment.stencilReadOnly = 0;
                    depth_attachment.depthReadOnly = 0;
                }
            }
        }

        var render_pass_desc = std.mem.zeroes(c.WGPURenderPassDescriptor);
        render_pass_desc.label = .{ .data = null, .length = 0 };
        render_pass_desc.colorAttachmentCount = 1;
        render_pass_desc.colorAttachments = &color_attachment;
        render_pass_desc.depthStencilAttachment = if (has_depth) &depth_attachment else null;

        self.render_pass = wgpu.commandEncoderBeginRenderPass(encoder, &render_pass_desc);
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

        // Release depth view
        if (self.current_depth_view) |view| {
            wgpu.textureViewRelease(view);
            self.current_depth_view = null;
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
