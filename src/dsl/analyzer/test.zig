//! Analyzer Tests
//!
//! All tests for the DSL semantic analyzer.
//! Tests verify reference resolution, cycle detection, symbol tables, and expression evaluation.

const std = @import("std");
const testing = std.testing;
const Analyzer = @import("../Analyzer.zig").Analyzer;
const Parser = @import("../Parser.zig").Parser;

fn parseAndAnalyze(source: [:0]const u8) !Analyzer.AnalysisResult {
    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);
    return Analyzer.analyze(testing.allocator, &ast);
}

// ----------------------------------------------------------------------------
// Reference Resolution Tests
// ----------------------------------------------------------------------------

test "Analyzer: valid reference" {
    const source: [:0]const u8 =
        \\#wgsl shader { value="fn main() {}" }
        \\#renderPipeline pipe { vertex={ module=$wgsl.shader } }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "Analyzer: undefined reference" {
    const source: [:0]const u8 =
        \\#renderPipeline pipe { vertex={ module=$wgsl.missing } }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.errors.len);
    try testing.expectEqual(Analyzer.AnalysisError.Kind.undefined_reference, result.errors[0].kind);
}

test "Analyzer: multiple undefined references" {
    const source: [:0]const u8 =
        \\#renderPipeline pipe {
        \\  vertex={ module=$wgsl.missing1 }
        \\  fragment={ module=$wgsl.missing2 }
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.errors.len);
}

test "Analyzer: invalid namespace" {
    const source: [:0]const u8 =
        \\#renderPipeline pipe { vertex={ module=$invalid.name } }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.errors.len);
    try testing.expectEqual(Analyzer.AnalysisError.Kind.invalid_reference_namespace, result.errors[0].kind);
}

test "Analyzer: reference to buffer" {
    const source: [:0]const u8 =
        \\#buffer vertices { size=100 usage=[VERTEX] }
        \\#renderPass pass { vertexBuffer=$buffer.vertices }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
}

// ----------------------------------------------------------------------------
// Duplicate Definition Tests
// ----------------------------------------------------------------------------

test "Analyzer: duplicate definition" {
    const source: [:0]const u8 =
        \\#wgsl shader { value="fn a() {}" }
        \\#wgsl shader { value="fn b() {}" }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.errors.len);
    try testing.expectEqual(Analyzer.AnalysisError.Kind.duplicate_definition, result.errors[0].kind);
}

test "Analyzer: same name different namespace" {
    const source: [:0]const u8 =
        \\#wgsl main { value="" }
        \\#buffer main { size=100 usage=[UNIFORM] }
        \\#frame main { perform=[] }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Same name in different namespaces is OK
    try testing.expectEqual(@as(usize, 0), result.errors.len);
}

// ----------------------------------------------------------------------------
// Cycle Detection Tests
// ----------------------------------------------------------------------------

test "Analyzer: circular import detected" {
    const source: [:0]const u8 =
        \\#wgsl a { imports=[$wgsl.b] value="" }
        \\#wgsl b { imports=[$wgsl.a] value="" }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expect(result.errors.len > 0);

    var has_cycle_error = false;
    for (result.errors) |err| {
        if (err.kind == .circular_dependency) {
            has_cycle_error = true;
            break;
        }
    }
    try testing.expect(has_cycle_error);
}

test "Analyzer: self-import cycle" {
    const source: [:0]const u8 =
        \\#wgsl a { imports=[$wgsl.a] value="" }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    var has_cycle_error = false;
    for (result.errors) |err| {
        if (err.kind == .circular_dependency) {
            has_cycle_error = true;
            break;
        }
    }
    try testing.expect(has_cycle_error);
}

test "Analyzer: valid import chain" {
    const source: [:0]const u8 =
        \\#wgsl common { value="fn helper() {}" }
        \\#wgsl shader { imports=[$wgsl.common] value="fn main() { helper(); }" }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // No cycles, should pass
    var has_cycle_error = false;
    for (result.errors) |err| {
        if (err.kind == .circular_dependency) {
            has_cycle_error = true;
            break;
        }
    }
    try testing.expect(!has_cycle_error);
}

test "Analyzer: three-way cycle" {
    const source: [:0]const u8 =
        \\#wgsl a { imports=[$wgsl.b] value="" }
        \\#wgsl b { imports=[$wgsl.c] value="" }
        \\#wgsl c { imports=[$wgsl.a] value="" }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    var has_cycle_error = false;
    for (result.errors) |err| {
        if (err.kind == .circular_dependency) {
            has_cycle_error = true;
            break;
        }
    }
    try testing.expect(has_cycle_error);
}

// ----------------------------------------------------------------------------
// Shader Deduplication Tests
// ----------------------------------------------------------------------------

test "Analyzer: shader deduplication" {
    const source: [:0]const u8 =
        \\#wgsl common { value="fn helper() {}" }
        \\#wgsl shaderA { value="@vertex fn vs() {}" }
        \\#wgsl shaderB { value="@fragment fn fs() {}" }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
    try testing.expectEqual(@as(usize, 3), result.shader_fragments.len);

    // All different content, so different data_ids
    var ids = std.AutoHashMap(u16, void).init(testing.allocator);
    defer ids.deinit();

    for (result.shader_fragments) |frag| {
        try ids.put(frag.data_id, {});
    }
    try testing.expectEqual(@as(usize, 3), ids.count());
}

