//! Built-in Inputs Tests
//!
//! Tests for pngineInputs and sceneTimeInputs built-in data sources.
//! These provide runtime-provided uniform data for shaders.
//!
//! ## pngineInputs (16 bytes currently, 112 bytes planned)
//! - time: f32 - elapsed seconds since start
//! - width: f32 - canvas width in pixels
//! - height: f32 - canvas height in pixels
//! - aspect: f32 - width / height
//!
//! ## sceneTimeInputs (12 bytes)
//! - sceneTime: f32 - time within current scene
//! - sceneDuration: f32 - scene duration
//! - normalizedTime: f32 - sceneTime / sceneDuration

const std = @import("std");
const testing = std.testing;

const Ast = @import("../Ast.zig").Ast;
const Parser = @import("../Parser.zig").Parser;
const Analyzer = @import("../Analyzer.zig").Analyzer;
const Emitter = @import("../Emitter.zig").Emitter;
const format = @import("../../bytecode/format.zig");
const opcodes = @import("../../bytecode/opcodes.zig");
const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;
const MockGPU = @import("../../executor/mock_gpu.zig").MockGPU;

/// Helper: compile DSL source to PNGB bytecode.
fn compileSource(source: [:0]const u8) ![]u8 {
    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    if (analysis.hasErrors()) {
        return error.AnalysisError;
    }

    return Emitter.emit(testing.allocator, &ast, &analysis);
}

/// Helper: find opcode in bytecode.
fn findOpcode(bytecode: []const u8, opcode: opcodes.OpCode) ?usize {
    const opcode_byte = @intFromEnum(opcode);
    for (bytecode, 0..) |byte, i| {
        if (byte == opcode_byte) return i;
    }
    return null;
}

// ============================================================================
// pngineInputs Tests
// ============================================================================

test "pngineInputs: compiles without errors" {
    const source: [:0]const u8 =
        \\#buffer uniforms { size=16 usage=[UNIFORM COPY_DST] }
        \\#queue writeInputs { writeBuffer={ buffer=uniforms bufferOffset=0 data=pngineInputs } }
        \\#frame main { perform=[writeInputs] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Verify PNGB header
    try testing.expectEqualStrings("PNGB", pngb[0..4]);
}

test "pngineInputs: generates write_time_uniform opcode" {
    const source: [:0]const u8 =
        \\#buffer uniforms { size=16 usage=[UNIFORM COPY_DST] }
        \\#queue writeInputs { writeBuffer={ buffer=uniforms bufferOffset=0 data=pngineInputs } }
        \\#frame main { perform=[writeInputs] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Deserialize to get bytecode section
    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Find write_time_uniform opcode (0x2A)
    const found = findOpcode(module.bytecode, .write_time_uniform);
    try testing.expect(found != null);
}

test "pngineInputs: executes correctly with MockGPU" {
    const source: [:0]const u8 =
        \\#buffer uniforms { size=16 usage=[UNIFORM COPY_DST] }
        \\#queue writeInputs { writeBuffer={ buffer=uniforms bufferOffset=0 data=pngineInputs } }
        \\#frame main { perform=[writeInputs] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = MockGPU.empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(MockGPU).init(testing.allocator, &gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    // Should have created buffer and written time uniform
    try testing.expect(gpu.calls.items.len >= 2);
}

test "pngineInputs: works with non-zero buffer offset" {
    const source: [:0]const u8 =
        \\#buffer uniforms { size=32 usage=[UNIFORM COPY_DST] }
        \\#queue writeInputs { writeBuffer={ buffer=uniforms bufferOffset=16 data=pngineInputs } }
        \\#frame main { perform=[writeInputs] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Should compile successfully
    try testing.expectEqualStrings("PNGB", pngb[0..4]);
}

test "pngineInputs: combined with other queue operations" {
    const source: [:0]const u8 =
        \\#buffer uniforms { size=16 usage=[UNIFORM COPY_DST] }
        \\#buffer other { size=32 usage=[UNIFORM COPY_DST] }
        \\#data otherData { float32Array=[1.0 2.0 3.0 4.0] }
        \\#queue writeAll {
        \\  writeBuffer={ buffer=uniforms bufferOffset=0 data=pngineInputs }
        \\  writeBuffer={ buffer=other bufferOffset=0 data=otherData }
        \\}
        \\#frame main { perform=[writeAll] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Should have both write_time_uniform and write_buffer opcodes
    const time_uniform = findOpcode(module.bytecode, .write_time_uniform);
    const write_buffer = findOpcode(module.bytecode, .write_buffer);

    try testing.expect(time_uniform != null);
    try testing.expect(write_buffer != null);
}

