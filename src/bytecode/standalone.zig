//! Bytecode Standalone Module
//!
//! Entry point for standalone bytecode tests. Includes all bytecode
//! components.
//!
//! Test count: ~170 tests total

const types = @import("types");

// Re-export types for internal use
pub const StringId = types.StringId;
pub const DataId = types.DataId;
pub const OpCode = types.opcodes.OpCode;
pub const PluginSet = types.PluginSet;
pub const Plugin = types.Plugin;
/// Shared descriptor types (TLV reader, field/value enums, formats). Re-exported
/// so backends that only import `bytecode` (e.g. wgpu_native) reach them without
/// a separate `types` module wiring.
pub const descriptors = types.descriptors;

// Re-export bytecode modules (for code using bytecode_mod.module.Type pattern)
pub const string_table = @import("string_table.zig");
pub const data_section = @import("data_section.zig");
pub const opcodes = @import("opcodes.zig");
pub const wire_schema = @import("wire_schema.zig");
/// Resource id-space budgets + the wire/spec/implementation classification.
pub const resource_limits = @import("resource_limits.zig");
pub const emitter = @import("emitter.zig");
pub const uniform_table = @import("uniform_table.zig");
pub const animation_table = @import("animation_table.zig");
pub const limits_table = @import("limits_table.zig");
pub const format = @import("format.zig");

// Re-export main types directly (for code using bytecode_mod.Type pattern)
pub const StringTable = string_table.StringTable;
pub const DataSection = data_section.DataSection;
pub const Emitter = emitter.Emitter;
pub const UniformTable = uniform_table.UniformTable;
pub const AnimationTable = animation_table.AnimationTable;

// ============================================================================
// Shared runtime limits — declared once in `resource_limits.zig`, which also
// records WHY each number is what it is (a wire fact, a WebGPU spec fact, or one
// runtime's statically-sized table). Re-exported here because these three names
// predate that file and are spelled `bytecode.X` at every call site.
// ============================================================================

pub const DEFAULT_MAX_PASSES: u32 = resource_limits.DEFAULT_MAX_PASSES;
pub const DEFAULT_MAX_FRAMES: u32 = resource_limits.DEFAULT_MAX_FRAMES;
pub const MAX_EXECUTE_BUNDLES: u32 = resource_limits.MAX_EXECUTE_BUNDLES;

// Include all tests
