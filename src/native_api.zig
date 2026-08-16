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
//! // Create animation from bytecode (NULL surface = headless)
//! PngineAnimation* anim = pngine_create(bytecode, len, surface_handle, w, h);
//! if (!anim) { fprintf(stderr, "%s\n", pngine_get_error()); return 1; }
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
//! ## Failure contract
//!
//! Every failure is REPORTED before it is returned. A NULL from `pngine_create`
//! or a non-OK `PngineError` always means the error callback fired (if one is
//! set) and `pngine_get_error()` holds a message — often more specific than the
//! error code, e.g. which device limit was unmet. Callers may poll instead of
//! registering a callback; `pngine_clear_error()` resets the latch.
//!
//! Bytecode reaching `pngine_create` is UNTRUSTED (a viewer plays a PNG off the
//! internet), so it is bounded — non-empty, at most 16 MiB — before anything
//! allocates or parses. Surface dimensions must be non-zero.
//!
//! ## Thread Safety
//!
//! - pngine_init/shutdown must be called from main thread
//! - Each PngineAnimation should only be used from one thread
//! - Multiple animations can exist concurrently on different threads
//! - Error callback may be invoked from any thread; the polled
//!   `pngine_get_error()` latch is last-writer-wins across threads

const std = @import("std");
const assert = std.debug.assert;

const wgpu_native = @import("executor/wgpu_native_gpu.zig");
const Context = wgpu_native.Context;
const WgpuNativeGPU = wgpu_native.WgpuNativeGPU;

// The dispatcher monomorphized over the native backend. Defined HERE (the
// consumer) rather than in wgpu_native_gpu.zig — see the note at the bottom of
// that file: keeping it free of the dispatcher import lets lib_module import it
// for the CLI `--frame` path without a duplicate-module error.
//
// Reached through the `executor` MODULE, not `@import("executor/dispatcher.zig")`.
// The by-file form worked only while this file belonged to no build target at
// all (r2-01); the moment lib_module started compiling it, dispatcher.zig lived
// in both 'executor' and 'pngine' and the build failed with "file exists in
// multiple modules". The named import is the repo convention for exactly this.
const NativeDispatcher = @import("executor").Dispatcher(WgpuNativeGPU);

const bytecode_mod = @import("bytecode");
const format = bytecode_mod.format;
const Module = format.Module;

const wgpu = @import("gpu/wgpu_c.zig");
const c = wgpu.c;

/// Largest bytecode blob `pngine_create` will accept, matching
/// `src/cli/utils.zig`'s `max_file_size` — the 16 MiB cap every other ingestion
/// path in the repo honours (`src/png/chunk.zig` too). Restated as a local
/// constant rather than imported: this file must not pull the cli module graph
/// into the viewers' link. Keep the three in step.
const MAX_BYTECODE_LEN: usize = 16 * 1024 * 1024;

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

/// Latched copy of the last reported message, so `pngine_get_error()` has
/// something to return.
///
/// Before r2-01 the backing global was declared and never assigned once, which
/// made `pngine_get_error()` return null no matter what had failed — the
/// polling half of the error channel was dead while the callback half worked.
/// A fixed buffer rather than a slice because the messages callers care about
/// are formatted into stack buffers that are gone by the time anyone polls.
///
/// Racy under the header's "callback may be invoked from any thread" contract,
/// exactly as `error_callback` already is: last-writer-wins on a bounded
/// buffer. Polling is a debugging aid; the callback is the real channel.
var last_error_buf: [256:0]u8 = @splat(0);
var last_error_set: bool = false;

/// Report an error: latch it for `pngine_get_error()`, then invoke the callback
/// if one is set. Every failure exit in this file goes through here — a `null`
/// return that skips it is a silent failure, which is the defect r2-01 fixed.
fn reportError(err: PngineError, message: [*:0]const u8, anim: ?*PngineAnimation) void {
    assert(err != .ok); // reporting success is a caller bug
    const msg = std.mem.span(message);
    assert(msg.len > 0); // an empty diagnostic is worse than none

    // `len - 1` so index `n` is always a real element: for `[N:0]u8` the
    // sentinel sits past the last index and is not writable through one.
    const n = @min(msg.len, last_error_buf.len - 1);
    @memcpy(last_error_buf[0..n], msg[0..n]);
    last_error_buf[n] = 0;
    last_error_set = true;

    if (error_callback) |cb| {
        cb(err, message, anim, error_callback_user_data);
    }
}

