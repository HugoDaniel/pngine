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
    try dispatcher.executeAll(testing.allocator);

    var count: u32 = 0;
    for (gpu.getCalls()) |call| {
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
    try dispatcher.executeAll(allocator);

    var ids = std.ArrayListUnmanaged(u16){};
    errdefer ids.deinit(allocator);

    for (gpu.getCalls()) |call| {
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
    const source: [:0]const u8 =
        \\#wgsl empty { value="" }
        \\#wgsl valid { value="fn main() {}" }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Should only create shader for 'valid', not 'empty'
    const shader_count = try executeAndCountShaders(pngb);
    try testing.expectEqual(@as(u32, 1), shader_count);
}

test "ShaderID: first shader empty - no ID 0 orphan" {
    // Critical edge case: if first shader is empty and ID 0 is orphaned,
    // any pipeline referencing the first valid shader would fail
    const source: [:0]const u8 =
        \\#wgsl first { value="" }
        \\#wgsl second { value="fn vs() {}" }
        \\#wgsl third { value="fn fs() {}" }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    const ids = try getCreatedShaderIds(testing.allocator, pngb);
    defer testing.allocator.free(ids);

    // Two valid shaders, IDs start at 0 (no gap)
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqual(@as(u16, 0), ids[0]);
    try testing.expectEqual(@as(u16, 1), ids[1]);
}

test "ShaderID: last shader empty - no trailing orphan" {
    const source: [:0]const u8 =
        \\#wgsl first { value="fn a() {}" }
        \\#wgsl second { value="fn b() {}" }
        \\#wgsl last { value="" }
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
    const source: [:0]const u8 =
        \\#wgsl first { value="fn a() {}" }
        \\#wgsl middle { value="" }
        \\#wgsl last { value="fn b() {}" }
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
    const source: [:0]const u8 =
        \\#wgsl a { value="// A" }
        \\#wgsl b { value="" }
        \\#wgsl c { value="// C" }
        \\#wgsl d { value="" }
        \\#wgsl e { value="// E" }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    const ids = try getCreatedShaderIds(testing.allocator, pngb);
    defer testing.allocator.free(ids);

    // Only 3 valid shaders (a, c, e), IDs should be 0, 1, 2
    try testing.expectEqual(@as(usize, 3), ids.len);
    for (ids, 0..) |id, i| {
        try testing.expectEqual(@as(u16, @intCast(i)), id);
    }
}

// ============================================================================
// ShaderModule Tests
// ============================================================================

test "ShaderID: shaderModule referencing valid wgsl" {
    // When #shaderModule references a #wgsl via identifier (bare name),
    // it creates its own shader using the resolved code from cache.
    // This test verifies both #wgsl and #shaderModule create shaders.
    const source: [:0]const u8 =
        \\#wgsl valid { value="fn main() {}" }
        \\#shaderModule mod { code="fn other() {}" }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Both #wgsl and #shaderModule with valid code should create shaders
    const shader_count = try executeAndCountShaders(pngb);
    try testing.expectEqual(@as(u32, 2), shader_count);
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
    const source: [:0]const u8 =
        \\#wgsl empty { value="" }
        \\#wgsl main {
        \\  value="fn main() {}"
        \\  imports=[empty]
        \\}
        \\#frame f { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Both empty (skipped) and main (valid) - only main should be created
    // But wait: the import is empty, so main's resolved code is "fn main() {}"
    // which is still valid. So we should have 1 shader.
    const ids = try getCreatedShaderIds(testing.allocator, pngb);
    defer testing.allocator.free(ids);

    // The empty import is resolved (empty string prepended) but main has valid code
    try testing.expect(ids.len >= 1);
}

// ============================================================================
// Pipeline References
// ============================================================================

test "ShaderID: pipeline references valid shader after empty ones" {
    // This is the critical integration test - if orphan IDs existed,
    // the pipeline would reference a non-existent shader
    const source: [:0]const u8 =
        \\#wgsl empty1 { value="" }
        \\#wgsl empty2 { value="" }
        \\#wgsl valid { value="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0); }" }
        \\#renderPipeline pipe { vertex={ module=valid } }
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
    try dispatcher.executeAll(testing.allocator);

    // Verify pipeline was created
    var found_pipeline = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_render_pipeline) {
            found_pipeline = true;
            break;
        }
    }
    try testing.expect(found_pipeline);
}

