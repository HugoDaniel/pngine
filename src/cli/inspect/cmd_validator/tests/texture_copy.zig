//! Inspector validation for command 0x2B — plan 06 slice 3.
//!
//! The command's own fields are decoded by `parse.zig`; these cases drive the
//! validator's shared `texture_layout.calculateTextureCopy` path against
//! retained descriptors. A refusal must reach the inspector as the existing
//! E001/E006 issue channel, never as a panic and never as a silent pass.

const std = @import("std");
const Allocator = std.mem.Allocator;

const cv_shared = @import("../params.zig");
const validator_mod = @import("../validator.zig");
const Validator = validator_mod.Validator;
const ParsedCommand = cv_shared.ParsedCommand;
const CopyTextureSubresourceParams = cv_shared.CopyTextureSubresourceParams;

/// One command's parameters with fields defaulted; each case overrides only
/// what it is about.
fn command(params: CopyTextureSubresourceParams) ParsedCommand {
    return .{
        .index = 0,
        .cmd = .copy_texture_subresource,
        .params = .{ .copy_texture_subresource = params },
    };
}

fn issueMessages(validator: *const Validator, gpa: Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    for (validator.issues.items) |issue| {
        try aw.writer.print("{s}: {s}\n", .{ issue.code, issue.message });
    }
    return gpa.dupe(u8, aw.writer.buffered());
}
