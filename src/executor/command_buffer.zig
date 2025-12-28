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

// Use bytecode module import
const bytecode_mod = @import("bytecode");
const format = bytecode_mod.format;
const Module = format.Module;
const DataId = bytecode_mod.DataId;
const StringId = bytecode_mod.StringId;

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
    create_texture_view = 0x08,
    create_query_set = 0x09,
    create_bind_group_layout = 0x0A,
    create_image_bitmap = 0x0B,
    create_pipeline_layout = 0x0C,
    create_render_bundle = 0x0D,

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
    execute_bundles = 0x1A,

    // Queue Operations (0x20-0x2F)
    write_buffer = 0x20,
    write_time_uniform = 0x21,
    copy_buffer_to_buffer = 0x22,
    copy_texture_to_texture = 0x23,
    write_buffer_from_wasm = 0x24,
    copy_external_image_to_texture = 0x25,

    // WASM Module Operations (0x30-0x3F)
    init_wasm_module = 0x30,
    call_wasm_func = 0x31,

    // Utility Operations (0x40-0x4F)
    create_typed_array = 0x40,
    fill_random = 0x41,
    fill_expression = 0x42,
    fill_constant = 0x43,
    write_buffer_from_array = 0x44,

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

    fn writeSlice(self: *Self, data: []const u8) void {
        const max_to_write = @min(data.len, self.buffer.len -| self.pos);
        if (max_to_write > 0) {
            @memcpy(self.buffer[self.pos..][0..max_to_write], data[0..max_to_write]);
            self.pos += max_to_write;
        }
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

    /// CREATE_IMAGE_BITMAP: [id:u16] [data_ptr:u32] [data_len:u32]
    pub fn createImageBitmap(self: *Self, id: u16, data_ptr: u32, data_len: u32) void {
        self.writeCmd(.create_image_bitmap);
        self.writeU16(id);
        self.writeU32(data_ptr);
        self.writeU32(data_len);
    }

    /// COPY_EXTERNAL_IMAGE_TO_TEXTURE: [bitmap_id:u16] [texture_id:u16] [mip_level:u8] [origin_x:u16] [origin_y:u16]
    pub fn copyExternalImageToTexture(self: *Self, bitmap_id: u16, texture_id: u16, mip_level: u8, origin_x: u16, origin_y: u16) void {
        self.writeCmd(.copy_external_image_to_texture);
        self.writeU16(bitmap_id);
        self.writeU16(texture_id);
        self.writeU8(mip_level);
        self.writeU16(origin_x);
        self.writeU16(origin_y);
    }

    /// CREATE_TEXTURE_VIEW: [id:u16] [texture_id:u16] [desc_ptr:u32] [desc_len:u32]
    pub fn createTextureView(self: *Self, id: u16, texture_id: u16, desc_ptr: u32, desc_len: u32) void {
        self.writeCmd(.create_texture_view);
        self.writeU16(id);
        self.writeU16(texture_id);
        self.writeU32(desc_ptr);
        self.writeU32(desc_len);
    }

    /// CREATE_QUERY_SET: [id:u16] [desc_ptr:u32] [desc_len:u32]
    pub fn createQuerySet(self: *Self, id: u16, desc_ptr: u32, desc_len: u32) void {
        self.writeCmd(.create_query_set);
        self.writeU16(id);
        self.writeU32(desc_ptr);
        self.writeU32(desc_len);
    }

    /// CREATE_BIND_GROUP_LAYOUT: [id:u16] [desc_ptr:u32] [desc_len:u32]
    pub fn createBindGroupLayout(self: *Self, id: u16, desc_ptr: u32, desc_len: u32) void {
        self.writeCmd(.create_bind_group_layout);
        self.writeU16(id);
        self.writeU32(desc_ptr);
        self.writeU32(desc_len);
    }

    /// CREATE_PIPELINE_LAYOUT: [id:u16] [desc_ptr:u32] [desc_len:u32]
    pub fn createPipelineLayout(self: *Self, id: u16, desc_ptr: u32, desc_len: u32) void {
        self.writeCmd(.create_pipeline_layout);
        self.writeU16(id);
        self.writeU32(desc_ptr);
        self.writeU32(desc_len);
    }

    /// CREATE_RENDER_BUNDLE: [id:u16] [desc_ptr:u32] [desc_len:u32]
    pub fn createRenderBundle(self: *Self, id: u16, desc_ptr: u32, desc_len: u32) void {
        self.writeCmd(.create_render_bundle);
        self.writeU16(id);
        self.writeU32(desc_ptr);
        self.writeU32(desc_len);
    }

    /// EXECUTE_BUNDLES: [count:u8] [bundle_ids:u16...]
    pub fn executeBundles(self: *Self, bundle_ids: []const u16) void {
        self.writeCmd(.execute_bundles);
        self.writeU8(@intCast(bundle_ids.len));
        for (bundle_ids) |id| {
            self.writeU16(id);
        }
    }

    /// COPY_BUFFER_TO_BUFFER: [src_id:u16] [src_offset:u32] [dst_id:u16] [dst_offset:u32] [size:u32]
    pub fn copyBufferToBuffer(self: *Self, src_id: u16, src_offset: u32, dst_id: u16, dst_offset: u32, size: u32) void {
        self.writeCmd(.copy_buffer_to_buffer);
        self.writeU16(src_id);
        self.writeU32(src_offset);
        self.writeU16(dst_id);
        self.writeU32(dst_offset);
        self.writeU32(size);
    }

    /// COPY_TEXTURE_TO_TEXTURE: [src_id:u16] [dst_id:u16] [width:u16] [height:u16]
    pub fn copyTextureToTexture(self: *Self, src_id: u16, dst_id: u16, width: u16, height: u16) void {
        self.writeCmd(.copy_texture_to_texture);
        self.writeU16(src_id);
        self.writeU16(dst_id);
        self.writeU16(width);
        self.writeU16(height);
    }

    /// WRITE_BUFFER_FROM_WASM: [buffer_id:u16] [buffer_offset:u32] [wasm_ptr:u32] [size:u32]
    pub fn writeBufferFromWasm(self: *Self, buffer_id: u16, buffer_offset: u32, wasm_ptr: u32, size: u32) void {
        self.writeCmd(.write_buffer_from_wasm);
        self.writeU16(buffer_id);
        self.writeU32(buffer_offset);
        self.writeU32(wasm_ptr);
        self.writeU32(size);
    }

    /// INIT_WASM_MODULE: [module_id:u16] [data_ptr:u32] [data_len:u32]
    pub fn initWasmModule(self: *Self, module_id: u16, data_ptr: u32, data_len: u32) void {
        self.writeCmd(.init_wasm_module);
        self.writeU16(module_id);
        self.writeU32(data_ptr);
        self.writeU32(data_len);
    }

    /// CALL_WASM_FUNC: [call_id:u16] [module_id:u16] [func_name_ptr:u32] [func_name_len:u32] [args_len:u8] [args bytes...]
    /// Note: args are copied inline to avoid dangling stack pointers.
    pub fn callWasmFunc(self: *Self, call_id: u16, module_id: u16, func_name_ptr: u32, func_name_len: u32, args: []const u8) void {
        self.writeCmd(.call_wasm_func);
        self.writeU16(call_id);
        self.writeU16(module_id);
        self.writeU32(func_name_ptr);
        self.writeU32(func_name_len);
        self.writeU8(@intCast(@min(args.len, 255)));
        self.writeSlice(args);
    }

    /// CREATE_TYPED_ARRAY: [id:u16] [type:u8] [size:u32]
    pub fn createTypedArray(self: *Self, id: u16, array_type: u8, size: u32) void {
        self.writeCmd(.create_typed_array);
        self.writeU16(id);
        self.writeU8(array_type);
        self.writeU32(size);
    }

    /// FILL_RANDOM: [array_id:u16] [offset:u32] [count:u32] [stride:u8] [data_ptr:u32]
    /// data_ptr points to pre-generated f32 values in WASM memory
    pub fn fillRandom(self: *Self, array_id: u16, offset: u32, count: u32, stride: u8, data_ptr: u32) void {
        self.writeCmd(.fill_random);
        self.writeU16(array_id);
        self.writeU32(offset);
        self.writeU32(count);
        self.writeU8(stride);
        self.writeU32(data_ptr);
    }

    /// FILL_EXPRESSION: [array_id:u16] [offset:u32] [count:u32] [stride:u8] [expr_ptr:u32] [expr_len:u16]
    pub fn fillExpression(self: *Self, array_id: u16, offset: u32, count: u32, stride: u8, expr_ptr: u32, expr_len: u16) void {
        self.writeCmd(.fill_expression);
        self.writeU16(array_id);
        self.writeU32(offset);
        self.writeU32(count);
        self.writeU8(stride);
        self.writeU32(expr_ptr);
        self.writeU16(expr_len);
    }

    /// FILL_CONSTANT: [array_id:u16] [offset:u32] [count:u32] [stride:u8] [value_ptr:u32]
    pub fn fillConstant(self: *Self, array_id: u16, offset: u32, count: u32, stride: u8, value_ptr: u32) void {
        self.writeCmd(.fill_constant);
        self.writeU16(array_id);
        self.writeU32(offset);
        self.writeU32(count);
        self.writeU8(stride);
        self.writeU32(value_ptr);
    }

    /// WRITE_BUFFER_FROM_ARRAY: [buffer_id:u16] [buffer_offset:u32] [array_id:u16]
    pub fn writeBufferFromArray(self: *Self, buffer_id: u16, buffer_offset: u32, array_id: u16) void {
        self.writeCmd(.write_buffer_from_array);
        self.writeU16(buffer_id);
        self.writeU32(buffer_offset);
        self.writeU16(array_id);
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

    /// Random data buffers that must be kept alive until command buffer is consumed.
    /// Freed in deinit().
    random_data: std.ArrayListUnmanaged([]f32),

    /// Allocator used for resolved_wgsl and random_data.
    alloc: ?Allocator,

    pub fn init(cmds: *CommandBuffer) Self {
        return .{
            .cmds = cmds,
            .module = null,
            .resolved_wgsl = .{},
            .random_data = .{},
            .alloc = null,
        };
    }

    /// Free all resolved WGSL and random data allocations.
    pub fn deinit(self: *Self) void {
        if (self.alloc) |a| {
            for (self.resolved_wgsl.items) |code| {
                a.free(code);
            }
            self.resolved_wgsl.deinit(a);
            for (self.random_data.items) |data| {
                a.free(data);
            }
            self.random_data.deinit(a);
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

    // Image bitmap and texture copy operations
    pub fn createImageBitmap(self: *Self, allocator: Allocator, bitmap_id: u16, blob_data_id: u16) !void {
        _ = allocator;
        const data = self.getData(blob_data_id) orelse return;
        self.cmds.createImageBitmap(bitmap_id, @intFromPtr(data.ptr), @intCast(data.len));
    }

    pub fn createTextureView(self: *Self, allocator: Allocator, view_id: u16, texture_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        const data = self.getData(descriptor_data_id) orelse return;
        self.cmds.createTextureView(view_id, texture_id, @intFromPtr(data.ptr), @intCast(data.len));
    }

    pub fn createQuerySet(self: *Self, allocator: Allocator, query_set_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        const data = self.getData(descriptor_data_id) orelse return;
        self.cmds.createQuerySet(query_set_id, @intFromPtr(data.ptr), @intCast(data.len));
    }

    pub fn createBindGroupLayout(self: *Self, allocator: Allocator, layout_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        const data = self.getData(descriptor_data_id) orelse return;
        self.cmds.createBindGroupLayout(layout_id, @intFromPtr(data.ptr), @intCast(data.len));
    }

    pub fn createPipelineLayout(self: *Self, allocator: Allocator, layout_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        const data = self.getData(descriptor_data_id) orelse return;
        self.cmds.createPipelineLayout(layout_id, @intFromPtr(data.ptr), @intCast(data.len));
    }

    pub fn createRenderBundle(self: *Self, allocator: Allocator, bundle_id: u16, descriptor_data_id: u16) !void {
        _ = allocator;
        const data = self.getData(descriptor_data_id) orelse return;
        self.cmds.createRenderBundle(bundle_id, @intFromPtr(data.ptr), @intCast(data.len));
    }

    pub fn executeBundles(self: *Self, allocator: Allocator, bundle_ids: []const u16) !void {
        _ = allocator;
        self.cmds.executeBundles(bundle_ids);
    }

    pub fn copyExternalImageToTexture(self: *Self, allocator: Allocator, bitmap_id: u16, texture_id: u16, mip_level: u8, origin_x: u16, origin_y: u16) !void {
        _ = allocator;
        self.cmds.copyExternalImageToTexture(bitmap_id, texture_id, mip_level, origin_x, origin_y);
    }

    pub fn copyBufferToBuffer(self: *Self, allocator: Allocator, src_id: u16, src_offset: u32, dst_id: u16, dst_offset: u32, size: u32) !void {
        _ = allocator;
        self.cmds.copyBufferToBuffer(src_id, src_offset, dst_id, dst_offset, size);
    }

    pub fn copyTextureToTexture(self: *Self, allocator: Allocator, src_id: u16, dst_id: u16, width: u16, height: u16) !void {
        _ = allocator;
        self.cmds.copyTextureToTexture(src_id, dst_id, width, height);
    }

    pub fn initWasmModule(self: *Self, allocator: Allocator, module_id: u16, wasm_data_id: u16) !void {
        _ = allocator;
        const data = self.getData(wasm_data_id) orelse return;
        self.cmds.initWasmModule(module_id, @intFromPtr(data.ptr), @intCast(data.len));
    }

    pub fn callWasmFunc(self: *Self, allocator: Allocator, call_id: u16, module_id: u16, func_name_id: u16, args: []const u8) !void {
        _ = allocator;
        const module = self.module orelse return;
        const string_id: StringId = @enumFromInt(func_name_id);
        const func_name = module.strings.get(string_id);
        // Pass args slice directly - they are copied inline into the command buffer
        self.cmds.callWasmFunc(call_id, module_id, @intFromPtr(func_name.ptr), @intCast(func_name.len), args);
    }

    pub fn writeBufferFromWasm(self: *Self, allocator: Allocator, buffer_id: u16, buffer_offset: u16, wasm_ptr: u32, size: u32) !void {
        _ = allocator;
        self.cmds.writeBufferFromWasm(buffer_id, buffer_offset, wasm_ptr, size);
    }

    pub fn createTypedArray(self: *Self, allocator: Allocator, id: u16, array_type: u8, size: u32) !void {
        _ = allocator;
        self.cmds.createTypedArray(id, array_type, size);
    }

    pub fn fillRandom(self: *Self, allocator: Allocator, array_id: u16, offset: u32, count: u32, stride: u8, seed_data_id: u16, min_data_id: u16, max_data_id: u16) !void {
        const seed_data = self.getData(seed_data_id) orelse return;
        const min_data = self.getData(min_data_id) orelse return;
        const max_data = self.getData(max_data_id) orelse return;

        // Parse values (stored as little-endian in data section)
        const seed = std.mem.readInt(u32, seed_data[0..4], .little);
        const min_val = @as(f32, @bitCast(std.mem.readInt(u32, min_data[0..4], .little)));
        const max_val = @as(f32, @bitCast(std.mem.readInt(u32, max_data[0..4], .little)));
        const range = max_val - min_val;

        // Allocate buffer for random values (persists until deinit)
        const values = try allocator.alloc(f32, count);
        errdefer allocator.free(values);

        // Generate random values using seeded PRNG (xoshiro256)
        const seed64: u64 = @as(u64, seed) | (@as(u64, seed ^ 0x6D2B79F5) << 32);
        var prng = std.Random.DefaultPrng.init(seed64);
        const random = prng.random();

        for (values) |*v| {
            v.* = min_val + random.float(f32) * range;
        }

        // Track allocation for cleanup
        self.alloc = allocator;
        try self.random_data.append(allocator, values);

        // Pass pointer to generated data
        self.cmds.fillRandom(array_id, offset, count, stride, @truncate(@intFromPtr(values.ptr)));
    }

    pub fn fillExpression(self: *Self, allocator: Allocator, array_id: u16, offset: u32, count: u32, stride: u8, total_count: u32, expr_data_id: u16) !void {
        _ = allocator;
        _ = total_count; // total_count is implicit in the iteration
        const expr_data = self.getData(expr_data_id) orelse return;
        self.cmds.fillExpression(array_id, offset, count, stride, @truncate(@intFromPtr(expr_data.ptr)), @intCast(expr_data.len));
    }

    pub fn fillConstant(self: *Self, allocator: Allocator, array_id: u16, offset: u32, count: u32, stride: u8, value_data_id: u16) !void {
        _ = allocator;
        const value_data = self.getData(value_data_id) orelse return;
        // value_ptr is a pointer to f32 value in data section
        self.cmds.fillConstant(array_id, offset, count, stride, @truncate(@intFromPtr(value_data.ptr)));
    }

    pub fn writeBufferFromArray(self: *Self, allocator: Allocator, buffer_id: u16, buffer_offset: u32, array_id: u16) !void {
        _ = allocator;
        self.cmds.writeBufferFromArray(buffer_id, buffer_offset, array_id);
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

// ============================================================================
// WASM Plugin Command Tests
// ============================================================================

test "CommandBuffer: initWasmModule encodes correctly" {
    var buffer: [256]u8 = undefined;
    var cmds = CommandBuffer.init(&buffer);

    const module_id: u16 = 5;
    const data_ptr: u32 = 0x1000;
    const data_len: u32 = 256;
    cmds.initWasmModule(module_id, data_ptr, data_len);
    _ = cmds.finish();

    // Expected: Header (8) + cmd(1) + module_id(2) + data_ptr(4) + data_len(4) = 19
    try std.testing.expectEqual(@as(usize, 19), cmds.pos);

    // Verify command byte
    try std.testing.expectEqual(@as(u8, @intFromEnum(Cmd.init_wasm_module)), buffer[HEADER_SIZE]);

    // Verify module_id
    var pos: usize = HEADER_SIZE + 1;
    try std.testing.expectEqual(module_id, std.mem.readInt(u16, buffer[pos..][0..2], .little));
    pos += 2;

    // Verify data_ptr
    try std.testing.expectEqual(data_ptr, std.mem.readInt(u32, buffer[pos..][0..4], .little));
    pos += 4;

    // Verify data_len
    try std.testing.expectEqual(data_len, std.mem.readInt(u32, buffer[pos..][0..4], .little));
}

test "CommandBuffer: callWasmFunc encodes correctly with inline args" {
    var buffer: [256]u8 = undefined;
    var cmds = CommandBuffer.init(&buffer);

    const call_id: u16 = 1;
    const module_id: u16 = 0;
    const func_name_ptr: u32 = 0x2000;
    const func_name_len: u32 = 10;
    // Inline args: [count=3, type=1, type=2, type=3]
    const args = [_]u8{ 3, 0x01, 0x02, 0x03 };

    cmds.callWasmFunc(call_id, module_id, func_name_ptr, func_name_len, &args);
    _ = cmds.finish();

    // Expected: Header (8) + cmd(1) + call_id(2) + module_id(2) + func_name_ptr(4)
    //           + func_name_len(4) + args_len(1) + args(4) = 26
    try std.testing.expectEqual(@as(usize, 26), cmds.pos);

    // Verify command byte
    try std.testing.expectEqual(@as(u8, @intFromEnum(Cmd.call_wasm_func)), buffer[HEADER_SIZE]);

    // Verify parameters
    var pos: usize = HEADER_SIZE + 1;
    try std.testing.expectEqual(call_id, std.mem.readInt(u16, buffer[pos..][0..2], .little));
    pos += 2;
    try std.testing.expectEqual(module_id, std.mem.readInt(u16, buffer[pos..][0..2], .little));
    pos += 2;
    try std.testing.expectEqual(func_name_ptr, std.mem.readInt(u32, buffer[pos..][0..4], .little));
    pos += 4;
    try std.testing.expectEqual(func_name_len, std.mem.readInt(u32, buffer[pos..][0..4], .little));
    pos += 4;
    // Args length (u8)
    try std.testing.expectEqual(@as(u8, 4), buffer[pos]);
    pos += 1;
    // Inline args bytes
    try std.testing.expectEqualSlices(u8, &args, buffer[pos..][0..4]);
}

test "CommandBuffer: writeBufferFromWasm encodes correctly" {
    var buffer: [256]u8 = undefined;
    var cmds = CommandBuffer.init(&buffer);

    const buffer_id: u16 = 3;
    const buffer_offset: u32 = 64;
    const wasm_ptr: u32 = 0x4000;
    const size: u32 = 128;

    cmds.writeBufferFromWasm(buffer_id, buffer_offset, wasm_ptr, size);
    _ = cmds.finish();

    // Expected: Header (8) + cmd(1) + buffer_id(2) + buffer_offset(4) + wasm_ptr(4) + size(4) = 23
    try std.testing.expectEqual(@as(usize, 23), cmds.pos);

    // Verify command byte
    try std.testing.expectEqual(@as(u8, @intFromEnum(Cmd.write_buffer_from_wasm)), buffer[HEADER_SIZE]);

    // Verify parameters
    var pos: usize = HEADER_SIZE + 1;
    try std.testing.expectEqual(buffer_id, std.mem.readInt(u16, buffer[pos..][0..2], .little));
    pos += 2;
    try std.testing.expectEqual(buffer_offset, std.mem.readInt(u32, buffer[pos..][0..4], .little));
    pos += 4;
    try std.testing.expectEqual(wasm_ptr, std.mem.readInt(u32, buffer[pos..][0..4], .little));
    pos += 4;
    try std.testing.expectEqual(size, std.mem.readInt(u32, buffer[pos..][0..4], .little));
}

test "CommandBuffer: WASM flow sequence" {
    // Test a typical WASM call flow:
    // 1. initWasmModule - load module
    // 2. callWasmFunc - call function with inline args
    // 3. writeBufferFromWasm - copy result to GPU
    var buffer: [512]u8 = undefined;
    var cmds = CommandBuffer.init(&buffer);

    // Args: [count=2][arg1_type=canvas_width][arg2_type=time_total]
    const args = [_]u8{ 2, 0x01, 0x03 };
    cmds.initWasmModule(0, 0x1000, 1024);
    cmds.callWasmFunc(0, 0, 0x2000, 8, &args);
    cmds.writeBufferFromWasm(1, 0, 0, 64);
    cmds.end();

    const result = cmds.finish();
    const cmd_count = std.mem.readInt(u16, result[4..6], .little);

    // 3 WASM commands + 1 end command
    try std.testing.expectEqual(@as(u16, 4), cmd_count);
}
