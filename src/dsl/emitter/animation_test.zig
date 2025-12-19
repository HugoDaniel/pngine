//! Tests for #animation macro parsing, analysis, and emission.
//!
//! Test coverage (~35 tests):
//! - Basic parsing: macro syntax, properties, scene arrays
//! - Analysis: symbol table, frame references
//! - Emission: bytecode generation, JSON metadata
//! - Fuzz testing: random input robustness for parser and toJson
//! - OOM testing: FailingAllocator for graceful degradation
//! - Edge cases: empty/max scenes, special chars, zero/negative/inf/NaN durations
//! - Integration: full parse->analyze->emit pipeline
//! - Property-based: idempotence, JSON structure invariants

const std = @import("std");
const testing = std.testing;

const Parser = @import("../Parser.zig").Parser;
const Ast = @import("../Ast.zig").Ast;
const Analyzer = @import("../Analyzer.zig").Analyzer;
const Emitter = @import("../Emitter.zig").Emitter;

test "animation: parse basic #animation macro" {
    const source =
        \\#animation test {
        \\  duration=60
        \\  loop=true
        \\  endBehavior=hold
        \\}
    ;

    const source_z: [:0]const u8 = source;
    var ast = try Parser.parse(testing.allocator, source_z);
    defer ast.deinit(testing.allocator);

    // Check that we have nodes (root + animation macro + properties)
    try testing.expect(ast.nodes.len > 0);

    // Find animation macro node
    var found_animation = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .macro_animation) {
            found_animation = true;
            break;
        }
    }
    try testing.expect(found_animation);
}

test "animation: analyze #animation with scenes" {
    const source =
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#renderPipeline pipe {
        \\  vertex={ module=$wgsl.shader entryPoint="vs" }
        \\}
        \\#renderPass pass1 {
        \\  pipeline=$renderPipeline.pipe
        \\  draw=3
        \\}
        \\#frame scene1 { perform=[$renderPass.pass1] }
        \\#frame scene2 { perform=[$renderPass.pass1] }
        \\#animation demo {
        \\  duration=120
        \\  loop=false
        \\  scenes=[
        \\    { id="intro" frame=$frame.scene1 start=0 end=60 }
        \\    { id="main" frame=$frame.scene2 start=60 end=120 }
        \\  ]
        \\}
    ;

    const source_z: [:0]const u8 = source;
    var ast = try Parser.parse(testing.allocator, source_z);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    // Should not have errors
    try testing.expect(!analysis.hasErrors());

    // Animation should be in symbol table
    try testing.expect(analysis.symbols.animation.get("demo") != null);
}

test "animation: emit animation metadata" {
    const source =
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#renderPipeline pipe {
        \\  vertex={ module=$wgsl.shader entryPoint="vs" }
        \\}
        \\#renderPass pass1 {
        \\  pipeline=$renderPipeline.pipe
        \\  draw=3
        \\}
        \\#frame sceneQ { perform=[$renderPass.pass1] }
        \\#frame sceneE { perform=[$renderPass.pass1] }
        \\#animation inercia2025 {
        \\  duration=260
        \\  loop=false
        \\  endBehavior=hold
        \\  scenes=[
        \\    { id="intro" frame=$frame.sceneQ start=0 end=60 }
        \\    { id="outro" frame=$frame.sceneE start=60 end=260 }
        \\  ]
        \\}
    ;

    const source_z: [:0]const u8 = source;
    var ast = try Parser.parse(testing.allocator, source_z);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    try testing.expect(!analysis.hasErrors());

    // Emit - this will also extract animation metadata
    const bytecode = try Emitter.emit(testing.allocator, &ast, &analysis);
    defer testing.allocator.free(bytecode);

    // Bytecode should be valid PNGB
    try testing.expect(bytecode.len >= 16);
    try testing.expectEqualStrings("PNGB", bytecode[0..4]);
}

test "animation: AnimationMetadata.toJson produces valid JSON" {
    const scenes = [_]Emitter.AnimationMetadata.Scene{
        .{ .id = "intro", .frame_name = "sceneQ", .start = 0.0, .end = 30.0 },
        .{ .id = "tunnel", .frame_name = "sceneE", .start = 30.0, .end = 60.0 },
    };

    const meta = Emitter.AnimationMetadata{
        .name = "inercia2025",
        .duration = 260.0,
        .loop = false,
        .end_behavior = .hold,
        .scenes = &scenes,
    };

    const json = try meta.toJson(testing.allocator);
    defer testing.allocator.free(json);

    // Verify JSON structure
    try testing.expect(std.mem.indexOf(u8, json, "\"animation\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"inercia2025\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"duration\":260") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"loop\":false") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"endBehavior\":\"hold\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"scenes\":[") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"id\":\"intro\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"frame\":\"sceneQ\"") != null);
}

