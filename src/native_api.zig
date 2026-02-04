//! PNGine Native C API
//!
//! Exports C functions for platform bindings (iOS, Android, macOS, Windows, Linux).
//! This is the FFI boundary between Zig core and platform-specific code.
//!
//! ## Usage from C/Swift/Kotlin
//!
//! ```c
//! #include "pngine.h"
//!
//! // Initialize once at app startup
//! pngine_init();
//!
//! // Set error callback (optional)
//! pngine_set_error_callback(my_handler, user_data);
//!
//! // Create animation from bytecode
//! PngineAnimation* anim = pngine_create(bytecode, len, surface_handle);
//!
//! // Render frames
//! PngineError err = pngine_render(anim, time);
//! if (err != PNGINE_OK) { /* handle error */ }
//!
//! // Cleanup
//! pngine_destroy(anim);
//! pngine_shutdown();
//! ```
//!
//! ## Thread Safety
//!
//! - pngine_init/shutdown must be called from main thread
//! - Each PngineAnimation should only be used from one thread
//! - Multiple animations can exist concurrently on different threads
//! - Error callback may be invoked from any thread

const std = @import("std");
const assert = std.debug.assert;

const wgpu_native = @import("executor/wgpu_native_gpu.zig");
const Context = wgpu_native.Context;
const WgpuNativeGPU = wgpu_native.WgpuNativeGPU;

const bytecode_mod = @import("bytecode");
const format = bytecode_mod.format;
const Module = format.Module;

const wgpu = @import("gpu/wgpu_c.zig");
const c = wgpu.c;

// ============================================================================
// Error Codes (match pngine.h PngineError enum)
// ============================================================================

pub const PngineError = enum(c_int) {
    ok = 0,
    not_initialized = -1,
    already_initialized = -2,
    context_failed = -3,
    bytecode_invalid = -4,
    surface_failed = -5,
    shader_compile = -6,
    pipeline_create = -7,
    texture_unavail = -8,
    resource_not_found = -9,
    out_of_memory = -10,
    invalid_argument = -11,
    render_failed = -12,
    compute_failed = -13,
};

// ============================================================================
// Error Callback
// ============================================================================

/// Error callback function type (matches C definition)
const ErrorCallback = *const fn (PngineError, [*:0]const u8, ?*PngineAnimation, ?*anyopaque) callconv(.c) void;

/// Thread-safe error callback storage
var error_callback: ?ErrorCallback = null;
var error_callback_user_data: ?*anyopaque = null;

/// Report an error via callback (if set)
fn reportError(err: PngineError, message: [*:0]const u8, anim: ?*PngineAnimation) void {
    if (error_callback) |cb| {
        cb(err, message, anim, error_callback_user_data);
    }
}

// ============================================================================
// Per-Animation Diagnostics
// ============================================================================

/// Diagnostics tracked per animation (thread-safe via per-animation isolation)
pub const AnimDiagnostics = struct {
    /// Last error that occurred
    last_error: PngineError = .ok,

    /// Compute pass statistics (reset each frame or on demand)
    compute_passes: u32 = 0,
    compute_pipelines: u32 = 0,
    bind_groups: u32 = 0,
    dispatches: u32 = 0,

    /// Render pass statistics
    render_passes: u32 = 0,
    draws: u32 = 0,

    /// Total frames rendered
    frame_count: u32 = 0,

    /// Pack compute counters into u32: [passes:8][pipelines:8][bindgroups:8][dispatches:8]
    pub fn packComputeCounters(self: *const AnimDiagnostics) u32 {
        return (@as(u32, self.compute_passes & 0xFF) << 24) |
            (@as(u32, self.compute_pipelines & 0xFF) << 16) |
            (@as(u32, self.bind_groups & 0xFF) << 8) |
            @as(u32, self.dispatches & 0xFF);
    }

    /// Pack render counters into u32: [passes:16][draws:16]
    pub fn packRenderCounters(self: *const AnimDiagnostics) u32 {
        return (@as(u32, self.render_passes & 0xFFFF) << 16) |
            @as(u32, self.draws & 0xFFFF);
    }

    /// Reset all counters (except frame_count and last_error)
    pub fn resetCounters(self: *AnimDiagnostics) void {
        self.compute_passes = 0;
        self.compute_pipelines = 0;
        self.bind_groups = 0;
        self.dispatches = 0;
        self.render_passes = 0;
        self.draws = 0;
    }
};

