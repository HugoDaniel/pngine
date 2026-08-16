//! wgpu-native C API Bindings (v27.0.4.0+)
//!
//! Imports wgpu.h via @cImport for native GPU operations.
//! This module provides type-safe Zig wrappers around the wgpu-native C API.
//!
//! ## Usage
//!
//! const wgpu = @import("gpu/wgpu_c.zig");
//! const instance = wgpu.createInstance(null);
//!
//! ## Build Requirements
//!
//! Link against libwgpu_native.a/.dylib and set include path:
//! - vendor/wgpu-native/include/ for headers
//! - vendor/wgpu-native/lib/ for libraries
//!
//! ## API Version
//!
//! This module targets wgpu-native v27+ which uses the new callback-based async API:
//! - Request functions return WGPUFuture and take WGPURequestXxxCallbackInfo
//! - Use wgpuInstanceWaitAny() to wait for async operations
//! - Callbacks receive WGPUStringView instead of null-terminated strings

const std = @import("std");
const builtin = @import("builtin");

// Import the C headers
pub const c = @cImport({
    @cInclude("webgpu/webgpu.h");
    @cInclude("webgpu/wgpu.h");
});

// ============================================================================
// Type Aliases (for cleaner Zig code)
// ============================================================================

pub const Instance = c.WGPUInstance;
pub const Adapter = c.WGPUAdapter;
pub const Device = c.WGPUDevice;
pub const Queue = c.WGPUQueue;
pub const Surface = c.WGPUSurface;
pub const Buffer = c.WGPUBuffer;
pub const Texture = c.WGPUTexture;
pub const TextureView = c.WGPUTextureView;
pub const Sampler = c.WGPUSampler;
pub const ShaderModule = c.WGPUShaderModule;
pub const RenderPipeline = c.WGPURenderPipeline;
pub const ComputePipeline = c.WGPUComputePipeline;
pub const BindGroup = c.WGPUBindGroup;
pub const BindGroupLayout = c.WGPUBindGroupLayout;
pub const PipelineLayout = c.WGPUPipelineLayout;
pub const CommandEncoder = c.WGPUCommandEncoder;
pub const RenderPassEncoder = c.WGPURenderPassEncoder;
pub const ComputePassEncoder = c.WGPUComputePassEncoder;
pub const CommandBuffer = c.WGPUCommandBuffer;
pub const SurfaceTexture = c.WGPUSurfaceTexture;

