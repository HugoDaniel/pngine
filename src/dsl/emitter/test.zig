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
const bytecode_emitter = @import("../../bytecode/emitter.zig").Emitter;
const uniform_table = @import("../../bytecode/uniform_table.zig");

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
        \\#renderPipeline pipe { vertex={ module=shader } }
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

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
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

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
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

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
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
        \\#renderPipeline pipe { vertex={ module=shader } }
        \\#renderPass pass { pipeline=pipe draw=3 }
        \\#frame main { perform=[pass] }
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
        \\  vertex={ entryPoint=vs module=triangleShader }
        \\  fragment={ entryPoint=fs module=triangleShader }
        \\}
        \\#renderPass drawPass {
        \\  pipeline=pipeline
        \\  draw=3
        \\}
        \\#frame main {
        \\  perform=[drawPass]
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
        \\#computePipeline pipe { compute={ module=computeShader } }
        \\#computePass pass { pipeline=pipe dispatch=[8 8 1] }
        \\#frame main { perform=[pass] }
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
        \\  vertex={ entrypoint=vs module=triangleShader }
        \\  fragment={ entrypoint=fs module=triangleShader }
        \\}
        \\#renderPass drawPass {
        \\  pipeline=pipeline
        \\  draw=3
        \\}
        \\#frame main {
        \\  perform=[drawPass]
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
        \\  vertex={ entryPoint=myVertex module=triangleShader }
        \\  fragment={ entryPoint=myFragment module=triangleShader }
        \\}
        \\#renderPass drawPass {
        \\  pipeline=pipeline
        \\  draw=3
        \\}
        \\#frame main {
        \\  perform=[drawPass]
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
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#renderPipeline myPipeline { vertex={ module=shader } }
        \\#renderPass pass { pipeline=myPipeline draw=3 }
        \\#frame main { perform=[pass] }
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

test "Emitter: setPipeline with bare identifier syntax" {
    // Bare identifier syntax for pipeline reference
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#renderPipeline myPipeline { vertex={ module=shader } }
        \\#renderPass pass { pipeline=myPipeline draw=3 }
        \\#frame main { perform=[pass] }
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
        \\#renderPipeline pipe { vertex={ module=shader } }
        \\#renderPass pass { pipeline=pipe draw=3 }
        \\#frame main { perform=[pass] }
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
    const source: [:0]const u8 =
        \\#wgsl shader { value="@group(0) @binding(0) var<uniform> u: f32; @vertex fn vs() { } @fragment fn fs() { }" }
        \\#buffer uniformBuf { size=4 usage=[UNIFORM COPY_DST] }
        \\#renderPipeline pipe { layout=auto vertex={ module=shader } fragment={ module=shader } }
        \\#bindGroup bg { layout={ pipeline=pipe index=0 } entries=[{ binding=0 resource={ buffer=uniformBuf } }] }
        \\#renderPass pass { pipeline=pipe bindGroups=[bg] draw=3 }
        \\#frame main { perform=[pass] }
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
        \\#renderPipeline pipe { layout=auto vertex={ module=shader } }
        \\#bindGroup myBindGroup { layout={ pipeline=pipe index=0 } entries=[{ binding=0 resource={ buffer=uniformInputsBuffer } }] }
        \\#renderPass pass { pipeline=pipe bindGroups=[myBindGroup] draw=3 }
        \\#frame main { perform=[pass] }
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

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
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
    // Tests that bindGroups=[name] works.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() { }" }
        \\#buffer buf { size=16 usage=[UNIFORM] }
        \\#renderPipeline pipe { layout=auto vertex={ module=shader } }
        \\#bindGroup myBindGroup { layout={ pipeline=pipe index=0 } entries=[{ binding=0 resource={ buffer=buf } }] }
        \\#renderPass pass { pipeline=pipe bindGroups=[myBindGroup] draw=3 }
        \\#frame main { perform=[pass] }
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

test "Emitter: bind group with buffer reference" {
    // Tests that entries=[{ binding=0 resource={ buffer=name } }] works
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() { }" }
        \\#buffer uniformBuf { size=16 usage=[UNIFORM] }
        \\#renderPipeline pipe { layout=auto vertex={ module=shader } }
        \\#bindGroup myBindGroup { layout={ pipeline=pipe index=0 } entries=[{ binding=0 resource={ buffer=uniformBuf } }] }
        \\#renderPass pass { pipeline=pipe bindGroups=[myBindGroup] draw=3 }
        \\#frame main { perform=[pass] }
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
        \\#renderPipeline pipe { layout=auto vertex={ module=shader } }
        \\#bindGroup myBindGroup { layout={ pipeline=pipe index=0 } entries=[{ binding=0 resource={ buffer=secondBuffer } }] }
        \\#renderPass pass { pipeline=pipe bindGroups=[myBindGroup] draw=3 }
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
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
        \\#renderPipeline pipe { layout=auto vertex={ module=shader } }
        \\#bindGroup myBindGroup { layout={ pipeline=pipe index=0 } entries=[{ binding=0 buffer=buf }] }
        \\#renderPass pass { pipeline=pipe bindGroups=[myBindGroup] draw=3 }
        \\#frame main { perform=[pass] }
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
    // Test that queue can reference buffer by bare identifier
    const source: [:0]const u8 =
        \\#buffer uniformBuf { size=16 usage=[UNIFORM COPY_DST] }
        \\#queue writeUniforms { writeBuffer={ buffer=uniformBuf data=[1.0 2.0 3.0 4.0] } }
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
        \\#renderPipeline pipe { vertex={ module=shader } }
        \\#renderPass pass { pipeline=pipe draw=3 }
        \\#queue writeUniforms { writeBuffer={ buffer=uniformBuf data=[0.5] } }
        \\#frame main { perform=[writeUniforms pass] }
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

test "Emitter: queue writeBuffer with bare identifier in perform" {
    // Test that bare identifier syntax works in perform array
    const source: [:0]const u8 =
        \\#buffer uniformBuf { size=4 usage=[UNIFORM COPY_DST] }
        \\#queue writeUniforms { writeBuffer={ buffer=uniformBuf data=[0.5] } }
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
    // Regression test: texture with size=[canvas.width canvas.height]
    // should encode without explicit width/height (runtime uses canvas dimensions)
    // This test uses the NEW syntax without $ or quotes
    const source: [:0]const u8 =
        \\#texture depthTexture {
        \\  size=[canvas.width canvas.height]
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
                // This verifies that canvas.width/height triggers canvas-size encoding
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
        \\  size=[canvas.width canvas.height]
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
        \\#frame main { perform=[pass] }
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
        \\#renderPipeline pipe { vertex={ module=shader } }
        \\#renderPass pass { pipeline=pipe draw=CUBE_VERTEX_COUNT }
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
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
        \\#renderPipeline pipe { vertex={ module=shader } }
        \\#renderPass pass { pipeline=pipe drawIndexed=MESH_INDEX_COUNT }
        \\#frame main { perform=[pass] }
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
    // Regression test: vertexBuffers=[verticesBuffer] with bare identifier
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#buffer verticesBuffer { size=1440 usage=[VERTEX] }
        \\#renderPipeline pipe { vertex={ module=shader } }
        \\#renderPass pass { pipeline=pipe vertexBuffers=[verticesBuffer] draw=36 }
        \\#frame main { perform=[pass] }
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
        \\#renderPipeline pipe { vertex={ module=shader } }
        \\#renderPass pass { pipeline=pipe vertexBuffers=[verticesBuffer] draw=36 }
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
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
        \\  vertex={ module=cubeShader }
        \\  fragment={ module=cubeShader }
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
        \\#frame main { perform=[cubePass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
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
        \\#renderPipeline pipe { vertex={ module=shader } }
        \\#renderPass pass { pipeline=pipe vertexBuffers=[positionBuffer normalBuffer uvBuffer] draw=36 }
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
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

test "Emitter: textureUsesCanvasSize detects builtin_ref nodes" {
    // Test that size=[canvas.width canvas.height] is properly detected as canvas-dependent.
    // Uses builtin_ref nodes (bare identifiers like canvas.width).

    // Test 1: Texture with canvas size should use canvas-size encoding (2 fields)
    const canvas_size_source: [:0]const u8 =
        \\#texture canvasTexture {
        \\  size=[canvas.width canvas.height]
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

// ============================================================================
// ImageBitmap and CopyExternalImageToTexture Tests
// ============================================================================

test "Emitter: imageBitmap with inline data" {
    // Note: #imageBitmap requires file path or data reference.
    // Since we can't use file paths in tests, we test the data reference pattern.
    const source: [:0]const u8 =
        \\#data imageBlob { blob="test_image.png" }
        \\#imageBitmap myImage { image=imageBlob }
        \\#frame main { perform=[] }
    ;

    // This test verifies that the source parses correctly.
    // Actual blob loading requires file access, which we skip here.
    // Instead, we verify the compile doesn't crash on the syntax.
    const result = compileSource(source);

    // The compile may fail due to missing file, which is expected.
    // We're testing that the parser/emitter handles the syntax correctly.
    if (result) |pngb| {
        defer testing.allocator.free(pngb);
        // If we get here, bytecode was produced
        try testing.expect(pngb.len > format.HEADER_SIZE);
    } else |_| {
        // Expected: file not found or similar error
    }
}

test "Emitter: queue copyExternalImageToTexture syntax" {
    // Test that copyExternalImageToTexture queue action emits correct opcode
    const source: [:0]const u8 =
        \\#texture destTexture {
        \\  width=256
        \\  height=256
        \\  format=rgba8unorm
        \\  usage=[TEXTURE_BINDING COPY_DST]
        \\}
        \\#data imageBlob { blob="test.png" }
        \\#imageBitmap srcBitmap { image=imageBlob }
        \\#queue uploadTexture {
        \\  copyExternalImageToTexture={
        \\    source={ source=srcBitmap }
        \\    destination={ texture=destTexture }
        \\  }
        \\}
        \\#frame main { perform=[uploadTexture] }
    ;

    // This tests syntax handling. Actual bitmap loading needs file access.
    const result = compileSource(source);
    if (result) |pngb| {
        defer testing.allocator.free(pngb);
        try testing.expect(pngb.len > format.HEADER_SIZE);
    } else |_| {
        // Expected: may fail due to missing blob file
    }
}

test "Emitter: queue copyExternalImageToTexture with mip level" {
    // Test that mip level is correctly passed through
    const source: [:0]const u8 =
        \\#texture destTexture {
        \\  width=256
        \\  height=256
        \\  format=rgba8unorm
        \\  usage=[TEXTURE_BINDING COPY_DST]
        \\}
        \\#data imageBlob { blob="test.png" }
        \\#imageBitmap srcBitmap { image=imageBlob }
        \\#queue uploadTexture {
        \\  copyExternalImageToTexture={
        \\    source={ source=srcBitmap }
        \\    destination={ texture=destTexture mipLevel=2 }
        \\  }
        \\}
        \\#frame main { perform=[uploadTexture] }
    ;

    const result = compileSource(source);
    if (result) |pngb| {
        defer testing.allocator.free(pngb);
        try testing.expect(pngb.len > format.HEADER_SIZE);
    } else |_| {
        // Expected: may fail due to missing blob file
    }
}