// ============================================================================
// Global State
// ============================================================================

var global_context: ?Context = null;
var global_allocator: std.mem.Allocator = std.heap.page_allocator;

// ============================================================================
// Animation Handle
// ============================================================================

/// Opaque animation handle exposed to C.
pub const PngineAnimation = struct {
    gpu: WgpuNativeGPU,
    module: Module,
    dispatcher: wgpu_native.NativeDispatcher,
    width: u32,
    height: u32,

    /// Per-animation diagnostics (thread-safe by design - each anim on one thread)
    diag: AnimDiagnostics = .{},
};

// ============================================================================
// C API Exports
// ============================================================================

/// Initialize the PNGine runtime.
/// Call once at application startup.
/// Returns 0 on success, non-zero on failure.
export fn pngine_init() callconv(.c) c_int {
    if (global_context != null) {
        return 0; // Already initialized
    }

    global_context = Context.init() catch {
        return -1;
    };

    return 0;
}

/// Shutdown the PNGine runtime.
/// Call once at application shutdown.
export fn pngine_shutdown() callconv(.c) void {
    if (global_context) |*ctx| {
        ctx.deinit();
        global_context = null;
    }
}

/// Notify runtime of memory pressure.
/// Clears caches and releases non-essential resources.
export fn pngine_memory_warning() callconv(.c) void {
    // TODO: Implement cache clearing
}

// ============================================================================
// Error Handling Exports
// ============================================================================

/// Set the error callback for receiving error notifications.
export fn pngine_set_error_callback(
    callback: ?ErrorCallback,
    user_data: ?*anyopaque,
) callconv(.c) void {
    error_callback = callback;
    error_callback_user_data = user_data;
}

/// Get human-readable error message for an error code.
export fn pngine_error_string(err: PngineError) callconv(.c) [*:0]const u8 {
    return switch (err) {
        .ok => "Success",
        .not_initialized => "PNGine not initialized - call pngine_init() first",
        .already_initialized => "PNGine already initialized",
        .context_failed => "GPU context creation failed",
        .bytecode_invalid => "Invalid bytecode format",
        .surface_failed => "Surface creation failed",
        .shader_compile => "Shader compilation failed",
        .pipeline_create => "Pipeline creation failed",
        .texture_unavail => "Surface texture unavailable",
        .resource_not_found => "Resource ID not found",
        .out_of_memory => "Out of memory",
        .invalid_argument => "Invalid argument",
        .render_failed => "Render pass failed",
        .compute_failed => "Compute pass failed",
    };
}

/// Create an animation from bytecode.
///
/// Parameters:
/// - bytecode: Pointer to PNGB bytecode data
/// - bytecode_len: Length of bytecode in bytes
/// - surface_handle: Platform-specific surface handle
///   - iOS: CAMetalLayer*
///   - Android: ANativeWindow*
///   - macOS: CAMetalLayer* or NSView*
///   - Windows: HWND
///   - Linux: X11 Window or wl_surface*
/// - width: Surface width in pixels
/// - height: Surface height in pixels
///
/// Returns: Animation handle, or NULL on failure.
export fn pngine_create(
    bytecode: [*]const u8,
    bytecode_len: usize,
    surface_handle: ?*anyopaque,
    width: u32,
    height: u32,
) callconv(.c) ?*PngineAnimation {
    const ctx = &(global_context orelse return null);

    // Create surface from platform handle
    var surface: ?wgpu.Surface = null;
    if (surface_handle) |handle| {
        surface = createSurfaceFromHandle(ctx.instance, handle);
    }

    // Allocate animation
    const anim = global_allocator.create(PngineAnimation) catch return null;
    errdefer global_allocator.destroy(anim);

    // Parse bytecode using format.deserialize
    const bytecode_slice = bytecode[0..bytecode_len];
    anim.module = format.deserialize(global_allocator, bytecode_slice) catch {
        return null;
    };

    // Initialize GPU backend
    anim.gpu = WgpuNativeGPU.init(ctx, surface, width, height);
    anim.gpu.setModule(&anim.module);

    // Initialize dispatcher
    anim.dispatcher = wgpu_native.NativeDispatcher.init(global_allocator, &anim.gpu, &anim.module);

    anim.width = width;
    anim.height = height;

    return anim;
}

