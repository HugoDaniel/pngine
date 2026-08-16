//! Device Limits Table (Arc-3 §5.3b)
//!
//! Carries authored WebGPU `requiredLimits` from the compiler to the runtime's
//! device-creation step. This is a FRONTEND-ONLY table: parsed by gpu.js (before
//! `requestDevice`) and by the native backend — NEVER by the shipping WASM
//! executor, which is blind to it exactly like the uniform table (offset 32,
//! read only by gpu.js). A hostile or absent table therefore cannot affect the
//! executor; the whole channel adds ZERO executor bytes.
//!
//! ## Format (serialized)
//!
//! ```
//! [count: u8]
//! For each limit (count entries):
//!   [name_string_id: u16 LE]   // WebGPU limit name (EXACT camelCase) in the string table
//!   [value: u64 LE]            // Requested value, verbatim (no clamping to the adapter)
//! ```
//!
//! ## Invariants
//!
//! - EMPTY table = ZERO bytes (not even a count byte). The header's
//!   `has_device_limits` flag then stays clear, so limit-less payloads are
//!   byte-identical to pre-§5.3b output (museum + goldens hold by construction).
//! - `name_string_id` references a valid string-table entry holding the EXACT
//!   WebGPU camelCase spelling → the runtime needs no hardcoded name map, and a
//!   future WebGPU limit is reachable with a schema+emitter change only.
//! - Values are u64: `maxBufferSize` / `maxStorageBufferBindingSize` exceed u32.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// Practical cap on distinct limits (WebGPU defines ~31). Bounds the decode loop
/// and the `count` u8.
pub const MAX_LIMITS: u8 = 64;

/// Bytes per serialized entry: name_string_id(2) + value(8).
const ENTRY_BYTES: usize = 10;

/// One authored device limit.
pub const LimitEntry = struct {
    name_string_id: u16,
    value: u64,
};

/// Authored device limits, in insertion order.
pub const LimitsTable = struct {
    entries: std.ArrayList(LimitEntry),

    pub const empty: LimitsTable = .{ .entries = .empty };

    pub fn deinit(self: *LimitsTable, allocator: Allocator) void {
        self.entries.deinit(allocator);
        self.* = undefined;
    }

    /// Number of authored limits.
    pub fn count(self: *const LimitsTable) u8 {
        assert(self.entries.items.len <= MAX_LIMITS);
        return @intCast(self.entries.items.len);
    }

    /// Append a limit. Pre-condition: room remains under MAX_LIMITS.
    pub fn add(self: *LimitsTable, allocator: Allocator, name_string_id: u16, value: u64) !void {
        assert(self.entries.items.len < MAX_LIMITS);
        try self.entries.append(allocator, .{ .name_string_id = name_string_id, .value = value });
        assert(self.entries.items.len <= MAX_LIMITS);
    }

    /// Serialize. EMPTY → zero bytes (see the byte-identity invariant); the
    /// header omits the section and clears `has_device_limits`.
    pub fn serialize(self: *const LimitsTable, allocator: Allocator) ![]u8 {
        assert(self.entries.items.len <= MAX_LIMITS);
        if (self.entries.items.len == 0) return allocator.alloc(u8, 0);

        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        try result.append(allocator, @intCast(self.entries.items.len));
        for (self.entries.items, 0..) |entry, i| {
            if (i >= MAX_LIMITS) break;
            var name_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &name_buf, entry.name_string_id, .little);
            try result.appendSlice(allocator, &name_buf);
            var val_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &val_buf, entry.value, .little);
            try result.appendSlice(allocator, &val_buf);
        }

        // Post-condition: exact serialized length.
        assert(result.items.len == 1 + @as(usize, self.entries.items.len) * ENTRY_BYTES);
        return result.toOwnedSlice(allocator);
    }
};

/// Deserialize a limits table. `data` is the slice AFTER the animation table,
/// non-empty only when the header's `has_device_limits` flag is set (the caller
/// passes an empty slice otherwise → an empty table).
///
/// Hostile-input safe: a declared count over MAX_LIMITS or a section too short
/// to hold `count` entries is a clean `error.InvalidLimitsTable`, never a trap.
pub fn deserialize(allocator: Allocator, data: []const u8) !LimitsTable {
    var table = LimitsTable{ .entries = .empty };
    errdefer table.deinit(allocator);

    if (data.len == 0) return table;

    const declared = data[0];
    if (declared > MAX_LIMITS) return error.InvalidLimitsTable;

    // The section must hold exactly `declared` fixed-width entries.
    const need = 1 + @as(usize, declared) * ENTRY_BYTES;
    if (data.len < need) return error.InvalidLimitsTable;

    try table.entries.ensureTotalCapacity(allocator, declared);
    var pos: usize = 1;
    for (0..declared) |_| {
        const name_string_id = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;
        const value = std.mem.readInt(u64, data[pos..][0..8], .little);
        pos += 8;
        table.entries.appendAssumeCapacity(.{ .name_string_id = name_string_id, .value = value });
    }

    // Post-condition: consumed exactly `need` bytes into `declared` entries.
    assert(pos == need);
    assert(table.entries.items.len == declared);
    return table;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
