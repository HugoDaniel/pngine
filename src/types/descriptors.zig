//! Descriptor Types
//!
//! Binary descriptor type definitions shared across encoder and validator.
//! Zero external dependencies for parallel compilation.
//!
//! ## Binary Format
//!
//! Descriptors are encoded as:
//! ```
//! [type_tag: u8]       Descriptor type identifier
//! [field_count: u8]    Number of fields present
//! [fields: ...]        Field data entries
//! ```
//!
//! Field entries are encoded as:
//! ```
//! [field_id: u8]       WebGPU field identifier
//! [value_type: u8]     Value encoding type
//! [value: ...]         Actual value data
//! ```
//!
//! ## Invariants
//!
//! - Field IDs are stable across versions (append-only)
//! - Values use little-endian encoding
//! - Enum values encode as u8

const std = @import("std");

// ============================================================================
// Descriptor Type Tags
// ============================================================================

/// Descriptor type identifiers.
/// Stable across versions - append only.
pub const DescriptorType = enum(u8) {
    texture = 0x01,
    sampler = 0x02,
    bind_group = 0x03,
    bind_group_layout = 0x04,
    render_pipeline = 0x05,
    compute_pipeline = 0x06,
    render_pass = 0x07,
    pipeline_layout = 0x08,
};

// ============================================================================
// Value Type Tags
// ============================================================================

/// Value encoding types for descriptor fields.
pub const ValueType = enum(u8) {
    u32_val = 0x00,
    f32_val = 0x01,
    string_id = 0x02, // Reference to string/data section
    array = 0x03, // Array of values
    nested = 0x04, // Nested descriptor
    bool_val = 0x05,
    u16_val = 0x06, // For resource IDs
    enum_val = 0x07, // Enum as u8
};

// ============================================================================
// Texture Field IDs (matches WebGPU GPUTextureDescriptor)
// ============================================================================

pub const TextureField = enum(u8) {
    width = 0x01,
    height = 0x02,
    depth = 0x03,
    mip_level_count = 0x04,
    sample_count = 0x05,
    dimension = 0x06, // "1d", "2d", "3d"
    format = 0x07, // TextureFormat enum
    usage = 0x08, // TextureUsage flags
    view_formats = 0x09, // Array of formats
    size_from_image_bitmap = 0x0A, // ImageBitmap ID for runtime size resolution
};

// ============================================================================
// Sampler Field IDs (matches WebGPU GPUSamplerDescriptor)
// ============================================================================

pub const SamplerField = enum(u8) {
    address_mode_u = 0x01,
    address_mode_v = 0x02,
    address_mode_w = 0x03,
    mag_filter = 0x04,
    min_filter = 0x05,
    mipmap_filter = 0x06,
    lod_min_clamp = 0x07,
    lod_max_clamp = 0x08,
    compare = 0x09,
    max_anisotropy = 0x0A,
};

// ============================================================================
// Bind Group Field IDs
// ============================================================================

pub const BindGroupField = enum(u8) {
    layout = 0x01, // layout_id reference
    entries = 0x02, // Array of bind group entries
};

pub const BindGroupEntryField = enum(u8) {
    binding = 0x01,
    resource_type = 0x02, // buffer, texture, sampler
    resource_id = 0x03,
    offset = 0x04, // For buffer bindings
    size = 0x05, // For buffer bindings
};

// ============================================================================
// Render Pass Field IDs
// ============================================================================

pub const RenderPassField = enum(u8) {
    color_attachments = 0x01,
    depth_stencil_attachment = 0x02,
};

pub const ColorAttachmentField = enum(u8) {
    view = 0x01, // texture_id for view
    resolve_target = 0x02,
    load_op = 0x03,
    store_op = 0x04,
    clear_value = 0x05, // [r, g, b, a]
};

// ============================================================================
// Pipeline Field IDs
// ============================================================================

pub const RenderPipelineField = enum(u8) {
    layout = 0x01,
    vertex_shader = 0x02, // shader_id
    vertex_entry_point = 0x03, // string_id
    fragment_shader = 0x04,
    fragment_entry_point = 0x05,
    vertex_buffers = 0x06, // Array of buffer layouts
    primitive_topology = 0x07,
    front_face = 0x08,
    cull_mode = 0x09,
    depth_stencil = 0x0A,
    multisample = 0x0B,
    targets = 0x0C, // Color targets
};

pub const ComputePipelineField = enum(u8) {
    layout = 0x01,
    compute_shader = 0x02,
    compute_entry_point = 0x03,
};

// ============================================================================
// Enum Values (WebGPU enums encoded as u8)
// ============================================================================

pub const TextureFormat = enum(u8) {
    rgba8unorm = 0x00,
    rgba8snorm = 0x01,
    rgba8uint = 0x02,
    rgba8sint = 0x03,
    bgra8unorm = 0x04,
    rgba16float = 0x05,
    rgba32float = 0x06,
    depth24plus = 0x10,
    depth24plus_stencil8 = 0x11,
    depth32float = 0x12,
    r32float = 0x20,
    rg32float = 0x21,
    _,

    pub fn fromString(s: []const u8) TextureFormat {
        const map = std.StaticStringMap(TextureFormat).initComptime(.{
            .{ "rgba8unorm", .rgba8unorm },
            .{ "rgba8snorm", .rgba8snorm },
            .{ "rgba8uint", .rgba8uint },
            .{ "rgba8sint", .rgba8sint },
            .{ "bgra8unorm", .bgra8unorm },
            .{ "rgba16float", .rgba16float },
            .{ "rgba32float", .rgba32float },
            .{ "depth24plus", .depth24plus },
            .{ "depth24plus-stencil8", .depth24plus_stencil8 },
            .{ "depth32float", .depth32float },
            .{ "r32float", .r32float },
            .{ "rg32float", .rg32float },
        });
        return map.get(s) orelse .rgba8unorm;
    }
};