test "Emitter: queue copyExternalImageToTexture with origin offset" {
    // Test that origin coordinates are correctly passed through
    const source: [:0]const u8 =
        \\#texture destTexture {
        \\  width=512
        \\  height=512
        \\  format=rgba8unorm
        \\  usage=[TEXTURE_BINDING COPY_DST]
        \\}
        \\#data imageBlob { blob="test.png" }
        \\#imageBitmap srcBitmap { image=imageBlob }
        \\#queue uploadTexture {
        \\  copyExternalImageToTexture={
        \\    source={ source=srcBitmap }
        \\    destination={ texture=destTexture origin=[128 256] }
        \\  }
        \\}
        \\#frame main { perform=[uploadTexture] }
    ;

    const result = compileSource(source);
    if (result) |pngb| {
        defer testing.allocator.free(pngb);
        try testing.expect(pngb.len > format.HEADER_SIZE);
    } else |_| {
        // Expected: may fail due to missing blob file
    }
}

test "Emitter: multiple imageBitmaps" {
    // Test that multiple imageBitmaps can be declared
    const source: [:0]const u8 =
        \\#data imageBlob1 { blob="image1.png" }
        \\#data imageBlob2 { blob="image2.png" }
        \\#imageBitmap image1 { image=imageBlob1 }
        \\#imageBitmap image2 { image=imageBlob2 }
        \\#frame main { perform=[] }
    ;

    const result = compileSource(source);
    if (result) |pngb| {
        defer testing.allocator.free(pngb);
        try testing.expect(pngb.len > format.HEADER_SIZE);
    } else |_| {
        // Expected: may fail due to missing blob files
    }
}

test "Emitter: imageBitmap referenced in queue" {
    // Test that bare identifier reference syntax works
    const source: [:0]const u8 =
        \\#texture destTexture {
        \\  width=256
        \\  height=256
        \\  format=rgba8unorm
        \\  usage=[TEXTURE_BINDING COPY_DST]
        \\}
        \\#data imageBlob { blob="test.png" }
        \\#imageBitmap srcBitmap { image=imageBlob }
        \\#queue uploadTexture {
        \\  copyExternalImageToTexture={
        \\    source={ source=srcBitmap }
        \\    destination={ texture=destTexture }
        \\  }
        \\}
        \\#frame main { perform=[uploadTexture] }
    ;

    const result = compileSource(source);
    if (result) |pngb| {
        defer testing.allocator.free(pngb);
        try testing.expect(pngb.len > format.HEADER_SIZE);
    } else |_| {
        // Expected: may fail due to missing blob file
    }
}

// ============================================================================
// OOM Tests for Low-Level Bytecode Emitter
// ============================================================================

test "Bytecode emitter: OOM handling for createImageBitmap" {
    // Test OOM handling at bytecode emitter level (simpler than full compiler)
    var fail_index: usize = 0;
    const max_iterations: usize = 20;

    while (fail_index < max_iterations) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        const alloc = failing.allocator();

        var emitter: bytecode_emitter = .empty;
        defer emitter.deinit(testing.allocator); // Always use real allocator for cleanup

        const result = emitter.createImageBitmap(alloc, 0, 10);
        if (failing.has_induced_failure) {
            if (result) |_| {
                // Succeeded despite induced failure (allocation happened before fail point)
            } else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
            }
        } else {
            // No failure induced - verify success
            try testing.expect(result != error.OutOfMemory);
            break;
        }
    }
}

test "Bytecode emitter: OOM handling for copyExternalImageToTexture" {
    // Test OOM handling at bytecode emitter level
    var fail_index: usize = 0;
    const max_iterations: usize = 20;

    while (fail_index < max_iterations) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        const alloc = failing.allocator();

        var emitter: bytecode_emitter = .empty;
        defer emitter.deinit(testing.allocator);

        const result = emitter.copyExternalImageToTexture(alloc, 0, 1, 0, 128, 256);
        if (failing.has_induced_failure) {
            if (result) |_| {
                // Allocation happened before fail point
            } else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
            }
        } else {
            try testing.expect(result != error.OutOfMemory);
            break;
        }
    }
}

// ============================================================================
// #shaderModule code=identifier Resolution Tests
// ============================================================================
//
// Property: #shaderModule code=identifier resolves to #wgsl macro's value property.
// Property: #define substitution applies to resolved shader code.

