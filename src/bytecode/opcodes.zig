//! PNGB Opcode Definitions and Varint Encoding
//!
//! Re-exports type definitions from types/opcodes.zig and provides
//! varint encoding utilities for bytecode serialization.
//!
//! For type definitions only, import types/opcodes.zig directly.

const std = @import("std");
const assert = std.debug.assert;

// Re-export all types from the types module
const types = @import("types").opcodes;
pub const OpCode = types.OpCode;
pub const BufferUsage = types.BufferUsage;
pub const LoadOp = types.LoadOp;
pub const StoreOp = types.StoreOp;
pub const PassType = types.PassType;
pub const WasmArgType = types.WasmArgType;
pub const WasmReturnType = types.WasmReturnType;
/// Opcode → required executor plugin (drives variant selection); see types.
pub const pluginForOpcode = types.pluginForOpcode;
/// `create_bind_group`'s `layout_id` id-space discriminator; see types.
pub const BIND_GROUP_LAYOUT_TAG = types.BIND_GROUP_LAYOUT_TAG;
pub const layoutIdIsBindGroupLayout = types.layoutIdIsBindGroupLayout;
pub const layoutIdValue = types.layoutIdValue;
pub const tagBindGroupLayoutId = types.tagBindGroupLayoutId;
pub const PluginSet = @import("types").PluginSet;
pub const Plugin = @import("types").Plugin;

// ============================================================================
// Variable-Length Integer Encoding (LEB128-style)
// ============================================================================

/// Encode a varint to buffer.
///
/// Returns number of bytes written (1, 2, or 4).
///
/// Encoding scheme (LEB128-style with 2/4 byte alignment):
/// - 0-127: 0xxxxxxx (1 byte, values 0x00-0x7F)
/// - 128-16383: 10xxxxxx xxxxxxxx (2 bytes, big-endian payload)
/// - 16384+: 11xxxxxx xxxxxxxx xxxxxxxx xxxxxxxx (4 bytes, big-endian payload)
///
/// Complexity: O(1).
pub fn encodeVarint(value: u32, buffer: *[4]u8) u8 {
    if (value < 128) {
        buffer[0] = @intCast(value);
        return 1;
    } else if (value < 16384) {
        buffer[0] = 0x80 | @as(u8, @intCast(value >> 8));
        buffer[1] = @intCast(value & 0xFF);
        return 2;
    } else {
        buffer[0] = 0xC0 | @as(u8, @intCast(value >> 24));
        buffer[1] = @intCast((value >> 16) & 0xFF);
        buffer[2] = @intCast((value >> 8) & 0xFF);
        buffer[3] = @intCast(value & 0xFF);
        return 4;
    }
}

/// Decode a varint from buffer.
///
/// Returns value and number of bytes consumed (1, 2, or 4).
/// Pre-condition: buffer.len >= 1 (at minimum).
/// Pre-condition: buffer.len >= encoded length (asserted at runtime).
///
/// Complexity: O(1).
pub fn decode_varint(buffer: []const u8) struct { value: u32, len: u8 } {
    // Pre-condition: buffer has at least 1 byte
    assert(buffer.len >= 1);

    const first = buffer[0];

    if (first & 0x80 == 0) {
        // 1 byte: 0xxxxxxx
        return .{ .value = first, .len = 1 };
    } else if (first & 0xC0 == 0x80) {
        // 2 bytes: 10xxxxxx xxxxxxxx
        assert(buffer.len >= 2);
        const high: u32 = first & 0x3F;
        const low: u32 = buffer[1];
        return .{ .value = (high << 8) | low, .len = 2 };
    } else {
        // 4 bytes: 11xxxxxx xxxxxxxx xxxxxxxx xxxxxxxx
        assert(buffer.len >= 4);
        const b0: u32 = first & 0x3F;
        const b1: u32 = buffer[1];
        const b2: u32 = buffer[2];
        const b3: u32 = buffer[3];
        return .{ .value = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3, .len = 4 };
    }
}

/// Length-tolerant varint decode for scanning possibly-truncated buffers.
///
/// `decode_varint` asserts the buffer holds the full encoding; the CLI decoders
/// (flat.zig, js_codegen.zig) walk raw bytecode that may end mid-instruction, so
/// they need a variant that returns `.{ .value = 0, .len = 0 }` on a short
/// buffer instead of asserting. This is the single source both share — the bit
/// math still lives once, in `decode_varint`.
///
/// Complexity: O(1).
pub fn decode_varint_safe(buffer: []const u8) struct { value: u32, len: u8 } {
    if (buffer.len == 0) return .{ .value = 0, .len = 0 };
    const first = buffer[0];
    const need: usize = if (first & 0x80 == 0) 1 else if (first & 0xC0 == 0x80) 2 else 4;
    if (buffer.len < need) return .{ .value = 0, .len = 0 };
    // Length is now guaranteed; delegate the decode to the canonical routine.
    const r = decode_varint(buffer);
    return .{ .value = r.value, .len = r.len };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

// ============================================================================
// New Opcode Tests (create_image_bitmap, copy_external_image_to_texture)
// ============================================================================

// ============================================================================
// WASM Opcode Tests
// ============================================================================
