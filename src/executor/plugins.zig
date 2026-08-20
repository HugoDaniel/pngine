//! Plugin Architecture for Embedded Executor
//!
//! Defines plugin interfaces and conditional compilation support for the
//! embedded WASM executor. Plugins are selected at compile-time based on
//! DSL feature analysis.
//!
//! ## Design
//!
//! - Plugins are compile-time selected via build options
//! - Each plugin maps to specific command opcodes
//! - Plugin traits define handler interfaces
//! - Core plugin is always included
//!
//! ## Invariants
//!
//! - Core plugin is always enabled
//! - Plugin selection is immutable after build
//! - All handlers for enabled plugins must be implemented

const std = @import("std");
const assert = std.debug.assert;
const Cmd = @import("command_buffer.zig").Cmd;

// Use bytecode module import
const bytecode_mod = @import("bytecode");

// Re-export types from bytecode module for convenience
pub const PluginSet = bytecode_mod.PluginSet;
pub const Plugin = bytecode_mod.Plugin;

// ============================================================================
// Build-time Plugin Configuration
// ============================================================================

/// Plugin options from the build system, read through the defaulting-import
/// shim (the same pattern wasm_entry.zig's `wasm_config` uses). build.zig wires
/// a `plugins` options module at every target that compiles this file: the
/// executor VARIANTS pass their real per-variant flags, while generic/test/CLI
/// targets get an all-on default module. Each flag falls back to `true` when its
/// declaration is absent, so a partial options module still means "full".
///
/// C11 fix (item 2.2): the old probe `@hasDecl(@import("root"), "plugins")`
/// tested for a root *declaration* named `plugins`, but build.zig passes the
/// flags as a *module import* — so the probe was permanently false and EVERY
/// variant silently compiled all-plugins-on (all 8 binaries byte-identical). The
/// `executors` build step now guards that core and full differ.
const cfg = @import("plugins");
pub const options = struct {
    pub const core: bool = if (@hasDecl(cfg, "core")) cfg.core else true;
    pub const render: bool = if (@hasDecl(cfg, "render")) cfg.render else true;
    pub const compute: bool = if (@hasDecl(cfg, "compute")) cfg.compute else true;
    pub const wasm: bool = if (@hasDecl(cfg, "wasm")) cfg.wasm else true;
    pub const animation: bool = if (@hasDecl(cfg, "animation")) cfg.animation else true;
    pub const texture: bool = if (@hasDecl(cfg, "texture")) cfg.texture else true;
};

/// Check if a plugin is enabled at compile time.
pub fn isEnabled(comptime plugin: Plugin) bool {
    return switch (plugin) {
        .core => options.core,
        .render => options.render,
        .compute => options.compute,
        .wasm => options.wasm,
        .animation => options.animation,
        .texture => options.texture,
    };
}

/// Get the PluginSet for currently enabled plugins.
pub fn enabledPlugins() PluginSet {
    return .{
        .core = options.core,
        .render = options.render,
        .compute = options.compute,
        .wasm = options.wasm,
        .animation = options.animation,
        .texture = options.texture,
    };
}

// ============================================================================
// Command to Plugin Mapping
// ============================================================================

/// Determine which plugin owns a command opcode.
/// Returns null for core commands (always available).
pub fn commandPlugin(cmd: Cmd) ?Plugin {
    return switch (cmd) {
        // Core commands (always available)
        .create_buffer,
        .create_sampler,
        .create_bind_group,
        .create_bind_group_layout,
        .create_pipeline_layout,
        .write_buffer,
        .write_time_uniform,
        .write_pointer_uniform,
        .copy_buffer_to_buffer,
        .resolve_query_set,
        .submit,
        .end,
        => null,

        // Render plugin
        .create_render_pipeline,
        .create_render_bundle,
        .begin_render_pass,
        .begin_render_pass_mrt,
        .begin_render_pass_f32,
        .begin_render_pass_mrt_f32,
        .set_pipeline, // Shared with compute, but render handles it
        .set_bind_group,
        .set_vertex_buffer,
        .set_index_buffer,
        .draw,
        .draw_indexed,
        .draw_indirect,
        .draw_indexed_indirect,
        .set_viewport,
        .set_pass_occlusion_query_set,
        .set_pass_timestamp_writes,
        .begin_occlusion_query,
        .end_occlusion_query,
        .set_stencil_reference,
        .set_scissor_rect,
        .set_pass_depth_stencil_ops,
        .set_blend_constant,
        .set_pass_clear_values,
        .end_pass, // Shared with compute
        .execute_bundles,
        => .render,

        // Compute plugin
        .create_compute_pipeline,
        .begin_compute_pass,
        .dispatch,
        .dispatch_indirect,
        => .compute,

        // Texture plugin
        .create_texture,
        .create_texture_view,
        .create_image_bitmap,
        .copy_texture_to_texture,
        .copy_external_image_to_texture,
        => .texture,

        // WASM plugin
        .init_wasm_module,
        .call_wasm_func,
        .write_buffer_from_wasm,
        => .wasm,

        // Query set - core for now
        .create_query_set,
        .create_shader,
        => null,
    };
}

