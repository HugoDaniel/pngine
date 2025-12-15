//! Bytecode Dispatcher
//!
//! Decodes PNGB bytecode and dispatches operations to GPU backend.
//! Uses a pluggable backend interface for testability.
//!
//! Invariants:
//! - Bytecode is validated before execution
//! - All resource IDs reference previously created resources
//! - Execution is deterministic (no randomness in dispatch)

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const opcodes = @import("../bytecode/opcodes.zig");
const OpCode = opcodes.OpCode;
const format = @import("../bytecode/format.zig");
const Module = format.Module;
const MockGPU = @import("mock_gpu.zig").MockGPU;

/// Execution error types.
pub const ExecuteError = error{
    InvalidOpcode,
    UnexpectedEndOfBytecode,
    InvalidResourceId,
    PassNotEnded,
    NotInPass,
    OutOfMemory,
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

        pub fn init(backend: *BackendType, module: *const Module) Self {
            return .{
                .backend = backend,
                .module = module,
                .pc = 0,
                .in_pass_def = false,
                .in_frame_def = false,
            };
        }

        /// Execute all bytecode.
        pub fn executeAll(self: *Self, allocator: Allocator) ExecuteError!void {
            // Pre-condition: start at beginning
            assert(self.pc == 0);

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
        pub fn step(self: *Self, allocator: Allocator) ExecuteError!void {
            const bytecode = self.module.bytecode;

            // Pre-condition: valid PC
            if (self.pc >= bytecode.len) return error.UnexpectedEndOfBytecode;

            const op: OpCode = @enumFromInt(bytecode[self.pc]);
            self.pc += 1;

            switch (op) {
                // ============================================================
                // Resource Creation
                // ============================================================

                .create_buffer => {
                    const buffer_id = try self.readVarint();
                    const size = try self.readVarint();
                    const usage = try self.readByte();
                    try self.backend.createBuffer(allocator, @intCast(buffer_id), size, usage);
                },

                .create_shader_module => {
                    const shader_id = try self.readVarint();
                    const code_data_id = try self.readVarint();
                    try self.backend.createShaderModule(allocator, @intCast(shader_id), @intCast(code_data_id));
                },

                .create_render_pipeline => {
                    const pipeline_id = try self.readVarint();
                    const descriptor_data_id = try self.readVarint();
                    try self.backend.createRenderPipeline(allocator, @intCast(pipeline_id), @intCast(descriptor_data_id));
                },

                .create_compute_pipeline => {
                    const pipeline_id = try self.readVarint();
                    const descriptor_data_id = try self.readVarint();
                    try self.backend.createComputePipeline(allocator, @intCast(pipeline_id), @intCast(descriptor_data_id));
                },

                .create_bind_group => {
                    const group_id = try self.readVarint();
                    const layout_id = try self.readVarint();
                    const entry_data_id = try self.readVarint();
                    try self.backend.createBindGroup(allocator, @intCast(group_id), @intCast(layout_id), @intCast(entry_data_id));
                },

                // ============================================================
                // Pass Operations
                // ============================================================

                .begin_render_pass => {
                    const color_texture_id = try self.readVarint();
                    const load_op = try self.readByte();
                    const store_op = try self.readByte();
                    try self.backend.beginRenderPass(allocator, @intCast(color_texture_id), load_op, store_op);
                },

                .begin_compute_pass => {
                    try self.backend.beginComputePass(allocator);
                },

                .set_pipeline => {
                    const pipeline_id = try self.readVarint();
                    try self.backend.setPipeline(allocator, @intCast(pipeline_id));
                },

                .set_bind_group => {
                    const slot = try self.readByte();
                    const group_id = try self.readVarint();
                    try self.backend.setBindGroup(allocator, slot, @intCast(group_id));
                },

                .set_vertex_buffer => {
                    const slot = try self.readByte();
                    const buffer_id = try self.readVarint();
                    try self.backend.setVertexBuffer(allocator, slot, @intCast(buffer_id));
                },

                .draw => {
                    const vertex_count = try self.readVarint();
                    const instance_count = try self.readVarint();
                    try self.backend.draw(allocator, vertex_count, instance_count);
                },

                .draw_indexed => {
                    const index_count = try self.readVarint();
                    const instance_count = try self.readVarint();
                    try self.backend.drawIndexed(allocator, index_count, instance_count);
                },

                .dispatch => {
                    const x = try self.readVarint();
                    const y = try self.readVarint();
                    const z = try self.readVarint();
                    try self.backend.dispatch(allocator, x, y, z);
                },

                .end_pass => {
                    try self.backend.endPass(allocator);
                },

                // ============================================================
                // Queue Operations
                // ============================================================

                .write_buffer => {
                    const buffer_id = try self.readVarint();
                    const offset = try self.readVarint();
                    const data_id = try self.readVarint();
                    try self.backend.writeBuffer(allocator, @intCast(buffer_id), offset, @intCast(data_id));
                },

                .submit => {
                    try self.backend.submit(allocator);
                },

                // ============================================================
                // Frame Control (structural, no GPU calls)
                // ============================================================

                .define_frame => {
                    _ = try self.readVarint(); // frame_id
                    _ = try self.readVarint(); // name_string_id
                    self.in_frame_def = true;
                },

                .end_frame => {
                    self.in_frame_def = false;
                },

                .exec_pass => {
                    _ = try self.readVarint(); // pass_id
                    // In a real executor, this would look up and execute the pass
                },

                .define_pass => {
                    _ = try self.readVarint(); // pass_id
                    _ = try self.readByte(); // pass_type
                    _ = try self.readVarint(); // descriptor_data_id
                    self.in_pass_def = true;
                },

                .end_pass_def => {
                    self.in_pass_def = false;
                },

                // ============================================================
                // Data Generation (to be implemented)
                // ============================================================

                .create_typed_array,
                .fill_constant,
                .fill_random,
                .fill_linear,
                .fill_element_index,
                .fill_expression,
                => {
                    // Skip data generation for now
                    // These will be implemented when we add runtime data generation
                    return error.InvalidOpcode;
                },

                // ============================================================
                // Unimplemented / Reserved
                // ============================================================

                .nop => {
                    // No operation
                },

                .create_texture,
                .create_sampler,
                .create_shader_concat,
                .create_bind_group_layout,
                .create_pipeline_layout,
                .set_index_buffer,
                .write_uniform,
                .copy_buffer_to_buffer,
                .copy_texture_to_texture,
                .select_from_pool,
                => {
                    // Not yet implemented
                    return error.InvalidOpcode;
                },

                _ => {
                    return error.InvalidOpcode;
                },
            }
        }

        // ====================================================================
        // Bytecode Reading
        // ====================================================================

        fn readByte(self: *Self) ExecuteError!u8 {
            const bytecode = self.module.bytecode;
            if (self.pc >= bytecode.len) return error.UnexpectedEndOfBytecode;

            const byte = bytecode[self.pc];
            self.pc += 1;
            return byte;
        }

        fn readVarint(self: *Self) ExecuteError!u32 {
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

    var dispatcher = MockDispatcher.init(&gpu, &module);
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

    var dispatcher = MockDispatcher.init(&gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    try testing.expectEqual(@as(usize, 1), gpu.callCount());
    try testing.expectEqual(@import("mock_gpu.zig").CallType.create_shader_module, gpu.getCall(0).call_type);
}

test "dispatcher draw sequence" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 3, 1);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(&gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    try testing.expectEqual(@as(usize, 2), gpu.callCount());

    const calls = gpu.getCalls();
    try testing.expectEqual(@import("mock_gpu.zig").CallType.set_pipeline, calls[0].call_type);
    try testing.expectEqual(@import("mock_gpu.zig").CallType.draw, calls[1].call_type);

    // Verify draw parameters
    try testing.expectEqual(@as(u32, 3), calls[1].params.draw.vertex_count);
    try testing.expectEqual(@as(u32, 1), calls[1].params.draw.instance_count);
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
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 3, 1);
    try emitter.endPass(testing.allocator);

    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(&gpu, &module);
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
