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
pub const assembler_test = @import("bytecode/assembler_test.zig");

// Executor
pub const mock_gpu = @import("executor/mock_gpu.zig");
pub const dispatcher = @import("executor/dispatcher.zig");
pub const executor_test = @import("executor/executor_test.zig");

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

pub const MockGPU = mock_gpu.MockGPU;
pub const Dispatcher = dispatcher.Dispatcher;
pub const MockDispatcher = dispatcher.MockDispatcher;

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
}
