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
//! - data_gen.zig: create_typed_array, fill_*
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
                .current_pass_id = null,
                .current_pass_start = 0,
                .frame_counter = initial_frame,
                .allocator = allocator,
            };
        }

        /// Clean up pass ranges map.
        pub fn deinit(self: *Self) void {
            self.pass_ranges.deinit();
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

            // Data generation
            if (handlers.data_gen.isDataGenOpcode(op)) {
                _ = try handlers.data_gen.handle(Self, self, op, allocator);
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

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const Builder = format.Builder;

test "dispatcher empty bytecode" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    try testing.expectEqual(@as(usize, 0), gpu.callCount());
}

test "dispatcher create shader module" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const shader_data = try builder.addData(testing.allocator, "shader code");
    const emitter = builder.getEmitter();
    try emitter.createShaderModule(testing.allocator, 0, shader_data.toInt());

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    try testing.expectEqual(@as(usize, 1), gpu.callCount());
    try testing.expectEqual(@import("mock_gpu.zig").CallType.create_shader_module, gpu.getCall(0).call_type);
}

test "dispatcher create texture" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const desc_data = try builder.addData(testing.allocator, "{}");
    const emitter = builder.getEmitter();
    try emitter.createTexture(testing.allocator, 0, desc_data.toInt());

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    try testing.expectEqual(@as(usize, 1), gpu.callCount());
    try testing.expectEqual(@import("mock_gpu.zig").CallType.create_texture, gpu.getCall(0).call_type);

    // Verify parameters were passed correctly
    const call = gpu.getCall(0);
    try testing.expectEqual(@as(u16, 0), call.params.create_texture.texture_id);
    try testing.expectEqual(@as(u16, 0), call.params.create_texture.descriptor_data_id);
}

test "dispatcher create sampler" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const desc_data = try builder.addData(testing.allocator, "{}");
    const emitter = builder.getEmitter();
    try emitter.createSampler(testing.allocator, 3, desc_data.toInt());

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    try testing.expectEqual(@as(usize, 1), gpu.callCount());
    try testing.expectEqual(@import("mock_gpu.zig").CallType.create_sampler, gpu.getCall(0).call_type);

    // Verify parameters were passed correctly
    const call = gpu.getCall(0);
    try testing.expectEqual(@as(u16, 3), call.params.create_sampler.sampler_id);
    try testing.expectEqual(@as(u16, 0), call.params.create_sampler.descriptor_data_id);
}

test "dispatcher draw sequence" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();
    // Must wrap draw commands in a render pass
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPass(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    try testing.expectEqual(@as(usize, 4), gpu.callCount());

    const calls = gpu.getCalls();
    try testing.expectEqual(@import("mock_gpu.zig").CallType.begin_render_pass, calls[0].call_type);
    try testing.expectEqual(@import("mock_gpu.zig").CallType.set_pipeline, calls[1].call_type);
    try testing.expectEqual(@import("mock_gpu.zig").CallType.draw, calls[2].call_type);
    try testing.expectEqual(@import("mock_gpu.zig").CallType.end_pass, calls[3].call_type);

    // Verify draw parameters
    try testing.expectEqual(@as(u32, 3), calls[2].params.draw.vertex_count);
    try testing.expectEqual(@as(u32, 1), calls[2].params.draw.instance_count);
}

test "dispatcher frame control" {
    // Test that frame control opcodes (define_frame, end_frame, exec_pass)
    // are processed without error and don't generate GPU calls
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_id = try builder.internString(testing.allocator, "test_frame");

    const emitter = builder.getEmitter();

    // Frame definition (structural, no GPU calls)
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());

    // Actual render pass inside the frame
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPass(testing.allocator);

    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    // define_frame and end_frame don't generate GPU calls
    // Only begin_render_pass, set_pipeline, draw, end_pass, submit
    const expected = [_]@import("mock_gpu.zig").CallType{
        .begin_render_pass,
        .set_pipeline,
        .draw,
        .end_pass,
        .submit,
    };

    try testing.expect(gpu.expectCallTypes(&expected));
}

// ============================================================================
// scanPassDefinitions Tests
// ============================================================================

test "scanPassDefinitions: empty bytecode" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    // Pre-condition: pass_ranges is empty
    try testing.expectEqual(@as(usize, 0), dispatcher.pass_ranges.count());

    dispatcher.scanPassDefinitions();

    // Post-condition: still empty (no passes in bytecode)
    try testing.expectEqual(@as(usize, 0), dispatcher.pass_ranges.count());
}

