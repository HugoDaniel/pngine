//! Miniray FFI Bindings
//!
//! Direct C function calls to libminiray.a (Go C-archive) for WGSL reflection
//! and minification. Provides ~50x faster reflection than subprocess spawning.
//!
//! ## C API Contract (libminiray.h)
//!
//! The library exports these C functions:
//!
//! ```c
//! // Reflect on WGSL source, returns JSON with bindings/structs/entryPoints
//! // Returns: 0=success, 1=json_encode_failed, 2=null_input
//! int miniray_reflect(
//!     const char* source,      // WGSL source code (not null-terminated required)
//!     int source_len,          // Length of source in bytes
//!     char** out_json,         // Output: JSON string (caller must free)
//!     int* out_json_len        // Output: Length of JSON
//! );
//!
//! // Minify WGSL and return reflection with mapped identifiers
//! // Returns: 0=success, 1=json_encode_failed, 2=null_input
//! int miniray_minify_and_reflect(
//!     const char* source,      // WGSL source code
//!     int source_len,          // Length of source
//!     const char* options,     // JSON options (nullable)
//!     int options_len,         // Length of options (0 if null)
//!     char** out_code,         // Output: Minified WGSL (caller must free)
//!     int* out_code_len,       // Output: Length of minified code
//!     char** out_json,         // Output: Reflection JSON (caller must free)
//!     int* out_json_len        // Output: Length of JSON
//! );
//!
//! // Free memory allocated by miniray functions
//! void miniray_free(void* ptr);
//!
//! // Get library version string (static, do not free)
//! const char* miniray_version(void);
//! ```
//!
//! ## JSON Response Format
//!
//! The reflection JSON has this structure:
//!
//! ```json
//! {
//!   "bindings": [{
//!     "group": 0,
//!     "binding": 0,
//!     "name": "uniforms",
//!     "nameMapped": "a",           // Only with minify_and_reflect
//!     "addressSpace": "uniform",
//!     "type": "Uniforms",
//!     "typeMapped": "b",           // Only with minify_and_reflect
//!     "layout": {
//!       "size": 16,
//!       "alignment": 16,
//!       "fields": [{
//!         "name": "time",
//!         "type": "f32",
//!         "offset": 0,
//!         "size": 4,
//!         "alignment": 4
//!       }]
//!     }
//!   }],
//!   "structs": {
//!     "Uniforms": { "size": 16, "alignment": 16, "fields": [...] }
//!   },
//!   "entryPoints": [{
//!     "name": "main",
//!     "stage": "compute"           // "vertex", "fragment", or "compute"
//!   }],
//!   "errors": [{                   // Parse errors (if any)
//!     "message": "unexpected token",
//!     "line": 5,
//!     "column": 12
//!   }]
//! }
//! ```
//!
//! ## Compile-time Configuration
//!
//! - `has_miniray_lib = true`: Library linked, FFI functions available
//! - `has_miniray_lib = false`: Library not linked, FFI calls are compile errors
//!
//! Build with: `zig build -Dminiray-lib=/path/to/libminiray.a`
//!
//! ## Memory Ownership
//!
//! - FFI results contain C-allocated memory (Go runtime heap)
//! - Caller MUST call `result.deinit()` to free the memory
//! - Do NOT use Zig allocators to free FFI results
//! - Do NOT access result data after calling deinit()
//!
//! ## Thread Safety
//!
//! The Go runtime is thread-safe. Multiple concurrent calls are allowed.
//!
//! ## Required Version
//!
//! miniray 0.3.0+ required for:
//! - WGSL-spec memory layout computation
//! - Array element stride/type metadata
//! - Minification with identifier mapping

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

/// Error codes from miniray C API.
///
/// These map to the integer return codes from C functions:
/// - 0 = success (no error)
/// - 1 = JsonEncodeFailed (Go JSON marshaling failed)
/// - 2 = NullInput (source pointer was null)
/// - Other = UnknownError
pub const Error = error{
    /// C API returned 1: JSON encoding failed in Go runtime.
    /// This can happen if reflection produces non-serializable data.
    JsonEncodeFailed,
    /// C API returned 2: Source pointer was null.
    /// This should never happen from Zig (assertions catch it).
    NullInput,
    /// C API returned unexpected error code.
    /// Check miniray version compatibility.
    UnknownError,
    /// Library not linked at compile time.
    /// Build with: zig build -Dminiray-lib=/path/to/libminiray.a
    LibraryNotLinked,
};