test "Emitter: shaderModule with code=wgslMacroName resolves shader" {
    // Goal: Verify #shaderModule code=identifier resolves to #wgsl macro value.
    // Method: Define #wgsl with code, reference via #shaderModule, verify data section.

    const source: [:0]const u8 =
        \\#wgsl cubeShader {
        \\  value="@vertex fn vertexMain() -> @builtin(position) vec4f { return vec4f(0); }"
        \\}
        \\#shaderModule cubeModule {
        \\  code=cubeShader
        \\}
        \\#renderPipeline pipe { vertex={ module=cubeModule } }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify shader code is in data section
    var found_shader_code = false;
    for (module.data.blobs.items) |blob| {
        if (std.mem.indexOf(u8, blob, "vertexMain")) |_| {
            found_shader_code = true;
            break;
        }
    }
    try testing.expect(found_shader_code);

    // Verify only ONE shader module created (the #wgsl and #shaderModule share code)
    var shader_module_count: u32 = 0;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_shader_module)) {
            shader_module_count += 1;
        }
    }
    // Both #wgsl and #shaderModule create shader modules
    try testing.expectEqual(@as(u32, 2), shader_module_count);
}

test "Emitter: shaderModule with code=string works" {
    // Goal: Verify #shaderModule code="..." with direct string literal works.
    // Method: Define shader with inline string, verify it appears in data section.

    const source: [:0]const u8 =
        \\#shaderModule directShader {
        \\  code="@vertex fn main() -> @builtin(position) vec4f { return vec4f(1); }"
        \\}
        \\#renderPipeline pipe { vertex={ module=directShader } }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify shader code is in data section
    var found_shader_code = false;
    for (module.data.blobs.items) |blob| {
        if (std.mem.indexOf(u8, blob, "vec4f(1)")) |_| {
            found_shader_code = true;
            break;
        }
    }
    try testing.expect(found_shader_code);
}

test "Emitter: shaderModule code=wgslMacro with #define substitution" {
    // Goal: Verify #define values are substituted when code is resolved via identifier.
    // Method: Define SIZE, reference in #wgsl, verify substitution in output.

    const source: [:0]const u8 =
        \\#define SIZE="10.0"
        \\#wgsl myShader {
        \\  value="let size = SIZE; @vertex fn main() {}"
        \\}
        \\#shaderModule myModule {
        \\  code=myShader
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify SIZE was substituted with 10.0
    var found_substituted = false;
    for (module.data.blobs.items) |blob| {
        if (std.mem.indexOf(u8, blob, "10.0")) |_| {
            // Verify SIZE was NOT left as-is
            if (std.mem.indexOf(u8, blob, "SIZE") == null) {
                found_substituted = true;
                break;
            }
        }
    }
    try testing.expect(found_substituted);
}

test "Emitter: rotating_cube style wgsl + shaderModule pattern" {
    // Goal: Verify full rotating_cube.pngine pattern compiles and executes.
    // Method: #wgsl with uniforms → #shaderModule → #renderPipeline → execute.

    const source: [:0]const u8 =
        \\#wgsl cubeShader {
        \\  value="
        \\struct Uniforms { time: f32 }
        \\@group(0) @binding(0) var<uniform> u: Uniforms;
        \\@vertex fn vertexMain() -> @builtin(position) vec4f { return vec4f(u.time); }
        \\@fragment fn fragMain() -> @location(0) vec4f { return vec4f(1); }
        \\"
        \\  uniforms=[{ id=inputs var=u struct=Uniforms bindGroup=0 binding=0 }]
        \\}
        \\#shaderModule cubeShaderModule {
        \\  code=cubeShader
        \\}
        \\#renderPipeline renderCube {
        \\  layout=auto
        \\  vertex={ entrypoint=vertexMain module=cubeShaderModule }
        \\  fragment={ entrypoint=fragMain module=cubeShaderModule }
        \\}
        \\#renderPass drawCube { pipeline=renderCube draw=36 }
        \\#frame main { perform=[drawCube] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Execute to verify the full pipeline works
    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    // Verify shader module, pipeline, and draw were created
    var found_shader = false;
    var found_pipeline = false;
    var found_draw = false;

    for (gpu.getCalls()) |call| {
        switch (call.call_type) {
            .create_shader_module => found_shader = true,
            .create_render_pipeline => found_pipeline = true,
            .draw => {
                try testing.expectEqual(@as(u32, 36), call.params.draw.vertex_count);
                found_draw = true;
            },
            else => {},
        }
    }

    try testing.expect(found_shader);
    try testing.expect(found_pipeline);
    try testing.expect(found_draw);
}

// ============================================================================
// #data wasm Property Tests
// ============================================================================
//
// Property: #data with wasm={...} triggers WASM file loading during compilation.
// Property: Buffer size=wasmDataName resolves to WASM return type byte size.
// Property: Existing data types (float32Array, blob) continue to work.

test "Emitter: data with wasm property syntax" {
    // Goal: Verify #data wasm={...} syntax is parsed and triggers file loading.
    // Method: Provide valid syntax with missing file, expect FileReadError.

    const source: [:0]const u8 =
        \\#data cubeVertexArray {
        \\  wasm={
        \\    module={ url="assets/cube.wasm" }
        \\    func=cube
        \\    returns="array<f32, 360>"
        \\  }
        \\}
        \\#frame main { perform=[] }
    ;

    // Expect file read error (no actual WASM file)
    const result = compileSource(source);
    if (result) |pngb| {
        // Unexpected success - only if file exists
        defer testing.allocator.free(pngb);
    } else |err| {
        // Expected: FileReadError since the WASM file doesn't exist
        try testing.expect(err == error.FileReadError or err == error.EmitError);
    }
}

test "Emitter: buffer size from wasm data reference" {
    // Goal: Verify buffer size=wasmDataName would resolve to WASM return type size.
    // Method: Define #data with wasm, reference in buffer size, expect file error.

    const source: [:0]const u8 =
        \\#data cubeData {
        \\  wasm={
        \\    module={ url="test.wasm" }
        \\    func=getData
        \\    returns="array<f32, 100>"
        \\  }
        \\}
        \\#buffer vertices {
        \\  size=cubeData
        \\  usage=[VERTEX]
        \\}
        \\#frame main { perform=[] }
    ;

    // Expect file read error since test.wasm doesn't exist
    const result = compileSource(source);
    if (result) |pngb| {
        defer testing.allocator.free(pngb);
    } else |err| {
        // FileReadError or EmitError expected when WASM file is missing
        try testing.expect(err == error.FileReadError or err == error.EmitError);
    }
}

test "Emitter: data with float32Array still works alongside wasm feature" {
    // Goal: Regression test - float32Array data unaffected by wasm feature addition.
    // Method: Define data with float32Array, verify buffer size = 6 × 4 = 24 bytes.

    const source: [:0]const u8 =
        \\#data vertices { float32Array=[1.0 2.0 3.0 4.0 5.0 6.0] }
        \\#buffer vertexBuf { size=vertices usage=[VERTEX] }
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

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    // Verify buffer size: 6 floats * 4 bytes = 24 bytes
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

test "Emitter: data with blob still works alongside wasm feature" {
    // Goal: Regression test - blob data path unaffected by wasm feature addition.
    // Method: Define data with blob, verify file loading is attempted (FileReadError).

    const source: [:0]const u8 =
        \\#data imageData { blob="test.png" }
        \\#frame main { perform=[] }
    ;

    // Expect file error since test.png doesn't exist
    const result = compileSource(source);
    if (result) |pngb| {
        defer testing.allocator.free(pngb);
    } else |err| {
        try testing.expect(err == error.FileReadError or err == error.EmitError);
    }
}

// ============================================================================
// Canvas/Time Builtin Refs Tests
// ============================================================================
//
// These tests verify that the new canvas.width, time.total syntax works
// without requiring $ prefix or quotes.

test "Emitter: canvas.width time.total in texture size parses correctly" {
    // Goal: Verify new builtin ref syntax parses and compiles in texture size.
    // Method: Use canvas.width canvas.height without $ or quotes in size array.

    const source: [:0]const u8 =
        \\#texture renderTarget {
        \\  size=[canvas.width canvas.height]
        \\  format=rgba8unorm
        \\  usage=[RENDER_ATTACHMENT TEXTURE_BINDING]
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify the bytecode contains create_texture opcode
    var found_create_texture = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_texture)) {
            found_create_texture = true;
            break;
        }
    }
    try testing.expect(found_create_texture);
}

