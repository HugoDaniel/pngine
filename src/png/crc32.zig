//! CRC-32 implementation for PNG chunk validation.
//!
//! Uses the standard CRC-32/ISO-HDLC algorithm (same as PNG/zlib).
//! Lookup table generated at comptime for O(1) per-byte updates.
//!
//! ## Invariants
//! - Produces identical output to zlib's crc32() function
//! - Initial value: 0xFFFFFFFF, final XOR: 0xFFFFFFFF
//!
//! ## Example
//! ```zig
//! const crc = crc32.compute("IEND");
//! // crc == 0xAE426082 (fixed value for empty IEND chunk)
//! ```

const std = @import("std");

/// Precomputed CRC-32 lookup table (256 entries).
/// Generated at comptime using the PNG polynomial 0xEDB88320.
const crc_table: [256]u32 = blk: {
    @setEvalBranchQuota(3000);
    var table: [256]u32 = undefined;
    for (0..256) |n| {
        var c: u32 = @intCast(n);
        for (0..8) |_| {
            c = if (c & 1 != 0)
                0xEDB88320 ^ (c >> 1)
            else
                c >> 1;
        }
        table[n] = c;
    }
    break :blk table;
};

/// Calculate CRC-32 over a byte slice.
///
/// Pre-condition: data is a valid slice.
/// Post-condition: returns same value as zlib crc32() for same input.
pub fn compute(data: []const u8) u32 {
    const result = finalize(update(0xFFFFFFFF, data));
    return result;
}

/// Update running CRC with additional data.
///
/// To compute CRC incrementally:
/// ```zig
/// var crc: u32 = 0xFFFFFFFF;
/// crc = update(crc, chunk1);
/// crc = update(crc, chunk2);
/// const final = finalize(crc);
/// ```
pub fn update(crc: u32, data: []const u8) u32 {
    var c = crc;
    for (data) |byte| {
        c = crc_table[(c ^ byte) & 0xFF] ^ (c >> 8);
    }
    return c;
}

/// Finalize CRC computation (apply final XOR).
pub fn finalize(crc: u32) u32 {
    return crc ^ 0xFFFFFFFF;
}

// ============================================================================
// Tests
// ============================================================================
