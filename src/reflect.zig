//! WGSL Reflection Module
//!
//! Provides WGSL shader reflection via miniray integration.
//! Used by the DSL compiler for auto buffer sizing and input metadata.

pub const miniray = @import("reflect/miniray.zig");

// Re-export main types
pub const Miniray = miniray.Miniray;
pub const ReflectionData = miniray.ReflectionData;
pub const Binding = miniray.Binding;
pub const Layout = miniray.Layout;
pub const Field = miniray.Field;
pub const EntryPoint = miniray.EntryPoint;

test {
    _ = miniray;
}