// ============================================================================
// Lifetime counters (LEAK-01) — the native mirror of the §309 browser instruments
// ============================================================================
//
// wgpu-native is refcounted C: every `wgpuDeviceCreate*`, `wgpuTextureCreateView`,
// `wgpu*BeginPass`, `wgpuSurfaceGetCurrentTexture` and `wgpu*GetBindGroupLayout`
// hands back an OWNED reference, and every leak is one missing `*Release`. Nothing
// in the process notices: no allocator sees it, no GC collects it, and the Zig
// test runner's leak check covers only Zig allocations. That silence is why the
// backend leaked the surface texture on EVERY windowed frame from the day the
// surface path was written until LEAK-01.
//
// These wrappers are the only route from the engine to wgpu for every counted
// kind, so counting here cannot be bypassed by a new call site the way an audit
// can be — but "counted kind" is the load-bearing half of that sentence. This
// comment used to dismiss the four `wgpuInstanceCreateSurface` calls in
// native_api.zig as "not refcount traffic". They are: a surface is a refcounted
// object like any other, and because the ledger had no counter for it, the one
// kind that escaped the wrappers was also the one kind nothing could see leak.
// LEAK-04 A/B lived in that blind spot. Surfaces and queues are counted now, and
// their creation goes through `instanceCreateSurface`/`deviceGetQueue` here.
//
// The property under test is not "created == released" — a backend mid-frame
// legitimately holds an encoder and a pass. It is that `created − released` per
// kind is FLAT from one frame to the next: a steady state, whatever its value.
// `live()` computes that vector; `tests/zig/render/native_frame_balance_test.zig`
// asserts it does not move across 200 frames.
//
// Debug/test builds only. `enabled` is comptime, so a release binary compiles
// every `bump` to nothing — a shipping viewer pays neither the atomic nor the
// branch.
pub const lifetimes = struct {
    /// Compile the counters in for Debug and for every test binary (`is_test`
    /// holds regardless of optimize mode, so `-Doptimize=ReleaseFast` cannot
    /// silently turn the balance gate into a tautology).
    pub const enabled = builtin.is_test or builtin.mode == .Debug;

    /// One counter per acquisition/release site. `bgl_derived` is kept apart
    /// from `bgl_created` because only the derived ones (`*GetBindGroupLayout`)
    /// are invisible to `deinit`'s table sweep — LEAK-02 B is exactly the gap
    /// between those two counters.
    pub const Kind = enum {
        buffer_created,
        buffer_released,
        texture_created,
        surface_texture_acquired,
        texture_released,
        view_created,
        view_released,
        sampler_created,
        sampler_released,
        shader_module_created,
        shader_module_released,
        render_pipeline_created,
        render_pipeline_released,
        compute_pipeline_created,
        compute_pipeline_released,
        bind_group_created,
        bind_group_released,
        bgl_created,
        bgl_derived,
        bgl_released,
        pipeline_layout_created,
        pipeline_layout_released,
        encoder_created,
        encoder_released,
        command_buffer_created,
        command_buffer_released,
        render_pass_begun,
        render_pass_released,
        compute_pass_begun,
        compute_pass_released,
        // A surface outlives every frame-scoped object above it and is owned by
        // the API layer, not the backend — which is exactly how it went nine
        // months without anyone releasing it.
        surface_created,
        surface_released,
        // `wgpuDeviceGetQueue` hands back an OWNED reference per the C contract,
        // "get" in the name notwithstanding.
        queue_acquired,
        queue_released,
    };

    var counts: [std.meta.fields(Kind).len]std.atomic.Value(u32) = @splat(.init(0));

    inline fn bump(comptime k: Kind) void {
        if (comptime !enabled) return;
        _ = counts[@intFromEnum(k)].fetchAdd(1, .monotonic);
    }

    /// Total events of one kind since the last `reset()`.
    pub fn get(k: Kind) u32 {
        return counts[@intFromEnum(k)].load(.monotonic);
    }

    /// Zero every counter. Tests call this at a known-quiet point; the counters
    /// are process-global (one device per process in every harness we have).
    pub fn reset() void {
        for (&counts) |*ct| ct.store(0, .monotonic);
    }

    /// References the process is holding right now, per kind. Field-per-kind
    /// rather than a flat array so a failing assertion names the object that
    /// leaked instead of an index.
    pub const Live = struct {
        buffers: i64,
        textures: i64,
        views: i64,
        samplers: i64,
        shader_modules: i64,
        render_pipelines: i64,
        compute_pipelines: i64,
        bind_groups: i64,
        bind_group_layouts: i64,
        pipeline_layouts: i64,
        encoders: i64,
        command_buffers: i64,
        render_passes: i64,
        compute_passes: i64,
        surfaces: i64,
        queues: i64,
    };

    fn delta(created: Kind, released: Kind) i64 {
        return @as(i64, get(created)) - @as(i64, get(released));
    }

    pub fn live() Live {
        return .{
            .buffers = delta(.buffer_created, .buffer_released),
            // Surface textures are acquired, not created, and released through
            // the same `wgpuTextureRelease` — one live count covers both.
            .textures = delta(.texture_created, .texture_released) + @as(i64, get(.surface_texture_acquired)),
            .views = delta(.view_created, .view_released),
            .samplers = delta(.sampler_created, .sampler_released),
            .shader_modules = delta(.shader_module_created, .shader_module_released),
            .render_pipelines = delta(.render_pipeline_created, .render_pipeline_released),
            .compute_pipelines = delta(.compute_pipeline_created, .compute_pipeline_released),
            .bind_groups = delta(.bind_group_created, .bind_group_released),
            .bind_group_layouts = delta(.bgl_created, .bgl_released) + @as(i64, get(.bgl_derived)),
            .pipeline_layouts = delta(.pipeline_layout_created, .pipeline_layout_released),
            .encoders = delta(.encoder_created, .encoder_released),
            .command_buffers = delta(.command_buffer_created, .command_buffer_released),
            .render_passes = delta(.render_pass_begun, .render_pass_released),
            .compute_passes = delta(.compute_pass_begun, .compute_pass_released),
            .surfaces = delta(.surface_created, .surface_released),
            .queues = delta(.queue_acquired, .queue_released),
        };
    }
};

/// Count `handle` as an acquisition of kind `k` and pass it through. A null
/// handle is a failed create — no reference was taken, so nothing to release.
inline fn acquired(comptime k: lifetimes.Kind, handle: anytype) @TypeOf(handle) {
    if (handle != null) lifetimes.bump(k);
    return handle;
}

/// Count a release of kind `k`. Releasing a null handle is a no-op in wgpu and
/// must not move the counter, or the balance goes negative on the paths that
/// release unconditionally.
inline fn releasing(comptime k: lifetimes.Kind, handle: anytype) void {
    if (handle != null) lifetimes.bump(k);
}

// ============================================================================
// Enums
// ============================================================================

