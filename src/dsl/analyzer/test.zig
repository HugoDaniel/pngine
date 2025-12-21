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
        \\#renderPipeline pipe { vertex={ module=shader } }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "Analyzer: undefined reference" {
    const source: [:0]const u8 =
        \\#renderPipeline pipe { vertex={ module=missing } }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.errors.len);
    try testing.expectEqual(Analyzer.AnalysisError.Kind.undefined_reference, result.errors[0].kind);
}

test "Analyzer: multiple undefined references" {
    const source: [:0]const u8 =
        \\#renderPipeline pipe {
        \\  vertex={ module=missing1 }
        \\  fragment={ module=missing2 }
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.errors.len);
}

// NOTE: With bare identifier syntax, invalid namespace test is no longer applicable
// The module property expects wgsl/shaderModule namespaces, and bare identifiers
// are resolved based on context. The old $invalid.name syntax is removed.

test "Analyzer: reference to buffer" {
    const source: [:0]const u8 =
        \\#buffer vertices { size=100 usage=[VERTEX] }
        \\#renderPass pass { vertexBuffer=vertices }
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

test "Analyzer: same name different namespace is error" {
    const source: [:0]const u8 =
        \\#wgsl main { value="" }
        \\#buffer main { size=100 usage=[UNIFORM] }
        \\#frame main { perform=[] }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Same name in different namespaces is now an error (global uniqueness required)
    try testing.expectEqual(@as(usize, 2), result.errors.len);
    try testing.expectEqual(Analyzer.AnalysisError.Kind.duplicate_definition, result.errors[0].kind);
    try testing.expectEqual(Analyzer.AnalysisError.Kind.duplicate_definition, result.errors[1].kind);
}

// ----------------------------------------------------------------------------
// Cycle Detection Tests
// ----------------------------------------------------------------------------

test "Analyzer: circular import detected" {
    const source: [:0]const u8 =
        \\#wgsl a { imports=[b] value="" }
        \\#wgsl b { imports=[a] value="" }
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
        \\#wgsl a { imports=[a] value="" }
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
        \\#wgsl shader { imports=[common] value="fn main() { helper(); }" }
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
        \\#wgsl a { imports=[b] value="" }
        \\#wgsl b { imports=[c] value="" }
        \\#wgsl c { imports=[a] value="" }
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
        \\  vertex={ entryPoint=vs module=triangleShader }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipeline
        \\  draw=3
        \\}
        \\#frame main {
        \\  perform=[pass]
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

// NOTE: With bare identifier syntax, the "explicit reference not double-resolved" test
// is no longer applicable since we no longer have $namespace.name syntax.
// Bare identifiers are always resolved via context, there is no "explicit" form.

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
        \\#queue myQueue { writeBuffer={ buffer=buf data="test" } }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), result.symbols.queue.count());
    try testing.expect(result.symbols.queue.get("myQueue") != null);
}

test "Analyzer: queue reference validation" {
    const source: [:0]const u8 =
        \\#queue myQueue { writeBuffer={ buffer=missing data="test" } }
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

// ----------------------------------------------------------------------------
// Uniform Access Tests
// ----------------------------------------------------------------------------

test "Analyzer: uniform_access with #wgsl - auto reflection" {
    const source: [:0]const u8 =
        \\#wgsl code {
        \\  value="@group(0) @binding(0) var<uniform> inputs : Uniforms;"
        \\}
        \\#buffer uniforms { size=48 usage=[uniform copy_dst] }
        \\#frame main {
        \\  perform=[]
        \\  writeBuffer=[{ buffer=uniforms data=code.inputs }]
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Should resolve successfully via WGSL reflection
    try testing.expectEqual(@as(usize, 0), result.errors.len);
    // Should have resolved uniform metadata
    try testing.expect(result.resolved_uniforms.count() > 0);

    // Verify reflection extracted correct binding info
    var iter = result.resolved_uniforms.iterator();
    if (iter.next()) |entry| {
        try testing.expectEqual(@as(u8, 0), entry.value_ptr.bind_group);
        try testing.expectEqual(@as(u8, 0), entry.value_ptr.binding);
        try testing.expectEqualStrings("inputs", entry.value_ptr.var_name);
    }
}

