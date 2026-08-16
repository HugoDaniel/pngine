//! PNGB Binary Format (v0)
//!
//! Serializes and deserializes the complete PNGB binary format.
//! v0 is the initial release with embedded executor support and plugin architecture.
//!
//! File Structure (40 bytes header):
//! ┌─────────────────────────────────────┐
//! │ Header (40 bytes)                   │
//! │   magic: "PNGB" (4 bytes)           │
//! │   version: u16 (0)                  │
//! │   flags: u16                        │
//! │     bit 0: has_embedded_executor    │
//! │     bit 1: has_animation_table      │
//! │     bit 2: has_device_limits        │
//! │     bit 3: canvas_alpha_opaque      │
//! │   plugins: u8 (PluginSet bitfield)  │
//! │   reserved: [3]u8 = limits offset   │
//! │     (u24 LE when bit 2 set, else 0) │
//! │   executor_offset: u32 (0 if none)  │
//! │   executor_length: u32              │
//! │   string_table_offset: u32          │
//! │   data_section_offset: u32          │
//! │   wgsl_table_offset: u32            │
//! │   uniform_table_offset: u32         │
//! │   animation_table_offset: u32       │
//! ├─────────────────────────────────────┤
//! │ Executor Section (if embedded)      │
//! │   (plugin-selected WASM module)     │
//! ├─────────────────────────────────────┤
//! │ Bytecode Section                    │
//! │   (immediately after executor)      │
//! ├─────────────────────────────────────┤
//! │ String Table                        │
//! ├─────────────────────────────────────┤
//! │ Data Section                        │
//! ├─────────────────────────────────────┤
//! │ WGSL Table                          │
//! │   (wgsl_id → data_id + deps)        │
//! ├─────────────────────────────────────┤
//! │ Uniform Table                       │
//! │   (binding → buffer + fields)       │
//! ├─────────────────────────────────────┤
//! │ Animation Table                     │
//! │   (timeline, scenes, durations)     │
//! ├─────────────────────────────────────┤
//! │ Device Limits Table (if bit 2)      │
//! │   (frontend-only; see limits_table) │
//! └─────────────────────────────────────┘
//!
//! Invariants:
//! - Magic must be "PNGB"
//! - Version must be 0
//! - Offsets point to valid positions within the file
//! - If has_embedded_executor, executor_offset and executor_length are valid

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const StringTable = @import("string_table.zig").StringTable;
const DataSection = @import("data_section.zig").DataSection;
const Emitter = @import("emitter.zig").Emitter;
const uniform_table_mod = @import("uniform_table.zig");
const UniformTable = uniform_table_mod.UniformTable;
const animation_table_mod = @import("animation_table.zig");
const AnimationTable = animation_table_mod.AnimationTable;
const limits_table_mod = @import("limits_table.zig");
const LimitsTable = limits_table_mod.LimitsTable;

/// Shared empty limits table for the common no-limits serialize path (default
/// for `SerializeOptions.limits`) — keeps limit-less output byte-identical.
const empty_limits_table: LimitsTable = .empty;

/// Magic bytes identifying PNGB format.
pub const MAGIC: *const [4]u8 = "PNGB";

/// Current format version (v0 - initial release with embedded executor).
pub const VERSION: u16 = 0;

/// Header size in bytes.
pub const HEADER_SIZE: usize = 40;

/// Maximum WGSL modules per file.
pub const MAX_WGSL_MODULES: u16 = 1024;

/// Maximum dependencies per WGSL module.
pub const MAX_WGSL_DEPS: u16 = 64;

// ============================================================================
// Plugin Architecture
// ============================================================================

// Import from types/ for zero-dependency sharing with Analyzer
const plugins = @import("types").plugins;

/// Plugin set bitfield - determines which executor features are included.
/// Compile-time selection based on DSL analysis.
///
/// See: docs/plans/archive/embedded-executor-plan.md for architecture details.
pub const PluginSet = plugins.PluginSet;

/// Individual plugin types.
pub const Plugin = plugins.Plugin;

// ============================================================================
// Header
// ============================================================================

/// Header flags.
pub const Flags = packed struct(u16) {
    /// Payload contains embedded WASM executor.
    has_embedded_executor: bool = false,
    /// Payload contains animation table.
    has_animation_table: bool = false,
    /// Payload carries an authored device-limits table (appended AFTER the
    /// animation table; its byte offset is stored little-endian in the header's
    /// 3 `reserved` bytes). Cleared → no table, `reserved` is {0,0,0}, and the
    /// payload is byte-identical to pre-§5.3b output. (Arc-3 §5.3b)
    has_device_limits: bool = false,
    /// The author requested an OPAQUE canvas (`(canvas :alpha-mode opaque)`).
    /// Clear → the historical premultiplied configure, byte-identical output
    /// for form-absent payloads. A 1-bit channel is enough because
    /// GPUCanvasAlphaMode has exactly two values and the absent-form default
    /// is premultiplied; anything list-shaped (viewFormats) will need a real
    /// table mechanism instead — the header's 3 reserved bytes are already
    /// consumed by the device-limits offset. (docs/plans/spec/04)
    canvas_alpha_opaque: bool = false,
    /// Reserved for future use.
    reserved: u12 = 0,
};

