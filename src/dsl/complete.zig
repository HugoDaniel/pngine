//! DSL Complete Module (Emitter + full DSL chain)
//!
//! Standalone module for end-to-end DSL compilation to PNGB bytecode.
//! Bundles all DSL components and uses module imports for external deps.
//!
//! Dependencies (via build.zig module imports):
//! - types: Core type definitions (PluginSet, etc.)
//! - bytecode: PNGB format, opcodes, emitter
//! - reflect: WGSL shader reflection (miniray)
//! - executor: Mock GPU and dispatcher for execution tests
//!
//! Test count: ~369 tests (emitter only, frontend/backend tested separately)
//! - test.zig: 120
//! - integration_test.zig: 19
//! - wgsl_imports_test.zig: 25
//! - animation_test.zig: 40
//! - shader_id_test.zig: 24
//! - define_subst_test.zig: 58
//! - import_dedup_test.zig: 24
//! - wgsl_runtime_test.zig: 13
//! - module_reference_test.zig: 26
//! - builtin_inputs_test.zig: 12
//! - minify_uniforms_test.zig: 12 (requires libminiray.a)

// ============================================================================
// Module Imports (provided by build.zig)
// ============================================================================

// Import types from module (for PluginSet needed by Analyzer via @import("root"))
const types = @import("types");
pub const PluginSet = types.PluginSet;
pub const Plugin = types.Plugin;

// Bytecode module for format, opcodes, emitter
pub const bytecode = @import("bytecode");

// Reflect module for WGSL reflection
pub const reflect = @import("reflect");

// Executor module for MockGPU and Dispatcher (execution tests)
pub const executor = @import("executor");

// ============================================================================
// DSL Frontend (Token, Lexer, Ast, Parser)
// ============================================================================

pub const Token = @import("Token.zig").Token;
pub const Lexer = @import("Lexer.zig").Lexer;
pub const Ast = @import("Ast.zig").Ast;
pub const Node = @import("Ast.zig").Node;
pub const Parser = @import("Parser.zig").Parser;

// ============================================================================
// DSL Backend (Analyzer)
// ============================================================================

pub const Analyzer = @import("Analyzer.zig").Analyzer;

// ============================================================================
// DSL Emitter
// ============================================================================

pub const Emitter = @import("Emitter.zig").Emitter;
pub const Compiler = @import("Compiler.zig").Compiler;
pub const DescriptorEncoder = @import("DescriptorEncoder.zig").DescriptorEncoder;
pub const ImportResolver = @import("ImportResolver.zig").ImportResolver;

// ============================================================================
// Tests (emitter tests only - frontend/backend tested in separate modules)
// ============================================================================

test {
    // Emitter test files
    _ = @import("emitter/test.zig");
    _ = @import("emitter/integration_test.zig");
    _ = @import("emitter/wgsl_imports_test.zig");
    _ = @import("emitter/animation_test.zig");
    _ = @import("emitter/shader_id_test.zig");
    _ = @import("emitter/define_subst_test.zig");
    _ = @import("emitter/import_dedup_test.zig");
    _ = @import("emitter/wgsl_runtime_test.zig");
    _ = @import("emitter/module_reference_test.zig");
    _ = @import("emitter/builtin_inputs_test.zig");
    _ = @import("emitter/minify_uniforms_test.zig");
}
