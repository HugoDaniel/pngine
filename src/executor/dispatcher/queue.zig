//! Queue Operations Handler
//!
//! Handles GPU queue operations:
//! - write_buffer, write_texture, write_uniform, write_time_uniform, write_pointer_uniform
//! - copy_buffer_to_buffer, copy_texture_to_texture, copy_external_image_to_texture
//! - submit
//!
//! ## Invariants
//!
//! - Buffer IDs must reference previously created buffers
//! - Data IDs must reference valid data section entries

const std = @import("std");
const Allocator = std.mem.Allocator;

const bytecode_mod = @import("bytecode");
const OpCode = bytecode_mod.opcodes.OpCode;
const wire = bytecode_mod.wire_schema;
const texture_layout = bytecode_mod.texture_layout;
const descriptors = bytecode_mod.descriptors;

/// What a `create_texture` descriptor says about a live texture, as far as the
/// reference can resolve it without a render size or a decoded ImageBitmap.
const TextureFacts = union(enum) {
    concrete: texture_layout.TextureDescriptor,
    /// A canvas- or image-derived extent. The reference dispatcher has neither
    /// a render size nor an image decoder, so it validates only the facts that
    /// do not depend on the extent; the executing backend owns the rest.
    dynamic,
    /// The descriptor bytes do not decode as a texture descriptor at all. No
    /// substitute resource: the write is refused.
    invalid,
};

fn tlvByte(scalar: u32) u8 {
    return std.math.lossyCast(u8, scalar);
}

/// Decode the concrete descriptor facts plan 01 validates. `extentSource` is
/// informational for the calculator; a descriptor with no explicit width and
/// height is `dynamic`, never a guessed 1x1/256x256 base extent.
fn readTextureFacts(data: []const u8) TextureFacts {
    if (descriptors.TlvReader.descriptorType(data) != .texture) return .invalid;
    var reader = descriptors.TlvReader.init(data) orelse return .invalid;

    var width: ?u32 = null;
    var height: ?u32 = null;
    var depth: u32 = 1;
    var mip_level_count: u32 = 1;
    var sample_count: u32 = 1;
    var dimension: texture_layout.Dimension = .d2;
    var tex_format: descriptors.TextureFormat = .rgba8unorm;
    var usage: descriptors.TextureUsage = .{ .render_attachment = true };
    var dynamic_extent = false;

    while (reader.next()) |field| {
        const tf = std.enums.fromInt(descriptors.TextureField, field.id) orelse continue;
        switch (field.value_type) {
            .u32_val => switch (tf) {
                .width => width = field.scalar,
                .height => height = field.scalar,
                .depth => depth = field.scalar,
                .mip_level_count => mip_level_count = field.scalar,
                .sample_count => sample_count = field.scalar,
                else => {},
            },
            .enum_val => switch (tf) {
                .format => tex_format = @enumFromInt(tlvByte(field.scalar)),
                .usage => usage = descriptors.TextureUsage.fromU8(tlvByte(field.scalar)),
                .dimension => dimension = switch (field.scalar) {
                    0 => .d1,
                    2 => .d3,
                    else => .d2,
                },
                else => {},
            },
            else => {},
        }
        if (tf == .size_from_image_bitmap) dynamic_extent = true;
    }

    // The preferred-canvas sentinel has no format row until a backend resolves
    // it. Every backend's canvas is one of the two 4-byte formats; BGRA8 is the
    // native one, so resolve it to that rather than refusing the descriptor.
    if (tex_format == .preferred_canvas_format) tex_format = .bgra8unorm;
    // `decodeTextureUsage` treats an authored 0 as RenderAttachment; describe
    // the created resource, not the raw byte.
    if (usage.toU8() == 0) usage = .{ .render_attachment = true };

    if (dynamic_extent or width == null or height == null) return .dynamic;
    return .{ .concrete = .{
        .size = .{ .width = width.?, .height = height.?, .depth_or_array_layers = depth },
        .dimension = dimension,
        .format = tex_format,
        .usage = usage,
        .sample_count = sample_count,
        .mip_level_count = mip_level_count,
        .extent_source = .explicit,
    } };
}

