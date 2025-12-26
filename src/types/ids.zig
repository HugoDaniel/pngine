//! Resource ID Types
//!
//! Typed indices for PNGB resources. These are simple enum wrappers around
//! u16 values, providing type safety without runtime overhead.
//!
//! Invariants:
//! - IDs are dense indices starting from 0
//! - Max 65535 resources per type

const std = @import("std");

/// Index into the string table.
pub const StringId = enum(u16) {
    _,

    pub fn toInt(self: StringId) u16 {
        return @intFromEnum(self);
    }

    pub fn fromInt(value: u16) StringId {
        return @enumFromInt(value);
    }
};

/// Index into the data section.
pub const DataId = enum(u16) {
    _,

    pub fn toInt(self: DataId) u16 {
        return @intFromEnum(self);
    }

    pub fn fromInt(value: u16) DataId {
        return @enumFromInt(value);
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "StringId conversion" {
    const id = StringId.fromInt(42);
    try testing.expectEqual(@as(u16, 42), id.toInt());
}

test "DataId conversion" {
    const id = DataId.fromInt(123);
    try testing.expectEqual(@as(u16, 123), id.toInt());
}
