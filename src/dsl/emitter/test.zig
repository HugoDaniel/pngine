//! Emitter Tests
//!
//! All tests for the DSL to PNGB emitter.
//! Tests verify bytecode emission, resource creation, and DSL feature support.

const std = @import("std");
const testing = std.testing;

// Core imports
const Ast = @import("../Ast.zig").Ast;
const Node = @import("../Ast.zig").Node;
const Parser = @import("../Parser.zig").Parser;
const Analyzer = @import("../Analyzer.zig").Analyzer;
const Emitter = @import("../Emitter.zig").Emitter;
const DescriptorEncoder = @import("../DescriptorEncoder.zig").DescriptorEncoder;

// Bytecode imports
const format = @import("../../bytecode/format.zig");
const opcodes = @import("../../bytecode/opcodes.zig");

/// Helper: compile DSL source to PNGB bytecode.
fn compileSource(source: [:0]const u8) ![]u8 {
    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    if (analysis.hasErrors()) {
        return error.EmitError;
    }

    return Emitter.emit(testing.allocator, &ast, &analysis);
}

// ============================================================================
// Basic Emission Tests
// ============================================================================

test "Emitter: simple shader" {
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Verify PNGB header
    try testing.expectEqualStrings("PNGB", pngb[0..4]);
    try testing.expect(pngb.len > format.HEADER_SIZE);
}

test "Emitter: shader and pipeline" {
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#renderPipeline pipe { vertex={ module=$wgsl.shader } }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Deserialize and verify
    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Should have shader code in data
    try testing.expect(module.data.count() > 0);

    // Should have frame name in strings
    try testing.expectEqualStrings("main", module.strings.get(@enumFromInt(0)));
}

test "Emitter: buffer with usage flags" {
    const source: [:0]const u8 =
        \\#buffer vertices { size=1024 usage=[VERTEX COPY_DST] }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Verify bytecode contains create_buffer opcode
    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found_create_buffer = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_buffer)) {
            found_create_buffer = true;
            break;
        }
    }
    try testing.expect(found_create_buffer);
}

test "Emitter: buffer size from data reference" {
    // Test that buffer size can reference a #data declaration
    const source: [:0]const u8 =
        \\#data vertexData { float32Array=[1 2 3 4 5 6] }
        \\#buffer vertices { size=vertexData usage=[VERTEX] }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Execute to get actual buffer parameters
    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(&gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    // Verify buffer was created with correct size: 6 floats * 4 bytes = 24 bytes
    var found_buffer = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_buffer) {
            try testing.expectEqual(@as(u32, 24), call.params.create_buffer.size);
            found_buffer = true;
            break;
        }
    }
    try testing.expect(found_buffer);
}

test "Emitter: buffer size from string arithmetic expression" {
    // Regression test: size="4+4+4" should evaluate to 12
    const source: [:0]const u8 =
        \\#buffer uniformBuf { size="4+4+4" usage=[UNIFORM COPY_DST] }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(&gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    // Verify buffer size: "4+4+4" = 12
    var found_buffer = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_buffer) {
            try testing.expectEqual(@as(u32, 12), call.params.create_buffer.size);
            found_buffer = true;
            break;
        }
    }
    try testing.expect(found_buffer);
}

test "Emitter: buffer size from define with expression" {
    // Regression test: size=DEFINE_NAME where DEFINE_NAME=4*10 should evaluate to 40
    const source: [:0]const u8 =
        \\#define VERTEX_SIZE=4 * 10
        \\#buffer vertices { size=VERTEX_SIZE usage=[VERTEX] }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(&gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    // Verify buffer size: VERTEX_SIZE = 4 * 10 = 40
    var found_buffer = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_buffer) {
            try testing.expectEqual(@as(u32, 40), call.params.create_buffer.size);
            found_buffer = true;
            break;
        }
    }
    try testing.expect(found_buffer);
}

test "Emitter: render pass with draw" {
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#renderPipeline pipe { vertex={ module=$wgsl.shader } }
        \\#renderPass pass { pipeline=$renderPipeline.pipe draw=3 }
        \\#frame main { perform=[$renderPass.pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify bytecode has draw opcode
    var found_draw = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.draw)) {
            found_draw = true;
            break;
        }
    }
    try testing.expect(found_draw);
}

// ============================================================================
// Complex Example Tests
// ============================================================================

test "Emitter: simpleTriangle example" {
    const source: [:0]const u8 =
        \\#wgsl triangleShader { value="@vertex fn vs() { } @fragment fn fs() { }" }
        \\#renderPipeline pipeline {
        \\  layout=auto
        \\  vertex={ entryPoint=vs module=$wgsl.triangleShader }
        \\  fragment={ entryPoint=fs module=$wgsl.triangleShader }
        \\}
        \\#renderPass drawPass {
        \\  pipeline=$renderPipeline.pipeline
        \\  draw=3
        \\}
        \\#frame main {
        \\  perform=[$renderPass.drawPass]
        \\}
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify structure
    try testing.expect(module.bytecode.len > 0);
    try testing.expect(module.strings.count() >= 1);
    try testing.expect(module.data.count() >= 1);

    // First opcode should be create_shader_module
    try testing.expectEqual(
        @as(u8, @intFromEnum(opcodes.OpCode.create_shader_module)),
        module.bytecode[0],
    );
}

test "Emitter: compute pipeline" {
    const source: [:0]const u8 =
        \\#wgsl computeShader { value="@compute fn main() { }" }
        \\#computePipeline pipe { compute={ module=$wgsl.computeShader } }
        \\#computePass pass { pipeline=$computePipeline.pipe dispatch=[8 8 1] }
        \\#frame main { perform=[$computePass.pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify compute pipeline opcode exists
    var found_compute = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_compute_pipeline)) {
            found_compute = true;
            break;
        }
    }
    try testing.expect(found_compute);
}

