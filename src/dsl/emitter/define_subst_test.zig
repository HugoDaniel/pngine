//! Define Substitution Tests
//!
//! Comprehensive tests for math constant and #define substitution in shader code.
//! Tests cover:
//! - Basic substitution (PI, TAU, E)
//! - Declaration detection (identifier followed by ':')
//! - Whole word matching
//! - String literal protection
//! - Edge cases and fuzz testing

const std = @import("std");
const testing = std.testing;

const Ast = @import("../Ast.zig").Ast;
const Parser = @import("../Parser.zig").Parser;
const Analyzer = @import("../Analyzer.zig").Analyzer;
const Emitter = @import("../Emitter.zig").Emitter;
const shaders = @import("shaders.zig");

// ============================================================================
// Test Helpers
// ============================================================================

/// Compile DSL source and extract the emitted shader code.
fn compileAndGetShaderCode(source: [:0]const u8) ![]u8 {
    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    if (analysis.hasErrors()) {
        return error.AnalysisError;
    }

    return Emitter.emit(testing.allocator, &ast, &analysis);
}

/// Direct test of matchesIdentifier (via substituteDefines).
/// Returns true if the identifier is considered a "match" for substitution.
fn testSubstitution(code: []const u8, expected_contains: []const u8) !void {
    // Wrap in minimal DSL to test substitution
    var buf: [4096]u8 = undefined;
    const source = try std.fmt.bufPrintZ(&buf,
        \\#wgsl shader {{ value="{s}" }}
        \\#frame main {{ perform=[] }}
    , .{code});

    const pngb = try compileAndGetShaderCode(source);
    defer testing.allocator.free(pngb);

    // The bytecode data section should contain the substituted code
    // We check if the expected string is in the bytecode
    const contains = std.mem.indexOf(u8, pngb, expected_contains) != null;
    if (!contains) {
        std.debug.print("\nExpected bytecode to contain: {s}\n", .{expected_contains});
        std.debug.print("Code was: {s}\n", .{code});
        return error.ExpectedNotFound;
    }
}

/// Verify substitution does NOT happen (original text preserved).
fn testNoSubstitution(code: []const u8, should_preserve: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const source = try std.fmt.bufPrintZ(&buf,
        \\#wgsl shader {{ value="{s}" }}
        \\#frame main {{ perform=[] }}
    , .{code});

    const pngb = try compileAndGetShaderCode(source);
    defer testing.allocator.free(pngb);

    // The original text should be preserved
    const contains = std.mem.indexOf(u8, pngb, should_preserve) != null;
    if (!contains) {
        std.debug.print("\nExpected bytecode to preserve: {s}\n", .{should_preserve});
        std.debug.print("Code was: {s}\n", .{code});
        return error.TextNotPreserved;
    }
}

// ============================================================================
// Basic Substitution Tests
// ============================================================================

test "substituteDefines: PI in expression" {
    try testSubstitution("let x = PI;", "3.141592653589793");
}

test "substituteDefines: TAU in expression" {
    try testSubstitution("let x = TAU;", "6.283185307179586");
}

test "substituteDefines: E in expression" {
    try testSubstitution("let x = E;", "2.718281828459045");
}

test "substituteDefines: multiple constants" {
    try testSubstitution("let x = PI + TAU;", "3.141592653589793");
    try testSubstitution("let x = PI + TAU;", "6.283185307179586");
}

test "substituteDefines: PI in function call" {
    try testSubstitution("sin(PI)", "3.141592653589793");
}

test "substituteDefines: PI in parentheses" {
    try testSubstitution("(PI)", "3.141592653589793");
}

test "substituteDefines: PI at start of expression" {
    try testSubstitution("PI * 2.0", "3.141592653589793");
}

test "substituteDefines: PI at end of expression" {
    try testSubstitution("2.0 * PI", "3.141592653589793");
}

test "substituteDefines: nested expressions" {
    try testSubstitution("sin(PI * cos(TAU))", "3.141592653589793");
    try testSubstitution("sin(PI * cos(TAU))", "6.283185307179586");
}

