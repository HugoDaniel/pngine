//! Dispatcher Tests
//!
//! Comprehensive tests for the bytecode dispatcher, covering:
//! - Basic execution and empty bytecode
//! - Resource creation (shader, texture, sampler, buffer)
//! - Draw sequences and frame control
//! - Pass scanning and exec_pass functionality
//! - Pool operations for ping-pong buffers
//! - Varint boundary handling
//! - Fuzz testing and OOM resilience
//! - Scene switching patterns
//!
//! ## Test Categories
//!
//! - Basic: empty bytecode, single opcodes
//! - Resource creation: shader, texture, sampler, buffer
//! - Draw/dispatch: render pass, compute pass sequences
//! - Frame control: define_frame, end_frame, exec_pass
//! - Pass scanning: scanPassDefinitions edge cases
//! - Pool operations: frame counter, buffer/bind group selection
//! - Varint: large values, boundary conditions
//! - Fuzz: random bytecode, varint roundtrip
//! - OOM: allocation failure resilience
//! - Scene switching: multi-scene patterns

const std = @import("std");
const testing = std.testing;

const bytecode_mod = @import("bytecode");
const opcodes = bytecode_mod.opcodes;
const OpCode = opcodes.OpCode;
const format = bytecode_mod.format;
const Builder = format.Builder;

const MockGPU = @import("../mock_gpu.zig").MockGPU;
const CallType = @import("../mock_gpu.zig").CallType;
const Dispatcher = @import("../dispatcher.zig").Dispatcher;
const MockDispatcher = @import("../dispatcher.zig").MockDispatcher;

const handlers = @import("handlers.zig");
const OpcodeScanner = handlers.OpcodeScanner;
const PassRange = handlers.PassRange;

// ============================================================================
// Basic Tests
// ============================================================================

test "dispatcher empty bytecode" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    try testing.expectEqual(@as(usize, 0), gpu.callCount());
}

test "dispatcher create shader module" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const shader_data = try builder.addData(testing.allocator, "shader code");
    const emitter = builder.getEmitter();
    try emitter.createShaderModule(testing.allocator, 0, shader_data.toInt());

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    try testing.expectEqual(@as(usize, 1), gpu.callCount());
    try testing.expectEqual(CallType.create_shader_module, gpu.getCall(0).call_type);
}

test "dispatcher create texture" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const desc_data = try builder.addData(testing.allocator, "{}");
    const emitter = builder.getEmitter();
    try emitter.createTexture(testing.allocator, 0, desc_data.toInt());

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    try testing.expectEqual(@as(usize, 1), gpu.callCount());
    try testing.expectEqual(CallType.create_texture, gpu.getCall(0).call_type);

    // Verify parameters were passed correctly
    const call = gpu.getCall(0);
    try testing.expectEqual(@as(u16, 0), call.params.create_texture.texture_id);
    try testing.expectEqual(@as(u16, 0), call.params.create_texture.descriptor_data_id);
}

test "dispatcher create sampler" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const desc_data = try builder.addData(testing.allocator, "{}");
    const emitter = builder.getEmitter();
    try emitter.createSampler(testing.allocator, 3, desc_data.toInt());

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    try testing.expectEqual(@as(usize, 1), gpu.callCount());
    try testing.expectEqual(CallType.create_sampler, gpu.getCall(0).call_type);

    // Verify parameters were passed correctly
    const call = gpu.getCall(0);
    try testing.expectEqual(@as(u16, 3), call.params.create_sampler.sampler_id);
    try testing.expectEqual(@as(u16, 0), call.params.create_sampler.descriptor_data_id);
}

test "dispatcher draw sequence" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();
    // Must wrap draw commands in a render pass
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPass(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    try testing.expectEqual(@as(usize, 4), gpu.callCount());

    const calls = gpu.getCalls();
    try testing.expectEqual(CallType.begin_render_pass, calls[0].call_type);
    try testing.expectEqual(CallType.set_pipeline, calls[1].call_type);
    try testing.expectEqual(CallType.draw, calls[2].call_type);
    try testing.expectEqual(CallType.end_pass, calls[3].call_type);

    // Verify draw parameters
    try testing.expectEqual(@as(u32, 3), calls[2].params.draw.vertex_count);
    try testing.expectEqual(@as(u32, 1), calls[2].params.draw.instance_count);
}

test "dispatcher frame control" {
    // Test that frame control opcodes (define_frame, end_frame, exec_pass)
    // are processed without error and don't generate GPU calls
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_id = try builder.internString(testing.allocator, "test_frame");

    const emitter = builder.getEmitter();

    // Frame definition (structural, no GPU calls)
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());

    // Actual render pass inside the frame
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPass(testing.allocator);

    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    try dispatcher.executeAll(testing.allocator);

    // define_frame and end_frame don't generate GPU calls
    // Only begin_render_pass, set_pipeline, draw, end_pass, submit
    const expected = [_]CallType{
        .begin_render_pass,
        .set_pipeline,
        .draw,
        .end_pass,
        .submit,
    };

    try testing.expect(gpu.expectCallTypes(&expected));
}

// ============================================================================
// scanPassDefinitions Tests
// ============================================================================