/// PNGB file header (v0, 40 bytes).
///
/// Layout optimized for 4-byte alignment of all u32 fields.
///
/// FROZEN FOREVER — never repack. Every executor ever shipped inside a PNG
/// reads these fields at FIXED byte offsets (see `src/wasm_entry.zig`, which
/// reads header[4..6], [12..16], [20..24], [24..28], [28..32], [36..40]
/// directly), and those binaries must keep working. Reserved bytes are spare
/// capacity to grow INTO in place, not slots to reorder around. (Plan C10 =
/// NEVER.)
pub const Header = extern struct {
    /// Magic bytes "PNGB".
    magic: [4]u8,
    /// Format version (0).
    version: u16,
    /// Feature flags.
    flags: Flags,
    /// Plugin set bitfield.
    plugins: PluginSet,
    /// Reserved for alignment and future use. Grow into these in place; never
    /// move a following field to make room (see the header's FROZEN note).
    reserved: [3]u8,
    /// Offset to embedded executor WASM (0 if not embedded).
    executor_offset: u32,
    /// Length of embedded executor WASM (0 if not embedded).
    executor_length: u32,
    /// Offset to string table section.
    string_table_offset: u32,
    /// Offset to data section.
    data_section_offset: u32,
    /// Offset to WGSL module table.
    wgsl_table_offset: u32,
    /// Offset to uniform binding table.
    uniform_table_offset: u32,
    /// Offset to animation table.
    animation_table_offset: u32,

    comptime {
        // Verify header is exactly 40 bytes
        assert(@sizeOf(Header) == HEADER_SIZE);
    }

    /// Validate header.
    pub fn validate(self: *const Header) !void {
        if (!std.mem.eql(u8, &self.magic, MAGIC)) {
            return error.InvalidMagic;
        }
        // Only accept v0 format
        if (self.version != VERSION) {
            return error.UnsupportedVersion;
        }
    }

    /// Check if this payload has an embedded executor.
    pub fn hasEmbeddedExecutor(self: *const Header) bool {
        return self.flags.has_embedded_executor and self.executor_length > 0;
    }

    /// Get bytecode start offset (after header and optional executor).
    pub fn bytecodeOffset(self: *const Header) u32 {
        if (self.hasEmbeddedExecutor()) {
            return self.executor_offset + self.executor_length;
        }
        return HEADER_SIZE;
    }

    /// True if this payload carries a device-limits table (Arc-3 §5.3b).
    pub fn hasDeviceLimits(self: *const Header) bool {
        return self.flags.has_device_limits;
    }

    /// Byte offset of the device-limits table, decoded little-endian from the 3
    /// `reserved` bytes. Meaningful only when `hasDeviceLimits()`. The u24 width
    /// caps the payload at 16 MiB — matching the PNG chunk-walk ceiling. (§5.3b)
    pub fn limitsTableOffset(self: *const Header) u32 {
        return std.mem.readInt(u24, &self.reserved, .little);
    }
};

// ============================================================================
// WGSL Table: Maps wgsl_id to data_id + dependencies
// ============================================================================

/// Entry in the WGSL table.
/// Each entry maps a WGSL module ID to its code (data_id) and direct dependencies.
pub const WgslEntry = struct {
    data_id: u16,
    deps: []const u16,
};

/// WGSL module table for runtime import resolution.
///
/// Format (serialized):
/// ```
/// count: varint
/// entries: [count] {
///     data_id: varint
///     dep_count: varint
///     deps: [dep_count]varint
/// }
/// ```
pub const WgslTable = struct {
    entries: std.ArrayList(WgslEntry),

    pub const empty: WgslTable = .{ .entries = .empty };

    pub fn deinit(self: *WgslTable, allocator: Allocator) void {
        for (self.entries.items) |entry| {
            if (entry.deps.len > 0) {
                allocator.free(entry.deps);
            }
        }
        self.entries.deinit(allocator);
        self.* = undefined;
    }

    /// Add a WGSL module entry.
    /// Returns the assigned wgsl_id.
    /// Pre-condition: deps slice is caller-owned, will be duplicated.
    pub fn add(self: *WgslTable, allocator: Allocator, data_id: u16, deps: []const u16) !u16 {
        // Pre-conditions
        assert(self.entries.items.len < MAX_WGSL_MODULES);
        assert(deps.len <= MAX_WGSL_DEPS);

        const id: u16 = @intCast(self.entries.items.len);
        const deps_copy = if (deps.len > 0)
            try allocator.dupe(u16, deps)
        else
            &[_]u16{};
        errdefer if (deps.len > 0) allocator.free(deps_copy);

        try self.entries.append(allocator, .{ .data_id = data_id, .deps = deps_copy });

        // Post-condition: entry was added
        assert(self.entries.items.len == id + 1);

        return id;
    }

    /// Get entry by wgsl_id.
    pub fn get(self: *const WgslTable, wgsl_id: u16) ?WgslEntry {
        if (wgsl_id >= self.entries.items.len) return null;
        return self.entries.items[wgsl_id];
    }

    /// Number of entries.
    pub fn count(self: *const WgslTable) u16 {
        return @intCast(self.entries.items.len);
    }

    /// Serialize WGSL table to bytes.
    /// Format: count(varint) + entries[count]{ data_id(varint) + dep_count(varint) + deps[dep_count](varint) }
    pub fn serialize(self: *const WgslTable, allocator: Allocator) ![]u8 {
        const opcodes = @import("opcodes.zig");

        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        var buf: [4]u8 = undefined;

        // Write count
        const count_len = opcodes.encodeVarint(@intCast(self.entries.items.len), &buf);
        try result.appendSlice(allocator, buf[0..count_len]);

        // Write entries (bounded loop)
        for (self.entries.items, 0..) |entry, i| {
            if (i >= MAX_WGSL_MODULES) break;

            // data_id
            const data_len = opcodes.encodeVarint(entry.data_id, &buf);
            try result.appendSlice(allocator, buf[0..data_len]);

            // dep_count
            const dep_count_len = opcodes.encodeVarint(@intCast(entry.deps.len), &buf);
            try result.appendSlice(allocator, buf[0..dep_count_len]);

            // deps (bounded loop)
            for (entry.deps, 0..) |dep, j| {
                if (j >= MAX_WGSL_DEPS) break;
                const dep_len = opcodes.encodeVarint(dep, &buf);
                try result.appendSlice(allocator, buf[0..dep_len]);
            }
        }

        return result.toOwnedSlice(allocator);
    }
};

