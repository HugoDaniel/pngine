//! Bytecode Standalone Module
//!
//! Entry point for standalone bytecode tests. Includes all bytecode
//! components. Note: assembler depends on pbsf but is included for
//! module boundary consistency (it can still run standalone tests).
//!
//! Test count: ~170 tests total

const types = @import("types");

// Re-export types for internal use
pub const StringId = types.StringId;
pub const DataId = types.DataId;
pub const OpCode = types.opcodes.OpCode;
pub const PluginSet = types.PluginSet;
pub const Plugin = types.Plugin;

// Re-export bytecode modules (for code using bytecode_mod.module.Type pattern)
pub const string_table = @import("string_table.zig");
pub const data_section = @import("data_section.zig");
pub const opcodes = @import("opcodes.zig");
pub const emitter = @import("emitter.zig");
pub const uniform_table = @import("uniform_table.zig");
pub const animation_table = @import("animation_table.zig");
pub const format = @import("format.zig");

// Re-export main types directly (for code using bytecode_mod.Type pattern)
pub const StringTable = string_table.StringTable;
pub const DataSection = data_section.DataSection;
pub const Emitter = emitter.Emitter;
pub const UniformTable = uniform_table.UniformTable;
pub const AnimationTable = animation_table.AnimationTable;

// Include all tests
test {
    _ = @import("string_table.zig");
    _ = @import("data_section.zig");
    _ = @import("opcodes.zig");
    _ = @import("uniform_table.zig");
    _ = @import("animation_table.zig");
    _ = @import("emitter.zig");
    _ = @import("format.zig");
    _ = @import("wgsl_table_test.zig");
}