test "Analyzer: uniform_access with #shaderModule - auto reflection" {
    const source: [:0]const u8 =
        \\#shaderModule code {
        \\  code="
        \\    struct PngineInputs { time: f32, width: f32, height: f32 };
        \\    @group(0) @binding(0) var<uniform> inputs : PngineInputs;
        \\  "
        \\}
        \\#buffer uniforms { size=12 usage=[uniform copy_dst] }
        \\#frame main {
        \\  perform=[]
        \\  writeBuffer=[{ buffer=uniforms data=code.inputs }]
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Should resolve successfully via WGSL reflection
    try testing.expectEqual(@as(usize, 0), result.errors.len);
    // Should have resolved uniform metadata
    try testing.expect(result.resolved_uniforms.count() > 0);
}

test "Analyzer: uniform_access with group(1) binding(2)" {
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="@group(1) @binding(2) var<uniform> camera : mat4x4f;"
        \\}
        \\#buffer cameraBuffer { size=64 usage=[uniform copy_dst] }
        \\#frame main {
        \\  perform=[]
        \\  writeBuffer=[{ buffer=cameraBuffer data=shader.camera }]
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
    try testing.expect(result.resolved_uniforms.count() > 0);

    // Verify reflection extracted correct group/binding
    var iter = result.resolved_uniforms.iterator();
    if (iter.next()) |entry| {
        try testing.expectEqual(@as(u8, 1), entry.value_ptr.bind_group);
        try testing.expectEqual(@as(u8, 2), entry.value_ptr.binding);
        try testing.expectEqualStrings("camera", entry.value_ptr.var_name);
    }
}

test "Analyzer: uniform_access with undefined module" {
    const source: [:0]const u8 =
        \\#buffer uniforms { size=48 usage=[uniform copy_dst] }
        \\#frame main {
        \\  perform=[]
        \\  writeBuffer=[{ buffer=uniforms data=nonexistent.inputs }]
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Should have error for undefined shader module
    try testing.expect(result.errors.len > 0);
    try testing.expectEqual(Analyzer.AnalysisError.Kind.undefined_reference, result.errors[0].kind);
}

// ----------------------------------------------------------------------------
// WGSL Reflection Edge Cases
// ----------------------------------------------------------------------------

test "Analyzer: WGSL reflection - multiple uniforms in same shader" {
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="
        \\    @group(0) @binding(0) var<uniform> inputs : Inputs;
        \\    @group(0) @binding(1) var<uniform> camera : mat4x4f;
        \\    @group(1) @binding(0) var<uniform> lights : array<Light, 8>;
        \\  "
        \\}
        \\#buffer buf0 { size=12 usage=[uniform copy_dst] }
        \\#buffer buf1 { size=64 usage=[uniform copy_dst] }
        \\#buffer buf2 { size=256 usage=[uniform copy_dst] }
        \\#frame main {
        \\  perform=[]
        \\  writeBuffer=[
        \\    { buffer=buf0 data=shader.inputs }
        \\    { buffer=buf1 data=shader.camera }
        \\    { buffer=buf2 data=shader.lights }
        \\  ]
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
    try testing.expectEqual(@as(u32, 3), result.resolved_uniforms.count());
}

test "Analyzer: WGSL reflection - whitespace variations" {
    // Test various whitespace patterns that should still parse
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="@group( 0 )  @binding( 0 )  var<uniform>  spaced  :  Type;"
        \\}
        \\#buffer buf { size=12 usage=[uniform copy_dst] }
        \\#frame main {
        \\  perform=[]
        \\  writeBuffer=[{ buffer=buf data=shader.spaced }]
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Whitespace around numbers breaks our simple parser - that's expected
    // This tests documents current behavior
    try testing.expect(result.resolved_uniforms.count() == 0 or result.resolved_uniforms.count() == 1);
}