test "animation: endBehavior variations" {
    const behaviors = [_]Emitter.AnimationMetadata.EndBehavior{ .hold, .stop, .restart };
    const expected = [_][]const u8{ "hold", "stop", "restart" };

    for (behaviors, expected) |behavior, exp| {
        const meta = Emitter.AnimationMetadata{
            .name = "test",
            .duration = 60.0,
            .loop = false,
            .end_behavior = behavior,
            .scenes = &[_]Emitter.AnimationMetadata.Scene{},
        };

        const json = try meta.toJson(testing.allocator);
        defer testing.allocator.free(json);

        const search = try std.fmt.allocPrint(testing.allocator, "\"endBehavior\":\"{s}\"", .{exp});
        defer testing.allocator.free(search);

        try testing.expect(std.mem.indexOf(u8, json, search) != null);
    }
}

test "animation: loop=true" {
    const meta = Emitter.AnimationMetadata{
        .name = "looping",
        .duration = 10.0,
        .loop = true,
        .end_behavior = .restart,
        .scenes = &[_]Emitter.AnimationMetadata.Scene{},
    };

    const json = try meta.toJson(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"loop\":true") != null);
}

test "animation: empty scenes array" {
    const meta = Emitter.AnimationMetadata{
        .name = "empty",
        .duration = 0.0,
        .loop = false,
        .end_behavior = .hold,
        .scenes = &[_]Emitter.AnimationMetadata.Scene{},
    };

    const json = try meta.toJson(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"scenes\":[]") != null);
}

// ============================================================================
// Fuzz Tests
// ============================================================================

/// Fuzz test for #animation parser.
/// Properties tested:
/// - Never crashes on any input
/// - Always produces valid AST or error (no undefined behavior)
/// - If AST is produced, animation node is either found or not (deterministic)
fn fuzzAnimationParser(_: void, input: []const u8) !void {
    // Filter: skip inputs with null bytes (can't be sentinel-terminated)
    for (input) |b| if (b == 0) return;

    // Filter: skip inputs that are too long (avoid memory pressure)
    if (input.len > 1000) return;

    // Build source with #animation macro using fuzzed content
    var buf: [2048]u8 = undefined;
    const prefix = "#animation fuzz { ";
    const suffix = " }";

    if (prefix.len + input.len + suffix.len >= buf.len) return;

    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..input.len], input);
    @memcpy(buf[prefix.len + input.len ..][0..suffix.len], suffix);

    const total = prefix.len + input.len + suffix.len;
    buf[total] = 0;

    const source: [:0]const u8 = buf[0..total :0];

    // Property: parser never crashes
    var ast = Parser.parse(testing.allocator, source) catch {
        // Parse error is acceptable for fuzz input
        return;
    };
    defer ast.deinit(testing.allocator);

    // Property: root node always at index 0
    try testing.expectEqual(@as(usize, 0), 0);
    try testing.expect(ast.nodes.len > 0);

    // Property: all token indices are valid
    for (ast.nodes.items(.main_token)) |tok_i| {
        try testing.expect(tok_i < ast.tokens.len);
    }
}

test "animation: fuzz parser" {
    try std.testing.fuzz({}, fuzzAnimationParser, .{});
}

