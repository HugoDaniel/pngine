//! Executor Standalone Module
//!
//! Entry point for standalone executor tests. Bytecode dispatch and
//! GPU abstraction layer.
//!
//! Excludes:
//! - executor_test.zig (42 tests) - depends on dsl/DescriptorEncoder
//!
//! Test count: 136 tests
//! - dispatcher: 81
//! - mock_gpu: 22
//! - command_buffer: 6
//! - plugins: 4
//! - plugins/core: 3
//! - plugins/render: 3
//! - plugins/compute: 3
//! - plugins/texture: 5
//! - plugins/wasm: 4
//! - plugins/animation: 3
//! - wasm_gpu: 1 (not run in native tests)

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
pub const dispatcher = @import("dispatcher.zig");
pub const mock_gpu = @import("mock_gpu.zig");
pub const command_buffer = @import("command_buffer.zig");
pub const plugins = @import("plugins.zig");
pub const plugin_impl = @import("plugins/main.zig");
pub const variant = @import("variant.zig");

// Re-export main types directly (for common patterns)
pub const Dispatcher = dispatcher.Dispatcher;
pub const MockDispatcher = dispatcher.MockDispatcher;
pub const MockGPU = mock_gpu.MockGPU;
pub const CommandBuffer = command_buffer.CommandBuffer;
pub const Cmd = command_buffer.Cmd;
pub const Variant = variant.Variant;
pub const selectVariant = variant.selectVariant;

// Include tests (excluding executor_test.zig which needs DSL)
test {
    _ = @import("dispatcher.zig");
    _ = @import("mock_gpu.zig");
    _ = @import("command_buffer.zig");
    _ = @import("plugins.zig");
    _ = @import("plugins/main.zig");
    _ = @import("variant.zig");
    // Note: wasm_gpu.zig has WASM-specific extern declarations
    // that don't work in native tests
}
