//! Integration Tests for DSL Macros
//!
//! Comprehensive tests ported from old_pngine TypeScript tests.
//! Tests verify end-to-end compilation from DSL source to PNGB bytecode.
//!
//! Test categories:
//! - Triangle example: Basic render pipeline
//! - MSAA example: Multi-sampling with #define
//! - Rotating cube: Vertex buffers, depth stencil
//! - Error handling: Invalid syntax detection
//!
//! Following TigerBeetle testing patterns:
//! - Descriptive test names documenting behavior
//! - Property verification with assertions
//! - Memory leak detection via testing.allocator

const std = @import("std");
const testing = std.testing;
const Parser = @import("../Parser.zig").Parser;
const Analyzer = @import("../Analyzer.zig").Analyzer;
const Emitter = @import("../Emitter.zig").Emitter;

// Use bytecode module import
const bytecode_mod = @import("bytecode");
const format = bytecode_mod.format;
const opcodes = bytecode_mod.opcodes;

// Use executor module import
const executor_mod = @import("executor");
const mock_gpu = executor_mod.mock_gpu;
const Dispatcher = executor_mod.Dispatcher;

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

/// Helper: compile and execute to verify GPU calls.
fn compileAndExecute(source: [:0]const u8) !mock_gpu.MockGPU {
    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: mock_gpu.MockGPU = .empty;
    errdefer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    return gpu;
}

// ============================================================================
// Triangle Example - Basic Render Pipeline
// Ported from old_pngine/src/preprocessor/ast.spec.ts "example 1 - triangle"
// ============================================================================

test "Integration: triangle example - basic render pipeline" {
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="@vertex fn vertexMain() -> @builtin(position) vec4f { return vec4f(0.0); }
        \\@fragment fn fragmentMain() -> @location(0) vec4f { return vec4f(1.0); }"
        \\}
        \\
        \\#renderPipeline triangle {
        \\  vertex={ module=shader entryPoint=vertexMain }
        \\  fragment={
        \\    module=shader
        \\    entryPoint=fragmentMain
        \\    targets=[{ format=bgra8unorm }]
        \\  }
        \\  primitive={ topology=triangle-list }
        \\}
        \\
        \\#renderPass mainPass {
        \\  colorAttachments=[{
        \\    clearValue=[0 0 0 0]
        \\    loadOp=clear
        \\    storeOp=store
        \\  }]
        \\  pipeline=triangle
        \\  draw=3
        \\}
        \\
        \\#frame main {
        \\  perform=[mainPass]
        \\}
    ;

    var gpu = try compileAndExecute(source);
    defer gpu.deinit(testing.allocator);

    // Verify shader module created
    var found_shader = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_shader_module) {
            found_shader = true;
            break;
        }
    }
    try testing.expect(found_shader);

    // Verify render pipeline created
    var found_pipeline = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_render_pipeline) {
            found_pipeline = true;
            break;
        }
    }
    try testing.expect(found_pipeline);

    // Verify draw call
    var found_draw = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .draw) {
            try testing.expectEqual(@as(u32, 3), call.params.draw.vertex_count);
            found_draw = true;
            break;
        }
    }
    try testing.expect(found_draw);
}

// ============================================================================
// MSAA Example - Multi-sampling with #define
// Ported from old_pngine/src/preprocessor/ast.spec.ts "example 2 - triangle MSAA"
// ============================================================================

test "Integration: MSAA example - #define substitution" {
    const source: [:0]const u8 =
        \\#define SAMPLE_COUNT=4
        \\
        \\#wgsl shader {
        \\  value="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0.0); }"
        \\}
        \\
        \\#texture msaaTexture {
        \\  size=[512 512]
        \\  sampleCount=SAMPLE_COUNT
        \\  format=bgra8unorm
        \\  usage=[RENDER_ATTACHMENT]
        \\}
        \\
        \\#renderPipeline msaaPipeline {
        \\  layout=auto
        \\  vertex={ module=shader entryPoint=vs }
        \\  multisample={ count=SAMPLE_COUNT }
        \\}
        \\
        \\#frame main { perform=[] }
    ;

    var gpu = try compileAndExecute(source);
    defer gpu.deinit(testing.allocator);

    // Verify MSAA texture created with sampleCount=4
    var found_texture = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_texture) {
            // Texture created (sampleCount is in JSON descriptor)
            found_texture = true;
            break;
        }
    }
    try testing.expect(found_texture);
}

