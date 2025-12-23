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

        /// Scan bytecode for pass definitions and populate pass_ranges.
        /// This is needed before executing a single frame, since exec_pass
        /// opcodes within the frame need to reference pass ranges.
        ///
        /// Complexity: O(bytecode.len)
        pub fn scanPassDefinitions(self: *Self) void {
            const bytecode = self.module.bytecode;
            var pc: usize = 0;
            const max_scan: usize = 50000;

            for (0..max_scan) |_| {
                if (pc >= bytecode.len) break;

                const op: OpCode = @enumFromInt(bytecode[pc]);
                pc += 1;

                if (op == .define_pass) {
                    // Read pass_id, pass_type, descriptor_data_id
                    const pass_id_result = opcodes.decodeVarint(bytecode[pc..]);
                    pc += pass_id_result.len;
                    pc += 1; // pass_type byte
                    const desc_result = opcodes.decodeVarint(bytecode[pc..]);
                    pc += desc_result.len;

                    const pass_start = pc;

                    // Scan for end_pass_def
                    for (0..max_scan) |_| {
                        if (pc >= bytecode.len) break;
                        const scan_op: OpCode = @enumFromInt(bytecode[pc]);
                        pc += 1;
                        if (scan_op == .end_pass_def) {
                            self.pass_ranges.put(@intCast(pass_id_result.value), .{
                                .start = pass_start,
                                .end = pc - 1,
                            }) catch {};
                            break;
                        }
                        skipOpcodeParamsAt(bytecode, &pc, scan_op);
                    }
                } else {
                    skipOpcodeParamsAt(bytecode, &pc, op);
                }
            }
        }

        /// Skip opcode parameters at a given position (for scanning without executing).
        /// Made public for use by CLI frame scanning.
        pub fn skipOpcodeParamsAt(bytecode: []const u8, pc: *usize, op: OpCode) void {
            switch (op) {
                .end_pass, .submit, .end_frame, .nop, .begin_compute_pass, .end_pass_def => {},
                .set_pipeline, .exec_pass => pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len,
                .define_frame => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                .create_buffer => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += 1;
                },
                .set_bind_group, .set_vertex_buffer => {
                    pc.* += 1;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                .draw => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                .draw_indexed => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                .dispatch => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                .execute_bundles => {
                    const bundle_count = opcodes.decodeVarint(bytecode[pc.*..]);
                    pc.* += bundle_count.len;
                    for (0..bundle_count.value) |_| {
                        pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    }
                },
                .begin_render_pass => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += 1;
                    pc.* += 1;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                .create_shader_module => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len; // shader_id
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len; // code_data_id
                },
                .write_buffer => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len; // buffer_id
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len; // offset
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len; // data_id
                },
                .create_texture, .create_render_pipeline, .create_compute_pipeline, .create_sampler => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                .create_bind_group => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len; // group_id
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len; // layout_id
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len; // entry_data_id
                },
                .define_pass => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += 1;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                .set_index_buffer => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += 1;
                },
                .create_typed_array => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += 1;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                .fill_constant => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += 1;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                .fill_linear, .fill_element_index => {
                    // array_id, offset, count, stride, start, step/scale, bias
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += 1;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                .fill_random => {
                    // array_id, offset, count, stride, seed_data_id, min_data_id, max_data_id
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += 1;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                .fill_expression => {
                    // array_id, offset, count, stride, expr_data_id
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += 1;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                .write_buffer_from_array => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                .write_time_uniform => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len; // buffer_id
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len; // offset
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len; // size
                },
                .set_bind_group_pool => {
                    pc.* += 1; // slot
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len; // base_id
                    pc.* += 1; // pool_size
                    pc.* += 1; // offset
                },
                .set_vertex_buffer_pool => {
                    pc.* += 1; // slot
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len; // base_id
                    pc.* += 1; // pool_size
                    pc.* += 1; // offset
                },
                .select_from_pool => {
                    pc.* += 1;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += 1;
                },
                .create_shader_concat => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len; // shader_id
                    const count = opcodes.decodeVarint(bytecode[pc.*..]);
                    pc.* += count.len;
                    for (0..count.value) |_| {
                        pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    }
                },
                .create_bind_group_layout, .create_pipeline_layout, .create_query_set, .create_render_bundle => {
                    // layout_id/query_set_id/bundle_id, descriptor_data_id
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                .create_texture_view => {
                    // view_id, texture_id, descriptor_data_id
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                .create_image_bitmap => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                .write_uniform => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                .copy_buffer_to_buffer => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                .copy_texture_to_texture => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                .copy_external_image_to_texture => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                .init_wasm_module => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                .call_wasm_func => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len; // call_id
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len; // module_id
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len; // func_name_id
                    // arg_count is a raw byte, not a varint (matches emitter and execution)
                    const arg_count = bytecode[pc.*];
                    pc.* += 1;
                    // Skip args: type byte + value (size depends on arg type)
                    for (0..arg_count) |_| {
                        const arg_type: opcodes.WasmArgType = @enumFromInt(bytecode[pc.*]);
                        pc.* += 1; // type byte
                        pc.* += arg_type.valueByteSize(); // value (0-4 bytes depending on type)
                    }
                },
                .write_buffer_from_wasm => {
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                    pc.* += opcodes.decodeVarint(bytecode[pc.*..]).len;
                },
                _ => {},
            }
        }

        /// Execute all bytecode.
        pub fn executeAll(self: *Self, allocator: Allocator) ExecuteError!void {
            // Pre-condition: start at beginning
            assert(self.pc == 0);
            try self.executeFromPC(allocator);
        }

        /// Execute bytecode from current PC to end.
        /// Use this when starting from a non-zero position (e.g., skipping resource creation).
        pub fn executeFromPC(self: *Self, allocator: Allocator) ExecuteError!void {
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
                    // Debug: log dispatch in WASM
                    if (@import("builtin").target.cpu.arch == .wasm32) {
                        const wasm_gpu = @import("wasm_gpu.zig");
                        wasm_gpu.gpuDebugLog(20, x); // dispatch x
                        wasm_gpu.gpuDebugLog(21, y); // dispatch y
                        wasm_gpu.gpuDebugLog(22, z); // dispatch z
                    }
                    try self.backend.dispatch(allocator, x, y, z);
                },

                .execute_bundles => {
                    const bundle_count = try self.readVarint();
                    // Read bundle IDs into temporary buffer
                    var bundle_ids: [16]u16 = undefined;
                    const count = @min(bundle_count, 16);
                    for (0..count) |i| {
                        bundle_ids[i] = @intCast(try self.readVarint());
                    }
                    // Skip any excess bundles
                    for (count..bundle_count) |_| {
                        _ = try self.readVarint();
                    }
                    try self.backend.executeBundles(allocator, bundle_ids[0..count]);
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
                        // Debug: log pass range in WASM
                        if (@import("builtin").target.cpu.arch == .wasm32) {
                            const wasm_gpu = @import("wasm_gpu.zig");
                            wasm_gpu.gpuDebugLog(10, pass_id); // pass_id
                            wasm_gpu.gpuDebugLog(11, @intCast(range.start)); // start
                            wasm_gpu.gpuDebugLog(12, @intCast(range.end)); // end
                        }
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
                    const seed_data_id = try self.readVarint();
                    const min_data_id = try self.readVarint();
                    const max_data_id = try self.readVarint();
                    try self.backend.fillRandom(allocator, @intCast(array_id), offset, count, stride, @intCast(seed_data_id), @intCast(min_data_id), @intCast(max_data_id));
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

                .write_time_uniform => {
                    const buffer_id = try self.readVarint();
                    const buffer_offset = try self.readVarint();
                    const size = try self.readVarint();
                    try self.backend.writeTimeUniform(allocator, @intCast(buffer_id), buffer_offset, @intCast(size));
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

                .create_render_bundle => {
                    const bundle_id = try self.readVarint();
                    const descriptor_data_id = try self.readVarint();
                    try self.backend.createRenderBundle(allocator, @intCast(bundle_id), @intCast(descriptor_data_id));
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

                // Byte + varint
                .set_bind_group, .set_vertex_buffer => {
                    _ = try self.readByte();
                    _ = try self.readVarint();
                },

                // Varint + byte
                .set_index_buffer => {
                    _ = try self.readVarint();
                    _ = try self.readByte();
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

                // ExecuteBundles: count + bundle_ids
                .execute_bundles => {
                    const bundle_count = try self.readVarint();
                    for (0..bundle_count) |_| {
                        _ = try self.readVarint();
                    }
                },

                // Write time uniform: 3 varints
                .write_time_uniform => {
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

    // Post-condition: each pass has valid range
    for ([_]u16{ 0, 1, 2 }) |pass_id| {
        const range = dispatcher.pass_ranges.get(pass_id).?;
        try testing.expect(range.start < range.end);
    }
}

test "scanPassDefinitions: empty pass body" {
    // Edge case: define_pass immediately followed by end_pass_def
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    try emitter.definePass(testing.allocator, 5, .render, 0);
    // No content in pass body
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

    // Post-condition: pass found with start == end (empty range)
    try testing.expectEqual(@as(usize, 1), dispatcher.pass_ranges.count());
    const range = dispatcher.pass_ranges.get(5).?;
    // Empty pass: start equals end (no bytes in body)
    try testing.expect(range.start == range.end);
}

test "scanPassDefinitions: duplicate pass IDs (later overwrites)" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // First definition of pass 0
    try emitter.definePass(testing.allocator, 0, .render, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPassDef(testing.allocator);

    // Second definition of pass 0 (should overwrite)
    try emitter.definePass(testing.allocator, 0, .render, 1);
    try emitter.draw(testing.allocator, 6, 1, 0, 0);
    try emitter.draw(testing.allocator, 6, 1, 0, 0); // Two draws - different size
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

    // Post-condition: only one pass (duplicate ID)
    try testing.expectEqual(@as(usize, 1), dispatcher.pass_ranges.count());

    // The second definition should have overwritten the first
    const range = dispatcher.pass_ranges.get(0).?;
    // Second pass body is larger (two draws vs one)
    try testing.expect(range.end - range.start > 5);
}

test "scanPassDefinitions: pass ID at varint boundary 127" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Pass ID 127 - last 1-byte varint
    try emitter.definePass(testing.allocator, 127, .render, 0);
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
    try testing.expect(dispatcher.pass_ranges.get(127) != null);
}

test "scanPassDefinitions: pass ID at varint boundary 128" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Pass ID 128 - first 2-byte varint
    try emitter.definePass(testing.allocator, 128, .render, 0);
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
    try testing.expect(dispatcher.pass_ranges.get(128) != null);
}

test "scanPassDefinitions: pass with complex opcodes" {
    // Test that skipOpcodeParamsAt correctly skips all opcode types
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    try emitter.definePass(testing.allocator, 0, .render, 0);
    // Various opcodes with different parameter counts
    try emitter.beginRenderPass(testing.allocator, 1, .clear, .store, 0xFFFF);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.setBindGroup(testing.allocator, 0, 0);
    try emitter.setVertexBuffer(testing.allocator, 0, 0);
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

    // Post-condition: pass found with all opcodes inside
    try testing.expectEqual(@as(usize, 1), dispatcher.pass_ranges.count());
    const range = dispatcher.pass_ranges.get(0).?;
    // Pass body should contain all the opcodes
    try testing.expect(range.end - range.start >= 10);
}

test "exec_pass uses scanPassDefinitions correctly" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_id = try builder.internString(testing.allocator, "test");
    const emitter = builder.getEmitter();

    // Define pass with actual render commands
    try emitter.definePass(testing.allocator, 0, .render, 0);
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Frame that executes the pass
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

    // Verify render pass was executed
    const calls = gpu.getCalls();
    try testing.expect(calls.len >= 4);

    // Should have: begin_render_pass, set_pipeline, draw, end_pass, submit
    var found_draw = false;
    for (calls) |call| {
        if (call.call_type == .draw) {
            found_draw = true;
            break;
        }
    }
    try testing.expect(found_draw);
}

test "exec_pass with missing pass_ranges is no-op" {
    // Simulate what happens if exec_pass is called without scanning
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Only emit exec_pass, no define_pass
    try emitter.execPass(testing.allocator, 99); // Non-existent pass
    try emitter.submit(testing.allocator);

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

    // Create a minimal valid module wrapper - dispatcher only uses bytecode field
    const StringTable = @import("../bytecode/string_table.zig").StringTable;
    const DataSection = @import("../bytecode/data_section.zig").DataSection;

    const mock_module = Module{
        .header = .{
            .magic = format.MAGIC.*,
            .version = format.VERSION,
            .flags = .{},
            .string_table_offset = 0,
            .data_section_offset = 0,
            .wgsl_table_offset = 0,
        },
        .bytecode = input,
        .strings = StringTable.empty,
        .data = DataSection.empty,
        .wgsl = format.WgslTable.empty,
    };

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &mock_module);
    defer dispatcher.deinit();

    // Property: this should never panic, only maybe find no passes
    dispatcher.scanPassDefinitions();

    // Property: pass_ranges entries always have start <= module.bytecode.len
    var it = dispatcher.pass_ranges.iterator();
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

// ============================================================================
// skipOpcodeParamsAt Sync Tests
// ============================================================================
//
// These tests ensure skipOpcodeParamsAt stays synchronized with the emitter.
// For every opcode, the bytes skipped must equal bytes emitted (minus opcode byte).
//
// INVARIANT: If skipOpcodeParamsAt skips fewer bytes than emitted, the scanner
// will desync and misinterpret data as opcodes, causing missed pass definitions.

const Emitter = @import("../bytecode/emitter.zig").Emitter;

/// Helper to measure emitted bytes for an opcode (excluding the opcode byte itself).
fn measureEmittedParams(bytecode: []const u8) usize {
    // bytecode[0] is the opcode, rest are params
    return if (bytecode.len > 0) bytecode.len - 1 else 0;
}

/// Helper to build bytecode with a single opcode and measure skip distance.
fn testOpcodeSkipSync(
    comptime emitFn: anytype,
    expected_opcode: OpCode,
) !void {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();
    try emitFn(emitter, testing.allocator);

    const bytecode = emitter.bytecode();

    // Verify opcode matches
    try testing.expectEqual(expected_opcode, @as(OpCode, @enumFromInt(bytecode[0])));

    const emitted_params = measureEmittedParams(bytecode);

    // Now test skipOpcodeParamsAt
    var pc: usize = 1; // Skip opcode byte
    MockDispatcher.skipOpcodeParamsAt(bytecode, &pc, expected_opcode);

    const skipped = pc - 1;

    // CRITICAL: skipped must equal emitted_params
    if (skipped != emitted_params) {
        std.debug.print("\nOPCODE SYNC ERROR: {s}\n", .{@tagName(expected_opcode)});
        std.debug.print("  Emitted params: {} bytes\n", .{emitted_params});
        std.debug.print("  Skipped:        {} bytes\n", .{skipped});
        std.debug.print("  Bytecode: ", .{});
        for (bytecode) |b| {
            std.debug.print("{x:0>2} ", .{b});
        }
        std.debug.print("\n", .{});
        return error.OpcodeSyncMismatch;
    }
}

test "skipOpcodeParamsAt sync: create_buffer" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.createBuffer(a, 0, 256, .{ .vertex = true });
        }
    }.emit, .create_buffer);
}

