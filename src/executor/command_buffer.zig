//! Command Buffer for GPU Operations
//!
//! Instead of calling extern JS functions directly, accumulates GPU commands
//! into a binary buffer that JS can execute. This reduces the JS bundle size
//! significantly by moving the dispatch logic from 2000 lines of JS to a
//! simple ~200 line switch statement.
//!
//! ## Format
//!
//! ```
//! Header (8 bytes):
//!   [total_len: u32]    Total buffer size including header
//!   [cmd_count: u16]    Number of commands
//!   [flags: u16]        Reserved for future use
//!
//! Commands (variable):
//!   [cmd: u8]           Command opcode
//!   [args: ...]         Fixed-size arguments per command type
//! ```
//!
//! ## Invariants
//!
//! - Buffer is pre-allocated with fixed capacity (64KB default)
//! - All writes are bounds-checked
//! - Pointers into WASM memory are passed as u32 offsets
//! - JS must read data from WASM memory using these pointers

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const format = @import("../bytecode/format.zig");
const Module = format.Module;
const DataId = @import("../bytecode/data_section.zig").DataId;

/// Command opcodes for JS dispatcher.
/// Grouped by category, matching the plan's command set.
pub const Cmd = enum(u8) {
    // Resource Creation (0x01-0x0F)
    create_buffer = 0x01,
    create_texture = 0x02,
    create_sampler = 0x03,
    create_shader = 0x04,
    create_render_pipeline = 0x05,
    create_compute_pipeline = 0x06,
    create_bind_group = 0x07,

    // Pass Operations (0x10-0x1F)
    begin_render_pass = 0x10,
    begin_compute_pass = 0x11,
    set_pipeline = 0x12,
    set_bind_group = 0x13,
    set_vertex_buffer = 0x14,
    draw = 0x15,
    draw_indexed = 0x16,
    end_pass = 0x17,
    dispatch = 0x18,
    set_index_buffer = 0x19,

    // Queue Operations (0x20-0x2F)
    write_buffer = 0x20,
    write_time_uniform = 0x21,

    // Control (0xF0-0xFF)
    submit = 0xF0,
    end = 0xFF,
};

/// Header size in bytes.
pub const HEADER_SIZE: usize = 8;

/// Default buffer capacity (64KB should be plenty for most frames).
pub const DEFAULT_CAPACITY: usize = 64 * 1024;

