//! WAMR WebAssembly Runtime Wrapper
//!
//! Provides a Zig-friendly interface to the WAMR C library for executing
//! WASM modules natively. Supports both interpreter and AOT execution modes.
//! Used by the validate command for command buffer inspection without a browser.
//!
//! ## Usage
//! ```zig
//! var runtime = try WamrRuntime.init(allocator, 64 * 1024, 64 * 1024);
//! defer runtime.deinit();
//!
//! try runtime.loadModule(wasm_bytes);
//! const result = try runtime.callInit();
//! ```
//!
//! ## Invariants
//! - Module must be valid WASM binary or AOT file
//! - Stack/heap sizes must be > 0
//! - Runtime must be initialized before loading modules

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

// Import WAMR C headers when available
const c = if (build_options.has_wamr) @cImport({
    @cInclude("wasm_export.h");
}) else struct {
    // Stub types for when WAMR is not available
    pub const wasm_module_t = ?*anyopaque;
    pub const wasm_module_inst_t = ?*anyopaque;
    pub const wasm_exec_env_t = ?*anyopaque;
    pub const wasm_function_inst_t = ?*anyopaque;
};

/// Error types for WAMR operations.
pub const WamrError = error{
    InitFailed,
    ParseFailed,
    LoadFailed,
    InstantiateFailed,
    FunctionNotFound,
    CallFailed,
    MemoryAccessFailed,
    NotAvailable,
    OutOfMemory,
};