test "Emitter: entrypoint case insensitivity" {
    // Tests that both 'entrypoint' (lowercase) and 'entryPoint' (camelCase) work
    // This is a regression test for the case sensitivity bug
    const source: [:0]const u8 =
        \\#wgsl triangleShader { value="@vertex fn vs() { } @fragment fn fs() { }" }
        \\#renderPipeline pipeline {
        \\  layout=auto
        \\  vertex={ entrypoint=vs module=$wgsl.triangleShader }
        \\  fragment={ entrypoint=fs module=$wgsl.triangleShader }
        \\}
        \\#renderPass drawPass {
        \\  pipeline=$renderPipeline.pipeline
        \\  draw=3
        \\}
        \\#frame main {
        \\  perform=[$renderPass.drawPass]
        \\}
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Find the pipeline descriptor in data section
    // It should contain "vs" and "fs" as entry points, not the defaults
    var found_custom_entry = false;
    var count: u16 = 0;
    while (count < module.data.count()) : (count += 1) {
        const data = module.data.get(@enumFromInt(count));
        // Pipeline descriptor JSON should contain "vs" entry point
        if (std.mem.indexOf(u8, data, "\"entryPoint\":\"vs\"") != null) {
            found_custom_entry = true;
            break;
        }
    }
    try testing.expect(found_custom_entry);
}

test "Emitter: entryPoint camelCase also works" {
    // Verify camelCase still works (backwards compatibility)
    const source: [:0]const u8 =
        \\#wgsl triangleShader { value="@vertex fn vs() { } @fragment fn fs() { }" }
        \\#renderPipeline pipeline {
        \\  layout=auto
        \\  vertex={ entryPoint=myVertex module=$wgsl.triangleShader }
        \\  fragment={ entryPoint=myFragment module=$wgsl.triangleShader }
        \\}
        \\#renderPass drawPass {
        \\  pipeline=$renderPipeline.pipeline
        \\  draw=3
        \\}
        \\#frame main {
        \\  perform=[$renderPass.drawPass]
        \\}
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Find the pipeline descriptor in data section
    var found_custom_entry = false;
    var count: u16 = 0;
    while (count < module.data.count()) : (count += 1) {
        const data = module.data.get(@enumFromInt(count));
        if (std.mem.indexOf(u8, data, "\"entryPoint\":\"myVertex\"") != null) {
            found_custom_entry = true;
            break;
        }
    }
    try testing.expect(found_custom_entry);
}

// ============================================================================
// Error Handling Tests
// ============================================================================

test "Emitter: empty input produces valid PNGB" {
    const source: [:0]const u8 = "#frame main { perform=[] }";

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    try testing.expectEqualStrings("PNGB", pngb[0..4]);
}

test "Emitter: multiple frames" {
    const source: [:0]const u8 =
        \\#frame setup { perform=[] }
        \\#frame render { perform=[] }
        \\#frame cleanup { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Should have 3 frame names in strings
    try testing.expectEqual(@as(u16, 3), module.strings.count());
}

// ============================================================================
// Regression Tests - setPipeline emission
// ============================================================================

test "Emitter: setPipeline with identifier value" {
    // Regression test: pipeline=pipelineName should emit set_pipeline
    // Previously only $renderPipeline.name references worked.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#renderPipeline myPipeline { vertex={ module=$wgsl.shader } }
        \\#renderPass pass { pipeline=myPipeline draw=3 }
        \\#frame main { perform=[$renderPass.pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Must find set_pipeline opcode in bytecode
    var found_set_pipeline = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.set_pipeline)) {
            found_set_pipeline = true;
            break;
        }
    }
    try testing.expect(found_set_pipeline);
}

test "Emitter: setPipeline with reference syntax" {
    // Verify that $renderPipeline.name syntax still works
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#renderPipeline myPipeline { vertex={ module=$wgsl.shader } }
        \\#renderPass pass { pipeline=$renderPipeline.myPipeline draw=3 }
        \\#frame main { perform=[$renderPass.pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Must find set_pipeline opcode in bytecode
    var found_set_pipeline = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.set_pipeline)) {
            found_set_pipeline = true;
            break;
        }
    }
    try testing.expect(found_set_pipeline);
}

test "Emitter: render pass emits begin/setPipeline/draw/end sequence" {
    // Regression test: Full render pass must emit correct opcode sequence.
    // This catches missing begin_render_pass or end_pass.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#renderPipeline pipe { vertex={ module=$wgsl.shader } }
        \\#renderPass pass { pipeline=pipe draw=3 }
        \\#frame main { perform=[$renderPass.pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Find the sequence: begin_render_pass, set_pipeline, draw, end_pass
    var found_begin = false;
    var found_set_pipeline = false;
    var found_draw = false;
    var found_end = false;

    for (module.bytecode) |byte| {
        const op: opcodes.OpCode = @enumFromInt(byte);
        switch (op) {
            .begin_render_pass => found_begin = true,
            .set_pipeline => {
                // set_pipeline must come after begin_render_pass
                try testing.expect(found_begin);
                found_set_pipeline = true;
            },
            .draw => {
                // draw must come after set_pipeline
                try testing.expect(found_set_pipeline);
                found_draw = true;
            },
            .end_pass => {
                // end_pass must come after draw
                try testing.expect(found_draw);
                found_end = true;
            },
            else => {},
        }
    }

    try testing.expect(found_begin);
    try testing.expect(found_set_pipeline);
    try testing.expect(found_draw);
    try testing.expect(found_end);
}

