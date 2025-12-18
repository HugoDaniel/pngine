//! Expression Parsing Tests
//!
//! Tests for parsing arithmetic expressions and math constants.

const std = @import("std");
const testing = std.testing;
const Parser = @import("../Parser.zig").Parser;
const Ast = @import("../Ast.zig").Ast;
const Node = @import("../Ast.zig").Node;

fn parseSource(source: [:0]const u8) !Ast {
    return Parser.parse(testing.allocator, source);
}

// ============================================================================
// Expression Parsing Tests
// ============================================================================

test "Parser: simple addition expression" {
    const source: [:0]const u8 = "#buffer buf { size=1+2 }";
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Should have an expr_add node
    var has_expr_add = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .expr_add) has_expr_add = true;
    }
    try testing.expect(has_expr_add);
}

test "Parser: subtraction expression" {
    const source: [:0]const u8 = "#buffer buf { size=10-5 }";
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    var has_expr_sub = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .expr_sub) has_expr_sub = true;
    }
    try testing.expect(has_expr_sub);
}

test "Parser: multiplication expression" {
    const source: [:0]const u8 = "#buffer buf { size=3*4 }";
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    var has_expr_mul = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .expr_mul) has_expr_mul = true;
    }
    try testing.expect(has_expr_mul);
}

test "Parser: division expression" {
    const source: [:0]const u8 = "#buffer buf { size=8/2 }";
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    var has_expr_div = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .expr_div) has_expr_div = true;
    }
    try testing.expect(has_expr_div);
}

test "Parser: parenthesized expression" {
    const source: [:0]const u8 = "#buffer buf { size=(1+2)*3 }";
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Should have both add and mul nodes
    var has_expr_add = false;
    var has_expr_mul = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .expr_add) has_expr_add = true;
        if (tag == .expr_mul) has_expr_mul = true;
    }
    try testing.expect(has_expr_add);
    try testing.expect(has_expr_mul);
}

test "Parser: operator precedence (* before +)" {
    // 1 + 2 * 3 should parse as 1 + (2 * 3), not (1 + 2) * 3
    const source: [:0]const u8 = "#buffer buf { size=1+2*3 }";
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Find the expr_add node - its second child should be expr_mul
    for (ast.nodes.items(.tag), 0..) |tag, i| {
        if (tag == .expr_add) {
            const data = ast.nodes.items(.data)[i];
            const rhs_idx = data.node_and_node[1];
            const rhs_tag = ast.nodes.items(.tag)[rhs_idx];
            try testing.expectEqual(Node.Tag.expr_mul, rhs_tag);
            break;
        }
    }
}

test "Parser: hex in expression" {
    const source: [:0]const u8 = "#buffer buf { size=0xFF+0x10 }";
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    var has_expr_add = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .expr_add) has_expr_add = true;
    }
    try testing.expect(has_expr_add);
}

test "Parser: expression in array" {
    // Expressions in arrays require parentheses to avoid ambiguity with space-separated values
    // Without parens: [1 -1] is two values, not 1-1=0
    // With parens: [(1+2) (3*4)] is two computed values
    const source: [:0]const u8 = "#buffer buf { values=[(1+2) (3*4)] }";
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    var expr_count: usize = 0;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .expr_add or tag == .expr_mul) expr_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), expr_count);
}

test "Parser: simple number (no expression)" {
    const source: [:0]const u8 = "#buffer buf { size=100 }";
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Should have a number_value node, not an expression
    var has_number_value = false;
    var has_expr = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .number_value) has_number_value = true;
        if (tag == .expr_add or tag == .expr_sub or tag == .expr_mul or tag == .expr_div) {
            has_expr = true;
        }
    }
    try testing.expect(has_number_value);
    try testing.expect(!has_expr);
}

// OOM test for expression parsing - first allocation failure.
//
// Properties tested:
// - Parser returns OutOfMemory on first allocation failure
// - No crash when OOM occurs during expression parsing
test "Parser: expression OOM handling" {
    const source: [:0]const u8 = "#buffer buf { size=(1+2)*(3+4)/5-6 }";

    // Test OOM on first allocation
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });

    const result = Parser.parse(failing.allocator(), source);
    try testing.expectError(error.OutOfMemory, result);
}

test "Parser: comments inside arrays" {
    // Regression test: comments inside arrays should be skipped
    const source: [:0]const u8 =
        \\#data vertices {
        \\  float32Array=[
        \\    // vertex 1
        \\    1 2 3
        \\    // vertex 2
        \\    4 5 6
        \\  ]
        \\}
    ;

    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Should successfully parse the array with 6 elements
    var found_array = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .array) found_array = true;
    }
    try testing.expect(found_array);
}

test "Parser: comments inside objects" {
    // Regression test: comments inside objects should be skipped
    const source: [:0]const u8 =
        \\#buffer buf {
        \\  // size in bytes
        \\  size=100
        \\  // usage flags
        \\  usage=[VERTEX]
        \\}
    ;

    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Should have both size and usage properties
    var prop_count: usize = 0;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .property) prop_count += 1;
    }
    // size, usage = 2 properties
    try testing.expect(prop_count >= 2);
}

// ============================================================================
// Math Constant Tests
// ============================================================================

test "Parser: PI constant creates number_value" {
    const source: [:0]const u8 = "#buffer buf { size=PI }";
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Should have a number_value node for PI
    var has_number_value = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .number_value) has_number_value = true;
    }
    try testing.expect(has_number_value);
}

test "Parser: E constant creates number_value" {
    const source: [:0]const u8 = "#buffer buf { size=E }";
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    var has_number_value = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .number_value) has_number_value = true;
    }
    try testing.expect(has_number_value);
}

test "Parser: TAU constant creates number_value" {
    const source: [:0]const u8 = "#buffer buf { size=TAU }";
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    var has_number_value = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .number_value) has_number_value = true;
    }
    try testing.expect(has_number_value);
}