/// Check if a command is available with current plugin configuration.
/// Note: Uses runtime switch since cmd is runtime value.
pub fn is_command_enabled(cmd: Cmd) bool {
    const plugin = commandPlugin(cmd);
    if (plugin) |p| {
        return switch (p) {
            .core => options.core,
            .render => options.render,
            .compute => options.compute,
            .wasm => options.wasm,
            .animation => options.animation,
            .texture => options.texture,
        };
    }
    // Core commands always enabled
    return true;
}

// ============================================================================
// Plugin Handler Traits
// ============================================================================

/// Error type for plugin handlers.
pub const HandlerError = error{
    OutOfMemory,
    InvalidOpcode,
    InvalidData,
    BufferOverflow,
    ResourceNotFound,
    WasmError,
    PluginDisabled,
};

/// Core plugin handler trait.
/// Always included - handles basic resource creation and buffer ops.
pub fn CoreHandler(comptime Context: type) type {
    return struct {
        pub const Error = HandlerError;

        /// Create a GPU buffer.
        createBuffer: *const fn (ctx: *Context, id: u16, size: u32, usage: u16) Error!void,

        /// Create a sampler.
        createSampler: *const fn (ctx: *Context, id: u16, desc_ptr: u32, desc_len: u32) Error!void,

        /// Write data to buffer.
        writeBuffer: *const fn (ctx: *Context, id: u16, offset: u32, data_ptr: u32, data_len: u32) Error!void,

        /// Write time uniform (convenience for pngineInputs).
        writeTimeUniform: *const fn (ctx: *Context, id: u16, time: f32, width: f32, height: f32) Error!void,

        /// Copy buffer to buffer.
        copyBufferToBuffer: *const fn (ctx: *Context, src: u16, src_off: u32, dst: u16, dst_off: u32, size: u32) Error!void,

        /// Submit queued commands.
        submit: *const fn (ctx: *Context) Error!void,

        /// Create shader module.
        createShader: *const fn (ctx: *Context, id: u16, code_ptr: u32, code_len: u32) Error!void,

        /// Create bind group.
        createBindGroup: *const fn (ctx: *Context, id: u16, layout: u16, entries_ptr: u32, entries_len: u32) Error!void,

        /// Create bind group layout.
        createBindGroupLayout: *const fn (ctx: *Context, id: u16, entries_ptr: u32, entries_len: u32) Error!void,

        /// Create pipeline layout.
        createPipelineLayout: *const fn (ctx: *Context, id: u16, layouts_ptr: u32, layouts_len: u32) Error!void,
    };
}

/// Render plugin handler trait.
/// Handles render pipelines, passes, and draw commands.
pub fn RenderHandler(comptime Context: type) type {
    return struct {
        pub const Error = HandlerError;

        /// Create render pipeline.
        createRenderPipeline: *const fn (ctx: *Context, id: u16, desc_ptr: u32, desc_len: u32) Error!void,

        /// Begin render pass.
        beginRenderPass: *const fn (ctx: *Context, color_attachment: u16, load_op: u8, store_op: u8, depth_attachment: u16) Error!void,

        /// Set current pipeline.
        setPipeline: *const fn (ctx: *Context, id: u16) Error!void,

        /// Set bind group.
        setBindGroup: *const fn (ctx: *Context, slot: u8, id: u16) Error!void,

        /// Set vertex buffer.
        setVertexBuffer: *const fn (ctx: *Context, slot: u8, id: u16) Error!void,

        /// Set index buffer.
        setIndexBuffer: *const fn (ctx: *Context, id: u16, format: u8) Error!void,

        /// Draw vertices.
        draw: *const fn (ctx: *Context, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) Error!void,

        /// Draw indexed.
        drawIndexed: *const fn (ctx: *Context, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) Error!void,

        /// End current pass.
        endPass: *const fn (ctx: *Context) Error!void,

        /// Execute render bundles.
        executeBundles: *const fn (ctx: *Context, bundles_ptr: u32, bundles_len: u32) Error!void,

        /// Create render bundle.
        createRenderBundle: *const fn (ctx: *Context, id: u16, desc_ptr: u32, desc_len: u32) Error!void,
    };
}

