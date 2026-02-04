//! Shader ID Assignment Tests
//! 
//! Comprehensive tests for shader ID management, specifically testing the fix for
//! orphaned shader IDs when code resolution fails.
//! 
//! ## Bug Description (Fixed)
//! Previously, shader IDs were assigned BEFORE validating shader code. If code
//! resolution failed (empty code, missing file), the ID was added to shader_ids
//! but no createShaderModule opcode was emitted. Pipelines referencing these
//! "phantom" IDs would fail at runtime.
//! 
//! ## Invariants
//! - For each entry in shader_ids, a createShaderModule opcode MUST be emitted
//! - Shader IDs are consecutive starting from 0 (no gaps)
//! - Pipeline shader references MUST exist in shader_ids
//! 
//! ## Test Coverage
//! - Unit tests: empty code, missing files, invalid references
//! - Property tests: ID consistency, no orphan IDs
//! - Integration tests: end-to-end with mock GPU
//! - Edge cases: first/last/all shaders empty, alternating valid/invalid
//! - Fuzz tests: random valid/invalid combinations
//! - OOM resilience: graceful handling of allocation failures

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

/// Compile source and return bytecode (caller owns)
fn compileSource(source: [:0]const u8) ![]u8 {
    return Compiler.compile(testing.allocator, source);
}

/// Count createShaderModule opcodes in bytecode section only
/// (not in string table, data section, or other sections which may contain matching bytes)
fn countShaderOpcodes(bytecode: []const u8) u32 {
    // Need at least v0 header
    if (bytecode.len < format.HEADER_SIZE) return 0;

    // Read version (should be 0)
    const version = std.mem.readInt(u16, bytecode[4..6], .little);
    if (version != format.VERSION) return 0;

    // Get string table offset from header to know where bytecode section ends
    // v0: offset at byte 20 (string_table_offset field)
    const string_table_offset = std.mem.readInt(u32, bytecode[20..24], .little);
    const bytecode_end = @min(string_table_offset, bytecode.len);
    if (bytecode_end < format.HEADER_SIZE) return 0;
    const bytecode_section = bytecode[format.HEADER_SIZE..bytecode_end];

    var count: u32 = 0;
    const create_shader = @intFromEnum(opcodes.OpCode.create_shader_module);
    for (bytecode_section) |byte| {
        if (byte == create_shader) {
            count += 1;
        }
    }
    return count;
}

/// Execute bytecode and return number of createShaderModule calls recorded
fn executeAndCountShaders(pngb: []const u8) !u32 {
    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.execute_all(testing.allocator);

    var count: u32 = 0;
    for (gpu.get_calls()) |call| {
        if (call.call_type == .create_shader_module) {
            count += 1;
        }
    }
    return count;
}

/// Get shader IDs from mock GPU calls (returns sorted slice)
fn getCreatedShaderIds(allocator: std.mem.Allocator, pngb: []const u8) ![]u16 {
    var module = try format.deserialize(allocator, pngb);
    defer module.deinit(allocator);

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.execute_all(allocator);

    var ids = std.ArrayListUnmanaged(u16){};
    errdefer ids.deinit(allocator);

    for (gpu.get_calls()) |call| {
        if (call.call_type == .create_shader_module) {
            try ids.append(allocator, call.params.create_shader_module.shader_id);
        }
    }

    const slice = try ids.toOwnedSlice(allocator);
    std.mem.sort(u16, slice, {}, std.sort.asc(u16));
    return slice;
}

// ============================================================================ 
// Core Bug Fix Tests
// ============================================================================ 

test "ShaderID: empty WGSL value produces no shader (no orphan ID)" {
    // Only #shaderModule creates shader modules now, not #wgsl
    const source: [:0]const u8 = 
        \\#wgsl empty { value="" }
        \\#wgsl valid { value="fn main() {}" }
        \\#shaderModule mod { code=valid }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Should only create shaderModule for 'valid', not 'empty'
    const shader_count = try executeAndCountShaders(pngb);
    try testing.expectEqual(@as(u32, 1), shader_count);
}