/// Render a frame at the specified time.
///
/// Parameters:
/// - anim: Animation handle
/// - time: Time in seconds since animation start
///
/// Returns: PNGINE_OK on success, error code on failure.
export fn pngine_render(anim: ?*PngineAnimation, time: f32) callconv(.c) PngineError {
    const a = anim orelse {
        reportError(.invalid_argument, "pngine_render: null animation handle", null);
        return .invalid_argument;
    };

    a.gpu.setTime(time);

    // Execute bytecode for this frame
    // Reset PC to beginning and execute all bytecode
    // Note: frame_counter is incremented by end_frame opcode, not here
    a.dispatcher.pc = 0;
    a.dispatcher.execute_from_pc(global_allocator) catch |err| {
        const pngine_err: PngineError = switch (err) {
            error.SurfaceTextureUnavailable => .texture_unavail,
            error.NoSurfaceConfigured => .surface_failed,
            error.TextureNotFound => .resource_not_found,
            error.InvalidResourceId => .resource_not_found,
            error.ShaderCompilationFailed => .shader_compile,
            error.PipelineCreationFailed => .pipeline_create,
            else => .render_failed,
        };

        a.diag.last_error = pngine_err;
        reportError(pngine_err, pngine_error_string(pngine_err), a);
        return pngine_err;
    };

    // Update diagnostics
    a.diag.frame_count +%= 1;
    a.diag.last_error = .ok;

    return .ok;
}

/// Resize the animation surface.
///
/// Parameters:
/// - anim: Animation handle
/// - width: New width in pixels
/// - height: New height in pixels
export fn pngine_resize(anim: ?*PngineAnimation, width: u32, height: u32) callconv(.c) void {
    const a = anim orelse return;

    a.width = width;
    a.height = height;
    a.gpu.width = width;
    a.gpu.height = height;

    // Reconfigure surface if present
    if (a.gpu.surface) |surface| {
        const ctx = a.gpu.ctx;
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
        wgpu.surfaceConfigure(surface, &config);
    }
}

/// Destroy an animation and release its resources.
///
/// Parameters:
/// - anim: Animation handle
export fn pngine_destroy(anim: ?*PngineAnimation) callconv(.c) void {
    const a = anim orelse return;

    a.gpu.deinit();
    a.module.deinit(global_allocator);
    global_allocator.destroy(a);
}

// Global error state for debugging
var last_error: ?[]const u8 = null;

/// Get the last error message.
/// Returns NULL if no error.
export fn pngine_get_error() callconv(.c) ?[*:0]const u8 {
    if (last_error) |err| {
        // Find null terminator or return the slice
        for (err, 0..) |ch, i| {
            if (ch == 0) return @ptrCast(err.ptr);
            _ = i;
        }
    }
    return null;
}

/// Debug: Get animation status
export fn pngine_debug_status(anim: ?*PngineAnimation) callconv(.c) c_int {
    const a = anim orelse return -1; // No animation

    if (a.gpu.surface == null) return -2; // No surface
    if (a.gpu.ctx.device == null) return -3; // No device

    // Check if pipeline was created
    if (a.gpu.render_pipelines[0] == null) return -4; // No pipeline

    // Check if shader was created
    if (a.gpu.shaders[0] == null) return -5; // No shader

    return 0; // All good
}

