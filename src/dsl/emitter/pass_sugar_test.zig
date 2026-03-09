//! Pass Sugar Tests
//!
//! Tests for #pass macro expansion into synthetic bytecode resources.

const std = @import("std");
const testing = std.testing;

const Ast = @import("../Ast.zig").Ast;
const Node = @import("../Ast.zig").Node;
const Parser = @import("../Parser.zig").Parser;
const Analyzer = @import("../Analyzer.zig").Analyzer;
const Emitter = @import("../Emitter.zig").Emitter;

const bytecode_mod = @import("bytecode");
const format = bytecode_mod.format;

const executor_mod = @import("executor");
const mock_gpu = executor_mod.mock_gpu;
const MockGPU = mock_gpu.MockGPU;
const CallType = mock_gpu.CallType;
const Dispatcher = executor_mod.Dispatcher;

/// Helper: compile DSL source to PNGB bytecode.
fn compileSource(source: [:0]const u8) ![]u8 {
    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    if (analysis.hasErrors()) return error.EmitError;

    return Emitter.emit(testing.allocator, &ast, &analysis);
}

/// Helper: compile and dispatch through mock GPU.
fn compileAndDispatch(source: [:0]const u8) !MockGPU {
    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = MockGPU.empty;
    errdefer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.execute_all(testing.allocator);

    return gpu;
}

/// Count occurrences of a specific call type.
fn countCalls(gpu: *const MockGPU, call_type: CallType) u32 {
    var count: u32 = 0;
    for (gpu.calls.items) |call| {
        if (call.call_type == call_type) count += 1;
    }
    return count;
}

/// Check if a specific call type exists.
fn hasCall(gpu: *const MockGPU, call_type: CallType) bool {
    return countCalls(gpu, call_type) > 0;
}

// ============================================================================
// Basic Pass Tests
// ============================================================================

test "pass sugar: simple fragment pass compiles" {
    const source: [:0]const u8 =
        \\#pass main {
        \\  code="@fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f { return vec4f(1, 0, 0, 1); }"
        \\}
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    try testing.expectEqualStrings("PNGB", pngb[0..4]);
    try testing.expect(pngb.len > format.HEADER_SIZE);
}

test "pass sugar: simple compute pass compiles" {
    const source: [:0]const u8 =
        \\#pass main {
        \\  code="@compute @workgroup_size(16, 16) fn main_image(@builtin(global_invocation_id) id: vec3u) { textureStore(screen, id.xy, vec4f(1, 0, 0, 1)); }"
        \\}
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    try testing.expectEqualStrings("PNGB", pngb[0..4]);
}

test "pass sugar: fragment pass dispatches correctly" {
    const source: [:0]const u8 =
        \\#pass main {
        \\  code="@fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f { let uv = pos.xy / vec2f(pngine.width, pngine.height); return vec4f(uv, 0, 1); }"
        \\}
    ;

    var gpu = try compileAndDispatch(source);
    defer gpu.deinit(testing.allocator);

    // Verify key resources were created
    try testing.expect(hasCall(&gpu, .create_buffer)); // uniform buffer (pngine used)
    try testing.expect(hasCall(&gpu, .create_shader_module));
    try testing.expect(hasCall(&gpu, .create_render_pipeline));
    try testing.expect(hasCall(&gpu, .create_bind_group));
    try testing.expect(hasCall(&gpu, .create_sampler));
    try testing.expect(hasCall(&gpu, .draw));
}

test "pass sugar: compute pass dispatches with blit" {
    const source: [:0]const u8 =
        \\#pass main {
        \\  code="@compute @workgroup_size(16, 16) fn render(@builtin(global_invocation_id) id: vec3u) { textureStore(screen, id.xy, vec4f(1, 0, 0, 1)); }"
        \\}
    ;

    var gpu = try compileAndDispatch(source);
    defer gpu.deinit(testing.allocator);

    // Compute main should have blit pass → draw call
    try testing.expect(hasCall(&gpu, .create_compute_pipeline));
    try testing.expect(hasCall(&gpu, .dispatch));
    // Blit pass
    try testing.expect(hasCall(&gpu, .create_render_pipeline));
    try testing.expect(hasCall(&gpu, .draw));
}

