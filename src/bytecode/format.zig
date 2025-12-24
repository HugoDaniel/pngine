//! PNGB Binary Format (v5)
//!
//! Serializes and deserializes the complete PNGB binary format.
//! v5 adds embedded executor support with plugin architecture.
//!
//! File Structure (40 bytes header):
//! ┌─────────────────────────────────────┐
//! │ Header (40 bytes)                   │
//! │   magic: "PNGB" (4 bytes)           │
//! │   version: u16 (5)                  │
//! │   flags: u16                        │
//! │     bit 0: has_embedded_executor    │
//! │     bit 1: has_animation_table      │
//! │   plugins: u8 (PluginSet bitfield)  │
//! │   reserved: [3]u8 (alignment)       │
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
//! └─────────────────────────────────────┘
//!
//! Invariants:
//! - Magic must be "PNGB"
//! - Version must be 5 (or 4 for backward compat)
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

/// Magic bytes identifying PNGB format.
pub const MAGIC: *const [4]u8 = "PNGB";

/// Current format version (v5 adds embedded executor with plugin architecture).
pub const VERSION: u16 = 5;

/// Previous version (for backward compatibility during deserialization).
pub const VERSION_V4: u16 = 4;

/// Header size in bytes (v5).
pub const HEADER_SIZE: usize = 40;

/// Header size for v4 format (backward compat).
pub const HEADER_SIZE_V4: usize = 28;

/// Maximum WGSL modules per file.
pub const MAX_WGSL_MODULES: u16 = 1024;

/// Maximum dependencies per WGSL module.
pub const MAX_WGSL_DEPS: u16 = 64;

// ============================================================================
// Plugin Architecture
// ============================================================================

/// Plugin set bitfield - determines which executor features are included.
/// Compile-time selection based on DSL analysis.
///
/// See: docs/embedded-executor-plan.md for architecture details.
pub const PluginSet = packed struct(u8) {
    /// Core plugin (always included): bytecode parsing, command emission.
    core: bool = true,
    /// Render plugin: render pipelines, render passes, draw commands.
    render: bool = false,
    /// Compute plugin: compute pipelines, dispatch commands.
    compute: bool = false,
    /// WASM-in-WASM plugin: nested WASM execution for physics engines, etc.
    wasm: bool = false,
    /// Animation plugin: scene table, timeline, transitions.
    animation: bool = false,
    /// Texture plugin: image/video texture loading.
    texture: bool = false,
    /// Reserved for future use.
    reserved: u2 = 0,

    /// Create empty plugin set (core only).
    pub const core_only: PluginSet = .{};

    /// Create full plugin set (all features).
    pub const full: PluginSet = .{
        .render = true,
        .compute = true,
        .wasm = true,
        .animation = true,
        .texture = true,
    };

    /// Convert to u8 for serialization.
    pub fn toU8(self: PluginSet) u8 {
        return @bitCast(self);
    }

    /// Create from u8 during deserialization.
    pub fn fromU8(byte: u8) PluginSet {
        return @bitCast(byte);
    }

    /// Check if this plugin set requires a specific plugin.
    pub fn hasPlugin(self: PluginSet, plugin: Plugin) bool {
        return switch (plugin) {
            .core => self.core,
            .render => self.render,
            .compute => self.compute,
            .wasm => self.wasm,
            .animation => self.animation,
            .texture => self.texture,
        };
    }
};

/// Individual plugin types.
pub const Plugin = enum(u3) {
    core = 0,
    render = 1,
    compute = 2,
    wasm = 3,
    animation = 4,
    texture = 5,
};

// ============================================================================
// Header
// ============================================================================

/// Header flags.
pub const Flags = packed struct(u16) {
    /// Payload contains embedded WASM executor.
    has_embedded_executor: bool = false,
    /// Payload contains animation table.
    has_animation_table: bool = false,
    /// Reserved for future use.
    reserved: u14 = 0,
};

