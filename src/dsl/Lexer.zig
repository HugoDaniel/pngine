//! DSL Lexer for PNGine
//!
//! Tokenizes the macro-based DSL syntax into tokens for parsing.
//! Uses sentinel-terminated input for safe EOF handling.
//! Implements a labeled switch state machine for zero function call overhead.
//!
//! ## Design
//!
//! - **Sentinel-terminated input**: Uses `[:0]const u8` for safe EOF detection
//! - **Labeled switch**: State machine without function call overhead
//! - **StaticStringMap**: O(1) macro keyword lookup
//! - **Bounded loops**: All loops have explicit MAX_TOKEN_LEN bound
//!
//! ## Invariants
//!
//! - Input must be sentinel-terminated (buffer[len] == 0)
//! - Token locations are always valid: `end >= start`
//! - Token bounds never exceed source length: `end <= source.len`
//! - EOF token has `start == end == source.len`
//! - Every input eventually produces EOF (bounded execution)
//!
//! ## Complexity
//!
//! - `next()`: O(n) where n = token length, bounded by MAX_TOKEN_LEN
//! - Total tokenization: O(source.len)

const std = @import("std");
const Token = @import("Token.zig").Token;
const macro_keywords = @import("Token.zig").macro_keywords;
const literal_keywords = @import("Token.zig").literal_keywords;