/// Result of FFI reflection call.
///
/// Contains C-allocated memory that MUST be freed by calling deinit().
///
/// ## Lifecycle
///
/// ```zig
/// var result = try reflectFfi(source);
/// defer result.deinit();  // REQUIRED: frees C memory
///
/// // Use result.json while result is valid
/// const data = try parseJson(allocator, result.json);
/// // data is Zig-allocated, independent of result
/// ```
///
/// ## Memory Layout
///
/// The `json` slice points directly into Go runtime heap memory.
/// Do not store references to this memory after deinit().
pub const FfiResult = struct {
    /// JSON reflection data as UTF-8 string.
    /// Points to C-allocated memory (Go heap).
    /// Valid until deinit() is called.
    json: []const u8,

    /// Free the C-allocated memory.
    /// After calling, this struct is undefined and must not be used.
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

/// Result of FFI minify+reflect call.
///
/// Contains two C-allocated buffers that MUST be freed by calling deinit().
///
/// ## Lifecycle
///
/// ```zig
/// var result = try minifyAndReflectFfi(source, null);
/// defer result.deinit();  // REQUIRED: frees both buffers
///
/// // Copy minified code if needed beyond this scope
/// const minified = try allocator.dupe(u8, result.code);
/// ```
///
/// ## Mapped Identifiers
///
/// When minification renames identifiers, the JSON includes mapping fields:
/// - `nameMapped`: minified binding variable name
/// - `typeMapped`: minified struct type name
/// - `elementTypeMapped`: minified array element type name
///
/// Entry points and struct field names are NEVER renamed.
pub const MinifyAndReflectResult = struct {
    /// Minified WGSL code as UTF-8 string.
    /// Contains the same shader logic with shorter identifiers.
    /// Points to C-allocated memory (Go heap).
    code: []const u8,

    /// JSON reflection data with mapped identifier names.
    /// Contains both original names (for API) and mapped names (in shader).
    /// Points to C-allocated memory (Go heap).
    json: []const u8,

    /// Free all C-allocated memory.
    /// After calling, this struct is undefined and must not be used.
    pub fn deinit(self: *MinifyAndReflectResult) void {
        if (comptime has_miniray_lib) {
            c.miniray_free(@ptrCast(@constCast(self.code.ptr)));
            c.miniray_free(@ptrCast(@constCast(self.json.ptr)));
        }
        self.* = undefined;
    }
};

/// Minify WGSL source and return reflection data with mapped names.
///
/// This combines minification with reflection, returning both the minified code
/// and reflection JSON where `nameMapped`, `typeMapped`, `elementTypeMapped` fields
/// contain the actual minified identifier names.
///
/// ## What Gets Minified
///
/// | Category          | Example               | Minified? |
/// |-------------------|-----------------------|-----------|
/// | Struct type names | `struct Uniforms`     | Yes → `a` |
/// | Local variables   | `let myValue = 1.0`   | Yes → `b` |
/// | Helper functions  | `fn computeNormal()`  | Yes → `c` |
/// | Function params   | `fn calc(input: f32)` | Yes       |
/// | Entry points      | `@vertex fn vs()`     | NO        |
/// | Struct fields     | `.time`, `.position`  | NO        |
/// | Binding vars*     | `var<uniform> u`      | NO*       |
///
/// *Binding variable names preserved by default. Pass `{"mangleBindings":true}`
/// in options_json to enable mangling (requires name mapping in uniform table).
///
/// ## Parameters
///
/// - `source`: WGSL source code to minify
/// - `options_json`: Optional JSON configuration, or null for defaults
///
/// ## Options JSON Format
///
/// ```json
/// {
///   "mangleBindings": false,  // If true, also rename binding variables
///   "preserveNames": []       // List of identifiers to never rename
/// }
/// ```
///
/// ## Example
///
/// ```zig
/// // Basic usage (recommended)
/// var result = try minifyAndReflectFfi(wgsl_source, null);
/// defer result.deinit();
///
/// // With options
/// var result = try minifyAndReflectFfi(wgsl_source, "{\"mangleBindings\":true}");
/// defer result.deinit();
/// ```
///
/// ## Compile-time
///
/// If `has_miniray_lib` is false, this function will not compile.
pub fn minifyAndReflectFfi(source: []const u8, options_json: ?[]const u8) Error!MinifyAndReflectResult {
    if (comptime !has_miniray_lib) {
        @compileError("miniray_ffi.minifyAndReflectFfi called but has_miniray_lib is false. " ++
            "Link libminiray.a or use subprocess fallback.");
    }

    // Pre-conditions
    std.debug.assert(source.len > 0);
    std.debug.assert(source.len <= std.math.maxInt(c_int));

    var out_code: [*c]u8 = undefined;
    var out_code_len: c_int = 0;
    var out_json: [*c]u8 = undefined;
    var out_json_len: c_int = 0;

    const result = if (options_json) |opts|
        c.miniray_minify_and_reflect(
            @ptrCast(@constCast(source.ptr)),
            @intCast(source.len),
            @ptrCast(@constCast(opts.ptr)),
            @intCast(opts.len),
            &out_code,
            &out_code_len,
            &out_json,
            &out_json_len,
        )
    else
        c.miniray_minify_and_reflect(
            @ptrCast(@constCast(source.ptr)),
            @intCast(source.len),
            null,
            0,
            &out_code,
            &out_code_len,
            &out_json,
            &out_json_len,
        );

    // Post-condition: check error codes
    return switch (result) {
        0 => MinifyAndReflectResult{
            .code = out_code[0..@intCast(out_code_len)],
            .json = out_json[0..@intCast(out_json_len)],
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

test "FFI: minifyAndReflectFfi returns minified code and reflection" {
    if (comptime !has_miniray_lib) {
        // Skip test if library not linked
        return error.SkipZigTest;
    }

    const wgsl =
        \\struct Particle { position: vec3f, velocity: vec3f }
        \\@group(0) @binding(0) var<storage, read_write> particles: array<Particle, 1000>;
        \\@compute @workgroup_size(64) fn main() {}
    ;

    var result = try minifyAndReflectFfi(wgsl, null);
    defer result.deinit();

    // Verify minified code is smaller
    try std.testing.expect(result.code.len > 0);
    try std.testing.expect(result.code.len < wgsl.len);

    // Verify JSON is valid and contains reflection fields
    try std.testing.expect(result.json.len > 0);
    try std.testing.expect(result.json[0] == '{');
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"bindings\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"entryPoints\"") != null);

    // Verify array metadata is present (new in 0.3.0)
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"elementStride\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"elementType\"") != null);
}