/// Command buffer that accumulates GPU commands.
pub const CommandBuffer = struct {
    const Self = @This();

    /// Backing buffer for commands.
    buffer: []u8,

    /// Current write position (after header).
    pos: usize,

    /// Number of commands written.
    cmd_count: u16,

    /// Initialize with pre-allocated buffer.
    pub fn init(buffer: []u8) Self {
        assert(buffer.len >= HEADER_SIZE);
        return .{
            .buffer = buffer,
            .pos = HEADER_SIZE,
            .cmd_count = 0,
        };
    }

    /// Finalize and write header. Returns slice of used buffer.
    pub fn finish(self: *Self) []const u8 {
        // Write header
        const total_len: u32 = @intCast(self.pos);
        std.mem.writeInt(u32, self.buffer[0..4], total_len, .little);
        std.mem.writeInt(u16, self.buffer[4..6], self.cmd_count, .little);
        std.mem.writeInt(u16, self.buffer[6..8], 0, .little); // flags

        return self.buffer[0..self.pos];
    }

    /// Get pointer to buffer start (for WASM export).
    pub fn ptr(self: *const Self) [*]const u8 {
        return self.buffer.ptr;
    }

    // ========================================================================
    // Low-level write methods
    // ========================================================================

    fn writeU8(self: *Self, value: u8) void {
        if (self.pos < self.buffer.len) {
            self.buffer[self.pos] = value;
            self.pos += 1;
        }
    }

    fn writeU16(self: *Self, value: u16) void {
        if (self.pos + 2 <= self.buffer.len) {
            std.mem.writeInt(u16, self.buffer[self.pos..][0..2], value, .little);
            self.pos += 2;
        }
    }

    fn writeU32(self: *Self, value: u32) void {
        if (self.pos + 4 <= self.buffer.len) {
            std.mem.writeInt(u32, self.buffer[self.pos..][0..4], value, .little);
            self.pos += 4;
        }
    }

    fn writeCmd(self: *Self, cmd: Cmd) void {
        self.writeU8(@intFromEnum(cmd));
        self.cmd_count += 1;
    }

    // ========================================================================
    // Command emission methods
    // ========================================================================

    /// CREATE_BUFFER: [id:u16] [size:u32] [usage:u8]
    pub fn createBuffer(self: *Self, id: u16, size: u32, usage: u8) void {
        self.writeCmd(.create_buffer);
        self.writeU16(id);
        self.writeU32(size);
        self.writeU8(usage);
    }

    /// CREATE_TEXTURE: [id:u16] [desc_ptr:u32] [desc_len:u32]
    pub fn createTexture(self: *Self, id: u16, desc_ptr: u32, desc_len: u32) void {
        self.writeCmd(.create_texture);
        self.writeU16(id);
        self.writeU32(desc_ptr);
        self.writeU32(desc_len);
    }

    /// CREATE_SAMPLER: [id:u16] [desc_ptr:u32] [desc_len:u32]
    pub fn createSampler(self: *Self, id: u16, desc_ptr: u32, desc_len: u32) void {
        self.writeCmd(.create_sampler);
        self.writeU16(id);
        self.writeU32(desc_ptr);
        self.writeU32(desc_len);
    }

    /// CREATE_SHADER: [id:u16] [code_ptr:u32] [code_len:u32]
    pub fn createShader(self: *Self, id: u16, code_ptr: u32, code_len: u32) void {
        self.writeCmd(.create_shader);
        self.writeU16(id);
        self.writeU32(code_ptr);
        self.writeU32(code_len);
    }

    /// CREATE_RENDER_PIPELINE: [id:u16] [desc_ptr:u32] [desc_len:u32]
    pub fn createRenderPipeline(self: *Self, id: u16, desc_ptr: u32, desc_len: u32) void {
        self.writeCmd(.create_render_pipeline);
        self.writeU16(id);
        self.writeU32(desc_ptr);
        self.writeU32(desc_len);
    }

    /// CREATE_COMPUTE_PIPELINE: [id:u16] [desc_ptr:u32] [desc_len:u32]
    pub fn createComputePipeline(self: *Self, id: u16, desc_ptr: u32, desc_len: u32) void {
        self.writeCmd(.create_compute_pipeline);
        self.writeU16(id);
        self.writeU32(desc_ptr);
        self.writeU32(desc_len);
    }

    /// CREATE_BIND_GROUP: [id:u16] [layout_id:u16] [entries_ptr:u32] [entries_len:u32]
    pub fn createBindGroup(self: *Self, id: u16, layout_id: u16, entries_ptr: u32, entries_len: u32) void {
        self.writeCmd(.create_bind_group);
        self.writeU16(id);
        self.writeU16(layout_id);
        self.writeU32(entries_ptr);
        self.writeU32(entries_len);
    }

    /// BEGIN_RENDER_PASS: [color_id:u16] [load:u8] [store:u8] [depth_id:u16]
    pub fn beginRenderPass(self: *Self, color_id: u16, load_op: u8, store_op: u8, depth_id: u16) void {
        self.writeCmd(.begin_render_pass);
        self.writeU16(color_id);
        self.writeU8(load_op);
        self.writeU8(store_op);
        self.writeU16(depth_id);
    }

    /// BEGIN_COMPUTE_PASS: (no args)
    pub fn beginComputePass(self: *Self) void {
        self.writeCmd(.begin_compute_pass);
    }

    /// SET_PIPELINE: [id:u16]
    pub fn setPipeline(self: *Self, id: u16) void {
        self.writeCmd(.set_pipeline);
        self.writeU16(id);
    }

    /// SET_BIND_GROUP: [slot:u8] [id:u16]
    pub fn setBindGroup(self: *Self, slot: u8, id: u16) void {
        self.writeCmd(.set_bind_group);
        self.writeU8(slot);
        self.writeU16(id);
    }

    /// SET_VERTEX_BUFFER: [slot:u8] [id:u16]
    pub fn setVertexBuffer(self: *Self, slot: u8, id: u16) void {
        self.writeCmd(.set_vertex_buffer);
        self.writeU8(slot);
        self.writeU16(id);
    }

    /// SET_INDEX_BUFFER: [id:u16] [format:u8]
    pub fn setIndexBuffer(self: *Self, id: u16, index_format: u8) void {
        self.writeCmd(.set_index_buffer);
        self.writeU16(id);
        self.writeU8(index_format);
    }

    /// DRAW: [vtx:u32] [inst:u32] [first_vtx:u32] [first_inst:u32]
    pub fn draw(self: *Self, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        self.writeCmd(.draw);
        self.writeU32(vertex_count);
        self.writeU32(instance_count);
        self.writeU32(first_vertex);
        self.writeU32(first_instance);
    }

    /// DRAW_INDEXED: [idx:u32] [inst:u32] [first_idx:u32] [base_vtx:u32] [first_inst:u32]
    pub fn drawIndexed(self: *Self, index_count: u32, instance_count: u32, first_index: u32, base_vertex: u32, first_instance: u32) void {
        self.writeCmd(.draw_indexed);
        self.writeU32(index_count);
        self.writeU32(instance_count);
        self.writeU32(first_index);
        self.writeU32(base_vertex);
        self.writeU32(first_instance);
    }

    /// DISPATCH: [x:u32] [y:u32] [z:u32]
    pub fn dispatch(self: *Self, x: u32, y: u32, z: u32) void {
        self.writeCmd(.dispatch);
        self.writeU32(x);
        self.writeU32(y);
        self.writeU32(z);
    }

    /// END_PASS: (no args)
    pub fn endPass(self: *Self) void {
        self.writeCmd(.end_pass);
    }

    /// WRITE_BUFFER: [id:u16] [offset:u32] [data_ptr:u32] [data_len:u32]
    pub fn writeBuffer(self: *Self, id: u16, offset: u32, data_ptr: u32, data_len: u32) void {
        self.writeCmd(.write_buffer);
        self.writeU16(id);
        self.writeU32(offset);
        self.writeU32(data_ptr);
        self.writeU32(data_len);
    }

    /// WRITE_TIME_UNIFORM: [id:u16] [offset:u32] [size:u16]
    pub fn writeTimeUniform(self: *Self, id: u16, offset: u32, size: u16) void {
        self.writeCmd(.write_time_uniform);
        self.writeU16(id);
        self.writeU32(offset);
        self.writeU16(size);
    }

    /// SUBMIT: (no args)
    pub fn submit(self: *Self) void {
        self.writeCmd(.submit);
    }

    /// END: (no args) - marks end of command buffer
    pub fn end(self: *Self) void {
        self.writeCmd(.end);
    }
};