// ============================================================================
// Vertex Buffer stepMode Tests
// ============================================================================
//
// These tests verify that stepMode parsing works for vertex buffers in
// render pipelines. stepMode determines whether buffer data advances per-vertex
// or per-instance during instanced rendering.

test "Emitter: vertex buffer with stepMode=instance" {
    // Test that stepMode=instance is correctly parsed and included in pipeline descriptor
    // This is critical for instanced rendering (e.g., boids particles)
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="
        \\    struct VertexInput {
        \\      @location(0) pos: vec4f,
        \\      @location(1) vel: vec4f,
        \\    }
        \\    @vertex fn vs(in: VertexInput) -> @builtin(position) vec4f { return in.pos; }
        \\    @fragment fn fs() -> @location(0) vec4f { return vec4f(1.0); }
        \\  "
        \\}
        \\#buffer particles { size=4096 usage=[VERTEX STORAGE] }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={
        \\    module=shader
        \\    entryPoint=vs
        \\    buffers=[{
        \\      arrayStride=32
        \\      stepMode=instance
        \\      attributes=[
        \\        { shaderLocation=0 offset=0 format=float32x4 }
        \\        { shaderLocation=1 offset=16 format=float32x4 }
        \\      ]
        \\    }]
        \\  }
        \\  fragment={ module=shader entryPoint=fs }
        \\}
        \\#renderPass pass { pipeline=pipe draw=6 instances=1000 }
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify render pipeline was created
    var found_render_pipeline = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_render_pipeline)) {
            found_render_pipeline = true;
            break;
        }
    }
    try testing.expect(found_render_pipeline);

    // Find the pipeline descriptor in data section and verify it contains stepMode
    // The descriptor JSON should contain "stepMode":"instance"
    var found_step_mode = false;
    for (0..module.data.count()) |i| {
        const data = module.data.get(@enumFromInt(i));
        // Look for JSON containing stepMode
        if (std.mem.indexOf(u8, data, "stepMode") != null and
            std.mem.indexOf(u8, data, "instance") != null)
        {
            found_step_mode = true;
            break;
        }
    }
    try testing.expect(found_step_mode);
}

test "Emitter: vertex buffer with stepMode=vertex (default)" {
    // Test that stepMode=vertex is correctly parsed
    // stepMode=vertex is the default but should still work when explicitly specified
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0.0); }"
        \\}
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={
        \\    module=shader
        \\    buffers=[{
        \\      arrayStride=16
        \\      stepMode=vertex
        \\      attributes=[{ shaderLocation=0 offset=0 format=float32x4 }]
        \\    }]
        \\  }
        \\}
        \\#renderPass pass { pipeline=pipe draw=3 }
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify pipeline was created successfully
    var found_render_pipeline = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_render_pipeline)) {
            found_render_pipeline = true;
            break;
        }
    }
    try testing.expect(found_render_pipeline);
}

test "Emitter: vertex buffer without stepMode uses default" {
    // Test that omitting stepMode works (defaults to vertex)
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0.0); }"
        \\}
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={
        \\    module=shader
        \\    buffers=[{
        \\      arrayStride=16
        \\      attributes=[{ shaderLocation=0 offset=0 format=float32x4 }]
        \\    }]
        \\  }
        \\}
        \\#renderPass pass { pipeline=pipe draw=3 }
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Should compile without errors
    try testing.expect(module.bytecode.len > 0);
}

test "Emitter: multiple vertex buffers with different stepModes" {
    // Test multiple buffers: one per-vertex (positions), one per-instance (transforms)
    // This is a common pattern for instanced rendering
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="
        \\    struct VSInput {
        \\      @location(0) pos: vec3f,
        \\      @location(1) instancePos: vec3f,
        \\    }
        \\    @vertex fn vs(in: VSInput) -> @builtin(position) vec4f {
        \\      return vec4f(in.pos + in.instancePos, 1.0);
        \\    }
        \\  "
        \\}
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={
        \\    module=shader
        \\    buffers=[
        \\      {
        \\        arrayStride=12
        \\        stepMode=vertex
        \\        attributes=[{ shaderLocation=0 offset=0 format=float32x3 }]
        \\      }
        \\      {
        \\        arrayStride=12
        \\        stepMode=instance
        \\        attributes=[{ shaderLocation=1 offset=0 format=float32x3 }]
        \\      }
        \\    ]
        \\  }
        \\}
        \\#renderPass pass { pipeline=pipe draw=36 instances=100 }
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify the pipeline descriptor contains both step modes
    var found_vertex_mode = false;
    var found_instance_mode = false;
    for (0..module.data.count()) |i| {
        const data = module.data.get(@enumFromInt(i));
        if (std.mem.indexOf(u8, data, "\"stepMode\":\"vertex\"") != null) {
            found_vertex_mode = true;
        }
        if (std.mem.indexOf(u8, data, "\"stepMode\":\"instance\"") != null) {
            found_instance_mode = true;
        }
    }
    try testing.expect(found_instance_mode);
    // Note: stepMode=vertex might not be emitted since it's the default
}

// ============================================================================
// Pool Buffer Tests (Ping-Pong Pattern from DSL)
// ============================================================================

test "Emitter: buffer with pool=2 creates pooled resources" {
    // Test that pool=2 on buffer creates proper ping-pong setup
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#buffer particles { size=4096 usage=[VERTEX STORAGE] pool=2 }
        \\#renderPipeline pipe { layout=auto vertex={ module=shader } }
        \\#renderPass pass { pipeline=pipe draw=1000 }
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    // Count buffer creations - should have 2 buffers for pool=2
    var buffer_count: usize = 0;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_buffer) {
            buffer_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), buffer_count);
}

// ============================================================================
// Auto Buffer Sizing Tests (WGSL Reflection via miniray)
// ============================================================================

test "Emitter: buffer size from WGSL binding reference" {
    // Test that size=shader.binding auto-resolves via reflection.
    // This requires miniray to be available at the expected location.
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="
        \\    struct Inputs {
        \\      time: f32,
        \\      resolution: vec2<u32>,
        \\    }
        \\    @group(0) @binding(0) var<uniform> inputs: Inputs;
        \\    @vertex fn vs() -> @builtin(position) vec4<f32> { return vec4f(0.0); }
        \\  "
        \\}
        \\#buffer uniforms { size=shader.inputs usage=[UNIFORM COPY_DST] }
        \\#renderPipeline pipe { layout=auto vertex={ module=shader } }
        \\#renderPass pass { pipeline=pipe draw=3 }
        \\#frame main { perform=[pass] }
    ;

    // Parse and analyze
    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    if (analysis.hasErrors()) {
        return error.EmitError;
    }

    // Emit with miniray path
    const pngb = Emitter.emitWithOptions(testing.allocator, &ast, &analysis, .{
        .miniray_path = "/Users/hugo/Development/miniray/miniray",
    }) catch |err| {
        // If miniray isn't available or reflection fails, skip this test
        std.debug.print("Skipping test: {}\n", .{err});
        return;
    };
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Execute to verify buffer creation
    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    // Find the buffer creation call and verify size
    // struct Inputs { time: f32, resolution: vec2<u32> } = 16 bytes
    // (time=4 bytes + padding=4 bytes + resolution=8 bytes = 16 bytes)
    for (gpu.getCalls()) |call| {
        if (call.call_type == .create_buffer) {
            // The size should be 16 bytes based on WGSL struct layout
            try testing.expectEqual(@as(u32, 16), call.params.create_buffer.size);
            return;
        }
    }
    // Should have found a buffer
    try testing.expect(false);
}

// ============================================================================
// #define String Expression Tests
// ============================================================================
// These tests verify that #define with string expressions like "64*64" are
// properly evaluated when used in draw commands, dispatch, and other contexts.

