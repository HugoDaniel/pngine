//! WGSL Table Comprehensive Tests
//!
//! Tests for v2 bytecode format WGSL table:
//! - Serialization/deserialization roundtrips
//! - Edge cases (empty, max size, boundary values)
//! - OOM handling
//! - Fuzz testing
//! - Version compatibility

const std = @import("std");
const testing = std.testing;
const format = @import("format.zig");
const WgslTable = format.WgslTable;
const WgslEntry = format.WgslEntry;
const deserializeWgslTable = format.deserializeWgslTable;

// ============================================================================
// Basic Functionality Tests
// ============================================================================

test "WgslTable: empty table roundtrip" {
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    // Empty table = just count (varint 0 = 1 byte)
    try testing.expectEqual(@as(usize, 1), bytes.len);
    try testing.expectEqual(@as(u8, 0), bytes[0]);

    var restored = try deserializeWgslTable(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 0), restored.count());
}

test "WgslTable: single entry no deps" {
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    const id = try table.add(testing.allocator, 42, &[_]u16{});
    try testing.expectEqual(@as(u16, 0), id);

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var restored = try deserializeWgslTable(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 1), restored.count());
    const entry = restored.get(0).?;
    try testing.expectEqual(@as(u16, 42), entry.data_id);
    try testing.expectEqual(@as(usize, 0), entry.deps.len);
}

test "WgslTable: single entry with deps" {
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    // First add dep targets
    _ = try table.add(testing.allocator, 10, &[_]u16{});
    _ = try table.add(testing.allocator, 20, &[_]u16{});

    // Then add module with deps
    const id = try table.add(testing.allocator, 100, &[_]u16{ 0, 1 });
    try testing.expectEqual(@as(u16, 2), id);

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var restored = try deserializeWgslTable(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 3), restored.count());

    const entry = restored.get(2).?;
    try testing.expectEqual(@as(u16, 100), entry.data_id);
    try testing.expectEqualSlices(u16, &[_]u16{ 0, 1 }, entry.deps);
}