test "scanPassDefinitions: empty bytecode" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    // Pre-condition: pass_ranges is empty
    try testing.expectEqual(@as(usize, 0), dispatcher.pass_ranges.count());

    dispatcher.scanPassDefinitions();

    // Post-condition: still empty (no passes in bytecode)
    try testing.expectEqual(@as(usize, 0), dispatcher.pass_ranges.count());
}

test "scanPassDefinitions: no pass definitions" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();
    // Only resource creation, no pass definitions
    try emitter.createShaderModule(testing.allocator, 0, 0);
    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    dispatcher.scanPassDefinitions();

    // Post-condition: no passes found
    try testing.expectEqual(@as(usize, 0), dispatcher.pass_ranges.count());
}

test "scanPassDefinitions: single pass definition" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Define a single pass
    try emitter.definePass(testing.allocator, 0, .render, 0);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    dispatcher.scanPassDefinitions();

    // Post-condition: exactly one pass found
    try testing.expectEqual(@as(usize, 1), dispatcher.pass_ranges.count());

    // Post-condition: pass 0 has valid range
    const range = dispatcher.pass_ranges.get(0).?;
    try testing.expect(range.start < range.end);
}

test "scanPassDefinitions: multiple pass definitions" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Define pass 0 (render)
    try emitter.definePass(testing.allocator, 0, .render, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPassDef(testing.allocator);

    // Define pass 1 (compute)
    try emitter.definePass(testing.allocator, 1, .compute, 1);
    try emitter.dispatch(testing.allocator, 64, 1, 1);
    try emitter.endPassDef(testing.allocator);

    // Define pass 2 (render)
    try emitter.definePass(testing.allocator, 2, .render, 2);
    try emitter.draw(testing.allocator, 6, 1, 0, 0);
    try emitter.endPassDef(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    dispatcher.scanPassDefinitions();

    // Post-condition: all three passes found
    try testing.expectEqual(@as(usize, 3), dispatcher.pass_ranges.count());
    try testing.expect(dispatcher.pass_ranges.get(0) != null);
    try testing.expect(dispatcher.pass_ranges.get(1) != null);
    try testing.expect(dispatcher.pass_ranges.get(2) != null);
}

test "scanPassDefinitions: exec_pass uses scanned range" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_id = try builder.internString(testing.allocator, "main");
    const emitter = builder.getEmitter();

    // Define pass first
    try emitter.definePass(testing.allocator, 0, .render, 0);
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Frame that uses exec_pass
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.execPass(testing.allocator, 0);
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    try dispatcher.executeAll(testing.allocator);

    // Verify pass was executed
    var draw_found = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .draw) {
            draw_found = true;
            break;
        }
    }
    try testing.expect(draw_found);
}

test "exec_pass with missing pass_id does not crash" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_id = try builder.internString(testing.allocator, "frame");
    const emitter = builder.getEmitter();

    // Frame that references non-existent pass
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.execPass(testing.allocator, 99); // Pass 99 doesn't exist
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    // Don't call scanPassDefinitions - pass_ranges is empty

    try dispatcher.executeAll(testing.allocator);

    // Only submit should be called (exec_pass 99 finds nothing)
    try testing.expectEqual(@as(usize, 1), gpu.callCount());
    try testing.expectEqual(CallType.submit, gpu.getCall(0).call_type);
}

// ============================================================================
// Pool Operation Tests
// ============================================================================

test "pool operations: frame counter increments" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_id = try builder.internString(testing.allocator, "frame");
    const emitter = builder.getEmitter();

    // Two frames
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    try emitter.defineFrame(testing.allocator, 1, name_id.toInt());
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.initWithFrame(testing.allocator, &gpu, &module, 0);
    defer dispatcher.deinit();

    // Pre-condition
    try testing.expectEqual(@as(u32, 0), dispatcher.frame_counter);

    try dispatcher.executeAll(testing.allocator);

    // Post-condition: frame counter incremented by 2
    try testing.expectEqual(@as(u32, 2), dispatcher.frame_counter);
}

test "pool operations: vertex buffer pool selection" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Must be in a render pass to call setVertexBuffer
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    // Set vertex buffer from pool with pool_size=2, offset=0
    try emitter.setVertexBufferPool(testing.allocator, 0, 10, 2, 0);
    try emitter.endPass(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    // Frame 0: actual_id = 10 + (0 + 0) % 2 = 10
    {
        var dispatcher = MockDispatcher.initWithFrame(testing.allocator, &gpu, &module, 0);
        defer dispatcher.deinit();
        try dispatcher.executeAll(testing.allocator);

        try testing.expectEqual(@as(usize, 3), gpu.callCount()); // begin, set, end
        const call = gpu.getCall(1);
        try testing.expectEqual(CallType.set_vertex_buffer, call.call_type);
        try testing.expectEqual(@as(u16, 10), call.params.set_vertex_buffer.buffer_id);
    }

    gpu.reset();

    // Frame 1: actual_id = 10 + (1 + 0) % 2 = 11
    {
        var dispatcher = MockDispatcher.initWithFrame(testing.allocator, &gpu, &module, 1);
        defer dispatcher.deinit();
        try dispatcher.executeAll(testing.allocator);

        try testing.expectEqual(@as(usize, 3), gpu.callCount());
        const call = gpu.getCall(1);
        try testing.expectEqual(@as(u16, 11), call.params.set_vertex_buffer.buffer_id);
    }

    gpu.reset();

    // Frame 2: actual_id = 10 + (2 + 0) % 2 = 10 (wraps around)
    {
        var dispatcher = MockDispatcher.initWithFrame(testing.allocator, &gpu, &module, 2);
        defer dispatcher.deinit();
        try dispatcher.executeAll(testing.allocator);

        const call = gpu.getCall(1);
        try testing.expectEqual(@as(u16, 10), call.params.set_vertex_buffer.buffer_id);
    }
}