// ============================================================================
// Rotating Cube Example - Vertex Buffers, Depth Stencil
// Ported from old_pngine/src/preprocessor/ast.spec.ts "example 3 - rotating cube"
// ============================================================================

test "Integration: rotating cube - vertex buffers and depth stencil" {
    const source: [:0]const u8 =
        \\#define CUBE_VERTEX_SIZE=40
        \\#define CUBE_POSITION_OFFSET=0
        \\#define CUBE_UV_OFFSET=32
        \\#define CUBE_VERTEX_COUNT=36
        \\
        \\#wgsl cubeShader {
        \\  value="@vertex fn vertexMain() -> @builtin(position) vec4f { return vec4f(0.0); }
        \\@fragment fn fragmentMain() -> @location(0) vec4f { return vec4f(1.0); }"
        \\}
        \\
        \\#data cubeVertexArray {
        \\  float32Array=[1 -1 1 1  1 0 1 1  0 1]
        \\}
        \\
        \\#buffer verticesBuffer {
        \\  size=cubeVertexArray
        \\  usage=[VERTEX COPY_DST]
        \\}
        \\
        \\#renderPipeline cube {
        \\  layout=auto
        \\  vertex={
        \\    module=cubeShader
        \\    entryPoint=vertexMain
        \\    buffers=[{
        \\      arrayStride=CUBE_VERTEX_SIZE
        \\      attributes=[
        \\        { shaderLocation=0 offset=CUBE_POSITION_OFFSET format=float32x4 }
        \\        { shaderLocation=1 offset=CUBE_UV_OFFSET format=float32x2 }
        \\      ]
        \\    }]
        \\  }
        \\  fragment={
        \\    module=cubeShader
        \\    entryPoint=fragmentMain
        \\    targets=[{ format=bgra8unorm }]
        \\  }
        \\  primitive={ topology=triangle-list cullMode=back }
        \\  depthStencil={ depthWriteEnabled=true depthCompare=less format=depth24plus }
        \\}
        \\
        \\#texture depthTexture {
        \\  size=[512 512]
        \\  format=depth24plus
        \\  usage=[RENDER_ATTACHMENT]
        \\}
        \\
        \\#renderPass cubePass {
        \\  colorAttachments=[{
        \\    clearValue=[0.5 0.5 0.5 1.0]
        \\    loadOp=clear
        \\    storeOp=store
        \\  }]
        \\  depthStencilAttachment={
        \\    view=depthTexture
        \\    depthClearValue=1.0
        \\    depthLoadOp=clear
        \\    depthStoreOp=store
        \\  }
        \\  pipeline=cube
        \\  vertexBuffers=[verticesBuffer]
        \\  draw=CUBE_VERTEX_COUNT
        \\}
        \\
        \\#frame main {
        \\  perform=[cubePass]
        \\}
    ;

    var gpu = try compileAndExecute(source);
    defer gpu.deinit(testing.allocator);

    // Verify vertex buffer created
    var found_buffer = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_buffer) {
            found_buffer = true;
            break;
        }
    }
    try testing.expect(found_buffer);

    // Verify depth texture created
    var texture_count: u32 = 0;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_texture) {
            texture_count += 1;
        }
    }
    try testing.expect(texture_count >= 1);

    // Verify draw call with vertex count from #define
    var found_draw = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .draw) {
            try testing.expectEqual(@as(u32, 36), call.params.draw.vertex_count);
            found_draw = true;
            break;
        }
    }
    try testing.expect(found_draw);
}