/// Debug: Execute one frame and return status
export fn pngine_debug_frame(anim: ?*PngineAnimation, time: f32) callconv(.c) c_int {
    const a = anim orelse return -1;

    a.gpu.setTime(time);

    // Reset PC and execute
    a.dispatcher.pc = 0;
    a.dispatcher.frame_counter +%= 1;

    a.dispatcher.execute_from_pc(global_allocator) catch |err| {
        return switch (err) {
            error.SurfaceTextureUnavailable => -10,
            error.NoSurfaceConfigured => -11,
            error.TextureNotFound => -12,
            error.InvalidResourceId => -13,
            error.ShaderCompilationFailed => -14,
            error.PipelineCreationFailed => -15,
            else => -99,
        };
    };

    return 0;
}

/// Debug: Get render pass status after frame execution
export fn pngine_debug_render_pass_status(anim: ?*PngineAnimation) callconv(.c) c_int {
    const a = anim orelse return -1;

    // Check if we have encoder/pass state (should be null after submit)
    if (a.gpu.encoder != null) return 1; // Encoder still active
    if (a.gpu.render_pass != null) return 2; // Pass still active

    return 0; // All cleaned up properly
}

/// Debug: Get compute counters packed into u32
/// Format: [passes:8][pipelines:8][bindgroups:8][dispatches:8]
/// Use this to diagnose compute shader issues.
export fn pngine_debug_compute_counters() callconv(.c) u32 {
    return wgpu_native.getDebugCounters();
}

/// Debug: Get render counters packed into u32
/// Format: [render_passes:16][draws:16]
export fn pngine_debug_render_counters() callconv(.c) u32 {
    return wgpu_native.getRenderCounters();
}

/// Debug: Get buffer IDs for compute/render comparison
/// Format: [last_vertex_buffer_id:16][last_storage_bind_buffer_id:16]
/// Use this to diagnose buffer mismatch issues between compute and render.
export fn pngine_debug_buffer_ids() callconv(.c) u32 {
    return wgpu_native.getBufferIds();
}

/// Debug: Get first-frame buffer IDs (only set once per session)
/// Format: [first_vertex_buffer_id:16][first_storage_bind_buffer_id:16]
export fn pngine_debug_first_buffer_ids() callconv(.c) u32 {
    return wgpu_native.getFirstBufferIds();
}

/// Debug: Get buffer 0 size
export fn pngine_debug_buffer_0_size() callconv(.c) u32 {
    return wgpu_native.getBuffer0Size();
}

/// Debug: Get dispatch X (workgroup count)
export fn pngine_debug_dispatch_x() callconv(.c) u32 {
    return wgpu_native.getDispatchX();
}

/// Debug: Get draw info packed into u32
/// Format: [vertex_count:16][instance_count:16]
export fn pngine_debug_draw_info() callconv(.c) u32 {
    return wgpu_native.getDrawInfo();
}

// ============================================================================
// Platform-Specific Surface Creation
// ============================================================================

