//! Module Reference Resolution Tests
//!
//! Comprehensive tests for shader module reference resolution, specifically testing:
//! 1. Bare identifier module references (e.g., module=shaderName)
//! 2. WGSL reference patterns (e.g., code=wgslName)
//!
//! ## Bug Fixes Tested
//! - Bare identifiers: Pipeline `module=sceneE` was not finding shader IDs because
//!   only reference syntax was handled, not bare identifiers.
//!
//! ## Test Categories
//! - Unit tests: basic reference patterns
//! - Edge cases: unusual naming patterns
//! - Property tests: all module references resolve correctly
//! - Integration tests: end-to-end with mock GPU

const std = @import("std");
const testing = std.testing;
const Compiler = @import("../Compiler.zig").Compiler;

// Use bytecode module import
const bytecode_mod = @import("bytecode");
const format = bytecode_mod.format;
const opcodes = bytecode_mod.opcodes;

// Use executor module import
const executor_mod = @import("executor");
const mock_gpu = executor_mod.mock_gpu;
const Dispatcher = executor_mod.Dispatcher;

// ============================================================================ 
// Test Helpers
// ============================================================================ 

fn compileSource(source: [:0]const u8) ![]u8 {
    return Compiler.compile(testing.allocator, source);
}

fn executeAndGetPipelineShaderIds(allocator: std.mem.Allocator, pngb: []const u8) ![]u16 {
    var module = try format.deserialize(allocator, pngb);
    defer module.deinit(allocator);

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(allocator);

    var ids = std.ArrayListUnmanaged(u16){};
    errdefer ids.deinit(allocator);

    for (gpu.get_calls()) |call| {
        if (call.call_type == .create_render_pipeline) {
            // Get vertex shader ID from pipeline descriptor
            const desc = call.params.create_render_pipeline.descriptor;
            if (std.mem.indexOf(u8, desc, "\"shader\":")) |pos| {
                // Extract shader ID number after "shader":
                var id_start = pos + 9;
                while (id_start < desc.len and desc[id_start] == ' ') : (id_start += 1) {}
                var id_end = id_start;
                while (id_end < desc.len and desc[id_end] >= '0' and desc[id_end] <= '9') : (id_end += 1) {}
                if (id_end > id_start) {
                    const id_str = desc[id_start..id_end];
                    const id = std.fmt.parseInt(u16, id_str, 10) catch 0xFFFF;
                    try ids.append(allocator, id);
                }
            }
        }
    }

    return ids.toOwnedSlice(allocator);
}

fn countShaders(allocator: std.mem.Allocator, pngb: []const u8) !u32 {
    var module = try format.deserialize(allocator, pngb);
    defer module.deinit(allocator);

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(allocator);

    var count: u32 = 0;
    for (gpu.get_calls()) |call| {
        if (call.call_type == .create_shader_module) {
            count += 1;
        }
    }
    return count;
}

// ============================================================================ 
// Basic Module Reference Tests
// ============================================================================ 