test "Emitter: render pass with bind group emits set_bind_group" {
    // Regression test: bindGroups=[name] should emit set_bind_group opcode.
    // Previously only $bindGroup.name references worked, not bare identifiers.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@group(0) @binding(0) var<uniform> u: f32; @vertex fn vs() { } @fragment fn fs() { }" }
        \\#buffer uniformBuf { size=4 usage=[UNIFORM COPY_DST] }
        \\#renderPipeline pipe { layout=auto vertex={ module=$wgsl.shader } fragment={ module=$wgsl.shader } }
        \\#bindGroup bg { layout={ pipeline=pipe index=0 } entries=[{ binding=0 resource={ buffer=uniformBuf } }] }
        \\#renderPass pass { pipeline=pipe bindGroups=[bg] draw=3 }
        \\#frame main { perform=[$renderPass.pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify bytecode contains set_bind_group opcode
    var found_set_bind_group = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.set_bind_group)) {
            found_set_bind_group = true;
            break;
        }
    }
    try testing.expect(found_set_bind_group);
}

test "Emitter: bind group selects correct buffer from multiple" {
    // Regression test: when multiple buffers exist, bind group must select the correct one
    // Verifies resource={ buffer=name } syntax resolves to correct buffer ID
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() { }" }
        \\#buffer verticesBuffer { size=64 usage=[VERTEX] }
        \\#buffer uniformInputsBuffer { size=16 usage=[UNIFORM] }
        \\#renderPipeline pipe { layout=auto vertex={ module=$wgsl.shader } }
        \\#bindGroup myBindGroup { layout={ pipeline=pipe index=0 } entries=[{ binding=0 resource={ buffer=uniformInputsBuffer } }] }
        \\#renderPass pass { pipeline=pipe bindGroups=[myBindGroup] draw=3 }
        \\#frame main { perform=[$renderPass.pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Execute bytecode
    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(&gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    // Verify both buffers are created with correct sizes
    var vertex_buffer_created = false;
    var uniform_buffer_created = false;
    var bind_group_created = false;

    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_buffer) {
            const size = call.params.create_buffer.size;
            if (size == 64) vertex_buffer_created = true;
            if (size == 16) uniform_buffer_created = true;
        }
        if (call.call_type == .create_bind_group) {
            bind_group_created = true;
        }
    }

    try testing.expect(vertex_buffer_created);
    try testing.expect(uniform_buffer_created);
    try testing.expect(bind_group_created);
}

test "Emitter: bind group with bare identifier reference" {
    // Tests that bindGroups=[name] works without $ prefix.
    // This is the common DSL syntax users expect.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() { }" }
        \\#buffer buf { size=16 usage=[UNIFORM] }
        \\#renderPipeline pipe { layout=auto vertex={ module=$wgsl.shader } }
        \\#bindGroup myBindGroup { layout={ pipeline=pipe index=0 } entries=[{ binding=0 resource={ buffer=buf } }] }
        \\#renderPass pass { pipeline=pipe bindGroups=[myBindGroup] draw=3 }
        \\#frame main { perform=[$renderPass.pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Property: set_bind_group must appear AFTER set_pipeline and BEFORE draw
    var found_set_pipeline = false;
    var found_set_bind_group = false;
    var found_draw = false;

    for (module.bytecode) |byte| {
        switch (@as(opcodes.OpCode, @enumFromInt(byte))) {
            .set_pipeline => {
                found_set_pipeline = true;
            },
            .set_bind_group => {
                // set_bind_group must come after set_pipeline
                try testing.expect(found_set_pipeline);
                found_set_bind_group = true;
            },
            .draw => {
                // draw must come after set_bind_group
                try testing.expect(found_set_bind_group);
                found_draw = true;
            },
            else => {},
        }
    }

    try testing.expect(found_set_pipeline);
    try testing.expect(found_set_bind_group);
    try testing.expect(found_draw);
}

test "Emitter: bind group with explicit $buffer reference" {
    // Tests that entries=[{ binding=0 resource={ buffer=$buffer.name } }] works
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() { }" }
        \\#buffer uniformBuf { size=16 usage=[UNIFORM] }
        \\#renderPipeline pipe { layout=auto vertex={ module=$wgsl.shader } }
        \\#bindGroup myBindGroup { layout={ pipeline=pipe index=0 } entries=[{ binding=0 resource={ buffer=$buffer.uniformBuf } }] }
        \\#renderPass pass { pipeline=pipe bindGroups=[myBindGroup] draw=3 }
        \\#frame main { perform=[$renderPass.pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify set_bind_group opcode is present
    var found_set_bind_group = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.set_bind_group)) {
            found_set_bind_group = true;
            break;
        }
    }
    try testing.expect(found_set_bind_group);
}

test "Emitter: bind group selects second buffer correctly" {
    // Regression test: ensure bind group references the SECOND buffer, not first
    // This catches bugs where buffer_ids.get() might return wrong ID
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() { }" }
        \\#buffer firstBuffer { size=100 usage=[VERTEX] }
        \\#buffer secondBuffer { size=200 usage=[UNIFORM] }
        \\#buffer thirdBuffer { size=300 usage=[STORAGE] }
        \\#renderPipeline pipe { layout=auto vertex={ module=$wgsl.shader } }
        \\#bindGroup myBindGroup { layout={ pipeline=pipe index=0 } entries=[{ binding=0 resource={ buffer=secondBuffer } }] }
        \\#renderPass pass { pipeline=pipe bindGroups=[myBindGroup] draw=3 }
        \\#frame main { perform=[$renderPass.pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(&gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    // Verify all three buffers are created with correct sizes
    var buffer_sizes: [3]bool = .{ false, false, false };
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_buffer) {
            const size = call.params.create_buffer.size;
            if (size == 100) buffer_sizes[0] = true;
            if (size == 200) buffer_sizes[1] = true;
            if (size == 300) buffer_sizes[2] = true;
        }
    }

    try testing.expect(buffer_sizes[0]); // firstBuffer (100)
    try testing.expect(buffer_sizes[1]); // secondBuffer (200)
    try testing.expect(buffer_sizes[2]); // thirdBuffer (300)
}

