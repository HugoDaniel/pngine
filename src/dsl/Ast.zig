//! AST definitions for PNGine DSL
//!
//! Uses a compact node representation following Zig standard library patterns.
//!
//! ## Node Layout
//!
//! - `tag`: 1 byte (enum(u8)) - node type
//! - `main_token`: 4 bytes (u32) - primary token index
//! - `data`: 8 bytes (union) - node-specific data
//!
//! With alignment: 16 bytes (3 bytes padding after tag).
//! Alternative: 12 bytes with packed struct.
//!
//! ## Data Storage
//!
//! - **Inline data**: Simple values stored in `data` union
//! - **Extra data**: Variable-length lists in separate `extra_data` array
//! - **Token indices**: Nodes reference tokens by index, not strings
//!
//! ## Typed Indices
//!
//! - `Node.Index`: Typed u32 enum for node references
//! - `Node.OptionalIndex`: Uses maxInt sentinel for null
//! - `Node.SubRange`: Range in extra_data array
//!
//! ## Grammar Reference
//!
//! ```ebnf
//! file = macro*
//! macro = "#" macro_name identifier "{" property* "}"
//! property = identifier "=" value
//! value = string | number | identifier | array | object | expr
//! array = "[" value* "]"
//! object = "{" property* "}"
//! expr = term (('+' | '-') term)*
//! term = factor (('*' | '/') factor)*
//! factor = number | '(' expr ')' | '-' factor
//! ```
//!
//! ## Invariants
//!
//! - Root node is always at index 0
//! - `data.extra_range`: end >= start
//! - Token indices are valid within tokens array
//! - Extra data indices are valid within extra_data array

const std = @import("std");
const Token = @import("Token.zig").Token;

pub const Ast = struct {
    source: [:0]const u8,
    tokens: TokenList.Slice,
    nodes: NodeList.Slice,
    extra_data: []const u32,
    errors: []const Diagnostic,

    pub const TokenList = std.MultiArrayList(struct {
        tag: Token.Tag,
        start: u32,
    });

    pub const NodeList = std.MultiArrayList(Node);

    pub fn deinit(self: *Ast, gpa: std.mem.Allocator) void {
        gpa.free(self.extra_data);
        gpa.free(self.errors);
        self.tokens.deinit(gpa);
        self.nodes.deinit(gpa);
        self.* = undefined;
    }

    /// Returns true if the parser detected syntax errors.
    pub fn hasParseErrors(self: Ast) bool {
        return self.errors.len > 0;
    }

    /// Get the source slice for a token.
    pub fn tokenSlice(self: Ast, token_index: u32) []const u8 {
        const starts = self.tokens.items(.start);
        const start = starts[token_index];
        const end: u32 = if (token_index + 1 < starts.len)
            starts[token_index + 1]
        else
            @intCast(self.source.len);
        return self.source[start..end];
    }

    /// Get extra data range as a slice.
    pub fn extraData(self: Ast, range: Node.SubRange) []const u32 {
        return self.extra_data[range.start..range.end];
    }

    /// Render all parse errors to a writer with source context.
    pub fn renderErrors(self: Ast, writer: anytype) !void {
        for (self.errors) |diag| {
            try self.renderDiagnostic(diag, writer);
        }
    }

    /// Render a single diagnostic with source location and context.
    fn renderDiagnostic(self: Ast, diag: Diagnostic, writer: anytype) !void {
        const token_start = self.tokens.items(.start)[diag.token];
        const info = getLineInfo(self.source, token_start);
        const line_text = self.source[info.line_start..info.line_end];
        const found_tag = self.tokens.items(.tag)[diag.token];

        // error: message
        try writer.print("error: {s}\n", .{diag.tag.message()});

        // --> location
        try writer.print(" --> line {d}, col {d}\n", .{ info.line_num, info.col_num });

        // source context
        try writer.writeAll("  |\n");
        try writer.print("{d: >3} | {s}\n", .{ info.line_num, line_text });

        // pointer with found-token info
        try writer.writeAll("    | ");
        for (0..info.col_num - 1) |_| try writer.writeByte(' ');
        if (found_tag == .eof) {
            try writer.writeAll("^ unexpected end of input\n");
        } else if (found_tag.lexeme()) |lex| {
            try writer.print("^ found '{s}'\n", .{lex});
        } else {
            try writer.writeAll("^\n");
        }

        // suggestion
        if (diag.tag.suggestion()) |sugg| {
            try writer.writeAll("  |\n");
            try writer.print("  = help: {s}\n", .{sugg});
        }

        try writer.writeByte('\n');
    }
};