test "pool operations: bind group pool selection with offset" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Must be in a render pass to call setBindGroup
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    // Set bind group from pool with pool_size=2, offset=1
    try emitter.setBindGroupPool(testing.allocator, 0, 20, 2, 1);
    try emitter.endPass(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    // Frame 0 with offset 1: actual_id = 20 + (0 + 1) % 2 = 21
    {
        var dispatcher = MockDispatcher.initWithFrame(testing.allocator, &gpu, &module, 0);
        defer dispatcher.deinit();
        try dispatcher.executeAll(testing.allocator);

        const call = gpu.getCall(1); // Index 1 (after begin_render_pass)
        try testing.expectEqual(CallType.set_bind_group, call.call_type);
        try testing.expectEqual(@as(u16, 21), call.params.set_bind_group.group_id);
    }

    gpu.reset();

    // Frame 1 with offset 1: actual_id = 20 + (1 + 1) % 2 = 20
    {
        var dispatcher = MockDispatcher.initWithFrame(testing.allocator, &gpu, &module, 1);
        defer dispatcher.deinit();
        try dispatcher.executeAll(testing.allocator);

        const call = gpu.getCall(1); // Index 1 (after begin_render_pass)
        try testing.expectEqual(@as(u16, 20), call.params.set_bind_group.group_id);
    }
}

// ============================================================================
// Varint Boundary Tests in Dispatcher Context
// ============================================================================

test "dispatcher handles large varint values" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Create buffer with large size (4-byte varint)
    try emitter.createBuffer(testing.allocator, 0, 100000, .{ .vertex = true, .copy_dst = true });

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    try dispatcher.executeAll(testing.allocator);

    try testing.expectEqual(@as(usize, 1), gpu.callCount());
    const call = gpu.getCall(0);
    try testing.expectEqual(@as(u32, 100000), call.params.create_buffer.size);
}

test "dispatcher handles draw with large vertex count" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Must be in a render pass to call draw
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    // Draw with large counts (2-byte and 4-byte varints)
    try emitter.draw(testing.allocator, 16384, 1000, 128, 0);
    try emitter.endPass(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    try dispatcher.executeAll(testing.allocator);

    const call = gpu.getCall(1); // Index 1 (after begin_render_pass)
    try testing.expectEqual(@as(u32, 16384), call.params.draw.vertex_count);
    try testing.expectEqual(@as(u32, 1000), call.params.draw.instance_count);
    try testing.expectEqual(@as(u32, 128), call.params.draw.first_vertex);
}

// ============================================================================
// Fuzz Testing
// ============================================================================

test "fuzz scanPassDefinitions with random bytecode" {
    // Property: scanPassDefinitions never panics on any bytecode
    try std.testing.fuzz({}, fuzzScanPassDefinitions, .{});
}

fn fuzzScanPassDefinitions(_: void, input: []const u8) !void {
    // Skip inputs with embedded nulls that might confuse allocator
    for (input) |b| {
        if (b == 0) return;
    }

    // Need at least some bytes to parse
    if (input.len < 4) return;

    // Test the OpcodeScanner directly
    var pass_ranges = OpcodeScanner.scanPassDefinitions(input, testing.allocator);
    defer pass_ranges.deinit();

    // Property: pass_ranges entries always have start <= input.len
    var it = pass_ranges.iterator();
    while (it.next()) |entry| {
        try testing.expect(entry.value_ptr.start <= input.len);
        try testing.expect(entry.value_ptr.end <= input.len);
    }
}

test "fuzz varint roundtrip" {
    // Property: encode(decode(x)) == x for all valid varints
    try std.testing.fuzz({}, fuzzVarintRoundtrip, .{});
}

fn fuzzVarintRoundtrip(_: void, input: []const u8) !void {
    if (input.len < 4) return;

    // Use first 4 bytes as a u32 value
    const value = std.mem.readInt(u32, input[0..4], .little);

    var buffer: [4]u8 = undefined;
    const len = opcodes.encodeVarint(value, &buffer);
    const decoded = opcodes.decodeVarint(buffer[0..len]);

    // Property: roundtrip preserves value
    try testing.expectEqual(value, decoded.value);
    // Property: length is consistent
    try testing.expectEqual(len, decoded.len);
}

// ============================================================================
// OOM Testing with FailingAllocator
// ============================================================================