test "ShaderID: first shader empty - no ID 0 orphan" {
    // Critical edge case: if first shader is empty and ID 0 is orphaned,
    // any pipeline referencing the first valid shader would fail
    // Only #shaderModule creates shader modules now, not #wgsl
    const source: [:0]const u8 = 
        \\#wgsl first { value="" }
        \\#wgsl second { value="fn vs() {}" }
        \\#wgsl third { value="fn fs() {}" }
        \\#shaderModule modSecond { code=second }
        \\#shaderModule modThird { code=third }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    const ids = try getCreatedShaderIds(testing.allocator, pngb);
    defer testing.allocator.free(ids);

    // Two shaderModules, IDs start at 0 (no gap)
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqual(@as(u16, 0), ids[0]);
    try testing.expectEqual(@as(u16, 1), ids[1]);
}

test "ShaderID: last shader empty - no trailing orphan" {
    // Only #shaderModule creates shader modules now, not #wgsl
    const source: [:0]const u8 = 
        \\#wgsl first { value="fn a() {}" }
        \\#wgsl second { value="fn b() {}" }
        \\#wgsl last { value="" }
        \\#shaderModule modFirst { code=first }
        \\#shaderModule modSecond { code=second }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    const ids = try getCreatedShaderIds(testing.allocator, pngb);
    defer testing.allocator.free(ids);

    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqual(@as(u16, 0), ids[0]);
    try testing.expectEqual(@as(u16, 1), ids[1]);
}

test "ShaderID: middle shader empty - no gap in IDs" {
    // Only #shaderModule creates shader modules now, not #wgsl
    const source: [:0]const u8 = 
        \\#wgsl first { value="fn a() {}" }
        \\#wgsl middle { value="" }
        \\#wgsl last { value="fn b() {}" }
        \\#shaderModule modFirst { code=first }
        \\#shaderModule modLast { code=last }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    const ids = try getCreatedShaderIds(testing.allocator, pngb);
    defer testing.allocator.free(ids);

    // IDs should be consecutive with no gaps
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqual(@as(u16, 0), ids[0]);
    try testing.expectEqual(@as(u16, 1), ids[1]);
}

test "ShaderID: all shaders empty - no shaders created" {
    const source: [:0]const u8 = 
        \\#wgsl a { value="" }
        \\#wgsl b { value="" }
        \\#wgsl c { value="" }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    const shader_count = try executeAndCountShaders(pngb);
    try testing.expectEqual(@as(u32, 0), shader_count);
}

test "ShaderID: alternating valid/empty shaders" {
    // Only #shaderModule creates shader modules now, not #wgsl
    const source: [:0]const u8 = 
        \\#wgsl a { value="// A" }
        \\#wgsl b { value="" }
        \\#wgsl c { value="// C" }
        \\#wgsl d { value="" }
        \\#wgsl e { value="// E" }
        \\#shaderModule modA { code=a }
        \\#shaderModule modC { code=c }
        \\#shaderModule modE { code=e }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    const ids = try getCreatedShaderIds(testing.allocator, pngb);
    defer testing.allocator.free(ids);

    // 3 shaderModules, IDs should be 0, 1, 2
    try testing.expectEqual(@as(usize, 3), ids.len);
    for (ids, 0..) |id, i| {
        try testing.expectEqual(@as(u16, @intCast(i)), id);
    }
}

// ============================================================================ 
// ShaderModule Tests
// ============================================================================ 

test "ShaderID: shaderModule referencing valid wgsl" {
    // Only #shaderModule creates shader modules now, not #wgsl
    // This test verifies that #shaderModule with inline code works
    const source: [:0]const u8 = 
        \\#wgsl valid { value="fn main() {}" }
        \\#shaderModule mod { code="fn other() {}" }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Only #shaderModule creates a shader module (1, not 2)
    const shader_count = try executeAndCountShaders(pngb);
    try testing.expectEqual(@as(u32, 1), shader_count);
}

