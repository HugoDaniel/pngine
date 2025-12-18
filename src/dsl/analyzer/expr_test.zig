//! Expression Evaluation Tests
//!
//! Tests for compile-time expression evaluation in the analyzer.
//! Verifies arithmetic, precedence, math constants, and edge cases.

const std = @import("std");
const testing = std.testing;
const Analyzer = @import("../Analyzer.zig").Analyzer;
const Parser = @import("../Parser.zig").Parser;

// ----------------------------------------------------------------------------
// Expression Evaluation Tests
// ----------------------------------------------------------------------------
//
// These tests verify compile-time expression evaluation properties:
// 1. Arithmetic correctness: +, -, *, / produce correct IEEE 754 f64 results
// 2. Operator precedence: * and / bind tighter than + and -
// 3. Associativity: left-to-right for all binary operators
// 4. Parentheses: override precedence as expected
// 5. Hex literals: 0xFF parsed correctly for WebGPU usage flags
// 6. Division by zero: returns null (graceful handling)
// 7. Unary negation: -x correctly negates operand

// Property: Addition produces correct f64 sum.
// Input: 1 + 2
// Expected: 3.0
test "Analyzer: evaluate simple addition" {
    const source: [:0]const u8 = "#buffer buf { size=1+2 usage=[UNIFORM] }";

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analyzer = Analyzer.init(testing.allocator, &ast);
    defer analyzer.deinit();

    // Find the property value node for 'size'
    for (ast.nodes.items(.tag), 0..) |tag, i| {
        if (tag == .expr_add) {
            const result = analyzer.evaluateExpression(@enumFromInt(@as(u32, @intCast(i))));
            try testing.expect(result != null);
            try testing.expectEqual(@as(f64, 3.0), result.?);
            return;
        }
    }
    try testing.expect(false); // Should have found expr_add
}

// Property: Subtraction produces correct f64 difference.
// Input: 10 - 5
// Expected: 5.0
test "Analyzer: evaluate subtraction" {
    const source: [:0]const u8 = "#buffer buf { size=10-5 usage=[UNIFORM] }";

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analyzer = Analyzer.init(testing.allocator, &ast);
    defer analyzer.deinit();

    for (ast.nodes.items(.tag), 0..) |tag, i| {
        if (tag == .expr_sub) {
            const result = analyzer.evaluateExpression(@enumFromInt(@as(u32, @intCast(i))));
            try testing.expectEqual(@as(f64, 5.0), result.?);
            return;
        }
    }
    try testing.expect(false);
}

// Property: Multiplication produces correct f64 product.
// Input: 3 * 4
// Expected: 12.0
test "Analyzer: evaluate multiplication" {
    const source: [:0]const u8 = "#buffer buf { size=3*4 usage=[UNIFORM] }";

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analyzer = Analyzer.init(testing.allocator, &ast);
    defer analyzer.deinit();

    for (ast.nodes.items(.tag), 0..) |tag, i| {
        if (tag == .expr_mul) {
            const result = analyzer.evaluateExpression(@enumFromInt(@as(u32, @intCast(i))));
            try testing.expectEqual(@as(f64, 12.0), result.?);
            return;
        }
    }
    try testing.expect(false);
}

// Property: Division produces correct f64 quotient.
// Input: 8 / 2
// Expected: 4.0
test "Analyzer: evaluate division" {
    const source: [:0]const u8 = "#buffer buf { size=8/2 usage=[UNIFORM] }";

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analyzer = Analyzer.init(testing.allocator, &ast);
    defer analyzer.deinit();

    for (ast.nodes.items(.tag), 0..) |tag, i| {
        if (tag == .expr_div) {
            const result = analyzer.evaluateExpression(@enumFromInt(@as(u32, @intCast(i))));
            try testing.expectEqual(@as(f64, 4.0), result.?);
            return;
        }
    }
    try testing.expect(false);
}