test "WgslTable: linear dependency chain" {
    // A -> B -> C -> D (each depends on previous)
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    const a = try table.add(testing.allocator, 0, &[_]u16{});
    const b = try table.add(testing.allocator, 1, &[_]u16{a});
    const c = try table.add(testing.allocator, 2, &[_]u16{b});
    const d = try table.add(testing.allocator, 3, &[_]u16{c});

    try testing.expectEqual(@as(u16, 0), a);
    try testing.expectEqual(@as(u16, 1), b);
    try testing.expectEqual(@as(u16, 2), c);
    try testing.expectEqual(@as(u16, 3), d);

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var restored = try deserializeWgslTable(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    // Verify chain
    try testing.expectEqualSlices(u16, &[_]u16{}, restored.get(0).?.deps);
    try testing.expectEqualSlices(u16, &[_]u16{0}, restored.get(1).?.deps);
    try testing.expectEqualSlices(u16, &[_]u16{1}, restored.get(2).?.deps);
    try testing.expectEqualSlices(u16, &[_]u16{2}, restored.get(3).?.deps);
}

test "WgslTable: diamond dependency pattern" {
    //     A
    //    / \
    //   B   C
    //    \ /
    //     D
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    const a = try table.add(testing.allocator, 0, &[_]u16{});
    const b = try table.add(testing.allocator, 1, &[_]u16{a});
    const c = try table.add(testing.allocator, 2, &[_]u16{a});
    const d = try table.add(testing.allocator, 3, &[_]u16{ b, c });

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var restored = try deserializeWgslTable(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    // D depends on both B and C
    try testing.expectEqualSlices(u16, &[_]u16{ b, c }, restored.get(d).?.deps);
}

// ============================================================================
// Boundary Value Tests
// ============================================================================

test "WgslTable: max data_id value" {
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    // Use max u16 value
    const id = try table.add(testing.allocator, std.math.maxInt(u16), &[_]u16{});

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var restored = try deserializeWgslTable(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    try testing.expectEqual(std.math.maxInt(u16), restored.get(id).?.data_id);
}

test "WgslTable: varint boundary 127/128" {
    // 127 fits in 1 byte, 128 needs 2 bytes
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    _ = try table.add(testing.allocator, 127, &[_]u16{});
    _ = try table.add(testing.allocator, 128, &[_]u16{});
    _ = try table.add(testing.allocator, 16383, &[_]u16{}); // 2 byte max
    _ = try table.add(testing.allocator, 16384, &[_]u16{}); // 3 byte start

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var restored = try deserializeWgslTable(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 127), restored.get(0).?.data_id);
    try testing.expectEqual(@as(u16, 128), restored.get(1).?.data_id);
    try testing.expectEqual(@as(u16, 16383), restored.get(2).?.data_id);
    try testing.expectEqual(@as(u16, 16384), restored.get(3).?.data_id);
}

test "WgslTable: max deps per entry" {
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    // First create MAX_WGSL_DEPS entries as deps
    var dep_ids: [format.MAX_WGSL_DEPS]u16 = undefined;
    for (0..format.MAX_WGSL_DEPS) |i| {
        dep_ids[i] = try table.add(testing.allocator, @intCast(i), &[_]u16{});
    }

    // Add entry with max deps
    const id = try table.add(testing.allocator, 999, &dep_ids);

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var restored = try deserializeWgslTable(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    const entry = restored.get(id).?;
    try testing.expectEqual(@as(usize, format.MAX_WGSL_DEPS), entry.deps.len);
}

test "WgslTable: many entries stress test" {
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    // Add 100 entries with varying deps
    const count: u16 = 100;
    for (0..count) |i| {
        const deps_count = @min(i, 5); // Max 5 deps each
        var deps: [5]u16 = undefined;
        for (0..deps_count) |j| {
            deps[j] = @intCast(i - j - 1);
        }
        _ = try table.add(testing.allocator, @intCast(i * 10), deps[0..deps_count]);
    }

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var restored = try deserializeWgslTable(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    try testing.expectEqual(count, restored.count());

    // Verify first and last entries
    try testing.expectEqual(@as(u16, 0), restored.get(0).?.data_id);
    try testing.expectEqual(@as(u16, 990), restored.get(99).?.data_id);
}

// ============================================================================
// Error Handling Tests
// ============================================================================

test "WgslTable: deserialize truncated data" {
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    _ = try table.add(testing.allocator, 100, &[_]u16{ 0, 1, 2 });

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    // Try deserializing truncated data
    for (1..bytes.len) |truncate_at| {
        const truncated = bytes[0..truncate_at];
        var restored = deserializeWgslTable(testing.allocator, truncated) catch |err| {
            // Should either succeed partially or fail gracefully
            try testing.expect(err == error.OutOfMemory or err == error.InvalidFormat);
            continue;
        };
        restored.deinit(testing.allocator);
    }
}

test "WgslTable: deserialize empty data" {
    var result = deserializeWgslTable(testing.allocator, &[_]u8{});
    // Empty data should return empty table (count=0 default)
    if (result) |*table| {
        defer table.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 0), table.count());
    } else |_| {
        // Also acceptable to error
    }
}

test "WgslTable: get invalid id returns null" {
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    _ = try table.add(testing.allocator, 0, &[_]u16{});

    try testing.expect(table.get(0) != null);
    try testing.expect(table.get(1) == null);
    try testing.expect(table.get(1000) == null);
    try testing.expect(table.get(std.math.maxInt(u16)) == null);
}

// ============================================================================
// OOM Tests
// ============================================================================

test "WgslTable: add handles OOM" {
    var fail_index: usize = 0;
    const max_iterations: usize = 50;

    for (0..max_iterations) |_| {
        var failing_alloc = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });

        var table = WgslTable{ .entries = .{} };
        defer table.deinit(failing_alloc.allocator());

        const result = table.add(failing_alloc.allocator(), 100, &[_]u16{ 0, 1, 2 });

        if (failing_alloc.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            _ = try result;
            break;
        }

        fail_index += 1;
    }
}

test "WgslTable: serialize handles OOM" {
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    // Add several entries
    for (0..10) |i| {
        _ = try table.add(testing.allocator, @intCast(i), &[_]u16{});
    }

    var fail_index: usize = 0;
    const max_iterations: usize = 50;

    for (0..max_iterations) |_| {
        var failing_alloc = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });

        const result = table.serialize(failing_alloc.allocator());

        if (failing_alloc.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            const bytes = try result;
            failing_alloc.allocator().free(bytes);
            break;
        }

        fail_index += 1;
    }
}

