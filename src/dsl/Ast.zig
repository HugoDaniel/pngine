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
//! value = string | number | identifier | reference | array | object
//! reference = "$" identifier ("." identifier)*
//! array = "[" value* "]"
//! object = "{" property* "}"
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

    pub const TokenList = std.MultiArrayList(struct {
        tag: Token.Tag,
        start: u32,
    });

    pub const NodeList = std.MultiArrayList(Node);

    pub fn deinit(self: *Ast, gpa: std.mem.Allocator) void {
        gpa.free(self.extra_data);
        self.tokens.deinit(gpa);
        self.nodes.deinit(gpa);
        self.* = undefined;
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
};

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
        /// #define NAME=value
        macro_define,

        // Values
        /// "string literal"
        string_value,
        /// 123, 0.5, -1
        number_value,
        /// identifier (bareword)
        identifier_value,
        /// $wgsl.name - data.node_and_node = [namespace_token, name_token]
        reference,
        /// [ ... ] - data.extra_range contains elements
        array,
        /// { ... } - data.extra_range contains properties
        object,

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