test "Analyzer: identical shaders share data_id" {
    const source: [:0]const u8 =
        \\#wgsl shaderA { value="fn same() {}" }
        \\#wgsl shaderB { value="fn same() {}" }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.shader_fragments.len);

    // Same content, should have same data_id
    try testing.expectEqual(result.shader_fragments[0].data_id, result.shader_fragments[1].data_id);
}

// ----------------------------------------------------------------------------
// Symbol Table Tests
// ----------------------------------------------------------------------------

test "Analyzer: symbol table population" {
    const source: [:0]const u8 =
        \\#wgsl shader { value="" }
        \\#buffer buf { size=100 }
        \\#frame main { perform=[] }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), result.symbols.wgsl.count());
    try testing.expectEqual(@as(u32, 1), result.symbols.buffer.count());
    try testing.expectEqual(@as(u32, 1), result.symbols.frame.count());

    try testing.expect(result.symbols.wgsl.get("shader") != null);
    try testing.expect(result.symbols.buffer.get("buf") != null);
    try testing.expect(result.symbols.frame.get("main") != null);
}

// ----------------------------------------------------------------------------
// Complex Example Tests
// ----------------------------------------------------------------------------

test "Analyzer: simpleTriangle example" {
    const source: [:0]const u8 =
        \\#wgsl triangleShader { value="@vertex fn vs() {}" }
        \\#renderPipeline pipeline {
        \\  layout=auto
        \\  vertex={ entryPoint=vs module=$wgsl.triangleShader }
        \\}
        \\#renderPass pass {
        \\  pipeline=$renderPipeline.pipeline
        \\  draw=3
        \\}
        \\#frame main {
        \\  perform=[$renderPass.pass]
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
    try testing.expectEqual(@as(u32, 1), result.symbols.wgsl.count());
    try testing.expectEqual(@as(u32, 1), result.symbols.render_pipeline.count());
    try testing.expectEqual(@as(u32, 1), result.symbols.render_pass.count());
    try testing.expectEqual(@as(u32, 1), result.symbols.frame.count());
}

test "Analyzer: empty input" {
    const source: [:0]const u8 = "";

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
}

// ----------------------------------------------------------------------------
// Bare Name Resolution Tests
// ----------------------------------------------------------------------------

test "Analyzer: bare name resolution for module" {
    const source: [:0]const u8 =
        \\#shaderModule code { code="" }
        \\#renderPipeline pipe { vertex={ module=code } }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Should resolve module=code to $shaderModule.code
    try testing.expectEqual(@as(usize, 0), result.errors.len);
    try testing.expect(result.resolved_identifiers.count() > 0);

    // Find the resolved identifier
    var found = false;
    var it = result.resolved_identifiers.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.name, "code")) {
            try testing.expectEqual(Analyzer.Namespace.shader_module, entry.value_ptr.namespace);
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Analyzer: bare name resolution for pipeline" {
    const source: [:0]const u8 =
        \\#shaderModule code { code="" }
        \\#renderPipeline myPipeline { vertex={ module=code } }
        \\#renderPass pass { pipeline=myPipeline }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
    try testing.expect(result.resolved_identifiers.count() > 0);

    // Find the resolved identifier for pipeline
    var found = false;
    var it = result.resolved_identifiers.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.name, "myPipeline")) {
            try testing.expectEqual(Analyzer.Namespace.render_pipeline, entry.value_ptr.namespace);
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Analyzer: bare name resolution for buffer" {
    const source: [:0]const u8 =
        \\#buffer uniformInputsBuffer { size=4 usage=[UNIFORM] }
        \\#bindGroup bg { entries=[{ buffer=uniformInputsBuffer }] }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
    try testing.expect(result.resolved_identifiers.count() > 0);
}

test "Analyzer: special values not resolved" {
    const source: [:0]const u8 =
        \\#shaderModule code { code="" }
        \\#renderPipeline pipe { layout=auto vertex={ module=code } }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // 'auto' should not be resolved to any namespace
    try testing.expectEqual(@as(usize, 0), result.errors.len);

    // Check that 'auto' was not added to resolved_identifiers
    var it = result.resolved_identifiers.iterator();
    while (it.next()) |entry| {
        try testing.expect(!std.mem.eql(u8, entry.value_ptr.name, "auto"));
    }
}

test "Analyzer: explicit reference not double-resolved" {
    const source: [:0]const u8 =
        \\#shaderModule code { code="" }
        \\#renderPipeline pipe { vertex={ module=$shaderModule.code } }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Explicit reference should not be in resolved_identifiers
    try testing.expectEqual(@as(usize, 0), result.errors.len);
    // The module value is a reference node, not identifier_value
    // so resolved_identifiers should be empty for this case
    try testing.expectEqual(@as(u32, 0), result.resolved_identifiers.count());
}

