//! WGSL Runtime Deduplication Tests
//!
//! Tests for the v2 format WGSL emission and resolution:
//! - Topological ordering of modules
//! - Dependency tracking correctness
//! - Diamond/linear/complex dependency graphs
//! - Integration with full compilation pipeline

const std = @import("std");
const testing = std.testing;
const Emitter = @import("../Emitter.zig").Emitter;
const Analyzer = @import("../Analyzer.zig").Analyzer;
const Parser = @import("../Parser.zig").Parser;
const format = @import("../../bytecode/format.zig");

// ============================================================================
// Helper Functions
// ============================================================================

fn compileSource(allocator: std.mem.Allocator, source: [:0]const u8) ![]u8 {
    var ast = try Parser.parse(allocator, source);
    defer ast.deinit(allocator);

    var analyzer = try Analyzer.analyze(allocator, &ast);
    defer analyzer.deinit(allocator);

    if (analyzer.hasErrors()) {
        return error.AnalysisError;
    }

    return Emitter.emitWithOptions(allocator, &ast, &analyzer, .{});
}

fn getWgslTableFromBytecode(allocator: std.mem.Allocator, pngb: []const u8) !format.WgslTable {
    var module = try format.deserialize(allocator, pngb);
    // Transfer ownership of wgsl table
    const wgsl = module.wgsl;
    module.wgsl = .{ .entries = .{} };
    module.deinit(allocator);
    return wgsl;
}

// ============================================================================
// Basic WGSL Module Tests
// ============================================================================

test "single #wgsl module produces WGSL table entry" {
    const source: [:0]const u8 =
        \\#wgsl shader { value="fn main() {}" }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=$wgsl.shader entryPoint=main }
        \\  fragment={ module=$wgsl.shader entryPoint=main targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store clearValue=[0,0,0,1]}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(testing.allocator, source);
    defer testing.allocator.free(pngb);

    var wgsl = try getWgslTableFromBytecode(testing.allocator, pngb);
    defer wgsl.deinit(testing.allocator);

    // Should have exactly 1 WGSL entry
    try testing.expectEqual(@as(u16, 1), wgsl.count());

    // Entry should have no dependencies
    const entry = wgsl.get(0).?;
    try testing.expectEqual(@as(usize, 0), entry.deps.len);
}

test "two independent #wgsl modules" {
    const source: [:0]const u8 =
        \\#wgsl vertShader { value="fn vert() {}" }
        \\#wgsl fragShader { value="fn frag() {}" }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=$wgsl.vertShader entryPoint=vert }
        \\  fragment={ module=$wgsl.fragShader entryPoint=frag targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store clearValue=[0,0,0,1]}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(testing.allocator, source);
    defer testing.allocator.free(pngb);

    var wgsl = try getWgslTableFromBytecode(testing.allocator, pngb);
    defer wgsl.deinit(testing.allocator);

    // Should have exactly 2 WGSL entries
    try testing.expectEqual(@as(u16, 2), wgsl.count());

    // Both should have no dependencies
    try testing.expectEqual(@as(usize, 0), wgsl.get(0).?.deps.len);
    try testing.expectEqual(@as(usize, 0), wgsl.get(1).?.deps.len);
}

// ============================================================================
// Dependency Tests
// ============================================================================

test "#wgsl with single import" {
    const source: [:0]const u8 =
        \\#wgsl utils { value="fn helper() -> f32 { return 1.0; }" }
        \\#wgsl main { value="fn mainFn() { helper(); }" imports=[$wgsl.utils] }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=$wgsl.main entryPoint=mainFn }
        \\  fragment={ module=$wgsl.main entryPoint=mainFn targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store clearValue=[0,0,0,1]}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(testing.allocator, source);
    defer testing.allocator.free(pngb);

    var wgsl = try getWgslTableFromBytecode(testing.allocator, pngb);
    defer wgsl.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 2), wgsl.count());

    // Find the entry with deps (should be 'main')
    var found_with_deps = false;
    for (0..wgsl.count()) |i| {
        const entry = wgsl.get(@intCast(i)).?;
        if (entry.deps.len > 0) {
            try testing.expectEqual(@as(usize, 1), entry.deps.len);
            found_with_deps = true;
        }
    }
    try testing.expect(found_with_deps);
}