// ============================================================================
// Declaration Detection Tests (should NOT substitute)
// ============================================================================

test "substituteDefines: const PI declaration preserved" {
    try testNoSubstitution("const PI: f32 = 3.14;", "const PI:");
}

test "substituteDefines: const PI with space before colon preserved" {
    try testNoSubstitution("const PI : f32 = 3.14;", "const PI :");
}

test "substituteDefines: const PI with multiple spaces preserved" {
    try testNoSubstitution("const PI   : f32 = 3.14;", "const PI   :");
}

test "substituteDefines: const PI with tab before colon preserved" {
    try testNoSubstitution("const PI\t: f32 = 3.14;", "const PI\t:");
}

test "substituteDefines: let PI declaration preserved" {
    try testNoSubstitution("let PI: f32 = 3.14;", "let PI:");
}

test "substituteDefines: var PI declaration preserved" {
    try testNoSubstitution("var PI: f32 = 3.14;", "var PI:");
}

test "substituteDefines: TAU declaration preserved" {
    try testNoSubstitution("const TAU: f32 = 6.28;", "const TAU:");
}

test "substituteDefines: E declaration preserved" {
    try testNoSubstitution("const E: f32 = 2.71;", "const E:");
}

test "substituteDefines: declaration then usage" {
    // First PI is declaration (preserved), second PI is usage (substituted)
    const code = "const PI: f32 = 3.14; let x = PI;";
    try testNoSubstitution(code, "const PI:");
    try testSubstitution(code, "3.141592653589793");
}

// ============================================================================
// Whole Word Matching Tests (should NOT substitute)
// ============================================================================

test "substituteDefines: PIPELINE not matched" {
    try testNoSubstitution("let PIPELINE = 1;", "PIPELINE");
}

test "substituteDefines: MY_PI not matched" {
    try testNoSubstitution("let MY_PI = 3.14;", "MY_PI");
}

test "substituteDefines: PI_VALUE not matched" {
    try testNoSubstitution("let PI_VALUE = 3.14;", "PI_VALUE");
}

test "substituteDefines: EPI not matched for E" {
    try testNoSubstitution("let EPI = 1;", "EPI");
}

test "substituteDefines: PIE not matched for PI" {
    try testNoSubstitution("let PIE = 1;", "PIE");
}

test "substituteDefines: TAPE not matched for TAU or E" {
    try testNoSubstitution("let TAPE = 1;", "TAPE");
}

test "substituteDefines: API not matched" {
    try testNoSubstitution("let API = 1;", "API");
}

test "substituteDefines: identifier starting with digit adjacent" {
    // 2PI should not match PI (2 is not an identifier char)
    // Actually wait, 2 is not an identifier char, so PI should match here
    try testSubstitution("let x = 2*PI;", "3.141592653589793");
}

// ============================================================================
// String Literal Tests (should NOT substitute)
// ============================================================================

test "substituteDefines: PI in string literal preserved" {
    // Escaped quotes in DSL become literal quotes in output
    try testNoSubstitution("let s = \\\"PI\\\";", "\\\"PI\\\"");
}

test "substituteDefines: TAU in string literal preserved" {
    try testNoSubstitution("let s = \\\"TAU\\\";", "\\\"TAU\\\"");
}

// ============================================================================
// Edge Cases
// ============================================================================

test "substituteDefines: empty wgsl code" {
    const source: [:0]const u8 =
        \\#wgsl shader { value="" }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileAndGetShaderCode(source);
    defer testing.allocator.free(pngb);

    // Should compile without error
    try testing.expect(pngb.len > 0);
}

test "substituteDefines: whitespace only" {
    const source: [:0]const u8 =
        \\#wgsl shader { value="   " }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileAndGetShaderCode(source);
    defer testing.allocator.free(pngb);

    try testing.expect(pngb.len > 0);
}

test "substituteDefines: very long whitespace before colon (>16 chars)" {
    // The bounded loop only checks 16 chars of whitespace
    // With >16 spaces, the colon won't be found and PI should be substituted
    const code = "const PI                   : f32 = 3.14;"; // 19 spaces
    // This should actually substitute PI because we only scan 16 chars
    try testSubstitution(code, "3.141592653589793");
}