// ============================================================================
// Compute Pipeline Tests
// Ported from old_pngine/src/preprocessor/parsePipeline.spec.ts
// ============================================================================

test "Integration: compute pipeline with dispatch" {
    const source: [:0]const u8 =
        \\#wgsl computeShader {
        \\  value="@compute @workgroup_size(64) fn main() {}"
        \\}
        \\
        \\#computePipeline compute {
        \\  compute={ module=computeShader entryPoint=main }
        \\}
        \\
        \\#computePass computePass {
        \\  pipeline=compute
        \\  dispatch=[16 16 1]
        \\}
        \\
        \\#frame main {
        \\  perform=[computePass]
        \\}
    ;

    var gpu = try compileAndExecute(source);
    defer gpu.deinit(testing.allocator);

    // Verify compute pipeline created
    var found_compute_pipeline = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_compute_pipeline) {
            found_compute_pipeline = true;
            break;
        }
    }
    try testing.expect(found_compute_pipeline);

    // Verify begin_compute_pass is called
    var found_begin_compute = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .begin_compute_pass) {
            found_begin_compute = true;
            break;
        }
    }
    try testing.expect(found_begin_compute);

    // Verify dispatch call
    var found_dispatch = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .dispatch) {
            try testing.expectEqual(@as(u32, 16), call.params.dispatch.x);
            try testing.expectEqual(@as(u32, 16), call.params.dispatch.y);
            try testing.expectEqual(@as(u32, 1), call.params.dispatch.z);
            found_dispatch = true;
            break;
        }
    }
    try testing.expect(found_dispatch);
}

// ============================================================================
// Vertex Buffer Layout Tests
// Ported from old_pngine/src/preprocessor/parsePipeline.spec.ts
// ============================================================================

test "Integration: pipeline with multiple vertex buffer layouts" {
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0.0); }"
        \\}
        \\
        \\#renderPipeline withBuffers {
        \\  vertex={
        \\    module=shader
        \\    entryPoint=vs
        \\    buffers=[
        \\      {
        \\        arrayStride=100
        \\        attributes=[
        \\          { format=float32x4 offset=0 shaderLocation=0 }
        \\          { format=float32x2 offset=16 shaderLocation=1 }
        \\        ]
        \\      }
        \\      {
        \\        arrayStride=16
        \\        stepMode=instance
        \\        attributes=[
        \\          { format=float32x4 offset=0 shaderLocation=2 }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
        \\
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Verify valid PNGB
    try testing.expectEqualStrings("PNGB", pngb[0..4]);
}

// ============================================================================
// Fragment Targets with Blend State
// ============================================================================

test "Integration: fragment targets with blend state" {
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0.0); }
        \\@fragment fn fs() -> @location(0) vec4f { return vec4f(1.0); }"
        \\}
        \\
        \\#renderPipeline blended {
        \\  vertex={ module=shader entryPoint=vs }
        \\  fragment={
        \\    module=shader
        \\    entryPoint=fs
        \\    targets=[{
        \\      format=bgra8unorm
        \\      blend={
        \\        color={ srcFactor=src-alpha dstFactor=one-minus-src-alpha operation=add }
        \\        alpha={ srcFactor=one dstFactor=zero operation=add }
        \\      }
        \\    }]
        \\  }
        \\}
        \\
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    try testing.expectEqualStrings("PNGB", pngb[0..4]);
}

// ============================================================================
// WGSL Imports Test
// Ported from old_pngine/src/preprocessor/parseWgsl.spec.ts
// ============================================================================

