//! DSL Parser for PNGine
//!
//! Parses the macro-based DSL into an AST using iterative descent with
//! explicit task stacks (no recursion).
//!
//! ## Grammar
//!
//! ```ebnf
//! file = macro*
//! macro = "#" macro_name identifier "{" property* "}"
//!       | "#define" identifier "=" value
//! property = identifier "=" value
//! value = string | number | identifier | reference | array | object
//! reference = "$" identifier ("." identifier)*
//! array = "[" value* "]"
//! object = "{" property* "}"
//! ```
//!
//! ## Design
//!
//! - **No recursion**: Uses explicit task stack for nested structures
//! - **Bounded loops**: All loops bounded by MAX_MACROS, MAX_PROPERTIES, MAX_PARSE_ITERATIONS
//! - **Capacity pre-estimation**: 8:1 source:tokens, 2:1 tokens:nodes
//! - **Typed indices**: Uses `Node.Index` enum for type safety
//!
//! ## Invariants
//!
//! - Input must be sentinel-terminated (source[len] == 0)
//! - Root node is always at index 0
//! - All allocations tracked via errdefer for cleanup on error
//! - Nodes reference tokens by index, no string copies
//! - Token index never exceeds tokens.len
//! - Scratch space restored after each parsing operation
//!
//! ## Complexity
//!
//! - `parse()`: O(n) where n = source length
//! - Memory: O(tokens) + O(nodes) + O(extra_data)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Token = @import("Token.zig").Token;
const macro_keywords = @import("Token.zig").macro_keywords;
const Lexer = @import("Lexer.zig").Lexer;
const Ast = @import("Ast.zig").Ast;
const Node = @import("Ast.zig").Node;