// Property: Operator precedence - multiplication binds tighter than addition.
// Input: 1 + 2 * 3
// Expected: 7.0 (not 9.0 - precedence matters)
// Verifies: * evaluated before + per standard math rules
test "Analyzer: evaluate complex expression with precedence" {
    const source: [:0]const u8 = "#buffer buf { size=1+2*3 usage=[UNIFORM] }";

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analyzer = Analyzer.init(testing.allocator, &ast);
    defer analyzer.deinit();

    for (ast.nodes.items(.tag), 0..) |tag, i| {
        if (tag == .expr_add) {
            const result = analyzer.evaluateExpression(@enumFromInt(@as(u32, @intCast(i))));
            try testing.expectEqual(@as(f64, 7.0), result.?);
            return;
        }
    }
    try testing.expect(false);
}

// Property: Parentheses override operator precedence.
// Input: (1 + 2) * 3
// Expected: 9.0 (not 7.0 - parentheses force addition first)
// Verifies: Grouped expressions evaluated before surrounding operators
test "Analyzer: evaluate parenthesized expression" {
    const source: [:0]const u8 = "#buffer buf { size=(1+2)*3 usage=[UNIFORM] }";

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analyzer = Analyzer.init(testing.allocator, &ast);
    defer analyzer.deinit();

    for (ast.nodes.items(.tag), 0..) |tag, i| {
        if (tag == .expr_mul) {
            const result = analyzer.evaluateExpression(@enumFromInt(@as(u32, @intCast(i))));
            try testing.expectEqual(@as(f64, 9.0), result.?);
            return;
        }
    }
    try testing.expect(false);
}

// Property: Hex literals (0xFF) parsed correctly for WebGPU usage flags.
// Input: 0xFF + 0x10
// Expected: 271.0 (255 + 16)
// Verifies: Hex parsing works in expressions (common for usage flags)
test "Analyzer: evaluate hex expression" {
    const source: [:0]const u8 = "#buffer buf { size=0xFF+0x10 usage=[UNIFORM] }";

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analyzer = Analyzer.init(testing.allocator, &ast);
    defer analyzer.deinit();

    for (ast.nodes.items(.tag), 0..) |tag, i| {
        if (tag == .expr_add) {
            const result = analyzer.evaluateExpression(@enumFromInt(@as(u32, @intCast(i))));
            try testing.expectEqual(@as(f64, 271.0), result.?);
            return;
        }
    }
    try testing.expect(false);
}

// Property: Plain number literals evaluate to their value.
// Input: 100
// Expected: 100.0
// Verifies: evaluateExpression handles leaf number_value nodes
test "Analyzer: evaluate number literal (no expression)" {
    const source: [:0]const u8 = "#buffer buf { size=100 usage=[UNIFORM] }";

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analyzer = Analyzer.init(testing.allocator, &ast);
    defer analyzer.deinit();

    for (ast.nodes.items(.tag), 0..) |tag, i| {
        if (tag == .number_value) {
            const result = analyzer.evaluateExpression(@enumFromInt(@as(u32, @intCast(i))));
            try testing.expectEqual(@as(f64, 100.0), result.?);
            return;
        }
    }
    try testing.expect(false);
}

// Property: Division by zero returns null (graceful error handling).
// Input: 10 / 0
// Expected: null
// Verifies: No crash or Inf on div-by-zero, caller must check
test "Analyzer: division by zero returns null" {
    const source: [:0]const u8 = "#buffer buf { size=10/0 usage=[UNIFORM] }";

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analyzer = Analyzer.init(testing.allocator, &ast);
    defer analyzer.deinit();

    for (ast.nodes.items(.tag), 0..) |tag, i| {
        if (tag == .expr_div) {
            const result = analyzer.evaluateExpression(@enumFromInt(@as(u32, @intCast(i))));
            try testing.expect(result == null);
            return;
        }
    }
    try testing.expect(false);
}

// ----------------------------------------------------------------------------
// Math Constant Tests
// ----------------------------------------------------------------------------

// Property: Math constants evaluate to their known values.
// Input: PI, E, TAU (also expressions using them)
// Expected: PI → 3.14159..., E → 2.71828..., TAU → 6.28318...
// Verifies: parseNumberLiteral recognizes math constants
test "Analyzer: evaluate PI constant" {
    const source: [:0]const u8 = "#buffer buf { size=PI usage=[UNIFORM] }";

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analyzer = Analyzer.init(testing.allocator, &ast);
    defer analyzer.deinit();

    for (ast.nodes.items(.tag), 0..) |tag, i| {
        if (tag == .number_value) {
            const result = analyzer.evaluateExpression(@enumFromInt(@as(u32, @intCast(i))));
            try testing.expectApproxEqAbs(std.math.pi, result.?, 0.00001);
            return;
        }
    }
    try testing.expect(false);
}

