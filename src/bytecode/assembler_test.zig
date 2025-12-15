//! Assembler Integration Test
//!
//! Tests the complete pipeline from PBSF source to PNGB bytecode.
//! This demonstrates how the AST would be translated to bytecode.
//!
//! The actual AST-to-bytecode compiler will be implemented in a future phase.
//! For now, this test manually constructs the equivalent bytecode.

const std = @import("std");
const testing = std.testing;
const parser = @import("../pbsf/parser.zig");
const format = @import("format.zig");
const opcodes = @import("opcodes.zig");
const simple_triangle = @import("../fixtures/simple_triangle.zig");

test "manual simpleTriangle AST to PNGB" {
    // Step 1: Parse the PBSF source
    var ast = try parser.parse(testing.allocator, simple_triangle.simple_triangle_pbsf);
    defer ast.deinit(testing.allocator);

    // Verify parsing succeeded
    try testing.expectEqual(@as(usize, 0), ast.errors.len);

    // Step 2: Manually construct the equivalent PNGB
    // In the future, a compiler would walk the AST and emit this automatically
    var builder = format.Builder.init();
    defer builder.deinit(testing.allocator);

    // Extract data from AST for reference
    // The module structure is: (module "name" (data ...) (shader ...) ...)
    const module_node = ast.children(.root)[0];
    const module_children = ast.children(module_node);

    // Find module name
    const module_name_node = module_children[1];
    try testing.expectEqual(parser.Node.Tag.string, ast.nodeTag(module_name_node));
    const module_name_raw = ast.tokenSlice(ast.nodeMainToken(module_name_node));
    // Strip quotes from string
    const module_name = module_name_raw[1 .. module_name_raw.len - 1];
    try testing.expectEqualStrings("simpleTriangle", module_name);

    // Intern strings
    const frame_name_id = try builder.internString(testing.allocator, module_name);
    _ = try builder.internString(testing.allocator, "vertexMain");
    _ = try builder.internString(testing.allocator, "fragMain");

    // Add shader code data
    // In a real compiler, we'd extract this from the (data ...) node
    const shader_code =
        \\@vertex fn vertexMain(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
        \\  var pos = array<vec2f, 3>(vec2(0.0, 0.5), vec2(-0.5, -0.5), vec2(0.5, -0.5));
        \\  return vec4f(pos[i], 0.0, 1.0);
        \\}
        \\@fragment fn fragMain() -> @location(0) vec4f {
        \\  return vec4f(1.0, 0.0, 0.0, 1.0);
        \\}
    ;
    const shader_data_id = try builder.addData(testing.allocator, shader_code);

    // Add pipeline descriptor data (JSON-like structure serialized to bytes)
    // In practice, this would be a compact binary descriptor
    const pipeline_desc = "{}"; // Placeholder
    const pipeline_desc_id = try builder.addData(testing.allocator, pipeline_desc);

    // Add pass descriptor data
    const pass_desc = "{}"; // Placeholder
    const pass_desc_id = try builder.addData(testing.allocator, pass_desc);

    // Emit bytecode
    const emitter = builder.getEmitter();

    // Create shader module from data
    try emitter.createShaderModule(
        testing.allocator,
        0, // shader_id = 0
        shader_data_id.toInt(),
    );

    // Create render pipeline
    try emitter.createRenderPipeline(
        testing.allocator,
        0, // pipeline_id = 0
        pipeline_desc_id.toInt(),
    );

    // Define the pass
    try emitter.definePass(
        testing.allocator,
        0, // pass_id = 0
        .render,
        pass_desc_id.toInt(),
    );
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 3, 1); // 3 vertices, 1 instance
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Define the frame
    try emitter.defineFrame(
        testing.allocator,
        0, // frame_id = 0
        frame_name_id.toInt(),
    );
    try emitter.execPass(testing.allocator, 0);
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    // Step 3: Finalize to PNGB
    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    // Step 4: Verify the PNGB
    try testing.expect(pngb.len > format.HEADER_SIZE);
    try testing.expectEqualStrings("PNGB", pngb[0..4]);

    // Deserialize and verify
    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify strings
    try testing.expectEqual(@as(u16, 3), module.strings.count());
    try testing.expectEqualStrings("simpleTriangle", module.strings.get(@enumFromInt(0)));
    try testing.expectEqualStrings("vertexMain", module.strings.get(@enumFromInt(1)));
    try testing.expectEqualStrings("fragMain", module.strings.get(@enumFromInt(2)));

    // Verify data
    try testing.expectEqual(@as(u16, 3), module.data.count());
    try testing.expectEqualStrings(shader_code, module.data.get(@enumFromInt(0)));

    // Verify bytecode starts with create_shader_module
    try testing.expectEqual(
        @as(u8, @intFromEnum(opcodes.OpCode.create_shader_module)),
        module.bytecode[0],
    );

    // Log success metrics
    std.debug.print("\n", .{});
    std.debug.print("=== simpleTriangle PNGB Generation ===\n", .{});
    std.debug.print("  PBSF source: {} bytes\n", .{simple_triangle.simple_triangle_pbsf.len});
    std.debug.print("  PNGB output: {} bytes\n", .{pngb.len});
    std.debug.print("  Compression: {d:.1}x\n", .{
        @as(f64, @floatFromInt(simple_triangle.simple_triangle_pbsf.len)) /
            @as(f64, @floatFromInt(pngb.len)),
    });
    std.debug.print("  Bytecode: {} bytes\n", .{module.bytecode.len});
    std.debug.print("  Strings: {} entries\n", .{module.strings.count()});
    std.debug.print("  Data: {} entries\n", .{module.data.count()});
    std.debug.print("\n", .{});
}