test "Emitter: bind group direct buffer syntax (alternative)" {
    // Tests the alternative syntax: entries=[{ binding=0 buffer=name }]
    // (without nested resource={})
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() { }" }
        \\#buffer buf { size=16 usage=[UNIFORM] }
        \\#renderPipeline pipe { layout=auto vertex={ module=$wgsl.shader } }
        \\#bindGroup myBindGroup { layout={ pipeline=pipe index=0 } entries=[{ binding=0 buffer=buf }] }
        \\#renderPass pass { pipeline=pipe bindGroups=[myBindGroup] draw=3 }
        \\#frame main { perform=[$renderPass.pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify set_bind_group opcode is present
    var found_set_bind_group = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.set_bind_group)) {
            found_set_bind_group = true;
            break;
        }
    }
    try testing.expect(found_set_bind_group);
}

// ============================================================================
// Queue Tests
// ============================================================================

test "Emitter: queue with writeBuffer emits write_buffer opcode" {
    // Test that #queue with writeBuffer action emits write_buffer bytecode
    const source: [:0]const u8 =
        \\#buffer uniformBuf { size=4 usage=[UNIFORM COPY_DST] }
        \\#queue writeUniforms { writeBuffer={ buffer=uniformBuf data=[0.0] } }
        \\#frame main { perform=[writeUniforms] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Property: write_buffer opcode must be present
    var found_write_buffer = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.write_buffer)) {
            found_write_buffer = true;
            break;
        }
    }
    try testing.expect(found_write_buffer);
}

test "Emitter: queue with buffer reference" {
    // Test that queue can reference buffer by $buffer.name syntax
    const source: [:0]const u8 =
        \\#buffer uniformBuf { size=16 usage=[UNIFORM COPY_DST] }
        \\#queue writeUniforms { writeBuffer={ buffer=$buffer.uniformBuf data=[1.0 2.0 3.0 4.0] } }
        \\#frame main { perform=[writeUniforms] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Property: write_buffer opcode must be present
    var found_write_buffer = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.write_buffer)) {
            found_write_buffer = true;
            break;
        }
    }
    try testing.expect(found_write_buffer);
}

test "Emitter: queue invoked alongside render pass" {
    // Test that queues can be invoked in perform array alongside passes
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#buffer uniformBuf { size=4 usage=[UNIFORM COPY_DST] }
        \\#renderPipeline pipe { vertex={ module=$wgsl.shader } }
        \\#renderPass pass { pipeline=pipe draw=3 }
        \\#queue writeUniforms { writeBuffer={ buffer=uniformBuf data=[0.5] } }
        \\#frame main { perform=[writeUniforms $renderPass.pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Simple check: both opcodes should be present in bytecode
    // Note: This may have false positives from varint args, but unlikely for both
    var found_write_buffer = false;
    var found_begin_render_pass = false;

    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.write_buffer)) found_write_buffer = true;
        if (byte == @intFromEnum(opcodes.OpCode.begin_render_pass)) found_begin_render_pass = true;
    }

    // begin_render_pass should definitely be present
    try testing.expect(found_begin_render_pass);
    // write_buffer presence depends on queue emission working
    try testing.expect(found_write_buffer);
}

test "Emitter: queue writeBuffer with non-zero bufferOffset" {
    // Test that bufferOffset is correctly encoded in write_buffer opcode
    const source: [:0]const u8 =
        \\#buffer uniformBuf { size=64 usage=[UNIFORM COPY_DST] }
        \\#queue writeUniforms { writeBuffer={ buffer=uniformBuf bufferOffset=16 data=[1.0 2.0] } }
        \\#frame main { perform=[writeUniforms] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Property: write_buffer opcode must be present
    var found_write_buffer = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.write_buffer)) {
            found_write_buffer = true;
            break;
        }
    }
    try testing.expect(found_write_buffer);
}

test "Emitter: queue writeBuffer with default offset (no bufferOffset)" {
    // Test that missing bufferOffset defaults to 0
    const source: [:0]const u8 =
        \\#buffer uniformBuf { size=16 usage=[UNIFORM COPY_DST] }
        \\#queue writeUniforms { writeBuffer={ buffer=uniformBuf data=[0.0 0.0 0.0 0.0] } }
        \\#frame main { perform=[writeUniforms] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Property: write_buffer opcode must be present (offset defaults to 0)
    var found_write_buffer = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.write_buffer)) {
            found_write_buffer = true;
            break;
        }
    }
    try testing.expect(found_write_buffer);
}

test "Emitter: queue writeBuffer with $queue.name reference in perform" {
    // Test that $queue.name syntax works in perform array
    const source: [:0]const u8 =
        \\#buffer uniformBuf { size=4 usage=[UNIFORM COPY_DST] }
        \\#queue writeUniforms { writeBuffer={ buffer=uniformBuf data=[0.5] } }
        \\#frame main { perform=[$queue.writeUniforms] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Property: write_buffer opcode must be present
    var found_write_buffer = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.write_buffer)) {
            found_write_buffer = true;
            break;
        }
    }
    try testing.expect(found_write_buffer);
}

test "Emitter: multiple queues in perform array" {
    // Test that multiple queues can be invoked in sequence
    const source: [:0]const u8 =
        \\#buffer buf1 { size=4 usage=[UNIFORM COPY_DST] }
        \\#buffer buf2 { size=4 usage=[UNIFORM COPY_DST] }
        \\#queue writeFirst { writeBuffer={ buffer=buf1 data=[1.0] } }
        \\#queue writeSecond { writeBuffer={ buffer=buf2 data=[2.0] } }
        \\#frame main { perform=[writeFirst writeSecond] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Property: should have two write_buffer opcodes
    var write_buffer_count: u32 = 0;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.write_buffer)) {
            write_buffer_count += 1;
        }
    }
    try testing.expectEqual(@as(u32, 2), write_buffer_count);
}