/// PNGB file header (v5, 40 bytes).
///
/// Layout optimized for 4-byte alignment of all u32 fields.
pub const Header = extern struct {
    /// Magic bytes "PNGB".
    magic: [4]u8,
    /// Format version (5).
    version: u16,
    /// Feature flags.
    flags: Flags,
    /// Plugin set bitfield.
    plugins: PluginSet,
    /// Reserved for alignment and future use.
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
        // Accept v5 (current) or v4 (backward compat)
        if (self.version != VERSION and self.version != VERSION_V4) {
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
};

/// Header for v4 format (backward compatibility).
/// Used only during deserialization of legacy payloads.
pub const HeaderV4 = extern struct {
    magic: [4]u8,
    version: u16,
    flags: u16,
    string_table_offset: u32,
    data_section_offset: u32,
    wgsl_table_offset: u32,
    uniform_table_offset: u32,
    animation_table_offset: u32,

    comptime {
        assert(@sizeOf(HeaderV4) == HEADER_SIZE_V4);
    }

    /// Convert v4 header to v5 header.
    pub fn toV5(self: *const HeaderV4) Header {
        return Header{
            .magic = self.magic,
            .version = VERSION, // Upgrade to v5
            .flags = .{},
            .plugins = .{}, // Core only (no embedded executor)
            .reserved = .{ 0, 0, 0 },
            .executor_offset = 0,
            .executor_length = 0,
            .string_table_offset = self.string_table_offset,
            .data_section_offset = self.data_section_offset,
            .wgsl_table_offset = self.wgsl_table_offset,
            .uniform_table_offset = self.uniform_table_offset,
            .animation_table_offset = self.animation_table_offset,
        };
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
    entries: std.ArrayListUnmanaged(WgslEntry),

    pub const empty: WgslTable = .{ .entries = .{} };

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

        var result = std.ArrayListUnmanaged(u8){};
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

    var table = WgslTable{ .entries = .{} };
    errdefer table.deinit(allocator);

    if (data.len == 0) return table;

    var pos: usize = 0;

    // Read count
    const count_result = opcodes.decodeVarint(data[pos..]);
    pos += count_result.len;
    const entry_count: u16 = @intCast(count_result.value);

    // Pre-allocate entries
    try table.entries.ensureTotalCapacity(allocator, entry_count);

    // Read entries (bounded loop)
    for (0..@min(entry_count, MAX_WGSL_MODULES)) |_| {
        // Check bounds before each varint read
        if (pos >= data.len) break;

        // data_id
        const data_id_result = opcodes.decodeVarint(data[pos..]);
        pos += data_id_result.len;
        const data_id: u16 = @intCast(data_id_result.value);

        // dep_count - check bounds first
        if (pos >= data.len) {
            // Truncated: add entry with no deps
            table.entries.appendAssumeCapacity(.{ .data_id = data_id, .deps = &[_]u16{} });
            break;
        }
        const dep_count_result = opcodes.decodeVarint(data[pos..]);
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
                const dep_result = opcodes.decodeVarint(data[pos..]);
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
        self.* = undefined;
    }
};

/// Serialization options.
pub const SerializeOptions = struct {
    /// Executor WASM bytes to embed (empty = no embedded executor).
    executor: []const u8 = &.{},
    /// Plugin set (detected from DSL or explicitly set).
    plugins: PluginSet = .{},
};

/// Serialize components to PNGB format (v5).
///
/// Pre-conditions:
/// - All table pointers are valid
/// - If options.executor is non-empty, it contains valid WASM
///
/// Post-conditions:
/// - Returns valid PNGB v5 format
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

/// Serialize components to PNGB format with options (v5).
///
/// Supports embedding executor WASM and setting plugin flags.
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
    // Serialize string table
    const string_bytes = try strings.serialize(allocator);
    defer allocator.free(string_bytes);

    // Serialize data section
    const data_bytes = try data.serialize(allocator);
    defer allocator.free(data_bytes);

    // Serialize WGSL table
    const wgsl_bytes = try wgsl.serialize(allocator);
    defer allocator.free(wgsl_bytes);

    // Serialize uniform table
    const uniform_bytes = try uniforms.serialize(allocator);
    defer allocator.free(uniform_bytes);

    // Serialize animation table
    const animation_bytes = try animation.serialize(allocator);
    defer allocator.free(animation_bytes);

    // Calculate section sizes
    const has_executor = options.executor.len > 0;
    const executor_len = options.executor.len;

    // Calculate offsets (header → executor → bytecode → strings → data → wgsl → uniform → animation)
    const executor_offset: u32 = if (has_executor) HEADER_SIZE else 0;
    const bytecode_start: u32 = @intCast(HEADER_SIZE + executor_len);
    const string_table_offset: u32 = @intCast(bytecode_start + bytecode.len);
    const data_section_offset: u32 = @intCast(string_table_offset + string_bytes.len);
    const wgsl_table_offset: u32 = @intCast(data_section_offset + data_bytes.len);
    const uniform_table_offset: u32 = @intCast(wgsl_table_offset + wgsl_bytes.len);
    const animation_table_offset: u32 = @intCast(uniform_table_offset + uniform_bytes.len);

    // Total size
    const total_size = HEADER_SIZE + executor_len + bytecode.len + string_bytes.len + data_bytes.len + wgsl_bytes.len + uniform_bytes.len + animation_bytes.len;

    // Allocate output buffer
    const output = try allocator.alloc(u8, total_size);
    errdefer allocator.free(output);

    var offset: usize = 0;

    // Build header
    const header = Header{
        .magic = MAGIC.*,
        .version = VERSION,
        .flags = .{
            .has_embedded_executor = has_executor,
            .has_animation_table = animation_bytes.len > 1, // Empty table is just count=0 (1 byte)
        },
        .plugins = options.plugins,
        .reserved = .{ 0, 0, 0 },
        .executor_offset = executor_offset,
        .executor_length = @intCast(executor_len),
        .string_table_offset = string_table_offset,
        .data_section_offset = data_section_offset,
        .wgsl_table_offset = wgsl_table_offset,
        .uniform_table_offset = uniform_table_offset,
        .animation_table_offset = animation_table_offset,
    };

    // Write header
    @memcpy(output[offset..][0..HEADER_SIZE], std.mem.asBytes(&header));
    offset += HEADER_SIZE;

    // Write executor (if embedded)
    if (has_executor) {
        @memcpy(output[offset..][0..executor_len], options.executor);
        offset += executor_len;
    }

    // Write bytecode
    @memcpy(output[offset..][0..bytecode.len], bytecode);
    offset += bytecode.len;

    // Write string table
    @memcpy(output[offset..][0..string_bytes.len], string_bytes);
    offset += string_bytes.len;

    // Write data section
    @memcpy(output[offset..][0..data_bytes.len], data_bytes);
    offset += data_bytes.len;

    // Write WGSL table
    @memcpy(output[offset..][0..wgsl_bytes.len], wgsl_bytes);
    offset += wgsl_bytes.len;

    // Write uniform table
    @memcpy(output[offset..][0..uniform_bytes.len], uniform_bytes);
    offset += uniform_bytes.len;

    // Write animation table
    @memcpy(output[offset..][0..animation_bytes.len], animation_bytes);
    offset += animation_bytes.len;

    // Post-condition: wrote exactly total_size
    assert(offset == total_size);

    return output;
}

/// Deserialize PNGB format to module.
/// Supports both v4 (28-byte header) and v5 (40-byte header) formats.
/// Note: The returned module references the input data - caller must ensure data outlives module.
pub fn deserialize(allocator: Allocator, data: []const u8) !Module {
    // Pre-condition: at least v4 header present
    if (data.len < HEADER_SIZE_V4) return error.InvalidFormat;

    // Check magic first
    if (!std.mem.eql(u8, data[0..4], MAGIC)) {
        return error.InvalidMagic;
    }

    // Read version to determine format
    const version = std.mem.readInt(u16, data[4..6], .little);

    // Handle v4 backward compatibility
    const header: Header = switch (version) {
        VERSION_V4 => blk: {
            const header_v4: *const HeaderV4 = @ptrCast(@alignCast(data[0..HEADER_SIZE_V4]));
            break :blk header_v4.toV5();
        },
        VERSION => blk: {
            if (data.len < HEADER_SIZE) return error.InvalidFormat;
            const h: *const Header = @ptrCast(@alignCast(data[0..HEADER_SIZE]));
            break :blk h.*;
        },
        else => return error.UnsupportedVersion,
    };

    // Determine actual header size based on version
    const actual_header_size: usize = if (version == VERSION_V4) HEADER_SIZE_V4 else HEADER_SIZE;

    // Validate offsets
    if (header.string_table_offset > data.len) return error.InvalidOffset;
    if (header.data_section_offset > data.len) return error.InvalidOffset;
    if (header.wgsl_table_offset > data.len) return error.InvalidOffset;
    if (header.uniform_table_offset > data.len) return error.InvalidOffset;
    if (header.animation_table_offset > data.len) return error.InvalidOffset;
    if (header.string_table_offset < actual_header_size) return error.InvalidOffset;

    // Extract embedded executor if present (v5 only)
    var executor: []const u8 = &.{};
    if (version == VERSION and header.hasEmbeddedExecutor()) {
        if (header.executor_offset + header.executor_length > data.len) {
            return error.InvalidOffset;
        }
        executor = try allocator.dupe(u8, data[header.executor_offset..][0..header.executor_length]);
    }
    errdefer if (executor.len > 0) allocator.free(executor);

    // Calculate bytecode start (after header + executor)
    const bytecode_start: usize = if (version == VERSION and header.hasEmbeddedExecutor())
        header.executor_offset + header.executor_length
    else
        actual_header_size;

    // Extract bytecode (between header/executor and string table)
    const bytecode_len = header.string_table_offset - bytecode_start;
    const bytecode = data[bytecode_start..][0..bytecode_len];

    // Deserialize string table
    const string_data = data[header.string_table_offset..header.data_section_offset];
    const strings = try @import("string_table.zig").deserialize(allocator, string_data);
    errdefer {
        var s = strings;
        s.deinit(allocator);
    }

    // Deserialize data section (between data_section_offset and wgsl_table_offset)
    const data_section_data = data[header.data_section_offset..header.wgsl_table_offset];
    const data_section = try @import("data_section.zig").deserialize(allocator, data_section_data);
    errdefer {
        var ds = data_section;
        ds.deinit(allocator);
    }

    // Deserialize WGSL table (between wgsl_table_offset and uniform_table_offset)
    const wgsl_data = data[header.wgsl_table_offset..header.uniform_table_offset];
    const wgsl = try deserializeWgslTable(allocator, wgsl_data);
    errdefer {
        var w = wgsl;
        w.deinit(allocator);
    }

    // Deserialize uniform table (between uniform_table_offset and animation_table_offset)
    const uniform_data = data[header.uniform_table_offset..header.animation_table_offset];
    const uniforms = try uniform_table_mod.deserialize(allocator, uniform_data);
    errdefer {
        var u = uniforms;
        u.deinit(allocator);
    }

    // Deserialize animation table (from animation_table_offset to end)
    const animation_data = data[header.animation_table_offset..];
    const animation = try animation_table_mod.deserialize(allocator, animation_data);

    return Module{
        .header = header,
        .executor = executor,
        .bytecode = bytecode,
        .strings = strings,
        .data = data_section,
        .wgsl = wgsl,
        .uniforms = uniforms,
        .animation = animation,
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
    emitter: Emitter,

    pub fn init() Self {
        return .{
            .strings = .empty,
            .data = .empty,
            .wgsl_table = .empty,
            .uniform_table = .empty,
            .animation_table = .empty,
            .emitter = .empty,
        };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.strings.deinit(allocator);
        self.data.deinit(allocator);
        self.wgsl_table.deinit(allocator);
        self.uniform_table.deinit(allocator);
        self.animation_table.deinit(allocator);
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

    /// Finalize and serialize to PNGB format.
    pub fn finalize(self: *Self, allocator: Allocator) ![]u8 {
        return serialize(
            allocator,
            self.emitter.bytecode(),
            &self.strings,
            &self.data,
            &self.wgsl_table,
            &self.uniform_table,
            &self.animation_table,
        );
    }

    /// Finalize and serialize to PNGB format with options.
    /// Supports embedding executor WASM and setting plugin flags.
    pub fn finalizeWithOptions(self: *Self, allocator: Allocator, options: SerializeOptions) ![]u8 {
        return serializeWithOptions(
            allocator,
            self.emitter.bytecode(),
            &self.strings,
            &self.data,
            &self.wgsl_table,
            &self.uniform_table,
            &self.animation_table,
            options,
        );
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "header size" {
    // v5 header is 40 bytes
    try testing.expectEqual(@as(usize, 40), @sizeOf(Header));
    // v4 header was 28 bytes (backward compat)
    try testing.expectEqual(@as(usize, 28), @sizeOf(HeaderV4));
}

test "empty module" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const output = try builder.finalize(testing.allocator);
    defer testing.allocator.free(output);

    // Should have at least header
    try testing.expect(output.len >= HEADER_SIZE);

    // Verify magic
    try testing.expectEqualStrings("PNGB", output[0..4]);
}

test "module with strings and data" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    // Add strings
    const name_id = try builder.internString(testing.allocator, "simpleTriangle");
    _ = try builder.internString(testing.allocator, "vertexMain");

    // Add data
    const shader_code = "@vertex fn vertexMain() -> @builtin(position) vec4f { return vec4f(0); }";
    const shader_id = try builder.addData(testing.allocator, shader_code);

    // Add some bytecode
    const emitter = builder.getEmitter();
    try emitter.createShaderModule(testing.allocator, 0, shader_id.toInt());
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.endFrame(testing.allocator);

    // Finalize
    const output = try builder.finalize(testing.allocator);
    defer testing.allocator.free(output);

    try testing.expect(output.len > HEADER_SIZE);

    // Deserialize and verify
    var module = try deserialize(testing.allocator, output);
    defer module.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 2), module.strings.count());
    try testing.expectEqualStrings("simpleTriangle", module.strings.get(@enumFromInt(0)));
    try testing.expectEqualStrings("vertexMain", module.strings.get(@enumFromInt(1)));

    try testing.expectEqual(@as(u16, 1), module.data.count());
    try testing.expectEqualStrings(shader_code, module.data.get(@enumFromInt(0)));
}

test "roundtrip serialization" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    // Build a simple triangle module
    const frame_name = try builder.internString(testing.allocator, "triangle");
    const shader = "@vertex fn vs() {} @fragment fn fs() {}";
    const shader_data = try builder.addData(testing.allocator, shader);

    const emitter = builder.getEmitter();
    try emitter.createShaderModule(testing.allocator, 0, shader_data.toInt());
    try emitter.createRenderPipeline(testing.allocator, 0, 0);
    try emitter.defineFrame(testing.allocator, 0, frame_name.toInt());
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    // Serialize
    const output = try builder.finalize(testing.allocator);
    defer testing.allocator.free(output);

    // Deserialize
    var module = try deserialize(testing.allocator, output);
    defer module.deinit(testing.allocator);

    // Verify bytecode starts with create_shader_module
    const opcodes = @import("opcodes.zig");
    try testing.expectEqual(@as(u8, @intFromEnum(opcodes.OpCode.create_shader_module)), module.bytecode[0]);

    // Verify string
    try testing.expectEqualStrings("triangle", module.strings.get(@enumFromInt(0)));

    // Verify data
    try testing.expectEqualStrings(shader, module.data.get(@enumFromInt(0)));
}

