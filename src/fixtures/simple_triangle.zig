//! simpleTriangle PBSF fixture for testing.
//!
//! This is the hand-written PBSF for the simplest PNGine example:
//! a red triangle rendered to a canvas.

/// Complete simpleTriangle PBSF source.
pub const simple_triangle_pbsf: [:0]const u8 =
    \\(module "simpleTriangle"
    \\  ;; Shader code in data section
    \\  (data $d:0 "
    \\    @vertex fn vertexMain(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    \\      var pos = array<vec2f, 3>(vec2(0.0, 0.5), vec2(-0.5, -0.5), vec2(0.5, -0.5));
    \\      return vec4f(pos[i], 0.0, 1.0);
    \\    }
    \\    @fragment fn fragMain() -> @location(0) vec4f {
    \\      return vec4f(1.0, 0.0, 0.0, 1.0);
    \\    }
    \\  ")
    \\
    \\  ;; Create shader module from data section
    \\  (shader $shd:0 (code $d:0))
    \\
    \\  ;; Create render pipeline
    \\  (render-pipeline $pipe:0
    \\    (layout auto)
    \\    (vertex $shd:0 (entry "vertexMain"))
    \\    (fragment $shd:0 (entry "fragMain")
    \\      (targets (target (format @preferredCanvasFormat))))
    \\    (primitive (topology triangle-list)))
    \\
    \\  ;; Define render pass
    \\  (pass $pass:0 "renderPipeline"
    \\    (render
    \\      (color-attachments
    \\        (attachment
    \\          (view @swapchain)
    \\          (clear-value 0 0 0 0)
    \\          (load-op clear)
    \\          (store-op store)))
    \\      (commands
    \\        (set-pipeline $pipe:0)
    \\        (draw 3 1))))
    \\
    \\  ;; Define frame
    \\  (frame $frm:0 "simpleTriangle"
    \\    (exec-pass $pass:0)
    \\    (submit)))
;

const std = @import("std");
const testing = std.testing;
const parser = @import("../pbsf/parser.zig");

test "parse complete simpleTriangle PBSF" {
    var ast = try parser.parse(testing.allocator, simple_triangle_pbsf);
    defer ast.deinit(testing.allocator);

    // Should parse without errors
    try testing.expectEqual(@as(usize, 0), ast.errors.len);

    // Root has one child (module)
    const root_children = ast.children(.root);
    try testing.expectEqual(@as(usize, 1), root_children.len);

    // Module is a list
    const module = root_children[0];
    try testing.expectEqual(parser.Node.Tag.list, ast.nodeTag(module));

    // Module has: module "name" (data...) (shader...) (render-pipeline...) (pass...) (frame...)
    const module_children = ast.children(module);
    try testing.expect(module_children.len >= 6);

    // Verify module keyword
    try testing.expectEqualStrings("module", ast.tokenSlice(ast.nodeMainToken(module_children[0])));

    // Verify module name
    try testing.expectEqual(parser.Node.Tag.string, ast.nodeTag(module_children[1]));
}

test "simpleTriangle data section contains shader code" {
    var ast = try parser.parse(testing.allocator, simple_triangle_pbsf);
    defer ast.deinit(testing.allocator);

    // Navigate to data section: module -> children[2] (first child after module name)
    const module = ast.children(.root)[0];
    const module_children = ast.children(module);

    // Find (data ...) - should be the first list after "module" and "simpleTriangle"
    var data_node: ?parser.NodeIndex = null;
    for (module_children) |child| {
        if (ast.nodeTag(child) == .list) {
            const list_children = ast.children(child);
            if (list_children.len > 0 and ast.nodeTag(list_children[0]) == .atom) {
                const name = ast.tokenSlice(ast.nodeMainToken(list_children[0]));
                if (std.mem.eql(u8, name, "data")) {
                    data_node = child;
                    break;
                }
            }
        }
    }

    try testing.expect(data_node != null);

    // Data node should have: data $d:0 "shader code"
    const data_children = ast.children(data_node.?);
    try testing.expect(data_children.len >= 3);

    // Third element should be the shader code string
    try testing.expectEqual(parser.Node.Tag.string, ast.nodeTag(data_children[2]));
}

test "simpleTriangle frame references pass" {
    var ast = try parser.parse(testing.allocator, simple_triangle_pbsf);
    defer ast.deinit(testing.allocator);

    // Find frame node
    const module = ast.children(.root)[0];
    const module_children = ast.children(module);

    var frame_node: ?parser.NodeIndex = null;
    for (module_children) |child| {
        if (ast.nodeTag(child) == .list) {
            const list_children = ast.children(child);
            if (list_children.len > 0 and ast.nodeTag(list_children[0]) == .atom) {
                const name = ast.tokenSlice(ast.nodeMainToken(list_children[0]));
                if (std.mem.eql(u8, name, "frame")) {
                    frame_node = child;
                    break;
                }
            }
        }
    }

    try testing.expect(frame_node != null);

    // Frame should have: frame $frm:0 "name" (exec-pass...) (submit)
    const frame_children = ast.children(frame_node.?);
    try testing.expect(frame_children.len >= 4);

    // Verify frame ID
    try testing.expectEqual(parser.Node.Tag.atom, ast.nodeTag(frame_children[1]));
    try testing.expectEqualStrings("$frm:0", ast.tokenSlice(ast.nodeMainToken(frame_children[1])));
}