test "#wgsl linear dependency chain" {
    const source: [:0]const u8 =
        \\#wgsl a { value="fn a() {}" }
        \\#wgsl b { value="fn b() { a(); }" imports=[$wgsl.a] }
        \\#wgsl c { value="fn c() { b(); }" imports=[$wgsl.b] }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=$wgsl.c entryPoint=c }
        \\  fragment={ module=$wgsl.c entryPoint=c targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store clearValue=[0,0,0,1]}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(testing.allocator, source);
    defer testing.allocator.free(pngb);

    var wgsl = try getWgslTableFromBytecode(testing.allocator, pngb);
    defer wgsl.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 3), wgsl.count());

    // Verify dependency structure: a -> b -> c
    // Due to topological ordering, a should be processed first
    var dep_counts = [_]usize{ 0, 0, 0 };
    for (0..3) |i| {
        dep_counts[i] = wgsl.get(@intCast(i)).?.deps.len;
    }

    // Should have 0, 1, 1 deps (in some order based on processing)
    var sum: usize = 0;
    for (dep_counts) |c| sum += c;
    try testing.expectEqual(@as(usize, 2), sum); // Total deps = 2
}

test "#wgsl diamond dependency pattern" {
    const source: [:0]const u8 =
        \\#wgsl base { value="fn base() {}" }
        \\#wgsl left { value="fn left() { base(); }" imports=[$wgsl.base] }
        \\#wgsl right { value="fn right() { base(); }" imports=[$wgsl.base] }
        \\#wgsl top { value="fn top() { left(); right(); }" imports=[$wgsl.left, $wgsl.right] }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=$wgsl.top entryPoint=top }
        \\  fragment={ module=$wgsl.top entryPoint=top targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store clearValue=[0,0,0,1]}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(testing.allocator, source);
    defer testing.allocator.free(pngb);

    var wgsl = try getWgslTableFromBytecode(testing.allocator, pngb);
    defer wgsl.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 4), wgsl.count());

    // Find 'top' entry (should have 2 deps)
    var found_top = false;
    for (0..wgsl.count()) |i| {
        const entry = wgsl.get(@intCast(i)).?;
        if (entry.deps.len == 2) {
            found_top = true;
        }
    }
    try testing.expect(found_top);
}

// ============================================================================
// Size Reduction Verification
// ============================================================================

test "shared modules stored once (deduplication)" {
    // Create a scenario where shared code would be duplicated in v1
    const source: [:0]const u8 =
        \\#wgsl shared { value="// Shared code that should only appear once\nfn shared() -> f32 { return 3.14159; }" }
        \\#wgsl user1 { value="fn user1() { shared(); }" imports=[$wgsl.shared] }
        \\#wgsl user2 { value="fn user2() { shared(); }" imports=[$wgsl.shared] }
        \\#wgsl user3 { value="fn user3() { shared(); }" imports=[$wgsl.shared] }
        \\#renderPipeline pipe1 {
        \\  layout=auto
        \\  vertex={ module=$wgsl.user1 entryPoint=user1 }
        \\  fragment={ module=$wgsl.user1 entryPoint=user1 targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPipeline pipe2 {
        \\  layout=auto
        \\  vertex={ module=$wgsl.user2 entryPoint=user2 }
        \\  fragment={ module=$wgsl.user2 entryPoint=user2 targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPipeline pipe3 {
        \\  layout=auto
        \\  vertex={ module=$wgsl.user3 entryPoint=user3 }
        \\  fragment={ module=$wgsl.user3 entryPoint=user3 targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass1 {
        \\  pipeline=pipe1
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store clearValue=[0,0,0,1]}]
        \\  draw=3
        \\}
        \\#renderPass pass2 {
        \\  pipeline=pipe2
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store clearValue=[0,0,0,1]}]
        \\  draw=3
        \\}
        \\#renderPass pass3 {
        \\  pipeline=pipe3
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store clearValue=[0,0,0,1]}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass1, pass2, pass3] }
    ;

    const pngb = try compileSource(testing.allocator, source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Should have 4 WGSL entries (shared + 3 users)
    try testing.expectEqual(@as(u16, 4), module.wgsl.count());

    // The shared code should only appear ONCE in the data section
    // Find the data entry for shared
    const shared_entry = module.wgsl.get(0).?; // First one processed (no deps)
    const shared_code = module.data.get(@enumFromInt(shared_entry.data_id));

    // Count occurrences of shared code pattern in data section
    var occurrences: usize = 0;
    for (0..module.data.blobs.items.len) |i| {
        const blob = module.data.get(@enumFromInt(i));
        if (std.mem.indexOf(u8, blob, "3.14159") != null) {
            occurrences += 1;
        }
    }

    // Should only appear once (in the shared module's data)
    try testing.expectEqual(@as(usize, 1), occurrences);
    _ = shared_code;
}

// ============================================================================
// #shaderModule Backward Compatibility
// ============================================================================

