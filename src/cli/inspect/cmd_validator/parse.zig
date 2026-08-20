//! Command-buffer byte-stream parsing: parseCommands/parseParams. Split out
//! of the original single-file cmd_validator.zig; re-exported by
//! ../cmd_validator.zig.

const std = @import("std");
const pngine = @import("pngine");
const Cmd = pngine.command_buffer.Cmd;
const desc = pngine.types.descriptors;

const cv_shared = @import("params.zig");
const MAX_COMMANDS = cv_shared.MAX_COMMANDS;
const MAX_RESOURCES = cv_shared.MAX_RESOURCES;
const BufferUsage = cv_shared.BufferUsage;
const TextureUsage = cv_shared.TextureUsage;
const CANVAS_TEXTURE_ID = cv_shared.CANVAS_TEXTURE_ID;
const NO_DEPTH_TEXTURE_ID = cv_shared.NO_DEPTH_TEXTURE_ID;
const Severity = cv_shared.Severity;
const Issue = cv_shared.Issue;
const PassState = cv_shared.PassState;
const Symptom = cv_shared.Symptom;
const DiagnosticCheck = cv_shared.DiagnosticCheck;
const Diagnosis = cv_shared.Diagnosis;
const BufferInfo = cv_shared.BufferInfo;
const TextureInfo = cv_shared.TextureInfo;
const ResourceInfo = cv_shared.ResourceInfo;
const DescriptorType = cv_shared.DescriptorType;
const TextureField = cv_shared.TextureField;
const ValueType = cv_shared.ValueType;
const PipelineInfo = cv_shared.PipelineInfo;
const ParsedCommand = cv_shared.ParsedCommand;
const writeJsonEscaped = cv_shared.writeJsonEscaped;
const CreateBufferParams = cv_shared.CreateBufferParams;
const CreateResourceParams = cv_shared.CreateResourceParams;
const CreateShaderParams = cv_shared.CreateShaderParams;
const CreateBindGroupParams = cv_shared.CreateBindGroupParams;
const CreateTextureViewParams = cv_shared.CreateTextureViewParams;
const BeginRenderPassParams = cv_shared.BeginRenderPassParams;
const SetPipelineParams = cv_shared.SetPipelineParams;
const SetBindGroupParams = cv_shared.SetBindGroupParams;
const SetVertexBufferParams = cv_shared.SetVertexBufferParams;
const SetIndexBufferParams = cv_shared.SetIndexBufferParams;
const DrawParams = cv_shared.DrawParams;
const DrawIndexedParams = cv_shared.DrawIndexedParams;
const DispatchParams = cv_shared.DispatchParams;
const WriteBufferParams = cv_shared.WriteBufferParams;
const WriteTimeUniformParams = cv_shared.WriteTimeUniformParams;
const CopyBufferParams = cv_shared.CopyBufferParams;
const CopyTextureParams = cv_shared.CopyTextureParams;
const CopyExternalImageParams = cv_shared.CopyExternalImageParams;
const InitWasmModuleParams = cv_shared.InitWasmModuleParams;
const CallWasmFuncParams = cv_shared.CallWasmFuncParams;
const WriteBufferFromWasmParams = cv_shared.WriteBufferFromWasmParams;

// ============================================================================
// JSON Serialization Helpers
// ============================================================================