pub const BufferUsage = struct {
    pub const MapRead: u32 = c.WGPUBufferUsage_MapRead;
    pub const MapWrite: u32 = c.WGPUBufferUsage_MapWrite;
    pub const CopySrc: u32 = c.WGPUBufferUsage_CopySrc;
    pub const CopyDst: u32 = c.WGPUBufferUsage_CopyDst;
    pub const Index: u32 = c.WGPUBufferUsage_Index;
    pub const Vertex: u32 = c.WGPUBufferUsage_Vertex;
    pub const Uniform: u32 = c.WGPUBufferUsage_Uniform;
    pub const Storage: u32 = c.WGPUBufferUsage_Storage;
    pub const Indirect: u32 = c.WGPUBufferUsage_Indirect;
    pub const QueryResolve: u32 = c.WGPUBufferUsage_QueryResolve;
};

pub const TextureUsage = struct {
    pub const CopySrc: u32 = c.WGPUTextureUsage_CopySrc;
    pub const CopyDst: u32 = c.WGPUTextureUsage_CopyDst;
    pub const TextureBinding: u32 = c.WGPUTextureUsage_TextureBinding;
    pub const StorageBinding: u32 = c.WGPUTextureUsage_StorageBinding;
    pub const RenderAttachment: u32 = c.WGPUTextureUsage_RenderAttachment;
};

pub const LoadOp = enum(u32) {
    Undefined = c.WGPULoadOp_Undefined,
    Clear = c.WGPULoadOp_Clear,
    Load = c.WGPULoadOp_Load,
};

pub const StoreOp = enum(u32) {
    Undefined = c.WGPUStoreOp_Undefined,
    Store = c.WGPUStoreOp_Store,
    Discard = c.WGPUStoreOp_Discard,
};

// ============================================================================
// Instance Creation
// ============================================================================

pub fn createInstance(descriptor: ?*const c.WGPUInstanceDescriptor) Instance {
    return c.wgpuCreateInstance(descriptor);
}

// ============================================================================
// Adapter Request (Synchronous wrapper for v27+ API)
// ============================================================================

pub const AdapterRequestResult = struct {
    adapter: ?Adapter,
    status: c.WGPURequestAdapterStatus,
    message: ?[]const u8,
};

// Thread-local storage for async callback results
// Ensures thread-safety when multiple threads initialize adapters
threadlocal var adapter_result: AdapterRequestResult = undefined;
threadlocal var adapter_ready: bool = false;

fn adapterCallback(
    status: c.WGPURequestAdapterStatus,
    adapter: c.WGPUAdapter,
    message: c.WGPUStringView,
    _: ?*anyopaque, // userdata1
    _: ?*anyopaque, // userdata2
) callconv(.c) void {
    adapter_result = .{
        .adapter = adapter,
        .status = status,
        .message = if (message.data) |data| data[0..message.length] else null,
    };
    adapter_ready = true;
}

/// Request adapter synchronously (blocks until callback fires)
/// Uses wgpu-native v27+ callback info API with polling
pub fn requestAdapterSync(instance: Instance, options: ?*const c.WGPURequestAdapterOptions) AdapterRequestResult {
    adapter_ready = false;

    // Create callback info struct for v27+ API
    // Use AllowProcessEvents mode - compatible with iOS simulator
    const callback_info = c.WGPURequestAdapterCallbackInfo{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = adapterCallback,
        .userdata1 = null,
        .userdata2 = null,
    };

    // Request adapter - returns a future
    _ = c.wgpuInstanceRequestAdapter(instance, options, callback_info);

    // Poll until callback fires (with timeout)
    // This approach works on iOS simulator where WaitAny is not implemented
    const max_iterations: u32 = 5000; // ~5 seconds at 1ms per iteration
    for (0..max_iterations) |_| {
        // Process events which may trigger callbacks
        c.wgpuInstanceProcessEvents(instance);

        if (adapter_ready) {
            return adapter_result;
        }

        // Small sleep to avoid busy-waiting (1ms)
        // Use C nanosleep directly — std.time.sleep is unavailable on iOS
        const ts = std.c.timespec{ .sec = 0, .nsec = 1_000_000 };
        _ = std.c.nanosleep(&ts, null);
    }

    // Timeout - return error result
    return .{
        .adapter = null,
        .status = c.WGPURequestAdapterStatus_Error,
        .message = "Adapter request timed out",
    };
}

// ============================================================================
// Device Request (Synchronous wrapper for v27+ API)
// ============================================================================

pub const DeviceRequestResult = struct {
    device: ?Device,
    status: c.WGPURequestDeviceStatus,
    message: ?[]const u8,
};

// Thread-local storage for async callback results
threadlocal var device_result: DeviceRequestResult = undefined;
threadlocal var device_ready: bool = false;
threadlocal var device_instance: Instance = null; // Store instance for polling