test "invalid magic" {
    var data: [HEADER_SIZE_V4]u8 = undefined;
    @memcpy(data[0..4], "XXXX"); // Invalid magic

    const result = deserialize(testing.allocator, &data);
    try testing.expectError(error.InvalidMagic, result);
}

test "invalid version" {
    var data: [HEADER_SIZE_V4]u8 = undefined;
    @memcpy(data[0..4], MAGIC);
    std.mem.writeInt(u16, data[4..6], 99, .little); // Invalid version

    const result = deserialize(testing.allocator, &data);
    try testing.expectError(error.UnsupportedVersion, result);
}

test "builder handles OOM gracefully" {
    // Test that Builder properly returns OutOfMemory and doesn't leak
    // when allocation fails at any point.
    var fail_index: usize = 0;
    const max_iterations: usize = 500;

    for (0..max_iterations) |_| {
        var failing_alloc = std.testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        const alloc = failing_alloc.allocator();

        var builder = Builder.init();
        defer builder.deinit(alloc);

        // Try to build a simple module
        const string_result = builder.internString(alloc, "test_frame");
        if (string_result) |_| {
            // String interning succeeded, try data
            const data_result = builder.addData(alloc, "shader code here");
            if (data_result) |data_id| {
                // Data add succeeded, try bytecode emission
                const emitter = builder.getEmitter();
                const emit_result = emitter.createShaderModule(alloc, 0, data_id.toInt());
                if (emit_result) |_| {
                    // Emission succeeded, try finalize
                    const finalize_result = builder.finalize(alloc);
                    if (finalize_result) |output| {
                        alloc.free(output);
                        // Full success - test complete
                        break;
                    } else |err| {
                        try testing.expectEqual(error.OutOfMemory, err);
                    }
                } else |err| {
                    try testing.expectEqual(error.OutOfMemory, err);
                }
            } else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
            }
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
        }

        fail_index += 1;
    } else {
        unreachable;
    }
}