pub const Lexer = struct {
    /// Sentinel-terminated input buffer.
    /// Invariant: buffer[buffer.len] == 0 (sentinel).
    buffer: [:0]const u8,

    /// Current position in buffer.
    /// Invariant: index <= buffer.len.
    index: u32,

    const Self = @This();

    /// Maximum length of a single token (prevents infinite loops).
    const MAX_TOKEN_LEN: u32 = 1 << 20; // 1MB

    pub fn init(buffer: [:0]const u8) Self {
        return .{
            .buffer = buffer,
            .index = 0,
        };
    }

    /// Tokenize the next token from the input.
    /// Returns EOF when input is exhausted.
    pub fn next(self: *Self) Token {
        // Pre-condition
        std.debug.assert(self.index <= self.buffer.len);

        var result: Token = .{
            .tag = undefined,
            .loc = .{ .start = self.index, .end = undefined },
        };

        // Labeled switch state machine
        state: switch (State.start) {
            .start => {
                const c = self.buffer[self.index];
                switch (c) {
                    0 => {
                        // Sentinel - EOF
                        result.tag = .eof;
                        result.loc.end = self.index;

                        // Post-condition: EOF at end
                        std.debug.assert(self.index == self.buffer.len);
                        return result;
                    },
                    ' ', '\t', '\n', '\r' => {
                        self.index += 1;
                        result.loc.start = self.index;
                        continue :state .start;
                    },
                    '#' => {
                        self.index += 1;
                        continue :state .hash;
                    },
                    '"' => {
                        self.index += 1;
                        continue :state .string_literal;
                    },
                    '/' => {
                        const next_c = self.buffer[self.index + 1];
                        if (next_c == '/') {
                            self.index += 2;
                            continue :state .line_comment;
                        } else {
                            // Division operator for arithmetic expressions
                            result.tag = .slash;
                            self.index += 1;
                        }
                    },
                    'a'...'z', 'A'...'Z', '_' => continue :state .identifier,
                    '0'...'9' => continue :state .number,
                    '-' => {
                        // Always emit minus as separate token
                        // Parser handles unary negation vs binary subtraction
                        result.tag = .minus;
                        self.index += 1;
                    },
                    '+' => {
                        result.tag = .plus;
                        self.index += 1;
                    },
                    '*' => {
                        result.tag = .star;
                        self.index += 1;
                    },
                    '{' => {
                        result.tag = .l_brace;
                        self.index += 1;
                    },
                    '}' => {
                        result.tag = .r_brace;
                        self.index += 1;
                    },
                    '[' => {
                        result.tag = .l_bracket;
                        self.index += 1;
                    },
                    ']' => {
                        result.tag = .r_bracket;
                        self.index += 1;
                    },
                    '(' => {
                        result.tag = .l_paren;
                        self.index += 1;
                    },
                    ')' => {
                        result.tag = .r_paren;
                        self.index += 1;
                    },
                    '=' => {
                        result.tag = .equals;
                        self.index += 1;
                    },
                    ',' => {
                        result.tag = .comma;
                        self.index += 1;
                    },
                    '.' => {
                        result.tag = .dot;
                        self.index += 1;
                    },
                    else => {
                        result.tag = .invalid;
                        self.index += 1;
                    },
                }
            },
            .hash => {
                // Read macro name after #
                const macro_start = self.index;
                for (0..MAX_TOKEN_LEN) |_| {
                    const c = self.buffer[self.index];
                    switch (c) {
                        'a'...'z', 'A'...'Z', '_', '0'...'9' => self.index += 1,
                        else => break,
                    }
                } else unreachable; // Token exceeds MAX_TOKEN_LEN
                const macro_name = self.buffer[macro_start..self.index];
                result.tag = macro_keywords.get(macro_name) orelse .invalid;
            },
            .identifier => {
                for (0..MAX_TOKEN_LEN) |_| {
                    const c = self.buffer[self.index];
                    switch (c) {
                        'a'...'z', 'A'...'Z', '_', '0'...'9', '-' => self.index += 1,
                        else => break,
                    }
                } else unreachable;
                // WebGPU properties often use boolean flags (e.g., writeMask, depthTest)
                // Distinguish true/false from regular identifiers for type safety
                const ident = self.buffer[result.loc.start..self.index];
                result.tag = literal_keywords.get(ident) orelse .identifier;
            },
            .number => {
                // WebGPU uses hex for usage flags (e.g., 0x00000010 for COPY_DST)
                // and color values (0xRRGGBBAA format)
                if (self.buffer[self.index] == '0') {
                    const next_char = self.buffer[self.index + 1];
                    if (next_char == 'x' or next_char == 'X') {
                        self.index += 2;
                        for (0..MAX_TOKEN_LEN) |_| {
                            const c = self.buffer[self.index];
                            switch (c) {
                                '0'...'9', 'a'...'f', 'A'...'F' => self.index += 1,
                                else => break,
                            }
                        } else unreachable;
                        result.tag = .number_literal;
                        break :state;
                    }
                }
                // Integer part (decimal)
                for (0..MAX_TOKEN_LEN) |_| {
                    const c = self.buffer[self.index];
                    switch (c) {
                        '0'...'9' => self.index += 1,
                        else => break,
                    }
                } else unreachable; // Token exceeds MAX_TOKEN_LEN
                // Decimal part
                if (self.buffer[self.index] == '.') {
                    self.index += 1;
                    for (0..MAX_TOKEN_LEN) |_| {
                        const c = self.buffer[self.index];
                        switch (c) {
                            '0'...'9' => self.index += 1,
                            else => break,
                        }
                    } else unreachable; // Token exceeds MAX_TOKEN_LEN
                }
                result.tag = .number_literal;
            },
            .string_literal => {
                for (0..MAX_TOKEN_LEN) |_| {
                    const c = self.buffer[self.index];
                    switch (c) {
                        0 => {
                            // Unterminated string
                            result.tag = .invalid;
                            break;
                        },
                        '"' => {
                            self.index += 1;
                            result.tag = .string_literal;
                            break;
                        },
                        '\\' => {
                            // Escape sequence - skip next char
                            self.index += 1;
                            if (self.buffer[self.index] != 0) {
                                self.index += 1;
                            }
                        },
                        else => self.index += 1,
                    }
                } else unreachable; // Token exceeds MAX_TOKEN_LEN
            },
            .line_comment => {
                for (0..MAX_TOKEN_LEN) |_| {
                    const c = self.buffer[self.index];
                    switch (c) {
                        0, '\n' => break,
                        else => self.index += 1,
                    }
                } else unreachable; // Token exceeds MAX_TOKEN_LEN
                // Check if it's a doc comment (///)
                const comment_text = self.buffer[result.loc.start..self.index];
                result.tag = if (comment_text.len >= 3 and comment_text[2] == '/')
                    .doc_comment
                else
                    .line_comment;
            },
        }

        result.loc.end = self.index;

        // Post-condition: valid location
        std.debug.assert(result.loc.end >= result.loc.start);

        return result;
    }

    const State = enum {
        start,
        hash,
        identifier,
        number,
        string_literal,
        line_comment,
    };
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn expectTokens(source: [:0]const u8, expected_tags: []const Token.Tag) !void {
    var lexer = Lexer.init(source);
    for (expected_tags) |expected| {
        const tok = lexer.next();
        try testing.expectEqual(expected, tok.tag);
    }
}

fn expectTokensWithSlices(
    source: [:0]const u8,
    expected: []const struct { tag: Token.Tag, slice: []const u8 },
) !void {
    var lexer = Lexer.init(source);
    for (expected) |exp| {
        const tok = lexer.next();
        try testing.expectEqual(exp.tag, tok.tag);
        try testing.expectEqualStrings(exp.slice, tok.slice(source));
    }
}

test "Lexer: empty input" {
    const source: [:0]const u8 = "";
    var lexer = Lexer.init(source);
    const tok = lexer.next();
    try testing.expectEqual(Token.Tag.eof, tok.tag);
    try testing.expectEqual(@as(u32, 0), tok.loc.start);
    try testing.expectEqual(@as(u32, 0), tok.loc.end);
}

test "Lexer: whitespace only" {
    const source: [:0]const u8 = "   \t\n\r  ";
    var lexer = Lexer.init(source);
    const tok = lexer.next();
    try testing.expectEqual(Token.Tag.eof, tok.tag);
}

test "Lexer: macro keywords" {
    try expectTokens("#renderPipeline", &.{ .macro_render_pipeline, .eof });
    try expectTokens("#computePipeline", &.{ .macro_compute_pipeline, .eof });
    try expectTokens("#buffer", &.{ .macro_buffer, .eof });
    try expectTokens("#texture", &.{ .macro_texture, .eof });
    try expectTokens("#sampler", &.{ .macro_sampler, .eof });
    try expectTokens("#bindGroup", &.{ .macro_bind_group, .eof });
    try expectTokens("#frame", &.{ .macro_frame, .eof });
    try expectTokens("#wgsl", &.{ .macro_wgsl, .eof });
    try expectTokens("#shaderModule", &.{ .macro_shader_module, .eof });
    try expectTokens("#data", &.{ .macro_data, .eof });
    try expectTokens("#queue", &.{ .macro_queue, .eof });
    try expectTokens("#define", &.{ .macro_define, .eof });
    try expectTokens("#renderPass", &.{ .macro_render_pass, .eof });
    try expectTokens("#computePass", &.{ .macro_compute_pass, .eof });
}

test "Lexer: unknown macro" {
    try expectTokens("#unknown", &.{ .invalid, .eof });
}

test "Lexer: identifiers" {
    try expectTokensWithSlices("foo bar baz", &.{
        .{ .tag = .identifier, .slice = "foo" },
        .{ .tag = .identifier, .slice = "bar" },
        .{ .tag = .identifier, .slice = "baz" },
        .{ .tag = .eof, .slice = "" },
    });
}

test "Lexer: identifiers with hyphens and underscores" {
    try expectTokensWithSlices("entry-point entry_point camelCase", &.{
        .{ .tag = .identifier, .slice = "entry-point" },
        .{ .tag = .identifier, .slice = "entry_point" },
        .{ .tag = .identifier, .slice = "camelCase" },
        .{ .tag = .eof, .slice = "" },
    });
}

test "Lexer: numbers" {
    try expectTokensWithSlices("123 456 0", &.{
        .{ .tag = .number_literal, .slice = "123" },
        .{ .tag = .number_literal, .slice = "456" },
        .{ .tag = .number_literal, .slice = "0" },
        .{ .tag = .eof, .slice = "" },
    });
}

test "Lexer: negative numbers as minus and number" {
    // Minus is always a separate token; parser handles unary negation
    try expectTokensWithSlices("-1 -0.5 -123", &.{
        .{ .tag = .minus, .slice = "-" },
        .{ .tag = .number_literal, .slice = "1" },
        .{ .tag = .minus, .slice = "-" },
        .{ .tag = .number_literal, .slice = "0.5" },
        .{ .tag = .minus, .slice = "-" },
        .{ .tag = .number_literal, .slice = "123" },
        .{ .tag = .eof, .slice = "" },
    });
}

test "Lexer: decimal numbers" {
    try expectTokensWithSlices("0.5 1.0 3.14159", &.{
        .{ .tag = .number_literal, .slice = "0.5" },
        .{ .tag = .number_literal, .slice = "1.0" },
        .{ .tag = .number_literal, .slice = "3.14159" },
        .{ .tag = .eof, .slice = "" },
    });
}

test "Lexer: strings" {
    try expectTokensWithSlices(
        \\"hello" "world"
    , &.{
        .{ .tag = .string_literal, .slice = "\"hello\"" },
        .{ .tag = .string_literal, .slice = "\"world\"" },
        .{ .tag = .eof, .slice = "" },
    });
}

test "Lexer: string with escapes" {
    try expectTokensWithSlices(
        \\"hello \"world\""
    , &.{
        .{ .tag = .string_literal, .slice = "\"hello \\\"world\\\"\"" },
        .{ .tag = .eof, .slice = "" },
    });
}

test "Lexer: punctuation" {
    try expectTokens("{ } [ ] ( ) = , .", &.{
        .l_brace,
        .r_brace,
        .l_bracket,
        .r_bracket,
        .l_paren,
        .r_paren,
        .equals,
        .comma,
        .dot,
        .eof,
    });
}

test "Lexer: arithmetic operators" {
    try expectTokens("+ - * /", &.{
        .plus,
        .minus,
        .star,
        .slash,
        .eof,
    });
}

test "Lexer: arithmetic expression" {
    try expectTokens("1 + 2", &.{
        .number_literal,
        .plus,
        .number_literal,
        .eof,
    });
    try expectTokens("10 - 5", &.{
        .number_literal,
        .minus,
        .number_literal,
        .eof,
    });
    try expectTokens("3 * 4", &.{
        .number_literal,
        .star,
        .number_literal,
        .eof,
    });
    try expectTokens("8 / 2", &.{
        .number_literal,
        .slash,
        .number_literal,
        .eof,
    });
}

test "Lexer: complex arithmetic expression" {
    // (1 + 2) * 3
    try expectTokens("(1 + 2) * 3", &.{
        .l_paren,
        .number_literal,
        .plus,
        .number_literal,
        .r_paren,
        .star,
        .number_literal,
        .eof,
    });
    // 0xDEADBEEF + 0x123
    try expectTokens("0xDEADBEEF + 0x123", &.{
        .number_literal,
        .plus,
        .number_literal,
        .eof,
    });
}

test "Lexer: minus as operator" {
    // Minus operator with space
    try expectTokens("5 - 3", &.{
        .number_literal,
        .minus,
        .number_literal,
        .eof,
    });
    // Minus without space - still separate tokens
    try expectTokens("5-3", &.{
        .number_literal,
        .minus,
        .number_literal,
        .eof,
    });
    // Unary minus (parser interprets as negation)
    try expectTokens("-3", &.{
        .minus,
        .number_literal,
        .eof,
    });
    // Double unary minus
    try expectTokens("5 - -3", &.{
        .number_literal,
        .minus,
        .minus,
        .number_literal,
        .eof,
    });
}

test "Lexer: slash vs comment" {
    // Division
    try expectTokens("10 / 2", &.{
        .number_literal,
        .slash,
        .number_literal,
        .eof,
    });
    // Comment (double slash)
    try expectTokens("10 // comment", &.{
        .number_literal,
        .line_comment,
        .eof,
    });
}

// NOTE: The $namespace.name reference syntax has been removed.
// Bare identifiers are now used everywhere and resolved based on context.

test "Lexer: line comments" {
    try expectTokensWithSlices("foo // comment\nbar", &.{
        .{ .tag = .identifier, .slice = "foo" },
        .{ .tag = .line_comment, .slice = "// comment" },
        .{ .tag = .identifier, .slice = "bar" },
        .{ .tag = .eof, .slice = "" },
    });
}

test "Lexer: doc comments" {
    try expectTokensWithSlices("/// doc comment\nfoo", &.{
        .{ .tag = .doc_comment, .slice = "/// doc comment" },
        .{ .tag = .identifier, .slice = "foo" },
        .{ .tag = .eof, .slice = "" },
    });
}

test "Lexer: simple render pipeline" {
    const source: [:0]const u8 =
        \\#renderPipeline pipeline {
        \\  layout=auto
        \\  vertex={ entryPoint=vertexMain }
        \\}
    ;
    try expectTokens(source, &.{
        .macro_render_pipeline, .identifier, .l_brace,
        .identifier,            .equals,     .identifier,
        .identifier,            .equals,     .l_brace,
        .identifier,            .equals,     .identifier,
        .r_brace,               .r_brace,    .eof,
    });
}