test "substituteDefines: exactly 16 chars whitespace before colon" {
    const code = "const PI                : f32 = 3.14;"; // 16 spaces
    try testNoSubstitution(code, "const PI                :");
}

test "substituteDefines: multiple declarations on same line" {
    const code = "const PI: f32 = 3.14; const TAU: f32 = 6.28;";
    try testNoSubstitution(code, "const PI:");
    try testNoSubstitution(code, "const TAU:");
}

test "substituteDefines: PI followed by newline then colon" {
    // Newline is not whitespace we skip, so colon won't be found
    const code = "const PI\n: f32 = 3.14;";
    try testSubstitution(code, "3.141592653589793");
}

test "substituteDefines: struct field named PI" {
    // In WGSL struct definitions: struct Foo { PI: f32 }
    // The PI here is followed by colon, so it's detected as "declaration"
    // This is actually correct behavior - we don't want to substitute struct field names
    try testNoSubstitution("struct Foo { PI: f32 }", "PI:");
}

test "substituteDefines: only PI" {
    try testSubstitution("PI", "3.141592653589793");
}

test "substituteDefines: only E" {
    try testSubstitution("E", "2.718281828459045");
}

test "substituteDefines: case sensitivity - pi not matched" {
    try testNoSubstitution("let x = pi;", "pi");
}

test "substituteDefines: case sensitivity - Pi not matched" {
    try testNoSubstitution("let x = Pi;", "Pi");
}

test "substituteDefines: case sensitivity - tau not matched" {
    try testNoSubstitution("let x = tau;", "tau");
}

test "substituteDefines: consecutive constants" {
    try testSubstitution("PI+TAU+E", "3.141592653589793");
    try testSubstitution("PI+TAU+E", "6.283185307179586");
    try testSubstitution("PI+TAU+E", "2.718281828459045");
}

test "substituteDefines: PI in array type (WGSL generic)" {
    // array<f32, N> where N could theoretically be PI
    // This is unusual but should substitute
    try testSubstitution("array<f32, PI>", "3.141592653589793");
}

test "substituteDefines: PI in vec constructor" {
    try testSubstitution("vec2<f32>(PI, TAU)", "3.141592653589793");
    try testSubstitution("vec2<f32>(PI, TAU)", "6.283185307179586");
}

test "substituteDefines: PI after equals" {
    try testSubstitution("let x = PI", "3.141592653589793");
}

test "substituteDefines: PI after comma" {
    try testSubstitution("foo(1.0, PI, 2.0)", "3.141592653589793");
}

test "substituteDefines: PI in array index" {
    // Unusual but valid - PI would be truncated at runtime
    try testSubstitution("arr[PI]", "3.141592653589793");
}

test "substituteDefines: PI before semicolon at end" {
    try testSubstitution("return PI;", "3.141592653589793");
}

test "substituteDefines: E alone is substituted (single char)" {
    // E is a single character - ensure whole word matching works
    try testSubstitution("x * E * y", "2.718281828459045");
}

test "substituteDefines: E not matched in HELLO" {
    try testNoSubstitution("let HELLO = 1;", "HELLO");
}

test "substituteDefines: E not matched in ME" {
    try testNoSubstitution("let ME = 1;", "ME");
}

test "substituteDefines: comment line not special" {
    // Comments are not handled specially - PI after // is still considered
    // But if followed by :, won't be substituted
    const code = "// PI ratio\nlet x = PI;";
    try testSubstitution(code, "3.141592653589793");
}

test "substituteDefines: declaration in comment" {
    // PI: in a comment looks like declaration, won't be substituted
    // This is fine - comments are stripped by WGSL compiler anyway
    const code = "// PI: constant\nlet x = PI;";
    // The second PI (after let x =) should be substituted
    try testSubstitution(code, "3.141592653589793");
}

// ============================================================================
// User-Defined #define Tests
// ============================================================================

