//! Miniray FFI Bindings
//!
//! Direct C function calls to libminiray.a for WGSL reflection.
//! Provides zero-overhead reflection when the library is linked.
//!
//! ## Compile-time Configuration
//!
//! When `has_miniray_lib` is true (library linked), FFI functions are available.
//! When false, calling FFI functions is a compile error.
//!
//! ## Memory Ownership
//!
//! - `reflectFfi` returns a slice pointing to C-allocated memory
//! - Caller MUST call `freeResult` to free the memory
//! - Do NOT use Zig allocators to free FFI results
//!
//! ## Thread Safety
//!
//! The Go runtime is thread-safe. Multiple concurrent calls to `reflectFfi`
//! are allowed from different threads.

const std = @import("std");
const builtin = @import("builtin");

/// Build options injected by build.zig
const build_options = @import("build_options");

/// Whether libminiray.a is linked (compile-time constant)
pub const has_miniray_lib: bool = if (@hasDecl(build_options, "has_miniray_lib"))
    build_options.has_miniray_lib
else
    false;

/// C bindings from libminiray.h
/// Only available when has_miniray_lib is true
const c = if (has_miniray_lib) @cImport({
    @cInclude("libminiray.h");
}) else struct {};

/// Error codes from miniray
pub const Error = error{
    /// JSON encoding failed in Go
    JsonEncodeFailed,
    /// Null input pointer
    NullInput,
    /// Unknown error from library
    UnknownError,
    /// Library not linked (compile-time)
    LibraryNotLinked,
};

/// Result of FFI reflection call
pub const FfiResult = struct {
    /// JSON data (C-allocated, must free with freeResult)
    json: []const u8,

    /// Free the result memory
    pub fn deinit(self: *FfiResult) void {
        if (comptime has_miniray_lib) {
            c.miniray_free(@ptrCast(@constCast(self.json.ptr)));
        }
        self.* = undefined;
    }
};

/// Reflect on WGSL source using the linked C library.
///
/// Returns JSON string in C-allocated memory.
/// Caller MUST call result.deinit() to free the memory.
///
/// ## Example
///
/// ```zig
/// var result = try miniray_ffi.reflectFfi(wgsl_source);
/// defer result.deinit();
/// // Use result.json...
/// ```
///
/// ## Errors
///
/// - `JsonEncodeFailed`: Go failed to encode result as JSON
/// - `NullInput`: Source pointer was null
/// - `UnknownError`: Unknown error code from library
///
/// ## Compile-time
///
/// If `has_miniray_lib` is false, this function will not compile.
pub fn reflectFfi(source: []const u8) Error!FfiResult {
    if (comptime !has_miniray_lib) {
        @compileError("miniray_ffi.reflectFfi called but has_miniray_lib is false. " ++
            "Link libminiray.a or use subprocess fallback.");
    }

    // Pre-conditions
    std.debug.assert(source.len > 0);
    std.debug.assert(source.len <= std.math.maxInt(c_int));

    var out_json: [*c]u8 = undefined;
    var out_len: c_int = 0;

    const result = c.miniray_reflect(
        @ptrCast(@constCast(source.ptr)),
        @intCast(source.len),
        &out_json,
        &out_len,
    );

    // Post-condition: check error codes
    return switch (result) {
        0 => FfiResult{
            .json = out_json[0..@intCast(out_len)],
        },
        1 => error.JsonEncodeFailed,
        2 => error.NullInput,
        else => error.UnknownError,
    };
}

/// Get the library version string.
/// Returns null if library not linked.
pub fn getVersion() ?[]const u8 {
    if (comptime !has_miniray_lib) {
        return null;
    }

    const version_ptr = c.miniray_version();
    if (version_ptr == null) {
        return null;
    }

    // Find null terminator
    var len: usize = 0;
    while (version_ptr[len] != 0) : (len += 1) {
        if (len > 100) break; // Safety bound
    }

    return version_ptr[0..len];
}

// ============================================================================
// Tests
// ============================================================================

test "FFI: has_miniray_lib constant is defined" {
    // This test always passes - it just verifies the constant exists
    const has_lib = has_miniray_lib;
    _ = has_lib;
}

test "FFI: reflectFfi with library linked" {
    if (comptime !has_miniray_lib) {
        // Skip test if library not linked
        return error.SkipZigTest;
    }

    const wgsl =
        \\struct U { time: f32, }
        \\@group(0) @binding(0) var<uniform> u: U;
    ;

    var result = try reflectFfi(wgsl);
    defer result.deinit();

    // Verify it's valid JSON (basic check)
    try std.testing.expect(result.json.len > 0);
    try std.testing.expect(result.json[0] == '{');
    try std.testing.expect(result.json[result.json.len - 1] == '}');

    // Verify it contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"bindings\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"structs\"") != null);
}

test "FFI: getVersion returns version string" {
    if (comptime !has_miniray_lib) {
        try std.testing.expect(getVersion() == null);
        return;
    }

    const version = getVersion();
    try std.testing.expect(version != null);
    try std.testing.expect(version.?.len > 0);
}