/// Re-validate a `write_texture` at the reference effect boundary.
///
/// Only a texture the stream actually created through `create_texture` has
/// metadata to check against. A bare instruction (plan 02's operand
/// characterizations, which build no resource) keeps its decode-and-record
/// behavior: that fixture proves the wire shape, not a runtime execution.
fn validateWriteTexture(
    comptime Self: type,
    self: *Self,
    texture_id: u16,
    data_id: u16,
    write: texture_layout.WriteLayout,
) !void {
    if (@as(usize, texture_id) >= self.texture_descriptor_ids.len) {
        if (self.texture_create_seen) return error.InvalidResourceId;
        return;
    }
    const descriptor_data_id = self.texture_descriptor_ids[texture_id] orelse {
        // Once this stream has created a texture, a write to one it never
        // created is a malformed destination — no substitute resource.
        if (self.texture_create_seen) return error.TextureNotFound;
        return;
    };

    // A data id past the section is a malformed payload, not an empty slice to
    // substitute (the data section's `get` is total and would otherwise turn
    // it into "no data"). An authored empty entry (id < count) stays legal.
    if (data_id >= self.module.data.count()) return error.InvalidTextureWrite;
    const data = self.module.data.get(bytecode_mod.DataId.fromInt(data_id));

    switch (readTextureFacts(self.module.data.get(bytecode_mod.DataId.fromInt(descriptor_data_id)))) {
        .dynamic => {},
        .invalid => return error.InvalidTextureWrite,
        .concrete => |descriptor| switch (texture_layout.calculateWrite(descriptor, write, @as(u64, data.len))) {
            .ok => {},
            .refuse => return error.InvalidTextureWrite,
        },
    }
}

/// Decode one buffer↔texture copy's shared fixed operand sequence. Both opcodes
/// use the same layout; `op` selects only which backend method the caller
/// stores the direction for. The presence bits are the sole record of an
/// omitted stride/size versus an authored zero, exactly as for writeTexture.
const TextureBufferCopy = struct {
    texture_id: u16,
    buffer_id: u16,
    write: texture_layout.WriteLayout,
};

fn readTextureBufferCopy(self: anytype, comptime op: OpCode) !TextureBufferCopy {
    const p = try wire.readOperands(wire.layoutOf(op), self);
    const has_bytes_per_row = (p.flags & (1 << 0)) != 0;
    const has_rows_per_image = (p.flags & (1 << 1)) != 0;
    const has_size = (p.flags & (1 << 2)) != 0;
    return .{
        .texture_id = try wire.narrowU16(p.texture_id),
        .buffer_id = try wire.narrowU16(p.buffer_id),
        .write = .{
            .offset = p.offset,
            .bytes_per_row = if (has_bytes_per_row) p.bytes_per_row else null,
            .rows_per_image = if (has_rows_per_image) p.rows_per_image else null,
            .origin = .{ .x = p.origin_x, .y = p.origin_y, .z = p.origin_z },
            .mip_level = p.mip_level,
            .aspect = @enumFromInt(p.aspect),
            .size = if (has_size) .{
                .width = p.size_width,
                .height = p.size_height,
                .depth_or_array_layers = p.size_depth,
            } else null,
        },
    };
}