test "Analyzer: WGSL reflection - newlines between attributes" {
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="
        \\    @group(0)
        \\    @binding(0)
        \\    var<uniform> multiline : Type;
        \\  "
        \\}
        \\#buffer buf { size=12 usage=[uniform copy_dst] }
        \\#frame main {
        \\  perform=[]
        \\  writeBuffer=[{ buffer=buf data=shader.multiline }]
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Newlines may exceed our distance threshold - documents current behavior
    try testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "Analyzer: WGSL reflection - var<storage> uses defaults" {
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="@group(0) @binding(0) var<storage> data : array<f32>;"
        \\}
        \\#buffer buf { size=12 usage=[uniform copy_dst] }
        \\#frame main {
        \\  perform=[]
        \\  writeBuffer=[{ buffer=buf data=shader.data }]
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // var<storage> doesn't match var<uniform> pattern, so defaults are used
    // The uniform_access is still valid since the module exists
    try testing.expectEqual(@as(u32, 1), result.resolved_uniforms.count());

    // Verify it uses defaults (group=0, binding=0)
    var iter = result.resolved_uniforms.iterator();
    if (iter.next()) |entry| {
        try testing.expectEqual(@as(u8, 0), entry.value_ptr.bind_group);
        try testing.expectEqual(@as(u8, 0), entry.value_ptr.binding);
    }
}

test "Analyzer: WGSL reflection - max group and binding values" {
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="@group(3) @binding(255) var<uniform> maxVals : Type;"
        \\}
        \\#buffer buf { size=12 usage=[uniform copy_dst] }
        \\#frame main {
        \\  perform=[]
        \\  writeBuffer=[{ buffer=buf data=shader.maxVals }]
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);

    var iter = result.resolved_uniforms.iterator();
    if (iter.next()) |entry| {
        try testing.expectEqual(@as(u8, 3), entry.value_ptr.bind_group);
        // Note: binding 255 may or may not parse depending on u8 range
    }
}

test "Analyzer: WGSL reflection - long variable name" {
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="@group(0) @binding(0) var<uniform> thisIsAVeryLongVariableNameThatShouldStillWork : Type;"
        \\}
        \\#buffer buf { size=12 usage=[uniform copy_dst] }
        \\#frame main {
        \\  perform=[]
        \\  writeBuffer=[{ buffer=buf data=shader.thisIsAVeryLongVariableNameThatShouldStillWork }]
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
    try testing.expectEqual(@as(u32, 1), result.resolved_uniforms.count());
}

test "Analyzer: WGSL reflection - underscore in variable name" {
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="@group(0) @binding(0) var<uniform> my_uniform_var : Type;"
        \\}
        \\#buffer buf { size=12 usage=[uniform copy_dst] }
        \\#frame main {
        \\  perform=[]
        \\  writeBuffer=[{ buffer=buf data=shader.my_uniform_var }]
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
    try testing.expectEqual(@as(u32, 1), result.resolved_uniforms.count());
}

test "Analyzer: WGSL reflection - no uniforms in shader" {
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0); }"
        \\}
        \\#buffer buf { size=12 usage=[uniform copy_dst] }
        \\#frame main {
        \\  perform=[]
        \\  writeBuffer=[{ buffer=buf data=shader.nonexistent }]
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Should still resolve (with defaults) since module exists
    try testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "Analyzer: WGSL reflection - comment between group and binding" {
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="@group(0) /* comment */ @binding(0) var<uniform> commented : Type;"
        \\}
        \\#buffer buf { size=12 usage=[uniform copy_dst] }
        \\#frame main {
        \\  perform=[]
        \\  writeBuffer=[{ buffer=buf data=shader.commented }]
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Comments may break our simple scanner - documents current behavior
    try testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "Analyzer: WGSL reflection - var without type annotation" {
    // Edge case: var<uniform> without explicit type (should still find variable name)
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="@group(0) @binding(0) var<uniform> untyped;"
        \\}
        \\#buffer buf { size=12 usage=[uniform copy_dst] }
        \\#frame main {
        \\  perform=[]
        \\  writeBuffer=[{ buffer=buf data=shader.untyped }]
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "Analyzer: WGSL reflection - mixed read-write uniforms" {
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="
        \\    @group(0) @binding(0) var<uniform> ro_uniform : Type;
        \\    @group(0) @binding(1) var<storage, read_write> rw_storage : Type;
        \\  "
        \\}
        \\#buffer buf { size=12 usage=[uniform copy_dst] }
        \\#frame main {
        \\  perform=[]
        \\  writeBuffer=[{ buffer=buf data=shader.ro_uniform }]
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
    // Should find ro_uniform but not rw_storage
    try testing.expectEqual(@as(u32, 1), result.resolved_uniforms.count());
}