// ----------------------------------------------------------------------------
// Required Property Validation Tests (based on WebGPU spec)
// ----------------------------------------------------------------------------

test "Analyzer: buffer missing size error" {
    const source: [:0]const u8 =
        \\#buffer buf { usage=[UNIFORM] }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Should have error for missing 'size'
    try testing.expect(result.errors.len > 0);
    var found_size_error = false;
    for (result.errors) |err| {
        if (err.kind == .missing_required_property and std.mem.eql(u8, err.message, "size")) {
            found_size_error = true;
            break;
        }
    }
    try testing.expect(found_size_error);
}

test "Analyzer: buffer missing usage error" {
    const source: [:0]const u8 =
        \\#buffer buf { size=256 }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Should have error for missing 'usage'
    try testing.expect(result.errors.len > 0);
    var found_usage_error = false;
    for (result.errors) |err| {
        if (err.kind == .missing_required_property and std.mem.eql(u8, err.message, "usage")) {
            found_usage_error = true;
            break;
        }
    }
    try testing.expect(found_usage_error);
}

test "Analyzer: buffer with all required properties" {
    const source: [:0]const u8 =
        \\#buffer buf { size=256 usage=[UNIFORM COPY_DST] }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Should have no validation errors
    for (result.errors) |err| {
        if (err.kind == .missing_required_property) {
            try testing.expect(false);
        }
    }
}

test "Analyzer: texture missing required properties" {
    const source: [:0]const u8 =
        \\#texture tex { format=bgra8unorm }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Should have error for missing 'usage' (format is present, width/height have defaults)
    var missing_count: usize = 0;
    for (result.errors) |err| {
        if (err.kind == .missing_required_property) {
            missing_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), missing_count);
}

test "Analyzer: texture with all required properties" {
    const source: [:0]const u8 =
        \\#texture tex {
        \\  width=512
        \\  height=512
        \\  format=bgra8unorm
        \\  usage=[RENDER_ATTACHMENT]
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Should have no missing_required_property errors
    for (result.errors) |err| {
        if (err.kind == .missing_required_property) {
            try testing.expect(false);
        }
    }
}

test "Analyzer: renderPipeline missing vertex error" {
    const source: [:0]const u8 =
        \\#renderPipeline pipe { layout=auto }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Should have error for missing 'vertex'
    var found_vertex_error = false;
    for (result.errors) |err| {
        if (err.kind == .missing_required_property and std.mem.eql(u8, err.message, "vertex")) {
            found_vertex_error = true;
            break;
        }
    }
    try testing.expect(found_vertex_error);
}

test "Analyzer: renderPipeline with vertex is valid" {
    const source: [:0]const u8 =
        \\#shaderModule code { code="" }
        \\#renderPipeline pipe { vertex={ module=code } }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Should have no missing_required_property errors
    for (result.errors) |err| {
        if (err.kind == .missing_required_property) {
            try testing.expect(false);
        }
    }
}

test "Analyzer: shaderModule missing code error" {
    const source: [:0]const u8 =
        \\#shaderModule shader { label=myShader }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Should have error for missing 'code'
    var found_code_error = false;
    for (result.errors) |err| {
        if (err.kind == .missing_required_property and std.mem.eql(u8, err.message, "code")) {
            found_code_error = true;
            break;
        }
    }
    try testing.expect(found_code_error);
}

test "Analyzer: wgsl missing value error" {
    const source: [:0]const u8 =
        \\#wgsl shader { imports=[] }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Should have error for missing 'value'
    var found_value_error = false;
    for (result.errors) |err| {
        if (err.kind == .missing_required_property and std.mem.eql(u8, err.message, "value")) {
            found_value_error = true;
            break;
        }
    }
    try testing.expect(found_value_error);
}

test "Analyzer: empty texture throws error" {
    const source: [:0]const u8 =
        \\#texture tex { }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Should have 2 errors: missing format, usage (width/height have defaults)
    var missing_count: usize = 0;
    for (result.errors) |err| {
        if (err.kind == .missing_required_property) {
            missing_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), missing_count);
}

// ----------------------------------------------------------------------------
// Queue Symbol Table Tests
// ----------------------------------------------------------------------------

test "Analyzer: queue symbol table population" {
    const source: [:0]const u8 =
        \\#buffer buf { size=64 usage=[UNIFORM COPY_DST] }
        \\#queue myQueue { writeBuffer={ buffer=$buffer.buf data="test" } }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), result.symbols.queue.count());
    try testing.expect(result.symbols.queue.get("myQueue") != null);
}

test "Analyzer: queue reference validation" {
    const source: [:0]const u8 =
        \\#queue myQueue { writeBuffer={ buffer=$buffer.missing data="test" } }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Should have error for undefined buffer reference
    try testing.expect(result.errors.len > 0);
    var found_undefined = false;
    for (result.errors) |err| {
        if (err.kind == .undefined_reference) {
            found_undefined = true;
            break;
        }
    }
    try testing.expect(found_undefined);
}
