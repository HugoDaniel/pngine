//! PNG Loader for Native Viewer
//!
//! Loads PNG files and extracts embedded executor payloads.
//!
//! ## Payload Format (v0; header layout unchanged from legacy v4/v5)
//! ```
//! Header (40 bytes):
//!   magic: "PNGB"
//!   version: u16 (0; legacy 4/5 also parsed)
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
const VERSION_V0: u16 = 0; // current format (40-byte header, == v5 layout)
const VERSION_V5: u16 = 5; // legacy
const VERSION_V4: u16 = 4; // legacy
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
/// Complexity: O(n) where n = file size.
///
/// Pre-condition: path points to valid PNG file
/// Post-condition: Returns payload info, caller owns memory
pub fn loadPNG(allocator: std.mem.Allocator, io: std.Io, path: []const u8) Error!Payload {
    // Pre-condition: path must be non-empty
    std.debug.assert(path.len > 0);

    // Open file
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => Error.FileNotFound,
            else => Error.IoError,
        };
    };
    defer file.close(io);

    // Get file size
    const stat = file.stat(io) catch return Error.IoError;
    if (stat.size > 10 * 1024 * 1024) return Error.IoError;
    const size: usize = @intCast(stat.size);

    // Read file contents
    const png_data = allocator.alloc(u8, size) catch return Error.OutOfMemory;
    errdefer allocator.free(png_data);

    // Read in bounded loop (max iterations = size to prevent infinite loop)
    var bytes_read: usize = 0;
    for (0..size + 1) |_| {
        if (bytes_read >= size) break;
        const n = file.readStreaming(io, &.{png_data[bytes_read..]}) catch return Error.IoError;
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
/// Complexity: O(1) - just reads header fields.
///
/// Pre-condition: data contains PNGB payload bytes
/// Post-condition: Returns parsed payload with valid slices into data
pub fn parsePayload(data: []const u8) Error!Payload {
    // Pre-condition: data length is bounded (can't parse empty data)
    // Note: actual minimum size check happens below with proper error

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

    // v0 is the current format; its 40-byte header is byte-identical to the
    // legacy v5 layout (the version renumbered 5→0 at the SJON cutover, header
    // unchanged), so it parses through the same path. Matches npm loader.js
    // (VERSION_V0 = 0, HEADER_SIZE_V0 = 40). Before this the native viewer
    // rejected every current PNG with InvalidPngbVersion.
    const result = if (version == VERSION_V0 or version == VERSION_V5)
        try parseV5Payload(data)
    else if (version == VERSION_V4)
        try parseV4Payload(data)
    else
        return Error.InvalidPngbVersion;

    // Post-condition: result refers to input data
    std.debug.assert(result.raw_data.ptr == data.ptr);
    std.debug.assert(result.raw_data.len == data.len);

    return result;
}

/// Parse v5 payload (40-byte header with embedded executor support).
fn parseV5Payload(data: []const u8) Error!Payload {
    // Pre-condition: minimum size already checked by caller
    std.debug.assert(data.len >= HEADER_SIZE_V4);

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

    // Post-condition: bytecode slice is within bounds
    std.debug.assert(bytecode_start <= bytecode_end);
    std.debug.assert(bytecode_end <= data.len);

    return Payload{
        // Report the actual on-disk version (0 for current PNGs, 5 for legacy);
        // the header layout is shared, only the version field differs.
        .version = std.mem.readInt(u16, data[4..6], .little),
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
    // Pre-condition: magic already verified by caller
    std.debug.assert(std.mem.eql(u8, data[0..4], &PNGB_MAGIC));

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

    // Post-condition: bytecode slice is within bounds
    std.debug.assert(bytecode_start <= bytecode_end);
    std.debug.assert(bytecode_end <= data.len);

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

// ============================================================================
// Edge Case Tests
// ============================================================================

// ============================================================================
// Property-Based Tests
// ============================================================================

// ============================================================================
// Fuzz Tests
// ============================================================================

fn fuzzParsePayload(_: void, smith: *std.testing.Smith) !void {
    var buf: [4096]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];

    // Property: parsePayload never crashes, only returns errors or valid payload
    const result = parsePayload(input);

    if (result) |payload| {
        // If parsing succeeds, validate invariants
        try std.testing.expect(payload.version == VERSION_V0 or payload.version == VERSION_V4 or payload.version == VERSION_V5);
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

// ============================================================================
// getPluginName Tests
// ============================================================================

// ============================================================================
// Payload Struct Tests
// ============================================================================
