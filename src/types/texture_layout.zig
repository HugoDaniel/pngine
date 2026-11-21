//! Texture write-layout contract.
//!
//! Plan 01's pure model: it proves a raw-byte write fits its source and
//! destination before any runtime emits or executes it. Nothing here
//! allocates, reads IO, touches GPU state, uses floating point, or falls back
//! to a default format. This file owns the public value shapes, the format-fact
//! table, destination usage/sample policy, depth/stencil aspect and
//! full-subresource rules, mip extents, descriptor/origin/range validation,
//! normalized strides and the required source span.

const std = @import("std");
const descriptors = @import("descriptors.zig");
const TextureFormat = descriptors.TextureFormat;
const TextureUsage = descriptors.TextureUsage;

/// WebGPU texture aspect tag, in the contract's fixed wire order.
pub const Aspect = enum(u8) {
    all = 0,
    stencil_only = 1,
    depth_only = 2,
    _,
};

/// Deterministic refusal codes from the plan's error catalogue.
pub const Code = enum {
    invalid_format,
    invalid_texture_descriptor,
    unsupported_dimension,
    missing_copy_dst,
    missing_copy_src,
    multisampled_destination,
    /// A texture→texture copy's endpoints must agree on sample count.
    sample_count_mismatch,
    /// A same-texture copy's source and destination subresource sets overlap.
    overlapping_subresources,
    invalid_aspect,
    aspect_not_writable,
    partial_depth_stencil_write,
    /// A depth-stencil or multisampled copy must cover the whole physical
    /// subresource (CRD `sections/copies.bs:263-266`).
    partial_subresource_copy,
    mip_out_of_range,
    origin_out_of_bounds,
    extent_out_of_bounds,
    unaligned_block_origin,
    unaligned_block_extent,
    missing_bytes_per_row,
    missing_rows_per_image,
    bytes_per_row_too_small,
    rows_per_image_too_small,
    bytes_per_row_alignment,
    buffer_offset_alignment,
    buffer_out_of_bounds,
    insufficient_data,
    arithmetic_overflow,
};

/// The most specific input named by a refusal. `none` is only for a
/// whole-descriptor refusal.
pub const Field = enum {
    none,
    format,
    aspect,
    dimension,
    usage,
    sample_count,
    mip_level,
    mip_level_count,
    size_width,
    size_height,
    size_depth_or_array_layers,
    origin_x,
    origin_y,
    origin_z,
    bytes_per_row,
    rows_per_image,
    offset,
    data,
};

pub const Extent = struct {
    width: u32,
    height: u32 = 1,
    depth_or_array_layers: u32 = 1,
};

pub const Origin = struct {
    x: u32 = 0,
    y: u32 = 0,
    z: u32 = 0,
};

pub const Dimension = enum {
    d1,
    d2,
    d3,
};

pub const ExtentSource = enum {
    explicit,
    canvas,
    image_bitmap,
};

pub const TextureDescriptor = struct {
    size: Extent,
    dimension: Dimension,
    format: TextureFormat,
    usage: TextureUsage,
    sample_count: u32,
    mip_level_count: u32,
    extent_source: ExtentSource,
};

pub const WriteLayout = struct {
    offset: u32 = 0,
    bytes_per_row: ?u32 = null,
    rows_per_image: ?u32 = null,
    origin: Origin = .{},
    mip_level: u32 = 0,
    aspect: Aspect = .all,
    size: ?Extent = null,
};

/// One `GPUTexelCopyTextureInfo` endpoint of a texture→texture copy: the
/// texture, its mip, origin and aspect. Plan 06's normalized model; the id is
/// the resolved (non-pool-member) texture id the wire will carry.
pub const SubresourceEndpoint = struct {
    texture_id: u16,
    mip_level: u32 = 0,
    origin: Origin = .{},
    aspect: Aspect = .all,
};

/// Plan 06's normalized `copyTextureToTexture`: both endpoints plus the method's
/// own `copySize`. An absent size means the remaining physical SOURCE extent at
/// `source.origin` and `source.mip_level`; `calculateTextureCopy` resolves it
/// once, with plan 01's `resolveCopyExtent`, and proves the destination holds
/// the same extent at its own origin.
pub const SubresourceCopy = struct {
    source: SubresourceEndpoint,
    destination: SubresourceEndpoint,
    size: ?Extent = null,
};

/// One endpoint's resolved physical facts. `copy_extent` is the size the copy
/// asks of this endpoint (the source's resolved default is the destination's
/// explicit size).
pub const SubresourceEndpointLayout = struct {
    mip: MipExtent,
    copy_extent: Extent,
};

/// Both endpoints resolved, plus the single copy extent the wire encodes.
pub const SubresourceCopyLayout = struct {
    source: SubresourceEndpointLayout,
    destination: SubresourceEndpointLayout,
    copy_extent: Extent,
};

/// Which side of a buffer↔texture copy the texture occupies. The usage bit the
/// texture endpoint must carry follows from this, and the two are different
/// checks: an upload writes a texture (`copy_dst`), a readback reads one
/// (`copy_src`).
pub const CopyDirection = enum { buffer_to_texture, texture_to_buffer };

/// Operation policy for the shared calculator. `writeTexture` is a queue write
/// and sets `aligned = false`; the GPUCommandEncoder buffer↔texture copies set
/// it true AND name the direction their texture endpoint occupies. Only
/// `aligned` acquires the bytes-per-row and buffer-offset rules, so a queue
/// write can never reach them.
pub const CopyPolicy = struct {
    aligned: bool,
    direction: CopyDirection = .buffer_to_texture,

    pub const queue_write: CopyPolicy = .{ .aligned = false };
    pub const buffer_to_texture: CopyPolicy = .{ .aligned = true, .direction = .buffer_to_texture };
    pub const texture_to_buffer: CopyPolicy = .{ .aligned = true, .direction = .texture_to_buffer };
};

pub const FormatInfo = struct {
    block_width: u32,
    block_height: u32,
    bytes_per_block: u32,
    has_depth: bool,
    has_stencil: bool,
    write_destination: bool,
};

pub const Layout = struct {
    logical_mip_extent: Extent,
    physical_mip_extent: Extent,
    copy_extent: Extent,
    width_in_blocks: u32,
    height_in_blocks: u32,
    bytes_in_last_row: u32,
    bytes_per_row: u32,
    rows_per_image: u32,
    image_stride: u32,
    required_bytes_in_copy: u32,
    end_offset: u32,
};

pub const Refusal = struct {
    code: Code,
    field: Field,
    actual: u64 = 0,
    limit: u64 = 0,
};

pub const FormatInfoResult = union(enum) {
    ok: FormatInfo,
    refuse: Refusal,
};

pub const Result = union(enum) {
    ok: Layout,
    refuse: Refusal,
};

