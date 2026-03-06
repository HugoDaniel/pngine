//! Parser Tests
//!
//! All tests for the DSL parser.
//! Tests verify macro parsing, expression parsing, and error handling.

const std = @import("std");
const testing = std.testing;
const Parser = @import("../Parser.zig").Parser;
const Ast = @import("../Ast.zig").Ast;
const Node = @import("../Ast.zig").Node;
const Diagnostic = @import("../Ast.zig").Diagnostic;

fn parseSource(source: [:0]const u8) !Ast {
    return Parser.parse(testing.allocator, source);
}

/// Parse and expect a specific diagnostic tag. Returns the Ast for inspection.
fn expectParseError(source: [:0]const u8, expected_tag: Diagnostic.Tag) !void {
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    try testing.expect(ast.hasParseErrors());
    try testing.expect(ast.errors.len > 0);
    try testing.expectEqual(expected_tag, ast.errors[0].tag);
}

// ============================================================================
// Basic Macro Tests
// ============================================================================

test "Parser: empty input" {
    var ast = try parseSource("");
    defer ast.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), ast.nodes.len); // Just root
    try testing.expectEqual(Node.Tag.root, ast.nodes.items(.tag)[0]);
}

test "Parser: simple buffer macro" {
    const source: [:0]const u8 = "#buffer myBuf { size=100 }";
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Root + buffer + property + number = 4 nodes
    try testing.expect(ast.nodes.len >= 4);

    // Check root has one child
    const root_data = ast.nodes.items(.data)[0];
    const children = ast.extraData(root_data.extra_range);
    try testing.expectEqual(@as(usize, 1), children.len);

    // Check buffer node
    const buffer_idx = children[0];
    try testing.expectEqual(Node.Tag.macro_buffer, ast.nodes.items(.tag)[buffer_idx]);
}

test "Parser: buffer with array usage" {
    const source: [:0]const u8 = "#buffer buf { size=100 usage=[VERTEX STORAGE] }";
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Find the array node
    var found_array = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .array) {
            found_array = true;
            break;
        }
    }
    try testing.expect(found_array);
}

test "Parser: renderPipeline with nested objects" {
    const source: [:0]const u8 =
        \\#renderPipeline pipeline {
        \\  layout=auto
        \\  vertex={ entryPoint=vertexMain }
        \\}
    ;
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Should have: root, renderPipeline, 2 properties, 1 object, 1 nested property
    try testing.expect(ast.nodes.len >= 6);

    // Verify render pipeline exists
    var found_pipeline = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .macro_render_pipeline) {
            found_pipeline = true;
            break;
        }
    }
    try testing.expect(found_pipeline);
}

test "Parser: frame with perform array" {
    const source: [:0]const u8 = "#frame main { perform=[pass1 pass2] }";
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Find frame node
    var frame_idx: ?usize = null;
    for (ast.nodes.items(.tag), 0..) |tag, i| {
        if (tag == .macro_frame) {
            frame_idx = i;
            break;
        }
    }
    try testing.expect(frame_idx != null);
}

// NOTE: The $namespace.name reference syntax has been removed.
// Bare identifiers are now used everywhere and resolved based on context.

test "Parser: define constant" {
    const source: [:0]const u8 = "#define FOV=1.5";
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Find define node
    var found_define = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .macro_define) {
            found_define = true;
            break;
        }
    }
    try testing.expect(found_define);
}

test "Parser: multiple macros" {
    const source: [:0]const u8 =
        \\#buffer buf1 { size=100 }
        \\#buffer buf2 { size=200 }
        \\#frame main { perform=[pass1] }
    ;
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Root should have 3 children
    const root_data = ast.nodes.items(.data)[0];
    const children = ast.extraData(root_data.extra_range);
    try testing.expectEqual(@as(usize, 3), children.len);
}

test "Parser: complex renderPass" {
    const source: [:0]const u8 =
        \\#renderPass drawPass {
        \\  colorAttachments=[{
        \\    view=contextCurrentTexture
        \\    clearValue=[0.0 0.0 0.0 1.0]
        \\    loadOp=clear
        \\  }]
        \\  pipeline=myPipeline
        \\  draw=3
        \\}
    ;
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Should parse without error
    try testing.expect(ast.nodes.len > 10);
}

test "Parser: string values" {
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="fn main() { }"
        \\}
    ;
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Find string value node
    var found_string = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .string_value) {
            found_string = true;
            break;
        }
    }
    try testing.expect(found_string);
}