test "serialize handles OOM gracefully" {
    // First build a valid module with normal allocator
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    _ = try builder.internString(testing.allocator, "test");
    const data_id = try builder.addData(testing.allocator, "data content");
    const emitter = builder.getEmitter();
    try emitter.createShaderModule(testing.allocator, 0, data_id.toInt());
    try emitter.draw(testing.allocator, 3, 1, 0, 0);

    // Now test serialization with failing allocator
    var fail_index: usize = 0;
    const max_iterations: usize = 100;

    for (0..max_iterations) |_| {
        var failing_alloc = std.testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });

        const result = serialize(
            failing_alloc.allocator(),
            emitter.bytecode(),
            &builder.strings,
            &builder.data,
            &builder.wgsl_table,
            &builder.uniform_table,
            &builder.animation_table,
        );

        if (failing_alloc.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            const output = try result;
            failing_alloc.allocator().free(output);
            break;
        }

        fail_index += 1;
    } else {
        unreachable;
    }
}

test "WgslTable serialize and deserialize roundtrip" {
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    // Add modules with dependencies
    // Module 0: no deps
    const id0 = try table.add(testing.allocator, 100, &[_]u16{});
    try testing.expectEqual(@as(u16, 0), id0);

    // Module 1: depends on module 0
    const id1 = try table.add(testing.allocator, 101, &[_]u16{0});
    try testing.expectEqual(@as(u16, 1), id1);

    // Module 2: depends on modules 0 and 1
    const id2 = try table.add(testing.allocator, 102, &[_]u16{ 0, 1 });
    try testing.expectEqual(@as(u16, 2), id2);

    // Module 3: multiple deps
    const id3 = try table.add(testing.allocator, 103, &[_]u16{ 0, 1, 2 });
    try testing.expectEqual(@as(u16, 3), id3);

    // Serialize
    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    // Deserialize
    var restored = try deserializeWgslTable(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    // Verify count
    try testing.expectEqual(@as(u16, 4), restored.count());

    // Verify entries
    const e0 = restored.get(0).?;
    try testing.expectEqual(@as(u16, 100), e0.data_id);
    try testing.expectEqual(@as(usize, 0), e0.deps.len);

    const e1 = restored.get(1).?;
    try testing.expectEqual(@as(u16, 101), e1.data_id);
    try testing.expectEqualSlices(u16, &[_]u16{0}, e1.deps);

    const e2 = restored.get(2).?;
    try testing.expectEqual(@as(u16, 102), e2.data_id);
    try testing.expectEqualSlices(u16, &[_]u16{ 0, 1 }, e2.deps);

    const e3 = restored.get(3).?;
    try testing.expectEqual(@as(u16, 103), e3.data_id);
    try testing.expectEqualSlices(u16, &[_]u16{ 0, 1, 2 }, e3.deps);
}

test "WgslTable empty serialize" {
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    // Empty table: just count = 0 (1 byte varint)
    try testing.expectEqual(@as(usize, 1), bytes.len);
    try testing.expectEqual(@as(u8, 0), bytes[0]);

    // Deserialize empty
    var restored = try deserializeWgslTable(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 0), restored.count());
}