/// Parse raw command buffer bytes into structured commands.
///
/// The command buffer format is:
/// │ u32: total_len │ u32: frame_count │ [commands...] │
///
/// Complexity: O(n) where n = data.len
///
/// Pre-condition: data.len >= 8 (header size)
/// Post-condition: Returns owned slice of parsed commands (caller must free)
pub fn parseCommands(allocator: std.mem.Allocator, data: []const u8) ![]ParsedCommand {
    // Pre-condition: minimum header size
    if (data.len < 8) return &[_]ParsedCommand{};

    const total_len = std.mem.readInt(u32, data[0..4], .little);

    // Validate header: total_len must not exceed data size
    if (total_len > data.len) return error.InvalidFormat;
    std.debug.assert(total_len >= 8);

    var commands = std.ArrayList(ParsedCommand).empty;
    errdefer commands.deinit(allocator);

    var pos: u32 = 8; // Skip 8-byte header
    var cmd_index: u32 = 0;

    // Bounded loop: prevent infinite loops on malformed input
    for (0..MAX_COMMANDS) |_| {
        if (pos >= total_len) break;

        const tag = data[pos];
        pos += 1;

        // Never `@enumFromInt` a byte we did not verify: inspect is a diagnostic
        // run over possibly-malformed input, and an unknown tag (or a decoder
        // desync that lands mid-operand) must surface as an error, not a panic.
        const cmd = std.enums.fromInt(Cmd, tag) orelse return error.InvalidFormat;
        const params = try parseParams(cmd, data, &pos);

        try commands.append(allocator, .{
            .index = cmd_index,
            .cmd = cmd,
            .params = params,
        });

        cmd_index += 1;

        if (cmd == .end) break;
    } else {
        // Loop exhausted without finding .end - malformed input
        return error.InvalidFormat;
    }

    const result = try commands.toOwnedSlice(allocator);

    // Post-condition: result length bounded
    std.debug.assert(result.len <= MAX_COMMANDS);

    return result;
}

/// Operand width of `cmd` in bytes, excluding the leading tag byte.
///
/// This is the reader's single source of truth for the command-buffer wire
/// layout; every entry mirrors one writer method in
/// `src/executor/command_buffer.zig`. Keeping width separate from field
/// decoding is what lets the ~19 commands whose operands this tool does not
/// interpret advance `pos` correctly without each carrying its own bounds
/// check and hand-written stride — the shape that made this function 317 lines
/// and let a stride typo hide in any one of forty near-identical arms.
///
/// Exception to the 70-line rule: a contiguous wire-layout table, one entry per
/// opcode. It is `wire_schema.zig:layoutOf` for the command-buffer opcode set.
///
/// Three commands are variable-width and read their own count byte, so this
/// needs `data`/`p` and reports `error.Truncated` when that byte is missing.
fn operandWidth(cmd: Cmd, data: []const u8, p: u32) !u32 {
    std.debug.assert(p <= data.len);
    const remaining = data.len - p;

    return switch (cmd) {
        // Variable width: a count byte, then that many fixed-size records.
        .begin_render_pass_mrt => blk: {
            if (remaining < 1) return error.Truncated;
            // count + attachments (tex_id:2 load:1 store:1 rgba:4) + depth_id:2
            break :blk 1 + @as(u32, data[p]) * 8 + 2;
        },
        .begin_render_pass_mrt_f32 => blk: {
            if (remaining < 1) return error.Truncated;
            // count + attachments (tex_id:2 load:1 store:1 rgba:16) + depth_id:2
            break :blk 1 + @as(u32, data[p]) * 20 + 2;
        },
        .execute_bundles => blk: {
            if (remaining < 1) return error.Truncated;
            break :blk 1 + @as(u32, data[p]) * 2; // count + bundle ids
        },
        .call_wasm_func => blk: {
            // Args ride inline behind a fixed 13-byte head, not behind a
            // pointer/length pair (see `CommandBuffer.callWasmFunc`).
            if (remaining < 13) return error.Truncated;
            break :blk 13 + @as(u32, data[p + 12]);
        },

        // Fixed width, grouped by stride.
        .begin_compute_pass, .end_pass, .end_occlusion_query, .submit, .end => 0,
        .set_pipeline, .set_pass_occlusion_query_set => 2,
        .set_bind_group, .set_vertex_buffer, .set_index_buffer => 3,
        .begin_occlusion_query, .set_stencil_reference, .set_pass_depth_stencil_ops => 4,
        .draw_indirect, .draw_indexed_indirect, .dispatch_indirect, .set_pass_timestamp_writes => 6,
        .create_buffer, .write_time_uniform, .write_pointer_uniform, .copy_texture_to_texture, .set_pass_clear_values => 8,
        .create_texture, .create_sampler, .create_shader, .create_query_set, .create_bind_group_layout, .create_pipeline_layout, .create_render_bundle, .create_render_pipeline, .create_compute_pipeline, .create_image_bitmap, .init_wasm_module => 10,
        .copy_external_image_to_texture => 11,
        .create_bind_group, .create_texture_view, .begin_render_pass, .dispatch => 12,
        .write_buffer, .write_buffer_from_wasm => 14,
        .draw, .set_scissor_rect, .set_blend_constant, .copy_buffer_to_buffer, .resolve_query_set => 16,
        .draw_indexed => 20,
        .set_viewport, .begin_render_pass_f32 => 24,
    };
}