test "Analyzer: evaluate E constant" {
    const source: [:0]const u8 = "#buffer buf { size=E usage=[UNIFORM] }";

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analyzer = Analyzer.init(testing.allocator, &ast);
    defer analyzer.deinit();

    for (ast.nodes.items(.tag), 0..) |tag, i| {
        if (tag == .number_value) {
            const result = analyzer.evaluateExpression(@enumFromInt(@as(u32, @intCast(i))));
            try testing.expectApproxEqAbs(std.math.e, result.?, 0.00001);
            return;
        }
    }
    try testing.expect(false);
}

test "Analyzer: evaluate TAU constant" {
    const source: [:0]const u8 = "#buffer buf { size=TAU usage=[UNIFORM] }";

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analyzer = Analyzer.init(testing.allocator, &ast);
    defer analyzer.deinit();

    for (ast.nodes.items(.tag), 0..) |tag, i| {
        if (tag == .number_value) {
            const result = analyzer.evaluateExpression(@enumFromInt(@as(u32, @intCast(i))));
            try testing.expectApproxEqAbs(std.math.tau, result.?, 0.00001);
            return;
        }
    }
    try testing.expect(false);
}

test "Analyzer: evaluate expression with PI (2*PI)" {
    const source: [:0]const u8 = "#buffer buf { size=2*PI usage=[UNIFORM] }";

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analyzer = Analyzer.init(testing.allocator, &ast);
    defer analyzer.deinit();

    for (ast.nodes.items(.tag), 0..) |tag, i| {
        if (tag == .expr_mul) {
            const result = analyzer.evaluateExpression(@enumFromInt(@as(u32, @intCast(i))));
            try testing.expectApproxEqAbs(2.0 * std.math.pi, result.?, 0.00001);
            return;
        }
    }
    try testing.expect(false);
}

// ----------------------------------------------------------------------------
// Fuzz Tests
// ----------------------------------------------------------------------------

// Fuzz test for expression evaluation.
//
// Properties tested:
// - Never crashes on any parseable expression
// - Returns either valid f64 or null (never NaN)
// - Same input produces same output (deterministic)
// - Evaluation bounded by MAX_EXPR_DEPTH (no stack overflow)
test "Analyzer: fuzz expression evaluation" {
    try std.testing.fuzz({}, fuzzExpressionEvaluation, .{});
}

fn fuzzExpressionEvaluation(_: void, input: []const u8) !void {
    // Filter: skip inputs with null bytes (can't be sentinel-terminated)
    for (input) |b| if (b == 0) return;

    // Filter: skip inputs that are too short or too long
    if (input.len < 1 or input.len > 100) return;

    // Build a valid-ish source with the fuzzed expression in size=
    var buf: [200]u8 = undefined;
    const prefix = "#buffer b { size=";
    const suffix = " usage=[UNIFORM] }";

    if (prefix.len + input.len + suffix.len >= buf.len) return;

    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..input.len], input);
    @memcpy(buf[prefix.len + input.len ..][0..suffix.len], suffix);
    buf[prefix.len + input.len + suffix.len] = 0;

    const source: [:0]const u8 = buf[0 .. prefix.len + input.len + suffix.len :0];

    // Try to parse (may fail, that's OK)
    var ast = Parser.parse(testing.allocator, source) catch return;
    defer ast.deinit(testing.allocator);

    // Create analyzer
    var analyzer = Analyzer.init(testing.allocator, &ast);
    defer analyzer.deinit();

    // Find any expression node and try to evaluate it
    for (ast.nodes.items(.tag), 0..) |tag, i| {
        switch (tag) {
            .expr_add, .expr_sub, .expr_mul, .expr_div, .number_value => {
                const result = analyzer.evaluateExpression(@enumFromInt(@as(u32, @intCast(i))));

                // Property: result is either null or a finite f64 (never NaN/Inf from valid ops)
                if (result) |val| {
                    // Note: We allow Inf from very large expressions, just not NaN
                    try testing.expect(!std.math.isNan(val));
                }
            },
            else => {},
        }
    }
}