fn deviceCallback(
    status: c.WGPURequestDeviceStatus,
    device: c.WGPUDevice,
    message: c.WGPUStringView,
    _: ?*anyopaque, // userdata1
    _: ?*anyopaque, // userdata2
) callconv(.c) void {
    device_result = .{
        .device = device,
        .status = status,
        .message = if (message.data) |data| data[0..message.length] else null,
    };
    device_ready = true;
}

/// Request device synchronously (blocks until callback fires)
/// Uses wgpu-native v27+ callback info API with polling
/// Note: Requires instance for polling
pub fn requestDeviceSync(instance: Instance, adapter: Adapter, descriptor: ?*const c.WGPUDeviceDescriptor) DeviceRequestResult {
    device_ready = false;
    device_instance = instance;

    // Create callback info struct for v27+ API
    // Use AllowProcessEvents mode - compatible with iOS simulator
    const callback_info = c.WGPURequestDeviceCallbackInfo{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = deviceCallback,
        .userdata1 = null,
        .userdata2 = null,
    };

    // Request device - returns a future
    _ = c.wgpuAdapterRequestDevice(adapter, descriptor, callback_info);

    // Poll until callback fires (with timeout)
    // This approach works on iOS simulator where WaitAny is not implemented
    const max_iterations: u32 = 5000; // ~5 seconds at 1ms per iteration
    for (0..max_iterations) |_| {
        // Process events which may trigger callbacks
        c.wgpuInstanceProcessEvents(instance);

        if (device_ready) {
            return device_result;
        }

        // Small sleep to avoid busy-waiting (1ms)
        // Use C nanosleep directly — std.time.sleep is unavailable on iOS
        const ts = std.c.timespec{ .sec = 0, .nsec = 1_000_000 };
        _ = std.c.nanosleep(&ts, null);
    }

    // Timeout - return error result
    return .{
        .device = null,
        .status = c.WGPURequestDeviceStatus_Error,
        .message = "Device request timed out",
    };
}

// ============================================================================
// Device Operations
// ============================================================================

/// Despite the name this ACQUIRES a reference (webgpu.h: "the caller owns the
/// returned queue and must release it"). Pair every call with `queueRelease`.
pub fn deviceGetQueue(device: Device) Queue {
    return acquired(.queue_acquired, c.wgpuDeviceGetQueue(device));
}

pub fn deviceCreateBuffer(device: Device, descriptor: *const c.WGPUBufferDescriptor) Buffer {
    return acquired(.buffer_created, c.wgpuDeviceCreateBuffer(device, descriptor));
}

pub fn deviceCreateTexture(device: Device, descriptor: *const c.WGPUTextureDescriptor) Texture {
    return acquired(.texture_created, c.wgpuDeviceCreateTexture(device, descriptor));
}

pub fn deviceCreateSampler(device: Device, descriptor: ?*const c.WGPUSamplerDescriptor) Sampler {
    return acquired(.sampler_created, c.wgpuDeviceCreateSampler(device, descriptor));
}

pub fn deviceCreateShaderModule(device: Device, descriptor: *const c.WGPUShaderModuleDescriptor) ShaderModule {
    return acquired(.shader_module_created, c.wgpuDeviceCreateShaderModule(device, descriptor));
}

pub fn deviceCreateBindGroupLayout(device: Device, descriptor: *const c.WGPUBindGroupLayoutDescriptor) BindGroupLayout {
    return acquired(.bgl_created, c.wgpuDeviceCreateBindGroupLayout(device, descriptor));
}

pub fn deviceCreatePipelineLayout(device: Device, descriptor: *const c.WGPUPipelineLayoutDescriptor) PipelineLayout {
    return acquired(.pipeline_layout_created, c.wgpuDeviceCreatePipelineLayout(device, descriptor));
}

pub fn deviceCreateRenderPipeline(device: Device, descriptor: *const c.WGPURenderPipelineDescriptor) RenderPipeline {
    return acquired(.render_pipeline_created, c.wgpuDeviceCreateRenderPipeline(device, descriptor));
}

pub fn deviceCreateComputePipeline(device: Device, descriptor: *const c.WGPUComputePipelineDescriptor) ComputePipeline {
    return acquired(.compute_pipeline_created, c.wgpuDeviceCreateComputePipeline(device, descriptor));
}

pub fn deviceCreateBindGroup(device: Device, descriptor: *const c.WGPUBindGroupDescriptor) BindGroup {
    return acquired(.bind_group_created, c.wgpuDeviceCreateBindGroup(device, descriptor));
}

pub fn deviceCreateCommandEncoder(device: Device, descriptor: ?*const c.WGPUCommandEncoderDescriptor) CommandEncoder {
    return acquired(.encoder_created, c.wgpuDeviceCreateCommandEncoder(device, descriptor));
}

// ============================================================================
// Texture Operations
// ============================================================================

pub fn textureCreateView(texture: Texture, descriptor: ?*const c.WGPUTextureViewDescriptor) TextureView {
    return acquired(.view_created, c.wgpuTextureCreateView(texture, descriptor));
}