/// Parse diagnostic with error tag and token location.
pub const Diagnostic = struct {
    tag: Tag,
    token: u32,

    pub const Tag = enum(u8) {
        expected_name,
        expected_opening_brace,
        expected_closing_brace,
        expected_equals,
        expected_value,
        expected_closing_bracket,
        expected_closing_paren,
        expected_operand,
        too_many_macros,
        too_many_properties,
        expression_too_deep,
        expression_too_complex,
        iteration_limit,

        /// Human-readable error message for this diagnostic kind.
        pub fn message(self: Tag) []const u8 {
            return switch (self) {
                .expected_name => "expected resource name after macro keyword",
                .expected_opening_brace => "expected '{' to open macro body",
                .expected_closing_brace => "unclosed block, expected '}'",
                .expected_equals => "expected '=' between property name and value",
                .expected_value => "expected a value",
                .expected_closing_bracket => "unclosed array, expected ']'",
                .expected_closing_paren => "unclosed parenthesis, expected ')'",
                .expected_operand => "expected number or expression after operator",
                .too_many_macros => "exceeded maximum of 4096 top-level macros",
                .too_many_properties => "exceeded maximum of 1024 properties in a single block",
                .expression_too_deep => "expression nesting exceeds maximum depth of 64",
                .expression_too_complex => "expression has too many terms",
                .iteration_limit => "input too complex: parser iteration limit exceeded",
            };
        }

        /// Fix suggestion for this diagnostic kind, or null if none.
        pub fn suggestion(self: Tag) ?[]const u8 {
            return switch (self) {
                .expected_name => "macros require a name: #buffer myBuf { size=100 }",
                .expected_opening_brace => "wrap properties in braces: #buffer myBuf { size=100 }",
                .expected_closing_brace => "add '}' to close the block",
                .expected_equals => "use '=' to assign values: size=100",
                .expected_value => "valid values: number (100), string (\"text\"), identifier, array ([...]), or object ({ key=val })",
                .expected_closing_bracket => "add ']' to close the array",
                .expected_closing_paren => "add ')' to match the opening '('",
                .expected_operand => "provide a number, identifier, or (expression) after the operator",
                .too_many_macros => "split into multiple files using #import",
                .expression_too_deep => "simplify or use #define for sub-expressions",
                .expression_too_complex => "simplify or use #define for sub-expressions",
                .too_many_properties, .iteration_limit => null,
            };
        }
    };
};

/// Source location info computed from byte offset.
pub const LineInfo = struct {
    line_num: u32,
    col_num: u32,
    line_start: u32,
    line_end: u32,
};

/// Compute line number, column, and line boundaries from a byte offset.
pub fn getLineInfo(source: []const u8, byte_offset: u32) LineInfo {
    const src_len: u32 = @intCast(source.len);
    const offset: u32 = @min(byte_offset, src_len);
    var line: u32 = 1;
    var line_start: u32 = 0;

    var i: u32 = 0;
    while (i < offset) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }

    // Find end of current line
    var line_end: u32 = offset;
    while (line_end < src_len and source[line_end] != '\n') {
        line_end += 1;
    }

    return .{
        .line_num = line,
        .col_num = offset - line_start + 1,
        .line_start = line_start,
        .line_end = line_end,
    };
}

