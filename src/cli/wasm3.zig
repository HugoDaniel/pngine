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
//! try runtime.linkFunction("env", "log", logFn);
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

// Import wasm3 C headers when available
const c = if (build_options.has_wasm3) @cImport({
    // Set compiler detection for wasm3 to use builtin bswap
    // This avoids the #include <endian.h> fallback on macOS
    @cDefine("M3_COMPILER_GCC", "1");
    @cDefine("__GNUC__", "14");
    @cDefine("__GNUC_MINOR__", "0");
    @cInclude("wasm3.h");
    @cInclude("m3_env.h");
}) else struct {
    // Stub types for when wasm3 is not available
    pub const IM3Environment = *anyopaque;
    pub const IM3Runtime = *anyopaque;
    pub const IM3Module = *anyopaque;
    pub const IM3Function = *anyopaque;
    pub const M3Result = ?[*:0]const u8;
};

/// Error types for wasm3 operations.
pub const Wasm3Error = error{
    InitFailed,
    ParseFailed,
    LoadFailed,
    LinkFailed,
    CompileFailed,
    FunctionNotFound,
    CallFailed,
    MemoryAccessFailed,
    NotAvailable,
    OutOfMemory,
};

/// wasm3 runtime instance.
pub const Wasm3Runtime = struct {
    env: c.IM3Environment,
    runtime: c.IM3Runtime,
    module: ?c.IM3Module,
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

        c.m3_FreeRuntime(self.runtime);
        c.m3_FreeEnvironment(self.env);
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

    /// Link a host function to the WASM module.
    /// The function signature is automatically derived from the Zig function type.
    pub fn linkFunction(
        self: *Wasm3Runtime,
        module_name: [*:0]const u8,
        function_name: [*:0]const u8,
        comptime func: anytype,
    ) Wasm3Error!void {
        if (!build_options.has_wasm3) {
            return Wasm3Error.NotAvailable;
        }

        const module = self.module orelse return Wasm3Error.LoadFailed;

        // Generate wasm3 signature from Zig function type
        const signature = comptime wasm3Signature(@TypeOf(func));

        const result = c.m3_LinkRawFunction(
            module,
            module_name,
            function_name,
            signature,
            @ptrCast(&wasm3Wrapper(func)),
        );

        // Ignore "function not found" errors - the module might not import it
        if (result != null and !std.mem.eql(u8, std.mem.span(result.?), "function lookup failed")) {
            return Wasm3Error.LinkFailed;
        }
    }

    /// Link a void function that takes (ptr, len) for logging.
    pub fn linkLogFunction(self: *Wasm3Runtime) Wasm3Error!void {
        return self.linkFunction("env", "log", logStub);
    }

    /// Compile all functions in the module.
    pub fn compile(self: *Wasm3Runtime) Wasm3Error!void {
        if (!build_options.has_wasm3) {
            return Wasm3Error.NotAvailable;
        }

        const module = self.module orelse return Wasm3Error.LoadFailed;
        const result = c.m3_CompileModule(module);
        if (result != null) {
            return Wasm3Error.CompileFailed;
        }
    }

    /// Find and call an exported function with no arguments, returning u32.
    pub fn callInit(self: *Wasm3Runtime) Wasm3Error!u32 {
        if (!build_options.has_wasm3) {
            return Wasm3Error.NotAvailable;
        }

        var func: c.IM3Function = undefined;
        const find_result = c.m3_FindFunction(&func, self.runtime, "init");
        if (find_result != null) {
            return Wasm3Error.FunctionNotFound;
        }

        var result: u32 = 0;
        const call_result = c.m3_Call(func, 0, null);
        if (call_result != null) {
            return Wasm3Error.CallFailed;
        }

        // Get return value
        var ret_ptrs = [_]?*const anyopaque{@ptrCast(&result)};
        _ = c.m3_GetResults(func, 1, &ret_ptrs);

        return result;
    }

    /// Call the frame(time, width, height) function.
    pub fn callFrame(self: *Wasm3Runtime, time: f32, width: u32, height: u32) Wasm3Error!u32 {
        if (!build_options.has_wasm3) {
            return Wasm3Error.NotAvailable;
        }

        var func: c.IM3Function = undefined;
        const find_result = c.m3_FindFunction(&func, self.runtime, "frame");
        if (find_result != null) {
            return Wasm3Error.FunctionNotFound;
        }

        // Pack arguments
        const time_bits: u32 = @bitCast(time);
        const args = [_]?*const anyopaque{
            @ptrCast(&time_bits),
            @ptrCast(&width),
            @ptrCast(&height),
        };

        var result: u32 = 0;
        const call_result = c.m3_Call(func, 3, @constCast(&args));
        if (call_result != null) {
            return Wasm3Error.CallFailed;
        }

        // Get return value
        var ret_ptrs = [_]?*const anyopaque{@ptrCast(&result)};
        _ = c.m3_GetResults(func, 1, &ret_ptrs);

        return result;
    }

    /// Call a function that returns a pointer (u32).
    pub fn callGetPtr(self: *Wasm3Runtime, name: [*:0]const u8) Wasm3Error!u32 {
        if (!build_options.has_wasm3) {
            return Wasm3Error.NotAvailable;
        }

        var func: c.IM3Function = undefined;
        const find_result = c.m3_FindFunction(&func, self.runtime, name);
        if (find_result != null) {
            return Wasm3Error.FunctionNotFound;
        }

        var result: u32 = 0;
        const call_result = c.m3_Call(func, 0, null);
        if (call_result != null) {
            return Wasm3Error.CallFailed;
        }

        var ret_ptrs = [_]?*const anyopaque{@ptrCast(&result)};
        _ = c.m3_GetResults(func, 1, &ret_ptrs);

        return result;
    }

    /// Call setBytecodeLen or setDataLen.
    pub fn callSetLen(self: *Wasm3Runtime, name: [*:0]const u8, len: u32) Wasm3Error!void {
        if (!build_options.has_wasm3) {
            return Wasm3Error.NotAvailable;
        }

        var func: c.IM3Function = undefined;
        const find_result = c.m3_FindFunction(&func, self.runtime, name);
        if (find_result != null) {
            return Wasm3Error.FunctionNotFound;
        }

        const args = [_]?*const anyopaque{@ptrCast(&len)};
        const call_result = c.m3_Call(func, 1, @constCast(&args));
        if (call_result != null) {
            return Wasm3Error.CallFailed;
        }
    }

    /// Get WASM linear memory.
    pub fn getMemory(self: *Wasm3Runtime) Wasm3Error![]u8 {
        if (!build_options.has_wasm3) {
            return Wasm3Error.NotAvailable;
        }

        var size: u32 = 0;
        const mem = c.m3_GetMemory(self.runtime, &size, 0);
        if (mem == null) {
            return Wasm3Error.MemoryAccessFailed;
        }

        return mem[0..size];
    }

    /// Write data to WASM memory at a given offset.
    pub fn writeMemory(self: *Wasm3Runtime, offset: u32, data: []const u8) Wasm3Error!void {
        const mem = try self.getMemory();
        if (offset + data.len > mem.len) {
            return Wasm3Error.MemoryAccessFailed;
        }
        @memcpy(mem[offset..][0..data.len], data);
    }

    /// Read data from WASM memory at a given offset.
    pub fn readMemory(self: *Wasm3Runtime, offset: u32, len: u32) Wasm3Error![]const u8 {
        const mem = try self.getMemory();
        if (offset + len > mem.len) {
            return Wasm3Error.MemoryAccessFailed;
        }
        return mem[offset..][0..len];
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

/// Stub log function for WASM imports.
fn logStub(_: c.IM3Runtime, _: c.IM3ImportContext, _: [*]u64, _: ?*anyopaque) callconv(.c) ?*anyopaque {
    // Silent stub - we could capture logs here if needed
    return null;
}

/// Generate wasm3 signature string from Zig function type.
fn wasm3Signature(comptime T: type) [*:0]const u8 {
    const info = @typeInfo(T).@"fn";
    comptime var sig: []const u8 = "v(";
    inline for (info.params) |param| {
        sig = sig ++ switch (param.type.?) {
            u32, i32 => "i",
            u64, i64 => "I",
            f32 => "f",
            f64 => "F",
            else => "i", // Default to i32
        };
    }
    sig = sig ++ ")";
    return sig[0..sig.len :0];
}

/// Create a wasm3 wrapper for a Zig function.
fn wasm3Wrapper(comptime func: anytype) fn (c.IM3Runtime, c.IM3ImportContext, [*]u64, ?*anyopaque) callconv(.c) ?*anyopaque {
    return struct {
        fn wrapper(_: c.IM3Runtime, _: c.IM3ImportContext, _: [*]u64, _: ?*anyopaque) callconv(.c) ?*anyopaque {
            // For now, just ignore the call - we can expand this later
            _ = func;
            return null;
        }
    }.wrapper;
}

// ============================================================================
// Tests
// ============================================================================

test "Wasm3Runtime: availability check" {
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