/// WAMR runtime instance.
pub const WamrRuntime = struct {
    module: c.wasm_module_t,
    instance: c.wasm_module_inst_t,
    exec_env: c.wasm_exec_env_t,
    allocator: std.mem.Allocator,
    wasm_buffer: ?[]u8, // Owned copy of WASM bytes (WAMR requires writable buffer)

    /// Initialize a new WAMR runtime.
    ///
    /// Pre-condition: stack_size > 0, heap_size > 0
    /// Post-condition: Runtime is ready for module loading
    pub fn init(allocator: std.mem.Allocator, stack_size: u32, heap_size: u32) WamrError!WamrRuntime {
        if (!build_options.has_wamr) {
            return WamrError.NotAvailable;
        }

        std.debug.assert(stack_size > 0);
        std.debug.assert(heap_size > 0);

        // Initialize WAMR runtime with system allocator to ensure proper alignment
        // (system malloc on macOS guarantees 16-byte alignment)
        var init_args: c.RuntimeInitArgs = std.mem.zeroes(c.RuntimeInitArgs);
        init_args.mem_alloc_type = c.Alloc_With_System_Allocator;

        // Register native "env" module with log function
        init_args.native_module_name = "env";
        init_args.native_symbols = &native_symbols;
        init_args.n_native_symbols = native_symbols.len;

        if (!c.wasm_runtime_full_init(&init_args)) {
            return WamrError.InitFailed;
        }

        return .{
            .module = null,
            .instance = null,
            .exec_env = null,
            .allocator = allocator,
            .wasm_buffer = null,
        };
    }

    // Native function implementations for WASM imports

    /// Global flag to control verbose WASM log output.
    /// Set via setVerbose() before calling WASM functions.
    var verbose_logging: bool = false;

    /// Enable or disable verbose WASM log output.
    pub fn setVerbose(verbose: bool) void {
        verbose_logging = verbose;
    }

    /// Native log function that prints to stderr (called from WASM).
    /// Uses "(ii)" signature - WAMR passes raw WASM i32 values.
    /// We manually convert WASM linear memory address to native pointer.
    /// Only prints when verbose_logging is enabled.
    fn nativeLog(exec_env: c.wasm_exec_env_t, wasm_ptr: u32, len: u32) callconv(.c) void {
        if (!verbose_logging) return;
        if (len == 0 or len > 4096) return;

        // Get the module instance to convert WASM address to native
        const module_inst = c.wasm_runtime_get_module_inst(exec_env);
        if (module_inst == null) return;

        // Validate address bounds before converting
        if (!c.wasm_runtime_validate_app_addr(module_inst, wasm_ptr, len)) return;

        const native_ptr: ?[*]const u8 = @ptrCast(c.wasm_runtime_addr_app_to_native(module_inst, wasm_ptr));
        if (native_ptr) |p| {
            std.debug.print("[WASM] {s}\n", .{p[0..len]});
        }
    }

    // Static native symbols array (must have static lifetime for WAMR)
    var native_symbols = [_]c.NativeSymbol{
        .{
            .symbol = "log",
            .func_ptr = @constCast(@ptrCast(&nativeLog)),
            .signature = "(ii)", // Two i32 params, manual address conversion
            .attachment = null,
        },
    };

    /// Clean up WAMR runtime resources.
    pub fn deinit(self: *WamrRuntime) void {
        if (!build_options.has_wamr) return;

        if (self.exec_env != null) {
            c.wasm_runtime_destroy_exec_env(self.exec_env);
        }
        if (self.instance != null) {
            c.wasm_runtime_deinstantiate(self.instance);
        }
        if (self.module != null) {
            c.wasm_runtime_unload(self.module);
        }
        if (self.wasm_buffer) |buf| {
            self.allocator.free(buf);
        }
        c.wasm_runtime_destroy();
        self.* = undefined;
    }

    /// Load a WASM module from bytes.
    ///
    /// Pre-condition: wasm_bytes is valid WASM binary
    /// Post-condition: Module is loaded and instantiated
    pub fn loadModule(self: *WamrRuntime, wasm_bytes: []const u8) WamrError!void {
        return self.loadModuleWithStackHeap(wasm_bytes, 64 * 1024, 64 * 1024);
    }

    /// Load a WASM module with custom stack/heap sizes.
    pub fn loadModuleWithStackHeap(self: *WamrRuntime, wasm_bytes: []const u8, stack_size: u32, heap_size: u32) WamrError!void {
        if (!build_options.has_wamr) {
            return WamrError.NotAvailable;
        }

        std.debug.assert(wasm_bytes.len >= 8); // Minimum WASM header

        // WAMR requires writable buffer. For AOT files, we need page-aligned memory
        // to allow proper memory mapping of native code sections.
        const is_aot = wasm_bytes.len >= 4 and std.mem.eql(u8, wasm_bytes[0..4], &.{ 0x00, 'a', 'o', 't' });
        const buffer = if (is_aot)
            // AOT files need page alignment for native code
            self.allocator.alignedAlloc(u8, .fromByteUnits(4096), wasm_bytes.len) catch return WamrError.OutOfMemory
        else
            self.allocator.dupe(u8, wasm_bytes) catch return WamrError.OutOfMemory;
        @memcpy(buffer, wasm_bytes);
        self.wasm_buffer = buffer;

        // Load the module
        var error_buf: [128]u8 = undefined;
        self.module = c.wasm_runtime_load(
            buffer.ptr,
            @intCast(buffer.len),
            &error_buf,
            error_buf.len,
        );
        if (self.module == null) {
            std.debug.print("WAMR load error: {s}\n", .{std.mem.sliceTo(&error_buf, 0)});
            // Free the buffer on failure to prevent memory leak
            if (is_aot) {
                self.allocator.free(@as([]align(4096) u8, @alignCast(buffer)));
            } else {
                self.allocator.free(buffer);
            }
            self.wasm_buffer = null;
            return WamrError.LoadFailed;
        }

        // Instantiate the module
        self.instance = c.wasm_runtime_instantiate(
            self.module,
            stack_size,
            heap_size,
            &error_buf,
            error_buf.len,
        );
        if (self.instance == null) {
            std.debug.print("WAMR instantiate error: {s}\n", .{std.mem.sliceTo(&error_buf, 0)});
            return WamrError.InstantiateFailed;
        }

        // Create execution environment
        self.exec_env = c.wasm_runtime_create_exec_env(self.instance, stack_size);
        if (self.exec_env == null) {
            return WamrError.InitFailed;
        }
    }

    /// Link a void function that takes (ptr, len) for logging.
    /// The executor imports: extern "env" fn log(ptr: [*]const u8, len: u32) void;
    pub fn linkLogFunction(self: *WamrRuntime) WamrError!void {
        if (!build_options.has_wamr) {
            return WamrError.NotAvailable;
        }

        // WAMR doesn't require explicit linking for missing imports - they become no-ops
        _ = self;
    }

    /// Find and call an exported function with no arguments, returning u32.
    pub fn callInit(self: *WamrRuntime) WamrError!u32 {
        if (!build_options.has_wamr) {
            return WamrError.NotAvailable;
        }

        const func = c.wasm_runtime_lookup_function(self.instance, "init");
        if (func == null) {
            return WamrError.FunctionNotFound;
        }

        var argv: [1]u32 = .{0}; // Return value placeholder
        if (!c.wasm_runtime_call_wasm(self.exec_env, func, 0, &argv)) {
            const err = c.wasm_runtime_get_exception(self.instance);
            if (err != null) {
                std.debug.print("WAMR call error: {s}\n", .{std.mem.sliceTo(err.?, 0)});
            }
            return WamrError.CallFailed;
        }

        return argv[0];
    }

    /// Call the frame(time, width, height) function.
    pub fn callFrame(self: *WamrRuntime, time: f32, width: u32, height: u32) WamrError!u32 {
        if (!build_options.has_wamr) {
            return WamrError.NotAvailable;
        }

        const func = c.wasm_runtime_lookup_function(self.instance, "frame");
        if (func == null) {
            return WamrError.FunctionNotFound;
        }

        // Pack arguments: time (as u32 bits), width, height, and space for return value
        var argv: [4]u32 = .{
            @bitCast(time),
            width,
            height,
            0, // Return value placeholder
        };

        if (!c.wasm_runtime_call_wasm(self.exec_env, func, 3, &argv)) {
            const err = c.wasm_runtime_get_exception(self.instance);
            if (err != null) {
                std.debug.print("WAMR frame error: {s}\n", .{std.mem.sliceTo(err.?, 0)});
            }
            return WamrError.CallFailed;
        }

        return argv[0]; // Return value is in argv[0] after call
    }

    /// Call a function that returns a pointer (u32).
    pub fn callGetPtr(self: *WamrRuntime, name: [*:0]const u8) WamrError!u32 {
        if (!build_options.has_wamr) {
            return WamrError.NotAvailable;
        }

        const func = c.wasm_runtime_lookup_function(self.instance, name);
        if (func == null) {
            return WamrError.FunctionNotFound;
        }

        var argv: [1]u32 = .{0};
        if (!c.wasm_runtime_call_wasm(self.exec_env, func, 0, &argv)) {
            return WamrError.CallFailed;
        }

        return argv[0];
    }

    /// Call setBytecodeLen or setDataLen.
    pub fn callSetLen(self: *WamrRuntime, name: [*:0]const u8, len: u32) WamrError!void {
        if (!build_options.has_wamr) {
            return WamrError.NotAvailable;
        }

        const func = c.wasm_runtime_lookup_function(self.instance, name);
        if (func == null) {
            return WamrError.FunctionNotFound;
        }

        var argv: [1]u32 = .{len};
        if (!c.wasm_runtime_call_wasm(self.exec_env, func, 1, &argv)) {
            return WamrError.CallFailed;
        }
    }

    /// Get WASM linear memory.
    pub fn getMemory(self: *WamrRuntime) WamrError![]u8 {
        if (!build_options.has_wamr) {
            return WamrError.NotAvailable;
        }

        // Get the default memory instance
        const mem_inst = c.wasm_runtime_get_default_memory(self.instance);
        if (mem_inst == null) {
            return WamrError.MemoryAccessFailed;
        }

        // Get base address and size
        const base_ptr = c.wasm_memory_get_base_address(mem_inst);
        if (base_ptr == null) {
            return WamrError.MemoryAccessFailed;
        }

        // Calculate size from page count
        const page_count = c.wasm_memory_get_cur_page_count(mem_inst);
        const bytes_per_page = c.wasm_memory_get_bytes_per_page(mem_inst);
        const size = page_count * bytes_per_page;

        return @as([*]u8, @ptrCast(base_ptr))[0..@intCast(size)];
    }

    /// Write data to WASM memory at a given offset.
    pub fn writeMemory(self: *WamrRuntime, offset: u32, data: []const u8) WamrError!void {
        const mem = try self.getMemory();
        if (offset + data.len > mem.len) {
            return WamrError.MemoryAccessFailed;
        }
        @memcpy(mem[offset..][0..data.len], data);
    }

    /// Read data from WASM memory at a given offset.
    pub fn readMemory(self: *WamrRuntime, offset: u32, len: u32) WamrError![]const u8 {
        const mem = try self.getMemory();
        if (offset + len > mem.len) {
            return WamrError.MemoryAccessFailed;
        }
        return mem[offset..][0..len];
    }

    /// Check if WAMR is available at compile time.
    pub fn isAvailable() bool {
        return build_options.has_wamr;
    }

    /// Get WAMR version string.
    pub fn version() []const u8 {
        if (!build_options.has_wamr) {
            return "not available";
        }
        // WAMR doesn't expose version in the same way, return a static string
        return "WAMR 2.2.0";
    }
};

// ============================================================================
// Tests
// ============================================================================

test "WamrRuntime: availability check" {
    const available = WamrRuntime.isAvailable();
    if (available) {
        std.debug.print("WAMR is available, version: {s}\n", .{WamrRuntime.version()});
    } else {
        std.debug.print("WAMR is not available\n", .{});
    }
}

test "WamrRuntime: init and deinit" {
    if (!WamrRuntime.isAvailable()) {
        return; // Skip if WAMR not available
    }

    var runtime = try WamrRuntime.init(std.testing.allocator, 64 * 1024, 64 * 1024);
    defer runtime.deinit();
}