/// Deserialize WGSL table from bytes.
pub fn deserializeWgslTable(allocator: Allocator, data: []const u8) !WgslTable {
    const opcodes = @import("opcodes.zig");

    var table = WgslTable{ .entries = .empty };
    errdefer table.deinit(allocator);

    if (data.len == 0) return table;

    var pos: usize = 0;

    // Read count
    const count_result = opcodes.decode_varint(data[pos..]);
    pos += count_result.len;
    const entry_count: u16 = @intCast(count_result.value);

    // Pre-allocate entries
    try table.entries.ensureTotalCapacity(allocator, entry_count);

    // Read entries (bounded loop)
    for (0..@min(entry_count, MAX_WGSL_MODULES)) |_| {
        // Check bounds before each varint read
        if (pos >= data.len) break;

        // data_id
        const data_id_result = opcodes.decode_varint(data[pos..]);
        pos += data_id_result.len;
        const data_id: u16 = @intCast(data_id_result.value);

        // dep_count - check bounds first
        if (pos >= data.len) {
            // Truncated: add entry with no deps
            table.entries.appendAssumeCapacity(.{ .data_id = data_id, .deps = &[_]u16{} });
            break;
        }
        const dep_count_result = opcodes.decode_varint(data[pos..]);
        pos += dep_count_result.len;
        const dep_count: u16 = @intCast(dep_count_result.value);

        // deps
        var deps: []u16 = &[_]u16{};
        if (dep_count > 0 and dep_count <= MAX_WGSL_DEPS) {
            deps = try allocator.alloc(u16, dep_count);
            errdefer allocator.free(deps);
            for (0..dep_count) |i| {
                if (pos >= data.len) {
                    // Truncated deps - free and use empty
                    allocator.free(deps);
                    deps = &[_]u16{};
                    break;
                }
                const dep_result = opcodes.decode_varint(data[pos..]);
                pos += dep_result.len;
                deps[i] = @intCast(dep_result.value);
            }
        }

        table.entries.appendAssumeCapacity(.{ .data_id = data_id, .deps = deps });
    }

    return table;
}

/// Complete PNGB module for execution.
pub const Module = struct {
    header: Header,
    /// Embedded WASM executor (empty if not embedded).
    executor: []const u8,
    bytecode: []const u8,
    strings: StringTable,
    data: DataSection,
    wgsl: WgslTable,
    uniforms: UniformTable,
    animation: AnimationTable,
    /// Authored device limits (empty unless the header's has_device_limits is
    /// set). Frontend-only channel — see limits_table.zig. (Arc-3 §5.3b)
    limits: LimitsTable,

    /// Check if this module has an embedded executor.
    pub fn hasEmbeddedExecutor(self: *const Module) bool {
        return self.executor.len > 0;
    }

    /// Get the plugin set for this module.
    pub fn plugins(self: *const Module) PluginSet {
        return self.header.plugins;
    }

    pub fn deinit(self: *Module, allocator: Allocator) void {
        if (self.executor.len > 0) {
            allocator.free(self.executor);
        }
        self.strings.deinit(allocator);
        self.data.deinit(allocator);
        self.wgsl.deinit(allocator);
        self.uniforms.deinit(allocator);
        self.animation.deinit(allocator);
        self.limits.deinit(allocator);
        self.* = undefined;
    }
};

/// Serialization options.
pub const SerializeOptions = struct {
    /// Executor WASM bytes to embed (empty = no embedded executor).
    executor: []const u8 = &.{},
    /// Plugin set (detected from DSL or explicitly set).
    plugins: PluginSet = .{},
    /// Authored device limits. Empty (the default) → no table, `has_device_limits`
    /// clear, byte-identical output. (Arc-3 §5.3b)
    limits: *const LimitsTable = &empty_limits_table,
    /// The author requested an opaque canvas (header flag bit 3). False (the
    /// default) → byte-identical output. (docs/plans/spec/04)
    canvas_alpha_opaque: bool = false,
};