test "Parser: negative numbers as unary negation" {
    const source: [:0]const u8 = "#buffer buf { offset=-10 }";
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Negative numbers are now parsed as expr_negate with number_value operand
    var found_negate = false;
    var found_number = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .expr_negate) found_negate = true;
        if (tag == .number_value) found_number = true;
    }
    try testing.expect(found_negate);
    try testing.expect(found_number);
}

test "Parser: all macro types" {
    const macros = [_][:0]const u8{
        "#renderPipeline p { layout=auto }",
        "#computePipeline p { layout=auto }",
        "#buffer b { size=100 }",
        "#texture t { format=rgba8 }",
        "#sampler s { filter=linear }",
        "#bindGroup bg { layout=auto }",
        "#renderPass rp { pipeline=p }",
        "#computePass cp { pipeline=p }",
        "#frame f { perform=[p] }",
        "#wgsl w { value=\"\" }",
        "#shaderModule sm { code=\"\" }",
        "#data d { float32Array=[1] }",
        "#queue q { writeBuffer=buf }",
        "#wasmCall wc { module={url=\"test.wasm\"} func=test }",
        "#imageBitmap ib { image=data }",
    };

    for (macros) |source| {
        var ast = try parseSource(source);
        defer ast.deinit(testing.allocator);
        // Just verify it parses without error
        try testing.expect(ast.nodes.len >= 2);
    }
}

test "Parser: wasmCall macro" {
    const source: [:0]const u8 =
        \\#wasmCall mvpMatrix {
        \\  module={
        \\    url="assets/mvp.wasm"
        \\  }
        \\  func=buildMVPMatrix
        \\  returns="mat4x4"
        \\  args=[canvas.width canvas.height time.total]
        \\}
    ;

    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Verify root has one child (the wasmCall macro)
    const root_data = ast.nodes.items(.data)[0];
    const children = ast.extraData(root_data.extra_range);
    try testing.expectEqual(@as(usize, 1), children.len);

    // Verify macro node
    const macro_idx = children[0];
    const macro_tag = ast.nodes.items(.tag)[macro_idx];
    try testing.expectEqual(Node.Tag.macro_wasm_call, macro_tag);
}

test "Parser: init macro" {
    const source: [:0]const u8 =
        \\#init resetParticles {
        \\  buffer=particles
        \\  shader=initParticles
        \\  params=[12345]
        \\}
    ;

    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Verify root has one child (the init macro)
    const root_data = ast.nodes.items(.data)[0];
    const children = ast.extraData(root_data.extra_range);
    try testing.expectEqual(@as(usize, 1), children.len);

    // Verify macro node
    const macro_idx = children[0];
    const macro_tag = ast.nodes.items(.tag)[macro_idx];
    try testing.expectEqual(Node.Tag.macro_init, macro_tag);

    // Verify properties exist
    const macro_data = ast.nodes.items(.data)[macro_idx];
    const props = ast.extraData(macro_data.extra_range);
    try testing.expectEqual(@as(usize, 3), props.len); // buffer, shader, params
}

test "Parser: builtin refs - canvas.width, time.total without dollar" {
    const source: [:0]const u8 =
        \\#wasmCall mvpMatrix {
        \\  module={ url="assets/mvp.wasm" }
        \\  func=buildMVPMatrix
        \\  args=[canvas.width canvas.height time.total]
        \\}
    ;

    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Verify root has the macro
    const root_data = ast.nodes.items(.data)[0];
    const children = ast.extraData(root_data.extra_range);
    try testing.expectEqual(@as(usize, 1), children.len);

    // Verify macro is a wasmCall
    const macro_idx = children[0];
    const macro_tag = ast.nodes.items(.tag)[macro_idx];
    try testing.expectEqual(Node.Tag.macro_wasm_call, macro_tag);

    // Get macro properties and find args
    const macro_data = ast.nodes.items(.data)[macro_idx];
    const props = ast.extraData(macro_data.extra_range);

    // Find the args property
    var args_array: ?Node.Index = null;
    for (props) |prop_idx| {
        const prop_tag = ast.nodes.items(.tag)[prop_idx];
        if (prop_tag == .property) {
            const prop_token = ast.nodes.items(.main_token)[prop_idx];
            const prop_name = ast.tokenSlice(prop_token);
            if (std.mem.eql(u8, std.mem.trimEnd(u8, prop_name, " \t\n\r={"), "args")) {
                const prop_data = ast.nodes.items(.data)[prop_idx];
                args_array = prop_data.node;
                break;
            }
        }
    }

    try testing.expect(args_array != null);
    const array_tag = ast.nodes.items(.tag)[args_array.?.toInt()];
    try testing.expectEqual(Node.Tag.array, array_tag);

    // Get array elements
    const array_data = ast.nodes.items(.data)[args_array.?.toInt()];
    const elements = ast.extraData(array_data.extra_range);
    try testing.expectEqual(@as(usize, 3), elements.len);

    // Verify first element is builtin_ref (canvas.width)
    const first_elem_tag = ast.nodes.items(.tag)[elements[0]];
    try testing.expectEqual(Node.Tag.builtin_ref, first_elem_tag);

    // Verify second element is builtin_ref (canvas.height)
    const second_elem_tag = ast.nodes.items(.tag)[elements[1]];
    try testing.expectEqual(Node.Tag.builtin_ref, second_elem_tag);

    // Verify third element is builtin_ref (time.total)
    const third_elem_tag = ast.nodes.items(.tag)[elements[2]];
    try testing.expectEqual(Node.Tag.builtin_ref, third_elem_tag);
}