pub const Parser = struct {
    /// General-purpose allocator for AST construction.
    gpa: Allocator,

    /// Sentinel-terminated source input.
    source: [:0]const u8,

    /// Token list from lexer (tag + start position).
    tokens: Ast.TokenList,

    /// AST nodes being constructed.
    nodes: Ast.NodeList,

    /// Extra data for nodes with variable-length content.
    /// Stores child node indices for arrays, objects, etc.
    extra_data: std.ArrayListUnmanaged(u32),

    /// Scratch space for building lists before committing to extra_data.
    /// Restored after each parsing operation via shrinkRetainingCapacity.
    ///
    /// **Pointer invalidation**: Slices into `scratch.items` are invalidated when
    /// `shrinkRetainingCapacity` is called. Always copy data to `extra_data` via
    /// `addExtraSlice` before shrinking.
    scratch: std.ArrayListUnmanaged(u32),

    /// Current token index. Invariant: tok_i < tokens.len.
    tok_i: u32,

    /// Current expression parsing depth. Used to bound recursion.
    expr_depth: u32 = 0,

    /// Maximum expression nesting depth (prevents stack overflow).
    const MAX_EXPR_DEPTH: u32 = 64;

    const Self = @This();

    pub const Error = error{
        OutOfMemory,
        ParseError,
    };

    /// Parse DSL source into an AST.
    pub fn parse(gpa: Allocator, source: [:0]const u8) Error!Ast {
        // Pre-condition
        std.debug.assert(source.len == 0 or source[source.len] == 0);

        // Phase 1: Tokenize
        var tokens = Ast.TokenList{};
        errdefer tokens.deinit(gpa);

        // Estimate capacity: ~8 bytes per token (minimum 32 for small inputs)
        const estimated_tokens = @max(source.len / 8, 32);
        try tokens.ensureTotalCapacity(gpa, estimated_tokens);

        var lexer = Lexer.init(source);
        // Bounded loop: at most source.len + 1 tokens (one per byte plus EOF)
        const max_tokens = source.len + 1;
        for (0..max_tokens) |_| {
            const tok = lexer.next();
            // Use append with growth for robustness with random/small inputs
            try tokens.append(gpa, .{
                .tag = tok.tag,
                .start = tok.loc.start,
            });
            if (tok.tag == .eof) break;
        } else unreachable; // Source should always end with EOF

        // Phase 2: Parse
        var parser = Self{
            .gpa = gpa,
            .source = source,
            .tokens = tokens,
            .nodes = .{},
            .extra_data = .{},
            .scratch = .{},
            .tok_i = 0,
        };
        errdefer {
            parser.nodes.deinit(gpa);
            parser.extra_data.deinit(gpa);
            parser.scratch.deinit(gpa);
        }

        // Estimate capacity: ~2 tokens per node
        try parser.nodes.ensureTotalCapacity(gpa, tokens.len / 2);

        try parser.parseRoot();

        // Post-condition
        std.debug.assert(parser.nodes.len > 0);

        // Clean up scratch (not needed after parsing)
        parser.scratch.deinit(gpa);

        return Ast{
            .source = source,
            .tokens = tokens.toOwnedSlice(),
            .nodes = parser.nodes.toOwnedSlice(),
            .extra_data = try parser.extra_data.toOwnedSlice(gpa),
        };
    }

    /// Maximum number of top-level macros.
    const MAX_MACROS: u32 = 4096;

    /// Maximum number of properties in a single object.
    const MAX_PROPERTIES: u32 = 1024;

    fn parseRoot(self: *Self) Error!void {
        // Pre-condition
        std.debug.assert(self.tok_i == 0);

        // Add root node at index 0
        const root_idx = try self.addNode(.{
            .tag = .root,
            .main_token = 0,
            .data = .{ .extra_range = .{ .start = 0, .end = 0 } },
        });
        std.debug.assert(root_idx == .root);

        // Parse all top-level macros
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        // Bounded iteration
        for (0..MAX_MACROS) |_| {
            if (self.currentTag() == .eof) break;
            if (try self.parseMacro()) |macro_idx| {
                try self.scratch.append(self.gpa, macro_idx.toInt());
            } else {
                // Skip unexpected token
                self.tok_i += 1;
            }
        } else {
            // Too many macros
            return error.ParseError;
        }

        // Store macro list in extra_data
        const range = try self.addExtraSlice(self.scratch.items[scratch_top..]);
        self.nodes.items(.data)[0] = .{ .extra_range = range };

        // Post-condition
        std.debug.assert(self.nodes.len > 0);
    }

    fn parseMacro(self: *Self) Error!?Node.Index {
        // Pre-condition: not at EOF
        std.debug.assert(self.tok_i < self.tokens.len);

        const tag = self.currentTag();

        // Map token tag to node tag
        const node_tag: Node.Tag = switch (tag) {
            .macro_render_pipeline => .macro_render_pipeline,
            .macro_compute_pipeline => .macro_compute_pipeline,
            .macro_buffer => .macro_buffer,
            .macro_texture => .macro_texture,
            .macro_sampler => .macro_sampler,
            .macro_bind_group => .macro_bind_group,
            .macro_bind_group_layout => .macro_bind_group_layout,
            .macro_pipeline_layout => .macro_pipeline_layout,
            .macro_render_pass => .macro_render_pass,
            .macro_compute_pass => .macro_compute_pass,
            .macro_render_bundle => .macro_render_bundle,
            .macro_frame => .macro_frame,
            .macro_wgsl => .macro_wgsl,
            .macro_shader_module => .macro_shader_module,
            .macro_data => .macro_data,
            .macro_queue => .macro_queue,
            .macro_image_bitmap => .macro_image_bitmap,
            .macro_wasm_call => .macro_wasm_call,
            .macro_query_set => .macro_query_set,
            .macro_texture_view => .macro_texture_view,
            .macro_animation => .macro_animation,
            .macro_define => return self.parseDefine(),
            else => return null,
        };

        const macro_token = self.tok_i;
        self.tok_i += 1; // consume macro keyword

        // Expect identifier (name)
        if (self.currentTag() != .identifier) {
            return error.ParseError;
        }
        self.tok_i += 1; // consume name

        // Expect opening brace
        if (self.currentTag() != .l_brace) {
            return error.ParseError;
        }
        self.tok_i += 1; // consume {

        // Parse properties until closing brace
        const props = try self.parsePropertyList();

        // Expect closing brace
        if (self.currentTag() != .r_brace) {
            return error.ParseError;
        }
        self.tok_i += 1; // consume }

        return try self.addNode(.{
            .tag = node_tag,
            .main_token = macro_token,
            .data = .{ .extra_range = props },
        });
    }

    fn parseDefine(self: *Self) Error!?Node.Index {
        const define_token = self.tok_i;
        self.tok_i += 1; // consume #define

        // Expect identifier
        if (self.currentTag() != .identifier) {
            return error.ParseError;
        }
        self.tok_i += 1; // consume name

        // Expect =
        if (self.currentTag() != .equals) {
            return error.ParseError;
        }
        self.tok_i += 1; // consume =

        // Parse value
        const value = try self.parseValue() orelse return error.ParseError;

        return try self.addNode(.{
            .tag = .macro_define,
            .main_token = define_token,
            .data = .{ .node = value },
        });
    }

    fn parsePropertyList(self: *Self) Error!Node.SubRange {
        // Pre-condition: valid token index
        std.debug.assert(self.tok_i < self.tokens.len);

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        // Bounded iteration
        for (0..MAX_PROPERTIES) |_| {
            // Skip comments inside macro bodies
            while (self.currentTag() == .line_comment) {
                self.tok_i += 1;
            }
            if (self.currentTag() != .identifier) break;
            const prop = try self.parseProperty();
            try self.scratch.append(self.gpa, prop.toInt());
        } else {
            // Too many properties
            return error.ParseError;
        }

        const range = try self.addExtraSlice(self.scratch.items[scratch_top..]);

        // Post-condition: valid range
        std.debug.assert(range.end >= range.start);

        return range;
    }

    fn parseProperty(self: *Self) Error!Node.Index {
        // Pre-condition: current token is identifier
        std.debug.assert(self.currentTag() == .identifier);

        // key=value
        const key_token = self.tok_i;
        self.tok_i += 1; // consume key

        if (self.currentTag() != .equals) {
            return error.ParseError;
        }
        self.tok_i += 1; // consume =

        const value = try self.parseValue() orelse return error.ParseError;

        const result = try self.addNode(.{
            .tag = .property,
            .main_token = key_token,
            .data = .{ .node = value },
        });

        // Post-condition: property node created
        std.debug.assert(self.nodes.items(.tag)[result.toInt()] == .property);

        return result;
    }

    /// Maximum nesting depth for arrays/objects (prevents stack overflow).
    const MAX_NESTING_DEPTH: u32 = 256;

    /// Maximum total iterations for parsing (prevents infinite loops).
    const MAX_PARSE_ITERATIONS: u32 = 65536;

    /// Task payload for array parsing.
    const ArrayTask = struct { bracket_token: u32, scratch_top: usize };

    /// Task payload for object parsing.
    const ObjectTask = struct { brace_token: u32, scratch_top: usize };

    /// Task payload for finishing a property.
    const PropertyTask = struct { key_token: u32 };

    /// Parse task for iterative value parsing.
    const ParseTask = union(enum) {
        /// Parse array elements and finalize
        array: ArrayTask,
        /// Parse object properties and finalize
        object: ObjectTask,
        /// Create property node with pending key and last result
        finish_property: PropertyTask,
    };

    /// Parse a value iteratively (no recursion).
    /// Handles nested arrays and objects using explicit task stack.
    fn parseValue(self: *Self) Error!?Node.Index {
        // Pre-condition
        std.debug.assert(self.tok_i < self.tokens.len);

        // Fast path: simple values (no nesting)
        switch (self.currentTag()) {
            .string_literal => return try self.parseSimpleValue(.string_value),
            .number_literal => {
                // Check if this is part of an expression (e.g., 1 + 2)
                if (try self.parseExpression()) |expr| {
                    return expr;
                }
                return try self.parseSimpleValue(.number_value);
            },
            .l_paren => {
                // Grouped expression: (1 + 2)
                if (try self.parseExpression()) |expr| {
                    return expr;
                }
                return null;
            },
            .minus => {
                // Unary negation at start of value: -10, -(1+2)
                if (try self.parseExpression()) |expr| {
                    return expr;
                }
                return null;
            },
            .boolean_literal => return try self.parseSimpleValue(.boolean_value),
            .identifier => {
                // Check for builtin ref pattern (canvas.width, time.total)
                if (self.isBuiltinRefPattern()) {
                    return try self.parseBuiltinRef();
                }
                // Check for uniform access pattern (shader.inputs)
                if (self.isUniformAccessPattern()) {
                    return try self.parseUniformAccess();
                }
                // Check if identifier is a math constant (PI, E, TAU)
                const token_start = self.tokens.items(.start)[self.tok_i];
                const token_end = if (self.tok_i + 1 < self.tokens.len)
                    self.tokens.items(.start)[self.tok_i + 1]
                else
                    @as(u32, @intCast(self.source.len));
                const text = std.mem.trimRight(u8, self.source[token_start..token_end], " \t\n\r");
                if (isMathConstant(text)) {
                    // Math constants can be part of expressions
                    if (try self.parseExpression()) |expr| {
                        return expr;
                    }
                    return try self.parseSimpleValue(.number_value);
                }
                // Non-math identifiers: try expression parsing (e.g., CONST*4)
                if (try self.parseExpression()) |expr| {
                    return expr;
                }
                return try self.parseSimpleValue(.identifier_value);
            },
            .l_bracket, .l_brace => {}, // Fall through to iterative parsing
            else => return null,
        }

        // Task stack for iterative parsing
        var tasks = std.ArrayListUnmanaged(ParseTask){};
        defer tasks.deinit(self.gpa);

        // Result stack - completed values waiting to be used
        var results = std.ArrayListUnmanaged(Node.Index){};
        defer results.deinit(self.gpa);

        // Push initial container task
        try self.pushContainerTask(&tasks);

        // Bounded iteration
        for (0..MAX_PARSE_ITERATIONS) |_| {
            if (tasks.items.len == 0) break;

            const task = &tasks.items[tasks.items.len - 1];

            switch (task.*) {
                .array => |*arr| {
                    if (try self.processArrayTask(arr, &tasks, &results)) {
                        _ = tasks.pop();
                    }
                },
                .object => |*obj| {
                    if (try self.processObjectTask(obj, &tasks, &results)) {
                        _ = tasks.pop();
                    }
                },
                .finish_property => |prop| {
                    // Pop the result and create property node
                    const value = results.pop() orelse unreachable;
                    const prop_node = try self.addNode(.{
                        .tag = .property,
                        .main_token = prop.key_token,
                        .data = .{ .node = value },
                    });
                    try self.scratch.append(self.gpa, prop_node.toInt());
                    _ = tasks.pop();
                },
            }
        } else {
            // Loop bound exceeded
            return error.ParseError;
        }

        // Post-condition
        std.debug.assert(results.items.len <= 1);

        return if (results.items.len > 0) results.items[0] else null;
    }

    fn parseSimpleValue(self: *Self, node_tag: Node.Tag) Error!Node.Index {
        // Pre-condition: valid token
        std.debug.assert(self.tok_i < self.tokens.len);

        // Check if string contains runtime interpolation ($...)
        var actual_tag = node_tag;
        if (node_tag == .string_value) {
            const token_start = self.tokens.items(.start)[self.tok_i];
            const token_end = if (self.tok_i + 1 < self.tokens.len)
                self.tokens.items(.start)[self.tok_i + 1]
            else
                @as(u32, @intCast(self.source.len));

            const content = self.source[token_start..token_end];
            // Check if string contains $ (runtime interpolation marker)
            if (std.mem.indexOfScalar(u8, content, '$') != null) {
                actual_tag = .runtime_interpolation;
            }
        }

        const idx = try self.addNode(.{
            .tag = actual_tag,
            .main_token = self.tok_i,
            .data = .{ .none = {} },
        });
        self.tok_i += 1;

        // Post-condition: node created
        std.debug.assert(self.nodes.items(.tag)[idx.toInt()] == actual_tag);
        return idx;
    }

    fn pushContainerTask(self: *Self, tasks: *std.ArrayListUnmanaged(ParseTask)) Error!void {
        // Pre-condition: at container start
        const tag = self.currentTag();
        std.debug.assert(tag == .l_bracket or tag == .l_brace);

        const start_token = self.tok_i;
        const scratch_top = self.scratch.items.len;
        const tasks_len_before = tasks.items.len;
        self.tok_i += 1; // consume [ or {

        if (tag == .l_bracket) {
            try tasks.append(self.gpa, .{ .array = .{
                .bracket_token = start_token,
                .scratch_top = scratch_top,
            } });
        } else {
            try tasks.append(self.gpa, .{ .object = .{
                .brace_token = start_token,
                .scratch_top = scratch_top,
            } });
        }

        // Post-condition: task added
        std.debug.assert(tasks.items.len == tasks_len_before + 1);
    }

    /// Create property node and append to scratch. Common pattern in object parsing.
    fn addPropertyToScratch(self: *Self, key_token: u32, value: Node.Index) Error!void {
        const prop = try self.addNode(.{
            .tag = .property,
            .main_token = key_token,
            .data = .{ .node = value },
        });
        try self.scratch.append(self.gpa, prop.toInt());
    }

    /// Parse identifier value, checking for math constants and special patterns.
    /// Returns the parsed value node and its tag type.
    fn parseIdentifierAsValue(self: *Self) Error!Node.Index {
        // Check for builtin ref pattern (canvas.width, time.total)
        if (self.isBuiltinRefPattern()) {
            return try self.parseBuiltinRef();
        }
        // Check for uniform access pattern (module.varName)
        if (self.isUniformAccessPattern()) {
            return try self.parseUniformAccess();
        }
        // Check if identifier is a math constant (PI, E, TAU)
        const token_start = self.tokens.items(.start)[self.tok_i];
        const token_end = if (self.tok_i + 1 < self.tokens.len)
            self.tokens.items(.start)[self.tok_i + 1]
        else
            @as(u32, @intCast(self.source.len));
        const text = std.mem.trimRight(u8, self.source[token_start..token_end], " \t\n\r");
        const node_tag: Node.Tag = if (isMathConstant(text)) .number_value else .identifier_value;
        return try self.parseSimpleValue(node_tag);
    }

    /// Parse unary negation in array context: -NUM or -(expr).
    fn parseArrayNegation(self: *Self) Error!Node.Index {
        const minus_token = self.tok_i;
        self.tok_i += 1; // consume -
        if (self.currentTag() == .number_literal) {
            const operand = try self.parseSimpleValue(.number_value);
            return try self.addNode(.{
                .tag = .expr_negate,
                .main_token = minus_token,
                .data = .{ .node = operand },
            });
        } else if (self.currentTag() == .l_paren) {
            // Allow -(expr) for explicit negated expressions
            const expr = try self.parseExpression() orelse return error.ParseError;
            return try self.addNode(.{
                .tag = .expr_negate,
                .main_token = minus_token,
                .data = .{ .node = expr },
            });
        } else {
            return error.ParseError;
        }
    }

    /// Process array task. Returns true when array is complete.
    fn processArrayTask(
        self: *Self,
        arr: *ArrayTask,
        tasks: *std.ArrayListUnmanaged(ParseTask),
        results: *std.ArrayListUnmanaged(Node.Index),
    ) Error!bool {
        // First, consume any pending results from nested containers
        while (results.items.len > 0) {
            const nested_result = results.pop() orelse unreachable;
            try self.scratch.append(self.gpa, nested_result.toInt());
        }

        const current = self.currentTag();

        // Check for array end
        if (current == .r_bracket) {
            const range = try self.addExtraSlice(self.scratch.items[arr.scratch_top..]);
            self.scratch.shrinkRetainingCapacity(arr.scratch_top);
            self.tok_i += 1; // consume ]

            const node = try self.addNode(.{
                .tag = .array,
                .main_token = arr.bracket_token,
                .data = .{ .extra_range = range },
            });
            try results.append(self.gpa, node);
            return true;
        }

        // Skip commas and comments
        if (current == .comma or current == .line_comment) {
            self.tok_i += 1;
            return false;
        }

        if (current == .eof) return error.ParseError;

        // Parse element
        switch (current) {
            .string_literal => {
                const elem = try self.parseSimpleValue(.string_value);
                try self.scratch.append(self.gpa, elem.toInt());
            },
            .number_literal => {
                // In arrays, parse numbers as simple values (not expressions)
                // This allows [1 -1 2 -2] to be 4 values, not 2 subtraction results
                // Use parentheses for expressions: [(1+2) 3]
                const elem = try self.parseSimpleValue(.number_value);
                try self.scratch.append(self.gpa, elem.toInt());
            },
            .l_paren => {
                // Grouped expression in array: [(1 + 2), 3]
                if (try self.parseExpression()) |expr| {
                    try self.scratch.append(self.gpa, expr.toInt());
                } else {
                    return error.ParseError;
                }
            },
            .minus => {
                // Unary negation in array: [-1, -2]
                // Don't use parseExpression to avoid "-1 -2" becoming "-1 - 2"
                const elem = try self.parseArrayNegation();
                try self.scratch.append(self.gpa, elem.toInt());
            },
            .boolean_literal => {
                const elem = try self.parseSimpleValue(.boolean_value);
                try self.scratch.append(self.gpa, elem.toInt());
            },
            .identifier => {
                const elem = try self.parseIdentifierAsValue();
                try self.scratch.append(self.gpa, elem.toInt());
            },
            .l_bracket, .l_brace => {
                // Nested container - push task (result will come later)
                try self.pushContainerTask(tasks);
            },
            else => return true, // End of elements
        }

        return false;
    }

    /// Process object task. Returns true when object is complete.
    fn processObjectTask(
        self: *Self,
        obj: *ObjectTask,
        tasks: *std.ArrayListUnmanaged(ParseTask),
        results: *std.ArrayListUnmanaged(Node.Index),
    ) Error!bool {
        const current = self.currentTag();

        // Check for object end
        if (current == .r_brace) {
            const range = try self.addExtraSlice(self.scratch.items[obj.scratch_top..]);
            self.scratch.shrinkRetainingCapacity(obj.scratch_top);
            self.tok_i += 1; // consume }

            const node = try self.addNode(.{
                .tag = .object,
                .main_token = obj.brace_token,
                .data = .{ .extra_range = range },
            });
            try results.append(self.gpa, node);
            return true;
        }

        if (current == .eof) return error.ParseError;

        // Skip comments inside objects
        if (current == .line_comment) {
            self.tok_i += 1;
            return false;
        }

        if (current != .identifier) return true; // End of properties

        // Parse property: key=value
        const key_token = self.tok_i;
        self.tok_i += 1; // consume key

        if (self.currentTag() != .equals) return error.ParseError;
        self.tok_i += 1; // consume =

        // Parse value and create property
        const value_tag = self.currentTag();
        switch (value_tag) {
            .string_literal => {
                const value = try self.parseSimpleValue(.string_value);
                try self.addPropertyToScratch(key_token, value);
            },
            .number_literal => {
                // Try to parse as expression first (e.g., size=1+2)
                const value = if (try self.parseExpression()) |expr|
                    expr
                else
                    try self.parseSimpleValue(.number_value);
                try self.addPropertyToScratch(key_token, value);
            },
            .l_paren => {
                // Grouped expression: size=(1+2)
                const value = try self.parseExpression() orelse return error.ParseError;
                try self.addPropertyToScratch(key_token, value);
            },
            .minus => {
                // Unary negation: offset=-10
                const value = try self.parseExpression() orelse return error.ParseError;
                try self.addPropertyToScratch(key_token, value);
            },
            .boolean_literal => {
                const value = try self.parseSimpleValue(.boolean_value);
                try self.addPropertyToScratch(key_token, value);
            },
            .identifier => {
                const value = try self.parseIdentifierAsValue();
                try self.addPropertyToScratch(key_token, value);
            },
            .l_bracket, .l_brace => {
                // Nested container - push finish_property task, then container task
                try tasks.append(self.gpa, .{ .finish_property = .{ .key_token = key_token } });
                try self.pushContainerTask(tasks);
            },
            else => return error.ParseError,
        }

        return false;
    }

    // NOTE: The parseReference function has been removed.
    // The $namespace.name reference syntax is no longer supported.
    // Bare identifiers are now used everywhere and resolved based on context.

    /// Check if identifier is a builtin namespace (canvas, time).
    fn isBuiltinNamespace(self: *Self) bool {
        if (self.currentTag() != .identifier) return false;
        const text = self.getTokenText(self.tok_i);
        return std.mem.eql(u8, text, "canvas") or std.mem.eql(u8, text, "time");
    }

    /// Check if current position is a builtin ref pattern (canvas.width, time.total).
    fn isBuiltinRefPattern(self: *Self) bool {
        if (!self.isBuiltinNamespace()) return false;
        // Check for .identifier pattern following
        if (self.tok_i + 2 >= self.tokens.len) return false;
        if (self.tokens.items(.tag)[self.tok_i + 1] != .dot) return false;
        if (self.tokens.items(.tag)[self.tok_i + 2] != .identifier) return false;
        return true;
    }

    /// Parse a builtin ref (canvas.width, time.total).
    fn parseBuiltinRef(self: *Self) Error!Node.Index {
        // Pre-condition: at builtin namespace identifier
        std.debug.assert(self.isBuiltinRefPattern());

        const namespace_token = self.tok_i;
        self.tok_i += 1; // consume namespace
        self.tok_i += 1; // consume .
        const property_token = self.tok_i;
        self.tok_i += 1; // consume property

        return try self.addNode(.{
            .tag = .builtin_ref,
            .main_token = namespace_token,
            .data = .{ .node_and_node = .{ namespace_token, property_token } },
        });
    }

    /// Check if current position is a uniform access pattern (module.varName).
    /// This is similar to builtin_ref but for shader uniform references.
    /// Returns true for identifier.identifier patterns that aren't builtin refs.
    fn isUniformAccessPattern(self: *Self) bool {
        // Must be identifier
        if (self.currentTag() != .identifier) return false;
        // Must NOT be a builtin namespace (canvas, time)
        if (self.isBuiltinNamespace()) return false;
        // Check for .identifier pattern following
        if (self.tok_i + 2 >= self.tokens.len) return false;
        if (self.tokens.items(.tag)[self.tok_i + 1] != .dot) return false;
        if (self.tokens.items(.tag)[self.tok_i + 2] != .identifier) return false;
        return true;
    }

    /// Parse a uniform access (module.varName).
    fn parseUniformAccess(self: *Self) Error!Node.Index {
        // Pre-condition: at module identifier
        std.debug.assert(self.isUniformAccessPattern());

        const module_token = self.tok_i;
        self.tok_i += 1; // consume module
        self.tok_i += 1; // consume .
        const var_token = self.tok_i;
        self.tok_i += 1; // consume varName

        return try self.addNode(.{
            .tag = .uniform_access,
            .main_token = module_token,
            .data = .{ .node_and_node = .{ module_token, var_token } },
        });
    }

    /// Get token text for current position.
    fn getTokenText(self: *Self, tok_i: u32) []const u8 {
        const token_start = self.tokens.items(.start)[tok_i];
        const token_end = if (tok_i + 1 < self.tokens.len)
            self.tokens.items(.start)[tok_i + 1]
        else
            @as(u32, @intCast(self.source.len));
        return std.mem.trimRight(u8, self.source[token_start..token_end], " \t\n\r.=[]{}");
    }

    // Kept for backward compatibility with parsePropertyList
    fn parseArray(self: *Self) Error!Node.Index {
        return (try self.parseValue()) orelse error.ParseError;
    }

    fn parseObject(self: *Self) Error!Node.Index {
        return (try self.parseValue()) orelse error.ParseError;
    }

    // ========================================================================
    // Expression Parsing (compile-time arithmetic)
    // ========================================================================

    /// Check if current token can start an expression.
    fn canStartExpression(self: *Self) bool {
        return switch (self.currentTag()) {
            .number_literal, .l_paren => true,
            .minus => blk: {
                // Check if this is unary minus (followed by number or paren)
                if (self.tok_i + 1 >= self.tokens.len) break :blk false;
                const next = self.tokens.items(.tag)[self.tok_i + 1];
                break :blk next == .number_literal or next == .l_paren;
            },
            .identifier => true, // All identifiers can start expressions (includes #define refs and math constants)
            else => false,
        };
    }

    /// Check if current token is an operator that continues an expression.
    fn isExpressionOperator(self: *Self) bool {
        return switch (self.currentTag()) {
            .plus, .minus, .star, .slash => true,
            else => false,
        };
    }

    /// Parse an expression with operator precedence.
    ///
    /// Grammar: expr = term (('+' | '-') term)*
    /// Handles addition/subtraction (lowest precedence).
    ///
    /// Returns null if current token can't start an expression.
    fn parseExpression(self: *Self) Error!?Node.Index {
        // Pre-conditions
        std.debug.assert(self.tok_i < self.tokens.len);
        const start_tok = self.tok_i;

        // Parse left operand (term handles higher precedence: *, /)
        var left = try self.parseTerm() orelse return null;

        // Consume additional terms separated by + or -
        const MAX_EXPR_TERMS: u32 = 256;
        for (0..MAX_EXPR_TERMS) |_| {
            const op_tag = self.currentTag();
            if (op_tag != .plus and op_tag != .minus) break;

            const op_token = self.tok_i;
            self.tok_i += 1; // advance past operator to parse right-hand side

            const right = try self.parseTerm() orelse return error.ParseError;

            // Build left-associative tree: a + b + c = (a + b) + c
            const node_tag: Node.Tag = if (op_tag == .plus) .expr_add else .expr_sub;
            left = try self.addNode(.{
                .tag = node_tag,
                .main_token = op_token,
                .data = .{ .node_and_node = .{ left.toInt(), right.toInt() } },
            });
        } else {
            return error.ParseError; // Bounded loop guard - expression too complex
        }

        // Post-condition: consumed at least one token
        std.debug.assert(self.tok_i > start_tok);

        return left;
    }

    /// Parse a term (handles * and /).
    ///
    /// Grammar: term = factor (('*' | '/') factor)*
    /// Handles multiplication/division (higher precedence than +/-).
    ///
    /// Returns null if current token can't start a factor.
    fn parseTerm(self: *Self) Error!?Node.Index {
        // Pre-conditions
        std.debug.assert(self.tok_i < self.tokens.len);
        const start_tok = self.tok_i;

        // Parse left operand (factor)
        var left = try self.parseFactor() orelse return null;

        // Parse right operands with * or /
        const MAX_TERM_FACTORS: u32 = 256;
        for (0..MAX_TERM_FACTORS) |_| {
            const op_tag = self.currentTag();
            if (op_tag != .star and op_tag != .slash) break;

            const op_token = self.tok_i;
            self.tok_i += 1; // consume operator

            const right = try self.parseFactor() orelse return error.ParseError;

            // Build left-associative tree: a * b * c = (a * b) * c
            const node_tag: Node.Tag = if (op_tag == .star) .expr_mul else .expr_div;
            left = try self.addNode(.{
                .tag = node_tag,
                .main_token = op_token,
                .data = .{ .node_and_node = .{ left.toInt(), right.toInt() } },
            });
        } else {
            return error.ParseError; // Too many factors
        }

        // Post-condition: consumed at least one token
        std.debug.assert(self.tok_i > start_tok);

        return left;
    }

    /// Parse a factor (atomic expression).
    ///
    /// Grammar: factor = number | '(' expr ')' | '-' factor
    /// Handles atomic values and grouping (highest precedence).
    ///
    /// Recursion is bounded by MAX_EXPR_DEPTH to prevent stack overflow.
    /// Returns null if current token can't start a factor.
    fn parseFactor(self: *Self) Error!?Node.Index {
        // Pre-conditions
        std.debug.assert(self.tok_i < self.tokens.len);
        if (self.expr_depth >= MAX_EXPR_DEPTH) return error.ParseError;
        const start_tok = self.tok_i;

        // Track depth for recursive calls
        self.expr_depth += 1;
        defer self.expr_depth -= 1;

        const result: ?Node.Index = switch (self.currentTag()) {
            .number_literal => {
                // Simple number
                return try self.parseSimpleValue(.number_value);
            },
            .l_paren => {
                // Grouped expression: ( expr )
                self.tok_i += 1; // consume (
                const inner = try self.parseExpression() orelse return error.ParseError;
                if (self.currentTag() != .r_paren) return error.ParseError;
                self.tok_i += 1; // consume )
                return inner;
            },
            .minus => {
                // Unary negation: -factor (recursive, but bounded by expr_depth)
                const minus_token = self.tok_i;
                self.tok_i += 1; // consume -

                // Parse the operand (handles --x, -(expr), etc.)
                const operand = try self.parseFactor() orelse return error.ParseError;
                return try self.addNode(.{
                    .tag = .expr_negate,
                    .main_token = minus_token,
                    .data = .{ .node = operand },
                });
            },
            .identifier => {
                // Identifiers in expressions: math constants (PI, E, TAU) or #define refs
                const token_start = self.tokens.items(.start)[self.tok_i];
                const token_end = if (self.tok_i + 1 < self.tokens.len)
                    self.tokens.items(.start)[self.tok_i + 1]
                else
                    @as(u32, @intCast(self.source.len));
                const text = std.mem.trimRight(u8, self.source[token_start..token_end], " \t\n\r");
                if (isMathConstant(text)) {
                    return try self.parseSimpleValue(.number_value);
                }
                // Non-math-constant identifiers: could be #define references
                return try self.parseSimpleValue(.identifier_value);
            },
            else => null,
        };

        // Post-condition: if successful, consumed at least one token
        if (result != null) {
            std.debug.assert(self.tok_i > start_tok);
        }

        return result;
    }

    /// Try to parse a value that might be an expression.
    /// Returns expression if operators follow a number, otherwise simple value.
    fn parseValueOrExpression(self: *Self) Error!?Node.Index {
        // Pre-condition
        std.debug.assert(self.tok_i < self.tokens.len);

        // Check if this could be an expression
        if (self.canStartExpression()) {
            // Save position to check if we got more than just a number
            const start_tok = self.tok_i;

            const result = try self.parseExpression();

            // If we consumed operators, it's an expression
            // If we just consumed one number, it's already a number_value node
            if (result) |node| {
                const tag = self.nodes.items(.tag)[node.toInt()];
                // If it's an expression node, return it
                if (tag == .expr_add or tag == .expr_sub or
                    tag == .expr_mul or tag == .expr_div or tag == .expr_negate)
                {
                    return node;
                }
                // Otherwise it's a simple number value
                return node;
            }

            // Couldn't parse expression, restore position
            self.tok_i = start_tok;
        }

        return null;
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    fn currentTag(self: *Self) Token.Tag {
        return self.tokens.items(.tag)[self.tok_i];
    }

    fn addNode(self: *Self, node: Node) Error!Node.Index {
        // Pre-condition: valid node tag (all tags are valid)
        std.debug.assert(@intFromEnum(node.tag) < std.meta.fields(Node.Tag).len);

        const idx: u32 = @intCast(self.nodes.len);
        try self.nodes.append(self.gpa, node);

        // Post-condition: node added
        std.debug.assert(self.nodes.len == idx + 1);
        return @enumFromInt(idx);
    }

    fn addExtraSlice(self: *Self, items: []const u32) Error!Node.SubRange {
        const start: u32 = @intCast(self.extra_data.items.len);
        const items_len: u32 = @intCast(items.len);
        try self.extra_data.appendSlice(self.gpa, items);

        const result: Node.SubRange = .{
            .start = start,
            .end = @intCast(self.extra_data.items.len),
        };

        // Post-condition: range is valid and has correct length
        std.debug.assert(result.end >= result.start);
        std.debug.assert(result.end - result.start == items_len);
        return result;
    }
};

// ============================================================================
/// Check if text is a recognized math constant.
/// Supports: PI, E, TAU (case-sensitive)
fn isMathConstant(text: []const u8) bool {
    return std.mem.eql(u8, text, "PI") or
        std.mem.eql(u8, text, "E") or
        std.mem.eql(u8, text, "TAU");
}