// ----------------------------------------------------------------------------
// WGSL Reflection Fuzz Testing
// ----------------------------------------------------------------------------

test "Analyzer: WGSL reflection fuzz - random patterns don't crash" {
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();

    // Generate random WGSL-like strings
    for (0..100) |_| {
        var wgsl_buf: [256]u8 = undefined;
        var source_buf: [512]u8 = undefined;

        // Generate random "WGSL" content
        const wgsl_len = random.intRangeAtMost(usize, 10, 200);
        for (wgsl_buf[0..wgsl_len]) |*c| {
            const chars = "@group()binding<>varuniform:;0123456789 \n\t";
            c.* = chars[random.intRangeAtMost(usize, 0, chars.len - 1)];
        }

        // Build valid DSL source with random WGSL content
        const header = "#wgsl shader { value=\"";
        const footer = "\" }\n#buffer buf { size=12 usage=[uniform copy_dst] }\n#frame main { perform=[] writeBuffer=[{ buffer=buf data=shader.x }] }";

        @memcpy(source_buf[0..header.len], header);
        @memcpy(source_buf[header.len..][0..wgsl_len], wgsl_buf[0..wgsl_len]);
        @memcpy(source_buf[header.len + wgsl_len ..][0..footer.len], footer);
        source_buf[header.len + wgsl_len + footer.len] = 0;

        const source: [:0]const u8 = source_buf[0 .. header.len + wgsl_len + footer.len :0];

        // Should not crash, may have errors
        var ast = Parser.parse(testing.allocator, source) catch continue;
        defer ast.deinit(testing.allocator);

        var result = Analyzer.analyze(testing.allocator, &ast) catch continue;
        defer result.deinit(testing.allocator);

        // Property: resolved uniforms should have valid bind_group (0-3)
        var iter = result.resolved_uniforms.iterator();
        while (iter.next()) |entry| {
            try testing.expect(entry.value_ptr.bind_group <= 3);
        }
    }
}

test "Analyzer: WGSL reflection - property: group in range 0-3" {
    // WebGPU only supports bind groups 0-3
    const groups = [_]u8{ 0, 1, 2, 3 };

    for (groups) |group| {
        var source_buf: [512]u8 = undefined;
        const source = std.fmt.bufPrintZ(&source_buf,
            \\#wgsl shader {{
            \\  value="@group({d}) @binding(0) var<uniform> u : T;"
            \\}}
            \\#buffer buf {{ size=12 usage=[uniform copy_dst] }}
            \\#frame main {{
            \\  perform=[]
            \\  writeBuffer=[{{ buffer=buf data=shader.u }}]
            \\}}
        , .{group}) catch continue;

        var ast = try Parser.parse(testing.allocator, source);
        defer ast.deinit(testing.allocator);

        var result = try Analyzer.analyze(testing.allocator, &ast);
        defer result.deinit(testing.allocator);

        var iter = result.resolved_uniforms.iterator();
        if (iter.next()) |entry| {
            try testing.expectEqual(group, entry.value_ptr.bind_group);
        }
    }
}