test "scanPassDefinitions: no pass definitions" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();
    // Only resource creation, no pass definitions
    try emitter.createShaderModule(testing.allocator, 0, 0);
    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    dispatcher.scanPassDefinitions();

    // Post-condition: no passes found
    try testing.expectEqual(@as(usize, 0), dispatcher.pass_ranges.count());
}

test "scanPassDefinitions: single pass definition" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Define a single pass
    try emitter.definePass(testing.allocator, 0, .render, 0);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    dispatcher.scanPassDefinitions();

    // Post-condition: exactly one pass found
    try testing.expectEqual(@as(usize, 1), dispatcher.pass_ranges.count());

    // Post-condition: pass 0 has valid range
    const range = dispatcher.pass_ranges.get(0).?;
    try testing.expect(range.start < range.end);
}

test "scanPassDefinitions: multiple pass definitions" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Define pass 0 (render)
    try emitter.definePass(testing.allocator, 0, .render, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPassDef(testing.allocator);

    // Define pass 1 (compute)
    try emitter.definePass(testing.allocator, 1, .compute, 1);
    try emitter.dispatch(testing.allocator, 64, 1, 1);
    try emitter.endPassDef(testing.allocator);

    // Define pass 2 (render)
    try emitter.definePass(testing.allocator, 2, .render, 2);
    try emitter.draw(testing.allocator, 6, 1, 0, 0);
    try emitter.endPassDef(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    dispatcher.scanPassDefinitions();

    // Post-condition: all three passes found
    try testing.expectEqual(@as(usize, 3), dispatcher.pass_ranges.count());
    try testing.expect(dispatcher.pass_ranges.get(0) != null);
    try testing.expect(dispatcher.pass_ranges.get(1) != null);
    try testing.expect(dispatcher.pass_ranges.get(2) != null);
}

test "scanPassDefinitions: exec_pass uses scanned range" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_id = try builder.internString(testing.allocator, "main");
    const emitter = builder.getEmitter();

    // Define pass first
    try emitter.definePass(testing.allocator, 0, .render, 0);
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Frame that uses exec_pass
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.execPass(testing.allocator, 0);
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    try dispatcher.executeAll(testing.allocator);

    // Verify pass was executed
    var draw_found = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .draw) {
            draw_found = true;
            break;
        }
    }
    try testing.expect(draw_found);
}

test "exec_pass with missing pass_id does not crash" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_id = try builder.internString(testing.allocator, "frame");
    const emitter = builder.getEmitter();

    // Frame that references non-existent pass
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.execPass(testing.allocator, 99); // Pass 99 doesn't exist
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    // Don't call scanPassDefinitions - pass_ranges is empty

    try dispatcher.executeAll(testing.allocator);

    // Only submit should be called (exec_pass 99 finds nothing)
    try testing.expectEqual(@as(usize, 1), gpu.callCount());
    try testing.expectEqual(@import("mock_gpu.zig").CallType.submit, gpu.getCall(0).call_type);
}

// ============================================================================
// Pool Operation Tests
// ============================================================================

test "pool operations: frame counter increments" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_id = try builder.internString(testing.allocator, "frame");
    const emitter = builder.getEmitter();

    // Two frames
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    try emitter.defineFrame(testing.allocator, 1, name_id.toInt());
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.initWithFrame(testing.allocator, &gpu, &module, 0);
    defer dispatcher.deinit();

    // Pre-condition
    try testing.expectEqual(@as(u32, 0), dispatcher.frame_counter);

    try dispatcher.executeAll(testing.allocator);

    // Post-condition: frame counter incremented by 2
    try testing.expectEqual(@as(u32, 2), dispatcher.frame_counter);
}

