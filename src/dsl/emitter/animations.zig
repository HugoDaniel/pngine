//! Animation Emission Module
//!
//! Handles extraction of animation metadata from #animation macros.
//! Animation metadata is serialized to the animation table section in PNGB.
//!
//! ## Invariants
//!
//! * Only one #animation is allowed per module.
//! * Scene references must point to existing #frame declarations.
//! * Animation metadata is converted to bytecode format and serialized.

const std = @import("std");
const Emitter = @import("../Emitter.zig").Emitter;
const Node = @import("../Ast.zig").Node;
const utils = @import("utils.zig");
const animation_table = @import("../../bytecode/animation_table.zig");

/// Maximum scenes per animation (prevents runaway iteration).
const MAX_SCENES: u32 = 64;

/// Extract animation metadata from #animation declarations.
/// Only one #animation is expected per module.
pub fn extractAnimations(e: *Emitter) Emitter.Error!void {
    // Pre-condition: AST has nodes
    std.debug.assert(e.ast.nodes.len > 0);

    var it = e.analysis.symbols.animation.iterator();
    const entry = it.next() orelse return; // No animations

    // Only process first animation (one per module)
    const name = entry.key_ptr.*;
    const info = entry.value_ptr.*;

    // Track animation ID
    const anim_id = e.next_animation_id;
    e.next_animation_id += 1;
    try e.animation_ids.put(e.gpa, name, anim_id);

    // Extract metadata
    try extractAnimationMetadata(e, name, info.node);
}

/// Extract metadata from a single #animation macro.
fn extractAnimationMetadata(e: *Emitter, name: []const u8, node: Node.Index) Emitter.Error!void {
    // Pre-condition: node is valid
    std.debug.assert(node.toInt() < e.ast.nodes.len);

    // Parse properties
    const duration = if (utils.findPropertyValue(e, node, "duration")) |d|
        utils.parseFloatNumber(e, d) orelse 0.0
    else
        0.0;

    const loop = if (utils.findPropertyValue(e, node, "loop")) |l|
        parseBoolean(e, l)
    else
        false;

    const end_behavior = if (utils.findPropertyValue(e, node, "endBehavior")) |eb|
        parseEndBehavior(e, eb)
    else
        .hold;

    // Parse scenes array
    var scenes_list = std.ArrayListUnmanaged(Emitter.AnimationMetadata.Scene){};
    errdefer scenes_list.deinit(e.gpa);

    if (utils.findPropertyValue(e, node, "scenes")) |scenes_node| {
        try parseScenes(e, scenes_node, &scenes_list);
    }

    // Store animation metadata
    e.animation_metadata = .{
        .name = name,
        .duration = duration,
        .loop = loop,
        .end_behavior = end_behavior,
        .scenes = try scenes_list.toOwnedSlice(e.gpa),
    };

    // Post-condition: metadata is set
    std.debug.assert(e.animation_metadata != null);
}

/// Parse boolean from identifier_value node.
fn parseBoolean(e: *Emitter, node: Node.Index) bool {
    const tag = e.ast.nodes.items(.tag)[node.toInt()];
    if (tag != .identifier_value) return false;

    const token = e.ast.nodes.items(.main_token)[node.toInt()];
    const text = utils.getTokenSlice(e, token);

    return std.mem.eql(u8, text, "true");
}

/// Parse endBehavior enum from identifier_value node.
fn parseEndBehavior(e: *Emitter, node: Node.Index) Emitter.AnimationMetadata.EndBehavior {
    const tag = e.ast.nodes.items(.tag)[node.toInt()];
    if (tag != .identifier_value) return .hold;

    const token = e.ast.nodes.items(.main_token)[node.toInt()];
    const text = utils.getTokenSlice(e, token);

    const map = std.StaticStringMap(Emitter.AnimationMetadata.EndBehavior).initComptime(.{
        .{ "hold", .hold },
        .{ "stop", .stop },
        .{ "restart", .restart },
    });

    return map.get(text) orelse .hold;
}

/// Parse scenes array.
fn parseScenes(
    e: *Emitter,
    array_node: Node.Index,
    scenes_list: *std.ArrayListUnmanaged(Emitter.AnimationMetadata.Scene),
) Emitter.Error!void {
    const tag = e.ast.nodes.items(.tag)[array_node.toInt()];
    if (tag != .array) return;

    const array_data = e.ast.nodes.items(.data)[array_node.toInt()];
    const elements = e.ast.extraData(array_data.extra_range);

    // Bounded iteration
    const max_elements = @min(elements.len, MAX_SCENES);
    for (0..max_elements) |i| {
        const elem: Node.Index = @enumFromInt(elements[i]);
        const elem_tag = e.ast.nodes.items(.tag)[elem.toInt()];

        if (elem_tag == .object) {
            if (parseScene(e, elem)) |scene| {
                try scenes_list.append(e.gpa, scene);
            }
        }
    }
}

