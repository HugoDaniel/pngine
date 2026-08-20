//! Uniform Table for Runtime Reflection
//!
//! Stores metadata about uniform bindings extracted from WGSL shaders via wgslender.
//! Enables runtime uniform setting by field name without recompilation.
//!
//! ## Format (serialized)
//!
//! ```
//! [binding_count: u16]
//! For each binding:
//!   [buffer_id: u16]         // GPU buffer this binding maps to
//!   [name_string_id: u16]    // Binding var name in string table
//!   [group: u8]              // @group(n)
//!   [binding_index: u8]      // @binding(n)
//!   [field_count: u16]
//!   For each field:
//!     [slot: u16]            // Compile-time slot index (sorted by name)
//!     [name_string_id: u16]  // Field name in string table (may have dots)
//!     [offset: u16]          // Byte offset in buffer (absolute)
//!     [size: u16]            // Byte size
//!     [type: u8]             // UniformType enum (an array's ELEMENT type)
//!     [elem_count: u8]       // Fixed array element count; 0 = not an array
//!                            // (was alignment padding — old payloads carry 0)
//! ```
//!
//! ## Invariants
//!
//! - Field offsets are WGSL-compliant (16-byte aligned for vec4, etc.)
//! - All string IDs reference valid entries in string table
//! - Buffer IDs reference valid buffers created by bytecode
//! - Maximum 256 bindings, 64 fields per binding

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// Maximum bindings per module (practical limit).
pub const MAX_BINDINGS: u16 = 256;

/// Maximum fields per binding.
pub const MAX_FIELDS: u16 = 64;

// ── Serialized layout (little-endian) ───────────────────────────────────────
// Named strides shared by serialize() and deserialize() so the two sides can
// never drift. A binding header precedes its field records; each field record
// is FIELD_BYTES wide with members at the byte offsets below.

/// Bytes in a per-binding header: buffer_id(2) + name_string_id(2) + group(1)
/// + binding_index(1) + field_count(2).
const BINDING_HEADER_BYTES: usize = 8;
/// Bytes in one serialized field record (data + type + elem_count).
const FIELD_BYTES: usize = 10;
const FIELD_OFF_SLOT: usize = 0;
const FIELD_OFF_NAME: usize = 2;
const FIELD_OFF_OFFSET: usize = 4;
const FIELD_OFF_SIZE: usize = 6;
const FIELD_OFF_TYPE: usize = 8;
/// Byte 9 was alignment padding (always written 0) until array reflection
/// landed; it now carries the fixed-array element count. Old payloads read as
/// elem_count 0 = "not an array", old readers skip the byte — compatible in
/// both directions with no version bump.
const FIELD_OFF_ELEM_COUNT: usize = 9;
comptime {
    assert(FIELD_OFF_NAME == FIELD_OFF_SLOT + 2);
    assert(FIELD_OFF_OFFSET == FIELD_OFF_NAME + 2);
    assert(FIELD_OFF_SIZE == FIELD_OFF_OFFSET + 2);
    assert(FIELD_OFF_TYPE == FIELD_OFF_SIZE + 2);
    assert(FIELD_OFF_ELEM_COUNT == FIELD_OFF_TYPE + 1);
    assert(FIELD_BYTES == FIELD_OFF_ELEM_COUNT + 1);
}

/// Uniform field types (matches WGSL types).
// ⚠️ Downstream coupling: pstudio's visual bus maps these tags to pacer lane
// counts (`editor/src/lib/preview/registries.ts` LANES_BY_TYPE, in
// git.hugodaniel.com/hugo/pstudio.git) — an array field whose tag it doesn't
// know silently DROPS there. Adding a tag here means teaching that map (or
// deliberately classifying the tag as undrivable). No build edge crosses the
// repo boundary; tests/npm/uniform-type-lanes.test.js gates this side of it.
pub const UniformType = enum(u8) {
    f32 = 0,
    i32 = 1,
    u32 = 2,
    vec2f = 3,
    vec3f = 4,
    vec4f = 5,
    mat3x3f = 6, // 48 bytes (3 vec4 columns with padding)
    mat4x4f = 7, // 64 bytes
    vec2i = 8,
    vec3i = 9,
    vec4i = 10,
    vec2u = 11,
    vec3u = 12,
    vec4u = 13,
    unknown = 255,

    /// Get byte size for this type.
    pub fn byteSize(self: UniformType) u16 {
        return switch (self) {
            .f32, .i32, .u32 => 4,
            .vec2f, .vec2i, .vec2u => 8,
            .vec3f, .vec3i, .vec3u => 12,
            .vec4f, .vec4i, .vec4u => 16,
            .mat3x3f => 48, // 3 vec4 columns
            .mat4x4f => 64,
            .unknown => 0,
        };
    }

    /// Parse WGSL type string to UniformType.
    /// Complexity: O(1) via StaticStringMap.
    pub fn fromWgslType(type_str: []const u8) UniformType {
        const map = std.StaticStringMap(UniformType).initComptime(.{
            .{ "f32", .f32 },
            .{ "i32", .i32 },
            .{ "u32", .u32 },
            .{ "vec2<f32>", .vec2f },
            .{ "vec2f", .vec2f },
            .{ "vec3<f32>", .vec3f },
            .{ "vec3f", .vec3f },
            .{ "vec4<f32>", .vec4f },
            .{ "vec4f", .vec4f },
            .{ "mat3x3<f32>", .mat3x3f },
            .{ "mat3x3f", .mat3x3f },
            .{ "mat4x4<f32>", .mat4x4f },
            .{ "mat4x4f", .mat4x4f },
            .{ "vec2<i32>", .vec2i },
            .{ "vec2i", .vec2i },
            .{ "vec3<i32>", .vec3i },
            .{ "vec3i", .vec3i },
            .{ "vec4<i32>", .vec4i },
            .{ "vec4i", .vec4i },
            .{ "vec2<u32>", .vec2u },
            .{ "vec2u", .vec2u },
            .{ "vec3<u32>", .vec3u },
            .{ "vec3u", .vec3u },
            .{ "vec4<u32>", .vec4u },
            .{ "vec4u", .vec4u },
        });
        return map.get(type_str) orelse .unknown;
    }
};