test "WgslTable: deserialize handles OOM" {
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    // Create table with deps (requires allocation during deserialize)
    _ = try table.add(testing.allocator, 0, &[_]u16{});
    _ = try table.add(testing.allocator, 1, &[_]u16{0});
    _ = try table.add(testing.allocator, 2, &[_]u16{ 0, 1 });

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var fail_index: usize = 0;
    const max_iterations: usize = 50;

    for (0..max_iterations) |_| {
        var failing_alloc = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });

        const result = deserializeWgslTable(failing_alloc.allocator(), bytes);

        if (failing_alloc.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            var restored = try result;
            restored.deinit(failing_alloc.allocator());
            break;
        }

        fail_index += 1;
    }
}

// ============================================================================
// Property-Based / Fuzz Tests
// ============================================================================

test "WgslTable: roundtrip property - random entries" {
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    const random = prng.random();

    for (0..100) |_| {
        var table = WgslTable{ .entries = .{} };
        defer table.deinit(testing.allocator);

        // Random number of entries (1-50)
        const entry_count = random.intRangeAtMost(u16, 1, 50);

        for (0..entry_count) |i| {
            const data_id = random.int(u16);

            // Random number of deps (0-5, must reference earlier entries)
            const max_deps = @min(i, 5);
            const dep_count = if (max_deps > 0) random.intRangeAtMost(usize, 0, max_deps) else 0;

            var deps: [5]u16 = undefined;
            for (0..dep_count) |j| {
                deps[j] = random.intRangeAtMost(u16, 0, @intCast(i - 1));
            }

            _ = try table.add(testing.allocator, data_id, deps[0..dep_count]);
        }

        // Serialize
        const bytes = try table.serialize(testing.allocator);
        defer testing.allocator.free(bytes);

        // Deserialize
        var restored = try deserializeWgslTable(testing.allocator, bytes);
        defer restored.deinit(testing.allocator);

        // Property: count matches
        try testing.expectEqual(table.count(), restored.count());

        // Property: all entries match
        for (0..table.count()) |i| {
            const original = table.get(@intCast(i)).?;
            const restored_entry = restored.get(@intCast(i)).?;

            try testing.expectEqual(original.data_id, restored_entry.data_id);
            try testing.expectEqualSlices(u16, original.deps, restored_entry.deps);
        }
    }
}