/// Serialize components to PNGB format (v0 — see `VERSION`).
///
/// Pre-conditions:
/// - All table pointers are valid
/// - If options.executor is non-empty, it contains valid WASM
///
/// Post-conditions:
/// - Returns valid PNGB v0 format
/// - Caller owns returned slice
pub fn serialize(
    allocator: Allocator,
    bytecode: []const u8,
    strings: *const StringTable,
    data: *const DataSection,
    wgsl: *const WgslTable,
    uniforms: *const UniformTable,
    animation: *const AnimationTable,
) ![]u8 {
    return serializeWithOptions(allocator, bytecode, strings, data, wgsl, uniforms, animation, .{});
}

/// Serialized section data for assembly.
const SerializedSections = struct {
    string_bytes: []u8,
    data_bytes: []u8,
    wgsl_bytes: []u8,
    uniform_bytes: []u8,
    animation_bytes: []u8,
    /// Device-limits table bytes (empty slice when no limits authored). (§5.3b)
    limits_bytes: []u8,

    fn deinit(self: *SerializedSections, allocator: Allocator) void {
        allocator.free(self.string_bytes);
        allocator.free(self.data_bytes);
        allocator.free(self.wgsl_bytes);
        allocator.free(self.uniform_bytes);
        allocator.free(self.animation_bytes);
        allocator.free(self.limits_bytes);
    }
};

/// Section offset calculations for header.
const SectionOffsets = struct {
    executor_offset: u32,
    string_table_offset: u32,
    data_section_offset: u32,
    wgsl_table_offset: u32,
    uniform_table_offset: u32,
    animation_table_offset: u32,
    /// Offset of the device-limits table (== animation end). Written into the
    /// header's `reserved` u24 only when limits are present. (§5.3b)
    limits_table_offset: u32,
    total_size: usize,
};

/// Serialize all tables to bytes.
/// Caller owns returned sections and must call deinit.
fn serializeAllSections(
    allocator: Allocator,
    strings: *const StringTable,
    data: *const DataSection,
    wgsl: *const WgslTable,
    uniforms: *const UniformTable,
    animation: *const AnimationTable,
    limits: *const LimitsTable,
) !SerializedSections {
    // Pre-condition: all table pointers are valid (non-null)
    assert(@intFromPtr(strings) != 0);
    assert(@intFromPtr(data) != 0);

    const string_bytes = try strings.serialize(allocator);
    errdefer allocator.free(string_bytes);

    const data_bytes = try data.serialize(allocator);
    errdefer allocator.free(data_bytes);

    const wgsl_bytes = try wgsl.serialize(allocator);
    errdefer allocator.free(wgsl_bytes);

    const uniform_bytes = try uniforms.serialize(allocator);
    errdefer allocator.free(uniform_bytes);

    const animation_bytes = try animation.serialize(allocator);
    errdefer allocator.free(animation_bytes);

    const limits_bytes = try limits.serialize(allocator);

    // Post-condition: all sections serialized
    assert(string_bytes.len > 0 or strings.count() == 0);

    return .{
        .string_bytes = string_bytes,
        .data_bytes = data_bytes,
        .wgsl_bytes = wgsl_bytes,
        .uniform_bytes = uniform_bytes,
        .animation_bytes = animation_bytes,
        .limits_bytes = limits_bytes,
    };
}

/// Calculate section offsets for header.
fn calculateSectionOffsets(
    bytecode_len: usize,
    executor_len: usize,
    sections: *const SerializedSections,
) SectionOffsets {
    // Pre-condition: valid section data
    assert(sections.string_bytes.len > 0 or sections.string_bytes.len == 0);

    const has_executor = executor_len > 0;
    const executor_offset: u32 = if (has_executor) HEADER_SIZE else 0;
    const bytecode_start: u32 = @intCast(HEADER_SIZE + executor_len);
    const string_table_offset: u32 = @intCast(bytecode_start + bytecode_len);
    const data_section_offset: u32 = @intCast(string_table_offset + sections.string_bytes.len);
    const wgsl_table_offset: u32 = @intCast(data_section_offset + sections.data_bytes.len);
    const uniform_table_offset: u32 = @intCast(wgsl_table_offset + sections.wgsl_bytes.len);
    const animation_table_offset: u32 = @intCast(uniform_table_offset + sections.uniform_bytes.len);
    // Limits table (if any) directly follows the animation table.
    const limits_table_offset: u32 = @intCast(animation_table_offset + sections.animation_bytes.len);

    const total_size = HEADER_SIZE + executor_len + bytecode_len +
        sections.string_bytes.len + sections.data_bytes.len +
        sections.wgsl_bytes.len + sections.uniform_bytes.len +
        sections.animation_bytes.len + sections.limits_bytes.len;

    // Post-condition: offsets are in ascending order
    assert(string_table_offset >= HEADER_SIZE);
    assert(data_section_offset >= string_table_offset);

    return .{
        .executor_offset = executor_offset,
        .string_table_offset = string_table_offset,
        .data_section_offset = data_section_offset,
        .wgsl_table_offset = wgsl_table_offset,
        .uniform_table_offset = uniform_table_offset,
        .animation_table_offset = animation_table_offset,
        .limits_table_offset = limits_table_offset,
        .total_size = total_size,
    };
}