/// A uniform field within a binding.
/// Fields are flattened at compile time - nested structs become dot-notation paths.
/// Example: "position.x" for struct field access.
pub const UniformField = struct {
    /// Compile-time assigned slot index for O(1) runtime lookup.
    /// Slots are assigned in sorted order by field name for stability.
    slot: u16,
    /// Field name string ID (may contain dots for nested fields).
    name_string_id: u16,
    /// Byte offset from buffer start (absolute, after flattening).
    offset: u16,
    /// Byte size of field (an array's TOTAL bytes including element stride).
    size: u16,
    /// WGSL type. For a fixed-size array field this is the ELEMENT type
    /// (`array<vec4f, N>` → .vec4f) — `elem_count` marks it as an array.
    uniform_type: UniformType,
    /// Fixed array element count (1..255); 0 = not an array (or an array
    /// whose count is unrepresentable: runtime-sized or > 255).
    elem_count: u8 = 0,
};

/// A uniform binding (maps to a GPU buffer).
pub const UniformBinding = struct {
    /// GPU buffer ID this binding writes to.
    buffer_id: u16,
    /// Binding variable name string ID.
    name_string_id: u16,
    /// Bind group index (0-3).
    group: u8,
    /// Binding index within group.
    binding_index: u8,
    /// Fields within this binding.
    fields: []const UniformField,
};

/// Uniform table for runtime reflection.
pub const UniformTable = struct {
    bindings: std.ArrayList(UniformBinding),
    /// Arena for field allocations.
    arena: ?std.heap.ArenaAllocator,

    pub const empty: UniformTable = .{ .bindings = .empty, .arena = null };

    pub fn deinit(self: *UniformTable, allocator: Allocator) void {
        // Free field slices if we have an arena
        if (self.arena) |*arena| {
            arena.deinit();
        } else {
            // Manual cleanup (for bindings added via addBinding)
            for (self.bindings.items) |binding| {
                if (binding.fields.len > 0) {
                    allocator.free(binding.fields);
                }
            }
        }
        self.bindings.deinit(allocator);
        self.* = undefined;
    }

    /// Add a binding with fields.
    /// Pre-condition: fields slice is copied, caller retains ownership of original.
    pub fn addBinding(
        self: *UniformTable,
        allocator: Allocator,
        buffer_id: u16,
        name_string_id: u16,
        group: u8,
        binding_index: u8,
        fields: []const UniformField,
    ) !void {
        // Pre-conditions
        assert(self.bindings.items.len < MAX_BINDINGS);
        assert(fields.len <= MAX_FIELDS);
        assert(group <= 3); // WebGPU limit

        const fields_copy = if (fields.len > 0)
            try allocator.dupe(UniformField, fields)
        else
            &[_]UniformField{};
        errdefer if (fields.len > 0) allocator.free(fields_copy);

        try self.bindings.append(allocator, .{
            .buffer_id = buffer_id,
            .name_string_id = name_string_id,
            .group = group,
            .binding_index = binding_index,
            .fields = fields_copy,
        });
    }

    /// Find a field by name string ID.
    /// Returns buffer_id, offset, size, type.
    /// Complexity: O(bindings * fields), bounded by MAX_BINDINGS * MAX_FIELDS.
    pub fn findFieldByStringId(self: *const UniformTable, field_name_id: u16) ?struct {
        buffer_id: u16,
        offset: u16,
        size: u16,
        uniform_type: UniformType,
    } {
        for (self.bindings.items) |binding| {
            for (binding.fields) |field| {
                if (field.name_string_id == field_name_id) {
                    return .{
                        .buffer_id = binding.buffer_id,
                        .offset = field.offset,
                        .size = field.size,
                        .uniform_type = field.uniform_type,
                    };
                }
            }
        }
        return null;
    }

    /// Get total field count across all bindings.
    pub fn totalFieldCount(self: *const UniformTable) u32 {
        var count: u32 = 0;
        for (self.bindings.items) |binding| {
            count += @intCast(binding.fields.len);
        }
        return count;
    }

    /// Get field by flat index (for enumeration).
    /// Returns null if index out of bounds.
    pub fn getFieldByIndex(self: *const UniformTable, index: u32) ?struct {
        binding: *const UniformBinding,
        field: *const UniformField,
    } {
        var current: u32 = 0;
        for (self.bindings.items) |*binding| {
            for (binding.fields) |*field| {
                if (current == index) {
                    return .{ .binding = binding, .field = field };
                }
                current += 1;
            }
        }
        return null;
    }

    /// Serialize uniform table to bytes.
    pub fn serialize(self: *const UniformTable, allocator: Allocator) ![]u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        // Binding count (u16 LE)
        const binding_count: u16 = @intCast(self.bindings.items.len);
        try result.appendSlice(allocator, &std.mem.toBytes(binding_count));

        // Each binding
        for (self.bindings.items) |binding| {
            // buffer_id (u16 LE)
            try result.appendSlice(allocator, &std.mem.toBytes(binding.buffer_id));
            // name_string_id (u16 LE)
            try result.appendSlice(allocator, &std.mem.toBytes(binding.name_string_id));
            // group (u8)
            try result.append(allocator, binding.group);
            // binding_index (u8)
            try result.append(allocator, binding.binding_index);
            // field_count (u16 LE)
            const field_count: u16 = @intCast(binding.fields.len);
            try result.appendSlice(allocator, &std.mem.toBytes(field_count));

            // Fields (FIELD_BYTES each). Write into a fixed record addressed by
            // the same offset constants the reader uses — read/write can't drift.
            for (binding.fields) |field| {
                var rec = [_]u8{0} ** FIELD_BYTES;
                std.mem.writeInt(u16, rec[FIELD_OFF_SLOT..][0..2], field.slot, .little);
                std.mem.writeInt(u16, rec[FIELD_OFF_NAME..][0..2], field.name_string_id, .little);
                std.mem.writeInt(u16, rec[FIELD_OFF_OFFSET..][0..2], field.offset, .little);
                std.mem.writeInt(u16, rec[FIELD_OFF_SIZE..][0..2], field.size, .little);
                rec[FIELD_OFF_TYPE] = @intFromEnum(field.uniform_type);
                rec[FIELD_OFF_ELEM_COUNT] = field.elem_count;
                try result.appendSlice(allocator, &rec);
            }
        }

        return result.toOwnedSlice(allocator);
    }
};