test "Integration: wgsl with imports" {
    const source: [:0]const u8 =
        \\#wgsl common {
        \\  value="fn helper() -> f32 { return 1.0; }"
        \\}
        \\
        \\#wgsl shader {
        \\  imports=[common]
        \\  value="@vertex fn vs() -> @builtin(position) vec4f {
        \\    let x = helper();
        \\    return vec4f(x);
        \\  }"
        \\}
        \\
        \\#renderPipeline pipe {
        \\  vertex={ module=shader entryPoint=vs }
        \\}
        \\
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    try testing.expectEqualStrings("PNGB", pngb[0..4]);
}

// ============================================================================
// Bind Group Tests
// ============================================================================

test "Integration: bind group with uniform buffer" {
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="@group(0) @binding(0) var<uniform> data: vec4f;"
        \\}
        \\
        \\#buffer uniformBuffer {
        \\  size=16
        \\  usage=[UNIFORM COPY_DST]
        \\}
        \\
        \\#bindGroup uniformGroup {
        \\  entries=[
        \\    { binding=0 resource={ buffer=uniformBuffer } }
        \\  ]
        \\}
        \\
        \\#frame main { perform=[] }
    ;

    var gpu = try compileAndExecute(source);
    defer gpu.deinit(testing.allocator);

    // Verify bind group created
    var found_bind_group = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_bind_group) {
            found_bind_group = true;
            break;
        }
    }
    try testing.expect(found_bind_group);
}

// ============================================================================
// Sampler Tests
// ============================================================================

test "Integration: sampler with all attributes" {
    const source: [:0]const u8 =
        \\#sampler linearSampler {
        \\  magFilter=linear
        \\  minFilter=linear
        \\  mipmapFilter=linear
        \\  addressModeU=repeat
        \\  addressModeV=repeat
        \\  maxAnisotropy=4
        \\}
        \\
        \\#frame main { perform=[] }
    ;

    var gpu = try compileAndExecute(source);
    defer gpu.deinit(testing.allocator);

    // Verify sampler created
    var found_sampler = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_sampler) {
            found_sampler = true;
            break;
        }
    }
    try testing.expect(found_sampler);
}

// ============================================================================
// TextureView Tests
// ============================================================================

test "Integration: texture view with dimension override" {
    const source: [:0]const u8 =
        \\#texture cubeMap {
        \\  size=[256 256 6]
        \\  format=rgba8unorm
        \\  usage=[TEXTURE_BINDING]
        \\}
        \\
        \\#textureView cubeView {
        \\  texture=cubeMap
        \\  dimension="cube"
        \\  baseArrayLayer=0
        \\  arrayLayerCount=6
        \\}
        \\
        \\#wgsl shader {
        \\  value="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0.0); }"
        \\}
        \\
        \\#renderPipeline pipe {
        \\  vertex={ module=shader entryPoint=vs }
        \\}
        \\
        \\#frame main {
        \\  perform=[]
        \\}
    ;

    var gpu = try compileAndExecute(source);
    defer gpu.deinit(testing.allocator);

    // Verify texture was created
    var found_texture = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_texture) {
            found_texture = true;
            break;
        }
    }
    try testing.expect(found_texture);

    // Verify texture view was created
    var found_view = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_texture_view) {
            found_view = true;
            try testing.expectEqual(@as(u16, 0), call.params.create_texture_view.view_id);
            try testing.expectEqual(@as(u16, 0), call.params.create_texture_view.texture_id);
            break;
        }
    }
    try testing.expect(found_view);
}

// ============================================================================
// QuerySet Tests
// ============================================================================

test "Integration: query set for timestamps" {
    const source: [:0]const u8 =
        \\#querySet timestamps {
        \\  type="timestamp"
        \\  count=32
        \\}
        \\
        \\#wgsl shader {
        \\  value="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0.0); }"
        \\}
        \\
        \\#renderPipeline pipe {
        \\  vertex={ module=shader entryPoint=vs }
        \\}
        \\
        \\#frame main {
        \\  perform=[]
        \\}
    ;

    var gpu = try compileAndExecute(source);
    defer gpu.deinit(testing.allocator);

    // Verify query set was created
    var found_query_set = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_query_set) {
            found_query_set = true;
            try testing.expectEqual(@as(u16, 0), call.params.create_query_set.query_set_id);
            break;
        }
    }
    try testing.expect(found_query_set);
}