/// Encode the 3 `reserved` header bytes: the little-endian device-limits offset
/// when limits are present, else {0,0,0} (preserving byte-identity + spare
/// capacity). Pre-condition: the offset fits u24 — the caller checks it first
/// and returns error.PayloadTooLarge otherwise. (Arc-3 §5.3b)
fn encodeReserved(has_limits: bool, limits_offset: u32) [3]u8 {
    if (!has_limits) return .{ 0, 0, 0 };
    assert(limits_offset <= 0xFFFFFF);
    var buf: [3]u8 = undefined;
    std.mem.writeInt(u24, &buf, @intCast(limits_offset), .little);
    return buf;
}

/// Build PNGB header from offsets and options.
fn buildHeader(offsets: *const SectionOffsets, options: SerializeOptions, animation_bytes_len: usize, limits_bytes_len: usize) Header {
    // Pre-condition: offsets are valid
    assert(offsets.string_table_offset >= HEADER_SIZE);
    assert(offsets.total_size > HEADER_SIZE);

    const has_executor = options.executor.len > 0;
    const has_limits = limits_bytes_len > 0;

    return Header{
        .magic = MAGIC.*,
        .version = VERSION,
        .flags = .{
            .has_embedded_executor = has_executor,
            .has_animation_table = animation_bytes_len > 1, // Empty table is just count=0 (1 byte)
            .has_device_limits = has_limits,
            .canvas_alpha_opaque = options.canvas_alpha_opaque,
        },
        .plugins = options.plugins,
        .reserved = encodeReserved(has_limits, offsets.limits_table_offset),
        .executor_offset = offsets.executor_offset,
        .executor_length = @intCast(options.executor.len),
        .string_table_offset = offsets.string_table_offset,
        .data_section_offset = offsets.data_section_offset,
        .wgsl_table_offset = offsets.wgsl_table_offset,
        .uniform_table_offset = offsets.uniform_table_offset,
        .animation_table_offset = offsets.animation_table_offset,
    };
}

/// Write all sections to output buffer.
/// Returns final offset (should equal total_size).
fn writeSectionsToOutput(
    output: []u8,
    header: *const Header,
    bytecode: []const u8,
    sections: *const SerializedSections,
    executor: []const u8,
) usize {
    // Pre-condition: output buffer is large enough
    assert(output.len >= HEADER_SIZE);

    var offset: usize = 0;

    // Write header
    @memcpy(output[offset..][0..HEADER_SIZE], std.mem.asBytes(header));
    offset += HEADER_SIZE;

    // Write executor (if embedded)
    if (executor.len > 0) {
        @memcpy(output[offset..][0..executor.len], executor);
        offset += executor.len;
    }

    // Write bytecode
    @memcpy(output[offset..][0..bytecode.len], bytecode);
    offset += bytecode.len;

    // Write all table sections
    @memcpy(output[offset..][0..sections.string_bytes.len], sections.string_bytes);
    offset += sections.string_bytes.len;

    @memcpy(output[offset..][0..sections.data_bytes.len], sections.data_bytes);
    offset += sections.data_bytes.len;

    @memcpy(output[offset..][0..sections.wgsl_bytes.len], sections.wgsl_bytes);
    offset += sections.wgsl_bytes.len;

    @memcpy(output[offset..][0..sections.uniform_bytes.len], sections.uniform_bytes);
    offset += sections.uniform_bytes.len;

    @memcpy(output[offset..][0..sections.animation_bytes.len], sections.animation_bytes);
    offset += sections.animation_bytes.len;

    // Device-limits table (empty slice when no limits authored). (§5.3b)
    @memcpy(output[offset..][0..sections.limits_bytes.len], sections.limits_bytes);
    offset += sections.limits_bytes.len;

    // Post-condition: wrote to valid range
    assert(offset <= output.len);

    return offset;
}

/// Serialize components to PNGB format with options (v0).
///
/// Supports embedding executor WASM and setting plugin flags.
///
/// Pre-conditions:
/// - All table pointers are valid
/// - If options.executor is non-empty, it contains valid WASM
///
/// Post-conditions:
/// - Returns valid PNGB v0 format
/// - Caller owns returned slice
pub fn serializeWithOptions(
    allocator: Allocator,
    bytecode: []const u8,
    strings: *const StringTable,
    data: *const DataSection,
    wgsl: *const WgslTable,
    uniforms: *const UniformTable,
    animation: *const AnimationTable,
    options: SerializeOptions,
) ![]u8 {
    // Pre-condition: valid inputs
    assert(@intFromPtr(strings) != 0);

    // Serialize all tables
    var sections = try serializeAllSections(allocator, strings, data, wgsl, uniforms, animation, options.limits);
    defer sections.deinit(allocator);

    // Calculate offsets
    const offsets = calculateSectionOffsets(bytecode.len, options.executor.len, &sections);

    // The limits offset is stored in the header's 3 `reserved` bytes (u24). A
    // payload large enough to push it past 16 MiB cannot address the table —
    // fail loud rather than truncate the offset. (PNG chunk walk caps at 16 MiB
    // anyway; only a ZIP-path payload could reach here.) (Arc-3 §5.3b)
    if (sections.limits_bytes.len > 0 and offsets.limits_table_offset > 0xFFFFFF) {
        return error.PayloadTooLarge;
    }

    // Build header
    const header = buildHeader(&offsets, options, sections.animation_bytes.len, sections.limits_bytes.len);

    // Allocate output buffer
    const output = try allocator.alloc(u8, offsets.total_size);
    errdefer allocator.free(output);

    // Write all sections
    const final_offset = writeSectionsToOutput(output, &header, bytecode, &sections, options.executor);

    // Post-condition: wrote exactly total_size
    assert(final_offset == offsets.total_size);

    return output;
}

