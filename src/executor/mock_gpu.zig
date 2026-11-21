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
const bytecode_emitter = @import("bytecode").emitter.Emitter;
const opcodes = @import("bytecode").opcodes;
const texture_layout = @import("bytecode").texture_layout;
/// Resource id-space budgets — shared with NullGPU and the native backend.
const limits = @import("bytecode").resource_limits;

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
    begin_render_pass_mrt,
    begin_render_pass_views,
    begin_compute_pass,
    set_pipeline,
    set_bind_group,
    set_vertex_buffer,
    set_index_buffer,
    draw,
    draw_indexed,
    dispatch,
    draw_indirect,
    draw_indexed_indirect,
    dispatch_indirect,
    set_viewport,
    set_pass_occlusion_query_set,
    set_pass_timestamp_writes,
    begin_occlusion_query,
    end_occlusion_query,
    resolve_query_set,
    set_stencil_reference,
    set_scissor_rect,
    set_pass_depth_stencil_ops,
    set_blend_constant,
    set_pass_clear_values,
    execute_bundles,
    end_pass,
    create_render_bundle,

    // Queue operations
    write_buffer,
    write_texture,
    copy_buffer_to_texture,
    copy_texture_to_buffer,
    write_controls,
    submit,
    copy_external_image_to_texture,
    copy_buffer_to_buffer,
    copy_texture_to_texture,
    /// Plan 06: the subresource texture→texture copy (PNGB 0x80).
    copy_texture_subresource,
    write_uniform,

    // WASM operations
    init_wasm_module,
    call_wasm_func,
    write_buffer_from_wasm,
};

/// A buffer↔texture copy's recorded payload. Both directions carry the same
/// texture id, buffer id and presence-bearing `WriteLayout`; the CallType is
/// the direction (the opcode), never a field.
pub const TextureBufferCopy = struct {
    texture_id: u16,
    buffer_id: u16,
    write: texture_layout.WriteLayout,
};

/// The human-readable form of one buffer↔texture copy for a MockGPU trace.
/// `name` is the direction's call-type name. Every carried field appears,
/// including presence as `null` and the flag byte's numeric inputs.
fn describeTextureBufferCopy(buf: []u8, comptime name: []const u8, p: TextureBufferCopy) []const u8 {
    const wl = p.write;
    if (wl.size) |s| {
        return std.fmt.bufPrint(buf, name ++ "(texture={d}, buffer={d}, offset={d}, bpr={?d}, rpi={?d}, mip={d}, origin=[{d},{d},{d}], aspect={d}, size=[{d},{d},{d}])", .{
            p.texture_id,            p.buffer_id, wl.offset,   wl.bytes_per_row,        wl.rows_per_image, wl.mip_level,
            wl.origin.x,             wl.origin.y, wl.origin.z, @intFromEnum(wl.aspect), s.width,           s.height,
            s.depth_or_array_layers,
        }) catch "texture_buffer_copy(...)";
    }
    return std.fmt.bufPrint(buf, name ++ "(texture={d}, buffer={d}, offset={d}, bpr={?d}, rpi={?d}, mip={d}, origin=[{d},{d},{d}], aspect={d}, size=null)", .{
        p.texture_id, p.buffer_id, wl.offset,   wl.bytes_per_row,        wl.rows_per_image, wl.mip_level,
        wl.origin.x,  wl.origin.y, wl.origin.z, @intFromEnum(wl.aspect),
    }) catch "texture_buffer_copy(...)";
}

/// The human-readable form of one subresource texture→texture copy for a
/// MockGPU trace. Every carried field appears: both endpoints, both mips, both
/// aspects, both origins, the extent, and whether the size was explicit.
fn describeSubresourceCopy(buf: []u8, p: texture_layout.SubresourceCopy) []const u8 {
    if (p.size) |s| {
        return std.fmt.bufPrint(
            buf,
            "copy_texture_subresource(src={d}, src_mip={d}, src_origin=[{d},{d},{d}], src_aspect={d}, dst={d}, dst_mip={d}, dst_origin=[{d},{d},{d}], dst_aspect={d}, size=[{d},{d},{d}])",
            .{
                p.source.texture_id,           p.source.mip_level,                 p.source.origin.x,       p.source.origin.y,      p.source.origin.z,
                @intFromEnum(p.source.aspect), p.destination.texture_id,           p.destination.mip_level, p.destination.origin.x, p.destination.origin.y,
                p.destination.origin.z,        @intFromEnum(p.destination.aspect), s.width,                 s.height,               s.depth_or_array_layers,
            },
        ) catch "copy_texture_subresource(...)";
    }
    return std.fmt.bufPrint(
        buf,
        "copy_texture_subresource(src={d}, src_mip={d}, src_origin=[{d},{d},{d}], src_aspect={d}, dst={d}, dst_mip={d}, dst_origin=[{d},{d},{d}], dst_aspect={d}, size=null)",
        .{
            p.source.texture_id,           p.source.mip_level,                 p.source.origin.x,       p.source.origin.y,      p.source.origin.z,
            @intFromEnum(p.source.aspect), p.destination.texture_id,           p.destination.mip_level, p.destination.origin.x, p.destination.origin.y,
            p.destination.origin.z,        @intFromEnum(p.destination.aspect),
        },
    ) catch "copy_texture_subresource(...)";
}

/// Append `bytes` at `pos`, refusing rather than overflowing.
fn appendBytes(buf: []u8, pos: *usize, bytes: []const u8) !void {
    if (pos.* > buf.len or bytes.len > buf.len - pos.*) return error.NoSpaceLeft;
    @memcpy(buf[pos.*..][0..bytes.len], bytes);
    pos.* += bytes.len;
}

/// Format into `buf` at `pos`, refusing rather than overflowing.
fn appendFmt(buf: []u8, pos: *usize, comptime fmt: []const u8, args: anytype) !void {
    const written = std.fmt.bufPrint(buf[pos.*..], fmt, args) catch return error.NoSpaceLeft;
    pos.* += written.len;
}

/// The human-readable form of one attachment target: `texture:N`, `view:N`,
/// `canvas` or `none`. The ONE target-resolution helper both the trace and the
/// reference tests read — the sentinel order and the high-bit mask live in
/// `types/opcodes.zig`, not here.
fn appendAttachmentTarget(buf: []u8, pos: *usize, target: u16) !void {
    switch (opcodes.decodeAttachmentTarget(target)) {
        .none => try appendBytes(buf, pos, "none"),
        .canvas => try appendBytes(buf, pos, "canvas"),
        .texture => |id| try appendFmt(buf, pos, "texture:{d}", .{id}),
        .view => |id| try appendFmt(buf, pos, "view:{d}", .{id}),
    }
}

