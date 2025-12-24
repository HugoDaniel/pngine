//! PNG Loader for Native Viewer
//!
//! Loads PNG files and extracts embedded executor payloads.
//!
//! ## Payload Format (v5)
//! ```
//! Header (40 bytes):
//!   magic: "PNGB"
//!   version: u16 (5)
//!   flags: u16 (bit 0 = has_embedded_executor)
//!   plugins: u8
//!   reserved: [3]u8
//!   executor_offset: u32
//!   executor_length: u32
//!   string_table_offset: u32
//!   data_offset: u32
//!   wgsl_offset: u32
//!   uniform_offset: u32
//!   animation_offset: u32
//! Executor Section (if embedded)
//! Bytecode Section
//! String Table
//! Data Section
//! ```
//!
//! ## Invariants
//! - Returns valid payload info or error
//! - Caller owns allocated memory

const std = @import("std");
const pngine = @import("pngine");

const PNGB_MAGIC = [4]u8{ 'P', 'N', 'G', 'B' };
const VERSION_V5: u16 = 5;
const VERSION_V4: u16 = 4;
const HEADER_SIZE_V5: u32 = 40;
const HEADER_SIZE_V4: u32 = 28;

const FLAG_HAS_EMBEDDED_EXECUTOR: u16 = 0x01;
const FLAG_HAS_ANIMATION_TABLE: u16 = 0x02;

pub const Error = error{
    InvalidPng,
    NoPngbChunk,
    InvalidPngbVersion,
    InvalidPngbFormat,
    DecompressionFailed,
    OutOfMemory,
    FileNotFound,
    IoError,
};

/// Parsed payload information.
pub const Payload = struct {
    /// PNGB format version (4 or 5)
    version: u16,
    /// Flags from header
    flags: u16,
    /// Plugin bitfield
    plugins: u8,
    /// Whether executor is embedded
    has_embedded_executor: bool,
    /// Whether animation table is present
    has_animation_table: bool,
    /// Embedded executor WASM data (empty if not embedded)
    executor_data: []const u8,
    /// Bytecode section
    bytecode: []const u8,
    /// Raw PNGB data for module loading
    raw_data: []const u8,
    /// Owns the raw data allocation
    owns_data: bool,

    /// Free allocated data.
    pub fn deinit(self: *const Payload, allocator: std.mem.Allocator) void {
        if (self.owns_data) {
            allocator.free(self.raw_data);
        }
    }
};

/// Load PNG file and extract payload.
///
/// Pre-condition: path points to valid PNG file
/// Post-condition: Returns payload info, caller owns memory
pub fn loadPNG(allocator: std.mem.Allocator, path: []const u8) Error!Payload {
    // Open file
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => Error.FileNotFound,
            else => Error.IoError,
        };
    };
    defer file.close();

    // Get file size
    const stat = file.stat() catch return Error.IoError;
    if (stat.size > 10 * 1024 * 1024) return Error.IoError;
    const size: usize = @intCast(stat.size);

    // Read file contents
    const png_data = allocator.alloc(u8, size) catch return Error.OutOfMemory;
    errdefer allocator.free(png_data);

    // Read in a loop (standard pattern)
    var bytes_read: usize = 0;
    while (bytes_read < size) {
        const n = file.read(png_data[bytes_read..]) catch return Error.IoError;
        if (n == 0) break;
        bytes_read += n;
    }
    if (bytes_read != size) return Error.IoError;
    defer allocator.free(png_data);

    // Extract PNGB from PNG
    const pngb_data = pngine.png.extractBytecode(allocator, png_data) catch |err| {
        return switch (err) {
            error.InvalidPng => Error.InvalidPng,
            error.NoPngbChunk => Error.NoPngbChunk,
            error.InvalidPngbFormat => Error.InvalidPngbFormat,
            error.DecompressionFailed => Error.DecompressionFailed,
            error.OutOfMemory => Error.OutOfMemory,
            else => Error.InvalidPngbFormat,
        };
    };

    // Parse payload
    return parsePayload(pngb_data);
}

/// Parse PNGB payload data.
///
/// Pre-condition: data is valid PNGB payload
/// Post-condition: Returns parsed payload info
pub fn parsePayload(data: []const u8) Error!Payload {
    // Check minimum size
    if (data.len < HEADER_SIZE_V4) {
        return Error.InvalidPngbFormat;
    }

    // Check magic
    if (!std.mem.eql(u8, data[0..4], &PNGB_MAGIC)) {
        return Error.InvalidPngbFormat;
    }

    // Read version
    const version = std.mem.readInt(u16, data[4..6], .little);

    if (version == VERSION_V5) {
        return parseV5Payload(data);
    } else if (version == VERSION_V4) {
        return parseV4Payload(data);
    } else {
        return Error.InvalidPngbVersion;
    }
}