/// Deserialize uniform table from bytes.
pub fn deserialize(allocator: Allocator, data: []const u8) !UniformTable {
    var table = UniformTable{
        .bindings = .empty,
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    errdefer {
        if (table.arena) |*arena| arena.deinit();
        table.bindings.deinit(allocator);
    }

    const alloc = table.arena.?.allocator();

    if (data.len < 2) {
        // Empty table
        return table;
    }

    var pos: usize = 0;

    // Read binding count
    const binding_count = std.mem.readInt(u16, data[pos..][0..2], .little);
    pos += 2;

    // Pre-allocate
    try table.bindings.ensureTotalCapacity(allocator, @min(binding_count, MAX_BINDINGS));

    // Read bindings
    for (0..@min(binding_count, MAX_BINDINGS)) |_| {
        if (pos + BINDING_HEADER_BYTES > data.len) break; // binding header

        const buffer_id = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;
        const name_string_id = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;
        const group = data[pos];
        pos += 1;
        const binding_index = data[pos];
        pos += 1;
        const field_count = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;

        // Read fields (FIELD_BYTES each) at the shared record offsets.
        var fields = try alloc.alloc(UniformField, @min(field_count, MAX_FIELDS));
        var actual_field_count: usize = 0;

        for (0..@min(field_count, MAX_FIELDS)) |i| {
            if (pos + FIELD_BYTES > data.len) break; // one field record

            fields[i] = .{
                .slot = std.mem.readInt(u16, data[pos + FIELD_OFF_SLOT ..][0..2], .little),
                .name_string_id = std.mem.readInt(u16, data[pos + FIELD_OFF_NAME ..][0..2], .little),
                .offset = std.mem.readInt(u16, data[pos + FIELD_OFF_OFFSET ..][0..2], .little),
                .size = std.mem.readInt(u16, data[pos + FIELD_OFF_SIZE ..][0..2], .little),
                // A byte that names no `UniformType` (a newer tag, or a hostile
                // file) is the enum's own `.unknown`, which every consumer
                // already skips — never `@enumFromInt` into an exhaustive enum,
                // which is a Debug panic and release UB in every later switch.
                .uniform_type = std.enums.fromInt(UniformType, data[pos + FIELD_OFF_TYPE]) orelse .unknown,
                .elem_count = data[pos + FIELD_OFF_ELEM_COUNT],
            };
            pos += FIELD_BYTES;
            actual_field_count += 1;
        }

        table.bindings.appendAssumeCapacity(.{
            .buffer_id = buffer_id,
            .name_string_id = name_string_id,
            .group = group,
            .binding_index = binding_index,
            .fields = fields[0..actual_field_count],
        });
    }

    return table;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
