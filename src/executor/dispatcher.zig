//! Bytecode Dispatcher
//!
//! Decodes PNGB bytecode and dispatches operations to GPU backend.
//! Uses a pluggable backend interface for testability.
//!
//! ## Design
//!
//! - **Generic backend**: Any type with required GPU methods works (MockGPU, WasmGPU)
//! - **Two-phase execution**: Pass definitions are recorded, then executed via exec_pass
//! - **Ping-pong support**: frame_counter enables double-buffering via pool operations
//! - **Bounded execution**: All loops have explicit max iterations (10000 for main, 1000 for passes)
//! - **Plugin-aware**: Commands are grouped by plugin (core/render/compute/texture/wasm)
//! - **Modular handlers**: Each opcode category is handled by a separate module in dispatcher/
//!
//! ## Architecture
//!
//! ```
//! PNGB Bytecode → Dispatcher.step() → Handler.handle() → Backend.method() → GPU calls
//!                     ↓
//!              pass_ranges map (for deferred exec_pass)
//! ```
//!
//! ## Handler Modules
//!
//! - resource.zig: create_buffer, create_texture, create_pipeline, etc.
//! - pass.zig: begin_render_pass, draw, dispatch, end_pass
//! - queue.zig: write_buffer, submit
//! - frame.zig: define_frame, exec_pass, define_pass
//! - pool.zig: set_*_pool operations
//! - wasm_ops.zig: init_wasm_module, call_wasm_func
//! - scanner.zig: OpcodeScanner for pass definition discovery
//!
//! ## Invariants
//!
//! - Bytecode is validated before execution (pc never exceeds bytecode.len)
//! - All resource IDs reference previously created resources
//! - Execution is deterministic (no randomness in dispatch)
//! - Pass definitions must end with end_pass_def before being executed
//! - frame_counter increments exactly once per end_frame opcode

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

// Use bytecode module import (named bytecode_mod to avoid conflict with local vars)
const bytecode_mod = @import("bytecode");
const opcodes = bytecode_mod.opcodes;
const OpCode = opcodes.OpCode;
const format = bytecode_mod.format;
const Module = format.Module;

const MockGPU = @import("mock_gpu.zig").MockGPU;

// Handler modules
const handlers = @import("dispatcher/handlers.zig");
const OpcodeScanner = handlers.OpcodeScanner;
const PassRange = handlers.PassRange;

/// Execution error types.
pub const ExecuteError = error{
    InvalidOpcode,
    UnexpectedEndOfBytecode,
    InvalidResourceId,
    PassNotEnded,
    NotInPass,
    OutOfMemory,
    /// Command requires a plugin that is not enabled.
    PluginDisabled,
    /// Module not set on backend.
    ModuleNotSet,
    /// Surface texture unavailable for rendering.
    SurfaceTextureUnavailable,
    /// No surface configured for presentation.
    NoSurfaceConfigured,
    /// Texture not found in resource table.
    TextureNotFound,
    /// Shader compilation failed.
    ShaderCompilationFailed,
    /// Pipeline creation failed.
    PipelineCreationFailed,
};

/// GPU backend interface.
/// Any type implementing these methods can be used.
pub fn Backend(comptime T: type) type {
    return struct {
        /// Verify the backend type has required methods.
        pub fn validate() void {
            comptime {
                // Resource creation
                _ = @field(T, "createBuffer");
                _ = @field(T, "createTexture");
                _ = @field(T, "createSampler");
                _ = @field(T, "createShaderModule");
                _ = @field(T, "createRenderPipeline");
                _ = @field(T, "createComputePipeline");
                _ = @field(T, "createBindGroup");

                // Pass operations
                _ = @field(T, "beginRenderPass");
                _ = @field(T, "beginComputePass");
                _ = @field(T, "setPipeline");
                _ = @field(T, "setBindGroup");
                _ = @field(T, "setVertexBuffer");
                _ = @field(T, "draw");
                _ = @field(T, "drawIndexed");
                _ = @field(T, "dispatch");
                _ = @field(T, "endPass");

                // Queue operations
                _ = @field(T, "writeBuffer");
                _ = @field(T, "submit");
            }
        }
    };
}