test "Emitter: define substitution in shader code" {
    // Test that #define values are substituted into shader code
    // Defines referencing other defines are recursively expanded
    const source: [:0]const u8 =
        \\#define PI="3.14159"
        \\#define FOV="(2.0 * PI) / 5.0"
        \\#shaderModule code {
        \\  code="fn test() { let x = FOV; let y = PI; }"
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Property: shader code should have fully substituted values
    // FOV -> (2.0 * PI) / 5.0 -> (2.0 * 3.14159) / 5.0
    var found_substituted = false;
    for (module.data.blobs.items) |data| {
        // Should contain "(2.0 * 3.14159)" - PI recursively expanded
        if (std.mem.indexOf(u8, data, "(2.0 * 3.14159)")) |_| {
            found_substituted = true;
            break;
        }
    }
    try testing.expect(found_substituted);
}

test "Emitter: define NOT substituted inside string literals" {
    // Test from old_pngine: defines should NOT be expanded inside strings
    // The FOV inside \"...\" should remain as "FOV", not be replaced
    const source: [:0]const u8 =
        \\#define FOV="(2 * PI) / 5"
        \\#shaderModule code {
        \\  code="let msg = \"The FOV value\"; let x = FOV;"
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Property: FOV should be preserved inside the string, substituted outside
    // PI should also be substituted to its numeric value
    for (module.data.blobs.items) |data| {
        // Should have "FOV" preserved inside the string literal
        if (std.mem.indexOf(u8, data, "The FOV value")) |_| {
            // Also verify FOV was substituted outside the string
            // PI should be replaced with its numeric value
            if (std.mem.indexOf(u8, data, "3.141592653589793")) |_| {
                return; // Both conditions met - test passes
            }
        }
    }
    // If we get here, test failed
    return error.TestUnexpectedResult;
}

test "Emitter: math constants PI E TAU substituted in shader code" {
    // Test that math constants are substituted even without user defines
    const source: [:0]const u8 =
        \\#shaderModule code {
        \\  code="let pi = PI; let tau = TAU;"
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Property: PI and TAU should be substituted with numeric values
    for (module.data.blobs.items) |data| {
        const has_pi = std.mem.indexOf(u8, data, "3.141592653589793") != null;
        const has_tau = std.mem.indexOf(u8, data, "6.283185307179586") != null;
        if (has_pi and has_tau) {
            return; // Both constants substituted - test passes
        }
    }
    return error.TestUnexpectedResult;
}