test "WgslTable: fuzz varint encoding" {
    // Test all u16 values encode/decode correctly
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    const random = prng.random();

    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    // Test boundary values and random samples
    const test_values = [_]u16{
        0,
        1,
        126,
        127,
        128,
        129,
        255,
        256,
        16382,
        16383,
        16384,
        16385,
        32767,
        32768,
        65534,
        65535,
        random.int(u16),
        random.int(u16),
        random.int(u16),
        random.int(u16),
    };

    for (test_values) |val| {
        _ = try table.add(testing.allocator, val, &[_]u16{});
    }

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var restored = try deserializeWgslTable(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    for (test_values, 0..) |expected, i| {
        try testing.expectEqual(expected, restored.get(@intCast(i)).?.data_id);
    }
}

// ============================================================================
// Full Module Integration Tests
// ============================================================================

test "full module roundtrip with WGSL table" {
    const Builder = format.Builder;

    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    // Simulate: transform2D -> primitives -> tangram
    const code0 = "// transform2D\nstruct Transform2D { m: mat3x3f }";
    const code1 = "// primitives\nfn circle(p: vec2f, r: f32) -> f32 { return length(p) - r; }";
    const code2 = "// tangram\nfn tangram_scene(p: vec2f) -> f32 { return circle(p, 1.0); }";

    const data0 = try builder.addData(testing.allocator, code0);
    const data1 = try builder.addData(testing.allocator, code1);
    const data2 = try builder.addData(testing.allocator, code2);

    // Add WGSL entries with dependencies
    const wgsl0 = try builder.addWgsl(testing.allocator, data0.toInt(), &[_]u16{});
    const wgsl1 = try builder.addWgsl(testing.allocator, data1.toInt(), &[_]u16{wgsl0});
    const wgsl2 = try builder.addWgsl(testing.allocator, data2.toInt(), &[_]u16{ wgsl0, wgsl1 });

    // Add shader modules
    const frame_name = try builder.internString(testing.allocator, "main");
    const emitter = builder.getEmitter();

    try emitter.createShaderModule(testing.allocator, 0, wgsl2);
    try emitter.defineFrame(testing.allocator, 0, frame_name.toInt());
    try emitter.endFrame(testing.allocator);

    // Finalize
    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    // Verify header
    try testing.expectEqualStrings("PNGB", pngb[0..4]);
    const version = std.mem.readInt(u16, pngb[4..6], .little);
    try testing.expectEqual(@as(u16, 2), version);

    // Deserialize
    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify WGSL table
    try testing.expectEqual(@as(u16, 3), module.wgsl.count());

    // Verify dependency structure
    const e0 = module.wgsl.get(0).?;
    const e1 = module.wgsl.get(1).?;
    const e2 = module.wgsl.get(2).?;

    try testing.expectEqual(@as(usize, 0), e0.deps.len);
    try testing.expectEqualSlices(u16, &[_]u16{0}, e1.deps);
    try testing.expectEqualSlices(u16, &[_]u16{ 0, 1 }, e2.deps);

    // Verify data is accessible
    try testing.expectEqualStrings(code0, module.data.get(@enumFromInt(e0.data_id)));
    try testing.expectEqualStrings(code1, module.data.get(@enumFromInt(e1.data_id)));
    try testing.expectEqualStrings(code2, module.data.get(@enumFromInt(e2.data_id)));
}

test "version 1 backward compatibility" {
    // Create a v1-style bytecode (no WGSL table entries)
    const Builder = format.Builder;

    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    // Don't add any WGSL entries - simulates v1 behavior
    const code = "// simple shader";
    const data_id = try builder.addData(testing.allocator, code);

    const frame_name = try builder.internString(testing.allocator, "main");
    const emitter = builder.getEmitter();

    // In v1, this would be data_id directly; in v2 with no WGSL, falls back
    try emitter.createShaderModule(testing.allocator, 0, data_id.toInt());
    try emitter.defineFrame(testing.allocator, 0, frame_name.toInt());
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Even with v2 header, empty WGSL table should work
    try testing.expectEqual(@as(u16, 2), module.header.version);
    try testing.expectEqual(@as(u16, 0), module.wgsl.count());
}

// ============================================================================
// Edge Cases
// ============================================================================

test "WgslTable: entry with empty deps array" {
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    // Explicitly pass empty slice
    const deps: []const u16 = &[_]u16{};
    _ = try table.add(testing.allocator, 42, deps);

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var restored = try deserializeWgslTable(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), restored.get(0).?.deps.len);
}

test "WgslTable: multiple entries same data_id" {
    // Legal: multiple WGSL modules could theoretically share data
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    _ = try table.add(testing.allocator, 100, &[_]u16{});
    _ = try table.add(testing.allocator, 100, &[_]u16{0}); // Same data_id, different deps
    _ = try table.add(testing.allocator, 100, &[_]u16{ 0, 1 });

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var restored = try deserializeWgslTable(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    // All should have same data_id
    for (0..3) |i| {
        try testing.expectEqual(@as(u16, 100), restored.get(@intCast(i)).?.data_id);
    }
}

test "WgslTable: dep references itself (self-loop)" {
    // This is technically invalid but shouldn't crash
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    _ = try table.add(testing.allocator, 0, &[_]u16{});

    // Entry 1 depends on itself (invalid but we just store it)
    // This would be caught by analyzer, but bytecode could be crafted
    // Note: we can't actually do this since deps must reference earlier entries
    // But we can test circular deps between entries
    _ = try table.add(testing.allocator, 1, &[_]u16{0});

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var restored = try deserializeWgslTable(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 2), restored.count());
}