test "bytecode execution order" {
    // Verify bytecode is emitted in the correct order for simpleTriangle:
    // 1. create_shader_module
    // 2. create_render_pipeline
    // 3. define_pass -> set_pipeline -> draw -> end_pass -> end_pass_def
    // 4. define_frame -> exec_pass -> submit -> end_frame

    var builder = format.Builder.init();
    defer builder.deinit(testing.allocator);

    // Minimal setup
    _ = try builder.addData(testing.allocator, "shader");
    _ = try builder.addData(testing.allocator, "{}");
    _ = try builder.addData(testing.allocator, "{}");
    _ = try builder.internString(testing.allocator, "frame");

    const emitter = builder.getEmitter();

    // Emit in order
    try emitter.createShaderModule(testing.allocator, 0, 0);
    try emitter.createRenderPipeline(testing.allocator, 0, 1);
    try emitter.definePass(testing.allocator, 0, .render, 2);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 3, 1);
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);
    try emitter.defineFrame(testing.allocator, 0, 0);
    try emitter.execPass(testing.allocator, 0);
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const bc = emitter.bytecode();

    // Verify opcode sequence
    var pos: usize = 0;

    // create_shader_module
    try testing.expectEqual(@as(u8, @intFromEnum(opcodes.OpCode.create_shader_module)), bc[pos]);
    pos += 3; // opcode + 2 varints

    // create_render_pipeline
    try testing.expectEqual(@as(u8, @intFromEnum(opcodes.OpCode.create_render_pipeline)), bc[pos]);
    pos += 3;

    // define_pass
    try testing.expectEqual(@as(u8, @intFromEnum(opcodes.OpCode.define_pass)), bc[pos]);
}

test "bytecode size efficiency" {
    // Verify bytecode is compact
    var builder = format.Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Single draw instruction
    try emitter.draw(testing.allocator, 3, 1);

    // Should be 3 bytes: opcode + vertex_count + instance_count
    try testing.expectEqual(@as(usize, 3), emitter.len());

    // Draw with larger counts
    try emitter.draw(testing.allocator, 1000, 100);

    // Should use varint encoding efficiently
    // 1000 = 2 bytes, 100 = 1 byte
    // Total: 3 + 1 + 2 + 1 = 7 bytes for both draws
    try testing.expectEqual(@as(usize, 7), emitter.len());
}