/// One row of WebGPU's texel-block facts for a named format. Colour rows set
/// `color_bytes_per_block`; depth/stencil rows set the per-aspect fields. A
/// zero footprint means WebGPU publishes none for that aspect (depth24plus),
/// never an invented size. `*_write_destination` is the CRD's valid texel-copy
/// destination verdict; writability is never inferred from a footprint.
const FormatRow = struct {
    format: TextureFormat,
    // Block dimensions and footprints are u8: WebGPU's largest block is 12x12
    // and its largest footprint 16 bytes. Keeping the table narrow matters —
    // the executor carries it — and every reading site widens before returning
    // the u32 contract values.
    block_width: u8 = 1,
    block_height: u8 = 1,
    color_bytes_per_block: u8 = 0,
    has_depth: bool = false,
    has_stencil: bool = false,
    depth_bytes_per_block: u8 = 0,
    depth_write_destination: bool = false,
    stencil_bytes_per_block: u8 = 0,
    stencil_write_destination: bool = false,
};

/// Which compressed family a format byte belongs to. The family names its
/// required device feature and, for BC/ASTC, its 3D-sliced sibling feature.
pub const CompressedFamily = enum(u8) {
    none = 0,
    bc = 1,
    etc2 = 2,
    astc = 3,
};

/// One compressed format's copy facts. `sliced_3d` is the CRD's dimension
/// support: BC and ASTC allow 3D only with their sliced-3d feature; ETC2/EAC
/// has no sliced feature at all, so 3D is always invalid.
const CompressedRow = struct {
    block_width: u8,
    block_height: u8,
    bytes_per_block: u8,
    family: CompressedFamily,
    sliced_3d: bool,
};

/// ASTC shapes in plan/CRD order, one byte each: low nibble = width, high
/// nibble = height. The 28 ASTC codes alternate linear then sRGB, so
/// `index = (code - 0xa0) / 2` selects one entry.
const astc_shapes = [_]u8{
    0x44, 0x45, 0x55, 0x56, 0x66, 0x58, 0x68,
    0x88, 0x5a, 0x6a, 0x8a, 0xaa, 0xac, 0xcc,
};

/// The single compressed block/byte table, shared by `formatInfo`, the
/// descriptor rules and every copy calculator. Codes are the append-only plan
/// 07 bytes; a family's bytes-per-block pattern is part of the CRD table, not
/// inferred from a texel width. `null` means the byte is not compressed (an
/// ordinary format row, a sentinel, or an unknown byte).
fn compressedRow(code: u8) ?CompressedRow {
    if (code >= 0x80 and code <= 0x8d) {
        const index = code - 0x80;
        const bytes: u8 = switch (index) {
            0, 1, 6, 7 => 8,
            else => 16,
        };
        return .{ .block_width = 4, .block_height = 4, .bytes_per_block = bytes, .family = .bc, .sliced_3d = true };
    }
    if (code >= 0x90 and code <= 0x99) {
        const index = code - 0x90;
        const bytes: u8 = switch (index) {
            0, 1, 2, 3, 6, 7 => 8,
            else => 16,
        };
        return .{ .block_width = 4, .block_height = 4, .bytes_per_block = bytes, .family = .etc2, .sliced_3d = false };
    }
    if (code >= 0xa0 and code <= 0xbb) {
        const shape = astc_shapes[(code - 0xa0) >> 1];
        return .{
            .block_width = shape & 0x0f,
            .block_height = shape >> 4,
            .bytes_per_block = 16,
            .family = .astc,
            .sliced_3d = true,
        };
    }
    return null;
}

/// The feature-policy facts a compressed format implies. `family = .none` for
/// every ordinary format. Callers map the family to the WebGPU feature name.
pub const FormatFeature = struct {
    family: CompressedFamily,
    sliced_3d: bool,
};

pub fn formatFeature(format: TextureFormat) FormatFeature {
    const row = compressedRow(@intFromEnum(format)) orelse
        return .{ .family = .none, .sliced_3d = false };
    return .{ .family = row.family, .sliced_3d = row.sliced_3d };
}

/// Every named ordinary format, in the enum's own declaration order. The
/// sentinels are values, not formats: they deliberately have no row, so an
/// unresolved or unknown format refuses instead of acquiring a footprint.
const format_rows = [_]FormatRow{
    // 8-bit RGBA/BGRA and wide RGBA/sRGB (0x0x).
    .{ .format = .rgba8unorm, .color_bytes_per_block = 4 },
    .{ .format = .rgba8snorm, .color_bytes_per_block = 4 },
    .{ .format = .rgba8uint, .color_bytes_per_block = 4 },
    .{ .format = .rgba8sint, .color_bytes_per_block = 4 },
    .{ .format = .bgra8unorm, .color_bytes_per_block = 4 },
    .{ .format = .rgba16float, .color_bytes_per_block = 8 },
    .{ .format = .rgba32float, .color_bytes_per_block = 16 },
    .{ .format = .rgba8unorm_srgb, .color_bytes_per_block = 4 },
    .{ .format = .bgra8unorm_srgb, .color_bytes_per_block = 4 },

    // Depth / stencil (0x1x). depth24plus has no copy footprint; the
    // depth32float family's depth aspect is a validated copy source but not a
    // destination. stencil8 and depth16unorm are both.
    .{ .format = .depth24plus, .has_depth = true },
    .{
        .format = .depth24plus_stencil8,
        .has_depth = true,
        .has_stencil = true,
        .stencil_bytes_per_block = 1,
        .stencil_write_destination = true,
    },
    .{
        .format = .depth32float,
        .has_depth = true,
        .depth_bytes_per_block = 4,
    },
    .{
        .format = .stencil8,
        .has_stencil = true,
        .stencil_bytes_per_block = 1,
        .stencil_write_destination = true,
    },
    .{
        .format = .depth16unorm,
        .has_depth = true,
        .depth_bytes_per_block = 2,
        .depth_write_destination = true,
    },
    .{
        .format = .depth32float_stencil8,
        .has_depth = true,
        .has_stencil = true,
        .depth_bytes_per_block = 4,
        .stencil_bytes_per_block = 1,
        .stencil_write_destination = true,
    },

    // 32-bit-per-channel r/rg (0x2x).
    .{ .format = .r32float, .color_bytes_per_block = 4 },
    .{ .format = .rg32float, .color_bytes_per_block = 8 },
    .{ .format = .r32uint, .color_bytes_per_block = 4 },
    .{ .format = .r32sint, .color_bytes_per_block = 4 },
    .{ .format = .rg32uint, .color_bytes_per_block = 8 },
    .{ .format = .rg32sint, .color_bytes_per_block = 8 },

    // 8-bit & 16-bit-float r/rg (0x3x).
    .{ .format = .r8unorm, .color_bytes_per_block = 1 },
    .{ .format = .rg8unorm, .color_bytes_per_block = 2 },
    .{ .format = .r16float, .color_bytes_per_block = 2 },
    .{ .format = .rg16float, .color_bytes_per_block = 4 },
    .{ .format = .r8snorm, .color_bytes_per_block = 1 },
    .{ .format = .r8uint, .color_bytes_per_block = 1 },
    .{ .format = .r8sint, .color_bytes_per_block = 1 },
    .{ .format = .rg8snorm, .color_bytes_per_block = 2 },
    .{ .format = .rg8uint, .color_bytes_per_block = 2 },
    .{ .format = .rg8sint, .color_bytes_per_block = 2 },

    // 16-bit int/unorm r/rg (0x4x).
    .{ .format = .r16uint, .color_bytes_per_block = 2 },
    .{ .format = .r16sint, .color_bytes_per_block = 2 },
    .{ .format = .rg16uint, .color_bytes_per_block = 4 },
    .{ .format = .rg16sint, .color_bytes_per_block = 4 },
    .{ .format = .r16unorm, .color_bytes_per_block = 2 },
    .{ .format = .r16snorm, .color_bytes_per_block = 2 },
    .{ .format = .rg16unorm, .color_bytes_per_block = 4 },
    .{ .format = .rg16snorm, .color_bytes_per_block = 4 },

    // 16-bit int/unorm rgba (0x5x).
    .{ .format = .rgba16uint, .color_bytes_per_block = 8 },
    .{ .format = .rgba16sint, .color_bytes_per_block = 8 },
    .{ .format = .rgba16unorm, .color_bytes_per_block = 8 },
    .{ .format = .rgba16snorm, .color_bytes_per_block = 8 },

    // 32-bit int rgba (0x6x).
    .{ .format = .rgba32uint, .color_bytes_per_block = 16 },
    .{ .format = .rgba32sint, .color_bytes_per_block = 16 },

    // Packed 32-bit (0x7x).
    .{ .format = .rgb10a2unorm, .color_bytes_per_block = 4 },
    .{ .format = .rgb10a2uint, .color_bytes_per_block = 4 },
    .{ .format = .rg11b10ufloat, .color_bytes_per_block = 4 },
    .{ .format = .rgb9e5ufloat, .color_bytes_per_block = 4 },
};

