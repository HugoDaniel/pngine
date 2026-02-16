//! WgpuNative GPU Backend
//!
//! Native GPU backend using wgpu-native C API for cross-platform WebGPU support.
//! Works on iOS (Metal), Android (Vulkan), macOS, Windows, and Linux.
//!
//! ## Architecture
//!
//! This backend implements the GPU interface using wgpu-native's C API directly
//! via @cImport instead of JavaScript extern functions. It follows the same
//! command-based pattern as the WASM backend but executes GPU commands natively.
//!
//! ```
//! ┌─────────────────────────────────────────────────────────────────┐
//! │                     Context (Shared)                            │
//! │  - Instance: wgpu instance                                      │
//! │  - Adapter: Physical GPU handle                                 │
//! │  - Device: Logical GPU handle                                   │
//! │  - Queue: Command submission queue                              │
//! └─────────────────────────────────────────────────────────────────┘
//!                              │
//!               ┌──────────────┴──────────────┐
//!               ▼                              ▼
//! ┌─────────────────────────┐    ┌─────────────────────────┐
//! │   WgpuNativeGPU #1      │    │   WgpuNativeGPU #2      │
//! │   (Animation Instance)  │    │   (Animation Instance)  │
//! │   - Surface             │    │   - Surface             │
//! │   - Resources           │    │   - Resources           │
//! │   - Pipelines           │    │   - Pipelines           │
//! └─────────────────────────┘    └─────────────────────────┘
//! ```
//!
//! ## Design Decisions
//!
//! - **Static allocation**: All resource arrays are fixed-size (MAX_*) to avoid
//!   runtime allocation. This ensures predictable memory usage and no GC pressure.
//! - **Resource IDs**: External IDs are array indices for O(1) lookup. The bytecode
//!   uses u16 IDs which map directly to array slots.
//! - **Thread-safe context**: Adapter and device request use atomic synchronization
//!   for thread-safe lazy initialization.
//! - **Helper functions**: Complex parsing logic is extracted into pure helper
//!   functions that return result structs (Zig Mastery compliance: ≤70 lines).
//!
//! ## Invariants
//!
//! - Context must be initialized before creating WgpuNativeGPU instances
//! - Module must be set before any GPU calls that reference data IDs
//! - Resource IDs are valid array indices (< MAX_* constants)
//! - All handles are either valid GPU objects or null (never dangling)
//! - Only one pass (render XOR compute) can be active at a time
//! - All resource arrays use static allocation (no malloc after init)
//!
//! ## Bounded Iteration (Zig Mastery Compliance)
//!
//! All loops use bounded iteration with `for (0..MAX_X)` and `else` fallback:
//! - MAX_JSON_TOKENS (2048): JSON descriptor parsing
//! - MAX_BYTECODE_FIELDS (256): Bytecode field iteration
//! - MAX_WGSL_ITERATIONS (1024): WGSL dependency resolution
//!
//! ## Usage
//!
//! ```zig
//! const gpu = @import("wgpu_native_gpu.zig");
//!
//! // Initialize shared context (once per application)
//! var ctx = try gpu.Context.init();
//! defer ctx.deinit();
//!
//! // Create per-animation GPU state
//! var native_gpu = gpu.WgpuNativeGPU.init(&ctx);
//! native_gpu.setModule(&bytecode_module);
//!
//! // Execute GPU commands
//! try native_gpu.createBuffer(allocator, 0, 1024, 0x28); // VERTEX | COPY_DST
//! try native_gpu.createShaderModule(allocator, 0, 0);
//! ```

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;

// ============================================================================
// Bounded Iteration Constants (Zig Mastery Compliance)
// ============================================================================

/// Maximum iterations for JSON token parsing (safety bound)
const MAX_JSON_TOKENS: u32 = 2048;

/// Maximum iterations for bytecode field parsing
const MAX_BYTECODE_FIELDS: u32 = 256;

/// Maximum iterations for WGSL dependency resolution
const MAX_WGSL_ITERATIONS: u32 = 1024;

// ============================================================================
// Thread-Safe Diagnostic Counters (DEPRECATED - use per-animation diagnostics)
// ============================================================================
// These are kept for backward compatibility but are deprecated.
// Use per-animation diagnostics (PngineAnimation.diag) instead.

var debug_compute_pipelines_created: Atomic(u32) = Atomic(u32).init(0);
var debug_bind_groups_created: Atomic(u32) = Atomic(u32).init(0);
var debug_compute_passes_begun: Atomic(u32) = Atomic(u32).init(0);
var debug_dispatches: Atomic(u32) = Atomic(u32).init(0);
var debug_render_passes_begun: Atomic(u32) = Atomic(u32).init(0);
var debug_draws: Atomic(u32) = Atomic(u32).init(0);
// Buffer ID tracking for compute vs render debugging
var debug_last_vertex_buffer_id: Atomic(u32) = Atomic(u32).init(0xFFFF);
var debug_last_storage_bind_buffer_id: Atomic(u32) = Atomic(u32).init(0xFFFF);
// First-frame tracking (only set on first occurrence)
var debug_first_vertex_buffer_id: Atomic(u32) = Atomic(u32).init(0xFFFF);
var debug_first_storage_bind_buffer_id: Atomic(u32) = Atomic(u32).init(0xFFFF);
// Buffer 0 size tracking
var debug_buffer_0_size: Atomic(u32) = Atomic(u32).init(0);
// Dispatch X tracking (workgroup count)
var debug_dispatch_x: Atomic(u32) = Atomic(u32).init(0);
// Draw instance count tracking
var debug_instance_count: Atomic(u32) = Atomic(u32).init(0);
var debug_vertex_count: Atomic(u32) = Atomic(u32).init(0);

/// Get diagnostic counters packed into a u32 (DEPRECATED)
/// Format: [compute_passes:8][compute_pipelines:8][bindgroups:8][dispatches:8]
pub fn getDebugCounters() u32 {
    const passes = debug_compute_passes_begun.load(.monotonic);
    const pipelines = debug_compute_pipelines_created.load(.monotonic);
    const bindgroups = debug_bind_groups_created.load(.monotonic);
    const dispatches = debug_dispatches.load(.monotonic);
    return ((passes & 0xFF) << 24) |
        ((pipelines & 0xFF) << 16) |
        ((bindgroups & 0xFF) << 8) |
        (dispatches & 0xFF);
}