test "full module with WGSL table" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    // Add shader code as data
    const code0 = "// Module 0\nstruct Transform2D {}";
    const code1 = "// Module 1\nfn use_transform() {}";
    const data0 = try builder.addData(testing.allocator, code0);
    const data1 = try builder.addData(testing.allocator, code1);

    // Add WGSL entries
    const wgsl0 = try builder.addWgsl(testing.allocator, data0.toInt(), &[_]u16{});
    const wgsl1 = try builder.addWgsl(testing.allocator, data1.toInt(), &[_]u16{wgsl0});

    // Add bytecode
    const emitter = builder.getEmitter();
    const frame_name = try builder.internString(testing.allocator, "main");
    try emitter.createShaderModule(testing.allocator, 0, wgsl1);
    try emitter.defineFrame(testing.allocator, 0, frame_name.toInt());
    try emitter.endFrame(testing.allocator);

    // Finalize
    const output = try builder.finalize(testing.allocator);
    defer testing.allocator.free(output);

    // Verify header
    try testing.expectEqualStrings("PNGB", output[0..4]);
    const version = std.mem.readInt(u16, output[4..6], .little);
    try testing.expectEqual(@as(u16, VERSION), version);

    // Deserialize
    var module = try deserialize(testing.allocator, output);
    defer module.deinit(testing.allocator);

    // Verify WGSL table
    try testing.expectEqual(@as(u16, 2), module.wgsl.count());

    const e0 = module.wgsl.get(0).?;
    try testing.expectEqual(@as(u16, 0), e0.data_id);
    try testing.expectEqual(@as(usize, 0), e0.deps.len);

    const e1 = module.wgsl.get(1).?;
    try testing.expectEqual(@as(u16, 1), e1.data_id);
    try testing.expectEqualSlices(u16, &[_]u16{0}, e1.deps);

    // Verify data is accessible via WGSL table
    try testing.expectEqualStrings(code0, module.data.get(@enumFromInt(e0.data_id)));
    try testing.expectEqualStrings(code1, module.data.get(@enumFromInt(e1.data_id)));
}

