//! Null GPU Backend — the intentional no-op fallback for GPU-less builds.
//!
//! `main.zig` binds this as `NullGPU`/`Context` ONLY when the build lacks
//! wgpu-native (`!gpu_backends.has_wgpu_native`): every `zig build npm` cross
//! binary, and any host build with `-Dgpu-native=false`. On such a build,
//! `--frame` hard-errors with a rebuild hint (renderWithGpu) BEFORE reaching
//! this backend, so nothing here ever produces user-visible output — it exists
//! to satisfy the `NullGPU` type contract at compile time. The real renderer
//! is `src/executor/wgpu_native_gpu.zig`, bound instead when `has_wgpu_native`
//! (the macOS default with the vendored wgpu-native lib).
//!
//! ## Every GPU method here is a deliberate no-op
//!
//! They record resource IDs in bitsets and track pass state so the assertions
//! stay meaningful, then do nothing. This is the finished, intended behaviour,
//! NOT unfinished work: real GPU work belongs to wgpu_native_gpu.zig and will
//! never be implemented here. (This note replaces 35 `TODO(NullGPU)`
//! comments that promised exactly that work for years.)
//!
//! `draw` used to fabricate a gradient into the pixel buffer. It was removed:
//! the only way it could reach a user was a regression in the `--frame` guard,
//! and a plausible-looking fake image is a far worse failure than a blank one.
//! `tests/zig/render/render_test.zig` still asserts real renders don't match
//! that gradient.
//!
//! ## Invariants
//! - Implements the same DISPATCHER interface as MockGPU/WgpuNativeGPU. Enforced
//!   at comptime by `Backend(T).validate()` via main.zig's `Dispatcher(NullGPU)`
//!   instantiation — not by the tests below. That instantiation is deliberately
//!   UNCONDITIONAL: until §377 main.zig only validated whichever backend the
//!   build selected, so on a host with vendored wgpu-native (the default, and
//!   what every gate runs on) this file went unchecked and drifted four clear
//!   values behind the contract.
//! - The HOST-DRIVER half of the interface — the methods `cli/render.zig` calls
//!   on `NativeGPU` directly rather than through the dispatcher (`setModule`,
//!   `setTime`, `setFrameCounter`, `read_pixels`, `resize`, `abortFrame`) — is
//!   checked by `main.zig`'s `assertDriverApi`. `CONTRACT` cannot cover it:
//!   those methods have per-method shapes, not the dispatcher's uniform
//!   `(self, gpa, …) !void`. This half is where the two backends HAD
//!   drifted: three of them were spelled `set_module`/`set_time`/`is_available`
//!   here and three were simply missing, which a GPU-less build could not
//!   catch because `renderWithGpuNative` sits behind a comptime `if` that such
//!   a build never analyzes.
//! - `init` is the one deliberate exception, and cannot be unified: this
//!   backend takes `(Allocator, w, h)` because it owns its pixel buffer, while
//!   the native one takes `(*Context, ?Surface, w, h)` because the device owns
//!   the target. Nothing calls either through a shared name.
//! - read_pixels returns the init-zeroed buffer (opaque black), never a fake
//!   render.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

// Use bytecode module import
const bytecode_mod = @import("bytecode");
/// Resource id-space budgets — shared with MockGPU and the native backend.
const limits = bytecode_mod.resource_limits;
const format = bytecode_mod.format;

// Conditional zgpu import (only available on native targets)
const has_zgpu = @hasDecl(@import("root"), "zgpu");

pub const Error = error{
    GpuNotAvailable,
    InitializationFailed,
    RenderFailed,
    OutOfMemory,
};