/// Total index over every possible enum byte, including undeclared ones. The
/// index is the enum's u8 tag, so no hostile byte can trap a cast; the row
/// itself is fetched only after a non-null hit.
const row_index_by_byte: [256]?u8 = blk: {
    var table = [_]?u8{null} ** 256;
    for (format_rows, 0..) |row, index| table[@intFromEnum(row.format)] = @as(u8, index);
    break :blk table;
};

/// The number of named formats with a row (the two sentinels have none).
/// Compressed formats are named in the enum as their tranche lands and resolve
/// through `compressedRow`, so the count follows the enum rather than only the
/// ordinary-format array.
pub const format_row_count: usize = blk: {
    var count: usize = 0;
    for (std.meta.fields(TextureFormat)) |field| {
        const format: TextureFormat = @field(TextureFormat, field.name);
        if (format == .preferred_canvas_format or format == .invalid) continue;
        count += 1;
    }
    break :blk count;
};

/// True when this enum byte has a format row. Sentinels and unknown bytes do not.
pub fn hasFormatRow(format: TextureFormat) bool {
    const byte = @intFromEnum(format);
    return row_index_by_byte[byte] != null or compressedRow(byte) != null;
}

fn refusal(code: Code, field: Field) Refusal {
    return .{ .code = code, .field = field };
}

/// Resolve a format and the selected aspect to its copy footprint. Unknown
/// format bytes, sentinels and absent aspect rows refuse with `invalid-format`
/// instead of falling back to any format. Depth/stencil rows resolve exactly
/// one legal aspect and apply D6's destination policy before exposing a
/// footprint; plain colour formats accept only the `all` tag.
pub fn formatInfo(format: TextureFormat, aspect: Aspect) FormatInfoResult {
    const byte = @intFromEnum(format);
    const row_index = row_index_by_byte[byte] orelse {
        // Compressed formats are colour-only: exactly one legal aspect, `all`.
        const compressed = compressedRow(byte) orelse
            return .{ .refuse = refusal(.invalid_format, .format) };
        if (aspect != .all) return .{ .refuse = refusal(.invalid_aspect, .aspect) };
        return .{ .ok = .{
            .block_width = compressed.block_width,
            .block_height = compressed.block_height,
            .bytes_per_block = compressed.bytes_per_block,
            .has_depth = false,
            .has_stencil = false,
            .write_destination = true,
        } };
    };
    const row = format_rows[row_index];

    if (row.has_depth or row.has_stencil) {
        const bytes_per_block: u32 = switch (aspect) {
            .depth_only => blk: {
                if (!row.has_depth) return .{ .refuse = refusal(.invalid_aspect, .aspect) };
                if (!row.depth_write_destination) return .{ .refuse = refusal(.aspect_not_writable, .aspect) };
                break :blk row.depth_bytes_per_block;
            },
            .stencil_only => blk: {
                if (!row.has_stencil) return .{ .refuse = refusal(.invalid_aspect, .aspect) };
                if (!row.stencil_write_destination) return .{ .refuse = refusal(.aspect_not_writable, .aspect) };
                break :blk row.stencil_bytes_per_block;
            },
            // `.all` is not singular, and an undeclared aspect tag is unknown.
            else => return .{ .refuse = refusal(.invalid_aspect, .aspect) },
        };
        if (bytes_per_block == 0) return .{ .refuse = refusal(.invalid_format, .format) };
        return .{ .ok = .{
            .block_width = row.block_width,
            .block_height = row.block_height,
            .bytes_per_block = bytes_per_block,
            .has_depth = row.has_depth,
            .has_stencil = row.has_stencil,
            .write_destination = true,
        } };
    }

    if (aspect != .all) return .{ .refuse = refusal(.invalid_aspect, .aspect) };
    if (row.color_bytes_per_block == 0) return .{ .refuse = refusal(.invalid_format, .format) };
    return .{ .ok = .{
        .block_width = row.block_width,
        .block_height = row.block_height,
        .bytes_per_block = row.color_bytes_per_block,
        .has_depth = false,
        .has_stencil = false,
        .write_destination = true,
    } };
}

fn valueRefusal(code: Code, field: Field, actual: u64, limit: u64) Refusal {
    return .{ .code = code, .field = field, .actual = actual, .limit = limit };
}

pub const MipExtent = struct {
    logical: Extent,
    physical: Extent,
};

pub const MipExtentResult = union(enum) {
    ok: MipExtent,
    refuse: Refusal,
};

/// Round a logical axis up to a whole texel block, in u64. The caller checks
/// the result against u32 before narrowing; a u32 logical value plus a block
/// cannot wrap in u64.
fn roundUpToBlock(value: u32, block: u32) u64 {
    std.debug.assert(block > 0);
    const block_wide: u64 = block;
    return (@as(u64, value) + block_wide - 1) / block_wide * block_wide;
}

