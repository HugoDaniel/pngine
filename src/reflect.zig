//! WGSL Reflection Module
//!
//! Provides WGSL shader reflection via native wgslender Zig module.
//! Used by the DSL compiler for auto buffer sizing and input metadata.

pub const wgslender = @import("reflect/wgslender.zig");
pub const wgslender_native = @import("reflect/wgslender_native.zig");

// Re-export main types
pub const Wgslender = wgslender.Wgslender;
pub const ReflectionData = wgslender.ReflectionData;
pub const Binding = wgslender.Binding;
pub const Resource = wgslender.Resource;
pub const Layout = wgslender.Layout;
pub const Field = wgslender.Field;
pub const EntryPoint = wgslender.EntryPoint;