/// Parse v5 payload (40-byte header with embedded executor support).
fn parseV5Payload(data: []const u8) Error!Payload {
    if (data.len < HEADER_SIZE_V5) {
        return Error.InvalidPngbFormat;
    }

    const flags = std.mem.readInt(u16, data[6..8], .little);
    const plugins = data[8];
    const executor_offset = std.mem.readInt(u32, data[12..16], .little);
    const executor_length = std.mem.readInt(u32, data[16..20], .little);
    const string_table_offset = std.mem.readInt(u32, data[20..24], .little);

    const has_embedded_executor = (flags & FLAG_HAS_EMBEDDED_EXECUTOR) != 0;
    const has_animation_table = (flags & FLAG_HAS_ANIMATION_TABLE) != 0;

    // Calculate bytecode boundaries
    const bytecode_start = if (has_embedded_executor)
        executor_offset + executor_length
    else
        HEADER_SIZE_V5;
    const bytecode_end = string_table_offset;

    // Validate boundaries
    if (bytecode_start > data.len or bytecode_end > data.len or bytecode_start > bytecode_end) {
        return Error.InvalidPngbFormat;
    }

    // Extract executor data
    const executor_data = if (has_embedded_executor and executor_length > 0)
        data[executor_offset .. executor_offset + executor_length]
    else
        &[0]u8{};

    return Payload{
        .version = VERSION_V5,
        .flags = flags,
        .plugins = plugins,
        .has_embedded_executor = has_embedded_executor,
        .has_animation_table = has_animation_table,
        .executor_data = executor_data,
        .bytecode = data[bytecode_start..bytecode_end],
        .raw_data = data,
        .owns_data = true,
    };
}

/// Parse v4 payload (28-byte header, no embedded executor).
fn parseV4Payload(data: []const u8) Error!Payload {
    if (data.len < HEADER_SIZE_V4) {
        return Error.InvalidPngbFormat;
    }

    const flags = std.mem.readInt(u16, data[6..8], .little);
    const string_table_offset = std.mem.readInt(u32, data[8..12], .little);

    // Bytecode is between header and string table
    const bytecode_start = HEADER_SIZE_V4;
    const bytecode_end = string_table_offset;

    if (bytecode_end > data.len or bytecode_start > bytecode_end) {
        return Error.InvalidPngbFormat;
    }

    return Payload{
        .version = VERSION_V4,
        .flags = flags,
        .plugins = 0x01, // Core only for v4
        .has_embedded_executor = false,
        .has_animation_table = false,
        .executor_data = &[0]u8{},
        .bytecode = data[bytecode_start..bytecode_end],
        .raw_data = data,
        .owns_data = true,
    };
}