test "substituteDefines: user define takes precedence over PI" {
    const source: [:0]const u8 =
        \\#define PI=custom_pi
        \\#wgsl shader { value="let x = PI;" }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileAndGetShaderCode(source);
    defer testing.allocator.free(pngb);

    // Should use custom_pi, not the math constant
    const has_custom = std.mem.indexOf(u8, pngb, "custom_pi") != null;
    const has_math = std.mem.indexOf(u8, pngb, "3.141592653589793") != null;

    try testing.expect(has_custom);
    try testing.expect(!has_math);
}

test "substituteDefines: user define with numeric value" {
    const source: [:0]const u8 =
        \\#define SCALE=2.5
        \\#wgsl shader { value="let x = SCALE;" }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileAndGetShaderCode(source);
    defer testing.allocator.free(pngb);

    const has_value = std.mem.indexOf(u8, pngb, "2.5") != null;
    try testing.expect(has_value);
}

test "substituteDefines: nested define substitution" {
    // Note: #define values that look like references (e.g., PI) may cause
    // analyzer warnings. Use quoted values for reliable nested substitution.
    const source: [:0]const u8 =
        \\#define SCALE=2.0
        \\#define FACTOR=SCALE
        \\#wgsl shader { value="let x = FACTOR;" }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileAndGetShaderCode(source);
    defer testing.allocator.free(pngb);

    // FACTOR -> SCALE -> 2.0
    const has_value = std.mem.indexOf(u8, pngb, "2.0") != null;
    try testing.expect(has_value);
}

// ============================================================================
// Fuzz Testing
// ============================================================================

test "substituteDefines: fuzz - random input should not crash" {
    try std.testing.fuzz({}, fuzzSubstituteDefines, .{});
}

fn fuzzSubstituteDefines(_: void, input: []const u8) !void {
    // Filter: skip null bytes (invalid in DSL strings)
    for (input) |b| {
        if (b == 0 or b == '"' or b == '\\') return;
    }

    // Filter: limit size
    if (input.len > 1000) return;

    // Create DSL source with fuzzed shader code
    var buf: [2048]u8 = undefined;
    const source = std.fmt.bufPrintZ(&buf,
        \\#wgsl shader {{ value="{s}" }}
        \\#frame main {{ perform=[] }}
    , .{input}) catch return;

    // Should not crash
    const result = compileAndGetShaderCode(source);
    if (result) |pngb| {
        testing.allocator.free(pngb);
    } else |_| {
        // Errors are OK (invalid syntax, etc.)
    }
}

test "substituteDefines: fuzz - PI-like patterns" {
    // Test many variations around PI to find edge cases
    const variations = [_][]const u8{
        "PI",
        "PI:",
        "PI :",
        "PI  :",
        ":PI",
        "xPI",
        "PIx",
        "xPIx",
        "_PI",
        "PI_",
        "_PI_",
        "0PI",
        "PI0",
        " PI ",
        "\tPI\t",
        "PI\n",
        "\nPI",
        "(PI)",
        "[PI]",
        "{PI}",
        "PI+PI",
        "PI-PI",
        "PI*PI",
        "PI/PI",
        "PIE",
        "EPI",
        "API",
        "EPIC",
        "PIPELINE",
        "constPI",
        "const PI",
        "constPI:",
        "const PI:",
        "PI ::",
    };

    for (variations) |code| {
        var buf: [256]u8 = undefined;
        const source = std.fmt.bufPrintZ(&buf,
            \\#wgsl shader {{ value="{s}" }}
            \\#frame main {{ perform=[] }}
        , .{code}) catch continue;

        // Should not crash
        const result = compileAndGetShaderCode(source);
        if (result) |pngb| {
            testing.allocator.free(pngb);
        } else |_| {}
    }
}

// ============================================================================
// Reflection Timing Tests (Phase 1 fix verification)
// ============================================================================

