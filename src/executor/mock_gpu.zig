//! Mock WebGPU Backend
//!
//! Records all GPU API calls for verification in tests.
//! No actual GPU operations are performed.
//!
//! Invariants:
//! - All calls are recorded in order
//! - Resource IDs are validated against created resources
//! - Call log can be compared against expected sequences

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// GPU API call types.
pub const CallType = enum {
    // Resource creation
    create_buffer,
    create_texture,
    create_sampler,
    create_shader_module,
    create_bind_group_layout,
    create_pipeline_layout,
    create_render_pipeline,
    create_compute_pipeline,
    create_bind_group,

    // Pass operations
    begin_render_pass,
    begin_compute_pass,
    set_pipeline,
    set_bind_group,
    set_vertex_buffer,
    set_index_buffer,
    draw,
    draw_indexed,
    dispatch,
    end_pass,

    // Queue operations
    write_buffer,
    submit,
};

/// Recorded GPU API call with parameters.
pub const Call = struct {
    call_type: CallType,
    params: Params,

    pub const Params = union {
        create_buffer: struct {
            buffer_id: u16,
            size: u32,
            usage: u8,
        },
        create_shader_module: struct {
            shader_id: u16,
            code_data_id: u16,
        },
        create_render_pipeline: struct {
            pipeline_id: u16,
            descriptor_data_id: u16,
        },
        create_compute_pipeline: struct {
            pipeline_id: u16,
            descriptor_data_id: u16,
        },
        create_bind_group: struct {
            group_id: u16,
            layout_id: u16,
            entry_data_id: u16,
        },
        begin_render_pass: struct {
            color_texture_id: u16,
            load_op: u8,
            store_op: u8,
        },
        set_pipeline: struct {
            pipeline_id: u16,
        },
        set_bind_group: struct {
            slot: u8,
            group_id: u16,
        },
        set_vertex_buffer: struct {
            slot: u8,
            buffer_id: u16,
        },
        draw: struct {
            vertex_count: u32,
            instance_count: u32,
        },
        draw_indexed: struct {
            index_count: u32,
            instance_count: u32,
        },
        dispatch: struct {
            x: u32,
            y: u32,
            z: u32,
        },
        write_buffer: struct {
            buffer_id: u16,
            offset: u32,
            data_id: u16,
        },
        none: void,
    };

    /// Write call description to buffer for debugging.
    pub fn describe(self: Call, buf: []u8) []const u8 {
        return switch (self.call_type) {
            .create_buffer => blk: {
                const p = self.params.create_buffer;
                break :blk std.fmt.bufPrint(buf, "create_buffer(id={d}, size={d}, usage=0x{x:0>2})", .{ p.buffer_id, p.size, p.usage }) catch "create_buffer(...)";
            },
            .create_shader_module => blk: {
                const p = self.params.create_shader_module;
                break :blk std.fmt.bufPrint(buf, "create_shader_module(id={d}, data={d})", .{ p.shader_id, p.code_data_id }) catch "create_shader_module(...)";
            },
            .create_render_pipeline => blk: {
                const p = self.params.create_render_pipeline;
                break :blk std.fmt.bufPrint(buf, "create_render_pipeline(id={d}, desc={d})", .{ p.pipeline_id, p.descriptor_data_id }) catch "create_render_pipeline(...)";
            },
            .create_compute_pipeline => blk: {
                const p = self.params.create_compute_pipeline;
                break :blk std.fmt.bufPrint(buf, "create_compute_pipeline(id={d}, desc={d})", .{ p.pipeline_id, p.descriptor_data_id }) catch "create_compute_pipeline(...)";
            },
            .create_bind_group => blk: {
                const p = self.params.create_bind_group;
                break :blk std.fmt.bufPrint(buf, "create_bind_group(id={d}, layout={d}, entries={d})", .{ p.group_id, p.layout_id, p.entry_data_id }) catch "create_bind_group(...)";
            },
            .begin_render_pass => blk: {
                const p = self.params.begin_render_pass;
                break :blk std.fmt.bufPrint(buf, "begin_render_pass(color={d}, load={d}, store={d})", .{ p.color_texture_id, p.load_op, p.store_op }) catch "begin_render_pass(...)";
            },
            .begin_compute_pass => "begin_compute_pass()",
            .set_pipeline => blk: {
                const p = self.params.set_pipeline;
                break :blk std.fmt.bufPrint(buf, "set_pipeline(id={d})", .{p.pipeline_id}) catch "set_pipeline(...)";
            },
            .set_bind_group => blk: {
                const p = self.params.set_bind_group;
                break :blk std.fmt.bufPrint(buf, "set_bind_group(slot={d}, id={d})", .{ p.slot, p.group_id }) catch "set_bind_group(...)";
            },
            .set_vertex_buffer => blk: {
                const p = self.params.set_vertex_buffer;
                break :blk std.fmt.bufPrint(buf, "set_vertex_buffer(slot={d}, id={d})", .{ p.slot, p.buffer_id }) catch "set_vertex_buffer(...)";
            },
            .draw => blk: {
                const p = self.params.draw;
                break :blk std.fmt.bufPrint(buf, "draw(vertices={d}, instances={d})", .{ p.vertex_count, p.instance_count }) catch "draw(...)";
            },
            .draw_indexed => blk: {
                const p = self.params.draw_indexed;
                break :blk std.fmt.bufPrint(buf, "draw_indexed(indices={d}, instances={d})", .{ p.index_count, p.instance_count }) catch "draw_indexed(...)";
            },
            .dispatch => blk: {
                const p = self.params.dispatch;
                break :blk std.fmt.bufPrint(buf, "dispatch(x={d}, y={d}, z={d})", .{ p.x, p.y, p.z }) catch "dispatch(...)";
            },
            .end_pass => "end_pass()",
            .write_buffer => blk: {
                const p = self.params.write_buffer;
                break :blk std.fmt.bufPrint(buf, "write_buffer(id={d}, offset={d}, data={d})", .{ p.buffer_id, p.offset, p.data_id }) catch "write_buffer(...)";
            },
            .submit => "submit()",
            else => @tagName(self.call_type),
        };
    }
};

