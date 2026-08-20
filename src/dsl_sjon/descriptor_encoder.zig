//! Binary Descriptor Encoder
//!
//! Canonical binary descriptor encoder for the SJON host. (Originally vendored
//! from the legacy `dsl` emitter; that tree was deleted at the SJON cutover, so
//! this is now the single source. See CONTRIBUTING §17.) Depends only on the
//! `types` module (no Ast/Analyzer coupling).
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
//!
//! ## Which descriptors are binary, and which are JSON
//!
//! PNGine emits some descriptors as these TLV bytes and others as hand-built
//! JSON strings that gpu.js `JSON.parse`s. That is a deliberate split, not
//! drift, and **the deciding property is the shape of the WebGPU dictionary**:
//!
//! - **Flat** — a fixed, shallow set of scalars and enums → **binary TLV**.
//!   Texture, sampler, texture view, bind-group entries (fixed-width rows),
//!   compute pipeline (shader id + entry name + layout id), render bundle.
//!   `[tag][field][value]` encodes these exactly, and they are the numerous
//!   ones, so compactness pays.
//!
//! - **Nested and open-ended** — arrays of dictionaries of optional
//!   dictionaries → **JSON**. Render pipeline (`vertex.buffers[].attributes[]`,
//!   `fragment.targets[].blend.{color,alpha}`, `depthStencil`, `multisample`),
//!   bind-group **layout** (`entries[].{buffer,texture,sampler,storageTexture}`),
//!   pipeline layout. A flat field table cannot express these without a bespoke
//!   nested sub-schema per descriptor — and gpu.js hands most of the parsed
//!   object to WebGPU nearly verbatim, so the JSON *is* the descriptor.
//!
//! This is why a bind group is binary while its LAYOUT is JSON, which reads as
//! an inconsistency until you notice the entries differ in shape: a bind-group
//! entry is a fixed `[binding][type][id](+offset,size)` row; a layout entry is a
//! dictionary with four mutually-exclusive optional sub-dictionaries.
//!
//! **Both encodings are frozen.** `docs/abi.md` pins the choice per opcode
//! (§6.1–6.5) as part of the v1 executor↔JS ABI, so switching a descriptor from
//! one to the other is an ABI break, not a refactor. Changes must be additive:
//! a new TLV field ID, or a new JSON key.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