/// Logical and physical (block-rounded) extents at `mip_level` for a concrete
/// base size. 2D array layers are not reduced by the mip; 3D depth is. Every
/// division is a right shift after proving the index is below 32, and rounding
/// is computed in u64 and refused if it would exceed u32.
pub fn mipExtent(
    size: Extent,
    dimension: Dimension,
    mip_level: u32,
    block_width: u32,
    block_height: u32,
) MipExtentResult {
    if (block_width == 0 or block_height == 0) {
        return .{ .refuse = refusal(.invalid_format, .format) };
    }
    if (mip_level >= 32) {
        return .{ .refuse = valueRefusal(.mip_out_of_range, .mip_level, mip_level, 32) };
    }

    const reduction: u5 = @intCast(mip_level);
    const logical: Extent = switch (dimension) {
        .d1 => .{
            .width = @max(1, size.width >> reduction),
            .height = 1,
            .depth_or_array_layers = 1,
        },
        .d2 => .{
            .width = @max(1, size.width >> reduction),
            .height = @max(1, size.height >> reduction),
            .depth_or_array_layers = size.depth_or_array_layers,
        },
        .d3 => .{
            .width = @max(1, size.width >> reduction),
            .height = @max(1, size.height >> reduction),
            .depth_or_array_layers = @max(1, size.depth_or_array_layers >> reduction),
        },
    };

    const padded_width = roundUpToBlock(logical.width, block_width);
    if (padded_width > std.math.maxInt(u32)) {
        return .{ .refuse = valueRefusal(.arithmetic_overflow, .size_width, padded_width, std.math.maxInt(u32)) };
    }
    // The CRD fixes a 1D texture's physical height at 1; only 2D/3D round it.
    const physical_height: u32 = switch (dimension) {
        .d1 => 1,
        else => blk: {
            const padded_height = roundUpToBlock(logical.height, block_height);
            if (padded_height > std.math.maxInt(u32)) {
                return .{ .refuse = valueRefusal(.arithmetic_overflow, .size_height, padded_height, std.math.maxInt(u32)) };
            }
            break :blk @intCast(padded_height);
        },
    };

    return .{ .ok = .{
        .logical = logical,
        .physical = .{
            .width = @intCast(padded_width),
            .height = physical_height,
            .depth_or_array_layers = logical.depth_or_array_layers,
        },
    } };
}

fn formatHasDepthOrStencil(format: TextureFormat) bool {
    const row_index = row_index_by_byte[@intFromEnum(format)] orelse return false;
    const row = format_rows[row_index];
    return row.has_depth or row.has_stencil;
}

/// WebGPU's `maximum mipLevel count`: floor(log2(maxDimension)) + 1, with 1D
/// fixed at one level. The integer bit length is that floor plus one.
fn maximumMipLevelCount(dimension: Dimension, size: Extent) u32 {
    const max_dimension: u32 = switch (dimension) {
        .d1 => return 1,
        .d2 => @max(size.width, size.height),
        .d3 => @max(@max(size.width, size.height), size.depth_or_array_layers),
    };
    std.debug.assert(max_dimension > 0);
    return @as(u32, @bitSizeOf(u32)) - @as(u32, @clz(max_dimension));
}

/// Descriptor checks that need no device: positive concrete extent and mip
/// count, the 1D shape, the maximum mip count, and the depth/stencil formats'
/// absent 1D/3D support. Adapter-specific maxima stay the runtime's job.
fn validateDescriptor(descriptor: TextureDescriptor) ?Refusal {
    if (descriptor.size.width == 0) {
        return valueRefusal(.invalid_texture_descriptor, .size_width, 0, 1);
    }
    if (descriptor.size.height == 0) {
        return valueRefusal(.invalid_texture_descriptor, .size_height, 0, 1);
    }
    if (descriptor.size.depth_or_array_layers == 0) {
        return valueRefusal(.invalid_texture_descriptor, .size_depth_or_array_layers, 0, 1);
    }
    if (descriptor.mip_level_count == 0) {
        return valueRefusal(.invalid_texture_descriptor, .mip_level_count, 0, 1);
    }

    switch (descriptor.dimension) {
        .d1 => {
            if (descriptor.size.height != 1) {
                return valueRefusal(.invalid_texture_descriptor, .size_height, descriptor.size.height, 1);
            }
            if (descriptor.size.depth_or_array_layers != 1) {
                return valueRefusal(.invalid_texture_descriptor, .size_depth_or_array_layers, descriptor.size.depth_or_array_layers, 1);
            }
        },
        .d2, .d3 => {},
    }

    const max_mips = maximumMipLevelCount(descriptor.dimension, descriptor.size);
    if (descriptor.mip_level_count > max_mips) {
        return valueRefusal(.invalid_texture_descriptor, .mip_level_count, descriptor.mip_level_count, max_mips);
    }

    // Compressed creation rules: 1D is never compressed; a 3D descriptor needs
    // a sliced-3d family (BC/ASTC; ETC2/EAC has none); and the BASE width and
    // height must be whole texel blocks unless the device exposes
    // `texture-compression-unaligned`. This tranche does not request that
    // relaxation, so the strict rule is the calculator's rule. Mip levels below
    // the base may reduce to a partial logical block; their physical extent is
    // block-rounded by `mipExtent`, which is why only the base is checked here.
    if (compressedRow(@intFromEnum(descriptor.format))) |row| {
        if (descriptor.dimension == .d1) {
            return valueRefusal(.invalid_texture_descriptor, .format, @intFromEnum(descriptor.format), 0);
        }
        if (descriptor.dimension == .d3 and !row.sliced_3d) {
            return valueRefusal(.invalid_texture_descriptor, .format, @intFromEnum(descriptor.format), 0);
        }
        if (descriptor.size.width % row.block_width != 0) {
            return valueRefusal(.invalid_texture_descriptor, .size_width, descriptor.size.width, row.block_width);
        }
        if (descriptor.size.height % row.block_height != 0) {
            return valueRefusal(.invalid_texture_descriptor, .size_height, descriptor.size.height, row.block_height);
        }
    }

    // Plain colour formats support 1D, 2D and 3D; depth/stencil formats do not
    // support 1D or 3D. Unknown formats fall through to `formatInfo`.
    if ((descriptor.dimension == .d1 or descriptor.dimension == .d3) and formatHasDepthOrStencil(descriptor.format)) {
        return valueRefusal(.invalid_texture_descriptor, .format, @intFromEnum(descriptor.format), 0);
    }
    return null;
}