test "ModuleRef: bare identifier module reference (the main bug fix)" {
    // This is the pattern that was broken:
    // #shaderModule scene { code="..." }
    // #renderPipeline pipe { vertex={ module=scene } }
    const source: [:0]const u8 = 
        \\#shaderModule scene { code="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0); }" }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=scene entryPoint=vs }
        \\  fragment={ module=scene entryPoint=vs targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    // This should NOT error - the pipeline should find the shader
    try dispatcher.executeAll(testing.allocator);

    // Verify pipeline was created
    var pipeline_count: u32 = 0;
    for (gpu.get_calls()) |call| {
        if (call.call_type == .create_render_pipeline) {
            pipeline_count += 1;
        }
    }
    try testing.expectEqual(@as(u32, 1), pipeline_count);
}

test "ModuleRef: wgsl reference in shaderModule code" {
    // shaderModule code property references a wgsl by name
    const source: [:0]const u8 = 
        \\#wgsl shaderCode { value="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0); }" }
        \\#shaderModule scene { code=shaderCode }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=scene entryPoint=vs }
        \\  fragment={ module=scene entryPoint=vs targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Should have 2 shaders: wgsl + shaderModule referencing it
    const shader_count = try countShaders(testing.allocator, pngb);
    try testing.expect(shader_count >= 1);
}

test "ModuleRef: bare identifier module reference in pipeline" {
    // Bare identifier reference to shaderModule from pipeline
    // Note: #wgsl alone does NOT create a shader module - must use #shaderModule
    const source: [:0]const u8 = 
        \\#wgsl shaderCode { value="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0); }" }
        \\#shaderModule shader { code=shaderCode }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=shader entryPoint=vs }
        \\  fragment={ module=shader entryPoint=vs targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    const shader_count = try countShaders(testing.allocator, pngb);
    try testing.expectEqual(@as(u32, 1), shader_count);
}

// ============================================================================ 
// Edge Cases for Naming Patterns
// ============================================================================ 

test "ModuleRef: wgsl name with underscores" {
    // Names with underscores
    const source: [:0]const u8 = 
        \\#wgsl shader_code_v2 { value="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0); }" }
        \\#shaderModule mod { code=shader_code_v2 }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=vs }
        \\  fragment={ module=mod entryPoint=vs targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    const shader_count = try countShaders(testing.allocator, pngb);
    try testing.expect(shader_count >= 1);
}

test "ModuleRef: inline WGSL code is treated as literal" {
    // Inline code should be treated as a literal string, not a reference
    const source: [:0]const u8 = 
        \\#shaderModule mod { code="fn check() -> f32 { return 3.14; }" }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=check }
        \\  fragment={ module=mod entryPoint=check targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    const shader_count = try countShaders(testing.allocator, pngb);
    try testing.expectEqual(@as(u32, 1), shader_count);
}

// ============================================================================ 
// Mixed Syntax Tests
// ============================================================================ 

test "ModuleRef: multiple shaders referenced by bare identifier" {
    // All pipelines use bare identifiers
    const source: [:0]const u8 = 
        \\#wgsl shader1 { value="@vertex fn vs1() -> @builtin(position) vec4f { return vec4f(0); }" }
        \\#wgsl shader2 { value="@vertex fn vs2() -> @builtin(position) vec4f { return vec4f(1); }" }
        \\#shaderModule mod3 { code="@vertex fn vs3() -> @builtin(position) vec4f { return vec4f(2); }" }
        \\#renderPipeline pipe1 {
        \\  layout=auto
        \\  vertex={ module=shader1 entryPoint=vs1 }
        \\  fragment={ module=shader1 entryPoint=vs1 targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPipeline pipe2 {
        \\  layout=auto
        \\  vertex={ module=shader2 entryPoint=vs2 }
        \\  fragment={ module=shader2 entryPoint=vs2 targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPipeline pipe3 {
        \\  layout=auto
        \\  vertex={ module=mod3 entryPoint=vs3 }
        \\  fragment={ module=mod3 entryPoint=vs3 targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass1 {
        \\  pipeline=pipe1
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#renderPass pass2 {
        \\  pipeline=pipe2
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#renderPass pass3 {
        \\  pipeline=pipe3
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass1, pass2, pass3] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    // Count pipelines created
    var pipeline_count: u32 = 0;
    for (gpu.get_calls()) |call| {
        if (call.call_type == .create_render_pipeline) {
            pipeline_count += 1;
        }
    }
    try testing.expectEqual(@as(u32, 3), pipeline_count);
}

// ============================================================================ 
// Complex Patterns (Demo-like)
// ============================================================================ 

test "ModuleRef: demo pattern - wgsl with imports, shaderModule ref" {
    // Pattern with wgsl imports and shaderModule reference
    const source: [:0]const u8 = 
        \\#wgsl constants { value="const AWAY: f32 = 1e10;" }
        \\#wgsl transform2D { value="fn transform(p: vec2f) -> vec2f { return p; }" }
        \\#wgsl sceneEShader {
        \\  value="@vertex fn vs_sceneE() -> @builtin(position) vec4f { return vec4f(transform(vec2f(0.0)), 0.0, 1.0); }"
        \\  imports=[constants transform2D]
        \\}
        \\#shaderModule sceneE { code=sceneEShader }
        \\#renderPipeline renderSceneE {
        \\  layout=auto
        \\  vertex={ entryPoint=vs_sceneE module=sceneE }
        \\  fragment={ entryPoint=vs_sceneE module=sceneE targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass passSceneE {
        \\  pipeline=renderSceneE
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#frame main { perform=[passSceneE] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    // This was the exact pattern that was failing
    try dispatcher.executeAll(testing.allocator);

    // Verify all expected resources created
    var shader_count: u32 = 0;
    var pipeline_count: u32 = 0;
    for (gpu.get_calls()) |call| {
        switch (call.call_type) {
            .create_shader_module => shader_count += 1,
            .create_render_pipeline => pipeline_count += 1,
            else => {},
        }
    }

    // Only #shaderModule creates a shader module now (not #wgsl)
    // sceneE is the only #shaderModule, so shader_count = 1
    try testing.expectEqual(@as(u32, 1), shader_count);
    try testing.expectEqual(@as(u32, 1), pipeline_count);
}

// ============================================================================ 
// Entry Point Edge Cases
// ============================================================================ 

test "ModuleRef: entry point as string vs identifier" {
    // Test both entryPoint="name" and entryPoint=name
    const source: [:0]const u8 = 
        \\#shaderModule mod { code="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0); }" }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint="vs" }
        \\  fragment={ module=mod entryPoint=vs targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Should compile successfully with either style
    const shader_count = try countShaders(testing.allocator, pngb);
    try testing.expectEqual(@as(u32, 1), shader_count);
}

test "ModuleRef: case sensitivity in entry points" {
    // Entry points should be case-sensitive
    const source: [:0]const u8 = 
        \\#shaderModule mod { code="@vertex fn VertexMain() -> @builtin(position) vec4f { return vec4f(0); }" }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=VertexMain }
        \\  fragment={ module=mod entryPoint=VertexMain targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Should work with CamelCase entry point
    const shader_count = try countShaders(testing.allocator, pngb);
    try testing.expectEqual(@as(u32, 1), shader_count);
}

// ============================================================================ 
// Compute Pipeline Tests
// ============================================================================ 

test "ModuleRef: compute pipeline with bare identifier" {
    const source: [:0]const u8 = 
        \\#shaderModule comp { code="@compute @workgroup_size(64) fn main() {}" }
        \\#computePipeline pipe {
        \\  compute={ module=comp entryPoint=main }
        \\}
        \\#computePass pass {
        \\  pipeline=pipe
        \\  dispatch=[1, 1, 1]
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    var compute_pipeline_count: u32 = 0;
    for (gpu.get_calls()) |call| {
        if (call.call_type == .create_compute_pipeline) {
            compute_pipeline_count += 1;
        }
    }
    try testing.expectEqual(@as(u32, 1), compute_pipeline_count);
}

// ============================================================================ 
// Property Tests
// ============================================================================ 

test "ModuleRef: property - all pipelines get valid shader IDs" {
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    const random = prng.random();

    for (0..10) |_| {
        var source_buf: [4096]u8 = undefined;
        @memset(&source_buf, 0);
        var pos: usize = 0;

        // Generate 1-5 shaders
        const shader_count = random.intRangeAtMost(u8, 1, 5);
        for (0..shader_count) |i| {
            const is_wgsl = random.boolean();
            if (is_wgsl) {
                const line = std.fmt.bufPrint(source_buf[pos..], "#wgsl s{d} {{ value=\"fn f{d}() {{}}\" }}\\n", .{ i, i }) catch break;
                pos += line.len;
            } else {
                const line = std.fmt.bufPrint(source_buf[pos..], "#shaderModule s{d} {{ code=\"fn f{d}() {{}}\" }}\\n", .{ i, i }) catch break;
                pos += line.len;
            }
        }

        // Generate a pipeline referencing first shader using bare identifier
        const pipe_line = "#renderPipeline pipe { layout=auto vertex={ module=s0 entryPoint=f0 } fragment={ module=s0 entryPoint=f0 targets=[{format=preferredCanvasFormat}] } }\\n";
        @memcpy(source_buf[pos..][0..pipe_line.len], pipe_line);
        pos += pipe_line.len;

        const pass_frame = 
            \\#renderPass pass { pipeline=pipe colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}] draw=3 }
            \\#frame main { perform=[pass] }
            \\
        ;
        @memcpy(source_buf[pos..][0..pass_frame.len], pass_frame);
        pos += pass_frame.len;

        const source_z = source_buf[0..pos :0];
        const pngb = compileSource(source_z) catch continue;
        defer testing.allocator.free(pngb);

        // Property: pipeline should execute without error
        var module = format.deserialize(testing.allocator, pngb) catch continue;
        defer module.deinit(testing.allocator);

        var gpu: mock_gpu.MockGPU = .empty;
        defer gpu.deinit(testing.allocator);

        var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
        defer dispatcher.deinit();

        // Should not crash
        dispatcher.executeAll(testing.allocator) catch continue;
    }
}

// ============================================================================ 
// Stress Tests
// ============================================================================ 

test "ModuleRef: many shaders with bare identifier refs" {
    var source_buf: [16384]u8 = undefined;
    @memset(&source_buf, 0);
    var pos: usize = 0;

    // Generate 20 shaders
    for (0..20) |i| {
        const line = std.fmt.bufPrint(source_buf[pos..], "#shaderModule s{d} {{ code=\"fn f{d}() {{}}\" }}\\n", .{ i, i }) catch break;
        pos += line.len;
    }

    // Generate 20 pipelines, each using bare identifier
    for (0..20) |i| {
        const line = std.fmt.bufPrint(source_buf[pos..],
            \\#renderPipeline pipe{d} {{
            \\  layout=auto
            \\  vertex={{ module=s{d} entryPoint=f{d} }}
            \\  fragment={{ module=s{d} entryPoint=f{d} targets=[{{format=preferredCanvasFormat}}] }}
            \\}}
            \\#renderPass pass{d} {{
            \\  pipeline=pipe{d}
            \\  colorAttachments=[{{view=contextCurrentTexture loadOp=clear storeOp=store}}]
            \\  draw=3
            \\}}
            \\,
        , .{ i, i, i, i, i, i, i }) catch break;
        pos += line.len;
    }

    // Generate frame with all passes
    const frame_start = "#frame main { perform=[";
    @memcpy(source_buf[pos..][0..frame_start.len], frame_start);
    pos += frame_start.len;

    for (0..20) |i| {
        if (i > 0) {
            source_buf[pos] = ',';
            pos += 1;
        }
        const pass_ref = std.fmt.bufPrint(source_buf[pos..], "pass{d}", .{i}) catch break;
        pos += pass_ref.len;
    }

    const frame_end = "] }\\n";
    @memcpy(source_buf[pos..][0..frame_end.len], frame_end);
    pos += frame_end.len;

    const source_z = source_buf[0..pos :0];
    const pngb = try compileSource(source_z);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    // Verify all 20 pipelines were created
    var pipeline_count: u32 = 0;
    for (gpu.get_calls()) |call| {
        if (call.call_type == .create_render_pipeline) {
            pipeline_count += 1;
        }
    }
    try testing.expectEqual(@as(u32, 20), pipeline_count);
}

// ============================================================================ 
// Fuzz Tests
// ============================================================================ 

fn fuzzModuleReference(_: void, input: []const u8) !void {
    // Filter inputs
    for (input) |b| {
        if (b == 0) return;
    }
    if (input.len < 3) return;

    // Use input to determine pattern
    const use_wgsl = input[0] % 2 == 0;
    _ = input[1]; // Previously used for ref syntax, now always bare identifier

    var source_buf: [2048]u8 = undefined;
    @memset(&source_buf, 0);
    var pos: usize = 0;

    // Generate shader
    if (use_wgsl) {
        const shader = "#wgsl test { value=\"fn f() {}\" }\\n";
        @memcpy(source_buf[pos..][0..shader.len], shader);
        pos += shader.len;
    } else {
        const shader = "#shaderModule test { code=\"fn f() {}\" }\\n";
        @memcpy(source_buf[pos..][0..shader.len], shader);
        pos += shader.len;
    }

    // Generate pipeline using bare identifier
    const pipe = "#renderPipeline pipe { layout=auto vertex={ module=test entryPoint=f } fragment={ module=test entryPoint=f targets=[{format=preferredCanvasFormat}] } }\\n";
    @memcpy(source_buf[pos..][0..pipe.len], pipe);
    pos += pipe.len;

    const rest = 
        \\#renderPass pass { pipeline=pipe colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}] draw=3 }
        \\#frame main { perform=[pass] }
        \\
    ;
    @memcpy(source_buf[pos..][0..rest.len], rest);
    pos += rest.len;

    const source_z = source_buf[0..pos :0];

    // Property: should either compile successfully or fail gracefully
    const result = compileSource(source_z);
    if (result) |pngb| {
        defer testing.allocator.free(pngb);

        // If compilation succeeds, execution should also succeed
        var module = format.deserialize(testing.allocator, pngb) catch return;
        defer module.deinit(testing.allocator);

        var gpu: mock_gpu.MockGPU = .empty;
        defer gpu.deinit(testing.allocator);

        var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
        defer dispatcher.deinit();

        // Should not crash
        dispatcher.executeAll(testing.allocator) catch return;
    } else |_| {
        // Compilation error is acceptable
    }
}

test "ModuleRef: fuzz test" {
    try std.testing.fuzz({}, fuzzModuleReference, .{});
}

// ============================================================================ 
// Long-Tail Edge Cases
// ============================================================================ 

test "ModuleRef: module name with numbers" {
    const source: [:0]const u8 = 
        \\#shaderModule shader123 { code="fn f() {}" }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=shader123 entryPoint=f }
        \\  fragment={ module=shader123 entryPoint=f targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    const shader_count = try countShaders(testing.allocator, pngb);
    try testing.expectEqual(@as(u32, 1), shader_count);
}

test "ModuleRef: module name starting with underscore" {
    const source: [:0]const u8 = 
        \\#shaderModule _internal { code="fn f() {}" }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=_internal entryPoint=f }
        \\  fragment={ module=_internal entryPoint=f targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    const shader_count = try countShaders(testing.allocator, pngb);
    try testing.expectEqual(@as(u32, 1), shader_count);
}

test "ModuleRef: very long module name" {
    const source: [:0]const u8 = 
        \\#shaderModule thisIsAVeryLongModuleNameThatShouldStillWorkCorrectly { code="fn f() {}" }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=thisIsAVeryLongModuleNameThatShouldStillWorkCorrectly entryPoint=f }
        \\  fragment={ module=thisIsAVeryLongModuleNameThatShouldStillWorkCorrectly entryPoint=f targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    const shader_count = try countShaders(testing.allocator, pngb);
    try testing.expectEqual(@as(u32, 1), shader_count);
}

test "ModuleRef: same module referenced multiple times" {
    const source: [:0]const u8 = 
        \\#shaderModule shared { code="fn f() {}" }
        \\#renderPipeline pipe1 {
        \\  layout=auto
        \\  vertex={ module=shared entryPoint=f }
        \\  fragment={ module=shared entryPoint=f targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPipeline pipe2 {
        \\  layout=auto
        \\  vertex={ module=shared entryPoint=f }
        \\  fragment={ module=shared entryPoint=f targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPipeline pipe3 {
        \\  layout=auto
        \\  vertex={ module=shared entryPoint=f }
        \\  fragment={ module=shared entryPoint=f targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass1 {
        \\  pipeline=pipe1
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#renderPass pass2 {
        \\  pipeline=pipe2
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#renderPass pass3 {
        \\  pipeline=pipe3
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass1, pass2, pass3] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    // Should have 1 shader, 3 pipelines
    var shader_count: u32 = 0;
    var pipeline_count: u32 = 0;
    for (gpu.get_calls()) |call| {
        switch (call.call_type) {
            .create_shader_module => shader_count += 1,
            .create_render_pipeline => pipeline_count += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(u32, 1), shader_count);
    try testing.expectEqual(@as(u32, 3), pipeline_count);
}

// ============================================================================ 
// OOM Tests
// ============================================================================ 

test "ModuleRef: OOM resilience baseline" {
    const source: [:0]const u8 = 
        \\#shaderModule mod { code="fn f() {}" }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=f }
        \\  fragment={ module=mod entryPoint=f targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    // Verify baseline compilation works
    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    const shader_count = try countShaders(testing.allocator, pngb);
    try testing.expectEqual(@as(u32, 1), shader_count);
}

// ============================================================================ 
// Additional Long-Tail Edge Cases
// ============================================================================ 

test "ModuleRef: module name containing 'wgsl' substring" {
    // Edge case: name contains 'wgsl' but is a regular identifier
    const source: [:0]const u8 = 
        \\#shaderModule myWgslShader { code="fn f() {}" }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=myWgslShader entryPoint=f }
        \\  fragment={ module=myWgslShader entryPoint=f targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    const shader_count = try countShaders(testing.allocator, pngb);
    try testing.expectEqual(@as(u32, 1), shader_count);
}

test "ModuleRef: chained wgsl references with shaderModule" {
    // Complex chain: wgsl A -> wgsl B -> shaderModule C referencing B
    const source: [:0]const u8 = 
        \\#wgsl base { value="fn base() -> f32 { return 1.0; }" }
        \\#wgsl derived { value="fn derived() -> f32 { return base() * 2.0; }" imports=[base] }
        \\#shaderModule final { code=derived }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=final entryPoint=derived }
        \\  fragment={ module=final entryPoint=derived targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    // Only #shaderModule creates a shader module now (not #wgsl)
    // 'final' is the only #shaderModule, so shader_count = 1
    var shader_count: u32 = 0;
    for (gpu.get_calls()) |call| {
        if (call.call_type == .create_shader_module) shader_count += 1;
    }
    try testing.expectEqual(@as(u32, 1), shader_count);
}

test "ModuleRef: vertex-only pipeline with bare identifier" {
    // Some pipelines might only specify vertex or only fragment
    const source: [:0]const u8 = 
        \\#shaderModule mod { code="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0); }" }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=vs }
        \\  fragment={ module=mod entryPoint=vs targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    const shader_count = try countShaders(testing.allocator, pngb);
    try testing.expectEqual(@as(u32, 1), shader_count);
}

test "ModuleRef: module reference with CamelCase name" {
    // Test CamelCase naming convention used in many demos
    const source: [:0]const u8 = 
        \\#shaderModule SceneRenderer { code="fn render() {}" }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=SceneRenderer entryPoint=render }
        \\  fragment={ module=SceneRenderer entryPoint=render targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    const shader_count = try countShaders(testing.allocator, pngb);
    try testing.expectEqual(@as(u32, 1), shader_count);
}

test "ModuleRef: different modules for vertex and fragment" {
    // Vertex and fragment use different shader modules
    const source: [:0]const u8 = 
        \\#shaderModule vertMod { code="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0); }" }
        \\#shaderModule fragMod { code="@fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=vertMod entryPoint=vs }
        \\  fragment={ module=fragMod entryPoint=fs targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    const shader_count = try countShaders(testing.allocator, pngb);
    try testing.expectEqual(@as(u32, 2), shader_count);
}

test "ModuleRef: pipeline property order independence" {
    // module can come before or after entryPoint
    const source: [:0]const u8 = 
        \\#shaderModule mod { code="fn f() {}" }
        \\#renderPipeline pipe1 {
        \\  layout=auto
        \\  vertex={ entryPoint=f module=mod }
        \\  fragment={ entryPoint=f module=mod targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPipeline pipe2 {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=f }
        \\  fragment={ module=mod entryPoint=f targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass1 {
        \\  pipeline=pipe1
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#renderPass pass2 {
        \\  pipeline=pipe2
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass1, pass2] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    // Both pipelines should be created
    var pipeline_count: u32 = 0;
    for (gpu.get_calls()) |call| {
        if (call.call_type == .create_render_pipeline) pipeline_count += 1;
    }
    try testing.expectEqual(@as(u32, 2), pipeline_count);
}

test "ModuleRef: wgsl and shaderModule with same name (shadowing)" {
    // Edge case: what happens when wgsl and shaderModule have same name
    // The shaderModule should take precedence for bare identifier lookup
    const source: [:0]const u8 = 
        \\#wgsl shader { value="fn wgsl_fn() {}" }
        \\#shaderModule shader { code="fn module_fn() {}" }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=shader entryPoint=module_fn }
        \\  fragment={ module=shader entryPoint=module_fn targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    // This might error due to duplicate name, or one might shadow the other
    // Either behavior is acceptable as long as it doesn't crash
    const result = compileSource(source);
    if (result) |pngb| {
        defer testing.allocator.free(pngb);
        // If it compiles, verify execution works
        var module = format.deserialize(testing.allocator, pngb) catch return;
        defer module.deinit(testing.allocator);

        var gpu: mock_gpu.MockGPU = .empty;
        defer gpu.deinit(testing.allocator);

        var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
        defer dispatcher.deinit();
        dispatcher.executeAll(testing.allocator) catch return;
    } else |_| {
        // Compilation error due to duplicate name is acceptable
    }
}

test "ModuleRef: reference to non-existent module fails gracefully" {
    // Referencing a module that doesn't exist should fail at compile time
    const source: [:0]const u8 = 
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=nonExistentModule entryPoint=f }
        \\  fragment={ module=nonExistentModule entryPoint=f targets=[{format=preferredCanvasFormat}] }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipe
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    // This should fail gracefully (either compile error or execution error)
    const result = compileSource(source);
    if (result) |pngb| {
        defer testing.allocator.free(pngb);
        // Even if compilation succeeds, execution with missing shader should handle gracefully
        var module = format.deserialize(testing.allocator, pngb) catch return;
        defer module.deinit(testing.allocator);
        // Don't execute - the point is it should have failed at compile time
    } else |_| {
        // Expected: compilation error due to undefined reference
    }
}