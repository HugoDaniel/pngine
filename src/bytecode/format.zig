//! PNGB Binary Format
//!
//! Serializes and deserializes the complete PNGB binary format.
//!
//! File Structure (16 bytes header):
//! ┌─────────────────────────────────────┐
//! │ Header (16 bytes)                   │
//! │   magic: "PNGB" (4 bytes)           │
//! │   version: u16                      │
//! │   flags: u16                        │
//! │   string_table_offset: u32          │
//! │   data_section_offset: u32          │
//! ├─────────────────────────────────────┤
//! │ Bytecode Section                    │
//! │   (immediately after header)        │
//! ├─────────────────────────────────────┤
//! │ String Table                        │
//! ├─────────────────────────────────────┤
//! │ Data Section                        │
//! └─────────────────────────────────────┘
//!
//! Invariants:
//! - Magic must be "PNGB"
//! - Version must be 1
//! - Offsets point to valid positions within the file

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const StringTable = @import("string_table.zig").StringTable;
const DataSection = @import("data_section.zig").DataSection;
const Emitter = @import("emitter.zig").Emitter;

/// Magic bytes identifying PNGB format.
pub const MAGIC: *const [4]u8 = "PNGB";

/// Current format version.
pub const VERSION: u16 = 1;

/// Header size in bytes.
pub const HEADER_SIZE: usize = 16;

/// Header flags.
pub const Flags = packed struct(u16) {
    /// Reserved for future use.
    reserved: u16 = 0,
};

/// PNGB file header.
pub const Header = extern struct {
    magic: [4]u8,
    version: u16,
    flags: Flags,
    string_table_offset: u32,
    data_section_offset: u32,

    comptime {
        // Verify header is exactly 16 bytes
        assert(@sizeOf(Header) == HEADER_SIZE);
    }

    /// Validate header.
    pub fn validate(self: *const Header) !void {
        if (!std.mem.eql(u8, &self.magic, MAGIC)) {
            return error.InvalidMagic;
        }
        if (self.version != VERSION) {
            return error.UnsupportedVersion;
        }
    }
};

/// Complete PNGB module for execution.
pub const Module = struct {
    header: Header,
    bytecode: []const u8,
    strings: StringTable,
    data: DataSection,

    pub fn deinit(self: *Module, allocator: Allocator) void {
        self.strings.deinit(allocator);
        self.data.deinit(allocator);
        self.* = undefined;
    }
};

/// Serialize components to PNGB format.
pub fn serialize(
    allocator: Allocator,
    bytecode: []const u8,
    strings: *const StringTable,
    data: *const DataSection,
) ![]u8 {
    // Serialize string table
    const string_bytes = try strings.serialize(allocator);
    defer allocator.free(string_bytes);

    // Serialize data section
    const data_bytes = try data.serialize(allocator);
    defer allocator.free(data_bytes);

    // Calculate offsets
    const string_table_offset: u32 = @intCast(HEADER_SIZE + bytecode.len);
    const data_section_offset: u32 = @intCast(HEADER_SIZE + bytecode.len + string_bytes.len);

    // Total size
    const total_size = HEADER_SIZE + bytecode.len + string_bytes.len + data_bytes.len;

    // Allocate output buffer
    const output = try allocator.alloc(u8, total_size);
    errdefer allocator.free(output);

    var offset: usize = 0;

    // Write header
    const header = Header{
        .magic = MAGIC.*,
        .version = VERSION,
        .flags = .{},
        .string_table_offset = string_table_offset,
        .data_section_offset = data_section_offset,
    };
    @memcpy(output[offset..][0..HEADER_SIZE], std.mem.asBytes(&header));
    offset += HEADER_SIZE;

    // Write bytecode
    @memcpy(output[offset..][0..bytecode.len], bytecode);
    offset += bytecode.len;

    // Write string table
    @memcpy(output[offset..][0..string_bytes.len], string_bytes);
    offset += string_bytes.len;

    // Write data section
    @memcpy(output[offset..][0..data_bytes.len], data_bytes);
    offset += data_bytes.len;

    // Post-condition: wrote exactly total_size
    assert(offset == total_size);

    return output;
}

