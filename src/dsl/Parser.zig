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
    scratch: std.ArrayListUnmanaged(u32),

    /// Current token index. Invariant: tok_i < tokens.len.
    tok_i: u32,

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
        while (true) {
            const tok = lexer.next();
            // Use append with growth for robustness with random/small inputs
            try tokens.append(gpa, .{
                .tag = tok.tag,
                .start = tok.loc.start,
            });
            if (tok.tag == .eof) break;
        }

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
            .macro_frame => .macro_frame,
            .macro_wgsl => .macro_wgsl,
            .macro_shader_module => .macro_shader_module,
            .macro_data => .macro_data,
            .macro_queue => .macro_queue,
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
            .number_literal => return try self.parseSimpleValue(.number_value),
            .identifier => return try self.parseSimpleValue(.identifier_value),
            .dollar => return try self.parseReference(),
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

        const idx = try self.addNode(.{
            .tag = node_tag,
            .main_token = self.tok_i,
            .data = .{ .none = {} },
        });
        self.tok_i += 1;

        // Post-condition: node created with correct tag
        std.debug.assert(self.nodes.items(.tag)[idx.toInt()] == node_tag);
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

        // Skip commas
        if (current == .comma) {
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
                const elem = try self.parseSimpleValue(.number_value);
                try self.scratch.append(self.gpa, elem.toInt());
            },
            .identifier => {
                const elem = try self.parseSimpleValue(.identifier_value);
                try self.scratch.append(self.gpa, elem.toInt());
            },
            .dollar => {
                const elem = try self.parseReference();
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
        if (current != .identifier) return true; // End of properties

        // Parse property: key=value
        const key_token = self.tok_i;
        self.tok_i += 1; // consume key

        if (self.currentTag() != .equals) return error.ParseError;
        self.tok_i += 1; // consume =

        // Parse value
        const value_tag = self.currentTag();
        switch (value_tag) {
            .string_literal => {
                const value = try self.parseSimpleValue(.string_value);
                const prop = try self.addNode(.{
                    .tag = .property,
                    .main_token = key_token,
                    .data = .{ .node = value },
                });
                try self.scratch.append(self.gpa, prop.toInt());
            },
            .number_literal => {
                const value = try self.parseSimpleValue(.number_value);
                const prop = try self.addNode(.{
                    .tag = .property,
                    .main_token = key_token,
                    .data = .{ .node = value },
                });
                try self.scratch.append(self.gpa, prop.toInt());
            },
            .identifier => {
                const value = try self.parseSimpleValue(.identifier_value);
                const prop = try self.addNode(.{
                    .tag = .property,
                    .main_token = key_token,
                    .data = .{ .node = value },
                });
                try self.scratch.append(self.gpa, prop.toInt());
            },
            .dollar => {
                const value = try self.parseReference();
                const prop = try self.addNode(.{
                    .tag = .property,
                    .main_token = key_token,
                    .data = .{ .node = value },
                });
                try self.scratch.append(self.gpa, prop.toInt());
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

    fn parseReference(self: *Self) Error!Node.Index {
        // Pre-condition
        std.debug.assert(self.currentTag() == .dollar);

        const dollar_token = self.tok_i;
        self.tok_i += 1; // consume $

        if (self.currentTag() != .identifier) return error.ParseError;
        const namespace_token = self.tok_i;
        self.tok_i += 1; // consume namespace

        // Optional: .name
        var name_token: u32 = namespace_token;
        if (self.currentTag() == .dot) {
            self.tok_i += 1; // consume .
            if (self.currentTag() != .identifier) return error.ParseError;
            name_token = self.tok_i;
            self.tok_i += 1; // consume name
        }

        // Post-condition
        std.debug.assert(name_token >= namespace_token);

        return try self.addNode(.{
            .tag = .reference,
            .main_token = dollar_token,
            .data = .{ .node_and_node = .{ namespace_token, name_token } },
        });
    }

    // Kept for backward compatibility with parsePropertyList
    fn parseArray(self: *Self) Error!Node.Index {
        return (try self.parseValue()) orelse error.ParseError;
    }

    fn parseObject(self: *Self) Error!Node.Index {
        return (try self.parseValue()) orelse error.ParseError;
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    fn currentTag(self: *Self) Token.Tag {
        return self.tokens.items(.tag)[self.tok_i];
    }

    fn addNode(self: *Self, node: Node) Error!Node.Index {
        // Pre-condition: valid node tag
        std.debug.assert(@intFromEnum(node.tag) <= @intFromEnum(Node.Tag.property));

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
// Tests
// ============================================================================

const testing = std.testing;

fn parseSource(source: [:0]const u8) !Ast {
    return Parser.parse(testing.allocator, source);
}

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

test "Parser: negative numbers" {
    const source: [:0]const u8 = "#buffer buf { offset=-10 }";
    var ast = try parseSource(source);
    defer ast.deinit(testing.allocator);

    // Find number value node
    var found_number = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .number_value) {
            found_number = true;
            break;
        }
    }
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
    };

    for (macros) |source| {
        var ast = try parseSource(source);
        defer ast.deinit(testing.allocator);
        // Just verify it parses without error
        try testing.expect(ast.nodes.len >= 2);
    }
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