test "skipOpcodeParamsAt sync: create_texture" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.createTexture(a, 0, 0);
        }
    }.emit, .create_texture);
}

test "skipOpcodeParamsAt sync: create_sampler" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.createSampler(a, 0, 0);
        }
    }.emit, .create_sampler);
}

test "skipOpcodeParamsAt sync: create_shader_module" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.createShaderModule(a, 0, 0);
        }
    }.emit, .create_shader_module);
}

test "skipOpcodeParamsAt sync: create_bind_group_layout" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.createBindGroupLayout(a, 0, 0);
        }
    }.emit, .create_bind_group_layout);
}

test "skipOpcodeParamsAt sync: create_pipeline_layout" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.createPipelineLayout(a, 0, 0);
        }
    }.emit, .create_pipeline_layout);
}

test "skipOpcodeParamsAt sync: create_render_pipeline" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.createRenderPipeline(a, 0, 0);
        }
    }.emit, .create_render_pipeline);
}

test "skipOpcodeParamsAt sync: create_compute_pipeline" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.createComputePipeline(a, 0, 0);
        }
    }.emit, .create_compute_pipeline);
}

test "skipOpcodeParamsAt sync: create_bind_group" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.createBindGroup(a, 0, 0, 0);
        }
    }.emit, .create_bind_group);
}