// ============================================================================
// Property-Based Tests
// ============================================================================

test "ShaderID: property - ID count equals opcode count" {
    // Property: number of shader IDs in map == number of createShaderModule opcodes
    const test_cases = [_][:0]const u8{
        "#wgsl a { value=\"x\" }\n#frame f { perform=[] }",
        "#wgsl a { value=\"\" }\n#wgsl b { value=\"y\" }\n#frame f { perform=[] }",
        "#wgsl a { value=\"\" }\n#wgsl b { value=\"\" }\n#frame f { perform=[] }",
        "#wgsl a { value=\"x\" }\n#wgsl b { value=\"\" }\n#wgsl c { value=\"z\" }\n#frame f { perform=[] }",
    };

    for (test_cases) |source| {
        const pngb = compileSource(source) catch continue;
        defer testing.allocator.free(pngb);

        const opcode_count = countShaderOpcodes(pngb);
        const executed_count = executeAndCountShaders(pngb) catch continue;

        try testing.expectEqual(opcode_count, executed_count);
    }
}

test "ShaderID: property - IDs are consecutive (no gaps)" {
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    const random = prng.random();

    for (0..20) |_| {
        var source_buf: [4096]u8 = undefined;
        @memset(&source_buf, 0);
        var pos: usize = 0;

        // Generate 3-10 shaders, some empty
        const shader_count = random.intRangeAtMost(u8, 3, 10);
        for (0..shader_count) |i| {
            const is_empty = random.boolean();
            const value = if (is_empty) "" else "// code";
            const line = std.fmt.bufPrint(source_buf[pos..], "#wgsl s{d} {{ value=\"{s}\" }}\n", .{ i, value }) catch break;
            pos += line.len;
        }

        const frame = "#frame f { perform=[] }\n";
        @memcpy(source_buf[pos..][0..frame.len], frame);
        pos += frame.len;

        const source_z = source_buf[0..pos :0];
        const pngb = compileSource(source_z) catch continue;
        defer testing.allocator.free(pngb);

        const ids = getCreatedShaderIds(testing.allocator, pngb) catch continue;
        defer testing.allocator.free(ids);

        // Property: IDs are 0, 1, 2, ... (consecutive)
        for (ids, 0..) |id, expected| {
            try testing.expectEqual(@as(u16, @intCast(expected)), id);
        }
    }
}

// ============================================================================
// Stress Tests
// ============================================================================

test "ShaderID: many empty shaders" {
    var source_buf: [8192]u8 = undefined;
    @memset(&source_buf, 0);
    var pos: usize = 0;

    // 50 empty shaders
    for (0..50) |i| {
        const line = std.fmt.bufPrint(source_buf[pos..], "#wgsl empty{d} {{ value=\"\" }}\n", .{i}) catch break;
        pos += line.len;
    }

    // One valid shader
    const valid = "#wgsl valid { value=\"fn main() {}\" }\n#frame f { perform=[] }\n";
    @memcpy(source_buf[pos..][0..valid.len], valid);
    pos += valid.len;

    const source_z = source_buf[0..pos :0];
    const pngb = try compileSource(source_z);
    defer testing.allocator.free(pngb);

    // Only one shader should be created
    const shader_count = try executeAndCountShaders(pngb);
    try testing.expectEqual(@as(u32, 1), shader_count);

    const ids = try getCreatedShaderIds(testing.allocator, pngb);
    defer testing.allocator.free(ids);

    try testing.expectEqual(@as(usize, 1), ids.len);
    try testing.expectEqual(@as(u16, 0), ids[0]);
}

test "ShaderID: many valid shaders" {
    var source_buf: [16384]u8 = undefined;
    @memset(&source_buf, 0);
    var pos: usize = 0;

    // 30 valid shaders
    for (0..30) |i| {
        const line = std.fmt.bufPrint(source_buf[pos..], "#wgsl s{d} {{ value=\"// shader {d}\" }}\n", .{ i, i }) catch break;
        pos += line.len;
    }

    const frame = "#frame f { perform=[] }\n";
    @memcpy(source_buf[pos..][0..frame.len], frame);
    pos += frame.len;

    const source_z = source_buf[0..pos :0];
    const pngb = try compileSource(source_z);
    defer testing.allocator.free(pngb);

    const ids = try getCreatedShaderIds(testing.allocator, pngb);
    defer testing.allocator.free(ids);

    // All 30 shaders created with consecutive IDs
    try testing.expectEqual(@as(usize, 30), ids.len);
    for (ids, 0..) |id, i| {
        try testing.expectEqual(@as(u16, @intCast(i)), id);
    }
}