test "Lexer: buffer with array" {
    const source: [:0]const u8 = "#buffer buf { size=100 usage=[VERTEX STORAGE] }";
    try expectTokens(source, &.{
        .macro_buffer,
        .identifier,
        .l_brace,
        .identifier,
        .equals,
        .number_literal,
        .identifier,
        .equals,
        .l_bracket,
        .identifier,
        .identifier,
        .r_bracket,
        .r_brace,
        .eof,
    });
}

test "Lexer: frame with perform array" {
    const source: [:0]const u8 = "#frame main { perform=[pass1 pass2] }";
    try expectTokens(source, &.{
        .macro_frame,
        .identifier,
        .l_brace,
        .identifier,
        .equals,
        .l_bracket,
        .identifier,
        .identifier,
        .r_bracket,
        .r_brace,
        .eof,
    });
}

test "Lexer: define constant" {
    const source: [:0]const u8 = "#define FOV=1.5";
    try expectTokens(source, &.{
        .macro_define,
        .identifier,
        .equals,
        .number_literal,
        .eof,
    });
}

test "Lexer: complex nested structure" {
    const source: [:0]const u8 =
        \\#renderPass drawPass {
        \\  colorAttachments=[{
        \\    view=contextCurrentTexture
        \\    clearValue=[0.0 0.0 0.0 1.0]
        \\    loadOp=clear
        \\  }]
        \\}
    ;
    var lexer = Lexer.init(source);
    var count: usize = 0;
    while (lexer.next().tag != .eof) : (count += 1) {}
    // Just verify it doesn't crash and produces reasonable token count
    try testing.expect(count > 15);
}

