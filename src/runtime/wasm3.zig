//! wasm3 WebAssembly Interpreter Wrapper
//!
//! Provides a Zig-friendly interface to the wasm3 C library for executing
//! WASM modules natively. Used by the validate command for command buffer
//! inspection without a browser.
//!
//! ## Usage
//! ```zig
//! var runtime = try Wasm3Runtime.init(allocator, 64 * 1024); // 64KB stack
//! defer runtime.deinit();
//!
//! try runtime.loadModule(wasm_bytes);
//! try runtime.linkHostFunction("env", "gpuCreateBuffer", gpuCreateBuffer);
//! const result = try runtime.call("init", .{});
//! ```
//!
//! ## Invariants
//! - Module must be valid WASM binary
//! - Host functions must be linked before calling WASM functions
//! - Stack size must be sufficient for WASM execution

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

// Import wasm3 C headers
const c = if (build_options.has_wasm3) @cImport({
    @cInclude("wasm3.h");
    @cInclude("m3_env.h");
}) else struct {};

/// Error types for wasm3 operations.
pub const Wasm3Error = error{
    InitFailed,
    ParseFailed,
    LoadFailed,
    LinkFailed,
    CallFailed,
    NotAvailable,
    OutOfMemory,
};

/// wasm3 runtime instance.
pub const Wasm3Runtime = struct {
    env: if (build_options.has_wasm3) c.IM3Environment else void,
    runtime: if (build_options.has_wasm3) c.IM3Runtime else void,
    module: if (build_options.has_wasm3) ?c.IM3Module else void,
    allocator: std.mem.Allocator,

    /// Initialize a new wasm3 runtime.
    ///
    /// Pre-condition: stack_size > 0
    /// Post-condition: Runtime is ready for module loading
    pub fn init(allocator: std.mem.Allocator, stack_size: u32) Wasm3Error!Wasm3Runtime {
        if (!build_options.has_wasm3) {
            return Wasm3Error.NotAvailable;
        }

        std.debug.assert(stack_size > 0);

        const env = c.m3_NewEnvironment() orelse return Wasm3Error.InitFailed;
        errdefer c.m3_FreeEnvironment(env);

        const runtime = c.m3_NewRuntime(env, stack_size, null) orelse return Wasm3Error.InitFailed;

        return .{
            .env = env,
            .runtime = runtime,
            .module = null,
            .allocator = allocator,
        };
    }

    /// Clean up wasm3 runtime resources.
    pub fn deinit(self: *Wasm3Runtime) void {
        if (!build_options.has_wasm3) return;

        if (self.runtime) |rt| {
            c.m3_FreeRuntime(rt);
        }
        if (self.env) |env| {
            c.m3_FreeEnvironment(env);
        }
        self.* = undefined;
    }

    /// Load a WASM module from bytes.
    ///
    /// Pre-condition: wasm_bytes is valid WASM binary
    /// Post-condition: Module is loaded and ready for linking
    pub fn loadModule(self: *Wasm3Runtime, wasm_bytes: []const u8) Wasm3Error!void {
        if (!build_options.has_wasm3) {
            return Wasm3Error.NotAvailable;
        }

        std.debug.assert(wasm_bytes.len >= 8); // Minimum WASM header

        var module: c.IM3Module = undefined;
        const parse_result = c.m3_ParseModule(
            self.env,
            &module,
            wasm_bytes.ptr,
            @intCast(wasm_bytes.len),
        );
        if (parse_result != null) {
            return Wasm3Error.ParseFailed;
        }

        const load_result = c.m3_LoadModule(self.runtime, module);
        if (load_result != null) {
            return Wasm3Error.LoadFailed;
        }

        self.module = module;
    }

    /// Check if wasm3 is available at compile time.
    pub fn isAvailable() bool {
        return build_options.has_wasm3;
    }

    /// Get wasm3 version string.
    pub fn version() []const u8 {
        if (!build_options.has_wasm3) {
            return "not available";
        }
        return std.mem.span(c.M3_VERSION);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Wasm3Runtime: availability check" {
    // This test verifies the compile-time availability flag
    const available = Wasm3Runtime.isAvailable();
    if (available) {
        std.debug.print("wasm3 is available, version: {s}\n", .{Wasm3Runtime.version()});
    } else {
        std.debug.print("wasm3 is not available\n", .{});
    }
}

test "Wasm3Runtime: init and deinit" {
    if (!Wasm3Runtime.isAvailable()) {
        return; // Skip if wasm3 not available
    }

    var runtime = try Wasm3Runtime.init(std.testing.allocator, 64 * 1024);
    defer runtime.deinit();
}
