//! PBSF S-Expression Tokenizer
//!
//! Tokenizes PBSF (PNGine Binary S-expression Format) text into tokens.
//! Uses sentinel-terminated input with labeled switch state machine for
//! zero function call overhead.
//!
//! Invariants:
//! - Token locations are always valid indices into the source buffer
//! - Token end >= token start
//! - EOF token location points to buffer end

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

/// Token produced by the tokenizer.
/// Contains only tag and location - no string copy for efficiency.
pub const Token = struct {
    tag: Tag,
    loc: Loc,

    /// Token location within source buffer.
    /// Uses u32 for explicit sizing (supports up to 4GB source files).
    pub const Loc = struct {
        start: u32,
        end: u32,
    };

    pub const Tag = enum(u8) {
        // Structural
        left_paren,
        right_paren,

        // Literals
        atom, // identifier, keyword, symbol like $buf:0, @swapchain
        string, // "..."
        number, // integer or float

        // Special
        comment, // ; to end of line
        eof,
        invalid,

        /// Returns the lexeme for fixed tokens, null for variable tokens.
        pub fn lexeme(tag: Tag) ?[]const u8 {
            return switch (tag) {
                .left_paren => "(",
                .right_paren => ")",
                .atom, .string, .number, .comment => null,
                .eof => "",
                .invalid => null,
            };
        }
    };

    /// Get the source slice for this token.
    pub fn slice(self: Token, source: []const u8) []const u8 {
        // Pre-condition: token location is valid
        assert(self.loc.end >= self.loc.start);
        assert(self.loc.end <= source.len);

        return source[self.loc.start..self.loc.end];
    }

    /// Get start position as usize (for indexing).
    pub fn start(self: Token) usize {
        return self.loc.start;
    }

    /// Get end position as usize (for indexing).
    pub fn end(self: Token) usize {
        return self.loc.end;
    }
};

