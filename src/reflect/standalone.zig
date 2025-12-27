//! Reflect Standalone Module
//!
//! Entry point for standalone reflect tests. WGSL shader reflection
//! via miniray integration. Optionally uses FFI when libminiray.a linked.
//!
//! Test count: 14+ tests
//! - miniray: 10 (7 parsing + 3 FFI-aware)
//! - miniray_ffi: 3
//! - benchmark: 3 (optional)
//! - reflect: 1

const std = @import("std");

// Re-export miniray types
pub const miniray = @import("miniray.zig");
pub const miniray_ffi = @import("miniray_ffi.zig");
pub const Miniray = miniray.Miniray;
pub const ReflectionData = miniray.ReflectionData;
pub const Binding = miniray.Binding;
pub const Layout = miniray.Layout;
pub const Field = miniray.Field;
pub const EntryPoint = miniray.EntryPoint;

// FFI status (compile-time)
pub const has_ffi = miniray.has_ffi;

// Include all tests
test {
    _ = @import("miniray.zig");
    _ = @import("miniray_ffi.zig");
    _ = @import("benchmark.zig");
}

// Verify re-exports work
test "reflect module re-exports" {
    // Miniray is a zero-sized struct, just verify types are accessible
    _ = Miniray{};
    _ = ReflectionData;
    // FFI status is accessible
    _ = has_ffi;
}