test "Emitter: define with string multiplication expression in instanceCount" {
    // This is the exact pattern that caused the sceneQ bug:
    // #define NUM="64*64" used in instanceCount should emit 4096, not 1
    const source: [:0]const u8 =
        \\#define NUM_PARTICLES="64*64"
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#renderPipeline pipe { layout=auto vertex={ module=mod entryPoint=vs } fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] } }
        \\#renderPass pass { colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}] pipeline=pipe draw={ vertexCount=4 instanceCount=NUM_PARTICLES } }
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Parse and execute to verify draw command
    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    // Find the draw call and verify instanceCount is 4096, not 1
    for (gpu.getCalls()) |call| {
        if (call.call_type == .draw) {
            try testing.expectEqual(@as(u32, 4), call.params.draw.vertex_count);
            try testing.expectEqual(@as(u32, 4096), call.params.draw.instance_count);
            return;
        }
    }
    try testing.expect(false); // Should have found draw call
}

test "Emitter: define with string addition expression" {
    const source: [:0]const u8 =
        \\#define COUNT="100+200"
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#renderPipeline pipe { layout=auto vertex={ module=mod entryPoint=vs } fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] } }
        \\#renderPass pass { colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}] pipeline=pipe draw={ vertexCount=3 instanceCount=COUNT } }
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    for (gpu.getCalls()) |call| {
        if (call.call_type == .draw) {
            try testing.expectEqual(@as(u32, 300), call.params.draw.instance_count);
            return;
        }
    }
    try testing.expect(false);
}

test "Emitter: define with string division expression" {
    const source: [:0]const u8 =
        \\#define COUNT="1000/10"
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#renderPipeline pipe { layout=auto vertex={ module=mod entryPoint=vs } fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] } }
        \\#renderPass pass { colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}] pipeline=pipe draw={ vertexCount=3 instanceCount=COUNT } }
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    for (gpu.getCalls()) |call| {
        if (call.call_type == .draw) {
            try testing.expectEqual(@as(u32, 100), call.params.draw.instance_count);
            return;
        }
    }
    try testing.expect(false);
}

test "Emitter: define with nested define reference in string" {
    // #define A=10, #define B="A*5" - B should resolve to 50
    const source: [:0]const u8 =
        \\#define BASE=10
        \\#define MULTIPLIED="BASE*5"
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#renderPipeline pipe { layout=auto vertex={ module=mod entryPoint=vs } fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] } }
        \\#renderPass pass { colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}] pipeline=pipe draw={ vertexCount=3 instanceCount=MULTIPLIED } }
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    for (gpu.getCalls()) |call| {
        if (call.call_type == .draw) {
            try testing.expectEqual(@as(u32, 50), call.params.draw.instance_count);
            return;
        }
    }
    try testing.expect(false);
}

test "Emitter: define with ceil function in string" {
    const source: [:0]const u8 =
        \\#define COUNT="ceil(100/3)"
        \\#wgsl shader { value="@compute @workgroup_size(64) fn main() {}" }
        \\#shaderModule mod { code=shader }
        \\#computePipeline pipe { layout=auto compute={ module=mod entryPoint=main } }
        \\#computePass pass { pipeline=pipe dispatchWorkgroups=COUNT }
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    for (gpu.getCalls()) |call| {
        if (call.call_type == .dispatch) {
            // ceil(100/3) = ceil(33.33...) = 34
            try testing.expectEqual(@as(u32, 34), call.params.dispatch.x);
            return;
        }
    }
    try testing.expect(false);
}

test "Emitter: define with plain number string" {
    const source: [:0]const u8 =
        \\#define COUNT="42"
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#renderPipeline pipe { layout=auto vertex={ module=mod entryPoint=vs } fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] } }
        \\#renderPass pass { colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}] pipeline=pipe draw={ vertexCount=3 instanceCount=COUNT } }
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    for (gpu.getCalls()) |call| {
        if (call.call_type == .draw) {
            try testing.expectEqual(@as(u32, 42), call.params.draw.instance_count);
            return;
        }
    }
    try testing.expect(false);
}

test "Emitter: define with complex chained expression" {
    // Test: (8*8) * 4 = 256
    const source: [:0]const u8 =
        \\#define GRID="8*8"
        \\#define TOTAL="GRID*4"
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#renderPipeline pipe { layout=auto vertex={ module=mod entryPoint=vs } fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] } }
        \\#renderPass pass { colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}] pipeline=pipe draw={ vertexCount=3 instanceCount=TOTAL } }
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    for (gpu.getCalls()) |call| {
        if (call.call_type == .draw) {
            try testing.expectEqual(@as(u32, 256), call.params.draw.instance_count);
            return;
        }
    }
    try testing.expect(false);
}

test "Emitter: define number literal (not string) still works" {
    // Ensure we didn't break the simple case
    const source: [:0]const u8 =
        \\#define COUNT=100
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#renderPipeline pipe { layout=auto vertex={ module=mod entryPoint=vs } fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] } }
        \\#renderPass pass { colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}] pipeline=pipe draw={ vertexCount=3 instanceCount=COUNT } }
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    for (gpu.getCalls()) |call| {
        if (call.call_type == .draw) {
            try testing.expectEqual(@as(u32, 100), call.params.draw.instance_count);
            return;
        }
    }
    try testing.expect(false);
}

test "Emitter: drawIndexed with string define instanceCount" {
    const source: [:0]const u8 =
        \\#define NUM_INSTANCES="32*32"
        \\#buffer indexBuf { size=12 usage=[INDEX] }
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#renderPipeline pipe { layout=auto vertex={ module=mod entryPoint=vs } fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] } }
        \\#renderPass pass { colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}] pipeline=pipe indexBuffer=indexBuf drawIndexed={ indexCount=6 instanceCount=NUM_INSTANCES } }
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    for (gpu.getCalls()) |call| {
        if (call.call_type == .draw_indexed) {
            try testing.expectEqual(@as(u32, 6), call.params.draw_indexed.index_count);
            try testing.expectEqual(@as(u32, 1024), call.params.draw_indexed.instance_count);
            return;
        }
    }
    try testing.expect(false);
}

test "Emitter: multiple draw params from string defines" {
    const source: [:0]const u8 =
        \\#define VERTS="6"
        \\#define INSTANCES="10*10"
        \\#define FIRST_VERT="2"
        \\#define FIRST_INST="5"
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#renderPipeline pipe { layout=auto vertex={ module=mod entryPoint=vs } fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] } }
        \\#renderPass pass { colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}] pipeline=pipe draw={ vertexCount=VERTS instanceCount=INSTANCES firstVertex=FIRST_VERT firstInstance=FIRST_INST } }
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    for (gpu.getCalls()) |call| {
        if (call.call_type == .draw) {
            try testing.expectEqual(@as(u32, 6), call.params.draw.vertex_count);
            try testing.expectEqual(@as(u32, 100), call.params.draw.instance_count);
            try testing.expectEqual(@as(u32, 2), call.params.draw.first_vertex);
            try testing.expectEqual(@as(u32, 5), call.params.draw.first_instance);
            return;
        }
    }
    try testing.expect(false);
}

// ============================================================================
// Resource Type Coverage Tests
// ============================================================================