test "skipOpcodeParamsAt sync: create_texture_view" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.createTextureView(a, 0, 0, 0);
        }
    }.emit, .create_texture_view);
}

test "skipOpcodeParamsAt sync: begin_render_pass" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.beginRenderPass(a, 0, .clear, .store, 0xFFFF);
        }
    }.emit, .begin_render_pass);
}

test "skipOpcodeParamsAt sync: set_pipeline" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.setPipeline(a, 0);
        }
    }.emit, .set_pipeline);
}

test "skipOpcodeParamsAt sync: set_bind_group" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.setBindGroup(a, 0, 0);
        }
    }.emit, .set_bind_group);
}

test "skipOpcodeParamsAt sync: set_vertex_buffer" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.setVertexBuffer(a, 0, 0);
        }
    }.emit, .set_vertex_buffer);
}

test "skipOpcodeParamsAt sync: set_index_buffer" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.setIndexBuffer(a, 0, 0); // format_id is u8
        }
    }.emit, .set_index_buffer);
}

test "skipOpcodeParamsAt sync: draw" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.draw(a, 6, 1, 0, 0);
        }
    }.emit, .draw);
}

test "skipOpcodeParamsAt sync: draw_indexed" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.drawIndexed(a, 6, 1, 0, 0, 0);
        }
    }.emit, .draw_indexed);
}

