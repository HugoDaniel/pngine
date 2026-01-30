//! Opcode Scanner
//!
//! Unified bytecode scanning for pass definitions and opcode skipping.
//! Eliminates duplication between skipOpcodeParamsAt and skipOpcodeParams.
//!
//! ## Design
//!
//! - Single OpcodeScanner type works with external pc pointer
//! - Used by scanPassDefinitions for pass range discovery
//! - Used by define_pass handler for skipping during execution
//!
//! ## Invariants
//!
//! - pc never exceeds bytecode.len after skip operations
//! - All opcode parameter structures match emitter exactly

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const bytecode_mod = @import("bytecode");
const opcodes = bytecode_mod.opcodes;
const OpCode = opcodes.OpCode;

/// Pass bytecode range (start and end offsets within bytecode).
pub const PassRange = struct {
    start: u32,
    end: u32,
};

/// Maximum iterations for scanning loops.
const MAX_SCAN_ITERATIONS: u32 = 50000;

/// Opcode scanner for pass definition discovery and parameter skipping.
pub const OpcodeScanner = struct {
    const Self = @This();

    bytecode: []const u8,
    pc: u32,

    /// Initialize scanner at given position.
    pub fn init(bytecode: []const u8, start_pc: u32) Self {
        // Pre-conditions
        assert(start_pc <= bytecode.len);

        return .{
            .bytecode = bytecode,
            .pc = start_pc,
        };
    }

    /// Check if scanner has more bytes to read.
    pub fn hasMore(self: *const Self) bool {
        return self.pc < self.bytecode.len;
    }

    /// Read current opcode and advance pc.
    pub fn readOpcode(self: *Self) ?OpCode {
        if (self.pc >= self.bytecode.len) return null;
        const op: OpCode = @enumFromInt(self.bytecode[self.pc]);
        self.pc += 1;
        return op;
    }

    /// Skip a single varint parameter.
    fn skipVarint(self: *Self) void {
        if (self.pc >= self.bytecode.len) return;
        const result = opcodes.decodeVarint(self.bytecode[self.pc..]);
        self.pc += result.len;
    }

    /// Skip N varint parameters.
    fn skipVarints(self: *Self, comptime count: u32) void {
        inline for (0..count) |_| {
            self.skipVarint();
        }
    }

    /// Skip a single byte parameter.
    fn skipByte(self: *Self) void {
        if (self.pc < self.bytecode.len) {
            self.pc += 1;
        }
    }

    /// Skip opcode parameters based on opcode type.
    /// This must stay synchronized with the emitter's output format.
    ///
    /// INVARIANT: If skipParams skips fewer bytes than emitted, the scanner
    /// will desync and misinterpret data as opcodes, causing missed pass definitions.
    pub fn skipParams(self: *Self, op: OpCode) void {
        switch (op) {
            // No parameters
            .end_pass, .submit, .end_frame, .nop, .begin_compute_pass, .end_pass_def => {},

            // 1 varint
            .set_pipeline, .exec_pass, .exec_pass_once => self.skipVarint(),

            // 2 varints
            .define_frame,
            .create_texture,
            .create_render_pipeline,
            .create_compute_pipeline,
            .create_sampler,
            .create_shader_module,
            .create_bind_group_layout,
            .create_pipeline_layout,
            .create_query_set,
            .create_render_bundle,
            .create_image_bitmap,
            .write_uniform,
            .copy_texture_to_texture,
            .init_wasm_module,
            => self.skipVarints(2),

            // 3 varints
            .create_bind_group,
            .write_buffer,
            .write_time_uniform,
            .create_texture_view,
            .dispatch,
            => self.skipVarints(3),

            // 4 varints
            .draw, .write_buffer_from_wasm => self.skipVarints(4),

            // 5 varints
            .draw_indexed, .copy_buffer_to_buffer, .copy_external_image_to_texture => self.skipVarints(5),

            // varint + varint + byte (create_buffer)
            .create_buffer => {
                self.skipVarints(2);
                self.skipByte();
            },

            // byte + varint
            .set_bind_group, .set_vertex_buffer => {
                self.skipByte();
                self.skipVarint();
            },

            // varint + byte
            .set_index_buffer => {
                self.skipVarint();
                self.skipByte();
            },

            // varint + 2 bytes + varint (begin_render_pass)
            .begin_render_pass => {
                self.skipVarint();
                self.skipByte();
                self.skipByte();
                self.skipVarint();
            },

            // byte + varint + 2 bytes (pool operations)
            .set_bind_group_pool, .set_vertex_buffer_pool => {
                self.skipByte();
                self.skipVarint();
                self.skipByte();
                self.skipByte();
            },

            // byte + varint + byte (select_from_pool)
            .select_from_pool => {
                self.skipByte();
                self.skipVarint();
                self.skipByte();
            },

            // varint + byte + varint (define_pass)
            .define_pass => {
                self.skipVarint();
                self.skipByte();
                self.skipVarint();
            },

            // Variable length: count + N varints
            .execute_bundles => {
                if (self.pc >= self.bytecode.len) return;
                const bundle_count = opcodes.decodeVarint(self.bytecode[self.pc..]);
                self.pc += bundle_count.len;
                for (0..@min(bundle_count.value, MAX_SCAN_ITERATIONS)) |_| {
                    self.skipVarint();
                }
            },

            // Variable length: shader_id + count + N data_ids
            .create_shader_concat => {
                self.skipVarint(); // shader_id
                if (self.pc >= self.bytecode.len) return;
                const count = opcodes.decodeVarint(self.bytecode[self.pc..]);
                self.pc += count.len;
                for (0..@min(count.value, MAX_SCAN_ITERATIONS)) |_| {
                    self.skipVarint();
                }
            },

            // Variable length: 3 varints + byte + args
            .call_wasm_func => {
                self.skipVarints(3); // call_id, module_id, func_name_id
                if (self.pc >= self.bytecode.len) return;
                const arg_count = self.bytecode[self.pc];
                self.pc += 1;
                // Skip args: type byte + value (size depends on arg type)
                for (0..@min(arg_count, 32)) |_| {
                    if (self.pc >= self.bytecode.len) return;
                    const arg_type: opcodes.WasmArgType = @enumFromInt(self.bytecode[self.pc]);
                    self.pc += 1; // type byte
                    self.pc += arg_type.valueByteSize(); // value (0-4 bytes)
                }
            },

            // Unknown opcodes - skip nothing (will likely cause desync)
            _ => {},
        }
    }

    /// Scan bytecode for all pass definitions and return their ranges.
    ///
    /// Complexity: O(bytecode.len)
    pub fn scanPassDefinitions(
        bytecode: []const u8,
        allocator: Allocator,
    ) std.AutoHashMap(u16, PassRange) {
        // Pre-conditions
        assert(bytecode.len <= 1024 * 1024); // 1MB max

        var pass_ranges = std.AutoHashMap(u16, PassRange).init(allocator);
        var scanner = OpcodeScanner.init(bytecode, 0);

        for (0..MAX_SCAN_ITERATIONS) |_| {
            const op = scanner.readOpcode() orelse break;

            if (op == .define_pass) {
                // Read pass_id
                if (scanner.pc >= bytecode.len) break;
                const pass_id_result = opcodes.decodeVarint(bytecode[scanner.pc..]);
                scanner.pc += pass_id_result.len;

                // Skip pass_type byte
                scanner.skipByte();

                // Skip descriptor_data_id
                scanner.skipVarint();

                const pass_start = scanner.pc;

                // Scan for end_pass_def
                for (0..MAX_SCAN_ITERATIONS) |_| {
                    const scan_op = scanner.readOpcode() orelse break;
                    if (scan_op == .end_pass_def) {
                        pass_ranges.put(@intCast(pass_id_result.value), .{
                            .start = pass_start,
                            .end = scanner.pc - 1,
                        }) catch {};
                        break;
                    }
                    scanner.skipParams(scan_op);
                }
            } else {
                scanner.skipParams(op);
            }
        }

        // Post-condition: scanner didn't exceed bytecode
        assert(scanner.pc <= bytecode.len);

        return pass_ranges;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const format = bytecode_mod.format;
const Builder = format.Builder;

test "OpcodeScanner: skip draw params" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();
    try emitter.draw(testing.allocator, 3, 1, 0, 0);

    const bytecode = emitter.bytecode();

    // Pre-condition: starts with draw opcode
    try testing.expectEqual(OpCode.draw, @as(OpCode, @enumFromInt(bytecode[0])));

    var scanner = OpcodeScanner.init(bytecode, 1); // Skip opcode byte
    scanner.skipParams(.draw);

    // Post-condition: skipped to end
    try testing.expectEqual(bytecode.len, scanner.pc);
}

test "OpcodeScanner: skip call_wasm_func with mixed args" {
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

    var scanner = OpcodeScanner.init(&bytecode, 1); // Skip opcode byte
    scanner.skipParams(.call_wasm_func);

    try testing.expectEqual(bytecode.len, scanner.pc);
}

test "OpcodeScanner: scanPassDefinitions finds multiple passes" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Pass 0
    try emitter.definePass(testing.allocator, 0, .render, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPassDef(testing.allocator);

    // Pass 1
    try emitter.definePass(testing.allocator, 1, .compute, 0);
    try emitter.dispatch(testing.allocator, 8, 8, 1);
    try emitter.endPassDef(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var pass_ranges = OpcodeScanner.scanPassDefinitions(module.bytecode, testing.allocator);
    defer pass_ranges.deinit();

    try testing.expectEqual(@as(usize, 2), pass_ranges.count());
    try testing.expect(pass_ranges.get(0) != null);
    try testing.expect(pass_ranges.get(1) != null);
}

test "OpcodeScanner: skip create_bind_group (3 varints)" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();
    try emitter.createBindGroup(testing.allocator, 200, 150, 180);

    const bytecode = emitter.bytecode();
    try testing.expectEqual(OpCode.create_bind_group, @as(OpCode, @enumFromInt(bytecode[0])));

    var scanner = OpcodeScanner.init(bytecode, 1);
    scanner.skipParams(.create_bind_group);

    try testing.expectEqual(bytecode.len, scanner.pc);
}
