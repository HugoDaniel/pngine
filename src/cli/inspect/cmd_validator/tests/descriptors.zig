//! E006 descriptor validation: buffer usage in context, and the texture
//! descriptor TLV walk with its dimension, usage, sample-count and MSAA
//! constraints.

const std = @import("std");
const pngine = @import("pngine");
const Cmd = pngine.command_buffer.Cmd;
const desc = pngine.types.descriptors;

const cv_shared = @import("../params.zig");
const validator_mod = @import("../validator.zig");
const parse_mod = @import("../parse.zig");
const Validator = validator_mod.Validator;
const parseCommands = parse_mod.parseCommands;
const writeJsonEscaped = cv_shared.writeJsonEscaped;
const BufferUsage = cv_shared.BufferUsage;
const TextureUsage = cv_shared.TextureUsage;
const TextureInfo = cv_shared.TextureInfo;
const WriteTextureParams = cv_shared.WriteTextureParams;
const Aspect = pngine.types.texture_layout.Aspect;
const Format = pngine.types.descriptors.TextureFormat;
const Symptom = cv_shared.Symptom;
const Severity = cv_shared.Severity;
const PassState = cv_shared.PassState;
const Issue = cv_shared.Issue;
const Diagnosis = cv_shared.Diagnosis;
const ParsedCommand = cv_shared.ParsedCommand;
const DescriptorType = cv_shared.DescriptorType;
const TextureField = cv_shared.TextureField;
const ValueType = cv_shared.ValueType;

// ============================================================================
// E006 Descriptor Validation Tests
// ============================================================================

// ============================================================================
// E006 Buffer Usage Context Validation Tests
// ============================================================================

// ============================================================================
// E006 Texture Descriptor Parsing Tests
// ============================================================================

// ============================================================================
// E006 Texture Usage Validation Tests
// ============================================================================

// ============================================================================
// E006 Texture Sample Count Validation Tests
// ============================================================================

// ============================================================================
// E006 1D Texture Constraint Tests
// ============================================================================

// ============================================================================
// E006 3D Texture Constraint Tests
// ============================================================================

// ============================================================================
// E006 MSAA Texture Constraint Tests
// ============================================================================

// ============================================================================
// E006 Texture Edge Cases and Combinations
// ============================================================================

// ============================================================================
// WRITE_TEXTURE (0x28) destination/layout validation over plan 01
// ============================================================================

/// A write whose data window is inside a real WASM memory but whose optional
/// fields are all absent. Tests set only the fields the case is about.
fn writeBase(id: u16) WriteTextureParams {
    return .{
        .id = id,
        .data_ptr = 64,
        .data_len = 64,
        .offset = 0,
        .bytes_per_row = 0,
        .rows_per_image = 0,
        .mip_level = 0,
        .origin_x = 0,
        .origin_y = 0,
        .origin_z = 0,
        .aspect = 0, // Aspect.all
        .size_width = 0,
        .size_height = 0,
        .size_depth = 0,
        .flags = 0,
    };
}

fn setStrides(write: *WriteTextureParams, bytes_per_row: u32, rows_per_image: u32) void {
    write.bytes_per_row = bytes_per_row;
    write.rows_per_image = rows_per_image;
    write.flags |= WriteTextureParams.bytes_per_row_bit | WriteTextureParams.rows_per_image_bit;
}

fn setSize(write: *WriteTextureParams, width: u32, height: u32, depth: u32) void {
    write.size_width = width;
    write.size_height = height;
    write.size_depth = depth;
    write.flags |= WriteTextureParams.size_bit;
}

/// A concrete 2x2 rgba8unorm COPY_DST destination.
fn concreteTexture() TextureInfo {
    return .{
        .width = 2,
        .height = 2,
        .format = @intFromEnum(Format.rgba8unorm),
        .usage = TextureUsage.COPY_DST,
        .sample_count = 1,
        .mip_level_count = 1,
        .dimension = .@"2d",
        .created_at = 0,
    };
}

fn expectWriteRefusal(validator: *Validator, code: []const u8) !void {
    try std.testing.expect(validator.hasErrors());
    for (validator.issues.items) |issue| {
        if (std.mem.eql(u8, issue.code, "E006") and std.mem.indexOf(u8, issue.message, code) != null) return;
    }
    std.debug.print("no E006 message containing '{s}'\n", .{code});
    for (validator.issues.items) |issue| {
        std.debug.print("  [{s}] {s}\n", .{ issue.code, issue.message });
    }
    return error.RefusalNotReported;
}

fn validateOneWrite(validator: *Validator, write: WriteTextureParams) !void {
    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .write_texture, .params = .{ .write_texture = write } },
    };
    try validator.validate(&commands);
}