test "deserialize: errdefer cleans up string table on data section failure" {
    // Create a valid PNGB with valid string table but corrupted data section
    // This tests that string table is properly cleaned up when data section fails

    // Build a valid PNGB with normal allocator first
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    _ = try builder.internString(testing.allocator, "test_string");
    _ = try builder.addData(testing.allocator, "test_data");

    const output = try builder.finalize(testing.allocator);
    defer testing.allocator.free(output);

    // Corrupt the data section by making it claim more entries than it has
    // The data section starts at data_section_offset
    const header: *const Header = @ptrCast(@alignCast(output[0..HEADER_SIZE]));
    const data_section_start = header.data_section_offset;

    // Create a copy we can corrupt
    const corrupted = try testing.allocator.dupe(u8, output);
    defer testing.allocator.free(corrupted);

    // Set data section entry count to a large value (but leave actual data short)
    // This will make data_section.deserialize fail after string_table.deserialize succeeds
    corrupted[data_section_start] = 0xFF; // count low byte
    corrupted[data_section_start + 1] = 0xFF; // count high byte (65535 entries)

    // Attempt deserialize - should fail but not leak
    const result = deserialize(testing.allocator, corrupted);
    try testing.expectError(error.InvalidDataSection, result);
}

test "deserialize: errdefer cleans up on WGSL table OOM" {
    // Test that data section is properly cleaned up when WGSL table allocation fails
    // Uses FailingAllocator to trigger OOM at specific allocation points

    // Build a valid PNGB with WGSL entries
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    _ = try builder.internString(testing.allocator, "entry_point");
    const data0 = try builder.addData(testing.allocator, "shader code 0");
    const data1 = try builder.addData(testing.allocator, "shader code 1");
    _ = try builder.addWgsl(testing.allocator, data0.toInt(), &[_]u16{});
    _ = try builder.addWgsl(testing.allocator, data1.toInt(), &[_]u16{0}); // depends on first

    const output = try builder.finalize(testing.allocator);
    defer testing.allocator.free(output);

    // Test with failing allocator at various points
    // We want to fail during WGSL table deserialization (after string table and data section succeed)
    var fail_index: usize = 0;
    const max_iterations: usize = 50;

    var hit_errdefer = false;

    for (0..max_iterations) |_| {
        var failing_alloc = std.testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });

        const result = deserialize(failing_alloc.allocator(), output);

        if (failing_alloc.has_induced_failure) {
            // OOM occurred - check that it was handled properly (no leak)
            try testing.expectError(error.OutOfMemory, result);
            // If we got past a certain point, the errdefer paths were exercised
            if (fail_index >= 3) {
                hit_errdefer = true;
            }
        } else {
            // Success - clean up and stop
            var module = try result;
            module.deinit(failing_alloc.allocator());
            break;
        }

        fail_index += 1;
    }

    // Verify we exercised the errdefer paths
    try testing.expect(hit_errdefer);
}