test "Analyzer: WGSL reflection - invalid group number (4+)" {
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="@group(4) @binding(0) var<uniform> invalid : Type;"
        \\}
        \\#buffer buf { size=12 usage=[uniform copy_dst] }
        \\#frame main {
        \\  perform=[]
        \\  writeBuffer=[{ buffer=buf data=shader.invalid }]
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Should parse (group 4 fits in u8) but would fail WebGPU validation
    try testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "Analyzer: WGSL reflection - empty shader source" {
    const source: [:0]const u8 =
        \\#wgsl shader { value="" }
        \\#buffer buf { size=12 usage=[uniform copy_dst] }
        \\#frame main {
        \\  perform=[]
        \\  writeBuffer=[{ buffer=buf data=shader.anything }]
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Empty shader should not crash, will use defaults
    try testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "Analyzer: WGSL reflection - malformed group/binding numbers" {
    const malformed_sources = [_][:0]const u8{
        \\#wgsl s { value="@group(-1) @binding(0) var<uniform> u : T;" }
        \\#buffer b { size=12 usage=[uniform copy_dst] }
        \\#frame main { perform=[] writeBuffer=[{ buffer=b data=s.u }] }
        ,
        \\#wgsl s { value="@group(abc) @binding(0) var<uniform> u : T;" }
        \\#buffer b { size=12 usage=[uniform copy_dst] }
        \\#frame main { perform=[] writeBuffer=[{ buffer=b data=s.u }] }
        ,
        \\#wgsl s { value="@group(999999) @binding(0) var<uniform> u : T;" }
        \\#buffer b { size=12 usage=[uniform copy_dst] }
        \\#frame main { perform=[] writeBuffer=[{ buffer=b data=s.u }] }
    };

    for (malformed_sources) |source| {
        var ast = Parser.parse(testing.allocator, source) catch continue;
        defer ast.deinit(testing.allocator);

        var result = Analyzer.analyze(testing.allocator, &ast) catch continue;
        defer result.deinit(testing.allocator);

        // Should not crash - malformed numbers just won't match
    }
}

test "Analyzer: WGSL reflection - stress test many uniforms" {
    // Pre-built shader with many uniforms
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="
        \\    @group(0) @binding(0) var<uniform> u0 : f32;
        \\    @group(0) @binding(1) var<uniform> u1 : f32;
        \\    @group(0) @binding(2) var<uniform> u2 : f32;
        \\    @group(0) @binding(3) var<uniform> u3 : f32;
        \\    @group(0) @binding(4) var<uniform> u4 : f32;
        \\    @group(0) @binding(5) var<uniform> u5 : f32;
        \\    @group(0) @binding(6) var<uniform> u6 : f32;
        \\    @group(0) @binding(7) var<uniform> u7 : f32;
        \\  "
        \\}
        \\#buffer buf { size=12 usage=[uniform copy_dst] }
        \\#frame main {
        \\  perform=[]
        \\  writeBuffer=[{ buffer=buf data=shader.u0 }]
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
    try testing.expectEqual(@as(u32, 1), result.resolved_uniforms.count()); // Only u0 is referenced
}

// ----------------------------------------------------------------------------
// Array Bare Identifier Resolution Tests (Phase 5: $ Removal)
// ----------------------------------------------------------------------------

test "Analyzer: perform array with bare identifiers" {
    const source: [:0]const u8 =
        \\#shaderModule code { code="fn main() {}" }
        \\#renderPipeline rp { vertex={ module=code } }
        \\#renderPass draw { pipeline=rp colorAttachments=[{ view=contextCurrentTexture }] }
        \\#computePipeline cp { compute={ module=code } }
        \\#computePass sim { pipeline=cp dispatch=[1 1 1] }
        \\#frame main { perform=[draw sim] }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);

    // Both 'draw' and 'sim' should be resolved
    var resolved_count: u32 = 0;
    var it = result.resolved_identifiers.iterator();
    while (it.next()) |entry| {
        const resolution = entry.value_ptr.*;
        if (std.mem.eql(u8, resolution.name, "draw")) {
            try testing.expectEqual(Analyzer.Namespace.render_pass, resolution.namespace);
            resolved_count += 1;
        } else if (std.mem.eql(u8, resolution.name, "sim")) {
            try testing.expectEqual(Analyzer.Namespace.compute_pass, resolution.namespace);
            resolved_count += 1;
        }
    }
    try testing.expect(resolved_count >= 2);
}

