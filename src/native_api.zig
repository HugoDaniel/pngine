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
//! // Create animation from bytecode
//! PngineAnimation* anim = pngine_create(bytecode, len, surface_handle);
//!
//! // Render frames
//! pngine_render(anim, time);
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
export fn pngine_render(anim: ?*PngineAnimation, time: f32) callconv(.c) void {
    const a = anim orelse return;

    a.gpu.setTime(time);

    // Execute bytecode for this frame
    // Reset PC to beginning and execute all bytecode
    a.dispatcher.pc = 0;
    a.dispatcher.frame_counter +%= 1; // Increment for ping-pong buffers
    a.dispatcher.executeFromPC(global_allocator) catch {
        // Log error but don't crash
        return;
    };
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

/// Get the last error message.
/// Returns NULL if no error.
export fn pngine_get_error() callconv(.c) ?[*:0]const u8 {
    // TODO: Implement error message storage
    return null;
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
