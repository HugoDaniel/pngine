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

/// Handle resource creation opcodes.
///
/// Returns true if the opcode was handled, false if it should be handled elsewhere.
pub fn handle(
    comptime Self: type,
    self: *Self,
    op: OpCode,
    allocator: Allocator,
) !bool {
    // Pre-condition: valid opcode for this handler
    assert(isResourceOpcode(op));

    switch (op) {
        .create_buffer => {
            const buffer_id = try self.readVarint();
            const size = try self.readVarint();
            const usage = try self.readByte();
            try self.backend.create_buffer(allocator, @intCast(buffer_id), size, usage);
        },

        .create_texture => {
            const texture_id = try self.readVarint();
            const descriptor_data_id = try self.readVarint();
            try self.backend.create_texture(allocator, @intCast(texture_id), @intCast(descriptor_data_id));
        },

        .create_sampler => {
            const sampler_id = try self.readVarint();
            const descriptor_data_id = try self.readVarint();
            try self.backend.create_sampler(allocator, @intCast(sampler_id), @intCast(descriptor_data_id));
        },

        .create_shader_module => {
            const shader_id = try self.readVarint();
            const code_data_id = try self.readVarint();
            try self.backend.create_shader_module(allocator, @intCast(shader_id), @intCast(code_data_id));
        },

        .create_render_pipeline => {
            const pipeline_id = try self.readVarint();
            const descriptor_data_id = try self.readVarint();
            try self.backend.create_render_pipeline(allocator, @intCast(pipeline_id), @intCast(descriptor_data_id));
        },

        .create_compute_pipeline => {
            const pipeline_id = try self.readVarint();
            const descriptor_data_id = try self.readVarint();
            try self.backend.create_compute_pipeline(allocator, @intCast(pipeline_id), @intCast(descriptor_data_id));
        },

        .create_bind_group => {
            const group_id = try self.readVarint();
            const layout_id = try self.readVarint();
            const entry_data_id = try self.readVarint();
            try self.backend.create_bind_group(allocator, @intCast(group_id), @intCast(layout_id), @intCast(entry_data_id));
        },

        .create_bind_group_layout => {
            const layout_id = try self.readVarint();
            const descriptor_data_id = try self.readVarint();
            try self.backend.create_bind_group_layout(allocator, @intCast(layout_id), @intCast(descriptor_data_id));
        },

        .create_pipeline_layout => {
            const layout_id = try self.readVarint();
            const descriptor_data_id = try self.readVarint();
            try self.backend.create_pipeline_layout(allocator, @intCast(layout_id), @intCast(descriptor_data_id));
        },

        .create_image_bitmap => {
            const bitmap_id = try self.readVarint();
            const blob_data_id = try self.readVarint();
            try self.backend.create_image_bitmap(allocator, @intCast(bitmap_id), @intCast(blob_data_id));
        },

        .create_texture_view => {
            const view_id = try self.readVarint();
            const texture_id = try self.readVarint();
            const descriptor_data_id = try self.readVarint();
            try self.backend.create_texture_view(allocator, @intCast(view_id), @intCast(texture_id), @intCast(descriptor_data_id));
        },

        .create_query_set => {
            const query_set_id = try self.readVarint();
            const descriptor_data_id = try self.readVarint();
            try self.backend.create_query_set(allocator, @intCast(query_set_id), @intCast(descriptor_data_id));
        },

        .create_render_bundle => {
            const bundle_id = try self.readVarint();
            const descriptor_data_id = try self.readVarint();
            try self.backend.create_render_bundle(allocator, @intCast(bundle_id), @intCast(descriptor_data_id));
        },

        else => return false,
    }

    return true;
}

/// Check if opcode is a resource creation opcode.
pub fn isResourceOpcode(op: OpCode) bool {
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
