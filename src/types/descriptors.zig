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
    texture_view = 0x09,
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

    /// Fixed byte width of a scalar value, or null for the variable-length
    /// kinds (array/nested) whose size isn't self-describing. Single source
    /// for the field-walk stride shared by the encoder and every decoder.
    pub fn scalarByteSize(self: ValueType) ?u8 {
        return switch (self) {
            .u32_val, .f32_val => 4,
            .string_id, .u16_val => 2,
            .bool_val, .enum_val => 1,
            .array, .nested => null,
        };
    }
};

/// Iterator over a TLV descriptor body: `[type_tag:u8][field_count:u8][fields…]`,
/// each field `[field_id:u8][value_type:u8][value:scalarByteSize bytes]`.
///
/// Yields scalar fields (u32/u16/f32/bool/enum) as a zero-extended u32; the
/// caller maps `id` through the descriptor's field enum (TextureField, …) and
/// `value_type` through ValueType — no magic hex at the call site. Stops at a
/// variable-length (array/nested) field or a truncated buffer. This is the
/// single field-walk both the native backend decode and the encoder round-trip
/// test share.
pub const TlvReader = struct {
    data: []const u8,
    off: usize,
    fields_left: u8,

    pub const Field = struct {
        id: u8,
        value_type: ValueType,
        /// u32/u16/enum/bool zero-extended; f32 carried as its bit pattern.
        scalar: u32,
    };

    /// The leading descriptor type tag (data[0]), or null if absent/unknown.
    pub fn descriptorType(data: []const u8) ?DescriptorType {
        if (data.len < 1) return null;
        return std.enums.fromInt(DescriptorType, data[0]);
    }

    /// Position at the first field. Returns null if there is no `[tag][count]`
    /// header.
    pub fn init(data: []const u8) ?TlvReader {
        if (data.len < 2) return null;
        return .{ .data = data, .off = 2, .fields_left = data[1] };
    }

    /// Next scalar field, or null at end / on a variable-length or truncated
    /// field.
    pub fn next(self: *TlvReader) ?Field {
        if (self.fields_left == 0) return null;
        if (self.off + 2 > self.data.len) return null;
        const id = self.data[self.off];
        const vt = std.enums.fromInt(ValueType, self.data[self.off + 1]) orelse return null;
        const width = vt.scalarByteSize() orelse return null; // variable-length: stop
        const val_start = self.off + 2;
        if (val_start + width > self.data.len) return null;
        const scalar: u32 = switch (width) {
            1 => self.data[val_start],
            2 => std.mem.readInt(u16, self.data[val_start..][0..2], .little),
            4 => std.mem.readInt(u32, self.data[val_start..][0..4], .little),
            else => unreachable,
        };
        self.off = val_start + width;
        self.fields_left -= 1;
        return .{ .id = id, .value_type = vt, .scalar = scalar };
    }
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
// Texture View Field IDs (matches WebGPU GPUTextureViewDescriptor)
// ============================================================================

pub const TextureViewField = enum(u8) {
    format = 0x01, // TextureFormat enum (default: source texture's format)
    dimension = 0x02, // view-dimension: 0=1d 1=2d 2=2d-array 3=cube 4=cube-array 5=3d
    aspect = 0x03, // 0=all 1=stencil-only 2=depth-only
    base_mip_level = 0x04, // u32, default 0
    mip_level_count = 0x05, // u32, default: all remaining
    base_array_layer = 0x06, // u32, default 0
    array_layer_count = 0x07, // u32, default: all remaining
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

// Note: pipeline descriptors are carried as JSON, not TLV — there are no
// RenderPipelineField / ComputePipelineField TLV enums (they were dead and are
// removed; see journal §197).

// ============================================================================
// Enum Values (WebGPU enums encoded as u8)
// ============================================================================

pub const TextureFormat = enum(u8) {
    // Byte codes are the PNGB ABI: APPEND-ONLY. Never renumber or reuse an
    // existing code; new formats get new codes. Grouped by channel layout, with
    // gaps left for siblings (see the WebGPU GPUTextureFormat capability table).
    // Coverage = every uncompressed format. The feature-gated ones (tier1 16-bit
    // unorm/snorm, bgra8 srgb, depth32float-stencil8) encode here unconditionally;
    // the runtime opportunistically requests their device feature so they render
    // wherever the adapter allows. Only compressed formats (BC/ETC2/EAC/ASTC,
    // which need a compressed-data upload path) are intentionally absent.

    // 8-bit rgba/bgra + wide rgba + srgb (0x0x).
    rgba8unorm = 0x00,
    rgba8snorm = 0x01,
    rgba8uint = 0x02,
    rgba8sint = 0x03,
    bgra8unorm = 0x04,
    rgba16float = 0x05,
    rgba32float = 0x06,
    rgba8unorm_srgb = 0x07,
    bgra8unorm_srgb = 0x08, // gated on core-features-and-limits

    // Depth / stencil (0x1x).
    depth24plus = 0x10,
    depth24plus_stencil8 = 0x11,
    depth32float = 0x12,
    stencil8 = 0x13,
    depth16unorm = 0x14,
    depth32float_stencil8 = 0x15, // gated on the depth32float-stencil8 device feature

    // 32-bit-per-channel r/rg (0x2x).
    r32float = 0x20,
    rg32float = 0x21,
    r32uint = 0x22,
    r32sint = 0x23,
    rg32uint = 0x24,
    rg32sint = 0x25,

    // 8-bit & 16-bit-float r/rg (0x3x).
    r8unorm = 0x30,
    rg8unorm = 0x31,
    r16float = 0x32,
    rg16float = 0x33,
    r8snorm = 0x34,
    r8uint = 0x35,
    r8sint = 0x36,
    rg8snorm = 0x37,
    rg8uint = 0x38,
    rg8sint = 0x39,

    // 16-bit int r/rg (0x4x). 0x44-0x47: tier1 unorm/snorm siblings (gated on
    // texture-formats-tier1).
    r16uint = 0x40,
    r16sint = 0x41,
    rg16uint = 0x42,
    rg16sint = 0x43,
    r16unorm = 0x44,
    r16snorm = 0x45,
    rg16unorm = 0x46,
    rg16snorm = 0x47,

    // 16-bit int rgba (0x5x). 0x52-0x53: tier1 unorm/snorm siblings (gated on
    // texture-formats-tier1).
    rgba16uint = 0x50,
    rgba16sint = 0x51,
    rgba16unorm = 0x52,
    rgba16snorm = 0x53,

    // 32-bit int rgba (0x6x).
    rgba32uint = 0x60,
    rgba32sint = 0x61,

    // Packed 32-bit (0x7x).
    rgb10a2unorm = 0x70,
    rgb10a2uint = 0x71,
    rg11b10ufloat = 0x72,
    rgb9e5ufloat = 0x73,

    /// Sentinel: resolved at runtime to navigator.gpu.getPreferredCanvasFormat()
    preferred_canvas_format = 0xFF,
    /// Sentinel: an unknown/unsupported format string. fromString returns this
    /// instead of silently defaulting to rgba8unorm, so a mis-wired schema member
    /// fails loudly. The conformance test asserts no schema member maps here.
    invalid = 0xFE,
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
            .{ "rgba8unorm-srgb", .rgba8unorm_srgb },
            .{ "bgra8unorm-srgb", .bgra8unorm_srgb },
            .{ "depth24plus", .depth24plus },
            .{ "depth24plus-stencil8", .depth24plus_stencil8 },
            .{ "depth32float", .depth32float },
            .{ "stencil8", .stencil8 },
            .{ "depth16unorm", .depth16unorm },
            .{ "depth32float-stencil8", .depth32float_stencil8 },
            .{ "r32float", .r32float },
            .{ "rg32float", .rg32float },
            .{ "r32uint", .r32uint },
            .{ "r32sint", .r32sint },
            .{ "rg32uint", .rg32uint },
            .{ "rg32sint", .rg32sint },
            .{ "r8unorm", .r8unorm },
            .{ "rg8unorm", .rg8unorm },
            .{ "r16float", .r16float },
            .{ "rg16float", .rg16float },
            .{ "r8snorm", .r8snorm },
            .{ "r8uint", .r8uint },
            .{ "r8sint", .r8sint },
            .{ "rg8snorm", .rg8snorm },
            .{ "rg8uint", .rg8uint },
            .{ "rg8sint", .rg8sint },
            .{ "r16uint", .r16uint },
            .{ "r16sint", .r16sint },
            .{ "rg16uint", .rg16uint },
            .{ "rg16sint", .rg16sint },
            .{ "r16unorm", .r16unorm },
            .{ "r16snorm", .r16snorm },
            .{ "rg16unorm", .rg16unorm },
            .{ "rg16snorm", .rg16snorm },
            .{ "rgba16uint", .rgba16uint },
            .{ "rgba16sint", .rgba16sint },
            .{ "rgba16unorm", .rgba16unorm },
            .{ "rgba16snorm", .rgba16snorm },
            .{ "rgba32uint", .rgba32uint },
            .{ "rgba32sint", .rgba32sint },
            .{ "rgb10a2unorm", .rgb10a2unorm },
            .{ "rgb10a2uint", .rgb10a2uint },
            .{ "rg11b10ufloat", .rg11b10ufloat },
            .{ "rgb9e5ufloat", .rgb9e5ufloat },
            .{ "preferredCanvasFormat", .preferred_canvas_format },
        });
        return map.get(s) orelse .invalid;
    }

    /// WebGPU GPUTextureFormat string for this code — the reverse of
    /// fromString, and the single source for the JS codegen's reverse table.
    /// Sentinels and any code with no named format fall back to "rgba8unorm",
    /// matching the codegen's historical default branch.
    pub fn toWebGPU(self: TextureFormat) []const u8 {
        return switch (self) {
            .rgba8unorm => "rgba8unorm",
            .rgba8snorm => "rgba8snorm",
            .rgba8uint => "rgba8uint",
            .rgba8sint => "rgba8sint",
            .bgra8unorm => "bgra8unorm",
            .rgba16float => "rgba16float",
            .rgba32float => "rgba32float",
            .rgba8unorm_srgb => "rgba8unorm-srgb",
            .bgra8unorm_srgb => "bgra8unorm-srgb",
            .depth24plus => "depth24plus",
            .depth24plus_stencil8 => "depth24plus-stencil8",
            .depth32float => "depth32float",
            .stencil8 => "stencil8",
            .depth16unorm => "depth16unorm",
            .depth32float_stencil8 => "depth32float-stencil8",
            .r32float => "r32float",
            .rg32float => "rg32float",
            .r32uint => "r32uint",
            .r32sint => "r32sint",
            .rg32uint => "rg32uint",
            .rg32sint => "rg32sint",
            .r8unorm => "r8unorm",
            .rg8unorm => "rg8unorm",
            .r16float => "r16float",
            .rg16float => "rg16float",
            .r8snorm => "r8snorm",
            .r8uint => "r8uint",
            .r8sint => "r8sint",
            .rg8snorm => "rg8snorm",
            .rg8uint => "rg8uint",
            .rg8sint => "rg8sint",
            .r16uint => "r16uint",
            .r16sint => "r16sint",
            .rg16uint => "rg16uint",
            .rg16sint => "rg16sint",
            .r16unorm => "r16unorm",
            .r16snorm => "r16snorm",
            .rg16unorm => "rg16unorm",
            .rg16snorm => "rg16snorm",
            .rgba16uint => "rgba16uint",
            .rgba16sint => "rgba16sint",
            .rgba16unorm => "rgba16unorm",
            .rgba16snorm => "rgba16snorm",
            .rgba32uint => "rgba32uint",
            .rgba32sint => "rgba32sint",
            .rgb10a2unorm => "rgb10a2unorm",
            .rgb10a2uint => "rgb10a2uint",
            .rg11b10ufloat => "rg11b10ufloat",
            .rgb9e5ufloat => "rgb9e5ufloat",
            .preferred_canvas_format, .invalid, _ => "rgba8unorm",
        };
    }
};