/// Validate header magic, version, and all section offsets.
/// Returns the parsed header on success.
fn validateHeaderAndOffsets(data: []const u8) !*const Header {
    // Pre-condition: minimum data length
    assert(data.len >= HEADER_SIZE);

    // Check magic
    if (!std.mem.eql(u8, data[0..4], MAGIC)) {
        return error.InvalidMagic;
    }

    // Check version
    const version = std.mem.readInt(u16, data[4..6], .little);
    if (version != VERSION) {
        return error.UnsupportedVersion;
    }

    // Parse header
    const header: *const Header = @ptrCast(@alignCast(data[0..HEADER_SIZE]));
    try header.validate();

    // Compute where the bytecode starts (after the header and optional
    // executor). The executor occupies [executor_offset, executor_offset +
    // executor_length); its end is where the bytecode begins. Add in u64 so a
    // crafted executor_offset + executor_length near maxInt(u32) cannot WRAP to
    // a small in-bounds value — the deserialize path runs in Debug/ReleaseSafe
    // (traps on wrap) but tooling built ReleaseFast would silently wrap and slice
    // OOB. (Arc-3 §2.1)
    const bytecode_start: u64 = if (header.hasEmbeddedExecutor()) blk: {
        if (header.executor_offset < HEADER_SIZE) return error.InvalidOffset;
        break :blk @as(u64, header.executor_offset) + @as(u64, header.executor_length);
    } else HEADER_SIZE;

    // Every section boundary must sit in ASCENDING order and stay within the
    // buffer. The old code only checked each offset <= data.len individually;
    // a reversed pair (e.g. data_section_offset < string_table_offset) still
    // passed, then sliced data[start..end] with start > end downstream → panic
    // (safe) / UB (ReleaseFast), and bytecode_start > string_table_offset
    // underflowed string_table_offset - bytecode_start into a huge bytecode_len.
    // Chaining the comparisons proves every boundary is ordered and <= data.len
    // (the serializer emits them non-decreasing; equal = an empty section, so
    // reject only a strict decrease). (Arc-3 §2.1)
    // When bit 2 (has_device_limits) is set, the limits table sits between the
    // animation table and EOF; its offset (u24 in `reserved`) must be ordered in
    // the chain too. When the bit is CLEAR, `reserved` is DON'T-CARE (spare
    // capacity) and is not read. (Arc-3 §5.3b)
    var boundaries_buf: [8]u64 = undefined;
    var n: usize = 0;
    boundaries_buf[n] = bytecode_start;
    n += 1;
    boundaries_buf[n] = header.string_table_offset;
    n += 1;
    boundaries_buf[n] = header.data_section_offset;
    n += 1;
    boundaries_buf[n] = header.wgsl_table_offset;
    n += 1;
    boundaries_buf[n] = header.uniform_table_offset;
    n += 1;
    boundaries_buf[n] = header.animation_table_offset;
    n += 1;
    if (header.hasDeviceLimits()) {
        boundaries_buf[n] = header.limitsTableOffset();
        n += 1;
    }
    boundaries_buf[n] = data.len;
    n += 1;
    var prev: u64 = HEADER_SIZE;
    for (boundaries_buf[0..n]) |off| {
        if (off < prev) return error.InvalidOffset;
        prev = off;
    }

    // Post-condition: header is valid and all sections are ordered + bounded
    assert(std.mem.eql(u8, &header.magic, MAGIC));
    assert(header.string_table_offset <= data.len);

    return header;
}

/// Extract executor and bytecode slices from data.
/// Returns executor (owned, caller must free) and bytecode (slice into data).
fn extractExecutorAndBytecode(
    allocator: Allocator,
    data: []const u8,
    header: *const Header,
) !struct { executor: []const u8, bytecode: []const u8 } {
    // Pre-condition: header is valid
    assert(std.mem.eql(u8, &header.magic, MAGIC));

    // Extract executor if present
    var executor: []const u8 = &.{};
    if (header.hasEmbeddedExecutor()) {
        if (header.executor_offset + header.executor_length > data.len) {
            return error.InvalidOffset;
        }
        executor = try allocator.dupe(u8, data[header.executor_offset..][0..header.executor_length]);
    }

    // Calculate bytecode bounds
    const bytecode_start: usize = if (header.hasEmbeddedExecutor())
        header.executor_offset + header.executor_length
    else
        HEADER_SIZE;
    const bytecode_len = header.string_table_offset - bytecode_start;
    const bytecode = data[bytecode_start..][0..bytecode_len];

    // Post-condition: bytecode is within data bounds
    assert(bytecode_start + bytecode_len <= data.len);

    return .{ .executor = executor, .bytecode = bytecode };
}

/// Deserialized tables result.
const DeserializedTables = struct {
    strings: StringTable,
    data_section: DataSection,
    wgsl: WgslTable,
    uniforms: UniformTable,
    animation: AnimationTable,
    limits: LimitsTable,
};