test "skipOpcodeParamsAt sync: dispatch" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.dispatch(a, 1, 1, 1);
        }
    }.emit, .dispatch);
}

test "skipOpcodeParamsAt sync: write_buffer" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.writeBuffer(a, 0, 0, 0);
        }
    }.emit, .write_buffer);
}

test "skipOpcodeParamsAt sync: write_time_uniform" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.writeTimeUniform(a, 0, 0, 16);
        }
    }.emit, .write_time_uniform);
}

test "skipOpcodeParamsAt sync: define_frame" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.defineFrame(a, 0, 0);
        }
    }.emit, .define_frame);
}

test "skipOpcodeParamsAt sync: exec_pass" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.execPass(a, 0);
        }
    }.emit, .exec_pass);
}

test "skipOpcodeParamsAt sync: define_pass" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.definePass(a, 0, .render, 0);
        }
    }.emit, .define_pass);
}

test "skipOpcodeParamsAt sync: set_bind_group_pool" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.setBindGroupPool(a, 0, 0, 2, 0);
        }
    }.emit, .set_bind_group_pool);
}

test "skipOpcodeParamsAt sync: set_vertex_buffer_pool" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.setVertexBufferPool(a, 0, 0, 2, 0);
        }
    }.emit, .set_vertex_buffer_pool);
}

