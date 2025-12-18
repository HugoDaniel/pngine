//! PNGine: A register-based bytecode interpreter for WebGPU.
//!
//! This module provides:
//! - PBSF (S-expression) parsing and PNGB (binary) format
//! - Bytecode execution with pluggable GPU backends
//! - Runtime data generation (procedural arrays)
//!
//! Invariants:
//! - All allocation happens at init, not during frame execution
//! - Bytecode execution is deterministic (seeded PRNG)
//! - Resource IDs are dense indices into fixed-size tables

const std = @import("std");

// PBSF parsing
pub const tokenizer = @import("pbsf/tokenizer.zig");
pub const parser = @import("pbsf/parser.zig");

// Bytecode
pub const string_table = @import("bytecode/string_table.zig");
pub const data_section = @import("bytecode/data_section.zig");
pub const opcodes = @import("bytecode/opcodes.zig");
pub const emitter = @import("bytecode/emitter.zig");
pub const format = @import("bytecode/format.zig");
pub const assembler = @import("bytecode/assembler.zig");
pub const assembler_test = @import("bytecode/assembler_test.zig");

// Executor
pub const mock_gpu = @import("executor/mock_gpu.zig");
pub const dispatcher = @import("executor/dispatcher.zig");
pub const executor_test = @import("executor/executor_test.zig");

// GPU backends
pub const gpu_backends = struct {
    pub const native_gpu = @import("gpu/native_gpu.zig");
    pub const NativeGPU = native_gpu.NativeGPU;
};

// ZIP bundle support
pub const zip = @import("zip.zig");

// PNG embedding/extraction/encoding
pub const png = struct {
    pub const crc32 = @import("png/crc32.zig");
    pub const chunk = @import("png/chunk.zig");
    pub const embed = @import("png/embed.zig");
    pub const extract = @import("png/extract.zig");
    pub const encoder = @import("png/encoder.zig");

    // Re-export main types
    pub const Chunk = chunk.Chunk;
    pub const ChunkType = chunk.ChunkType;
    pub const PNG_SIGNATURE = chunk.PNG_SIGNATURE;

    // Re-export functions
    pub const embedBytecode = embed.embed;
    pub const extractBytecode = extract.extract;
    pub const hasPngb = extract.hasPngb;
    pub const getPngbInfo = extract.getPngbInfo;
    pub const encode = encoder.encode;
    pub const encodeBGRA = encoder.encodeBGRA;
};

// DSL compiler (new macro-based syntax)
pub const dsl = struct {
    pub const Token = @import("dsl/Token.zig").Token;
    pub const Lexer = @import("dsl/Lexer.zig").Lexer;
    pub const Ast = @import("dsl/Ast.zig").Ast;
    pub const Node = @import("dsl/Ast.zig").Node;
    pub const Parser = @import("dsl/Parser.zig").Parser;
    pub const Analyzer = @import("dsl/Analyzer.zig").Analyzer;
    pub const Emitter = @import("dsl/Emitter.zig").Emitter;
    pub const Compiler = @import("dsl/Compiler.zig").Compiler;
    pub const DescriptorEncoder = @import("dsl/DescriptorEncoder.zig").DescriptorEncoder;
    pub const ImportResolver = @import("dsl/ImportResolver.zig").ImportResolver;
    /// High-level compile function
    pub const compile = Compiler.compile;
    pub const compileWithOptions = Compiler.compileWithOptions;
    pub const compileSlice = Compiler.compileSlice;
};

// Re-export DescriptorEncoder at top level for convenience
pub const DescriptorEncoder = dsl.DescriptorEncoder;

// Re-export main types
pub const Tokenizer = tokenizer.Tokenizer;
pub const Token = tokenizer.Token;
pub const Ast = parser.Ast;
pub const parse = parser.parse;

pub const StringTable = string_table.StringTable;
pub const StringId = string_table.StringId;
pub const DataSection = data_section.DataSection;
pub const DataId = data_section.DataId;
pub const OpCode = opcodes.OpCode;
pub const Emitter = emitter.Emitter;
pub const Builder = format.Builder;
pub const Module = format.Module;
pub const Assembler = assembler.Assembler;
pub const assemble = assembler.assemble;

pub const MockGPU = mock_gpu.MockGPU;
pub const Dispatcher = dispatcher.Dispatcher;
pub const MockDispatcher = dispatcher.MockDispatcher;

// ============================================================================
// High-level Pipeline Functions
// ============================================================================