test "Lexer: unterminated string" {
    const source: [:0]const u8 = "\"unterminated";
    var lexer = Lexer.init(source);
    const tok = lexer.next();
    try testing.expectEqual(Token.Tag.invalid, tok.tag);
}

test "Lexer: string with newline escape" {
    try expectTokensWithSlices(
        \\"line1\nline2"
    , &.{
        .{ .tag = .string_literal, .slice = "\"line1\\nline2\"" },
        .{ .tag = .eof, .slice = "" },
    });
}

test "Lexer: property preserves location" {
    const source: [:0]const u8 = "foo=bar";
    var lexer = Lexer.init(source);

    const foo = lexer.next();
    try testing.expectEqual(@as(u32, 0), foo.loc.start);
    try testing.expectEqual(@as(u32, 3), foo.loc.end);

    const eq = lexer.next();
    try testing.expectEqual(@as(u32, 3), eq.loc.start);
    try testing.expectEqual(@as(u32, 4), eq.loc.end);

    const bar = lexer.next();
    try testing.expectEqual(@as(u32, 4), bar.loc.start);
    try testing.expectEqual(@as(u32, 7), bar.loc.end);
}

test "Lexer: full simpleTriangle example" {
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

    var lexer = Lexer.init(source);
    var token_count: usize = 0;
    var last_tag: Token.Tag = .invalid;

    // Count tokens and ensure no invalid ones (except final eof)
    while (true) {
        const tok = lexer.next();
        if (tok.tag == .invalid) {
            std.debug.print("Invalid token at {d}-{d}: '{s}'\n", .{
                tok.loc.start,
                tok.loc.end,
                tok.slice(source),
            });
        }
        // Comments are valid tokens, don't fail on them
        if (tok.tag != .line_comment and tok.tag != .doc_comment) {
            try testing.expect(tok.tag != .invalid);
        }
        token_count += 1;
        last_tag = tok.tag;
        if (tok.tag == .eof) break;
    }

    try testing.expectEqual(Token.Tag.eof, last_tag);
    try testing.expect(token_count > 50);
}