/// The name of the first authored device limit (§5.3b) the live device can't
/// satisfy, or null if all are met. Each authored entry's interned camelCase
/// name is matched to its WGPULimits field, then compared against what
/// `wgpuDeviceGetLimits` reports. Pure — no GPU calls of its own.
fn firstUnsatisfiedLimit(module: *const Module, device_limits: *const wgpu.c.WGPULimits) ?[]const u8 {
    assert(module.limits.count() > 0); // callers gate on this; an empty sweep is a bug
    assert(device_limits.nextInChain == null); // an unread chain would silently drop limits

    for (module.limits.entries.items) |entry| {
        const name = module.strings.get(@enumFromInt(entry.name_string_id));
        inline for (@typeInfo(wgpu.c.WGPULimits).@"struct".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "nextInChain")) continue;
            if (std.mem.eql(u8, f.name, name)) {
                if (entry.value > @field(device_limits, f.name)) return name;
            }
        }
    }
    return null;
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
    dispatcher: NativeDispatcher,
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

    // The C-API device is created here, before any module exists, so authored
    // requiredLimits can't be applied at creation (unlike --frame). pngine_create
    // verifies the live device satisfies a module's limits instead (§5.3b).
    global_context = Context.init(null) catch {
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
/// Returns: Animation handle, or NULL on failure. On NULL the failure has
/// ALWAYS been reported: the error callback fired (if set) and
/// `pngine_get_error()` holds the message.
///
/// A null `surface_handle` means "render headless" and is not an error; a
/// non-null handle that yields no surface IS one (see `createImpl`).
export fn pngine_create(
    bytecode: [*]const u8,
    bytecode_len: usize,
    surface_handle: ?*anyopaque,
    width: u32,
    height: u32,
) callconv(.c) ?*PngineAnimation {
    // The whole body of this export is "run the real thing, and turn its error
    // into a reported null". Keeping the logic in an error-union function is
    // what makes `errdefer` work at all: before r2-01 this function *had* an
    // `errdefer` while returning `?*PngineAnimation`, so it could never fire and
    // every failure past the allocation leaked an animation.
    var detail: Detail = .{};
    return createImpl(bytecode, bytecode_len, surface_handle, width, height, &detail) catch |err| {
        const code = errorCodeFor(err);
        reportError(code, detail.messageOr(pngine_error_string(code)), null);
        return null;
    };
}

/// Failures `createImpl` can report. Each maps to a `PngineError` in
/// `errorCodeFor`; the ones whose code alone is too vague to act on also fill
/// in a `Detail` (which limit, which dimensions, which parse error).
const CreateError = error{
    NotInitialized,
    EmptyBytecode,
    BytecodeTooLarge,
    ZeroDimensions,
    SurfaceFailed,
    OutOfMemory,
    BytecodeInvalid,
    LimitUnsatisfied,
    /// The payload's resource-creation section failed to execute. Since the
    /// init/frame split (§347) that section runs at create time, so a shader
    /// that will not compile or a pipeline that will not build is reported
    /// here — at load — instead of by the first render.
    ResourceCreationFailed,
};

fn errorCodeFor(err: CreateError) PngineError {
    return switch (err) {
        error.NotInitialized => .not_initialized,
        error.EmptyBytecode, error.BytecodeTooLarge, error.ZeroDimensions => .invalid_argument,
        error.SurfaceFailed => .surface_failed,
        error.OutOfMemory => .out_of_memory,
        error.BytecodeInvalid, error.LimitUnsatisfied => .bytecode_invalid,
        error.ResourceCreationFailed => .render_failed,
    };
}

/// A failure message that knows more than its error code does — "device lacks
/// required limit: maxStorageBufferBindingSize" rather than "Invalid bytecode
/// format".
///
/// Lives on the CALLER's stack, not in a global, because the module header
/// promises animations may be created from several threads at once.
const Detail = struct {
    buf: [192:0]u8 = undefined,
    set: bool = false,

    fn print(self: *Detail, comptime fmt: []const u8, args: anytype) void {
        // A detail that does not fit is dropped, not truncated into nonsense:
        // the caller falls back to the error code's own string.
        _ = std.fmt.bufPrintZ(&self.buf, fmt, args) catch {
            self.set = false;
            return;
        };
        self.set = true;
    }

    fn messageOr(self: *const Detail, fallback: [*:0]const u8) [*:0]const u8 {
        return if (self.set) @ptrCast(&self.buf) else fallback;
    }
};

/// The real `pngine_create`. Returns an error union so that `errdefer` is a
/// working cleanup mechanism rather than dead code, which is the whole point of
/// the split (r2-01).
fn createImpl(
    bytecode: [*]const u8,
    bytecode_len: usize,
    surface_handle: ?*anyopaque,
    width: u32,
    height: u32,
    detail: *Detail,
) CreateError!*PngineAnimation {
    // Bound the raw integers the C boundary hands us BEFORE they reach anything
    // that indexes or allocates with them. Every other ingestion path in the
    // repo caps input at 16 MiB; this one used to accept any length at all.
    if (global_context == null) return error.NotInitialized;
    if (bytecode_len == 0) return error.EmptyBytecode;
    if (bytecode_len > MAX_BYTECODE_LEN) {
        detail.print("bytecode is {d} bytes; the cap is {d}", .{ bytecode_len, MAX_BYTECODE_LEN });
        return error.BytecodeTooLarge;
    }
    if (width == 0 or height == 0) {
        detail.print("surface must be non-degenerate; got {d}x{d}", .{ width, height });
        return error.ZeroDimensions;
    }

    const ctx = &global_context.?;
    assert(bytecode_len > 0 and bytecode_len <= MAX_BYTECODE_LEN);
    assert(width > 0 and height > 0);

    // A null handle is a deliberate headless animation. A non-null handle that
    // produces no surface is a failure and says so — degrading to headless
    // there (the pre-r2-01 behaviour) hands a viewer a black window with no
    // diagnostic, which is the same silent-effect defect in another costume.
    var surface: ?wgpu.Surface = null;
    if (surface_handle) |handle| {
        surface = createSurfaceFromHandle(ctx.instance, handle) orelse {
            detail.print("surface creation failed for this platform handle", .{});
            return error.SurfaceFailed;
        };
    }
    // Every failure below this line — a refused payload, an unsatisfiable limit,
    // resource creation blowing up — returns without a handle, so nobody is left
    // who could release this. r2-01's errdefers start one statement further down
    // and its regression loop passes `surface_handle == null`, so this branch was
    // both unguarded and untested. On SUCCESS ownership passes to the animation
    // and `pngine_destroy` frees it. (LEAK-04 A)
    errdefer if (surface) |s| wgpu.surfaceRelease(s);

    const anim = global_allocator.create(PngineAnimation) catch return error.OutOfMemory;
    errdefer global_allocator.destroy(anim);

    const bytecode_slice = bytecode[0..bytecode_len];
    anim.module = format.deserialize(global_allocator, bytecode_slice) catch |err| {
        detail.print("bytecode did not deserialize: {s}", .{@errorName(err)});
        return error.BytecodeInvalid;
    };
    errdefer anim.module.deinit(global_allocator);

    // Authored device limits (§5.3b): the device already exists (created at
    // pngine_init without any module), so we can't pass requiredLimits — instead
    // verify the live device meets them and fail LOUDLY, naming the limit, rather
    // than letting pipeline creation fail cryptically downstream.
    if (anim.module.limits.count() > 0) {
        var device_limits: wgpu.c.WGPULimits = undefined;
        device_limits.nextInChain = null;
        _ = wgpu.c.wgpuDeviceGetLimits(ctx.device, &device_limits);
        if (firstUnsatisfiedLimit(&anim.module, &device_limits)) |bad| {
            detail.print("device lacks required limit: {s}", .{bad});
            return error.LimitUnsatisfied;
        }
    }

    // Initialize GPU backend
    anim.gpu = WgpuNativeGPU.init(ctx, surface, width, height);
    anim.gpu.setModule(&anim.module);
    errdefer anim.gpu.deinit();

    // Initialize dispatcher
    anim.dispatcher = NativeDispatcher.init(global_allocator, &anim.gpu, &anim.module);
    errdefer anim.dispatcher.deinit();

    anim.width = width;
    anim.height = height;
    anim.diag = .{};

    // Run the payload's resource-creation section ONCE, here, and record where
    // each frame body starts — the split `wasm_entry.zig` has always had
    // (`init()` / `frame()`). Before §347 `pngine_render` replayed the whole
    // bytecode from pc 0 every frame instead, so a create opcode missing its
    // `table[id] != null` guard leaked per frame and every static `write_buffer`
    // re-uploaded its blob at frame rate.
    anim.dispatcher.execute_init(global_allocator) catch |err| {
        detail.print("resource creation failed: {s}", .{@errorName(err)});
        return error.ResourceCreationFailed;
    };

    // Post-conditions: a non-null return is fully wired — the caller may render
    // it without further checks.
    assert(anim.width > 0 and anim.height > 0);
    assert(anim.gpu.module != null);
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

    // Run ONE frame body — the one this time selects. Resource creation ran at
    // `pngine_create`; replaying it here is what LEAK-03 was. `end_frame` is
    // executed as part of the body, so the frame counter (the ping-pong pool
    // phase) advances exactly once per call.
    const frame_pc = a.dispatcher.select_frame_pc(time) orelse {
        // A payload with no `(frame …)` has nothing to draw. Not an error —
        // resource creation already ran and succeeded — but there is no work.
        a.diag.last_error = .ok;
        return .ok;
    };
    a.dispatcher.pc = frame_pc;
    a.dispatcher.execute_frame_body(global_allocator) catch |err| {
        // Unwind the half-built frame BEFORE reporting. Without this the backend
        // stays wedged — encoder, open pass, swapchain texture and views all
        // still latched — and the next pngine_render replays from pc 0 straight
        // over them. A viewer that treats a non-fatal code as "try the next
        // frame" (the normal thing to do; a transient SurfaceTextureUnavailable
        // during a window resize *is* non-fatal) then leaks one pass-encoder
        // chain per failing frame. (LEAK-01 E)
        a.gpu.abortFrame();

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
    assert(a.width > 0 and a.height > 0); // only `createImpl` hands out handles

    // Torn down in reverse construction order. The dispatcher goes FIRST
    // because it holds pointers into the other two — and because it was being
    // skipped entirely before r2-01: `NativeDispatcher.init` allocates
    // `pass_ranges` and `executed_once`, and nothing freed them, so every
    // create/destroy cycle in a viewer leaked a little. Same family as the
    // create-path leaks, one function further along.
    // Read the surface BEFORE `gpu.deinit()`, which sets `gpu.* = undefined`.
    // The API layer created it from the caller's platform handle and the API
    // layer frees it: `WgpuNativeGPU.deinit` deliberately leaves it alone,
    // because a backend that released a surface it did not create would be
    // wrong for the render path that borrows one. Nothing on either side of that
    // split actually did it until LEAK-04 B — `surfaceRelease` had zero call
    // sites in `src/`. The platform handle itself (CAMetalLayer, HWND, …) stays
    // the caller's.
    const surface = a.gpu.surface;

    a.dispatcher.deinit();
    a.gpu.deinit();
    if (surface) |s| wgpu.surfaceRelease(s);
    a.module.deinit(global_allocator);
    global_allocator.destroy(a);
}

/// Get the last error message, or NULL if nothing has failed yet.
///
/// The returned pointer is owned by the library and is valid until the next
/// reported failure. See `last_error_buf` for the thread-safety caveat.
export fn pngine_get_error() callconv(.c) ?[*:0]const u8 {
    if (!last_error_set) return null;
    return &last_error_buf;
}

/// Clear the latched error message, so a caller can tell "nothing failed since
/// I last looked" from "the same failure I already handled".
export fn pngine_clear_error() callconv(.c) void {
    last_error_set = false;
    last_error_buf[0] = 0;
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

    // Same split as pngine_render: one selected frame body, no replay of the
    // init section. The explicit counter bump is gone with it — `end_frame`
    // inside the body carries it, and doing both double-advanced the pool phase.
    const frame_pc = a.dispatcher.select_frame_pc(time) orelse return 0;
    a.dispatcher.pc = frame_pc;

    a.dispatcher.execute_frame_body(global_allocator) catch |err| {
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

        return wgpu.instanceCreateSurface(instance, &surface_desc);
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

        return wgpu.instanceCreateSurface(instance, &surface_desc);
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

        return wgpu.instanceCreateSurface(instance, &surface_desc);
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

        return wgpu.instanceCreateSurface(instance, &surface_desc);
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

// ============================================================================
// Tests — the C ABI's failure paths (r2-01)
// ============================================================================
//
// Until r2-01 this file had no tests and, more to the point, no build target at
// all: `grep native_api build.zig` came back empty, so nothing compiled it.
// It is reached now through `main.zig`'s `gpu_backends.native_api`, which puts
// these under `zig build test` on any host that builds the wgpu-native backend.
// Hosts without a usable adapter SKIP the device-dependent cases rather than
// failing them, mirroring `tests/zig/render/render_test.zig`'s `ensureGpu`.

const testing = std.testing;

/// Bring the runtime up, or skip: every check past `global_context` in
/// `createImpl` needs a real device.
fn ensureInit() error{SkipZigTest}!void {
    if (global_context != null) return;
    if (pngine_init() != 0) return error.SkipZigTest;
}

/// Capture of the most recent `reportError` callback invocation.
var test_capture: struct {
    fired: u32 = 0,
    code: PngineError = .ok,
} = .{};

fn captureCallback(
    err: PngineError,
    _: [*:0]const u8,
    _: ?*PngineAnimation,
    _: ?*anyopaque,
) callconv(.c) void {
    test_capture.fired += 1;
    test_capture.code = err;
}

/// Reset both halves of the error channel before an expected failure, so a
/// stale message can't make a silent failure look reported.
fn armCapture() void {
    test_capture = .{};
    pngine_clear_error();
    pngine_set_error_callback(captureCallback, null);
}

// ============================================================================
// Tests — the wgpu references r2-01 did not cover (LEAK-04)
// ============================================================================
//
// r2-01 fixed the ZIG allocations `pngine_create` leaked on its failure paths,
// and proved it by swapping `global_allocator` for the checking allocator. The
// wgpu references on those same paths stayed invisible: a `WGPUSurface` is
// refcounted C, so no allocator sees it leak.
//
// The r2-01 loop test passes `null` for `surface_handle`, so the only
// leak-proving test in this file never entered the surface branch at all —
// which is how the branch came to have no `errdefer` and no release anywhere in
// the repo. These tests permanently carry the non-null case, so that blind spot
// cannot reopen by someone reading the loop above and assuming it covers this.

const lifetimes = wgpu.lifetimes;
const metal_layer = @import("gpu/metal_layer.zig");

/// The smallest document that reaches a *successful* create: one shader, one
/// pipeline, one pass, one frame. Inline rather than `@embedFile`d so this
/// file's tests keep working whatever happens to `examples/`.
const triangle_sjon =
    \\(shader-module :name code :code """
    \\@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    \\  var p = array<vec2f, 3>(vec2(0.0, 0.5), vec2(-0.5, -0.5), vec2(0.5, -0.5));
    \\  return vec4f(p[i], 0.0, 1.0);
    \\}
    \\@fragment fn fs() -> @location(0) vec4f { return vec4(1.0, 0.0, 0.0, 1.0); }
    \\""")
    \\(render-pipeline :name pipe
    \\  (layout auto)
    \\  (vertex (module code) (entry vs))
    \\  (fragment (module code) (entry fs)
    \\    (targets (target :format preferred-canvas-format))))
    \\(render-pass :name pass
    \\  (color-attachment :view context-current-texture
    \\    :clear-value [0 0 0 1] :load-op clear :store-op store)
    \\  :pipeline pipe
    \\  (draw :vertex-count 3))
    \\(frame :name main :perform [pass])
;