/// Handle queue operation opcodes.
///
/// Decodes operands through the shared wire schema (`wire.readOperands`) then
/// forwards them to the backend — the decode/effect split.
///
/// Returns true if the opcode was handled, false if it should be handled elsewhere.
pub fn handle(
    comptime Self: type,
    self: *Self,
    op: OpCode,
    gpa: Allocator,
) !bool {
    switch (op) {
        .write_buffer => {
            const p = try wire.readOperands(wire.layoutOf(.write_buffer), self);
            try self.backend.write_buffer(gpa, try wire.narrowU16(p.v0), p.v1, try wire.narrowU16(p.v2));
        },

        .write_texture => {
            const p = try wire.readOperands(wire.layoutOf(.write_texture), self);
            // The three trailing-bit flags are the ONLY record of presence: an
            // absent stride/size and an authored zero carry the same field
            // value, so a decoder that materialized a default would erase the
            // distinction the compiler preserved.
            const has_bytes_per_row = (p.flags & (1 << 0)) != 0;
            const has_rows_per_image = (p.flags & (1 << 1)) != 0;
            const has_size = (p.flags & (1 << 2)) != 0;
            const write: texture_layout.WriteLayout = .{
                .offset = p.offset,
                .bytes_per_row = if (has_bytes_per_row) p.bytes_per_row else null,
                .rows_per_image = if (has_rows_per_image) p.rows_per_image else null,
                .origin = .{ .x = p.origin_x, .y = p.origin_y, .z = p.origin_z },
                .mip_level = p.mip_level,
                .aspect = @enumFromInt(p.aspect),
                .size = if (has_size) .{
                    .width = p.size_width,
                    .height = p.size_height,
                    .depth_or_array_layers = p.size_depth,
                } else null,
            };
            const texture_id = try wire.narrowU16(p.texture_id);
            const data_id = try wire.narrowU16(p.data_id);
            try validateWriteTexture(Self, self, texture_id, data_id, write);
            try self.backend.write_texture(gpa, texture_id, data_id, write);
        },

        .copy_buffer_to_texture => {
            const copy = try readTextureBufferCopy(self, .copy_buffer_to_texture);
            try self.backend.copy_buffer_to_texture(gpa, copy.texture_id, copy.buffer_id, copy.write);
        },

        .copy_texture_to_buffer => {
            const copy = try readTextureBufferCopy(self, .copy_texture_to_buffer);
            try self.backend.copy_texture_to_buffer(gpa, copy.texture_id, copy.buffer_id, copy.write);
        },

        .write_time_uniform => {
            const p = try wire.readOperands(wire.layoutOf(.write_time_uniform), self);
            try self.backend.write_time_uniform(gpa, try wire.narrowU16(p.v0), p.v1, try wire.narrowU16(p.v2));
        },

        .write_pointer_uniform => {
            const p = try wire.readOperands(wire.layoutOf(.write_pointer_uniform), self);
            try self.backend.write_pointer_uniform(gpa, try wire.narrowU16(p.v0), p.v1, try wire.narrowU16(p.v2));
        },

        .write_audio_data => {
            const p = try wire.readOperands(wire.layoutOf(.write_audio_data), self);
            try self.backend.write_audio_data(gpa, try wire.narrowU16(p.v0), p.v1, try wire.narrowU16(p.v2));
        },

        .write_controls => {
            const p = try wire.readOperands(wire.layoutOf(.write_controls), self);
            // The written values are controls[1 .. 1 + size/4] — the DECLARED
            // controls in declaration order. Slot 0 (`time`) is deliberately
            // not writable through this instruction: control-inputs carries
            // the declared controls only. A size that is not a multiple of 4,
            // or that runs past the declared controls, is a payload error.
            if (p.size % 4 != 0) return error.InvalidControlWrite;
            const count = p.size / 4;
            if (count > self.declared_controls) return error.InvalidControlWrite;
            try self.backend.write_controls(
                gpa,
                try wire.narrowU16(p.buffer),
                p.offset,
                self.controls[1 .. 1 + count],
            );
        },

        .copy_external_image_to_texture => {
            const p = try wire.readOperands(wire.layoutOf(.copy_external_image_to_texture), self);
            try self.backend.copy_external_image_to_texture(
                gpa,
                try wire.narrowU16(p.bitmap_id),
                try wire.narrowU16(p.texture_id),
                p.mip_level,
                try wire.narrowU16(p.origin_x),
                try wire.narrowU16(p.origin_y),
                try wire.narrowU16(p.origin_z),
            );
        },

        .copy_buffer_to_buffer => {
            const p = try wire.readOperands(wire.layoutOf(.copy_buffer_to_buffer), self);
            try self.backend.copy_buffer_to_buffer(
                gpa,
                try wire.narrowU16(p.v0),
                p.v1,
                try wire.narrowU16(p.v2),
                p.v3,
                p.v4,
            );
        },

        .copy_texture_to_texture => {
            const p = try wire.readOperands(wire.layoutOf(.copy_texture_to_texture), self);
            try self.backend.copy_texture_to_texture(gpa, try wire.narrowU16(p.v0), try wire.narrowU16(p.v1));
        },

        .copy_texture_subresource => {
            const p = try wire.readOperands(wire.layoutOf(.copy_texture_subresource), self);
            // Flags bit 0 is the ONLY record of an authored size: an omitted
            // size and an explicit all-zero size carry the same three field
            // values, and materializing a default would erase the distinction.
            const has_size = (p.flags & (1 << 0)) != 0;
            const source_id = try wire.narrowU16(p.source_id);
            const destination_id = try wire.narrowU16(p.destination_id);
            try self.backend.copy_texture_subresource(
                gpa,
                source_id,
                destination_id,
                .{
                    .source = .{
                        .texture_id = source_id,
                        .mip_level = p.source_mip,
                        .origin = .{ .x = p.source_origin_x, .y = p.source_origin_y, .z = p.source_origin_z },
                        .aspect = @enumFromInt(p.source_aspect),
                    },
                    .destination = .{
                        .texture_id = destination_id,
                        .mip_level = p.destination_mip,
                        .origin = .{
                            .x = p.destination_origin_x,
                            .y = p.destination_origin_y,
                            .z = p.destination_origin_z,
                        },
                        .aspect = @enumFromInt(p.destination_aspect),
                    },
                    .size = if (has_size) .{
                        .width = p.size_width,
                        .height = p.size_height,
                        .depth_or_array_layers = p.size_depth,
                    } else null,
                },
            );
        },

        .write_uniform => {
            const p = try wire.readOperands(wire.layoutOf(.write_uniform), self);
            try self.backend.write_uniform(gpa, try wire.narrowU16(p.v0), try wire.narrowU16(p.v1));
        },

        .resolve_query_set => {
            const p = try wire.readOperands(wire.layoutOf(.resolve_query_set), self);
            try self.backend.resolve_query_set(gpa, try wire.narrowU16(p.v0), p.v1, p.v2, try wire.narrowU16(p.v3), p.v4);
        },

        .submit => {
            // L_NONE: no operands to decode.
            try self.backend.submit(gpa);
        },

        else => return false,
    }

    return true;
}