/// Get render counters packed into a u32 (DEPRECATED)
/// Format: [render_passes:16][draws:16]
pub fn getRenderCounters() u32 {
    const passes = debug_render_passes_begun.load(.monotonic);
    const draws = debug_draws.load(.monotonic);
    return ((passes & 0xFFFF) << 16) | (draws & 0xFFFF);
}

/// Get buffer IDs for compute/render debugging (DEPRECATED)
/// Format: [last_vertex_buffer_id:16][last_storage_bind_buffer_id:16]
pub fn getBufferIds() u32 {
    const vertex_id = debug_last_vertex_buffer_id.load(.monotonic);
    const storage_id = debug_last_storage_bind_buffer_id.load(.monotonic);
    return ((vertex_id & 0xFFFF) << 16) | (storage_id & 0xFFFF);
}

/// Get first-frame buffer IDs (only set once) (DEPRECATED)
/// Format: [first_vertex_buffer_id:16][first_storage_bind_buffer_id:16]
pub fn getFirstBufferIds() u32 {
    const vertex_id = debug_first_vertex_buffer_id.load(.monotonic);
    const storage_id = debug_first_storage_bind_buffer_id.load(.monotonic);
    return ((vertex_id & 0xFFFF) << 16) | (storage_id & 0xFFFF);
}

/// Get buffer 0 size (DEPRECATED)
pub fn getBuffer0Size() u32 {
    return debug_buffer_0_size.load(.monotonic);
}

/// Get dispatch X (workgroup count) (DEPRECATED)
pub fn getDispatchX() u32 {
    return debug_dispatch_x.load(.monotonic);
}

/// Get draw info packed into a u32 (DEPRECATED)
/// Format: [vertex_count:16][instance_count:16]
pub fn getDrawInfo() u32 {
    const vertex_count = debug_vertex_count.load(.monotonic);
    const instance_count = debug_instance_count.load(.monotonic);
    return ((vertex_count & 0xFFFF) << 16) | (instance_count & 0xFFFF);
}