/// Native GPU backend for headless rendering.
///
/// Pre-condition: init() must be called before any operations.
/// Post-condition: deinit() must be called to release resources.
pub const NullGPU = struct {
    const Self = @This();

    /// Maximum resources per category — the width of the `*_created` bitsets
    /// below, from `bytecode.resource_limits` so this backend cannot disagree
    /// with the one that actually holds the resources (r3-03).
    pub const MAX_BUFFERS: u16 = limits.capOf(.buffers);
    pub const MAX_TEXTURES: u16 = limits.capOf(.textures);
    pub const MAX_SHADERS: u16 = limits.capOf(.shaders);
    pub const MAX_PIPELINES: u16 = limits.capOf(.pipelines);
    pub const MAX_BIND_GROUPS: u16 = limits.capOf(.bind_groups);

    /// Render target dimensions.
    width: u32,
    height: u32,

    /// Module reference for data lookups.
    module: ?*const format.Module,

    /// Time uniform for animations.
    time: f32,

    /// Frame counter (`pngine-frame-inputs`), the twin of WgpuNativeGPU's.
    frame_counter: u32,

    /// Initialization state.
    initialized: bool,

    /// Resource tracking (for validation).
    buffers_created: std.StaticBitSet(MAX_BUFFERS),
    textures_created: std.StaticBitSet(MAX_TEXTURES),
    shaders_created: std.StaticBitSet(MAX_SHADERS),
    pipelines_created: std.StaticBitSet(MAX_PIPELINES),
    bind_groups_created: std.StaticBitSet(MAX_BIND_GROUPS),

    /// Pass state.
    in_render_pass: bool,
    in_compute_pass: bool,
    current_pipeline: ?u16,

    /// Pixel buffer for readback (RGBA).
    pixel_buffer: ?[]u8,

    /// Initialize headless GPU rendering.
    ///
    /// Pre-conditions:
    /// - width > 0 and height > 0
    ///
    /// Post-conditions:
    /// - GPU device is ready for commands
    /// - Render target texture is created
    pub fn init(gpa: Allocator, width: u32, height: u32) Error!Self {
        // Pre-conditions
        if (width == 0 or height == 0) return Error.InitializationFailed;

        assert(width > 0);
        assert(height > 0);

        // Allocate pixel buffer for readback
        const pixel_size = @as(usize, width) * @as(usize, height) * 4;
        const pixel_buffer = gpa.alloc(u8, pixel_size) catch {
            return Error.OutOfMemory;
        };

        // Initialize with clear color (black, opaque)
        @memset(pixel_buffer, 0);
        // Set alpha to 255 for each pixel (bounded loop)
        const pixel_count = (@as(usize, width) * @as(usize, height));
        for (0..pixel_count) |p| {
            pixel_buffer[p * 4 + 3] = 255;
        }

        return Self{
            .width = width,
            .height = height,
            .module = null,
            .time = 0.0,
            .frame_counter = 0,
            .initialized = true,
            .buffers_created = std.StaticBitSet(MAX_BUFFERS).initEmpty(),
            .textures_created = std.StaticBitSet(MAX_TEXTURES).initEmpty(),
            .shaders_created = std.StaticBitSet(MAX_SHADERS).initEmpty(),
            .pipelines_created = std.StaticBitSet(MAX_PIPELINES).initEmpty(),
            .bind_groups_created = std.StaticBitSet(MAX_BIND_GROUPS).initEmpty(),
            .in_render_pass = false,
            .in_compute_pass = false,
            .current_pipeline = null,
            .pixel_buffer = pixel_buffer,
        };
    }

    pub fn deinit(self: *Self, gpa: Allocator) void {
        // Pre-condition: was initialized
        assert(self.initialized);
        assert(!self.in_render_pass and !self.in_compute_pass);

        if (self.pixel_buffer) |buf| {
            gpa.free(buf);
        }
        self.* = undefined;
    }

    /// Set module reference for data lookups.
    pub fn setModule(self: *Self, module: *const format.Module) void {
        // Pre-conditions
        assert(self.initialized);
        assert(module.bytecode.len > 0);

        self.module = module;
    }

    /// Set time uniform for animations.
    pub fn setTime(self: *Self, time_value: f32) void {
        // Pre-conditions
        assert(self.initialized);
        assert(!std.math.isNan(time_value));

        self.time = time_value;
    }

    /// The frame counter this frame body runs at (`pngine-frame-inputs`).
    pub fn setFrameCounter(self: *Self, n: u32) void {
        assert(self.initialized);

        self.frame_counter = n;
        assert(self.frame_counter == n); // post: a later read sees it
    }

    /// Resize the render target. Refuses a zero dimension exactly as the native
    /// twin does; the pixel buffer is left alone because nothing here renders
    /// into it (see the module note above), so its size is not observable.
    pub fn resize(self: *Self, width: u32, height: u32) error{ZeroDimensions}!void {
        assert(self.initialized);

        if (width == 0 or height == 0) return error.ZeroDimensions;
        self.width = width;
        self.height = height;
        assert(self.width > 0 and self.height > 0);
    }

    /// Drop frame-scoped state after a frame that never reached submit(). The
    /// native twin releases encoders here; this backend holds none, so only the
    /// pass flags need clearing. Safe on an idle backend, as there.
    pub fn abortFrame(self: *Self) void {
        assert(self.initialized);

        self.in_render_pass = false;
        self.in_compute_pass = false;
        self.current_pipeline = null;
        assert(!self.in_render_pass and !self.in_compute_pass);
    }

    /// Read rendered pixels back to CPU.
    ///
    /// Pre-condition: GPU is initialized.
    /// Post-condition: Returns RGBA pixel data (width * height * 4 bytes).
    ///
    /// Caller owns the returned pixels.
    pub fn read_pixels(self: *Self, gpa: Allocator) Error![]u8 {
        // Pre-conditions
        assert(self.initialized);
        assert(self.pixel_buffer != null);

        if (self.pixel_buffer) |buf| {
            const result = gpa.alloc(u8, buf.len) catch {
                return Error.OutOfMemory;
            };
            @memcpy(result, buf);

            // Post-condition: result size matches pixel buffer
            assert(result.len == buf.len);
            return result;
        }

        return Error.RenderFailed;
    }

    // ========================================================================
    // GPU Backend Interface (required by Dispatcher)
    // ========================================================================

    pub fn create_buffer(self: *Self, gpa: Allocator, buffer_id: u16, size: u32, usage: u16) !void {
        _ = gpa;
        _ = size;
        _ = usage;

        assert(buffer_id < MAX_BUFFERS);
        assert(self.initialized);

        self.buffers_created.set(buffer_id);
    }

    pub fn create_texture(self: *Self, gpa: Allocator, texture_id: u16, descriptor_data_id: u16) !void {
        _ = gpa;
        _ = descriptor_data_id;

        assert(texture_id < MAX_TEXTURES);
        assert(self.initialized);

        self.textures_created.set(texture_id);
    }

    pub fn create_texture_view(self: *Self, gpa: Allocator, view_id: u16, texture_id: u16, descriptor_data_id: u16) !void {
        _ = gpa;
        _ = view_id;
        _ = descriptor_data_id;

        assert(texture_id < MAX_TEXTURES);
        assert(self.initialized);
    }

    pub fn create_sampler(self: *Self, gpa: Allocator, sampler_id: u16, descriptor_data_id: u16) !void {
        _ = gpa;
        _ = descriptor_data_id;
        _ = sampler_id;

        // No id assert: this backend keeps no sampler table, so there is no
        // bound to enforce. The assert that stood here read
        // `sampler_id < MAX_TEXTURES` — a borrowed number from another id space,
        // which guarded nothing and would Debug-panic on a perfectly legal
        // sampler id past the texture cap. MockGPU dropped the identical
        // copy-paste for the same reason.
        assert(self.initialized);
    }

    pub fn create_shader_module(self: *Self, gpa: Allocator, shader_id: u16, code_data_id: u16) !void {
        _ = gpa;
        _ = code_data_id;

        assert(shader_id < MAX_SHADERS);
        assert(self.initialized);

        self.shaders_created.set(shader_id);
    }

    pub fn create_render_pipeline(self: *Self, gpa: Allocator, pipeline_id: u16, descriptor_data_id: u16) !void {
        _ = gpa;
        _ = descriptor_data_id;

        assert(pipeline_id < MAX_PIPELINES);
        assert(self.initialized);

        self.pipelines_created.set(pipeline_id);
    }

    pub fn create_compute_pipeline(self: *Self, gpa: Allocator, pipeline_id: u16, descriptor_data_id: u16) !void {
        _ = gpa;
        _ = descriptor_data_id;

        assert(pipeline_id < MAX_PIPELINES);
        assert(self.initialized);

        self.pipelines_created.set(pipeline_id);
    }

    pub fn create_bind_group(self: *Self, gpa: Allocator, group_id: u16, layout_id: u16, entry_data_id: u16) !void {
        _ = gpa;
        _ = layout_id;
        _ = entry_data_id;

        assert(group_id < MAX_BIND_GROUPS);
        assert(self.initialized);

        self.bind_groups_created.set(group_id);
    }

    pub fn create_bind_group_layout(self: *Self, gpa: Allocator, layout_id: u16, descriptor_data_id: u16) !void {
        _ = gpa;
        _ = layout_id;
        _ = descriptor_data_id;

        assert(self.initialized);
    }

    pub fn create_pipeline_layout(self: *Self, gpa: Allocator, layout_id: u16, descriptor_data_id: u16) !void {
        _ = gpa;
        _ = layout_id;
        _ = descriptor_data_id;

        assert(self.initialized);
    }

    pub fn create_query_set(self: *Self, gpa: Allocator, query_set_id: u16, descriptor_data_id: u16) !void {
        _ = gpa;
        _ = query_set_id;
        _ = descriptor_data_id;

        assert(self.initialized);
    }

    pub fn create_image_bitmap(self: *Self, gpa: Allocator, bitmap_id: u16, blob_data_id: u16) !void {
        _ = gpa;
        _ = bitmap_id;
        _ = blob_data_id;

        assert(self.initialized);
    }

    pub fn create_render_bundle(self: *Self, gpa: Allocator, bundle_id: u16, descriptor_data_id: u16) !void {
        _ = gpa;
        _ = bundle_id;
        _ = descriptor_data_id;

        assert(self.initialized);
    }

    pub fn execute_bundles(self: *Self, gpa: Allocator, bundle_ids: []const u16) !void {
        _ = gpa;
        _ = bundle_ids;

        assert(self.in_render_pass);
        assert(self.initialized);
    }

    // ========================================================================
    // Pass Operations
    // ========================================================================

    pub fn begin_render_pass(self: *Self, gpa: Allocator, color_texture_id: u16, load_op: u8, store_op: u8, depth_texture_id: u16, clear_r_bits: u32, clear_g_bits: u32, clear_b_bits: u32, clear_a_bits: u32, resolve_texture_id: u16) !void {
        _ = gpa;
        _ = color_texture_id;
        _ = load_op;
        _ = store_op;
        _ = depth_texture_id;
        _ = clear_r_bits;
        _ = clear_g_bits;
        _ = clear_b_bits;
        _ = clear_a_bits;
        _ = resolve_texture_id;

        assert(!self.in_render_pass and !self.in_compute_pass);
        assert(self.initialized);

        self.in_render_pass = true;
        self.current_pipeline = null;
    }

    pub fn begin_render_pass_mrt(self: *Self, gpa: Allocator, attachments: []const @import("bytecode").emitter.Emitter.ColorAttachment, depth_texture_id: u16) !void {
        _ = gpa;
        _ = attachments;
        _ = depth_texture_id;

        assert(!self.in_render_pass and !self.in_compute_pass);
        assert(self.initialized);

        self.in_render_pass = true;
        self.current_pipeline = null;
    }

    pub fn begin_compute_pass(self: *Self, gpa: Allocator) !void {
        _ = gpa;

        assert(!self.in_render_pass and !self.in_compute_pass);
        assert(self.initialized);

        self.in_compute_pass = true;
        self.current_pipeline = null;
    }

    pub fn set_pipeline(self: *Self, gpa: Allocator, pipeline_id: u16) !void {
        _ = gpa;

        assert(self.in_render_pass or self.in_compute_pass);
        assert(self.initialized);

        self.current_pipeline = pipeline_id;
    }

    pub fn set_bind_group(self: *Self, gpa: Allocator, slot: u8, group_id: u16) !void {
        _ = gpa;
        _ = slot;
        _ = group_id;

        assert(self.in_render_pass or self.in_compute_pass);
        assert(self.initialized);
    }

    pub fn set_vertex_buffer(self: *Self, gpa: Allocator, slot: u8, buffer_id: u16) !void {
        _ = gpa;
        _ = slot;
        _ = buffer_id;

        assert(self.in_render_pass);
        assert(self.initialized);
    }

    pub fn set_index_buffer(self: *Self, gpa: Allocator, buffer_id: u16, index_format: u8) !void {
        _ = gpa;
        _ = buffer_id;
        _ = index_format;

        assert(self.in_render_pass);
        assert(self.initialized);
    }

    pub fn draw(self: *Self, gpa: Allocator, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) !void {
        _ = gpa;
        _ = vertex_count;
        _ = instance_count;
        _ = first_vertex;
        _ = first_instance;

        assert(self.in_render_pass);
        assert(self.initialized);
    }

    pub fn draw_indexed(self: *Self, gpa: Allocator, index_count: u32, instance_count: u32, first_index: u32, base_vertex: u32, first_instance: u32) !void {
        _ = gpa;
        _ = index_count;
        _ = instance_count;
        _ = first_index;
        _ = base_vertex;
        _ = first_instance;

        assert(self.in_render_pass);
        assert(self.initialized);
    }

    pub fn dispatch(self: *Self, gpa: Allocator, x: u32, y: u32, z: u32) !void {
        _ = gpa;
        _ = x;
        _ = y;
        _ = z;

        assert(self.in_compute_pass);
        assert(self.initialized);
    }

    pub fn set_viewport(self: *Self, gpa: Allocator, x: u32, y: u32, w: u32, h: u32, min_depth_bits: u32, max_depth_bits: u32) !void {
        _ = gpa;
        _ = x;
        _ = y;
        _ = w;
        _ = h;
        _ = min_depth_bits;
        _ = max_depth_bits;
        assert(self.in_render_pass);
    }

    pub fn set_pass_occlusion_query_set(self: *Self, gpa: Allocator, query_set_id: u16) !void {
        _ = self;
        _ = gpa;
        _ = query_set_id;
    }

    pub fn set_pass_timestamp_writes(self: *Self, gpa: Allocator, query_set_id: u16, begin_index: u32, end_index: u32) !void {
        _ = self;
        _ = gpa;
        _ = query_set_id;
        _ = begin_index;
        _ = end_index;
    }

    pub fn begin_occlusion_query(self: *Self, gpa: Allocator, query_index: u32) !void {
        _ = gpa;
        _ = query_index;
        assert(self.in_render_pass);
    }

    pub fn end_occlusion_query(self: *Self, gpa: Allocator) !void {
        _ = gpa;
        assert(self.in_render_pass);
    }

    pub fn resolve_query_set(self: *Self, gpa: Allocator, query_set_id: u16, first_query: u32, query_count: u32, dest_buffer_id: u16, dest_offset: u32) !void {
        _ = self;
        _ = gpa;
        _ = query_set_id;
        _ = first_query;
        _ = query_count;
        _ = dest_buffer_id;
        _ = dest_offset;
    }

    pub fn set_stencil_reference(self: *Self, gpa: Allocator, reference: u32) !void {
        _ = gpa;
        _ = reference;
        assert(self.in_render_pass);
    }

    pub fn set_blend_constant(self: *Self, gpa: Allocator, r_bits: u32, g_bits: u32, b_bits: u32, a_bits: u32) !void {
        _ = gpa;
        _ = r_bits;
        _ = g_bits;
        _ = b_bits;
        _ = a_bits;
        assert(self.in_render_pass);
    }

    pub fn set_scissor_rect(self: *Self, gpa: Allocator, x: u32, y: u32, w: u32, h: u32) !void {
        _ = gpa;
        _ = x;
        _ = y;
        _ = w;
        _ = h;
        assert(self.in_render_pass);
    }

    pub fn set_pass_depth_stencil_ops(self: *Self, gpa: Allocator, depth_load_op: u8, depth_store_op: u8, stencil_load_op: u8, stencil_store_op: u8) !void {
        _ = self;
        _ = gpa;
        _ = depth_load_op;
        _ = depth_store_op;
        _ = stencil_load_op;
        _ = stencil_store_op;
    }

    pub fn set_pass_clear_values(self: *Self, gpa: Allocator, depth_bits: u32, stencil_value: u32) !void {
        _ = self;
        _ = gpa;
        _ = depth_bits;
        _ = stencil_value;
    }

    pub fn draw_indirect(self: *Self, gpa: Allocator, buffer_id: u16, offset: u32) !void {
        _ = gpa;
        _ = buffer_id;
        _ = offset;
        assert(self.in_render_pass);
    }

    pub fn draw_indexed_indirect(self: *Self, gpa: Allocator, buffer_id: u16, offset: u32) !void {
        _ = gpa;
        _ = buffer_id;
        _ = offset;
        assert(self.in_render_pass);
    }

    pub fn dispatch_indirect(self: *Self, gpa: Allocator, buffer_id: u16, offset: u32) !void {
        _ = gpa;
        _ = buffer_id;
        _ = offset;
        assert(self.in_compute_pass);
    }

    pub fn end_pass(self: *Self, gpa: Allocator) !void {
        _ = gpa;

        assert(self.in_render_pass or self.in_compute_pass);
        assert(self.initialized);

        self.in_render_pass = false;
        self.in_compute_pass = false;
        self.current_pipeline = null;
    }

    // ========================================================================
    // Queue Operations
    // ========================================================================

    pub fn write_buffer(self: *Self, gpa: Allocator, buffer_id: u16, offset: u32, data_id: u16) !void {
        _ = gpa;
        _ = buffer_id;
        _ = offset;
        _ = data_id;

        assert(self.initialized);
    }

    /// Write the declared controls to a buffer (frame program §7.1). The
    /// headless stub has no buffer contents to mutate.
    pub fn write_controls(self: *Self, gpa: Allocator, buffer_id: u16, offset: u32, values: []const f32) !void {
        _ = gpa;
        _ = buffer_id;
        _ = offset;
        _ = values;

        assert(self.initialized);
    }

    pub fn submit(self: *Self, gpa: Allocator) !void {
        _ = gpa;

        assert(!self.in_render_pass and !self.in_compute_pass);
        assert(self.initialized);
    }

    pub fn copy_external_image_to_texture(self: *Self, gpa: Allocator, bitmap_id: u16, texture_id: u16, mip_level: u8, origin_x: u16, origin_y: u16, origin_z: u16) !void {
        _ = gpa;
        _ = bitmap_id;
        _ = texture_id;
        _ = mip_level;
        _ = origin_x;
        _ = origin_y;
        _ = origin_z;

        assert(self.initialized);
    }

    pub fn copy_buffer_to_buffer(self: *Self, gpa: Allocator, src_buffer: u16, src_offset: u32, dst_buffer: u16, dst_offset: u32, size: u32) !void {
        _ = gpa;
        _ = src_buffer;
        _ = src_offset;
        _ = dst_buffer;
        _ = dst_offset;
        _ = size;

        assert(self.initialized);
    }

    pub fn copy_texture_to_texture(self: *Self, gpa: Allocator, src_texture: u16, dst_texture: u16) !void {
        _ = gpa;
        _ = src_texture;
        _ = dst_texture;

        assert(self.initialized);
    }

    pub fn write_uniform(self: *Self, gpa: Allocator, buffer_id: u16, uniform_id: u16) !void {
        _ = gpa;
        _ = buffer_id;
        _ = uniform_id;

        assert(self.initialized);
    }

    // ========================================================================
    // WASM Module Operations (stub - native GPU doesn't support WASM calls)
    // ========================================================================

    pub fn init_wasm_module(self: *Self, gpa: Allocator, module_id: u16, wasm_data_id: u16) !void {
        _ = gpa;
        _ = module_id;
        _ = wasm_data_id;

        assert(self.initialized);

        // WASM module initialization is a no-op for native GPU
        // WASM calls are only meaningful in browser context
    }

    pub fn call_wasm_func(self: *Self, gpa: Allocator, call_id: u16, module_id: u16, func_name_id: u16, args: []const u8) !void {
        _ = gpa;
        _ = call_id;
        _ = module_id;
        _ = func_name_id;
        _ = args;

        assert(self.initialized);

        // WASM function calls are a no-op for native GPU
        // WASM calls are only meaningful in browser context
    }

    pub fn write_buffer_from_wasm(self: *Self, gpa: Allocator, call_id: u16, buffer_id: u16, offset: u32, byte_len: u32) !void {
        _ = gpa;
        _ = call_id;
        _ = buffer_id;
        _ = offset;
        _ = byte_len;

        assert(self.initialized);

        // WASM buffer writes are a no-op for native GPU
        // WASM calls are only meaningful in browser context
    }

    /// Write time/canvas uniform data to GPU buffer.
    /// Runtime provides f32 values: time, canvas_width, canvas_height[, aspect_ratio].
    pub fn write_time_uniform(self: *Self, gpa: Allocator, buffer_id: u16, buffer_offset: u32, size: u16) !void {
        _ = gpa;
        _ = buffer_id;
        _ = buffer_offset;
        _ = size;
        assert(self.initialized);
    }

    pub fn write_pointer_uniform(self: *Self, gpa: Allocator, buffer_id: u16, buffer_offset: u32, size: u16) !void {
        _ = gpa;
        _ = buffer_id;
        _ = buffer_offset;
        _ = size;
        assert(self.initialized);
    }

    pub fn write_audio_data(self: *Self, gpa: Allocator, buffer_id: u16, buffer_offset: u32, size: u16) !void {
        _ = gpa;
        _ = buffer_id;
        _ = buffer_offset;
        _ = size;
        assert(self.initialized);
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

// The five "regression: <method> stub exists and callable" tests that used to
// live here were deleted. They asserted only that a method existed and did not
// crash, which is now checked far more strictly, and for all ~46 contract
// methods rather than five, by the comptime Backend(T).validate() that
// main.zig triggers via `Dispatcher(NativeGPU)`. Calling a no-op and observing
// that nothing happened added no signal on top of that.