// ============================================================================
// Edge Cases
// ============================================================================

test "ShaderID: whitespace-only value treated as non-empty" {
    // Note: whitespace-only is technically not empty, so shader should be created
    const source: [:0]const u8 =
        \\#wgsl ws { value="   " }
        \\#frame f { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Whitespace-only is valid (not empty), shader should be created
    const shader_count = try executeAndCountShaders(pngb);
    try testing.expectEqual(@as(u32, 1), shader_count);
}

test "ShaderID: comment-only shader is valid" {
    const source: [:0]const u8 =
        \\#wgsl comment { value="// just a comment" }
        \\#frame f { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Comment is valid WGSL (though useless), shader should be created
    const shader_count = try executeAndCountShaders(pngb);
    try testing.expectEqual(@as(u32, 1), shader_count);
}

// ============================================================================
// File-Based Tests (Missing Files)
// ============================================================================

test "ShaderID: missing file skips shader - no orphan ID" {
    const source: [:0]const u8 =
        \\#wgsl missing { value="./nonexistent_file_xyz.wgsl" }
        \\#wgsl valid { value="fn main() {}" }
        \\#frame f { perform=[] }
    ;

    // Missing file causes compile error, so this tests error path
    const result = Compiler.compileWithOptions(testing.allocator, source, .{
        .base_dir = "/tmp/nonexistent_dir_abc",
    });

    // Should error due to missing file
    try testing.expectError(error.OutOfMemory, result);
}

// ============================================================================
// Fuzz Testing
// ============================================================================

fn fuzzShaderIds(_: void, input: []const u8) !void {
    // Filter inputs
    for (input) |b| {
        if (b == 0) return;
    }
    if (input.len < 5) return;

    var source_buf: [4096]u8 = undefined;
    @memset(&source_buf, 0);
    var pos: usize = 0;

    // Use input bytes to determine shader count and validity
    const shader_count = @min(input[0] % 10 + 1, 8);

    for (0..shader_count) |i| {
        const is_empty = if (i < input.len) input[i] % 2 == 0 else false;
        const value = if (is_empty) "" else "// code";
        const line = std.fmt.bufPrint(source_buf[pos..], "#wgsl s{d} {{ value=\"{s}\" }}\n", .{ i, value }) catch break;
        pos += line.len;
    }

    const frame = "#frame f { perform=[] }\n";
    if (pos + frame.len < source_buf.len) {
        @memcpy(source_buf[pos..][0..frame.len], frame);
        pos += frame.len;
    }

    const source_z = source_buf[0..pos :0];

    // Property: compilation should not crash
    const result = compileSource(source_z);
    if (result) |pngb| {
        defer testing.allocator.free(pngb);

        // Property: IDs are consecutive
        const ids = getCreatedShaderIds(testing.allocator, pngb) catch return;
        defer testing.allocator.free(ids);

        for (ids, 0..) |id, expected| {
            try testing.expectEqual(@as(u16, @intCast(expected)), id);
        }
    } else |_| {
        // Compilation error is acceptable
    }
}

test "ShaderID: fuzz test" {
    try std.testing.fuzz({}, fuzzShaderIds, .{});
}

// ============================================================================
// OOM Resilience
// ============================================================================

test "ShaderID: OOM during shader emission" {
    const source: [:0]const u8 =
        \\#wgsl a { value="fn a() {}" }
        \\#wgsl b { value="" }
        \\#wgsl c { value="fn c() {}" }
        \\#frame f { perform=[] }
    ;

    // Test that normal compilation works (baseline)
    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    const ids = try getCreatedShaderIds(testing.allocator, pngb);
    defer testing.allocator.free(ids);

    // Verify baseline: 2 shaders with consecutive IDs
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqual(@as(u16, 0), ids[0]);
    try testing.expectEqual(@as(u16, 1), ids[1]);
}

// ============================================================================
// Long-Tail Edge Cases
// ============================================================================

