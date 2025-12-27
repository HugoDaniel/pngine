//! Plugin Implementations
//!
//! This module exports the individual plugin implementations for the
//! embedded executor architecture. Each plugin handles a specific
//! category of GPU commands.
//!
//! ## Plugin Overview
//!
//! | Plugin     | Description                    | Commands                |
//! |------------|--------------------------------|-------------------------|
//! | core       | Always enabled                 | Buffer, sampler, shader |
//! | render     | Render pipelines and passes    | Draw, render pass       |
//! | compute    | Compute pipelines              | Dispatch                |
//! | texture    | Texture and image handling     | Texture creation        |
//! | wasm       | Nested WASM execution          | WASM-in-WASM calls      |
//! | animation  | Scene timeline                 | Frame selection         |
//!
//! ## Usage
//!
//! Plugins are conditionally included based on DSL analysis.
//! The build system passes plugin flags via build options.

pub const core = @import("core.zig");
pub const render = @import("render.zig");
pub const compute = @import("compute.zig");
pub const texture = @import("texture.zig");
pub const wasm = @import("wasm.zig");
pub const animation = @import("animation.zig");

// Re-export main types
pub const CorePlugin = core.CorePlugin;
pub const RenderPlugin = render.RenderPlugin;
pub const ComputePlugin = compute.ComputePlugin;
pub const TexturePlugin = texture.TexturePlugin;
pub const WasmPlugin = wasm.WasmPlugin;
pub const AnimationPlugin = animation.AnimationPlugin;

// Tests
test {
    _ = core;
    _ = render;
    _ = compute;
    _ = texture;
    _ = wasm;
    _ = animation;
}