// Fuzz test for lexer safety
test "Lexer: fuzz properties" {
    // Test with various edge cases
    const edge_cases = [_][:0]const u8{
        "",
        " ",
        "#",
        "##",
        "#a",
        "\"",
        "\"\\\"",
        "///",
        "//\n",
        "123.456.789",
        "-",
        "--1",
        "{}[]()=,.",
    };

    for (edge_cases) |source| {
        var lexer = Lexer.init(source);
        // Just ensure it doesn't crash and terminates
        for (0..100) |_| {
            const tok = lexer.next();
            // Property: end >= start
            try testing.expect(tok.loc.end >= tok.loc.start);
            if (tok.tag == .eof) break;
        }
    }
}

// Fuzz test edge cases for hex number parsing
test "Lexer: hex number edge cases" {
    const hex_edge_cases = [_][:0]const u8{
        "0x",
        "0X",
        "0x0",
        "0xG",
        "0xFFFFFFFF",
        "0x",
        "-0x1",
        "0x0x0",
        "0xABCDEFabcdef0123456789",
        "0x ",
        "0x\n",
    };

    for (hex_edge_cases) |source| {
        var lexer = Lexer.init(source);
        for (0..100) |_| {
            const tok = lexer.next();
            // Property: valid token range
            try testing.expect(tok.loc.end >= tok.loc.start);
            try testing.expect(tok.loc.end <= source.len);
            if (tok.tag == .eof) break;
        }
    }
}