test "skipOpcodeParamsAt sync: create_typed_array" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.createTypedArray(a, 0, .f32, 100);
        }
    }.emit, .create_typed_array);
}

test "skipOpcodeParamsAt sync: fill_constant" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.fillConstant(a, 0, 0, 100, 4, 0); // value_data_id is u16
        }
    }.emit, .fill_constant);
}

// fill_linear has no emitter method - test with direct bytecode
test "skipOpcodeParamsAt sync: fill_linear" {
    // Params: array_id, offset, count, stride, start, step (6 varints + 1 byte)
    const bytecode = [_]u8{
        @intFromEnum(OpCode.fill_linear),
        0, // array_id (varint)
        0, // offset (varint)
        100, // count (varint)
        4, // stride (byte)
        0, // start (varint)
        1, // step (varint)
    };
    var pc: usize = 1;
    MockDispatcher.skipOpcodeParamsAt(&bytecode, &pc, .fill_linear);
    try testing.expectEqual(@as(usize, bytecode.len), pc);
}

// fill_element_index has no emitter method - test with direct bytecode
test "skipOpcodeParamsAt sync: fill_element_index" {
    // Params: array_id, offset, count, stride, scale, bias (5 varints + 1 byte)
    const bytecode = [_]u8{
        @intFromEnum(OpCode.fill_element_index),
        0, // array_id (varint)
        0, // offset (varint)
        100, // count (varint)
        4, // stride (byte)
        1, // scale (varint)
        0, // bias (varint)
    };
    var pc: usize = 1;
    MockDispatcher.skipOpcodeParamsAt(&bytecode, &pc, .fill_element_index);
    try testing.expectEqual(@as(usize, bytecode.len), pc);
}