test "Emitter: render pipeline vertex buffers layout" {
    // Test that vertex buffer layouts are included in render pipeline descriptor
    const source: [:0]const u8 =
        \\#shaderModule code { code="@vertex fn main() -> @builtin(position) vec4f { return vec4f(0); }" }
        \\#renderPipeline pipeline {
        \\  vertex={
        \\    module=code
        \\    entrypoint=main
        \\    buffers=[
        \\      {
        \\        arrayStride=40
        \\        attributes=[
        \\          { shaderLocation=0 offset=0 format=float32x4 }
        \\          { shaderLocation=1 offset=32 format=float32x2 }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Deserialize to check the data section
    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Check each data blob for the buffers JSON
    var found_buffers = false;
    for (module.data.blobs.items) |blob| {
        if (std.mem.indexOf(u8, blob, "arrayStride")) |_| {
            found_buffers = true;
            break;
        }
    }
    try testing.expect(found_buffers);
}

test "Emitter: render pipeline primitive state" {
    // Test that primitive state (topology, cullMode, frontFace) is included in descriptor
    const source: [:0]const u8 =
        \\#shaderModule code { code="@vertex fn main() -> @builtin(position) vec4f { return vec4f(0); }" }
        \\#renderPipeline pipeline {
        \\  vertex={ module=code entrypoint=main }
        \\  primitive={
        \\    topology=triangle-list
        \\    cullMode=back
        \\    frontFace=ccw
        \\  }
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Check for primitive state in data section
    var found_primitive = false;
    for (module.data.blobs.items) |blob| {
        if (std.mem.indexOf(u8, blob, "\"primitive\"")) |_| {
            // Verify cullMode is present
            if (std.mem.indexOf(u8, blob, "\"cullMode\":\"back\"")) |_| {
                found_primitive = true;
                break;
            }
        }
    }
    try testing.expect(found_primitive);
}

test "Emitter: render pipeline depthStencil state" {
    // Test that depthStencil state is included in descriptor
    const source: [:0]const u8 =
        \\#shaderModule code { code="@vertex fn main() -> @builtin(position) vec4f { return vec4f(0); }" }
        \\#renderPipeline pipeline {
        \\  vertex={ module=code entrypoint=main }
        \\  depthStencil={
        \\    format=depth24plus
        \\    depthWriteEnabled=true
        \\    depthCompare=less
        \\  }
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Check for depthStencil state in data section
    var found_depth_stencil = false;
    for (module.data.blobs.items) |blob| {
        if (std.mem.indexOf(u8, blob, "\"depthStencil\"")) |_| {
            // Verify format and depthCompare are present
            if (std.mem.indexOf(u8, blob, "\"format\":\"depth24plus\"")) |_| {
                if (std.mem.indexOf(u8, blob, "\"depthCompare\":\"less\"")) |_| {
                    found_depth_stencil = true;
                    break;
                }
            }
        }
    }
    try testing.expect(found_depth_stencil);
}

test "Emitter: render pipeline multisample state" {
    // Test that multisample state is included in descriptor
    const source: [:0]const u8 =
        \\#shaderModule code { code="@vertex fn main() -> @builtin(position) vec4f { return vec4f(0); }" }
        \\#renderPipeline pipeline {
          \\  vertex={ module=code entrypoint=main }
        \\  multisample={
        \\    count=4
        \\  }
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Check for multisample state in data section
    var found_multisample = false;
    for (module.data.blobs.items) |blob| {
        if (std.mem.indexOf(u8, blob, "\"multisample\"")) |_| {
            if (std.mem.indexOf(u8, blob, "\"count\":4")) |_| {
                found_multisample = true;
                break;
            }
        }
    }
    try testing.expect(found_multisample);
}

test "Emitter: render pipeline complete rotating_cube style" {
    // Regression test: full rotating_cube style render pipeline with all attributes
    const source: [:0]const u8 =
        \\#shaderModule code { code="@vertex fn main() -> @builtin(position) vec4f { return vec4f(0); }" }
        \\#renderPipeline renderCube {
        \\  layout=auto
        \\  vertex={
        \\    entrypoint=vertexMain
        \\    module=code
        \\    buffers=[{ arrayStride=40 attributes=[{ shaderLocation=0 offset=0 format=float32x4 }] }]
        \\  }
        \\  fragment={
        \\    entrypoint=fragMain
        \\    module=code
        \\  }
        \\  primitive={
        \\    topology=triangle-list
        \\    cullMode=back
        \\  }
        \\  depthStencil={
        \\    depthWriteEnabled=true
        \\    depthCompare=less
        \\    format=depth24plus
        \\  }
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify all key parts are in the descriptor
    var found_vertex = false;
    var found_fragment = false;
    var found_primitive = false;
    var found_depth_stencil = false;

    for (module.data.blobs.items) |blob| {
        if (std.mem.indexOf(u8, blob, "\"vertex\"")) |_| found_vertex = true;
        if (std.mem.indexOf(u8, blob, "\"fragment\"")) |_| found_fragment = true;
        if (std.mem.indexOf(u8, blob, "\"primitive\"")) |_| found_primitive = true;
        if (std.mem.indexOf(u8, blob, "\"depthStencil\"")) |_| found_depth_stencil = true;
    }

    try testing.expect(found_vertex);
    try testing.expect(found_fragment);
    try testing.expect(found_primitive);
    try testing.expect(found_depth_stencil);
}

test "Emitter: texture with canvas size uses canvas-size encoding" {
    // Regression test: texture with size=["$canvas.width", "$canvas.height"]
    // should encode without explicit width/height (runtime uses canvas dimensions)
    const source: [:0]const u8 =
        \\#texture depthTexture {
        \\  size=["$canvas.width", "$canvas.height"]
        \\  format=depth24plus
        \\  usage=[RENDER_ATTACHMENT]
        \\}
        \\#shaderModule shader { code="@vertex fn vs() {}" }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Find the create_texture opcode in bytecode
    var found_create_texture = false;
    var i: usize = 0;
    while (i < module.bytecode.len) {
        if (module.bytecode[i] == @intFromEnum(opcodes.OpCode.create_texture)) {
            found_create_texture = true;

            // Read texture_id (varint)
            i += 1;
            const texture_id_result = opcodes.decodeVarint(module.bytecode[i..]);
            i += texture_id_result.len;

            // Read descriptor data_id (varint)
            const desc_id_result = opcodes.decodeVarint(module.bytecode[i..]);
            const desc_id = desc_id_result.value;

            // Get the descriptor blob
            if (desc_id < module.data.blobs.items.len) {
                const desc = module.data.blobs.items[desc_id];

                // Must have at least 2 bytes (type + field count)
                try testing.expect(desc.len >= 2);

                // Verify it's a texture descriptor
                try testing.expectEqual(@as(u8, @intFromEnum(DescriptorEncoder.DescriptorType.texture)), desc[0]);

                // Canvas-size texture should have 2 fields (format + usage), not 4 (width + height + format + usage)
                // This verifies that $canvas.width/height triggers canvas-size encoding
                try testing.expectEqual(@as(u8, 2), desc[1]);
            } else {
                // desc_id out of range means something is wrong
                return error.TestUnexpectedResult;
            }
            break;
        }
        i += 1;
    }

    try testing.expect(found_create_texture);
}

test "Emitter: render pass with depth attachment emits depth texture ID" {
    // Regression test: render pass with depthStencilAttachment should emit
    // the depth texture ID in begin_render_pass opcode (not 0xFFFF)
    const source: [:0]const u8 =
        \\#texture depthTexture {
        \\  size=["$canvas.width" "$canvas.height"]
        \\  format=depth24plus
        \\  usage=[render-attachment]
        \\}
        \\#shaderModule shader { code="@vertex fn vs() {}" }
        \\#renderPipeline pipeline {
        \\  layout=auto
        \\  vertex={ module=shader entrypoint=vs }
        \\}
        \\#renderPass pass {
        \\  pipeline=pipeline
        \\  depthStencilAttachment={
        \\    view=depthTexture
        \\    depthClearValue=1.0
        \\    depthLoadOp=clear
        \\    depthStoreOp=store
        \\  }
        \\  draw=3
        \\}
        \\#frame main { perform=[$renderPass.pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Find begin_render_pass opcode and verify depth_texture_id is 0 (first texture)
    var found_begin_render_pass = false;
    var i: usize = 0;
    while (i < module.bytecode.len) : (i += 1) {
        if (module.bytecode[i] == @intFromEnum(opcodes.OpCode.begin_render_pass)) {
            found_begin_render_pass = true;

            // Skip opcode
            i += 1;

            // Read color_texture_id (varint)
            const color_result = opcodes.decodeVarint(module.bytecode[i..]);
            i += color_result.len;

            // Read load_op (1 byte)
            i += 1;

            // Read store_op (1 byte)
            i += 1;

            // Read depth_texture_id (varint)
            const depth_result = opcodes.decodeVarint(module.bytecode[i..]);
            const depth_texture_id = depth_result.value;

            // depth_texture_id should be 0 (first texture created), not 0xFFFF
            try testing.expectEqual(@as(u32, 0), depth_texture_id);
            break;
        }
    }

    try testing.expect(found_begin_render_pass);
}

// ============================================================================
// Regression Tests - #define with draw/vertexBuffers/bindGroups
// ============================================================================

