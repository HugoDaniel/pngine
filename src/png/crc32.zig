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

test "CRC-32: IEND chunk has known CRC" {
    // IEND chunk type bytes
    const iend = "IEND";
    const crc = compute(iend);

    // Known fixed CRC for "IEND" (type only, no data)
    try std.testing.expectEqual(@as(u32, 0xAE426082), crc);
}

test "CRC-32: empty data" {
    const crc = compute("");
    // CRC of empty data is 0x00000000
    try std.testing.expectEqual(@as(u32, 0x00000000), crc);
}

test "CRC-32: IHDR chunk type" {
    const crc = compute("IHDR");
    // Pre-computed known value (verified against std.hash.Crc32)
    try std.testing.expectEqual(@as(u32, 0xA8A1AE0A), crc);
}

test "CRC-32: incremental update matches single compute" {
    const data = "Hello, PNG World!";
    const single = compute(data);

    var crc: u32 = 0xFFFFFFFF;
    crc = update(crc, data[0..7]); // "Hello, "
    crc = update(crc, data[7..]); // "PNG World!"
    const incremental = finalize(crc);

    try std.testing.expectEqual(single, incremental);
}

test "CRC-32: PNG signature" {
    // Test with PNG signature bytes
    const data = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    const crc = compute(&data);
    // Verify it produces a valid u32 (basic sanity check)
    try std.testing.expect(crc != 0);
}

test "CRC-32: table has correct first entries" {
    // Verify first few table entries match known values
    try std.testing.expectEqual(@as(u32, 0x00000000), crc_table[0]);
    try std.testing.expectEqual(@as(u32, 0x77073096), crc_table[1]);
    try std.testing.expectEqual(@as(u32, 0xEE0E612C), crc_table[2]);
    try std.testing.expectEqual(@as(u32, 0x990951BA), crc_table[3]);
}

test "CRC-32: all byte values" {
    // Ensure CRC works for all possible byte values
    var data: [256]u8 = undefined;
    for (0..256) |i| {
        data[i] = @intCast(i);
    }
    const crc = compute(&data);
    // Known CRC for bytes 0x00-0xFF in sequence
    try std.testing.expectEqual(@as(u32, 0x29058C73), crc);
}
