//! SJON host test root.
//!
//! Aggregates the SJON-backed compiler/emitter so `zig build test-sjon`
//! discovers every file's tests in one module.
//!
//! Dependencies (wired by build.zig module imports):
//! - sjon:     SJON host (parse, schema, validator, lowering)
//! - types:    PluginSet (executor-variant selection)
//! - bytecode: PNGB format, opcodes, emitter (reused unchanged)
//! - reflect:  WGSL reflection via wgslender (reused unchanged)
//! - executor: MockGPU + Dispatcher (backend for the golden traces, test-sjon-golden)
//! Plus the `pngine_schema` anonymous import (the embedded `schema/pngine.sjon`).

const std = @import("std");

// ============================================================================
// Module Imports (provided by build.zig)
// ============================================================================

pub const sjon = @import("sjon");
pub const types = @import("types");
pub const bytecode = @import("bytecode");
pub const reflect = @import("reflect");
pub const executor = @import("executor");

// ============================================================================
// SJON host surface (schema + emitter + lowering hooks)
// ============================================================================

pub const Compiler = @import("Compiler.zig").Compiler;
pub const Emitter = @import("Emitter.zig").Emitter;
pub const hooks = @import("hooks.zig");

// ============================================================================
// Tests — force discovery of every skeleton file's tests.
// ============================================================================
