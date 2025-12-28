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
pub const plugins = @import("plugins.zig");
pub const descriptors = @import("descriptors.zig");

// Convenience re-exports
pub const OpCode = opcodes.OpCode;
pub const BufferUsage = opcodes.BufferUsage;
pub const LoadOp = opcodes.LoadOp;
pub const StoreOp = opcodes.StoreOp;
pub const PassType = opcodes.PassType;
pub const WasmArgType = opcodes.WasmArgType;
pub const WasmReturnType = opcodes.WasmReturnType;

pub const StringId = ids.StringId;
pub const DataId = ids.DataId;

pub const PluginSet = plugins.PluginSet;
pub const Plugin = plugins.Plugin;

pub const DescriptorType = descriptors.DescriptorType;
pub const ValueType = descriptors.ValueType;
pub const TextureField = descriptors.TextureField;
pub const SamplerField = descriptors.SamplerField;
pub const BindGroupField = descriptors.BindGroupField;
pub const BindGroupEntryField = descriptors.BindGroupEntryField;
pub const RenderPassField = descriptors.RenderPassField;
pub const ColorAttachmentField = descriptors.ColorAttachmentField;
pub const RenderPipelineField = descriptors.RenderPipelineField;
pub const ComputePipelineField = descriptors.ComputePipelineField;
pub const TextureFormat = descriptors.TextureFormat;
pub const FilterMode = descriptors.FilterMode;
pub const AddressMode = descriptors.AddressMode;
pub const ResourceType = descriptors.ResourceType;
pub const TextureUsage = descriptors.TextureUsage;

test {
    _ = opcodes;
    _ = ids;
    _ = plugins;
    _ = descriptors;
}