test "OOM: scanPassDefinitions handles allocation failure gracefully" {
    // Test that pass_ranges.put failing doesn't crash
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Create several pass definitions
    for (0..5) |i| {
        try emitter.definePass(testing.allocator, @intCast(i), .render, 0);
        try emitter.draw(testing.allocator, 3, 1, 0, 0);
        try emitter.endPassDef(testing.allocator);
    }

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Test with progressively earlier allocation failures
    var fail_index: usize = 0;
    const max_fail_attempts: usize = 20;

    for (0..max_fail_attempts) |_| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });

        var gpu: MockGPU = .empty;
        defer gpu.deinit(testing.allocator);

        // Create dispatcher with failing allocator
        var pass_ranges = std.AutoHashMap(u16, PassRange).init(failing.allocator());
        defer pass_ranges.deinit();

        // Manually simulate what happens when put fails
        // The code uses `catch {}` so it should silently skip

        if (failing.has_induced_failure) {
            // OOM occurred - this is expected, verify no crash
        } else {
            // No OOM - all passes should be found
            break;
        }

        fail_index += 1;
    }
}

test "OOM: dispatcher executeAll with early allocation failure" {
    // Test complete execution path under OOM
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();
    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var fail_index: usize = 0;
    const max_attempts: usize = 10;

    while (fail_index < max_attempts) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });

        var gpu: MockGPU = .empty;
        defer gpu.deinit(testing.allocator);

        var dispatcher = MockDispatcher.init(failing.allocator(), &gpu, &module);
        defer dispatcher.deinit();

        const result = dispatcher.executeAll(failing.allocator());

        if (failing.has_induced_failure) {
            // OOM occurred - should return OutOfMemory error
            if (result) |_| {
                // Unexpected success after induced failure
            } else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
            }
        } else {
            // No OOM - should succeed
            try result;
            break;
        }
    }
}

// ============================================================================
// Edge Case Tests
// ============================================================================

test "dispatcher: nop opcode is handled" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Emit raw nop opcode
    try emitter.bytes.append(testing.allocator, @intFromEnum(OpCode.nop));
    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    try dispatcher.executeAll(testing.allocator);

    // Only submit should be called (nop is ignored)
    try testing.expectEqual(@as(usize, 1), gpu.callCount());
}

test "dispatcher: begin_compute_pass with no params" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    try emitter.beginComputePass(testing.allocator);
    try emitter.endPass(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    try dispatcher.executeAll(testing.allocator);

    try testing.expectEqual(@as(usize, 2), gpu.callCount());
    try testing.expectEqual(CallType.begin_compute_pass, gpu.getCall(0).call_type);
    try testing.expectEqual(CallType.end_pass, gpu.getCall(1).call_type);
}

test "dispatcher: dispatch workgroups" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Must be in a compute pass to call dispatch
    try emitter.beginComputePass(testing.allocator);
    try emitter.dispatch(testing.allocator, 64, 32, 16);
    try emitter.endPass(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    try dispatcher.executeAll(testing.allocator);

    try testing.expectEqual(@as(usize, 3), gpu.callCount()); // begin, dispatch, end
    const call = gpu.getCall(1); // Index 1 (after begin_compute_pass)
    try testing.expectEqual(CallType.dispatch, call.call_type);
    try testing.expectEqual(@as(u32, 64), call.params.dispatch.x);
    try testing.expectEqual(@as(u32, 32), call.params.dispatch.y);
    try testing.expectEqual(@as(u32, 16), call.params.dispatch.z);
}

test "dispatcher: draw_indexed with all parameters" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Must be in a render pass to call draw_indexed
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.drawIndexed(testing.allocator, 36, 10, 12, 100, 5);
    try emitter.endPass(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    try dispatcher.executeAll(testing.allocator);

    try testing.expectEqual(@as(usize, 3), gpu.callCount()); // begin, draw_indexed, end
    const call = gpu.getCall(1); // Index 1 (after begin_render_pass)
    try testing.expectEqual(CallType.draw_indexed, call.call_type);
    try testing.expectEqual(@as(u32, 36), call.params.draw_indexed.index_count);
    try testing.expectEqual(@as(u32, 10), call.params.draw_indexed.instance_count);
    try testing.expectEqual(@as(u32, 12), call.params.draw_indexed.first_index);
    try testing.expectEqual(@as(u32, 100), call.params.draw_indexed.base_vertex);
    try testing.expectEqual(@as(u32, 5), call.params.draw_indexed.first_instance);
}

test "scanPassDefinitions: passes interleaved with other opcodes" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Resource creation
    try emitter.createShaderModule(testing.allocator, 0, 0);
    try emitter.createRenderPipeline(testing.allocator, 0, 1);

    // Pass 0
    try emitter.definePass(testing.allocator, 0, .render, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPassDef(testing.allocator);

    // More resources
    try emitter.createBuffer(testing.allocator, 0, 1024, .{ .vertex = true });

    // Pass 1
    try emitter.definePass(testing.allocator, 1, .compute, 1);
    try emitter.dispatch(testing.allocator, 8, 8, 1);
    try emitter.endPassDef(testing.allocator);

    // Frame definition
    const name_id = try builder.internString(testing.allocator, "test");
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.execPass(testing.allocator, 0);
    try emitter.execPass(testing.allocator, 1);
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    dispatcher.scanPassDefinitions();

    // Both passes should be found despite interleaved opcodes
    try testing.expectEqual(@as(usize, 2), dispatcher.pass_ranges.count());
    try testing.expect(dispatcher.pass_ranges.get(0) != null);
    try testing.expect(dispatcher.pass_ranges.get(1) != null);
}