/// Deserialize PNGB format to module.
/// Note: The returned module references the input data - caller must ensure data outlives module.
pub fn deserialize(allocator: Allocator, data: []const u8) !Module {
    // Pre-condition: at least header present
    if (data.len < HEADER_SIZE) return error.InvalidFormat;

    // Read and validate header
    const header: *const Header = @ptrCast(@alignCast(data[0..HEADER_SIZE]));
    try header.validate();

    // Validate offsets
    if (header.string_table_offset > data.len) return error.InvalidOffset;
    if (header.data_section_offset > data.len) return error.InvalidOffset;
    if (header.string_table_offset < HEADER_SIZE) return error.InvalidOffset;

    // Extract bytecode (between header and string table)
    const bytecode_len = header.string_table_offset - HEADER_SIZE;
    const bytecode = data[HEADER_SIZE..][0..bytecode_len];

    // Deserialize string table
    const string_data = data[header.string_table_offset..header.data_section_offset];
    const strings = try @import("string_table.zig").deserialize(allocator, string_data);
    errdefer {
        var s = strings;
        s.deinit(allocator);
    }

    // Deserialize data section
    const data_section_data = data[header.data_section_offset..];
    const data_section = try @import("data_section.zig").deserialize(allocator, data_section_data);

    return Module{
        .header = header.*,
        .bytecode = bytecode,
        .strings = strings,
        .data = data_section,
    };
}

// ============================================================================
// Builder: High-level interface for constructing PNGB modules
// ============================================================================

/// Builder for constructing PNGB modules.
pub const Builder = struct {
    const Self = @This();

    strings: StringTable,
    data: DataSection,
    emitter: Emitter,

    pub fn init() Self {
        return .{
            .strings = .empty,
            .data = .empty,
            .emitter = .empty,
        };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.strings.deinit(allocator);
        self.data.deinit(allocator);
        self.emitter.deinit(allocator);
        self.* = undefined;
    }

    /// Intern a string and return its ID.
    pub fn internString(self: *Self, allocator: Allocator, str: []const u8) !@import("string_table.zig").StringId {
        return self.strings.intern(allocator, str);
    }

    /// Add data and return its ID.
    pub fn addData(self: *Self, allocator: Allocator, data: []const u8) !@import("data_section.zig").DataId {
        return self.data.add(allocator, data);
    }

    /// Get the emitter for bytecode generation.
    pub fn getEmitter(self: *Self) *Emitter {
        return &self.emitter;
    }

    /// Finalize and serialize to PNGB format.
    pub fn finalize(self: *Self, allocator: Allocator) ![]u8 {
        return serialize(
            allocator,
            self.emitter.bytecode(),
            &self.strings,
            &self.data,
        );
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "header size" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(Header));
}

test "empty module" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const output = try builder.finalize(testing.allocator);
    defer testing.allocator.free(output);

    // Should have at least header
    try testing.expect(output.len >= HEADER_SIZE);

    // Verify magic
    try testing.expectEqualStrings("PNGB", output[0..4]);
}

test "module with strings and data" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    // Add strings
    const name_id = try builder.internString(testing.allocator, "simpleTriangle");
    _ = try builder.internString(testing.allocator, "vertexMain");

    // Add data
    const shader_code = "@vertex fn vertexMain() -> @builtin(position) vec4f { return vec4f(0); }";
    const shader_id = try builder.addData(testing.allocator, shader_code);

    // Add some bytecode
    const emitter = builder.getEmitter();
    try emitter.createShaderModule(testing.allocator, 0, shader_id.toInt());
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.endFrame(testing.allocator);

    // Finalize
    const output = try builder.finalize(testing.allocator);
    defer testing.allocator.free(output);

    try testing.expect(output.len > HEADER_SIZE);

    // Deserialize and verify
    var module = try deserialize(testing.allocator, output);
    defer module.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 2), module.strings.count());
    try testing.expectEqualStrings("simpleTriangle", module.strings.get(@enumFromInt(0)));
    try testing.expectEqualStrings("vertexMain", module.strings.get(@enumFromInt(1)));

    try testing.expectEqual(@as(u16, 1), module.data.count());
    try testing.expectEqualStrings(shader_code, module.data.get(@enumFromInt(0)));
}