/// The texture half of WebGPU's `validating texture buffer copy`: the texture
/// endpoint must carry the usage bit the copy direction requires (COPY_DST for
/// a destination, COPY_SRC for a source) and exactly one sample. Usage is the
/// outer check, so a texture that is the wrong endpoint never reaches aspect
/// parsing. `actual` is the usage byte (or sample count); `limit` is the
/// required usage bit (or 1).
fn textureEndpointRefusal(descriptor: TextureDescriptor, policy: CopyPolicy) ?Refusal {
    const is_source = policy.direction == .texture_to_buffer;
    if (is_source) {
        if (!descriptor.usage.copy_src) {
            return valueRefusal(.missing_copy_src, .usage, descriptor.usage.toU8(), TextureUsage.WEBGPU_COPY_SRC);
        }
    } else if (!descriptor.usage.copy_dst) {
        return valueRefusal(.missing_copy_dst, .usage, descriptor.usage.toU8(), TextureUsage.WEBGPU_COPY_DST);
    }
    if (descriptor.sample_count != 1) {
        return valueRefusal(.multisampled_destination, .sample_count, descriptor.sample_count, 1);
    }
    return null;
}

fn originRefusal(origin: Origin, physical: Extent) ?Refusal {
    if (origin.x > physical.width) {
        return valueRefusal(.origin_out_of_bounds, .origin_x, origin.x, physical.width);
    }
    if (origin.y > physical.height) {
        return valueRefusal(.origin_out_of_bounds, .origin_y, origin.y, physical.height);
    }
    if (origin.z > physical.depth_or_array_layers) {
        return valueRefusal(.origin_out_of_bounds, .origin_z, origin.z, physical.depth_or_array_layers);
    }
    return null;
}

/// WebGPU requires a depth/stencil texel copy to cover the full physical
/// subresource (CRD `validating GPUTexelCopyTextureInfo`): the copy extent must
/// equal the physical mip extent, which also forces every origin component to
/// zero. A reduced extent or a nonzero origin is a partial depth/stencil write,
/// named per axis in x, y, z, width, height, depth order. `code` distinguishes
/// the write path's `partial-depth-stencil-write` from a texture→texture copy's
/// `partial-subresource-copy` (which also covers multisampled endpoints).
fn fullSubresourceRefusal(origin: Origin, copy: Extent, physical: Extent, code: Code) ?Refusal {
    if (origin.x != 0) return valueRefusal(code, .origin_x, origin.x, 0);
    if (origin.y != 0) return valueRefusal(code, .origin_y, origin.y, 0);
    if (origin.z != 0) return valueRefusal(code, .origin_z, origin.z, 0);
    if (copy.width != physical.width) {
        return valueRefusal(code, .size_width, copy.width, physical.width);
    }
    if (copy.height != physical.height) {
        return valueRefusal(code, .size_height, copy.height, physical.height);
    }
    if (copy.depth_or_array_layers != physical.depth_or_array_layers) {
        return valueRefusal(
            code,
            .size_depth_or_array_layers,
            copy.depth_or_array_layers,
            physical.depth_or_array_layers,
        );
    }
    return null;
}

const CopyExtentResult = union(enum) {
    ok: Extent,
    refuse: Refusal,
};

/// Default an omitted size to the remaining physical extent at the origin, or
/// prove an explicit size fits. Additions happen in u64 so no sum can wrap.
fn resolveCopyExtent(physical: Extent, write: WriteLayout) CopyExtentResult {
    if (write.size) |size| {
        const end_x = @as(u64, write.origin.x) + size.width;
        if (end_x > @as(u64, physical.width)) {
            return .{ .refuse = valueRefusal(.extent_out_of_bounds, .size_width, end_x, physical.width) };
        }
        const end_y = @as(u64, write.origin.y) + size.height;
        if (end_y > @as(u64, physical.height)) {
            return .{ .refuse = valueRefusal(.extent_out_of_bounds, .size_height, end_y, physical.height) };
        }
        const end_z = @as(u64, write.origin.z) + size.depth_or_array_layers;
        if (end_z > @as(u64, physical.depth_or_array_layers)) {
            return .{ .refuse = valueRefusal(.extent_out_of_bounds, .size_depth_or_array_layers, end_z, physical.depth_or_array_layers) };
        }
        return .{ .ok = size };
    }
    return .{ .ok = .{
        .width = physical.width - write.origin.x,
        .height = physical.height - write.origin.y,
        .depth_or_array_layers = physical.depth_or_array_layers - write.origin.z,
    } };
}

/// Check a copy origin and extent against a format's texel-block dimensions.
/// Plan 01 has no block larger than 1x1, so `calculateWrite` always passes;
/// the pure rule is exposed for the Task 2 unit and plan 07's compressed rows.
pub fn blockAlignmentRefusal(
    origin: Origin,
    size: Extent,
    block_width: u32,
    block_height: u32,
) ?Refusal {
    if (block_width == 0 or block_height == 0) return refusal(.invalid_format, .format);
    if (origin.x % block_width != 0) {
        return valueRefusal(.unaligned_block_origin, .origin_x, origin.x, block_width);
    }
    if (origin.y % block_height != 0) {
        return valueRefusal(.unaligned_block_origin, .origin_y, origin.y, block_height);
    }
    if (size.width % block_width != 0) {
        return valueRefusal(.unaligned_block_extent, .size_width, size.width, block_width);
    }
    if (size.height % block_height != 0) {
        return valueRefusal(.unaligned_block_extent, .size_height, size.height, block_height);
    }
    return null;
}

/// The two buffer-copy alignment rules, applied only under the aligned policy.
/// `validating GPUTexelCopyBufferInfo` requires a supplied bytesPerRow to be a
/// multiple of 256; `validating texture buffer copy` requires the buffer offset
/// to be a multiple of the texel block copy footprint, except that a
/// depth-stencil texture endpoint — source or destination — sets it to 4.
/// `writeTexture` passes `aligned = false` and acquires neither.
fn copyAlignmentRefusal(write: WriteLayout, info: FormatInfo, policy: CopyPolicy) ?Refusal {
    if (!policy.aligned) return null;

    if (write.bytes_per_row) |supplied| {
        if (supplied % 256 != 0) {
            return valueRefusal(.bytes_per_row_alignment, .bytes_per_row, supplied, 256);
        }
    }

    const offset_alignment: u32 = if (info.has_depth or info.has_stencil) 4 else info.bytes_per_block;
    // `formatInfo` never exposes a zero footprint, but keep the rule total.
    if (offset_alignment == 0) return refusal(.invalid_format, .format);
    if (write.offset % offset_alignment != 0) {
        return valueRefusal(.buffer_offset_alignment, .offset, write.offset, offset_alignment);
    }
    return null;
}

const CheckedValue = union(enum) {
    ok: u64,
    refuse: Refusal,
};

/// Multiply two nonnegative values in checked u64 and prove the product is a
/// legal returned u32. Operands are widened before multiplication, so no
/// overflow check runs on an already-narrowed input.
fn checkedMul(field: Field, a: u64, b: u64) CheckedValue {
    const product = std.math.mul(u64, a, b) catch {
        // Unreachable for u32 inputs, but an overflowing intermediate is still
        // a refusal rather than a wrapped value.
        return .{ .refuse = valueRefusal(.arithmetic_overflow, field, std.math.maxInt(u64), std.math.maxInt(u64)) };
    };
    if (product > std.math.maxInt(u32)) {
        return .{ .refuse = valueRefusal(.arithmetic_overflow, field, product, std.math.maxInt(u32)) };
    }
    return .{ .ok = product };
}