/// AST Node - compact representation.
///
/// Layout:
/// - tag: 1 byte (enum(u8))
/// - main_token: 4 bytes (u32)
/// - data: 8 bytes (union)
///
/// With natural alignment: 16 bytes (3 bytes padding after tag).
/// Could be 12 bytes with packed struct, but alignment is preferred for performance.
pub const Node = struct {
    tag: Tag,
    main_token: u32,
    data: Data,

    pub const Tag = enum(u8) {
        /// Root node - data.extra_range contains all top-level macros
        root,

        // Macro declarations
        /// #renderPipeline name { ... }
        macro_render_pipeline,
        /// #computePipeline name { ... }
        macro_compute_pipeline,
        /// #buffer name { ... }
        macro_buffer,
        /// #texture name { ... }
        macro_texture,
        /// #sampler name { ... }
        macro_sampler,
        /// #bindGroup name { ... }
        macro_bind_group,
        /// #bindGroupLayout name { ... }
        macro_bind_group_layout,
        /// #pipelineLayout name { ... }
        macro_pipeline_layout,
        /// #renderPass name { ... }
        macro_render_pass,
        /// #computePass name { ... }
        macro_compute_pass,
        /// #init name { buffer=... shader=... params=[...] }
        /// Compute shader initialization for buffers.
        /// Expands to: compute pipeline + params buffer + bind group + compute pass.
        /// Properties:
        /// - buffer: target buffer reference
        /// - shader: WGSL shader module reference
        /// - params: optional array of uniform values
        macro_init,
        /// #renderBundle name { ... }
        /// Pre-recorded draw commands for efficient replay.
        /// Properties:
        /// - colorFormats: array of texture formats
        /// - depthStencilFormat: optional depth format
        /// - sampleCount: MSAA sample count (default 1)
        /// - pipeline: render pipeline reference
        /// - bindGroups: array of bind group references
        /// - vertexBuffers: array of buffer references
        /// - indexBuffer: optional index buffer reference
        /// - draw/drawIndexed: draw command
        macro_render_bundle,
        /// #frame name { ... }
        macro_frame,
        /// #wgsl name { ... }
        macro_wgsl,
        /// #shaderModule name { ... }
        macro_shader_module,
        /// #data name { ... }
        macro_data,
        /// #queue name { ... }
        macro_queue,
        /// #imageBitmap name { ... }
        macro_image_bitmap,
        /// #wasmCall name { ... }
        macro_wasm_call,
        /// #define NAME=value
        macro_define,
        /// #querySet name { ... }
        macro_query_set,
        /// #textureView name { ... }
        macro_texture_view,
        /// #animation name { duration=N loop=bool scenes=[...] }
        /// Timeline definition for scene-based animations.
        /// Properties:
        /// - duration: total animation length in seconds
        /// - loop: whether animation repeats (default: false)
        /// - endBehavior: hold | stop | restart (default: hold)
        /// - scenes: array of scene objects { id frame start end }
        macro_animation,

        // Values
        /// "string literal"
        string_value,
        /// Legacy runtime interpolation string (deprecated)
        /// Previously used for "$canvas.width", now use builtin_ref nodes
        runtime_interpolation,
        /// 123, 0.5, -1, 0xFF
        number_value,
        /// true, false
        boolean_value,
        /// identifier (bareword) - unique resource name
        identifier_value,
        /// canvas.width, time.total - built-in runtime values
        /// No $ prefix needed for these special namespaces.
        /// Layout:
        /// - main_token: namespace token (canvas, time)
        /// - data.node_and_node[0]: namespace token index
        /// - data.node_and_node[1]: property token index
        builtin_ref,
        /// code.inputs - uniform data access for shader modules
        /// References a uniform variable in a shader module.
        /// Analyzer validates module exists and resolves metadata.
        /// Layout:
        /// - main_token: module name token
        /// - data.node_and_node[0]: module token index
        /// - data.node_and_node[1]: var name token index
        uniform_access,
        /// [ ... ] - data.extra_range contains elements
        array,
        /// { ... } - data.extra_range contains properties
        object,

        // ====================================================================
        // Arithmetic expressions (compile-time evaluated)
        // ====================================================================
        //
        // Expression nodes form a tree structure evaluated at compile time.
        // The analyzer resolves these to constant f64 values.
        //
        // Precedence (lowest to highest):
        // 1. Addition/subtraction: expr_add, expr_sub
        // 2. Multiplication/division: expr_mul, expr_div
        // 3. Unary negation: expr_negate
        // 4. Atoms: number_value, parenthesized expressions
        //
        // Associativity: left-to-right for binary operators.
        // Tree structure: 1+2+3 = (1+2)+3, stored as add(add(1,2),3)

        /// Binary addition: a + b
        ///
        /// Layout:
        /// - main_token: the '+' operator token
        /// - data.node_and_node[0]: left operand node index (lhs)
        /// - data.node_and_node[1]: right operand node index (rhs)
        ///
        /// Invariants:
        /// - Both operands must be numeric expressions or number_value
        /// - Result is f64 (lhs + rhs)
        expr_add,

        /// Binary subtraction: a - b
        ///
        /// Layout:
        /// - main_token: the '-' operator token
        /// - data.node_and_node[0]: left operand node index (lhs)
        /// - data.node_and_node[1]: right operand node index (rhs)
        ///
        /// Invariants:
        /// - Both operands must be numeric expressions or number_value
        /// - Result is f64 (lhs - rhs)
        expr_sub,

        /// Binary multiplication: a * b
        ///
        /// Layout:
        /// - main_token: the '*' operator token
        /// - data.node_and_node[0]: left operand node index (lhs)
        /// - data.node_and_node[1]: right operand node index (rhs)
        ///
        /// Invariants:
        /// - Both operands must be numeric expressions or number_value
        /// - Result is f64 (lhs * rhs)
        expr_mul,

        /// Binary division: a / b
        ///
        /// Layout:
        /// - main_token: the '/' operator token
        /// - data.node_and_node[0]: left operand node index (lhs)
        /// - data.node_and_node[1]: right operand node index (rhs)
        ///
        /// Invariants:
        /// - Both operands must be numeric expressions or number_value
        /// - Division by zero returns +Inf or -Inf (IEEE 754)
        /// - Result is f64 (lhs / rhs)
        expr_div,

        /// Unary negation: -a
        ///
        /// Layout:
        /// - main_token: the '-' operator token
        /// - data.node: operand node index
        ///
        /// Invariants:
        /// - Operand must be a numeric expression or number_value
        /// - Result is f64 (-operand)
        /// - Double negation (--a) produces nested expr_negate nodes
        expr_negate,

        // Properties
        /// key=value - main_token is key, data.node is value node
        property,
    };

    pub const Data = extern union {
        none: void,
        node: Index,
        node_and_node: [2]u32,
        extra_range: SubRange,
    };

    /// Typed index into the nodes array.
    pub const Index = enum(u32) {
        root = 0,
        _,

        pub fn toInt(self: Index) u32 {
            return @intFromEnum(self);
        }
    };

    /// Optional index (maxInt sentinel for none).
    pub const OptionalIndex = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(self: OptionalIndex) ?Index {
            return if (self == .none) null else @enumFromInt(@intFromEnum(self));
        }

        pub fn from(idx: ?Index) OptionalIndex {
            return if (idx) |i| @enumFromInt(@intFromEnum(i)) else .none;
        }
    };

    /// Range in extra_data array.
    pub const SubRange = extern struct {
        start: u32,
        end: u32,

        pub fn len(self: SubRange) u32 {
            return self.end - self.start;
        }
    };
};

