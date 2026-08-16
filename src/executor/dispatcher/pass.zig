//! Pass Operations Handler
//!
//! Handles render and compute pass opcodes:
//! - begin_render_pass, begin_compute_pass, end_pass
//! - set_pipeline, set_bind_group, set_vertex_buffer, set_index_buffer
//! - draw, draw_indexed, dispatch
//! - execute_bundles
//!
//! ## Invariants
//!
//! - Pass operations must occur within begin/end pass pairs
//! - Pipeline must be set before draw/dispatch

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const bytecode_mod = @import("bytecode");
const OpCode = bytecode_mod.opcodes.OpCode;
const bytecode_emitter = bytecode_mod.emitter.Emitter;
const wire = bytecode_mod.wire_schema;

/// Colour attachments per MRT pass — the wire schema's cap, not a local one.
const MAX_MRT: usize = wire.repMaxOf(.begin_render_pass_mrt);

/// Bundles per `execute_bundles` — likewise from the schema.
const MAX_BUNDLES: usize = wire.repMaxOf(.execute_bundles);

/// Handle pass operation opcodes.
///
/// Fixed-shape ops decode via the shared wire schema (`wire.readOperands`) then
/// call the backend. Two count-prefixed ops decode manually:
/// begin_render_pass_mrt (up to 8 attachments → `[8]ColorAttachment`) and
/// execute_bundles (reads every bundle id but stores only 16 for the backend).
///
/// Returns true if the opcode was handled, false if it should be handled elsewhere.
pub fn handle(
    comptime Self: type,
    self: *Self,
    op: OpCode,
    allocator: Allocator,
) !bool {
    // Pre-condition: valid opcode for this handler
    assert(is_pass_opcode(op));

    switch (op) {
        .begin_render_pass => {
            const p = try wire.readOperands(wire.layoutOf(.begin_render_pass), self);
            try self.backend.begin_render_pass(
                allocator,
                try wire.narrowU16(p.color_texture_id),
                p.load_op,
                p.store_op,
                try wire.narrowU16(p.depth_texture_id),
                p.clear_r,
                p.clear_g,
                p.clear_b,
                p.clear_a,
                try wire.narrowU16(p.resolve_texture_id),
            );
        },

        .begin_render_pass_mrt => {
            // Rep group: up to MAX_MRT attachments then a depth id — decoded
            // manually because it maps onto the backend's ColorAttachment array.
            const count = try self.read_byte();
            // Over-cap desyncs the stream rather than overflowing anything — see
            // the `RepCountOverCap` doc comment.
            if (count > MAX_MRT) return error.RepCountOverCap;
            var attachments: [MAX_MRT]bytecode_emitter.ColorAttachment = undefined;
            for (0..count) |i| {
                attachments[i] = .{
                    .texture_id = try wire.narrowU16(try self.read_varint()),
                    .load_op = @enumFromInt(try self.read_byte()),
                    .store_op = @enumFromInt(try self.read_byte()),
                    .clear_r = try self.read_byte(),
                    .clear_g = try self.read_byte(),
                    .clear_b = try self.read_byte(),
                    .clear_a = try self.read_byte(),
                };
            }
            const depth_texture_id = try self.read_varint();
            try self.backend.begin_render_pass_mrt(
                allocator,
                attachments[0..count],
                @intCast(depth_texture_id),
            );
        },

        .begin_compute_pass => {
            try self.backend.begin_compute_pass(allocator);
        },

        .set_pipeline => {
            const p = try wire.readOperands(wire.layoutOf(.set_pipeline), self);
            try self.backend.set_pipeline(allocator, try wire.narrowU16(p.v0));
        },

        .set_bind_group => {
            const p = try wire.readOperands(wire.layoutOf(.set_bind_group), self);
            try self.backend.set_bind_group(allocator, p.slot, try wire.narrowU16(p.id));
        },

        .set_vertex_buffer => {
            const p = try wire.readOperands(wire.layoutOf(.set_vertex_buffer), self);
            try self.backend.set_vertex_buffer(allocator, p.slot, try wire.narrowU16(p.id));
        },

        .set_index_buffer => {
            const p = try wire.readOperands(wire.layoutOf(.set_index_buffer), self);
            try self.backend.set_index_buffer(allocator, try wire.narrowU16(p.buffer_id), p.index_format);
        },

        .draw => {
            const p = try wire.readOperands(wire.layoutOf(.draw), self);
            try self.backend.draw(allocator, p.v0, p.v1, p.v2, p.v3);
        },

        .draw_indexed => {
            const p = try wire.readOperands(wire.layoutOf(.draw_indexed), self);
            try self.backend.draw_indexed(allocator, p.v0, p.v1, p.v2, p.v3, p.v4);
        },

        .dispatch => {
            const p = try wire.readOperands(wire.layoutOf(.dispatch), self);
            // Debug logging for WASM builds
            if (@import("builtin").target.cpu.arch == .wasm32) {
                const debug_log = @import("debug_log.zig");
                debug_log.gpuDebugLog(20, p.v0); // dispatch x
                debug_log.gpuDebugLog(21, p.v1); // dispatch y
                debug_log.gpuDebugLog(22, p.v2); // dispatch z
            }
            try self.backend.dispatch(allocator, p.v0, p.v1, p.v2);
        },

        .set_viewport => {
            const p = try wire.readOperands(wire.layoutOf(.set_viewport), self);
            try self.backend.set_viewport(allocator, p.x, p.y, p.w, p.h, p.min_depth, p.max_depth);
        },

        .set_pass_occlusion_query_set => {
            const p = try wire.readOperands(wire.layoutOf(.set_pass_occlusion_query_set), self);
            try self.backend.set_pass_occlusion_query_set(allocator, try wire.narrowU16(p.v0));
        },

        .set_pass_timestamp_writes => {
            const p = try wire.readOperands(wire.layoutOf(.set_pass_timestamp_writes), self);
            try self.backend.set_pass_timestamp_writes(allocator, try wire.narrowU16(p.v0), p.v1, p.v2);
        },

        .begin_occlusion_query => {
            const p = try wire.readOperands(wire.layoutOf(.begin_occlusion_query), self);
            try self.backend.begin_occlusion_query(allocator, p.v0);
        },

        .end_occlusion_query => {
            try self.backend.end_occlusion_query(allocator);
        },

        .set_stencil_reference => {
            const p = try wire.readOperands(wire.layoutOf(.set_stencil_reference), self);
            try self.backend.set_stencil_reference(allocator, p.v0);
        },

        .set_scissor_rect => {
            const p = try wire.readOperands(wire.layoutOf(.set_scissor_rect), self);
            try self.backend.set_scissor_rect(allocator, p.v0, p.v1, p.v2, p.v3);
        },

        .set_pass_depth_stencil_ops => {
            const p = try wire.readOperands(wire.layoutOf(.set_pass_depth_stencil_ops), self);
            try self.backend.set_pass_depth_stencil_ops(allocator, p.depth_load_op, p.depth_store_op, p.stencil_load_op, p.stencil_store_op);
        },

        .set_blend_constant => {
            const p = try wire.readOperands(wire.layoutOf(.set_blend_constant), self);
            try self.backend.set_blend_constant(allocator, p.r, p.g, p.b, p.a);
        },

        .set_pass_clear_values => {
            const p = try wire.readOperands(wire.layoutOf(.set_pass_clear_values), self);
            try self.backend.set_pass_clear_values(allocator, p.depth_bits, p.stencil_value);
        },

        .draw_indirect => {
            const p = try wire.readOperands(wire.layoutOf(.draw_indirect), self);
            try self.backend.draw_indirect(allocator, try wire.narrowU16(p.v0), p.v1);
        },

        .draw_indexed_indirect => {
            const p = try wire.readOperands(wire.layoutOf(.draw_indexed_indirect), self);
            try self.backend.draw_indexed_indirect(allocator, try wire.narrowU16(p.v0), p.v1);
        },

        .dispatch_indirect => {
            const p = try wire.readOperands(wire.layoutOf(.dispatch_indirect), self);
            try self.backend.dispatch_indirect(allocator, try wire.narrowU16(p.v0), p.v1);
        },

        .execute_bundles => {
            // Rep group, decoded manually. This used to read every id and
            // discard the surplus past 16, which kept it agreeing with the
            // shipping executor (which did the same) and disagreeing with
            // `skipParams`, whose clamp is the schema's cap — 10_000 bytes
            // apart at 60_000 ids (§320). Refusing is what keeps all three
            // together; the frontend rejects over-cap passes up front, so no
            // compiled PNG reaches this.
            const bundle_count = try self.read_varint();
            if (bundle_count > MAX_BUNDLES) return error.RepCountOverCap;
            var bundle_ids: [MAX_BUNDLES]u16 = undefined;
            for (0..bundle_count) |i| {
                bundle_ids[i] = try wire.narrowU16(try self.read_varint());
            }
            try self.backend.execute_bundles(allocator, bundle_ids[0..bundle_count]);
        },

        .end_pass => {
            try self.backend.end_pass(allocator);
        },

        else => return false,
    }

    return true;
}

/// Check if opcode is a pass operation opcode.
pub fn is_pass_opcode(op: OpCode) bool {
    return switch (op) {
        .begin_render_pass,
        .begin_render_pass_mrt,
        .begin_compute_pass,
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
        .set_viewport,
        .set_pass_occlusion_query_set,
        .set_pass_timestamp_writes,
        .begin_occlusion_query,
        .end_occlusion_query,
        .set_stencil_reference,
        .set_scissor_rect,
        .set_pass_depth_stencil_ops,
        .set_blend_constant,
        .set_pass_clear_values,
        .execute_bundles,
        .end_pass,
        => true,
        else => false,
    };
}
