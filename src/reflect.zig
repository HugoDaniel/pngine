//! WGSL Reflection Module
//!
//! Provides WGSL shader reflection via miniray integration.
//! Used by the DSL compiler for auto buffer sizing and input metadata.
//!
//! ## FFI vs Subprocess
//!
//! When libminiray.a is linked (has_miniray_lib=true), reflection uses
//! direct C function calls for ~10-50x speedup over subprocess spawning.
//!
//! Build with FFI: zig build -Dminiray-lib=../miniray/build/libminiray.a
//! Or place library at: ../miniray/build/libminiray.a (auto-detected)

pub const miniray = @import("reflect/miniray.zig");
pub const miniray_ffi = @import("reflect/miniray_ffi.zig");

// Re-export main types
pub const Miniray = miniray.Miniray;
pub const ReflectionData = miniray.ReflectionData;
pub const Binding = miniray.Binding;
pub const Layout = miniray.Layout;
pub const Field = miniray.Field;
pub const EntryPoint = miniray.EntryPoint;

// Re-export FFI status
pub const has_miniray_lib = miniray_ffi.has_miniray_lib;

test {
    _ = miniray;
    _ = miniray_ffi;
    _ = @import("reflect/benchmark.zig");
}