// Compile-time size verification
comptime {
    // Node should be compact
    std.debug.assert(@sizeOf(Node) <= 16);
    std.debug.assert(@sizeOf(Node.Data) == 8);
}

test "Ast: node size" {
    const testing = std.testing;
    try testing.expect(@sizeOf(Node) <= 16);
    try testing.expect(@sizeOf(Node.Data) == 8);
}

test "Ast: Index conversion" {
    const testing = std.testing;
    const idx: Node.Index = @enumFromInt(42);
    try testing.expectEqual(@as(u32, 42), idx.toInt());
}

test "Ast: OptionalIndex" {
    const testing = std.testing;

    const none: Node.OptionalIndex = .none;
    try testing.expect(none.unwrap() == null);

    const some: Node.OptionalIndex = @enumFromInt(5);
    try testing.expectEqual(@as(u32, 5), some.unwrap().?.toInt());

    try testing.expectEqual(Node.OptionalIndex.none, Node.OptionalIndex.from(null));
    const idx: Node.Index = @enumFromInt(10);
    try testing.expectEqual(@as(u32, 10), @intFromEnum(Node.OptionalIndex.from(idx)));
}

test "Diagnostic: all tags have messages" {
    inline for (std.meta.fields(Diagnostic.Tag)) |field| {
        const tag: Diagnostic.Tag = @enumFromInt(field.value);
        try std.testing.expect(tag.message().len > 0);
    }
}

test "getLineInfo: first line" {
    const source = "hello world";
    const info = getLineInfo(source, 6);
    try std.testing.expectEqual(@as(u32, 1), info.line_num);
    try std.testing.expectEqual(@as(u32, 7), info.col_num);
    try std.testing.expectEqual(@as(u32, 0), info.line_start);
}

test "getLineInfo: second line" {
    const source = "line1\nline2\nline3";
    const info = getLineInfo(source, 8);
    try std.testing.expectEqual(@as(u32, 2), info.line_num);
    try std.testing.expectEqual(@as(u32, 3), info.col_num);
    try std.testing.expectEqual(@as(u32, 6), info.line_start);
    try std.testing.expectEqual(@as(u32, 11), info.line_end);
}

test "getLineInfo: offset at end of source" {
    const source = "abc";
    const info = getLineInfo(source, 3);
    try std.testing.expectEqual(@as(u32, 1), info.line_num);
    try std.testing.expectEqual(@as(u32, 4), info.col_num);
}

test "getLineInfo: empty source" {
    const source = "";
    const info = getLineInfo(source, 0);
    try std.testing.expectEqual(@as(u32, 1), info.line_num);
    try std.testing.expectEqual(@as(u32, 1), info.col_num);
}