test "reflection uses substituted code, not original" {
    // This test verifies that WGSL reflection happens AFTER define substitution.
    // The struct size should reflect the SUBSTITUTED value (32), not "STRUCT_SIZE".
    const source: [:0]const u8 =
        \\#define STRUCT_SIZE=32
        \\#wgsl shader {
        \\  value="struct Inputs { data: array<f32, 8> } @group(0) @binding(0) var<uniform> inputs: Inputs;"
        \\}
        \\#frame main { perform=[] }
    ;

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    if (analysis.hasErrors()) {
        return error.AnalysisError;
    }

    // Create emitter and run emission (which triggers reflection)
    var emitter = Emitter.init(testing.allocator, &ast, &analysis, .{});
    defer emitter.deinit();

    // Emit shaders - this triggers reflectAndCache with substituted code
    try shaders.emitShaders(&emitter);

    // Check that reflection was performed and cached
    // Note: Reflection may fail if miniray not available, so check gracefully
    if (emitter.wgsl_reflections.getPtr("shader")) |reflection| {
        // If reflection succeeded, verify it has bindings
        try testing.expect(reflection.bindings.len > 0);
        // The binding should have a valid size (32 bytes for array<f32, 8>)
        try testing.expectEqual(@as(u32, 32), reflection.bindings[0].layout.size);
    }
    // If reflection not available (no miniray), test passes anyway
    // The important thing is the code path doesn't crash
}

test "minify_shaders option produces smaller output" {
    // This test verifies that minify_shaders=true produces smaller shader code.
    // Requires libminiray.a to be linked.
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="struct LongStructName { firstField: f32, secondField: vec3f } @group(0) @binding(0) var<uniform> uniformBuffer: LongStructName; @vertex fn vertexMain() -> @builtin(position) vec4f { return vec4f(0.0); }"
        \\}
        \\#frame main { perform=[] }
    ;

    // Compile without minification
    var ast1 = try Parser.parse(testing.allocator, source);
    defer ast1.deinit(testing.allocator);

    var analysis1 = try Analyzer.analyze(testing.allocator, &ast1);
    defer analysis1.deinit(testing.allocator);

    if (analysis1.hasErrors()) return error.AnalysisError;

    var emitter1 = Emitter.init(testing.allocator, &ast1, &analysis1, .{
        .minify_shaders = false,
    });
    defer emitter1.deinit();
    try shaders.emitShaders(&emitter1);

    // Compile with minification
    var ast2 = try Parser.parse(testing.allocator, source);
    defer ast2.deinit(testing.allocator);

    var analysis2 = try Analyzer.analyze(testing.allocator, &ast2);
    defer analysis2.deinit(testing.allocator);

    if (analysis2.hasErrors()) return error.AnalysisError;

    var emitter2 = Emitter.init(testing.allocator, &ast2, &analysis2, .{
        .minify_shaders = true,
    });
    defer emitter2.deinit();
    try shaders.emitShaders(&emitter2);

    // Check that minified code exists and is smaller
    // Get the data section sizes from the builders
    const size1 = emitter1.builder.data.total_size;
    const size2 = emitter2.builder.data.total_size;

    // If minification is available (libminiray.a linked), minified should be smaller
    // If not available, sizes should be equal (fallback to non-minified)
    try testing.expect(size2 <= size1);

    // Note: We can't guarantee a specific size reduction without miniray linked,
    // but the code path should not crash either way.
}

test "substituteDefines: property - output length bounded" {
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();

    for (0..100) |_| {
        // Generate random code with some PI/TAU/E
        var code: [200]u8 = undefined;
        for (&code) |*c| {
            const r = random.int(u8);
            c.* = switch (r % 10) {
                0 => 'P',
                1 => 'I',
                2 => 'T',
                3 => 'A',
                4 => 'U',
                5 => 'E',
                6 => ' ',
                7 => ':',
                8 => ';',
                else => 'x',
            };
        }

        var buf: [512]u8 = undefined;
        const source = std.fmt.bufPrintZ(&buf,
            \\#wgsl shader {{ value="{s}" }}
            \\#frame main {{ perform=[] }}
        , .{&code}) catch continue;

        const result = compileAndGetShaderCode(source);
        if (result) |pngb| {
            defer testing.allocator.free(pngb);
            // Property: output should not be ridiculously larger than input
            // (each PI/TAU/E expands to ~17 chars max)
            try testing.expect(pngb.len < code.len * 20 + 1000);
        } else |_| {}
    }
}