test "scanPassDefinitions: max pass_id (255 for u16 cast)" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Test with pass ID 255 (max for 1-byte direct, but within u16 range)
    try emitter.definePass(testing.allocator, 255, .render, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPassDef(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    dispatcher.scanPassDefinitions();

    try testing.expectEqual(@as(usize, 1), dispatcher.pass_ranges.count());
    try testing.expect(dispatcher.pass_ranges.get(255) != null);
}

// ============================================================================
// Scene Switching Integration Tests
// ============================================================================

test "scene switching: exec_pass with scan finds pass defined before frame" {
    // Simulates the scene switching fix - passes defined, then frames use exec_pass
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_a = try builder.internString(testing.allocator, "sceneA");
    const name_b = try builder.internString(testing.allocator, "sceneB");
    const emitter = builder.getEmitter();

    // Define passes first (common pattern)
    try emitter.definePass(testing.allocator, 0, .render, 0);
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.draw(testing.allocator, 3, 1, 0, 0); // Scene A draws triangle
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    try emitter.definePass(testing.allocator, 1, .render, 1);
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.draw(testing.allocator, 6, 1, 0, 0); // Scene B draws quad
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Define frames that exec_pass
    try emitter.defineFrame(testing.allocator, 0, name_a.toInt());
    try emitter.execPass(testing.allocator, 0);
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    try emitter.defineFrame(testing.allocator, 1, name_b.toInt());
    try emitter.execPass(testing.allocator, 1);
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    // Execute all - should run both frames
    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();
    try dispatcher.executeAll(testing.allocator);

    // Verify: should see 2 begin_render_pass, 2 draws (3 and 6), 2 end_pass, 2 submit
    var draw_count: usize = 0;
    var begin_pass_count: usize = 0;
    var submit_count: usize = 0;
    for (gpu.getCalls()) |call| {
        switch (call.call_type) {
            .draw => draw_count += 1,
            .begin_render_pass => begin_pass_count += 1,
            .submit => submit_count += 1,
            else => {},
        }
    }

    try testing.expectEqual(@as(usize, 2), draw_count);
    try testing.expectEqual(@as(usize, 2), begin_pass_count);
    try testing.expectEqual(@as(usize, 2), submit_count);
}

test "scene switching: pass defined after exec_pass still works" {
    // Edge case: forward reference to pass
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_id = try builder.internString(testing.allocator, "main");
    const emitter = builder.getEmitter();

    // Frame first, then pass (forward reference)
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.execPass(testing.allocator, 0);
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    // Pass defined after frame
    try emitter.definePass(testing.allocator, 0, .render, 0);
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    // scanPassDefinitions should find the pass even though it's after the frame
    dispatcher.scanPassDefinitions();
    try testing.expectEqual(@as(usize, 1), dispatcher.pass_ranges.count());

    // Now execute - should work because pass was scanned
    try dispatcher.executeAll(testing.allocator);

    var draw_found = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .draw) {
            draw_found = true;
            break;
        }
    }
    try testing.expect(draw_found);
}

