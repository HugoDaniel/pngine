//! Uniform Table for Runtime Reflection
//!
//! Stores metadata about uniform bindings extracted from WGSL shaders via miniray.
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
//!     [type: u8]             // UniformType enum
//!     [_pad: u8]             // Alignment padding
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

/// Uniform field types (matches WGSL types).
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
    /// Byte size of field.
    size: u16,
    /// WGSL type.
    uniform_type: UniformType,
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
    bindings: std.ArrayListUnmanaged(UniformBinding),
    /// Arena for field allocations.
    arena: ?std.heap.ArenaAllocator,

    pub const empty: UniformTable = .{ .bindings = .{}, .arena = null };

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
        var result = std.ArrayListUnmanaged(u8){};
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

            // Fields (10 bytes each: slot + name_string_id + offset + size + type + pad)
            for (binding.fields) |field| {
                // slot (u16 LE)
                try result.appendSlice(allocator, &std.mem.toBytes(field.slot));
                // name_string_id (u16 LE)
                try result.appendSlice(allocator, &std.mem.toBytes(field.name_string_id));
                // offset (u16 LE)
                try result.appendSlice(allocator, &std.mem.toBytes(field.offset));
                // size (u16 LE)
                try result.appendSlice(allocator, &std.mem.toBytes(field.size));
                // type (u8)
                try result.append(allocator, @intFromEnum(field.uniform_type));
                // padding (u8)
                try result.append(allocator, 0);
            }
        }

        return result.toOwnedSlice(allocator);
    }
};

/// Deserialize uniform table from bytes.
pub fn deserialize(allocator: Allocator, data: []const u8) !UniformTable {
    var table = UniformTable{
        .bindings = .{},
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
        if (pos + 8 > data.len) break; // Need at least 8 bytes for binding header

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

        // Read fields (10 bytes each: slot + name_string_id + offset + size + type + pad)
        var fields = try alloc.alloc(UniformField, @min(field_count, MAX_FIELDS));
        var actual_field_count: usize = 0;

        for (0..@min(field_count, MAX_FIELDS)) |i| {
            if (pos + 10 > data.len) break; // Need 10 bytes per field

            fields[i] = .{
                .slot = std.mem.readInt(u16, data[pos..][0..2], .little),
                .name_string_id = std.mem.readInt(u16, data[pos + 2 ..][0..2], .little),
                .offset = std.mem.readInt(u16, data[pos + 4 ..][0..2], .little),
                .size = std.mem.readInt(u16, data[pos + 6 ..][0..2], .little),
                .uniform_type = @enumFromInt(data[pos + 8]),
            };
            pos += 10; // 8 bytes data + 1 type + 1 padding
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

test "UniformType: byte sizes" {
    try testing.expectEqual(@as(u16, 4), UniformType.f32.byteSize());
    try testing.expectEqual(@as(u16, 4), UniformType.i32.byteSize());
    try testing.expectEqual(@as(u16, 4), UniformType.u32.byteSize());
    try testing.expectEqual(@as(u16, 8), UniformType.vec2f.byteSize());
    try testing.expectEqual(@as(u16, 12), UniformType.vec3f.byteSize());
    try testing.expectEqual(@as(u16, 16), UniformType.vec4f.byteSize());
    try testing.expectEqual(@as(u16, 48), UniformType.mat3x3f.byteSize());
    try testing.expectEqual(@as(u16, 64), UniformType.mat4x4f.byteSize());
}

test "UniformType: from WGSL type strings" {
    try testing.expectEqual(UniformType.f32, UniformType.fromWgslType("f32"));
    try testing.expectEqual(UniformType.vec4f, UniformType.fromWgslType("vec4<f32>"));
    try testing.expectEqual(UniformType.vec4f, UniformType.fromWgslType("vec4f"));
    try testing.expectEqual(UniformType.mat4x4f, UniformType.fromWgslType("mat4x4<f32>"));
    try testing.expectEqual(UniformType.unknown, UniformType.fromWgslType("custom_type"));
}

test "UniformTable: empty table" {
    var table = UniformTable.empty;
    defer table.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), table.totalFieldCount());

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    // Empty: just binding_count = 0 (2 bytes)
    try testing.expectEqual(@as(usize, 2), bytes.len);
}

test "UniformTable: add binding with fields" {
    var table = UniformTable.empty;
    defer table.deinit(testing.allocator);

    const fields = [_]UniformField{
        .{ .slot = 0, .name_string_id = 1, .offset = 0, .size = 4, .uniform_type = .f32 },
        .{ .slot = 1, .name_string_id = 2, .offset = 16, .size = 16, .uniform_type = .vec4f },
    };

    try table.addBinding(testing.allocator, 0, 0, 0, 0, &fields);

    try testing.expectEqual(@as(usize, 1), table.bindings.items.len);
    try testing.expectEqual(@as(u32, 2), table.totalFieldCount());
}

test "UniformTable: find field by string ID" {
    var table = UniformTable.empty;
    defer table.deinit(testing.allocator);

    const fields = [_]UniformField{
        .{ .slot = 0, .name_string_id = 10, .offset = 0, .size = 4, .uniform_type = .f32 },
        .{ .slot = 1, .name_string_id = 11, .offset = 16, .size = 16, .uniform_type = .vec4f },
    };

    try table.addBinding(testing.allocator, 5, 0, 0, 0, &fields);

    // Find "time" (string ID 10)
    const result = table.findFieldByStringId(10);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u16, 5), result.?.buffer_id);
    try testing.expectEqual(@as(u16, 0), result.?.offset);
    try testing.expectEqual(@as(u16, 4), result.?.size);
    try testing.expectEqual(UniformType.f32, result.?.uniform_type);

    // Find "color" (string ID 11)
    const result2 = table.findFieldByStringId(11);
    try testing.expect(result2 != null);
    try testing.expectEqual(@as(u16, 16), result2.?.offset);
    try testing.expectEqual(@as(u16, 16), result2.?.size);

    // Not found
    try testing.expect(table.findFieldByStringId(99) == null);
}

