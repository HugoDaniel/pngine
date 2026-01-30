//! Minification + Uniform Access Tests
//!
//! Verifies that WGSL minification does NOT break:
//! - Entry point names used by render/compute pipelines
//! - Shader execution (same GPU calls with minified vs non-minified)
//! - Binding variable access patterns in shaders
//!
//! ## What Minification Preserves (by design)
//!
//! - Struct field names (e.g., `.time`, `.resolution`)
//! - Entry point names (e.g., `@vertex fn vertexMain`)
//! - Binding variable names (e.g., `var<uniform> uniforms`)
//!
//! ## What Minification Renames (internal only)
//!
//! - Struct type names (`struct Uniforms` -> `struct a`)
//! - Local variables (`let myValue` -> `let a`)
//! - Helper functions (`fn computeNormal()` -> `fn a()`)
//!
//! ## Test Strategy
//!
//! 1. Compile shader WITHOUT minification - verify works
//! 2. Compile same shader WITH minification - verify works
//! 3. Verify minified version is smaller
//! 4. Verify same GPU calls are produced
//! 5. Verify shader code still contains preserved names

const std = @import("std");
const testing = std.testing;
const Parser = @import("../Parser.zig").Parser;
const Analyzer = @import("../Analyzer.zig").Analyzer;
const Emitter = @import("../Emitter.zig").Emitter;

// Use bytecode module import
const bytecode_mod = @import("bytecode");
const format = bytecode_mod.format;
const string_table = bytecode_mod.string_table;

// Use executor module import
const executor_mod = @import("executor");
const mock_gpu = executor_mod.mock_gpu;
const Dispatcher = executor_mod.Dispatcher;

// Reflection module
const reflect = @import("reflect");

/// Helper: compile DSL source to PNGB bytecode with options.
fn compileSourceWithOptions(source: [:0]const u8, minify: bool) ![]u8 {
    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    if (analysis.hasErrors()) {
        return error.AnalysisError;
    }

    const options = Emitter.Options{
        .minify_shaders = minify,
    };

    return Emitter.emitWithOptions(testing.allocator, &ast, &analysis, options);
}

/// Helper: extract shader code from data section.
fn extractShaderCode(pngb: []const u8) ![]const u8 {
    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Get first data entry (shader code)
    if (module.data.count() > 0) {
        // Return a copy since module will be deinitialized
        return testing.allocator.dupe(u8, module.data.get(@enumFromInt(0)));
    }
    return &[_]u8{};
}

// ============================================================================
// Test: Basic shader with uniforms
// ============================================================================

const UNIFORM_SHADER_BASIC: [:0]const u8 =
    \\#wgsl shader {
    \\  value="
    \\struct Uniforms {
    \\    time: f32,
    \\    resolution: vec2f,
    \\    color: vec4f,
    \\}
    \\@group(0) @binding(0) var<uniform> uniforms: Uniforms;
    \\
    \\@vertex fn vertexMain(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    \\    let t = uniforms.time;
    \\    return vec4f(0.0, 0.0, 0.0, 1.0);
    \\}
    \\
    \\@fragment fn fragmentMain() -> @location(0) vec4f {
    \\    return uniforms.color;
    \\}
    \\"
    \\}
    \\
    \\#shaderModule shaderMod { code=shader }
    \\
    \\#buffer uniformBuffer {
    \\  size=32
    \\  usage=[UNIFORM COPY_DST]
    \\}
    \\
    \\#bindGroupLayout layout0 {
    \\  entries=[
    \\    { binding=0 visibility=[VERTEX FRAGMENT] buffer={ type=uniform } }
    \\  ]
    \\}
    \\
    \\#bindGroup group0 {
    \\  layout=layout0
    \\  entries=[
    \\    { binding=0 resource={ buffer=uniformBuffer } }
    \\  ]
    \\}
    \\
    \\#renderPipeline pipeline {
    \\  vertex={ module=shaderMod entryPoint=vertexMain }
    \\  fragment={
    \\    module=shaderMod
    \\    entryPoint=fragmentMain
    \\    targets=[{ format=bgra8unorm }]
    \\  }
    \\}
    \\
    \\#renderPass mainPass {
    \\  colorAttachments=[{ clearValue=[0 0 0 1] loadOp=clear storeOp=store }]
    \\  pipeline=pipeline
    \\  bindGroups=[group0]
    \\  draw=3
    \\}
    \\
    \\#frame main { perform=[mainPass] }
;

test "Minify: compiles without minification" {
    const pngb = try compileSourceWithOptions(UNIFORM_SHADER_BASIC, false);
    defer testing.allocator.free(pngb);

    try testing.expect(pngb.len > 0);

    // Should be valid PNGB
    const header: *const format.Header = @ptrCast(@alignCast(pngb.ptr));
    try header.validate();
}