pub fn textureDestroy(texture: Texture) void {
    c.wgpuTextureDestroy(texture);
}

pub fn textureRelease(texture: Texture) void {
    releasing(.texture_released, texture);
    c.wgpuTextureRelease(texture);
}

// ============================================================================
// Surface Operations
// ============================================================================

/// Create a surface from a platform-specific descriptor chain. The returned
/// handle is OWNED: whoever asks for it releases it (`surfaceRelease`).
///
/// Exists so surface creation is counted like every other reference. The four
/// per-platform call sites in `native_api.zig` used to call
/// `c.wgpuInstanceCreateSurface` directly, which is why nothing in the repo
/// could see that no code path ever released one.
pub fn instanceCreateSurface(instance: Instance, descriptor: *const c.WGPUSurfaceDescriptor) Surface {
    return acquired(.surface_created, c.wgpuInstanceCreateSurface(instance, descriptor));
}

/// Acquire the swapchain's texture for this frame. The returned
/// `texture.texture` is an OWNED reference — the caller must release it, even
/// on the suboptimal-status path where it is still usable, and even when the
/// only thing taken from it is a view (LEAK-01 A).
pub fn surfaceGetCurrentTexture(surface: Surface, texture: *SurfaceTexture) void {
    c.wgpuSurfaceGetCurrentTexture(surface, texture);
    _ = acquired(.surface_texture_acquired, texture.texture);
}

pub fn surfacePresent(surface: Surface) void {
    _ = c.wgpuSurfacePresent(surface);
}

pub fn surfaceConfigure(surface: Surface, config: *const c.WGPUSurfaceConfiguration) void {
    c.wgpuSurfaceConfigure(surface, config);
}

// ============================================================================
// Command Encoder Operations
// ============================================================================

pub fn commandEncoderBeginRenderPass(encoder: CommandEncoder, descriptor: *const c.WGPURenderPassDescriptor) RenderPassEncoder {
    return acquired(.render_pass_begun, c.wgpuCommandEncoderBeginRenderPass(encoder, descriptor));
}

pub fn commandEncoderBeginComputePass(encoder: CommandEncoder, descriptor: ?*const c.WGPUComputePassDescriptor) ComputePassEncoder {
    return acquired(.compute_pass_begun, c.wgpuCommandEncoderBeginComputePass(encoder, descriptor));
}

pub fn commandEncoderFinish(encoder: CommandEncoder, descriptor: ?*const c.WGPUCommandBufferDescriptor) CommandBuffer {
    return acquired(.command_buffer_created, c.wgpuCommandEncoderFinish(encoder, descriptor));
}

pub fn commandEncoderRelease(encoder: CommandEncoder) void {
    releasing(.encoder_released, encoder);
    c.wgpuCommandEncoderRelease(encoder);
}

// ============================================================================
// Render Pass Operations
// ============================================================================

pub fn renderPassEncoderSetPipeline(pass: RenderPassEncoder, pipeline: RenderPipeline) void {
    c.wgpuRenderPassEncoderSetPipeline(pass, pipeline);
}

pub fn renderPassEncoderSetBindGroup(pass: RenderPassEncoder, index: u32, group: BindGroup, dynamic_offsets: []const u32) void {
    c.wgpuRenderPassEncoderSetBindGroup(pass, index, group, dynamic_offsets.len, if (dynamic_offsets.len > 0) dynamic_offsets.ptr else null);
}

pub fn renderPassEncoderSetVertexBuffer(pass: RenderPassEncoder, slot: u32, buffer: Buffer, offset: u64, size: u64) void {
    c.wgpuRenderPassEncoderSetVertexBuffer(pass, slot, buffer, offset, size);
}

pub fn renderPassEncoderSetIndexBuffer(pass: RenderPassEncoder, buffer: Buffer, format: c.WGPUIndexFormat, offset: u64, size: u64) void {
    c.wgpuRenderPassEncoderSetIndexBuffer(pass, buffer, format, offset, size);
}

pub fn renderPassEncoderSetStencilReference(pass: RenderPassEncoder, reference: u32) void {
    c.wgpuRenderPassEncoderSetStencilReference(pass, reference);
}

pub fn renderPassEncoderSetBlendConstant(pass: RenderPassEncoder, color: *const c.WGPUColor) void {
    c.wgpuRenderPassEncoderSetBlendConstant(pass, color);
}

/// x/y/width/height are floats in WebGPU even though the bytecode carries them
/// as integer pixels; min/max depth are the only genuinely fractional fields.
pub fn renderPassEncoderSetViewport(pass: RenderPassEncoder, x: f32, y: f32, width: f32, height: f32, min_depth: f32, max_depth: f32) void {
    c.wgpuRenderPassEncoderSetViewport(pass, x, y, width, height, min_depth, max_depth);
}

