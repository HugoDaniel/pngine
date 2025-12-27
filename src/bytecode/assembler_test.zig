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

// Use bytecode module for sibling imports to avoid module conflicts
const bytecode_mod = @import("bytecode");
const format = bytecode_mod.format;
const opcodes = bytecode_mod.opcodes;

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
    try emitter.draw(testing.allocator, 3, 1, 0, 0); // 3 vertices, 1 instance
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
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
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
    try emitter.draw(testing.allocator, 3, 1, 0, 0);

    // Should be 5 bytes: opcode + vertex_count + instance_count + first_vertex + first_instance
    try testing.expectEqual(@as(usize, 5), emitter.len());

    // Draw with larger counts
    try emitter.draw(testing.allocator, 1000, 100, 0, 0);

    // Should use varint encoding efficiently
    // First draw: 5 bytes (all 1-byte varints)
    // Second draw: 1 (opcode) + 2 (1000) + 1 (100) + 1 (0) + 1 (0) = 6 bytes
    // Total: 5 + 6 = 11 bytes
    try testing.expectEqual(@as(usize, 11), emitter.len());
}

// ============================================================================
// Shorthand PBSF Format Tests
// ============================================================================

const assembler = @import("assembler.zig");

test "shorthand shader format: (shader N \"code\")" {
    const source: [:0]const u8 =
        \\(shader 0 "@vertex fn main() {}")
    ;

    var ast = try parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);

    const pngb = try assembler.assemble(testing.allocator, &ast);
    defer testing.allocator.free(pngb);

    // Verify it produced valid PNGB
    try testing.expect(pngb.len > format.HEADER_SIZE);
    try testing.expectEqualStrings("PNGB", pngb[0..4]);

    // Deserialize and verify shader was created
    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Should have shader code in data section
    try testing.expectEqual(@as(u16, 1), module.data.count());
    try testing.expectEqualStrings("@vertex fn main() {}", module.data.get(@enumFromInt(0)));

    // Bytecode should start with create_shader_module
    try testing.expectEqual(
        @as(u8, @intFromEnum(opcodes.OpCode.create_shader_module)),
        module.bytecode[0],
    );
}

test "shorthand pipeline format: (pipeline N (json \"...\"))" {
    const source: [:0]const u8 =
        \\(pipeline 0 (json "{\"vertex\":{\"shader\":0}}"))
    ;

    var ast = try parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);

    const pngb = try assembler.assemble(testing.allocator, &ast);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Should have JSON descriptor in data section (unescaped)
    try testing.expectEqual(@as(u16, 1), module.data.count());
    try testing.expectEqualStrings("{\"vertex\":{\"shader\":0}}", module.data.get(@enumFromInt(0)));

    // Bytecode should have create_render_pipeline
    try testing.expectEqual(
        @as(u8, @intFromEnum(opcodes.OpCode.create_render_pipeline)),
        module.bytecode[0],
    );
}

test "shorthand frame format with inline commands" {
    const source: [:0]const u8 =
        \\(frame "main"
        \\    (begin-render-pass :texture 0 :load clear :store store)
        \\    (set-pipeline 0)
        \\    (draw 3 1)
        \\    (end-pass)
        \\    (submit))
    ;

    var ast = try parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);

    const pngb = try assembler.assemble(testing.allocator, &ast);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Should have frame name in strings
    try testing.expectEqual(@as(u16, 1), module.strings.count());
    try testing.expectEqualStrings("main", module.strings.get(@enumFromInt(0)));

    // Verify bytecode sequence contains expected opcodes
    var found_define_frame = false;
    var found_begin_render_pass = false;
    var found_set_pipeline = false;
    var found_draw = false;
    var found_end_pass = false;
    var found_submit = false;

    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.define_frame)) found_define_frame = true;
        if (byte == @intFromEnum(opcodes.OpCode.begin_render_pass)) found_begin_render_pass = true;
        if (byte == @intFromEnum(opcodes.OpCode.set_pipeline)) found_set_pipeline = true;
        if (byte == @intFromEnum(opcodes.OpCode.draw)) found_draw = true;
        if (byte == @intFromEnum(opcodes.OpCode.end_pass)) found_end_pass = true;
        if (byte == @intFromEnum(opcodes.OpCode.submit)) found_submit = true;
    }

    try testing.expect(found_define_frame);
    try testing.expect(found_begin_render_pass);
    try testing.expect(found_set_pipeline);
    try testing.expect(found_draw);
    try testing.expect(found_end_pass);
    try testing.expect(found_submit);
}

test "complete shorthand PBSF (web demo format)" {
    // This is the format used by the web demo
    const source: [:0]const u8 =
        \\(shader 0 "@vertex fn v() {} @fragment fn f() {}")
        \\(pipeline 0 (json "{\"vertex\":{\"shader\":0},\"fragment\":{\"shader\":0}}"))
        \\(frame "main"
        \\    (begin-render-pass :texture 0 :load clear :store store)
        \\    (set-pipeline 0)
        \\    (draw 3 1)
        \\    (end-pass)
        \\    (submit))
    ;

    var ast = try parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);

    const pngb = try assembler.assemble(testing.allocator, &ast);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify complete structure
    try testing.expectEqual(@as(u16, 1), module.strings.count()); // "main"
    try testing.expectEqual(@as(u16, 2), module.data.count()); // shader code + pipeline JSON

    // Verify opcodes in order
    try testing.expectEqual(
        @as(u8, @intFromEnum(opcodes.OpCode.create_shader_module)),
        module.bytecode[0],
    );
}

// ============================================================================
// String Escape Sequence Tests
// ============================================================================

test "escape sequences: backslash-quote in strings" {
    // Test that \" is unescaped to " in the output
    const source: [:0]const u8 =
        \\(pipeline 0 (json "{\"key\":\"value\"}"))
    ;

    var ast = try parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    const pngb = try assembler.assemble(testing.allocator, &ast);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // The JSON should have real quotes, not escaped ones
    const json = module.data.get(@enumFromInt(0));
    try testing.expectEqualStrings("{\"key\":\"value\"}", json);

    // Verify it's valid JSON by checking structure
    try testing.expect(json[0] == '{');
    try testing.expect(json[json.len - 1] == '}');
    try testing.expect(std.mem.indexOf(u8, json, "\"key\"") != null);
}

test "escape sequences: backslash-n for newlines" {
    const source: [:0]const u8 =
        \\(shader 0 "line1\nline2")
    ;

    var ast = try parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    const pngb = try assembler.assemble(testing.allocator, &ast);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const code = module.data.get(@enumFromInt(0));
    // Should contain actual newline character
    try testing.expect(std.mem.indexOf(u8, code, "\n") != null);
    try testing.expectEqualStrings("line1\nline2", code);
}

test "escape sequences: backslash-backslash" {
    const source: [:0]const u8 =
        \\(shader 0 "path\\to\\file")
    ;

    var ast = try parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    const pngb = try assembler.assemble(testing.allocator, &ast);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const code = module.data.get(@enumFromInt(0));
    // Should have single backslashes
    try testing.expectEqualStrings("path\\to\\file", code);
}

test "no escape sequences: string without backslashes unchanged" {
    const source: [:0]const u8 =
        \\(shader 0 "simple string")
    ;

    var ast = try parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    const pngb = try assembler.assemble(testing.allocator, &ast);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    try testing.expectEqualStrings("simple string", module.data.get(@enumFromInt(0)));
}