test "UniformTable: serialize and deserialize roundtrip" {
    var table = UniformTable.empty;
    defer table.deinit(testing.allocator);

    // Add two bindings
    const fields1 = [_]UniformField{
        .{ .slot = 0, .name_string_id = 1, .offset = 0, .size = 4, .uniform_type = .f32 },
        .{ .slot = 1, .name_string_id = 2, .offset = 4, .size = 4, .uniform_type = .f32 },
        .{ .slot = 2, .name_string_id = 3, .offset = 16, .size = 16, .uniform_type = .vec4f },
    };
    try table.addBinding(testing.allocator, 0, 10, 0, 0, &fields1);

    const fields2 = [_]UniformField{
        .{ .slot = 3, .name_string_id = 4, .offset = 0, .size = 64, .uniform_type = .mat4x4f },
    };
    try table.addBinding(testing.allocator, 1, 11, 0, 1, &fields2);

    // Serialize
    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    // Deserialize
    var restored = try deserialize(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    // Verify binding count
    try testing.expectEqual(@as(usize, 2), restored.bindings.items.len);

    // Verify first binding
    const b0 = restored.bindings.items[0];
    try testing.expectEqual(@as(u16, 0), b0.buffer_id);
    try testing.expectEqual(@as(u16, 10), b0.name_string_id);
    try testing.expectEqual(@as(u8, 0), b0.group);
    try testing.expectEqual(@as(u8, 0), b0.binding_index);
    try testing.expectEqual(@as(usize, 3), b0.fields.len);

    // Verify first binding fields (including slot)
    try testing.expectEqual(@as(u16, 0), b0.fields[0].slot);
    try testing.expectEqual(@as(u16, 1), b0.fields[0].name_string_id);
    try testing.expectEqual(@as(u16, 0), b0.fields[0].offset);
    try testing.expectEqual(UniformType.f32, b0.fields[0].uniform_type);

    try testing.expectEqual(@as(u16, 2), b0.fields[2].slot);
    try testing.expectEqual(@as(u16, 3), b0.fields[2].name_string_id);
    try testing.expectEqual(@as(u16, 16), b0.fields[2].offset);
    try testing.expectEqual(UniformType.vec4f, b0.fields[2].uniform_type);

    // Verify second binding (including slot)
    const b1 = restored.bindings.items[1];
    try testing.expectEqual(@as(u16, 1), b1.buffer_id);
    try testing.expectEqual(@as(usize, 1), b1.fields.len);
    try testing.expectEqual(@as(u16, 3), b1.fields[0].slot);
    try testing.expectEqual(UniformType.mat4x4f, b1.fields[0].uniform_type);

    // Test field lookup on restored table
    const found = restored.findFieldByStringId(3);
    try testing.expect(found != null);
    try testing.expectEqual(@as(u16, 0), found.?.buffer_id);
    try testing.expectEqual(@as(u16, 16), found.?.offset);
}

test "UniformTable: get field by index" {
    var table = UniformTable.empty;
    defer table.deinit(testing.allocator);

    const fields1 = [_]UniformField{
        .{ .slot = 0, .name_string_id = 1, .offset = 0, .size = 4, .uniform_type = .f32 },
        .{ .slot = 1, .name_string_id = 2, .offset = 4, .size = 4, .uniform_type = .i32 },
    };
    try table.addBinding(testing.allocator, 0, 10, 0, 0, &fields1);

    const fields2 = [_]UniformField{
        .{ .slot = 2, .name_string_id = 3, .offset = 0, .size = 64, .uniform_type = .mat4x4f },
    };
    try table.addBinding(testing.allocator, 1, 11, 0, 1, &fields2);

    // Total: 3 fields
    try testing.expectEqual(@as(u32, 3), table.totalFieldCount());

    // Index 0: first field of first binding
    const f0 = table.getFieldByIndex(0);
    try testing.expect(f0 != null);
    try testing.expectEqual(@as(u16, 1), f0.?.field.name_string_id);

    // Index 1: second field of first binding
    const f1 = table.getFieldByIndex(1);
    try testing.expect(f1 != null);
    try testing.expectEqual(@as(u16, 2), f1.?.field.name_string_id);

    // Index 2: first field of second binding
    const f2 = table.getFieldByIndex(2);
    try testing.expect(f2 != null);
    try testing.expectEqual(@as(u16, 3), f2.?.field.name_string_id);
    try testing.expectEqual(@as(u16, 1), f2.?.binding.buffer_id);

    // Index 3: out of bounds
    try testing.expect(table.getFieldByIndex(3) == null);
}

test "UniformTable: OOM handling" {
    var fail_index: usize = 0;
    const max_iterations: usize = 50;

    for (0..max_iterations) |_| {
        var failing_alloc = std.testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        const alloc = failing_alloc.allocator();

        var table = UniformTable.empty;
        defer table.deinit(alloc);

        const fields = [_]UniformField{
            .{ .slot = 0, .name_string_id = 1, .offset = 0, .size = 4, .uniform_type = .f32 },
        };

        const result = table.addBinding(alloc, 0, 0, 0, 0, &fields);
        if (result) |_| {
            // Success - test complete
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
        }

        fail_index += 1;
    } else {
        unreachable;
    }
}

test "UniformTable: multiple bindings different groups" {
    var table = UniformTable.empty;
    defer table.deinit(testing.allocator);

    // Group 0
    const fields0 = [_]UniformField{
        .{ .slot = 0, .name_string_id = 1, .offset = 0, .size = 4, .uniform_type = .f32 },
    };
    try table.addBinding(testing.allocator, 0, 10, 0, 0, &fields0);

    // Group 1
    const fields1 = [_]UniformField{
        .{ .slot = 1, .name_string_id = 2, .offset = 0, .size = 16, .uniform_type = .vec4f },
    };
    try table.addBinding(testing.allocator, 1, 11, 1, 0, &fields1);

    // Group 2
    const fields2 = [_]UniformField{
        .{ .slot = 2, .name_string_id = 3, .offset = 0, .size = 64, .uniform_type = .mat4x4f },
    };
    try table.addBinding(testing.allocator, 2, 12, 2, 0, &fields2);

    // Serialize and roundtrip
    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var restored = try deserialize(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    // Verify groups
    try testing.expectEqual(@as(u8, 0), restored.bindings.items[0].group);
    try testing.expectEqual(@as(u8, 1), restored.bindings.items[1].group);
    try testing.expectEqual(@as(u8, 2), restored.bindings.items[2].group);
}
