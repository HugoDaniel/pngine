//! Flatten PNGB bytecode into a flat command buffer (pNGf format).
//!
//! Runs the dispatcher at compile time against MockGPU backend to capture
//! all GPU calls, then serializes them as flat command buffers with an
//! inline data section. The result can be embedded in a PNG as a pNGf chunk,
//! eliminating the need for WASM executor at runtime.
//!
//! ## pNGf Format
//!
//! ```
//! [version: u8]       = 1
//! [flags: u8]         = 0 (reserved)
//! [init_len: u32 LE]  Length of init commands
//! [frame_len: u32 LE] Length of frame commands
//! [data_len: u32 LE]  Length of data section
//! [init_cmds: bytes]  Resource creation commands (opcode + args, no header)
//! [frame_cmds: bytes] Per-frame commands (opcode + args, no header)
//! [data: bytes]       WGSL strings, JSON descriptors, bind group entries
//! ```
//!
//! ## Limitations
//!
//! - No ping-pong buffers (frame template is static)
//! - No animation timeline / frame switching
//! - No WASM-in-WASM plugins
//! - Only write_time_uniform as dynamic data source
//! - Single frame definition only
//!
//! ## Invariants
//!
//! - All data pointers in output reference the data section by offset
//! - Init commands include resource creation; frame commands include passes

const std = @import("std");
const pngine = @import("pngine");
const format = pngine.format;
const mock_gpu = pngine.mock_gpu;
const MockGPU = mock_gpu.MockGPU;
const Call = mock_gpu.Call;
const CallType = mock_gpu.CallType;
const Dispatcher = pngine.Dispatcher;
const Cmd = pngine.command_buffer.Cmd;

const PNGF_VERSION: u8 = 1;
const PNGF_HEADER_SIZE: usize = 14;

pub const FlattenError = error{
    InvalidBytecode,
    ExecutionFailed,
    OutOfMemory,
};