/// Deserialize all tables from data using header offsets.
fn deserializeAllTables(allocator: Allocator, data: []const u8, header: *const Header) !DeserializedTables {
    // Pre-condition: header offsets are valid
    assert(header.string_table_offset <= data.len);
    assert(header.data_section_offset <= data.len);

    // Deserialize string table
    const string_data = data[header.string_table_offset..header.data_section_offset];
    const strings = try @import("string_table.zig").deserialize(allocator, string_data);
    errdefer {
        var s = strings;
        s.deinit(allocator);
    }

    // Deserialize data section
    const data_section_data = data[header.data_section_offset..header.wgsl_table_offset];
    const data_section = try @import("data_section.zig").deserialize(allocator, data_section_data);
    errdefer {
        var ds = data_section;
        ds.deinit(allocator);
    }

    // Deserialize WGSL table
    const wgsl_data = data[header.wgsl_table_offset..header.uniform_table_offset];
    const wgsl = try deserializeWgslTable(allocator, wgsl_data);
    errdefer {
        var w = wgsl;
        w.deinit(allocator);
    }

    // Deserialize uniform table
    const uniform_data = data[header.uniform_table_offset..header.animation_table_offset];
    const uniforms = try uniform_table_mod.deserialize(allocator, uniform_data);
    errdefer {
        var u = uniforms;
        u.deinit(allocator);
    }

    // Deserialize animation table. When a device-limits table follows it, the
    // animation section ends at the limits offset; otherwise it runs to EOF.
    // (validateHeaderAndOffsets proved animation_table_offset <= limits_offset
    // <= data.len when the flag is set.) (Arc-3 §5.3b)
    const animation_end: usize = if (header.hasDeviceLimits())
        header.limitsTableOffset()
    else
        data.len;
    const animation_data = data[header.animation_table_offset..animation_end];
    const animation = try animation_table_mod.deserialize(allocator, animation_data);
    errdefer {
        var a = animation;
        a.deinit(allocator);
    }

    // Deserialize device-limits table (frontend-only; empty when the flag is
    // clear). Blind old executors never reach here — they slice animation
    // open-ended and its content-driven parser tolerates the trailing bytes.
    const limits_data: []const u8 = if (header.hasDeviceLimits())
        data[header.limitsTableOffset()..]
    else
        &.{};
    const limits = try limits_table_mod.deserialize(allocator, limits_data);

    // Post-condition: all tables deserialized
    assert(@intFromPtr(&strings) != 0);

    return .{
        .strings = strings,
        .data_section = data_section,
        .wgsl = wgsl,
        .uniforms = uniforms,
        .animation = animation,
        .limits = limits,
    };
}

/// Deserialize PNGB format to module (v0 only).
///
/// Pre-conditions:
/// - data contains valid PNGB v0 format
/// - data.len >= HEADER_SIZE
///
/// Post-conditions:
/// - Returns valid Module
/// - Caller owns executor slice (if present)
/// - Bytecode slice references input data
///
/// Note: The returned module references the input data - caller must ensure data outlives module.
pub fn deserialize(allocator: Allocator, data: []const u8) !Module {
    // Pre-condition: at least header present
    if (data.len < HEADER_SIZE) return error.InvalidFormat;

    // Validate header and offsets
    const header = try validateHeaderAndOffsets(data);

    // Extract executor and bytecode
    const extracted = try extractExecutorAndBytecode(allocator, data, header);
    errdefer if (extracted.executor.len > 0) allocator.free(extracted.executor);

    // Deserialize all tables
    const tables = try deserializeAllTables(allocator, data, header);

    // Post-condition: valid module constructed
    assert(std.mem.eql(u8, &header.magic, MAGIC));

    return Module{
        .header = header.*,
        .executor = extracted.executor,
        .bytecode = extracted.bytecode,
        .strings = tables.strings,
        .data = tables.data_section,
        .wgsl = tables.wgsl,
        .uniforms = tables.uniforms,
        .animation = tables.animation,
        .limits = tables.limits,
    };
}

// ============================================================================
// Builder: High-level interface for constructing PNGB modules
// ============================================================================