/// Add two nonnegative values in checked u64 and prove the sum is a legal
/// returned u32.
fn checkedAdd(field: Field, a: u64, b: u64) CheckedValue {
    const sum = std.math.add(u64, a, b) catch {
        return .{ .refuse = valueRefusal(.arithmetic_overflow, field, std.math.maxInt(u64), std.math.maxInt(u64)) };
    };
    if (sum > std.math.maxInt(u32)) {
        return .{ .refuse = valueRefusal(.arithmetic_overflow, field, sum, std.math.maxInt(u32)) };
    }
    return .{ .ok = sum };
}

const LinearLayout = struct {
    width_in_blocks: u32,
    height_in_blocks: u32,
    bytes_in_last_row: u32,
    bytes_per_row: u32,
    rows_per_image: u32,
    image_stride: u32,
    required_bytes_in_copy: u32,
    end_offset: u32,
};

const LinearResult = union(enum) {
    ok: LinearLayout,
    refuse: Refusal,
};

/// The arithmetic specification's steps 5-9: block counts, stride presence and
/// minima, normalized strides, the required span with final-row and
/// final-image padding excluded, and the offset-inclusive end. Every product
/// and sum is checked in u64 and must fit u32 before it becomes a returned or
/// wire value.
fn resolveLinearLayout(write: WriteLayout, copy: Extent, info: FormatInfo) LinearResult {
    const width_in_blocks: u32 = copy.width / info.block_width;
    const height_in_blocks: u32 = copy.height / info.block_height;

    const bytes_in_last_row: u32 = switch (checkedMul(.size_width, width_in_blocks, info.bytes_per_block)) {
        .ok => |value| @intCast(value),
        .refuse => |refusal_value| return .{ .refuse = refusal_value },
    };

    const depth = copy.depth_or_array_layers;
    if ((height_in_blocks > 1 or depth > 1) and write.bytes_per_row == null) {
        return .{ .refuse = valueRefusal(.missing_bytes_per_row, .bytes_per_row, 0, bytes_in_last_row) };
    }
    if (depth > 1 and write.rows_per_image == null) {
        return .{ .refuse = valueRefusal(.missing_rows_per_image, .rows_per_image, 0, height_in_blocks) };
    }
    // Supplied minima apply even when the field was not required.
    if (write.bytes_per_row) |supplied| {
        if (supplied < bytes_in_last_row) {
            return .{ .refuse = valueRefusal(.bytes_per_row_too_small, .bytes_per_row, supplied, bytes_in_last_row) };
        }
    }
    if (write.rows_per_image) |supplied| {
        if (supplied < height_in_blocks) {
            return .{ .refuse = valueRefusal(.rows_per_image_too_small, .rows_per_image, supplied, height_in_blocks) };
        }
    }

    // Presence is decided above; only now may an omitted stride take its
    // normalized minimum. An authored zero never becomes a minimum.
    const bytes_per_row: u32 = write.bytes_per_row orelse bytes_in_last_row;
    const rows_per_image: u32 = write.rows_per_image orelse height_in_blocks;
    const image_stride: u32 = switch (checkedMul(.bytes_per_row, bytes_per_row, rows_per_image)) {
        .ok => |value| @intCast(value),
        .refuse => |refusal_value| return .{ .refuse = refusal_value },
    };

    var required_bytes: u64 = 0;
    if (depth > 0) {
        // One full image stride per gap before the final image. This term
        // exists even when the copy height is zero.
        const image_gap: u64 = switch (checkedMul(.size_depth_or_array_layers, image_stride, depth - 1)) {
            .ok => |value| value,
            .refuse => |refusal_value| return .{ .refuse = refusal_value },
        };
        required_bytes = switch (checkedAdd(.data, required_bytes, image_gap)) {
            .ok => |value| value,
            .refuse => |refusal_value| return .{ .refuse = refusal_value },
        };
        if (height_in_blocks > 0) {
            // The final row contributes bytesInLastRow, never a full stride.
            const row_gap: u64 = switch (checkedMul(.bytes_per_row, bytes_per_row, height_in_blocks - 1)) {
                .ok => |value| value,
                .refuse => |refusal_value| return .{ .refuse = refusal_value },
            };
            const rows_and_last: u64 = switch (checkedAdd(.bytes_per_row, row_gap, bytes_in_last_row)) {
                .ok => |value| value,
                .refuse => |refusal_value| return .{ .refuse = refusal_value },
            };
            required_bytes = switch (checkedAdd(.data, required_bytes, rows_and_last)) {
                .ok => |value| value,
                .refuse => |refusal_value| return .{ .refuse = refusal_value },
            };
        }
    }

    // `offset` is counted once, outside the span.
    const end_offset: u32 = switch (checkedAdd(.offset, write.offset, required_bytes)) {
        .ok => |value| @intCast(value),
        .refuse => |refusal_value| return .{ .refuse = refusal_value },
    };

    return .{ .ok = .{
        .width_in_blocks = width_in_blocks,
        .height_in_blocks = height_in_blocks,
        .bytes_in_last_row = bytes_in_last_row,
        .bytes_per_row = bytes_per_row,
        .rows_per_image = rows_per_image,
        .image_stride = image_stride,
        .required_bytes_in_copy = @intCast(required_bytes),
        .end_offset = end_offset,
    } };
}