// ============================================================================
// CommandGPU Backend
// ============================================================================

// Constants for WGSL resolution
const MAX_WGSL_MODULES: u32 = 64;
const MAX_WGSL_DEPS: u32 = 16;

/// GPU backend that writes to a CommandBuffer instead of calling extern functions.
/// Implements the same interface as WasmGPU so it can be used with Dispatcher.
pub const CommandGPU = struct {
    const Self = @This();

    /// Command buffer to write to.
    cmds: *CommandBuffer,

    /// Reference to module for data lookups.
    module: ?*const Module,

    /// Resolved WGSL code that must be kept alive until command buffer is consumed.
    /// Freed in deinit().
    resolved_wgsl: std.ArrayListUnmanaged([]const u8),

    /// Allocator used for resolved_wgsl.
    alloc: ?Allocator,

    pub fn init(cmds: *CommandBuffer) Self {
        return .{
            .cmds = cmds,
            .module = null,
            .resolved_wgsl = .{},
            .alloc = null,
        };
    }

    /// Free all resolved WGSL allocations.
    pub fn deinit(self: *Self) void {
        if (self.alloc) |a| {
            for (self.resolved_wgsl.items) |code| {
                a.free(code);
            }
            self.resolved_wgsl.deinit(a);
        }
    }

    pub fn setModule(self: *Self, module: *const Module) void {
        self.module = module;
    }

    /// Get data from module's data section.
    fn getData(self: *const Self, data_id: u16) ?[]const u8 {
        const module = self.module orelse return null;
        const id: DataId = @enumFromInt(data_id);
        if (id.toInt() >= module.data.count()) return null;
        return module.data.get(id);
    }

    // ========================================================================
    // Backend Interface (matches WasmGPU signatures exactly)
    // ========================================================================

    pub fn createBuffer(self: *Self, allocator: Allocator, buffer_id: u16, size: u32, usage: u8) !void {
        _ = allocator;
        self.cmds.createBuffer(buffer_id, size, usage);
    }

    pub fn createTexture(self: *Self, allocator: Allocator, texture_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        const data = self.getData(descriptor_data_id) orelse return;
        self.cmds.createTexture(texture_id, @intFromPtr(data.ptr), @intCast(data.len));
    }

    pub fn createSampler(self: *Self, allocator: Allocator, sampler_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        const data = self.getData(descriptor_data_id) orelse return;
        self.cmds.createSampler(sampler_id, @intFromPtr(data.ptr), @intCast(data.len));
    }

    pub fn createShaderModule(self: *Self, allocator: Allocator, shader_id: u16, wgsl_id: u16) !void {
        // Resolve WGSL from module using allocator
        const module = self.module orelse return error.OutOfMemory;
        const code = try self.resolveWgsl(allocator, module, wgsl_id);

        // Store allocator for deinit
        self.alloc = allocator;

        // Keep code alive until command buffer is consumed
        try self.resolved_wgsl.append(allocator, code);

        self.cmds.createShader(shader_id, @intFromPtr(code.ptr), @intCast(code.len));
    }

    pub fn createRenderPipeline(self: *Self, allocator: Allocator, pipeline_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        const data = self.getData(descriptor_data_id) orelse return;
        self.cmds.createRenderPipeline(pipeline_id, @intFromPtr(data.ptr), @intCast(data.len));
    }

    pub fn createComputePipeline(self: *Self, allocator: Allocator, pipeline_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        const data = self.getData(descriptor_data_id) orelse return;
        self.cmds.createComputePipeline(pipeline_id, @intFromPtr(data.ptr), @intCast(data.len));
    }

    pub fn createBindGroup(self: *Self, allocator: Allocator, group_id: u16, layout_id: u16, entry_data_id: u16) !void {
        _ = allocator;
        const data = self.getData(entry_data_id) orelse return;
        self.cmds.createBindGroup(group_id, layout_id, @intFromPtr(data.ptr), @intCast(data.len));
    }

    pub fn beginRenderPass(self: *Self, allocator: Allocator, color_texture_id: u16, load_op: u8, store_op: u8, depth_texture_id: u16) !void {
        _ = allocator;
        self.cmds.beginRenderPass(color_texture_id, load_op, store_op, depth_texture_id);
    }

    pub fn beginComputePass(self: *Self, allocator: Allocator) !void {
        _ = allocator;
        self.cmds.beginComputePass();
    }

    pub fn setPipeline(self: *Self, allocator: Allocator, pipeline_id: u16) !void {
        _ = allocator;
        self.cmds.setPipeline(pipeline_id);
    }

    pub fn setBindGroup(self: *Self, allocator: Allocator, slot: u8, group_id: u16) !void {
        _ = allocator;
        self.cmds.setBindGroup(slot, group_id);
    }

    pub fn setVertexBuffer(self: *Self, allocator: Allocator, slot: u8, buffer_id: u16) !void {
        _ = allocator;
        self.cmds.setVertexBuffer(slot, buffer_id);
    }

    pub fn setIndexBuffer(self: *Self, allocator: Allocator, buffer_id: u16, index_format: u8) !void {
        _ = allocator;
        self.cmds.setIndexBuffer(buffer_id, index_format);
    }

    pub fn draw(self: *Self, allocator: Allocator, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) !void {
        _ = allocator;
        self.cmds.draw(vertex_count, instance_count, first_vertex, first_instance);
    }

    pub fn drawIndexed(self: *Self, allocator: Allocator, index_count: u32, instance_count: u32, first_index: u32, base_vertex: u32, first_instance: u32) !void {
        _ = allocator;
        self.cmds.drawIndexed(index_count, instance_count, first_index, base_vertex, first_instance);
    }

    pub fn dispatch(self: *Self, allocator: Allocator, x: u32, y: u32, z: u32) !void {
        _ = allocator;
        self.cmds.dispatch(x, y, z);
    }

    pub fn endPass(self: *Self, allocator: Allocator) !void {
        _ = allocator;
        self.cmds.endPass();
    }

    pub fn writeBuffer(self: *Self, allocator: Allocator, buffer_id: u16, offset: u32, data_id: u16) !void {
        _ = allocator;
        const data = self.getData(data_id) orelse return;
        self.cmds.writeBuffer(buffer_id, offset, @intFromPtr(data.ptr), @intCast(data.len));
    }

    pub fn writeTimeUniform(self: *Self, allocator: Allocator, buffer_id: u16, offset: u32, size: u16) !void {
        _ = allocator;
        self.cmds.writeTimeUniform(buffer_id, offset, size);
    }

    pub fn submit(self: *Self, allocator: Allocator) !void {
        _ = allocator;
        self.cmds.submit();
    }

    // Stubs for operations not yet supported in command buffer
    pub fn createImageBitmap(self: *Self, allocator: Allocator, _: u16, _: u16) !void {
        _ = self;
        _ = allocator;
    }

    pub fn createTextureView(self: *Self, allocator: Allocator, _: u16, _: u16, _: u16) !void {
        _ = self;
        _ = allocator;
    }

    pub fn createQuerySet(self: *Self, allocator: Allocator, _: u16, _: u16) !void {
        _ = self;
        _ = allocator;
    }

    pub fn createBindGroupLayout(self: *Self, allocator: Allocator, _: u16, _: u16) !void {
        _ = self;
        _ = allocator;
    }

    pub fn createPipelineLayout(self: *Self, allocator: Allocator, _: u16, _: u16) !void {
        _ = self;
        _ = allocator;
    }

    pub fn createRenderBundle(self: *Self, allocator: Allocator, _: u16, _: u16) !void {
        _ = self;
        _ = allocator;
    }

    pub fn executeBundles(self: *Self, allocator: Allocator, _: []const u16) !void {
        _ = self;
        _ = allocator;
    }

    pub fn copyExternalImageToTexture(self: *Self, allocator: Allocator, _: u16, _: u16, _: u8, _: u16, _: u16) !void {
        _ = self;
        _ = allocator;
    }

    pub fn initWasmModule(self: *Self, allocator: Allocator, _: u16, _: u16) !void {
        _ = self;
        _ = allocator;
    }

    pub fn callWasmFunc(self: *Self, allocator: Allocator, _: u16, _: u16, _: u16, _: []const u8) !void {
        _ = self;
        _ = allocator;
    }

    pub fn writeBufferFromWasm(self: *Self, allocator: Allocator, _: u16, _: u16, _: u32, _: u32) !void {
        _ = self;
        _ = allocator;
    }

    pub fn createTypedArray(self: *Self, allocator: Allocator, _: u16, _: u8, _: u32) !void {
        _ = self;
        _ = allocator;
    }

    pub fn fillRandom(self: *Self, allocator: Allocator, _: u16, _: u32, _: u32, _: u8, _: u16, _: u16) !void {
        _ = self;
        _ = allocator;
    }

    pub fn fillExpression(self: *Self, allocator: Allocator, _: u16, _: u32, _: u32, _: u8, _: u32, _: u16) !void {
        _ = self;
        _ = allocator;
    }

    pub fn fillConstant(self: *Self, allocator: Allocator, _: u16, _: u32, _: u32, _: u8, _: u16) !void {
        _ = self;
        _ = allocator;
    }

    pub fn writeBufferFromArray(self: *Self, allocator: Allocator, _: u16, _: u32, _: u16) !void {
        _ = self;
        _ = allocator;
    }

    pub fn consoleLog(self: *Self, _: []const u8, _: []const u8) void {
        _ = self;
    }

    pub fn consoleLogInt(self: *Self, _: []const u8, _: i32) void {
        _ = self;
    }

    // ========================================================================
    // WGSL Resolution (similar to WasmGPU)
    // ========================================================================

    fn resolveWgsl(self: *Self, allocator: Allocator, module: *const Module, wgsl_id: u16) ![]u8 {
        _ = self;
        const wgsl_table = &module.wgsl;

        // Track included modules and order
        var included = std.AutoHashMapUnmanaged(u16, void){};
        defer included.deinit(allocator);

        var order = std.ArrayListUnmanaged(u16){};
        defer order.deinit(allocator);

        var stack = std.ArrayListUnmanaged(u16){};
        defer stack.deinit(allocator);

        try stack.append(allocator, wgsl_id);

        // Iterative DFS with bounded iterations
        const max_iterations: u32 = MAX_WGSL_MODULES * MAX_WGSL_DEPS;
        for (0..max_iterations) |_| {
            if (stack.items.len == 0) break;

            const current = stack.pop() orelse break;
            if (included.contains(current)) continue;

            const entry = wgsl_table.get(current) orelse continue;

            // Check if all deps are included
            var all_deps_ready = true;
            for (entry.deps) |dep| {
                if (!included.contains(dep)) {
                    all_deps_ready = false;
                    break;
                }
            }

            if (all_deps_ready) {
                try included.put(allocator, current, {});
                try order.append(allocator, current);
            } else {
                try stack.append(allocator, current);
                for (entry.deps) |dep| {
                    if (!included.contains(dep)) {
                        try stack.append(allocator, dep);
                    }
                }
            }
        }

        // Calculate total size
        var total_size: usize = 0;
        for (order.items) |id| {
            if (wgsl_table.get(id)) |entry| {
                const data = module.data.get(@enumFromInt(entry.data_id));
                total_size += data.len;
            }
        }

        // Concatenate in order
        const result = try allocator.alloc(u8, total_size);
        var pos: usize = 0;
        for (order.items) |id| {
            if (wgsl_table.get(id)) |entry| {
                const data = module.data.get(@enumFromInt(entry.data_id));
                @memcpy(result[pos..][0..data.len], data);
                pos += data.len;
            }
        }

        return result;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "CommandBuffer basic" {
    var buffer: [1024]u8 = undefined;
    var cmds = CommandBuffer.init(&buffer);

    cmds.createBuffer(0, 256, 0x21);
    cmds.beginRenderPass(0xFFFF, 1, 1, 0xFFFF);
    cmds.setPipeline(0);
    cmds.draw(3, 1, 0, 0);
    cmds.endPass();
    cmds.submit();
    cmds.end();

    const result = cmds.finish();

    // Check header
    const total_len = std.mem.readInt(u32, result[0..4], .little);
    const cmd_count = std.mem.readInt(u16, result[4..6], .little);

    try std.testing.expect(total_len > HEADER_SIZE);
    try std.testing.expectEqual(@as(u16, 7), cmd_count);
}

test "CommandBuffer commands" {
    var buffer: [256]u8 = undefined;
    var cmds = CommandBuffer.init(&buffer);

    cmds.createBuffer(1, 1024, 0x41);
    _ = cmds.finish();

    // Verify command encoding
    // Header (8) + cmd(1) + id(2) + size(4) + usage(1) = 16
    try std.testing.expectEqual(@as(usize, 16), cmds.pos);

    // Check command byte
    try std.testing.expectEqual(@as(u8, 0x01), buffer[HEADER_SIZE]);

    // Check id (little-endian)
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buffer[HEADER_SIZE + 1 ..][0..2], .little));

    // Check size
    try std.testing.expectEqual(@as(u32, 1024), std.mem.readInt(u32, buffer[HEADER_SIZE + 3 ..][0..4], .little));
}