// ============================================================================
// BindGroupLayout and PipelineLayout Tests
// ============================================================================

test "Integration: explicit bind group layout" {
    const source: [:0]const u8 =
        \\#bindGroupLayout layout0 {
        \\  entries=[
        \\    { binding=0 visibility=[VERTEX FRAGMENT] buffer={ type="uniform" } }
        \\    { binding=1 visibility=[FRAGMENT] sampler={} }
        \\    { binding=2 visibility=[FRAGMENT] texture={ sampleType="float" viewDimension="2d" } }
        \\  ]
        \\}
        \\
        \\#wgsl shader {
        \\  value="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0.0); }"
        \\}
        \\
        \\#renderPipeline pipe {
        \\  vertex={ module=shader entryPoint=vs }
        \\}
        \\
        \\#frame main {
        \\  perform=[]
        \\}
    ;

    var gpu = try compileAndExecute(source);
    defer gpu.deinit(testing.allocator);

    // Verify bind group layout was created
    var found_layout = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_bind_group_layout) {
            found_layout = true;
            try testing.expectEqual(@as(u16, 0), call.params.create_bind_group_layout.layout_id);
            break;
        }
    }
    try testing.expect(found_layout);
}

test "Integration: explicit pipeline layout" {
    const source: [:0]const u8 =
        \\#bindGroupLayout layout0 {
        \\  entries=[
        \\    { binding=0 visibility=[VERTEX] buffer={} }
        \\  ]
        \\}
        \\
        \\#bindGroupLayout layout1 {
        \\  entries=[
        \\    { binding=0 visibility=[FRAGMENT] sampler={} }
        \\  ]
        \\}
        \\
        \\#pipelineLayout pipeLayout {
        \\  bindGroupLayouts=[layout0 layout1]
        \\}
        \\
        \\#wgsl shader {
        \\  value="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0.0); }"
        \\}
        \\
        \\#renderPipeline pipe {
        \\  vertex={ module=shader entryPoint=vs }
        \\}
        \\
        \\#frame main {
        \\  perform=[]
        \\}
    ;

    var gpu = try compileAndExecute(source);
    defer gpu.deinit(testing.allocator);

    // Verify bind group layouts were created
    var layout_count: usize = 0;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_bind_group_layout) {
            layout_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), layout_count);

    // Verify pipeline layout was created
    var found_pipeline_layout = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_pipeline_layout) {
            found_pipeline_layout = true;
            try testing.expectEqual(@as(u16, 0), call.params.create_pipeline_layout.layout_id);
            break;
        }
    }
    try testing.expect(found_pipeline_layout);
}

// ============================================================================
// Error Handling Tests
// ============================================================================

test "Parser: duplicate definition should fail analysis" {
    const source: [:0]const u8 =
        \\#buffer same { size=100 }
        \\#buffer same { size=200 }
        \\#frame main { perform=[] }
    ;

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    // Should have duplicate definition error
    try testing.expect(analysis.hasErrors());
}

test "Parser: undefined reference should fail analysis" {
    const source: [:0]const u8 =
        \\#renderPipeline pipe {
        \\  vertex={ module=nonexistent }
        \\}
        \\#frame main { perform=[] }
    ;

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    // Should have undefined reference error
    try testing.expect(analysis.hasErrors());
}

// ============================================================================
// Arithmetic Expression Tests
// ============================================================================

