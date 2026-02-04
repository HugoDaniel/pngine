//! PBSF S-Expression Parser
//!
//! Parses tokenized PBSF input into an AST. Uses two-phase parsing:
//! first tokenize all input, then parse tokens into tree structure.
//!
//! Invariants:
//! - Node index 0 is always the root
//! - All node indices are valid within the nodes array
//! - Extra data indices point to valid ranges

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Token = @import("tokenizer.zig").Token;

/// Index into the nodes array.
pub const NodeIndex = enum(u32) {
    root = 0,
    _,

    pub fn toOptional(i: NodeIndex) OptionalNodeIndex {
        return @enumFromInt(@intFromEnum(i));
    }
};

/// Optional node index using maxInt as sentinel for "none".
pub const OptionalNodeIndex = enum(u32) {
    root = 0,
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(oi: OptionalNodeIndex) ?NodeIndex {
        return if (oi == .none) null else @enumFromInt(@intFromEnum(oi));
    }
};

/// Index into the extra_data array.
pub const ExtraIndex = enum(u32) { _ };

/// Index into token array.
pub const TokenIndex = u32;

/// AST Node - 12 bytes total.
/// Stores tag, main token, and either inline data or reference to extra_data.
pub const Node = struct {
    tag: Tag,
    main_token: TokenIndex,
    data: Data,

    pub const Tag = enum(u8) {
        /// Root node containing all top-level expressions.
        /// data.extra_range = range of child nodes in extra_data
        root,

        /// List: (elements...)
        /// data.extra_range = range of child node indices in extra_data
        list,

        /// Atom: identifier, keyword, or symbol ($buf:0, @swapchain, etc.)
        /// data = unused, token contains the atom text
        atom,

        /// Number literal (integer or float)
        /// data = unused, token contains the number text
        number,

        /// String literal "..."
        /// data = unused, token contains the string with quotes
        string,
    };

    /// 8-byte union for node data.
    pub const Data = union {
        /// Single node reference.
        node: NodeIndex,

        /// Range of indices in extra_data array.
        extra_range: SubRange,

        /// No data needed.
        none: void,
    };

    pub const SubRange = struct {
        start: ExtraIndex,
        end: ExtraIndex,

        pub fn len(self: SubRange) u32 {
            return @intFromEnum(self.end) - @intFromEnum(self.start);
        }

        pub fn slice(self: SubRange, extra_data: []const u32) []const u32 {
            return extra_data[@intFromEnum(self.start)..@intFromEnum(self.end)];
        }
    };

    // Note: Node size varies by Zig version due to union layout changes.
    // In Zig 0.14.x it was 12 bytes, in 0.16.x it may differ.
};

/// AST structure holding parsed S-expressions.
pub const Ast = struct {
    source: [:0]const u8,
    tokens: TokenList.Slice,
    nodes: NodeList.Slice,
    extra_data: []const u32,
    errors: []const Error,

    pub const TokenList = std.MultiArrayList(struct {
        tag: Token.Tag,
        start: u32, // Byte offset into source
    });

    pub const NodeList = std.MultiArrayList(Node);

    pub const Error = struct {
        token: TokenIndex,
        kind: Kind,

        pub const Kind = enum {
            expected_expression,
            expected_right_paren,
            unexpected_token,
        };
    };

    pub fn deinit(self: *Ast, allocator: Allocator) void {
        allocator.free(self.extra_data);
        allocator.free(self.errors);
        self.tokens.deinit(allocator);
        self.nodes.deinit(allocator);
    }

    /// Get source slice for a token.
    pub fn tokenSlice(self: Ast, token_index: TokenIndex) []const u8 {
        const tag = self.tokens.items(.tag)[token_index];

        // Fixed tokens have known lexeme
        if (tag.lexeme()) |lex| {
            return lex;
        }

        // Variable tokens need re-tokenization from start position
        const start = self.tokens.items(.start)[token_index];
        var tokenizer: Tokenizer = .{
            .buffer = self.source,
            .index = start,
        };
        const token = tokenizer.next();
        return self.source[token.loc.start..token.loc.end];
    }

    /// Get children of a list or root node.
    pub fn children(self: Ast, node_index: NodeIndex) []const NodeIndex {
        const node = self.nodes.get(@intFromEnum(node_index));
        return switch (node.tag) {
            .root, .list => blk: {
                const range = node.data.extra_range;
                const raw = self.extra_data[@intFromEnum(range.start)..@intFromEnum(range.end)];
                break :blk @ptrCast(raw);
            },
            else => &[_]NodeIndex{},
        };
    }

    /// Get the tag of a node.
    pub fn nodeTag(self: Ast, node_index: NodeIndex) Node.Tag {
        return self.nodes.items(.tag)[@intFromEnum(node_index)];
    }

    /// Get the main token of a node.
    pub fn nodeMainToken(self: Ast, node_index: NodeIndex) TokenIndex {
        return self.nodes.items(.main_token)[@intFromEnum(node_index)];
    }
};