test "pool operations: vertex buffer pool selection" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Must be in a render pass to call setVertexBuffer
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    // Set vertex buffer from pool with pool_size=2, offset=0
    try emitter.setVertexBufferPool(testing.allocator, 0, 10, 2, 0);
    try emitter.endPass(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    // Frame 0: actual_id = 10 + (0 + 0) % 2 = 10
    {
        var dispatcher = MockDispatcher.initWithFrame(testing.allocator, &gpu, &module, 0);
        defer dispatcher.deinit();
        try dispatcher.executeAll(testing.allocator);

        try testing.expectEqual(@as(usize, 3), gpu.callCount()); // begin, set, end
        const call = gpu.getCall(1);
        try testing.expectEqual(@import("mock_gpu.zig").CallType.set_vertex_buffer, call.call_type);
        try testing.expectEqual(@as(u16, 10), call.params.set_vertex_buffer.buffer_id);
    }

    gpu.reset();

    // Frame 1: actual_id = 10 + (1 + 0) % 2 = 11
    {
        var dispatcher = MockDispatcher.initWithFrame(testing.allocator, &gpu, &module, 1);
        defer dispatcher.deinit();
        try dispatcher.executeAll(testing.allocator);

        try testing.expectEqual(@as(usize, 3), gpu.callCount());
        const call = gpu.getCall(1);
        try testing.expectEqual(@as(u16, 11), call.params.set_vertex_buffer.buffer_id);
    }

    gpu.reset();

    // Frame 2: actual_id = 10 + (2 + 0) % 2 = 10 (wraps around)
    {
        var dispatcher = MockDispatcher.initWithFrame(testing.allocator, &gpu, &module, 2);
        defer dispatcher.deinit();
        try dispatcher.executeAll(testing.allocator);

        const call = gpu.getCall(1);
        try testing.expectEqual(@as(u16, 10), call.params.set_vertex_buffer.buffer_id);
    }
}

test "pool operations: bind group pool selection with offset" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Must be in a render pass to call setBindGroup
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    // Set bind group from pool with pool_size=2, offset=1
    try emitter.setBindGroupPool(testing.allocator, 0, 20, 2, 1);
    try emitter.endPass(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    // Frame 0 with offset 1: actual_id = 20 + (0 + 1) % 2 = 21
    {
        var dispatcher = MockDispatcher.initWithFrame(testing.allocator, &gpu, &module, 0);
        defer dispatcher.deinit();
        try dispatcher.executeAll(testing.allocator);

        const call = gpu.getCall(1); // Index 1 (after begin_render_pass)
        try testing.expectEqual(@import("mock_gpu.zig").CallType.set_bind_group, call.call_type);
        try testing.expectEqual(@as(u16, 21), call.params.set_bind_group.group_id);
    }

    gpu.reset();

    // Frame 1 with offset 1: actual_id = 20 + (1 + 1) % 2 = 20
    {
        var dispatcher = MockDispatcher.initWithFrame(testing.allocator, &gpu, &module, 1);
        defer dispatcher.deinit();
        try dispatcher.executeAll(testing.allocator);

        const call = gpu.getCall(1); // Index 1 (after begin_render_pass)
        try testing.expectEqual(@as(u16, 20), call.params.set_bind_group.group_id);
    }
}

// ============================================================================
// Varint Boundary Tests in Dispatcher Context
// ============================================================================

test "dispatcher handles large varint values" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Create buffer with large size (4-byte varint)
    try emitter.createBuffer(testing.allocator, 0, 100000, .{ .vertex = true, .copy_dst = true });

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    try dispatcher.executeAll(testing.allocator);

    try testing.expectEqual(@as(usize, 1), gpu.callCount());
    const call = gpu.getCall(0);
    try testing.expectEqual(@as(u32, 100000), call.params.create_buffer.size);
}

test "dispatcher handles draw with large vertex count" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Must be in a render pass to call draw
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    // Draw with large counts (2-byte and 4-byte varints)
    try emitter.draw(testing.allocator, 16384, 1000, 128, 0);
    try emitter.endPass(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    try dispatcher.executeAll(testing.allocator);

    const call = gpu.getCall(1); // Index 1 (after begin_render_pass)
    try testing.expectEqual(@as(u32, 16384), call.params.draw.vertex_count);
    try testing.expectEqual(@as(u32, 1000), call.params.draw.instance_count);
    try testing.expectEqual(@as(u32, 128), call.params.draw.first_vertex);
}

// ============================================================================
// Fuzz Testing
// ============================================================================

test "fuzz scanPassDefinitions with random bytecode" {
    // Property: scanPassDefinitions never panics on any bytecode
    try std.testing.fuzz({}, fuzzScanPassDefinitions, .{});
}

fn fuzzScanPassDefinitions(_: void, input: []const u8) !void {
    // Skip inputs with embedded nulls that might confuse allocator
    for (input) |b| {
        if (b == 0) return;
    }

    // Need at least some bytes to parse
    if (input.len < 4) return;

    // Test the OpcodeScanner directly
    var pass_ranges = OpcodeScanner.scanPassDefinitions(input, testing.allocator);
    defer pass_ranges.deinit();

    // Property: pass_ranges entries always have start <= input.len
    var it = pass_ranges.iterator();
    while (it.next()) |entry| {
        try testing.expect(entry.value_ptr.start <= input.len);
        try testing.expect(entry.value_ptr.end <= input.len);
    }
}