/// The 0x81 trace line. Every colour target AND every resolve target names its
/// own id space, and the depth target is named the same way; a bare count would
/// hide exactly the substitution this opcode exists to prevent.
fn describeBeginRenderPassViews(buf: []u8, p: anytype) []const u8 {
    var pos: usize = 0;
    const ok = blk: {
        appendFmt(buf, &pos, "begin_render_pass_views(count={d}, targets=[", .{p.attachment_count}) catch break :blk false;
        for (0..p.attachment_count) |i| {
            if (i > 0) appendBytes(buf, &pos, ",") catch break :blk false;
            appendAttachmentTarget(buf, &pos, p.attachments[i].target) catch break :blk false;
        }
        appendBytes(buf, &pos, "], resolves=[") catch break :blk false;
        for (0..p.attachment_count) |i| {
            if (i > 0) appendBytes(buf, &pos, ",") catch break :blk false;
            appendAttachmentTarget(buf, &pos, p.attachments[i].resolve_target) catch break :blk false;
        }
        appendBytes(buf, &pos, "], depth=") catch break :blk false;
        appendAttachmentTarget(buf, &pos, p.depth_target) catch break :blk false;
        appendBytes(buf, &pos, ")") catch break :blk false;
        break :blk true;
    };
    return if (ok) buf[0..pos] else "begin_render_pass_views(...)";
}