// ============================================================================
// sceneTimeInputs Tests
// ============================================================================

test "sceneTimeInputs: compiles without errors" {
    const source: [:0]const u8 =
        \\#buffer sceneUniforms { size=12 usage=[UNIFORM COPY_DST] }
        \\#queue writeSceneTime { writeBuffer={ buffer=sceneUniforms bufferOffset=0 data=sceneTimeInputs } }
        \\#frame main { perform=[writeSceneTime] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    try testing.expectEqualStrings("PNGB", pngb[0..4]);
}

test "sceneTimeInputs: generates write_time_uniform opcode" {
    const source: [:0]const u8 =
        \\#buffer sceneUniforms { size=12 usage=[UNIFORM COPY_DST] }
        \\#queue writeSceneTime { writeBuffer={ buffer=sceneUniforms bufferOffset=0 data=sceneTimeInputs } }
        \\#frame main { perform=[writeSceneTime] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const found = findOpcode(module.bytecode, .write_time_uniform);
    try testing.expect(found != null);
}

test "sceneTimeInputs: executes correctly with MockGPU" {
    const source: [:0]const u8 =
        \\#buffer sceneUniforms { size=12 usage=[UNIFORM COPY_DST] }
        \\#queue writeSceneTime { writeBuffer={ buffer=sceneUniforms bufferOffset=0 data=sceneTimeInputs } }
        \\#frame main { perform=[writeSceneTime] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = MockGPU.empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(MockGPU).init(testing.allocator, &gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    try testing.expect(gpu.calls.items.len >= 2);
}

// ============================================================================
// Combined Usage Tests
// ============================================================================

test "both pngineInputs and sceneTimeInputs in same file" {
    const source: [:0]const u8 =
        \\#buffer globalUniforms { size=16 usage=[UNIFORM COPY_DST] }
        \\#buffer sceneUniforms { size=12 usage=[UNIFORM COPY_DST] }
        \\#queue writeGlobal { writeBuffer={ buffer=globalUniforms bufferOffset=0 data=pngineInputs } }
        \\#queue writeScene { writeBuffer={ buffer=sceneUniforms bufferOffset=0 data=sceneTimeInputs } }
        \\#frame main { perform=[writeGlobal writeScene] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Count write_time_uniform opcodes - should be 2 (one for each built-in)
    var count: usize = 0;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.write_time_uniform)) count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

// ============================================================================
// Analyzer Tests - Special Value Recognition
// ============================================================================

test "pngineInputs: recognized as special value (no undefined reference error)" {
    const source: [:0]const u8 =
        \\#buffer uniforms { size=16 usage=[UNIFORM COPY_DST] }
        \\#queue writeInputs { writeBuffer={ buffer=uniforms bufferOffset=0 data=pngineInputs } }
        \\#frame main { perform=[writeInputs] }
    ;

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    // Should have NO errors - pngineInputs is a recognized special value
    try testing.expect(!analysis.hasErrors());
}

test "sceneTimeInputs: recognized as special value (no undefined reference error)" {
    const source: [:0]const u8 =
        \\#buffer uniforms { size=12 usage=[UNIFORM COPY_DST] }
        \\#queue writeInputs { writeBuffer={ buffer=uniforms bufferOffset=0 data=sceneTimeInputs } }
        \\#frame main { perform=[writeInputs] }
    ;

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    try testing.expect(!analysis.hasErrors());
}

test "unknown built-in: reports undefined reference error" {
    const source: [:0]const u8 =
        \\#buffer uniforms { size=16 usage=[UNIFORM COPY_DST] }
        \\#queue writeInputs { writeBuffer={ buffer=uniforms bufferOffset=0 data=unknownBuiltin } }
        \\#frame main { perform=[writeInputs] }
    ;

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    // Should have error for unknown identifier
    try testing.expect(analysis.hasErrors());
}