pub fn renderPassEncoderSetScissorRect(pass: RenderPassEncoder, x: u32, y: u32, width: u32, height: u32) void {
    c.wgpuRenderPassEncoderSetScissorRect(pass, x, y, width, height);
}

pub fn renderPassEncoderDraw(pass: RenderPassEncoder, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
    c.wgpuRenderPassEncoderDraw(pass, vertex_count, instance_count, first_vertex, first_instance);
}

pub fn renderPassEncoderDrawIndexed(pass: RenderPassEncoder, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
    c.wgpuRenderPassEncoderDrawIndexed(pass, index_count, instance_count, first_index, base_vertex, first_instance);
}

pub fn renderPassEncoderDrawIndirect(pass: RenderPassEncoder, indirect_buffer: Buffer, indirect_offset: u64) void {
    c.wgpuRenderPassEncoderDrawIndirect(pass, indirect_buffer, indirect_offset);
}

pub fn renderPassEncoderDrawIndexedIndirect(pass: RenderPassEncoder, indirect_buffer: Buffer, indirect_offset: u64) void {
    c.wgpuRenderPassEncoderDrawIndexedIndirect(pass, indirect_buffer, indirect_offset);
}

pub fn renderPassEncoderEnd(pass: RenderPassEncoder) void {
    c.wgpuRenderPassEncoderEnd(pass);
}

pub fn renderPassEncoderRelease(pass: RenderPassEncoder) void {
    releasing(.render_pass_released, pass);
    c.wgpuRenderPassEncoderRelease(pass);
}

// ============================================================================
// Compute Pass Operations
// ============================================================================

pub fn computePassEncoderSetPipeline(pass: ComputePassEncoder, pipeline: ComputePipeline) void {
    c.wgpuComputePassEncoderSetPipeline(pass, pipeline);
}

pub fn computePassEncoderSetBindGroup(pass: ComputePassEncoder, index: u32, group: BindGroup, dynamic_offsets: []const u32) void {
    c.wgpuComputePassEncoderSetBindGroup(pass, index, group, dynamic_offsets.len, if (dynamic_offsets.len > 0) dynamic_offsets.ptr else null);
}

pub fn computePassEncoderDispatchWorkgroups(pass: ComputePassEncoder, x: u32, y: u32, z: u32) void {
    c.wgpuComputePassEncoderDispatchWorkgroups(pass, x, y, z);
}

pub fn computePassEncoderDispatchWorkgroupsIndirect(pass: ComputePassEncoder, indirect_buffer: Buffer, indirect_offset: u64) void {
    c.wgpuComputePassEncoderDispatchWorkgroupsIndirect(pass, indirect_buffer, indirect_offset);
}

pub fn computePassEncoderEnd(pass: ComputePassEncoder) void {
    c.wgpuComputePassEncoderEnd(pass);
}

pub fn computePassEncoderRelease(pass: ComputePassEncoder) void {
    releasing(.compute_pass_released, pass);
    c.wgpuComputePassEncoderRelease(pass);
}

// ============================================================================
// Queue Operations
// ============================================================================

pub fn queueSubmit(queue: Queue, commands: []const CommandBuffer) void {
    c.wgpuQueueSubmit(queue, @intCast(commands.len), if (commands.len > 0) commands.ptr else null);
}

pub fn queueWriteBuffer(queue: Queue, buffer: Buffer, offset: u64, data: []const u8) void {
    c.wgpuQueueWriteBuffer(queue, buffer, offset, data.ptr, data.len);
}

pub fn queueWriteTexture(queue: Queue, destination: *const c.WGPUImageCopyTexture, data: []const u8, data_layout: *const c.WGPUTextureDataLayout, write_size: *const c.WGPUExtent3D) void {
    c.wgpuQueueWriteTexture(queue, destination, data.ptr, data.len, data_layout, write_size);
}

// ============================================================================
// Buffer Operations
// ============================================================================

pub fn bufferDestroy(buffer: Buffer) void {
    c.wgpuBufferDestroy(buffer);
}

pub fn bufferRelease(buffer: Buffer) void {
    releasing(.buffer_released, buffer);
    c.wgpuBufferRelease(buffer);
}

pub fn bufferGetSize(buffer: Buffer) u64 {
    return c.wgpuBufferGetSize(buffer);
}

// ============================================================================
// Texture → Buffer Readback (offscreen render → CPU pixels)
// ============================================================================
//
// The CLI `--frame` path renders into an offscreen BGRA8Unorm texture, copies
// it into a MapRead buffer, and reads the mapped bytes back on the CPU. wgpu
// requires the copy's bytesPerRow to be a multiple of 256, so the caller pads
// per-row and unpads after mapping. These are the missing wrappers that path
// needs; the on-screen (surface) path never reads pixels back.