/// Recorded GPU API call with parameters.
pub const Call = struct {
    call_type: CallType,
    params: Params,

    pub const Params = union {
        create_buffer: struct {
            buffer_id: u16,
            size: u32,
            usage: u16,
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
            clear_r_bits: u32,
            clear_g_bits: u32,
            clear_b_bits: u32,
            clear_a_bits: u32,
            resolve_texture_id: u16 = 0xFFFF,
        },
        begin_render_pass_mrt: struct {
            attachment_count: u8,
            attachments: [limits.MAX_COLOR_ATTACHMENTS]bytecode_emitter.ColorAttachment,
            depth_texture_id: u16,
        },
        /// 0x81's owned record: the repeated colour attachments (target +
        /// load/store + four clear channels + resolve target) and the depth
        /// target. Copied by value so the log never aliases the decoder's stack.
        begin_render_pass_views: struct {
            attachment_count: u8,
            attachments: [limits.MAX_COLOR_ATTACHMENTS]bytecode_emitter.ViewColorAttachment,
            depth_target: u16,
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
        draw_indirect: struct {
            buffer_id: u16,
            offset: u32,
        },
        draw_indexed_indirect: struct {
            buffer_id: u16,
            offset: u32,
        },
        dispatch_indirect: struct {
            buffer_id: u16,
            offset: u32,
        },
        set_viewport: struct {
            x: u32,
            y: u32,
            width: u32,
            height: u32,
            min_depth_bits: u32,
            max_depth_bits: u32,
        },
        set_pass_occlusion_query_set: struct {
            query_set_id: u16,
        },
        set_pass_timestamp_writes: struct {
            query_set_id: u16,
            begin_index: u32,
            end_index: u32,
        },
        begin_occlusion_query: struct {
            query_index: u32,
        },
        end_occlusion_query: struct {
            dummy: u8 = 0,
        },
        resolve_query_set: struct {
            query_set_id: u16,
            first_query: u32,
            query_count: u32,
            dest_buffer_id: u16,
            dest_offset: u32,
        },
        set_stencil_reference: struct {
            reference: u32,
        },
        set_scissor_rect: struct {
            x: u32,
            y: u32,
            width: u32,
            height: u32,
        },
        set_pass_depth_stencil_ops: struct {
            depth_load_op: u8,
            depth_store_op: u8,
            stencil_load_op: u8,
            stencil_store_op: u8,
        },
        set_blend_constant: struct {
            r_bits: u32,
            g_bits: u32,
            b_bits: u32,
            a_bits: u32,
        },
        set_pass_clear_values: struct {
            depth_bits: u32,
            stencil_value: u32,
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
        /// A raw texture upload. The write carries the same presence-bearing
        /// `WriteLayout` the compiler normalized, so a golden can pin an
        /// omitted stride/size against an authored zero.
        write_texture: struct {
            texture_id: u16,
            data_id: u16,
            write: texture_layout.WriteLayout,
        },
        /// A buffer→texture copy. Every field the 0x2E instruction carries,
        /// recorded by value so a golden can pin presence, origin and extent.
        copy_buffer_to_texture: TextureBufferCopy,
        /// A texture→buffer copy: the same recorded shape, opposite direction.
        copy_texture_to_buffer: TextureBufferCopy,
        /// The declared controls written by `write_controls`, copied into a
        /// fixed array so the record owns its values (the same reason
        /// begin_render_pass_mrt copies its attachments). `count` says how
        /// many of `values` are real.
        write_controls: struct {
            buffer_id: u16,
            offset: u32,
            values: [opcodes.MAX_CONTROLS]f32,
            count: u8,
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
            origin_z: u16,
        },
        copy_buffer_to_buffer: struct {
            src_buffer: u16,
            src_offset: u32,
            dst_buffer: u16,
            dst_offset: u32,
            size: u32,
        },
        copy_texture_to_texture: struct {
            src_texture: u16,
            dst_texture: u16,
        },
        /// Plan 06's subresource copy, recorded by value: both endpoints (id,
        /// mip, origin, aspect) and the optional authored size. A golden can
        /// therefore pin presence as well as every field.
        copy_texture_subresource: texture_layout.SubresourceCopy,
        write_uniform: struct {
            buffer_id: u16,
            uniform_id: u16,
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
    ///
    /// Every arm's `catch "…(...)"` is a MESSAGE fallback, and deliberate: this
    /// text is read by a human in a trace, so a truncated line still tells them
    /// which call it was. That is the opposite of the rule in `cli/js_emit.zig`,
    /// where the formatted text is a value the page computes with and no
    /// fallback is acceptable (§440).
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
                // Name the id space a tagged layout_id refers to; the raw operand
                // reads as 32768+n, which looks like a corrupt id rather than an
                // explicit (bind-group-layout …). Untagged keeps `layout={d}`.
                if (opcodes.layoutIdIsBindGroupLayout(p.layout_id)) {
                    break :blk std.fmt.bufPrint(buf, "create_bind_group(id={d}, layout=bgl:{d}, entries={d})", .{ p.group_id, opcodes.layoutIdValue(p.layout_id), p.entry_data_id }) catch "create_bind_group(...)";
                }
                break :blk std.fmt.bufPrint(buf, "create_bind_group(id={d}, layout={d}, entries={d})", .{ p.group_id, p.layout_id, p.entry_data_id }) catch "create_bind_group(...)";
            },
            .begin_render_pass => blk: {
                const p = self.params.begin_render_pass;
                break :blk std.fmt.bufPrint(buf, "begin_render_pass(color={d}, load={d}, store={d})", .{ p.color_texture_id, p.load_op, p.store_op }) catch "begin_render_pass(...)";
            },
            .begin_render_pass_mrt => blk: {
                const p = self.params.begin_render_pass_mrt;
                break :blk std.fmt.bufPrint(buf, "begin_render_pass_mrt(count={d}, depth={d})", .{ p.attachment_count, p.depth_texture_id }) catch "begin_render_pass_mrt(...)";
            },
            .begin_render_pass_views => describeBeginRenderPassViews(buf, self.params.begin_render_pass_views),
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
            .draw_indirect => blk: {
                const p = self.params.draw_indirect;
                break :blk std.fmt.bufPrint(buf, "draw_indirect(buf={d}, offset={d})", .{ p.buffer_id, p.offset }) catch "draw_indirect(...)";
            },
            .draw_indexed_indirect => blk: {
                const p = self.params.draw_indexed_indirect;
                break :blk std.fmt.bufPrint(buf, "draw_indexed_indirect(buf={d}, offset={d})", .{ p.buffer_id, p.offset }) catch "draw_indexed_indirect(...)";
            },
            .dispatch_indirect => blk: {
                const p = self.params.dispatch_indirect;
                break :blk std.fmt.bufPrint(buf, "dispatch_indirect(buf={d}, offset={d})", .{ p.buffer_id, p.offset }) catch "dispatch_indirect(...)";
            },
            .set_viewport => blk: {
                const p = self.params.set_viewport;
                break :blk std.fmt.bufPrint(buf, "set_viewport({d}, {d}, {d}, {d})", .{ p.x, p.y, p.width, p.height }) catch "set_viewport(...)";
            },
            .set_pass_occlusion_query_set => blk: {
                const p = self.params.set_pass_occlusion_query_set;
                break :blk std.fmt.bufPrint(buf, "set_pass_occlusion_query_set({d})", .{p.query_set_id}) catch "set_pass_occlusion_query_set(...)";
            },
            .set_pass_timestamp_writes => blk: {
                const p = self.params.set_pass_timestamp_writes;
                break :blk std.fmt.bufPrint(buf, "set_pass_timestamp_writes(qs={d}, begin={d}, end={d})", .{ p.query_set_id, p.begin_index, p.end_index }) catch "set_pass_timestamp_writes(...)";
            },
            .begin_occlusion_query => blk: {
                const p = self.params.begin_occlusion_query;
                break :blk std.fmt.bufPrint(buf, "begin_occlusion_query({d})", .{p.query_index}) catch "begin_occlusion_query(...)";
            },
            .end_occlusion_query => "end_occlusion_query()",
            .resolve_query_set => blk: {
                const p = self.params.resolve_query_set;
                break :blk std.fmt.bufPrint(buf, "resolve_query_set(qs={d}, first={d}, count={d}, buf={d})", .{ p.query_set_id, p.first_query, p.query_count, p.dest_buffer_id }) catch "resolve_query_set(...)";
            },
            .set_stencil_reference => blk: {
                const p = self.params.set_stencil_reference;
                break :blk std.fmt.bufPrint(buf, "set_stencil_reference({d})", .{p.reference}) catch "set_stencil_reference(...)";
            },
            .set_scissor_rect => blk: {
                const p = self.params.set_scissor_rect;
                break :blk std.fmt.bufPrint(buf, "set_scissor_rect({d}, {d}, {d}, {d})", .{ p.x, p.y, p.width, p.height }) catch "set_scissor_rect(...)";
            },
            .set_pass_depth_stencil_ops => blk: {
                const p = self.params.set_pass_depth_stencil_ops;
                break :blk std.fmt.bufPrint(buf, "set_pass_depth_stencil_ops(dLoad={d}, dStore={d}, sLoad={d}, sStore={d})", .{ p.depth_load_op, p.depth_store_op, p.stencil_load_op, p.stencil_store_op }) catch "set_pass_depth_stencil_ops(...)";
            },
            .set_blend_constant => blk: {
                const p = self.params.set_blend_constant;
                break :blk std.fmt.bufPrint(buf, "set_blend_constant({d}, {d}, {d}, {d})", .{
                    @as(f32, @bitCast(p.r_bits)), @as(f32, @bitCast(p.g_bits)), @as(f32, @bitCast(p.b_bits)), @as(f32, @bitCast(p.a_bits)),
                }) catch "set_blend_constant(...)";
            },
            .set_pass_clear_values => blk: {
                const p = self.params.set_pass_clear_values;
                break :blk std.fmt.bufPrint(buf, "set_pass_clear_values(depth={d}, stencil={d})", .{
                    @as(f32, @bitCast(p.depth_bits)), p.stencil_value,
                }) catch "set_pass_clear_values(...)";
            },
            .end_pass => "end_pass()",
            .write_buffer => blk: {
                const p = self.params.write_buffer;
                break :blk std.fmt.bufPrint(buf, "write_buffer(id={d}, offset={d}, data={d})", .{ p.buffer_id, p.offset, p.data_id }) catch "write_buffer(...)";
            },
            .write_texture => blk: {
                const p = self.params.write_texture;
                const wl = p.write;
                if (wl.size) |s| {
                    break :blk std.fmt.bufPrint(buf, "write_texture(id={d}, data={d}, offset={d}, bpr={?d}, rpi={?d}, mip={d}, origin=[{d},{d},{d}], aspect={d}, size=[{d},{d},{d}])", .{
                        p.texture_id,            p.data_id,   wl.offset,   wl.bytes_per_row,        wl.rows_per_image, wl.mip_level,
                        wl.origin.x,             wl.origin.y, wl.origin.z, @intFromEnum(wl.aspect), s.width,           s.height,
                        s.depth_or_array_layers,
                    }) catch "write_texture(...)";
                }
                break :blk std.fmt.bufPrint(buf, "write_texture(id={d}, data={d}, offset={d}, bpr={?d}, rpi={?d}, mip={d}, origin=[{d},{d},{d}], aspect={d}, size=null)", .{
                    p.texture_id, p.data_id,   wl.offset,   wl.bytes_per_row,        wl.rows_per_image, wl.mip_level,
                    wl.origin.x,  wl.origin.y, wl.origin.z, @intFromEnum(wl.aspect),
                }) catch "write_texture(...)";
            },
            .copy_buffer_to_texture => describeTextureBufferCopy(buf, "copy_buffer_to_texture", self.params.copy_buffer_to_texture),
            .copy_texture_to_buffer => describeTextureBufferCopy(buf, "copy_texture_to_buffer", self.params.copy_texture_to_buffer),
            .write_controls => blk: {
                const p = self.params.write_controls;
                break :blk std.fmt.bufPrint(buf, "write_controls(id={d}, offset={d}, count={d})", .{ p.buffer_id, p.offset, p.count }) catch "write_controls(...)";
            },
            .submit => "submit()",
            .copy_buffer_to_buffer => blk: {
                const p = self.params.copy_buffer_to_buffer;
                break :blk std.fmt.bufPrint(buf, "copy_buffer_to_buffer(src={d}, srcOff={d}, dst={d}, dstOff={d}, size={d})", .{ p.src_buffer, p.src_offset, p.dst_buffer, p.dst_offset, p.size }) catch "copy_buffer_to_buffer(...)";
            },
            .copy_texture_to_texture => blk: {
                const p = self.params.copy_texture_to_texture;
                break :blk std.fmt.bufPrint(buf, "copy_texture_to_texture(src={d}, dst={d})", .{ p.src_texture, p.dst_texture }) catch "copy_texture_to_texture(...)";
            },
            .copy_texture_subresource => describeSubresourceCopy(buf, self.params.copy_texture_subresource),
            .write_uniform => blk: {
                const p = self.params.write_uniform;
                break :blk std.fmt.bufPrint(buf, "write_uniform(buffer={d}, uniform={d})", .{ p.buffer_id, p.uniform_id }) catch "write_uniform(...)";
            },
            else => @tagName(self.call_type),
        };
    }
};

/// Mock GPU backend that records all API calls.
pub const MockGPU = struct {
    const Self = @This();

    /// Maximum resources per category — the bound on the `*_created` bitsets
    /// below, NOT a bound on what may be recorded.
    ///
    /// `MockGPU` runs on untrusted bytecode: `pngine inspect art.png` and
    /// `pngine extract art.png | pngine inspect -` dispatch arbitrary PNGB
    /// through it in the shipping npm CLI. An id past these caps must therefore
    /// never reach `StaticBitSet.set` — that is an out-of-bounds write to the
    /// bitset's backing array once `assert` compiles out under ReleaseFast.
    ///
    /// The call is still RECORDED with its real id: inspection is the whole
    /// point of this backend, and a trace reading `create_bind_group(id=60000)`
    /// diagnoses the malformed payload that a dropped call would hide. Only the
    /// bitset write — a resource-tracking convenience — is skipped.
    ///
    /// The numbers themselves are NOT here: they come from
    /// `bytecode.resource_limits`, the one declaration all three backends read,
    /// so a bitset here cannot be narrower than the table that actually stops a
    /// render. `MAX_BIND_GROUPS` used to be 64 in this file while the native
    /// backend held 128 — a reader consulting MockGPU concluded 64 was the
    /// engine's limit and was wrong by a factor of two (r3-03).
    pub const MAX_BUFFERS: u16 = limits.capOf(.buffers);
    pub const MAX_TEXTURES: u16 = limits.capOf(.textures);
    pub const MAX_SHADERS: u16 = limits.capOf(.shaders);
    pub const MAX_PIPELINES: u16 = limits.capOf(.pipelines);
    pub const MAX_BIND_GROUPS: u16 = limits.capOf(.bind_groups);

    /// A recorded runtime-uniform write. `kind` distinguishes the two opcodes
    /// (`.time` = write_time_uniform, `.pointer` = write_pointer_uniform); `size`
    /// is the byte count (16 = pngineInputs, 12 = sceneTimeInputs, 48 = pointer).
    pub const UniformWrite = struct {
        kind: enum { time, pointer },
        buffer_id: u16,
        offset: u32,
        size: u16,
    };

    /// The most calls one dispatch will record. Past it, `record` REFUSES —
    /// see there for why this is a budget and not an assert.
    ///
    /// Two orders of magnitude above anything a real payload produces: the
    /// top-level stream is capped at MAX_TOP_LEVEL_STEPS (10_000) instructions
    /// and a frame's passes add hundreds more, so an honest document uses a low
    /// single-digit percent of this. It caps the log at ~7 MB.
    pub const CALL_BUDGET: usize = 100_000;

    /// Recorded calls. Append ONLY through `record`.
    calls: std.ArrayList(Call),

    /// Recorded runtime-uniform writes (`write_time_uniform` / `write_pointer_uniform`).
    /// These opcodes stream per-frame time/canvas/pointer data into a buffer; MockGPU
    /// has no buffer contents to mutate, so they are deliberately kept OUT of `calls`
    /// (the call-log oracle stays stable and blind to them). They are recorded here
    /// instead so the SJON parity harness can assert the legacy and SJON paths emit
    /// identical uniform-write sequences — the runtime-uniform validation track that
    /// the call-log bijection cannot provide.
    uniform_writes: std.ArrayList(UniformWrite),

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

    /// Pass-sequencing violations seen in the dispatched stream: a setter or
    /// draw with no pass open, a `begin` with one already open, an `end_pass`
    /// with nothing to end, a `submit` with a pass still open.
    ///
    /// LATCHED, NOT ASSERTED — the same call the MAX_* id caps above make, for
    /// the same reason. These were `assert`s until r2-07, which is the wrong
    /// shape twice over on a backend fed untrusted bytecode: in a Debug build a
    /// hostile stream PANICS `pngine inspect`, and in the shipping ReleaseFast
    /// npm binary the assert compiles out and the same stream is recorded as
    /// though it were well-formed. Nothing upstream stands between the two:
    /// `dispatcher/pass.zig` decodes each op and calls the backend straight
    /// through, tracking no pass state whatsoever (checked first — it was
    /// r2-07's own refutation clause, and the probe refuted it: a corpus body
    /// that draws outside a pass aborted the test binary at `set_pipeline`).
    ///
    /// So this is malformed INPUT, and input gets a verdict rather than a
    /// panic. The call is still RECORDED, again for the id caps' reason: a
    /// trace showing `draw()` outside a pass is what diagnoses the payload,
    /// where a dropped call would hide it.
    ///
    /// Saturating: a diagnostic count over a stream of attacker-chosen length.
    pass_state_violations: u32,

    pub const empty: Self = .{
        .calls = .empty,
        .uniform_writes = .empty,
        .buffers_created = std.StaticBitSet(MAX_BUFFERS).initEmpty(),
        .textures_created = std.StaticBitSet(MAX_TEXTURES).initEmpty(),
        .shaders_created = std.StaticBitSet(MAX_SHADERS).initEmpty(),
        .pipelines_created = std.StaticBitSet(MAX_PIPELINES).initEmpty(),
        .bind_groups_created = std.StaticBitSet(MAX_BIND_GROUPS).initEmpty(),
        .in_render_pass = false,
        .in_compute_pass = false,
        .current_pipeline = null,
        .pass_state_violations = 0,
    };

    /// The ONE seam every recorded call goes through, and therefore the one
    /// place the log's size is decided.
    ///
    /// Before this there were six `assert(calls.items.len < 10000)` tripwires
    /// spread over ~48 append sites, which is the wrong shape three times over.
    /// They covered an eighth of the sites, so most growth was unwatched. They
    /// were asserts on a bound the INPUT reaches — `pngine inspect` dispatches
    /// downloaded PNGB, and a pass body of `submit` run from a run of
    /// `exec_pass` crosses 10k calls out of 2 KB of bytecode — which is a Debug
    /// panic on a hostile payload, the shape r2-07 (§331) rejected everywhere
    /// else. And they compiled out of the ReleaseFast npm binary that actually
    /// ships, where the same stream grew the log until the process died.
    ///
    /// So: a refusal, at every site, in every build. The dispatcher propagates
    /// it as `error.CallBudgetExhausted` and the trace recorded up to the
    /// refusal stays intact — that prefix is what diagnoses the payload.
    fn record(self: *Self, gpa: Allocator, call: Call) !void {
        if (self.calls.items.len >= CALL_BUDGET) return error.CallBudgetExhausted;
        try self.calls.append(gpa, call);
        // Post-condition: the log never passes the budget.
        assert(self.calls.items.len <= CALL_BUDGET);
    }

    /// Note a pass-sequencing expectation over untrusted input. `ok` is exactly
    /// what the pre-r2-07 `assert` enforced; a false one latches instead of
    /// panicking. See `pass_state_violations`.
    fn notePassState(self: *Self, ok: bool) void {
        if (!ok) self.pass_state_violations +|= 1;
    }

    /// Whether the dispatched stream violated pass sequencing at any point.
    /// `pngine inspect` reports this; a well-formed payload never sets it.
    pub fn hasPassStateViolation(self: *const Self) bool {
        return self.pass_state_violations > 0;
    }

    pub fn deinit(self: *Self, gpa: Allocator) void {
        self.calls.deinit(gpa);
        self.uniform_writes.deinit(gpa);
        self.* = undefined;
    }

    /// Reset state for reuse.
    pub fn reset(self: *Self) void {
        self.calls.clearRetainingCapacity();
        self.uniform_writes.clearRetainingCapacity();
        self.buffers_created = std.StaticBitSet(MAX_BUFFERS).initEmpty();
        self.textures_created = std.StaticBitSet(MAX_TEXTURES).initEmpty();
        self.shaders_created = std.StaticBitSet(MAX_SHADERS).initEmpty();
        self.pipelines_created = std.StaticBitSet(MAX_PIPELINES).initEmpty();
        self.bind_groups_created = std.StaticBitSet(MAX_BIND_GROUPS).initEmpty();
        self.in_render_pass = false;
        self.in_compute_pass = false;
        self.current_pipeline = null;
        self.pass_state_violations = 0;
    }

    // ========================================================================
    // Resource Creation
    // ========================================================================

    pub fn create_buffer(self: *Self, gpa: Allocator, buffer_id: u16, size: u32, usage: u16) !void {
        // Untrusted id: a real branch, not an assert (see the MAX_* contract).
        if (buffer_id < MAX_BUFFERS) self.buffers_created.set(buffer_id);

        try self.record(gpa, .{
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
    pub fn create_texture(self: *Self, gpa: Allocator, texture_id: u16, descriptor_data_id: u16) !void {
        // Untrusted id: a real branch, not an assert (see the MAX_* contract).
        //
        // No duplicate-id assert either. It claimed an invariant the INPUT is
        // what guarantees — `create_texture 0` twice is two well-formed
        // instructions no decoder rejects, and the assert turned that into a
        // Debug panic in the backend whose job is to describe such payloads
        // (probed in r2-07: the corpus case aborted the test binary here). The
        // sibling assert on `create_sampler` went the same way in r1-01. The
        // bitset write is idempotent, so re-creation needs no handling; the
        // duplicate is visible in the recorded call log where it belongs.
        if (texture_id < MAX_TEXTURES) self.textures_created.set(texture_id);

        try self.record(gpa, .{
            .call_type = .create_texture,
            .params = .{ .create_texture = .{
                .texture_id = texture_id,
                .descriptor_data_id = descriptor_data_id,
            } },
        });
    }

    /// Record sampler creation.
    /// Samplers are not tracked in bitset (typically few per pipeline).
    pub fn create_sampler(self: *Self, gpa: Allocator, sampler_id: u16, descriptor_data_id: u16) !void {
        // No id assert: samplers have no table here (see the doc line above), so
        // the old `sampler_id < MAX_TEXTURES` bounded a sampler id by the TEXTURE
        // cap — a borrowed number, not an invariant. It guarded nothing and
        // Debug-panicked on the malformed payloads this backend exists to report.

        try self.record(gpa, .{
            .call_type = .create_sampler,
            .params = .{ .create_sampler = .{
                .sampler_id = sampler_id,
                .descriptor_data_id = descriptor_data_id,
            } },
        });
    }

    /// Record texture view creation.
    pub fn create_texture_view(self: *Self, gpa: Allocator, view_id: u16, texture_id: u16, descriptor_data_id: u16) !void {
        try self.record(gpa, .{
            .call_type = .create_texture_view,
            .params = .{ .create_texture_view = .{
                .view_id = view_id,
                .texture_id = texture_id,
                .descriptor_data_id = descriptor_data_id,
            } },
        });
    }

    /// Record query set creation.
    pub fn create_query_set(self: *Self, gpa: Allocator, query_set_id: u16, descriptor_data_id: u16) !void {
        try self.record(gpa, .{
            .call_type = .create_query_set,
            .params = .{ .create_query_set = .{
                .query_set_id = query_set_id,
                .descriptor_data_id = descriptor_data_id,
            } },
        });
    }

    /// Record bind group layout creation.
    pub fn create_bind_group_layout(self: *Self, gpa: Allocator, layout_id: u16, descriptor_data_id: u16) !void {
        // No id assert: this backend keeps no bind-group-layout table, so there
        // is no bound to enforce — the old `layout_id < MAX_BIND_GROUPS` guarded
        // nothing and named the wrong id space besides. Asserting here only
        // turned a malformed payload into a Debug panic in the one backend whose
        // job is to describe malformed payloads.

        try self.record(gpa, .{
            .call_type = .create_bind_group_layout,
            .params = .{ .create_bind_group_layout = .{
                .layout_id = layout_id,
                .descriptor_data_id = descriptor_data_id,
            } },
        });
    }

    /// Record pipeline layout creation.
    pub fn create_pipeline_layout(self: *Self, gpa: Allocator, layout_id: u16, descriptor_data_id: u16) !void {
        try self.record(gpa, .{
            .call_type = .create_pipeline_layout,
            .params = .{ .create_pipeline_layout = .{
                .layout_id = layout_id,
                .descriptor_data_id = descriptor_data_id,
            } },
        });
    }

    /// Record render bundle creation.
    pub fn create_render_bundle(self: *Self, gpa: Allocator, bundle_id: u16, descriptor_data_id: u16) !void {
        try self.record(gpa, .{
            .call_type = .create_render_bundle,
            .params = .{ .create_render_bundle = .{
                .bundle_id = bundle_id,
                .descriptor_data_id = descriptor_data_id,
            } },
        });
    }

    pub fn create_shader_module(self: *Self, gpa: Allocator, shader_id: u16, code_data_id: u16) !void {
        if (shader_id < MAX_SHADERS) self.shaders_created.set(shader_id); // untrusted id

        try self.record(gpa, .{
            .call_type = .create_shader_module,
            .params = .{ .create_shader_module = .{
                .shader_id = shader_id,
                .code_data_id = code_data_id,
            } },
        });
    }

    pub fn create_render_pipeline(self: *Self, gpa: Allocator, pipeline_id: u16, descriptor_data_id: u16) !void {
        if (pipeline_id < MAX_PIPELINES) self.pipelines_created.set(pipeline_id); // untrusted id

        try self.record(gpa, .{
            .call_type = .create_render_pipeline,
            .params = .{ .create_render_pipeline = .{
                .pipeline_id = pipeline_id,
                .descriptor_data_id = descriptor_data_id,
            } },
        });
    }

    pub fn create_compute_pipeline(self: *Self, gpa: Allocator, pipeline_id: u16, descriptor_data_id: u16) !void {
        if (pipeline_id < MAX_PIPELINES) self.pipelines_created.set(pipeline_id); // untrusted id

        try self.record(gpa, .{
            .call_type = .create_compute_pipeline,
            .params = .{ .create_compute_pipeline = .{
                .pipeline_id = pipeline_id,
                .descriptor_data_id = descriptor_data_id,
            } },
        });
    }

    pub fn create_bind_group(self: *Self, gpa: Allocator, group_id: u16, layout_id: u16, entry_data_id: u16) !void {
        if (group_id < MAX_BIND_GROUPS) self.bind_groups_created.set(group_id); // untrusted id

        try self.record(gpa, .{
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

    pub fn begin_render_pass(self: *Self, gpa: Allocator, color_texture_id: u16, load_op: u8, store_op: u8, depth_texture_id: u16, clear_r_bits: u32, clear_g_bits: u32, clear_b_bits: u32, clear_a_bits: u32, resolve_texture_id: u16) !void {
        // Latched, not asserted: this is input, not a caller bug.
        self.notePassState(!self.in_render_pass and !self.in_compute_pass);

        self.in_render_pass = true;
        self.current_pipeline = null;

        try self.record(gpa, .{
            .call_type = .begin_render_pass,
            .params = .{ .begin_render_pass = .{
                .color_texture_id = color_texture_id,
                .load_op = load_op,
                .store_op = store_op,
                .depth_texture_id = depth_texture_id,
                .clear_r_bits = clear_r_bits,
                .clear_g_bits = clear_g_bits,
                .clear_b_bits = clear_b_bits,
                .clear_a_bits = clear_a_bits,
                .resolve_texture_id = resolve_texture_id,
            } },
        });
    }

    pub fn begin_render_pass_mrt(self: *Self, gpa: Allocator, attachments: []const bytecode_emitter.ColorAttachment, depth_texture_id: u16) !void {
        self.notePassState(!self.in_render_pass and !self.in_compute_pass);

        self.in_render_pass = true;
        self.current_pipeline = null;

        var atts: [8]bytecode_emitter.ColorAttachment = undefined;
        const count: u8 = @intCast(@min(attachments.len, 8));
        @memcpy(atts[0..count], attachments[0..count]);

        try self.record(gpa, .{
            .call_type = .begin_render_pass_mrt,
            .params = .{ .begin_render_pass_mrt = .{
                .attachment_count = count,
                .attachments = atts,
                .depth_texture_id = depth_texture_id,
            } },
        });
    }

    /// 0x81: record the pass's resolved targets. The attachment array is COPIED
    /// into the call's owned params (the dispatcher's slice is a stack local).
    /// MockGPU applies no GPU validation, but a structurally impossible call is
    /// refused rather than recorded as a pass: >8 colour attachments, or zero
    /// colours with no depth target.
    pub fn begin_render_pass_views(
        self: *Self,
        gpa: Allocator,
        attachments: []const bytecode_emitter.ViewColorAttachment,
        depth_target: u16,
    ) !void {
        assert(attachments.len <= limits.MAX_COLOR_ATTACHMENTS);
        assert(attachments.len > 0 or depth_target != opcodes.ATTACHMENT_NONE);

        self.notePassState(!self.in_render_pass and !self.in_compute_pass);
        self.in_render_pass = true;
        self.current_pipeline = null;

        var atts: [limits.MAX_COLOR_ATTACHMENTS]bytecode_emitter.ViewColorAttachment = undefined;
        const count: u8 = @intCast(attachments.len);
        @memcpy(atts[0..count], attachments);

        try self.record(gpa, .{
            .call_type = .begin_render_pass_views,
            .params = .{ .begin_render_pass_views = .{
                .attachment_count = count,
                .attachments = atts,
                .depth_target = depth_target,
            } },
        });
    }

    pub fn begin_compute_pass(self: *Self, gpa: Allocator) !void {
        self.notePassState(!self.in_render_pass and !self.in_compute_pass);

        self.in_compute_pass = true;
        self.current_pipeline = null;

        try self.record(gpa, .{
            .call_type = .begin_compute_pass,
            .params = .{ .none = {} },
        });
    }

    pub fn set_pipeline(self: *Self, gpa: Allocator, pipeline_id: u16) !void {
        // Latched, not asserted: this is input, not a caller bug.
        self.notePassState(self.in_render_pass or self.in_compute_pass);

        self.current_pipeline = pipeline_id;

        try self.record(gpa, .{
            .call_type = .set_pipeline,
            .params = .{ .set_pipeline = .{
                .pipeline_id = pipeline_id,
            } },
        });
    }

    pub fn set_bind_group(self: *Self, gpa: Allocator, slot: u8, group_id: u16) !void {
        self.notePassState(self.in_render_pass or self.in_compute_pass);

        try self.record(gpa, .{
            .call_type = .set_bind_group,
            .params = .{ .set_bind_group = .{
                .slot = slot,
                .group_id = group_id,
            } },
        });
    }

    pub fn set_vertex_buffer(self: *Self, gpa: Allocator, slot: u8, buffer_id: u16) !void {
        self.notePassState(self.in_render_pass);

        try self.record(gpa, .{
            .call_type = .set_vertex_buffer,
            .params = .{ .set_vertex_buffer = .{
                .slot = slot,
                .buffer_id = buffer_id,
            } },
        });
    }

    pub fn set_index_buffer(self: *Self, gpa: Allocator, buffer_id: u16, index_format: u8) !void {
        self.notePassState(self.in_render_pass);

        try self.record(gpa, .{
            .call_type = .set_index_buffer,
            .params = .{ .set_index_buffer = .{
                .buffer_id = buffer_id,
                .index_format = index_format,
            } },
        });
    }

    pub fn draw(
        self: *Self,
        gpa: Allocator,
        vertex_count: u32,
        instance_count: u32,
        first_vertex: u32,
        first_instance: u32,
    ) !void {
        self.notePassState(self.in_render_pass);

        try self.record(gpa, .{
            .call_type = .draw,
            .params = .{ .draw = .{
                .vertex_count = vertex_count,
                .instance_count = instance_count,
                .first_vertex = first_vertex,
                .first_instance = first_instance,
            } },
        });
    }

    pub fn draw_indexed(
        self: *Self,
        gpa: Allocator,
        index_count: u32,
        instance_count: u32,
        first_index: u32,
        base_vertex: u32,
        first_instance: u32,
    ) !void {
        self.notePassState(self.in_render_pass);

        try self.record(gpa, .{
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

    pub fn dispatch(self: *Self, gpa: Allocator, x: u32, y: u32, z: u32) !void {
        self.notePassState(self.in_compute_pass);

        try self.record(gpa, .{
            .call_type = .dispatch,
            .params = .{ .dispatch = .{
                .x = x,
                .y = y,
                .z = z,
            } },
        });
    }

    pub fn draw_indirect(self: *Self, gpa: Allocator, buffer_id: u16, offset: u32) !void {
        self.notePassState(self.in_render_pass);

        try self.record(gpa, .{
            .call_type = .draw_indirect,
            .params = .{ .draw_indirect = .{
                .buffer_id = buffer_id,
                .offset = offset,
            } },
        });
    }

    pub fn draw_indexed_indirect(self: *Self, gpa: Allocator, buffer_id: u16, offset: u32) !void {
        self.notePassState(self.in_render_pass);

        try self.record(gpa, .{
            .call_type = .draw_indexed_indirect,
            .params = .{ .draw_indexed_indirect = .{
                .buffer_id = buffer_id,
                .offset = offset,
            } },
        });
    }

    pub fn set_viewport(self: *Self, gpa: Allocator, x: u32, y: u32, width: u32, height: u32, min_depth_bits: u32, max_depth_bits: u32) !void {
        self.notePassState(self.in_render_pass);

        try self.record(gpa, .{
            .call_type = .set_viewport,
            .params = .{ .set_viewport = .{
                .x = x,
                .y = y,
                .width = width,
                .height = height,
                .min_depth_bits = min_depth_bits,
                .max_depth_bits = max_depth_bits,
            } },
        });
    }

    pub fn set_pass_occlusion_query_set(self: *Self, gpa: Allocator, query_set_id: u16) !void {
        try self.record(gpa, .{ .call_type = .set_pass_occlusion_query_set, .params = .{ .set_pass_occlusion_query_set = .{ .query_set_id = query_set_id } } });
    }

    pub fn set_pass_timestamp_writes(self: *Self, gpa: Allocator, query_set_id: u16, begin_index: u32, end_index: u32) !void {
        try self.record(gpa, .{ .call_type = .set_pass_timestamp_writes, .params = .{ .set_pass_timestamp_writes = .{ .query_set_id = query_set_id, .begin_index = begin_index, .end_index = end_index } } });
    }

    pub fn begin_occlusion_query(self: *Self, gpa: Allocator, query_index: u32) !void {
        self.notePassState(self.in_render_pass);
        try self.record(gpa, .{ .call_type = .begin_occlusion_query, .params = .{ .begin_occlusion_query = .{ .query_index = query_index } } });
    }

    pub fn end_occlusion_query(self: *Self, gpa: Allocator) !void {
        self.notePassState(self.in_render_pass);
        try self.record(gpa, .{ .call_type = .end_occlusion_query, .params = .{ .end_occlusion_query = .{} } });
    }

    pub fn resolve_query_set(self: *Self, gpa: Allocator, query_set_id: u16, first_query: u32, query_count: u32, dest_buffer_id: u16, dest_offset: u32) !void {
        try self.record(gpa, .{ .call_type = .resolve_query_set, .params = .{ .resolve_query_set = .{ .query_set_id = query_set_id, .first_query = first_query, .query_count = query_count, .dest_buffer_id = dest_buffer_id, .dest_offset = dest_offset } } });
    }

    pub fn set_stencil_reference(self: *Self, gpa: Allocator, reference: u32) !void {
        self.notePassState(self.in_render_pass);

        try self.record(gpa, .{
            .call_type = .set_stencil_reference,
            .params = .{ .set_stencil_reference = .{ .reference = reference } },
        });
    }

    pub fn set_blend_constant(self: *Self, gpa: Allocator, r_bits: u32, g_bits: u32, b_bits: u32, a_bits: u32) !void {
        self.notePassState(self.in_render_pass);

        try self.record(gpa, .{
            .call_type = .set_blend_constant,
            .params = .{ .set_blend_constant = .{ .r_bits = r_bits, .g_bits = g_bits, .b_bits = b_bits, .a_bits = a_bits } },
        });
    }

    pub fn set_scissor_rect(self: *Self, gpa: Allocator, x: u32, y: u32, width: u32, height: u32) !void {
        self.notePassState(self.in_render_pass);

        try self.record(gpa, .{
            .call_type = .set_scissor_rect,
            .params = .{ .set_scissor_rect = .{
                .x = x,
                .y = y,
                .width = width,
                .height = height,
            } },
        });
    }

    pub fn set_pass_depth_stencil_ops(self: *Self, gpa: Allocator, depth_load_op: u8, depth_store_op: u8, stencil_load_op: u8, stencil_store_op: u8) !void {
        try self.record(gpa, .{
            .call_type = .set_pass_depth_stencil_ops,
            .params = .{ .set_pass_depth_stencil_ops = .{
                .depth_load_op = depth_load_op,
                .depth_store_op = depth_store_op,
                .stencil_load_op = stencil_load_op,
                .stencil_store_op = stencil_store_op,
            } },
        });
    }

    pub fn set_pass_clear_values(self: *Self, gpa: Allocator, depth_bits: u32, stencil_value: u32) !void {
        try self.record(gpa, .{
            .call_type = .set_pass_clear_values,
            .params = .{ .set_pass_clear_values = .{
                .depth_bits = depth_bits,
                .stencil_value = stencil_value,
            } },
        });
    }

    pub fn dispatch_indirect(self: *Self, gpa: Allocator, buffer_id: u16, offset: u32) !void {
        self.notePassState(self.in_compute_pass);

        try self.record(gpa, .{
            .call_type = .dispatch_indirect,
            .params = .{ .dispatch_indirect = .{
                .buffer_id = buffer_id,
                .offset = offset,
            } },
        });
    }

    /// Execute pre-recorded render bundles.
    pub fn execute_bundles(self: *Self, gpa: Allocator, bundle_ids: []const u16) !void {
        self.notePassState(self.in_render_pass);

        try self.record(gpa, .{
            .call_type = .execute_bundles,
            .params = .{ .execute_bundles = .{
                .bundle_count = @intCast(bundle_ids.len),
            } },
        });
    }

    pub fn end_pass(self: *Self, gpa: Allocator) !void {
        // Latched, not asserted: this is input, not a caller bug.
        self.notePassState(self.in_render_pass or self.in_compute_pass);

        self.in_render_pass = false;
        self.in_compute_pass = false;
        self.current_pipeline = null;

        try self.record(gpa, .{
            .call_type = .end_pass,
            .params = .{ .none = {} },
        });
    }

    // ========================================================================
    // Queue Operations
    // ========================================================================

    pub fn write_buffer(self: *Self, gpa: Allocator, buffer_id: u16, offset: u32, data_id: u16) !void {
        try self.record(gpa, .{
            .call_type = .write_buffer,
            .params = .{ .write_buffer = .{
                .buffer_id = buffer_id,
                .offset = offset,
                .data_id = data_id,
            } },
        });
    }

    /// Record a raw texture upload. `write` is copied by value, including its
    /// null-vs-zero presence, so the trace can distinguish an omitted stride or
    /// size from an authored zero.
    pub fn write_texture(self: *Self, gpa: Allocator, texture_id: u16, data_id: u16, write: texture_layout.WriteLayout) !void {
        try self.record(gpa, .{
            .call_type = .write_texture,
            .params = .{ .write_texture = .{
                .texture_id = texture_id,
                .data_id = data_id,
                .write = write,
            } },
        });
    }

    /// Record a buffer→texture copy. The CallType is the direction — the
    /// opcode — and every operand field (including presence) is copied by
    /// value, because the golden trace must pin all of them.
    pub fn copy_buffer_to_texture(self: *Self, gpa: Allocator, texture_id: u16, buffer_id: u16, write: texture_layout.WriteLayout) !void {
        try self.record(gpa, .{
            .call_type = .copy_buffer_to_texture,
            .params = .{ .copy_buffer_to_texture = .{
                .texture_id = texture_id,
                .buffer_id = buffer_id,
                .write = write,
            } },
        });
    }

    /// Record a texture→buffer copy, the byte-preserving readback direction.
    pub fn copy_texture_to_buffer(self: *Self, gpa: Allocator, texture_id: u16, buffer_id: u16, write: texture_layout.WriteLayout) !void {
        try self.record(gpa, .{
            .call_type = .copy_texture_to_buffer,
            .params = .{ .copy_texture_to_buffer = .{
                .texture_id = texture_id,
                .buffer_id = buffer_id,
                .write = write,
            } },
        });
    }

    /// Record a controls write (frame program §7.1). The VALUES are copied in
    /// so a test can read them back from the log — including what slot 0
    /// (`time`) would have contributed, which is nothing: the handler slices
    /// the declared controls only.
    pub fn write_controls(self: *Self, gpa: Allocator, buffer_id: u16, offset: u32, values: []const f32) !void {
        var vals: [opcodes.MAX_CONTROLS]f32 = @splat(0);
        const count: u8 = @intCast(@min(values.len, opcodes.MAX_CONTROLS));
        @memcpy(vals[0..count], values[0..count]);
        try self.record(gpa, .{
            .call_type = .write_controls,
            .params = .{ .write_controls = .{
                .buffer_id = buffer_id,
                .offset = offset,
                .values = vals,
                .count = count,
            } },
        });
    }

    pub fn submit(self: *Self, gpa: Allocator) !void {
        // Latched, not asserted: a pass left open at submit is malformed input.
        self.notePassState(!self.in_render_pass and !self.in_compute_pass);

        try self.record(gpa, .{
            .call_type = .submit,
            .params = .{ .none = {} },
        });
    }

    pub fn create_image_bitmap(self: *Self, gpa: Allocator, bitmap_id: u16, blob_data_id: u16) !void {
        try self.record(gpa, .{
            .call_type = .create_image_bitmap,
            .params = .{ .create_image_bitmap = .{
                .bitmap_id = bitmap_id,
                .blob_data_id = blob_data_id,
            } },
        });
    }

    pub fn copy_external_image_to_texture(self: *Self, gpa: Allocator, bitmap_id: u16, texture_id: u16, mip_level: u8, origin_x: u16, origin_y: u16, origin_z: u16) !void {
        try self.record(gpa, .{
            .call_type = .copy_external_image_to_texture,
            .params = .{ .copy_external_image_to_texture = .{
                .bitmap_id = bitmap_id,
                .texture_id = texture_id,
                .mip_level = mip_level,
                .origin_x = origin_x,
                .origin_y = origin_y,
                .origin_z = origin_z,
            } },
        });
    }

    // ========================================================================
    // Copy Operations
    // ========================================================================

    pub fn copy_buffer_to_buffer(self: *Self, gpa: Allocator, src_buffer: u16, src_offset: u32, dst_buffer: u16, dst_offset: u32, size: u32) !void {
        try self.record(gpa, .{
            .call_type = .copy_buffer_to_buffer,
            .params = .{ .copy_buffer_to_buffer = .{
                .src_buffer = src_buffer,
                .src_offset = src_offset,
                .dst_buffer = dst_buffer,
                .dst_offset = dst_offset,
                .size = size,
            } },
        });
    }

    pub fn copy_texture_to_texture(self: *Self, gpa: Allocator, src_texture: u16, dst_texture: u16) !void {
        try self.record(gpa, .{
            .call_type = .copy_texture_to_texture,
            .params = .{ .copy_texture_to_texture = .{
                .src_texture = src_texture,
                .dst_texture = dst_texture,
            } },
        });
    }

    /// Record a subresource texture→texture copy. The normalized
    /// `SubresourceCopy` is copied by value, so the golden pins the presence
    /// of the size as well as every field.
    pub fn copy_texture_subresource(self: *Self, gpa: Allocator, source_id: u16, destination_id: u16, copy: texture_layout.SubresourceCopy) !void {
        // The ids are separate arguments because the wire carries them twice
        // (once as operands, once inside the normalized copy); the reference
        // proves the decode kept the two in step.
        std.debug.assert(source_id == copy.source.texture_id);
        std.debug.assert(destination_id == copy.destination.texture_id);
        try self.record(gpa, .{
            .call_type = .copy_texture_subresource,
            .params = .{ .copy_texture_subresource = copy },
        });
    }

    pub fn write_uniform(self: *Self, gpa: Allocator, buffer_id: u16, uniform_id: u16) !void {
        try self.record(gpa, .{
            .call_type = .write_uniform,
            .params = .{ .write_uniform = .{
                .buffer_id = buffer_id,
                .uniform_id = uniform_id,
            } },
        });
    }

    // ========================================================================
    // WASM Operations
    // ========================================================================

    pub fn init_wasm_module(self: *Self, gpa: Allocator, module_id: u16, wasm_data_id: u16) !void {
        try self.record(gpa, .{
            .call_type = .init_wasm_module,
            .params = .{ .init_wasm_module = .{
                .module_id = module_id,
                .wasm_data_id = wasm_data_id,
            } },
        });
    }

    pub fn call_wasm_func(self: *Self, gpa: Allocator, call_id: u16, module_id: u16, func_name_id: u16, args: []const u8) !void {
        _ = args; // Args passed to JS at runtime, not needed for mock
        try self.record(gpa, .{
            .call_type = .call_wasm_func,
            .params = .{ .call_wasm_func = .{
                .call_id = call_id,
                .module_id = module_id,
                .func_name_id = func_name_id,
            } },
        });
    }

    pub fn write_buffer_from_wasm(self: *Self, gpa: Allocator, call_id: u16, buffer_id: u16, offset: u32, byte_len: u32) !void {
        try self.record(gpa, .{
            .call_type = .write_buffer_from_wasm,
            .params = .{ .write_buffer_from_wasm = .{
                .call_id = call_id,
                .buffer_id = buffer_id,
                .offset = offset,
                .byte_len = byte_len,
            } },
        });
    }

    pub fn write_time_uniform(self: *Self, gpa: Allocator, buffer_id: u16, buffer_offset: u32, size: u16) !void {
        try self.uniform_writes.append(gpa, .{ .kind = .time, .buffer_id = buffer_id, .offset = buffer_offset, .size = size });
    }

    pub fn write_pointer_uniform(self: *Self, gpa: Allocator, buffer_id: u16, buffer_offset: u32, size: u16) !void {
        try self.uniform_writes.append(gpa, .{ .kind = .pointer, .buffer_id = buffer_id, .offset = buffer_offset, .size = size });
    }

    pub fn write_audio_data(self: *Self, gpa: Allocator, buffer_id: u16, buffer_offset: u32, size: u16) !void {
        _ = self;
        _ = gpa;
        _ = buffer_id;
        _ = buffer_offset;
        _ = size;
    }

    // ========================================================================
    // Verification
    // ========================================================================

    /// Get call count.
    pub fn call_count(self: *const Self) usize {
        return self.calls.items.len;
    }

    /// Get call at index.
    pub fn get_call(self: *const Self, index: usize) Call {
        return self.calls.items[index];
    }

    /// Get all calls as slice.
    pub fn get_calls(self: *const Self) []const Call {
        return self.calls.items;
    }

    /// Get all recorded runtime-uniform writes (see `uniform_writes`).
    pub fn get_uniform_writes(self: *const Self) []const UniformWrite {
        return self.uniform_writes.items;
    }

    /// Check if call sequence matches expected types.
    pub fn expect_call_types(self: *const Self, expected: []const CallType) bool {
        if (self.calls.items.len != expected.len) return false;

        for (self.calls.items, expected) |call, exp| {
            if (call.call_type != exp) return false;
        }

        return true;
    }

    /// Print all recorded calls for debugging.
    pub fn dump_calls(self: *const Self, writer: anytype) !void {
        // 512, not 256: an 8-attachment 0x81 trace names targets AND resolves,
        // which can exceed the old size and fall back to a detail-free line.
        var buf: [512]u8 = undefined;
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

// ============================================================================
// New Method Tests (createImageBitmap, copyExternalImageToTexture)
// ============================================================================

// ============================================================================
// WASM Plugin Tests
// ============================================================================

// ============================================================================
// WASM OOM Tests
// ============================================================================

// ============================================================================
// Copy Operation Tests
// ============================================================================