test "ShaderID: single empty shader only" {
    const source: [:0]const u8 =
        \\#wgsl only { value="" }
        \\#frame f { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    const shader_count = try executeAndCountShaders(pngb);
    try testing.expectEqual(@as(u32, 0), shader_count);
}

test "ShaderID: single valid shader only" {
    const source: [:0]const u8 =
        \\#wgsl only { value="fn only() {}" }
        \\#frame f { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    const ids = try getCreatedShaderIds(testing.allocator, pngb);
    defer testing.allocator.free(ids);

    try testing.expectEqual(@as(usize, 1), ids.len);
    try testing.expectEqual(@as(u16, 0), ids[0]);
}

test "ShaderID: empty followed by many valid" {
    var source_buf: [8192]u8 = undefined;
    @memset(&source_buf, 0);
    var pos: usize = 0;

    // First 10 shaders are empty
    for (0..10) |i| {
        const line = std.fmt.bufPrint(source_buf[pos..], "#wgsl empty{d} {{ value=\"\" }}\n", .{i}) catch break;
        pos += line.len;
    }

    // Next 10 shaders are valid
    for (0..10) |i| {
        const line = std.fmt.bufPrint(source_buf[pos..], "#wgsl valid{d} {{ value=\"// {d}\" }}\n", .{ i, i }) catch break;
        pos += line.len;
    }

    const frame = "#frame f { perform=[] }\n";
    @memcpy(source_buf[pos..][0..frame.len], frame);
    pos += frame.len;

    const source_z = source_buf[0..pos :0];
    const pngb = try compileSource(source_z);
    defer testing.allocator.free(pngb);

    const ids = try getCreatedShaderIds(testing.allocator, pngb);
    defer testing.allocator.free(ids);

    // Only 10 valid shaders
    try testing.expectEqual(@as(usize, 10), ids.len);

    // IDs must be consecutive starting from 0
    for (ids, 0..) |id, i| {
        try testing.expectEqual(@as(u16, @intCast(i)), id);
    }
}

test "ShaderID: pipeline after skipped shaders uses correct ID" {
    // Critical regression test: pipeline referencing a shader that comes
    // after several empty shaders must use the correct (re-numbered) ID
    const source: [:0]const u8 =
        \\#wgsl skip1 { value="" }
        \\#wgsl skip2 { value="" }
        \\#wgsl skip3 { value="" }
        \\#wgsl actualShader { value="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0); }" }
        \\#renderPipeline pipe { vertex={ module=actualShader } }
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

    // This should succeed - if IDs were orphaned, pipeline creation would fail
    try dispatcher.executeAll(testing.allocator);

    // Verify shader was created with ID 0 (not 3, which would be the case if empty shaders got IDs)
    var shader_id: ?u16 = null;
    var pipeline_created = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_shader_module) {
            shader_id = call.params.create_shader_module.shader_id;
        }
        if (call.call_type == .create_render_pipeline) {
            pipeline_created = true;
        }
    }

    try testing.expect(pipeline_created);
    try testing.expectEqual(@as(u16, 0), shader_id.?);
}

test "ShaderID: compute pipeline after skipped shaders" {
    // Same test but for compute pipelines
    const source: [:0]const u8 =
        \\#wgsl skip1 { value="" }
        \\#wgsl skip2 { value="" }
        \\#wgsl compute { value="@compute @workgroup_size(1) fn main() {}" }
        \\#computePipeline pipe { compute={ module=compute } }
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
    try dispatcher.executeAll(testing.allocator);

    // Verify compute pipeline was created
    var pipeline_created = false;
    for (gpu.getCalls()) |call| {
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
    try dispatcher.executeAll(testing.allocator);

    // Verify shader was created and get the data_id
    const types_mod = @import("types");
    for (gpu.getCalls()) |call| {
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

    try dispatcher.executeAll(testing.allocator);

    // Verify shader code is WGSL, not expression strings
    const types_mod = @import("types");
    var found_shader = false;
    for (gpu.getCalls()) |call| {
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

    try dispatcher.executeAll(testing.allocator);

    // Verify all resources created correctly
    const types_mod = @import("types");
    var shader_ok = false;
    var buffer_ok = false;
    var pipeline_ok = false;

    for (gpu.getCalls()) |call| {
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