/// Compute plugin handler trait.
/// Handles compute pipelines and dispatch.
pub fn ComputeHandler(comptime Context: type) type {
    return struct {
        pub const Error = HandlerError;

        /// Create compute pipeline.
        createComputePipeline: *const fn (ctx: *Context, id: u16, desc_ptr: u32, desc_len: u32) Error!void,

        /// Begin compute pass.
        beginComputePass: *const fn (ctx: *Context) Error!void,

        /// Dispatch workgroups.
        dispatch: *const fn (ctx: *Context, x: u32, y: u32, z: u32) Error!void,

        /// End compute pass (shared with render but listed here for clarity).
        endPass: *const fn (ctx: *Context) Error!void,

        /// Set pipeline (shared with render).
        setPipeline: *const fn (ctx: *Context, id: u16) Error!void,

        /// Set bind group (shared with render).
        setBindGroup: *const fn (ctx: *Context, slot: u8, id: u16) Error!void,
    };
}

/// Texture plugin handler trait.
/// Handles texture creation and image loading.
pub fn TextureHandler(comptime Context: type) type {
    return struct {
        pub const Error = HandlerError;

        /// Create texture.
        createTexture: *const fn (ctx: *Context, id: u16, desc_ptr: u32, desc_len: u32) Error!void,

        /// Create texture view.
        createTextureView: *const fn (ctx: *Context, id: u16, texture_id: u16, desc_ptr: u32, desc_len: u32) Error!void,

        /// Create image bitmap from data.
        createImageBitmap: *const fn (ctx: *Context, id: u16, data_ptr: u32, data_len: u32) Error!void,

        /// Copy texture to texture.
        copyTextureToTexture: *const fn (ctx: *Context, src: u16, dst: u16, width: u16, height: u16) Error!void,

        /// Copy external image to texture.
        copyExternalImageToTexture: *const fn (ctx: *Context, src_id: u16, dst_id: u16, width: u16, height: u16) Error!void,
    };
}

/// WASM plugin handler trait.
/// Handles nested WASM module execution.
pub fn WasmHandler(comptime Context: type) type {
    return struct {
        pub const Error = HandlerError;

        /// Initialize a WASM module from embedded bytes.
        initWasmModule: *const fn (ctx: *Context, module_id: u16, wasm_ptr: u32, wasm_len: u32) Error!void,

        /// Call a function in a WASM module.
        callWasmFunc: *const fn (ctx: *Context, call_id: u16, module_id: u16, func_ptr: u32, func_len: u32, args_ptr: u32, args_len: u32) Error!void,

        /// Write WASM call result to a buffer.
        writeBufferFromWasm: *const fn (ctx: *Context, call_id: u16, buffer_id: u16, offset: u32, len: u32) Error!void,
    };
}

/// Animation plugin handler trait.
/// Handles scene transitions and timeline.
pub fn AnimationHandler(comptime Context: type) type {
    return struct {
        pub const Error = HandlerError;

        /// Set current scene.
        setScene: *const fn (ctx: *Context, scene_id: u16, transition: u8) Error!void,

        /// Get scene time info.
        getSceneTime: *const fn (ctx: *Context) struct { scene_time: f32, duration: f32, normalized: f32 },
    };
}

// ============================================================================
// Plugin Registry
// ============================================================================

/// Combined handler registry for all plugins.
/// Uses optional fields for disabled plugins.
pub fn PluginRegistry(comptime Context: type) type {
    return struct {
        const Self = @This();

        core: CoreHandler(Context),
        render: if (isEnabled(.render)) RenderHandler(Context) else void,
        compute: if (isEnabled(.compute)) ComputeHandler(Context) else void,
        texture: if (isEnabled(.texture)) TextureHandler(Context) else void,
        wasm: if (isEnabled(.wasm)) WasmHandler(Context) else void,
        animation: if (isEnabled(.animation)) AnimationHandler(Context) else void,

        /// Check if registry has a specific plugin.
        pub fn hasPlugin(comptime plugin: Plugin) bool {
            return isEnabled(plugin);
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