fn nativeLog(comptime fmt: []const u8, args: anytype) void {
    // Logging disabled on iOS - use debug counters instead
    _ = fmt;
    _ = args;
}

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
///
/// Manages the core wgpu resources that are shared across all animation instances:
/// instance, adapter, device, and queue. These resources are expensive to create
/// and should be reused for multiple WgpuNativeGPU instances.
///
/// ## Lifecycle
///
/// 1. Create once at application startup with `init()`
/// 2. Pass reference to WgpuNativeGPU instances
/// 3. Deinit after all WgpuNativeGPU instances are destroyed
///
/// ## Thread Safety
///
/// The Context itself is not thread-safe. Create it on the main thread before
/// spawning worker threads. However, adapter and device requests use atomic
/// synchronization internally for thread-safe lazy initialization.
///
/// ## Error Handling
///
/// `init()` returns errors for GPU initialization failures:
/// - `InstanceCreationFailed`: wgpu instance could not be created
/// - `AdapterRequestFailed`: No compatible GPU adapter found
/// - `DeviceRequestFailed`: Device creation failed (driver issue)
pub const Context = struct {
    const Self = @This();

    /// wgpu instance - entry point for all GPU operations.
    instance: wgpu.Instance,

    /// Physical GPU adapter - represents a specific GPU device.
    adapter: wgpu.Adapter,

    /// Logical GPU device - used for resource creation.
    device: wgpu.Device,

    /// Command submission queue - used for submitting command buffers.
    queue: wgpu.Queue,

    /// Whether the context has been successfully initialized.
    /// Used to validate state in deinit().
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
///
/// Implements the GPU interface for executing PNGine bytecode commands natively
/// using the wgpu-native C API. This backend runs on iOS (Metal), Android (Vulkan),
/// macOS, Windows, and Linux.
///
/// ## Design
///
/// - **Static allocation**: All resource arrays are fixed-size arrays indexed by
///   resource ID. This avoids runtime allocation and ensures O(1) lookup.
/// - **Command-based**: Same interface as WasmGPU/MockGPU - receives GPU commands
///   from the bytecode dispatcher.
/// - **Pass state**: Tracks current encoder, render pass, or compute pass. Only one
///   pass can be active at a time.
///
/// ## Resource Management
///
/// Resources are stored in fixed-size arrays indexed by their bytecode ID:
/// - Buffers, textures, texture views, samplers (data resources)
/// - Shader modules, render/compute pipelines (program resources)
/// - Bind groups, bind group layouts, pipeline layouts (binding resources)
///
/// ## Surface Rendering
///
/// For on-screen rendering, a surface must be provided at init time. The special
/// texture ID `0xFFFE` in render passes indicates "render to surface".
///
/// ## Invariants
///
/// - Context must be initialized before init() is called
/// - width/height must be > 0
/// - Only one of render_pass/compute_pass can be non-null at a time
/// - Module must be set before operations that reference data IDs
pub const WgpuNativeGPU = struct {
    const Self = @This();

    /// Maximum resources per category (static allocation bounds).
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

    // -----------------------------------------------------------------------
    // Core References
    // -----------------------------------------------------------------------

    /// Shared GPU context (instance, adapter, device, queue).
    /// Must remain valid for the lifetime of this WgpuNativeGPU instance.
    ctx: *Context,

    /// Surface for rendering to a window (optional).
    /// Set to null for headless/offscreen rendering.
    surface: ?wgpu.Surface,

    /// Current surface texture view acquired from surface.
    /// Valid only during active render pass targeting surface.
    /// Released after submit().
    current_surface_view: ?wgpu.TextureView,

    // -----------------------------------------------------------------------
    // Resource Arrays (Static Allocation - O(1) Lookup by ID)
    // -----------------------------------------------------------------------

    /// GPU buffers indexed by bytecode buffer ID.
    buffers: [MAX_BUFFERS]?wgpu.Buffer,

    /// GPU textures indexed by bytecode texture ID.
    textures: [MAX_TEXTURES]?wgpu.Texture,

    /// Texture views for sampling/rendering.
    texture_views: [MAX_TEXTURE_VIEWS]?wgpu.TextureView,

    /// Samplers for texture filtering.
    samplers: [MAX_SAMPLERS]?wgpu.Sampler,

    /// Compiled WGSL shader modules.
    shaders: [MAX_SHADERS]?wgpu.ShaderModule,

    /// Render pipelines (vertex + fragment stages).
    render_pipelines: [MAX_RENDER_PIPELINES]?wgpu.RenderPipeline,

    /// Compute pipelines (compute stage only).
    compute_pipelines: [MAX_COMPUTE_PIPELINES]?wgpu.ComputePipeline,

    /// Bind groups mapping resources to shader bindings.
    bind_groups: [MAX_BIND_GROUPS]?wgpu.BindGroup,

    /// Bind group layouts describing binding structure.
    bind_group_layouts: [MAX_BIND_GROUP_LAYOUTS]?wgpu.BindGroupLayout,

    /// Pipeline layouts combining multiple bind group layouts.
    pipeline_layouts: [MAX_PIPELINE_LAYOUTS]?wgpu.PipelineLayout,

    // -----------------------------------------------------------------------
    // Encoder State (Only One Pass Active at a Time)
    // -----------------------------------------------------------------------

    /// Command encoder for recording GPU commands.
    encoder: ?wgpu.CommandEncoder,

    /// Active render pass encoder (null if no render pass active).
    /// Invariant: render_pass != null implies compute_pass == null.
    render_pass: ?wgpu.RenderPassEncoder,

    /// Active compute pass encoder (null if no compute pass active).
    /// Invariant: compute_pass != null implies render_pass == null.
    compute_pass: ?wgpu.ComputePassEncoder,

    /// Depth stencil view created during beginRenderPass.
    /// Released after submit().
    current_depth_view: ?wgpu.TextureView,

    // -----------------------------------------------------------------------
    // Bytecode Module Reference
    // -----------------------------------------------------------------------

    /// Reference to bytecode module for data section lookups.
    /// Must be set before any GPU calls that reference data IDs.
    module: ?*const Module,

    // -----------------------------------------------------------------------
    // Render Configuration
    // -----------------------------------------------------------------------

    /// Render target width in pixels.
    width: u32,

    /// Render target height in pixels.
    height: u32,

    /// Texture formats for creating depth/stencil views.
    /// Indexed by texture ID, stores WGPUTextureFormat values.
    texture_formats: [MAX_TEXTURES]c_uint,

    /// Animation time in seconds for time-based uniforms.
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

        // Pre-condition assertions (Zig Mastery Compliance)
        assert(buffer_id < MAX_BUFFERS);
        assert(size > 0); // Zero-size buffers are invalid
        assert(usage != 0); // Must have at least one usage flag

        // Skip if buffer already exists (resources are created once, not per-frame)
        if (self.buffers[buffer_id] != null) {
            return;
        }

        // Track buffer 0 size for debugging
        if (buffer_id == 0) {
            debug_buffer_0_size.store(size, .monotonic);
        }

        const descriptor = c.WGPUBufferDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },
            .size = size,
            .usage = wgpu.mapBufferUsage(usage),
            .mappedAtCreation = @intFromBool(false),
        };

        const buffer = wgpu.deviceCreateBuffer(self.ctx.device, &descriptor);
        nativeLog("createBuffer: id={}, size={}, usage=0x{x}, result={}\n", .{
            buffer_id,
            size,
            usage,
            buffer != null,
        });
        self.buffers[buffer_id] = buffer;

        // Post-condition: buffer slot is now populated (may be null if GPU failed)
        assert(self.buffers[buffer_id] != null or buffer == null);
    }

    pub fn createTexture(self: *Self, allocator: Allocator, texture_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        assert(texture_id < MAX_TEXTURES);
        assert(self.module != null);

        // Skip if texture already exists
        if (self.textures[texture_id] != null) {
            return;
        }

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

        // Skip if sampler already exists
        if (self.samplers[sampler_id] != null) {
            return;
        }

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
        // Pre-condition assertions (Zig Mastery Compliance)
        assert(shader_id < MAX_SHADERS);
        assert(self.module != null);
        assert(self.ctx.device != null);

        // Skip if shader already exists
        if (self.shaders[shader_id] != null) {
            return;
        }

        const module = self.module.?;

        // Get WGSL code directly from data section
        const code = module.data.get(DataId.fromInt(code_data_id));
        assert(code.len > 0); // Shader code must not be empty

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
        nativeLog("createShaderModule: id={}, code_len={}, result={}\n", .{
            shader_id,
            code.len,
            shader != null,
        });
        if (shader == null) {
            return error.ShaderCompilationFailed;
        }
        self.shaders[shader_id] = shader;

        // Post-condition: shader slot is now populated
        assert(self.shaders[shader_id] != null);
    }

    /// Resolve WGSL module by ID, concatenating all dependencies.
    /// Uses iterative DFS with bounded iteration to prevent infinite loops.
    fn resolveWgsl(self: *Self, allocator: Allocator, wgsl_id: u16) ![]u8 {
        const module = self.module orelse return error.ModuleNotSet;
        const wgsl_table = &module.wgsl;

        // Pre-condition assertions
        assert(wgsl_id < format.MAX_WGSL_MODULES);

        var included = std.AutoHashMapUnmanaged(u16, void){};
        defer included.deinit(allocator);

        var order = std.ArrayListUnmanaged(u16){};
        defer order.deinit(allocator);

        var stack = std.ArrayListUnmanaged(u16){};
        defer stack.deinit(allocator);

        try stack.append(allocator, wgsl_id);

        // Iterative DFS with bounded iteration (Zig Mastery Compliance)
        for (0..MAX_WGSL_ITERATIONS) |_| {
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
        } else {
            // Iteration limit exceeded - likely circular dependency or malformed data
            return error.WgslDependencyDepthExceeded;
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

        // Skip if pipeline already exists
        if (self.render_pipelines[pipeline_id] != null) {
            return;
        }

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

        // Parse vertex buffer layouts using helper function
        var vertex_layouts = parseVertexBufferLayouts(vertex_obj);

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

        // Parse primitive and depth stencil states using helpers
        const primitive = parsePrimitiveState(root);
        var depth_stencil = parseDepthStencilState(root);

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
            .bufferCount = vertex_layouts.buffer_count,
            .buffers = if (vertex_layouts.buffer_count > 0) @as([*c]const c.WGPUVertexBufferLayout, @ptrCast(&vertex_layouts.buffer_layouts)) else null,
        };
        descriptor.primitive = .{
            .nextInChain = null,
            .topology = primitive.topology,
            .stripIndexFormat = c.WGPUIndexFormat_Undefined,
            .frontFace = c.WGPUFrontFace_CCW,
            .cullMode = primitive.cull_mode,
        };
        descriptor.depthStencil = if (depth_stencil.has_depth_stencil) &depth_stencil.state else null;
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

    /// Vertex buffer layout parsing result for render pipeline creation.
    const VertexLayoutResult = struct {
        buffer_layouts: [4]c.WGPUVertexBufferLayout,
        attributes: [4][8]c.WGPUVertexAttribute,
        buffer_count: usize,
    };

    /// Parse vertex buffer layouts from JSON descriptor.
    /// Extracts array stride, step mode, and vertex attributes.
    fn parseVertexBufferLayouts(vertex_obj: std.json.ObjectMap) VertexLayoutResult {
        var result: VertexLayoutResult = undefined;
        result.buffer_count = 0;

        const buffers_val = vertex_obj.get("buffers") orelse return result;
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
                    result.attributes[bi][ai] = .{
                        .format = parseVertexFormat(attr_obj.get("format").?.string),
                        .offset = @intCast(attr_obj.get("offset").?.integer),
                        .shaderLocation = @intCast(attr_obj.get("shaderLocation").?.integer),
                    };
                    attr_count += 1;
                }
            }

            // Parse stepMode from JSON, default to vertex
            const step_mode: c_uint = blk: {
                if (buf_obj.get("stepMode")) |step_mode_val| {
                    const step_mode_str = step_mode_val.string;
                    if (std.mem.eql(u8, step_mode_str, "instance")) {
                        break :blk c.WGPUVertexStepMode_Instance;
                    }
                }
                break :blk c.WGPUVertexStepMode_Vertex;
            };

            result.buffer_layouts[bi] = .{
                .arrayStride = @intCast(stride),
                .stepMode = step_mode,
                .attributeCount = attr_count,
                .attributes = @ptrCast(&result.attributes[bi]),
            };
            result.buffer_count += 1;
        }

        return result;
    }

    /// Primitive state parsing result.
    const PrimitiveStateResult = struct {
        topology: u32,
        cull_mode: u32,
    };

    /// Parse primitive state from JSON descriptor.
    fn parsePrimitiveState(root: std.json.ObjectMap) PrimitiveStateResult {
        var result = PrimitiveStateResult{
            .topology = c.WGPUPrimitiveTopology_TriangleList,
            .cull_mode = c.WGPUCullMode_None,
        };

        const prim_val = root.get("primitive") orelse return result;
        const prim_obj = prim_val.object;

        if (prim_obj.get("topology")) |topo_val| {
            result.topology = parseTopology(topo_val.string);
        }
        if (prim_obj.get("cullMode")) |cull_val| {
            result.cull_mode = parseCullMode(cull_val.string);
        }

        return result;
    }

    /// Depth stencil state parsing result.
    const DepthStencilResult = struct {
        state: c.WGPUDepthStencilState,
        has_depth_stencil: bool,
    };

    /// Parse depth stencil state from JSON descriptor.
    fn parseDepthStencilState(root: std.json.ObjectMap) DepthStencilResult {
        var result = DepthStencilResult{
            .state = undefined,
            .has_depth_stencil = false,
        };

        const ds_val = root.get("depthStencil") orelse return result;
        const ds_obj = ds_val.object;
        result.has_depth_stencil = true;

        result.state = std.mem.zeroes(c.WGPUDepthStencilState);
        result.state.format = if (ds_obj.get("format")) |fmt|
            parseDepthFormat(fmt.string)
        else
            c.WGPUTextureFormat_Depth24Plus;
        result.state.depthWriteEnabled = if (ds_obj.get("depthWriteEnabled")) |dwe|
            @intFromBool(dwe.bool)
        else
            1;
        result.state.depthCompare = if (ds_obj.get("depthCompare")) |dc|
            parseCompareFunction(dc.string)
        else
            c.WGPUCompareFunction_Less;

        // Default stencil operations
        result.state.stencilFront = .{
            .compare = c.WGPUCompareFunction_Always,
            .failOp = c.WGPUStencilOperation_Keep,
            .depthFailOp = c.WGPUStencilOperation_Keep,
            .passOp = c.WGPUStencilOperation_Keep,
        };
        result.state.stencilBack = result.state.stencilFront;
        result.state.stencilReadMask = 0xFFFFFFFF;
        result.state.stencilWriteMask = 0xFFFFFFFF;
        result.state.depthBias = 0;
        result.state.depthBiasSlopeScale = 0;
        result.state.depthBiasClamp = 0;

        return result;
    }

    // -----------------------------------------------------------------------
    // Helper Structs and Functions (Zig Mastery: ≤70 lines per function)
    // -----------------------------------------------------------------------

    /// Result of acquiring color target view for render pass.
    ///
    /// Used by `getColorTargetView()` to return both the view handle and
    /// metadata about whether it came from the surface (needs cleanup) or
    /// a custom texture (already managed).
    const ColorViewResult = struct {
        /// Texture view to use as color attachment.
        view: wgpu.TextureView,
        /// True if view is from surface (must release after submit).
        is_surface: bool,
    };

    /// Acquire color target view from texture ID or surface.
    ///
    /// Special texture IDs:
    /// - `0xFFFE`: Render to surface/screen (requires surface to be configured)
    /// - `0-MAX_TEXTURES`: Render to custom texture
    ///
    /// Errors:
    /// - `NoSurfaceConfigured`: texture_id=0xFFFE but no surface set
    /// - `SurfaceTextureUnavailable`: Surface texture acquisition failed
    /// - `TextureNotFound`: texture_id not found in texture arrays
    fn getColorTargetView(self: *Self, color_texture_id: u16) !ColorViewResult {
        // 0xFFFE (65534) = render to surface/screen
        if (color_texture_id == 0xFFFE) {
            const surface = self.surface orelse return error.NoSurfaceConfigured;
            var surface_texture: wgpu.SurfaceTexture = undefined;
            wgpu.surfaceGetCurrentTexture(surface, &surface_texture);

            const status = surface_texture.status;
            if (status != c.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal and
                status != c.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal)
            {
                return error.SurfaceTextureUnavailable;
            }

            if (surface_texture.texture == null) return error.SurfaceTextureUnavailable;
            const view = wgpu.textureCreateView(surface_texture.texture, null);
            if (view == null) return error.SurfaceTextureUnavailable;

            return .{ .view = view, .is_surface = true };
        }

        // Render to custom texture
        if (self.texture_views[color_texture_id]) |v| {
            return .{ .view = v, .is_surface = false };
        }
        if (self.textures[color_texture_id]) |t| {
            const view = wgpu.textureCreateView(t, null);
            if (view == null) return error.TextureNotFound;
            return .{ .view = view, .is_surface = false };
        }
        return error.TextureNotFound;
    }

    /// Result of setting up depth stencil attachment.
    ///
    /// Used by `setupDepthAttachment()` to return the configured attachment
    /// and associated view. If `valid` is false, depth testing is disabled.
    const DepthAttachmentResult = struct {
        /// Configured depth stencil attachment descriptor.
        attachment: c.WGPURenderPassDepthStencilAttachment,
        /// View handle (must be released after submit if valid).
        view: wgpu.TextureView,
        /// True if depth attachment is valid and should be used.
        valid: bool,
    };

    /// Setup depth stencil attachment from texture ID.
    ///
    /// Creates a depth-only texture view from the specified texture ID.
    /// Returns invalid result for:
    /// - `0xFFFF`: No depth attachment requested
    /// - Invalid texture IDs or null textures
    ///
    /// The returned view must be released after the command buffer is submitted.
    fn setupDepthAttachment(self: *Self, depth_texture_id: u16) DepthAttachmentResult {
        var result = DepthAttachmentResult{
            .attachment = undefined,
            .view = null,
            .valid = false,
        };

        if (depth_texture_id == 0xFFFF or depth_texture_id >= MAX_TEXTURES) return result;
        const depth_tex = self.textures[depth_texture_id] orelse return result;

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
        if (depth_view == null) return result;

        result.view = depth_view;
        result.valid = true;
        result.attachment = std.mem.zeroes(c.WGPURenderPassDepthStencilAttachment);
        result.attachment.view = depth_view;
        result.attachment.depthLoadOp = c.WGPULoadOp_Clear;
        result.attachment.depthStoreOp = c.WGPUStoreOp_Store;
        result.attachment.depthClearValue = 1.0;
        result.attachment.stencilLoadOp = c.WGPULoadOp_Undefined;
        result.attachment.stencilStoreOp = c.WGPUStoreOp_Undefined;
        result.attachment.stencilClearValue = 0;
        result.attachment.stencilReadOnly = 0;
        result.attachment.depthReadOnly = 0;

        return result;
    }

    /// Result of parsing a single bind group layout entry.
    ///
    /// Used by `parseBindGroupEntry()` to return the parsed entry and
    /// byte consumption for advancing through the binary descriptor.
    const BindGroupEntryResult = struct {
        /// Parsed bind group layout entry.
        entry: c.WGPUBindGroupLayoutEntry,
        /// Number of bytes consumed from the input data.
        bytes_consumed: usize,
        /// True if parsing succeeded.
        valid: bool,
    };

    /// Parse a single bind group entry from binary descriptor data.
    ///
    /// Binary format per entry:
    /// ```
    /// [binding:u8][visibility:u8][resource_type:u8][type_specific_data...]
    /// ```
    ///
    /// Resource types:
    /// - `0x01`: Buffer (uniform, storage, or read-only storage)
    /// - `0x02`: Sampler
    /// - `0x03`: Sampled texture
    /// - `0x04`: Storage texture
    ///
    /// Returns invalid result if data is malformed or insufficient.
    fn parseBindGroupEntry(data: []const u8, offset: usize) BindGroupEntryResult {
        var result = BindGroupEntryResult{
            .entry = std.mem.zeroes(c.WGPUBindGroupLayoutEntry),
            .bytes_consumed = 0,
            .valid = false,
        };

        // Need at least 3 bytes for header
        if (offset + 3 > data.len) return result;

        const binding = data[offset];
        const visibility = data[offset + 1];
        const resource_type = data[offset + 2];
        var off: usize = offset + 3;

        // Initialize entry with all binding types as "not used"
        result.entry.binding = binding;
        result.entry.visibility = visibility;
        result.entry.buffer.type = c.WGPUBufferBindingType_BindingNotUsed;
        result.entry.sampler.type = c.WGPUSamplerBindingType_BindingNotUsed;
        result.entry.texture.sampleType = c.WGPUTextureSampleType_BindingNotUsed;
        result.entry.storageTexture.access = c.WGPUStorageTextureAccess_BindingNotUsed;

        switch (resource_type) {
            0x00 => {
                // Buffer binding: [type:u8][hasDynamicOffset:u8][minBindingSize:u32]
                if (off + 6 > data.len) return result;
                const buf_type = data[off];
                const has_dynamic_offset = data[off + 1];
                const min_binding_size = std.mem.readInt(u32, data[off + 2 ..][0..4], .little);
                off += 6;

                result.entry.buffer.type = switch (buf_type) {
                    0 => c.WGPUBufferBindingType_Uniform,
                    1 => c.WGPUBufferBindingType_Storage,
                    2 => c.WGPUBufferBindingType_ReadOnlyStorage,
                    else => c.WGPUBufferBindingType_Uniform,
                };
                result.entry.buffer.hasDynamicOffset = if (has_dynamic_offset != 0) 1 else 0;
                result.entry.buffer.minBindingSize = min_binding_size;
            },
            0x01 => {
                // Sampler binding: [type:u8]
                if (off + 1 > data.len) return result;
                const samp_type = data[off];
                off += 1;

                result.entry.sampler.type = switch (samp_type) {
                    0 => c.WGPUSamplerBindingType_Filtering,
                    1 => c.WGPUSamplerBindingType_NonFiltering,
                    2 => c.WGPUSamplerBindingType_Comparison,
                    else => c.WGPUSamplerBindingType_Filtering,
                };
            },
            0x02 => {
                // Texture binding: [sampleType:u8][viewDimension:u8][multisampled:u8]
                if (off + 3 > data.len) return result;
                const sample_type = data[off];
                const view_dim = data[off + 1];
                const multisampled = data[off + 2];
                off += 3;

                result.entry.texture.sampleType = switch (sample_type) {
                    0 => c.WGPUTextureSampleType_Float,
                    1 => c.WGPUTextureSampleType_UnfilterableFloat,
                    2 => c.WGPUTextureSampleType_Depth,
                    3 => c.WGPUTextureSampleType_Sint,
                    4 => c.WGPUTextureSampleType_Uint,
                    else => c.WGPUTextureSampleType_Float,
                };
                result.entry.texture.viewDimension = mapViewDimension(view_dim);
                result.entry.texture.multisampled = if (multisampled != 0) 1 else 0;
            },
            0x03 => {
                // Storage texture binding: [format:u8][access:u8][viewDimension:u8]
                if (off + 3 > data.len) return result;
                const tex_format = data[off];
                const access = data[off + 1];
                const view_dim = data[off + 2];
                off += 3;

                result.entry.storageTexture.format = mapTextureFormat(tex_format);
                result.entry.storageTexture.access = switch (access) {
                    0 => c.WGPUStorageTextureAccess_WriteOnly,
                    1 => c.WGPUStorageTextureAccess_ReadOnly,
                    2 => c.WGPUStorageTextureAccess_ReadWrite,
                    else => c.WGPUStorageTextureAccess_WriteOnly,
                };
                result.entry.storageTexture.viewDimension = mapViewDimension(view_dim);
            },
            0x04 => {
                // External texture: no extra data (WebGPU-only, skip for native)
            },
            else => {},
        }

        result.bytes_consumed = off - offset;
        result.valid = true;
        return result;
    }

    pub fn createComputePipeline(self: *Self, allocator: Allocator, pipeline_id: u16, descriptor_data_id: u16) !void {
        assert(pipeline_id < MAX_COMPUTE_PIPELINES);
        assert(self.module != null);

        // Skip if pipeline already exists
        if (self.compute_pipelines[pipeline_id] != null) {
            return;
        }

        const module = self.module.?;
        const desc_data = module.data.get(DataId.fromInt(descriptor_data_id));

        // Binary format: [type_tag:0x06][shader_id:u16 LE][entry_len:u8][entry_bytes]
        if (desc_data.len < 4) return error.InvalidResourceId;
        if (desc_data[0] != 0x06) return error.InvalidResourceId; // type tag must be compute_pipeline

        const compute_shader_id: u16 = @as(u16, desc_data[1]) | (@as(u16, desc_data[2]) << 8);
        const entry_len = desc_data[3];

        // Default entry point if none specified
        var entry_point: []const u8 = "main";
        if (entry_len > 0 and desc_data.len >= 4 + entry_len) {
            entry_point = desc_data[4..][0..entry_len];
        }

        const compute_shader = self.shaders[compute_shader_id] orelse return error.InvalidResourceId;

        // Create null-terminated entry point string
        const entry_z = try allocator.allocSentinel(u8, entry_point.len, 0);
        defer allocator.free(entry_z);
        @memcpy(entry_z, entry_point);

        // Create compute pipeline descriptor
        var descriptor = std.mem.zeroes(c.WGPUComputePipelineDescriptor);
        descriptor.label = .{ .data = null, .length = 0 };
        descriptor.layout = null; // Auto layout
        descriptor.compute = .{
            .nextInChain = null,
            .module = compute_shader,
            .entryPoint = .{ .data = entry_z.ptr, .length = entry_z.len },
            .constantCount = 0,
            .constants = null,
        };

        const pipeline = wgpu.deviceCreateComputePipeline(self.ctx.device, &descriptor);
        if (pipeline != null) {
            _ = debug_compute_pipelines_created.fetchAdd(1, .monotonic);
        }
        nativeLog("createComputePipeline: id={}, shader_id={}, entry={s}, result={}\n", .{
            pipeline_id,
            compute_shader_id,
            entry_point,
            pipeline != null,
        });
        if (pipeline == null) {
            return error.PipelineCreationFailed;
        }
        self.compute_pipelines[pipeline_id] = pipeline;
    }


    pub fn createBindGroup(self: *Self, allocator: Allocator, group_id: u16, layout_id: u16, entry_data_id: u16) !void {
        assert(group_id < MAX_BIND_GROUPS);
        assert(self.module != null);

        // Skip if bind group already exists
        if (self.bind_groups[group_id] != null) {
            return;
        }

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

        // Get layout: check explicit bind group layout first, then auto-layout from pipeline
        const layout: c.WGPUBindGroupLayout = blk: {
            // Try explicit bind group layout first
            if (layout_id < MAX_BIND_GROUP_LAYOUTS) {
                if (self.bind_group_layouts[layout_id]) |explicit_layout| {
                    break :blk explicit_layout;
                }
            }
            // Try auto-layout from render pipeline
            if (self.render_pipelines[layout_id]) |pipeline| {
                break :blk wgpu.renderPipelineGetBindGroupLayout(pipeline, group_index);
            }
            // Try auto-layout from compute pipeline
            if (self.compute_pipelines[layout_id]) |pipeline| {
                break :blk wgpu.computePipelineGetBindGroupLayout(pipeline, group_index);
            }
            break :blk null;
        };
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
                                // Track storage buffer ID for debugging
                                debug_last_storage_bind_buffer_id.store(rid, .monotonic);
                                // Only set first on first occurrence (compare-and-swap)
                                _ = debug_first_storage_bind_buffer_id.cmpxchgStrong(0xFFFF, rid, .monotonic, .monotonic);
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

        const bind_group = wgpu.deviceCreateBindGroup(self.ctx.device, &desc);
        if (bind_group != null) {
            _ = debug_bind_groups_created.fetchAdd(1, .monotonic);
        }
        self.bind_groups[group_id] = bind_group;
        nativeLog("createBindGroup: id={}, layout_id={}, entries={}, result={}\n", .{
            group_id,
            layout_id,
            entry_count,
            bind_group != null,
        });
        _ = allocator; // Interface requirement - native backend doesn't need allocator
    }

    pub fn createBindGroupLayout(self: *Self, allocator: Allocator, layout_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        assert(layout_id < MAX_BIND_GROUP_LAYOUTS);
        assert(self.module != null);

        // Skip if layout already exists
        if (self.bind_group_layouts[layout_id] != null) {
            return;
        }

        const module = self.module.?;
        const data = module.data.get(DataId.fromInt(descriptor_data_id));

        // Parse binary descriptor format:
        // [type_tag:u8][field_count:u8][entries_field_id:u8][array_type:u8][entry_count:u8][entries...]
        if (data.len < 5) return;

        // Skip type_tag (0x04) and field_count, check for entries field
        if (data[2] != 0x01 or data[3] != 0x03) return;

        const entry_count = data[4];
        if (entry_count == 0 or entry_count > 16) return;

        // Parse entries into C struct array using helper
        var entries: [16]c.WGPUBindGroupLayoutEntry = undefined;
        var parsed_count: usize = 0;
        var off: usize = 5;

        for (0..entry_count) |i| {
            const result = parseBindGroupEntry(data, off);
            if (!result.valid) break;

            entries[i] = result.entry;
            off += result.bytes_consumed;
            parsed_count += 1;
        }

        if (parsed_count == 0) return;

        // Create bind group layout
        var desc = std.mem.zeroes(c.WGPUBindGroupLayoutDescriptor);
        desc.entryCount = parsed_count;
        desc.entries = &entries;

        const layout = wgpu.deviceCreateBindGroupLayout(self.ctx.device, &desc);
        self.bind_group_layouts[layout_id] = layout;

        // Post-condition: layout slot is populated (may be null if GPU failed)
        assert(self.bind_group_layouts[layout_id] != null or layout == null);

        nativeLog("createBindGroupLayout: id={}, entries={}, result={}\n", .{
            layout_id,
            parsed_count,
            layout != null,
        });
    }

    /// Map encoded view dimension to wgpu constant
    fn mapViewDimension(dim: u8) c_uint {
        return switch (dim) {
            0 => c.WGPUTextureViewDimension_1D,
            1 => c.WGPUTextureViewDimension_2D,
            2 => c.WGPUTextureViewDimension_2DArray,
            3 => c.WGPUTextureViewDimension_Cube,
            4 => c.WGPUTextureViewDimension_CubeArray,
            5 => c.WGPUTextureViewDimension_3D,
            else => c.WGPUTextureViewDimension_2D,
        };
    }

    /// Map encoded texture format to wgpu constant
    fn mapTextureFormat(fmt: u8) c_uint {
        return switch (fmt) {
            0x00 => c.WGPUTextureFormat_RGBA8Unorm,
            0x01 => c.WGPUTextureFormat_RGBA8Snorm,
            0x02 => c.WGPUTextureFormat_RGBA8Uint,
            0x03 => c.WGPUTextureFormat_RGBA8Sint,
            0x04 => c.WGPUTextureFormat_RGBA16Uint,
            0x05 => c.WGPUTextureFormat_RGBA16Sint,
            0x06 => c.WGPUTextureFormat_RGBA16Float,
            0x07 => c.WGPUTextureFormat_RGBA32Uint,
            0x08 => c.WGPUTextureFormat_RGBA32Sint,
            0x09 => c.WGPUTextureFormat_RGBA32Float,
            0x0A => c.WGPUTextureFormat_BGRA8Unorm,
            0x0B => c.WGPUTextureFormat_R32Float,
            0x0C => c.WGPUTextureFormat_RG32Float,
            else => c.WGPUTextureFormat_RGBA8Unorm,
        };
    }

    pub fn createPipelineLayout(self: *Self, allocator: Allocator, layout_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        assert(layout_id < MAX_PIPELINE_LAYOUTS);
        assert(self.module != null);

        // Skip if layout already exists
        if (self.pipeline_layouts[layout_id] != null) {
            return;
        }

        const module = self.module.?;
        const data = module.data.get(DataId.fromInt(descriptor_data_id));

        // Parse descriptor format: [count:u8][layout_id:u16]...
        if (data.len < 1) return;

        const bgl_count = data[0];
        if (bgl_count == 0 or bgl_count > 8) return; // WebGPU limit is typically 4, be generous

        // Verify we have enough data for all layout IDs
        const expected_len = 1 + @as(usize, bgl_count) * 2;
        if (data.len < expected_len) return;

        // Collect bind group layout handles
        var layouts: [8]c.WGPUBindGroupLayout = undefined;
        var valid_count: usize = 0;

        for (0..bgl_count) |i| {
            const off = 1 + i * 2;
            const bgl_id = @as(u16, data[off]) | (@as(u16, data[off + 1]) << 8);

            if (bgl_id >= MAX_BIND_GROUP_LAYOUTS) continue;

            const bgl = self.bind_group_layouts[bgl_id] orelse continue;
            layouts[valid_count] = bgl;
            valid_count += 1;
        }

        if (valid_count == 0) return;

        // Create pipeline layout
        var desc = std.mem.zeroes(c.WGPUPipelineLayoutDescriptor);
        desc.bindGroupLayoutCount = valid_count;
        desc.bindGroupLayouts = &layouts;

        const layout = wgpu.deviceCreatePipelineLayout(self.ctx.device, &desc);
        self.pipeline_layouts[layout_id] = layout;
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

        // Pre-condition assertions (Zig Mastery Compliance)
        assert(self.ctx.device != null);
        assert(load_op <= 1); // 0=Load, 1=Clear
        assert(store_op <= 1); // 0=Store, 1=Discard

        // Get color target view using helper
        const color_result = try getColorTargetView(self, color_texture_id);
        if (color_result.is_surface) {
            self.current_surface_view = color_result.view;
        }

        // Reuse existing encoder if one exists, otherwise create new
        if (self.encoder == null) {
            self.encoder = wgpu.deviceCreateCommandEncoder(self.ctx.device, null);
        }
        const encoder = self.encoder orelse return error.SurfaceTextureUnavailable;

        // Map bytecode load/store ops to wgpu-native values
        const wgpu_load_op: c_uint = if (load_op == 0) c.WGPULoadOp_Load else c.WGPULoadOp_Clear;
        const wgpu_store_op: c_uint = if (store_op == 0) c.WGPUStoreOp_Store else c.WGPUStoreOp_Discard;

        // Color attachment
        var color_attachment = std.mem.zeroes(c.WGPURenderPassColorAttachment);
        color_attachment.view = color_result.view;
        color_attachment.depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED;
        color_attachment.loadOp = wgpu_load_op;
        color_attachment.storeOp = wgpu_store_op;
        color_attachment.clearValue = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };

        // Release previous depth view if any
        if (self.current_depth_view) |old_view| {
            wgpu.textureViewRelease(old_view);
            self.current_depth_view = null;
        }

        // Depth stencil attachment using helper
        const depth_result = setupDepthAttachment(self, depth_texture_id);
        var depth_attachment = depth_result.attachment;
        if (depth_result.valid) {
            self.current_depth_view = depth_result.view;
        }

        var render_pass_desc = std.mem.zeroes(c.WGPURenderPassDescriptor);
        render_pass_desc.label = .{ .data = null, .length = 0 };
        render_pass_desc.colorAttachmentCount = 1;
        render_pass_desc.colorAttachments = &color_attachment;
        render_pass_desc.depthStencilAttachment = if (depth_result.valid) &depth_attachment else null;

        self.render_pass = wgpu.commandEncoderBeginRenderPass(encoder, &render_pass_desc);

        // Post-condition: render pass was started
        if (self.render_pass != null) {
            _ = debug_render_passes_begun.fetchAdd(1, .monotonic);
        }
    }

    pub fn beginComputePass(self: *Self, allocator: Allocator) !void {
        _ = allocator;

        // Pre-condition assertions (Zig Mastery Compliance)
        assert(self.ctx.device != null);
        assert(self.compute_pass == null); // Must not be in a compute pass already

        // Reuse existing encoder if one exists, otherwise create new
        const reusing = self.encoder != null;
        if (self.encoder == null) {
            self.encoder = wgpu.deviceCreateCommandEncoder(self.ctx.device, null);
        }
        self.compute_pass = wgpu.commandEncoderBeginComputePass(self.encoder.?, null);
        if (self.compute_pass != null) {
            _ = debug_compute_passes_begun.fetchAdd(1, .monotonic);
        }
        nativeLog("[NATIVE] beginComputePass: reusing={}, pass_valid={}\n", .{ reusing, self.compute_pass != null });

        // Post-condition: compute pass is now active
        assert(self.compute_pass != null);
    }

    pub fn setPipeline(self: *Self, allocator: Allocator, pipeline_id: u16) !void {
        _ = allocator;

        if (self.render_pass) |pass| {
            if (self.render_pipelines[pipeline_id]) |pipeline| {
                wgpu.renderPassEncoderSetPipeline(pass, pipeline);
            }
        } else if (self.compute_pass) |pass| {
            const has_pipeline = self.compute_pipelines[pipeline_id] != null;
            nativeLog("setPipeline(compute): id={}, found={}, pass_valid={}\n", .{ pipeline_id, has_pipeline, pass != null });
            if (self.compute_pipelines[pipeline_id]) |pipeline| {
                wgpu.computePassEncoderSetPipeline(pass, pipeline);
            }
        }
    }

    pub fn setBindGroup(self: *Self, allocator: Allocator, slot: u8, group_id: u16) !void {
        _ = allocator;

        const has_group = self.bind_groups[group_id] != null;
        const in_compute = self.compute_pass != null;
        if (in_compute) {
            nativeLog("setBindGroup(compute): slot={}, group_id={}, found={}\n", .{ slot, group_id, has_group });
        }

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

        // Track buffer ID for debugging
        debug_last_vertex_buffer_id.store(buffer_id, .monotonic);
        // Only set first on first occurrence (compare-and-swap)
        _ = debug_first_vertex_buffer_id.cmpxchgStrong(0xFFFF, buffer_id, .monotonic, .monotonic);

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
            _ = debug_draws.fetchAdd(1, .monotonic);
            debug_vertex_count.store(vertex_count, .monotonic);
            debug_instance_count.store(instance_count, .monotonic);
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

        const has_pass = self.compute_pass != null;
        nativeLog("dispatch: x={}, y={}, z={}, has_pass={}\n", .{ x, y, z, has_pass });

        if (self.compute_pass) |pass| {
            _ = debug_dispatches.fetchAdd(1, .monotonic);
            debug_dispatch_x.store(x, .monotonic);
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
            nativeLog("endPass(compute): ending compute pass\n", .{});
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

    // ========================================================================
    // Snake_case Aliases (Dispatcher Backend Interface Compliance)
    // ========================================================================
    //
    // The dispatcher and handler modules (resource.zig, pass.zig, queue.zig, etc.)
    // call backend methods using snake_case names matching MockGPU's convention.
    // These zero-cost comptime aliases bridge the naming difference.

    // Resource creation
    pub const create_buffer = createBuffer;
    pub const create_texture = createTexture;
    pub const create_sampler = createSampler;
    pub const create_shader_module = createShaderModule;
    pub const create_render_pipeline = createRenderPipeline;
    pub const create_compute_pipeline = createComputePipeline;
    pub const create_bind_group = createBindGroup;
    pub const create_bind_group_layout = createBindGroupLayout;
    pub const create_pipeline_layout = createPipelineLayout;
    pub const create_texture_view = createTextureView;
    pub const create_query_set = createQuerySet;
    pub const create_image_bitmap = createImageBitmap;
    pub const create_render_bundle = createRenderBundle;

    // Pass operations
    pub const begin_render_pass = beginRenderPass;
    pub const begin_compute_pass = beginComputePass;
    pub const set_pipeline = setPipeline;
    pub const set_bind_group = setBindGroup;
    pub const set_vertex_buffer = setVertexBuffer;
    pub const set_index_buffer = setIndexBuffer;
    pub const draw_indexed = drawIndexed;
    pub const end_pass = endPass;
    pub const execute_bundles = executeBundles;

    // Queue operations
    pub const write_buffer = writeBuffer;
    pub const write_time_uniform = writeTimeUniform;
    pub const copy_external_image_to_texture = copyExternalImageToTexture;

    // WASM operations
    pub const init_wasm_module = initWasmModule;
    pub const call_wasm_func = callWasmFunc;
    pub const write_buffer_from_wasm = writeBufferFromWasm;
};

// ============================================================================
// Dispatcher Type Alias
// ============================================================================

const dispatcher_mod = @import("dispatcher.zig");
pub const NativeDispatcher = dispatcher_mod.Dispatcher(WgpuNativeGPU);