/// Maximum number of passes to track.
const MAX_PASSES: u16 = 256;

/// Bytecode dispatcher.
pub fn Dispatcher(comptime BackendType: type) type {
    // Validate backend at comptime
    Backend(BackendType).validate();

    return struct {
        const Self = @This();

        /// GPU backend to dispatch calls to.
        backend: *BackendType,

        /// Module being executed.
        module: *const Module,

        /// Current bytecode position.
        pc: usize,

        /// Execution state.
        in_pass_def: bool,
        in_frame_def: bool,

        /// Pass bytecode ranges for exec_pass.
        pass_ranges: std.AutoHashMap(u16, PassRange),

        /// Passes executed via exec_pass_once (run-once tracking).
        executed_once: std.AutoHashMap(u16, void),

        /// Current pass ID being defined (for tracking range).
        current_pass_id: ?u16,

        /// Start position of current pass definition.
        current_pass_start: usize,

        /// Frame counter for ping-pong pool calculations.
        frame_counter: u32,

        /// Allocator for internal data structures (pass_ranges map).
        allocator: Allocator,

        /// Initialize dispatcher with default frame counter.
        ///
        /// Complexity: O(1)
        /// Memory: Allocates hashmap for pass ranges (grows on demand).
        pub fn init(allocator: Allocator, backend: *BackendType, module: *const Module) Self {
            return initWithFrame(allocator, backend, module, 0);
        }

        /// Initialize with a specific frame counter (for animation loops).
        ///
        /// The frame_counter enables ping-pong buffer patterns where:
        /// actual_id = base_id + (frame_counter + offset) % pool_size
        ///
        /// Complexity: O(1)
        pub fn initWithFrame(allocator: Allocator, backend: *BackendType, module: *const Module, initial_frame: u32) Self {
            // Pre-conditions
            assert(module.bytecode.len <= 1024 * 1024); // 1MB max bytecode

            return .{
                .backend = backend,
                .module = module,
                .pc = 0,
                .in_pass_def = false,
                .in_frame_def = false,
                .pass_ranges = std.AutoHashMap(u16, PassRange).init(allocator),
                .executed_once = std.AutoHashMap(u16, void).init(allocator),
                .current_pass_id = null,
                .current_pass_start = 0,
                .frame_counter = initial_frame,
                .allocator = allocator,
            };
        }

        /// Clean up dispatcher state.
        pub fn deinit(self: *Self) void {
            self.pass_ranges.deinit();
            self.executed_once.deinit();
        }

        /// Scan bytecode for pass definitions and populate pass_ranges.
        /// This is needed before executing a single frame, since exec_pass
        /// opcodes within the frame need to reference pass ranges.
        ///
        /// Complexity: O(bytecode.len)
        pub fn scanPassDefinitions(self: *Self) void {
            // Pre-condition: module bytecode is valid
            assert(self.module.bytecode.len <= 1024 * 1024);

            // Delegate to OpcodeScanner
            var scanned = OpcodeScanner.scanPassDefinitions(self.module.bytecode, self.allocator);

            // Merge scanned ranges into our map
            var it = scanned.iterator();
            while (it.next()) |entry| {
                self.pass_ranges.put(entry.key_ptr.*, entry.value_ptr.*) catch {};
            }
            scanned.deinit();

            // Post-condition: pass_ranges may have entries (or empty if no passes)
        }

        /// Skip opcode parameters at a given position (for scanning without executing).
        /// Made public for use by CLI frame scanning and tests.
        pub fn skipOpcodeParamsAt(bytecode: []const u8, pc: *usize, op: OpCode) void {
            var scanner = OpcodeScanner.init(bytecode, pc.*);
            scanner.skipParams(op);
            pc.* = scanner.pc;
        }

        /// Execute all bytecode.
        pub fn executeAll(self: *Self, allocator: Allocator) ExecuteError!void {
            // Pre-condition: start at beginning
            assert(self.pc == 0);

            try self.executeFromPC(allocator);

            // Post-condition: consumed all bytecode
            assert(self.pc == self.module.bytecode.len);
        }

        /// Execute bytecode from current PC to end.
        /// Use this when starting from a non-zero position (e.g., skipping resource creation).
        pub fn executeFromPC(self: *Self, allocator: Allocator) ExecuteError!void {
            // Pre-condition: pc within bounds or at end
            assert(self.pc <= self.module.bytecode.len);

            const bytecode = self.module.bytecode;
            const max_iterations: usize = 10000; // Safety bound

            for (0..max_iterations) |_| {
                if (self.pc >= bytecode.len) break;
                try self.step(allocator);
            } else {
                // Hit max iterations - likely infinite loop
                unreachable;
            }

            // Post-condition: consumed all bytecode
            assert(self.pc == bytecode.len);
        }

        /// Execute single instruction.
        ///
        /// Dispatches to appropriate handler module based on opcode category.
        /// Each handler is <70 lines, keeping this function small.
        pub fn step(self: *Self, allocator: Allocator) ExecuteError!void {
            const bytecode = self.module.bytecode;

            // Pre-condition: valid PC
            if (self.pc >= bytecode.len) return error.UnexpectedEndOfBytecode;

            const op: OpCode = @enumFromInt(bytecode[self.pc]);
            self.pc += 1;

            // Try each handler in priority order
            // Resource creation
            if (handlers.resource.isResourceOpcode(op)) {
                _ = try handlers.resource.handle(Self, self, op, allocator);
                return;
            }

            // Pass operations
            if (handlers.pass.isPassOpcode(op)) {
                _ = try handlers.pass.handle(Self, self, op, allocator);
                return;
            }

            // Queue operations
            if (handlers.queue.isQueueOpcode(op)) {
                _ = try handlers.queue.handle(Self, self, op, allocator);
                return;
            }

            // Frame control
            if (handlers.frame.isFrameOpcode(op)) {
                _ = try handlers.frame.handle(Self, self, op, allocator);
                return;
            }

            // Pool operations
            if (handlers.pool.isPoolOpcode(op)) {
                _ = try handlers.pool.handle(Self, self, op, allocator);
                return;
            }

            // WASM operations
            if (handlers.wasm_ops.isWasmOpcode(op)) {
                _ = try handlers.wasm_ops.handle(Self, self, op, allocator);
                return;
            }

            // Special cases
            switch (op) {
                .nop => {},

                // Unimplemented opcodes
                .create_shader_concat,
                .write_uniform,
                .copy_buffer_to_buffer,
                .copy_texture_to_texture,
                .select_from_pool,
                => return error.InvalidOpcode,

                else => return error.InvalidOpcode,
            }
        }

        // ====================================================================
        // Bytecode Reading
        // ====================================================================

        pub fn readByte(self: *Self) ExecuteError!u8 {
            const bytecode = self.module.bytecode;
            if (self.pc >= bytecode.len) return error.UnexpectedEndOfBytecode;

            const byte = bytecode[self.pc];
            self.pc += 1;
            return byte;
        }

        pub fn readVarint(self: *Self) ExecuteError!u32 {
            const bytecode = self.module.bytecode;
            if (self.pc >= bytecode.len) return error.UnexpectedEndOfBytecode;

            const result = opcodes.decodeVarint(bytecode[self.pc..]);
            self.pc += result.len;
            return result.value;
        }
    };
}

/// Convenience type alias for MockGPU dispatcher.
pub const MockDispatcher = Dispatcher(MockGPU);

// Tests are in dispatcher/test.zig
test {
    _ = @import("dispatcher/test.zig");
}