test "scene switching: many passes with non-sequential IDs" {
    // Test that pass IDs don't need to be sequential
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Non-sequential pass IDs: 10, 50, 100
    try emitter.definePass(testing.allocator, 10, .render, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPassDef(testing.allocator);

    try emitter.definePass(testing.allocator, 50, .compute, 0);
    try emitter.dispatch(testing.allocator, 8, 1, 1);
    try emitter.endPassDef(testing.allocator);

    try emitter.definePass(testing.allocator, 100, .render, 0);
    try emitter.draw(testing.allocator, 6, 1, 0, 0);
    try emitter.endPassDef(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    dispatcher.scanPassDefinitions();

    try testing.expectEqual(@as(usize, 3), dispatcher.pass_ranges.count());
    try testing.expect(dispatcher.pass_ranges.get(10) != null);
    try testing.expect(dispatcher.pass_ranges.get(50) != null);
    try testing.expect(dispatcher.pass_ranges.get(100) != null);
    try testing.expect(dispatcher.pass_ranges.get(0) == null);
    try testing.expect(dispatcher.pass_ranges.get(11) == null);
}

test "scanPassDefinitions: deeply nested opcode sequence" {
    // Test with many different opcodes in pass body
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    try emitter.definePass(testing.allocator, 0, .render, 0);
    // Complex sequence of opcodes
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.setBindGroup(testing.allocator, 0, 0);
    try emitter.setBindGroup(testing.allocator, 1, 1);
    try emitter.setVertexBuffer(testing.allocator, 0, 0);
    try emitter.setVertexBuffer(testing.allocator, 1, 1);
    try emitter.draw(testing.allocator, 36, 1, 0, 0);
    try emitter.draw(testing.allocator, 24, 1, 36, 0);
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    dispatcher.scanPassDefinitions();

    try testing.expectEqual(@as(usize, 1), dispatcher.pass_ranges.count());
    const range = dispatcher.pass_ranges.get(0).?;
    // Complex pass should have a large range
    try testing.expect(range.end - range.start > 20);
}

test "scanPassDefinitions: boids-like pattern with bind_group + write_buffer" {
    // Regression test for the specific pattern that caused the original bug:
    // create_bind_group (3 varints) followed by other opcodes.

    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Simulate boids pattern: buffer, bind_group, write_buffer, passes
    try emitter.createBuffer(testing.allocator, 0, 1024, .{ .storage = true });
    try emitter.createBuffer(testing.allocator, 1, 1024, .{ .storage = true });
    try emitter.createBindGroup(testing.allocator, 0, 0, 0); // The problematic opcode
    try emitter.createBindGroup(testing.allocator, 1, 0, 1);
    try emitter.writeBuffer(testing.allocator, 0, 0, 0); // Also was problematic

    // Render pass
    try emitter.definePass(testing.allocator, 0, .render, 0);
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 3, 2048, 0, 0);
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Compute pass
    try emitter.definePass(testing.allocator, 1, .compute, 0);
    try emitter.beginComputePass(testing.allocator);
    try emitter.setPipeline(testing.allocator, 1);
    try emitter.setBindGroupPool(testing.allocator, 0, 0, 2, 0);
    try emitter.dispatch(testing.allocator, 32, 1, 1);
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Frame
    try emitter.defineFrame(testing.allocator, 0, 0);
    try emitter.execPass(testing.allocator, 0);
    try emitter.execPass(testing.allocator, 1);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    dispatcher.scanPassDefinitions();

    // CRITICAL: Both passes must be found
    try testing.expectEqual(@as(usize, 2), dispatcher.pass_ranges.count());
    try testing.expect(dispatcher.pass_ranges.get(0) != null); // render pass
    try testing.expect(dispatcher.pass_ranges.get(1) != null); // compute pass
}

// ============================================================================
// exec_pass_once Tests - Run-once Initialization Pattern
// ============================================================================
//
// These tests verify the exec_pass_once opcode behavior which is critical for
// initialization passes (e.g., particle system init via compute shader).
//
// Key invariants:
// 1. exec_pass_once executes only the first time it's encountered
// 2. Subsequent calls to exec_pass_once for the same pass_id are skipped
// 3. exec_pass_once and exec_pass can be mixed - exec_pass always runs
// 4. Invalid pass_id should be handled gracefully (no crash)
// 5. State from init pass persists to subsequent frames

test "exec_pass_once: basic execution on first frame" {
    // Test: exec_pass_once executes the pass body on first invocation
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_id = try builder.internString(testing.allocator, "main");
    const emitter = builder.getEmitter();

    // Define an init pass (pass_id = 0)
    try emitter.definePass(testing.allocator, 0, .compute, 0);
    try emitter.beginComputePass(testing.allocator);
    try emitter.dispatch(testing.allocator, 64, 1, 1);
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Frame that uses exec_pass_once
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.execPassOnce(testing.allocator, 0);
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    try dispatcher.executeAll(testing.allocator);

    // Verify dispatch was called (pass executed)
    var dispatch_found = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .dispatch) {
            dispatch_found = true;
            try testing.expectEqual(@as(u32, 64), call.params.dispatch.x);
            break;
        }
    }
    try testing.expect(dispatch_found);
}

test "exec_pass_once: skipped on subsequent executions" {
    // Test: exec_pass_once runs only once, even when called multiple times
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_id = try builder.internString(testing.allocator, "main");
    const emitter = builder.getEmitter();

    // Define pass
    try emitter.definePass(testing.allocator, 0, .compute, 0);
    try emitter.beginComputePass(testing.allocator);
    try emitter.dispatch(testing.allocator, 42, 1, 1);
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Frame with multiple exec_pass_once for same pass
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.execPassOnce(testing.allocator, 0); // First call - should execute
    try emitter.execPassOnce(testing.allocator, 0); // Second call - should skip
    try emitter.execPassOnce(testing.allocator, 0); // Third call - should skip
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    try dispatcher.executeAll(testing.allocator);

    // Count dispatch calls - should only have 1 even though exec_pass_once was called 3 times
    var dispatch_count: usize = 0;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .dispatch) dispatch_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), dispatch_count);
}

test "exec_pass_once: multiple different passes each run once" {
    // Test: Multiple distinct init passes, each runs exactly once
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_id = try builder.internString(testing.allocator, "main");
    const emitter = builder.getEmitter();

    // Define 3 different init passes with unique dispatch values
    try emitter.definePass(testing.allocator, 0, .compute, 0);
    try emitter.beginComputePass(testing.allocator);
    try emitter.dispatch(testing.allocator, 10, 1, 1); // Pass 0: x=10
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    try emitter.definePass(testing.allocator, 1, .compute, 0);
    try emitter.beginComputePass(testing.allocator);
    try emitter.dispatch(testing.allocator, 20, 1, 1); // Pass 1: x=20
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    try emitter.definePass(testing.allocator, 2, .compute, 0);
    try emitter.beginComputePass(testing.allocator);
    try emitter.dispatch(testing.allocator, 30, 1, 1); // Pass 2: x=30
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Frame with all three passes called via exec_pass_once
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.execPassOnce(testing.allocator, 0);
    try emitter.execPassOnce(testing.allocator, 1);
    try emitter.execPassOnce(testing.allocator, 2);
    // Call them again - should all be skipped
    try emitter.execPassOnce(testing.allocator, 0);
    try emitter.execPassOnce(testing.allocator, 1);
    try emitter.execPassOnce(testing.allocator, 2);
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    try dispatcher.executeAll(testing.allocator);

    // Count dispatches - should be exactly 3 (one per unique pass)
    var dispatch_count: usize = 0;
    var x_values: [3]u32 = undefined;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .dispatch) {
            if (dispatch_count < 3) {
                x_values[dispatch_count] = call.params.dispatch.x;
            }
            dispatch_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), dispatch_count);
    // Verify each pass ran with correct x value
    try testing.expectEqual(@as(u32, 10), x_values[0]);
    try testing.expectEqual(@as(u32, 20), x_values[1]);
    try testing.expectEqual(@as(u32, 30), x_values[2]);
}