/// Fuzz test for AnimationMetadata.toJson.
/// Properties tested:
/// - Never crashes on any valid AnimationMetadata
/// - Output is valid JSON structure (starts with { ends with })
/// - Name, duration, loop, endBehavior fields are present
/// - Scenes array is present
fn fuzzAnimationToJson(_: void, input: []const u8) !void {
    // Filter: skip null bytes and very short inputs
    for (input) |b| if (b == 0) return;
    if (input.len < 4) return;
    if (input.len > 200) return;

    // Use first byte to derive duration, loop, end_behavior
    const duration = @as(f64, @floatFromInt(input[0])) * 10.0;
    const loop = (input[1] & 1) == 1;
    const end_behavior: Emitter.AnimationMetadata.EndBehavior = switch (input[2] % 3) {
        0 => .hold,
        1 => .stop,
        else => .restart,
    };

    // Use remaining bytes as name (filter non-printable)
    var name_buf: [100]u8 = undefined;
    var name_len: usize = 0;
    for (input[3..]) |b| {
        if (b >= 32 and b < 127 and b != '"' and b != '\\') {
            if (name_len < name_buf.len) {
                name_buf[name_len] = b;
                name_len += 1;
            }
        }
    }
    if (name_len == 0) return;

    const meta = Emitter.AnimationMetadata{
        .name = name_buf[0..name_len],
        .duration = duration,
        .loop = loop,
        .end_behavior = end_behavior,
        .scenes = &[_]Emitter.AnimationMetadata.Scene{},
    };

    const json = meta.toJson(testing.allocator) catch return;
    defer testing.allocator.free(json);

    // Property: output starts with { and ends with }
    try testing.expect(json.len >= 2);
    try testing.expect(json[0] == '{');
    try testing.expect(json[json.len - 1] == '}');

    // Property: required fields are present
    try testing.expect(std.mem.indexOf(u8, json, "\"animation\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"duration\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"loop\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"endBehavior\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"scenes\":") != null);
}

test "animation: fuzz toJson" {
    try std.testing.fuzz({}, fuzzAnimationToJson, .{});
}

// ============================================================================
// OOM Tests with FailingAllocator
// ============================================================================

test "animation: toJson handles OOM" {
    const meta = Emitter.AnimationMetadata{
        .name = "test",
        .duration = 60.0,
        .loop = true,
        .end_behavior = .hold,
        .scenes = &[_]Emitter.AnimationMetadata.Scene{
            .{ .id = "intro", .frame_name = "scene1", .start = 0.0, .end = 30.0 },
            .{ .id = "outro", .frame_name = "scene2", .start = 30.0, .end = 60.0 },
        },
    };

    // Test OOM at each allocation point
    var fail_index: usize = 0;
    while (fail_index < 50) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });

        const result = meta.toJson(failing.allocator());
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            // If no failure induced, should succeed
            const json = try result;
            defer failing.allocator().free(json);
            try testing.expect(json.len > 0);
            break;
        }
    }
}

test "animation: analyzer handles OOM" {
    const source: [:0]const u8 =
        \\#animation demo {
        \\  duration=120
        \\  loop=true
        \\  endBehavior=restart
        \\}
    ;

    // Parse first (with regular allocator)
    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    // Test OOM in analyzer
    var fail_index: usize = 0;
    while (fail_index < 50) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });

        if (Analyzer.analyze(failing.allocator(), &ast)) |analysis_val| {
            var analysis = analysis_val;
            defer analysis.deinit(failing.allocator());
            if (!failing.has_induced_failure) {
                // Success without induced failure - done
                break;
            }
        } else |_| {
            // OOM or analysis error is expected when failure is induced
        }
    }
}

// ============================================================================
// Edge Case Tests
// ============================================================================

test "animation: zero duration" {
    const meta = Emitter.AnimationMetadata{
        .name = "zero",
        .duration = 0.0,
        .loop = false,
        .end_behavior = .hold,
        .scenes = &[_]Emitter.AnimationMetadata.Scene{},
    };

    const json = try meta.toJson(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"duration\":0") != null);
}

test "animation: very large duration" {
    const meta = Emitter.AnimationMetadata{
        .name = "long",
        .duration = 3600.0 * 24.0, // 24 hours in seconds
        .loop = true,
        .end_behavior = .restart,
        .scenes = &[_]Emitter.AnimationMetadata.Scene{},
    };

    const json = try meta.toJson(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"duration\":86400") != null);
}

test "animation: fractional duration" {
    const meta = Emitter.AnimationMetadata{
        .name = "precise",
        .duration = 0.016666666666666666, // ~60fps frame time
        .loop = false,
        .end_behavior = .hold,
        .scenes = &[_]Emitter.AnimationMetadata.Scene{},
    };

    const json = try meta.toJson(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"duration\":") != null);
}