test "#shaderModule still works (legacy path)" {
    const source: [:0]const u8 =
        \\#shaderModule code { code="fn main() {}" }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=$shaderModule.code entryPoint=main }
        \\  fragment={ module=$shaderModule.code entryPoint=main targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store clearValue=[0,0,0,1]}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(testing.allocator, source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // #shaderModule also creates WGSL table entry (for v2 compat)
    try testing.expectEqual(@as(u16, 1), module.wgsl.count());

    // Should have no deps
    try testing.expectEqual(@as(usize, 0), module.wgsl.get(0).?.deps.len);
}

// ============================================================================
// Complex Graphs
// ============================================================================

test "complex dependency graph - multiple shared bases" {
    const source: [:0]const u8 =
        \\#wgsl math { value="fn pi() -> f32 { return 3.14; }" }
        \\#wgsl transform { value="struct T { m: mat4x4f }" }
        \\#wgsl geom { value="fn circle() {}" imports=[$wgsl.math] }
        \\#wgsl render { value="fn draw() {}" imports=[$wgsl.transform, $wgsl.geom] }
        \\#wgsl main { value="fn mainFn() {}" imports=[$wgsl.render, $wgsl.math] }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=$wgsl.main entryPoint=mainFn }
        \\  fragment={ module=$wgsl.main entryPoint=mainFn targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store clearValue=[0,0,0,1]}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(testing.allocator, source);
    defer testing.allocator.free(pngb);

    var wgsl = try getWgslTableFromBytecode(testing.allocator, pngb);
    defer wgsl.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 5), wgsl.count());
}

// ============================================================================
// Edge Cases
// ============================================================================

