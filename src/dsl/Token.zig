//! Token definitions for PNGine DSL
//!
//! The DSL uses a macro-based syntax:
//!   #renderPipeline name { properties... }
//!   #buffer name { size=100 usage=[VERTEX] }
//!   #frame name { perform=[pass1 pass2] }
//!
//! Tokens represent lexical units without storing string data.
//! Location references back to source via start/end offsets.

const std = @import("std");

pub const Token = struct {
    /// Token type tag. 1 byte (enum(u8)).
    tag: Tag,
    /// Source location. 8 bytes (2 x u32).
    loc: Loc,

    /// Source location within input buffer.
    pub const Loc = struct {
        /// Byte offset of first character (inclusive).
        start: u32,
        /// Byte offset past last character (exclusive).
        /// Invariant: end >= start.
        end: u32,
    };

    // Compile-time layout verification
    comptime {
        // Token.Tag fits in 1 byte
        std.debug.assert(@sizeOf(Tag) == 1);
        // Token.Loc is exactly 8 bytes
        std.debug.assert(@sizeOf(Loc) == 8);
        // Token is compact (12 bytes with alignment padding)
        std.debug.assert(@sizeOf(Token) <= 12);
    }

    pub const Tag = enum(u8) {
        // Special
        invalid,
        eof,

        // Literals & identifiers
        identifier, // foo, bar, entryPoint
        string_literal, // "text"
        number_literal, // 123, 0.5, -1.5, 0xFF (WebGPU uses hex for usage flags)
        boolean_literal, // true, false (for enable/disable flags)

        // Macros (# prefix)
        macro_define, // #define
        macro_wgsl, // #wgsl
        macro_shader_module, // #shaderModule
        macro_render_pipeline, // #renderPipeline
        macro_compute_pipeline, // #computePipeline
        macro_buffer, // #buffer
        macro_texture, // #texture
        macro_sampler, // #sampler
        macro_bind_group, // #bindGroup
        macro_bind_group_layout, // #bindGroupLayout
        macro_pipeline_layout, // #pipelineLayout
        macro_render_pass, // #renderPass
        macro_compute_pass, // #computePass
        macro_render_bundle, // #renderBundle
        macro_frame, // #frame
        macro_data, // #data
        macro_queue, // #queue
        macro_query_set, // #querySet
        macro_texture_view, // #textureView
        macro_image_bitmap, // #imageBitmap
        macro_wasm_call, // #wasmCall
        macro_import, // #import
        macro_animation, // #animation

        // Punctuation
        l_brace, // {
        r_brace, // }
        l_bracket, // [
        r_bracket, // ]
        l_paren, // (
        r_paren, // )
        equals, // =
        comma, // ,
        dot, // .

        // Arithmetic operators (for compile-time constant expressions)
        plus, // +
        minus, // -
        star, // *
        slash, // /

        // Comments (preserved for WGSL passthrough)
        line_comment, // // ...
        doc_comment, // /// ...

        /// Returns the lexeme for fixed tokens, null for variable-content tokens.
        pub fn lexeme(tag: Tag) ?[]const u8 {
            return switch (tag) {
                .l_brace => "{",
                .r_brace => "}",
                .l_bracket => "[",
                .r_bracket => "]",
                .l_paren => "(",
                .r_paren => ")",
                .equals => "=",
                .comma => ",",
                .dot => ".",
                .plus => "+",
                .minus => "-",
                .star => "*",
                .slash => "/",
                else => null,
            };
        }
    };

    /// Get the source text for this token.
    pub fn slice(self: Token, source: []const u8) []const u8 {
        return source[self.loc.start..self.loc.end];
    }
};

/// Macro keyword lookup table.
pub const macro_keywords = std.StaticStringMap(Token.Tag).initComptime(.{
    .{ "define", .macro_define },
    .{ "wgsl", .macro_wgsl },
    .{ "shaderModule", .macro_shader_module },
    .{ "renderPipeline", .macro_render_pipeline },
    .{ "computePipeline", .macro_compute_pipeline },
    .{ "buffer", .macro_buffer },
    .{ "texture", .macro_texture },
    .{ "sampler", .macro_sampler },
    .{ "bindGroup", .macro_bind_group },
    .{ "bindGroupLayout", .macro_bind_group_layout },
    .{ "pipelineLayout", .macro_pipeline_layout },
    .{ "renderPass", .macro_render_pass },
    .{ "computePass", .macro_compute_pass },
    .{ "renderBundle", .macro_render_bundle },
    .{ "frame", .macro_frame },
    .{ "data", .macro_data },
    .{ "queue", .macro_queue },
    .{ "querySet", .macro_query_set },
    .{ "textureView", .macro_texture_view },
    .{ "imageBitmap", .macro_image_bitmap },
    .{ "wasmCall", .macro_wasm_call },
    .{ "import", .macro_import },
    .{ "animation", .macro_animation },
});

/// Literal keywords that produce special tokens instead of identifiers.
///
/// These reserved words have special meaning in the DSL and are tokenized
/// as their corresponding literal type rather than generic identifiers.
///
/// Example: `enabled=true` tokenizes `true` as `.boolean_literal`, not `.identifier`.
pub const literal_keywords = std.StaticStringMap(Token.Tag).initComptime(.{
    .{ "true", .boolean_literal },
    .{ "false", .boolean_literal },
});

test "Token: lexeme returns correct strings" {
    const testing = std.testing;
    try testing.expectEqualStrings("{", Token.Tag.l_brace.lexeme().?);
    try testing.expectEqualStrings("}", Token.Tag.r_brace.lexeme().?);
    try testing.expectEqualStrings("=", Token.Tag.equals.lexeme().?);
    try testing.expect(Token.Tag.identifier.lexeme() == null);
    try testing.expect(Token.Tag.string_literal.lexeme() == null);
}

test "Token: macro_keywords lookup" {
    const testing = std.testing;
    try testing.expectEqual(Token.Tag.macro_render_pipeline, macro_keywords.get("renderPipeline").?);
    try testing.expectEqual(Token.Tag.macro_buffer, macro_keywords.get("buffer").?);
    try testing.expectEqual(Token.Tag.macro_frame, macro_keywords.get("frame").?);
    try testing.expect(macro_keywords.get("unknown") == null);
}