pub const FlatPayload = struct {
    data: []u8,

    pub fn deinit(self: *FlatPayload, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// Flatten PNGB bytecode into pNGf format.
///
/// Runs the dispatcher with MockGPU to capture all GPU calls, then
/// serializes them as command buffers with inline data.
pub fn flattenPayload(allocator: std.mem.Allocator, bytecode: []const u8) FlattenError!FlatPayload {
    if (bytecode.len < format.HEADER_SIZE or !std.mem.eql(u8, bytecode[0..4], format.MAGIC)) {
        return FlattenError.InvalidBytecode;
    }

    var module = format.deserialize(allocator, bytecode) catch {
        return FlattenError.InvalidBytecode;
    };
    defer module.deinit(allocator);

    // Execute bytecode with MockGPU to capture call sequence
    var gpu: MockGPU = .empty;
    defer gpu.deinit(allocator);

    var dispatcher = Dispatcher(MockGPU).init(allocator, &gpu, &module);
    defer dispatcher.deinit();
    dispatcher.execute_all(allocator) catch {
        return FlattenError.ExecutionFailed;
    };

    const calls = gpu.get_calls();

    // Find split point between init (resource creation) and frame (passes)
    var split_idx: usize = 0;
    for (calls, 0..) |call, i| {
        switch (call.call_type) {
            .create_buffer, .create_texture, .create_sampler, .create_shader_module, .create_render_pipeline, .create_compute_pipeline, .create_bind_group, .create_texture_view, .create_query_set, .create_bind_group_layout, .create_pipeline_layout, .create_image_bitmap, .create_render_bundle => {
                split_idx = i + 1;
            },
            else => break,
        }
    }

    // Build data section and serialize calls
    var data_section = std.ArrayListUnmanaged(u8){};
    defer data_section.deinit(allocator);

    var init_cmds = std.ArrayListUnmanaged(u8){};
    defer init_cmds.deinit(allocator);

    var frame_cmds = std.ArrayListUnmanaged(u8){};
    defer frame_cmds.deinit(allocator);

    // Map from data_id to data section offset
    var data_map = std.AutoHashMapUnmanaged(u16, u32){};
    defer data_map.deinit(allocator);

    // Serialize init calls
    for (calls[0..split_idx]) |call| {
        try serializeCall(allocator, &init_cmds, &data_section, &data_map, call, &module);
    }

    // Serialize frame calls
    for (calls[split_idx..]) |call| {
        try serializeCall(allocator, &frame_cmds, &data_section, &data_map, call, &module);
    }

    // Build output
    const total = PNGF_HEADER_SIZE + init_cmds.items.len + frame_cmds.items.len + data_section.items.len;
    const output = allocator.alloc(u8, total) catch return FlattenError.OutOfMemory;
    errdefer allocator.free(output);

    // Header
    output[0] = PNGF_VERSION;
    output[1] = 0;
    std.mem.writeInt(u32, output[2..6], @intCast(init_cmds.items.len), .little);
    std.mem.writeInt(u32, output[6..10], @intCast(frame_cmds.items.len), .little);
    std.mem.writeInt(u32, output[10..14], @intCast(data_section.items.len), .little);

    // Copy sections
    var pos: usize = PNGF_HEADER_SIZE;
    @memcpy(output[pos..][0..init_cmds.items.len], init_cmds.items);
    pos += init_cmds.items.len;
    @memcpy(output[pos..][0..frame_cmds.items.len], frame_cmds.items);
    pos += frame_cmds.items.len;
    @memcpy(output[pos..][0..data_section.items.len], data_section.items);

    std.debug.assert(pos + data_section.items.len == total);

    return FlatPayload{ .data = output };
}

/// Resolve a data_id to its offset in the data section, adding it if needed.
fn resolveData(
    allocator: std.mem.Allocator,
    data_section: *std.ArrayListUnmanaged(u8),
    data_map: *std.AutoHashMapUnmanaged(u16, u32),
    data_id: u16,
    module: *const format.Module,
) !u32 {
    if (data_map.get(data_id)) |offset| return offset;

    const data = module.data.get(@enumFromInt(data_id));
    const offset: u32 = @intCast(data_section.items.len);
    try data_map.put(allocator, data_id, offset);
    try data_section.appendSlice(allocator, data);
    return offset;
}

/// Resolve WGSL data (with imports) to its offset in the data section.
/// Uses two map keys per WGSL: offset at (wgsl_id | 0x8000), length at (wgsl_id | 0xC000).
fn resolveWgsl(
    allocator: std.mem.Allocator,
    data_section: *std.ArrayListUnmanaged(u8),
    data_map: *std.AutoHashMapUnmanaged(u16, u32),
    wgsl_id: u16,
    module: *const format.Module,
) !struct { offset: u32, len: u32 } {
    const offset_key: u16 = wgsl_id | 0x8000;
    const len_key: u16 = wgsl_id | 0xC000;
    if (data_map.get(offset_key)) |offset| {
        return .{ .offset = offset, .len = data_map.get(len_key) orelse 0 };
    }

    const wgsl_table = &module.wgsl;

    // Track included modules and order (iterative DFS)
    var included = std.AutoHashMapUnmanaged(u16, void){};
    defer included.deinit(allocator);
    var order = std.ArrayListUnmanaged(u16){};
    defer order.deinit(allocator);
    var stack = std.ArrayListUnmanaged(u16){};
    defer stack.deinit(allocator);

    try stack.append(allocator, wgsl_id);

    for (0..1024) |_| {
        if (stack.items.len == 0) break;
        const current = stack.pop() orelse break;
        if (included.contains(current)) continue;

        const entry = wgsl_table.get(current) orelse continue;

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

    // Write concatenated WGSL to data section
    const offset: u32 = @intCast(data_section.items.len);
    for (order.items) |id| {
        if (wgsl_table.get(id)) |entry| {
            const data = module.data.get(@enumFromInt(entry.data_id));
            try data_section.appendSlice(allocator, data);
        }
    }

    try data_map.put(allocator, offset_key, offset);
    try data_map.put(allocator, len_key, @intCast(total_size));
    return .{ .offset = offset, .len = @intCast(total_size) };
}

/// Serialize a MockGPU call to command buffer format.
fn serializeCall(
    allocator: std.mem.Allocator,
    cmds: *std.ArrayListUnmanaged(u8),
    data_section: *std.ArrayListUnmanaged(u8),
    data_map: *std.AutoHashMapUnmanaged(u16, u32),
    call: Call,
    module: *const format.Module,
) !void {
    switch (call.call_type) {
        .create_buffer => {
            const p = call.params.create_buffer;
            try cmds.append(allocator, @intFromEnum(Cmd.create_buffer));
            try appendU16(allocator, cmds, p.buffer_id);
            try appendU32(allocator, cmds, p.size);
            try cmds.append(allocator, p.usage);
        },
        .create_shader_module => {
            const p = call.params.create_shader_module;
            const wgsl = try resolveWgsl(allocator, data_section, data_map, p.code_data_id, module);
            try cmds.append(allocator, @intFromEnum(Cmd.create_shader));
            try appendU16(allocator, cmds, p.shader_id);
            try appendU32(allocator, cmds, wgsl.offset);
            try appendU32(allocator, cmds, wgsl.len);
        },
        .create_render_pipeline => {
            const p = call.params.create_render_pipeline;
            const offset = try resolveData(allocator, data_section, data_map, p.descriptor_data_id, module);
            const data = module.data.get(@enumFromInt(p.descriptor_data_id));
            try cmds.append(allocator, @intFromEnum(Cmd.create_render_pipeline));
            try appendU16(allocator, cmds, p.pipeline_id);
            try appendU32(allocator, cmds, offset);
            try appendU32(allocator, cmds, @intCast(data.len));
        },
        .create_compute_pipeline => {
            const p = call.params.create_compute_pipeline;
            const offset = try resolveData(allocator, data_section, data_map, p.descriptor_data_id, module);
            const data = module.data.get(@enumFromInt(p.descriptor_data_id));
            try cmds.append(allocator, @intFromEnum(Cmd.create_compute_pipeline));
            try appendU16(allocator, cmds, p.pipeline_id);
            try appendU32(allocator, cmds, offset);
            try appendU32(allocator, cmds, @intCast(data.len));
        },
        .create_bind_group => {
            const p = call.params.create_bind_group;
            const offset = try resolveData(allocator, data_section, data_map, p.entry_data_id, module);
            const data = module.data.get(@enumFromInt(p.entry_data_id));
            try cmds.append(allocator, @intFromEnum(Cmd.create_bind_group));
            try appendU16(allocator, cmds, p.group_id);
            try appendU16(allocator, cmds, p.layout_id);
            try appendU32(allocator, cmds, offset);
            try appendU32(allocator, cmds, @intCast(data.len));
        },
        .create_texture => {
            const p = call.params.create_texture;
            const offset = try resolveData(allocator, data_section, data_map, p.descriptor_data_id, module);
            const data = module.data.get(@enumFromInt(p.descriptor_data_id));
            try cmds.append(allocator, @intFromEnum(Cmd.create_texture));
            try appendU16(allocator, cmds, p.texture_id);
            try appendU32(allocator, cmds, offset);
            try appendU32(allocator, cmds, @intCast(data.len));
        },
        .create_sampler => {
            const p = call.params.create_sampler;
            const offset = try resolveData(allocator, data_section, data_map, p.descriptor_data_id, module);
            const data = module.data.get(@enumFromInt(p.descriptor_data_id));
            try cmds.append(allocator, @intFromEnum(Cmd.create_sampler));
            try appendU16(allocator, cmds, p.sampler_id);
            try appendU32(allocator, cmds, offset);
            try appendU32(allocator, cmds, @intCast(data.len));
        },
        .create_texture_view => {
            const p = call.params.create_texture_view;
            try cmds.append(allocator, @intFromEnum(Cmd.create_texture_view));
            try appendU16(allocator, cmds, p.view_id);
            try appendU16(allocator, cmds, p.texture_id);
            // Texture views may not have descriptor data
            try appendU32(allocator, cmds, 0);
            try appendU32(allocator, cmds, 0);
        },
        .begin_render_pass => {
            const p = call.params.begin_render_pass;
            try cmds.append(allocator, @intFromEnum(Cmd.begin_render_pass));
            try appendU16(allocator, cmds, p.color_texture_id);
            try cmds.append(allocator, p.load_op);
            try cmds.append(allocator, p.store_op);
            try appendU16(allocator, cmds, p.depth_texture_id);
        },
        .begin_compute_pass => {
            try cmds.append(allocator, @intFromEnum(Cmd.begin_compute_pass));
        },
        .set_pipeline => {
            const p = call.params.set_pipeline;
            try cmds.append(allocator, @intFromEnum(Cmd.set_pipeline));
            try appendU16(allocator, cmds, p.pipeline_id);
        },
        .set_bind_group => {
            const p = call.params.set_bind_group;
            try cmds.append(allocator, @intFromEnum(Cmd.set_bind_group));
            try cmds.append(allocator, p.slot);
            try appendU16(allocator, cmds, p.group_id);
        },
        .set_vertex_buffer => {
            const p = call.params.set_vertex_buffer;
            try cmds.append(allocator, @intFromEnum(Cmd.set_vertex_buffer));
            try cmds.append(allocator, p.slot);
            try appendU16(allocator, cmds, p.buffer_id);
        },
        .set_index_buffer => {
            const p = call.params.set_index_buffer;
            try cmds.append(allocator, @intFromEnum(Cmd.set_index_buffer));
            try appendU16(allocator, cmds, p.buffer_id);
            try cmds.append(allocator, p.index_format);
        },
        .draw => {
            const p = call.params.draw;
            try cmds.append(allocator, @intFromEnum(Cmd.draw));
            try appendU32(allocator, cmds, p.vertex_count);
            try appendU32(allocator, cmds, p.instance_count);
            try appendU32(allocator, cmds, p.first_vertex);
            try appendU32(allocator, cmds, p.first_instance);
        },
        .draw_indexed => {
            const p = call.params.draw_indexed;
            try cmds.append(allocator, @intFromEnum(Cmd.draw_indexed));
            try appendU32(allocator, cmds, p.index_count);
            try appendU32(allocator, cmds, p.instance_count);
            try appendU32(allocator, cmds, p.first_index);
            try appendU32(allocator, cmds, p.base_vertex);
            try appendU32(allocator, cmds, p.first_instance);
        },
        .dispatch => {
            const p = call.params.dispatch;
            try cmds.append(allocator, @intFromEnum(Cmd.dispatch));
            try appendU32(allocator, cmds, p.x);
            try appendU32(allocator, cmds, p.y);
            try appendU32(allocator, cmds, p.z);
        },
        .end_pass => {
            try cmds.append(allocator, @intFromEnum(Cmd.end_pass));
        },
        .write_buffer => {
            const p = call.params.write_buffer;
            // write_time_uniform is a special case (data_id == 0xFFFF means runtime data)
            // For flat mode, we emit write_time_uniform for any write_buffer to the uniform buffer
            // The MockGPU records this as write_buffer; detect by checking data_id pattern
            try cmds.append(allocator, @intFromEnum(Cmd.write_time_uniform));
            try appendU16(allocator, cmds, p.buffer_id);
            try appendU32(allocator, cmds, p.offset);
            try appendU16(allocator, cmds, 16); // pngineInputs = 16 bytes
        },
        .submit => {
            try cmds.append(allocator, @intFromEnum(Cmd.submit));
        },
        // Unsupported in flat mode - skip silently
        .create_query_set, .create_bind_group_layout, .create_pipeline_layout, .create_image_bitmap, .create_render_bundle, .execute_bundles, .copy_external_image_to_texture, .init_wasm_module, .call_wasm_func, .write_buffer_from_wasm => {},
    }
}

fn appendU16(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, value, .little);
    try list.appendSlice(allocator, &buf);
}

fn appendU32(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try list.appendSlice(allocator, &buf);
}