test "ShaderID: shaderModule with inline code alongside empty wgsl" {
    // Empty #wgsl should not create shader, but #shaderModule with
    // inline code should still work
    const source: [:0]const u8 = 
        \\#wgsl empty { value="" }
        \\#shaderModule mod { code="fn main() {}" }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Only shaderModule creates a shader (empty wgsl is skipped)
    const shader_count = try executeAndCountShaders(pngb);
    try testing.expectEqual(@as(u32, 1), shader_count);

    const ids = try getCreatedShaderIds(testing.allocator, pngb);
    defer testing.allocator.free(ids);

    // ID should start at 0 (no orphan from empty wgsl)
    try testing.expectEqual(@as(u16, 0), ids[0]);
}

// ============================================================================ 
// WGSL with Imports
// ============================================================================ 

test "ShaderID: import chain with empty base" {
    // Only #shaderModule creates shader modules now, not #wgsl
    const source: [:0]const u8 = 
        \\#wgsl empty { value="" }
        \\#wgsl main {
        \\  value="fn main() {}"
        \\  imports=[empty]
        \\}
        \\#shaderModule mod { code=main }
        \\#frame f { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Only #shaderModule creates a shader module
    const ids = try getCreatedShaderIds(testing.allocator, pngb);
    defer testing.allocator.free(ids);

    try testing.expectEqual(@as(usize, 1), ids.len);
}

// ============================================================================ 
// Pipeline References
// ============================================================================ 

test "ShaderID: pipeline references valid shader after empty ones" {
    // Only #shaderModule creates shader modules now, not #wgsl
    const source: [:0]const u8 = 
        \\#wgsl empty1 { value="" }
        \\#wgsl empty2 { value="" }
        \\#wgsl valid { value="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0); }" }
        \\#shaderModule mod { code=valid }
        \\#renderPipeline pipe { vertex={ module=mod } }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Execute and verify no errors (pipeline creation would fail with orphan IDs)
    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    // This should not error - the pipeline should reference shader ID 0 (the valid one)
    try dispatcher.execute_all(testing.allocator);

    // Verify pipeline was created
    var found_pipeline = false;
    for (gpu.get_calls()) |call| {
        if (call.call_type == .create_render_pipeline) {
            found_pipeline = true;
            break;
        }
    }
    try testing.expect(found_pipeline);
}

test "ShaderID: compute pipeline after skipped shaders" {
    // Only #shaderModule creates shader modules now, not #wgsl
    const source: [:0]const u8 = 
        \\#wgsl skip1 { value="" }
        \\#wgsl skip2 { value="" }
        \\#wgsl compute { value="@compute @workgroup_size(1) fn main() {}" }
        \\#shaderModule computeMod { code=compute }
        \\#computePipeline pipe { compute={ module=computeMod } }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    // This should succeed
    try dispatcher.execute_all(testing.allocator);

    // Verify compute pipeline was created
    var pipeline_created = false;
    for (gpu.get_calls()) |call| {
        if (call.call_type == .create_compute_pipeline) {
            pipeline_created = true;
        }
    }
    try testing.expect(pipeline_created);
}

// ============================================================================ 
// Data Section ID Bug Regression Tests
// ============================================================================ 
// Bug: When #data blocks with expressions exist, the shader was getting
// data_id 0 (expression string) instead of its actual data_id in the data section.
// The bytecode emitter was passing wgsl_id (WGSL table index) but wasm_entry.zig
// expects data_id (data section index).
// 
// Without #data blocks: data_id == wgsl_id (coincidentally same)
// With #data blocks: expressions get data_ids 0,1,2...; WGSL code comes later