/// Tokenizer state machine.
pub const Tokenizer = struct {
    buffer: [:0]const u8,
    /// Current position in buffer (u32 for explicit sizing).
    index: u32,

    const State = enum {
        start,
        atom,
        string,
        string_escape,
        number,
        number_dot,
        number_frac,
        number_neg,
        comment,
    };

    /// Maximum number of characters to scan in a single token.
    /// Prevents infinite loops on malformed input.
    const max_token_len: usize = 1024 * 1024; // 1MB max token

    pub fn init(source: [:0]const u8) Tokenizer {
        // Pre-condition: source is sentinel-terminated
        assert(source.len == 0 or source[source.len] == 0);
        // Pre-condition: source fits in u32 (4GB max)
        assert(source.len <= std.math.maxInt(u32));

        return .{
            .buffer = source,
            .index = 0,
        };
    }

    /// Tokenize from a non-sentinel buffer by copying to a sentinel-terminated buffer.
    /// Caller owns returned Tokenizer and must ensure buffer outlives it.
    pub fn initFromSlice(allocator: std.mem.Allocator, source: []const u8) !struct { tokenizer: Tokenizer, buffer: [:0]u8 } {
        const buffer = try allocator.allocSentinel(u8, source.len, 0);
        @memcpy(buffer, source);
        return .{
            .tokenizer = init(buffer),
            .buffer = buffer,
        };
    }

    pub fn next(self: *Tokenizer) Token {
        // Pre-condition: index is valid
        assert(self.index <= self.buffer.len);

        var result: Token = .{
            .tag = undefined,
            .loc = .{ .start = self.index, .end = undefined },
        };

        const buffer_len: u32 = @intCast(self.buffer.len);

        // Labeled switch state machine
        state: switch (State.start) {
            .start => switch (self.buffer[self.index]) {
                0 => {
                    // EOF - check if we're at the true end
                    if (self.index >= buffer_len) {
                        result.tag = .eof;
                        result.loc.end = self.index;
                        // Post-condition: EOF token at buffer end
                        assert(result.loc.end == buffer_len);
                        return result;
                    }
                    // Embedded null - treat as invalid
                    result.tag = .invalid;
                    self.index += 1;
                    result.loc.end = self.index;
                    return result;
                },
                ' ', '\t', '\n', '\r' => {
                    // Skip whitespace
                    self.index += 1;
                    result.loc.start = self.index;
                    continue :state .start;
                },
                '(' => {
                    result.tag = .left_paren;
                    self.index += 1;
                    result.loc.end = self.index;
                    return result;
                },
                ')' => {
                    result.tag = .right_paren;
                    self.index += 1;
                    result.loc.end = self.index;
                    return result;
                },
                '"' => {
                    result.tag = .string;
                    self.index += 1;
                    continue :state .string;
                },
                ';' => {
                    result.tag = .comment;
                    self.index += 1;
                    continue :state .comment;
                },
                '-' => {
                    // Could be negative number or atom starting with -
                    self.index += 1;
                    continue :state .number_neg;
                },
                '0'...'9' => {
                    result.tag = .number;
                    self.index += 1;
                    continue :state .number;
                },
                else => {
                    // Atom: identifiers, keywords, symbols ($, @, etc.)
                    if (isAtomChar(self.buffer[self.index])) {
                        result.tag = .atom;
                        self.index += 1;
                        continue :state .atom;
                    }
                    // Invalid character
                    result.tag = .invalid;
                    self.index += 1;
                    result.loc.end = self.index;
                    return result;
                },
            },

            .atom => {
                // Bounded loop for safety
                for (0..max_token_len) |_| {
                    const c = self.buffer[self.index];
                    if (isAtomChar(c)) {
                        self.index += 1;
                    } else {
                        result.loc.end = self.index;
                        // Post-condition: valid token location
                        assert(result.loc.end >= result.loc.start);
                        return result;
                    }
                } else {
                    // Token too long - treat as invalid
                    result.tag = .invalid;
                    result.loc.end = self.index;
                    return result;
                }
            },

            .string => {
                for (0..max_token_len) |_| {
                    switch (self.buffer[self.index]) {
                        0 => {
                            // Unterminated string
                            result.tag = .invalid;
                            result.loc.end = self.index;
                            return result;
                        },
                        '"' => {
                            self.index += 1;
                            result.loc.end = self.index;
                            return result;
                        },
                        '\\' => {
                            self.index += 1;
                            continue :state .string_escape;
                        },
                        else => {
                            self.index += 1;
                        },
                    }
                } else {
                    result.tag = .invalid;
                    result.loc.end = self.index;
                    return result;
                }
            },

            .string_escape => {
                switch (self.buffer[self.index]) {
                    0 => {
                        // Unterminated escape
                        result.tag = .invalid;
                        result.loc.end = self.index;
                        return result;
                    },
                    else => {
                        // Accept any escaped character
                        self.index += 1;
                        continue :state .string;
                    },
                }
            },

            .number_neg => {
                switch (self.buffer[self.index]) {
                    '0'...'9' => {
                        result.tag = .number;
                        self.index += 1;
                        continue :state .number;
                    },
                    else => {
                        // Just a '-' followed by non-digit - treat as atom
                        result.tag = .atom;
                        continue :state .atom;
                    },
                }
            },

            .number => {
                for (0..max_token_len) |_| {
                    switch (self.buffer[self.index]) {
                        '0'...'9' => {
                            self.index += 1;
                        },
                        '.' => {
                            self.index += 1;
                            continue :state .number_dot;
                        },
                        else => {
                            result.loc.end = self.index;
                            return result;
                        },
                    }
                } else {
                    result.tag = .invalid;
                    result.loc.end = self.index;
                    return result;
                }
            },

            .number_dot => {
                switch (self.buffer[self.index]) {
                    '0'...'9' => {
                        self.index += 1;
                        continue :state .number_frac;
                    },
                    else => {
                        // Number followed by dot but no digits (e.g., "123.")
                        // Include the dot in the number
                        result.loc.end = self.index;
                        return result;
                    },
                }
            },

            .number_frac => {
                for (0..max_token_len) |_| {
                    switch (self.buffer[self.index]) {
                        '0'...'9' => {
                            self.index += 1;
                        },
                        else => {
                            result.loc.end = self.index;
                            return result;
                        },
                    }
                } else {
                    result.tag = .invalid;
                    result.loc.end = self.index;
                    return result;
                }
            },

            .comment => {
                for (0..max_token_len) |_| {
                    switch (self.buffer[self.index]) {
                        0, '\n' => {
                            result.loc.end = self.index;
                            return result;
                        },
                        else => {
                            self.index += 1;
                        },
                    }
                } else {
                    result.tag = .invalid;
                    result.loc.end = self.index;
                    return result;
                }
            },
        }

        // Post-condition: all paths return
        unreachable;
    }

    /// Check if character can be part of an atom.
    fn isAtomChar(c: u8) bool {
        return switch (c) {
            // Whitespace and structural characters are not atom chars
            0, ' ', '\t', '\n', '\r', '(', ')', '"', ';' => false,
            // Everything else is valid in atoms (including $, @, :, -, _, etc.)
            else => true,
        };
    }

    /// Collect all tokens into a list (for testing).
    pub fn tokenize(self: *Tokenizer, allocator: std.mem.Allocator) ![]Token {
        var tokens: std.ArrayListUnmanaged(Token) = .{};
        errdefer tokens.deinit(allocator);

        // Bounded loop for safety
        const max_tokens: usize = 1024 * 1024;
        for (0..max_tokens) |_| {
            const token = self.next();
            // Skip comments for simplified output
            if (token.tag == .comment) continue;

            try tokens.append(allocator, token);
            if (token.tag == .eof) break;
        } else {
            return error.TooManyTokens;
        }

        return tokens.toOwnedSlice(allocator);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "empty input produces EOF" {
    const source: [:0]const u8 = "";
    var tokenizer = Tokenizer.init(source);

    const token = tokenizer.next();
    try testing.expectEqual(Token.Tag.eof, token.tag);
    try testing.expectEqual(@as(usize, 0), token.loc.start);
    try testing.expectEqual(@as(usize, 0), token.loc.end);
}

test "whitespace only produces EOF" {
    const source: [:0]const u8 = "   \t\n\r  ";
    var tokenizer = Tokenizer.init(source);

    const token = tokenizer.next();
    try testing.expectEqual(Token.Tag.eof, token.tag);
}

test "parentheses" {
    const source: [:0]const u8 = "()";
    var tokenizer = Tokenizer.init(source);

    const t1 = tokenizer.next();
    try testing.expectEqual(Token.Tag.left_paren, t1.tag);
    try testing.expectEqualStrings("(", t1.slice(source));

    const t2 = tokenizer.next();
    try testing.expectEqual(Token.Tag.right_paren, t2.tag);
    try testing.expectEqualStrings(")", t2.slice(source));

    const t3 = tokenizer.next();
    try testing.expectEqual(Token.Tag.eof, t3.tag);
}

test "simple atom" {
    const source: [:0]const u8 = "buffer";
    var tokenizer = Tokenizer.init(source);

    const token = tokenizer.next();
    try testing.expectEqual(Token.Tag.atom, token.tag);
    try testing.expectEqualStrings("buffer", token.slice(source));
}

test "atom with special chars ($, @, :)" {
    const source: [:0]const u8 = "$buf:0 @swapchain";
    var tokenizer = Tokenizer.init(source);

    const t1 = tokenizer.next();
    try testing.expectEqual(Token.Tag.atom, t1.tag);
    try testing.expectEqualStrings("$buf:0", t1.slice(source));

    const t2 = tokenizer.next();
    try testing.expectEqual(Token.Tag.atom, t2.tag);
    try testing.expectEqualStrings("@swapchain", t2.slice(source));
}

test "string literal" {
    const source: [:0]const u8 = "\"hello world\"";
    var tokenizer = Tokenizer.init(source);

    const token = tokenizer.next();
    try testing.expectEqual(Token.Tag.string, token.tag);
    try testing.expectEqualStrings("\"hello world\"", token.slice(source));
}

test "string with escape" {
    const source: [:0]const u8 = "\"hello\\nworld\"";
    var tokenizer = Tokenizer.init(source);

    const token = tokenizer.next();
    try testing.expectEqual(Token.Tag.string, token.tag);
    try testing.expectEqualStrings("\"hello\\nworld\"", token.slice(source));
}

test "string with escaped quote" {
    const source: [:0]const u8 = "\"say \\\"hi\\\"\"";
    var tokenizer = Tokenizer.init(source);

    const token = tokenizer.next();
    try testing.expectEqual(Token.Tag.string, token.tag);
}

test "unterminated string" {
    const source: [:0]const u8 = "\"hello";
    var tokenizer = Tokenizer.init(source);

    const token = tokenizer.next();
    try testing.expectEqual(Token.Tag.invalid, token.tag);
}

test "integer number" {
    const source: [:0]const u8 = "1024";
    var tokenizer = Tokenizer.init(source);

    const token = tokenizer.next();
    try testing.expectEqual(Token.Tag.number, token.tag);
    try testing.expectEqualStrings("1024", token.slice(source));
}

test "negative number" {
    const source: [:0]const u8 = "-42";
    var tokenizer = Tokenizer.init(source);

    const token = tokenizer.next();
    try testing.expectEqual(Token.Tag.number, token.tag);
    try testing.expectEqualStrings("-42", token.slice(source));
}

test "float number" {
    const source: [:0]const u8 = "3.14159";
    var tokenizer = Tokenizer.init(source);

    const token = tokenizer.next();
    try testing.expectEqual(Token.Tag.number, token.tag);
    try testing.expectEqualStrings("3.14159", token.slice(source));
}

test "negative float" {
    const source: [:0]const u8 = "-0.5";
    var tokenizer = Tokenizer.init(source);

    const token = tokenizer.next();
    try testing.expectEqual(Token.Tag.number, token.tag);
    try testing.expectEqualStrings("-0.5", token.slice(source));
}

test "comment" {
    const source: [:0]const u8 = "; this is a comment\natom";
    var tokenizer = Tokenizer.init(source);

    const t1 = tokenizer.next();
    try testing.expectEqual(Token.Tag.comment, t1.tag);
    try testing.expectEqualStrings("; this is a comment", t1.slice(source));

    const t2 = tokenizer.next();
    try testing.expectEqual(Token.Tag.atom, t2.tag);
    try testing.expectEqualStrings("atom", t2.slice(source));
}

test "simple s-expression" {
    const source: [:0]const u8 = "(buffer $buf:0 (size 1024))";
    var tokenizer = Tokenizer.init(source);

    const tokens = try tokenizer.tokenize(testing.allocator);
    defer testing.allocator.free(tokens);

    // Expected: ( buffer $buf:0 ( size 1024 ) ) EOF
    try testing.expectEqual(@as(usize, 9), tokens.len);

    try testing.expectEqual(Token.Tag.left_paren, tokens[0].tag);
    try testing.expectEqual(Token.Tag.atom, tokens[1].tag);
    try testing.expectEqualStrings("buffer", tokens[1].slice(source));
    try testing.expectEqual(Token.Tag.atom, tokens[2].tag);
    try testing.expectEqualStrings("$buf:0", tokens[2].slice(source));
    try testing.expectEqual(Token.Tag.left_paren, tokens[3].tag);
    try testing.expectEqual(Token.Tag.atom, tokens[4].tag);
    try testing.expectEqualStrings("size", tokens[4].slice(source));
    try testing.expectEqual(Token.Tag.number, tokens[5].tag);
    try testing.expectEqualStrings("1024", tokens[5].slice(source));
    try testing.expectEqual(Token.Tag.right_paren, tokens[6].tag);
    try testing.expectEqual(Token.Tag.right_paren, tokens[7].tag);
    try testing.expectEqual(Token.Tag.eof, tokens[8].tag);
}

test "multiline s-expression with comments" {
    const source: [:0]const u8 =
        \\(module "test"
        \\  ; Comment line
        \\  (shader $shd:0))
    ;
    var tokenizer = Tokenizer.init(source);

    const tokens = try tokenizer.tokenize(testing.allocator);
    defer testing.allocator.free(tokens);

    // Comments are skipped by tokenize()
    // Expected: ( module "test" ( shader $shd:0 ) ) EOF
    try testing.expectEqual(@as(usize, 9), tokens.len);
}

test "token location invariants" {
    const source: [:0]const u8 = "(atom 123 \"str\")";
    var tokenizer = Tokenizer.init(source);

    // Bounded loop for safety (max tokens = source length + 1 for EOF)
    const max_tokens: usize = source.len + 1;
    for (0..max_tokens) |_| {
        const token = tokenizer.next();
        // Invariant: end >= start
        try testing.expect(token.loc.end >= token.loc.start);
        // Invariant: end <= buffer length
        try testing.expect(token.loc.end <= source.len);

        if (token.tag == .eof) break;
    } else {
        // Safety: detect if tokenizer didn't terminate
        unreachable;
    }
}

test "PBSF simpleTriangle example" {
    const source: [:0]const u8 =
        \\(module "simpleTriangle"
        \\  (data $d:0 "shader code here")
        \\  (shader $shd:0 (code $d:0))
        \\  (render-pipeline $pipe:0
        \\    (layout auto)
        \\    (vertex $shd:0 (entry "vertexMain")))
        \\  (frame $frm:0 "simpleTriangle"
        \\    (exec-pass $pass:0)
        \\    (submit)))
    ;
    var tokenizer = Tokenizer.init(source);

    const tokens = try tokenizer.tokenize(testing.allocator);
    defer testing.allocator.free(tokens);

    // Verify we got tokens
    try testing.expect(tokens.len > 10);

    // Verify first token is left paren
    try testing.expectEqual(Token.Tag.left_paren, tokens[0].tag);

    // Verify "module" atom
    try testing.expectEqual(Token.Tag.atom, tokens[1].tag);
    try testing.expectEqualStrings("module", tokens[1].slice(source));

    // Verify module name string
    try testing.expectEqual(Token.Tag.string, tokens[2].tag);
    try testing.expectEqualStrings("\"simpleTriangle\"", tokens[2].slice(source));
}

// ============================================================================
// Fuzz Tests
// ============================================================================

// Fuzz test for tokenizer properties.
// Verifies invariants hold for arbitrary input.
test "fuzz tokenizer properties" {
    try std.testing.fuzz(.{}, fuzzTokenizerProperties, .{});
}

fn fuzzTokenizerProperties(_: @TypeOf(.{}), input: []const u8) !void {
    // Create sentinel-terminated buffer
    var buf: [4096]u8 = undefined;
    if (input.len >= buf.len) return; // Skip inputs that are too large

    @memcpy(buf[0..input.len], input);
    buf[input.len] = 0;
    const source: [:0]const u8 = buf[0..input.len :0];

    var tokenizer = Tokenizer.init(source);

    // Property 1: Tokenizer always terminates with EOF
    var token_count: usize = 0;
    const max_tokens: usize = 100_000;
    var last_tag: Token.Tag = .invalid;

    for (0..max_tokens) |_| {
        const token = tokenizer.next();

        // Property 2: Token end >= start (invariant from module docs)
        try testing.expect(token.loc.end >= token.loc.start);

        // Property 3: Token end <= buffer length
        try testing.expect(token.loc.end <= source.len);

        // Property 4: Token start <= buffer length
        try testing.expect(token.loc.start <= source.len);

        // Property 5: For non-EOF tokens, end > start OR it's a structural token
        if (token.tag != .eof) {
            // Empty tokens only allowed for certain cases
            if (token.loc.end == token.loc.start) {
                // This shouldn't happen for valid tokens
                try testing.expect(token.tag == .invalid);
            }
        }

        last_tag = token.tag;
        token_count += 1;

        if (token.tag == .eof) break;
    } else {
        // Property 6: Must terminate within max_tokens
        unreachable;
    }

    // Property 7: Last token is always EOF
    try testing.expectEqual(Token.Tag.eof, last_tag);

    // Property 8: At least one token (EOF)
    try testing.expect(token_count >= 1);
}

// Fuzz test for token slice validity.
test "fuzz token slice validity" {
    try std.testing.fuzz(.{}, fuzzTokenSliceValidity, .{});
}

fn fuzzTokenSliceValidity(_: @TypeOf(.{}), input: []const u8) !void {
    var buf: [4096]u8 = undefined;
    if (input.len >= buf.len) return;

    @memcpy(buf[0..input.len], input);
    buf[input.len] = 0;
    const source: [:0]const u8 = buf[0..input.len :0];

    var tokenizer = Tokenizer.init(source);
    const max_tokens: usize = 100_000;

    for (0..max_tokens) |_| {
        const token = tokenizer.next();

        // Property: slice() always returns valid slice within source
        const slice = token.slice(source);
        _ = slice; // Just verify it doesn't panic

        if (token.tag == .eof) break;
    }
}

// Fuzz test for parenthesis balance tracking.
test "fuzz parenthesis counting" {
    try std.testing.fuzz(.{}, fuzzParenthesisCounting, .{});
}

fn fuzzParenthesisCounting(_: @TypeOf(.{}), input: []const u8) !void {
    var buf: [4096]u8 = undefined;
    if (input.len >= buf.len) return;

    @memcpy(buf[0..input.len], input);
    buf[input.len] = 0;
    const source: [:0]const u8 = buf[0..input.len :0];

    var tokenizer = Tokenizer.init(source);
    const max_tokens: usize = 100_000;

    var left_count: usize = 0;
    var right_count: usize = 0;

    for (0..max_tokens) |_| {
        const token = tokenizer.next();

        switch (token.tag) {
            .left_paren => left_count += 1,
            .right_paren => right_count += 1,
            else => {},
        }

        if (token.tag == .eof) break;
    }

    // Property: Count of '(' in source equals left_paren tokens
    var source_left: usize = 0;
    var source_right: usize = 0;
    for (source) |c| {
        if (c == '(') source_left += 1;
        if (c == ')') source_right += 1;
    }

    // Note: Parentheses inside strings/comments won't match exactly,
    // but this is a sanity check that we're not inventing tokens
    try testing.expect(left_count <= source_left + 1);
    try testing.expect(right_count <= source_right + 1);
}