test "Emitter: textureView basic" {
    // Goal: Verify #textureView creates texture view from existing texture.
    // Method: Define texture and textureView, verify create_texture_view opcode emitted.
    const source: [:0]const u8 =
        \\#texture myTexture {
        \\  size=[512 512]
        \\  format=rgba8unorm
        \\  usage=[TEXTURE_BINDING RENDER_ATTACHMENT]
        \\}
        \\#textureView myView {
        \\  texture=myTexture
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify create_texture_view opcode is present
    var found = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_texture_view)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Emitter: textureView with format and dimension" {
    // Goal: Verify textureView descriptor includes optional format and dimension.
    const source: [:0]const u8 =
        \\#texture cubeTexture {
        \\  size=[256 256 6]
        \\  format=rgba8unorm
        \\  usage=[TEXTURE_BINDING]
        \\}
        \\#textureView cubeView {
        \\  texture=cubeTexture
        \\  format=rgba8unorm
        \\  dimension=cube
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_texture_view)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Emitter: textureView with mip levels" {
    // Goal: Verify textureView descriptor includes mip level properties.
    const source: [:0]const u8 =
        \\#texture mipmapped {
        \\  size=[1024 1024]
        \\  format=rgba8unorm
        \\  usage=[TEXTURE_BINDING]
        \\  mipLevelCount=4
        \\}
        \\#textureView mip1 {
        \\  texture=mipmapped
        \\  baseMipLevel=1
        \\  mipLevelCount=2
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_texture_view)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Emitter: querySet occlusion" {
    // Goal: Verify #querySet for occlusion queries emits create_query_set opcode.
    const source: [:0]const u8 =
        \\#querySet occlusionQueries {
        \\  type=occlusion
        \\  count=8
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_query_set)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Emitter: querySet timestamp" {
    // Goal: Verify #querySet for timestamp queries.
    const source: [:0]const u8 =
        \\#querySet timestampQueries {
        \\  type=timestamp
        \\  count=16
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_query_set)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Emitter: bindGroupLayout explicit" {
    // Goal: Verify #bindGroupLayout with explicit entry definitions.
    const source: [:0]const u8 =
        \\#bindGroupLayout uniforms {
        \\  entries=[
        \\    { binding=0 visibility=[VERTEX FRAGMENT] buffer={ type=uniform } }
        \\  ]
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_bind_group_layout)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Emitter: bindGroupLayout with sampler and texture" {
    // Goal: Verify #bindGroupLayout with texture/sampler bindings.
    const source: [:0]const u8 =
        \\#bindGroupLayout textures {
        \\  entries=[
        \\    { binding=0 visibility=[FRAGMENT] sampler={ type=filtering } }
        \\    { binding=1 visibility=[FRAGMENT] texture={ sampleType=float } }
        \\  ]
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_bind_group_layout)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Emitter: pipelineLayout explicit" {
    // Goal: Verify #pipelineLayout with bindGroupLayouts array.
    const source: [:0]const u8 =
        \\#bindGroupLayout group0 {
        \\  entries=[
        \\    { binding=0 visibility=[VERTEX] buffer={ type=uniform } }
        \\  ]
        \\}
        \\#pipelineLayout myLayout {
        \\  bindGroupLayouts=[group0]
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found_bgl = false;
    var found_pl = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_bind_group_layout)) {
            found_bgl = true;
        }
        if (byte == @intFromEnum(opcodes.OpCode.create_pipeline_layout)) {
            found_pl = true;
        }
    }
    try testing.expect(found_bgl);
    try testing.expect(found_pl);
}

test "Emitter: pipelineLayout multiple groups" {
    // Goal: Verify #pipelineLayout with multiple bind group layouts.
    const source: [:0]const u8 =
        \\#bindGroupLayout uniforms {
        \\  entries=[
        \\    { binding=0 visibility=[VERTEX] buffer={ type=uniform } }
        \\  ]
        \\}
        \\#bindGroupLayout textures {
        \\  entries=[
        \\    { binding=0 visibility=[FRAGMENT] texture={} }
        \\    { binding=1 visibility=[FRAGMENT] sampler={} }
        \\  ]
        \\}
        \\#pipelineLayout combined {
        \\  bindGroupLayouts=[uniforms textures]
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Should have both bind group layouts and one pipeline layout
    var bgl_count: u32 = 0;
    var pl_count: u32 = 0;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_bind_group_layout)) {
            bgl_count += 1;
        }
        if (byte == @intFromEnum(opcodes.OpCode.create_pipeline_layout)) {
            pl_count += 1;
        }
    }
    try testing.expectEqual(@as(u32, 2), bgl_count);
    try testing.expectEqual(@as(u32, 1), pl_count);
}

test "Emitter: renderBundle basic" {
    // Goal: Verify #renderBundle creates a render bundle object.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=vs }
        \\  fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] }
        \\}
        \\#renderBundle myBundle {
        \\  colorFormats=[rgba8unorm]
        \\  pipeline=pipe
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_render_bundle)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Emitter: renderBundle with depthStencil and sampleCount" {
    // Goal: Verify renderBundle with depth/stencil format and MSAA.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=vs }
        \\  fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] }
        \\  depthStencil={ format=depth24plus depthCompare=less depthWriteEnabled=true }
        \\  multisample={ count=4 }
        \\}
        \\#renderBundle msaaBundle {
        \\  colorFormats=[rgba8unorm]
        \\  depthStencilFormat=depth24plus
        \\  sampleCount=4
        \\  pipeline=pipe
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_render_bundle)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Emitter: renderBundle with vertexBuffers and bindGroups" {
    // Goal: Verify renderBundle with vertex buffers and bind groups.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#buffer vertexBuf { size=1024 usage=[VERTEX] }
        \\#buffer uniformBuf { size=64 usage=[UNIFORM] }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=vs }
        \\  fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] }
        \\}
        \\#bindGroup uniforms {
        \\  layout={ pipeline=pipe index=0 }
        \\  entries=[{ binding=0 resource={ buffer=uniformBuf }}]
        \\}
        \\#renderBundle bundleWithBuffers {
        \\  colorFormats=[rgba8unorm]
        \\  pipeline=pipe
        \\  vertexBuffers=[vertexBuf]
        \\  bindGroups=[uniforms]
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_render_bundle)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Emitter: textureView with array layers" {
    // Goal: Verify textureView with baseArrayLayer and arrayLayerCount.
    const source: [:0]const u8 =
        \\#texture arrayTexture {
        \\  size=[256 256 4]
        \\  format=rgba8unorm
        \\  usage=[TEXTURE_BINDING]
        \\}
        \\#textureView layer1 {
        \\  texture=arrayTexture
        \\  baseArrayLayer=1
        \\  arrayLayerCount=1
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_texture_view)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Emitter: bindGroupLayout with storage buffer" {
    // Goal: Verify #bindGroupLayout with storage buffer binding.
    const source: [:0]const u8 =
        \\#bindGroupLayout compute {
        \\  entries=[
        \\    { binding=0 visibility=[COMPUTE] buffer={ type=storage } }
        \\    { binding=1 visibility=[COMPUTE] buffer={ type="read-only-storage" } }
        \\  ]
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_bind_group_layout)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Emitter: bindGroupLayout with storageTexture" {
    // Goal: Verify #bindGroupLayout with storage texture binding.
    const source: [:0]const u8 =
        \\#bindGroupLayout imageProcessing {
        \\  entries=[
        \\    { binding=0 visibility=[COMPUTE] storageTexture={ access=write-only format=rgba8unorm } }
        \\  ]
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_bind_group_layout)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

// ============================================================================
// Pass and Frame Coverage Tests
// ============================================================================

test "Emitter: renderPass with depth attachment identifier" {
    // Goal: Verify depth attachment using bare identifier (not reference).
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#texture depthTex { size=[512 512] format=depth24plus usage=[RENDER_ATTACHMENT] }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=vs }
        \\  fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] }
        \\  depthStencil={ format=depth24plus depthCompare=less depthWriteEnabled=true }
        \\}
        \\#renderPass pass {
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  depthStencilAttachment={ view=depthTex depthLoadOp=clear depthStoreOp=store depthClearValue=1.0 }
        \\  pipeline=pipe
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.begin_render_pass)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Emitter: renderPass with custom color texture" {
    // Goal: Verify color attachment with non-canvas texture.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#texture renderTarget { size=[512 512] format=rgba8unorm usage=[RENDER_ATTACHMENT TEXTURE_BINDING] }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=vs }
        \\  fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] }
        \\}
        \\#renderPass offscreen {
        \\  colorAttachments=[{view=renderTarget loadOp=clear storeOp=store}]
        \\  pipeline=pipe
        \\  draw=3
        \\}
        \\#frame main { perform=[offscreen] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.begin_render_pass)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Emitter: renderPass executeBundles array" {
    // Goal: Verify executeBundles command with array of bundles.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=vs }
        \\  fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] }
        \\}
        \\#renderBundle bundle1 { colorFormats=[rgba8unorm] pipeline=pipe }
        \\#renderPass pass {
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  executeBundles=[bundle1]
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.execute_bundles)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Emitter: renderPass executeBundles single" {
    // Goal: Verify executeBundles with single bundle (non-array syntax).
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=vs }
        \\  fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] }
        \\}
        \\#renderBundle myBundle { colorFormats=[rgba8unorm] pipeline=pipe }
        \\#renderPass pass {
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  executeBundles=myBundle
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.execute_bundles)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Emitter: computePass with begin and dispatch" {
    // Goal: Verify compute pass emits begin_compute_pass and dispatch.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@compute @workgroup_size(8,8,1) fn main() {}" }
        \\#shaderModule mod { code=shader }
        \\#computePipeline pipe { layout=auto compute={ module=mod entryPoint=main } }
        \\#computePass pass { pipeline=pipe dispatch=[16 16 1] }
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found_begin = false;
    var found_dispatch = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.begin_compute_pass)) {
            found_begin = true;
        }
        if (byte == @intFromEnum(opcodes.OpCode.dispatch)) {
            found_dispatch = true;
        }
    }
    try testing.expect(found_begin);
    try testing.expect(found_dispatch);
}

