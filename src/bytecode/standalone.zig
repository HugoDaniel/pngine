//! Bytecode Standalone Module
//!
//! Entry point for standalone bytecode tests. Includes all bytecode
//! components that only depend on the types module.
//!
//! Excludes:
//! - assembler.zig (depends on pbsf/parser.zig)
//! - assembler_test.zig (depends on pbsf + fixtures)
//!
//! Test count: 146 tests
//! - string_table: 7
//! - data_section: 12
//! - opcodes: 25
//! - uniform_table: 9
//! - animation_table: 5
//! - emitter: 44
//! - format: 16
//! - wgsl_table_test: 28

const types = @import("types");

// Re-export types for internal use
pub const StringId = types.StringId;
pub const DataId = types.DataId;
pub const OpCode = types.opcodes.OpCode;
pub const PluginSet = types.PluginSet;
pub const Plugin = types.Plugin;

// Re-export bytecode components
pub const StringTable = @import("string_table.zig").StringTable;
pub const DataSection = @import("data_section.zig").DataSection;
pub const opcodes = @import("opcodes.zig");
pub const Emitter = @import("emitter.zig").Emitter;
pub const UniformTable = @import("uniform_table.zig").UniformTable;
pub const AnimationTable = @import("animation_table.zig").AnimationTable;
pub const format = @import("format.zig");

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