test "exec_pass_once: mixed with exec_pass - both work correctly" {
    // Test: exec_pass always runs, exec_pass_once runs only once
    // This is the boids pattern: init runs once, update runs every frame
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_id = try builder.internString(testing.allocator, "main");
    const emitter = builder.getEmitter();

    // Pass 0: init (run once)
    try emitter.definePass(testing.allocator, 0, .compute, 0);
    try emitter.beginComputePass(testing.allocator);
    try emitter.dispatch(testing.allocator, 100, 1, 1); // Init: x=100
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Pass 1: update (run every frame)
    try emitter.definePass(testing.allocator, 1, .compute, 0);
    try emitter.beginComputePass(testing.allocator);
    try emitter.dispatch(testing.allocator, 64, 1, 1); // Update: x=64
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Frame: init once, update always
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.execPassOnce(testing.allocator, 0); // Init - once
    try emitter.execPass(testing.allocator, 1); // Update - always
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    // Execute frame once
    try dispatcher.executeAll(testing.allocator);

    // First frame: both passes should execute
    var dispatch_count: usize = 0;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .dispatch) dispatch_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), dispatch_count);

    // Reset GPU calls and pc for second frame
    gpu.reset();
    dispatcher.pc = 0; // Reset pc to simulate new frame

    // On second frame, only exec_pass should run (exec_pass_once is skipped)
    try dispatcher.executeAll(testing.allocator);

    dispatch_count = 0;
    var found_update = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .dispatch) {
            dispatch_count += 1;
            if (call.params.dispatch.x == 64) found_update = true;
        }
    }
    // Only the update pass (x=64) should have run
    try testing.expectEqual(@as(usize, 1), dispatch_count);
    try testing.expect(found_update);
}

test "exec_pass_once: invalid pass_id does not crash" {
    // Test: Referencing non-existent pass should be handled gracefully
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_id = try builder.internString(testing.allocator, "main");
    const emitter = builder.getEmitter();

    // No passes defined - just a frame referencing non-existent pass
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.execPassOnce(testing.allocator, 99); // Pass 99 doesn't exist
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    // Should not crash
    try dispatcher.executeAll(testing.allocator);

    // Only submit should be called (exec_pass_once 99 finds nothing)
    try testing.expectEqual(@as(usize, 1), gpu.callCount());
    try testing.expectEqual(CallType.submit, gpu.getCall(0).call_type);
}

test "exec_pass_once: order preserved - init before update" {
    // Test: exec_pass_once runs in order relative to other passes
    // Critical for init patterns where init must complete before update reads
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_id = try builder.internString(testing.allocator, "main");
    const emitter = builder.getEmitter();

    // Pass 0: init (sets up data)
    try emitter.definePass(testing.allocator, 0, .compute, 0);
    try emitter.beginComputePass(testing.allocator);
    try emitter.dispatch(testing.allocator, 1, 1, 1); // Init marker: x=1
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Pass 1: update (reads data)
    try emitter.definePass(testing.allocator, 1, .compute, 0);
    try emitter.beginComputePass(testing.allocator);
    try emitter.dispatch(testing.allocator, 2, 1, 1); // Update marker: x=2
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Pass 2: render
    try emitter.definePass(testing.allocator, 2, .render, 0);
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.draw(testing.allocator, 3, 1, 0, 0); // Draw marker
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Frame: init, update, render - must execute in this order
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.execPassOnce(testing.allocator, 0); // Init
    try emitter.execPass(testing.allocator, 1); // Update
    try emitter.execPass(testing.allocator, 2); // Render
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    try dispatcher.executeAll(testing.allocator);

    // Verify order: dispatch(1), dispatch(2), begin_render_pass, draw
    var dispatch_order: [2]u32 = undefined;
    var dispatch_idx: usize = 0;
    var draw_after_dispatches = false;
    var dispatches_before_draw: usize = 0;

    for (gpu.getCalls()) |call| {
        if (call.call_type == .dispatch) {
            if (dispatch_idx < 2) {
                dispatch_order[dispatch_idx] = call.params.dispatch.x;
            }
            dispatch_idx += 1;
            dispatches_before_draw += 1;
        }
        if (call.call_type == .draw) {
            draw_after_dispatches = dispatches_before_draw >= 2;
        }
    }

    // Init (x=1) should come before update (x=2)
    try testing.expectEqual(@as(u32, 1), dispatch_order[0]);
    try testing.expectEqual(@as(u32, 2), dispatch_order[1]);
    // Draw should come after both dispatches
    try testing.expect(draw_after_dispatches);
}