test "Minify: compiles with minification" {
    // Skip if libminiray not linked
    if (!reflect.miniray_ffi.has_miniray_lib) {
        return error.SkipZigTest;
    }

    const pngb = try compileSourceWithOptions(UNIFORM_SHADER_BASIC, true);
    defer testing.allocator.free(pngb);

    try testing.expect(pngb.len > 0);

    // Should be valid PNGB
    const header: *const format.Header = @ptrCast(@alignCast(pngb.ptr));
    try header.validate();
}

test "Minify: minified shader is smaller than original" {
    // Skip if libminiray not linked
    if (!reflect.miniray_ffi.has_miniray_lib) {
        return error.SkipZigTest;
    }

    // Compile without minification
    const pngb_normal = try compileSourceWithOptions(UNIFORM_SHADER_BASIC, false);
    defer testing.allocator.free(pngb_normal);

    // Compile with minification
    const pngb_minified = try compileSourceWithOptions(UNIFORM_SHADER_BASIC, true);
    defer testing.allocator.free(pngb_minified);

    // Minified should be smaller (or at worst equal for trivial shaders)
    try testing.expect(pngb_minified.len <= pngb_normal.len);
}

test "Minify: execution produces same GPU call count" {
    // Skip if libminiray not linked
    if (!reflect.miniray_ffi.has_miniray_lib) {
        return error.SkipZigTest;
    }

    // Compile both versions
    const pngb_normal = try compileSourceWithOptions(UNIFORM_SHADER_BASIC, false);
    defer testing.allocator.free(pngb_normal);

    const pngb_minified = try compileSourceWithOptions(UNIFORM_SHADER_BASIC, true);
    defer testing.allocator.free(pngb_minified);

    // Execute both
    var module_normal = try format.deserialize(testing.allocator, pngb_normal);
    defer module_normal.deinit(testing.allocator);

    var module_minified = try format.deserialize(testing.allocator, pngb_minified);
    defer module_minified.deinit(testing.allocator);

    var gpu_normal: mock_gpu.MockGPU = .empty;
    defer gpu_normal.deinit(testing.allocator);

    var gpu_minified: mock_gpu.MockGPU = .empty;
    defer gpu_minified.deinit(testing.allocator);

    var dispatcher_normal = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu_normal, &module_normal);
    defer dispatcher_normal.deinit();
    try dispatcher_normal.executeAll(testing.allocator);

    var dispatcher_minified = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu_minified, &module_minified);
    defer dispatcher_minified.deinit();
    try dispatcher_minified.executeAll(testing.allocator);

    // Same number of GPU calls
    try testing.expectEqual(gpu_normal.call_count(), gpu_minified.call_count());
}

test "Minify: execution produces same GPU call types" {
    // Skip if libminiray not linked
    if (!reflect.miniray_ffi.has_miniray_lib) {
        return error.SkipZigTest;
    }

    // Compile both versions
    const pngb_normal = try compileSourceWithOptions(UNIFORM_SHADER_BASIC, false);
    defer testing.allocator.free(pngb_normal);

    const pngb_minified = try compileSourceWithOptions(UNIFORM_SHADER_BASIC, true);
    defer testing.allocator.free(pngb_minified);

    // Execute both
    var module_normal = try format.deserialize(testing.allocator, pngb_normal);
    defer module_normal.deinit(testing.allocator);

    var module_minified = try format.deserialize(testing.allocator, pngb_minified);
    defer module_minified.deinit(testing.allocator);

    var gpu_normal: mock_gpu.MockGPU = .empty;
    defer gpu_normal.deinit(testing.allocator);

    var gpu_minified: mock_gpu.MockGPU = .empty;
    defer gpu_minified.deinit(testing.allocator);

    var dispatcher_normal = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu_normal, &module_normal);
    defer dispatcher_normal.deinit();
    try dispatcher_normal.executeAll(testing.allocator);

    var dispatcher_minified = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu_minified, &module_minified);
    defer dispatcher_minified.deinit();
    try dispatcher_minified.executeAll(testing.allocator);

    // Same call types in same order
    const calls_normal = gpu_normal.get_calls();
    const calls_minified = gpu_minified.get_calls();

    for (calls_normal, calls_minified) |cn, cm| {
        try testing.expectEqual(cn.call_type, cm.call_type);
    }
}

// ============================================================================
// Test: Shader code content verification
// ============================================================================