test "pass sugar: multi-pass fragment chain" {
    const source: [:0]const u8 =
        \\#pass pass0 {
        \\  code="@fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f { return vec4f(1, 0, 0, 1); }"
        \\}
        \\#pass main {
        \\  code="@fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f { let c = textureSample(pass0, samp, pos.xy); return c; }"
        \\}
    ;

    var gpu = try compileAndDispatch(source);
    defer gpu.deinit(testing.allocator);

    // Should have 2 render pipelines
    try testing.expect(countCalls(&gpu, .create_render_pipeline) >= 2);
    // Should have 2 draw calls
    try testing.expect(countCalls(&gpu, .draw) >= 2);
}

test "pass sugar: code property required" {
    const source: [:0]const u8 =
        \\#pass main {
        \\  feedback=true
        \\}
    ;

    // Should fail at analysis (missing required 'code')
    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    try testing.expect(analysis.hasErrors());
}

test "pass sugar: multiple compute entry points" {
    const source: [:0]const u8 =
        \\#pass main {
        \\  code="@compute @workgroup_size(64) fn physics(@builtin(global_invocation_id) id: vec3u) { } @compute @workgroup_size(16, 16) fn render(@builtin(global_invocation_id) id: vec3u) { textureStore(screen, id.xy, vec4f(1)); }"
        \\}
    ;

    var gpu = try compileAndDispatch(source);
    defer gpu.deinit(testing.allocator);

    // Should have 2 compute pipelines + dispatches + blit
    try testing.expect(countCalls(&gpu, .create_compute_pipeline) >= 2);
    try testing.expect(countCalls(&gpu, .dispatch) >= 2);
    // Blit render pipeline
    try testing.expect(hasCall(&gpu, .create_render_pipeline));
}

test "pass sugar: feedback creates pool textures" {
    const source: [:0]const u8 =
        \\#pass main {
        \\  feedback=true
        \\  code="@fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f { let prev = textureSample(prev_main, samp, pos.xy / vec2f(pngine.width, pngine.height)); return prev; }"
        \\}
    ;

    var gpu = try compileAndDispatch(source);
    defer gpu.deinit(testing.allocator);

    // Should have created 2 textures (ping-pong for feedback)
    try testing.expect(countCalls(&gpu, .create_texture) >= 2);
}

test "pass sugar: init code creates init passes" {
    const source: [:0]const u8 =
        \\#pass main {
        \\  init="@compute @workgroup_size(64) fn seed(@builtin(global_invocation_id) id: vec3u) { }"
        \\  code="@compute @workgroup_size(16, 16) fn render(@builtin(global_invocation_id) id: vec3u) { textureStore(screen, id.xy, vec4f(1)); }"
        \\}
    ;

    var gpu = try compileAndDispatch(source);
    defer gpu.deinit(testing.allocator);

    // Should have compute pipelines for init + main + blit
    try testing.expect(countCalls(&gpu, .create_compute_pipeline) >= 2);
    try testing.expect(hasCall(&gpu, .dispatch));
    try testing.expect(hasCall(&gpu, .draw));
}

test "pass sugar: coexists with explicit macros" {
    const source: [:0]const u8 =
        \\#wgsl helper { value="fn helper() -> f32 { return 1.0; }" }
        \\#pass main {
        \\  code="@fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f { return vec4f(1, 0, 0, 1); }"
        \\}
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);
    try testing.expectEqualStrings("PNGB", pngb[0..4]);
}

test "pass sugar: no passes is no-op" {
    const source: [:0]const u8 =
        \\#wgsl shader { value="fn foo() -> f32 { return 1.0; }" }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);
    try testing.expectEqualStrings("PNGB", pngb[0..4]);
}

test "pass sugar: auto-generates frame" {
    const source: [:0]const u8 =
        \\#pass main {
        \\  code="@fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f { return vec4f(1); }"
        \\}
    ;

    var gpu = try compileAndDispatch(source);
    defer gpu.deinit(testing.allocator);

    // Should have a submit call (from auto-generated frame)
    try testing.expect(hasCall(&gpu, .submit));
}

test "pass sugar: uniform buffer gets writeTimeUniform" {
    const source: [:0]const u8 =
        \\#pass main {
        \\  code="@fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f { return vec4f(pngine.time); }"
        \\}
    ;

    var gpu = try compileAndDispatch(source);
    defer gpu.deinit(testing.allocator);

    // Uniform buffer should be created (writeTimeUniform is a no-op in MockGPU)
    try testing.expect(hasCall(&gpu, .create_buffer));
}
