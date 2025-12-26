//! DSL Backend Module (Analyzer)
//!
//! Standalone module for semantic analysis of DSL AST.
//! Uses module import for types (provided by build.zig).
//!
//! The Analyzer performs:
//! - Symbol table construction
//! - Reference resolution
//! - Cycle detection in imports
//! - Plugin detection

// Import types from module (provided by build.zig addImport)
const types = @import("types");

// Re-export PluginSet so Analyzer.zig can find it via @import("root")
pub const PluginSet = types.PluginSet;
pub const Plugin = types.Plugin;

// Analyzer (imports PluginSet from root)
pub const Analyzer = @import("Analyzer.zig").Analyzer;

// Frontend types needed for analysis
pub const Ast = @import("Ast.zig").Ast;
pub const Node = @import("Ast.zig").Node;
pub const Parser = @import("Parser.zig").Parser;

test {
    // Core analyzer module
    _ = @import("Analyzer.zig");

    // Test files
    _ = @import("analyzer/test.zig");
    _ = @import("analyzer/expr_test.zig");
}