pub const FilterMode = enum(u8) {
    nearest = 0x00,
    linear = 0x01,

    /// WebGPU GPUFilterMode / GPUMipmapFilterMode string.
    pub fn toWebGPU(self: FilterMode) []const u8 {
        return switch (self) {
            .nearest => "nearest",
            .linear => "linear",
        };
    }
};

pub const AddressMode = enum(u8) {
    clamp_to_edge = 0x00,
    repeat = 0x01,
    mirror_repeat = 0x02,

    /// WebGPU GPUAddressMode string.
    pub fn toWebGPU(self: AddressMode) []const u8 {
        return switch (self) {
            .clamp_to_edge => "clamp-to-edge",
            .repeat => "repeat",
            .mirror_repeat => "mirror-repeat",
        };
    }
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

    /// WebGPU GPUCompareFunction string.
    pub fn toWebGPU(self: CompareFunction) []const u8 {
        return switch (self) {
            .never => "never",
            .less => "less",
            .equal => "equal",
            .less_equal => "less-equal",
            .greater => "greater",
            .not_equal => "not-equal",
            .greater_equal => "greater-equal",
            .always => "always",
        };
    }
};

// Note: LoadOp and StoreOp are in opcodes.zig

pub const ResourceType = enum(u8) {
    buffer = 0x00,
    texture_view = 0x01, // a (texture …) bound directly → backend makes a default 2d view
    sampler = 0x02,
    external_texture = 0x03,
    explicit_texture_view = 0x04, // a pre-created (texture-view …) object, bound by view id
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