/// Parse command parameters from buffer, advancing `pos` past them.
///
/// Two phases: `operandWidth` decides how far to advance (and is the only
/// place strides live), then a family decoder reads the fields this tool cares
/// about. Commands whose operands are not interpreted decode to `.none` but
/// still advance correctly.
fn parseParams(cmd: Cmd, data: []const u8, pos: *u32) !ParsedCommand.Params {
    const p = pos.*;
    std.debug.assert(p <= data.len);

    const width = try operandWidth(cmd, data, p);
    if (data.len - p < width) return error.Truncated;
    pos.* = p + width;

    // Decode is split along the command set's own families — the 0x0N / 0x1N /
    // 0x2N ranges `Cmd` documents — matching the executor's dispatcher split
    // and the `--html` codegen's.
    return switch (cmd) {
        .create_buffer,
        .create_texture,
        .create_sampler,
        .create_shader,
        .create_render_pipeline,
        .create_compute_pipeline,
        .create_bind_group,
        .create_texture_view,
        .create_query_set,
        .create_bind_group_layout,
        .create_image_bitmap,
        .create_pipeline_layout,
        .create_render_bundle,
        => decodeCreateParams(cmd, data, p),

        .begin_render_pass,
        .begin_render_pass_f32,
        .set_pipeline,
        .set_bind_group,
        .set_vertex_buffer,
        .set_index_buffer,
        .draw,
        .draw_indexed,
        .dispatch,
        .draw_indirect,
        .draw_indexed_indirect,
        .dispatch_indirect,
        => decodePassParams(cmd, data, p),

        .write_buffer,
        .write_time_uniform,
        .write_pointer_uniform,
        .copy_buffer_to_buffer,
        .copy_texture_to_texture,
        .copy_external_image_to_texture,
        .write_buffer_from_wasm,
        .init_wasm_module,
        .call_wasm_func,
        => decodeQueueParams(cmd, data, p),

        else => .{ .none = {} },
    };
}

/// Decode resource-creation operands (`Cmd` 0x01–0x0F).
///
/// Pre-condition: `parseParams` has already bounds-checked `operandWidth` bytes
/// from `p`, so every read here is in range.
fn decodeCreateParams(cmd: Cmd, data: []const u8, p: u32) ParsedCommand.Params {
    return switch (cmd) {
        .create_buffer => .{ .create_buffer = .{
            .id = readU16(data, p),
            .size = readU32(data, p + 2),
            .usage = readU16(data, p + 6),
        } },
        .create_shader => .{ .create_shader = .{
            .id = readU16(data, p),
            .code_ptr = readU32(data, p + 2),
            .code_len = readU32(data, p + 6),
        } },
        .create_bind_group => .{ .create_bind_group = .{
            .id = readU16(data, p),
            .layout_id = readU16(data, p + 2),
            .entries_ptr = readU32(data, p + 4),
            .entries_len = readU32(data, p + 8),
        } },
        .create_texture_view => .{ .create_texture_view = .{
            .id = readU16(data, p),
            .texture_id = readU16(data, p + 2),
            .desc_ptr = readU32(data, p + 4),
            .desc_len = readU32(data, p + 8),
        } },
        // Everything else in the family is the same id + descriptor blob.
        else => .{ .create_resource = .{
            .id = readU16(data, p),
            .desc_ptr = readU32(data, p + 2),
            .desc_len = readU32(data, p + 6),
        } },
    };
}