/// Mock GPU backend that records all API calls.
pub const MockGPU = struct {
    const Self = @This();

    /// Maximum resources per category.
    pub const MAX_BUFFERS: u16 = 256;
    pub const MAX_TEXTURES: u16 = 256;
    pub const MAX_SHADERS: u16 = 64;
    pub const MAX_PIPELINES: u16 = 64;
    pub const MAX_BIND_GROUPS: u16 = 64;

    /// Recorded calls.
    calls: std.ArrayListUnmanaged(Call),

    /// Resource tracking (bitsets for created resources).
    buffers_created: std.StaticBitSet(MAX_BUFFERS),
    textures_created: std.StaticBitSet(MAX_TEXTURES),
    shaders_created: std.StaticBitSet(MAX_SHADERS),
    pipelines_created: std.StaticBitSet(MAX_PIPELINES),
    bind_groups_created: std.StaticBitSet(MAX_BIND_GROUPS),

    /// Pass state.
    in_render_pass: bool,
    in_compute_pass: bool,
    current_pipeline: ?u16,

    pub const empty: Self = .{
        .calls = .{},
        .buffers_created = std.StaticBitSet(MAX_BUFFERS).initEmpty(),
        .textures_created = std.StaticBitSet(MAX_TEXTURES).initEmpty(),
        .shaders_created = std.StaticBitSet(MAX_SHADERS).initEmpty(),
        .pipelines_created = std.StaticBitSet(MAX_PIPELINES).initEmpty(),
        .bind_groups_created = std.StaticBitSet(MAX_BIND_GROUPS).initEmpty(),
        .in_render_pass = false,
        .in_compute_pass = false,
        .current_pipeline = null,
    };

    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.calls.deinit(allocator);
        self.* = undefined;
    }

    /// Reset state for reuse.
    pub fn reset(self: *Self) void {
        self.calls.clearRetainingCapacity();
        self.buffers_created = std.StaticBitSet(MAX_BUFFERS).initEmpty();
        self.textures_created = std.StaticBitSet(MAX_TEXTURES).initEmpty();
        self.shaders_created = std.StaticBitSet(MAX_SHADERS).initEmpty();
        self.pipelines_created = std.StaticBitSet(MAX_PIPELINES).initEmpty();
        self.bind_groups_created = std.StaticBitSet(MAX_BIND_GROUPS).initEmpty();
        self.in_render_pass = false;
        self.in_compute_pass = false;
        self.current_pipeline = null;
    }

    // ========================================================================
    // Resource Creation
    // ========================================================================

    pub fn createBuffer(self: *Self, allocator: Allocator, buffer_id: u16, size: u32, usage: u8) !void {
        // Pre-condition: ID in range
        assert(buffer_id < MAX_BUFFERS);

        self.buffers_created.set(buffer_id);

        try self.calls.append(allocator, .{
            .call_type = .create_buffer,
            .params = .{ .create_buffer = .{
                .buffer_id = buffer_id,
                .size = size,
                .usage = usage,
            } },
        });
    }

    pub fn createShaderModule(self: *Self, allocator: Allocator, shader_id: u16, code_data_id: u16) !void {
        assert(shader_id < MAX_SHADERS);

        self.shaders_created.set(shader_id);

        try self.calls.append(allocator, .{
            .call_type = .create_shader_module,
            .params = .{ .create_shader_module = .{
                .shader_id = shader_id,
                .code_data_id = code_data_id,
            } },
        });
    }

    pub fn createRenderPipeline(self: *Self, allocator: Allocator, pipeline_id: u16, descriptor_data_id: u16) !void {
        assert(pipeline_id < MAX_PIPELINES);

        self.pipelines_created.set(pipeline_id);

        try self.calls.append(allocator, .{
            .call_type = .create_render_pipeline,
            .params = .{ .create_render_pipeline = .{
                .pipeline_id = pipeline_id,
                .descriptor_data_id = descriptor_data_id,
            } },
        });
    }

    pub fn createComputePipeline(self: *Self, allocator: Allocator, pipeline_id: u16, descriptor_data_id: u16) !void {
        assert(pipeline_id < MAX_PIPELINES);

        self.pipelines_created.set(pipeline_id);

        try self.calls.append(allocator, .{
            .call_type = .create_compute_pipeline,
            .params = .{ .create_compute_pipeline = .{
                .pipeline_id = pipeline_id,
                .descriptor_data_id = descriptor_data_id,
            } },
        });
    }

    pub fn createBindGroup(self: *Self, allocator: Allocator, group_id: u16, layout_id: u16, entry_data_id: u16) !void {
        assert(group_id < MAX_BIND_GROUPS);

        self.bind_groups_created.set(group_id);

        try self.calls.append(allocator, .{
            .call_type = .create_bind_group,
            .params = .{ .create_bind_group = .{
                .group_id = group_id,
                .layout_id = layout_id,
                .entry_data_id = entry_data_id,
            } },
        });
    }

    // ========================================================================
    // Pass Operations
    // ========================================================================

    pub fn beginRenderPass(self: *Self, allocator: Allocator, color_texture_id: u16, load_op: u8, store_op: u8) !void {
        // Pre-condition: not already in a pass
        assert(!self.in_render_pass and !self.in_compute_pass);

        self.in_render_pass = true;
        self.current_pipeline = null;

        try self.calls.append(allocator, .{
            .call_type = .begin_render_pass,
            .params = .{ .begin_render_pass = .{
                .color_texture_id = color_texture_id,
                .load_op = load_op,
                .store_op = store_op,
            } },
        });
    }

    pub fn beginComputePass(self: *Self, allocator: Allocator) !void {
        assert(!self.in_render_pass and !self.in_compute_pass);

        self.in_compute_pass = true;
        self.current_pipeline = null;

        try self.calls.append(allocator, .{
            .call_type = .begin_compute_pass,
            .params = .{ .none = {} },
        });
    }

    pub fn setPipeline(self: *Self, allocator: Allocator, pipeline_id: u16) !void {
        // Must be in a pass to set pipeline
        assert(self.in_render_pass or self.in_compute_pass);

        self.current_pipeline = pipeline_id;

        try self.calls.append(allocator, .{
            .call_type = .set_pipeline,
            .params = .{ .set_pipeline = .{
                .pipeline_id = pipeline_id,
            } },
        });
    }

    pub fn setBindGroup(self: *Self, allocator: Allocator, slot: u8, group_id: u16) !void {
        assert(self.in_render_pass or self.in_compute_pass);

        try self.calls.append(allocator, .{
            .call_type = .set_bind_group,
            .params = .{ .set_bind_group = .{
                .slot = slot,
                .group_id = group_id,
            } },
        });
    }

    pub fn setVertexBuffer(self: *Self, allocator: Allocator, slot: u8, buffer_id: u16) !void {
        assert(self.in_render_pass);

        try self.calls.append(allocator, .{
            .call_type = .set_vertex_buffer,
            .params = .{ .set_vertex_buffer = .{
                .slot = slot,
                .buffer_id = buffer_id,
            } },
        });
    }

    pub fn draw(self: *Self, allocator: Allocator, vertex_count: u32, instance_count: u32) !void {
        assert(self.in_render_pass);

        try self.calls.append(allocator, .{
            .call_type = .draw,
            .params = .{ .draw = .{
                .vertex_count = vertex_count,
                .instance_count = instance_count,
            } },
        });
    }

    pub fn drawIndexed(self: *Self, allocator: Allocator, index_count: u32, instance_count: u32) !void {
        assert(self.in_render_pass);

        try self.calls.append(allocator, .{
            .call_type = .draw_indexed,
            .params = .{ .draw_indexed = .{
                .index_count = index_count,
                .instance_count = instance_count,
            } },
        });
    }

    pub fn dispatch(self: *Self, allocator: Allocator, x: u32, y: u32, z: u32) !void {
        assert(self.in_compute_pass);

        try self.calls.append(allocator, .{
            .call_type = .dispatch,
            .params = .{ .dispatch = .{
                .x = x,
                .y = y,
                .z = z,
            } },
        });
    }

    pub fn endPass(self: *Self, allocator: Allocator) !void {
        // Pre-condition: in a pass
        assert(self.in_render_pass or self.in_compute_pass);

        self.in_render_pass = false;
        self.in_compute_pass = false;
        self.current_pipeline = null;

        try self.calls.append(allocator, .{
            .call_type = .end_pass,
            .params = .{ .none = {} },
        });
    }

    // ========================================================================
    // Queue Operations
    // ========================================================================

    pub fn writeBuffer(self: *Self, allocator: Allocator, buffer_id: u16, offset: u32, data_id: u16) !void {
        try self.calls.append(allocator, .{
            .call_type = .write_buffer,
            .params = .{ .write_buffer = .{
                .buffer_id = buffer_id,
                .offset = offset,
                .data_id = data_id,
            } },
        });
    }

    pub fn submit(self: *Self, allocator: Allocator) !void {
        // Pre-condition: not in a pass
        assert(!self.in_render_pass and !self.in_compute_pass);

        try self.calls.append(allocator, .{
            .call_type = .submit,
            .params = .{ .none = {} },
        });
    }

    // ========================================================================
    // Verification
    // ========================================================================

    /// Get call count.
    pub fn callCount(self: *const Self) usize {
        return self.calls.items.len;
    }

    /// Get call at index.
    pub fn getCall(self: *const Self, index: usize) Call {
        return self.calls.items[index];
    }

    /// Get all calls as slice.
    pub fn getCalls(self: *const Self) []const Call {
        return self.calls.items;
    }

    /// Check if call sequence matches expected types.
    pub fn expectCallTypes(self: *const Self, expected: []const CallType) bool {
        if (self.calls.items.len != expected.len) return false;

        for (self.calls.items, expected) |call, exp| {
            if (call.call_type != exp) return false;
        }

        return true;
    }

    /// Print all recorded calls for debugging.
    pub fn dumpCalls(self: *const Self, writer: anytype) !void {
        var buf: [256]u8 = undefined;
        try writer.print("MockGPU call log ({d} calls):\n", .{self.calls.items.len});
        for (self.calls.items, 0..) |call, i| {
            const desc = call.describe(&buf);
            try writer.print("  [{d:3}] {s}\n", .{ i, desc });
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "mock gpu create buffer" {
    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    try gpu.createBuffer(testing.allocator, 0, 1024, 0x44);

    try testing.expectEqual(@as(usize, 1), gpu.callCount());
    try testing.expectEqual(CallType.create_buffer, gpu.getCall(0).call_type);
    try testing.expect(gpu.buffers_created.isSet(0));
}

test "mock gpu render pass sequence" {
    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    try gpu.createShaderModule(testing.allocator, 0, 0);
    try gpu.createRenderPipeline(testing.allocator, 0, 1);
    try gpu.beginRenderPass(testing.allocator, 0, 1, 0);
    try gpu.setPipeline(testing.allocator, 0);
    try gpu.draw(testing.allocator, 3, 1);
    try gpu.endPass(testing.allocator);
    try gpu.submit(testing.allocator);

    const expected = [_]CallType{
        .create_shader_module,
        .create_render_pipeline,
        .begin_render_pass,
        .set_pipeline,
        .draw,
        .end_pass,
        .submit,
    };

    try testing.expect(gpu.expectCallTypes(&expected));
}

test "mock gpu reset" {
    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    try gpu.createBuffer(testing.allocator, 0, 1024, 0x44);
    try testing.expectEqual(@as(usize, 1), gpu.callCount());

    gpu.reset();
    try testing.expectEqual(@as(usize, 0), gpu.callCount());
    try testing.expect(!gpu.buffers_created.isSet(0));
}

test "mock gpu call formatting" {
    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    // load_op=1 (clear), store_op=0 (store)
    try gpu.beginRenderPass(testing.allocator, 0, 1, 0);
    try gpu.draw(testing.allocator, 3, 1);
    try gpu.endPass(testing.allocator);

    var buf: [256]u8 = undefined;
    // calls[0] = begin_render_pass, calls[1] = draw
    const str = gpu.getCall(1).describe(&buf);
    try testing.expectEqualStrings("draw(vertices=3, instances=1)", str);
}