test "Minify: entry point names preserved in shader code" {
    // Skip if libminiray not linked
    if (!reflect.miniray_ffi.has_miniray_lib) {
        return error.SkipZigTest;
    }

    const pngb = try compileSourceWithOptions(UNIFORM_SHADER_BASIC, true);
    defer testing.allocator.free(pngb);

    const shader_code = try extractShaderCode(pngb);
    defer if (shader_code.len > 0) testing.allocator.free(shader_code);

    // Entry points should be preserved in minified code
    // miniray preserves function names decorated with @vertex/@fragment/@compute
    try testing.expect(std.mem.indexOf(u8, shader_code, "vertexMain") != null);
    try testing.expect(std.mem.indexOf(u8, shader_code, "fragmentMain") != null);
}

test "Minify: binding variable names preserved in shader code" {
    // Skip if libminiray not linked
    if (!reflect.miniray_ffi.has_miniray_lib) {
        return error.SkipZigTest;
    }

    const pngb = try compileSourceWithOptions(UNIFORM_SHADER_BASIC, true);
    defer testing.allocator.free(pngb);

    const shader_code = try extractShaderCode(pngb);
    defer if (shader_code.len > 0) testing.allocator.free(shader_code);

    // Binding variable name should be preserved (uniforms)
    // miniray preserves binding variable names by default
    try testing.expect(std.mem.indexOf(u8, shader_code, "uniforms") != null);
}

test "Minify: struct field access preserved in shader code" {
    // Skip if libminiray not linked
    if (!reflect.miniray_ffi.has_miniray_lib) {
        return error.SkipZigTest;
    }

    const pngb = try compileSourceWithOptions(UNIFORM_SHADER_BASIC, true);
    defer testing.allocator.free(pngb);

    const shader_code = try extractShaderCode(pngb);
    defer if (shader_code.len > 0) testing.allocator.free(shader_code);

    // Struct field accesses should be preserved
    // The minifier preserves .time and .color
    try testing.expect(std.mem.indexOf(u8, shader_code, ".time") != null);
    try testing.expect(std.mem.indexOf(u8, shader_code, ".color") != null);
}

// ============================================================================
// Test: Complex shader with multiple uniforms
// ============================================================================

const COMPLEX_SHADER: [:0]const u8 =
    \\#wgsl shader {
    \\  value="
    \\struct Camera {
    \\    viewMatrix: mat4x4f,
    \\    projMatrix: mat4x4f,
    \\    position: vec3f,
    \\    fov: f32,
    \\}
    \\
    \\struct Light {
    \\    direction: vec3f,
    \\    intensity: f32,
    \\    color: vec4f,
    \\}
    \\
    \\@group(0) @binding(0) var<uniform> camera: Camera;
    \\@group(0) @binding(1) var<uniform> light: Light;
    \\
    \\fn calculateLighting(normal: vec3f) -> vec4f {
    \\    let ndotl = max(dot(normal, light.direction), 0.0);
    \\    return light.color * ndotl * light.intensity;
    \\}
    \\
    \\@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    \\    return camera.projMatrix * camera.viewMatrix * vec4f(0.0, 0.0, 0.0, 1.0);
    \\}
    \\
    \\@fragment fn fs() -> @location(0) vec4f {
    \\    return calculateLighting(vec3f(0.0, 1.0, 0.0));
    \\}
    \\"
    \\}
    \\
    \\#shaderModule complexShader { code=shader }
    \\
    \\#buffer cameraBuffer { size=144 usage=[UNIFORM COPY_DST] }
    \\#buffer lightBuffer { size=32 usage=[UNIFORM COPY_DST] }
    \\
    \\#bindGroupLayout layout0 {
    \\  entries=[
    \\    { binding=0 visibility=[VERTEX] buffer={ type=uniform } }
    \\    { binding=1 visibility=[FRAGMENT] buffer={ type=uniform } }
    \\  ]
    \\}
    \\
    \\#bindGroup group0 {
    \\  layout=layout0
    \\  entries=[
    \\    { binding=0 resource={ buffer=cameraBuffer } }
    \\    { binding=1 resource={ buffer=lightBuffer } }
    \\  ]
    \\}
    \\
    \\#renderPipeline pipeline {
    \\  vertex={ module=complexShader entryPoint=vs }
    \\  fragment={
    \\    module=complexShader
    \\    entryPoint=fs
    \\    targets=[{ format=bgra8unorm }]
    \\  }
    \\}
    \\
    \\#renderPass mainPass {
    \\  colorAttachments=[{ clearValue=[0 0 0 1] loadOp=clear storeOp=store }]
    \\  pipeline=pipeline
    \\  bindGroups=[group0]
    \\  draw=3
    \\}
    \\
    \\#frame main { perform=[mainPass] }
;

