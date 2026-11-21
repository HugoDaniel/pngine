//! Command 0x55 (`begin_render_pass_views`) in the inspector: the new width,
//! target tags, attachment state and the descriptor checks that keep a tagged
//! view from silently binding a texture or another view's subresource.
//!
//! The records are constructed as ParsedCommands here (parse.zig's own tests
//! pin the byte width and field offsets); this file is about what the validator
//! concludes once the record is decoded.

const std = @import("std");
const pngine = @import("pngine");
const Cmd = pngine.command_buffer.Cmd;

const cv_shared = @import("../params.zig");
const validator_mod = @import("../validator.zig");
const Validator = validator_mod.Validator;
const TextureUsage = cv_shared.TextureUsage;
const TextureInfo = cv_shared.TextureInfo;
const TextureViewInfo = cv_shared.TextureViewInfo;
const BeginRenderPassViewsParams = cv_shared.BeginRenderPassViewsParams;
const ViewAttachmentParams = cv_shared.ViewAttachmentParams;
const ParsedCommand = cv_shared.ParsedCommand;

const CANVAS = 0xfffe;
const NONE = 0xffff;
const VIEW_TAG = 0x8000;

fn viewTarget(id: u16) u16 {
    return VIEW_TAG | id;
}

/// A 0x55 record with one colour attachment and the given depth target.
fn passCommand(index: u32, target: u16, depth: u16) ParsedCommand {
    var params = BeginRenderPassViewsParams{ .count = 1, .depth_target = depth };
    params.attachments[0] = .{ .target = target, .resolve_target = NONE };
    return .{ .index = index, .cmd = .begin_render_pass_views, .params = .{ .begin_render_pass_views = params } };
}

fn endPass(index: u32) ParsedCommand {
    return .{ .index = index, .cmd = .end_pass, .params = .{ .none = {} } };
}

fn renderableTexture() TextureInfo {
    return .{
        .created_at = 0,
        .usage = TextureUsage.RENDER_ATTACHMENT,
        .format = 0x00, // rgba8unorm
        .mip_level_count = 1,
        .depth = 1,
        .descriptor_parsed = true,
    };
}

fn attachmentView(texture_id: u16, mip_count: u32, layers: u32) TextureViewInfo {
    return .{
        .created_at = 0,
        .texture_id = texture_id,
        .dimension = 1, // 2d
        .aspect = 0,
        .base_mip_level = 0,
        .mip_level_count = mip_count,
        .base_array_layer = 0,
        .array_layer_count = layers,
        .descriptor_parsed = true,
    };
}
