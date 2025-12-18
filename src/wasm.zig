//! WASM Entry Point for PNGine
//!
//! Provides exported functions for browser usage.
//! Uses global allocator since WASM has no thread-local storage.
//!
//! ## Exported API
//!
//! - `onInit()`: Initialize the allocator
//! - `compile(src_ptr, src_len)`: Compile PBSF to PNGB
//! - `loadModule(ptr, len)`: Load PNGB bytecode for execution
//! - `executeAll()`: Execute all bytecode
//! - `getOutputPtr/Len()`: Get compilation output
//! - `freeOutput()`: Free compilation output
//! - `alloc/free()`: Memory management for JS
//!
//! ## Error Codes
//!
//! All exported functions returning u32 use these codes:
//! - 0: Success
//! - 1: Not initialized (onInit not called)
//! - 2: Out of memory
//! - 3: Parse error
//! - 4: Invalid format
//! - 5: No module loaded
//! - 6: Execution error
//! - 10-19: Assembler errors (see ErrorCode enum)
//! - 99: Unknown error
//!
//! ## Invariants
//!
//! - onInit() must be called before any other function
//! - loadModule() must be called before executeAll()
//! - Module data must remain valid while executing

const std = @import("std");
const assert = std.debug.assert;
const pngine = @import("main.zig");
const format = @import("bytecode/format.zig");
const Module = format.Module;
const WasmGPU = @import("executor/wasm_gpu.zig").WasmGPU;
const Dispatcher = @import("executor/dispatcher.zig").Dispatcher;

// ============================================================================
// Error Codes
// ============================================================================

/// Error codes returned by exported functions.
/// These map to the error codes documented in the module header.
pub const ErrorCode = enum(u32) {
    success = 0,
    not_initialized = 1,
    out_of_memory = 2,
    parse_error = 3,
    invalid_format = 4,
    no_module_loaded = 5,
    execution_error = 6,
    // Assembler errors (10-19)
    unknown_form = 10,
    invalid_form_structure = 11,
    undefined_resource = 12,
    duplicate_resource = 13,
    too_many_resources = 14,
    expected_atom = 15,
    expected_string = 16,
    expected_number = 17,
    expected_list = 18,
    invalid_resource_id = 19,
    // Catch-all
    unknown = 99,

    pub fn toU32(self: ErrorCode) u32 {
        return @intFromEnum(self);
    }
};

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
var frame_counter: u32 = 0; // Persists across executeAll calls for ping-pong

// ============================================================================
// Exported Functions
// ============================================================================

/// Initialize the WASM module. Must be called before any other function.
///
/// Post-condition: initialized == true, allocator is valid.
export fn onInit() void {
    gpa = .{};
    allocator = gpa.allocator();
    initialized = true;
    last_output = null;
    last_error = 0;
    gpu = .empty;
    current_module = null;
    module_data = null;
    frame_counter = 0;

    // Post-condition: runtime is ready
    assert(initialized);
}

/// Compile PBSF source to PNGB bytecode.
/// Returns: ErrorCode.success on success, error code on failure.
/// Use getOutputPtr() and getOutputLen() to retrieve the result.
export fn compile(src_ptr: [*]const u8, src_len: usize) u32 {
    if (!initialized) return ErrorCode.not_initialized.toU32();

    // Free previous output
    if (last_output) |output| {
        allocator.free(output);
        last_output = null;
    }

    // Create sentinel-terminated copy for parser
    const source_z = allocator.allocSentinel(u8, src_len, 0) catch return ErrorCode.out_of_memory.toU32();
    defer allocator.free(source_z[0 .. src_len + 1]);
    @memcpy(source_z[0..src_len], src_ptr[0..src_len]);

    // Compile
    const result = pngine.compile(allocator, source_z) catch |err| {
        last_error = @intFromEnum(switch (err) {
            error.ParseError => ErrorCode.parse_error,
            error.OutOfMemory => ErrorCode.out_of_memory,
            // Assembler errors
            error.UnknownForm => ErrorCode.unknown_form,
            error.InvalidFormStructure => ErrorCode.invalid_form_structure,
            error.UndefinedResource => ErrorCode.undefined_resource,
            error.DuplicateResource => ErrorCode.duplicate_resource,
            error.TooManyResources => ErrorCode.too_many_resources,
            error.ExpectedAtom => ErrorCode.expected_atom,
            error.ExpectedString => ErrorCode.expected_string,
            error.ExpectedNumber => ErrorCode.expected_number,
            error.ExpectedList => ErrorCode.expected_list,
            error.InvalidResourceId => ErrorCode.invalid_resource_id,
            else => ErrorCode.unknown,
        });
        return last_error;
    };

    last_output = result;
    last_error = 0;
    return ErrorCode.success.toU32();
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
/// Returns: ErrorCode.success on success, error code on failure.
///
/// Pre-condition: onInit() has been called.
/// Post-condition: On success, current_module is valid and frame_counter == 0.
export fn loadModule(pngb_ptr: [*]const u8, pngb_len: usize) u32 {
    // Pre-condition check
    if (!initialized) return ErrorCode.not_initialized.toU32();
    assert(pngb_len > 0);

    // Free previous module if any
    freeModule();

    // Reset frame counter for new module
    frame_counter = 0;

    // Make owned copy of PNGB data (must outlive module)
    const data = allocator.alloc(u8, pngb_len) catch return ErrorCode.out_of_memory.toU32();
    @memcpy(data, pngb_ptr[0..pngb_len]);
    module_data = data;

    // Deserialize module
    current_module = format.deserialize(allocator, data) catch |err| {
        allocator.free(data);
        module_data = null;
        return @intFromEnum(switch (err) {
            error.InvalidMagic, error.UnsupportedVersion, error.InvalidFormat, error.InvalidOffset => ErrorCode.invalid_format,
            error.OutOfMemory => ErrorCode.out_of_memory,
            else => ErrorCode.unknown,
        });
    };

    // Set module reference for GPU backend
    gpu.setModule(&current_module.?);

    // Post-condition: module loaded successfully
    assert(current_module != null);
    assert(frame_counter == 0);

    return ErrorCode.success.toU32();
}

/// Get the current frame counter (for debugging).
export fn getFrameCounter() u32 {
    return frame_counter;
}

/// Execute all bytecode in the loaded module.
/// Returns: ErrorCode.success on success, error code on failure.
///
/// Pre-condition: onInit() and loadModule() have been called.
/// Post-condition: frame_counter is incremented by number of end_frame opcodes.
export fn executeAll() u32 {
    // Pre-condition checks
    if (!initialized) return ErrorCode.not_initialized.toU32();
    const module = &(current_module orelse return ErrorCode.no_module_loaded.toU32());

    const frame_before = frame_counter;

    // Use persistent frame counter for ping-pong buffer patterns
    var dispatcher = Dispatcher(WasmGPU).initWithFrame(allocator, &gpu, module, frame_counter);
    dispatcher.executeAll(allocator) catch return ErrorCode.execution_error.toU32();

    // Update global frame counter for next call
    frame_counter = dispatcher.frame_counter;

    // Post-condition: frame counter can only increase (never decreases)
    assert(frame_counter >= frame_before);

    return ErrorCode.success.toU32();
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