/// Poll the device, optionally blocking until queued work (and any pending map
/// callbacks) complete. Returns true while the queue is non-empty.
pub fn devicePoll(device: Device, wait: bool) bool {
    return c.wgpuDevicePoll(device, @intFromBool(wait), null) != 0;
}

/// Record a texture→buffer copy into an existing command encoder.
/// v27 names these `TexelCopy{Texture,Buffer}Info` (was `ImageCopy*`).
pub fn commandEncoderCopyTextureToBuffer(
    encoder: CommandEncoder,
    source: *const c.WGPUTexelCopyTextureInfo,
    destination: *const c.WGPUTexelCopyBufferInfo,
    copy_size: *const c.WGPUExtent3D,
) void {
    c.wgpuCommandEncoderCopyTextureToBuffer(encoder, source, destination, copy_size);
}

/// Record a texture→texture copy into an existing command encoder.
pub fn commandEncoderCopyTextureToTexture(
    encoder: CommandEncoder,
    source: *const c.WGPUTexelCopyTextureInfo,
    destination: *const c.WGPUTexelCopyTextureInfo,
    copy_size: *const c.WGPUExtent3D,
) void {
    c.wgpuCommandEncoderCopyTextureToTexture(encoder, source, destination, copy_size);
}

/// Record a buffer→buffer copy into an existing command encoder.
pub fn commandEncoderCopyBufferToBuffer(
    encoder: CommandEncoder,
    source: Buffer,
    source_offset: u64,
    destination: Buffer,
    destination_offset: u64,
    size: u64,
) void {
    c.wgpuCommandEncoderCopyBufferToBuffer(encoder, source, source_offset, destination, destination_offset, size);
}

/// Query a texture's dimensions. The bytecode's `copy_texture_to_texture`
/// carries only two ids — the extent has to come from the resources themselves.
pub fn textureGetWidth(texture: Texture) u32 {
    return c.wgpuTextureGetWidth(texture);
}

pub fn textureGetHeight(texture: Texture) u32 {
    return c.wgpuTextureGetHeight(texture);
}

/// Return a read-only pointer into a mapped buffer's range (null on failure).
pub fn bufferGetConstMappedRange(buffer: Buffer, offset: usize, size: usize) ?*const anyopaque {
    return c.wgpuBufferGetConstMappedRange(buffer, offset, size);
}

/// Unmap a previously mapped buffer.
pub fn bufferUnmap(buffer: Buffer) void {
    c.wgpuBufferUnmap(buffer);
}

// Map-callback result storage (threadlocal, mirrors the adapter/device sync
// wrappers above so concurrent readbacks on different threads stay isolated).
threadlocal var map_status: c.WGPUMapAsyncStatus = c.WGPUMapAsyncStatus_Unknown;
threadlocal var map_ready: bool = false;

fn mapCallback(
    status: c.WGPUMapAsyncStatus,
    _: c.WGPUStringView, // message
    _: ?*anyopaque, // userdata1
    _: ?*anyopaque, // userdata2
) callconv(.c) void {
    map_status = status;
    map_ready = true;
}

/// Map a buffer for reading, blocking until the callback fires. wgpu-native
/// services map callbacks from the DEVICE poll (not `wgpuInstanceProcessEvents`
/// alone), so this loop drives both — `wgpuDevicePoll(wait=true)` blocks until
/// the preceding copy submit completes and the map is ready. Bounded at
/// 5000×1ms (~5s) like the adapter/device waits. Returns true on success.
pub fn bufferMapReadSync(instance: Instance, device: Device, buffer: Buffer, size: usize) bool {
    map_ready = false;
    map_status = c.WGPUMapAsyncStatus_Unknown;

    const callback_info = c.WGPUBufferMapCallbackInfo{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = mapCallback,
        .userdata1 = null,
        .userdata2 = null,
    };

    _ = c.wgpuBufferMapAsync(buffer, c.WGPUMapMode_Read, 0, size, callback_info);

    const max_iterations: u32 = 5000; // ~5 seconds at 1ms per iteration
    for (0..max_iterations) |_| {
        // wait=true drains the queue AND any ready map callbacks in one call.
        _ = c.wgpuDevicePoll(device, 1, null);
        c.wgpuInstanceProcessEvents(instance);

        if (map_ready) {
            return map_status == c.WGPUMapAsyncStatus_Success;
        }

        const ts = std.c.timespec{ .sec = 0, .nsec = 1_000_000 };
        _ = std.c.nanosleep(&ts, null);
    }

    return false; // timed out
}

// ============================================================================
// Release Functions
// ============================================================================

pub fn shaderModuleRelease(module: ShaderModule) void {
    releasing(.shader_module_released, module);
    c.wgpuShaderModuleRelease(module);
}

