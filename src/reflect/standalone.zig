//! Reflect Standalone Module
//!
//! Entry point for standalone reflect tests. WGSL shader reflection
//! via native wgslender Zig module.

const std = @import("std");

// Re-export wgslender types
pub const wgslender = @import("wgslender.zig");
pub const wgslender_native = @import("wgslender_native.zig");
pub const Wgslender = wgslender.Wgslender;
pub const ReflectionData = wgslender.ReflectionData;
pub const Binding = wgslender.Binding;
pub const Layout = wgslender.Layout;
pub const Field = wgslender.Field;
pub const EntryPoint = wgslender.EntryPoint;

// Include all tests

// Verify re-exports work
