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
//! - **Static resource tables**: All resource arrays are fixed-size (MAX_*) to
//!   avoid runtime allocation. This ensures predictable memory usage and no GC
//!   pressure. Note this covers the TABLES, not the whole backend — see the
//!   allocation note under Invariants.
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
//! - All resource arrays use static allocation
//! - No malloc in the per-frame draw/dispatch path
//!
//! That second invariant is deliberately narrower than the "no malloc after
//! init" this file used to claim, which was not true. Resource CREATION
//! allocates short-lived null-terminated copies to cross the C boundary
//! (create_shader_module, create_render_pipeline,
//! create_compute_pipeline), and read_pixels allocates its output buffer per
//! capture. All of it is freed by the caller or on scope exit; none of it sits
//! on the per-frame path. Contrast wasm_entry.zig, which really is allocation-
//! free — do not carry that assumption over to this file.
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
//! try native_gpu.create_buffer(allocator, 0, 1024, 0x28); // VERTEX | COPY_DST
//! try native_gpu.create_shader_module(allocator, 0, 0);
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

// The getters below are marked DEPRECATED but are NOT dead code and are NOT
// test scaffolding: src/native_api.zig re-exports them across the C FFI
// boundary (pngine.h) for the iOS/Android/desktop bindings, so deleting them
// or gating them behind `builtin.is_test` breaks those library builds.
// "Deprecated" here means "do not add new callers", not "unused".

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

// ============================================================================
// Native oracle — uncaptured GPU error capture (Arc-3 §1.1, fail-loud)
// ============================================================================
//
// The render-snapshot + `npm run parity` gates trust native `--frame` as the
// pixel oracle. wgpu-native invokes the device's uncaptured-error callback
// synchronously whenever a validation / out-of-memory / internal error escapes
// an error scope — a bad pipeline, an invalid draw, a rejected submit. Before
// this, the device descriptor was `std.mem.zeroes` (no callback) so every such
// error was swallowed: `--frame` exited 0 and wrote a blank/garbage PNG that
// the snapshot/parity gate happily green-lit. Now the callback flips a global
// flag; render.zig calls `oracle.hadError()` after readback and exits nonzero.
//
// The flag is process-global (one device per process for `--frame`); the
// callback is installed once at Context.init(). `oracle.reset()` clears it so a
// test driver can render more than once in a single process (§1.3).

// The buffer holds the FIRST error of a render, not the most recent, and it is
// 1 KiB rather than 256 B. Both were learned the hard way in r2-06 (§335).
//
// A single root-cause error cascades: a shader module naga rejects makes the
// pipeline invalid, which makes `getBindGroupLayout` invalid, which makes the
// bind group invalid, which aborts at `set_pipeline`. Five callbacks, and only
// the FIRST names a cause — a last-write-wins buffer reports "RenderPipeline
// with '' label is invalid", which is the symptom furthest from the defect.
// 256 B then truncated even that: naga's message carries a source snippet, and
// the sentence naming the unsupported extension was cut mid-word.
var oracle_error: Atomic(bool) = Atomic(bool).init(false);
var oracle_msg_buf: [1024]u8 = [_]u8{0} ** 1024;
var oracle_msg_len: Atomic(u32) = Atomic(u32).init(0);

fn oracleErrorCallback(
    device: [*c]const c.WGPUDevice,
    error_type: c.WGPUErrorType,
    message_view: c.WGPUStringView,
    _: ?*anyopaque, // userdata1
    _: ?*anyopaque, // userdata2
) callconv(.c) void {
    _ = device;
    _ = error_type;
    const first = !oracle_error.swap(true, .monotonic);

    // Print EVERY error the moment it fires. render.zig's post-readback report
    // is the verdict, but it only runs if control gets that far: wgpu-native
    // panics inside `wgpuQueueSubmit` on an invalid command stream, so a render
    // whose root cause was captured five callbacks earlier used to die with a
    // bare "failed to initiate panic, error 5" and nothing else. An abort must
    // not be able to swallow a diagnosis we already hold.
    if (message_view.data) |data| {
        std.debug.print("[native] GPU error: {s}\n", .{data[0..message_view.length]});
    }

    // Retain the FIRST message only — see the buffer's comment above.
    if (!first) return;
    if (message_view.data) |data| {
        const n: u32 = @intCast(@min(message_view.length, oracle_msg_buf.len));
        @memcpy(oracle_msg_buf[0..n], data[0..n]);
        oracle_msg_len.store(n, .monotonic);
    }
}

/// Native-oracle uncaptured-error state. render.zig consults this after a frame
/// to decide whether the pixels are trustworthy (Arc-3 §1.1).
pub const oracle = struct {
    /// Clear captured state before a render (the flag is process-global).
    pub fn reset() void {
        oracle_error.store(false, .monotonic);
        oracle_msg_len.store(0, .monotonic);
    }

    /// True if any uncaptured GPU error fired since the last reset().
    pub fn hadError() bool {
        return oracle_error.load(.monotonic);
    }

    /// The FIRST captured error message since reset() (empty slice if none) —
    /// the root cause, not the last symptom its cascade produced.
    pub fn message() []const u8 {
        return oracle_msg_buf[0..oracle_msg_len.load(.monotonic)];
    }
};

// ============================================================================
// Native stub honesty (Arc-3 §1.2, fail-loud)
// ============================================================================
//
// A handful of opcodes are unimplemented on native — indirect draws, query
// sets, occlusion/timestamp queries, viewport/scissor, buffer/texture copies,
// image bitmaps, render bundles, the WASM-data ops, pointer input. Each was a
// SILENT `_ =`-discard no-op: the frame renders "OK" (exit 0) but the fixture's
// feature simply did nothing → the coverage.txt capability table lied "OK".
//
// `stub.note("op")` makes each one explicit: it warns ONCE per op per process
// (developer visibility) and sets a per-render flag. The `--strict-native-stubs`
// coverage runs make render.zig exit nonzero when the flag is set, so the
// capability table records `stub` instead of `OK`. Normal `--frame` is
// unaffected (exit 0 + the warning) — the reclassification is a gate concern.

var stub_any_hit: bool = false;
var stub_warned: [32][]const u8 = undefined;
var stub_warned_count: usize = 0;

/// Once-per-byte dedup for the decodeTextureFormat fallback warning (spec/05).
var warned_format_bytes = std.StaticBitSet(256).initEmpty();

/// Native-stub honesty state. render.zig consults `anyHit()` in strict mode
/// (the coverage gate) to reclassify an OK-via-no-op render as `stub`.
pub const stub = struct {
    /// Record that an unimplemented native opcode was reached. Warns once per
    /// distinct `op` per process; always sets the per-render hit flag.
    pub fn note(op: []const u8) void {
        assert(op.len > 0);
        stub_any_hit = true;
        for (stub_warned[0..stub_warned_count]) |w| {
            if (std.mem.eql(u8, w, op)) return; // already warned this op
        }
        if (stub_warned_count < stub_warned.len) {
            stub_warned[stub_warned_count] = op;
            stub_warned_count += 1;
            std.debug.print("[native] unimplemented on native: {s} (rendered without it)\n", .{op});
        }
    }

    /// Clear the per-render hit flag (the warn-once set persists per process).
    pub fn reset() void {
        stub_any_hit = false;
    }

    /// True if any unimplemented native opcode was reached since reset().
    pub fn anyHit() bool {
        return stub_any_hit;
    }
};

// Use bytecode module import
const bytecode_mod = @import("bytecode");
const format = bytecode_mod.format;
const Module = format.Module;
const DataSection = bytecode_mod.DataSection;
const DataId = bytecode_mod.DataId;
const LoadOp = bytecode_mod.opcodes.LoadOp;
const StoreOp = bytecode_mod.opcodes.StoreOp;
const opcodes = bytecode_mod.opcodes;

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
/// The WGPULimits struct passed to requestDevice — re-exported so callers
/// (render.zig via gpu_backends) can name the type without importing the wgpu C
/// bindings directly.
pub const RequiredLimits = c.WGPULimits;