/// Compile PBSF source to PNGB bytes.
/// This is the main entry point for the compilation pipeline.
///
/// Returns owned PNGB bytes that the caller must free.
pub fn compile(allocator: std.mem.Allocator, source: [:0]const u8) ![]u8 {
    // Parse PBSF to AST
    var ast = try parser.parse(allocator, source);
    defer ast.deinit(allocator);

    if (ast.errors.len > 0) {
        return error.ParseError;
    }

    // Assemble AST to PNGB
    return assembler.assemble(allocator, &ast);
}

/// Compile PBSF source to PNGB bytes (non-sentinel version).
/// Makes a copy of the source with sentinel terminator.
pub fn compileSlice(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);
    return compile(allocator, source_z);
}

/// Load PNGB bytes into a Module for execution.
/// Note: The returned module references the input data - caller must ensure
/// data outlives the module.
pub fn load(allocator: std.mem.Allocator, pngb: []const u8) !Module {
    return format.deserialize(allocator, pngb);
}

// Test fixtures
pub const fixtures = struct {
    pub const simple_triangle = @import("fixtures/simple_triangle.zig");
};

test {
    std.testing.refAllDecls(@This());
    // Also run fixture tests
    _ = fixtures.simple_triangle;
    // Run executor tests
    _ = executor_test;
    // Run DSL compiler tests
    _ = @import("dsl/Token.zig");
    _ = @import("dsl/Lexer.zig");
    _ = @import("dsl/Ast.zig");
    _ = @import("dsl/Parser.zig");
    _ = @import("dsl/parser/test.zig");
    _ = @import("dsl/parser/expr_test.zig");
    _ = @import("dsl/Analyzer.zig");
    _ = @import("dsl/analyzer/test.zig");
    _ = @import("dsl/analyzer/expr_test.zig");
    _ = @import("dsl/Emitter.zig");
    _ = @import("dsl/emitter/test.zig");
    _ = @import("dsl/emitter/integration_test.zig");
    _ = @import("dsl/emitter/wgsl_imports_test.zig");
    _ = @import("dsl/Compiler.zig");
    // Run PNG embedding/encoding tests
    _ = @import("png/crc32.zig");
    _ = @import("png/chunk.zig");
    _ = @import("png/embed.zig");
    _ = @import("png/extract.zig");
    _ = @import("png/encoder.zig");
    // Run GPU backend tests
    _ = @import("gpu/native_gpu.zig");
    // Run ZIP tests
    _ = @import("zip.zig");
}

test "compile PBSF to PNGB" {
    const source =
        \\(module "test"
        \\  (data $d:0 "shader code")
        \\  (shader $shd:0 (code $d:0))
        \\  (frame $frm:0 "main"
        \\    (draw 3 1)))
    ;

    const pngb = try compile(std.testing.allocator, source);
    defer std.testing.allocator.free(pngb);

    // Verify magic
    try std.testing.expectEqualStrings("PNGB", pngb[0..4]);

    // Load and verify
    var module = try load(std.testing.allocator, pngb);
    defer module.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 1), module.strings.count());
    try std.testing.expectEqualStrings("main", module.strings.get(@enumFromInt(0)));
}

test "full pipeline: compile and execute" {
    const source =
        \\(module "triangle"
        \\  (data $d:0 "shader code")
        \\  (data $d:1 "{}")
        \\  (shader $shd:0 (code $d:0))
        \\  (render-pipeline $pipe:0
        \\    (shader $shd:0)
        \\    (descriptor $d:1))
        \\  (pass $pass:0 "render"
        \\    (render
        \\      (commands
        \\        (set-pipeline $pipe:0)
        \\        (draw 3 1))))
        \\  (frame $frm:0 "main"
        \\    (exec-pass $pass:0)
        \\    (submit)))
    ;

    // Compile
    const pngb = try compile(std.testing.allocator, source);
    defer std.testing.allocator.free(pngb);

    // Load
    var module = try load(std.testing.allocator, pngb);
    defer module.deinit(std.testing.allocator);

    // Execute with mock GPU
    var gpu: MockGPU = .empty;
    defer gpu.deinit(std.testing.allocator);

    var disp = MockDispatcher.init(std.testing.allocator, &gpu, &module);
    try disp.executeAll(std.testing.allocator);

    // Verify GPU calls: create_shader_module, create_render_pipeline,
    // begin_render_pass, set_pipeline, draw, end_pass,
    // define_frame (no GPU call), exec_pass (no GPU call), submit, end_frame (no GPU call)
    // Actual GPU calls: create_shader_module, create_render_pipeline, begin_render_pass, set_pipeline, draw, end_pass, submit
    try std.testing.expectEqual(@as(usize, 7), gpu.callCount());
}