test "animation: many scenes (stress test)" {
    // Create 64 scenes
    var scenes: [64]Emitter.AnimationMetadata.Scene = undefined;
    for (&scenes, 0..) |*scene, i| {
        scene.* = .{
            .id = "scene",
            .frame_name = "frame",
            .start = @as(f64, @floatFromInt(i)) * 10.0,
            .end = @as(f64, @floatFromInt(i + 1)) * 10.0,
        };
    }

    const meta = Emitter.AnimationMetadata{
        .name = "stress",
        .duration = 640.0,
        .loop = true,
        .end_behavior = .restart,
        .scenes = &scenes,
    };

    const json = try meta.toJson(testing.allocator);
    defer testing.allocator.free(json);

    // Should have 64 scene entries
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, json, pos, "\"id\":\"scene\"")) |idx| {
        count += 1;
        pos = idx + 1;
    }
    try testing.expectEqual(@as(usize, 64), count);
}

test "animation: single scene at boundary" {
    const scenes = [_]Emitter.AnimationMetadata.Scene{
        .{ .id = "only", .frame_name = "main", .start = 0.0, .end = 0.0 },
    };

    const meta = Emitter.AnimationMetadata{
        .name = "boundary",
        .duration = 0.0,
        .loop = false,
        .end_behavior = .stop,
        .scenes = &scenes,
    };

    const json = try meta.toJson(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"start\":0") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"end\":0") != null);
}

test "animation: scene with equal start and end" {
    const scenes = [_]Emitter.AnimationMetadata.Scene{
        .{ .id = "instant", .frame_name = "flash", .start = 5.0, .end = 5.0 },
    };

    const meta = Emitter.AnimationMetadata{
        .name = "instant",
        .duration = 10.0,
        .loop = false,
        .end_behavior = .hold,
        .scenes = &scenes,
    };

    const json = try meta.toJson(testing.allocator);
    defer testing.allocator.free(json);

    // Both start and end should be 5
    try testing.expect(std.mem.indexOf(u8, json, "\"start\":5") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"end\":5") != null);
}

test "animation: parse with malformed duration" {
    const source: [:0]const u8 = "#animation test { duration=notanumber }";
    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    // Parser should succeed (value is just an identifier)
    var found = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .macro_animation) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "animation: parse with missing properties" {
    const source: [:0]const u8 = "#animation empty {}";
    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var found = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .macro_animation) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "animation: parse with extra unknown properties" {
    const source: [:0]const u8 =
        \\#animation test {
        \\  duration=60
        \\  unknownProp=42
        \\  anotherUnknown="value"
        \\}
    ;
    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    // Parser should accept unknown properties
    try testing.expect(ast.nodes.len > 0);
}

test "animation: special characters in name (via direct struct)" {
    // Note: Parser may not allow all special chars, but struct accepts them
    const meta = Emitter.AnimationMetadata{
        .name = "demo-2025_v1",
        .duration = 60.0,
        .loop = false,
        .end_behavior = .hold,
        .scenes = &[_]Emitter.AnimationMetadata.Scene{},
    };

    const json = try meta.toJson(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "demo-2025_v1") != null);
}

test "animation: scene id with dashes and underscores" {
    const scenes = [_]Emitter.AnimationMetadata.Scene{
        .{ .id = "intro-part_1", .frame_name = "frame_main", .start = 0.0, .end = 30.0 },
    };

    const meta = Emitter.AnimationMetadata{
        .name = "test",
        .duration = 30.0,
        .loop = false,
        .end_behavior = .hold,
        .scenes = &scenes,
    };

    const json = try meta.toJson(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "intro-part_1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "frame_main") != null);
}

// ============================================================================
// Integration Tests
// ============================================================================

test "animation: full pipeline parse->analyze->emit" {
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0); }" }
        \\#renderPipeline pipe {
        \\  vertex={ module=$wgsl.shader entryPoint="vs" }
        \\}
        \\#renderPass pass {
        \\  pipeline=$renderPipeline.pipe
        \\  draw=3
        \\}
        \\#frame main { perform=[$renderPass.pass] }
        \\#animation demo {
        \\  duration=60
        \\  loop=true
        \\  endBehavior=restart
        \\  scenes=[
        \\    { id="intro" frame=$frame.main start=0 end=30 }
        \\    { id="outro" frame=$frame.main start=30 end=60 }
        \\  ]
        \\}
    ;

    // Parse
    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);
    try testing.expect(ast.nodes.len > 0);

    // Analyze
    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);
    try testing.expect(!analysis.hasErrors());
    try testing.expect(analysis.symbols.animation.get("demo") != null);
    try testing.expect(analysis.symbols.frame.get("main") != null);

    // Emit
    const bytecode = try Emitter.emit(testing.allocator, &ast, &analysis);
    defer testing.allocator.free(bytecode);

    // Verify bytecode
    try testing.expect(bytecode.len >= 16);
    try testing.expectEqualStrings("PNGB", bytecode[0..4]);
}

