//! Reflect Standalone Module
//!
//! Entry point for standalone reflect tests. WGSL shader reflection
//! via miniray integration. Zero external dependencies (std only).
//!
//! Test count: 8 tests
//! - miniray: 7
//! - reflect: 1

const std = @import("std");

// Re-export miniray types
pub const miniray = @import("miniray.zig");
pub const Miniray = miniray.Miniray;
pub const ReflectionData = miniray.ReflectionData;
pub const Binding = miniray.Binding;
pub const Layout = miniray.Layout;
pub const Field = miniray.Field;
pub const EntryPoint = miniray.EntryPoint;

// Include all tests
test {
    _ = @import("miniray.zig");
}

// Verify re-exports work
test "reflect module re-exports" {
    // Miniray is a zero-sized struct, just verify types are accessible
    _ = Miniray{};
    _ = ReflectionData;
}