// Import shared descriptor types from types module. (No Ast/Node coupling: this
// module is plain-args only, so it imports cleanly into both `dsl` and
// `dsl_sjon` — see CONTRIBUTING.md §17.)
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
    pub const TextureViewField = types.TextureViewField;
    pub const SamplerField = types.SamplerField;
    pub const BindGroupField = types.BindGroupField;
    pub const BindGroupEntryField = types.BindGroupEntryField;
    pub const RenderPassField = types.RenderPassField;
    pub const ColorAttachmentField = types.ColorAttachmentField;
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

    buffer: std.ArrayList(u8),

    pub fn init() Self {
        return .{ .buffer = .empty };
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

    /// How a texture's width/height are resolved at runtime.
    pub const TextureSize = union(enum) {
        /// Explicit texel dimensions authored in the source.
        explicit: struct { width: u32, height: u32 },
        /// Track the canvas size at runtime (no width/height fields emitted).
        canvas,
        /// Resolve from a decoded ImageBitmap by id.
        image_bitmap: u16,
    };

    /// Full texture descriptor inputs. `format` and `usage` are always emitted;
    /// every extended field (the extent's depth, dimension, mip-level-count,
    /// sample-count) is emitted ONLY when it differs from the WebGPU default, so a
    /// texture that authors none of the new keys is byte-for-byte identical to the
    /// historical encoding — the golden traces depend on this. Decoders walk by
    /// field id (append-only), so emission order is free.
    pub const TextureOptions = struct {
        size: TextureSize,
        format: TextureFormat,
        usage: TextureUsage,
        depth_or_array_layers: u32 = 1,
        dimension: u8 = 1, // 0=1d, 1=2d (default), 2=3d
        mip_level_count: u32 = 1,
        sample_count: u32 = 1,
    };

    /// Encode a texture descriptor from the full option set.
    /// Memory: Caller owns returned slice.
    pub fn encodeTextureOpts(allocator: Allocator, opts: TextureOptions) ![]u8 {
        // Pre-conditions: encoded ranges are sane (schema already bounds these).
        assert(opts.dimension <= 2);
        assert(opts.depth_or_array_layers >= 1);
        assert(opts.mip_level_count >= 1);

        var encoder = Self.init();
        errdefer encoder.deinit(allocator);

        const field_count_pos = try encoder.beginDescriptor(allocator, .texture);
        var field_count: u8 = 0;

        switch (opts.size) {
            .explicit => |wh| {
                assert(wh.width > 0);
                assert(wh.height > 0);
                try encoder.writeU32Field(allocator, @intFromEnum(TextureField.width), wh.width);
                field_count += 1;
                try encoder.writeU32Field(allocator, @intFromEnum(TextureField.height), wh.height);
                field_count += 1;
            },
            .canvas => {}, // no width/height — runtime uses canvas size
            .image_bitmap => |image_bitmap_id| {
                try encoder.writeByte(allocator, @intFromEnum(TextureField.size_from_image_bitmap));
                try encoder.writeByte(allocator, @intFromEnum(ValueType.u16_val));
                try encoder.writeU16(allocator, image_bitmap_id);
                field_count += 1;
            },
        }

        if (opts.depth_or_array_layers > 1) {
            try encoder.writeU32Field(allocator, @intFromEnum(TextureField.depth), opts.depth_or_array_layers);
            field_count += 1;
        }

        if (opts.dimension != 1) { // 0=1d, 1=2d (default), 2=3d
            try encoder.writeEnumField(allocator, @intFromEnum(TextureField.dimension), opts.dimension);
            field_count += 1;
        }

        if (opts.mip_level_count > 1) {
            try encoder.writeU32Field(allocator, @intFromEnum(TextureField.mip_level_count), opts.mip_level_count);
            field_count += 1;
        }

        try encoder.writeEnumField(allocator, @intFromEnum(TextureField.format), @intFromEnum(opts.format));
        field_count += 1;

        try encoder.writeByte(allocator, @intFromEnum(TextureField.usage));
        try encoder.writeByte(allocator, @intFromEnum(ValueType.enum_val));
        try encoder.writeByte(allocator, @bitCast(opts.usage));
        field_count += 1;

        if (opts.sample_count > 1) {
            try encoder.writeU32Field(allocator, @intFromEnum(TextureField.sample_count), opts.sample_count);
            field_count += 1;
        }

        encoder.endDescriptor(field_count_pos, field_count);

        const result = try encoder.toOwnedSlice(allocator);

        // Post-condition: output starts with correct type tag.
        assert(result[0] == @intFromEnum(DescriptorType.texture));

        return result;
    }

    /// Encode a texture descriptor with explicit texel dimensions.
    /// Thin byte-identical wrapper over `encodeTextureOpts`.
    /// Memory: Caller owns returned slice.
    pub fn encodeTexture(
        allocator: Allocator,
        width: u32,
        height: u32,
        depth: u32,
        dimension: u8,
        format: TextureFormat,
        usage: TextureUsage,
        sample_count: u32,
    ) ![]u8 {
        return encodeTextureOpts(allocator, .{
            .size = .{ .explicit = .{ .width = width, .height = height } },
            .format = format,
            .usage = usage,
            .depth_or_array_layers = depth,
            .dimension = dimension,
            .sample_count = sample_count,
        });
    }

    /// Encode a canvas-sized texture (runtime tracks the canvas size).
    /// Thin byte-identical wrapper over `encodeTextureOpts`.
    /// Memory: Caller owns returned slice.
    pub fn encodeTextureCanvasSize(
        allocator: Allocator,
        format: TextureFormat,
        usage: TextureUsage,
        sample_count: u32,
    ) ![]u8 {
        return encodeTextureOpts(allocator, .{
            .size = .canvas,
            .format = format,
            .usage = usage,
            .sample_count = sample_count,
        });
    }

    /// Encode a texture sized from a decoded ImageBitmap.
    /// Thin byte-identical wrapper over `encodeTextureOpts`.
    /// Memory: Caller owns returned slice.
    pub fn encodeTextureImageBitmapSize(
        allocator: Allocator,
        image_bitmap_id: u16,
        format: TextureFormat,
        usage: TextureUsage,
        sample_count: u32,
    ) ![]u8 {
        return encodeTextureOpts(allocator, .{
            .size = .{ .image_bitmap = image_bitmap_id },
            .format = format,
            .usage = usage,
            .sample_count = sample_count,
        });
    }

    /// GPUTextureViewDescriptor inputs. Every field is optional — an omitted field
    /// means "WebGPU's own default" and is not emitted, so a view that authors only
    /// a dimension carries a two-field blob. Decoders walk by field id (append-only
    /// wire contract), so emission order is free. `?`-typed base indices default to
    /// 0 in WebGPU and are emitted only when non-zero; counts are emitted only when
    /// present (absent = "all remaining", the WebGPU default).
    pub const TextureViewOptions = struct {
        /// 0=1d 1=2d 2=2d-array 3=cube 4=cube-array 5=3d; null = inferred from texture.
        dimension: ?u8 = null,
        /// 0=all 1=stencil-only 2=depth-only; null = all (WebGPU default).
        aspect: ?u8 = null,
        base_mip_level: u32 = 0,
        mip_level_count: ?u32 = null,
        base_array_layer: u32 = 0,
        array_layer_count: ?u32 = null,
        /// TextureFormat enum byte; null = the source texture's own format.
        format: ?u8 = null,
    };

    /// Encode a GPUTextureViewDescriptor. Only authored (non-default) fields are
    /// emitted; an all-default view yields a header-only blob equivalent to a
    /// default `createView()`.
    /// Memory: Caller owns returned slice.
    pub fn encodeTextureView(allocator: Allocator, opts: TextureViewOptions) ![]u8 {
        // Pre-conditions: encoded enum ranges are sane (schema already bounds these).
        assert(opts.dimension == null or opts.dimension.? <= 5);
        assert(opts.aspect == null or opts.aspect.? <= 2);

        var encoder = Self.init();
        errdefer encoder.deinit(allocator);

        const field_count_pos = try encoder.beginDescriptor(allocator, .texture_view);
        var field_count: u8 = 0;

        if (opts.format) |f| {
            try encoder.writeEnumField(allocator, @intFromEnum(TextureViewField.format), f);
            field_count += 1;
        }
        if (opts.dimension) |d| {
            try encoder.writeEnumField(allocator, @intFromEnum(TextureViewField.dimension), d);
            field_count += 1;
        }
        if (opts.aspect) |a| {
            try encoder.writeEnumField(allocator, @intFromEnum(TextureViewField.aspect), a);
            field_count += 1;
        }
        if (opts.base_mip_level > 0) {
            try encoder.writeU32Field(allocator, @intFromEnum(TextureViewField.base_mip_level), opts.base_mip_level);
            field_count += 1;
        }
        if (opts.mip_level_count) |n| {
            try encoder.writeU32Field(allocator, @intFromEnum(TextureViewField.mip_level_count), n);
            field_count += 1;
        }
        if (opts.base_array_layer > 0) {
            try encoder.writeU32Field(allocator, @intFromEnum(TextureViewField.base_array_layer), opts.base_array_layer);
            field_count += 1;
        }
        if (opts.array_layer_count) |n| {
            try encoder.writeU32Field(allocator, @intFromEnum(TextureViewField.array_layer_count), n);
            field_count += 1;
        }

        encoder.endDescriptor(field_count_pos, field_count);

        const result = try encoder.toOwnedSlice(allocator);

        // Post-condition: output starts with correct type tag.
        assert(result[0] == @intFromEnum(DescriptorType.texture_view));

        return result;
    }

    /// Full sampler descriptor inputs. The four required fields (mag/min filter,
    /// address U/V) are always emitted; every `?`-typed field is emitted ONLY when
    /// non-null, so a sampler that authors none of the extended keys is byte-for-byte
    /// identical to the historical 4-field (+compare) encoding — the golden traces
    /// depend on this. New fields append after the base set (decoders walk by field
    /// id, so order is free); the append-only field-id table is the wire contract.
    pub const SamplerOptions = struct {
        mag_filter: FilterMode = .nearest,
        min_filter: FilterMode = .nearest,
        address_mode_u: AddressMode = .clamp_to_edge,
        address_mode_v: AddressMode = .clamp_to_edge,
        address_mode_w: ?AddressMode = null,
        mipmap_filter: ?FilterMode = null,
        lod_min_clamp: ?f32 = null,
        lod_max_clamp: ?f32 = null,
        max_anisotropy: ?u16 = null,
        /// 0=never, 1=less, 2=equal, 3=less-equal, 4=greater, 5=not-equal, 6=greater-equal, 7=always
        compare: ?u8 = null,
    };

    /// Encode a sampler descriptor with only the base filter/address fields (the
    /// legacy 4-field shape). Retained for callers/tests that predate SamplerOptions.
    ///
    /// Memory: Caller owns returned slice.
    pub fn encodeSampler(
        allocator: Allocator,
        mag_filter: FilterMode,
        min_filter: FilterMode,
        address_mode: AddressMode,
    ) ![]u8 {
        return encodeSamplerOpts(allocator, .{
            .mag_filter = mag_filter,
            .min_filter = min_filter,
            .address_mode_u = address_mode,
            .address_mode_v = address_mode,
        });
    }

    /// Encode sampler descriptor with optional compare function (legacy 4-field +
    /// compare shape). Thin wrapper over `encodeSamplerOpts`.
    pub fn encodeSamplerWithCompare(
        allocator: Allocator,
        mag_filter: FilterMode,
        min_filter: FilterMode,
        address_mode: AddressMode,
        compare: ?u8,
    ) ![]u8 {
        return encodeSamplerOpts(allocator, .{
            .mag_filter = mag_filter,
            .min_filter = min_filter,
            .address_mode_u = address_mode,
            .address_mode_v = address_mode,
            .compare = compare,
        });
    }

    /// Encode a full sampler descriptor from `SamplerOptions`. See that struct's
    /// doc for the byte-identity invariant.
    ///
    /// Memory: Caller owns returned slice.
    pub fn encodeSamplerOpts(allocator: Allocator, opts: SamplerOptions) ![]u8 {
        // Pre-condition: filter enum values are valid (enforced by type system).
        assert(@intFromEnum(opts.mag_filter) <= 1);
        assert(@intFromEnum(opts.min_filter) <= 1);

        var encoder = Self.init();
        errdefer encoder.deinit(allocator);

        const field_count_pos = try encoder.beginDescriptor(allocator, .sampler);
        var field_count: u8 = 0;

        try encoder.writeEnumField(allocator, @intFromEnum(SamplerField.mag_filter), @intFromEnum(opts.mag_filter));
        field_count += 1;

        try encoder.writeEnumField(allocator, @intFromEnum(SamplerField.min_filter), @intFromEnum(opts.min_filter));
        field_count += 1;

        try encoder.writeEnumField(allocator, @intFromEnum(SamplerField.address_mode_u), @intFromEnum(opts.address_mode_u));
        field_count += 1;

        try encoder.writeEnumField(allocator, @intFromEnum(SamplerField.address_mode_v), @intFromEnum(opts.address_mode_v));
        field_count += 1;

        if (opts.address_mode_w) |w| {
            try encoder.writeEnumField(allocator, @intFromEnum(SamplerField.address_mode_w), @intFromEnum(w));
            field_count += 1;
        }
        if (opts.mipmap_filter) |mf| {
            try encoder.writeEnumField(allocator, @intFromEnum(SamplerField.mipmap_filter), @intFromEnum(mf));
            field_count += 1;
        }
        if (opts.lod_min_clamp) |lod| {
            try encoder.writeF32Field(allocator, @intFromEnum(SamplerField.lod_min_clamp), lod);
            field_count += 1;
        }
        if (opts.lod_max_clamp) |lod| {
            try encoder.writeF32Field(allocator, @intFromEnum(SamplerField.lod_max_clamp), lod);
            field_count += 1;
        }
        if (opts.max_anisotropy) |aniso| {
            try encoder.writeU16Field(allocator, @intFromEnum(SamplerField.max_anisotropy), aniso);
            field_count += 1;
        }
        if (opts.compare) |cmp| {
            try encoder.writeEnumField(allocator, @intFromEnum(SamplerField.compare), cmp);
            field_count += 1;
        }

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

// Property: MSAA textures include sample_count field (5 fields vs 4).

// Round-trip: the shared TlvReader decodes exactly what encodeTexture wrote,
// with no magic hex (the native backend consumes the same reader).

// Property: canvas-sized textures omit width/height fields (2 fields vs 4).
// Regression test: size=[canvas.width canvas.height] should NOT encode dimensions.

// Byte-identity: the explicit-size wrapper is a pure pass-through to
// encodeTextureOpts — a texture that authors none of the new keys (depth,
// dimension, mip) stays byte-for-byte identical, which is what let §5.3 land
// without regenerating existing texture goldens.

// The full extended field set (3d + depth/array layers + mip levels + MSAA)
// encodes exactly once each, decodable through the shared TlvReader.

// Property: sampler encoding produces correct type tag and field count.

// Property: a bare SamplerOptions is byte-identical to the legacy encodeSampler —
// the golden-trace byte-identity guarantee that let §5.2 land without regenerating
// the 74 existing sampler traces.

// Property: every extended sampler field encodes with its append-only field id and
// value type, walked back through the shared TlvReader.

// Property: bind group entries are encoded with correct type tag.

// Property: render pass encoding produces valid descriptor.

// Property: TextureFormat.fromString returns correct enum values.