test "Parser: builtin refs in texture size" {
    const source: [:0]const u8 =
        \\#texture depthTexture {
        \\  size=[canvas.width canvas.height]
        \\  format=depth24plus
        \\}
    ;

    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Verify root has the macro
    const root_data = ast.nodes.items(.data)[0];
    const children = ast.extraData(root_data.extra_range);
    try testing.expectEqual(@as(usize, 1), children.len);

    // Verify macro is a texture
    const macro_tag = ast.nodes.items(.tag)[children[0]];
    try testing.expectEqual(Node.Tag.macro_texture, macro_tag);
}

test "Parser: simpleTriangle example" {
    const source: [:0]const u8 =
        \\#renderPipeline pipeline {
        \\  layout=auto
        \\  vertex={ entryPoint=vertexMain }
        \\  fragment={
        \\    entryPoint=fragMain
        \\    targets=[{ format=preferredCanvasFormat }]
        \\  }
        \\  primitive={ topology=triangle-list }
        \\}
        \\
        \\#renderPass renderPipeline {
        \\  colorAttachments=[{
        \\    view=contextCurrentTexture
        \\    clearValue=[0, 0, 0, 0]
        \\    loadOp=clear
        \\    storeOp=store
        \\  }]
        \\  pipeline=pipeline
        \\  draw=3
        \\}
        \\
        \\#frame simpleTriangle {
        \\  perform=[renderPipeline]
        \\}
    ;

    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Root should have 3 top-level macros
    const root_data = ast.nodes.items(.data)[0];
    const children = ast.extraData(root_data.extra_range);
    try testing.expectEqual(@as(usize, 3), children.len);

    // Verify we have: renderPipeline, renderPass, frame
    var counts = struct {
        render_pipeline: usize = 0,
        render_pass: usize = 0,
        frame: usize = 0,
    }{};

    for (ast.nodes.items(.tag)) |tag| {
        switch (tag) {
            .macro_render_pipeline => counts.render_pipeline += 1,
            .macro_render_pass => counts.render_pass += 1,
            .macro_frame => counts.frame += 1,
            else => {},
        }
    }

    try testing.expectEqual(@as(usize, 1), counts.render_pipeline);
    try testing.expectEqual(@as(usize, 1), counts.render_pass);
    try testing.expectEqual(@as(usize, 1), counts.frame);
}

// ============================================================================
// Error Handling Tests
// ============================================================================

test "Parser: missing name reports expected_name" {
    try expectParseError("#buffer { }", .expected_name);
}

test "Parser: missing opening brace reports expected_opening_brace" {
    try expectParseError("#buffer buf size=100", .expected_opening_brace);
}

test "Parser: missing closing brace reports expected_closing_brace" {
    try expectParseError("#buffer buf { size=100", .expected_closing_brace);
}

test "Parser: missing equals reports expected_equals" {
    try expectParseError("#buffer buf { size 100 }", .expected_equals);
}

test "Parser: missing value reports expected_value" {
    try expectParseError("#define FOO=", .expected_value);
}

test "Parser: unclosed array reports expected_closing_bracket" {
    try expectParseError("#data d { arr=[1 2 3 }", .expected_closing_bracket);
}

test "Parser: unclosed paren reports expected_closing_paren" {
    try expectParseError("#buffer buf { size=(1+2 }", .expected_closing_paren);
}

test "Parser: dangling operator reports expected_operand" {
    try expectParseError("#buffer buf { size=1+ }", .expected_operand);
}

test "Parser: define missing name reports expected_name" {
    try expectParseError("#define =100", .expected_name);
}

test "Parser: define missing equals reports expected_equals" {
    try expectParseError("#define FOO 100", .expected_equals);
}

test "Parser: error Ast does not leak memory" {
    // Parse error returns Ast with errors — must not leak
    var ast = try parseSource("#buffer { }");
    defer ast.deinit(testing.allocator);

    try testing.expect(ast.hasParseErrors());
}

