//! Executor Standalone Module
//!
//! Entry point for standalone executor tests. Bytecode dispatch and
//! GPU abstraction layer.
//!
//! Excludes:
//! - executor_test.zig (42 tests) - depends on dsl/DescriptorEncoder
//!
//! Test count: 114 tests
//! - dispatcher: 81
//! - mock_gpu: 22
//! - command_buffer: 6
//! - plugins: 4
//! - wasm_gpu: 1

const std = @import("std");

// Import from bytecode module (provided by build.zig)
pub const bytecode = @import("bytecode");

// Re-export bytecode types for internal use
pub const format = bytecode.format;
pub const opcodes = bytecode.opcodes;
pub const StringId = bytecode.StringId;
pub const DataId = bytecode.DataId;
pub const StringTable = bytecode.StringTable;
pub const DataSection = bytecode.DataSection;
pub const UniformTable = bytecode.UniformTable;
pub const AnimationTable = bytecode.AnimationTable;
pub const Emitter = bytecode.Emitter;
pub const PluginSet = bytecode.PluginSet;
pub const Plugin = bytecode.Plugin;

// Re-export executor components
pub const Dispatcher = @import("dispatcher.zig").Dispatcher;
pub const MockDispatcher = @import("dispatcher.zig").MockDispatcher;
pub const MockGPU = @import("mock_gpu.zig").MockGPU;
pub const CommandBuffer = @import("command_buffer.zig").CommandBuffer;
pub const Cmd = @import("command_buffer.zig").Cmd;
pub const plugins = @import("plugins.zig");

// Include tests (excluding executor_test.zig which needs DSL)
test {
    _ = @import("dispatcher.zig");
    _ = @import("mock_gpu.zig");
    _ = @import("command_buffer.zig");
    _ = @import("plugins.zig");
    // Note: wasm_gpu.zig has WASM-specific extern declarations
    // that don't work in native tests
}