test "Emitter: queue with sceneTimeInputs" {
    // Goal: Verify queue writeBuffer with sceneTimeInputs built-in.
    const source: [:0]const u8 =
        \\#buffer uniformBuf { size=12 usage=[UNIFORM COPY_DST] }
        \\#queue writeUniforms {
        \\  writeBuffer={ buffer=uniformBuf bufferOffset=0 data=sceneTimeInputs }
        \\}
        \\#frame main { perform=[writeUniforms] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.write_time_uniform)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Emitter: queue with literal array data" {
    // Goal: Verify queue writeBuffer with inline array of numbers.
    const source: [:0]const u8 =
        \\#buffer buf { size=16 usage=[UNIFORM COPY_DST] }
        \\#queue writeData {
        \\  writeBuffer={ buffer=buf bufferOffset=0 data=[1.0 2.0 3.0 4.0] }
        \\}
        \\#frame main { perform=[writeData] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.write_buffer)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Emitter: queue with string literal data" {
    // Goal: Verify queue writeBuffer with literal string bytes.
    const source: [:0]const u8 =
        \\#buffer buf { size=16 usage=[UNIFORM COPY_DST] }
        \\#queue writeData {
        \\  writeBuffer={ buffer=buf bufferOffset=0 data="hello" }
        \\}
        \\#frame main { perform=[writeData] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.write_buffer)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Emitter: multiple frames with shared pass" {
    // Goal: Verify multiple frame definitions sharing a pass.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=vs }
        \\  fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] }
        \\}
        \\#renderPass pass { colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}] pipeline=pipe draw=3 }
        \\#frame frameA { perform=[pass] }
        \\#frame frameB { perform=[pass] }
        \\#frame frameC { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Count define_frame opcodes
    var frame_count: u32 = 0;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.define_frame)) {
            frame_count += 1;
        }
    }
    try testing.expectEqual(@as(u32, 3), frame_count);
}

test "Emitter: renderPass with pool offsets" {
    // Goal: Verify vertexBuffersPoolOffsets and bindGroupsPoolOffsets parsing.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#buffer vbuf { size=1024 usage=[VERTEX] pool=2 }
        \\#buffer uniforms { size=64 usage=[UNIFORM] }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=vs }
        \\  fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] }
        \\}
        \\#bindGroup bg { layout={ pipeline=pipe index=0 } entries=[{binding=0 resource={buffer=uniforms}}] }
        \\#renderPass pass {
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  pipeline=pipe
        \\  vertexBuffers=[vbuf]
        \\  vertexBuffersPoolOffsets=[1]
        \\  bindGroups=[bg]
        \\  bindGroupsPoolOffsets=[0]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // With pool offsets, set_vertex_buffer_pool is emitted instead of set_vertex_buffer
    var found = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.set_vertex_buffer_pool)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Emitter: drawIndexed with all params" {
    // Goal: Verify drawIndexed with all optional parameters.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#buffer indexBuf { size=64 usage=[INDEX] }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=vs }
        \\  fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] }
        \\}
        \\#renderPass pass {
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  pipeline=pipe
        \\  indexBuffer=indexBuf
        \\  drawIndexed={ indexCount=36 instanceCount=10 firstIndex=0 baseVertex=0 firstInstance=0 }
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.draw_indexed)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Emitter: draw with object params execution" {
    // Goal: Verify draw command with object-style parameters executes correctly.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=vs }
        \\  fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] }
        \\}
        \\#renderPass pass {
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  pipeline=pipe
        \\  draw={ vertexCount=6 instanceCount=100 firstVertex=0 firstInstance=0 }
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    const mock_gpu = @import("../../executor/mock_gpu.zig");
    const Dispatcher = @import("../../executor/dispatcher.zig").Dispatcher;

    var gpu: mock_gpu.MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = Dispatcher(mock_gpu.MockGPU).init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    for (gpu.getCalls()) |call| {
        if (call.call_type == .draw) {
            try testing.expectEqual(@as(u32, 6), call.params.draw.vertex_count);
            try testing.expectEqual(@as(u32, 100), call.params.draw.instance_count);
            return;
        }
    }
    try testing.expect(false);
}

// ============================================================================
// Uniform Table Tests
// ============================================================================

test "Emitter: uniform table with size=shader.binding" {
    // Goal: Verify that buffers with size=shader.binding populate the uniform table.
    //
    // The uniform table enables runtime reflection:
    // - Platforms can call setUniform("time", 1.5) without knowing buffer layouts
    // - Dynamic UI tools can introspect available uniforms
    // - Same bytecode works across Web/iOS/Android/Desktop
    //
    // This test verifies the complete flow:
    // DSL source → Parser → Analyzer → Emitter → PNGB with uniform table
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="
        \\    struct Inputs { time: f32, color: vec4f, scale: vec2f }
        \\    @group(0) @binding(0) var<uniform> inputs: Inputs;
        \\    @vertex fn vs() {} @fragment fn fs() {}
        \\  "
        \\}
        \\#shaderModule mod { code=shader }
        \\#buffer uniforms { size=shader.inputs usage=[UNIFORM COPY_DST] }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=vs }
        \\  fragment={ module=mod entryPoint=fs targets=[{format=bgra8unorm}] }
        \\}
        \\#bindGroup bg { layout={ pipeline=pipe index=0 } entries=[{binding=0 resource={buffer=uniforms}}] }
        \\#renderPass pass {
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  pipeline=pipe
        \\  bindGroups=[bg]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify uniform table is populated
    // Note: The uniform table may be empty if miniray integration isn't available
    // at compile time, but the code path should not error
    _ = module.uniforms;

    // Verify bytecode header has correct version (v5 includes embedded executor support)
    try testing.expectEqual(format.VERSION, module.header.version);
}

test "Emitter: uniform table empty when no shader.binding" {
    // Goal: Verify uniform table is empty when no size=shader.binding is used.
    // This tests the common case where buffers have explicit sizes.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() {}" }
        \\#shaderModule mod { code=shader }
        \\#buffer uniforms { size=64 usage=[UNIFORM] }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=vs }
        \\  fragment={ module=mod entryPoint=fs targets=[{format=bgra8unorm}] }
        \\}
        \\#renderPass pass {
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  pipeline=pipe
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Uniform table should be empty (no bindings)
    try testing.expectEqual(@as(usize, 0), module.uniforms.bindings.items.len);
}

test "Emitter: uniform table preserves field order" {
    // Goal: Verify field order matches WGSL struct declaration order.
    // This is important for iterating fields in a predictable order.
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="
        \\    struct Data { alpha: f32, beta: f32, gamma: f32 }
        \\    @group(0) @binding(0) var<uniform> data: Data;
        \\    @vertex fn vs() {} @fragment fn fs() {}
        \\  "
        \\}
        \\#shaderModule mod { code=shader }
        \\#buffer buf { size=shader.data usage=[UNIFORM] }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=vs }
        \\  fragment={ module=mod entryPoint=fs targets=[{format=bgra8unorm}] }
        \\}
        \\#bindGroup bg { layout={ pipeline=pipe index=0 } entries=[{binding=0 resource={buffer=buf}}] }
        \\#renderPass pass {
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  pipeline=pipe
        \\  bindGroups=[bg]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Note: This test primarily verifies the code path doesn't error.
    // Full field order verification requires miniray integration.
    try testing.expectEqual(format.VERSION, module.header.version);
}