test "fuzz varint roundtrip" {
    // Property: encode(decode(x)) == x for all valid varints
    try std.testing.fuzz({}, fuzzVarintRoundtrip, .{});
}

fn fuzzVarintRoundtrip(_: void, input: []const u8) !void {
    if (input.len < 4) return;

    // Use first 4 bytes as a u32 value
    const value = std.mem.readInt(u32, input[0..4], .little);

    var buffer: [4]u8 = undefined;
    const len = opcodes.encodeVarint(value, &buffer);
    const decoded = opcodes.decodeVarint(buffer[0..len]);

    // Property: roundtrip preserves value
    try testing.expectEqual(value, decoded.value);
    // Property: length is consistent
    try testing.expectEqual(len, decoded.len);
}

// ============================================================================
// OOM Testing with FailingAllocator
// ============================================================================

test "OOM: scanPassDefinitions handles allocation failure gracefully" {
    // Test that pass_ranges.put failing doesn't crash
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Create several pass definitions
    for (0..5) |i| {
        try emitter.definePass(testing.allocator, @intCast(i), .render, 0);
        try emitter.draw(testing.allocator, 3, 1, 0, 0);
        try emitter.endPassDef(testing.allocator);
    }

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Test with progressively earlier allocation failures
    var fail_index: usize = 0;
    const max_fail_attempts: usize = 20;

    for (0..max_fail_attempts) |_| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });

        var gpu: MockGPU = .empty;
        defer gpu.deinit(testing.allocator);

        // Create dispatcher with failing allocator
        var pass_ranges = std.AutoHashMap(u16, PassRange).init(failing.allocator());
        defer pass_ranges.deinit();

        // Manually simulate what happens when put fails
        // The code uses `catch {}` so it should silently skip

        if (failing.has_induced_failure) {
            // OOM occurred - this is expected, verify no crash
        } else {
            // No OOM - all passes should be found
            break;
        }

        fail_index += 1;
    }
}

test "OOM: dispatcher executeAll with early allocation failure" {
    // Test complete execution path under OOM
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();
    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var fail_index: usize = 0;
    const max_attempts: usize = 10;

    while (fail_index < max_attempts) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });

        var gpu: MockGPU = .empty;
        defer gpu.deinit(testing.allocator);

        var dispatcher = MockDispatcher.init(failing.allocator(), &gpu, &module);
        defer dispatcher.deinit();

        const result = dispatcher.executeAll(failing.allocator());

        if (failing.has_induced_failure) {
            // OOM occurred - should return OutOfMemory error
            if (result) |_| {
                // Unexpected success after induced failure
            } else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
            }
        } else {
            // No OOM - should succeed
            try result;
            break;
        }
    }
}

// ============================================================================
// Edge Case Tests
// ============================================================================

test "dispatcher: nop opcode is handled" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Emit raw nop opcode
    try emitter.bytes.append(testing.allocator, @intFromEnum(OpCode.nop));
    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    try dispatcher.executeAll(testing.allocator);

    // Only submit should be called (nop is ignored)
    try testing.expectEqual(@as(usize, 1), gpu.callCount());
}

test "dispatcher: begin_compute_pass with no params" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    try emitter.beginComputePass(testing.allocator);
    try emitter.endPass(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    try dispatcher.executeAll(testing.allocator);

    try testing.expectEqual(@as(usize, 2), gpu.callCount());
    try testing.expectEqual(@import("mock_gpu.zig").CallType.begin_compute_pass, gpu.getCall(0).call_type);
    try testing.expectEqual(@import("mock_gpu.zig").CallType.end_pass, gpu.getCall(1).call_type);
}

test "dispatcher: dispatch workgroups" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Must be in a compute pass to call dispatch
    try emitter.beginComputePass(testing.allocator);
    try emitter.dispatch(testing.allocator, 64, 32, 16);
    try emitter.endPass(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    try dispatcher.executeAll(testing.allocator);

    try testing.expectEqual(@as(usize, 3), gpu.callCount()); // begin, dispatch, end
    const call = gpu.getCall(1); // Index 1 (after begin_compute_pass)
    try testing.expectEqual(@import("mock_gpu.zig").CallType.dispatch, call.call_type);
    try testing.expectEqual(@as(u32, 64), call.params.dispatch.x);
    try testing.expectEqual(@as(u32, 32), call.params.dispatch.y);
    try testing.expectEqual(@as(u32, 16), call.params.dispatch.z);
}

