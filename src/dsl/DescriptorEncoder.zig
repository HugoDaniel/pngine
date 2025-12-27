//! Binary Descriptor Encoder
//!
//! Encodes WebGPU descriptors as compact binary for direct runtime use.
//! No JSON parsing at runtime - binary is passed directly to WebGPU.
//!
//! ## Binary Format
//!
//! ```
//! Descriptor:
//! ┌─────────────────────────────────────────┐
//! │ type_tag: u8                            │  Descriptor type identifier
//! │ field_count: u8                         │  Number of fields present
//! │ fields: [field_count]FieldEntry         │  Field data
//! └─────────────────────────────────────────┘
//!
//! FieldEntry:
//! │ field_id: u8                            │  WebGPU field identifier
//! │ value_type: u8                          │  u32/f32/string_id/array/nested
//! │ value: varies                           │  Actual value data
//! ```
//!
//! ## Invariants
//!
//! - Field IDs are stable across versions (append-only)
//! - Values use little-endian encoding
//! - String values stored as data section references (u16)
//! - Arrays prefixed with element count (u8)

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Ast = @import("Ast.zig").Ast;
const Node = @import("Ast.zig").Node;

// Import shared descriptor types from types module
const types = @import("types");

pub const DescriptorEncoder = struct {
    const Self = @This();

    // ========================================================================
    // Re-export shared descriptor types for backwards compatibility
    // These types are defined in src/types/descriptors.zig
    // ========================================================================

    pub const DescriptorType = types.DescriptorType;
    pub const ValueType = types.ValueType;
    pub const TextureField = types.TextureField;
    pub const SamplerField = types.SamplerField;
    pub const BindGroupField = types.BindGroupField;
    pub const BindGroupEntryField = types.BindGroupEntryField;
    pub const RenderPassField = types.RenderPassField;
    pub const ColorAttachmentField = types.ColorAttachmentField;
    pub const RenderPipelineField = types.RenderPipelineField;
    pub const TextureFormat = types.TextureFormat;
    pub const FilterMode = types.FilterMode;
    pub const AddressMode = types.AddressMode;
    pub const LoadOp = types.LoadOp;
    pub const StoreOp = types.StoreOp;
    pub const ResourceType = types.ResourceType;
    pub const TextureUsage = types.TextureUsage;

    // ========================================================================
    // Encoding Buffer
    // ========================================================================

    buffer: std.ArrayListUnmanaged(u8),

    pub fn init() Self {
        return .{ .buffer = .{} };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.buffer.deinit(allocator);
    }

    pub fn toOwnedSlice(self: *Self, allocator: Allocator) ![]u8 {
        return self.buffer.toOwnedSlice(allocator);
    }

    // ========================================================================
    // Low-level encoding
    // ========================================================================

    pub fn writeByte(self: *Self, allocator: Allocator, byte: u8) !void {
        try self.buffer.append(allocator, byte);
    }

    pub fn writeU16(self: *Self, allocator: Allocator, value: u16) !void {
        try self.buffer.append(allocator, @intCast(value & 0xFF));
        try self.buffer.append(allocator, @intCast(value >> 8));
    }

    pub fn writeU32(self: *Self, allocator: Allocator, value: u32) !void {
        try self.buffer.append(allocator, @intCast(value & 0xFF));
        try self.buffer.append(allocator, @intCast((value >> 8) & 0xFF));
        try self.buffer.append(allocator, @intCast((value >> 16) & 0xFF));
        try self.buffer.append(allocator, @intCast(value >> 24));
    }

    fn writeF32(self: *Self, allocator: Allocator, value: f32) !void {
        const bits: u32 = @bitCast(value);
        try self.writeU32(allocator, bits);
    }

    // ========================================================================
    // Field encoding helpers
    // ========================================================================

    pub fn beginDescriptor(self: *Self, allocator: Allocator, desc_type: DescriptorType) !usize {
        try self.writeByte(allocator, @intFromEnum(desc_type));
        const field_count_pos = self.buffer.items.len;
        try self.writeByte(allocator, 0); // Placeholder for field count
        return field_count_pos;
    }

    pub fn endDescriptor(self: *Self, field_count_pos: usize, field_count: u8) void {
        self.buffer.items[field_count_pos] = field_count;
    }

    pub fn writeU32Field(self: *Self, allocator: Allocator, field_id: u8, value: u32) !void {
        try self.writeByte(allocator, field_id);
        try self.writeByte(allocator, @intFromEnum(ValueType.u32_val));
        try self.writeU32(allocator, value);
    }

    pub fn writeU16Field(self: *Self, allocator: Allocator, field_id: u8, value: u16) !void {
        try self.writeByte(allocator, field_id);
        try self.writeByte(allocator, @intFromEnum(ValueType.u16_val));
        try self.writeU16(allocator, value);
    }

    pub fn writeF32Field(self: *Self, allocator: Allocator, field_id: u8, value: f32) !void {
        try self.writeByte(allocator, field_id);
        try self.writeByte(allocator, @intFromEnum(ValueType.f32_val));
        try self.writeF32(allocator, value);
    }

    pub fn writeBoolField(self: *Self, allocator: Allocator, field_id: u8, value: bool) !void {
        try self.writeByte(allocator, field_id);
        try self.writeByte(allocator, @intFromEnum(ValueType.bool_val));
        try self.writeByte(allocator, if (value) 1 else 0);
    }

    pub fn writeEnumField(self: *Self, allocator: Allocator, field_id: u8, value: u8) !void {
        try self.writeByte(allocator, field_id);
        try self.writeByte(allocator, @intFromEnum(ValueType.enum_val));
        try self.writeByte(allocator, value);
    }

    pub fn writeStringIdField(self: *Self, allocator: Allocator, field_id: u8, string_id: u16) !void {
        try self.writeByte(allocator, field_id);
        try self.writeByte(allocator, @intFromEnum(ValueType.string_id));
        try self.writeU16(allocator, string_id);
    }

    // ========================================================================
    // High-level descriptor encoding
    // ========================================================================

    /// Encode a texture descriptor.
    /// Returns owned slice that must be freed by caller.
    ///
    /// Memory: Caller owns returned slice.
    pub fn encodeTexture(
        allocator: Allocator,
        width: u32,
        height: u32,
        format: TextureFormat,
        usage: TextureUsage,
        sample_count: u32,
    ) ![]u8 {
        // Pre-conditions: dimensions must be positive.
        assert(width > 0);
        assert(height > 0);

        var encoder = Self.init();
        errdefer encoder.deinit(allocator);

        const field_count_pos = try encoder.beginDescriptor(allocator, .texture);
        var field_count: u8 = 0;

        try encoder.writeU32Field(allocator, @intFromEnum(TextureField.width), width);
        field_count += 1;

        try encoder.writeU32Field(allocator, @intFromEnum(TextureField.height), height);
        field_count += 1;

        try encoder.writeEnumField(allocator, @intFromEnum(TextureField.format), @intFromEnum(format));
        field_count += 1;

        try encoder.writeByte(allocator, @intFromEnum(TextureField.usage));
        try encoder.writeByte(allocator, @intFromEnum(ValueType.enum_val));
        try encoder.writeByte(allocator, @bitCast(usage));
        field_count += 1;

        if (sample_count > 1) {
            try encoder.writeU32Field(allocator, @intFromEnum(TextureField.sample_count), sample_count);
            field_count += 1;
        }

        encoder.endDescriptor(field_count_pos, field_count);

        const result = try encoder.toOwnedSlice(allocator);

        // Post-condition: output starts with correct type tag.
        assert(result[0] == @intFromEnum(DescriptorType.texture));

        return result;
    }

    /// Encode a texture descriptor without explicit dimensions.
    /// Runtime will use canvas size as the default.
    /// Used for textures with size=[canvas.width canvas.height].
    ///
    /// Memory: Caller owns returned slice.
    pub fn encodeTextureCanvasSize(
        allocator: Allocator,
        format: TextureFormat,
        usage: TextureUsage,
        sample_count: u32,
    ) ![]u8 {
        var encoder = Self.init();
        errdefer encoder.deinit(allocator);

        const field_count_pos = try encoder.beginDescriptor(allocator, .texture);
        var field_count: u8 = 0;

        // No width/height fields - runtime will use canvas size by default

        try encoder.writeEnumField(allocator, @intFromEnum(TextureField.format), @intFromEnum(format));
        field_count += 1;

        try encoder.writeByte(allocator, @intFromEnum(TextureField.usage));
        try encoder.writeByte(allocator, @intFromEnum(ValueType.enum_val));
        try encoder.writeByte(allocator, @bitCast(usage));
        field_count += 1;

        if (sample_count > 1) {
            try encoder.writeU32Field(allocator, @intFromEnum(TextureField.sample_count), sample_count);
            field_count += 1;
        }

        encoder.endDescriptor(field_count_pos, field_count);

        const result = try encoder.toOwnedSlice(allocator);

        // Post-condition: output starts with correct type tag.
        assert(result[0] == @intFromEnum(DescriptorType.texture));

        return result;
    }

    /// Encode a texture descriptor with size from an ImageBitmap.
    /// Runtime will use the ImageBitmap dimensions after it's decoded.
    /// Used for textures with size=[imageBitmap.width imageBitmap.height].
    ///
    /// Memory: Caller owns returned slice.
    pub fn encodeTextureImageBitmapSize(
        allocator: Allocator,
        image_bitmap_id: u16,
        format: TextureFormat,
        usage: TextureUsage,
        sample_count: u32,
    ) ![]u8 {
        var encoder = Self.init();
        errdefer encoder.deinit(allocator);

        const field_count_pos = try encoder.beginDescriptor(allocator, .texture);
        var field_count: u8 = 0;

        // ImageBitmap reference for size - runtime resolves dimensions
        try encoder.writeByte(allocator, @intFromEnum(TextureField.size_from_image_bitmap));
        try encoder.writeByte(allocator, @intFromEnum(ValueType.u16_val));
        try encoder.writeU16(allocator, image_bitmap_id);
        field_count += 1;

        try encoder.writeEnumField(allocator, @intFromEnum(TextureField.format), @intFromEnum(format));
        field_count += 1;

        try encoder.writeByte(allocator, @intFromEnum(TextureField.usage));
        try encoder.writeByte(allocator, @intFromEnum(ValueType.enum_val));
        try encoder.writeByte(allocator, @bitCast(usage));
        field_count += 1;

        if (sample_count > 1) {
            try encoder.writeU32Field(allocator, @intFromEnum(TextureField.sample_count), sample_count);
            field_count += 1;
        }

        encoder.endDescriptor(field_count_pos, field_count);

        const result = try encoder.toOwnedSlice(allocator);

        // Post-condition: output starts with correct type tag.
        assert(result[0] == @intFromEnum(DescriptorType.texture));

        return result;
    }

    /// Encode a sampler descriptor.
    ///
    /// Memory: Caller owns returned slice.
    pub fn encodeSampler(
        allocator: Allocator,
        mag_filter: FilterMode,
        min_filter: FilterMode,
        address_mode: AddressMode,
    ) ![]u8 {
        // Pre-condition: enum values are valid (enforced by type system).
        assert(@intFromEnum(mag_filter) <= 1);
        assert(@intFromEnum(min_filter) <= 1);

        var encoder = Self.init();
        errdefer encoder.deinit(allocator);

        const field_count_pos = try encoder.beginDescriptor(allocator, .sampler);
        var field_count: u8 = 0;

        try encoder.writeEnumField(allocator, @intFromEnum(SamplerField.mag_filter), @intFromEnum(mag_filter));
        field_count += 1;

        try encoder.writeEnumField(allocator, @intFromEnum(SamplerField.min_filter), @intFromEnum(min_filter));
        field_count += 1;

        try encoder.writeEnumField(allocator, @intFromEnum(SamplerField.address_mode_u), @intFromEnum(address_mode));
        field_count += 1;

        try encoder.writeEnumField(allocator, @intFromEnum(SamplerField.address_mode_v), @intFromEnum(address_mode));
        field_count += 1;

        encoder.endDescriptor(field_count_pos, field_count);

        const result = try encoder.toOwnedSlice(allocator);

        // Post-condition: output starts with correct type tag.
        assert(result[0] == @intFromEnum(DescriptorType.sampler));

        return result;
    }

    /// Encode bind group descriptor with group index and entries.
    /// Format: type_tag + field_count + group_index + entries_array
    ///
    /// Memory: Caller owns returned slice.
    pub fn encodeBindGroupDescriptor(
        allocator: Allocator,
        group_index: u8,
        entries: []const BindGroupEntry,
    ) ![]u8 {
        // Pre-condition: entries count fits in u8 for compact encoding.
        assert(entries.len <= 255);

        var encoder = Self.init();
        errdefer encoder.deinit(allocator);

        const field_count_pos = try encoder.beginDescriptor(allocator, .bind_group);
        var field_count: u8 = 0;

        // Write group index (which slot in the pipeline layout)
        try encoder.writeEnumField(allocator, @intFromEnum(BindGroupField.layout), group_index);
        field_count += 1;

        // Write entries array header
        try encoder.writeByte(allocator, @intFromEnum(BindGroupField.entries));
        try encoder.writeByte(allocator, @intFromEnum(ValueType.array));
        try encoder.writeByte(allocator, @intCast(entries.len));
        field_count += 1;

        // Write each entry
        for (entries) |entry| {
            try encoder.writeByte(allocator, entry.binding);
            try encoder.writeByte(allocator, @intFromEnum(entry.resource_type));
            try encoder.writeU16(allocator, entry.resource_id);
            if (entry.resource_type == .buffer) {
                try encoder.writeU32(allocator, entry.offset);
                try encoder.writeU32(allocator, entry.size);
            }
        }

        encoder.endDescriptor(field_count_pos, field_count);

        const result = try encoder.toOwnedSlice(allocator);

        // Post-condition: output starts with correct type tag.
        assert(result[0] == @intFromEnum(DescriptorType.bind_group));

        return result;
    }

    /// Legacy: Encode bind group entries without group index.
    /// Deprecated: Use encodeBindGroupDescriptor instead.
    pub fn encodeBindGroupEntries(
        allocator: Allocator,
        entries: []const BindGroupEntry,
    ) ![]u8 {
        return encodeBindGroupDescriptor(allocator, 0, entries);
    }

    /// Encode render pass descriptor.
    ///
    /// Memory: Caller owns returned slice.
    pub fn encodeRenderPass(
        allocator: Allocator,
        color_load_op: LoadOp,
        color_store_op: StoreOp,
        clear_color: [4]f32,
    ) ![]u8 {
        // Pre-conditions: clear color values are normalized [0,1].
        assert(clear_color[0] >= 0.0 and clear_color[0] <= 1.0);
        assert(clear_color[3] >= 0.0 and clear_color[3] <= 1.0);

        var encoder = Self.init();
        errdefer encoder.deinit(allocator);

        const field_count_pos = try encoder.beginDescriptor(allocator, .render_pass);

        // Color attachment (simplified: single attachment)
        try encoder.writeByte(allocator, @intFromEnum(RenderPassField.color_attachments));
        try encoder.writeByte(allocator, @intFromEnum(ValueType.array));
        try encoder.writeByte(allocator, 1); // 1 color attachment

        // Attachment fields
        try encoder.writeEnumField(allocator, @intFromEnum(ColorAttachmentField.load_op), @intFromEnum(color_load_op));
        try encoder.writeEnumField(allocator, @intFromEnum(ColorAttachmentField.store_op), @intFromEnum(color_store_op));

        // Clear value (4 floats)
        try encoder.writeByte(allocator, @intFromEnum(ColorAttachmentField.clear_value));
        try encoder.writeByte(allocator, @intFromEnum(ValueType.array));
        try encoder.writeByte(allocator, 4);
        for (clear_color) |c| {
            try encoder.writeF32(allocator, c);
        }

        encoder.endDescriptor(field_count_pos, 1);

        const result = try encoder.toOwnedSlice(allocator);

        // Post-condition: output starts with correct type tag.
        assert(result[0] == @intFromEnum(DescriptorType.render_pass));

        return result;
    }

    pub const BindGroupEntry = struct {
        binding: u8,
        resource_type: ResourceType,
        resource_id: u16,
        offset: u32 = 0,
        size: u32 = 0,
    };

    // Compile-time size assertions for binary format stability.
    comptime {
        // BindGroupEntry must be exactly 12 bytes for consistent encoding.
        assert(@sizeOf(BindGroupEntry) == 12);
        // TextureUsage must fit in 1 byte for compact encoding.
        assert(@sizeOf(TextureUsage) == 1);
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

// Property: encoded texture has correct type tag and field count.
test "DescriptorEncoder: encode texture" {
    const desc = try DescriptorEncoder.encodeTexture(
        testing.allocator,
        256,
        256,
        .rgba8unorm,
        .{ .render_attachment = true },
        1,
    );
    defer testing.allocator.free(desc);

    // Property: first byte is descriptor type tag.
    try testing.expectEqual(@as(u8, @intFromEnum(DescriptorEncoder.DescriptorType.texture)), desc[0]);
    // Property: second byte is field count (4 fields when sample_count=1).
    try testing.expectEqual(@as(u8, 4), desc[1]);
    // Property: output has minimum expected size for header + fields.
    try testing.expect(desc.len > 10);
}

// Property: MSAA textures include sample_count field (5 fields vs 4).
test "DescriptorEncoder: encode texture with MSAA" {
    const desc = try DescriptorEncoder.encodeTexture(
        testing.allocator,
        512,
        512,
        .bgra8unorm,
        .{ .render_attachment = true, .texture_binding = true },
        4, // 4x MSAA
    );
    defer testing.allocator.free(desc);

    // Property: type tag is texture.
    try testing.expectEqual(@as(u8, @intFromEnum(DescriptorEncoder.DescriptorType.texture)), desc[0]);
    // Property: 5 fields when sample_count > 1.
    try testing.expectEqual(@as(u8, 5), desc[1]);
}

// Property: canvas-sized textures omit width/height fields (2 fields vs 4).
// Regression test: size=[canvas.width canvas.height] should NOT encode dimensions.
test "DescriptorEncoder: encode texture canvas size" {
    const desc = try DescriptorEncoder.encodeTextureCanvasSize(
        testing.allocator,
        .depth24plus,
        .{ .render_attachment = true },
        1,
    );
    defer testing.allocator.free(desc);

    // Property: type tag is texture.
    try testing.expectEqual(@as(u8, @intFromEnum(DescriptorEncoder.DescriptorType.texture)), desc[0]);
    // Property: only 2 fields (format, usage) when no width/height.
    try testing.expectEqual(@as(u8, 2), desc[1]);
    // Property: smaller than explicit-size descriptor.
    try testing.expect(desc.len < 15); // Explicit size would be ~20 bytes
}

// Property: sampler encoding produces correct type tag and field count.
test "DescriptorEncoder: encode sampler" {
    const desc = try DescriptorEncoder.encodeSampler(
        testing.allocator,
        .linear,
        .linear,
        .repeat,
    );
    defer testing.allocator.free(desc);

    // Property: type tag is sampler.
    try testing.expectEqual(@as(u8, @intFromEnum(DescriptorEncoder.DescriptorType.sampler)), desc[0]);
    // Property: 4 fields (mag, min, address_u, address_v).
    try testing.expectEqual(@as(u8, 4), desc[1]);
}

// Property: bind group entries are encoded with correct type tag.
test "DescriptorEncoder: encode bind group entries" {
    const entries = [_]DescriptorEncoder.BindGroupEntry{
        .{ .binding = 0, .resource_type = .buffer, .resource_id = 0, .offset = 0, .size = 64 },
        .{ .binding = 1, .resource_type = .sampler, .resource_id = 0 },
        .{ .binding = 2, .resource_type = .texture_view, .resource_id = 0 },
    };

    const desc = try DescriptorEncoder.encodeBindGroupEntries(testing.allocator, &entries);
    defer testing.allocator.free(desc);

    // Property: type tag is bind_group.
    try testing.expectEqual(@as(u8, @intFromEnum(DescriptorEncoder.DescriptorType.bind_group)), desc[0]);
    // Property: output size accounts for all entries.
    try testing.expect(desc.len > 5);
}

// Property: render pass encoding produces valid descriptor.
test "DescriptorEncoder: encode render pass" {
    const desc = try DescriptorEncoder.encodeRenderPass(
        testing.allocator,
        .clear,
        .store,
        .{ 0.0, 0.0, 0.0, 1.0 },
    );
    defer testing.allocator.free(desc);

    // Property: type tag is render_pass.
    try testing.expectEqual(@as(u8, @intFromEnum(DescriptorEncoder.DescriptorType.render_pass)), desc[0]);
    // Property: output includes clear color (4 floats = 16 bytes).
    try testing.expect(desc.len > 10);
}

// Property: TextureFormat.fromString returns correct enum values.
test "DescriptorEncoder: TextureFormat fromString" {
    // Property: known formats map correctly.
    try testing.expectEqual(DescriptorEncoder.TextureFormat.rgba8unorm, DescriptorEncoder.TextureFormat.fromString("rgba8unorm"));
    try testing.expectEqual(DescriptorEncoder.TextureFormat.bgra8unorm, DescriptorEncoder.TextureFormat.fromString("bgra8unorm"));
    try testing.expectEqual(DescriptorEncoder.TextureFormat.depth24plus, DescriptorEncoder.TextureFormat.fromString("depth24plus"));
    // Property: unknown formats return default (rgba8unorm).
    try testing.expectEqual(DescriptorEncoder.TextureFormat.rgba8unorm, DescriptorEncoder.TextureFormat.fromString("unknown"));
}