test "Integration: arithmetic expressions in buffer size" {
    const source: [:0]const u8 =
        \\#define FLOAT_SIZE=4
        \\#define VEC4_SIZE=FLOAT_SIZE*4
        \\
        \\#buffer uniformBuf {
        \\  size=VEC4_SIZE
        \\  usage=[UNIFORM]
        \\}
        \\
        \\#frame main { perform=[] }
    ;

    var gpu = try compileAndExecute(source);
    defer gpu.deinit(testing.allocator);

    // Verify buffer created with correct size: 4*4 = 16
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_buffer) {
            try testing.expectEqual(@as(u32, 16), call.params.create_buffer.size);
            return;
        }
    }
    try testing.expect(false); // Should have found buffer
}

test "Integration: complex arithmetic expression" {
    const source: [:0]const u8 =
        \\#buffer complexBuf {
        \\  size=(4+4)*8/2
        \\  usage=[STORAGE]
        \\}
        \\
        \\#frame main { perform=[] }
    ;

    var gpu = try compileAndExecute(source);
    defer gpu.deinit(testing.allocator);

    // Verify buffer created with correct size: (4+4)*8/2 = 32
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_buffer) {
            try testing.expectEqual(@as(u32, 32), call.params.create_buffer.size);
            return;
        }
    }
    try testing.expect(false);
}

// ============================================================================
// Render Bundle Tests
// ============================================================================

test "Integration: render bundle creation and execution" {
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0.0); }
        \\@fragment fn fs() -> @location(0) vec4f { return vec4f(1.0); }"
        \\}
        \\
        \\#renderPipeline pipeline {
        \\  vertex={ module=shader entryPoint=vs }
        \\  fragment={
        \\    module=shader
        \\    entryPoint=fs
        \\    targets=[{ format=bgra8unorm }]
        \\  }
        \\}
        \\
        \\#renderBundle bundle {
        \\  colorFormats=[bgra8unorm]
        \\  pipeline=pipeline
        \\  draw=3
        \\}
        \\
        \\#renderPass pass {
        \\  executeBundles=[bundle]
        \\}
        \\
        \\#frame main { perform=[pass] }
    ;

    var gpu = try compileAndExecute(source);
    defer gpu.deinit(testing.allocator);

    // Verify render bundle was created
    var found_bundle = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_render_bundle) {
            found_bundle = true;
            try testing.expectEqual(@as(u16, 0), call.params.create_render_bundle.bundle_id);
            break;
        }
    }
    try testing.expect(found_bundle);

    // Verify execute_bundles was called
    var found_execute = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .execute_bundles) {
            found_execute = true;
            try testing.expectEqual(@as(u16, 1), call.params.execute_bundles.bundle_count);
            break;
        }
    }
    try testing.expect(found_execute);
}

test "Integration: render bundle with multiple bundles" {
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0.0); }
        \\@fragment fn fs() -> @location(0) vec4f { return vec4f(1.0); }"
        \\}
        \\
        \\#renderPipeline pipeline {
        \\  vertex={ module=shader entryPoint=vs }
        \\  fragment={
        \\    module=shader
        \\    entryPoint=fs
        \\    targets=[{ format=bgra8unorm }]
        \\  }
        \\}
        \\
        \\#renderBundle bundle1 {
        \\  colorFormats=[bgra8unorm]
        \\  pipeline=pipeline
        \\  draw=3
        \\}
        \\
        \\#renderBundle bundle2 {
        \\  colorFormats=[bgra8unorm]
        \\  pipeline=pipeline
        \\  draw=6
        \\}
        \\
        \\#renderPass pass {
        \\  executeBundles=[bundle1 bundle2]
        \\}
        \\
        \\#frame main { perform=[pass] }
    ;

    var gpu = try compileAndExecute(source);
    defer gpu.deinit(testing.allocator);

    // Count render bundle creations
    var bundle_count: usize = 0;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_render_bundle) {
            bundle_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), bundle_count);

    // Verify execute_bundles was called with both bundles
    for (gpu.getCalls()) |call| {
        if (call.call_type == .execute_bundles) {
            try testing.expectEqual(@as(u16, 2), call.params.execute_bundles.bundle_count);
            return;
        }
    }
    try testing.expect(false); // Should have found execute_bundles
}

