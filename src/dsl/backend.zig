//! DSL Backend Module (Analyzer)
//!
//! Standalone module for semantic analysis of DSL AST.
//! Dependencies: types/plugins.zig (PluginSet), dsl frontend (Ast, Parser)
//!
//! The Analyzer performs:
//! - Symbol table construction
//! - Reference resolution
//! - Cycle detection in imports
//! - Plugin detection

pub const Analyzer = @import("Analyzer.zig").Analyzer;

// Frontend types needed for analysis
pub const Ast = @import("Ast.zig").Ast;
pub const Node = @import("Ast.zig").Node;
pub const Parser = @import("Parser.zig").Parser;

// Plugin types from shared types module
pub const PluginSet = @import("../types/plugins.zig").PluginSet;

test {
    // Core analyzer module
    _ = @import("Analyzer.zig");

    // Test files
    _ = @import("analyzer/test.zig");
    _ = @import("analyzer/expr_test.zig");
}