// Fuzz test edge cases for boolean literal parsing
test "Lexer: boolean literal edge cases" {
    const bool_edge_cases = [_][:0]const u8{
        "true",
        "false",
        "truefalse",
        "falsetrue",
        "true123",
        "false_",
        "TRUE",
        "FALSE",
        "True",
        "False",
        "truetruetrue",
        "true=false",
        "t",
        "f",
        "tr",
        "fa",
    };

    for (bool_edge_cases) |source| {
        var lexer = Lexer.init(source);
        for (0..100) |_| {
            const tok = lexer.next();
            // Property: valid token range
            try testing.expect(tok.loc.end >= tok.loc.start);
            try testing.expect(tok.loc.end <= source.len);
            if (tok.tag == .eof) break;
        }
    }
}

// Property-based fuzz test for lexer using std.testing.fuzz API
test "Lexer: hex numbers" {
    try expectTokensWithSlices("0x123ABC", &.{
        .{ .tag = .number_literal, .slice = "0x123ABC" },
        .{ .tag = .eof, .slice = "" },
    });
    try expectTokensWithSlices("0xFF", &.{
        .{ .tag = .number_literal, .slice = "0xFF" },
        .{ .tag = .eof, .slice = "" },
    });
    try expectTokensWithSlices("0x0", &.{
        .{ .tag = .number_literal, .slice = "0x0" },
        .{ .tag = .eof, .slice = "" },
    });
    // Uppercase X
    try expectTokensWithSlices("0XFFEE", &.{
        .{ .tag = .number_literal, .slice = "0XFFEE" },
        .{ .tag = .eof, .slice = "" },
    });
}

test "Lexer: boolean literals" {
    try expectTokensWithSlices("true", &.{
        .{ .tag = .boolean_literal, .slice = "true" },
        .{ .tag = .eof, .slice = "" },
    });
    try expectTokensWithSlices("false", &.{
        .{ .tag = .boolean_literal, .slice = "false" },
        .{ .tag = .eof, .slice = "" },
    });
    // Booleans in property context
    try expectTokens("enabled=true", &.{
        .identifier,
        .equals,
        .boolean_literal,
        .eof,
    });
}

test "Lexer: fuzz with random input" {
    try std.testing.fuzz({}, fuzzLexerProperties, .{});
}

/// Fuzz test function for lexer properties.
/// Properties tested:
/// - Token end >= start (valid range)
/// - Token bounds within source
/// - Always produces EOF
fn fuzzLexerProperties(_: void, input: []const u8) !void {
    // Filter out inputs with embedded nulls (invalid for sentinel-terminated)
    for (input) |byte| {
        if (byte == 0) return; // Skip this input
    }

    // Create sentinel-terminated copy
    var buf: [512]u8 = undefined;
    if (input.len >= buf.len) return; // Skip too-large inputs
    @memcpy(buf[0..input.len], input);
    buf[input.len] = 0;

    const source: [:0]const u8 = buf[0..input.len :0];
    var lexer = Lexer.init(source);

    // Tokenize entire input
    var token_count: usize = 0;
    for (0..10000) |_| {
        const tok = lexer.next();

        // Property 1: end >= start (always valid range)
        try testing.expect(tok.loc.end >= tok.loc.start);

        // Property 2: token within source bounds
        try testing.expect(tok.loc.start <= source.len);
        try testing.expect(tok.loc.end <= source.len);

        token_count += 1;
        if (tok.tag == .eof) break;
    } else {
        // Bounded iteration should always complete
        return error.TestUnexpectedResult;
    }

    // Property 3: always produces at least EOF
    try testing.expect(token_count >= 1);
}