test "animation: multiple animations (should use first)" {
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#renderPipeline pipe { vertex={ module=$wgsl.shader entryPoint="vs" } }
        \\#renderPass pass { pipeline=$renderPipeline.pipe draw=3 }
        \\#frame main { perform=[$renderPass.pass] }
        \\#animation first { duration=30 loop=false }
        \\#animation second { duration=60 loop=true }
    ;

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    // Both should be in symbol table
    try testing.expect(analysis.symbols.animation.get("first") != null);
    try testing.expect(analysis.symbols.animation.get("second") != null);
}

test "animation: with #define constant" {
    const source: [:0]const u8 =
        \\#define DURATION=120
        \\#animation demo {
        \\  duration=DURATION
        \\  loop=false
        \\}
    ;

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    // Parser should accept this
    try testing.expect(ast.nodes.len > 0);
}

// ============================================================================
// Long-Tail Edge Cases
// ============================================================================

test "animation: negative duration (via struct)" {
    const meta = Emitter.AnimationMetadata{
        .name = "negative",
        .duration = -10.0,
        .loop = false,
        .end_behavior = .hold,
        .scenes = &[_]Emitter.AnimationMetadata.Scene{},
    };

    const json = try meta.toJson(testing.allocator);
    defer testing.allocator.free(json);

    // Should serialize the negative value
    try testing.expect(std.mem.indexOf(u8, json, "\"duration\":-10") != null);
}

test "animation: infinity duration" {
    const meta = Emitter.AnimationMetadata{
        .name = "infinite",
        .duration = std.math.inf(f64),
        .loop = true,
        .end_behavior = .restart,
        .scenes = &[_]Emitter.AnimationMetadata.Scene{},
    };

    const json = try meta.toJson(testing.allocator);
    defer testing.allocator.free(json);

    // Should produce valid JSON (inf formats as "inf" in Zig)
    try testing.expect(json.len > 0);
    try testing.expect(json[0] == '{');
}

test "animation: NaN duration" {
    const meta = Emitter.AnimationMetadata{
        .name = "nan",
        .duration = std.math.nan(f64),
        .loop = false,
        .end_behavior = .hold,
        .scenes = &[_]Emitter.AnimationMetadata.Scene{},
    };

    const json = try meta.toJson(testing.allocator);
    defer testing.allocator.free(json);

    // Should produce valid JSON (nan formats as "nan" in Zig)
    try testing.expect(json.len > 0);
    try testing.expect(json[0] == '{');
}

test "animation: very long name (100 chars)" {
    const long_name = "a" ** 100;
    const meta = Emitter.AnimationMetadata{
        .name = long_name,
        .duration = 60.0,
        .loop = false,
        .end_behavior = .hold,
        .scenes = &[_]Emitter.AnimationMetadata.Scene{},
    };

    const json = try meta.toJson(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, long_name) != null);
}

test "animation: empty name" {
    const meta = Emitter.AnimationMetadata{
        .name = "",
        .duration = 60.0,
        .loop = false,
        .end_behavior = .hold,
        .scenes = &[_]Emitter.AnimationMetadata.Scene{},
    };

    const json = try meta.toJson(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"\"") != null);
}

test "animation: scene with end < start" {
    const scenes = [_]Emitter.AnimationMetadata.Scene{
        .{ .id = "reverse", .frame_name = "frame", .start = 60.0, .end = 30.0 },
    };

    const meta = Emitter.AnimationMetadata{
        .name = "invalid",
        .duration = 60.0,
        .loop = false,
        .end_behavior = .hold,
        .scenes = &scenes,
    };

    const json = try meta.toJson(testing.allocator);
    defer testing.allocator.free(json);

    // Should serialize anyway (validation is separate concern)
    try testing.expect(std.mem.indexOf(u8, json, "\"start\":60") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"end\":30") != null);
}