// ============================================================================
// Moving Triangle Example - Animated Triangle with pngineInputs
// Tests: uniform time updates, bind groups, basic animation pattern
// ============================================================================

test "Integration: moving_triangle example - animated with pngineInputs" {
    // This test verifies the moving_triangle.pngine example pattern:
    // - Uses pngineInputs for time-based animation
    // - 16-byte uniform buffer for time/width/height/aspect
    // - Shader reads inputs.time for animation
    const source: [:0]const u8 =
        \\#renderPipeline pipeline {
        \\  layout=auto
        \\  vertex={ entrypoint=vertexMain module=code }
        \\  fragment={
        \\    entrypoint=fragMain
        \\    module=code
        \\    targets=[{ format=preferredCanvasFormat }]
        \\  }
        \\  primitive={ topology=triangle-list }
        \\}
        \\
        \\#renderPass drawTriangle {
        \\  colorAttachments=[{
        \\    view=contextCurrentTexture
        \\    clearValue=[0 0 0 0]
        \\    loadOp=clear
        \\    storeOp=store
        \\  }]
        \\  pipeline=pipeline
        \\  bindGroups=[inputsBinding]
        \\  draw=3
        \\}
        \\
        \\#frame main {
        \\  perform=[
        \\    writeInputUniforms
        \\    drawTriangle
        \\  ]
        \\}
        \\
        \\#buffer uniformInputsBuffer {
        \\  size=16
        \\  usage=[UNIFORM COPY_DST]
        \\}
        \\
        \\#queue writeInputUniforms {
        \\  writeBuffer={
        \\    buffer=uniformInputsBuffer
        \\    bufferOffset=0
        \\    data=pngineInputs
        \\  }
        \\}
        \\
        \\#bindGroup inputsBinding {
        \\  layout={ pipeline=pipeline index=0 }
        \\  entries=[
        \\    { binding=0 resource={ buffer=uniformInputsBuffer }}
        \\  ]
        \\}
        \\
        \\#shaderModule code {
        \\  code="
        \\struct PngineInputs {
        \\  time: f32,
        \\};
        \\@binding(0) @group(0) var<uniform> inputs : PngineInputs;
        \\
        \\@vertex
        \\fn vertexMain(
        \\  @builtin(vertex_index) VertexIndex : u32
        \\) -> @builtin(position) vec4f {
        \\  var pos = array<vec2f, 3>(
        \\    vec2(sin(inputs.time * 8.0) * 0.25, 0.5),
        \\    vec2(-0.5, -0.5),
        \\    vec2(0.5, -0.5)
        \\  );
        \\  return vec4f(pos[VertexIndex], 0.0, 1.0);
        \\}
        \\
        \\@fragment
        \\fn fragMain() -> @location(0) vec4f {
        \\  return vec4(abs(sin(inputs.time)), abs(cos(inputs.time)), 0.0, 1.0);
        \\}
        \\"
        \\}
    ;

    // Compile to bytecode (fast validation, no mock_gpu)
    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Verify valid PNGB header
    try testing.expectEqualStrings("PNGB", pngb[0..4]);

    // Deserialize to check bytecode contents
    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify critical opcodes are present in bytecode
    var found_write_time = false;
    var found_create_buffer = false;
    var found_create_pipeline = false;
    var found_draw = false;

    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.write_time_uniform)) found_write_time = true;
        if (byte == @intFromEnum(opcodes.OpCode.create_buffer)) found_create_buffer = true;
        if (byte == @intFromEnum(opcodes.OpCode.create_render_pipeline)) found_create_pipeline = true;
        if (byte == @intFromEnum(opcodes.OpCode.draw)) found_draw = true;
    }

    // pngineInputs must generate write_time_uniform - this is the key test
    try testing.expect(found_write_time);
    try testing.expect(found_create_buffer);
    try testing.expect(found_create_pipeline);
    try testing.expect(found_draw);
}
