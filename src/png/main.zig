//! PNG Encoding and Bytecode Embedding Module
//!
//! Standalone module for PNG operations.
//! Zero external dependencies - can compile independently.

pub const crc32 = @import("crc32.zig");
pub const chunk = @import("chunk.zig");
pub const embed = @import("embed.zig");
pub const extract = @import("extract.zig");
pub const encoder = @import("encoder.zig");
pub const decoder = @import("decoder.zig");
pub const compare = @import("compare.zig");
pub const diff = @import("diff.zig");
pub const inflate = @import("inflate.zig");

pub const Chunk = chunk.Chunk;
pub const ChunkType = chunk.ChunkType;
pub const PNG_SIGNATURE = chunk.PNG_SIGNATURE;