test "PluginSet bitfield" {
    // Test core_only preset
    const core_only = PluginSet.core_only;
    try testing.expect(core_only.core);
    try testing.expect(!core_only.render);
    try testing.expect(!core_only.compute);
    try testing.expect(!core_only.wasm);
    try testing.expect(!core_only.animation);
    try testing.expect(!core_only.texture);

    // Test full preset
    const full = PluginSet.full;
    try testing.expect(full.core);
    try testing.expect(full.render);
    try testing.expect(full.compute);
    try testing.expect(full.wasm);
    try testing.expect(full.animation);
    try testing.expect(full.texture);

    // Test roundtrip through u8
    const custom = PluginSet{ .render = true, .compute = true };
    const as_byte = custom.toU8();
    const restored = PluginSet.fromU8(as_byte);
    try testing.expect(restored.core);
    try testing.expect(restored.render);
    try testing.expect(restored.compute);
    try testing.expect(!restored.wasm);

    // Test hasPlugin
    try testing.expect(full.hasPlugin(.render));
    try testing.expect(!core_only.hasPlugin(.render));
}

test "v5 format with embedded executor" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    // Build simple module
    const frame_name = try builder.internString(testing.allocator, "main");
    const shader = "@vertex fn vs() {}";
    const shader_data = try builder.addData(testing.allocator, shader);

    const emitter = builder.getEmitter();
    try emitter.createShaderModule(testing.allocator, 0, shader_data.toInt());
    try emitter.defineFrame(testing.allocator, 0, frame_name.toInt());
    try emitter.endFrame(testing.allocator);

    // Fake executor WASM bytes
    const fake_executor = &[_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };

    // Serialize with embedded executor
    const output = try builder.finalizeWithOptions(testing.allocator, .{
        .executor = fake_executor,
        .plugins = .{ .render = true, .compute = true },
    });
    defer testing.allocator.free(output);

    // Verify header
    try testing.expectEqualStrings("PNGB", output[0..4]);
    const version = std.mem.readInt(u16, output[4..6], .little);
    try testing.expectEqual(VERSION, version);

    // Verify flags indicate embedded executor
    const flags: Flags = @bitCast(std.mem.readInt(u16, output[6..8], .little));
    try testing.expect(flags.has_embedded_executor);

    // Verify plugins byte
    const plugins = PluginSet.fromU8(output[8]);
    try testing.expect(plugins.core);
    try testing.expect(plugins.render);
    try testing.expect(plugins.compute);
    try testing.expect(!plugins.wasm);

    // Deserialize
    var module = try deserialize(testing.allocator, output);
    defer module.deinit(testing.allocator);

    // Verify embedded executor was extracted
    try testing.expect(module.hasEmbeddedExecutor());
    try testing.expectEqualSlices(u8, fake_executor, module.executor);

    // Verify plugins preserved
    try testing.expect(module.plugins().render);
    try testing.expect(module.plugins().compute);

    // Verify bytecode still accessible
    const opcodes = @import("opcodes.zig");
    try testing.expectEqual(@as(u8, @intFromEnum(opcodes.OpCode.create_shader_module)), module.bytecode[0]);
}