test "roundtrip serialization" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    // Build a simple triangle module
    const frame_name = try builder.internString(testing.allocator, "triangle");
    const shader = "@vertex fn vs() {} @fragment fn fs() {}";
    const shader_data = try builder.addData(testing.allocator, shader);

    const emitter = builder.getEmitter();
    try emitter.createShaderModule(testing.allocator, 0, shader_data.toInt());
    try emitter.createRenderPipeline(testing.allocator, 0, 0);
    try emitter.defineFrame(testing.allocator, 0, frame_name.toInt());
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 3, 1);
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    // Serialize
    const output = try builder.finalize(testing.allocator);
    defer testing.allocator.free(output);

    // Deserialize
    var module = try deserialize(testing.allocator, output);
    defer module.deinit(testing.allocator);

    // Verify bytecode starts with create_shader_module
    const opcodes = @import("opcodes.zig");
    try testing.expectEqual(@as(u8, @intFromEnum(opcodes.OpCode.create_shader_module)), module.bytecode[0]);

    // Verify string
    try testing.expectEqualStrings("triangle", module.strings.get(@enumFromInt(0)));

    // Verify data
    try testing.expectEqualStrings(shader, module.data.get(@enumFromInt(0)));
}

test "invalid magic" {
    var data: [HEADER_SIZE]u8 = undefined;
    @memcpy(data[0..4], "XXXX"); // Invalid magic

    const result = deserialize(testing.allocator, &data);
    try testing.expectError(error.InvalidMagic, result);
}

test "invalid version" {
    var data: [HEADER_SIZE]u8 = undefined;
    @memcpy(data[0..4], MAGIC);
    std.mem.writeInt(u16, data[4..6], 99, .little); // Invalid version

    const result = deserialize(testing.allocator, &data);
    try testing.expectError(error.UnsupportedVersion, result);
}

test "builder handles OOM gracefully" {
    // Test that Builder properly returns OutOfMemory and doesn't leak
    // when allocation fails at any point.
    var fail_index: usize = 0;
    const max_iterations: usize = 500;

    for (0..max_iterations) |_| {
        var failing_alloc = std.testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        const alloc = failing_alloc.allocator();

        var builder = Builder.init();
        defer builder.deinit(alloc);

        // Try to build a simple module
        const string_result = builder.internString(alloc, "test_frame");
        if (string_result) |_| {
            // String interning succeeded, try data
            const data_result = builder.addData(alloc, "shader code here");
            if (data_result) |data_id| {
                // Data add succeeded, try bytecode emission
                const emitter = builder.getEmitter();
                const emit_result = emitter.createShaderModule(alloc, 0, data_id.toInt());
                if (emit_result) |_| {
                    // Emission succeeded, try finalize
                    const finalize_result = builder.finalize(alloc);
                    if (finalize_result) |output| {
                        alloc.free(output);
                        // Full success - test complete
                        break;
                    } else |err| {
                        try testing.expectEqual(error.OutOfMemory, err);
                    }
                } else |err| {
                    try testing.expectEqual(error.OutOfMemory, err);
                }
            } else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
            }
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
        }

        fail_index += 1;
    } else {
        unreachable;
    }
}

test "serialize handles OOM gracefully" {
    // First build a valid module with normal allocator
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    _ = try builder.internString(testing.allocator, "test");
    const data_id = try builder.addData(testing.allocator, "data content");
    const emitter = builder.getEmitter();
    try emitter.createShaderModule(testing.allocator, 0, data_id.toInt());
    try emitter.draw(testing.allocator, 3, 1);

    // Now test serialization with failing allocator
    var fail_index: usize = 0;
    const max_iterations: usize = 100;

    for (0..max_iterations) |_| {
        var failing_alloc = std.testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });

        const result = serialize(
            failing_alloc.allocator(),
            emitter.bytecode(),
            &builder.strings,
            &builder.data,
        );

        if (failing_alloc.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            const output = try result;
            failing_alloc.allocator().free(output);
            break;
        }

        fail_index += 1;
    } else {
        unreachable;
    }
}