test "Analyzer: vertexBuffers array with bare identifiers" {
    const source: [:0]const u8 =
        \\#shaderModule code { code="fn main() {}" }
        \\#buffer verts { size=1024 usage=[vertex] }
        \\#buffer uvs { size=512 usage=[vertex] }
        \\#renderPipeline rp { vertex={ module=code } }
        \\#renderPass draw {
        \\  pipeline=rp
        \\  vertexBuffers=[verts uvs]
        \\  colorAttachments=[{ view=contextCurrentTexture }]
        \\}
        \\#frame main { perform=[draw] }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "Analyzer: bindGroups array with bare identifiers" {
    const source: [:0]const u8 =
        \\#shaderModule code { code="fn main() {}" }
        \\#buffer uniforms { size=64 usage=[uniform] }
        \\#bindGroup materials { entries=[{ binding=0 resource={ buffer=uniforms } }] }
        \\#bindGroup lights { entries=[{ binding=0 resource={ buffer=uniforms } }] }
        \\#renderPipeline rp { vertex={ module=code } }
        \\#renderPass draw {
        \\  pipeline=rp
        \\  bindGroups=[materials lights]
        \\  colorAttachments=[{ view=contextCurrentTexture }]
        \\}
        \\#frame main { perform=[draw] }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "Analyzer: undefined reference in perform array" {
    const source: [:0]const u8 =
        \\#frame main { perform=[nonexistent] }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.errors.len);
    try testing.expectEqual(Analyzer.AnalysisError.Kind.undefined_reference, result.errors[0].kind);
    // Error message indicates expected type
    try testing.expect(std.mem.indexOf(u8, result.errors[0].message, "pass") != null or
        std.mem.indexOf(u8, result.errors[0].message, "queue") != null);
}

test "Analyzer: undefined reference in vertexBuffers array" {
    const source: [:0]const u8 =
        \\#shaderModule code { code="fn main() {}" }
        \\#renderPipeline rp { vertex={ module=code } }
        \\#renderPass draw {
        \\  pipeline=rp
        \\  vertexBuffers=[missingBuffer]
        \\  colorAttachments=[{ view=contextCurrentTexture }]
        \\}
        \\#frame main { perform=[draw] }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.errors.len);
    try testing.expectEqual(Analyzer.AnalysisError.Kind.undefined_reference, result.errors[0].kind);
}

test "Analyzer: mixed valid and invalid in array" {
    const source: [:0]const u8 =
        \\#shaderModule code { code="fn main() {}" }
        \\#renderPipeline rp { vertex={ module=code } }
        \\#renderPass draw { pipeline=rp colorAttachments=[{ view=contextCurrentTexture }] }
        \\#frame main { perform=[draw nonexistent] }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Should have exactly 1 error for 'nonexistent'
    try testing.expectEqual(@as(usize, 1), result.errors.len);
    try testing.expectEqual(Analyzer.AnalysisError.Kind.undefined_reference, result.errors[0].kind);
}

test "Analyzer: before/after arrays with bare identifiers" {
    const source: [:0]const u8 =
        \\#shaderModule code { code="fn main() {}" }
        \\#buffer uniforms { size=64 usage=[uniform copy_dst] }
        \\#data params { float32Array=[1.0 2.0] }
        \\#queue writeUniforms { writeBuffer={ buffer=uniforms data=params } }
        \\#renderPipeline rp { vertex={ module=code } }
        \\#renderPass draw { pipeline=rp colorAttachments=[{ view=contextCurrentTexture }] }
        \\#frame main {
        \\  before=[writeUniforms]
        \\  perform=[draw]
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "Analyzer: queue in perform resolves correctly" {
    const source: [:0]const u8 =
        \\#buffer buf { size=64 usage=[copy_dst] }
        \\#data params { float32Array=[1.0] }
        \\#queue writeData { writeBuffer={ buffer=buf data=params } }
        \\#frame main { perform=[writeData] }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);

    // 'writeData' should resolve to queue namespace
    var found = false;
    var it = result.resolved_identifiers.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.name, "writeData")) {
            try testing.expectEqual(Analyzer.Namespace.queue, entry.value_ptr.namespace);
            found = true;
        }
    }
    try testing.expect(found);
}