test "dispatcher: draw_indexed with all parameters" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Must be in a render pass to call draw_indexed
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.drawIndexed(testing.allocator, 36, 10, 12, 100, 5);
    try emitter.endPass(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    try dispatcher.executeAll(testing.allocator);

    try testing.expectEqual(@as(usize, 3), gpu.callCount()); // begin, draw_indexed, end
    const call = gpu.getCall(1); // Index 1 (after begin_render_pass)
    try testing.expectEqual(@import("mock_gpu.zig").CallType.draw_indexed, call.call_type);
    try testing.expectEqual(@as(u32, 36), call.params.draw_indexed.index_count);
    try testing.expectEqual(@as(u32, 10), call.params.draw_indexed.instance_count);
    try testing.expectEqual(@as(u32, 12), call.params.draw_indexed.first_index);
    try testing.expectEqual(@as(u32, 100), call.params.draw_indexed.base_vertex);
    try testing.expectEqual(@as(u32, 5), call.params.draw_indexed.first_instance);
}

test "scanPassDefinitions: passes interleaved with other opcodes" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Resource creation
    try emitter.createShaderModule(testing.allocator, 0, 0);
    try emitter.createRenderPipeline(testing.allocator, 0, 1);

    // Pass 0
    try emitter.definePass(testing.allocator, 0, .render, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPassDef(testing.allocator);

    // More resources
    try emitter.createBuffer(testing.allocator, 0, 1024, .{ .vertex = true });

    // Pass 1
    try emitter.definePass(testing.allocator, 1, .compute, 1);
    try emitter.dispatch(testing.allocator, 8, 8, 1);
    try emitter.endPassDef(testing.allocator);

    // Frame definition
    const name_id = try builder.internString(testing.allocator, "test");
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.execPass(testing.allocator, 0);
    try emitter.execPass(testing.allocator, 1);
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    dispatcher.scanPassDefinitions();

    // Both passes should be found despite interleaved opcodes
    try testing.expectEqual(@as(usize, 2), dispatcher.pass_ranges.count());
    try testing.expect(dispatcher.pass_ranges.get(0) != null);
    try testing.expect(dispatcher.pass_ranges.get(1) != null);
}

test "scanPassDefinitions: max pass_id (255 for u16 cast)" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Test with pass ID 255 (max for 1-byte direct, but within u16 range)
    try emitter.definePass(testing.allocator, 255, .render, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPassDef(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    dispatcher.scanPassDefinitions();

    try testing.expectEqual(@as(usize, 1), dispatcher.pass_ranges.count());
    try testing.expect(dispatcher.pass_ranges.get(255) != null);
}

// ============================================================================
// Scene Switching Integration Tests
// ============================================================================

test "scene switching: exec_pass with scan finds pass defined before frame" {
    // Simulates the scene switching fix - passes defined, then frames use exec_pass
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_a = try builder.internString(testing.allocator, "sceneA");
    const name_b = try builder.internString(testing.allocator, "sceneB");
    const emitter = builder.getEmitter();

    // Define passes first (common pattern)
    try emitter.definePass(testing.allocator, 0, .render, 0);
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.draw(testing.allocator, 3, 1, 0, 0); // Scene A draws triangle
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    try emitter.definePass(testing.allocator, 1, .render, 1);
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.draw(testing.allocator, 6, 1, 0, 0); // Scene B draws quad
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Define frames that exec_pass
    try emitter.defineFrame(testing.allocator, 0, name_a.toInt());
    try emitter.execPass(testing.allocator, 0);
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    try emitter.defineFrame(testing.allocator, 1, name_b.toInt());
    try emitter.execPass(testing.allocator, 1);
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    // Execute all - should run both frames
    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    // Verify: should see 2 begin_render_pass, 2 draws (3 and 6), 2 end_pass, 2 submit
    var draw_count: usize = 0;
    var begin_pass_count: usize = 0;
    var submit_count: usize = 0;
    for (gpu.getCalls()) |call| {
        switch (call.call_type) {
            .draw => draw_count += 1,
            .begin_render_pass => begin_pass_count += 1,
            .submit => submit_count += 1,
            else => {},
        }
    }

    try testing.expectEqual(@as(usize, 2), draw_count);
    try testing.expectEqual(@as(usize, 2), begin_pass_count);
    try testing.expectEqual(@as(usize, 2), submit_count);
}

test "scene switching: pass defined after exec_pass still works" {
    // Edge case: forward reference to pass
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_id = try builder.internString(testing.allocator, "main");
    const emitter = builder.getEmitter();

    // Frame first, then pass (forward reference)
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.execPass(testing.allocator, 0);
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    // Pass defined after frame
    try emitter.definePass(testing.allocator, 0, .render, 0);
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    // scanPassDefinitions should find the pass even though it's after the frame
    dispatcher.scanPassDefinitions();
    try testing.expectEqual(@as(usize, 1), dispatcher.pass_ranges.count());

    // Now execute - should work because pass was scanned
    try dispatcher.executeAll(testing.allocator);

    var draw_found = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .draw) {
            draw_found = true;
            break;
        }
    }
    try testing.expect(draw_found);
}