test "Minify: complex shader with multiple uniforms compiles" {
    // Skip if libminiray not linked
    if (!reflect.miniray_ffi.has_miniray_lib) {
        return error.SkipZigTest;
    }

    const pngb = try compileSourceWithOptions(COMPLEX_SHADER, true);
    defer testing.allocator.free(pngb);

    try testing.expect(pngb.len > 0);

    // Verify execution
    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    try testing.expect(gpu.call_count() > 0);
}

test "Minify: multiple binding names preserved" {
    // Skip if libminiray not linked
    if (!reflect.miniray_ffi.has_miniray_lib) {
        return error.SkipZigTest;
    }

    const pngb = try compileSourceWithOptions(COMPLEX_SHADER, true);
    defer testing.allocator.free(pngb);

    const shader_code = try extractShaderCode(pngb);
    defer if (shader_code.len > 0) testing.allocator.free(shader_code);

    // Both binding names should be preserved
    try testing.expect(std.mem.indexOf(u8, shader_code, "camera") != null);
    try testing.expect(std.mem.indexOf(u8, shader_code, "light") != null);
}

test "Minify: struct field accesses in complex shader preserved" {
    // Skip if libminiray not linked
    if (!reflect.miniray_ffi.has_miniray_lib) {
        return error.SkipZigTest;
    }

    const pngb = try compileSourceWithOptions(COMPLEX_SHADER, true);
    defer testing.allocator.free(pngb);

    const shader_code = try extractShaderCode(pngb);
    defer if (shader_code.len > 0) testing.allocator.free(shader_code);

    // Field accesses should be preserved
    try testing.expect(std.mem.indexOf(u8, shader_code, ".viewMatrix") != null);
    try testing.expect(std.mem.indexOf(u8, shader_code, ".projMatrix") != null);
    try testing.expect(std.mem.indexOf(u8, shader_code, ".direction") != null);
    try testing.expect(std.mem.indexOf(u8, shader_code, ".intensity") != null);
}

// ============================================================================
// Test: Math constants substitution before minification
// ============================================================================

const MATH_CONSTANTS_SHADER: [:0]const u8 =
    \\#wgsl shader {
    \\  value="
    \\struct Uniforms {
    \\    angle: f32,
    \\}
    \\@group(0) @binding(0) var<uniform> u: Uniforms;
    \\
    \\@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    \\    let a = u.angle * PI;
    \\    let b = sin(a * TAU);
    \\    return vec4f(b, 0.0, 0.0, 1.0);
    \\}
    \\
    \\@fragment fn fs() -> @location(0) vec4f {
    \\    return vec4f(E / 3.0, 0.0, 0.0, 1.0);
    \\}
    \\"
    \\}
    \\
    \\#shaderModule shaderMod { code=shader }
    \\
    \\#buffer uniformBuffer { size=16 usage=[UNIFORM COPY_DST] }
    \\
    \\#bindGroupLayout layout0 {
    \\  entries=[
    \\    { binding=0 visibility=[VERTEX FRAGMENT] buffer={ type=uniform } }
    \\  ]
    \\}
    \\
    \\#bindGroup group0 {
    \\  layout=layout0
    \\  entries=[
    \\    { binding=0 resource={ buffer=uniformBuffer } }
    \\  ]
    \\}
    \\
    \\#renderPipeline pipeline {
    \\  vertex={ module=shaderMod entryPoint=vs }
    \\  fragment={
    \\    module=shaderMod
    \\    entryPoint=fs
    \\    targets=[{ format=bgra8unorm }]
    \\  }
    \\}
    \\
    \\#renderPass mainPass {
    \\  colorAttachments=[{ clearValue=[0 0 0 1] loadOp=clear storeOp=store }]
    \\  pipeline=pipeline
    \\  bindGroups=[group0]
    \\  draw=3
    \\}
    \\
    \\#frame main { perform=[mainPass] }
;

test "Minify: math constants substituted before minification" {
    // Skip if libminiray not linked
    if (!reflect.miniray_ffi.has_miniray_lib) {
        return error.SkipZigTest;
    }

    const pngb = try compileSourceWithOptions(MATH_CONSTANTS_SHADER, true);
    defer testing.allocator.free(pngb);

    // Should compile without errors (PI, TAU, E are substituted with values)
    try testing.expect(pngb.len > 0);

    const shader_code = try extractShaderCode(pngb);
    defer if (shader_code.len > 0) testing.allocator.free(shader_code);

    // Constants should be replaced with numeric values
    // PI -> 3.141592653589793
    // TAU -> 6.283185307179586
    // E -> 2.718281828459045
    try testing.expect(std.mem.indexOf(u8, shader_code, "PI") == null);
    try testing.expect(std.mem.indexOf(u8, shader_code, "TAU") == null);
    try testing.expect(std.mem.indexOf(u8, shader_code, " E ") == null); // Space around to avoid matching in other words
}