/// Parser state for converting tokens to AST.
const Parser = struct {
    gpa: Allocator,
    source: [:0]const u8,
    tokens: Ast.TokenList.Slice,
    tok_i: TokenIndex,
    nodes: *Ast.NodeList,
    extra_data: *std.ArrayListUnmanaged(u32),
    scratch: *std.ArrayListUnmanaged(NodeIndex),
    errors: *std.ArrayListUnmanaged(Ast.Error),

    fn tokenTag(p: *const Parser, i: TokenIndex) Token.Tag {
        return p.tokens.items(.tag)[i];
    }

    fn eatToken(p: *Parser, tag: Token.Tag) ?TokenIndex {
        if (p.tokenTag(p.tok_i) == tag) {
            const result = p.tok_i;
            p.tok_i += 1;
            return result;
        }
        return null;
    }

    fn expectToken(p: *Parser, tag: Token.Tag) !TokenIndex {
        if (p.eatToken(tag)) |tok| return tok;
        try p.errors.append(p.gpa, .{
            .token = p.tok_i,
            .kind = switch (tag) {
                .right_paren => .expected_right_paren,
                else => .unexpected_token,
            },
        });
        return error.ParseError;
    }

    fn addNode(p: *Parser, node: Node) !NodeIndex {
        const index: NodeIndex = @enumFromInt(@as(u32, @intCast(p.nodes.len)));
        try p.nodes.append(p.gpa, node);
        return index;
    }

    fn nodesLen(p: *const Parser) usize {
        return p.nodes.len;
    }

    fn addExtra(p: *Parser, items: []const NodeIndex) !Node.SubRange {
        const start: ExtraIndex = @enumFromInt(@as(u32, @intCast(p.extra_data.items.len)));
        try p.extra_data.appendSlice(p.gpa, @ptrCast(items));
        const end: ExtraIndex = @enumFromInt(@as(u32, @intCast(p.extra_data.items.len)));
        return .{ .start = start, .end = end };
    }

    /// Parse root: all top-level expressions until EOF.
    fn parse_root(p: *Parser) !void {
        // Root node is always index 0
        const root_node: Node = .{
            .tag = .root,
            .main_token = 0,
            .data = .{ .extra_range = undefined },
        };
        try p.nodes.append(p.gpa, root_node);

        const scratch_top = p.scratch.items.len;
        defer p.scratch.shrinkRetainingCapacity(scratch_top);

        // Parse all top-level expressions
        const max_exprs: usize = 1024 * 1024;
        for (0..max_exprs) |_| {
            // Check for EOF before and after parsing
            if (p.tokenTag(p.tok_i) == .eof) break;

            if (try p.parseExpr()) |expr| {
                try p.scratch.append(p.gpa, expr);
            } else {
                // parseExpr returned null - could be EOF (from comment skip) or invalid
                // Check again before skipping
                if (p.tokenTag(p.tok_i) == .eof) break;
                // Skip invalid token
                p.tok_i += 1;
            }
        } else {
            // Hit max expressions - shouldn't happen
            unreachable;
        }

        // Store children in extra_data
        const children = p.scratch.items[scratch_top..];
        const range = try p.addExtra(children);
        p.nodes.items(.data)[0] = .{ .extra_range = range };
    }

    /// Parse a single expression: atom, number, string, or list.
    fn parseExpr(p: *Parser) error{OutOfMemory}!?NodeIndex {
        switch (p.tokenTag(p.tok_i)) {
            .left_paren => return try p.parseList(),
            .atom => return try p.parseAtom(),
            .number => return try p.parseNumber(),
            .string => return try p.parseString(),
            .eof, .right_paren => return null,
            .comment => {
                // Skip comment
                p.tok_i += 1;
                return try p.parseExpr();
            },
            .invalid => {
                try p.errors.append(p.gpa, .{
                    .token = p.tok_i,
                    .kind = .unexpected_token,
                });
                return null;
            },
        }
    }

    /// Parse list: (elements...)
    fn parseList(p: *Parser) !NodeIndex {
        const lparen = p.eatToken(.left_paren) orelse unreachable;

        const scratch_top = p.scratch.items.len;
        defer p.scratch.shrinkRetainingCapacity(scratch_top);

        // Parse list elements
        const max_elements: usize = 1024 * 1024;
        for (0..max_elements) |_| {
            if (p.tokenTag(p.tok_i) == .right_paren) break;
            if (p.tokenTag(p.tok_i) == .eof) {
                try p.errors.append(p.gpa, .{
                    .token = p.tok_i,
                    .kind = .expected_right_paren,
                });
                break;
            }

            if (try p.parseExpr()) |elem| {
                try p.scratch.append(p.gpa, elem);
            } else {
                // Couldn't parse element, skip token
                p.tok_i += 1;
            }
        } else {
            unreachable;
        }

        _ = p.eatToken(.right_paren);

        const children = p.scratch.items[scratch_top..];
        const range = try p.addExtra(children);

        return try p.addNode(.{
            .tag = .list,
            .main_token = lparen,
            .data = .{ .extra_range = range },
        });
    }

    fn parseAtom(p: *Parser) !NodeIndex {
        // Pre-condition: current token is an atom
        assert(p.tokenTag(p.tok_i) == .atom);

        const token = p.tok_i;
        p.tok_i += 1;

        const node = try p.addNode(.{
            .tag = .atom,
            .main_token = token,
            .data = .{ .none = {} },
        });

        // Post-condition: node was added
        assert(@intFromEnum(node) < p.nodes.len);
        return node;
    }

    fn parseNumber(p: *Parser) !NodeIndex {
        // Pre-condition: current token is a number
        assert(p.tokenTag(p.tok_i) == .number);

        const token = p.tok_i;
        p.tok_i += 1;

        const node = try p.addNode(.{
            .tag = .number,
            .main_token = token,
            .data = .{ .none = {} },
        });

        // Post-condition: node was added
        assert(@intFromEnum(node) < p.nodes.len);
        return node;
    }

    fn parseString(p: *Parser) !NodeIndex {
        // Pre-condition: current token is a string
        assert(p.tokenTag(p.tok_i) == .string);

        const token = p.tok_i;
        p.tok_i += 1;

        const node = try p.addNode(.{
            .tag = .string,
            .main_token = token,
            .data = .{ .none = {} },
        });

        // Post-condition: node was added
        assert(@intFromEnum(node) < p.nodes.len);
        return node;
    }
};