/// Builder for constructing PNGB modules.
pub const Builder = struct {
    const Self = @This();

    strings: StringTable,
    data: DataSection,
    wgsl_table: WgslTable,
    uniform_table: UniformTable,
    animation_table: AnimationTable,
    limits_table: LimitsTable,
    emitter: Emitter,
    /// Header flag bit 3: the author requested an opaque canvas. Set by the
    /// frontend (`(canvas :alpha-mode opaque)`); folded into the header by
    /// `finalizeWithOptions` like the limits table. (docs/plans/spec/04)
    canvas_alpha_opaque: bool,

    pub fn init() Self {
        return .{
            .strings = .empty,
            .data = .empty,
            .wgsl_table = .empty,
            .uniform_table = .empty,
            .animation_table = .empty,
            .limits_table = .empty,
            .emitter = .empty,
            .canvas_alpha_opaque = false,
        };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.strings.deinit(allocator);
        self.data.deinit(allocator);
        self.wgsl_table.deinit(allocator);
        self.uniform_table.deinit(allocator);
        self.animation_table.deinit(allocator);
        self.limits_table.deinit(allocator);
        self.emitter.deinit(allocator);
        self.* = undefined;
    }

    /// Intern a string and return its ID.
    pub fn internString(self: *Self, allocator: Allocator, str: []const u8) !@import("string_table.zig").StringId {
        return self.strings.intern(allocator, str);
    }

    /// Add data and return its ID.
    pub fn addData(self: *Self, allocator: Allocator, data: []const u8) !@import("data_section.zig").DataId {
        return self.data.add(allocator, data);
    }

    /// Get the size of a data entry by ID.
    pub fn getDataSize(self: *const Self, data_id: u16) u32 {
        const blob = self.data.blobs.items[data_id];
        return @intCast(blob.len);
    }

    /// Get the emitter for bytecode generation.
    pub fn getEmitter(self: *Self) *Emitter {
        return &self.emitter;
    }

    /// Add a WGSL module entry and return its ID.
    /// Pre-condition: data_id must be a valid ID in the data section.
    pub fn addWgsl(self: *Self, allocator: Allocator, data_id: u16, deps: []const u16) !u16 {
        return self.wgsl_table.add(allocator, data_id, deps);
    }

    /// Add a uniform binding with fields to the uniform table.
    pub fn addUniformBinding(
        self: *Self,
        allocator: Allocator,
        buffer_id: u16,
        name_string_id: u16,
        group: u8,
        binding_index: u8,
        fields: []const uniform_table_mod.UniformField,
    ) !void {
        return self.uniform_table.addBinding(allocator, buffer_id, name_string_id, group, binding_index, fields);
    }

    /// Get uniform table for direct manipulation.
    pub fn getUniformTable(self: *Self) *UniformTable {
        return &self.uniform_table;
    }

    /// Get animation table for direct manipulation.
    pub fn getAnimationTable(self: *Self) *AnimationTable {
        return &self.animation_table;
    }

    /// Add an authored device limit (WebGPU camelCase name already interned).
    /// Fed into `requiredLimits` at device creation by the frontend. (§5.3b)
    pub fn addDeviceLimit(self: *Self, allocator: Allocator, name_string_id: u16, value: u64) !void {
        return self.limits_table.add(allocator, name_string_id, value);
    }

    /// Get limits table for direct manipulation.
    pub fn getLimitsTable(self: *Self) *LimitsTable {
        return &self.limits_table;
    }

    /// Finalize and serialize to PNGB format.
    pub fn finalize(self: *Self, allocator: Allocator) ![]u8 {
        return self.finalizeWithOptions(allocator, .{});
    }

    /// Finalize and serialize to PNGB format with options.
    /// Supports embedding executor WASM and setting plugin flags. The builder's
    /// own limits table and canvas flag are always used (callers set
    /// executor/plugins only).
    pub fn finalizeWithOptions(self: *Self, allocator: Allocator, options: SerializeOptions) ![]u8 {
        var opts = options;
        opts.limits = &self.limits_table;
        opts.canvas_alpha_opaque = self.canvas_alpha_opaque;
        return serializeWithOptions(
            allocator,
            self.emitter.bytecode(),
            &self.strings,
            &self.data,
            &self.wgsl_table,
            &self.uniform_table,
            &self.animation_table,
            opts,
        );
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

// Arc-3 §2.1 — hostile header offsets. The serializer emits section offsets
// non-decreasing; these craft a valid module then corrupt the header to prove
// deserialize rejects reversed / out-of-range / overflowing offsets with a
// clean error instead of slicing OOB (panic in safe mode, UB in ReleaseFast).
fn buildSimpleModuleBytes() ![]u8 {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);
    const name_id = try builder.internString(testing.allocator, "f");
    const shader_id = try builder.addData(testing.allocator, "@vertex fn vs() {}");
    const emitter = builder.getEmitter();
    try emitter.createShaderModule(testing.allocator, 0, shader_id.toInt());
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.endFrame(testing.allocator);
    return builder.finalize(testing.allocator);
}

// ── Device limits table (Arc-3 §5.3b) ───────────────────────────────────────

/// Build a minimal one-shader module. `add_limits` toggles the limits table so
/// the byte-identity test can compare with/without on an otherwise identical
/// build.
fn buildLimitsFixture(allocator: Allocator, add_limits: bool) ![]u8 {
    var builder = Builder.init();
    defer builder.deinit(allocator);

    const frame_name = try builder.internString(allocator, "main");
    // Intern the WebGPU camelCase limit names so the entries reference the
    // string table (the "zero JS name map" design).
    const wg_x = try builder.internString(allocator, "maxComputeWorkgroupSizeX");
    const buf_sz = try builder.internString(allocator, "maxBufferSize");
    const shader_data = try builder.addData(allocator, "@vertex fn vs() {}");

    const emitter = builder.getEmitter();
    try emitter.createShaderModule(allocator, 0, shader_data.toInt());
    try emitter.defineFrame(allocator, 0, frame_name.toInt());
    try emitter.endFrame(allocator);

    if (add_limits) {
        try builder.addDeviceLimit(allocator, @intCast(@intFromEnum(wg_x)), 512);
        // A value beyond u32 — proves the u64 channel end to end.
        try builder.addDeviceLimit(allocator, @intCast(@intFromEnum(buf_sz)), 0x2_0000_0000);
    }

    return builder.finalize(allocator);
}
