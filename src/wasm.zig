//! WASM Entry Point for PNGine
//!
//! Provides exported functions for browser usage.
//! Uses global allocator since WASM has no thread-local storage.
//!
//! Exported API:
//! - onInit(): Initialize the allocator
//! - compile(src_ptr, src_len): Compile PBSF to PNGB
//! - loadModule(ptr, len): Load PNGB bytecode for execution
//! - executeAll(): Execute all bytecode
//! - getOutputPtr/Len(): Get compilation output
//! - freeOutput(): Free compilation output
//! - alloc/free(): Memory management for JS
//!
//! Invariants:
//! - onInit() must be called before any other function
//! - loadModule() must be called before executeAll()
//! - Module data must remain valid while executing

const std = @import("std");
const pngine = @import("main.zig");
const format = @import("bytecode/format.zig");
const Module = format.Module;
const WasmGPU = @import("executor/wasm_gpu.zig").WasmGPU;
const Dispatcher = @import("executor/dispatcher.zig").Dispatcher;

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

// Execution state
var gpu: WasmGPU = .empty;
var current_module: ?Module = null;
var module_data: ?[]u8 = null; // Owned copy of PNGB data

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
    gpu = .empty;
    current_module = null;
    module_data = null;
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
            // Assembler errors (10-29)
            error.UnknownForm => 10,
            error.InvalidFormStructure => 11,
            error.UndefinedResource => 12,
            error.DuplicateResource => 13,
            error.TooManyResources => 14,
            error.ExpectedAtom => 15,
            error.ExpectedString => 16,
            error.ExpectedNumber => 17,
            error.ExpectedList => 18,
            error.InvalidResourceId => 19,
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

// ============================================================================
// Execution Exports
// ============================================================================

/// Load PNGB bytecode for execution.
/// Returns: 0 on success, error code on failure.
///   1 = Not initialized
///   2 = Out of memory
///   4 = Invalid format
export fn loadModule(pngb_ptr: [*]const u8, pngb_len: usize) u32 {
    if (!initialized) return 1;

    // Free previous module if any
    freeModule();

    // Make owned copy of PNGB data (must outlive module)
    const data = allocator.alloc(u8, pngb_len) catch return 2;
    @memcpy(data, pngb_ptr[0..pngb_len]);
    module_data = data;

    // Deserialize module
    current_module = format.deserialize(allocator, data) catch |err| {
        allocator.free(data);
        module_data = null;
        return switch (err) {
            error.InvalidMagic, error.UnsupportedVersion, error.InvalidFormat, error.InvalidOffset => 4,
            error.OutOfMemory => 2,
            else => 99,
        };
    };

    // Set module reference for GPU backend
    gpu.setModule(&current_module.?);

    return 0;
}

/// Execute all bytecode in the loaded module.
/// Returns: 0 on success, error code on failure.
///   1 = Not initialized
///   5 = No module loaded
///   6 = Execution error
export fn executeAll() u32 {
    if (!initialized) return 1;

    const module = &(current_module orelse return 5);

    var dispatcher = Dispatcher(WasmGPU).init(&gpu, module);
    dispatcher.executeAll(allocator) catch return 6;

    return 0;
}

/// Free the loaded module.
export fn freeModule() void {
    if (current_module) |*module| {
        module.deinit(allocator);
        current_module = null;
    }
    if (module_data) |data| {
        allocator.free(data);
        module_data = null;
    }
    gpu = .empty;
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