test "#wgsl with define substitution" {
    const source: [:0]const u8 =
        \\#define PI=3.14159
        \\#wgsl shader { value="const PI_VAL: f32 = PI;" }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=$wgsl.shader entryPoint=main }
        \\  fragment={ module=$wgsl.shader entryPoint=main targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store clearValue=[0,0,0,1]}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(testing.allocator, source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify define was substituted in stored code
    const entry = module.wgsl.get(0).?;
    const code = module.data.get(@enumFromInt(entry.data_id));

    try testing.expect(std.mem.indexOf(u8, code, "3.14159") != null);
    try testing.expect(std.mem.indexOf(u8, code, "PI") == null or
        std.mem.indexOf(u8, code, "PI_VAL") != null);
}

test "empty #wgsl value handled gracefully" {
    const source: [:0]const u8 =
        \\#wgsl empty { value="" }
        \\#wgsl main { value="fn mainFn() {}" }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=$wgsl.main entryPoint=mainFn }
        \\  fragment={ module=$wgsl.main entryPoint=mainFn targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store clearValue=[0,0,0,1]}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = compileSource(testing.allocator, source) catch |err| {
        // Empty value might be rejected by analyzer - that's fine
        try testing.expect(err == error.AnalysisError or err == error.OutOfMemory);
        return;
    };
    defer testing.allocator.free(pngb);

    // If it compiles, verify it has entries
    var wgsl = try getWgslTableFromBytecode(testing.allocator, pngb);
    defer wgsl.deinit(testing.allocator);

    try testing.expect(wgsl.count() >= 1);
}

// ============================================================================
// OOM Tests
// ============================================================================

// Note: Full compilation OOM test is complex due to parser/analyzer internals.
// OOM testing for WgslTable itself is done in wgsl_table_test.zig.

// ============================================================================
// Property Tests
// ============================================================================

test "property: all deps reference earlier entries" {
    const source: [:0]const u8 =
        \\#wgsl a { value="fn a() {}" }
        \\#wgsl b { value="fn b() {}" imports=[$wgsl.a] }
        \\#wgsl c { value="fn c() {}" imports=[$wgsl.a, $wgsl.b] }
        \\#wgsl d { value="fn d() {}" imports=[$wgsl.b, $wgsl.c] }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=$wgsl.d entryPoint=d }
        \\  fragment={ module=$wgsl.d entryPoint=d targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store clearValue=[0,0,0,1]}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(testing.allocator, source);
    defer testing.allocator.free(pngb);

    var wgsl = try getWgslTableFromBytecode(testing.allocator, pngb);
    defer wgsl.deinit(testing.allocator);

    // Property: all dep indices are < current index (topological order)
    for (0..wgsl.count()) |i| {
        const entry = wgsl.get(@intCast(i)).?;
        for (entry.deps) |dep| {
            try testing.expect(dep < i);
        }
    }
}

test "property: no duplicate deps in entry" {
    const source: [:0]const u8 =
        \\#wgsl base { value="fn base() {}" }
        \\#wgsl mid1 { value="fn mid1() {}" imports=[$wgsl.base] }
        \\#wgsl mid2 { value="fn mid2() {}" imports=[$wgsl.base] }
        \\#wgsl top { value="fn top() {}" imports=[$wgsl.mid1, $wgsl.mid2] }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=$wgsl.top entryPoint=top }
        \\  fragment={ module=$wgsl.top entryPoint=top targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store clearValue=[0,0,0,1]}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(testing.allocator, source);
    defer testing.allocator.free(pngb);

    var wgsl = try getWgslTableFromBytecode(testing.allocator, pngb);
    defer wgsl.deinit(testing.allocator);

    // Property: no entry has duplicate deps
    for (0..wgsl.count()) |i| {
        const entry = wgsl.get(@intCast(i)).?;
        for (0..entry.deps.len) |j| {
            for (j + 1..entry.deps.len) |k| {
                try testing.expect(entry.deps[j] != entry.deps[k]);
            }
        }
    }
}

// ============================================================================
// #shaderModule referencing $wgsl.* (demo pattern)
// ============================================================================

test "#shaderModule referencing $wgsl with imports" {
    // This is the exact pattern used in the demo:
    // #wgsl sceneShader { imports=[...] }
    // #shaderModule scene { code="$wgsl.sceneShader" }
    const source: [:0]const u8 =
        \\#wgsl constants { value="const AWAY: f32 = 1e10;" }
        \\#wgsl utils { value="fn helper() -> f32 { return AWAY; }" imports=[$wgsl.constants] }
        \\#wgsl sceneShader {
        \\  value="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0.0, 0.0, helper(), 1.0); }"
        \\  imports=[$wgsl.constants, $wgsl.utils]
        \\}
        \\#shaderModule scene { code="$wgsl.sceneShader" }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=$shaderModule.scene entryPoint=vs }
        \\  fragment={ module=$shaderModule.scene entryPoint=vs targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store clearValue=[0,0,0,1]}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(testing.allocator, source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Should have 3 WGSL entries (constants, utils, sceneShader)
    // Note: #shaderModule referencing $wgsl.* reuses the wgsl_id, doesn't create new entry
    try testing.expectEqual(@as(u16, 3), module.wgsl.count());

    // Find sceneShader entry (has 2 deps)
    var scene_id: ?u16 = null;
    for (0..module.wgsl.count()) |i| {
        const entry = module.wgsl.get(@intCast(i)).?;
        if (entry.deps.len == 2) {
            scene_id = @intCast(i);
            break;
        }
    }
    try testing.expect(scene_id != null);

    // Simulate runtime resolution - walk deps and concat code

    // Collect all code in dependency order (simple DFS for test)
    var visited = std.AutoHashMap(u16, void).init(testing.allocator);
    defer visited.deinit();
    var code_parts = std.ArrayListUnmanaged([]const u8){};
    defer code_parts.deinit(testing.allocator);

    // Simple recursive simulation (ok for test)
    const WgslTable = format.WgslTable;
    const DataSection = @import("../../bytecode/data_section.zig").DataSection;
    const visitFn = struct {
        fn visit(allocator: std.mem.Allocator, wgsl: *const WgslTable, data: *const DataSection, id: u16, v: *std.AutoHashMap(u16, void), parts: *std.ArrayListUnmanaged([]const u8)) !void {
            if (v.contains(id)) return;
            const entry = wgsl.get(id) orelse return;
            // Visit deps first
            for (entry.deps) |dep| {
                try visit(allocator, wgsl, data, dep, v, parts);
            }
            try v.put(id, {});
            try parts.append(allocator, data.get(@enumFromInt(entry.data_id)));
        }
    }.visit;

    try visitFn(testing.allocator, &module.wgsl, &module.data, scene_id.?, &visited, &code_parts);

    // Concatenate all code
    var total_len: usize = 0;
    for (code_parts.items) |part| {
        total_len += part.len + 1;
    }

    const resolved = try testing.allocator.alloc(u8, total_len);
    defer testing.allocator.free(resolved);

    var pos: usize = 0;
    for (code_parts.items) |part| {
        @memcpy(resolved[pos..][0..part.len], part);
        pos += part.len;
        resolved[pos] = '\n';
        pos += 1;
    }

    // Verify all code is present
    try testing.expect(std.mem.indexOf(u8, resolved, "AWAY") != null);
    try testing.expect(std.mem.indexOf(u8, resolved, "helper") != null);
    try testing.expect(std.mem.indexOf(u8, resolved, "@vertex fn vs") != null);
}