/// Get plugin name from bitfield.
pub fn getPluginName(plugins: u8) []const u8 {
    return switch (plugins) {
        0x01 => "core",
        0x03 => "core-render",
        0x05 => "core-compute",
        0x07 => "core-render-compute",
        0x09 => "core-wasm",
        0x0B => "core-render-wasm",
        0x0F => "core-render-compute-wasm",
        0x11 => "core-anim",
        0x13 => "core-render-anim",
        0x1F => "core-render-compute-wasm-anim",
        0x3F => "full",
        else => "custom",
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parsePayload: v5 minimal header" {
    // Build minimal v5 header
    var header: [HEADER_SIZE_V5]u8 = undefined;
    @memset(&header, 0);

    // Magic
    @memcpy(header[0..4], &PNGB_MAGIC);
    // Version 5
    std.mem.writeInt(u16, header[4..6], VERSION_V5, .little);
    // Flags = 0
    std.mem.writeInt(u16, header[6..8], 0, .little);
    // Plugins = core
    header[8] = 0x01;
    // String table at header end
    std.mem.writeInt(u32, header[20..24], HEADER_SIZE_V5, .little);

    const payload = try parsePayload(&header);

    try testing.expectEqual(@as(u16, 5), payload.version);
    try testing.expect(!payload.has_embedded_executor);
    try testing.expectEqual(@as(usize, 0), payload.bytecode.len);
}

test "parsePayload: v5 with embedded executor flag" {
    var data: [60]u8 = undefined;
    @memset(&data, 0);

    // Magic
    @memcpy(data[0..4], &PNGB_MAGIC);
    // Version 5
    std.mem.writeInt(u16, data[4..6], VERSION_V5, .little);
    // Flags = has_embedded_executor
    std.mem.writeInt(u16, data[6..8], FLAG_HAS_EMBEDDED_EXECUTOR, .little);
    // Plugins
    data[8] = 0x03;
    // Executor at offset 40, length 10
    std.mem.writeInt(u32, data[12..16], 40, .little);
    std.mem.writeInt(u32, data[16..20], 10, .little);
    // String table at 55
    std.mem.writeInt(u32, data[20..24], 55, .little);

    // Fill executor data
    @memcpy(data[40..50], "WASMMODULE");
    // Bytecode from 50-55
    @memcpy(data[50..55], "BCODE");

    const payload = try parsePayload(&data);

    try testing.expectEqual(@as(u16, 5), payload.version);
    try testing.expect(payload.has_embedded_executor);
    try testing.expectEqual(@as(usize, 10), payload.executor_data.len);
    try testing.expectEqualStrings("WASMMODULE", payload.executor_data);
    try testing.expectEqual(@as(usize, 5), payload.bytecode.len);
    try testing.expectEqualStrings("BCODE", payload.bytecode);
}

test "parsePayload: v4 header" {
    var header: [HEADER_SIZE_V4]u8 = undefined;
    @memset(&header, 0);

    // Magic
    @memcpy(header[0..4], &PNGB_MAGIC);
    // Version 4
    std.mem.writeInt(u16, header[4..6], VERSION_V4, .little);
    // String table at header end
    std.mem.writeInt(u32, header[8..12], HEADER_SIZE_V4, .little);

    const payload = try parsePayload(&header);

    try testing.expectEqual(@as(u16, 4), payload.version);
    try testing.expect(!payload.has_embedded_executor);
}

test "parsePayload: invalid magic" {
    var data: [40]u8 = undefined;
    @memset(&data, 0);
    @memcpy(data[0..4], "XXXX");

    try testing.expectError(Error.InvalidPngbFormat, parsePayload(&data));
}

test "parsePayload: unsupported version" {
    var data: [40]u8 = undefined;
    @memset(&data, 0);
    @memcpy(data[0..4], &PNGB_MAGIC);
    std.mem.writeInt(u16, data[4..6], 3, .little); // Unsupported version

    try testing.expectError(Error.InvalidPngbVersion, parsePayload(&data));
}

test "getPluginName: common combinations" {
    try testing.expectEqualStrings("core", getPluginName(0x01));
    try testing.expectEqualStrings("core-render", getPluginName(0x03));
    try testing.expectEqualStrings("core-compute", getPluginName(0x05));
    try testing.expectEqualStrings("core-render-compute", getPluginName(0x07));
    try testing.expectEqualStrings("full", getPluginName(0x3F));
    try testing.expectEqualStrings("custom", getPluginName(0x42));
}

// ============================================================================
// Edge Case Tests
// ============================================================================

test "parsePayload: data too short for v4 header" {
    var data: [HEADER_SIZE_V4 - 1]u8 = undefined;
    @memset(&data, 0);
    @memcpy(data[0..4], &PNGB_MAGIC);

    try testing.expectError(Error.InvalidPngbFormat, parsePayload(&data));
}

test "parsePayload: data too short for v5 header" {
    // Valid v4 size but claims to be v5
    var data: [HEADER_SIZE_V4]u8 = undefined;
    @memset(&data, 0);
    @memcpy(data[0..4], &PNGB_MAGIC);
    std.mem.writeInt(u16, data[4..6], VERSION_V5, .little);

    try testing.expectError(Error.InvalidPngbFormat, parsePayload(&data));
}

test "parsePayload: exactly minimum v4 size" {
    var data: [HEADER_SIZE_V4]u8 = undefined;
    @memset(&data, 0);
    @memcpy(data[0..4], &PNGB_MAGIC);
    std.mem.writeInt(u16, data[4..6], VERSION_V4, .little);
    std.mem.writeInt(u32, data[8..12], HEADER_SIZE_V4, .little);

    const payload = try parsePayload(&data);
    try testing.expectEqual(@as(u16, 4), payload.version);
    try testing.expectEqual(@as(usize, 0), payload.bytecode.len);
}

test "parsePayload: exactly minimum v5 size" {
    var data: [HEADER_SIZE_V5]u8 = undefined;
    @memset(&data, 0);
    @memcpy(data[0..4], &PNGB_MAGIC);
    std.mem.writeInt(u16, data[4..6], VERSION_V5, .little);
    std.mem.writeInt(u32, data[20..24], HEADER_SIZE_V5, .little);

    const payload = try parsePayload(&data);
    try testing.expectEqual(@as(u16, 5), payload.version);
    try testing.expectEqual(@as(usize, 0), payload.bytecode.len);
}

test "parsePayload: v5 with animation flag set" {
    var data: [HEADER_SIZE_V5]u8 = undefined;
    @memset(&data, 0);
    @memcpy(data[0..4], &PNGB_MAGIC);
    std.mem.writeInt(u16, data[4..6], VERSION_V5, .little);
    std.mem.writeInt(u16, data[6..8], FLAG_HAS_ANIMATION_TABLE, .little);
    std.mem.writeInt(u32, data[20..24], HEADER_SIZE_V5, .little);

    const payload = try parsePayload(&data);
    try testing.expect(payload.has_animation_table);
    try testing.expect(!payload.has_embedded_executor);
}

test "parsePayload: v5 with both flags set" {
    var data: [50]u8 = undefined;
    @memset(&data, 0);
    @memcpy(data[0..4], &PNGB_MAGIC);
    std.mem.writeInt(u16, data[4..6], VERSION_V5, .little);
    std.mem.writeInt(u16, data[6..8], FLAG_HAS_EMBEDDED_EXECUTOR | FLAG_HAS_ANIMATION_TABLE, .little);
    std.mem.writeInt(u32, data[12..16], HEADER_SIZE_V5, .little); // executor_offset
    std.mem.writeInt(u32, data[16..20], 5, .little); // executor_length
    std.mem.writeInt(u32, data[20..24], 50, .little); // string_table_offset

    const payload = try parsePayload(&data);
    try testing.expect(payload.has_embedded_executor);
    try testing.expect(payload.has_animation_table);
    try testing.expectEqual(@as(usize, 5), payload.executor_data.len);
}

test "parsePayload: unsupported versions" {
    const unsupported_versions = [_]u16{ 0, 1, 2, 3, 6, 7, 100, 255, 65535 };

    for (unsupported_versions) |version| {
        var data: [HEADER_SIZE_V5]u8 = undefined;
        @memset(&data, 0);
        @memcpy(data[0..4], &PNGB_MAGIC);
        std.mem.writeInt(u16, data[4..6], version, .little);

        try testing.expectError(Error.InvalidPngbVersion, parsePayload(&data));
    }
}

test "parsePayload: all plugin combinations" {
    // Test each plugin bit individually
    const plugin_bits = [_]u8{ 0x01, 0x02, 0x04, 0x08, 0x10, 0x20 };

    for (plugin_bits) |bit| {
        var data: [HEADER_SIZE_V5]u8 = undefined;
        @memset(&data, 0);
        @memcpy(data[0..4], &PNGB_MAGIC);
        std.mem.writeInt(u16, data[4..6], VERSION_V5, .little);
        data[8] = bit;
        std.mem.writeInt(u32, data[20..24], HEADER_SIZE_V5, .little);

        const payload = try parsePayload(&data);
        try testing.expectEqual(bit, payload.plugins);
    }
}

test "parsePayload: v5 invalid string_table_offset beyond data" {
    var data: [HEADER_SIZE_V5]u8 = undefined;
    @memset(&data, 0);
    @memcpy(data[0..4], &PNGB_MAGIC);
    std.mem.writeInt(u16, data[4..6], VERSION_V5, .little);
    // String table offset beyond data length
    std.mem.writeInt(u32, data[20..24], HEADER_SIZE_V5 + 100, .little);

    try testing.expectError(Error.InvalidPngbFormat, parsePayload(&data));
}

test "parsePayload: v4 invalid string_table_offset beyond data" {
    var data: [HEADER_SIZE_V4]u8 = undefined;
    @memset(&data, 0);
    @memcpy(data[0..4], &PNGB_MAGIC);
    std.mem.writeInt(u16, data[4..6], VERSION_V4, .little);
    // String table offset beyond data length
    std.mem.writeInt(u32, data[8..12], HEADER_SIZE_V4 + 100, .little);

    try testing.expectError(Error.InvalidPngbFormat, parsePayload(&data));
}

test "parsePayload: v5 bytecode_start > bytecode_end" {
    var data: [HEADER_SIZE_V5]u8 = undefined;
    @memset(&data, 0);
    @memcpy(data[0..4], &PNGB_MAGIC);
    std.mem.writeInt(u16, data[4..6], VERSION_V5, .little);
    // String table before header end (invalid)
    std.mem.writeInt(u32, data[20..24], HEADER_SIZE_V5 - 10, .little);

    try testing.expectError(Error.InvalidPngbFormat, parsePayload(&data));
}

// ============================================================================
// Property-Based Tests
// ============================================================================

test "parsePayload: property - bytecode region is valid slice" {
    // Property: bytecode start <= bytecode end <= data.len
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    const random = prng.random();

    for (0..100) |_| {
        // Random bytecode size (0-200 bytes)
        const bytecode_size = random.intRangeAtMost(u32, 0, 200);
        const total_size = HEADER_SIZE_V5 + bytecode_size;

        var data = testing.allocator.alloc(u8, total_size) catch continue;
        defer testing.allocator.free(data);
        @memset(data, 0);

        @memcpy(data[0..4], &PNGB_MAGIC);
        std.mem.writeInt(u16, data[4..6], VERSION_V5, .little);
        std.mem.writeInt(u32, data[20..24], total_size, .little);

        const payload = try parsePayload(data);

        // Property: bytecode is valid slice within data
        try testing.expect(payload.bytecode.len == bytecode_size);
        try testing.expect(@intFromPtr(payload.bytecode.ptr) >= @intFromPtr(data.ptr));
        try testing.expect(@intFromPtr(payload.bytecode.ptr) + payload.bytecode.len <= @intFromPtr(data.ptr) + data.len);
    }
}

test "parsePayload: property - executor region doesn't overlap bytecode" {
    // Property: executor and bytecode regions are disjoint
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    const random = prng.random();

    for (0..100) |_| {
        const executor_size = random.intRangeAtMost(u32, 1, 100);
        const bytecode_size = random.intRangeAtMost(u32, 0, 100);
        const total_size = HEADER_SIZE_V5 + executor_size + bytecode_size;

        var data = testing.allocator.alloc(u8, total_size) catch continue;
        defer testing.allocator.free(data);
        @memset(data, 0);

        @memcpy(data[0..4], &PNGB_MAGIC);
        std.mem.writeInt(u16, data[4..6], VERSION_V5, .little);
        std.mem.writeInt(u16, data[6..8], FLAG_HAS_EMBEDDED_EXECUTOR, .little);
        std.mem.writeInt(u32, data[12..16], HEADER_SIZE_V5, .little); // executor_offset
        std.mem.writeInt(u32, data[16..20], executor_size, .little); // executor_length
        std.mem.writeInt(u32, data[20..24], total_size, .little); // string_table_offset

        const payload = try parsePayload(data);

        // Property: regions don't overlap
        const exec_start = @intFromPtr(payload.executor_data.ptr);
        const exec_end = exec_start + payload.executor_data.len;
        const bc_start = @intFromPtr(payload.bytecode.ptr);
        const bc_end = bc_start + payload.bytecode.len;

        // Either executor ends before bytecode starts, or bytecode is empty
        try testing.expect(exec_end <= bc_start or payload.bytecode.len == 0);
        _ = bc_end;
    }
}

test "parsePayload: property - version preserved in output" {
    // Property: output version matches input version
    const versions = [_]u16{ VERSION_V4, VERSION_V5 };

    for (versions) |version| {
        const header_size: u32 = if (version == VERSION_V5) HEADER_SIZE_V5 else HEADER_SIZE_V4;
        var data = testing.allocator.alloc(u8, header_size) catch continue;
        defer testing.allocator.free(data);
        @memset(data, 0);

        @memcpy(data[0..4], &PNGB_MAGIC);
        std.mem.writeInt(u16, data[4..6], version, .little);
        if (version == VERSION_V5) {
            std.mem.writeInt(u32, data[20..24], header_size, .little);
        } else {
            std.mem.writeInt(u32, data[8..12], header_size, .little);
        }

        const payload = try parsePayload(data);
        try testing.expectEqual(version, payload.version);
    }
}

// ============================================================================
// Fuzz Tests
// ============================================================================

test "fuzz parsePayload: never crashes on random input" {
    try std.testing.fuzz({}, fuzzParsePayload, .{
        .corpus = &.{
            // Valid minimal v4
            "PNGB\x04\x00\x00\x00\x1c\x00\x00\x00",
            // Valid minimal v5
            "PNGB\x05\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x28\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
            // Invalid magic
            "XXXX\x05\x00",
            // Too short
            "PNG",
            // Invalid version
            "PNGB\x03\x00",
        },
    });
}

fn fuzzParsePayload(_: void, input: []const u8) !void {
    // Property: parsePayload never crashes, only returns errors or valid payload
    const result = parsePayload(input);

    if (result) |payload| {
        // If parsing succeeds, validate invariants
        try std.testing.expect(payload.version == VERSION_V4 or payload.version == VERSION_V5);
        try std.testing.expect(payload.raw_data.ptr == input.ptr);
        try std.testing.expect(payload.raw_data.len == input.len);

        // Bytecode must be within bounds
        if (payload.bytecode.len > 0) {
            const bc_start = @intFromPtr(payload.bytecode.ptr);
            const data_start = @intFromPtr(input.ptr);
            const data_end = data_start + input.len;
            try std.testing.expect(bc_start >= data_start);
            try std.testing.expect(bc_start + payload.bytecode.len <= data_end);
        }

        // Executor must be within bounds (if present)
        if (payload.executor_data.len > 0) {
            const exec_start = @intFromPtr(payload.executor_data.ptr);
            const data_start = @intFromPtr(input.ptr);
            const data_end = data_start + input.len;
            try std.testing.expect(exec_start >= data_start);
            try std.testing.expect(exec_start + payload.executor_data.len <= data_end);
        }
    } else |err| {
        // Errors are expected for invalid input - just ensure it's a known error
        try std.testing.expect(err == Error.InvalidPngbFormat or
            err == Error.InvalidPngbVersion);
    }
}

test "fuzz parsePayload: modified valid headers" {
    // Start with valid header and mutate bytes
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    const random = prng.random();

    for (0..200) |_| {
        // Start with valid v5 header
        var data: [60]u8 = undefined;
        @memset(&data, 0);
        @memcpy(data[0..4], &PNGB_MAGIC);
        std.mem.writeInt(u16, data[4..6], VERSION_V5, .little);
        std.mem.writeInt(u32, data[20..24], 60, .little);

        // Randomly mutate 1-5 bytes
        const mutations = random.intRangeAtMost(u8, 1, 5);
        for (0..mutations) |_| {
            const idx = random.intRangeLessThan(usize, 0, data.len);
            data[idx] = random.int(u8);
        }

        // Should not crash
        _ = parsePayload(&data) catch {};
    }
}

// ============================================================================
// getPluginName Tests
// ============================================================================

test "getPluginName: all mapped values" {
    const mappings = [_]struct { plugins: u8, name: []const u8 }{
        .{ .plugins = 0x01, .name = "core" },
        .{ .plugins = 0x03, .name = "core-render" },
        .{ .plugins = 0x05, .name = "core-compute" },
        .{ .plugins = 0x07, .name = "core-render-compute" },
        .{ .plugins = 0x09, .name = "core-wasm" },
        .{ .plugins = 0x0B, .name = "core-render-wasm" },
        .{ .plugins = 0x0F, .name = "core-render-compute-wasm" },
        .{ .plugins = 0x11, .name = "core-anim" },
        .{ .plugins = 0x13, .name = "core-render-anim" },
        .{ .plugins = 0x1F, .name = "core-render-compute-wasm-anim" },
        .{ .plugins = 0x3F, .name = "full" },
    };

    for (mappings) |m| {
        try testing.expectEqualStrings(m.name, getPluginName(m.plugins));
    }
}

test "getPluginName: unmapped returns custom" {
    // Test values that aren't in the switch
    const unmapped = [_]u8{ 0x00, 0x02, 0x04, 0x06, 0x08, 0x0A, 0x40, 0x80, 0xFF };

    for (unmapped) |plugins| {
        try testing.expectEqualStrings("custom", getPluginName(plugins));
    }
}

// ============================================================================
// Payload Struct Tests
// ============================================================================

test "Payload.deinit: handles owns_data=false" {
    var data: [HEADER_SIZE_V5]u8 = undefined;
    @memset(&data, 0);
    @memcpy(data[0..4], &PNGB_MAGIC);
    std.mem.writeInt(u16, data[4..6], VERSION_V5, .little);
    std.mem.writeInt(u32, data[20..24], HEADER_SIZE_V5, .little);

    var payload = try parsePayload(&data);
    // Manually set owns_data to false (simulating borrowed data)
    payload.owns_data = false;

    // Should not crash or double-free
    payload.deinit(testing.allocator);
}
