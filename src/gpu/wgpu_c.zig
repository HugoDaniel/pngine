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

// Import the C headers
pub const c = @cImport({
    @cInclude("webgpu.h");
    @cInclude("wgpu.h");
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

var adapter_result: AdapterRequestResult = undefined;
var adapter_ready: bool = false;

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
        std.posix.nanosleep(0, 1_000_000);
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

var device_result: DeviceRequestResult = undefined;
var device_ready: bool = false;
var device_instance: Instance = null; // Store instance for wait call

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
        std.posix.nanosleep(0, 1_000_000);
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

pub fn deviceGetQueue(device: Device) Queue {
    return c.wgpuDeviceGetQueue(device);
}

pub fn deviceCreateBuffer(device: Device, descriptor: *const c.WGPUBufferDescriptor) Buffer {
    return c.wgpuDeviceCreateBuffer(device, descriptor);
}

pub fn deviceCreateTexture(device: Device, descriptor: *const c.WGPUTextureDescriptor) Texture {
    return c.wgpuDeviceCreateTexture(device, descriptor);
}

pub fn deviceCreateSampler(device: Device, descriptor: ?*const c.WGPUSamplerDescriptor) Sampler {
    return c.wgpuDeviceCreateSampler(device, descriptor);
}

pub fn deviceCreateShaderModule(device: Device, descriptor: *const c.WGPUShaderModuleDescriptor) ShaderModule {
    return c.wgpuDeviceCreateShaderModule(device, descriptor);
}

pub fn deviceCreateBindGroupLayout(device: Device, descriptor: *const c.WGPUBindGroupLayoutDescriptor) BindGroupLayout {
    return c.wgpuDeviceCreateBindGroupLayout(device, descriptor);
}

pub fn deviceCreatePipelineLayout(device: Device, descriptor: *const c.WGPUPipelineLayoutDescriptor) PipelineLayout {
    return c.wgpuDeviceCreatePipelineLayout(device, descriptor);
}

pub fn deviceCreateRenderPipeline(device: Device, descriptor: *const c.WGPURenderPipelineDescriptor) RenderPipeline {
    return c.wgpuDeviceCreateRenderPipeline(device, descriptor);
}

pub fn deviceCreateComputePipeline(device: Device, descriptor: *const c.WGPUComputePipelineDescriptor) ComputePipeline {
    return c.wgpuDeviceCreateComputePipeline(device, descriptor);
}

pub fn deviceCreateBindGroup(device: Device, descriptor: *const c.WGPUBindGroupDescriptor) BindGroup {
    return c.wgpuDeviceCreateBindGroup(device, descriptor);
}

pub fn deviceCreateCommandEncoder(device: Device, descriptor: ?*const c.WGPUCommandEncoderDescriptor) CommandEncoder {
    return c.wgpuDeviceCreateCommandEncoder(device, descriptor);
}

// ============================================================================
// Texture Operations
// ============================================================================

pub fn textureCreateView(texture: Texture, descriptor: ?*const c.WGPUTextureViewDescriptor) TextureView {
    return c.wgpuTextureCreateView(texture, descriptor);
}

pub fn textureDestroy(texture: Texture) void {
    c.wgpuTextureDestroy(texture);
}

pub fn textureRelease(texture: Texture) void {
    c.wgpuTextureRelease(texture);
}

// ============================================================================
// Surface Operations
// ============================================================================

pub fn surfaceGetCurrentTexture(surface: Surface, texture: *SurfaceTexture) void {
    c.wgpuSurfaceGetCurrentTexture(surface, texture);
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
    return c.wgpuCommandEncoderBeginRenderPass(encoder, descriptor);
}

pub fn commandEncoderBeginComputePass(encoder: CommandEncoder, descriptor: ?*const c.WGPUComputePassDescriptor) ComputePassEncoder {
    return c.wgpuCommandEncoderBeginComputePass(encoder, descriptor);
}

pub fn commandEncoderFinish(encoder: CommandEncoder, descriptor: ?*const c.WGPUCommandBufferDescriptor) CommandBuffer {
    return c.wgpuCommandEncoderFinish(encoder, descriptor);
}

pub fn commandEncoderRelease(encoder: CommandEncoder) void {
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

pub fn renderPassEncoderDraw(pass: RenderPassEncoder, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
    c.wgpuRenderPassEncoderDraw(pass, vertex_count, instance_count, first_vertex, first_instance);
}

pub fn renderPassEncoderDrawIndexed(pass: RenderPassEncoder, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
    c.wgpuRenderPassEncoderDrawIndexed(pass, index_count, instance_count, first_index, base_vertex, first_instance);
}

pub fn renderPassEncoderEnd(pass: RenderPassEncoder) void {
    c.wgpuRenderPassEncoderEnd(pass);
}

pub fn renderPassEncoderRelease(pass: RenderPassEncoder) void {
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

pub fn computePassEncoderEnd(pass: ComputePassEncoder) void {
    c.wgpuComputePassEncoderEnd(pass);
}

pub fn computePassEncoderRelease(pass: ComputePassEncoder) void {
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
    c.wgpuBufferRelease(buffer);
}

pub fn bufferGetSize(buffer: Buffer) u64 {
    return c.wgpuBufferGetSize(buffer);
}

// ============================================================================
// Release Functions
// ============================================================================

pub fn shaderModuleRelease(module: ShaderModule) void {
    c.wgpuShaderModuleRelease(module);
}

pub fn renderPipelineRelease(pipeline: RenderPipeline) void {
    c.wgpuRenderPipelineRelease(pipeline);
}

pub fn computePipelineRelease(pipeline: ComputePipeline) void {
    c.wgpuComputePipelineRelease(pipeline);
}

pub fn bindGroupRelease(group: BindGroup) void {
    c.wgpuBindGroupRelease(group);
}

pub fn bindGroupLayoutRelease(layout: BindGroupLayout) void {
    c.wgpuBindGroupLayoutRelease(layout);
}

pub fn pipelineLayoutRelease(layout: PipelineLayout) void {
    c.wgpuPipelineLayoutRelease(layout);
}

pub fn samplerRelease(sampler: Sampler) void {
    c.wgpuSamplerRelease(sampler);
}

pub fn textureViewRelease(view: TextureView) void {
    c.wgpuTextureViewRelease(view);
}

pub fn commandBufferRelease(buffer: CommandBuffer) void {
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
    c.wgpuSurfaceRelease(surface);
}

// ============================================================================
// Helper: Map bytecode usage flags to wgpu usage
// ============================================================================

/// Map PNGine bytecode buffer usage flags to wgpu BufferUsage.
/// Bytecode uses compact 8-bit flags, wgpu uses 32-bit flags.
pub fn mapBufferUsage(bytecode_usage: u8) u32 {
    var result: u32 = 0;

    // Bytecode flag mapping (from bytecode/opcodes.zig):
    // bit 0: MAP_READ, bit 1: MAP_WRITE, bit 2: COPY_SRC, bit 3: COPY_DST
    // bit 4: INDEX, bit 5: VERTEX, bit 6: UNIFORM, bit 7: STORAGE
    if (bytecode_usage & 0x01 != 0) result |= BufferUsage.MapRead;
    if (bytecode_usage & 0x02 != 0) result |= BufferUsage.MapWrite;
    if (bytecode_usage & 0x04 != 0) result |= BufferUsage.CopySrc;
    if (bytecode_usage & 0x08 != 0) result |= BufferUsage.CopyDst;
    if (bytecode_usage & 0x10 != 0) result |= BufferUsage.Index;
    if (bytecode_usage & 0x20 != 0) result |= BufferUsage.Vertex;
    if (bytecode_usage & 0x40 != 0) result |= BufferUsage.Uniform;
    if (bytecode_usage & 0x80 != 0) result |= BufferUsage.Storage;

    return result;
}

/// Map PNGine bytecode load op to wgpu LoadOp.
pub fn mapLoadOp(bytecode_op: u8) LoadOp {
    return switch (bytecode_op) {
        0 => .Undefined,
        1 => .Clear,
        2 => .Load,
        else => .Undefined,
    };
}

/// Map PNGine bytecode store op to wgpu StoreOp.
pub fn mapStoreOp(bytecode_op: u8) StoreOp {
    return switch (bytecode_op) {
        0 => .Undefined,
        1 => .Store,
        2 => .Discard,
        else => .Undefined,
    };
}