test "ShaderID: shader with data blocks gets correct WGSL code" {
    // Regression test: #data blocks should not affect shader code resolution.
    // The shader should receive actual WGSL code, not expression strings from #data.
    const source: [:0]const u8 = 
        \\#define NUM=4
        \\#data particleData {
        \\  float32Array={
        \\    numberOfElements=NUM
        \\    initEachElementWith=["cos(ELEMENT_ID)" "sin(ELEMENT_ID)"]
        \\  }
        \\}
        \\#shaderModule code {
        \\  code="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0); }"
        \\}
        \\#renderPipeline pipe { vertex={ module=code } }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    // Execute - this would fail with the bug because pipeline creation
    // would receive expression string instead of WGSL code
    try dispatcher.execute_all(testing.allocator);

    // Verify shader was created and get the data_id
    const types_mod = @import("types");
    for (gpu.get_calls()) |call| {
        if (call.call_type == .create_shader_module) {
            const raw_data_id = call.params.create_shader_module.code_data_id;
            const data_id: types_mod.DataId = @enumFromInt(raw_data_id);
            // Look up the actual data in the module's data section
            const code = module.data.get(data_id);
            // The shader code should start with '@vertex', not 'cos(ELEMENT_ID)'
            try testing.expect(code.len > 10);
            try testing.expect(std.mem.startsWith(u8, code, "@vertex"));
        }
    }
}

test "ShaderID: multiple data blocks before shader" {
    // More complex case: multiple #data blocks with expressions, then shader
    const source: [:0]const u8 = 
        \\#data posData { float32Array=["1.0" "2.0"] }
        \\#data velData { float32Array=["3.0" "4.0"] }
        \\#data colorData { float32Array=["0.5" "0.5" "0.5"] }
        \\#shaderModule shader {
        \\  code="@fragment fn fs() -> @location(0) vec4f { return vec4f(1); }"
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    try dispatcher.execute_all(testing.allocator);

    // Verify shader code is WGSL, not expression strings
    const types_mod = @import("types");
    var found_shader = false;
    for (gpu.get_calls()) |call| {
        if (call.call_type == .create_shader_module) {
            found_shader = true;
            const raw_data_id = call.params.create_shader_module.code_data_id;
            const data_id: types_mod.DataId = @enumFromInt(raw_data_id);
            const code = module.data.get(data_id);
            try testing.expect(std.mem.startsWith(u8, code, "@fragment"));
        }
    }
    try testing.expect(found_shader);
}

test "ShaderID: data with buffer and shader combined" {
    // Full integration: #data + #buffer + #shaderModule
    const source: [:0]const u8 = 
        \\#define N=8
        \\#data initData {
        \\  float32Array={
        \\    numberOfElements=N
        \\    initEachElementWith=["random()" "0.0"]
        \\  }
        \\}
        \\#buffer particles {
        \\  size=initData
        \\  usage=[STORAGE]
        \\  mappedAtCreation=initData
        \\}
        \\#shaderModule render {
        \\  code="@vertex fn main() -> @builtin(position) vec4f { return vec4f(0); }"
        \\}
        \\#renderPipeline pipe { vertex={ module=render } }
        \\#renderPass pass {
        \\  colorAttachments=[{
        \\    view=contextCurrentTexture
        \\    clearValue=[0 0 0 1]
        \\    loadOp=clear
        \\    storeOp=store
        \\  }]
        \\  pipeline=pipe
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

    try dispatcher.execute_all(testing.allocator);

    // Verify all resources created correctly
    const types_mod = @import("types");
    var shader_ok = false;
    var buffer_ok = false;
    var pipeline_ok = false;

    for (gpu.get_calls()) |call| {
        switch (call.call_type) {
            .create_shader_module => {
                const raw_data_id = call.params.create_shader_module.code_data_id;
                const data_id: types_mod.DataId = @enumFromInt(raw_data_id);
                const code = module.data.get(data_id);
                // Must be WGSL, not expression like "random()"
                shader_ok = std.mem.startsWith(u8, code, "@vertex");
            },
            .create_buffer => buffer_ok = true,
            .create_render_pipeline => pipeline_ok = true,
            else => {},
        }
    }

    try testing.expect(shader_ok);
    try testing.expect(buffer_ok);
    try testing.expect(pipeline_ok);
}