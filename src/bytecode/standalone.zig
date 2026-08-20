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
// Shared runtime limits — mirrored by the compiler (emitter pre-flight) and the
// executor. One source of truth so the two cannot drift silently.
// ============================================================================

/// Default number of distinct passes the shipping WASM executor can store — the
/// fixed size of `wasm_entry.zig`'s `pass_ranges` table (`wasm_config` defaults
/// `max_passes` to this). Both sides mirror it: the executor's config default
/// derives from this constant, and the SJON emitter rejects any document that
/// defines more passes. Exceeding it is a silent-drop divergence — the executor
/// stores a range only for `pass_id < max_passes`, so a pass beyond the cap
/// vanishes at load, whereas the reference dispatcher's pass map is unbounded
/// (so the document renders in native `--frame`/tests but loses passes in every
/// browser). A custom executor build MAY raise its own `max_passes`; the
/// frontend targets the default shipping executor.
pub const DEFAULT_MAX_PASSES: u32 = 32;

/// Maximum `(frame …)` definitions the shipping executor indexes by name
/// (`wasm_entry.zig`'s `frame_entries` table). A frame past this count is
/// silently skipped by the executor's frame scan — the same asymmetry as
/// `DEFAULT_MAX_PASSES` (the reference dispatcher has no such table), so the
/// frontend refuses the document instead of shipping one the browser reads
/// differently from the preview.
pub const DEFAULT_MAX_FRAMES: u32 = 64;

/// Maximum render bundles a single `execute_bundles` opcode carries — a hard
/// wire limit fixed by the opcode's `[16]u16` decode buffer in BOTH the shipping
/// executor (`wasm_entry.zig`) and the reference dispatcher. Unlike
/// DEFAULT_MAX_PASSES it is NOT build-configurable: a pass listing more bundles
/// overflows the opcode, so the SJON emitter rejects it outright.
///
/// Derived from the wire schema rather than restated. It was an independent
/// `16` while the schema's own cap for the opcode said 50_000, and the decoders
/// read-and-discarded ids between the two — which is precisely the range where
/// they walked past where `skipParams` stopped (§320).
pub const MAX_EXECUTE_BUNDLES: u32 = wire_schema.repMaxOf(.execute_bundles);

// Include all tests