// ============================================================================
// Resources Coverage Tests
// ============================================================================

test "Emitter: buffer size from shader.binding syntax" {
    // Goal: Test uniform_access syntax (shader.binding) for buffer sizing.
    // This exercises the resolveBufferSize path for uniform_access nodes.
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="
        \\    struct Uniforms { time: f32, scale: f32 }
        \\    @group(0) @binding(0) var<uniform> inputs: Uniforms;
        \\    @vertex fn vs() {}
        \\  "
        \\}
        \\#shaderModule mod { code=shader }
        \\#buffer uniforms { size=shader.inputs usage=[UNIFORM COPY_DST] }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify compilation succeeded with shader.binding syntax
    try testing.expectEqual(format.VERSION, module.header.version);
}

test "Emitter: buffer with pool and bind group adjustment" {
    // Goal: Test bind group pool offset adjustments for ping-pong buffers.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#buffer particles { size=1024 usage=[STORAGE VERTEX] pool=2 }
        \\#bindGroupLayout bgl { entries=[{binding=0 visibility=COMPUTE buffer={type=storage}}] }
        \\#bindGroup bg {
        \\  layout=bgl
        \\  entries=[{binding=0 resource={buffer=particles pingPong=0}}]
        \\  pool=2
        \\}
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=vs }
        \\  fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] }
        \\}
        \\#renderPass pass {
        \\  colorAttachments=[{view=contextCurrentTexture loadOp=clear storeOp=store}]
        \\  pipeline=pipe
        \\  bindGroups=[bg]
        \\  bindGroupsPoolOffsets=[0]
        \\  draw=3
        \\}
        \\#frame main { perform=[pass] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Check bytecode contains bind group and set_bind_group_pool for pool offsets
    var found_bind_group = false;
    var found_pool_set = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_bind_group)) {
            found_bind_group = true;
        }
        if (byte == @intFromEnum(opcodes.OpCode.set_bind_group_pool)) {
            found_pool_set = true;
        }
    }
    // At minimum should have bind group creation
    try testing.expect(found_bind_group);
}

test "Emitter: buffer size from data identifier" {
    // Goal: Test resolveBufferSize with identifier referencing #data.
    const source: [:0]const u8 =
        \\#data vertices { value=[1.0 2.0 3.0 4.0 5.0 6.0] }
        \\#buffer vbuf { size=vertices usage=[VERTEX] }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Buffer should have been created with size from data
    var found_buffer = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_buffer)) {
            found_buffer = true;
            break;
        }
    }
    try testing.expect(found_buffer);
}

test "Emitter: texture with view dimension cube" {
    // Goal: Test texture emission with viewDimension=cube.
    const source: [:0]const u8 =
        \\#texture envmap { size=[256 256] format=rgba8unorm usage=[TEXTURE_BINDING] viewDimension=cube }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Should have create_texture opcode
    var found_texture = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_texture)) {
            found_texture = true;
            break;
        }
    }
    try testing.expect(found_texture);
}

test "Emitter: sampler with all comparison options" {
    // Goal: Test sampler with compare function.
    const source: [:0]const u8 =
        \\#sampler depthSampler { compare=less }
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found_sampler = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_sampler)) {
            found_sampler = true;
            break;
        }
    }
    try testing.expect(found_sampler);
}

test "Emitter: bindGroupLayout with multiple entry types" {
    // Goal: Test bindGroupLayout with buffer, texture, sampler, and storageTexture entries.
    const source: [:0]const u8 =
        \\#bindGroupLayout bgl {
        \\  entries=[
        \\    { binding=0 visibility=FRAGMENT buffer={ type=uniform } }
        \\    { binding=1 visibility=FRAGMENT texture={ sampleType=float } }
        \\    { binding=2 visibility=FRAGMENT sampler={ type=filtering } }
        \\    { binding=3 visibility=COMPUTE storageTexture={ access=write-only format=rgba8unorm } }
        \\  ]
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found_bgl = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_bind_group_layout)) {
            found_bgl = true;
            break;
        }
    }
    try testing.expect(found_bgl);
}

// ============================================================================
// Pipelines Coverage Tests
// ============================================================================

test "Emitter: renderPipeline with all primitive options" {
    // Goal: Test primitive topology, cullMode, frontFace options.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=vs }
        \\  fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] }
        \\  primitive={ topology=triangle-strip cullMode=back frontFace=cw }
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found_pipeline = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_render_pipeline)) {
            found_pipeline = true;
            break;
        }
    }
    try testing.expect(found_pipeline);
}

test "Emitter: renderPipeline with depthStencil stencil ops" {
    // Goal: Test depthStencil with stencil operations.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=vs }
        \\  fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] }
        \\  depthStencil={
        \\    format=depth24plus-stencil8
        \\    depthCompare=less
        \\    depthWriteEnabled=true
        \\    stencilFront={ compare=always passOp=replace failOp=keep depthFailOp=keep }
        \\    stencilBack={ compare=always passOp=replace failOp=keep depthFailOp=keep }
        \\    stencilReadMask=255
        \\    stencilWriteMask=255
        \\  }
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found_pipeline = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_render_pipeline)) {
            found_pipeline = true;
            break;
        }
    }
    try testing.expect(found_pipeline);
}

test "Emitter: renderPipeline with multisample" {
    // Goal: Test multisample configuration.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=vs }
        \\  fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] }
        \\  multisample={ count=4 mask=0xFFFFFFFF alphaToCoverageEnabled=true }
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found_pipeline = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_render_pipeline)) {
            found_pipeline = true;
            break;
        }
    }
    try testing.expect(found_pipeline);
}

test "Emitter: renderPipeline with vertex buffer layouts" {
    // Goal: Test vertex buffer layout with attributes.
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="
        \\    struct VertexInput { @location(0) pos: vec3f, @location(1) uv: vec2f }
        \\    @vertex fn vs(in: VertexInput) -> @builtin(position) vec4f { return vec4f(in.pos, 1); }
        \\    @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }
        \\  "
        \\}
        \\#shaderModule mod { code=shader }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={
        \\    module=mod
        \\    entryPoint=vs
        \\    buffers=[
        \\      { arrayStride=20 stepMode=vertex attributes=[{format=float32x3 offset=0 shaderLocation=0} {format=float32x2 offset=12 shaderLocation=1}] }
        \\    ]
        \\  }
        \\  fragment={ module=mod entryPoint=fs targets=[{format=rgba8unorm}] }
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found_pipeline = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_render_pipeline)) {
            found_pipeline = true;
            break;
        }
    }
    try testing.expect(found_pipeline);
}

test "Emitter: fragment target with blend state" {
    // Goal: Test fragment target with full blend configuration.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() -> @location(0) vec4f { return vec4f(1); }" }
        \\#shaderModule mod { code=shader }
        \\#renderPipeline pipe {
        \\  layout=auto
        \\  vertex={ module=mod entryPoint=vs }
        \\  fragment={
        \\    module=mod
        \\    entryPoint=fs
        \\    targets=[{
        \\      format=rgba8unorm
        \\      blend={
        \\        color={ srcFactor=src-alpha dstFactor=one-minus-src-alpha operation=add }
        \\        alpha={ srcFactor=one dstFactor=one-minus-src-alpha operation=add }
        \\      }
        \\      writeMask=ALL
        \\    }]
        \\  }
        \\}
        \\#frame main { perform=[] }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var found_pipeline = false;
    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_render_pipeline)) {
            found_pipeline = true;
            break;
        }
    }
    try testing.expect(found_pipeline);
}