/// Decode pass operands (`Cmd` 0x10–0x1F).
///
/// Pre-condition: `parseParams` has already bounds-checked the operand bytes.
fn decodePassParams(cmd: Cmd, data: []const u8, p: u32) ParsedCommand.Params {
    return switch (cmd) {
        .begin_render_pass => .{ .begin_render_pass = .{
            .color_id = readU16(data, p),
            .load_op = data[p + 2],
            .store_op = data[p + 3],
            .depth_id = readU16(data, p + 4),
            .clear_r = data[p + 6],
            .clear_g = data[p + 7],
            .clear_b = data[p + 8],
            .clear_a = data[p + 9],
        } },
        .begin_render_pass_f32 => .{ .begin_render_pass_f32 = .{
            .color_id = readU16(data, p),
            .load_op = data[p + 2],
            .store_op = data[p + 3],
            .depth_id = readU16(data, p + 4),
            .clear_r_bits = readU32(data, p + 6),
            .clear_g_bits = readU32(data, p + 10),
            .clear_b_bits = readU32(data, p + 14),
            .clear_a_bits = readU32(data, p + 18),
            .resolve_id = readU16(data, p + 22),
        } },
        .set_pipeline => .{ .set_pipeline = .{ .id = readU16(data, p) } },
        .set_bind_group => .{ .set_bind_group = .{
            .slot = data[p],
            .id = readU16(data, p + 1),
        } },
        .set_vertex_buffer => .{ .set_vertex_buffer = .{
            .slot = data[p],
            .id = readU16(data, p + 1),
        } },
        .set_index_buffer => .{ .set_index_buffer = .{
            .id = readU16(data, p),
            .format = data[p + 2],
        } },
        .draw => .{ .draw = .{
            .vertex_count = readU32(data, p),
            .instance_count = readU32(data, p + 4),
            .first_vertex = readU32(data, p + 8),
            .first_instance = readU32(data, p + 12),
        } },
        .draw_indexed => .{ .draw_indexed = .{
            .index_count = readU32(data, p),
            .instance_count = readU32(data, p + 4),
            .first_index = readU32(data, p + 8),
            .base_vertex = readU32(data, p + 12),
            .first_instance = readU32(data, p + 16),
        } },
        .dispatch => .{ .dispatch = .{
            .x = readU32(data, p),
            .y = readU32(data, p + 4),
            .z = readU32(data, p + 8),
        } },
        // The three indirect forms share one shape. Decoding them is what lets
        // the validator see that a draw happens at all (§337).
        else => .{ .indirect = .{
            .id = readU16(data, p),
            .offset = readU32(data, p + 2),
        } },
    };
}