/// The shared texel-copy calculator. Stages, in order, so the first refusal is
/// stable: descriptor, the texture endpoint's usage/sample count for the
/// policy's direction, format/aspect, mip range, origin, default/explicit copy
/// extent and range, depth/stencil full subresource, block alignment, the
/// policy's buffer-copy alignment, then the linear-data rules (stride presence
/// and minima, normalized strides, required span, source/buffer length). A
/// short aligned buffer reports `buffer-out-of-bounds`; the queue write keeps
/// plan 01's `insufficient-data`.
pub fn calculateCopy(
    descriptor: TextureDescriptor,
    write: WriteLayout,
    data_length: u64,
    policy: CopyPolicy,
) Result {
    if (validateDescriptor(descriptor)) |refusal_value| {
        return .{ .refuse = refusal_value };
    }

    if (textureEndpointRefusal(descriptor, policy)) |refusal_value| {
        return .{ .refuse = refusal_value };
    }

    const info = switch (formatInfo(descriptor.format, write.aspect)) {
        .ok => |info| info,
        .refuse => |refusal_value| return .{ .refuse = refusal_value },
    };

    if (write.mip_level >= descriptor.mip_level_count) {
        return .{ .refuse = valueRefusal(.mip_out_of_range, .mip_level, write.mip_level, descriptor.mip_level_count) };
    }

    const mip = switch (mipExtent(descriptor.size, descriptor.dimension, write.mip_level, info.block_width, info.block_height)) {
        .ok => |mip| mip,
        .refuse => |refusal_value| return .{ .refuse = refusal_value },
    };

    if (originRefusal(write.origin, mip.physical)) |refusal_value| {
        return .{ .refuse = refusal_value };
    }

    const copy = switch (resolveCopyExtent(mip.physical, write)) {
        .ok => |copy| copy,
        .refuse => |refusal_value| return .{ .refuse = refusal_value },
    };

    // The CRD's range stage requires depth/stencil copies to cover the full
    // physical subresource; a subregion or nonzero origin is never a partial
    // aspect write. Plain colour formats keep their subregions.
    if (info.has_depth or info.has_stencil) {
        if (fullSubresourceRefusal(write.origin, copy, mip.physical, .partial_depth_stencil_write)) |refusal_value| {
            return .{ .refuse = refusal_value };
        }
    }

    if (blockAlignmentRefusal(write.origin, copy, info.block_width, info.block_height)) |refusal_value| {
        return .{ .refuse = refusal_value };
    }

    if (copyAlignmentRefusal(write, info, policy)) |refusal_value| {
        return .{ .refuse = refusal_value };
    }

    const linear = switch (resolveLinearLayout(write, copy, info)) {
        .ok => |linear| linear,
        .refuse => |refusal_value| return .{ .refuse = refusal_value },
    };

    if (@as(u64, linear.end_offset) > data_length) {
        if (policy.aligned) {
            return .{ .refuse = valueRefusal(.buffer_out_of_bounds, .data, linear.end_offset, data_length) };
        }
        return .{ .refuse = valueRefusal(.insufficient_data, .data, linear.end_offset, data_length) };
    }

    return .{
        .ok = .{
            .logical_mip_extent = mip.logical,
            .physical_mip_extent = mip.physical,
            .copy_extent = copy,
            .width_in_blocks = linear.width_in_blocks,
            .height_in_blocks = linear.height_in_blocks,
            .bytes_in_last_row = linear.bytes_in_last_row,
            .bytes_per_row = linear.bytes_per_row,
            .rows_per_image = linear.rows_per_image,
            .image_stride = linear.image_stride,
            .required_bytes_in_copy = linear.required_bytes_in_copy,
            .end_offset = linear.end_offset,
        },
    };
}

/// `GPUQueue.writeTexture`'s calculator: plan 01 exactly, with the aligned
/// policy's two buffer-copy rules permanently off.
pub fn calculateWrite(
    descriptor: TextureDescriptor,
    write: WriteLayout,
    data_length: u64,
) Result {
    return calculateCopy(descriptor, write, data_length, CopyPolicy.queue_write);
}

// ── texture→texture subresource copies (plan 06) ─────────────────────────────

/// A format's texel-block size, independent of aspect. `null` for a sentinel or
/// an unknown format byte — the copy refuses rather than inventing a footprint.
fn copyBlock(format: TextureFormat) ?struct { width: u32, height: u32 } {
    const byte = @intFromEnum(format);
    if (row_index_by_byte[byte]) |row_index| {
        const row = format_rows[row_index];
        return .{ .width = row.block_width, .height = row.block_height };
    }
    const compressed = compressedRow(byte) orelse return null;
    return .{ .width = compressed.block_width, .height = compressed.block_height };
}

/// `copyTextureToTexture`'s aspect rule: both endpoints carry `all`. For a
/// depth-stencil format that means *all aspects on both sides* (CRD
/// `index.bs:11192-11195`) — deliberately the opposite of plan 02's write path,
/// which requires one aspect. A colour format accepts only `all` too.
pub fn copyAspectRefusal(format: TextureFormat, aspect: Aspect) ?Refusal {
    const byte = @intFromEnum(format);
    if (row_index_by_byte[byte] == null and compressedRow(byte) == null) {
        return refusal(.invalid_format, .format);
    }
    if (aspect != .all) {
        return valueRefusal(.invalid_aspect, .aspect, @intFromEnum(aspect), @intFromEnum(Aspect.all));
    }
    return null;
}

/// WebGPU `copy-compatible`: equal, or equal except for the `-srgb` suffix.
/// Compressed rows alternate linear then sRGB in adjacent bytes (plan 07's
/// order), so a pair sharing `byte & 0xfe` is the same format modulo sRGB.
pub fn copyCompatible(source: TextureFormat, destination: TextureFormat) bool {
    if (source == destination) return true;
    const source_byte = @intFromEnum(source);
    const destination_byte = @intFromEnum(destination);
    if (compressedRow(source_byte) != null and compressedRow(destination_byte) != null) {
        return (source_byte | 1) == (destination_byte | 1);
    }
    return switch (source) {
        .rgba8unorm => destination == .rgba8unorm_srgb,
        .rgba8unorm_srgb => destination == .rgba8unorm,
        .bgra8unorm => destination == .bgra8unorm_srgb,
        .bgra8unorm_srgb => destination == .bgra8unorm,
        else => false,
    };
}

/// Which side of a texture→texture copy an endpoint is. The depth-stencil
/// texel-copy table publishes different source and destination verdicts.
const CopyEndpointRole = enum { source, destination };

/// `copyTextureToTexture`'s aspect-COPYABILITY rule, named before any range
/// arithmetic. Every aspect the format actually has must be copyable on this
/// side:
///   - `depth24plus` (and the depth aspect of `depth24plus-stencil8`) has no
///     copy footprint, so it is never a valid copy source (`invalid-format`);
///   - `depth32float` (and the depth aspect of `depth32float-stencil8`) is a
///     valid copy source but not a copy destination
///     (`aspect-not-writable`).
/// A depth-only aspect on a stencil-only texture, or the reverse, is refused by
/// `copyAspectRefusal`'s `invalid-aspect` before reaching a footprint lookup —
/// never as a downstream extent/range error from a zero-size aspect.
fn copyFormatRefusal(format: TextureFormat, role: CopyEndpointRole) ?Refusal {
    const byte = @intFromEnum(format);
    const row_index = row_index_by_byte[byte] orelse {
        if (compressedRow(byte) != null) return null;
        return refusal(.invalid_format, .format);
    };
    const row = format_rows[row_index];

    if (row.has_depth) {
        switch (role) {
            .source => if (row.depth_bytes_per_block == 0) return refusal(.invalid_format, .format),
            .destination => if (!row.depth_write_destination) return refusal(.aspect_not_writable, .aspect),
        }
    }
    if (row.has_stencil) {
        switch (role) {
            .source => if (row.stencil_bytes_per_block == 0) return refusal(.invalid_format, .format),
            .destination => if (!row.stencil_write_destination) return refusal(.aspect_not_writable, .aspect),
        }
    }
    if (!row.has_depth and !row.has_stencil and row.color_bytes_per_block == 0) {
        return refusal(.invalid_format, .format);
    }
    return null;
}