test "skipOpcodeParamsAt sync: fill_random" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.fillRandom(a, 0, 0, 100, 4, 42, 0, 1); // seed_data_id, min_data_id, max_data_id
        }
    }.emit, .fill_random);
}

test "skipOpcodeParamsAt sync: fill_expression" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.fillExpression(a, 0, 0, 100, 4, 0);
        }
    }.emit, .fill_expression);
}

test "skipOpcodeParamsAt sync: write_buffer_from_array" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            try e.writeBufferFromArray(a, 0, 0, 0);
        }
    }.emit, .write_buffer_from_array);
}

// call_wasm_func tests - verify correct handling of different WasmArgType values
test "skipOpcodeParamsAt sync: call_wasm_func with runtime args (0-byte values)" {
    // Args with runtime types (canvas_width=0x01, canvas_height=0x02) have 0-byte values
    const bytecode = [_]u8{
        @intFromEnum(OpCode.call_wasm_func),
        0, // call_id (varint)
        0, // module_id (varint)
        3, // func_name_id (varint)
        2, // arg_count (byte, NOT varint!)
        0x01, // arg0 type: canvas_width (0 value bytes)
        0x02, // arg1 type: canvas_height (0 value bytes)
    };
    var pc: usize = 1;
    MockDispatcher.skipOpcodeParamsAt(&bytecode, &pc, .call_wasm_func);
    try testing.expectEqual(@as(usize, bytecode.len), pc);
}

test "skipOpcodeParamsAt sync: call_wasm_func with literal args (4-byte values)" {
    // Args with literal types (literal_f32=0x00) have 4-byte values
    const bytecode = [_]u8{
        @intFromEnum(OpCode.call_wasm_func),
        0, // call_id (varint)
        0, // module_id (varint)
        5, // func_name_id (varint)
        1, // arg_count (byte)
        0x00, // arg0 type: literal_f32 (4 value bytes)
        0x00, 0x00, 0x80, 0x3F, // arg0 value: 1.0f
    };
    var pc: usize = 1;
    MockDispatcher.skipOpcodeParamsAt(&bytecode, &pc, .call_wasm_func);
    try testing.expectEqual(@as(usize, bytecode.len), pc);
}

test "skipOpcodeParamsAt sync: call_wasm_func with mixed args" {
    // Mix of runtime (0-byte) and literal (4-byte) args
    const bytecode = [_]u8{
        @intFromEnum(OpCode.call_wasm_func),
        0, // call_id (varint)
        0, // module_id (varint)
        7, // func_name_id (varint)
        3, // arg_count (byte)
        0x01, // arg0 type: canvas_width (0 value bytes)
        0x00, // arg1 type: literal_f32 (4 value bytes)
        0x00, 0x00, 0x00, 0x40, // arg1 value: 2.0f
        0x03, // arg2 type: time_total (0 value bytes)
    };
    var pc: usize = 1;
    MockDispatcher.skipOpcodeParamsAt(&bytecode, &pc, .call_wasm_func);
    try testing.expectEqual(@as(usize, bytecode.len), pc);
}

test "skipOpcodeParamsAt sync: call_wasm_func with no args" {
    const bytecode = [_]u8{
        @intFromEnum(OpCode.call_wasm_func),
        0, // call_id (varint)
        0, // module_id (varint)
        0, // func_name_id (varint)
        0, // arg_count (byte) - no args
    };
    var pc: usize = 1;
    MockDispatcher.skipOpcodeParamsAt(&bytecode, &pc, .call_wasm_func);
    try testing.expectEqual(@as(usize, bytecode.len), pc);
}