pub fn renderPipelineRelease(pipeline: RenderPipeline) void {
    releasing(.render_pipeline_released, pipeline);
    c.wgpuRenderPipelineRelease(pipeline);
}

pub fn renderPipelineGetBindGroupLayout(pipeline: RenderPipeline, group_index: u32) BindGroupLayout {
    return acquired(.bgl_derived, c.wgpuRenderPipelineGetBindGroupLayout(pipeline, group_index));
}

pub fn computePipelineRelease(pipeline: ComputePipeline) void {
    releasing(.compute_pipeline_released, pipeline);
    c.wgpuComputePipelineRelease(pipeline);
}

pub fn computePipelineGetBindGroupLayout(pipeline: ComputePipeline, group_index: u32) BindGroupLayout {
    return acquired(.bgl_derived, c.wgpuComputePipelineGetBindGroupLayout(pipeline, group_index));
}

pub fn bindGroupRelease(group: BindGroup) void {
    releasing(.bind_group_released, group);
    c.wgpuBindGroupRelease(group);
}

pub fn bindGroupLayoutRelease(layout: BindGroupLayout) void {
    releasing(.bgl_released, layout);
    c.wgpuBindGroupLayoutRelease(layout);
}

pub fn pipelineLayoutRelease(layout: PipelineLayout) void {
    releasing(.pipeline_layout_released, layout);
    c.wgpuPipelineLayoutRelease(layout);
}

pub fn samplerRelease(sampler: Sampler) void {
    releasing(.sampler_released, sampler);
    c.wgpuSamplerRelease(sampler);
}

pub fn textureViewRelease(view: TextureView) void {
    releasing(.view_released, view);
    c.wgpuTextureViewRelease(view);
}

pub fn commandBufferRelease(buffer: CommandBuffer) void {
    releasing(.command_buffer_released, buffer);
    c.wgpuCommandBufferRelease(buffer);
}

pub fn instanceRelease(instance: Instance) void {
    c.wgpuInstanceRelease(instance);
}

pub fn adapterRelease(adapter: Adapter) void {
    c.wgpuAdapterRelease(adapter);
}

pub fn deviceRelease(device: Device) void {
    c.wgpuDeviceRelease(device);
}

pub fn surfaceRelease(surface: Surface) void {
    releasing(.surface_released, surface);
    c.wgpuSurfaceRelease(surface);
}

pub fn queueRelease(queue: Queue) void {
    releasing(.queue_released, queue);
    c.wgpuQueueRelease(queue);
}

// ============================================================================
// Helper: Map bytecode usage flags to wgpu usage
// ============================================================================

/// Map PNGine bytecode buffer usage flags to wgpu BufferUsage.
/// Bytecode uses compact 16-bit flags, wgpu uses 32-bit flags.
pub fn mapBufferUsage(bytecode_usage: u16) u32 {
    var result: u32 = 0;

    // Bytecode flag mapping (from types/opcodes.zig):
    // bit 0: MAP_READ, bit 1: MAP_WRITE, bit 2: COPY_SRC, bit 3: COPY_DST
    // bit 4: INDEX, bit 5: VERTEX, bit 6: UNIFORM, bit 7: STORAGE
    // bit 8: INDIRECT
    if (bytecode_usage & 0x01 != 0) result |= BufferUsage.MapRead;
    if (bytecode_usage & 0x02 != 0) result |= BufferUsage.MapWrite;
    if (bytecode_usage & 0x04 != 0) result |= BufferUsage.CopySrc;
    if (bytecode_usage & 0x08 != 0) result |= BufferUsage.CopyDst;
    if (bytecode_usage & 0x10 != 0) result |= BufferUsage.Index;
    if (bytecode_usage & 0x20 != 0) result |= BufferUsage.Vertex;
    if (bytecode_usage & 0x40 != 0) result |= BufferUsage.Uniform;
    if (bytecode_usage & 0x80 != 0) result |= BufferUsage.Storage;
    if (bytecode_usage & 0x100 != 0) result |= BufferUsage.Indirect;

    return result;
}

/// Map PNGine bytecode load op to wgpu LoadOp.
/// Bytecode encoding: 0=load, 1=clear (from types/opcodes.zig)
pub fn mapLoadOp(bytecode_op: u8) LoadOp {
    return switch (bytecode_op) {
        0 => .Load,
        1 => .Clear,
        else => .Clear, // Default to clear for safety
    };
}

/// Map PNGine bytecode store op to wgpu StoreOp.
/// Bytecode encoding: 0=store, 1=discard (from types/opcodes.zig)
pub fn mapStoreOp(bytecode_op: u8) StoreOp {
    return switch (bytecode_op) {
        0 => .Store,
        1 => .Discard,
        else => .Store, // Default to store for safety
    };
}