/// Build the WGPULimits to request from an authored device-limits table
/// (Arc-3 §5.3b). Every field starts at the UNDEFINED sentinel (= "use the
/// adapter default") — a zeroed struct would REQUEST zero and reject instantly.
/// Each authored entry then overlays the matching field by its interned
/// camelCase name, which is EXACTLY the WGPULimits field name, so a future limit
/// needs no change here (the fields drive the match). Pure (no GPU) →
/// unit-testable without a device.
pub fn buildRequiredLimits(module: *const Module) c.WGPULimits {
    var lim: c.WGPULimits = undefined;
    lim.nextInChain = null;
    inline for (@typeInfo(c.WGPULimits).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "nextInChain")) continue;
        @field(lim, f.name) = switch (@typeInfo(f.type).int.bits) {
            32 => c.WGPU_LIMIT_U32_UNDEFINED,
            64 => c.WGPU_LIMIT_U64_UNDEFINED,
            else => comptime unreachable,
        };
    }
    for (module.limits.entries.items) |entry| {
        const name = module.strings.get(@enumFromInt(entry.name_string_id));
        inline for (@typeInfo(c.WGPULimits).@"struct".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "nextInChain")) continue;
            if (std.mem.eql(u8, f.name, name)) {
                // Authored values fit u32 (schema repr); a value that doesn't fit
                // the field keeps the sentinel rather than trapping.
                @field(lim, f.name) = std.math.cast(f.type, entry.value) orelse @field(lim, f.name);
            }
        }
    }
    return lim;
}

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
    /// This should be called once at application startup. `required_limits`, when
    /// non-null, is passed to requestDevice as the authored device limits (build
    /// it with `buildRequiredLimits`); an unsatisfiable limit fails the request
    /// loudly (message printed) rather than silently. (Arc-3 §5.3b)
    pub fn init(required_limits: ?*const c.WGPULimits) !Self {
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

        // Opportunistically enable depth-clip-control (mirrors gpu.js
        // OPTIONAL_DEVICE_FEATURES): gate on adapter support, since requesting a
        // feature the adapter lacks rejects the device request. It powers
        // `(primitive :unclipped-depth true)`; inert for every other pipeline.
        var required_features = [_]c.WGPUFeatureName{c.WGPUFeatureName_DepthClipControl};
        var device_desc = std.mem.zeroes(c.WGPUDeviceDescriptor);
        const want_depth_clip = c.wgpuAdapterHasFeature(adapter, c.WGPUFeatureName_DepthClipControl) != 0;
        if (want_depth_clip) {
            device_desc.requiredFeatureCount = required_features.len;
            device_desc.requiredFeatures = &required_features;
        }
        // Install the uncaptured-error callback (Arc-3 §1.1) so a validation
        // error during `--frame` is captured and can fail the render loudly,
        // instead of exit 0 + a blank PNG. Always pass the descriptor now — a
        // zeroed descriptor with just the callback is equivalent to the old
        // `null` (no features requested).
        device_desc.uncapturedErrorCallbackInfo = .{
            .nextInChain = null,
            .callback = oracleErrorCallback,
            .userdata1 = null,
            .userdata2 = null,
        };

        // Authored device limits (Arc-3 §5.3b) are REQUIREMENTS — pass them
        // verbatim. Unsatisfiable → requestDevice returns null below, and we
        // print the driver's reason (was discarded → a mute failure exit).
        if (required_limits) |lim| device_desc.requiredLimits = lim;

        // Request device (synchronous) - v27+ API requires instance for wait
        const device_result = wgpu.requestDeviceSync(instance, adapter, &device_desc);
        if (device_result.device == null) {
            if (device_result.message) |msg| {
                std.debug.print("Error: device request failed: {s}\n", .{msg});
            }
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

        // The queue is an owned reference despite `wgpuDeviceGetQueue`'s name,
        // so it needs releasing like the three below it. It went without one
        // until LEAK-04 C — plausibly harmless, since wgpu-native may well drop
        // it when the device goes, but the C contract does not say so and a
        // viewer that reinitialises pays for the difference either way.
        wgpu.queueRelease(self.queue);
        wgpu.deviceRelease(self.device);
        wgpu.adapterRelease(self.adapter);
        wgpu.instanceRelease(self.instance);

        self.* = undefined;
    }

    /// Test-only: deliberately provoke a GPU validation error on this device so
    /// the oracle-honesty guard (Arc-3 §1.3) can prove the uncaptured-error
    /// callback installed in `init()` is actually live. `MapRead | MapWrite` is a
    /// spec-invalid buffer usage combination — wgpu-native reports it via the
    /// uncaptured-error callback (not an abort), which flips `oracle.hadError()`.
    /// Never on the runtime path; the CLI never references it (dead-code-eliminated).
    pub fn provokeValidationErrorForTest(self: *Self) void {
        assert(self.initialized);
        const desc = c.WGPUBufferDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },
            .size = 16,
            .usage = c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_MapWrite,
            .mappedAtCreation = @intFromBool(false),
        };
        const buf = wgpu.deviceCreateBuffer(self.device, &desc);
        // Drain any queued callback delivery (wgpu-native reports synchronously,
        // but poll to be certain the flag is set before the caller checks it).
        _ = wgpu.devicePoll(self.device, false);
        if (buf != null) wgpu.bufferRelease(buf);
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
/// - **Command-based**: Same interface as MockGPU - receives GPU commands
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
    /// WebGPU caps a render pass at 8 simultaneous color attachments; the pipeline
    /// target list and the MRT render-pass path share this bound (pass.zig decodes
    /// up to 8, command_buffer.zig documents the same).
    pub const MAX_COLOR_ATTACHMENTS: u16 = 8;
    pub const MAX_BIND_GROUPS: u16 = 128;
    pub const MAX_BIND_GROUP_LAYOUTS: u16 = 64;
    pub const MAX_PIPELINE_LAYOUTS: u16 = 64;

    /// Narrow a resource id decoded from a JSON descriptor to something the
    /// `max`-sized table can hold.
    ///
    /// Two hazards in one step, both on untrusted bytes: `std.json` yields an
    /// i64, so a bare `@intCast` to u16 is undefined behaviour for anything
    /// outside 0..65535 (it does not "wrap" — ReleaseFast may do anything with
    /// it), and even a well-formed u16 can still be past the table's end.
    /// Rejecting instead of clamping keeps a corrupt descriptor from silently
    /// binding resource 0 in place of the one it named.
    fn tableId(v: std.json.Value, comptime max: u16) error{InvalidResourceId}!u16 {
        const n = switch (v) {
            .integer => |i| i,
            else => return error.InvalidResourceId,
        };
        if (n < 0 or n >= max) return error.InvalidResourceId;
        return @intCast(n);
    }

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

    /// The swapchain texture the current frame's surface view was made from.
    ///
    /// `wgpuSurfaceGetCurrentTexture` hands back an OWNED reference; the view
    /// taken from it is a second, independent one. Releasing only the view — what
    /// this backend did until LEAK-01 — leaks one texture reference and its
    /// swapchain image on EVERY windowed frame, 60/s, in every C-ABI viewer.
    /// `--frame` is headless so no gate could see it; `getColorTargetView` is
    /// the sibling of `getCopyTexture`, which has marked the identical
    /// acquisition `owned = true` since the day it was written.
    ///
    /// Latched here so submit(), abortFrame() and deinit() each have something
    /// to release, and so a second surface acquisition in one frame releases the
    /// first instead of dropping it.
    current_surface_texture: ?wgpu.Texture,

    /// Offscreen color target for headless (surface==null) rendering. Created in
    /// init() as BGRA8Unorm | RenderAttachment | CopySrc so that read_pixels()
    /// can copy it back to the CPU. Persistent for the instance lifetime —
    /// released in deinit(), NOT submit() (unlike the transient surface view).
    offscreen_texture: ?wgpu.Texture,
    offscreen_view: ?wgpu.TextureView,

    // -----------------------------------------------------------------------
    // Resource Arrays (Static Allocation - O(1) Lookup by ID)
    // -----------------------------------------------------------------------
    //
    // CONTRACT: every id used to index one of these tables MUST be range-checked
    // with a real branch before the index. Resource ids arrive from bytecode and
    // are therefore untrusted — `pngine_create` (the public C ABI, native_api.zig)
    // hands this backend arbitrary PNGB extracted from a PNG. `assert(id < MAX_*)`
    // is NOT that check: it compiles out under ReleaseFast/ReleaseSmall, which is
    // precisely where a hostile id lands. Unchecked, `tables[id] = ptr` is an
    // out-of-bounds write of a heap pointer, not a crash.
    //
    // The two idioms, by site kind:
    //   - creation:  `if (id >= MAX_X) return error.InvalidResourceId;`
    //   - use:       `if (id >= MAX_X) return;`  (matches the existing
    //                "resource was never created" path — nothing more is
    //                actionable at a use site)
    // Ids decoded from descriptor data are checked at the point of derivation,
    // where the `@intCast` that narrows them is itself UB on out-of-range input.

    /// GPU buffers indexed by bytecode buffer ID.
    buffers: [MAX_BUFFERS]?wgpu.Buffer,

    /// GPU textures indexed by bytecode texture ID.
    textures: [MAX_TEXTURES]?wgpu.Texture,

    /// Default 2d views, cached by TEXTURE id — a `(entry :texture …)` binding
    /// (resource_type texture_view) reuses/creates one here.
    texture_views: [MAX_TEXTURE_VIEWS]?wgpu.TextureView,

    /// Explicit (texture-view …) objects, indexed by VIEW id (a separate space
    /// from texture ids so it never collides with the default-view cache above).
    /// A `(entry :texture-view …)` binding (resource_type explicit_texture_view)
    /// binds one of these directly.
    explicit_texture_views: [MAX_TEXTURE_VIEWS]?wgpu.TextureView,

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

    /// Depth stencil view created during begin_render_pass.
    /// Released after submit().
    current_depth_view: ?wgpu.TextureView,

    /// Pending depth/stencil load-store ops for the NEXT begin_render_pass.
    /// `set_pass_depth_stencil_ops` (pre-pass state) overrides these; each
    /// begin_render_pass{,_mrt} consumes them into the depth-stencil attachment
    /// and then resets to the clear/store defaults — the emitter only emits the
    /// opcode for a non-default pass, so a plain pass must see the defaults (§214).
    /// Wire encoding: LoadOp{load=0,clear=1}, StoreOp{store=0,discard=1}.
    pending_depth_load_op: u8,
    pending_depth_store_op: u8,
    pending_stencil_load_op: u8,
    pending_stencil_store_op: u8,

    /// Pending depth/stencil clear values for the NEXT begin_render_pass.
    /// `set_pass_clear_values` (pre-pass state) overrides these; consumed and
    /// reset alongside the pending load-store ops. Defaults: 1.0 / 0.
    pending_depth_clear_value: f32,
    pending_stencil_clear_value: u32,

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

        // Headless (no surface): create a persistent offscreen color target so
        // read_pixels() has something to copy back. CopySrc is required for that
        // copy; the format matches the pipeline color-target hardcode so the
        // render pass is format-compatible. On-screen instances skip this.
        var offscreen_texture: ?wgpu.Texture = null;
        var offscreen_view: ?wgpu.TextureView = null;
        if (surface == null) {
            var off_desc = std.mem.zeroes(c.WGPUTextureDescriptor);
            off_desc.usage = c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_CopySrc;
            off_desc.dimension = c.WGPUTextureDimension_2D;
            off_desc.size = .{ .width = width, .height = height, .depthOrArrayLayers = 1 };
            off_desc.format = c.WGPUTextureFormat_BGRA8Unorm;
            off_desc.mipLevelCount = 1;
            off_desc.sampleCount = 1;
            const tex = wgpu.deviceCreateTexture(ctx.device, &off_desc);
            offscreen_texture = tex;
            if (tex != null) offscreen_view = wgpu.textureCreateView(tex, null);
        }

        const self = Self{
            .ctx = ctx,
            .surface = surface,
            .current_surface_view = null,
            .current_surface_texture = null,
            .offscreen_texture = offscreen_texture,
            .offscreen_view = offscreen_view,
            .buffers = [_]?wgpu.Buffer{null} ** MAX_BUFFERS,
            .textures = [_]?wgpu.Texture{null} ** MAX_TEXTURES,
            .texture_views = [_]?wgpu.TextureView{null} ** MAX_TEXTURE_VIEWS,
            .explicit_texture_views = [_]?wgpu.TextureView{null} ** MAX_TEXTURE_VIEWS,
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
            .pending_depth_load_op = @intFromEnum(LoadOp.clear),
            .pending_depth_store_op = @intFromEnum(StoreOp.store),
            .pending_stencil_load_op = @intFromEnum(LoadOp.clear),
            .pending_stencil_store_op = @intFromEnum(StoreOp.store),
            .pending_depth_clear_value = 1.0,
            .pending_stencil_clear_value = 0,
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
                // CopySrc matches what the browser configures its canvas context
                // with (core.js:143, worker-core.js:211) — without it a
                // `copy-texture-to-texture :source context-current-texture` is a
                // validation error on a windowed instance and works headless,
                // which is the worst of both.
                .usage = c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_CopySrc,
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
        // Frame-scoped state FIRST. Teardown after a frame that never reached
        // submit() — a mid-frame `error.TextureNotFound`, a payload that simply
        // ends without a submit opcode — otherwise stranded the encoder, the open
        // pass and the swapchain texture: the table sweep below cannot see any of
        // them, and submit() is the only other release point (LEAK-01 D).
        self.abortFrame();

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
        for (&self.explicit_texture_views) |*view| {
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

        // current_surface_view / current_surface_texture / current_depth_view are
        // already gone — abortFrame() above owns the frame-scoped set.
        //
        // `self.surface` is NOT released here, on purpose: this backend borrows
        // a surface it did not create (the `--frame` path passes null, the C ABI
        // passes one it made from the caller's window handle). Its owner is
        // `pngine_destroy`, which does release it — since LEAK-04 B, when this
        // comment named a division of labour that only one side was keeping.
        if (self.offscreen_view) |v| {
            wgpu.textureViewRelease(v);
        }
        if (self.offscreen_texture) |t| {
            wgpu.textureRelease(t);
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

    pub fn create_buffer(self: *Self, allocator: Allocator, buffer_id: u16, size: u32, usage: u16) !void {
        _ = allocator;

        // Untrusted id: a real branch, not an assert (see the resource-array
        // contract). Everything below indexes `buffers` with it.
        if (buffer_id >= MAX_BUFFERS) return error.InvalidResourceId;
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
        nativeLog("create_buffer: id={}, size={}, usage=0x{x}, result={}\n", .{
            buffer_id,
            size,
            usage,
            buffer != null,
        });
        self.buffers[buffer_id] = buffer;

        // Post-condition: buffer slot is now populated (may be null if GPU failed)
        assert(self.buffers[buffer_id] != null or buffer == null);
    }

    pub fn create_texture(self: *Self, allocator: Allocator, texture_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        // Untrusted id: bounds `textures` and `texture_formats` (same MAX).
        if (texture_id >= MAX_TEXTURES) return error.InvalidResourceId;
        assert(self.module != null);

        // Skip if texture already exists
        if (self.textures[texture_id] != null) {
            return;
        }

        const module = self.module.?;
        const data = module.data.get(DataId.fromInt(descriptor_data_id));

        // Parse texture descriptor via the shared TLV reader — field ids map
        // through TextureField and value kinds through ValueType, so there is no
        // magic hex here (the reader is single-sourced with the encoder).
        const descriptors = bytecode_mod.descriptors;
        var tex_width: u32 = self.width;
        var tex_height: u32 = self.height;
        var tex_format: c_uint = c.WGPUTextureFormat_RGBA8Unorm;
        var tex_usage: c_uint = c.WGPUTextureUsage_RenderAttachment;
        var sample_count: u32 = 1;
        var depth_or_array_layers: u32 = 1;
        var mip_level_count: u32 = 1;
        var dimension: c_uint = c.WGPUTextureDimension_2D;

        if (descriptors.TlvReader.init(data)) |reader_const| {
            var reader = reader_const;
            while (reader.next()) |field| {
                const tf = std.enums.fromInt(descriptors.TextureField, field.id) orelse continue;
                switch (field.value_type) {
                    .u32_val => switch (tf) {
                        .width => tex_width = field.scalar,
                        .height => tex_height = field.scalar,
                        .depth => depth_or_array_layers = field.scalar,
                        .mip_level_count => mip_level_count = field.scalar,
                        .sample_count => sample_count = field.scalar,
                        else => {},
                    },
                    .enum_val => switch (tf) {
                        .format => tex_format = decodeTextureFormat(@intCast(field.scalar)),
                        .usage => tex_usage = decodeTextureUsage(@intCast(field.scalar)),
                        .dimension => dimension = switch (field.scalar) {
                            0 => c.WGPUTextureDimension_1D,
                            2 => c.WGPUTextureDimension_3D,
                            else => c.WGPUTextureDimension_2D,
                        },
                        else => {},
                    },
                    else => {},
                }
            }
        }

        // Zero-initialize to avoid undefined memory issues
        var descriptor = std.mem.zeroes(c.WGPUTextureDescriptor);
        descriptor.nextInChain = null;
        descriptor.label = .{ .data = null, .length = 0 };
        descriptor.usage = tex_usage;
        descriptor.dimension = dimension;
        descriptor.size = .{ .width = tex_width, .height = tex_height, .depthOrArrayLayers = depth_or_array_layers };
        descriptor.format = tex_format;
        descriptor.mipLevelCount = mip_level_count;
        descriptor.sampleCount = sample_count;
        descriptor.viewFormatCount = 0;
        descriptor.viewFormats = null;

        self.textures[texture_id] = wgpu.deviceCreateTexture(self.ctx.device, &descriptor);
        self.texture_formats[texture_id] = tex_format;
    }

    // Byte → wgpu-native enum. Kept in lockstep with descriptors.zig TextureFormat
    // (the encoder) and the JS/codegen decoders; the npm conformance test pins the
    // JS side, this one is the native viewer's decoder for the same byte codes.
    fn decodeTextureFormat(val: u8) c_uint {
        return switch (val) {
            0x00 => c.WGPUTextureFormat_RGBA8Unorm,
            0x01 => c.WGPUTextureFormat_RGBA8Snorm,
            0x02 => c.WGPUTextureFormat_RGBA8Uint,
            0x03 => c.WGPUTextureFormat_RGBA8Sint,
            0x04 => c.WGPUTextureFormat_BGRA8Unorm,
            0x05 => c.WGPUTextureFormat_RGBA16Float,
            0x06 => c.WGPUTextureFormat_RGBA32Float,
            0x07 => c.WGPUTextureFormat_RGBA8UnormSrgb,
            0x08 => c.WGPUTextureFormat_BGRA8UnormSrgb,
            0x10 => c.WGPUTextureFormat_Depth24Plus,
            0x11 => c.WGPUTextureFormat_Depth24PlusStencil8,
            0x12 => c.WGPUTextureFormat_Depth32Float,
            0x13 => c.WGPUTextureFormat_Stencil8,
            0x14 => c.WGPUTextureFormat_Depth16Unorm,
            0x15 => c.WGPUTextureFormat_Depth32FloatStencil8,
            0x20 => c.WGPUTextureFormat_R32Float,
            0x21 => c.WGPUTextureFormat_RG32Float,
            0x22 => c.WGPUTextureFormat_R32Uint,
            0x23 => c.WGPUTextureFormat_R32Sint,
            0x24 => c.WGPUTextureFormat_RG32Uint,
            0x25 => c.WGPUTextureFormat_RG32Sint,
            0x30 => c.WGPUTextureFormat_R8Unorm,
            0x31 => c.WGPUTextureFormat_RG8Unorm,
            0x32 => c.WGPUTextureFormat_R16Float,
            0x33 => c.WGPUTextureFormat_RG16Float,
            0x34 => c.WGPUTextureFormat_R8Snorm,
            0x35 => c.WGPUTextureFormat_R8Uint,
            0x36 => c.WGPUTextureFormat_R8Sint,
            0x37 => c.WGPUTextureFormat_RG8Snorm,
            0x38 => c.WGPUTextureFormat_RG8Uint,
            0x39 => c.WGPUTextureFormat_RG8Sint,
            0x40 => c.WGPUTextureFormat_R16Uint,
            0x41 => c.WGPUTextureFormat_R16Sint,
            0x42 => c.WGPUTextureFormat_RG16Uint,
            0x43 => c.WGPUTextureFormat_RG16Sint,
            0x50 => c.WGPUTextureFormat_RGBA16Uint,
            0x51 => c.WGPUTextureFormat_RGBA16Sint,
            0x60 => c.WGPUTextureFormat_RGBA32Uint,
            0x61 => c.WGPUTextureFormat_RGBA32Sint,
            0x70 => c.WGPUTextureFormat_RGB10A2Unorm,
            0x71 => c.WGPUTextureFormat_RGB10A2Uint,
            0x72 => c.WGPUTextureFormat_RG11B10Ufloat,
            0x73 => c.WGPUTextureFormat_RGB9E5Ufloat,
            // The preferred-canvas-format SENTINEL (descriptors.zig 0xFF) — a
            // legitimate byte, resolved to the native canvas format here, NOT
            // an unsupported value. (The spec/05 fail-loud fallback below
            // exposed that MSAA resolve targets reach this decoder with 0xFF.)
            0xFF => c.WGPUTextureFormat_BGRA8Unorm,
            // 0x44-0x47, 0x52-0x53 (tier1 16-bit unorm/snorm) are absent from the
            // vendored wgpu-native header (predates texture-formats-tier1); they fall
            // through until the vendor lib is bumped. The web stack decodes them fully.
            // The gap is ledgered by the native conformance gate
            // (NATIVE_KNOWN_UNSUPPORTED in webgpu-conformance.test.js, spec/05).
            else => {
                // Fail loud, never mis-render silently: label the fallback once
                // per byte, and let `stub` reclassify the render under
                // --strict-native-stubs / the coverage gate.
                if (!warned_format_bytes.isSet(val)) {
                    warned_format_bytes.set(val);
                    std.debug.print("[native] unsupported texture-format byte 0x{X:0>2} — rendering as bgra8unorm\n", .{val});
                }
                stub.note("texture-format (unsupported byte)");
                return c.WGPUTextureFormat_BGRA8Unorm;
            },
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

    pub fn create_texture_view(self: *Self, allocator: Allocator, view_id: u16, texture_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        // Untrusted ids, both indexed below (view_id → explicit_texture_views,
        // texture_id → textures + texture_formats).
        if (view_id >= MAX_TEXTURE_VIEWS) return error.InvalidResourceId;
        if (texture_id >= MAX_TEXTURES) return error.InvalidResourceId;
        assert(self.module != null);

        // The sibling guard every other create opcode has, and this one lacked
        // (LEAK-02 A). It is not only hostile-stream defence: `pngine_render`
        // replays the whole bytecode each frame, so an ordinary authored
        // `(texture-view …)` re-entered this function 60 times a second and
        // dropped the previous WGPUTextureView unreleased every time — 98 leaked
        // views over 100 frames, measured.
        if (self.explicit_texture_views[view_id] != null) return;

        const texture = self.textures[texture_id] orelse return;

        // Explicit (texture-view …): decode the GPUTextureViewDescriptor so a
        // 1d/3d/array/cube view gets the right dimension/aspect/subresource range.
        // Defaults = WebGPU's own: infer dimension from the texture, all aspects,
        // all remaining mips/layers, the texture's own format. Absent fields keep
        // these — an all-default blob yields a plain view, same as createView(null).
        const descriptors = bytecode_mod.descriptors;
        const data = self.module.?.data.get(DataId.fromInt(descriptor_data_id));
        var descriptor = c.WGPUTextureViewDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },
            .format = self.texture_formats[texture_id],
            .dimension = c.WGPUTextureViewDimension_Undefined,
            .baseMipLevel = 0,
            .mipLevelCount = 0xFFFFFFFF, // WGPU_MIP_LEVEL_COUNT_UNDEFINED = all remaining
            .baseArrayLayer = 0,
            .arrayLayerCount = 0xFFFFFFFF, // WGPU_ARRAY_LAYER_COUNT_UNDEFINED = all remaining
            .aspect = c.WGPUTextureAspect_All,
            .usage = 0,
        };
        if (descriptors.TlvReader.init(data)) |reader_const| {
            var reader = reader_const;
            while (reader.next()) |field| {
                const vf = std.enums.fromInt(descriptors.TextureViewField, field.id) orelse continue;
                switch (vf) {
                    .format => descriptor.format = decodeTextureFormat(@intCast(field.scalar)),
                    .dimension => descriptor.dimension = mapViewDimension(@intCast(field.scalar)),
                    .aspect => descriptor.aspect = decodeTextureAspect(@intCast(field.scalar)),
                    .base_mip_level => descriptor.baseMipLevel = field.scalar,
                    .mip_level_count => descriptor.mipLevelCount = field.scalar,
                    .base_array_layer => descriptor.baseArrayLayer = field.scalar,
                    .array_layer_count => descriptor.arrayLayerCount = field.scalar,
                }
            }
        }

        self.explicit_texture_views[view_id] = wgpu.textureCreateView(texture, &descriptor);
    }

    /// Byte → wgpu-native texture aspect (0=all, 1=stencil-only, 2=depth-only).
    fn decodeTextureAspect(val: u8) c_uint {
        return switch (val) {
            1 => c.WGPUTextureAspect_StencilOnly,
            2 => c.WGPUTextureAspect_DepthOnly,
            else => c.WGPUTextureAspect_All,
        };
    }

    pub fn create_sampler(self: *Self, allocator: Allocator, sampler_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        if (sampler_id >= MAX_SAMPLERS) return error.InvalidResourceId; // untrusted id
        assert(self.module != null);

        // Skip if sampler already exists
        if (self.samplers[sampler_id] != null) {
            return;
        }

        const module = self.module.?;
        const data = module.data.get(DataId.fromInt(descriptor_data_id));

        // Parse via the shared TLV reader (single-sourced with the encoder), so a
        // `:compare` sampler becomes a real comparison sampler — a WGSL
        // `sampler_comparison` binding is rejected outright otherwise ("expects
        // comparison = true"). Defaults equal the previous hardcode, and the
        // emitter's null-defaults are linear/clamp too, so a plain sampler is
        // byte-for-byte unchanged.
        const descriptors = bytecode_mod.descriptors;
        var descriptor = c.WGPUSamplerDescriptor{
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

        if (descriptors.TlvReader.init(data)) |reader_const| {
            var reader = reader_const;
            while (reader.next()) |field| {
                const sf = std.enums.fromInt(descriptors.SamplerField, field.id) orelse continue;
                switch (sf) {
                    .address_mode_u => descriptor.addressModeU = decodeAddressMode(@intCast(field.scalar)),
                    .address_mode_v => descriptor.addressModeV = decodeAddressMode(@intCast(field.scalar)),
                    .address_mode_w => descriptor.addressModeW = decodeAddressMode(@intCast(field.scalar)),
                    .mag_filter => descriptor.magFilter = decodeFilterMode(@intCast(field.scalar)),
                    .min_filter => descriptor.minFilter = decodeFilterMode(@intCast(field.scalar)),
                    .mipmap_filter => descriptor.mipmapFilter = decodeMipmapFilterMode(@intCast(field.scalar)),
                    .compare => descriptor.compare = decodeSamplerCompare(@intCast(field.scalar)),
                    .max_anisotropy => descriptor.maxAnisotropy = @intCast(field.scalar),
                    // Lod clamps are f32; TlvReader carries the value as its bit pattern.
                    .lod_min_clamp => descriptor.lodMinClamp = @bitCast(field.scalar),
                    .lod_max_clamp => descriptor.lodMaxClamp = @bitCast(field.scalar),
                }
            }
        }

        self.samplers[sampler_id] = wgpu.deviceCreateSampler(self.ctx.device, &descriptor);
    }

    /// Byte → wgpu-native address mode (descriptors.zig AddressMode: 0=clamp,
    /// 1=repeat, 2=mirror-repeat).
    fn decodeAddressMode(val: u8) c_uint {
        return switch (val) {
            1 => c.WGPUAddressMode_Repeat,
            2 => c.WGPUAddressMode_MirrorRepeat,
            else => c.WGPUAddressMode_ClampToEdge,
        };
    }

    /// Byte → wgpu-native filter mode (0=nearest, 1=linear).
    fn decodeFilterMode(val: u8) c_uint {
        return if (val == 0) c.WGPUFilterMode_Nearest else c.WGPUFilterMode_Linear;
    }

    fn decodeMipmapFilterMode(val: u8) c_uint {
        return if (val == 0) c.WGPUMipmapFilterMode_Nearest else c.WGPUMipmapFilterMode_Linear;
    }

    /// Byte → wgpu-native compare function. The sampler TLV encodes 0=never …
    /// 7=always (values.mapCompareFunction), one below the wgpu enum (Never=1).
    fn decodeSamplerCompare(val: u8) c_uint {
        return switch (val) {
            0 => c.WGPUCompareFunction_Never,
            1 => c.WGPUCompareFunction_Less,
            2 => c.WGPUCompareFunction_Equal,
            3 => c.WGPUCompareFunction_LessEqual,
            4 => c.WGPUCompareFunction_Greater,
            5 => c.WGPUCompareFunction_NotEqual,
            6 => c.WGPUCompareFunction_GreaterEqual,
            7 => c.WGPUCompareFunction_Always,
            else => c.WGPUCompareFunction_Undefined,
        };
    }

    pub fn create_shader_module(self: *Self, allocator: Allocator, shader_id: u16, code_data_id: u16) !void {
        // Pre-condition assertions (Zig Mastery Compliance)
        if (shader_id >= MAX_SHADERS) return error.InvalidResourceId; // untrusted id
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
        nativeLog("create_shader_module: id={}, code_len={}, result={}\n", .{
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

    pub fn create_render_pipeline(self: *Self, allocator: Allocator, pipeline_id: u16, descriptor_data_id: u16) !void {
        if (pipeline_id >= MAX_RENDER_PIPELINES) return error.InvalidResourceId; // untrusted id
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
        // The descriptor is data, so its shader id is untrusted twice over: a
        // bare `@intCast` of an out-of-range i64 is UB, and the narrowed value
        // then indexes `shaders`. `shaderId` does both checks.
        const vertex_shader_id = try tableId(vertex_obj.get("shader").?, MAX_SHADERS);
        const vertex_entry = vertex_obj.get("entryPoint").?.string;
        const vertex_shader = self.shaders[vertex_shader_id] orelse return error.InvalidResourceId;

        const vertex_entry_z = try allocator.allocSentinel(u8, vertex_entry.len, 0);
        defer allocator.free(vertex_entry_z);
        @memcpy(vertex_entry_z, vertex_entry);

        // Parse vertex buffer layouts into caller-owned storage. `vertex_layouts`
        // MUST outlive deviceCreateRenderPipeline below: the per-buffer
        // `.attributes` pointers point back into it (see parseVertexBufferLayouts).
        var vertex_layouts: VertexLayoutResult = undefined;
        parseVertexBufferLayouts(&vertex_layouts, vertex_obj);

        // Get fragment stage info. `blend_states`/`color_targets` are function-scope
        // so they outlive deviceCreateRenderPipeline below; each color target's
        // `.blend` points back into `blend_states[i]`, so both arrays must persist.
        var fragment_state: ?c.WGPUFragmentState = null;
        var fragment_entry_z: ?[:0]u8 = null;
        var blend_states: [MAX_COLOR_ATTACHMENTS]c.WGPUBlendState = undefined;
        var color_targets: [MAX_COLOR_ATTACHMENTS]c.WGPUColorTargetState = undefined;

        if (root.get("fragment")) |frag_val| {
            const frag_obj = frag_val.object;
            const frag_shader_id = try tableId(frag_obj.get("shader").?, MAX_SHADERS);
            const frag_entry = frag_obj.get("entryPoint").?.string;
            const frag_shader = self.shaders[frag_shader_id] orelse return error.InvalidResourceId;

            fragment_entry_z = try allocator.allocSentinel(u8, frag_entry.len, 0);
            @memcpy(fragment_entry_z.?, frag_entry);

            // Default: opaque replace (src One / dst Zero), applied to every target.
            const default_blend = c.WGPUBlendState{
                .color = .{ .srcFactor = c.WGPUBlendFactor_One, .dstFactor = c.WGPUBlendFactor_Zero, .operation = c.WGPUBlendOperation_Add },
                .alpha = .{ .srcFactor = c.WGPUBlendFactor_One, .dstFactor = c.WGPUBlendFactor_Zero, .operation = c.WGPUBlendOperation_Add },
            };

            // Build one WGPUColorTargetState per `fragment.targets[]` entry, honoring
            // each target's declared format. An OMITTED format (the emitter drops it
            // for `preferred-canvas-format`) → BGRA8Unorm. This is what lets a pass
            // rendering into an Rgba8Unorm/Rgba16Float texture match its pipeline
            // (previously every target was hardcoded BGRA8Unorm → validation reject).
            var target_count: usize = 0;
            if (frag_obj.get("targets")) |targets_val| {
                const targets = targets_val.array;
                assert(targets.items.len <= MAX_COLOR_ATTACHMENTS);
                for (targets.items, 0..) |t_val, i| {
                    if (i >= MAX_COLOR_ATTACHMENTS) break;
                    const t_obj = t_val.object;
                    const fmt = if (t_obj.get("format")) |f|
                        parseTextureFormatName(f.string)
                    else
                        c.WGPUTextureFormat_BGRA8Unorm;
                    // Honor the authored blend state (the JSON `blend` object) so
                    // `constant`/`one-minus-constant` factors consume the value set
                    // by set_blend_constant; fall back to replace when unblended.
                    blend_states[i] = if (t_obj.get("blend")) |bv| parseBlendState(bv, default_blend) else default_blend;
                    // Authored channel mask (R=1 G=2 B=4 A=8, same bit values
                    // as WGPUColorWriteMask); absent → All.
                    const write_mask: u64 = if (t_obj.get("writeMask")) |wm|
                        @intCast(@max(0, @min(wm.integer, 15)))
                    else
                        c.WGPUColorWriteMask_All;
                    color_targets[i] = c.WGPUColorTargetState{
                        .nextInChain = null,
                        .format = fmt,
                        .blend = &blend_states[i],
                        .writeMask = write_mask,
                    };
                    target_count = i + 1;
                }
            }
            // A fragment stage with no explicit `targets` (or an empty list) still
            // needs one target — the preferred canvas format.
            if (target_count == 0) {
                blend_states[0] = default_blend;
                color_targets[0] = c.WGPUColorTargetState{
                    .nextInChain = null,
                    .format = c.WGPUTextureFormat_BGRA8Unorm,
                    .blend = &blend_states[0],
                    .writeMask = c.WGPUColorWriteMask_All,
                };
                target_count = 1;
            }
            assert(target_count >= 1 and target_count <= MAX_COLOR_ATTACHMENTS);

            fragment_state = c.WGPUFragmentState{
                .nextInChain = null,
                .module = frag_shader,
                .entryPoint = .{ .data = fragment_entry_z.?.ptr, .length = fragment_entry_z.?.len },
                .constantCount = 0,
                .constants = null,
                .targetCount = target_count,
                .targets = @ptrCast(&color_targets),
            };
        }
        defer if (fragment_entry_z) |z| allocator.free(z);

        // Parse primitive and depth stencil states using helpers
        const primitive = parsePrimitiveState(root);
        var depth_stencil = parseDepthStencilState(root);

        // Create pipeline descriptor
        var descriptor = std.mem.zeroes(c.WGPURenderPipelineDescriptor);
        descriptor.label = .{ .data = null, .length = 0 };
        // Explicit pipeline layout when the descriptor carries a `layoutId` (a
        // (render-pipeline … :pipeline-layout …) reference); otherwise null = auto.
        descriptor.layout = if (root.get("layoutId")) |lid|
            (self.pipeline_layouts[try tableId(lid, MAX_PIPELINE_LAYOUTS)] orelse null)
        else
            null;
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
            .stripIndexFormat = primitive.strip_index_format,
            .frontFace = c.WGPUFrontFace_CCW,
            .cullMode = primitive.cull_mode,
            .unclippedDepth = primitive.unclipped_depth,
        };
        descriptor.depthStencil = if (depth_stencil.has_depth_stencil) &depth_stencil.state else null;

        // Multisample count: honor the pipeline's (multisample :count …). The
        // emitter writes "multisample":{"count":N} only when authored; absent →
        // 1× (no MSAA). The texture bound as this pipeline's render target MUST
        // carry a matching sample-count (create_texture parses :sample-count) or
        // wgpu-native rejects the pipeline as target-incompatible.
        var ms_count: u32 = 1;
        var ms_mask: u32 = 0xFFFFFFFF;
        var ms_a2c: u32 = 0;
        if (root.get("multisample")) |ms_val| {
            if (ms_val.object.get("count")) |cnt| {
                const raw = cnt.integer;
                if (raw >= 1 and raw <= 16) ms_count = @intCast(raw);
            }
            if (ms_val.object.get("mask")) |m| {
                if (m == .integer and m.integer >= 0) ms_mask = @truncate(@as(u64, @intCast(m.integer)));
            }
            if (ms_val.object.get("alphaToCoverageEnabled")) |b| {
                if (b == .bool and b.bool) ms_a2c = 1;
            }
        }
        assert(ms_count >= 1 and ms_count <= 16);
        descriptor.multisample = .{
            .nextInChain = null,
            .count = ms_count,
            .mask = ms_mask,
            .alphaToCoverageEnabled = ms_a2c,
        };
        descriptor.fragment = if (fragment_state != null) &fragment_state.? else null;

        const pipeline = wgpu.deviceCreateRenderPipeline(self.ctx.device, &descriptor);
        if (pipeline == null) {
            return error.PipelineCreationFailed;
        }
        self.render_pipelines[pipeline_id] = pipeline;
    }

    /// Map a WebGPU `GPUVertexFormat` string to its wgpu-native enum. Covers the
    /// full spec set (asserted by tests/npm/webgpu-conformance.test.js: every
    /// schema `vertex-format` member must appear here). The browser path needs no
    /// such map — Emitter writes the string verbatim and WebGPU consumes it; this
    /// per-value map exists only because the native C ABI takes an enum.
    fn parseVertexFormat(fmt: []const u8) c_uint {
        // 8-bit
        if (std.mem.eql(u8, fmt, "uint8")) return c.WGPUVertexFormat_Uint8;
        if (std.mem.eql(u8, fmt, "uint8x2")) return c.WGPUVertexFormat_Uint8x2;
        if (std.mem.eql(u8, fmt, "uint8x4")) return c.WGPUVertexFormat_Uint8x4;
        if (std.mem.eql(u8, fmt, "sint8")) return c.WGPUVertexFormat_Sint8;
        if (std.mem.eql(u8, fmt, "sint8x2")) return c.WGPUVertexFormat_Sint8x2;
        if (std.mem.eql(u8, fmt, "sint8x4")) return c.WGPUVertexFormat_Sint8x4;
        if (std.mem.eql(u8, fmt, "unorm8")) return c.WGPUVertexFormat_Unorm8;
        if (std.mem.eql(u8, fmt, "unorm8x2")) return c.WGPUVertexFormat_Unorm8x2;
        if (std.mem.eql(u8, fmt, "unorm8x4")) return c.WGPUVertexFormat_Unorm8x4;
        if (std.mem.eql(u8, fmt, "snorm8")) return c.WGPUVertexFormat_Snorm8;
        if (std.mem.eql(u8, fmt, "snorm8x2")) return c.WGPUVertexFormat_Snorm8x2;
        if (std.mem.eql(u8, fmt, "snorm8x4")) return c.WGPUVertexFormat_Snorm8x4;
        // 16-bit
        if (std.mem.eql(u8, fmt, "uint16")) return c.WGPUVertexFormat_Uint16;
        if (std.mem.eql(u8, fmt, "uint16x2")) return c.WGPUVertexFormat_Uint16x2;
        if (std.mem.eql(u8, fmt, "uint16x4")) return c.WGPUVertexFormat_Uint16x4;
        if (std.mem.eql(u8, fmt, "sint16")) return c.WGPUVertexFormat_Sint16;
        if (std.mem.eql(u8, fmt, "sint16x2")) return c.WGPUVertexFormat_Sint16x2;
        if (std.mem.eql(u8, fmt, "sint16x4")) return c.WGPUVertexFormat_Sint16x4;
        if (std.mem.eql(u8, fmt, "unorm16")) return c.WGPUVertexFormat_Unorm16;
        if (std.mem.eql(u8, fmt, "unorm16x2")) return c.WGPUVertexFormat_Unorm16x2;
        if (std.mem.eql(u8, fmt, "unorm16x4")) return c.WGPUVertexFormat_Unorm16x4;
        if (std.mem.eql(u8, fmt, "snorm16")) return c.WGPUVertexFormat_Snorm16;
        if (std.mem.eql(u8, fmt, "snorm16x2")) return c.WGPUVertexFormat_Snorm16x2;
        if (std.mem.eql(u8, fmt, "snorm16x4")) return c.WGPUVertexFormat_Snorm16x4;
        if (std.mem.eql(u8, fmt, "float16")) return c.WGPUVertexFormat_Float16;
        if (std.mem.eql(u8, fmt, "float16x2")) return c.WGPUVertexFormat_Float16x2;
        if (std.mem.eql(u8, fmt, "float16x4")) return c.WGPUVertexFormat_Float16x4;
        // 32-bit
        if (std.mem.eql(u8, fmt, "float32")) return c.WGPUVertexFormat_Float32;
        if (std.mem.eql(u8, fmt, "float32x2")) return c.WGPUVertexFormat_Float32x2;
        if (std.mem.eql(u8, fmt, "float32x3")) return c.WGPUVertexFormat_Float32x3;
        if (std.mem.eql(u8, fmt, "float32x4")) return c.WGPUVertexFormat_Float32x4;
        if (std.mem.eql(u8, fmt, "uint32")) return c.WGPUVertexFormat_Uint32;
        if (std.mem.eql(u8, fmt, "uint32x2")) return c.WGPUVertexFormat_Uint32x2;
        if (std.mem.eql(u8, fmt, "uint32x3")) return c.WGPUVertexFormat_Uint32x3;
        if (std.mem.eql(u8, fmt, "uint32x4")) return c.WGPUVertexFormat_Uint32x4;
        if (std.mem.eql(u8, fmt, "sint32")) return c.WGPUVertexFormat_Sint32;
        if (std.mem.eql(u8, fmt, "sint32x2")) return c.WGPUVertexFormat_Sint32x2;
        if (std.mem.eql(u8, fmt, "sint32x3")) return c.WGPUVertexFormat_Sint32x3;
        if (std.mem.eql(u8, fmt, "sint32x4")) return c.WGPUVertexFormat_Sint32x4;
        // packed
        if (std.mem.eql(u8, fmt, "unorm10-10-10-2")) return c.WGPUVertexFormat_Unorm10_10_10_2;
        if (std.mem.eql(u8, fmt, "unorm8x4-bgra")) return c.WGPUVertexFormat_Unorm8x4BGRA;
        return c.WGPUVertexFormat_Float32x4;
    }

    /// Map a WebGPU `GPUTextureFormat` string (as spelled in the render-pipeline
    /// descriptor JSON at `fragment.targets[].format`) to its wgpu-native enum.
    /// The string sibling of `decodeTextureFormat` (the byte→enum map used on the
    /// TLV texture path): the render-pipeline descriptor is JSON, not TLV, so the
    /// color-target format arrives as a string. Unknown/absent → BGRA8Unorm, the
    /// preferred canvas format — matching the emitter, which OMITS the `format`
    /// key for `preferred-canvas-format` targets (see appendTarget).
    fn parseTextureFormatName(name: []const u8) c_uint {
        const map = std.StaticStringMap(c_uint).initComptime(.{
            // 8-bit
            .{ "r8unorm", c.WGPUTextureFormat_R8Unorm },
            .{ "r8snorm", c.WGPUTextureFormat_R8Snorm },
            .{ "r8uint", c.WGPUTextureFormat_R8Uint },
            .{ "r8sint", c.WGPUTextureFormat_R8Sint },
            .{ "rg8unorm", c.WGPUTextureFormat_RG8Unorm },
            .{ "rg8snorm", c.WGPUTextureFormat_RG8Snorm },
            .{ "rg8uint", c.WGPUTextureFormat_RG8Uint },
            .{ "rg8sint", c.WGPUTextureFormat_RG8Sint },
            .{ "rgba8unorm", c.WGPUTextureFormat_RGBA8Unorm },
            .{ "rgba8unorm-srgb", c.WGPUTextureFormat_RGBA8UnormSrgb },
            .{ "rgba8snorm", c.WGPUTextureFormat_RGBA8Snorm },
            .{ "rgba8uint", c.WGPUTextureFormat_RGBA8Uint },
            .{ "rgba8sint", c.WGPUTextureFormat_RGBA8Sint },
            .{ "bgra8unorm", c.WGPUTextureFormat_BGRA8Unorm },
            .{ "bgra8unorm-srgb", c.WGPUTextureFormat_BGRA8UnormSrgb },
            // 16-bit
            .{ "r16uint", c.WGPUTextureFormat_R16Uint },
            .{ "r16sint", c.WGPUTextureFormat_R16Sint },
            .{ "r16float", c.WGPUTextureFormat_R16Float },
            .{ "rg16uint", c.WGPUTextureFormat_RG16Uint },
            .{ "rg16sint", c.WGPUTextureFormat_RG16Sint },
            .{ "rg16float", c.WGPUTextureFormat_RG16Float },
            .{ "rgba16uint", c.WGPUTextureFormat_RGBA16Uint },
            .{ "rgba16sint", c.WGPUTextureFormat_RGBA16Sint },
            .{ "rgba16float", c.WGPUTextureFormat_RGBA16Float },
            // 32-bit
            .{ "r32uint", c.WGPUTextureFormat_R32Uint },
            .{ "r32sint", c.WGPUTextureFormat_R32Sint },
            .{ "r32float", c.WGPUTextureFormat_R32Float },
            .{ "rg32uint", c.WGPUTextureFormat_RG32Uint },
            .{ "rg32sint", c.WGPUTextureFormat_RG32Sint },
            .{ "rg32float", c.WGPUTextureFormat_RG32Float },
            .{ "rgba32uint", c.WGPUTextureFormat_RGBA32Uint },
            .{ "rgba32sint", c.WGPUTextureFormat_RGBA32Sint },
            .{ "rgba32float", c.WGPUTextureFormat_RGBA32Float },
            // packed
            .{ "rgb10a2unorm", c.WGPUTextureFormat_RGB10A2Unorm },
            .{ "rgb10a2uint", c.WGPUTextureFormat_RGB10A2Uint },
            .{ "rg11b10ufloat", c.WGPUTextureFormat_RG11B10Ufloat },
            .{ "rgb9e5ufloat", c.WGPUTextureFormat_RGB9E5Ufloat },
        });
        return map.get(name) orelse c.WGPUTextureFormat_BGRA8Unorm;
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

    /// Map a GPUStencilOperation name (schema value-kind `stencil-operation`) to
    /// its wgpu-native enum. Default `Keep` matches WebGPU's stencil-face default.
    fn parseStencilOperation(op: []const u8) c_uint {
        if (std.mem.eql(u8, op, "keep")) return c.WGPUStencilOperation_Keep;
        if (std.mem.eql(u8, op, "zero")) return c.WGPUStencilOperation_Zero;
        if (std.mem.eql(u8, op, "replace")) return c.WGPUStencilOperation_Replace;
        if (std.mem.eql(u8, op, "invert")) return c.WGPUStencilOperation_Invert;
        if (std.mem.eql(u8, op, "increment-clamp")) return c.WGPUStencilOperation_IncrementClamp;
        if (std.mem.eql(u8, op, "decrement-clamp")) return c.WGPUStencilOperation_DecrementClamp;
        if (std.mem.eql(u8, op, "increment-wrap")) return c.WGPUStencilOperation_IncrementWrap;
        if (std.mem.eql(u8, op, "decrement-wrap")) return c.WGPUStencilOperation_DecrementWrap;
        return c.WGPUStencilOperation_Keep;
    }

    /// Parse a `stencilFront`/`stencilBack` JSON face object into a face state,
    /// honoring only authored keys (the emitter emits only those). Unset keys take
    /// the WebGPU defaults: compare=Always, all three ops=Keep.
    fn parseStencilFace(face_val: std.json.Value) c.WGPUStencilFaceState {
        var face = c.WGPUStencilFaceState{
            .compare = c.WGPUCompareFunction_Always,
            .failOp = c.WGPUStencilOperation_Keep,
            .depthFailOp = c.WGPUStencilOperation_Keep,
            .passOp = c.WGPUStencilOperation_Keep,
        };
        const obj = switch (face_val) {
            .object => |o| o,
            else => return face,
        };
        if (obj.get("compare")) |v| face.compare = parseCompareFunction(v.string);
        if (obj.get("failOp")) |v| face.failOp = parseStencilOperation(v.string);
        if (obj.get("depthFailOp")) |v| face.depthFailOp = parseStencilOperation(v.string);
        if (obj.get("passOp")) |v| face.passOp = parseStencilOperation(v.string);
        return face;
    }

    /// Map a GPUBlendFactor name (schema value-kind `blend-factor`) to its
    /// wgpu-native enum. `constant`/`one-minus-constant` reference the value set
    /// by set_blend_constant (Arc-3 §5.2). Default `One` on an unknown name.
    fn parseBlendFactor(name: []const u8) c_uint {
        if (std.mem.eql(u8, name, "zero")) return c.WGPUBlendFactor_Zero;
        if (std.mem.eql(u8, name, "one")) return c.WGPUBlendFactor_One;
        if (std.mem.eql(u8, name, "src")) return c.WGPUBlendFactor_Src;
        if (std.mem.eql(u8, name, "one-minus-src")) return c.WGPUBlendFactor_OneMinusSrc;
        if (std.mem.eql(u8, name, "src-alpha")) return c.WGPUBlendFactor_SrcAlpha;
        if (std.mem.eql(u8, name, "one-minus-src-alpha")) return c.WGPUBlendFactor_OneMinusSrcAlpha;
        if (std.mem.eql(u8, name, "dst")) return c.WGPUBlendFactor_Dst;
        if (std.mem.eql(u8, name, "one-minus-dst")) return c.WGPUBlendFactor_OneMinusDst;
        if (std.mem.eql(u8, name, "dst-alpha")) return c.WGPUBlendFactor_DstAlpha;
        if (std.mem.eql(u8, name, "one-minus-dst-alpha")) return c.WGPUBlendFactor_OneMinusDstAlpha;
        if (std.mem.eql(u8, name, "src-alpha-saturated")) return c.WGPUBlendFactor_SrcAlphaSaturated;
        if (std.mem.eql(u8, name, "constant")) return c.WGPUBlendFactor_Constant;
        if (std.mem.eql(u8, name, "one-minus-constant")) return c.WGPUBlendFactor_OneMinusConstant;
        // The four dual-source src1* factors are absent from the vendored
        // wgpu-native header until the vendor bump (ledgered by the native
        // conformance gate, spec/05). Fail loud, don't blend-wrong silently:
        // parse runs once per pipeline, so a per-occurrence print is fine, and
        // `stub` reclassifies the render under --strict-native-stubs.
        std.debug.print("[native] unsupported blend-factor '{s}' — using one\n", .{name});
        stub.note("blend-factor (unsupported)");
        return c.WGPUBlendFactor_One;
    }

    /// Map a GPUBlendOperation name (schema value-kind `blend-operation`) to its
    /// wgpu-native enum. Default `Add` matches WebGPU's blend-component default.
    fn parseBlendOperation(name: []const u8) c_uint {
        if (std.mem.eql(u8, name, "add")) return c.WGPUBlendOperation_Add;
        if (std.mem.eql(u8, name, "subtract")) return c.WGPUBlendOperation_Subtract;
        if (std.mem.eql(u8, name, "reverse-subtract")) return c.WGPUBlendOperation_ReverseSubtract;
        if (std.mem.eql(u8, name, "min")) return c.WGPUBlendOperation_Min;
        if (std.mem.eql(u8, name, "max")) return c.WGPUBlendOperation_Max;
        return c.WGPUBlendOperation_Add;
    }

    /// Parse a blend component `{srcFactor,dstFactor,operation}`. Unset keys take
    /// the WebGPU component defaults (srcFactor=One, dstFactor=Zero, operation=Add).
    fn parseBlendComponent(comp_val: std.json.Value) c.WGPUBlendComponent {
        var comp = c.WGPUBlendComponent{
            .srcFactor = c.WGPUBlendFactor_One,
            .dstFactor = c.WGPUBlendFactor_Zero,
            .operation = c.WGPUBlendOperation_Add,
        };
        const obj = switch (comp_val) {
            .object => |o| o,
            else => return comp,
        };
        if (obj.get("srcFactor")) |v| comp.srcFactor = parseBlendFactor(v.string);
        if (obj.get("dstFactor")) |v| comp.dstFactor = parseBlendFactor(v.string);
        if (obj.get("operation")) |v| comp.operation = parseBlendOperation(v.string);
        return comp;
    }

    /// Parse a target's `blend` object into a WGPUBlendState. Absent color/alpha
    /// components fall back to `fallback`'s corresponding component. Previously the
    /// authored blend was ignored entirely (every target used the replace default),
    /// so blended examples rendered without blending on native (Arc-3 §5.2).
    fn parseBlendState(blend_val: std.json.Value, fallback: c.WGPUBlendState) c.WGPUBlendState {
        var st = fallback;
        const obj = switch (blend_val) {
            .object => |o| o,
            else => return st,
        };
        if (obj.get("color")) |v| st.color = parseBlendComponent(v);
        if (obj.get("alpha")) |v| st.alpha = parseBlendComponent(v);
        return st;
    }

    /// Vertex buffer layout parsing result for render pipeline creation.
    const VertexLayoutResult = struct {
        buffer_layouts: [4]c.WGPUVertexBufferLayout,
        attributes: [4][8]c.WGPUVertexAttribute,
        buffer_count: usize,
    };

    /// Parse vertex buffer layouts from JSON descriptor into caller-owned
    /// storage. Extracts array stride, step mode, and vertex attributes.
    ///
    /// MUST fill `result` in place (via a pointer) rather than return a
    /// `VertexLayoutResult` by value: each `buffer_layouts[bi].attributes`
    /// points into `result.attributes[bi]`, so returning by value would leave
    /// those interior pointers dangling into the freed callee stack. wgpu-native
    /// then reads a garbage vertex format and aborts the process
    /// ("invalid vertex format for vertex attribute: 0"). The caller keeps
    /// `result` alive through deviceCreateRenderPipeline, keeping them valid.
    fn parseVertexBufferLayouts(result: *VertexLayoutResult, vertex_obj: std.json.ObjectMap) void {
        result.buffer_count = 0;

        const buffers_val = vertex_obj.get("buffers") orelse return;
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
            assert(attr_count <= 8);

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

        assert(result.buffer_count <= 4);
    }

    /// Primitive state parsing result.
    const PrimitiveStateResult = struct {
        topology: u32,
        cull_mode: u32,
        strip_index_format: u32,
        unclipped_depth: c.WGPUBool,
    };

    /// Parse primitive state from JSON descriptor.
    fn parsePrimitiveState(root: std.json.ObjectMap) PrimitiveStateResult {
        var result = PrimitiveStateResult{
            .topology = c.WGPUPrimitiveTopology_TriangleList,
            .cull_mode = c.WGPUCullMode_None,
            .strip_index_format = c.WGPUIndexFormat_Undefined,
            .unclipped_depth = 0,
        };

        const prim_val = root.get("primitive") orelse return result;
        const prim_obj = prim_val.object;

        if (prim_obj.get("topology")) |topo_val| {
            result.topology = parseTopology(topo_val.string);
        }
        if (prim_obj.get("cullMode")) |cull_val| {
            result.cull_mode = parseCullMode(cull_val.string);
        }
        if (prim_obj.get("stripIndexFormat")) |sif_val| {
            result.strip_index_format = if (std.mem.eql(u8, sif_val.string, "uint32"))
                c.WGPUIndexFormat_Uint32
            else
                c.WGPUIndexFormat_Uint16;
        }
        // unclippedDepth needs the depth-clip-control device feature (requested
        // opportunistically at device creation); wgpu-native rejects the pipeline
        // if it is set without the feature enabled.
        if (prim_obj.get("unclippedDepth")) |ud_val| {
            result.unclipped_depth = @intFromBool(ud_val.bool);
        }

        return result;
    }

    /// Depth stencil state parsing result.
    pub const DepthStencilResult = struct {
        state: c.WGPUDepthStencilState,
        has_depth_stencil: bool,
    };

    /// Coerce a JSON number (emitted as either an int or a float literal) to f32.
    fn jsonToF32(v: std.json.Value) f32 {
        return switch (v) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => 0,
        };
    }

    /// Parse depth stencil state from JSON descriptor.
    pub fn parseDepthStencilState(root: std.json.ObjectMap) DepthStencilResult {
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

        // Stencil state: parse authored stencilFront/stencilBack faces (each key
        // defaults to compare=Always / op=Keep when absent). The two faces are
        // INDEPENDENT — `GPUDepthStencilState` declares `stencilFront` and
        // `stencilBack` as separate optional dictionaries, each defaulting to `{}`,
        // and a WebIDL default cannot reference a sibling member. This matters
        // because gpu.js hands the descriptor to createRenderPipeline untouched
        // (`gpu.js:411`), so an unauthored back face takes the spec default in the
        // browser; a native fallback to the front face would silently mask
        // differently on the two backends. (It did until r2-05: the fallback was
        // introduced with the §214-era stencil work and its "matching WebGPU" claim
        // went unchecked because no fixture rasterized a back face — removing it
        // left every render test green, which was read as the unit test earning its
        // keep rather than as the behaviour being unreachable. `test_stencil_back`
        // is the fixture that reaches it.)
        const default_face: c.WGPUStencilFaceState = .{
            .compare = c.WGPUCompareFunction_Always,
            .failOp = c.WGPUStencilOperation_Keep,
            .depthFailOp = c.WGPUStencilOperation_Keep,
            .passOp = c.WGPUStencilOperation_Keep,
        };
        result.state.stencilFront = if (ds_obj.get("stencilFront")) |sf|
            parseStencilFace(sf)
        else
            default_face;
        result.state.stencilBack = if (ds_obj.get("stencilBack")) |sb|
            parseStencilFace(sb)
        else
            default_face;
        result.state.stencilReadMask = if (ds_obj.get("stencilReadMask")) |m| @intCast(m.integer) else 0xFFFFFFFF;
        result.state.stencilWriteMask = if (ds_obj.get("stencilWriteMask")) |m| @intCast(m.integer) else 0xFFFFFFFF;
        // Depth bias (shadow maps: constant + slope-scaled offset to kill acne).
        // depthBias is an int, slope-scale/clamp floats; the emitter emits only
        // authored keys, so absent → 0 (WebGPU default).
        result.state.depthBias = if (ds_obj.get("depthBias")) |v| @intCast(v.integer) else 0;
        result.state.depthBiasSlopeScale = if (ds_obj.get("depthBiasSlopeScale")) |v| jsonToF32(v) else 0;
        result.state.depthBiasClamp = if (ds_obj.get("depthBiasClamp")) |v| jsonToF32(v) else 0;

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
            // Headless: render into the persistent offscreen target. is_surface
            // is false — it is released in deinit(), not after submit().
            if (self.surface == null) {
                return .{
                    .view = self.offscreen_view orelse return error.NoSurfaceConfigured,
                    .is_surface = false,
                };
            }
            const surface = self.surface.?;
            var surface_texture: wgpu.SurfaceTexture = undefined;
            wgpu.surfaceGetCurrentTexture(surface, &surface_texture);

            // From here on the acquisition is OWNED — every exit must either
            // latch it (so submit/abort/deinit release it) or release it here.
            // wgpu can hand back a texture alongside a non-success status
            // (Timeout, Outdated), so the error paths release rather than assume
            // null.
            errdefer if (surface_texture.texture != null) wgpu.textureRelease(surface_texture.texture);

            const status = surface_texture.status;
            if (status != c.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal and
                status != c.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal)
            {
                return error.SurfaceTextureUnavailable;
            }

            if (surface_texture.texture == null) return error.SurfaceTextureUnavailable;
            const view = wgpu.textureCreateView(surface_texture.texture, null);
            if (view == null) return error.SurfaceTextureUnavailable;

            // Release-before-overwrite: two passes in one frame that both target
            // the surface (a `load`-op second pass over the canvas) would
            // otherwise strand the first acquisition.
            self.releaseSurfaceTexture();
            self.current_surface_texture = surface_texture.texture;
            return .{ .view = view, .is_surface = true };
        }

        // Render to custom texture. The id comes off the wire and 0xFFFE (the
        // surface sentinel) is the only above-table value with a meaning — the
        // rest are `TextureNotFound`, the same answer an empty slot gives.
        if (color_texture_id >= MAX_TEXTURES) return error.TextureNotFound;
        if (self.texture_views[color_texture_id]) |v| {
            return .{ .view = v, .is_surface = false };
        }
        if (self.textures[color_texture_id]) |t| {
            const view = wgpu.textureCreateView(t, null);
            if (view == null) return error.TextureNotFound;
            // Cache it (LEAK-01 B). Returned uncached, this view was stored only
            // in the caller's stack-local attachment descriptor: submit()
            // releases just `current_surface_view` and deinit() only walks the
            // tables, so it leaked once per pass per frame. The cache is only
            // ever populated by create_bind_group's texture arm, so any target
            // rendered TO but never bound as a plain `:texture` — an MSAA color
            // target, a write-only attachment — missed it forever.
            //
            // `texture_views` is the right table and not merely a convenient
            // one: deinit() already sweeps it, and its entries carry exactly
            // these semantics (createView(null) = all mips, inferred dimension),
            // so a texture that is both rendered to and sampled now shares one
            // view instead of holding two identical ones.
            self.texture_views[color_texture_id] = view;
            return .{ .view = view, .is_surface = false };
        }
        return error.TextureNotFound;
    }

    /// Release the latched swapchain texture, if any. Idempotent — every frame
    /// exit (submit, abortFrame, deinit, a second acquisition) calls it.
    fn releaseSurfaceTexture(self: *Self) void {
        if (self.current_surface_texture) |t| {
            wgpu.textureRelease(t);
            self.current_surface_texture = null;
        }
    }

    /// Latch this frame's surface view, releasing any previous one.
    ///
    /// The two call sites in `begin_render_pass` (color, then MSAA resolve) and
    /// the MRT twin all used to assign unconditionally, so a frame with two
    /// surface-targeting passes leaked every view but the last — submit()
    /// releases exactly one. The `assert(!color_is_surface)` that used to guard
    /// the resolve case is Debug-only, i.e. compiled out precisely where hostile
    /// bytecode runs.
    fn latchSurfaceView(self: *Self, view: wgpu.TextureView) void {
        if (self.current_surface_view) |old| {
            if (old != view) wgpu.textureViewRelease(old);
        }
        self.current_surface_view = view;
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
    /// Creates the attachment view with the aspect the texture's format demands:
    /// `All` for a combined depth+stencil format (else wgpu-native rejects the
    /// pass — "Unable to view Depth24PlusStencil8 as Depth24PlusStencil8"),
    /// `DepthOnly` for a depth-only format. Consumes the pending depth/stencil
    /// load-store ops (see `set_pass_depth_stencil_ops`); the caller resets them.
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

        // A combined depth+stencil format needs the stencil aspect in both the
        // view (aspect=All) and the attachment's stencil ops; a depth-only format
        // needs neither (setting stencil ops on it is a wgpu-native validation
        // error). depth24plus-stencil8 is the only combined format we emit.
        const tex_format = self.texture_formats[depth_texture_id];
        const has_stencil = tex_format == c.WGPUTextureFormat_Depth24PlusStencil8;

        // Create view for depth texture with correct aspect
        var depth_view_desc = std.mem.zeroes(c.WGPUTextureViewDescriptor);
        depth_view_desc.format = tex_format;
        depth_view_desc.dimension = c.WGPUTextureViewDimension_2D;
        depth_view_desc.aspect = if (has_stencil) c.WGPUTextureAspect_All else c.WGPUTextureAspect_DepthOnly;
        depth_view_desc.baseMipLevel = 0;
        depth_view_desc.mipLevelCount = 1;
        depth_view_desc.baseArrayLayer = 0;
        depth_view_desc.arrayLayerCount = 1;

        const depth_view = wgpu.textureCreateView(depth_tex, &depth_view_desc);
        if (depth_view == null) return result;

        // Map the pending ops (LoadOp{load=0,clear=1}, StoreOp{store=0,discard=1}).
        assert(self.pending_depth_load_op <= 1 and self.pending_depth_store_op <= 1);
        assert(self.pending_stencil_load_op <= 1 and self.pending_stencil_store_op <= 1);
        const depth_load: c_uint = if (self.pending_depth_load_op == 0) c.WGPULoadOp_Load else c.WGPULoadOp_Clear;
        const depth_store: c_uint = if (self.pending_depth_store_op == 0) c.WGPUStoreOp_Store else c.WGPUStoreOp_Discard;

        result.view = depth_view;
        result.valid = true;
        result.attachment = std.mem.zeroes(c.WGPURenderPassDepthStencilAttachment);
        result.attachment.view = depth_view;
        result.attachment.depthLoadOp = depth_load;
        result.attachment.depthStoreOp = depth_store;
        result.attachment.depthClearValue = self.pending_depth_clear_value;
        if (has_stencil) {
            result.attachment.stencilLoadOp = if (self.pending_stencil_load_op == 0) c.WGPULoadOp_Load else c.WGPULoadOp_Clear;
            result.attachment.stencilStoreOp = if (self.pending_stencil_store_op == 0) c.WGPUStoreOp_Store else c.WGPUStoreOp_Discard;
        } else {
            result.attachment.stencilLoadOp = c.WGPULoadOp_Undefined;
            result.attachment.stencilStoreOp = c.WGPUStoreOp_Undefined;
        }
        result.attachment.stencilClearValue = self.pending_stencil_clear_value;
        result.attachment.stencilReadOnly = 0;
        result.attachment.depthReadOnly = 0;

        return result;
    }

    /// Reset the pending depth/stencil ops to the clear/store defaults. Called by
    /// begin_render_pass{,_mrt} after `setupDepthAttachment` has consumed them, so
    /// a following pass that emits no `set_pass_depth_stencil_ops` sees defaults.
    fn resetPendingDepthStencilOps(self: *Self) void {
        self.pending_depth_load_op = @intFromEnum(LoadOp.clear);
        self.pending_depth_store_op = @intFromEnum(StoreOp.store);
        self.pending_stencil_load_op = @intFromEnum(LoadOp.clear);
        self.pending_stencil_store_op = @intFromEnum(StoreOp.store);
        self.pending_depth_clear_value = 1.0;
        self.pending_stencil_clear_value = 0;
        assert(self.pending_depth_load_op == 1 and self.pending_stencil_load_op == 1);
    }

    pub fn create_compute_pipeline(self: *Self, allocator: Allocator, pipeline_id: u16, descriptor_data_id: u16) !void {
        if (pipeline_id >= MAX_COMPUTE_PIPELINES) return error.InvalidResourceId; // untrusted id
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
        if (compute_shader_id >= MAX_SHADERS) return error.InvalidResourceId; // id from data
        const entry_len = desc_data[3];

        // Default entry point if none specified
        var entry_point: []const u8 = "main";
        if (entry_len > 0 and desc_data.len >= 4 + entry_len) {
            entry_point = desc_data[4..][0..entry_len];
        }

        const compute_shader = self.shaders[compute_shader_id] orelse return error.InvalidResourceId;

        // Optional trailing u16 pipeline-layout id at offset 4+entry_len (a
        // (compute-pipeline … :pipeline-layout …) reference); absent → auto layout.
        // Same slot gpu.js probes past the entry point.
        var layout: c.WGPUPipelineLayout = null;
        const layout_off: usize = 4 + @as(usize, entry_len);
        if (desc_data.len >= layout_off + 2) {
            const layout_id: u16 = @as(u16, desc_data[layout_off]) | (@as(u16, desc_data[layout_off + 1]) << 8);
            if (layout_id < MAX_PIPELINE_LAYOUTS) layout = self.pipeline_layouts[layout_id] orelse null;
        }

        // Create null-terminated entry point string
        const entry_z = try allocator.allocSentinel(u8, entry_point.len, 0);
        defer allocator.free(entry_z);
        @memcpy(entry_z, entry_point);

        // Create compute pipeline descriptor
        var descriptor = std.mem.zeroes(c.WGPUComputePipelineDescriptor);
        descriptor.label = .{ .data = null, .length = 0 };
        descriptor.layout = layout; // explicit pipeline layout or null = auto
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
        nativeLog("create_compute_pipeline: id={}, shader_id={}, entry={s}, result={}\n", .{
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

    pub fn create_bind_group(self: *Self, allocator: Allocator, group_id: u16, layout_id: u16, entry_data_id: u16) !void {
        if (group_id >= MAX_BIND_GROUPS) return error.InvalidResourceId; // untrusted id
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

        // Resolve the group's layout in the id space the operand NAMES — the tag bit
        // says which (bytecode.opcodes.BIND_GROUP_LAYOUT_TAG). This used to try
        // render pipeline → compute pipeline → bgl in order and take the first hit,
        // which is a guess: the two spaces are both numbered from 0, so a compute
        // group's bgl id 0 resolved to RENDER pipeline 0's layout. It survived only
        // because the corpus' explicit-BGL fixtures had both ids equal to 0.
        //
        // There is no fallback between the spaces on purpose. An auto-derived layout
        // is exclusive to its own pipeline and an explicit one is incompatible with
        // any auto-layout pipeline, so substituting either for the other is a silent
        // layout swap that WebGPU rejects at draw time (journal §339).
        //
        // Ownership travels with the resolution: `*GetBindGroupLayout` returns a
        // NEW owned reference per call, while the explicit table's object is
        // borrowed (deinit's `bind_group_layouts[]` sweep releases that one).
        // Before LEAK-02 B the derived reference was used for the create and
        // dropped — no table held it, so nothing could ever release it, on the
        // success path or on the `entry_count == 0` early return. That is the
        // common case: every auto-layout bind group in every payload.
        const resolved: struct { layout: c.WGPUBindGroupLayout, derived: bool } = blk: {
            if (opcodes.layoutIdIsBindGroupLayout(layout_id)) {
                const bgl_id = opcodes.layoutIdValue(layout_id);
                if (bgl_id < MAX_BIND_GROUP_LAYOUTS) {
                    if (self.bind_group_layouts[bgl_id]) |explicit_layout| {
                        break :blk .{ .layout = explicit_layout, .derived = false };
                    }
                }
                break :blk .{ .layout = null, .derived = false };
            }
            if (layout_id < MAX_RENDER_PIPELINES) {
                if (self.render_pipelines[layout_id]) |pipeline| {
                    break :blk .{ .layout = wgpu.renderPipelineGetBindGroupLayout(pipeline, group_index), .derived = true };
                }
            }
            if (layout_id < MAX_COMPUTE_PIPELINES) {
                if (self.compute_pipelines[layout_id]) |pipeline| {
                    break :blk .{ .layout = wgpu.computePipelineGetBindGroupLayout(pipeline, group_index), .derived = true };
                }
            }
            break :blk .{ .layout = null, .derived = false };
        };
        const layout = resolved.layout;
        // Hand the derived reference back once the bind group has taken its own:
        // WebGPU refcounts through the bind group, so this is the whole lifetime
        // (gpu.js holds no reference either). Never released for the borrowed
        // explicit layout — that one belongs to the table.
        defer if (resolved.derived and layout != null) wgpu.bindGroupLayoutRelease(layout);
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
                                // size 0 = "rest of the buffer" (the wire's whole-buffer
                                // default) — measured FROM the offset, else a sliced
                                // binding overruns the buffer and fails validation.
                                // Saturating: a malformed payload with offset past the
                                // end must surface as a wgpu validation error, not a
                                // Zig integer-underflow panic.
                                entry.size = if (buf_size == 0) wgpu.bufferGetSize(buffer) -| buf_offset else buf_size;
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
                                // Create view and store for reuse. WebGPU
                                // createView(null) semantics: ALL remaining
                                // mips/layers, dimension inferred from the
                                // texture — a mipped texture bound by name
                                // must sample its full chain (the browser
                                // runtime does; a hardcoded mipLevelCount=1
                                // silently clamped native sampling to mip 0).
                                var view_desc = std.mem.zeroes(c.WGPUTextureViewDescriptor);
                                view_desc.format = self.texture_formats[rid];
                                view_desc.dimension = c.WGPUTextureViewDimension_Undefined;
                                view_desc.baseMipLevel = 0;
                                view_desc.mipLevelCount = 0xFFFFFFFF; // WGPU_MIP_LEVEL_COUNT_UNDEFINED
                                view_desc.baseArrayLayer = 0;
                                view_desc.arrayLayerCount = 0xFFFFFFFF; // WGPU_ARRAY_LAYER_COUNT_UNDEFINED
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
                    } else if (rt == 4) {
                        // Explicit (texture-view …) binding: bind the pre-created
                        // view object by VIEW id (its own space, not a texture id).
                        if (rid < MAX_TEXTURE_VIEWS) {
                            if (self.explicit_texture_views[rid]) |v| entry.textureView = v;
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
        nativeLog("create_bind_group: id={}, layout_id={}, entries={}, result={}\n", .{
            group_id,
            layout_id,
            entry_count,
            bind_group != null,
        });
        _ = allocator; // Interface requirement - native backend doesn't need allocator
    }

    pub fn create_bind_group_layout(self: *Self, allocator: Allocator, layout_id: u16, descriptor_data_id: u16) !void {
        if (layout_id >= MAX_BIND_GROUP_LAYOUTS) return error.InvalidResourceId; // untrusted id
        assert(self.module != null);

        // Skip if layout already exists
        if (self.bind_group_layouts[layout_id] != null) {
            return;
        }

        const module = self.module.?;
        const data = module.data.get(DataId.fromInt(descriptor_data_id));

        // JSON descriptor `{"entries":[{"binding":N,"visibility":F,"buffer":{"type":"T"}}]}`
        // — the shape the emitter builds (emitBindGroupLayout) and the browser
        // command-buffer path parses (gpu-resource-pass-commands case 0x0A). Only
        // buffer bindings are modeled today (uniform_access's sole kind); the encoder
        // gains sampler/texture entries later, and this parser extends alongside it.
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
        defer parsed.deinit();
        const json_entries = (parsed.value.object.get("entries") orelse return).array;
        if (json_entries.items.len == 0 or json_entries.items.len > 16) return;

        var entries: [16]c.WGPUBindGroupLayoutEntry = undefined;
        var parsed_count: usize = 0;
        for (json_entries.items) |e_val| {
            const e_obj = e_val.object;
            var entry = std.mem.zeroes(c.WGPUBindGroupLayoutEntry);
            entry.binding = @intCast((e_obj.get("binding") orelse continue).integer);
            entry.visibility = @intCast((e_obj.get("visibility") orelse continue).integer);
            // Mark every binding type "not used", then light up the one present.
            entry.buffer.type = c.WGPUBufferBindingType_BindingNotUsed;
            entry.sampler.type = c.WGPUSamplerBindingType_BindingNotUsed;
            entry.texture.sampleType = c.WGPUTextureSampleType_BindingNotUsed;
            entry.storageTexture.access = c.WGPUStorageTextureAccess_BindingNotUsed;
            if (e_obj.get("buffer")) |buf_val| {
                const bt = if (buf_val.object.get("type")) |t| t.string else "uniform";
                entry.buffer.type = if (std.mem.eql(u8, bt, "storage"))
                    c.WGPUBufferBindingType_Storage
                else if (std.mem.eql(u8, bt, "read-only-storage"))
                    c.WGPUBufferBindingType_ReadOnlyStorage
                else
                    c.WGPUBufferBindingType_Uniform;
            }
            if (e_obj.get("sampler")) |s_val| {
                const st = if (s_val.object.get("type")) |t| t.string else "filtering";
                entry.sampler.type = mapSamplerBindingTypeStr(st);
            }
            if (e_obj.get("texture")) |t_val| {
                const to = t_val.object;
                entry.texture.sampleType = mapTextureSampleTypeStr(if (to.get("sampleType")) |s| s.string else "float");
                entry.texture.viewDimension = mapViewDimensionStr(if (to.get("viewDimension")) |v| v.string else "2d");
                entry.texture.multisampled = if (to.get("multisampled")) |m| @intFromBool(m == .bool and m.bool) else 0;
            }
            if (e_obj.get("storageTexture")) |st_val| {
                const so = st_val.object;
                entry.storageTexture.access = mapStorageAccessStr(if (so.get("access")) |a| a.string else "write-only");
                entry.storageTexture.format = mapStorageFormatStr(if (so.get("format")) |f| f.string else "rgba8unorm");
                entry.storageTexture.viewDimension = mapViewDimensionStr(if (so.get("viewDimension")) |v| v.string else "2d");
            }
            entries[parsed_count] = entry;
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
    }

    // BGL non-buffer resource strings → wgpu enums. The emitter writes the WebGPU
    // spellings into the descriptor JSON (values.zig map*/viewDimensionString); these
    // read them back. Unknown input falls to the WebGPU default.
    fn mapSamplerBindingTypeStr(s: []const u8) c_uint {
        if (std.mem.eql(u8, s, "non-filtering")) return c.WGPUSamplerBindingType_NonFiltering;
        if (std.mem.eql(u8, s, "comparison")) return c.WGPUSamplerBindingType_Comparison;
        return c.WGPUSamplerBindingType_Filtering;
    }
    fn mapTextureSampleTypeStr(s: []const u8) c_uint {
        if (std.mem.eql(u8, s, "unfilterable-float")) return c.WGPUTextureSampleType_UnfilterableFloat;
        if (std.mem.eql(u8, s, "depth")) return c.WGPUTextureSampleType_Depth;
        if (std.mem.eql(u8, s, "sint")) return c.WGPUTextureSampleType_Sint;
        if (std.mem.eql(u8, s, "uint")) return c.WGPUTextureSampleType_Uint;
        return c.WGPUTextureSampleType_Float;
    }
    fn mapStorageAccessStr(s: []const u8) c_uint {
        if (std.mem.eql(u8, s, "read-only")) return c.WGPUStorageTextureAccess_ReadOnly;
        if (std.mem.eql(u8, s, "read-write")) return c.WGPUStorageTextureAccess_ReadWrite;
        return c.WGPUStorageTextureAccess_WriteOnly;
    }
    fn mapViewDimensionStr(s: []const u8) c_uint {
        if (std.mem.eql(u8, s, "1d")) return c.WGPUTextureViewDimension_1D;
        if (std.mem.eql(u8, s, "2d-array")) return c.WGPUTextureViewDimension_2DArray;
        if (std.mem.eql(u8, s, "cube")) return c.WGPUTextureViewDimension_Cube;
        if (std.mem.eql(u8, s, "cube-array")) return c.WGPUTextureViewDimension_CubeArray;
        if (std.mem.eql(u8, s, "3d")) return c.WGPUTextureViewDimension_3D;
        return c.WGPUTextureViewDimension_2D;
    }
    fn mapStorageFormatStr(s: []const u8) c_uint {
        if (std.mem.eql(u8, s, "rgba8snorm")) return c.WGPUTextureFormat_RGBA8Snorm;
        if (std.mem.eql(u8, s, "rgba8uint")) return c.WGPUTextureFormat_RGBA8Uint;
        if (std.mem.eql(u8, s, "rgba8sint")) return c.WGPUTextureFormat_RGBA8Sint;
        if (std.mem.eql(u8, s, "rgba16uint")) return c.WGPUTextureFormat_RGBA16Uint;
        if (std.mem.eql(u8, s, "rgba16sint")) return c.WGPUTextureFormat_RGBA16Sint;
        if (std.mem.eql(u8, s, "rgba16float")) return c.WGPUTextureFormat_RGBA16Float;
        if (std.mem.eql(u8, s, "rgba32uint")) return c.WGPUTextureFormat_RGBA32Uint;
        if (std.mem.eql(u8, s, "rgba32sint")) return c.WGPUTextureFormat_RGBA32Sint;
        if (std.mem.eql(u8, s, "rgba32float")) return c.WGPUTextureFormat_RGBA32Float;
        if (std.mem.eql(u8, s, "r32float")) return c.WGPUTextureFormat_R32Float;
        if (std.mem.eql(u8, s, "r32uint")) return c.WGPUTextureFormat_R32Uint;
        if (std.mem.eql(u8, s, "r32sint")) return c.WGPUTextureFormat_R32Sint;
        if (std.mem.eql(u8, s, "rg32float")) return c.WGPUTextureFormat_RG32Float;
        return c.WGPUTextureFormat_RGBA8Unorm;
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

    pub fn create_pipeline_layout(self: *Self, allocator: Allocator, layout_id: u16, descriptor_data_id: u16) !void {
        if (layout_id >= MAX_PIPELINE_LAYOUTS) return error.InvalidResourceId; // untrusted id
        assert(self.module != null);

        // Skip if layout already exists
        if (self.pipeline_layouts[layout_id] != null) {
            return;
        }

        const module = self.module.?;
        const data = module.data.get(DataId.fromInt(descriptor_data_id));

        // JSON descriptor `{"bindGroupLayouts":[id0,id1,…]}` — the same shape the
        // emitter feeds the browser command-buffer path (gpu-resource-pass-commands
        // case 0x0C). Each id resolves against the bind_group_layouts table (created
        // by the create_bind_group_layout phase that runs before this one).
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
        defer parsed.deinit();
        const bgls = (parsed.value.object.get("bindGroupLayouts") orelse return).array;
        if (bgls.items.len == 0 or bgls.items.len > 8) return;

        var layouts: [8]c.WGPUBindGroupLayout = undefined;
        var valid_count: usize = 0;
        for (bgls.items) |item| {
            // `tableId` rather than a bare `@intCast` + range test: the cast
            // itself is UB when the descriptor carries a non-u16 integer.
            const bgl_id = tableId(item, MAX_BIND_GROUP_LAYOUTS) catch continue;
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

    /// DEFERRED, not abandoned (r2-06, §335). wgpu-native has the whole API
    /// (`wgpuDeviceCreateQuerySet`, `wgpuCommandEncoderResolveQuerySet`,
    /// occlusion via the pass descriptor, timestamps behind the TimestampQuery
    /// feature this device does not currently request). Four fixtures wait on it
    /// — webgpu_occlusion_query, webgpu_timestamp_query and the two stress_*.
    /// The blocker is not the API: a query's whole point is CPU readback, and
    /// `--frame` renders one frame and exits, so a resolved query would go to a
    /// buffer nothing reads. Implement together with something that consumes the
    /// result, or the fixtures flip to a green that measures nothing.
    pub fn create_query_set(self: *Self, allocator: Allocator, query_set_id: u16, descriptor_data_id: u16) !void {
        stub.note("create_query_set");
        _ = self;
        _ = allocator;
        _ = query_set_id;
        _ = descriptor_data_id;
    }

    /// NON-GOAL for the CLI (r2-06, §335). The browser gets ImageBitmap decoding
    /// from the host; native would have to vendor a PNG/JPEG decoder to match, and
    /// the six fixtures that want it (cubemap, image_blur, normal_map,
    /// textured_rotating_cube, webgpu_textured_cube, webgpu_text_msdf) are all
    /// asset-loading demos whose GPU paths are covered elsewhere in the corpus.
    /// Their `stub` rows are the honest record; see also copy_external_image_to_texture.
    pub fn create_image_bitmap(self: *Self, allocator: Allocator, bitmap_id: u16, blob_data_id: u16) !void {
        stub.note("create_image_bitmap");
        _ = self;
        _ = allocator;
        _ = bitmap_id;
        _ = blob_data_id;

        // TODO: Implement image loading
    }

    /// DEFERRED (r2-06, §335) — the largest of the remaining stubs, and the only
    /// one needing new *structure* rather than new calls. A bundle is recorded
    /// into a `WGPURenderBundleEncoder`, a second encoder type that accepts the
    /// pass command set, so every in-pass method here would have to route to
    /// whichever encoder is currently recording rather than to `self.render_pass`.
    /// Three fixtures wait on it (webgpu_render_bundles, webgpu_stress_bundles,
    /// webgpu_text_msdf — the last also needs image decode). Bundles are a CPU
    /// -overhead optimisation: replaying one must produce pixels identical to
    /// drawing directly, so the payoff here is parity confidence, not new output.
    pub fn create_render_bundle(self: *Self, allocator: Allocator, bundle_id: u16, descriptor_data_id: u16) !void {
        stub.note("create_render_bundle");
        _ = self;
        _ = allocator;
        _ = bundle_id;
        _ = descriptor_data_id;
    }

    pub fn execute_bundles(self: *Self, allocator: Allocator, bundle_ids: []const u16) !void {
        stub.note("execute_bundles");
        _ = self;
        _ = allocator;
        _ = bundle_ids;
    }

    // ========================================================================
    // Pass Operations
    // ========================================================================

    /// Refuse to open a pass while one is already open.
    ///
    /// Assigning over `render_pass`/`compute_pass` dropped the previous encoder
    /// unreleased — and worse, left the command encoder *locked*, so the next
    /// `submit()` aborted the process inside `wgpuQueueSubmit` ("Encoder is
    /// locked by a previously created render/compute pass") instead of returning
    /// an error. Unbalanced begin/begin is not emitter-reachable, but
    /// `pngine_create` takes arbitrary PNGB out of a PNG off the internet, so
    /// that is a property of the emitter, not a safety property.
    ///
    /// Refusing (rather than silently ending the stale pass) keeps malformed
    /// streams loud, mirroring wasm_entry's stance; the frame unwinds to
    /// `abortFrame`, which releases what is open. (LEAK-01 D)
    fn requireNoOpenPass(self: *const Self) error{PassNotEnded}!void {
        if (self.render_pass != null or self.compute_pass != null) return error.PassNotEnded;
    }

    pub fn begin_render_pass(self: *Self, allocator: Allocator, color_texture_id: u16, load_op: u8, store_op: u8, depth_texture_id: u16, clear_r: u8, clear_g: u8, clear_b: u8, clear_a: u8, resolve_texture_id: u16) !void {
        _ = allocator;

        // Pre-condition assertions (Zig Mastery Compliance)
        assert(self.ctx.device != null);
        assert(load_op <= 1); // 0=Load, 1=Clear
        assert(store_op <= 1); // 0=Store, 1=Discard
        try self.requireNoOpenPass();

        // 0xFFFF = no color attachment (a depth-only pass — shadow map / depth
        // pre-pass; the emitter emits NO_TEXTURE_ID here). getColorTargetView only
        // knows real ids + 0xFFFE, so the whole color path is gated on this.
        const has_color = color_texture_id != 0xFFFF;

        // Reuse existing encoder if one exists, otherwise create new
        if (self.encoder == null) {
            self.encoder = wgpu.deviceCreateCommandEncoder(self.ctx.device, null);
        }
        const encoder = self.encoder orelse return error.SurfaceTextureUnavailable;

        // Color attachment (skipped entirely for a depth-only pass)
        var color_attachment = std.mem.zeroes(c.WGPURenderPassColorAttachment);
        var color_is_surface = false;
        if (has_color) {
            const color_result = try getColorTargetView(self, color_texture_id);
            color_is_surface = color_result.is_surface;
            if (color_result.is_surface) {
                self.latchSurfaceView(color_result.view);
            }

            // Map bytecode load/store ops to wgpu-native values
            const wgpu_load_op: c_uint = if (load_op == 0) c.WGPULoadOp_Load else c.WGPULoadOp_Clear;
            const wgpu_store_op: c_uint = if (store_op == 0) c.WGPUStoreOp_Store else c.WGPUStoreOp_Discard;

            color_attachment.view = color_result.view;
            color_attachment.depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED;
            color_attachment.loadOp = wgpu_load_op;
            color_attachment.storeOp = wgpu_store_op;
            color_attachment.clearValue = .{ .r = @as(f64, @floatFromInt(clear_r)) / 255.0, .g = @as(f64, @floatFromInt(clear_g)) / 255.0, .b = @as(f64, @floatFromInt(clear_b)) / 255.0, .a = @as(f64, @floatFromInt(clear_a)) / 255.0 };

            // MSAA resolve target: 0xFFFF = none (single-sample pass). Otherwise the
            // multisampled color is resolved into this single-sample view. In headless
            // render that view is the persistent offscreen target (0xFFFE, is_surface
            // false → released in deinit, not here); windowed it is the surface
            // texture, in which case it — not the multisampled color — is the view
            // submit() must present and release, so route it through current_surface_
            // view. Color and resolve can never BOTH be the surface (one attachment).
            if (resolve_texture_id != 0xFFFF) {
                const resolve_result = try getColorTargetView(self, resolve_texture_id);
                assert(resolve_result.view != null);
                color_attachment.resolveTarget = resolve_result.view;
                if (resolve_result.is_surface) {
                    assert(!color_is_surface);
                    self.latchSurfaceView(resolve_result.view);
                }
            }
        }

        // Release previous depth view if any
        if (self.current_depth_view) |old_view| {
            wgpu.textureViewRelease(old_view);
            self.current_depth_view = null;
        }

        // Depth stencil attachment using helper (consumes the pending ops)
        const depth_result = setupDepthAttachment(self, depth_texture_id);
        var depth_attachment = depth_result.attachment;
        if (depth_result.valid) {
            self.current_depth_view = depth_result.view;
        }
        resetPendingDepthStencilOps(self);

        // A pass needs at least one attachment; a depth-only pass must have depth.
        assert(has_color or depth_result.valid);

        var render_pass_desc = std.mem.zeroes(c.WGPURenderPassDescriptor);
        render_pass_desc.label = .{ .data = null, .length = 0 };
        render_pass_desc.colorAttachmentCount = if (has_color) 1 else 0;
        render_pass_desc.colorAttachments = if (has_color) &color_attachment else null;
        render_pass_desc.depthStencilAttachment = if (depth_result.valid) &depth_attachment else null;

        self.render_pass = wgpu.commandEncoderBeginRenderPass(encoder, &render_pass_desc);

        // Post-condition: render pass was started
        if (self.render_pass != null) {
            _ = debug_render_passes_begun.fetchAdd(1, .monotonic);
        }
    }

    pub fn begin_compute_pass(self: *Self, allocator: Allocator) !void {
        _ = allocator;

        // Pre-condition assertions (Zig Mastery Compliance)
        assert(self.ctx.device != null);
        // A real branch, not the Debug-only `assert(self.compute_pass == null)`
        // this replaced — it compiled out exactly where hostile bytecode runs.
        try self.requireNoOpenPass();

        // Reuse existing encoder if one exists, otherwise create new
        const reusing = self.encoder != null;
        if (self.encoder == null) {
            self.encoder = wgpu.deviceCreateCommandEncoder(self.ctx.device, null);
        }
        self.compute_pass = wgpu.commandEncoderBeginComputePass(self.encoder.?, null);
        if (self.compute_pass != null) {
            _ = debug_compute_passes_begun.fetchAdd(1, .monotonic);
        }
        nativeLog("[NATIVE] begin_compute_pass: reusing={}, pass_valid={}\n", .{ reusing, self.compute_pass != null });

        // Post-condition: compute pass is now active
        assert(self.compute_pass != null);
    }

    pub fn set_pipeline(self: *Self, allocator: Allocator, pipeline_id: u16) !void {
        _ = allocator;

        if (self.render_pass) |pass| {
            if (pipeline_id >= MAX_RENDER_PIPELINES) return; // untrusted id, same as an empty slot
            if (self.render_pipelines[pipeline_id]) |pipeline| {
                wgpu.renderPassEncoderSetPipeline(pass, pipeline);
            }
        } else if (self.compute_pass) |pass| {
            if (pipeline_id >= MAX_COMPUTE_PIPELINES) return; // untrusted id
            const has_pipeline = self.compute_pipelines[pipeline_id] != null;
            nativeLog("set_pipeline(compute): id={}, found={}, pass_valid={}\n", .{ pipeline_id, has_pipeline, pass != null });
            if (self.compute_pipelines[pipeline_id]) |pipeline| {
                wgpu.computePassEncoderSetPipeline(pass, pipeline);
            }
        }
    }

    pub fn set_bind_group(self: *Self, allocator: Allocator, slot: u8, group_id: u16) !void {
        _ = allocator;

        if (group_id >= MAX_BIND_GROUPS) return; // untrusted id, same as an empty slot
        const has_group = self.bind_groups[group_id] != null;
        const in_compute = self.compute_pass != null;
        if (in_compute) {
            nativeLog("set_bind_group(compute): slot={}, group_id={}, found={}\n", .{ slot, group_id, has_group });
        }

        if (self.bind_groups[group_id]) |group| {
            if (self.render_pass) |pass| {
                wgpu.renderPassEncoderSetBindGroup(pass, slot, group, &[_]u32{});
            } else if (self.compute_pass) |pass| {
                wgpu.computePassEncoderSetBindGroup(pass, slot, group, &[_]u32{});
            }
        }
    }

    pub fn set_vertex_buffer(self: *Self, allocator: Allocator, slot: u8, buffer_id: u16) !void {
        _ = allocator;

        if (buffer_id >= MAX_BUFFERS) return; // untrusted id, same as an empty slot

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

    pub fn set_index_buffer(self: *Self, allocator: Allocator, buffer_id: u16, index_format: u8) !void {
        _ = allocator;

        if (buffer_id >= MAX_BUFFERS) return; // untrusted id, same as an empty slot
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

    pub fn draw_indexed(self: *Self, allocator: Allocator, index_count: u32, instance_count: u32, first_index: u32, base_vertex: u32, first_instance: u32) !void {
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

    pub fn end_pass(self: *Self, allocator: Allocator) !void {
        _ = allocator;

        if (self.render_pass) |pass| {
            wgpu.renderPassEncoderEnd(pass);
            wgpu.renderPassEncoderRelease(pass);
            self.render_pass = null;
        }
        if (self.compute_pass) |pass| {
            nativeLog("end_pass(compute): ending compute pass\n", .{});
            wgpu.computePassEncoderEnd(pass);
            wgpu.computePassEncoderRelease(pass);
            self.compute_pass = null;
        }
    }

    // ========================================================================
    // Extended Pass Operations (stubs for new features)
    // ========================================================================

    pub fn draw_indirect(self: *Self, allocator: Allocator, buffer_id: u16, offset: u32) !void {
        _ = allocator;
        if (buffer_id >= MAX_BUFFERS) return; // untrusted id, same as an empty slot
        if (self.render_pass) |pass| {
            if (self.buffers[buffer_id]) |buffer| {
                wgpu.renderPassEncoderDrawIndirect(pass, buffer, offset);
            }
        }
    }

    pub fn draw_indexed_indirect(self: *Self, allocator: Allocator, buffer_id: u16, offset: u32) !void {
        _ = allocator;
        if (buffer_id >= MAX_BUFFERS) return; // untrusted id, same as an empty slot
        if (self.render_pass) |pass| {
            if (self.buffers[buffer_id]) |buffer| {
                wgpu.renderPassEncoderDrawIndexedIndirect(pass, buffer, offset);
            }
        }
    }

    pub fn dispatch_indirect(self: *Self, allocator: Allocator, buffer_id: u16, offset: u32) !void {
        _ = allocator;
        if (buffer_id >= MAX_BUFFERS) return; // untrusted id, same as an empty slot
        if (self.compute_pass) |pass| {
            if (self.buffers[buffer_id]) |buffer| {
                wgpu.computePassEncoderDispatchWorkgroupsIndirect(pass, buffer, offset);
            }
        }
    }

    /// In-pass state: restrict rasterization to a sub-rectangle and remap depth.
    ///
    /// The depth operands arrive as the *bit patterns* of two f32s in u32 slots —
    /// the same encoding the browser decodes with `getFloat32` (0x1F in
    /// gpu-resource-pass-commands.js). Reading them as integers would silently
    /// send 0/1065353216 instead of 0.0/1.0.
    pub fn set_viewport(self: *Self, allocator: Allocator, x: u32, y: u32, w: u32, h: u32, min_depth_bits: u32, max_depth_bits: u32) !void {
        _ = allocator;
        assert(self.compute_pass == null); // viewport is a render-pass concept
        const pass = self.render_pass orelse return;
        wgpu.renderPassEncoderSetViewport(
            pass,
            @floatFromInt(x),
            @floatFromInt(y),
            @floatFromInt(w),
            @floatFromInt(h),
            @bitCast(min_depth_bits),
            @bitCast(max_depth_bits),
        );
    }

    /// In-pass state: discard fragments outside the rectangle. No-op when no
    /// render pass is active (compute passes never emit it).
    pub fn set_scissor_rect(self: *Self, allocator: Allocator, x: u32, y: u32, w: u32, h: u32) !void {
        _ = allocator;
        assert(self.compute_pass == null); // scissor is a render-pass concept
        const pass = self.render_pass orelse return;
        wgpu.renderPassEncoderSetScissorRect(pass, x, y, w, h);
    }

    /// In-pass state: set the stencil comparison reference value for subsequent
    /// draws. No-op when no render pass is active (compute passes never emit it).
    pub fn set_stencil_reference(self: *Self, allocator: Allocator, reference: u32) !void {
        _ = allocator;
        assert(self.compute_pass == null); // stencil ref is a render-pass concept
        if (self.render_pass) |pass| {
            wgpu.renderPassEncoderSetStencilReference(pass, reference);
        }
    }

    /// In-pass state: set the blend constant (the value the `constant` /
    /// `one-minus-constant` blend factors multiply by). Args are f32 bit patterns
    /// (raw u32); WGPUColor takes f64, so widen through f32. No-op with no render
    /// pass active (compute passes never emit it).
    pub fn set_blend_constant(self: *Self, allocator: Allocator, r_bits: u32, g_bits: u32, b_bits: u32, a_bits: u32) !void {
        _ = allocator;
        assert(self.compute_pass == null); // blend constant is a render-pass concept
        if (self.render_pass) |pass| {
            const color = c.WGPUColor{
                .r = @as(f32, @bitCast(r_bits)),
                .g = @as(f32, @bitCast(g_bits)),
                .b = @as(f32, @bitCast(b_bits)),
                .a = @as(f32, @bitCast(a_bits)),
            };
            wgpu.renderPassEncoderSetBlendConstant(pass, &color);
        }
    }

    /// Pre-pass state (emitted before begin_render_pass): stash the depth/stencil
    /// load-store ops so the next begin_render_pass{,_mrt} bakes them into the
    /// depth-stencil attachment. Only emitted for a non-default pass (§214).
    pub fn set_pass_depth_stencil_ops(self: *Self, allocator: Allocator, depth_load_op: u8, depth_store_op: u8, stencil_load_op: u8, stencil_store_op: u8) !void {
        _ = allocator;
        assert(depth_load_op <= 1 and depth_store_op <= 1);
        assert(stencil_load_op <= 1 and stencil_store_op <= 1);
        self.pending_depth_load_op = depth_load_op;
        self.pending_depth_store_op = depth_store_op;
        self.pending_stencil_load_op = stencil_load_op;
        self.pending_stencil_store_op = stencil_store_op;
    }

    /// Pre-pass state: stash the depth/stencil clear values so the next
    /// begin_render_pass{,_mrt} bakes them into the depth-stencil attachment.
    /// Only emitted for a non-default pass (see set_pass_depth_stencil_ops).
    pub fn set_pass_clear_values(self: *Self, allocator: Allocator, depth_bits: u32, stencil_value: u32) !void {
        _ = allocator;
        const depth: f32 = @bitCast(depth_bits);
        assert(depth >= 0.0 and depth <= 1.0); // schema type is unorm
        self.pending_depth_clear_value = depth;
        self.pending_stencil_clear_value = stencil_value;
    }

    pub fn set_pass_occlusion_query_set(self: *Self, allocator: Allocator, query_set_id: u16) !void {
        stub.note("set_pass_occlusion_query_set");
        _ = self;
        _ = allocator;
        _ = query_set_id;
    }

    pub fn set_pass_timestamp_writes(self: *Self, allocator: Allocator, query_set_id: u16, begin_index: u32, end_index: u32) !void {
        stub.note("set_pass_timestamp_writes");
        _ = self;
        _ = allocator;
        _ = query_set_id;
        _ = begin_index;
        _ = end_index;
    }

    pub fn begin_occlusion_query(self: *Self, allocator: Allocator, query_index: u32) !void {
        stub.note("begin_occlusion_query");
        _ = self;
        _ = allocator;
        _ = query_index;
    }

    pub fn end_occlusion_query(self: *Self, allocator: Allocator) !void {
        stub.note("end_occlusion_query");
        _ = self;
        _ = allocator;
    }

    pub fn resolve_query_set(self: *Self, allocator: Allocator, query_set_id: u16, first_query: u32, query_count: u32, dest_buffer_id: u16, dest_offset: u32) !void {
        stub.note("resolve_query_set");
        _ = self;
        _ = allocator;
        _ = query_set_id;
        _ = first_query;
        _ = query_count;
        _ = dest_buffer_id;
        _ = dest_offset;
    }

    // ========================================================================
    // Queue Operations
    // ========================================================================

    pub fn write_buffer(self: *Self, allocator: Allocator, buffer_id: u16, offset: u32, data_id: u16) !void {
        _ = allocator;

        if (buffer_id >= MAX_BUFFERS) return; // untrusted id, same as an empty slot
        if (self.buffers[buffer_id]) |buffer| {
            if (self.module) |module| {
                const data = module.data.get(DataId.fromInt(data_id));
                wgpu.queueWriteBuffer(self.ctx.queue, buffer, offset, data);
            }
        }
    }

    /// Resolve a copy operand's texture id to a live texture.
    ///
    /// `0xFFFE` is the canvas sentinel, the same one `getColorTargetView` reads —
    /// headless it is the persistent offscreen target, windowed it is the
    /// surface's current texture. The surface branch hands back a reference the
    /// CALLER releases (`owned = true`); the offscreen and table branches do not,
    /// because those textures outlive the copy.
    const CopyTextureResult = struct { texture: wgpu.Texture, owned: bool };

    fn getCopyTexture(self: *Self, texture_id: u16) ?CopyTextureResult {
        if (texture_id == 0xFFFE) {
            const surface = self.surface orelse {
                const t = self.offscreen_texture orelse return null;
                return .{ .texture = t, .owned = false };
            };
            var surface_texture: wgpu.SurfaceTexture = undefined;
            wgpu.surfaceGetCurrentTexture(surface, &surface_texture);
            const t = surface_texture.texture orelse return null;
            return .{ .texture = t, .owned = true };
        }
        if (texture_id >= MAX_TEXTURES) return null; // untrusted id
        const t = self.textures[texture_id] orelse return null;
        return .{ .texture = t, .owned = false };
    }

    pub fn copy_buffer_to_buffer(self: *Self, allocator: Allocator, src_buffer: u16, src_offset: u32, dst_buffer: u16, dst_offset: u32, size: u32) !void {
        _ = allocator;
        assert(self.render_pass == null and self.compute_pass == null); // encoder-level op
        if (src_buffer >= MAX_BUFFERS or dst_buffer >= MAX_BUFFERS) return; // untrusted ids
        const src = self.buffers[src_buffer] orelse return;
        const dst = self.buffers[dst_buffer] orelse return;
        if (size == 0) return; // wgpu rejects a zero-size copy; the browser no-ops it

        if (self.encoder == null) {
            self.encoder = wgpu.deviceCreateCommandEncoder(self.ctx.device, null);
        }
        const encoder = self.encoder orelse return;
        wgpu.commandEncoderCopyBufferToBuffer(encoder, src, src_offset, dst, dst_offset, size);
    }

    /// Copy one whole texture into another. The opcode carries only two ids, so
    /// the extent comes from the resources: the smaller of the two, which is what
    /// WebGPU requires anyway (a copy may not exceed either subresource). The
    /// browser instead falls back to the canvas size when its w/h operands are 0
    /// (0x23 in gpu-queue-commands.js) — same answer whenever the canvas-sized
    /// feedback texture is the destination, which is every corpus use today.
    pub fn copy_texture_to_texture(self: *Self, allocator: Allocator, src_texture: u16, dst_texture: u16) !void {
        _ = allocator;
        assert(self.render_pass == null and self.compute_pass == null); // encoder-level op
        const src = self.getCopyTexture(src_texture) orelse return;
        defer if (src.owned) wgpu.textureRelease(src.texture);
        const dst = self.getCopyTexture(dst_texture) orelse return;
        defer if (dst.owned) wgpu.textureRelease(dst.texture);

        const width = @min(wgpu.textureGetWidth(src.texture), wgpu.textureGetWidth(dst.texture));
        const height = @min(wgpu.textureGetHeight(src.texture), wgpu.textureGetHeight(dst.texture));
        if (width == 0 or height == 0) return;

        if (self.encoder == null) {
            self.encoder = wgpu.deviceCreateCommandEncoder(self.ctx.device, null);
        }
        const encoder = self.encoder orelse return;

        const source = c.WGPUTexelCopyTextureInfo{
            .texture = src.texture,
            .mipLevel = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = c.WGPUTextureAspect_All,
        };
        const destination = c.WGPUTexelCopyTextureInfo{
            .texture = dst.texture,
            .mipLevel = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = c.WGPUTextureAspect_All,
        };
        const copy_size = c.WGPUExtent3D{ .width = width, .height = height, .depthOrArrayLayers = 1 };
        wgpu.commandEncoderCopyTextureToTexture(encoder, &source, &destination, &copy_size);
    }

    // write_uniform (0x21) and write_audio_data (0x2C) are RESERVED-INERT — see
    // their entries in src/types/opcodes.zig. No frontend path emits either, and
    // the SHIPPING BROWSER EXECUTOR decodes and skips both (there is no
    // command-buffer counterpart), so a native no-op is parity with the browser,
    // not a gap behind it. They carry no `stub.note` for that reason: flagging
    // them would report a divergence that does not exist, and `--strict-native-stubs`
    // would reclassify a faithful render as `stub`. Deliberately permanent — this
    // is the state these two ops are meant to stay in, not a deferred TODO.

    pub fn write_uniform(self: *Self, allocator: Allocator, buffer_id: u16, uniform_id: u16) !void {
        _ = allocator;
        _ = self;
        _ = buffer_id;
        _ = uniform_id;
    }

    pub fn write_audio_data(self: *Self, allocator: Allocator, buffer_id: u16, buffer_offset: u32, size: u16) !void {
        _ = allocator;
        _ = self;
        _ = buffer_id;
        _ = buffer_offset;
        _ = size;
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

        // …and the texture it was made from. Present() does not consume the
        // reference; the acquisition is ours to give back (LEAK-01 A).
        self.releaseSurfaceTexture();

        // Release depth view
        if (self.current_depth_view) |view| {
            wgpu.textureViewRelease(view);
            self.current_depth_view = null;
        }
    }

    /// Abandon the frame in progress and return every reference it holds.
    ///
    /// A `pngine_render` that fails mid-frame used to return the error code and
    /// leave the backend wedged: encoder, open pass, surface texture and views
    /// all still latched. The next render replays from pc 0 and overwrites them,
    /// so a viewer that treats a non-fatal code as "try the next frame" — the
    /// normal thing to do, and a transient `SurfaceTextureUnavailable` during a
    /// window resize *is* non-fatal — converted one error into a leak per
    /// failing frame (LEAK-01 E).
    ///
    /// Safe to call at any point: every step is guarded, and calling it on an
    /// idle backend is a no-op.
    pub fn abortFrame(self: *Self) void {
        // End before release: the encoder stays locked while a pass is open, and
        // a locked encoder aborts the process inside wgpuQueueSubmit rather than
        // returning an error.
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
        // Dropped without finish(): the recorded commands are discarded, which
        // is the point — the frame is not being presented.
        if (self.encoder) |encoder| {
            wgpu.commandEncoderRelease(encoder);
            self.encoder = null;
        }
        if (self.current_surface_view) |view| {
            wgpu.textureViewRelease(view);
            self.current_surface_view = null;
        }
        self.releaseSurfaceTexture();
        if (self.current_depth_view) |view| {
            wgpu.textureViewRelease(view);
            self.current_depth_view = null;
        }

        // Post-condition: nothing frame-scoped survives.
        assert(self.render_pass == null and self.compute_pass == null);
        assert(self.encoder == null and self.current_surface_texture == null);
    }

    /// Read the offscreen color target back to CPU as RGBA8 (row-unpadded,
    /// BGRA→RGBA swizzled). Valid only for a headless (surface==null) instance
    /// after the frame has been submitted. Caller owns the returned slice.
    ///
    /// wgpu requires the copy's bytesPerRow to be a multiple of 256, so we copy
    /// into a padded staging buffer and strip the padding per row on the way
    /// out. The single BGRA→RGBA swizzle here is why the encoder keeps its
    /// "returns RGBA" contract even though the target is BGRA8Unorm.
    pub fn read_pixels(self: *Self, allocator: Allocator) ![]u8 {
        assert(self.width > 0 and self.height > 0);
        const texture = self.offscreen_texture orelse return error.NoOffscreenTarget;

        const unpadded_bpr: u32 = self.width * 4;
        const padded_bpr: u32 = std.mem.alignForward(u32, unpadded_bpr, 256);
        const buffer_size: u64 = @as(u64, padded_bpr) * self.height;

        const readback_desc = c.WGPUBufferDescriptor{
            .nextInChain = null,
            .label = .{ .data = null, .length = 0 },
            .size = buffer_size,
            .usage = c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_CopyDst,
            .mappedAtCreation = @intFromBool(false),
        };
        const readback = wgpu.deviceCreateBuffer(self.ctx.device, &readback_desc);
        if (readback == null) return error.OutOfMemory;
        defer wgpu.bufferRelease(readback);

        // Record + submit the texture→buffer copy on a fresh encoder (the frame
        // encoder was already finished + released by submit()).
        const encoder = wgpu.deviceCreateCommandEncoder(self.ctx.device, null);
        const source = c.WGPUTexelCopyTextureInfo{
            .texture = texture,
            .mipLevel = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = c.WGPUTextureAspect_All,
        };
        const destination = c.WGPUTexelCopyBufferInfo{
            .layout = .{ .offset = 0, .bytesPerRow = padded_bpr, .rowsPerImage = self.height },
            .buffer = readback,
        };
        const copy_size = c.WGPUExtent3D{ .width = self.width, .height = self.height, .depthOrArrayLayers = 1 };
        wgpu.commandEncoderCopyTextureToBuffer(encoder, &source, &destination, &copy_size);
        const cmd = wgpu.commandEncoderFinish(encoder, null);
        wgpu.queueSubmit(self.ctx.queue, &[_]wgpu.CommandBuffer{cmd});
        wgpu.commandBufferRelease(cmd);
        wgpu.commandEncoderRelease(encoder);

        // Map + read (blocks on device poll until the copy completes).
        if (!wgpu.bufferMapReadSync(self.ctx.instance, self.ctx.device, readback, @intCast(buffer_size))) {
            return error.ReadbackMapFailed;
        }
        const mapped = wgpu.bufferGetConstMappedRange(readback, 0, @intCast(buffer_size)) orelse {
            wgpu.bufferUnmap(readback);
            return error.ReadbackMapFailed;
        };
        const src_ptr: [*]const u8 = @ptrCast(mapped);
        const src: []const u8 = src_ptr[0..@intCast(buffer_size)];

        const out = try allocator.alloc(u8, @as(usize, self.width) * self.height * 4);
        errdefer allocator.free(out);

        // Per-row unpad + BGRA→RGBA swizzle. Bounds are the real dimensions.
        const w: usize = self.width;
        const h: usize = self.height;
        const padded: usize = padded_bpr;
        const unpadded: usize = unpadded_bpr;
        for (0..h) |y| {
            const src_row = src[y * padded ..][0..unpadded];
            const dst_row = out[y * unpadded ..][0..unpadded];
            for (0..w) |x| {
                const p = x * 4;
                dst_row[p + 0] = src_row[p + 2]; // R ← BGRA byte 2
                dst_row[p + 1] = src_row[p + 1]; // G ← BGRA byte 1
                dst_row[p + 2] = src_row[p + 0]; // B ← BGRA byte 0
                dst_row[p + 3] = src_row[p + 3]; // A ← BGRA byte 3
            }
        }

        wgpu.bufferUnmap(readback);

        assert(out.len == @as(usize, self.width) * self.height * 4);
        return out;
    }

    pub fn copy_external_image_to_texture(self: *Self, allocator: Allocator, bitmap_id: u16, texture_id: u16, mip_level: u8, origin_x: u16, origin_y: u16, origin_z: u16) !void {
        stub.note("copy_external_image_to_texture");
        _ = self;
        _ = allocator;
        _ = bitmap_id;
        _ = texture_id;
        _ = mip_level;
        _ = origin_x;
        _ = origin_y;
        _ = origin_z;

        // NON-GOAL for the CLI, the other half of create_image_bitmap's decision
        // (r2-06, §335): there is no decoded bitmap to copy because native does
        // not decode. If that ever changes, note that the origin — including the
        // destination array layer / depth slice — is ignored here too.
    }

    // ========================================================================
    // WASM Module Operations
    // ========================================================================
    //
    // DEFERRED (r2-06, §335), and the cost is not what it looks like: the repo
    // already vendors WAMR for `inspect --deep`, so a native `(wasm-data …)` path is
    // wiring an existing runtime in, not adopting one. Three fixtures wait on it
    // (test_data_pass, test_wasm_data, wasm_rotated_cube) and their buffers stay
    // zero-initialised without it — wasm_rotated_cube's cube therefore renders
    // with an identity transform rather than not at all, which is the failure
    // mode a `stub` row exists to record. Not "browser-only" as this header
    // previously claimed: browser-only is where it stands, not where it must.

    pub fn init_wasm_module(self: *Self, allocator: Allocator, module_id: u16, wasm_data_id: u16) !void {
        stub.note("init_wasm_module");
        _ = self;
        _ = allocator;
        _ = module_id;
        _ = wasm_data_id;
        // See the section header above: deferred, not permanent.
    }

    pub fn call_wasm_func(self: *Self, allocator: Allocator, call_id: u16, module_id: u16, func_name_id: u16, args: []const u8) !void {
        stub.note("call_wasm_func");
        _ = self;
        _ = allocator;
        _ = call_id;
        _ = module_id;
        _ = func_name_id;
        _ = args;
        // See the section header above: deferred, not permanent.
    }

    pub fn write_buffer_from_wasm(self: *Self, allocator: Allocator, call_id: u16, buffer_id: u16, offset: u32, byte_len: u32) !void {
        stub.note("write_buffer_from_wasm");
        _ = self;
        _ = allocator;
        _ = call_id;
        _ = buffer_id;
        _ = offset;
        _ = byte_len;
        // See the section header above: deferred, not permanent.
    }

    pub fn write_time_uniform(self: *Self, allocator: Allocator, buffer_id: u16, buffer_offset: u32, size: u16) !void {
        _ = allocator;

        if (buffer_id >= MAX_BUFFERS) return; // untrusted id, same as an empty slot
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

    /// Write the 48-byte pointer-inputs block (11 floats + 1 pad, layout pinned by
    /// tests/npm/helpers/pointer-layout.js).
    ///
    /// A headless render has no pointer device, and that is not the same as
    /// "unimplemented": it is the at-rest state, which is exactly what the
    /// browser writes before the first pointer event — gpu.js initialises all
    /// eleven to 0 and this op is the only writer. So native writes zeros, which
    /// makes the frame DEFINED rather than "whatever the buffer happened to
    /// hold". Previously it no-op'd, and the five pointer fixtures rendered
    /// correctly only because WebGPU zero-initialises buffers anyway — a right
    /// answer resting on an unstated guarantee.
    pub fn write_pointer_uniform(self: *Self, allocator: Allocator, buffer_id: u16, buffer_offset: u32, size: u16) !void {
        _ = allocator;
        assert(size <= 64); // the block is 48 B; anything larger is a decode bug

        if (buffer_id >= MAX_BUFFERS) return; // untrusted id, same as an empty slot
        const buffer = self.buffers[buffer_id] orelse return;
        const at_rest = [_]u8{0} ** 48;
        const write_size = @min(size, at_rest.len);
        if (write_size == 0) return;
        wgpu.queueWriteBuffer(self.ctx.queue, buffer, buffer_offset, at_rest[0..write_size]);
    }

    // Backend methods are defined above with their dispatcher-facing snake_case
    // names directly — no alias shim.
    //
    // Begin a render pass with N (1..8) color attachments — the real MRT path.
    // Mirrors begin_render_pass for the encoder / depth / debug-counter handling
    // but builds one WGPURenderPassColorAttachment per bytecode ColorAttachment, so
    // a g-buffer pipeline declaring multiple targets (e.g. deferred rendering's
    // normal + albedo) matches its pass instead of validation-aborting on an
    // attachment-count mismatch. MRT carries no resolve target (the emitter's
    // ColorAttachment has no resolve id); MSAA resolve stays on the single-
    // attachment begin_render_pass path.
    pub fn begin_render_pass_mrt(self: *Self, allocator: Allocator, attachments: []const @import("bytecode").emitter.Emitter.ColorAttachment, depth_texture_id: u16) !void {
        _ = allocator;

        // Pre-conditions: device ready and a valid attachment count (the bytecode
        // always emits ≥1; WebGPU caps at MAX_COLOR_ATTACHMENTS, which the
        // dispatcher already clamps the decoded slice to).
        assert(self.ctx.device != null);
        assert(attachments.len >= 1 and attachments.len <= MAX_COLOR_ATTACHMENTS);
        try self.requireNoOpenPass();

        // Reuse existing encoder if one exists, otherwise create new.
        if (self.encoder == null) {
            self.encoder = wgpu.deviceCreateCommandEncoder(self.ctx.device, null);
        }
        const encoder = self.encoder orelse return error.SurfaceTextureUnavailable;

        // One color attachment per target. getColorTargetView acquires each view
        // (cached custom-texture view, fresh view, or the surface) exactly as the
        // single-attachment path does.
        var color_attachments: [MAX_COLOR_ATTACHMENTS]c.WGPURenderPassColorAttachment = undefined;
        for (attachments, 0..) |a, i| {
            const cv = try getColorTargetView(self, a.texture_id);
            if (cv.is_surface) self.latchSurfaceView(cv.view);
            const wgpu_load_op: c_uint = if (@intFromEnum(a.load_op) == 0) c.WGPULoadOp_Load else c.WGPULoadOp_Clear;
            const wgpu_store_op: c_uint = if (@intFromEnum(a.store_op) == 0) c.WGPUStoreOp_Store else c.WGPUStoreOp_Discard;
            color_attachments[i] = std.mem.zeroes(c.WGPURenderPassColorAttachment);
            color_attachments[i].view = cv.view;
            color_attachments[i].depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED;
            color_attachments[i].loadOp = wgpu_load_op;
            color_attachments[i].storeOp = wgpu_store_op;
            color_attachments[i].clearValue = .{
                .r = @as(f64, @floatFromInt(a.clear_r)) / 255.0,
                .g = @as(f64, @floatFromInt(a.clear_g)) / 255.0,
                .b = @as(f64, @floatFromInt(a.clear_b)) / 255.0,
                .a = @as(f64, @floatFromInt(a.clear_a)) / 255.0,
            };
        }

        // Release previous depth view if any, then set up this pass's depth.
        if (self.current_depth_view) |old_view| {
            wgpu.textureViewRelease(old_view);
            self.current_depth_view = null;
        }
        const depth_result = setupDepthAttachment(self, depth_texture_id);
        var depth_attachment = depth_result.attachment;
        if (depth_result.valid) {
            self.current_depth_view = depth_result.view;
        }
        resetPendingDepthStencilOps(self);

        var render_pass_desc = std.mem.zeroes(c.WGPURenderPassDescriptor);
        render_pass_desc.label = .{ .data = null, .length = 0 };
        render_pass_desc.colorAttachmentCount = attachments.len;
        render_pass_desc.colorAttachments = @ptrCast(&color_attachments);
        render_pass_desc.depthStencilAttachment = if (depth_result.valid) &depth_attachment else null;

        self.render_pass = wgpu.commandEncoderBeginRenderPass(encoder, &render_pass_desc);

        // Post-condition: render pass was started.
        if (self.render_pass != null) {
            _ = debug_render_passes_begun.fetchAdd(1, .monotonic);
        }
    }
};

// NOTE: The `Dispatcher(WgpuNativeGPU)` alias intentionally lives in the
// consumer (`src/native_api.zig`), NOT here. Importing `dispatcher.zig` by file
// from this module would place it in two module graphs at once (the `executor`
// module already owns it) whenever `lib_module` pulls this file in for the CLI
// `--frame` path — a "file exists in multiple modules" build error. This file
// must only import the `bytecode` module + `../gpu/wgpu_c.zig` to stay
// safe to import from `lib_module`. See docs/journal.md keystone entry.