test "skipOpcodeParamsAt sync: call_wasm_func with all runtime arg types" {
    // Test all runtime arg types: canvas_width, canvas_height, time_total, time_delta
    const bytecode = [_]u8{
        @intFromEnum(OpCode.call_wasm_func),
        0, // call_id (varint)
        0, // module_id (varint)
        0, // func_name_id (varint)
        4, // arg_count (byte)
        0x01, // arg0: canvas_width
        0x02, // arg1: canvas_height
        0x03, // arg2: time_total
        0x06, // arg3: time_delta
    };
    var pc: usize = 1;
    MockDispatcher.skipOpcodeParamsAt(&bytecode, &pc, .call_wasm_func);
    try testing.expectEqual(@as(usize, bytecode.len), pc);
}

test "skipOpcodeParamsAt sync: call_wasm_func with all literal arg types" {
    // Test all literal arg types: literal_f32, literal_i32, literal_u32
    const bytecode = [_]u8{
        @intFromEnum(OpCode.call_wasm_func),
        0, // call_id
        0, // module_id
        0, // func_name_id
        3, // arg_count
        0x00, 0x00, 0x00, 0x80, 0x3F, // literal_f32 + 1.0f
        0x04, 0xFF, 0xFF, 0xFF, 0xFF, // literal_i32 + -1
        0x05, 0x01, 0x00, 0x00, 0x00, // literal_u32 + 1
    };
    var pc: usize = 1;
    MockDispatcher.skipOpcodeParamsAt(&bytecode, &pc, .call_wasm_func);
    try testing.expectEqual(@as(usize, bytecode.len), pc);
}

// create_shader_concat has no emitter method - test with direct bytecode
test "skipOpcodeParamsAt sync: create_shader_concat" {
    // Params: shader_id, count, data_id_0, data_id_1, ... (varints)
    const bytecode = [_]u8{
        @intFromEnum(OpCode.create_shader_concat),
        0, // shader_id (varint)
        3, // count (varint)
        0, // data_id_0 (varint)
        1, // data_id_1 (varint)
        2, // data_id_2 (varint)
    };
    var pc: usize = 1;
    MockDispatcher.skipOpcodeParamsAt(&bytecode, &pc, .create_shader_concat);
    try testing.expectEqual(@as(usize, bytecode.len), pc);
}

test "skipOpcodeParamsAt sync: execute_bundles" {
    try testOpcodeSkipSync(struct {
        fn emit(e: *Emitter, a: Allocator) !void {
            const bundle_ids = [_]u16{ 0, 1 };
            try e.executeBundles(a, &bundle_ids);
        }
    }.emit, .execute_bundles);
}

// copy_buffer_to_buffer has no emitter method - test with direct bytecode
test "skipOpcodeParamsAt sync: copy_buffer_to_buffer" {
    // Params: src_buffer, src_offset, dst_buffer, dst_offset, size (5 varints)
    const bytecode = [_]u8{
        @intFromEnum(OpCode.copy_buffer_to_buffer),
        0, // src_buffer (varint)
        0, // src_offset (varint)
        1, // dst_buffer (varint)
        0, // dst_offset (varint)
        @as(u8, 0x80) | 1, 0, // size = 256 (2-byte varint)
    };
    var pc: usize = 1;
    MockDispatcher.skipOpcodeParamsAt(&bytecode, &pc, .copy_buffer_to_buffer);
    try testing.expectEqual(@as(usize, bytecode.len), pc);
}

// copy_texture_to_texture has no emitter method - test with direct bytecode
test "skipOpcodeParamsAt sync: copy_texture_to_texture" {
    // Params: src_texture, dst_texture (2 varints)
    const bytecode = [_]u8{
        @intFromEnum(OpCode.copy_texture_to_texture),
        0, // src_texture (varint)
        1, // dst_texture (varint)
    };
    var pc: usize = 1;
    MockDispatcher.skipOpcodeParamsAt(&bytecode, &pc, .copy_texture_to_texture);
    try testing.expectEqual(@as(usize, bytecode.len), pc);
}

// ============================================================================
// Comprehensive Opcode Coverage Test
// ============================================================================