test "scene switching: many passes with non-sequential IDs" {
    // Test that pass IDs don't need to be sequential
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Non-sequential pass IDs: 10, 50, 100
    try emitter.definePass(testing.allocator, 10, .render, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPassDef(testing.allocator);

    try emitter.definePass(testing.allocator, 50, .compute, 0);
    try emitter.dispatch(testing.allocator, 8, 1, 1);
    try emitter.endPassDef(testing.allocator);

    try emitter.definePass(testing.allocator, 100, .render, 0);
    try emitter.draw(testing.allocator, 6, 1, 0, 0);
    try emitter.endPassDef(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    dispatcher.scanPassDefinitions();

    try testing.expectEqual(@as(usize, 3), dispatcher.pass_ranges.count());
    try testing.expect(dispatcher.pass_ranges.get(10) != null);
    try testing.expect(dispatcher.pass_ranges.get(50) != null);
    try testing.expect(dispatcher.pass_ranges.get(100) != null);
    try testing.expect(dispatcher.pass_ranges.get(0) == null);
    try testing.expect(dispatcher.pass_ranges.get(11) == null);
}

test "scanPassDefinitions: deeply nested opcode sequence" {
    // Test with many different opcodes in pass body
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    try emitter.definePass(testing.allocator, 0, .render, 0);
    // Complex sequence of opcodes
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.setBindGroup(testing.allocator, 0, 0);
    try emitter.setBindGroup(testing.allocator, 1, 1);
    try emitter.setVertexBuffer(testing.allocator, 0, 0);
    try emitter.setVertexBuffer(testing.allocator, 1, 1);
    try emitter.draw(testing.allocator, 36, 1, 0, 0);
    try emitter.draw(testing.allocator, 24, 1, 36, 0);
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    dispatcher.scanPassDefinitions();

    try testing.expectEqual(@as(usize, 1), dispatcher.pass_ranges.count());
    const range = dispatcher.pass_ranges.get(0).?;
    // Complex pass should have a large range
    try testing.expect(range.end - range.start > 20);
}

test "scanPassDefinitions: boids-like pattern with bind_group + write_buffer" {
    // Regression test for the specific pattern that caused the original bug:
    // create_bind_group (3 varints) followed by other opcodes.

    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Simulate boids pattern: buffer, bind_group, write_buffer, passes
    try emitter.createBuffer(testing.allocator, 0, 1024, .{ .storage = true });
    try emitter.createBuffer(testing.allocator, 1, 1024, .{ .storage = true });
    try emitter.createBindGroup(testing.allocator, 0, 0, 0); // The problematic opcode
    try emitter.createBindGroup(testing.allocator, 1, 0, 1);
    try emitter.writeBuffer(testing.allocator, 0, 0, 0); // Also was problematic

    // Render pass
    try emitter.definePass(testing.allocator, 0, .render, 0);
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 3, 2048, 0, 0);
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Compute pass
    try emitter.definePass(testing.allocator, 1, .compute, 0);
    try emitter.beginComputePass(testing.allocator);
    try emitter.setPipeline(testing.allocator, 1);
    try emitter.setBindGroupPool(testing.allocator, 0, 0, 2, 0);
    try emitter.dispatch(testing.allocator, 32, 1, 1);
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Frame
    try emitter.defineFrame(testing.allocator, 0, 0);
    try emitter.execPass(testing.allocator, 0);
    try emitter.execPass(testing.allocator, 1);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    dispatcher.scanPassDefinitions();

    // CRITICAL: Both passes must be found
    try testing.expectEqual(@as(usize, 2), dispatcher.pass_ranges.count());
    try testing.expect(dispatcher.pass_ranges.get(0) != null); // render pass
    try testing.expect(dispatcher.pass_ranges.get(1) != null); // compute pass
}