/// Parse a single scene object.
fn parseScene(e: *Emitter, obj_node: Node.Index) ?Emitter.AnimationMetadata.Scene {
    // Scene object: { id="name" frame=frameName start=0 end=30 }
    const id = if (utils.findPropertyValueInObject(e, obj_node, "id")) |id_node|
        utils.getStringContent(e, id_node)
    else
        return null;

    const frame_name = if (utils.findPropertyValueInObject(e, obj_node, "frame")) |frame_node|
        resolveFrameName(e, frame_node)
    else
        return null;

    if (frame_name.len == 0) return null;

    const start = if (utils.findPropertyValueInObject(e, obj_node, "start")) |s|
        utils.parseFloatNumber(e, s) orelse 0.0
    else
        0.0;

    const end = if (utils.findPropertyValueInObject(e, obj_node, "end")) |end_node|
        utils.parseFloatNumber(e, end_node) orelse 0.0
    else
        0.0;

    return .{
        .id = id,
        .frame_name = frame_name,
        .start = start,
        .end = end,
    };
}

/// Resolve frame identifier to name string.
fn resolveFrameName(e: *Emitter, node: Node.Index) []const u8 {
    const tag = e.ast.nodes.items(.tag)[node.toInt()];

    if (tag == .identifier_value) {
        const token = e.ast.nodes.items(.main_token)[node.toInt()];
        return utils.getTokenSlice(e, token);
    }

    return "";
}

/// Populate the bytecode animation table from extracted DSL metadata.
/// Must be called after extractAnimations() and after frame names are interned.
pub fn populateAnimationTable(e: *Emitter) Emitter.Error!void {
    const meta = e.animation_metadata orelse return; // No animation defined

    // Intern animation name
    const name_string_id = try e.builder.internString(e.gpa, meta.name);

    // Convert duration from seconds to milliseconds
    const duration_ms: u32 = @intFromFloat(meta.duration * 1000.0);

    // Convert end behavior
    const end_behavior: animation_table.EndBehavior = switch (meta.end_behavior) {
        .hold => .hold,
        .stop => .stop,
        .restart => .restart,
    };

    // Convert scenes
    var scenes = std.ArrayListUnmanaged(animation_table.Scene){};
    errdefer scenes.deinit(e.gpa);

    for (meta.scenes, 0..) |scene, i| {
        if (i >= MAX_SCENES) break;

        // Intern scene ID and frame name
        const id_string_id = try e.builder.internString(e.gpa, scene.id);
        const frame_string_id = try e.builder.internString(e.gpa, scene.frame_name);

        // Convert times from seconds to milliseconds
        const start_ms: u32 = @intFromFloat(scene.start * 1000.0);
        const end_ms: u32 = @intFromFloat(scene.end * 1000.0);

        try scenes.append(e.gpa, .{
            .id_string_id = id_string_id.toInt(),
            .frame_string_id = frame_string_id.toInt(),
            .start_ms = start_ms,
            .end_ms = end_ms,
        });
    }

    // Set animation info on the builder's animation table
    const anim_table = e.builder.getAnimationTable();
    const scenes_slice = try scenes.toOwnedSlice(e.gpa);
    anim_table.* = .{
        .info = .{
            .name_string_id = name_string_id.toInt(),
            .duration_ms = duration_ms,
            .loop = meta.loop,
            .end_behavior = end_behavior,
            .scenes = scenes_slice,
        },
        .owned_scenes = scenes_slice, // Builder owns the scenes slice
    };
}

test "AnimationMetadata.toJson" {
    const allocator = std.testing.allocator;

    const scenes = [_]Emitter.AnimationMetadata.Scene{
        .{ .id = "intro", .frame_name = "sceneQ", .start = 0.0, .end = 30.0 },
        .{ .id = "tunnel", .frame_name = "sceneE", .start = 30.0, .end = 60.0 },
    };

    const meta = Emitter.AnimationMetadata{
        .name = "inercia2025",
        .duration = 260.0,
        .loop = false,
        .end_behavior = .hold,
        .scenes = &scenes,
    };

    const json = try meta.toJson(allocator);
    defer allocator.free(json);

    // Verify structure
    try std.testing.expect(std.mem.indexOf(u8, json, "\"animation\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"inercia2025\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"duration\":260") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"loop\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"endBehavior\":\"hold\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scenes\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"intro\"") != null);
}