/// Parse PBSF source into AST.
pub fn parse(gpa: Allocator, source: [:0]const u8) !Ast {
    var tokens = Ast.TokenList{};
    errdefer tokens.deinit(gpa);

    // Heuristic: 8:1 ratio of source bytes to tokens
    const estimated_token_count = @max(source.len / 8, 16);
    try tokens.ensureTotalCapacity(gpa, estimated_token_count);

    // Phase 1: Tokenize entire input
    var tokenizer = Tokenizer.init(source);
    const max_tokens: usize = 1024 * 1024;
    for (0..max_tokens) |_| {
        const token = tokenizer.next();
        try tokens.append(gpa, .{
            .tag = token.tag,
            .start = @intCast(token.loc.start),
        });
        if (token.tag == .eof) break;
    } else {
        return error.TooManyTokens;
    }

    // Phase 2: Parse tokens into AST
    var extra_data: std.ArrayListUnmanaged(u32) = .{};
    errdefer extra_data.deinit(gpa);

    var scratch: std.ArrayListUnmanaged(NodeIndex) = .{};
    defer scratch.deinit(gpa);

    var errors: std.ArrayListUnmanaged(Ast.Error) = .{};
    errdefer errors.deinit(gpa);

    var nodes: Ast.NodeList = .{};
    errdefer nodes.deinit(gpa);

    var parser: Parser = .{
        .gpa = gpa,
        .source = source,
        .tokens = tokens.slice(),
        .tok_i = 0,
        .nodes = &nodes,
        .extra_data = &extra_data,
        .scratch = &scratch,
        .errors = &errors,
    };

    // Heuristic: 2:1 ratio of tokens to AST nodes
    const estimated_node_count = @max((tokens.len + 2) / 2, 8);
    try nodes.ensureTotalCapacity(gpa, estimated_node_count);

    try parser.parse_root();

    // Convert to owned slices in order that handles partial failure.
    // Each toOwnedSlice clears the source, so we must not call errdefer after.
    const owned_extra = try extra_data.toOwnedSlice(gpa);
    errdefer gpa.free(owned_extra);

    const owned_errors = try errors.toOwnedSlice(gpa);
    // No errdefer needed - if we got here, we'll succeed

    return Ast{
        .source = source,
        .tokens = tokens.toOwnedSlice(),
        .nodes = nodes.toOwnedSlice(),
        .extra_data = owned_extra,
        .errors = owned_errors,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "parse empty input" {
    const source: [:0]const u8 = "";
    var ast = try parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    // Root node with no children
    try testing.expectEqual(Node.Tag.root, ast.nodeTag(.root));
    try testing.expectEqual(@as(usize, 0), ast.children(.root).len);
}

test "parse single atom" {
    const source: [:0]const u8 = "buffer";
    var ast = try parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    // Root with one child
    const root_children = ast.children(.root);
    try testing.expectEqual(@as(usize, 1), root_children.len);

    // Child is an atom
    const child = root_children[0];
    try testing.expectEqual(Node.Tag.atom, ast.nodeTag(child));
    try testing.expectEqualStrings("buffer", ast.tokenSlice(ast.nodeMainToken(child)));
}

test "parse single number" {
    const source: [:0]const u8 = "42";
    var ast = try parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    const root_children = ast.children(.root);
    try testing.expectEqual(@as(usize, 1), root_children.len);

    const child = root_children[0];
    try testing.expectEqual(Node.Tag.number, ast.nodeTag(child));
    try testing.expectEqualStrings("42", ast.tokenSlice(ast.nodeMainToken(child)));
}

test "parse single string" {
    const source: [:0]const u8 = "\"hello\"";
    var ast = try parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    const root_children = ast.children(.root);
    try testing.expectEqual(@as(usize, 1), root_children.len);

    const child = root_children[0];
    try testing.expectEqual(Node.Tag.string, ast.nodeTag(child));
    try testing.expectEqualStrings("\"hello\"", ast.tokenSlice(ast.nodeMainToken(child)));
}

test "parse empty list" {
    const source: [:0]const u8 = "()";
    var ast = try parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    const root_children = ast.children(.root);
    try testing.expectEqual(@as(usize, 1), root_children.len);

    const list = root_children[0];
    try testing.expectEqual(Node.Tag.list, ast.nodeTag(list));
    try testing.expectEqual(@as(usize, 0), ast.children(list).len);
}

test "parse simple list" {
    const source: [:0]const u8 = "(buffer 1024)";
    var ast = try parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    const root_children = ast.children(.root);
    try testing.expectEqual(@as(usize, 1), root_children.len);

    const list = root_children[0];
    try testing.expectEqual(Node.Tag.list, ast.nodeTag(list));

    const list_children = ast.children(list);
    try testing.expectEqual(@as(usize, 2), list_children.len);

    try testing.expectEqual(Node.Tag.atom, ast.nodeTag(list_children[0]));
    try testing.expectEqualStrings("buffer", ast.tokenSlice(ast.nodeMainToken(list_children[0])));

    try testing.expectEqual(Node.Tag.number, ast.nodeTag(list_children[1]));
    try testing.expectEqualStrings("1024", ast.tokenSlice(ast.nodeMainToken(list_children[1])));
}

test "parse nested lists" {
    const source: [:0]const u8 = "(buffer $buf:0 (size 1024))";
    var ast = try parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    const root_children = ast.children(.root);
    try testing.expectEqual(@as(usize, 1), root_children.len);

    const outer = root_children[0];
    try testing.expectEqual(Node.Tag.list, ast.nodeTag(outer));

    const outer_children = ast.children(outer);
    try testing.expectEqual(@as(usize, 3), outer_children.len);

    // First: atom "buffer"
    try testing.expectEqual(Node.Tag.atom, ast.nodeTag(outer_children[0]));
    try testing.expectEqualStrings("buffer", ast.tokenSlice(ast.nodeMainToken(outer_children[0])));

    // Second: atom "$buf:0"
    try testing.expectEqual(Node.Tag.atom, ast.nodeTag(outer_children[1]));
    try testing.expectEqualStrings("$buf:0", ast.tokenSlice(ast.nodeMainToken(outer_children[1])));

    // Third: nested list (size 1024)
    const inner = outer_children[2];
    try testing.expectEqual(Node.Tag.list, ast.nodeTag(inner));

    const inner_children = ast.children(inner);
    try testing.expectEqual(@as(usize, 2), inner_children.len);
    try testing.expectEqualStrings("size", ast.tokenSlice(ast.nodeMainToken(inner_children[0])));
    try testing.expectEqualStrings("1024", ast.tokenSlice(ast.nodeMainToken(inner_children[1])));
}

test "parse multiple top-level expressions" {
    const source: [:0]const u8 = "(a) (b) (c)";
    var ast = try parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    const root_children = ast.children(.root);
    try testing.expectEqual(@as(usize, 3), root_children.len);

    for (root_children) |child| {
        try testing.expectEqual(Node.Tag.list, ast.nodeTag(child));
    }
}

test "parse with comments" {
    const source: [:0]const u8 =
        \\; This is a comment
        \\(module "test")
        \\; Another comment
    ;
    var ast = try parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    // Comments should be skipped
    const root_children = ast.children(.root);
    try testing.expectEqual(@as(usize, 1), root_children.len);

    const list = root_children[0];
    try testing.expectEqual(Node.Tag.list, ast.nodeTag(list));
}

test "parse simpleTriangle PBSF" {
    const source: [:0]const u8 =
        \\(module "simpleTriangle"
        \\  (data $d:0 "shader code")
        \\  (shader $shd:0 (code $d:0))
        \\  (render-pipeline $pipe:0
        \\    (layout auto)
        \\    (vertex $shd:0 (entry "vertexMain")))
        \\  (frame $frm:0 "simpleTriangle"
        \\    (exec-pass $pass:0)
        \\    (submit)))
    ;
    var ast = try parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    // Root has one child (module)
    const root_children = ast.children(.root);
    try testing.expectEqual(@as(usize, 1), root_children.len);

    const module = root_children[0];
    try testing.expectEqual(Node.Tag.list, ast.nodeTag(module));

    const module_children = ast.children(module);
    // (module "simpleTriangle" (data...) (shader...) (render-pipeline...) (frame...))
    try testing.expectEqual(@as(usize, 6), module_children.len);

    // First child is "module" atom
    try testing.expectEqual(Node.Tag.atom, ast.nodeTag(module_children[0]));
    try testing.expectEqualStrings("module", ast.tokenSlice(ast.nodeMainToken(module_children[0])));

    // Second child is string "simpleTriangle"
    try testing.expectEqual(Node.Tag.string, ast.nodeTag(module_children[1]));

    // Third child is (data ...) list
    try testing.expectEqual(Node.Tag.list, ast.nodeTag(module_children[2]));

    // Fourth child is (shader ...) list
    try testing.expectEqual(Node.Tag.list, ast.nodeTag(module_children[3]));

    // Fifth child is (render-pipeline ...) list
    try testing.expectEqual(Node.Tag.list, ast.nodeTag(module_children[4]));

    // Sixth child is (frame ...) list
    try testing.expectEqual(Node.Tag.list, ast.nodeTag(module_children[5]));
}

test "parse error: unclosed list" {
    const source: [:0]const u8 = "(buffer";
    var ast = try parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    // Should have errors
    try testing.expect(ast.errors.len > 0);
    try testing.expectEqual(Ast.Error.Kind.expected_right_paren, ast.errors[0].kind);
}

test "parser handles OOM gracefully" {
    // Test that parser properly returns error and doesn't leak
    // when allocation fails at any point during parsing.
    const source: [:0]const u8 =
        \\(module "test"
        \\  (data $d:0 "shader")
        \\  (shader $shd:0 (code $d:0))
        \\  (frame $frm:0 "main"
        \\    (exec-pass $pass:0)))
    ;

    // Test OOM at each allocation point
    var fail_index: usize = 0;
    const max_iterations: usize = 1000; // Safety bound

    for (0..max_iterations) |_| {
        var failing_alloc = std.testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });

        const result = parse(failing_alloc.allocator(), source);

        if (result) |*ast| {
            // Success - clean up and we're done
            var mutable_ast = ast.*;
            mutable_ast.deinit(failing_alloc.allocator());
            break;
        } else |_| {
            // Error occurred - this is expected during OOM testing
            // The errdefer in parse() should have cleaned up
        }

        fail_index += 1;
    } else {
        // Should have completed within max_iterations
        unreachable;
    }
}

test "parser OOM during nested list parsing" {
    // Deeply nested structure to stress allocation paths
    const source: [:0]const u8 = "(a (b (c (d (e (f))))))";

    var fail_index: usize = 0;
    const max_iterations: usize = 500;

    for (0..max_iterations) |_| {
        var failing_alloc = std.testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });

        const result = parse(failing_alloc.allocator(), source);

        if (result) |*ast| {
            var mutable_ast = ast.*;
            mutable_ast.deinit(failing_alloc.allocator());
            break;
        } else |_| {
            // Error expected during OOM testing
        }

        fail_index += 1;
    } else {
        unreachable;
    }
}