pub const EndpointResult = union(enum) {
    ok: SubresourceEndpointLayout,
    refuse: Refusal,
};

/// Resolve one `GPUTexelCopyTextureInfo` against its concrete descriptor:
/// aspect, mip range, physical mip extent, origin, explicit-or-remaining copy
/// extent and block alignment. `size = null` is the source's omission rule (the
/// remaining physical extent at the origin) and the same `resolveCopyExtent`
/// plan 01's write/buffer-copy paths use.
pub fn calculateEndpoint(
    descriptor: TextureDescriptor,
    endpoint: SubresourceEndpoint,
    size: ?Extent,
) EndpointResult {
    if (validateDescriptor(descriptor)) |refusal_value| return .{ .refuse = refusal_value };

    const block = copyBlock(descriptor.format) orelse return .{ .refuse = refusal(.invalid_format, .format) };
    if (copyAspectRefusal(descriptor.format, endpoint.aspect)) |refusal_value| {
        return .{ .refuse = refusal_value };
    }
    if (endpoint.mip_level >= descriptor.mip_level_count) {
        return .{ .refuse = valueRefusal(.mip_out_of_range, .mip_level, endpoint.mip_level, descriptor.mip_level_count) };
    }

    const mip = switch (mipExtent(descriptor.size, descriptor.dimension, endpoint.mip_level, block.width, block.height)) {
        .ok => |resolved| resolved,
        .refuse => |refusal_value| return .{ .refuse = refusal_value },
    };
    if (originRefusal(endpoint.origin, mip.physical)) |refusal_value| {
        return .{ .refuse = refusal_value };
    }
    const copy = switch (resolveCopyExtent(mip.physical, .{ .origin = endpoint.origin, .size = size })) {
        .ok => |resolved| resolved,
        .refuse => |refusal_value| return .{ .refuse = refusal_value },
    };
    if (blockAlignmentRefusal(endpoint.origin, copy, block.width, block.height)) |refusal_value| {
        return .{ .refuse = refusal_value };
    }
    return .{ .ok = .{ .mip = mip, .copy_extent = copy } };
}

pub const SubresourceCopyResult = union(enum) {
    ok: SubresourceCopyLayout,
    refuse: Refusal,
};

/// Plan 06's static `copyTextureToTexture` calculator. Stages, first refusal
/// stable: descriptor, usage (COPY_SRC / COPY_DST), sample-count equality,
/// copy-compatible formats, the source endpoint (aspect/mip/origin/extent/
/// block), the destination endpoint against the RESOLVED source extent, then
/// the same-texture disjoint-subresource rule (`index.bs:11196`). The default
/// size is plan 01's remaining physical source extent — one calculation, no
/// second formula.
pub fn calculateTextureCopy(
    source_descriptor: TextureDescriptor,
    destination_descriptor: TextureDescriptor,
    copy: SubresourceCopy,
) SubresourceCopyResult {
    if (validateDescriptor(source_descriptor)) |refusal_value| return .{ .refuse = refusal_value };
    if (validateDescriptor(destination_descriptor)) |refusal_value| return .{ .refuse = refusal_value };

    if (!source_descriptor.usage.copy_src) {
        return .{ .refuse = valueRefusal(.missing_copy_src, .usage, source_descriptor.usage.toU8(), TextureUsage.WEBGPU_COPY_SRC) };
    }
    if (!destination_descriptor.usage.copy_dst) {
        return .{ .refuse = valueRefusal(.missing_copy_dst, .usage, destination_descriptor.usage.toU8(), TextureUsage.WEBGPU_COPY_DST) };
    }
    if (source_descriptor.sample_count != destination_descriptor.sample_count) {
        return .{ .refuse = valueRefusal(
            .sample_count_mismatch,
            .sample_count,
            source_descriptor.sample_count,
            destination_descriptor.sample_count,
        ) };
    }
    if (!copyCompatible(source_descriptor.format, destination_descriptor.format)) {
        return .{ .refuse = valueRefusal(
            .invalid_format,
            .format,
            @intFromEnum(source_descriptor.format),
            @intFromEnum(destination_descriptor.format),
        ) };
    }
    // Each endpoint's format must be copyable on its side BEFORE any extent is
    // resolved: an absent aspect footprint would otherwise read as a zero-size
    // range and surface as a downstream range error.
    if (copyFormatRefusal(source_descriptor.format, .source)) |refusal_value| return .{ .refuse = refusal_value };
    if (copyFormatRefusal(destination_descriptor.format, .destination)) |refusal_value| return .{ .refuse = refusal_value };

    const source = switch (calculateEndpoint(source_descriptor, copy.source, copy.size)) {
        .ok => |resolved| resolved,
        .refuse => |refusal_value| return .{ .refuse = refusal_value },
    };
    const destination = switch (calculateEndpoint(destination_descriptor, copy.destination, source.copy_extent)) {
        .ok => |resolved| resolved,
        .refuse => |refusal_value| return .{ .refuse = refusal_value },
    };

    // For a depth-stencil or multisampled endpoint the copy must cover the
    // ENTIRE physical subresource (CRD `sections/copies.bs:263-266`). Extent
    // equality also forces the origin to zero through the range checks above;
    // the refusal is named per axis.
    if (formatHasDepthOrStencil(source_descriptor.format) or source_descriptor.sample_count > 1) {
        if (fullSubresourceRefusal(copy.source.origin, source.copy_extent, source.mip.physical, .partial_subresource_copy)) |refusal_value| {
            return .{ .refuse = refusal_value };
        }
    }
    if (formatHasDepthOrStencil(destination_descriptor.format) or destination_descriptor.sample_count > 1) {
        if (fullSubresourceRefusal(copy.destination.origin, destination.copy_extent, destination.mip.physical, .partial_subresource_copy)) |refusal_value| {
            return .{ .refuse = refusal_value };
        }
    }

    // A copy within one texture may not share a subresource (mip + aspect +
    // layer/slice), even when the texel ranges inside it would not overlap.
    // Both endpoints carry `all` aspects, so only the mip and z ranges can
    // differ.
    if (copy.source.texture_id == copy.destination.texture_id and
        copy.source.mip_level == copy.destination.mip_level and
        source.copy_extent.depth_or_array_layers > 0)
    {
        const src_start: u64 = copy.source.origin.z;
        const dst_start: u64 = copy.destination.origin.z;
        const src_end = src_start + source.copy_extent.depth_or_array_layers;
        const dst_end = dst_start + source.copy_extent.depth_or_array_layers;
        if (src_start < dst_end and dst_start < src_end) {
            return .{ .refuse = valueRefusal(
                .overlapping_subresources,
                .mip_level,
                copy.source.mip_level,
                copy.destination.mip_level,
            ) };
        }
    }

    return .{ .ok = .{
        .source = source,
        .destination = destination,
        .copy_extent = source.copy_extent,
    } };
}
