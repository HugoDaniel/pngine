//! Resource Creation Handler
//!
//! Handles GPU resource creation opcodes:
//! - create_buffer, create_texture, create_sampler
//! - create_shader_module, create_render_pipeline, create_compute_pipeline
//! - create_bind_group, create_bind_group_layout, create_pipeline_layout
//! - create_image_bitmap, create_texture_view, create_query_set, create_render_bundle
//!
//! ## Invariants
//!
//! - Resource IDs are unique per resource type
//! - Descriptor data IDs reference valid data section entries

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const bytecode_mod = @import("bytecode");
const OpCode = bytecode_mod.opcodes.OpCode;
const wire = bytecode_mod.wire_schema;

/// Handle resource creation opcodes.
///
/// Decodes operands through the shared wire schema (`wire.readOperands`) and
/// forwards them to the backend — the decode/effect split. All resource
/// opcodes are fixed-shape, so each arm is a decode + one backend call.
///
/// Returns true if the opcode was handled, false if it should be handled elsewhere.
pub fn handle(
    comptime Self: type,
    self: *Self,
    op: OpCode,
    allocator: Allocator,
) !bool {
    // Pre-condition: valid opcode for this handler
    assert(is_resource_opcode(op));

    switch (op) {
        .create_buffer => {
            const p = try wire.readOperands(wire.layoutOf(.create_buffer), self);
            const usage: u16 = @as(u16, p.usage_lo) | (@as(u16, p.usage_hi) << 8);
            try self.backend.create_buffer(allocator, try wire.narrowU16(p.buffer_id), p.size, usage);
        },

        .create_texture => {
            const p = try wire.readOperands(wire.layoutOf(.create_texture), self);
            try self.backend.create_texture(allocator, try wire.narrowU16(p.v0), try wire.narrowU16(p.v1));
        },

        .create_sampler => {
            const p = try wire.readOperands(wire.layoutOf(.create_sampler), self);
            try self.backend.create_sampler(allocator, try wire.narrowU16(p.v0), try wire.narrowU16(p.v1));
        },

        .create_shader_module => {
            const p = try wire.readOperands(wire.layoutOf(.create_shader_module), self);
            try self.backend.create_shader_module(allocator, try wire.narrowU16(p.v0), try wire.narrowU16(p.v1));
        },

        .create_render_pipeline => {
            const p = try wire.readOperands(wire.layoutOf(.create_render_pipeline), self);
            try self.backend.create_render_pipeline(allocator, try wire.narrowU16(p.v0), try wire.narrowU16(p.v1));
        },

        .create_compute_pipeline => {
            const p = try wire.readOperands(wire.layoutOf(.create_compute_pipeline), self);
            try self.backend.create_compute_pipeline(allocator, try wire.narrowU16(p.v0), try wire.narrowU16(p.v1));
        },

        .create_bind_group => {
            const p = try wire.readOperands(wire.layoutOf(.create_bind_group), self);
            try self.backend.create_bind_group(allocator, try wire.narrowU16(p.v0), try wire.narrowU16(p.v1), try wire.narrowU16(p.v2));
        },

        .create_bind_group_layout => {
            const p = try wire.readOperands(wire.layoutOf(.create_bind_group_layout), self);
            try self.backend.create_bind_group_layout(allocator, try wire.narrowU16(p.v0), try wire.narrowU16(p.v1));
        },

        .create_pipeline_layout => {
            const p = try wire.readOperands(wire.layoutOf(.create_pipeline_layout), self);
            try self.backend.create_pipeline_layout(allocator, try wire.narrowU16(p.v0), try wire.narrowU16(p.v1));
        },

        .create_image_bitmap => {
            const p = try wire.readOperands(wire.layoutOf(.create_image_bitmap), self);
            try self.backend.create_image_bitmap(allocator, try wire.narrowU16(p.v0), try wire.narrowU16(p.v1));
        },

        .create_texture_view => {
            const p = try wire.readOperands(wire.layoutOf(.create_texture_view), self);
            try self.backend.create_texture_view(allocator, try wire.narrowU16(p.v0), try wire.narrowU16(p.v1), try wire.narrowU16(p.v2));
        },

        .create_query_set => {
            const p = try wire.readOperands(wire.layoutOf(.create_query_set), self);
            try self.backend.create_query_set(allocator, try wire.narrowU16(p.v0), try wire.narrowU16(p.v1));
        },

        .create_render_bundle => {
            const p = try wire.readOperands(wire.layoutOf(.create_render_bundle), self);
            try self.backend.create_render_bundle(allocator, try wire.narrowU16(p.v0), try wire.narrowU16(p.v1));
        },

        else => return false,
    }

    return true;
}

/// Check if opcode is a resource creation opcode.
pub fn is_resource_opcode(op: OpCode) bool {
    return switch (op) {
        .create_buffer,
        .create_texture,
        .create_sampler,
        .create_shader_module,
        .create_render_pipeline,
        .create_compute_pipeline,
        .create_bind_group,
        .create_bind_group_layout,
        .create_pipeline_layout,
        .create_image_bitmap,
        .create_texture_view,
        .create_query_set,
        .create_render_bundle,
        => true,
        else => false,
    };
}