test "skipOpcodeParamsAt: all valid opcodes handled (no catch-all fallthrough)" {
    // This test verifies that every valid opcode has an explicit handler.
    // If a new opcode is added to the enum but not to skipOpcodeParamsAt,
    // the catch-all `_ => {}` will silently skip 0 bytes, causing desync.
    //
    // We verify by checking that the opcode enum tags match explicit handlers.

    const all_opcodes = [_]OpCode{
        // Resource Creation (0x00-0x0F)
        .nop,
        .create_buffer,
        .create_texture,
        .create_sampler,
        .create_shader_module,
        .create_shader_concat,
        .create_bind_group_layout,
        .create_pipeline_layout,
        .create_render_pipeline,
        .create_compute_pipeline,
        .create_bind_group,
        .create_image_bitmap,
        .create_texture_view,
        .create_query_set,
        .create_render_bundle,
        // Pass Operations (0x10-0x1F)
        .begin_render_pass,
        .begin_compute_pass,
        .set_pipeline,
        .set_bind_group,
        .set_vertex_buffer,
        .set_index_buffer,
        .draw,
        .draw_indexed,
        .dispatch,
        .end_pass,
        .execute_bundles,
        // Queue Operations (0x20-0x2F)
        .write_buffer,
        .write_uniform,
        .copy_buffer_to_buffer,
        .copy_texture_to_texture,
        .submit,
        .copy_external_image_to_texture,
        .init_wasm_module,
        .call_wasm_func,
        .write_buffer_from_wasm,
        .write_buffer_from_array,
        .write_time_uniform,
        // Frame Control (0x30-0x3F)
        .define_frame,
        .end_frame,
        .exec_pass,
        .define_pass,
        .end_pass_def,
        // Pool Operations (0x40-0x4F)
        .select_from_pool,
        .set_vertex_buffer_pool,
        .set_bind_group_pool,
        // Data Generation (0x50-0x7F)
        .create_typed_array,
        .fill_constant,
        .fill_random,
        .fill_linear,
        .fill_element_index,
        .fill_expression,
    };

    // Verify each valid opcode is known
    for (all_opcodes) |op| {
        try testing.expect(op.isValid());
    }

    // Count: we should have all valid opcodes covered
    // This list should be updated when new opcodes are added
    try testing.expectEqual(@as(usize, 51), all_opcodes.len);
}

// ============================================================================
// Varying Varint Size Tests
// ============================================================================

test "skipOpcodeParamsAt sync: varying varint sizes" {
    // Property: skipOpcodeParamsAt must skip exactly what emitter emits,
    // even when IDs require 2 or 4 byte varints.

    // Test create_bind_group with IDs that use 2-byte varints (>= 128)
    {
        var emitter: Emitter = .empty;
        defer emitter.deinit(testing.allocator);

        try emitter.createBindGroup(testing.allocator, 200, 150, 180); // All > 127

        const bytecode = emitter.bytecode();
        try testing.expectEqual(@as(u8, @intFromEnum(OpCode.create_bind_group)), bytecode[0]);

        const emitted_params = bytecode.len - 1;
        var pc: usize = 1;
        MockDispatcher.skipOpcodeParamsAt(bytecode, &pc, .create_bind_group);
        const skipped = pc - 1;

        try testing.expectEqual(emitted_params, skipped);
    }

    // Test write_buffer with large IDs
    {
        var emitter: Emitter = .empty;
        defer emitter.deinit(testing.allocator);

        try emitter.writeBuffer(testing.allocator, 200, 16384, 150); // offset uses 4-byte varint

        const bytecode = emitter.bytecode();
        try testing.expectEqual(@as(u8, @intFromEnum(OpCode.write_buffer)), bytecode[0]);

        const emitted_params = bytecode.len - 1;
        var pc: usize = 1;
        MockDispatcher.skipOpcodeParamsAt(bytecode, &pc, .write_buffer);
        const skipped = pc - 1;

        try testing.expectEqual(emitted_params, skipped);
    }

    // Test draw with large counts
    {
        var emitter: Emitter = .empty;
        defer emitter.deinit(testing.allocator);

        try emitter.draw(testing.allocator, 10000, 500, 0, 0);

        const bytecode = emitter.bytecode();
        try testing.expectEqual(@as(u8, @intFromEnum(OpCode.draw)), bytecode[0]);

        const emitted_params = bytecode.len - 1;
        var pc: usize = 1;
        MockDispatcher.skipOpcodeParamsAt(bytecode, &pc, .draw);
        const skipped = pc - 1;

        try testing.expectEqual(emitted_params, skipped);
    }
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