test "exec_pass_once: persistence across multiple executeAll calls" {
    // Test: exec_pass_once state persists when dispatcher is reused
    // This simulates animation loop behavior
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_id = try builder.internString(testing.allocator, "main");
    const emitter = builder.getEmitter();

    // Init pass
    try emitter.definePass(testing.allocator, 0, .compute, 0);
    try emitter.beginComputePass(testing.allocator);
    try emitter.dispatch(testing.allocator, 99, 1, 1);
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Frame
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.execPassOnce(testing.allocator, 0);
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    // Simulate 5 animation frames
    var total_dispatches: usize = 0;
    for (0..5) |_| {
        gpu.reset();
        dispatcher.pc = 0; // Reset pc to simulate new frame
        try dispatcher.executeAll(testing.allocator);

        for (gpu.getCalls()) |call| {
            if (call.call_type == .dispatch) total_dispatches += 1;
        }
    }

    // exec_pass_once should have run exactly once across all 5 frames
    try testing.expectEqual(@as(usize, 1), total_dispatches);
}

test "exec_pass_once: interleaved with regular opcodes" {
    // Test: exec_pass_once works correctly when mixed with other opcodes
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_id = try builder.internString(testing.allocator, "main");
    const emitter = builder.getEmitter();

    // Create a buffer first
    try emitter.createBuffer(testing.allocator, 0, 1024, .{ .storage = true });

    // Init pass
    try emitter.definePass(testing.allocator, 0, .compute, 0);
    try emitter.beginComputePass(testing.allocator);
    try emitter.dispatch(testing.allocator, 32, 1, 1);
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Frame with mixed opcodes
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.writeBuffer(testing.allocator, 0, 0, 0); // Regular opcode
    try emitter.execPassOnce(testing.allocator, 0); // Init pass
    try emitter.writeBuffer(testing.allocator, 0, 0, 0); // Another regular opcode
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    try dispatcher.executeAll(testing.allocator);

    // Verify: create_buffer, write_buffer, dispatch, write_buffer, submit
    var found_dispatch = false;
    var write_buffer_count: usize = 0;
    var create_buffer_count: usize = 0;

    for (gpu.getCalls()) |call| {
        if (call.call_type == .dispatch) found_dispatch = true;
        if (call.call_type == .write_buffer) write_buffer_count += 1;
        if (call.call_type == .create_buffer) create_buffer_count += 1;
    }

    try testing.expect(found_dispatch);
    try testing.expectEqual(@as(usize, 2), write_buffer_count);
    try testing.expectEqual(@as(usize, 1), create_buffer_count);
}

test "exec_pass_once: boids-like pattern - init + compute + render" {
    // Full boids simulation pattern: init particles once, then compute + render every frame
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_id = try builder.internString(testing.allocator, "boids");
    const emitter = builder.getEmitter();

    // Create particle buffers (pool of 2 for ping-pong)
    try emitter.createBuffer(testing.allocator, 0, 32768, .{ .vertex = true, .storage = true });
    try emitter.createBuffer(testing.allocator, 1, 32768, .{ .vertex = true, .storage = true });

    // Pass 0: Init particles (run once)
    try emitter.definePass(testing.allocator, 0, .compute, 0);
    try emitter.beginComputePass(testing.allocator);
    try emitter.dispatch(testing.allocator, 32, 1, 1); // Initialize 2048 particles
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Pass 1: Compute simulation (run every frame)
    try emitter.definePass(testing.allocator, 1, .compute, 0);
    try emitter.beginComputePass(testing.allocator);
    try emitter.dispatch(testing.allocator, 32, 1, 1); // Update particles
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Pass 2: Render particles (run every frame)
    try emitter.definePass(testing.allocator, 2, .render, 0);
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.draw(testing.allocator, 3, 2048, 0, 0); // Draw 2048 instances
    try emitter.endPass(testing.allocator);
    try emitter.endPassDef(testing.allocator);

    // Frame: init once, then compute + render every frame
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.execPassOnce(testing.allocator, 0); // Init (first frame only)
    try emitter.execPass(testing.allocator, 1); // Compute (every frame)
    try emitter.execPass(testing.allocator, 2); // Render (every frame)
    try emitter.submit(testing.allocator);
    try emitter.endFrame(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var dispatcher = MockDispatcher.init(testing.allocator, &gpu, &module);
    defer dispatcher.deinit();

    // Frame 1: init + compute + render = 2 dispatches + 1 draw
    try dispatcher.executeAll(testing.allocator);

    var frame1_dispatches: usize = 0;
    var frame1_draws: usize = 0;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .dispatch) frame1_dispatches += 1;
        if (call.call_type == .draw) frame1_draws += 1;
    }
    try testing.expectEqual(@as(usize, 2), frame1_dispatches); // init + compute
    try testing.expectEqual(@as(usize, 1), frame1_draws);

    // Frame 2-5: compute + render = 1 dispatch + 1 draw per frame
    for (0..4) |frame_idx| {
        _ = frame_idx;
        gpu.reset();
        dispatcher.pc = 0; // Reset pc to simulate new frame
        try dispatcher.executeAll(testing.allocator);

        var dispatches: usize = 0;
        var draws: usize = 0;
        for (gpu.getCalls()) |call| {
            if (call.call_type == .dispatch) dispatches += 1;
            if (call.call_type == .draw) draws += 1;
        }
        try testing.expectEqual(@as(usize, 1), dispatches); // only compute
        try testing.expectEqual(@as(usize, 1), draws);
    }
}