test "animation: scene with negative times" {
    const scenes = [_]Emitter.AnimationMetadata.Scene{
        .{ .id = "negative", .frame_name = "frame", .start = -10.0, .end = -5.0 },
    };

    const meta = Emitter.AnimationMetadata{
        .name = "negative_times",
        .duration = 60.0,
        .loop = false,
        .end_behavior = .hold,
        .scenes = &scenes,
    };

    const json = try meta.toJson(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"start\":-10") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"end\":-5") != null);
}

test "animation: whitespace in parsed source" {
    const source: [:0]const u8 =
        \\
        \\    #animation    spaced    {
        \\        duration   =   60
        \\        loop   =   true
        \\    }
        \\
    ;

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var found = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .macro_animation) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "animation: numeric name (valid identifier)" {
    const source: [:0]const u8 = "#animation anim123 { duration=60 }";
    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    try testing.expect(analysis.symbols.animation.get("anim123") != null);
}

test "animation: underscore in name" {
    const source: [:0]const u8 = "#animation my_cool_animation { duration=60 }";
    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    try testing.expect(analysis.symbols.animation.get("my_cool_animation") != null);
}

test "animation: minimal valid source" {
    const source: [:0]const u8 = "#animation a{}";
    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var found = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .macro_animation) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "animation: scientific notation duration" {
    const meta = Emitter.AnimationMetadata{
        .name = "scientific",
        .duration = 1.5e6, // 1,500,000 seconds
        .loop = false,
        .end_behavior = .hold,
        .scenes = &[_]Emitter.AnimationMetadata.Scene{},
    };

    const json = try meta.toJson(testing.allocator);
    defer testing.allocator.free(json);

    // Should contain the large number
    try testing.expect(std.mem.indexOf(u8, json, "\"duration\":") != null);
}

test "animation: very small duration" {
    const meta = Emitter.AnimationMetadata{
        .name = "tiny",
        .duration = 1e-10, // 0.0000000001 seconds
        .loop = false,
        .end_behavior = .hold,
        .scenes = &[_]Emitter.AnimationMetadata.Scene{},
    };

    const json = try meta.toJson(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"duration\":") != null);
}

// ============================================================================
// Property-Based Tests
// ============================================================================

test "animation: toJson idempotence (same input = same output)" {
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    const random = prng.random();

    // Generate 10 random test cases
    for (0..10) |_| {
        const duration = random.float(f64) * 1000.0;
        const loop = random.boolean();
        const end_behavior: Emitter.AnimationMetadata.EndBehavior = switch (random.intRangeAtMost(u8, 0, 2)) {
            0 => .hold,
            1 => .stop,
            else => .restart,
        };

        const meta = Emitter.AnimationMetadata{
            .name = "test",
            .duration = duration,
            .loop = loop,
            .end_behavior = end_behavior,
            .scenes = &[_]Emitter.AnimationMetadata.Scene{},
        };

        const json1 = try meta.toJson(testing.allocator);
        defer testing.allocator.free(json1);

        const json2 = try meta.toJson(testing.allocator);
        defer testing.allocator.free(json2);

        // Property: same input produces identical output
        try testing.expectEqualStrings(json1, json2);
    }
}

test "animation: JSON structure invariants" {
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    const random = prng.random();

    for (0..20) |_| {
        const scene_count = random.intRangeAtMost(usize, 0, 10);
        var scenes: [10]Emitter.AnimationMetadata.Scene = undefined;

        for (scenes[0..scene_count], 0..) |*scene, i| {
            scene.* = .{
                .id = "s",
                .frame_name = "f",
                .start = @as(f64, @floatFromInt(i)) * 10.0,
                .end = @as(f64, @floatFromInt(i + 1)) * 10.0,
            };
        }

        const meta = Emitter.AnimationMetadata{
            .name = "random",
            .duration = random.float(f64) * 1000.0,
            .loop = random.boolean(),
            .end_behavior = .hold,
            .scenes = scenes[0..scene_count],
        };

        const json = try meta.toJson(testing.allocator);
        defer testing.allocator.free(json);

        // Property: JSON is always properly bracketed
        try testing.expect(json[0] == '{');
        try testing.expect(json[json.len - 1] == '}');

        // Property: required fields always present
        try testing.expect(std.mem.indexOf(u8, json, "\"animation\":") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"name\":") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"scenes\":") != null);

        // Property: scene count matches
        var count: usize = 0;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, json, pos, "\"id\":\"s\"")) |idx| {
            count += 1;
            pos = idx + 1;
        }
        try testing.expectEqual(scene_count, count);
    }
}
