//! DSL Frontend Module (Lexer + Parser)
//!
//! Standalone module for tokenizing and parsing DSL source.
//! Zero external dependencies - can compile independently.
//!
//! Includes: Token, Lexer, Ast, Parser

pub const Token = @import("Token.zig");
pub const Lexer = @import("Lexer.zig");
pub const Ast = @import("Ast.zig");
pub const Parser = @import("Parser.zig");

// Re-export common types
pub const TokenType = Token.Token;
pub const LexerType = Lexer.Lexer;
pub const AstType = Ast.Ast;
pub const Node = Ast.Node;
pub const ParserType = Parser.Parser;

test {
    // Core modules
    _ = Token;
    _ = Lexer;
    _ = Ast;
    _ = Parser;

    // Test files
    _ = @import("parser/test.zig");
    _ = @import("parser/expr_test.zig");
}