pub const FilterMode = enum(u8) {
    nearest = 0x00,
    linear = 0x01,
};

pub const AddressMode = enum(u8) {
    clamp_to_edge = 0x00,
    repeat = 0x01,
    mirror_repeat = 0x02,
};

/// Primitive topologies (matches WebGPU GPUPrimitiveTopology).
/// IMPORTANT: Indices must match enums.js TOPOLOGY array.
pub const PrimitiveTopology = enum(u8) {
    point_list = 0x00,
    line_list = 0x01,
    line_strip = 0x02,
    triangle_list = 0x03,
    triangle_strip = 0x04,
};

/// Cull modes (matches WebGPU GPUCullMode).
/// IMPORTANT: Indices must match enums.js CULL_MODE array.
pub const CullMode = enum(u8) {
    none = 0x00,
    front = 0x01,
    back = 0x02,
};

/// Front face winding (matches WebGPU GPUFrontFace).
/// IMPORTANT: Indices must match enums.js FRONT_FACE array.
pub const FrontFace = enum(u8) {
    ccw = 0x00,
    cw = 0x01,
};

/// Compare functions (matches WebGPU GPUCompareFunction).
/// IMPORTANT: Indices must match enums.js COMPARE_FUNCTION array.
pub const CompareFunction = enum(u8) {
    never = 0x00,
    less = 0x01,
    equal = 0x02,
    less_equal = 0x03,
    greater = 0x04,
    not_equal = 0x05,
    greater_equal = 0x06,
    always = 0x07,
};

// Note: LoadOp and StoreOp are in opcodes.zig

pub const ResourceType = enum(u8) {
    buffer = 0x00,
    texture_view = 0x01,
    sampler = 0x02,
    external_texture = 0x03,
};

/// Texture usage flags (matches WebGPU GPUTextureUsage).
/// Bit positions are verified at comptime to match WebGPU spec.
pub const TextureUsage = packed struct(u8) {
    copy_src: bool = false,
    copy_dst: bool = false,
    texture_binding: bool = false,
    storage_binding: bool = false,
    render_attachment: bool = false,
    _padding: u3 = 0,

    pub const render_attachment_val: TextureUsage = .{ .render_attachment = true };
    pub const texture_binding_val: TextureUsage = .{ .texture_binding = true };
    pub const copy_dst_val: TextureUsage = .{ .copy_dst = true };
    pub const storage_binding_val: TextureUsage = .{ .storage_binding = true };

    /// WebGPU GPUTextureUsage constants (from W3C WebGPU spec §6.1.2)
    pub const WEBGPU_COPY_SRC: u32 = 0x01;
    pub const WEBGPU_COPY_DST: u32 = 0x02;
    pub const WEBGPU_TEXTURE_BINDING: u32 = 0x04;
    pub const WEBGPU_STORAGE_BINDING: u32 = 0x08;
    pub const WEBGPU_RENDER_ATTACHMENT: u32 = 0x10;

    /// Convert to WebGPU-compatible u32 (identity since bits match).
    pub fn toWebGPU(self: TextureUsage) u32 {
        return @as(u8, @bitCast(self));
    }

    /// Convert to u8 for serialization.
    pub fn toU8(self: TextureUsage) u8 {
        return @bitCast(self);
    }

    /// Create from u8 (deserialization).
    pub fn fromU8(value: u8) TextureUsage {
        return @bitCast(value);
    }

    // Compile-time verification that packed struct bits match WebGPU values
    comptime {
        const assert = std.debug.assert;
        assert(@as(u8, @bitCast(TextureUsage{ .copy_src = true })) == WEBGPU_COPY_SRC);
        assert(@as(u8, @bitCast(TextureUsage{ .copy_dst = true })) == WEBGPU_COPY_DST);
        assert(@as(u8, @bitCast(TextureUsage{ .texture_binding = true })) == WEBGPU_TEXTURE_BINDING);
        assert(@as(u8, @bitCast(TextureUsage{ .storage_binding = true })) == WEBGPU_STORAGE_BINDING);
        assert(@as(u8, @bitCast(TextureUsage{ .render_attachment = true })) == WEBGPU_RENDER_ATTACHMENT);
    }
};


// ============================================================================
// Tests
// ============================================================================

test "DescriptorType values" {
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(DescriptorType.texture));
    try std.testing.expectEqual(@as(u8, 0x02), @intFromEnum(DescriptorType.sampler));
    try std.testing.expectEqual(@as(u8, 0x05), @intFromEnum(DescriptorType.render_pipeline));
}

test "ValueType values" {
    try std.testing.expectEqual(@as(u8, 0x00), @intFromEnum(ValueType.u32_val));
    try std.testing.expectEqual(@as(u8, 0x07), @intFromEnum(ValueType.enum_val));
}

test "TextureField values" {
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(TextureField.width));
    try std.testing.expectEqual(@as(u8, 0x08), @intFromEnum(TextureField.usage));
}

test "TextureFormat fromString" {
    try std.testing.expectEqual(TextureFormat.rgba8unorm, TextureFormat.fromString("rgba8unorm"));
    try std.testing.expectEqual(TextureFormat.depth24plus_stencil8, TextureFormat.fromString("depth24plus-stencil8"));
    try std.testing.expectEqual(TextureFormat.rgba8unorm, TextureFormat.fromString("unknown")); // default
}

test "TextureUsage serialization" {
    const usage = TextureUsage{ .copy_dst = true, .render_attachment = true };
    const serialized = usage.toU8();
    const restored = TextureUsage.fromU8(serialized);
    try std.testing.expectEqual(usage, restored);
}