test "Parser: OOM handling" {
    // Test that OOM on first allocation returns error properly
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0, // Fail on first allocation
    });

    const result = Parser.parse(failing.allocator(), "#buffer buf { size=100 }");
    try testing.expectError(error.OutOfMemory, result);
}

test "Parser: error messages are self-explanatory" {
    // Verify rendered output contains key information
    var ast = try parseSource("#buffer { }");
    defer ast.deinit(testing.allocator);

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try ast.renderErrors(&writer);
    const output = writer.buffered();

    // Must contain the error message
    try testing.expect(std.mem.indexOf(u8, output, "expected resource name") != null);
    // Must contain line/col location
    try testing.expect(std.mem.indexOf(u8, output, "line 1") != null);
    // Must contain help suggestion
    try testing.expect(std.mem.indexOf(u8, output, "help:") != null);
    // Must contain source context
    try testing.expect(std.mem.indexOf(u8, output, "#buffer") != null);
}

test "Parser: multiline error reports correct line" {
    const source: [:0]const u8 =
        \\#buffer buf1 { size=100 }
        \\#buffer { size=200 }
    ;
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    try testing.expect(ast.hasParseErrors());

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try ast.renderErrors(&writer);
    const output = writer.buffered();

    // Error should be on line 2
    try testing.expect(std.mem.indexOf(u8, output, "line 2") != null);
}

test "Parser: unclosed object in nested position" {
    try expectParseError(
        \\#renderPipeline p {
        \\  vertex={ entryPoint=vs
        \\}
    , .expected_closing_brace);
}

// ============================================================================
// String and Interpolation Tests
// ============================================================================

test "Parser: builtin references (canvas.width, canvas.height)" {
    const source: [:0]const u8 =
        \\#texture tex {
        \\  size=[canvas.width canvas.height]
        \\}
    ;
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Find builtin_ref nodes
    var builtin_ref_count: usize = 0;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .builtin_ref) {
            builtin_ref_count += 1;
        }
    }
    // Should find 2 builtin references
    try testing.expectEqual(@as(usize, 2), builtin_ref_count);
}

test "Parser: regular string vs interpolation" {
    const source: [:0]const u8 =
        \\#wgsl code {
        \\  code="fn main() {}"
        \\}
    ;
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Find string nodes
    var string_count: usize = 0;
    var interpolation_count: usize = 0;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .string_value) string_count += 1;
        if (tag == .runtime_interpolation) interpolation_count += 1;
    }
    // Should have 1 regular string, 0 interpolation
    try testing.expectEqual(@as(usize, 1), string_count);
    try testing.expectEqual(@as(usize, 0), interpolation_count);
}

// ============================================================================
// Fuzz Tests
// ============================================================================

// Property-based fuzz test for parser using std.testing.fuzz API
test "Parser: fuzz with random input" {
    try std.testing.fuzz({}, fuzzParserProperties, .{});
}

/// Fuzz test function for parser properties.
/// Properties tested:
/// - Never crashes on any input
/// - Always returns an Ast (with or without errors)
/// - All nodes reference valid token indices
/// - Token positions are within source bounds
/// - Diagnostics have valid token indices
fn fuzzParserProperties(_: void, input: []const u8) !void {
    // Filter out inputs with embedded nulls (invalid for sentinel-terminated)
    for (input) |byte| {
        if (byte == 0) return; // Skip this input
    }

    // Create sentinel-terminated copy
    var buf: [256]u8 = undefined;
    if (input.len >= buf.len) return; // Skip too-large inputs
    @memcpy(buf[0..input.len], input);
    buf[input.len] = 0;

    const source: [:0]const u8 = buf[0..input.len :0];

    // Parse always returns an Ast (never crashes)
    if (Parser.parse(testing.allocator, source)) |ast| {
        var mutable_ast = ast;
        defer mutable_ast.deinit(testing.allocator);

        const nodes = mutable_ast.nodes;
        const tokens = mutable_ast.tokens;

        // Property 1: All main_token indices are valid
        const main_tokens = nodes.items(.main_token);
        for (main_tokens) |tok_idx| {
            try testing.expect(tok_idx < tokens.len);
        }

        // Property 2: Token positions within source bounds
        const token_starts = tokens.items(.start);
        for (token_starts) |start| {
            try testing.expect(start <= source.len);
        }

        // Property 3: Diagnostic tokens are valid indices
        for (mutable_ast.errors) |diag| {
            try testing.expect(diag.token < tokens.len);
        }
    } else |err| {
        // Only OOM should propagate
        try testing.expect(err == error.OutOfMemory);
    }
}
