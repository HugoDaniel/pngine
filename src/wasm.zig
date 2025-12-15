//! WASM Entry Point for PNGine
//!
//! Provides exported functions for browser usage.
//! Uses global allocator since WASM has no thread-local storage.
//!
//! Exported API:
//! - onInit(): Initialize the allocator
//! - compile(src_ptr, src_len, out_ptr): Compile PBSF to PNGB
//! - getOutputLen(): Get length of last compilation output
//! - free(ptr, len): Free allocated memory

const std = @import("std");
const pngine = @import("main.zig");

// ============================================================================
// Global State (WASM has no TLS)
// ============================================================================

var gpa: std.heap.GeneralPurposeAllocator(.{
    // Disable safety checks for smaller binary
    .safety = false,
    .never_unmap = true,
}) = undefined;
var allocator: std.mem.Allocator = undefined;
var initialized: bool = false;

// Last compilation result
var last_output: ?[]u8 = null;
var last_error: u32 = 0;

// ============================================================================
// Exported Functions
// ============================================================================

/// Initialize the WASM module. Must be called before any other function.
export fn onInit() void {
    gpa = .{};
    allocator = gpa.allocator();
    initialized = true;
    last_output = null;
    last_error = 0;
}

/// Compile PBSF source to PNGB bytecode.
/// Returns: 0 on success, error code on failure.
/// Use getOutputPtr() and getOutputLen() to retrieve the result.
export fn compile(src_ptr: [*]const u8, src_len: usize) u32 {
    if (!initialized) return 1; // Not initialized

    // Free previous output
    if (last_output) |output| {
        allocator.free(output);
        last_output = null;
    }

    // Create sentinel-terminated copy for parser
    const source_z = allocator.allocSentinel(u8, src_len, 0) catch return 2;
    defer allocator.free(source_z[0 .. src_len + 1]);
    @memcpy(source_z[0..src_len], src_ptr[0..src_len]);

    // Compile
    const result = pngine.compile(allocator, source_z) catch |err| {
        last_error = switch (err) {
            error.ParseError => 3,
            error.OutOfMemory => 2,
            else => 99,
        };
        return last_error;
    };

    last_output = result;
    last_error = 0;
    return 0;
}

/// Get pointer to last compilation output.
export fn getOutputPtr() ?[*]const u8 {
    if (last_output) |output| {
        return output.ptr;
    }
    return null;
}

/// Get length of last compilation output.
export fn getOutputLen() usize {
    if (last_output) |output| {
        return output.len;
    }
    return 0;
}

/// Free the last compilation output.
export fn freeOutput() void {
    if (last_output) |output| {
        allocator.free(output);
        last_output = null;
    }
}

/// Allocate memory (for JS to pass data).
export fn alloc(len: usize) ?[*]u8 {
    if (!initialized) return null;
    const slice = allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

/// Free allocated memory.
export fn free(ptr: [*]u8, len: usize) void {
    if (!initialized) return;
    allocator.free(ptr[0..len]);
}

// ============================================================================
// Memory exports for C interop (if needed)
// ============================================================================

export fn memcpy(dest: ?[*]u8, src: ?[*]const u8, n: usize) ?[*]u8 {
    if (dest == null or src == null) return dest;
    @memcpy(dest.?[0..n], src.?[0..n]);
    return dest;
}

export fn memset(dest: ?[*]u8, c: c_int, n: usize) ?[*]u8 {
    if (dest == null) return dest;
    const byte: u8 = @truncate(@as(c_uint, @bitCast(c)));
    @memset(dest.?[0..n], byte);
    return dest;
}