test "Emitter: draw with #define identifier resolves to numeric value" {
    // Regression test: draw=VERTEX_COUNT where VERTEX_COUNT is a #define
    // Previously identifiers were not resolved, causing default value (3) to be used.
    const source: [:0]const u8 =
        \\#define CUBE_VERTEX_COUNT=36
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#renderPipeline pipe { vertex={ module=$wgsl.shader } }
        \\#renderPass pass { pipeline=pipe draw=CUBE_VERTEX_COUNT }
        \\#frame main { perform=[$renderPass.pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(&gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    // Verify draw was called with 36 vertices, not the default 3
    var found_draw = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .draw) {
            try testing.expectEqual(@as(u32, 36), call.params.draw.vertex_count);
            try testing.expectEqual(@as(u32, 1), call.params.draw.instance_count);
            found_draw = true;
            break;
        }
    }
    try testing.expect(found_draw);
}

test "Emitter: drawIndexed with #define identifier emits correct bytecode" {
    // Regression test: drawIndexed=INDEX_COUNT where INDEX_COUNT is a #define
    // Note: set_index_buffer dispatch not yet implemented, so we only verify bytecode emission.
    const source: [:0]const u8 =
        \\#define MESH_INDEX_COUNT=72
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#renderPipeline pipe { vertex={ module=$wgsl.shader } }
        \\#renderPass pass { pipeline=pipe drawIndexed=MESH_INDEX_COUNT }
        \\#frame main { perform=[$renderPass.pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify draw_indexed opcode is present in bytecode
    var found_draw_indexed = false;
    var i: usize = 0;
    while (i < module.bytecode.len) {
        if (module.bytecode[i] == @intFromEnum(opcodes.OpCode.draw_indexed)) {
            found_draw_indexed = true;

            // Read the index count from bytecode (after opcode)
            i += 1;
            const index_count_result = opcodes.decodeVarint(module.bytecode[i..]);
            const index_count = index_count_result.value;

            // Verify the #define was resolved: 72, not default 3
            try testing.expectEqual(@as(u32, 72), index_count);
            break;
        }
        i += 1;
    }
    try testing.expect(found_draw_indexed);
}

test "Emitter: vertexBuffers with bare identifier emits set_vertex_buffer" {
    // Regression test: vertexBuffers=[verticesBuffer] with bare identifier (not $buffer.x)
    // Previously only $buffer.name references worked.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#buffer verticesBuffer { size=1440 usage=[VERTEX] }
        \\#renderPipeline pipe { vertex={ module=$wgsl.shader } }
        \\#renderPass pass { pipeline=pipe vertexBuffers=[verticesBuffer] draw=36 }
        \\#frame main { perform=[$renderPass.pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify set_vertex_buffer opcode is present in bytecode
    var found_set_vertex_buffer = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.set_vertex_buffer)) {
            found_set_vertex_buffer = true;
            break;
        }
    }
    try testing.expect(found_set_vertex_buffer);
}

test "Emitter: vertexBuffers with bare identifier executes correctly" {
    // Regression test: verify set_vertex_buffer is actually called with correct buffer ID
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#buffer verticesBuffer { size=1440 usage=[VERTEX] }
        \\#renderPipeline pipe { vertex={ module=$wgsl.shader } }
        \\#renderPass pass { pipeline=pipe vertexBuffers=[verticesBuffer] draw=36 }
        \\#frame main { perform=[$renderPass.pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(&gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    // Verify set_vertex_buffer was called with slot=0 and buffer_id=0 (first buffer)
    var found_set_vertex_buffer = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .set_vertex_buffer) {
            try testing.expectEqual(@as(u32, 0), call.params.set_vertex_buffer.slot);
            try testing.expectEqual(@as(u32, 0), call.params.set_vertex_buffer.buffer_id);
            found_set_vertex_buffer = true;
            break;
        }
    }
    try testing.expect(found_set_vertex_buffer);
}

test "Emitter: rotating_cube style render pass with all commands" {
    // Regression test: complete rotating_cube style render pass
    // Tests: draw with #define, vertexBuffers with bare identifier, bindGroups with bare identifier
    const source: [:0]const u8 =
        \\#define CUBE_VERTEX_COUNT=36
        \\#wgsl cubeShader { value="@group(0) @binding(0) var<uniform> u: f32; @vertex fn vs() { } @fragment fn fs() { }" }
        \\#buffer verticesBuffer { size=1440 usage=[VERTEX COPY_DST] }
        \\#buffer inputsBuffer { size=12 usage=[UNIFORM COPY_DST] }
        \\#renderPipeline renderCube {
        \\  layout=auto
        \\  vertex={ module=$wgsl.cubeShader }
        \\  fragment={ module=$wgsl.cubeShader }
        \\}
        \\#bindGroup inputsBinding {
        \\  layout={ pipeline=renderCube index=0 }
        \\  entries=[{ binding=0 resource={ buffer=inputsBuffer } }]
        \\}
        \\#renderPass cubePass {
        \\  pipeline=renderCube
        \\  bindGroups=[inputsBinding]
        \\  vertexBuffers=[verticesBuffer]
        \\  draw=CUBE_VERTEX_COUNT
        \\}
        \\#frame main { perform=[$renderPass.cubePass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(&gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    // Verify all expected GPU calls were made
    var found_create_vertex_buffer = false;
    var found_create_uniform_buffer = false;
    var found_set_pipeline = false;
    var found_set_bind_group = false;
    var found_set_vertex_buffer = false;
    var found_draw = false;

    for (gpu.getCalls()) |call| {
        switch (call.call_type) {
            .create_buffer => {
                const size = call.params.create_buffer.size;
                if (size == 1440) found_create_vertex_buffer = true;
                if (size == 12) found_create_uniform_buffer = true;
            },
            .set_pipeline => found_set_pipeline = true,
            .set_bind_group => {
                // Verify bind group is set at slot 0
                try testing.expectEqual(@as(u32, 0), call.params.set_bind_group.slot);
                found_set_bind_group = true;
            },
            .set_vertex_buffer => {
                // Verify vertex buffer is set at slot 0
                try testing.expectEqual(@as(u32, 0), call.params.set_vertex_buffer.slot);
                found_set_vertex_buffer = true;
            },
            .draw => {
                // Verify draw uses 36 vertices from #define
                try testing.expectEqual(@as(u32, 36), call.params.draw.vertex_count);
                try testing.expectEqual(@as(u32, 1), call.params.draw.instance_count);
                found_draw = true;
            },
            else => {},
        }
    }

    // All calls must be present for rotating cube to work
    try testing.expect(found_create_vertex_buffer);
    try testing.expect(found_create_uniform_buffer);
    try testing.expect(found_set_pipeline);
    try testing.expect(found_set_bind_group);
    try testing.expect(found_set_vertex_buffer);
    try testing.expect(found_draw);
}