test "v4 backward compatibility" {
    // Create a v4 format payload manually
    var v4_data: [100]u8 = undefined;
    @memset(&v4_data, 0);

    // Write v4 header (28 bytes)
    @memcpy(v4_data[0..4], MAGIC);
    std.mem.writeInt(u16, v4_data[4..6], VERSION_V4, .little);
    std.mem.writeInt(u16, v4_data[6..8], 0, .little); // flags

    // Section offsets - string_table and data_section use u16 counts (2 bytes each)
    // wgsl_table, uniform_table, animation_table use varint (1 byte for 0)
    const string_off: u32 = HEADER_SIZE_V4;
    const data_off: u32 = string_off + 2; // u16 count for string table = 0
    const wgsl_off: u32 = data_off + 2; // u16 count for data section = 0
    const uniform_off: u32 = wgsl_off + 1; // varint count for wgsl table = 0
    const anim_off: u32 = uniform_off + 1; // varint count for uniform table = 0
    const total_len: u32 = anim_off + 1; // +1 for animation table varint count

    std.mem.writeInt(u32, v4_data[8..12], string_off, .little);
    std.mem.writeInt(u32, v4_data[12..16], data_off, .little);
    std.mem.writeInt(u32, v4_data[16..20], wgsl_off, .little);
    std.mem.writeInt(u32, v4_data[20..24], uniform_off, .little);
    std.mem.writeInt(u32, v4_data[24..28], anim_off, .little);

    // Write empty sections
    std.mem.writeInt(u16, v4_data[string_off..][0..2], 0, .little); // string table: u16 count = 0
    std.mem.writeInt(u16, v4_data[data_off..][0..2], 0, .little); // data section: u16 count = 0
    v4_data[wgsl_off] = 0; // wgsl table: varint count = 0
    v4_data[uniform_off] = 0; // uniform table: varint count = 0
    v4_data[anim_off] = 0; // animation table: varint count = 0

    // Deserialize v4 format
    var module = try deserialize(testing.allocator, v4_data[0..total_len]);
    defer module.deinit(testing.allocator);

    // Verify header was upgraded to v5 internally
    try testing.expectEqual(VERSION, module.header.version);

    // Verify no embedded executor
    try testing.expect(!module.hasEmbeddedExecutor());
    try testing.expectEqual(@as(usize, 0), module.executor.len);

    // Verify plugins default to core only
    try testing.expect(module.plugins().core);
    try testing.expect(!module.plugins().render);
}