/// Decode queue and WASM operands (`Cmd` 0x20–0x2F, 0x30–0x3F).
///
/// Pre-condition: `parseParams` has already bounds-checked the operand bytes.
fn decodeQueueParams(cmd: Cmd, data: []const u8, p: u32) ParsedCommand.Params {
    return switch (cmd) {
        .write_buffer => .{ .write_buffer = .{
            .id = readU16(data, p),
            .offset = readU32(data, p + 2),
            .data_ptr = readU32(data, p + 6),
            .data_len = readU32(data, p + 10),
        } },
        .write_time_uniform => .{ .write_time_uniform = .{
            .id = readU16(data, p),
            .offset = readU32(data, p + 2),
            .size = readU16(data, p + 6),
        } },
        .write_pointer_uniform => .{ .write_pointer_uniform = .{
            .id = readU16(data, p),
            .offset = readU32(data, p + 2),
            .size = readU16(data, p + 6),
        } },
        .copy_buffer_to_buffer => .{ .copy_buffer = .{
            .src_id = readU16(data, p),
            .src_offset = readU32(data, p + 2),
            .dst_id = readU16(data, p + 6),
            .dst_offset = readU32(data, p + 8),
            .size = readU32(data, p + 12),
        } },
        .copy_texture_to_texture => .{ .copy_texture = .{
            .src_id = readU16(data, p),
            .dst_id = readU16(data, p + 2),
            .width = readU16(data, p + 4),
            .height = readU16(data, p + 6),
        } },
        .copy_external_image_to_texture => .{ .copy_external_image = .{
            .bitmap_id = readU16(data, p),
            .texture_id = readU16(data, p + 2),
            .mip_level = data[p + 4],
            .origin_x = readU16(data, p + 5),
            .origin_y = readU16(data, p + 7),
            .origin_z = readU16(data, p + 9),
        } },
        .write_buffer_from_wasm => .{ .write_buffer_from_wasm = .{
            .buffer_id = readU16(data, p),
            .buffer_offset = readU32(data, p + 2),
            .wasm_ptr = readU32(data, p + 6),
            .size = readU32(data, p + 10),
        } },
        .init_wasm_module => .{ .init_wasm_module = .{
            .module_id = readU16(data, p),
            .data_ptr = readU32(data, p + 2),
            .data_len = readU32(data, p + 6),
        } },
        else => .{ .call_wasm_func = .{
            .call_id = readU16(data, p),
            .module_id = readU16(data, p + 2),
            .func_ptr = readU32(data, p + 4),
            .func_len = readU32(data, p + 8),
            .args_len = data[p + 12],
        } },
    };
}

/// Read little-endian u16 from data at offset.
/// Pre-condition: offset + 2 <= data.len
inline fn readU16(data: []const u8, offset: u32) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

