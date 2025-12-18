//! Parser Tests
//!
//! All tests for the DSL parser.
//! Tests verify macro parsing, expression parsing, and error handling.

const std = @import("std");
const testing = std.testing;
const Parser = @import("../Parser.zig").Parser;
const Ast = @import("../Ast.zig").Ast;
const Node = @import("../Ast.zig").Node;

fn parseSource(source: [:0]const u8) !Ast {
    return Parser.parse(testing.allocator, source);
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

test "Parser: reference syntax" {
    const source: [:0]const u8 = "#buffer buf { data=$wgsl.shader }";
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Find reference node
    var found_ref = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .reference) {
            found_ref = true;
            break;
        }
    }
    try testing.expect(found_ref);
}

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
        \\  args=[ "$canvas.width", "$canvas.height", "$t.total" ]
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

test "Parser: memory cleanup on error" {
    // Invalid input - should return error but not leak
    const result = Parser.parse(testing.allocator, "#buffer { }");
    try testing.expectError(error.ParseError, result);
}

test "Parser: OOM handling" {
    // Test that OOM on first allocation returns error properly
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0, // Fail on first allocation
    });

    const result = Parser.parse(failing.allocator(), "#buffer buf { size=100 }");
    try testing.expectError(error.OutOfMemory, result);
}

// ============================================================================
// String and Interpolation Tests
// ============================================================================

test "Parser: runtime interpolation strings" {
    const source: [:0]const u8 =
        \\#texture tex {
        \\  size=["$canvas.width", "$canvas.height"]
        \\}
    ;
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Find runtime_interpolation nodes
    var interpolation_count: usize = 0;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .runtime_interpolation) {
            interpolation_count += 1;
        }
    }
    // Should find 2 runtime interpolation strings
    try testing.expectEqual(@as(usize, 2), interpolation_count);
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
/// - Root node always at index 0 when successful
/// - Only returns ParseError or OutOfMemory on failure
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

    // Try to parse - should either succeed or return error, never crash
    if (Parser.parse(testing.allocator, source)) |ast| {
        var mutable_ast = ast;
        defer mutable_ast.deinit(testing.allocator);

        // Property 1: At least root node
        try testing.expect(mutable_ast.nodes.len >= 1);

        // Property 2: Root node at index 0
        try testing.expect(mutable_ast.nodes.items(.tag)[0] == .root);
    } else |err| {
        // Property 3: Only expected errors
        try testing.expect(err == error.ParseError or err == error.OutOfMemory);
    }
}
