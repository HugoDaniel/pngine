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
    create_texture_view,
    create_query_set,
    create_bind_group_layout,
    create_pipeline_layout,
    create_render_pipeline,
    create_compute_pipeline,
    create_bind_group,
    create_image_bitmap,

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
    execute_bundles,
    end_pass,
    create_render_bundle,

    // Queue operations
    write_buffer,
    submit,
    copy_external_image_to_texture,

    // WASM operations
    init_wasm_module,
    call_wasm_func,
    write_buffer_from_wasm,
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
        create_texture: struct {
            texture_id: u16,
            descriptor_data_id: u16,
        },
        create_sampler: struct {
            sampler_id: u16,
            descriptor_data_id: u16,
        },
        create_texture_view: struct {
            view_id: u16,
            texture_id: u16,
            descriptor_data_id: u16,
        },
        create_query_set: struct {
            query_set_id: u16,
            descriptor_data_id: u16,
        },
        create_bind_group_layout: struct {
            layout_id: u16,
            descriptor_data_id: u16,
        },
        create_pipeline_layout: struct {
            layout_id: u16,
            descriptor_data_id: u16,
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
            depth_texture_id: u16,
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
        set_index_buffer: struct {
            buffer_id: u16,
            index_format: u8,
        },
        draw: struct {
            vertex_count: u32,
            instance_count: u32,
            first_vertex: u32,
            first_instance: u32,
        },
        draw_indexed: struct {
            index_count: u32,
            instance_count: u32,
            first_index: u32,
            base_vertex: u32,
            first_instance: u32,
        },
        dispatch: struct {
            x: u32,
            y: u32,
            z: u32,
        },
        execute_bundles: struct {
            bundle_count: u16,
        },
        create_render_bundle: struct {
            bundle_id: u16,
            descriptor_data_id: u16,
        },
        write_buffer: struct {
            buffer_id: u16,
            offset: u32,
            data_id: u16,
        },
        create_image_bitmap: struct {
            bitmap_id: u16,
            blob_data_id: u16,
        },
        copy_external_image_to_texture: struct {
            bitmap_id: u16,
            texture_id: u16,
            mip_level: u8,
            origin_x: u16,
            origin_y: u16,
        },
        init_wasm_module: struct {
            module_id: u16,
            wasm_data_id: u16,
        },
        call_wasm_func: struct {
            call_id: u16,
            module_id: u16,
            func_name_id: u16,
        },
        write_buffer_from_wasm: struct {
            call_id: u16,
            buffer_id: u16,
            offset: u32,
            byte_len: u32,
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
            .create_texture => blk: {
                const p = self.params.create_texture;
                break :blk std.fmt.bufPrint(buf, "create_texture(id={d}, desc={d})", .{ p.texture_id, p.descriptor_data_id }) catch "create_texture(...)";
            },
            .create_sampler => blk: {
                const p = self.params.create_sampler;
                break :blk std.fmt.bufPrint(buf, "create_sampler(id={d}, desc={d})", .{ p.sampler_id, p.descriptor_data_id }) catch "create_sampler(...)";
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

    /// Record texture creation.
    /// Tracks texture ID in bitset for resource validation.
    pub fn createTexture(self: *Self, allocator: Allocator, texture_id: u16, descriptor_data_id: u16) !void {
        // Pre-conditions
        assert(texture_id < MAX_TEXTURES);
        assert(!self.textures_created.isSet(texture_id)); // No duplicate IDs

        self.textures_created.set(texture_id);

        try self.calls.append(allocator, .{
            .call_type = .create_texture,
            .params = .{ .create_texture = .{
                .texture_id = texture_id,
                .descriptor_data_id = descriptor_data_id,
            } },
        });
    }

    /// Record sampler creation.
    /// Samplers are not tracked in bitset (typically few per pipeline).
    pub fn createSampler(self: *Self, allocator: Allocator, sampler_id: u16, descriptor_data_id: u16) !void {
        // Pre-conditions
        assert(sampler_id < MAX_TEXTURES); // Use MAX_TEXTURES as reasonable upper bound
        assert(self.calls.items.len < 10000); // Sanity check: not in runaway loop

        try self.calls.append(allocator, .{
            .call_type = .create_sampler,
            .params = .{ .create_sampler = .{
                .sampler_id = sampler_id,
                .descriptor_data_id = descriptor_data_id,
            } },
        });
    }

    /// Record texture view creation.
    pub fn createTextureView(self: *Self, allocator: Allocator, view_id: u16, texture_id: u16, descriptor_data_id: u16) !void {
        assert(view_id < MAX_TEXTURES);
        assert(self.calls.items.len < 10000);

        try self.calls.append(allocator, .{
            .call_type = .create_texture_view,
            .params = .{ .create_texture_view = .{
                .view_id = view_id,
                .texture_id = texture_id,
                .descriptor_data_id = descriptor_data_id,
            } },
        });
    }

    /// Record query set creation.
    pub fn createQuerySet(self: *Self, allocator: Allocator, query_set_id: u16, descriptor_data_id: u16) !void {
        assert(query_set_id < MAX_BUFFERS);
        assert(self.calls.items.len < 10000);

        try self.calls.append(allocator, .{
            .call_type = .create_query_set,
            .params = .{ .create_query_set = .{
                .query_set_id = query_set_id,
                .descriptor_data_id = descriptor_data_id,
            } },
        });
    }

    /// Record bind group layout creation.
    pub fn createBindGroupLayout(self: *Self, allocator: Allocator, layout_id: u16, descriptor_data_id: u16) !void {
        assert(layout_id < MAX_BIND_GROUPS);
        assert(self.calls.items.len < 10000);

        try self.calls.append(allocator, .{
            .call_type = .create_bind_group_layout,
            .params = .{ .create_bind_group_layout = .{
                .layout_id = layout_id,
                .descriptor_data_id = descriptor_data_id,
            } },
        });
    }

    /// Record pipeline layout creation.
    pub fn createPipelineLayout(self: *Self, allocator: Allocator, layout_id: u16, descriptor_data_id: u16) !void {
        assert(layout_id < MAX_PIPELINES);
        assert(self.calls.items.len < 10000);

        try self.calls.append(allocator, .{
            .call_type = .create_pipeline_layout,
            .params = .{ .create_pipeline_layout = .{
                .layout_id = layout_id,
                .descriptor_data_id = descriptor_data_id,
            } },
        });
    }

    /// Record render bundle creation.
    pub fn createRenderBundle(self: *Self, allocator: Allocator, bundle_id: u16, descriptor_data_id: u16) !void {
        assert(bundle_id < MAX_PIPELINES);
        assert(self.calls.items.len < 10000);

        try self.calls.append(allocator, .{
            .call_type = .create_render_bundle,
            .params = .{ .create_render_bundle = .{
                .bundle_id = bundle_id,
                .descriptor_data_id = descriptor_data_id,
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

    pub fn beginRenderPass(self: *Self, allocator: Allocator, color_texture_id: u16, load_op: u8, store_op: u8, depth_texture_id: u16) !void {
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
                .depth_texture_id = depth_texture_id,
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

    pub fn setIndexBuffer(self: *Self, allocator: Allocator, buffer_id: u16, index_format: u8) !void {
        assert(self.in_render_pass);

        try self.calls.append(allocator, .{
            .call_type = .set_index_buffer,
            .params = .{ .set_index_buffer = .{
                .buffer_id = buffer_id,
                .index_format = index_format,
            } },
        });
    }

    pub fn draw(
        self: *Self,
        allocator: Allocator,
        vertex_count: u32,
        instance_count: u32,
        first_vertex: u32,
        first_instance: u32,
    ) !void {
        assert(self.in_render_pass);

        try self.calls.append(allocator, .{
            .call_type = .draw,
            .params = .{ .draw = .{
                .vertex_count = vertex_count,
                .instance_count = instance_count,
                .first_vertex = first_vertex,
                .first_instance = first_instance,
            } },
        });
    }

    pub fn drawIndexed(
        self: *Self,
        allocator: Allocator,
        index_count: u32,
        instance_count: u32,
        first_index: u32,
        base_vertex: u32,
        first_instance: u32,
    ) !void {
        assert(self.in_render_pass);

        try self.calls.append(allocator, .{
            .call_type = .draw_indexed,
            .params = .{ .draw_indexed = .{
                .index_count = index_count,
                .instance_count = instance_count,
                .first_index = first_index,
                .base_vertex = base_vertex,
                .first_instance = first_instance,
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

    /// Execute pre-recorded render bundles.
    pub fn executeBundles(self: *Self, allocator: Allocator, bundle_ids: []const u16) !void {
        assert(self.in_render_pass);

        try self.calls.append(allocator, .{
            .call_type = .execute_bundles,
            .params = .{ .execute_bundles = .{
                .bundle_count = @intCast(bundle_ids.len),
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

    pub fn createImageBitmap(self: *Self, allocator: Allocator, bitmap_id: u16, blob_data_id: u16) !void {
        try self.calls.append(allocator, .{
            .call_type = .create_image_bitmap,
            .params = .{ .create_image_bitmap = .{
                .bitmap_id = bitmap_id,
                .blob_data_id = blob_data_id,
            } },
        });
    }

    pub fn copyExternalImageToTexture(self: *Self, allocator: Allocator, bitmap_id: u16, texture_id: u16, mip_level: u8, origin_x: u16, origin_y: u16) !void {
        try self.calls.append(allocator, .{
            .call_type = .copy_external_image_to_texture,
            .params = .{ .copy_external_image_to_texture = .{
                .bitmap_id = bitmap_id,
                .texture_id = texture_id,
                .mip_level = mip_level,
                .origin_x = origin_x,
                .origin_y = origin_y,
            } },
        });
    }

    // ========================================================================
    // WASM Operations
    // ========================================================================

    pub fn initWasmModule(self: *Self, allocator: Allocator, module_id: u16, wasm_data_id: u16) !void {
        try self.calls.append(allocator, .{
            .call_type = .init_wasm_module,
            .params = .{ .init_wasm_module = .{
                .module_id = module_id,
                .wasm_data_id = wasm_data_id,
            } },
        });
    }

    pub fn callWasmFunc(self: *Self, allocator: Allocator, call_id: u16, module_id: u16, func_name_id: u16, args: []const u8) !void {
        _ = args; // Args passed to JS at runtime, not needed for mock
        try self.calls.append(allocator, .{
            .call_type = .call_wasm_func,
            .params = .{ .call_wasm_func = .{
                .call_id = call_id,
                .module_id = module_id,
                .func_name_id = func_name_id,
            } },
        });
    }

    pub fn writeBufferFromWasm(self: *Self, allocator: Allocator, call_id: u16, buffer_id: u16, offset: u32, byte_len: u32) !void {
        try self.calls.append(allocator, .{
            .call_type = .write_buffer_from_wasm,
            .params = .{ .write_buffer_from_wasm = .{
                .call_id = call_id,
                .buffer_id = buffer_id,
                .offset = offset,
                .byte_len = byte_len,
            } },
        });
    }

    // ========================================================================
    // Data Generation (stubs for testing - actual implementation in JS)
    // ========================================================================

    pub fn createTypedArray(self: *Self, allocator: Allocator, array_id: u16, element_type: u8, element_count: u32) !void {
        _ = self;
        _ = allocator;
        _ = array_id;
        _ = element_type;
        _ = element_count;
        // Mock: no-op, data generation happens in JS runtime
    }

    pub fn fillRandom(self: *Self, allocator: Allocator, array_id: u16, offset: u32, count: u32, stride: u8, seed_data_id: u16, min_data_id: u16, max_data_id: u16) !void {
        _ = self;
        _ = allocator;
        _ = array_id;
        _ = offset;
        _ = count;
        _ = stride;
        _ = seed_data_id;
        _ = min_data_id;
        _ = max_data_id;
    }

    pub fn fillExpression(self: *Self, allocator: Allocator, array_id: u16, offset: u32, count: u32, stride: u8, total_count: u32, expr_data_id: u16) !void {
        _ = self;
        _ = allocator;
        _ = array_id;
        _ = offset;
        _ = count;
        _ = stride;
        _ = total_count;
        _ = expr_data_id;
    }

    pub fn fillConstant(self: *Self, allocator: Allocator, array_id: u16, offset: u32, count: u32, stride: u8, value_data_id: u16) !void {
        _ = self;
        _ = allocator;
        _ = array_id;
        _ = offset;
        _ = count;
        _ = stride;
        _ = value_data_id;
    }

    pub fn writeBufferFromArray(self: *Self, allocator: Allocator, buffer_id: u16, buffer_offset: u32, array_id: u16) !void {
        _ = self;
        _ = allocator;
        _ = buffer_id;
        _ = buffer_offset;
        _ = array_id;
    }

    pub fn writeTimeUniform(self: *Self, allocator: Allocator, buffer_id: u16, buffer_offset: u32, size: u16) !void {
        _ = self;
        _ = allocator;
        _ = buffer_id;
        _ = buffer_offset;
        _ = size;
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

test "mock gpu create texture" {
    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    try gpu.createTexture(testing.allocator, 0, 42);

    try testing.expectEqual(@as(usize, 1), gpu.callCount());
    try testing.expectEqual(CallType.create_texture, gpu.getCall(0).call_type);
    try testing.expect(gpu.textures_created.isSet(0));

    // Verify parameters
    const call = gpu.getCall(0);
    try testing.expectEqual(@as(u16, 0), call.params.create_texture.texture_id);
    try testing.expectEqual(@as(u16, 42), call.params.create_texture.descriptor_data_id);
}

test "mock gpu create sampler" {
    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    try gpu.createSampler(testing.allocator, 5, 99);

    try testing.expectEqual(@as(usize, 1), gpu.callCount());
    try testing.expectEqual(CallType.create_sampler, gpu.getCall(0).call_type);

    // Verify parameters
    const call = gpu.getCall(0);
    try testing.expectEqual(@as(u16, 5), call.params.create_sampler.sampler_id);
    try testing.expectEqual(@as(u16, 99), call.params.create_sampler.descriptor_data_id);
}

test "mock gpu render pass sequence" {
    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    try gpu.createShaderModule(testing.allocator, 0, 0);
    try gpu.createRenderPipeline(testing.allocator, 0, 1);
    try gpu.beginRenderPass(testing.allocator, 0, 1, 0, 0xFFFF);
    try gpu.setPipeline(testing.allocator, 0);
    try gpu.draw(testing.allocator, 3, 1, 0, 0);
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
    try gpu.beginRenderPass(testing.allocator, 0, 1, 0, 0xFFFF);
    try gpu.draw(testing.allocator, 3, 1, 0, 0);
    try gpu.endPass(testing.allocator);

    var buf: [256]u8 = undefined;
    // calls[0] = begin_render_pass, calls[1] = draw
    const str = gpu.getCall(1).describe(&buf);
    try testing.expectEqualStrings("draw(vertices=3, instances=1)", str);
}

test "mock gpu texture and sampler formatting" {
    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    try gpu.createTexture(testing.allocator, 1, 42);
    try gpu.createSampler(testing.allocator, 2, 99);

    var buf: [256]u8 = undefined;

    const tex_str = gpu.getCall(0).describe(&buf);
    try testing.expectEqualStrings("create_texture(id=1, desc=42)", tex_str);

    const sampler_str = gpu.getCall(1).describe(&buf);
    try testing.expectEqualStrings("create_sampler(id=2, desc=99)", sampler_str);
}

// ============================================================================
// New Method Tests (createImageBitmap, copyExternalImageToTexture)
// ============================================================================

test "mock gpu createImageBitmap records call" {
    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    try gpu.createImageBitmap(testing.allocator, 0, 10);

    // Property: call was recorded
    try testing.expectEqual(@as(usize, 1), gpu.callCount());
    try testing.expectEqual(CallType.create_image_bitmap, gpu.getCall(0).call_type);

    // Property: parameters match
    const params = gpu.getCall(0).params.create_image_bitmap;
    try testing.expectEqual(@as(u16, 0), params.bitmap_id);
    try testing.expectEqual(@as(u16, 10), params.blob_data_id);
}

test "mock gpu createImageBitmap multiple calls" {
    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    try gpu.createImageBitmap(testing.allocator, 0, 10);
    try gpu.createImageBitmap(testing.allocator, 1, 20);
    try gpu.createImageBitmap(testing.allocator, 2, 30);

    // Property: all calls recorded in order
    try testing.expectEqual(@as(usize, 3), gpu.callCount());

    for (gpu.getCalls(), 0..) |call, i| {
        try testing.expectEqual(CallType.create_image_bitmap, call.call_type);
        try testing.expectEqual(@as(u16, @intCast(i)), call.params.create_image_bitmap.bitmap_id);
        try testing.expectEqual(@as(u16, @intCast((i + 1) * 10)), call.params.create_image_bitmap.blob_data_id);
    }
}

test "mock gpu copyExternalImageToTexture records call" {
    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    try gpu.copyExternalImageToTexture(testing.allocator, 5, 10, 2, 100, 200);

    // Property: call was recorded
    try testing.expectEqual(@as(usize, 1), gpu.callCount());
    try testing.expectEqual(CallType.copy_external_image_to_texture, gpu.getCall(0).call_type);

    // Property: all parameters match
    const params = gpu.getCall(0).params.copy_external_image_to_texture;
    try testing.expectEqual(@as(u16, 5), params.bitmap_id);
    try testing.expectEqual(@as(u16, 10), params.texture_id);
    try testing.expectEqual(@as(u8, 2), params.mip_level);
    try testing.expectEqual(@as(u16, 100), params.origin_x);
    try testing.expectEqual(@as(u16, 200), params.origin_y);
}

test "mock gpu copyExternalImageToTexture zero origin" {
    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    // Test default case: zero origin (most common)
    try gpu.copyExternalImageToTexture(testing.allocator, 0, 0, 0, 0, 0);

    const params = gpu.getCall(0).params.copy_external_image_to_texture;
    try testing.expectEqual(@as(u16, 0), params.origin_x);
    try testing.expectEqual(@as(u16, 0), params.origin_y);
}

test "mock gpu image workflow sequence" {
    // Test typical image upload workflow:
    // 1. Create texture
    // 2. Create image bitmap from blob
    // 3. Copy image bitmap to texture
    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    try gpu.createTexture(testing.allocator, 0, 1);
    try gpu.createImageBitmap(testing.allocator, 0, 2);
    try gpu.copyExternalImageToTexture(testing.allocator, 0, 0, 0, 0, 0);

    const expected = [_]CallType{
        .create_texture,
        .create_image_bitmap,
        .copy_external_image_to_texture,
    };

    try testing.expect(gpu.expectCallTypes(&expected));

    // Property: texture_id matches between create and copy
    const create_texture_id = gpu.getCall(0).params.create_texture.texture_id;
    const copy_texture_id = gpu.getCall(2).params.copy_external_image_to_texture.texture_id;
    try testing.expectEqual(create_texture_id, copy_texture_id);

    // Property: bitmap_id matches between create and copy
    const create_bitmap_id = gpu.getCall(1).params.create_image_bitmap.bitmap_id;
    const copy_bitmap_id = gpu.getCall(2).params.copy_external_image_to_texture.bitmap_id;
    try testing.expectEqual(create_bitmap_id, copy_bitmap_id);
}

test "mock gpu reset clears image bitmap calls" {
    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    try gpu.createImageBitmap(testing.allocator, 0, 0);
    try gpu.copyExternalImageToTexture(testing.allocator, 0, 0, 0, 0, 0);

    try testing.expectEqual(@as(usize, 2), gpu.callCount());

    gpu.reset();

    try testing.expectEqual(@as(usize, 0), gpu.callCount());
}

test "mock gpu full rendering with texture upload" {
    // Simulate a complete frame that uploads a texture then renders with it
    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    // Setup phase: create resources
    try gpu.createTexture(testing.allocator, 0, 0); // texture for upload
    try gpu.createImageBitmap(testing.allocator, 0, 1); // from blob data
    try gpu.copyExternalImageToTexture(testing.allocator, 0, 0, 0, 0, 0);
    try gpu.createShaderModule(testing.allocator, 0, 2);
    try gpu.createRenderPipeline(testing.allocator, 0, 3);

    // Render phase
    try gpu.beginRenderPass(testing.allocator, 0, 1, 0, 0xFFFF);
    try gpu.setPipeline(testing.allocator, 0);
    try gpu.draw(testing.allocator, 6, 1, 0, 0);
    try gpu.endPass(testing.allocator);
    try gpu.submit(testing.allocator);

    // Property: correct number of calls
    try testing.expectEqual(@as(usize, 10), gpu.callCount());

    // Property: copy happens after create
    var create_bitmap_idx: ?usize = null;
    var copy_idx: ?usize = null;
    for (gpu.getCalls(), 0..) |call, i| {
        if (call.call_type == .create_image_bitmap) create_bitmap_idx = i;
        if (call.call_type == .copy_external_image_to_texture) copy_idx = i;
    }
    try testing.expect(create_bitmap_idx.? < copy_idx.?);
}