fn createSurfaceFromHandle(instance: wgpu.Instance, handle: *anyopaque) ?wgpu.Surface {
    // Detect platform at compile time
    const target = @import("builtin").target;

    if (target.os.tag == .macos or target.os.tag == .ios) {
        // Metal surface from CAMetalLayer
        const metal_desc = c.WGPUSurfaceSourceMetalLayer{
            .chain = .{
                .next = null,
                .sType = c.WGPUSType_SurfaceSourceMetalLayer,
            },
            .layer = handle,
        };

        const surface_desc = c.WGPUSurfaceDescriptor{
            .nextInChain = @ptrCast(&metal_desc),
            .label = .{ .data = null, .length = 0 },
        };

        return c.wgpuInstanceCreateSurface(instance, &surface_desc);
    } else if (target.os.tag == .windows) {
        // Windows surface from HWND
        const windows_desc = c.WGPUSurfaceSourceWindowsHWND{
            .chain = .{
                .next = null,
                .sType = c.WGPUSType_SurfaceSourceWindowsHWND,
            },
            .hinstance = null, // Use default
            .hwnd = handle,
        };

        const surface_desc = c.WGPUSurfaceDescriptor{
            .nextInChain = @ptrCast(&windows_desc),
            .label = .{ .data = null, .length = 0 },
        };

        return c.wgpuInstanceCreateSurface(instance, &surface_desc);
    } else if (target.os.tag == .linux) {
        // X11 or Wayland - for now assume X11
        // TODO: Add Wayland support
        const x11_desc = c.WGPUSurfaceSourceXlibWindow{
            .chain = .{
                .next = null,
                .sType = c.WGPUSType_SurfaceSourceXlibWindow,
            },
            .display = null, // Use default
            .window = @intFromPtr(handle),
        };

        const surface_desc = c.WGPUSurfaceDescriptor{
            .nextInChain = @ptrCast(&x11_desc),
            .label = .{ .data = null, .length = 0 },
        };

        return c.wgpuInstanceCreateSurface(instance, &surface_desc);
    } else if (target.os.tag == .android) {
        // Android surface from ANativeWindow
        const android_desc = c.WGPUSurfaceSourceAndroidNativeWindow{
            .chain = .{
                .next = null,
                .sType = c.WGPUSType_SurfaceSourceAndroidNativeWindow,
            },
            .window = handle,
        };

        const surface_desc = c.WGPUSurfaceDescriptor{
            .nextInChain = @ptrCast(&android_desc),
            .label = .{ .data = null, .length = 0 },
        };

        return c.wgpuInstanceCreateSurface(instance, &surface_desc);
    }

    return null;
}

// ============================================================================
// Additional Utility Exports
// ============================================================================

/// Get animation dimensions.
export fn pngine_get_width(anim: ?*PngineAnimation) callconv(.c) u32 {
    const a = anim orelse return 0;
    return a.width;
}

export fn pngine_get_height(anim: ?*PngineAnimation) callconv(.c) u32 {
    const a = anim orelse return 0;
    return a.height;
}

/// Check if PNGine is initialized.
export fn pngine_is_initialized() callconv(.c) bool {
    return global_context != null;
}

/// Get PNGine version string.
export fn pngine_version() callconv(.c) [*:0]const u8 {
    return "0.1.0";
}

// ============================================================================
// Per-Animation Diagnostics Exports
// ============================================================================

/// Get last error for a specific animation.
export fn pngine_anim_get_last_error(anim: ?*PngineAnimation) callconv(.c) PngineError {
    const a = anim orelse return .invalid_argument;
    return a.diag.last_error;
}

/// Get compute counters for a specific animation.
/// Format: [passes:8][pipelines:8][bindgroups:8][dispatches:8]
export fn pngine_anim_compute_counters(anim: ?*PngineAnimation) callconv(.c) u32 {
    const a = anim orelse return 0;
    return a.diag.packComputeCounters();
}

/// Get render counters for a specific animation.
/// Format: [render_passes:16][draws:16]
export fn pngine_anim_render_counters(anim: ?*PngineAnimation) callconv(.c) u32 {
    const a = anim orelse return 0;
    return a.diag.packRenderCounters();
}

/// Get total frame count for a specific animation.
export fn pngine_anim_frame_count(anim: ?*PngineAnimation) callconv(.c) u32 {
    const a = anim orelse return 0;
    return a.diag.frame_count;
}

/// Reset diagnostics counters for an animation.
export fn pngine_anim_reset_counters(anim: ?*PngineAnimation) callconv(.c) void {
    const a = anim orelse return;
    a.diag.resetCounters();
}
