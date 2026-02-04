//! WASM Plugin (WASM-in-WASM)
//!
//! Handles nested WASM module execution for CPU-side computation.
//! Only included when `#wasmCall` or `#data wasm={...}` is used.
//!
//! ## Commands Handled
//!
//! - INIT_WASM_MODULE
//! - CALL_WASM_FUNC
//! - WRITE_BUFFER_FROM_WASM
//!
//! ## Use Cases
//!
//! - Physics engines (Rapier, Box2D compiled to WASM)
//! - Complex math (FFT, matrix decomposition)
//! - Deterministic simulation (WASM is deterministic, GPU compute isn't)
//! - Existing WASM libraries
//!
//! ## Memory Model
//!
//! The nested WASM module gets its own linear memory:
//! - Inputs: Copied from executor memory
//! - Outputs: Copied back to specified buffer region
//!
//! ## Invariants
//!
//! - Module must be initialized before calling functions
//! - Function names must be valid null-terminated strings
//! - Output buffer must have sufficient space

const std = @import("std");
const assert = std.debug.assert;

const CommandBuffer = @import("../command_buffer.zig").CommandBuffer;
const Cmd = @import("../command_buffer.zig").Cmd;

/// Maximum number of WASM modules per payload.
pub const MAX_WASM_MODULES: usize = 16;

/// Maximum WASM output size.
pub const MAX_WASM_OUTPUT: usize = 1024 * 1024; // 1MB

/// WASM plugin state.
pub const WasmPlugin = struct {
    const Self = @This();

    /// Command buffer to write to.
    cmd_buffer: *CommandBuffer,

    /// Track initialized modules (for validation).
    initialized_modules: u16,

    /// Initialize WASM plugin with command buffer.
    pub fn init(cmd_buffer: *CommandBuffer) Self {
        // Pre-condition: command buffer initialized
        assert(cmd_buffer.buffer.len >= 8);

        return .{
            .cmd_buffer = cmd_buffer,
            .initialized_modules = 0,
        };
    }

    // ========================================================================
    // Module Management
    // ========================================================================

    /// Initialize a WASM module from embedded bytes.
    ///
    /// Args:
    ///   module_id: Module identifier
    ///   wasm_ptr: Pointer to WASM bytes in memory
    ///   wasm_len: WASM module size
    pub fn initWasmModule(self: *Self, module_id: u16, wasm_ptr: u32, wasm_len: u32) void {
        // Pre-conditions
        assert(module_id < MAX_WASM_MODULES);
        assert(wasm_len > 8); // Minimum valid WASM

        self.cmd_buffer.initWasmModule(module_id, wasm_ptr, wasm_len);
        self.initialized_modules |= @as(u16, 1) << @intCast(module_id);
    }

    /// Call a function in an initialized WASM module.
    ///
    /// Args:
    ///   call_id: Unique call identifier (for result retrieval)
    ///   module_id: Target module ID
    ///   func_name_ptr: Pointer to function name string
    ///   func_name_len: Function name length
    ///   args: Serialized arguments (copied inline into command buffer)
    pub fn callWasmFunc(
        self: *Self,
        call_id: u16,
        module_id: u16,
        func_name_ptr: u32,
        func_name_len: u32,
        args: []const u8,
    ) void {
        // Pre-conditions
        assert(module_id < MAX_WASM_MODULES);
        assert(func_name_len > 0);

        self.cmd_buffer.callWasmFunc(call_id, module_id, func_name_ptr, func_name_len, args);
    }

    /// Write WASM call result to a GPU buffer.
    ///
    /// Args:
    ///   buffer_id: Target GPU buffer ID
    ///   buffer_offset: Offset into buffer
    ///   wasm_ptr: Pointer in WASM memory
    ///   size: Bytes to copy
    pub fn writeBufferFromWasm(
        self: *Self,
        buffer_id: u16,
        buffer_offset: u32,
        wasm_ptr: u32,
        size: u32,
    ) void {
        // Pre-conditions
        assert(size > 0);
        assert(size <= MAX_WASM_OUTPUT);

        self.cmd_buffer.writeBufferFromWasm(buffer_id, buffer_offset, wasm_ptr, size);
    }

    /// Check if a module is initialized.
    pub fn is_module_initialized(self: *const Self, module_id: u16) bool {
        if (module_id >= MAX_WASM_MODULES) return false;
        return (self.initialized_modules & (@as(u16, 1) << @intCast(module_id))) != 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "WasmPlugin: init module" {
    var buffer: [1024]u8 = undefined;
    var cmd_buffer = CommandBuffer.init(&buffer);
    var wasm_plugin = WasmPlugin.init(&cmd_buffer);

    try testing.expect(!wasm_plugin.is_module_initialized(0));

    wasm_plugin.initWasmModule(0, 0x1000, 256);

    try testing.expect(wasm_plugin.is_module_initialized(0));
    try testing.expect(!wasm_plugin.is_module_initialized(1));

    const result = cmd_buffer.finish();
    try testing.expect(result.len > 8);
    try testing.expectEqual(@intFromEnum(Cmd.init_wasm_module), result[8]);
}

test "WasmPlugin: call function" {
    var buffer: [1024]u8 = undefined;
    var cmd_buffer = CommandBuffer.init(&buffer);
    var wasm_plugin = WasmPlugin.init(&cmd_buffer);

    // Args: [count=3][canvas_width][canvas_height][time_total]
    const args = [_]u8{ 3, 0x01, 0x02, 0x03 };
    wasm_plugin.callWasmFunc(0, 0, 0x2000, 8, &args);

    const result = cmd_buffer.finish();
    try testing.expect(result.len > 8);
    try testing.expectEqual(@intFromEnum(Cmd.call_wasm_func), result[8]);
}

test "WasmPlugin: write buffer from wasm" {
    var buffer: [1024]u8 = undefined;
    var cmd_buffer = CommandBuffer.init(&buffer);
    var wasm_plugin = WasmPlugin.init(&cmd_buffer);

    wasm_plugin.writeBufferFromWasm(1, 0, 0x4000, 128);

    const result = cmd_buffer.finish();
    try testing.expect(result.len > 8);
    try testing.expectEqual(@intFromEnum(Cmd.write_buffer_from_wasm), result[8]);
}

test "WasmPlugin: full workflow" {
    var buffer: [1024]u8 = undefined;
    var cmd_buffer = CommandBuffer.init(&buffer);
    var wasm_plugin = WasmPlugin.init(&cmd_buffer);

    // 1. Initialize module
    wasm_plugin.initWasmModule(0, 0x1000, 1024);

    // 2. Call function with inline args
    // Args: [count=3][canvas_width][canvas_height][time_total]
    const args = [_]u8{ 3, 0x01, 0x02, 0x03 };
    wasm_plugin.callWasmFunc(0, 0, 0x2000, 8, &args);

    // 3. Copy result to GPU buffer
    wasm_plugin.writeBufferFromWasm(1, 0, 0x4000, 64);

    const result = cmd_buffer.finish();
    // Should have 3 commands
    const cmd_count = std.mem.readInt(u16, result[4..6], .little);
    try testing.expectEqual(@as(u16, 3), cmd_count);
}