/// Read little-endian u32 from data at offset.
/// Pre-condition: offset + 4 <= data.len
inline fn readU32(data: []const u8, offset: u32) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Emit one of every `Cmd` through the real writer, returning the tag order.
///
/// Field values are arbitrary but distinct, so a decoder reading the right
/// bytes at the wrong offset produces a visibly wrong number rather than a
/// plausible one.
///
/// Exception to the 70-line rule: a contiguous data table — one writer call per
/// opcode, then the tag sequence they produce. The two halves have to be read
/// against each other, so splitting them into separate functions would hide the
/// one property that matters (that they correspond).
fn writeOneOfEveryCommand(cb: *pngine.command_buffer.CommandBuffer) []const Cmd {
    const Att = pngine.emitter.Emitter.ColorAttachment;
    // Two attachment shapes because there are two MRT opcodes: 0x1B takes 0-255
    // bytes and 0x54 takes f32 bit patterns (spec/09 step D). The legacy pair is
    // retired from emission but still decoded, so both belong in a table whose
    // job is one writer call per opcode.
    const atts = [_]Att{.{ .texture_id = 7, .load_op = .clear, .store_op = .store, .clear_r_bits = 1, .clear_g_bits = 2, .clear_b_bits = 3, .clear_a_bits = 4 }};
    const legacy_atts = [_]pngine.command_buffer.CommandBuffer.LegacyColorAttachment{
        .{ .texture_id = 7, .load_op = 1, .store_op = 0, .clear_r = 1, .clear_g = 2, .clear_b = 3, .clear_a = 4 },
    };

    cb.createBuffer(1, 256, 0x20);
    cb.createTexture(2, 100, 20);
    cb.createSampler(3, 120, 20);
    cb.createShader(4, 140, 30);
    cb.createRenderPipeline(5, 170, 40);
    cb.createComputePipeline(6, 210, 40);
    cb.createBindGroup(7, 5, 250, 16);
    cb.createTextureView(8, 2, 266, 12);
    cb.createQuerySet(9, 278, 8);
    cb.createBindGroupLayout(10, 286, 8);
    cb.createImageBitmap(11, 294, 8);
    cb.createPipelineLayout(12, 302, 8);
    cb.createRenderBundle(13, 310, 8);

    cb.beginRenderPass(14, 1, 2, 15, 10, 20, 30, 40, 16);
    cb.setViewport(0, 0, 640, 480, 0.0, 1.0);
    cb.setScissorRect(1, 2, 3, 4);
    cb.setStencilReference(17);
    cb.setBlendConstant(0.1, 0.2, 0.3, 0.4);
    cb.setPassDepthStencilOps(1, 2, 3, 4);
    cb.setPassClearValues(0.5, 18);
    cb.setPassTimestampWrites(19, 20, 21);
    cb.setPassOcclusionQuerySet(22);
    cb.beginOcclusionQuery(23);
    cb.endOcclusionQuery();
    cb.setPipeline(24);
    cb.setBindGroup(1, 25);
    cb.setVertexBuffer(2, 26);
    cb.setIndexBuffer(27, 1);
    cb.draw(3, 1, 0, 0);
    cb.drawIndexed(6, 2, 0, 0, 0);
    cb.drawIndirect(28, 64);
    cb.drawIndexedIndirect(29, 128);
    cb.executeBundles(&[_]u16{ 13, 30 });
    cb.endPass();

    cb.beginRenderPassMRT(&legacy_atts, 31);
    cb.endPass();

    cb.beginRenderPassF32(14, 1, 2, 15, 10, 20, 30, 40, 16);
    cb.endPass();

    cb.beginRenderPassMrtF32(&atts, 31);
    cb.endPass();

    cb.beginComputePass();
    cb.dispatch(8, 4, 2);
    cb.dispatchIndirect(32, 256);
    cb.endPass();

    cb.writeBuffer(33, 4, 400, 16);
    cb.writeTimeUniform(34, 0, 16);
    cb.writePointerUniform(35, 16, 48);
    cb.copyBufferToBuffer(36, 0, 37, 8, 64);
    cb.copyTextureToTexture(38, 39, 128, 64);
    cb.copyExternalImageToTexture(11, 2, 0, 1, 2, 3);
    cb.writeBufferFromWasm(40, 0, 500, 32);
    cb.resolveQuerySet(9, 0, 4, 41, 0);

    cb.initWasmModule(42, 600, 100);
    cb.callWasmFunc(43, 42, 700, 4, &[_]u8{ 1, 2, 3 });

    cb.submit();
    cb.end();

    return &.{
        .create_buffer,             .create_texture,                 .create_sampler,             .create_shader,
        .create_render_pipeline,    .create_compute_pipeline,        .create_bind_group,          .create_texture_view,
        .create_query_set,          .create_bind_group_layout,       .create_image_bitmap,        .create_pipeline_layout,
        .create_render_bundle,      .begin_render_pass,              .set_viewport,               .set_scissor_rect,
        .set_stencil_reference,     .set_blend_constant,             .set_pass_depth_stencil_ops, .set_pass_clear_values,
        .set_pass_timestamp_writes, .set_pass_occlusion_query_set,   .begin_occlusion_query,      .end_occlusion_query,
        .set_pipeline,              .set_bind_group,                 .set_vertex_buffer,          .set_index_buffer,
        .draw,                      .draw_indexed,                   .draw_indirect,              .draw_indexed_indirect,
        .execute_bundles,           .end_pass,                       .begin_render_pass_mrt,      .end_pass,
        .begin_render_pass_f32,     .end_pass,                       .begin_render_pass_mrt_f32,  .end_pass,
        .begin_compute_pass,        .dispatch,                       .dispatch_indirect,          .end_pass,
        .write_buffer,              .write_time_uniform,             .write_pointer_uniform,      .copy_buffer_to_buffer,
        .copy_texture_to_texture,   .copy_external_image_to_texture, .write_buffer_from_wasm,     .resolve_query_set,
        .init_wasm_module,          .call_wasm_func,                 .submit,                     .end,
    };
}