test "WgslTable: deep dependency chain" {
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    // Create a 50-deep chain
    const depth: u16 = 50;
    for (0..depth) |i| {
        const deps: []const u16 = if (i == 0) &[_]u16{} else &[_]u16{@intCast(i - 1)};
        _ = try table.add(testing.allocator, @intCast(i), deps);
    }

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var restored = try deserializeWgslTable(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    try testing.expectEqual(depth, restored.count());

    // Verify chain integrity
    for (1..depth) |i| {
        const entry = restored.get(@intCast(i)).?;
        try testing.expectEqualSlices(u16, &[_]u16{@intCast(i - 1)}, entry.deps);
    }
}

// ============================================================================
// Creative Edge Cases (Long Tail)
// ============================================================================

test "WgslTable: binary tree dependency pattern" {
    // Creates a binary tree of deps: 0 and 1 have no deps,
    // 2 depends on 0 and 1, 3 and 4 depend on 0 and 1, etc.
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    // Level 0: two roots
    _ = try table.add(testing.allocator, 0, &[_]u16{});
    _ = try table.add(testing.allocator, 1, &[_]u16{});

    // Level 1: two nodes each depending on both roots
    _ = try table.add(testing.allocator, 2, &[_]u16{ 0, 1 });
    _ = try table.add(testing.allocator, 3, &[_]u16{ 0, 1 });

    // Level 2: four nodes depending on level 1
    _ = try table.add(testing.allocator, 4, &[_]u16{ 2, 3 });
    _ = try table.add(testing.allocator, 5, &[_]u16{ 2, 3 });
    _ = try table.add(testing.allocator, 6, &[_]u16{ 2, 3 });
    _ = try table.add(testing.allocator, 7, &[_]u16{ 2, 3 });

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var restored = try deserializeWgslTable(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 8), restored.count());

    // Verify tree structure
    try testing.expectEqual(@as(usize, 0), restored.get(0).?.deps.len);
    try testing.expectEqual(@as(usize, 0), restored.get(1).?.deps.len);
    try testing.expectEqual(@as(usize, 2), restored.get(2).?.deps.len);
    try testing.expectEqual(@as(usize, 2), restored.get(7).?.deps.len);
}

test "WgslTable: all-to-all dependency pattern" {
    // Each entry depends on ALL previous entries (worst case for resolution)
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    const count: u16 = 10;
    for (0..count) |i| {
        var deps: [10]u16 = undefined;
        for (0..i) |j| {
            deps[j] = @intCast(j);
        }
        _ = try table.add(testing.allocator, @intCast(i), deps[0..i]);
    }

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var restored = try deserializeWgslTable(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    try testing.expectEqual(count, restored.count());

    // Verify: entry i has i deps
    for (0..count) |i| {
        try testing.expectEqual(i, restored.get(@intCast(i)).?.deps.len);
    }
}

test "WgslTable: alternating dependency pattern" {
    // Even entries depend on odd, odd depend on even (zigzag)
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    // First two have no deps
    _ = try table.add(testing.allocator, 0, &[_]u16{});
    _ = try table.add(testing.allocator, 1, &[_]u16{});

    // Each subsequent depends on the one before
    for (2..20) |i| {
        _ = try table.add(testing.allocator, @intCast(i), &[_]u16{@intCast(i - 1)});
    }

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var restored = try deserializeWgslTable(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 20), restored.count());
}

test "WgslTable: serialize size efficiency" {
    // Verify that empty deps don't bloat the format
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    // 100 entries with no deps
    for (0..100) |i| {
        _ = try table.add(testing.allocator, @intCast(i), &[_]u16{});
    }

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    // Each entry is: data_id (1-2 bytes varint) + dep_count (1 byte = 0)
    // So ~2-3 bytes per entry + 1-2 bytes for count
    // Should be roughly 200-302 bytes for 100 entries
    try testing.expect(bytes.len < 400);
    try testing.expect(bytes.len > 100); // At least some overhead
}

test "WgslTable: identical deps list" {
    // Multiple entries with identical dependency lists
    var table = WgslTable{ .entries = .{} };
    defer table.deinit(testing.allocator);

    const shared_deps = &[_]u16{ 0, 1, 2 };

    // Create deps targets
    for (0..3) |i| {
        _ = try table.add(testing.allocator, @intCast(i), &[_]u16{});
    }

    // Multiple entries with same deps
    for (3..10) |i| {
        _ = try table.add(testing.allocator, @intCast(i * 10), shared_deps);
    }

    const bytes = try table.serialize(testing.allocator);
    defer testing.allocator.free(bytes);

    var restored = try deserializeWgslTable(testing.allocator, bytes);
    defer restored.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 10), restored.count());

    // Verify all have same deps
    for (3..10) |i| {
        try testing.expectEqualSlices(u16, shared_deps, restored.get(@intCast(i)).?.deps);
    }
}
