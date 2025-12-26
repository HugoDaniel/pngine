//! PNGine Core Types
//!
//! Zero-dependency type definitions shared across all modules.
//! This module enables parallel compilation by breaking circular dependencies.
//!
//! Usage:
//!   const types = @import("types/main.zig");
//!   const OpCode = types.OpCode;
//!   const StringId = types.StringId;

// Re-export all types
pub const opcodes = @import("opcodes.zig");
pub const ids = @import("ids.zig");

// Convenience re-exports
pub const OpCode = opcodes.OpCode;
pub const BufferUsage = opcodes.BufferUsage;
pub const LoadOp = opcodes.LoadOp;
pub const StoreOp = opcodes.StoreOp;
pub const PassType = opcodes.PassType;
pub const ElementType = opcodes.ElementType;
pub const WasmArgType = opcodes.WasmArgType;
pub const WasmReturnType = opcodes.WasmReturnType;

pub const StringId = ids.StringId;
pub const DataId = ids.DataId;

test {
    _ = opcodes;
    _ = ids;
}