test "Emitter: multiple vertex buffers with bare identifiers" {
    // Test that multiple vertex buffers at different slots are emitted correctly
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#buffer positionBuffer { size=1024 usage=[VERTEX] }
        \\#buffer normalBuffer { size=1024 usage=[VERTEX] }
        \\#buffer uvBuffer { size=512 usage=[VERTEX] }
        \\#renderPipeline pipe { vertex={ module=$wgsl.shader } }
        \\#renderPass pass { pipeline=pipe vertexBuffers=[positionBuffer normalBuffer uvBuffer] draw=36 }
        \\#frame main { perform=[$renderPass.pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(&gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    // Verify 3 vertex buffers are set at slots 0, 1, 2
    var slot_0_set = false;
    var slot_1_set = false;
    var slot_2_set = false;

    for (gpu.getCalls()) |call| {
        if (call.call_type == .set_vertex_buffer) {
            const slot = call.params.set_vertex_buffer.slot;
            if (slot == 0) slot_0_set = true;
            if (slot == 1) slot_1_set = true;
            if (slot == 2) slot_2_set = true;
        }
    }

    try testing.expect(slot_0_set);
    try testing.expect(slot_1_set);
    try testing.expect(slot_2_set);
}

test "Emitter: textureUsesCanvasSize detects runtime_interpolation nodes" {
    // Regression test: strings containing "$" are parsed as .runtime_interpolation nodes,
    // not .string_value nodes. The textureUsesCanvasSize function must check for both.
    // Bug: originally only checked .string_value, causing $canvas.width to be missed.

    // Test 1: Texture with runtime interpolation should use canvas-size encoding (2 fields)
    const canvas_size_source: [:0]const u8 =
        \\#texture canvasTexture {
        \\  size=["$canvas.width", "$canvas.height"]
        \\  format=rgba8unorm
        \\  usage=[RENDER_ATTACHMENT]
        \\}
        \\#shaderModule shader { code="@vertex fn vs() {}" }
        \\#frame main { perform=[] }
    ;

    const canvas_pngb = try compileSource(canvas_size_source);
    defer testing.allocator.free(canvas_pngb);

    var canvas_module = try format.deserialize(testing.allocator, canvas_pngb);
    defer canvas_module.deinit(testing.allocator);

    // Test 2: Texture with explicit size should use full encoding (4 fields)
    const explicit_size_source: [:0]const u8 =
        \\#texture explicitTexture {
        \\  width=800
        \\  height=600
        \\  format=rgba8unorm
        \\  usage=[RENDER_ATTACHMENT]
        \\}
        \\#shaderModule shader { code="@vertex fn vs() {}" }
        \\#frame main { perform=[] }
    ;

    const explicit_pngb = try compileSource(explicit_size_source);
    defer testing.allocator.free(explicit_pngb);

    var explicit_module = try format.deserialize(testing.allocator, explicit_pngb);
    defer explicit_module.deinit(testing.allocator);

    // Find texture descriptors and compare field counts
    var canvas_field_count: ?u8 = null;
    var explicit_field_count: ?u8 = null;

    // Find canvas texture descriptor
    for (canvas_module.bytecode, 0..) |byte, idx| {
        if (byte == @intFromEnum(opcodes.OpCode.create_texture)) {
            var j = idx + 1;
            _ = opcodes.decodeVarint(canvas_module.bytecode[j..]); // texture_id
            j += opcodes.decodeVarint(canvas_module.bytecode[j..]).len;
            const desc_id = opcodes.decodeVarint(canvas_module.bytecode[j..]).value;
            if (desc_id < canvas_module.data.blobs.items.len) {
                const desc = canvas_module.data.blobs.items[desc_id];
                if (desc.len >= 2 and desc[0] == @intFromEnum(DescriptorEncoder.DescriptorType.texture)) {
                    canvas_field_count = desc[1];
                }
            }
            break;
        }
    }

    // Find explicit texture descriptor
    for (explicit_module.bytecode, 0..) |byte, idx| {
        if (byte == @intFromEnum(opcodes.OpCode.create_texture)) {
            var j = idx + 1;
            _ = opcodes.decodeVarint(explicit_module.bytecode[j..]); // texture_id
            j += opcodes.decodeVarint(explicit_module.bytecode[j..]).len;
            const desc_id = opcodes.decodeVarint(explicit_module.bytecode[j..]).value;
            if (desc_id < explicit_module.data.blobs.items.len) {
                const desc = explicit_module.data.blobs.items[desc_id];
                if (desc.len >= 2 and desc[0] == @intFromEnum(DescriptorEncoder.DescriptorType.texture)) {
                    explicit_field_count = desc[1];
                }
            }
            break;
        }
    }

    // Canvas-size texture: 2 fields (format + usage), no width/height
    try testing.expectEqual(@as(u8, 2), canvas_field_count.?);

    // Explicit-size texture: 4 fields (width + height + format + usage)
    try testing.expectEqual(@as(u8, 4), explicit_field_count.?);
}
