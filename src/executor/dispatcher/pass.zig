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

/// Handle pass operation opcodes.
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
            const color_texture_id = try self.read_varint();
            const load_op = try self.read_byte();
            const store_op = try self.read_byte();
            const depth_texture_id = try self.read_varint();
            try self.backend.begin_render_pass(
                allocator,
                @intCast(color_texture_id),
                load_op,
                store_op,
                @intCast(depth_texture_id),
            );
        },

        .begin_compute_pass => {
            try self.backend.begin_compute_pass(allocator);
        },

        .set_pipeline => {
            const pipeline_id = try self.read_varint();
            try self.backend.set_pipeline(allocator, @intCast(pipeline_id));
        },

        .set_bind_group => {
            const slot = try self.read_byte();
            const group_id = try self.read_varint();
            try self.backend.set_bind_group(allocator, slot, @intCast(group_id));
        },

        .set_vertex_buffer => {
            const slot = try self.read_byte();
            const buffer_id = try self.read_varint();
            try self.backend.set_vertex_buffer(allocator, slot, @intCast(buffer_id));
        },

        .set_index_buffer => {
            const buffer_id = try self.read_varint();
            const index_format = try self.read_byte();
            try self.backend.set_index_buffer(allocator, @intCast(buffer_id), index_format);
        },

        .draw => {
            const vertex_count = try self.read_varint();
            const instance_count = try self.read_varint();
            const first_vertex = try self.read_varint();
            const first_instance = try self.read_varint();
            try self.backend.draw(allocator, vertex_count, instance_count, first_vertex, first_instance);
        },

        .draw_indexed => {
            const index_count = try self.read_varint();
            const instance_count = try self.read_varint();
            const first_index = try self.read_varint();
            const base_vertex = try self.read_varint();
            const first_instance = try self.read_varint();
            try self.backend.draw_indexed(
                allocator,
                index_count,
                instance_count,
                first_index,
                base_vertex,
                first_instance,
            );
        },

        .dispatch => {
            const x = try self.read_varint();
            const y = try self.read_varint();
            const z = try self.read_varint();
            // Debug logging for WASM builds
            if (@import("builtin").target.cpu.arch == .wasm32) {
                const wasm_gpu = @import("../wasm_gpu.zig");
                wasm_gpu.gpuDebugLog(20, x); // dispatch x
                wasm_gpu.gpuDebugLog(21, y); // dispatch y
                wasm_gpu.gpuDebugLog(22, z); // dispatch z
            }
            try self.backend.dispatch(allocator, x, y, z);
        },

        .execute_bundles => {
            const bundle_count = try self.read_varint();
            // Read bundle IDs into temporary buffer
            var bundle_ids: [16]u16 = undefined;
            const count = @min(bundle_count, 16);
            for (0..count) |i| {
                bundle_ids[i] = @intCast(try self.read_varint());
            }
            // Skip any excess bundles
            for (count..bundle_count) |_| {
                _ = try self.read_varint();
            }
            try self.backend.execute_bundles(allocator, bundle_ids[0..count]);
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
        .begin_compute_pass,
        .set_pipeline,
        .set_bind_group,
        .set_vertex_buffer,
        .set_index_buffer,
        .draw,
        .draw_indexed,
        .dispatch,
        .execute_bundles,
        .end_pass,
        => true,
        else => false,
    };
}
