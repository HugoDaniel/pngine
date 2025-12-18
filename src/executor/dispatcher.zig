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
//!
//! ## Architecture
//!
//! ```
//! PNGB Bytecode → Dispatcher.step() → Backend.method() → GPU/Mock calls
//!                     ↓
//!              pass_ranges map (for deferred exec_pass)
//! ```
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

/// Pass bytecode range (start and end offsets within bytecode).
const PassRange = struct {
    start: usize,
    end: usize,
};

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

                .create_texture => {
                    const texture_id = try self.readVarint();
                    const descriptor_data_id = try self.readVarint();
                    try self.backend.createTexture(allocator, @intCast(texture_id), @intCast(descriptor_data_id));
                },

                .create_sampler => {
                    const sampler_id = try self.readVarint();
                    const descriptor_data_id = try self.readVarint();
                    try self.backend.createSampler(allocator, @intCast(sampler_id), @intCast(descriptor_data_id));
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

                .create_image_bitmap => {
                    const bitmap_id = try self.readVarint();
                    const blob_data_id = try self.readVarint();
                    try self.backend.createImageBitmap(allocator, @intCast(bitmap_id), @intCast(blob_data_id));
                },

                .create_texture_view => {
                    const view_id = try self.readVarint();
                    const texture_id = try self.readVarint();
                    const descriptor_data_id = try self.readVarint();
                    try self.backend.createTextureView(allocator, @intCast(view_id), @intCast(texture_id), @intCast(descriptor_data_id));
                },

                .create_query_set => {
                    const query_set_id = try self.readVarint();
                    const descriptor_data_id = try self.readVarint();
                    try self.backend.createQuerySet(allocator, @intCast(query_set_id), @intCast(descriptor_data_id));
                },

                // ============================================================
                // Pass Operations
                // ============================================================

                .begin_render_pass => {
                    const color_texture_id = try self.readVarint();
                    const load_op = try self.readByte();
                    const store_op = try self.readByte();
                    const depth_texture_id = try self.readVarint();
                    try self.backend.beginRenderPass(allocator, @intCast(color_texture_id), load_op, store_op, @intCast(depth_texture_id));
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
                    const first_vertex = try self.readVarint();
                    const first_instance = try self.readVarint();
                    try self.backend.draw(allocator, vertex_count, instance_count, first_vertex, first_instance);
                },

                .draw_indexed => {
                    const index_count = try self.readVarint();
                    const instance_count = try self.readVarint();
                    const first_index = try self.readVarint();
                    const base_vertex = try self.readVarint();
                    const first_instance = try self.readVarint();
                    try self.backend.drawIndexed(allocator, index_count, instance_count, first_index, base_vertex, first_instance);
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

                .copy_external_image_to_texture => {
                    const bitmap_id = try self.readVarint();
                    const texture_id = try self.readVarint();
                    const mip_level = try self.readByte();
                    const origin_x = try self.readVarint();
                    const origin_y = try self.readVarint();
                    try self.backend.copyExternalImageToTexture(allocator, @intCast(bitmap_id), @intCast(texture_id), mip_level, @intCast(origin_x), @intCast(origin_y));
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
                    self.frame_counter += 1;
                },

                .exec_pass => {
                    const pass_id: u16 = @intCast(try self.readVarint());
                    // Execute the pass bytecode range
                    if (self.pass_ranges.get(pass_id)) |range| {
                        // Save current PC
                        const saved_pc = self.pc;
                        // Execute pass bytecode
                        self.pc = range.start;
                        const pass_max_iterations: usize = 1000;
                        for (0..pass_max_iterations) |_| {
                            if (self.pc >= range.end) break;
                            try self.step(allocator);
                        }
                        // Restore PC
                        self.pc = saved_pc;
                    }
                },

                .define_pass => {
                    const pass_id: u16 = @intCast(try self.readVarint());
                    _ = try self.readByte(); // pass_type
                    _ = try self.readVarint(); // descriptor_data_id

                    // Record pass start position
                    const pass_start = self.pc;

                    // Skip ahead to find end_pass_def - don't execute pass body during definition
                    const max_scan: usize = 10000;
                    for (0..max_scan) |_| {
                        if (self.pc >= self.module.bytecode.len) break;
                        const scan_op: OpCode = @enumFromInt(self.module.bytecode[self.pc]);
                        self.pc += 1;

                        if (scan_op == .end_pass_def) {
                            // Store the pass range (excluding end_pass_def)
                            self.pass_ranges.put(pass_id, .{
                                .start = pass_start,
                                .end = self.pc - 1,
                            }) catch {};
                            break;
                        }

                        // Skip opcode parameters (simplified - read varints until next opcode)
                        // This works because varints have high bit set for continuation
                        try self.skipOpcodeParams(scan_op);
                    }
                },

                .end_pass_def => {
                    // Should not be reached - handled by define_pass scanning
                },

                // ============================================================
                // Data Generation (to be implemented)
                // ============================================================

                .create_typed_array => {
                    const array_id = try self.readVarint();
                    const element_type = try self.readByte();
                    const element_count = try self.readVarint();
                    try self.backend.createTypedArray(allocator, @intCast(array_id), element_type, element_count);
                },

                .fill_constant => {
                    const array_id = try self.readVarint();
                    const offset = try self.readVarint();
                    const count = try self.readVarint();
                    const stride = try self.readByte();
                    const value_data_id = try self.readVarint();
                    try self.backend.fillConstant(allocator, @intCast(array_id), offset, count, stride, @intCast(value_data_id));
                },

                .fill_random => {
                    const array_id = try self.readVarint();
                    const offset = try self.readVarint();
                    const count = try self.readVarint();
                    const stride = try self.readByte();
                    const min_data_id = try self.readVarint();
                    const max_data_id = try self.readVarint();
                    try self.backend.fillRandom(allocator, @intCast(array_id), offset, count, stride, @intCast(min_data_id), @intCast(max_data_id));
                },

                .fill_linear,
                .fill_element_index,
                => {
                    // Skip for now - not used by boids
                    _ = try self.readVarint(); // array_id
                    _ = try self.readVarint(); // offset
                    _ = try self.readVarint(); // count
                    _ = try self.readByte(); // stride
                    _ = try self.readVarint(); // start/scale
                    _ = try self.readVarint(); // step/bias
                },

                .fill_expression => {
                    const array_id = try self.readVarint();
                    const offset = try self.readVarint();
                    const count = try self.readVarint();
                    const stride = try self.readByte();
                    const expr_data_id = try self.readVarint();
                    // count is used as total_count for NUM_PARTICLES substitution
                    try self.backend.fillExpression(allocator, @intCast(array_id), offset, count, stride, count, @intCast(expr_data_id));
                },

                .write_buffer_from_array => {
                    const buffer_id = try self.readVarint();
                    const buffer_offset = try self.readVarint();
                    const array_id = try self.readVarint();
                    try self.backend.writeBufferFromArray(allocator, @intCast(buffer_id), buffer_offset, @intCast(array_id));
                },

                // ============================================================
                // Pool Operations
                // ============================================================

                .set_vertex_buffer_pool => {
                    const slot = try self.readByte();
                    const base_buffer_id = try self.readVarint();
                    const pool_size = try self.readByte();
                    const offset = try self.readByte();
                    // Calculate actual buffer ID: base + (frame_counter + offset) % pool_size
                    const actual_id: u16 = @intCast(base_buffer_id + (self.frame_counter + offset) % pool_size);
                    try self.backend.setVertexBuffer(allocator, slot, actual_id);
                },

                .set_bind_group_pool => {
                    const slot = try self.readByte();
                    const base_group_id = try self.readVarint();
                    const pool_size = try self.readByte();
                    const offset = try self.readByte();
                    // Calculate actual bind group ID: base + (frame_counter + offset) % pool_size
                    const actual_id: u16 = @intCast(base_group_id + (self.frame_counter + offset) % pool_size);
                    try self.backend.setBindGroup(allocator, slot, actual_id);
                },

                // ============================================================
                // Unimplemented / Reserved
                // ============================================================

                .nop => {
                    // No operation
                },

                .create_bind_group_layout => {
                    const layout_id = try self.readVarint();
                    const descriptor_data_id = try self.readVarint();
                    try self.backend.createBindGroupLayout(allocator, @intCast(layout_id), @intCast(descriptor_data_id));
                },

                .create_pipeline_layout => {
                    const layout_id = try self.readVarint();
                    const descriptor_data_id = try self.readVarint();
                    try self.backend.createPipelineLayout(allocator, @intCast(layout_id), @intCast(descriptor_data_id));
                },

                .create_shader_concat,
                .set_index_buffer,
                .write_uniform,
                .copy_buffer_to_buffer,
                .copy_texture_to_texture,
                .select_from_pool,
                => {
                    // Not yet implemented
                    return error.InvalidOpcode;
                },

                // ============================================================
                // WASM Operations (to be implemented)
                // ============================================================

                .init_wasm_module => {
                    const module_id = try self.readVarint();
                    const wasm_data_id = try self.readVarint();
                    try self.backend.initWasmModule(allocator, @intCast(module_id), @intCast(wasm_data_id));
                },

                .call_wasm_func => {
                    const call_id = try self.readVarint();
                    const module_id = try self.readVarint();
                    const func_name_id = try self.readVarint();
                    const arg_count = try self.readByte();

                    // Collect encoded args into buffer
                    // Format: [arg_count][arg_type, value?]...
                    var args_buf: [256]u8 = undefined;
                    var args_len: usize = 0;
                    args_buf[args_len] = arg_count;
                    args_len += 1;

                    for (0..arg_count) |_| {
                        const arg_type = try self.readByte();
                        if (args_len < args_buf.len) {
                            args_buf[args_len] = arg_type;
                            args_len += 1;
                        }
                        // Read value bytes based on arg type
                        const value_size: u8 = switch (arg_type) {
                            0x00, 0x04, 0x05 => 4, // literal f32/i32/u32
                            else => 0, // runtime resolved
                        };
                        for (0..value_size) |_| {
                            const byte = try self.readByte();
                            if (args_len < args_buf.len) {
                                args_buf[args_len] = byte;
                                args_len += 1;
                            }
                        }
                    }
                    try self.backend.callWasmFunc(allocator, @intCast(call_id), @intCast(module_id), @intCast(func_name_id), args_buf[0..args_len]);
                },

                .write_buffer_from_wasm => {
                    const call_id = try self.readVarint();
                    const buffer_id = try self.readVarint();
                    const offset = try self.readVarint();
                    const byte_len = try self.readVarint();
                    try self.backend.writeBufferFromWasm(allocator, @intCast(call_id), @intCast(buffer_id), offset, byte_len);
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

        /// Skip opcode parameters during pass definition scanning.
        /// Each opcode has a known parameter structure that we skip over.
        fn skipOpcodeParams(self: *Self, op: OpCode) ExecuteError!void {
            switch (op) {
                // No parameters
                .end_pass, .submit, .end_frame => {},

                // 1 varint
                .set_pipeline => _ = try self.readVarint(),

                // 2 varints
                .set_bind_group, .set_vertex_buffer => {
                    _ = try self.readByte();
                    _ = try self.readVarint();
                },

                // Draw: 4 varints
                .draw => {
                    _ = try self.readVarint();
                    _ = try self.readVarint();
                    _ = try self.readVarint();
                    _ = try self.readVarint();
                },

                // DrawIndexed: 5 varints
                .draw_indexed => {
                    _ = try self.readVarint();
                    _ = try self.readVarint();
                    _ = try self.readVarint();
                    _ = try self.readVarint();
                    _ = try self.readVarint();
                },

                // Dispatch: 3 varints
                .dispatch => {
                    _ = try self.readVarint();
                    _ = try self.readVarint();
                    _ = try self.readVarint();
                },

                // Begin render pass: 2 varints + 2 bytes + 1 varint
                .begin_render_pass => {
                    _ = try self.readVarint();
                    _ = try self.readByte();
                    _ = try self.readByte();
                    _ = try self.readVarint();
                },

                // Begin compute pass: no params
                .begin_compute_pass => {},

                // Pool operations: 1 byte + 1 varint + 2 bytes
                .set_vertex_buffer_pool, .set_bind_group_pool => {
                    _ = try self.readByte();
                    _ = try self.readVarint();
                    _ = try self.readByte();
                    _ = try self.readByte();
                },

                // Default: try to skip unknown opcodes by reading until valid opcode
                else => {},
            }
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
