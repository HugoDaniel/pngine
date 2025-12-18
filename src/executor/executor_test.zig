//! Executor Integration Tests
//!
//! End-to-end tests for bytecode execution.
//! Verifies that bytecode produces correct GPU call sequences.

const std = @import("std");
const testing = std.testing;
const format = @import("../bytecode/format.zig");
const opcodes = @import("../bytecode/opcodes.zig");
const mock_gpu = @import("mock_gpu.zig");
const dispatcher = @import("dispatcher.zig");
const DescriptorEncoder = @import("../dsl/DescriptorEncoder.zig").DescriptorEncoder;

const Builder = format.Builder;
const MockGPU = mock_gpu.MockGPU;
const MockDispatcher = dispatcher.MockDispatcher;
const CallType = mock_gpu.CallType;
const LoadOp = opcodes.LoadOp;
const StoreOp = opcodes.StoreOp;
const BufferUsage = opcodes.BufferUsage;

test "simpleTriangle full pipeline" {
    // Build a complete simpleTriangle module
    // This test uses direct render pass commands (begin_render_pass/end_pass)
    // rather than the define_pass/exec_pass pattern
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    // Add data
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
    const pipeline_desc_id = try builder.addData(testing.allocator, "{}");

    // Emit bytecode
    const emitter = builder.getEmitter();

    // 1. Create resources
    try emitter.createShaderModule(testing.allocator, 0, shader_data_id.toInt());
    try emitter.createRenderPipeline(testing.allocator, 0, pipeline_desc_id.toInt());

    // 2. Render pass
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPass(testing.allocator);

    // 3. Submit
    try emitter.submit(testing.allocator);

    // Finalize
    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    // Deserialize
    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Execute
    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(testing.allocator, &gpu, &module);
    try exec.executeAll(testing.allocator);

    // Verify call sequence
    const expected = [_]CallType{
        .create_shader_module,
        .create_render_pipeline,
        .begin_render_pass,
        .set_pipeline,
        .draw,
        .end_pass,
        .submit,
    };

    try testing.expect(gpu.expectCallTypes(&expected));

    // Verify specific parameters
    const calls = gpu.getCalls();

    // create_shader_module: id=0, data=0
    try testing.expectEqual(@as(u16, 0), calls[0].params.create_shader_module.shader_id);
    try testing.expectEqual(@as(u16, 0), calls[0].params.create_shader_module.code_data_id);

    // create_render_pipeline: id=0, desc=1
    try testing.expectEqual(@as(u16, 0), calls[1].params.create_render_pipeline.pipeline_id);
    try testing.expectEqual(@as(u16, 1), calls[1].params.create_render_pipeline.descriptor_data_id);

    // begin_render_pass: texture=0, clear, store
    try testing.expectEqual(@as(u16, 0), calls[2].params.begin_render_pass.color_texture_id);

    // set_pipeline: id=0
    try testing.expectEqual(@as(u16, 0), calls[3].params.set_pipeline.pipeline_id);

    // draw: 3 vertices, 1 instance
    try testing.expectEqual(@as(u32, 3), calls[4].params.draw.vertex_count);
    try testing.expectEqual(@as(u32, 1), calls[4].params.draw.instance_count);

    // Log metrics
    std.debug.print("\n", .{});
    std.debug.print("=== simpleTriangle Execution ===\n", .{});
    std.debug.print("  PNGB size: {d} bytes\n", .{pngb.len});
    std.debug.print("  Bytecode: {d} bytes\n", .{module.bytecode.len});
    std.debug.print("  GPU calls: {d}\n", .{gpu.callCount()});
    std.debug.print("\n", .{});
}

test "compute dispatch" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();
    const desc_id = try builder.addData(testing.allocator, "{}");

    // Create compute pipeline and dispatch
    try emitter.createComputePipeline(testing.allocator, 0, desc_id.toInt());
    try emitter.beginComputePass(testing.allocator);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.dispatch(testing.allocator, 16, 16, 1);
    try emitter.endPass(testing.allocator);
    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(testing.allocator, &gpu, &module);
    try exec.executeAll(testing.allocator);

    const expected = [_]CallType{
        .create_compute_pipeline,
        .begin_compute_pass,
        .set_pipeline,
        .dispatch,
        .end_pass,
        .submit,
    };

    try testing.expect(gpu.expectCallTypes(&expected));

    // Verify dispatch parameters
    const dispatch_call = gpu.getCall(3);
    try testing.expectEqual(@as(u32, 16), dispatch_call.params.dispatch.x);
    try testing.expectEqual(@as(u32, 16), dispatch_call.params.dispatch.y);
    try testing.expectEqual(@as(u32, 1), dispatch_call.params.dispatch.z);
}

test "multi-pass rendering" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();
    const desc_id = try builder.addData(testing.allocator, "{}");
    _ = try builder.internString(testing.allocator, "multiPass");

    // Create two pipelines
    try emitter.createShaderModule(testing.allocator, 0, desc_id.toInt());
    try emitter.createRenderPipeline(testing.allocator, 0, desc_id.toInt());
    try emitter.createRenderPipeline(testing.allocator, 1, desc_id.toInt());

    // Pass 1: shadow map
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF); // clear, store
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 36, 100, 0, 0); // 100 instances
    try emitter.endPass(testing.allocator);

    // Pass 2: main scene
    try emitter.beginRenderPass(testing.allocator, 1, .clear, .store, 0xFFFF); // clear, store
    try emitter.setPipeline(testing.allocator, 1);
    try emitter.draw(testing.allocator, 36, 100, 0, 0);
    try emitter.endPass(testing.allocator);

    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(testing.allocator, &gpu, &module);
    try exec.executeAll(testing.allocator);

    // Count calls by type
    var pass_count: usize = 0;
    var draw_count: usize = 0;
    for (gpu.getCalls()) |call| {
        switch (call.call_type) {
            .begin_render_pass => pass_count += 1,
            .draw => draw_count += 1,
            else => {},
        }
    }

    try testing.expectEqual(@as(usize, 2), pass_count);
    try testing.expectEqual(@as(usize, 2), draw_count);
}

test "buffer write and use" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const uniform_data = try builder.addData(testing.allocator, &[_]u8{ 0, 0, 0, 0 } ** 16); // 64 bytes

    const emitter = builder.getEmitter();

    // Create buffer and write data
    try emitter.createBuffer(testing.allocator, 0, 64, BufferUsage.uniform_copy_dst); // uniform + copy_dst
    try emitter.writeBuffer(testing.allocator, 0, 0, uniform_data.toInt());

    // Use buffer in render (must be in a render pass)
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.setVertexBuffer(testing.allocator, 0, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPass(testing.allocator);
    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(testing.allocator, &gpu, &module);
    try exec.executeAll(testing.allocator);

    const expected = [_]CallType{
        .create_buffer,
        .write_buffer,
        .begin_render_pass,
        .set_pipeline,
        .set_vertex_buffer,
        .draw,
        .end_pass,
        .submit,
    };

    try testing.expect(gpu.expectCallTypes(&expected));

    // Verify buffer parameters
    const create_call = gpu.getCall(0);
    try testing.expectEqual(@as(u32, 64), create_call.params.create_buffer.size);
    // uniform (0x40) + copy_dst (0x08) = 0x48
    try testing.expectEqual(@as(u8, @bitCast(BufferUsage.uniform_copy_dst)), create_call.params.create_buffer.usage);
}

test "bind group setup" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const entries_data = try builder.addData(testing.allocator, "[]");

    const emitter = builder.getEmitter();

    // Create bind group and use it
    try emitter.createBindGroup(testing.allocator, 0, 0, entries_data.toInt());
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.setBindGroup(testing.allocator, 0, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPass(testing.allocator);
    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(testing.allocator, &gpu, &module);
    try exec.executeAll(testing.allocator);

    const expected = [_]CallType{
        .create_bind_group,
        .begin_render_pass,
        .set_pipeline,
        .set_bind_group,
        .draw,
        .end_pass,
        .submit,
    };

    try testing.expect(gpu.expectCallTypes(&expected));

    // Verify bind group parameters
    const set_bg_call = gpu.getCall(3);
    try testing.expectEqual(@as(u8, 0), set_bg_call.params.set_bind_group.slot);
    try testing.expectEqual(@as(u16, 0), set_bg_call.params.set_bind_group.group_id);
}

test "large vertex count varint encoding" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Draw with large vertex count (tests 2-byte varint)
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.draw(testing.allocator, 10000, 1, 0, 0);

    // Draw with very large count (tests 4-byte varint)
    try emitter.draw(testing.allocator, 100000, 500, 0, 0);
    try emitter.endPass(testing.allocator);

    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(testing.allocator, &gpu, &module);
    try exec.executeAll(testing.allocator);

    const calls = gpu.getCalls();

    // calls[0] = begin_render_pass
    // First draw: 10000 vertices
    try testing.expectEqual(@as(u32, 10000), calls[1].params.draw.vertex_count);
    try testing.expectEqual(@as(u32, 1), calls[1].params.draw.instance_count);

    // Second draw: 100000 vertices, 500 instances
    try testing.expectEqual(@as(u32, 100000), calls[2].params.draw.vertex_count);
    try testing.expectEqual(@as(u32, 500), calls[2].params.draw.instance_count);
}

test "indexed draw" {
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.drawIndexed(testing.allocator, 36, 10, 0, 0, 0);
    try emitter.endPass(testing.allocator);
    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(testing.allocator, &gpu, &module);
    try exec.executeAll(testing.allocator);

    // calls[0] = begin_render_pass, calls[1] = set_pipeline, calls[2] = draw_indexed
    const draw_call = gpu.getCall(2);
    try testing.expectEqual(CallType.draw_indexed, draw_call.call_type);
    try testing.expectEqual(@as(u32, 36), draw_call.params.draw_indexed.index_count);
    try testing.expectEqual(@as(u32, 10), draw_call.params.draw_indexed.instance_count);
}

test "texture-based render pass (MSAA pattern)" {
    // Tests the pattern used by MSAA examples:
    // 1. Create texture (for MSAA resolve target)
    // 2. Create shader and pipeline
    // 3. Render pass with texture
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const shader_code =
        \\@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
        \\  return vec4f(0.0, 0.0, 0.0, 1.0);
        \\}
        \\@fragment fn fs() -> @location(0) vec4f {
        \\  return vec4f(1.0, 0.0, 0.0, 1.0);
        \\}
    ;
    const shader_data_id = try builder.addData(testing.allocator, shader_code);

    // Create proper binary texture descriptor (required for JS decoder)
    const texture_desc = try DescriptorEncoder.encodeTexture(
        testing.allocator,
        512,
        512,
        .bgra8unorm,
        .{ .render_attachment = true },
        4, // 4x MSAA
    );
    defer testing.allocator.free(texture_desc);
    const texture_desc_id = try builder.addData(testing.allocator, texture_desc);
    const pipeline_desc_id = try builder.addData(testing.allocator, "{}");

    const emitter = builder.getEmitter();

    // Create resources
    try emitter.createTexture(testing.allocator, 0, texture_desc_id.toInt());
    try emitter.createShaderModule(testing.allocator, 0, shader_data_id.toInt());
    try emitter.createRenderPipeline(testing.allocator, 0, pipeline_desc_id.toInt());

    // Render pass using texture as render target
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 3, 1, 0, 0);
    try emitter.endPass(testing.allocator);
    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(testing.allocator, &gpu, &module);
    try exec.executeAll(testing.allocator);

    // Verify call sequence
    const expected = [_]CallType{
        .create_texture,
        .create_shader_module,
        .create_render_pipeline,
        .begin_render_pass,
        .set_pipeline,
        .draw,
        .end_pass,
        .submit,
    };

    try testing.expect(gpu.expectCallTypes(&expected));

    // Verify texture was created
    try testing.expect(gpu.textures_created.isSet(0));

    // Verify texture parameters
    const tex_call = gpu.getCall(0);
    try testing.expectEqual(@as(u16, 0), tex_call.params.create_texture.texture_id);
}

test "binary texture descriptor format validation" {
    // Verifies that texture descriptors use correct binary format
    // that the JS decoder expects
    const desc = try DescriptorEncoder.encodeTexture(
        testing.allocator,
        800,
        600,
        .rgba8unorm,
        .{ .render_attachment = true, .texture_binding = true },
        1,
    );
    defer testing.allocator.free(desc);

    // Property: first byte is texture type tag (0x01)
    try testing.expectEqual(@as(u8, 0x01), desc[0]);

    // Property: second byte is field count (4 fields: width, height, format, usage)
    try testing.expectEqual(@as(u8, 4), desc[1]);

    // Property: descriptor has minimum expected size
    // Header (2) + 4 fields * (field_id + value_type + value)
    try testing.expect(desc.len >= 10);
}

test "binary sampler descriptor format validation" {
    // Verifies that sampler descriptors use correct binary format
    const desc = try DescriptorEncoder.encodeSampler(
        testing.allocator,
        .linear, // mag filter
        .nearest, // min filter
        .repeat, // address mode
    );
    defer testing.allocator.free(desc);

    // Property: first byte is sampler type tag (0x02)
    try testing.expectEqual(@as(u8, 0x02), desc[0]);

    // Property: second byte is field count (4 fields: mag, min, addr_u, addr_v)
    try testing.expectEqual(@as(u8, 4), desc[1]);
}

test "texture descriptor with MSAA includes sample count" {
    // MSAA textures should include the sample_count field
    const desc_no_msaa = try DescriptorEncoder.encodeTexture(
        testing.allocator,
        256,
        256,
        .rgba8unorm,
        .{ .render_attachment = true },
        1, // No MSAA
    );
    defer testing.allocator.free(desc_no_msaa);

    const desc_with_msaa = try DescriptorEncoder.encodeTexture(
        testing.allocator,
        256,
        256,
        .rgba8unorm,
        .{ .render_attachment = true },
        4, // 4x MSAA
    );
    defer testing.allocator.free(desc_with_msaa);

    // Property: non-MSAA has 4 fields, MSAA has 5 fields (extra sample_count)
    try testing.expectEqual(@as(u8, 4), desc_no_msaa[1]);
    try testing.expectEqual(@as(u8, 5), desc_with_msaa[1]);

    // Property: MSAA descriptor is larger due to extra field
    try testing.expect(desc_with_msaa.len > desc_no_msaa.len);
}

test "binary bind group descriptor format validation" {
    // Verifies that bind group descriptors use correct binary format
    // that the JS decoder expects

    // Create entries with different resource types
    const entries = [_]DescriptorEncoder.BindGroupEntry{
        // Buffer binding (includes offset/size)
        .{ .binding = 0, .resource_type = .buffer, .resource_id = 0, .offset = 0, .size = 64 },
        // Sampler binding (no offset/size)
        .{ .binding = 1, .resource_type = .sampler, .resource_id = 0 },
        // Texture view binding (no offset/size)
        .{ .binding = 2, .resource_type = .texture_view, .resource_id = 1 },
    };

    const desc = try DescriptorEncoder.encodeBindGroupDescriptor(
        testing.allocator,
        0, // group index
        &entries,
    );
    defer testing.allocator.free(desc);

    // Property: first byte is bind_group type tag (0x03)
    try testing.expectEqual(@as(u8, 0x03), desc[0]);

    // Property: second byte is field count (2 fields: layout, entries)
    try testing.expectEqual(@as(u8, 2), desc[1]);

    // Property: descriptor has minimum expected size
    // Header (2) + layout field (3) + entries header (3) + entries data
    try testing.expect(desc.len >= 10);
}

test "bind group descriptor with group index" {
    // Verifies that bind group index is correctly encoded
    const entries = [_]DescriptorEncoder.BindGroupEntry{
        .{ .binding = 0, .resource_type = .buffer, .resource_id = 0, .offset = 0, .size = 16 },
    };

    const desc_group0 = try DescriptorEncoder.encodeBindGroupDescriptor(
        testing.allocator,
        0, // group index 0
        &entries,
    );
    defer testing.allocator.free(desc_group0);

    const desc_group1 = try DescriptorEncoder.encodeBindGroupDescriptor(
        testing.allocator,
        1, // group index 1
        &entries,
    );
    defer testing.allocator.free(desc_group1);

    // Property: both have correct type tag
    try testing.expectEqual(@as(u8, 0x03), desc_group0[0]);
    try testing.expectEqual(@as(u8, 0x03), desc_group1[0]);

    // Property: group index is encoded in the layout field
    // Format: type_tag(1) + field_count(1) + field_id(1) + value_type(1) + group_index(1)
    // The group index is at byte 4 (0-indexed)
    try testing.expectEqual(@as(u8, 0), desc_group0[4]); // group index 0
    try testing.expectEqual(@as(u8, 1), desc_group1[4]); // group index 1
}

test "bind group with buffer binding includes offset and size" {
    // Buffer bindings require offset and size fields
    const entries_buffer = [_]DescriptorEncoder.BindGroupEntry{
        .{ .binding = 0, .resource_type = .buffer, .resource_id = 5, .offset = 128, .size = 256 },
    };

    const entries_sampler = [_]DescriptorEncoder.BindGroupEntry{
        .{ .binding = 0, .resource_type = .sampler, .resource_id = 5 },
    };

    const desc_buffer = try DescriptorEncoder.encodeBindGroupDescriptor(
        testing.allocator,
        0,
        &entries_buffer,
    );
    defer testing.allocator.free(desc_buffer);

    const desc_sampler = try DescriptorEncoder.encodeBindGroupDescriptor(
        testing.allocator,
        0,
        &entries_sampler,
    );
    defer testing.allocator.free(desc_sampler);

    // Property: buffer binding descriptor is larger due to offset/size fields
    // Buffer entry: binding(1) + type(1) + id(2) + offset(4) + size(4) = 12 bytes
    // Sampler entry: binding(1) + type(1) + id(2) = 4 bytes
    try testing.expect(desc_buffer.len > desc_sampler.len);
}

// ============================================================================
// Buffer Usage Tests
// ============================================================================

test "buffer usage encoding matches JS decoder" {
    // Verifies that BufferUsage packed struct has correct bit positions
    // that the JS mapBufferUsage decoder expects.
    //
    // JS expects (Zig packed struct, LSB first):
    //   bit 0: map_read   (0x01)
    //   bit 1: map_write  (0x02)
    //   bit 2: copy_src   (0x04)
    //   bit 3: copy_dst   (0x08)
    //   bit 4: index      (0x10)
    //   bit 5: vertex     (0x20)
    //   bit 6: uniform    (0x40)
    //   bit 7: storage    (0x80)

    // Property: individual flags have correct bit positions
    const map_read: u8 = @bitCast(opcodes.BufferUsage{ .map_read = true });
    try testing.expectEqual(@as(u8, 0x01), map_read);

    const map_write: u8 = @bitCast(opcodes.BufferUsage{ .map_write = true });
    try testing.expectEqual(@as(u8, 0x02), map_write);

    const copy_src: u8 = @bitCast(opcodes.BufferUsage{ .copy_src = true });
    try testing.expectEqual(@as(u8, 0x04), copy_src);

    const copy_dst: u8 = @bitCast(opcodes.BufferUsage{ .copy_dst = true });
    try testing.expectEqual(@as(u8, 0x08), copy_dst);

    const index: u8 = @bitCast(opcodes.BufferUsage{ .index = true });
    try testing.expectEqual(@as(u8, 0x10), index);

    const vertex: u8 = @bitCast(opcodes.BufferUsage{ .vertex = true });
    try testing.expectEqual(@as(u8, 0x20), vertex);

    const uniform: u8 = @bitCast(opcodes.BufferUsage{ .uniform = true });
    try testing.expectEqual(@as(u8, 0x40), uniform);

    const storage: u8 = @bitCast(opcodes.BufferUsage{ .storage = true });
    try testing.expectEqual(@as(u8, 0x80), storage);
}

test "buffer usage combinations encode correctly" {
    // Common buffer usage patterns should encode to expected values

    // UNIFORM | COPY_DST (common for uniforms written by CPU)
    const uniform_copy_dst: u8 = @bitCast(opcodes.BufferUsage{ .uniform = true, .copy_dst = true });
    try testing.expectEqual(@as(u8, 0x48), uniform_copy_dst); // 0x40 | 0x08

    // VERTEX | COPY_DST (common for vertex buffers)
    const vertex_copy_dst: u8 = @bitCast(opcodes.BufferUsage{ .vertex = true, .copy_dst = true });
    try testing.expectEqual(@as(u8, 0x28), vertex_copy_dst); // 0x20 | 0x08

    // STORAGE | COPY_SRC | COPY_DST (common for compute buffers)
    const storage_copy: u8 = @bitCast(opcodes.BufferUsage{ .storage = true, .copy_src = true, .copy_dst = true });
    try testing.expectEqual(@as(u8, 0x8C), storage_copy); // 0x80 | 0x04 | 0x08

    // INDEX | COPY_DST (common for index buffers)
    const index_copy_dst: u8 = @bitCast(opcodes.BufferUsage{ .index = true, .copy_dst = true });
    try testing.expectEqual(@as(u8, 0x18), index_copy_dst); // 0x10 | 0x08
}

// ============================================================================
// Image Bitmap and Copy External Image Tests
// ============================================================================

test "create_image_bitmap dispatch" {
    // Test that create_image_bitmap opcode is correctly dispatched
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    // Add blob data (simulating [mime_len:u8][mime:bytes][data:bytes])
    // Format: mime_len (1 byte) + mime string + image data
    var blob_data: [14]u8 = undefined;
    blob_data[0] = 9; // mime length
    @memcpy(blob_data[1..10], "image/png");
    @memcpy(blob_data[10..14], &[_]u8{ 0x89, 0x50, 0x4E, 0x47 });
    const blob_data_id = try builder.addData(testing.allocator, &blob_data);

    const emitter = builder.getEmitter();

    // Emit create_image_bitmap
    try emitter.createImageBitmap(testing.allocator, 0, blob_data_id.toInt());

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(testing.allocator, &gpu, &module);
    try exec.executeAll(testing.allocator);

    // Property: create_image_bitmap was called
    try testing.expectEqual(@as(usize, 1), gpu.callCount());
    try testing.expectEqual(CallType.create_image_bitmap, gpu.getCall(0).call_type);

    // Property: parameters match
    const params = gpu.getCall(0).params.create_image_bitmap;
    try testing.expectEqual(@as(u16, 0), params.bitmap_id);
    try testing.expectEqual(blob_data_id.toInt(), params.blob_data_id);
}

test "copy_external_image_to_texture dispatch" {
    // Test that copy_external_image_to_texture opcode is correctly dispatched
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Emit copy_external_image_to_texture with various parameters
    try emitter.copyExternalImageToTexture(testing.allocator, 0, 1, 2, 64, 128);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(testing.allocator, &gpu, &module);
    try exec.executeAll(testing.allocator);

    // Property: copy was called
    try testing.expectEqual(@as(usize, 1), gpu.callCount());
    try testing.expectEqual(CallType.copy_external_image_to_texture, gpu.getCall(0).call_type);

    // Property: all parameters match
    const params = gpu.getCall(0).params.copy_external_image_to_texture;
    try testing.expectEqual(@as(u16, 0), params.bitmap_id);
    try testing.expectEqual(@as(u16, 1), params.texture_id);
    try testing.expectEqual(@as(u8, 2), params.mip_level);
    try testing.expectEqual(@as(u16, 64), params.origin_x);
    try testing.expectEqual(@as(u16, 128), params.origin_y);
}

test "image texture upload sequence" {
    // Test complete texture upload workflow via dispatcher
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    // Add texture descriptor
    const texture_desc = try DescriptorEncoder.encodeTexture(
        testing.allocator,
        256,
        256,
        .rgba8unorm,
        .{ .texture_binding = true, .copy_dst = true },
        1,
    );
    defer testing.allocator.free(texture_desc);
    const texture_desc_id = try builder.addData(testing.allocator, texture_desc);

    // Add blob data for image
    var blob_data: [26]u8 = undefined;
    blob_data[0] = 9; // mime length
    @memcpy(blob_data[1..10], "image/png");
    @memset(blob_data[10..26], 0); // dummy image data
    const blob_data_id = try builder.addData(testing.allocator, &blob_data);

    const emitter = builder.getEmitter();

    // 1. Create texture
    try emitter.createTexture(testing.allocator, 0, texture_desc_id.toInt());

    // 2. Create image bitmap from blob
    try emitter.createImageBitmap(testing.allocator, 0, blob_data_id.toInt());

    // 3. Copy image bitmap to texture
    try emitter.copyExternalImageToTexture(testing.allocator, 0, 0, 0, 0, 0);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(testing.allocator, &gpu, &module);
    try exec.executeAll(testing.allocator);

    // Property: correct call sequence
    const expected = [_]CallType{
        .create_texture,
        .create_image_bitmap,
        .copy_external_image_to_texture,
    };
    try testing.expect(gpu.expectCallTypes(&expected));
}

test "multiple image bitmaps dispatch" {
    // Test creating multiple image bitmaps
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    var blob1: [14]u8 = undefined;
    blob1[0] = 9; // mime length
    @memcpy(blob1[1..10], "image/png");
    @memset(blob1[10..14], 0);

    var blob2: [15]u8 = undefined;
    blob2[0] = 10; // mime length
    @memcpy(blob2[1..11], "image/jpeg");
    @memset(blob2[11..15], 0);

    const blob1_id = try builder.addData(testing.allocator, &blob1);
    const blob2_id = try builder.addData(testing.allocator, &blob2);

    const emitter = builder.getEmitter();

    try emitter.createImageBitmap(testing.allocator, 0, blob1_id.toInt());
    try emitter.createImageBitmap(testing.allocator, 1, blob2_id.toInt());

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(testing.allocator, &gpu, &module);
    try exec.executeAll(testing.allocator);

    // Property: both image bitmaps created
    try testing.expectEqual(@as(usize, 2), gpu.callCount());

    try testing.expectEqual(@as(u16, 0), gpu.getCall(0).params.create_image_bitmap.bitmap_id);
    try testing.expectEqual(@as(u16, 1), gpu.getCall(1).params.create_image_bitmap.bitmap_id);
}

test "image upload then render" {
    // Full integration: upload texture then use it in render pass
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    // Add texture descriptor
    const texture_desc = try DescriptorEncoder.encodeTexture(
        testing.allocator,
        256,
        256,
        .rgba8unorm,
        .{ .texture_binding = true, .copy_dst = true },
        1,
    );
    defer testing.allocator.free(texture_desc);
    const texture_desc_id = try builder.addData(testing.allocator, texture_desc);

    // Add blob data and shader code
    var blob_data: [18]u8 = undefined;
    blob_data[0] = 9; // mime length
    @memcpy(blob_data[1..10], "image/png");
    @memset(blob_data[10..18], 0); // dummy image data
    const blob_data_id = try builder.addData(testing.allocator, &blob_data);
    const shader_code_id = try builder.addData(testing.allocator, "@vertex fn vs() {}");
    const pipeline_desc_id = try builder.addData(testing.allocator, "{}");

    const emitter = builder.getEmitter();

    // Setup: upload texture
    try emitter.createTexture(testing.allocator, 0, texture_desc_id.toInt());
    try emitter.createImageBitmap(testing.allocator, 0, blob_data_id.toInt());
    try emitter.copyExternalImageToTexture(testing.allocator, 0, 0, 0, 0, 0);

    // Setup: create pipeline
    try emitter.createShaderModule(testing.allocator, 0, shader_code_id.toInt());
    try emitter.createRenderPipeline(testing.allocator, 0, pipeline_desc_id.toInt());

    // Render
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 6, 1, 0, 0); // Textured quad (2 triangles)
    try emitter.endPass(testing.allocator);
    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(testing.allocator, &gpu, &module);
    try exec.executeAll(testing.allocator);

    // Property: all expected calls made
    const expected = [_]CallType{
        .create_texture,
        .create_image_bitmap,
        .copy_external_image_to_texture,
        .create_shader_module,
        .create_render_pipeline,
        .begin_render_pass,
        .set_pipeline,
        .draw,
        .end_pass,
        .submit,
    };
    try testing.expect(gpu.expectCallTypes(&expected));

    // Property: texture was created before copy
    try testing.expect(gpu.textures_created.isSet(0));
}

test "copy to non-zero mip level" {
    // Test uploading to a specific mip level
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Copy to mip level 3
    try emitter.copyExternalImageToTexture(testing.allocator, 0, 0, 3, 0, 0);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(testing.allocator, &gpu, &module);
    try exec.executeAll(testing.allocator);

    // Property: mip level preserved
    try testing.expectEqual(@as(u8, 3), gpu.getCall(0).params.copy_external_image_to_texture.mip_level);
}

test "copy with large origin offset" {
    // Test copying to offset position (e.g., for texture atlases)
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Copy to offset (512, 1024) - requires 2-byte varints
    try emitter.copyExternalImageToTexture(testing.allocator, 0, 0, 0, 512, 1024);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(testing.allocator, &gpu, &module);
    try exec.executeAll(testing.allocator);

    // Property: origin preserved through varint encoding/decoding
    const params = gpu.getCall(0).params.copy_external_image_to_texture;
    try testing.expectEqual(@as(u16, 512), params.origin_x);
    try testing.expectEqual(@as(u16, 1024), params.origin_y);
}

// ============================================================================
// Blob Format Parsing Tests
// ============================================================================

/// Helper: parse blob format [mime_len:u8][mime:bytes][data:bytes]
/// Returns (mime_type, image_data) or null if invalid
fn parseBlobFormat(blob: []const u8) ?struct { mime: []const u8, data: []const u8 } {
    if (blob.len == 0) return null;

    const mime_len: usize = blob[0];
    if (mime_len == 0) return null;
    if (1 + mime_len > blob.len) return null;

    return .{
        .mime = blob[1 .. 1 + mime_len],
        .data = blob[1 + mime_len ..],
    };
}

test "blob format parsing: valid formats" {
    // Test valid blob formats
    var blob1: [14]u8 = undefined;
    blob1[0] = 9; // mime length
    @memcpy(blob1[1..10], "image/png");
    @memset(blob1[10..14], 0xFF);

    const result1 = parseBlobFormat(&blob1);
    try testing.expect(result1 != null);
    try testing.expectEqualStrings("image/png", result1.?.mime);
    try testing.expectEqual(@as(usize, 4), result1.?.data.len);

    // Test JPEG mime type
    var blob2: [15]u8 = undefined;
    blob2[0] = 10; // mime length
    @memcpy(blob2[1..11], "image/jpeg");
    @memset(blob2[11..15], 0xAB);

    const result2 = parseBlobFormat(&blob2);
    try testing.expect(result2 != null);
    try testing.expectEqualStrings("image/jpeg", result2.?.mime);
    try testing.expectEqual(@as(usize, 4), result2.?.data.len);
}

test "blob format parsing: edge cases" {
    // Empty blob
    const empty: []const u8 = &[_]u8{};
    try testing.expect(parseBlobFormat(empty) == null);

    // Zero mime length (invalid)
    const zero_mime = [_]u8{0};
    try testing.expect(parseBlobFormat(&zero_mime) == null);

    // Mime length exceeds blob size
    const truncated = [_]u8{ 50, 'a', 'b', 'c' };
    try testing.expect(parseBlobFormat(&truncated) == null);

    // Exactly mime, no data (valid but unusual)
    var exact: [10]u8 = undefined;
    exact[0] = 9;
    @memcpy(exact[1..10], "image/png");
    const result = parseBlobFormat(&exact);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 0), result.?.data.len);
}

test "blob format parsing: boundary values" {
    // Minimum valid blob (1 byte mime + 0 data)
    const min_blob = [_]u8{ 1, 'x' };
    const result_min = parseBlobFormat(&min_blob);
    try testing.expect(result_min != null);
    try testing.expectEqualStrings("x", result_min.?.mime);
    try testing.expectEqual(@as(usize, 0), result_min.?.data.len);

    // Large mime length (200 bytes) - test larger but not max to avoid large stack allocation
    var large_mime: [202]u8 = undefined;
    large_mime[0] = 200;
    for (1..201) |i| {
        large_mime[i] = 'a';
    }
    large_mime[201] = 0xFF; // 1 byte of data

    const result_large = parseBlobFormat(&large_mime);
    try testing.expect(result_large != null);
    try testing.expectEqual(@as(usize, 200), result_large.?.mime.len);
    try testing.expectEqual(@as(usize, 1), result_large.?.data.len);
}

test "blob format property: mime_len + mime + data = blob.len" {
    // Property-based test: for any valid blob, the structure is consistent
    const test_cases = [_]struct { mime_len: u8, data_len: usize }{
        .{ .mime_len = 9, .data_len = 100 },
        .{ .mime_len = 10, .data_len = 0 },
        .{ .mime_len = 1, .data_len = 50 },
        .{ .mime_len = 100, .data_len = 50 },
    };

    for (test_cases) |tc| {
        const mime_len_usize: usize = tc.mime_len;
        const total_len = 1 + mime_len_usize + tc.data_len;
        const blob = try testing.allocator.alloc(u8, total_len);
        defer testing.allocator.free(blob);

        blob[0] = tc.mime_len;
        // Fill mime bytes
        for (0..mime_len_usize) |i| {
            blob[1 + i] = 'm';
        }
        // Fill data bytes
        for (0..tc.data_len) |i| {
            blob[1 + mime_len_usize + i] = 'd';
        }

        const result = parseBlobFormat(blob);
        try testing.expect(result != null);

        // Property: parsed structure matches input
        try testing.expectEqual(mime_len_usize, result.?.mime.len);
        try testing.expectEqual(tc.data_len, result.?.data.len);
    }
}

test "fuzz blob parsing with random data" {
    // Use deterministic random for reproducibility.
    // Use a default seed if testing.random_seed is 0 to avoid PRNG issues.
    const seed: u64 = if (std.testing.random_seed != 0)
        std.testing.random_seed
    else
        0xDEADBEEF12345678;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    const iterations = 100;
    for (0..iterations) |_| {
        const len = random.intRangeAtMost(usize, 1, 300);

        const blob = try testing.allocator.alloc(u8, len);
        defer testing.allocator.free(blob);

        // Fill with random data
        random.bytes(blob);

        // Property: parsing never crashes
        const result = parseBlobFormat(blob);

        // Property: if valid, structure is consistent
        if (result) |parsed| {
            // mime_len matches actual mime length
            try testing.expectEqual(@as(usize, blob[0]), parsed.mime.len);

            // All data is accounted for
            try testing.expectEqual(blob.len - 1 - parsed.mime.len, parsed.data.len);
        }
    }
}

// ============================================================================
// Async Texture Upload Sequence Tests
// ============================================================================
//
// These tests verify the correct ordering of operations for textured rendering.
// In JavaScript, createImageBitmap is async - it returns a Promise that decodes
// the image. The WASM bytecode executes synchronously, so:
//
// 1. create_image_bitmap starts async decode (JS stores Promise in imageBitmaps Map)
// 2. copy_external_image_to_texture tries to copy from pending Promise
// 3. draw executes with no texture data (black)
// 4. Async decode completes AFTER submit
//
// Fix: JS must call waitForBitmaps() after first executeAll() to wait for
// all ImageBitmap Promises to resolve, then re-execute.

test "texture upload sequence: bitmap before copy" {
    // Invariant: create_image_bitmap MUST come before copy_external_image_to_texture
    // for the same bitmap_id. This test verifies bytecode order is correct.
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    var blob_data: [14]u8 = undefined;
    blob_data[0] = 9; // mime length
    @memcpy(blob_data[1..10], "image/png");
    @memset(blob_data[10..14], 0);
    const blob_id = try builder.addData(testing.allocator, &blob_data);

    const emitter = builder.getEmitter();

    // Correct order: create bitmap 0, then copy from bitmap 0
    try emitter.createImageBitmap(testing.allocator, 0, blob_id.toInt());
    try emitter.copyExternalImageToTexture(testing.allocator, 0, 0, 0, 0, 0);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(testing.allocator, &gpu, &module);
    try exec.executeAll(testing.allocator);

    // Invariant: create_image_bitmap comes before copy_external_image_to_texture
    const calls = gpu.getCalls();
    try testing.expectEqual(@as(usize, 2), calls.len);
    try testing.expectEqual(CallType.create_image_bitmap, calls[0].call_type);
    try testing.expectEqual(CallType.copy_external_image_to_texture, calls[1].call_type);

    // Invariant: same bitmap_id used in both calls
    try testing.expectEqual(
        calls[0].params.create_image_bitmap.bitmap_id,
        calls[1].params.copy_external_image_to_texture.bitmap_id,
    );
}

test "texture upload sequence: copy before draw" {
    // Invariant: copy_external_image_to_texture MUST complete before draw
    // for the texture to be visible. This test verifies bytecode order.
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    // Setup resources
    const texture_desc = try DescriptorEncoder.encodeTexture(
        testing.allocator,
        256,
        256,
        .rgba8unorm,
        .{ .texture_binding = true, .copy_dst = true },
        1,
    );
    defer testing.allocator.free(texture_desc);
    const texture_desc_id = try builder.addData(testing.allocator, texture_desc);

    var blob_data: [14]u8 = undefined;
    blob_data[0] = 9;
    @memcpy(blob_data[1..10], "image/png");
    @memset(blob_data[10..14], 0);
    const blob_id = try builder.addData(testing.allocator, &blob_data);
    const shader_id = try builder.addData(testing.allocator, "@vertex fn vs() {}");
    const pipeline_id = try builder.addData(testing.allocator, "{}");

    const emitter = builder.getEmitter();

    // Resource creation phase
    try emitter.createTexture(testing.allocator, 0, texture_desc_id.toInt());
    try emitter.createImageBitmap(testing.allocator, 0, blob_id.toInt());
    try emitter.copyExternalImageToTexture(testing.allocator, 0, 0, 0, 0, 0);
    try emitter.createShaderModule(testing.allocator, 0, shader_id.toInt());
    try emitter.createRenderPipeline(testing.allocator, 0, pipeline_id.toInt());

    // Render phase - must come AFTER texture upload
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 6, 1, 0, 0);
    try emitter.endPass(testing.allocator);
    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(testing.allocator, &gpu, &module);
    try exec.executeAll(testing.allocator);

    // Find indices of key operations
    const calls = gpu.getCalls();
    var copy_idx: ?usize = null;
    var draw_idx: ?usize = null;

    for (calls, 0..) |call, i| {
        if (call.call_type == .copy_external_image_to_texture) copy_idx = i;
        if (call.call_type == .draw) draw_idx = i;
    }

    // Invariant: copy_external_image_to_texture appears before draw
    try testing.expect(copy_idx != null);
    try testing.expect(draw_idx != null);
    try testing.expect(copy_idx.? < draw_idx.?);
}

test "texture upload sequence: full frame with multiple bitmaps" {
    // Test frame that uploads multiple textures before rendering.
    // This simulates the textured_rotating_cube example.
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    // Two textures
    const tex_desc = try DescriptorEncoder.encodeTexture(
        testing.allocator,
        256,
        256,
        .rgba8unorm,
        .{ .texture_binding = true, .copy_dst = true },
        1,
    );
    defer testing.allocator.free(tex_desc);
    const tex_desc_id = try builder.addData(testing.allocator, tex_desc);

    // Two blobs
    var blob1: [14]u8 = undefined;
    blob1[0] = 9;
    @memcpy(blob1[1..10], "image/png");
    @memset(blob1[10..14], 0);
    var blob2: [14]u8 = undefined;
    blob2[0] = 9;
    @memcpy(blob2[1..10], "image/png");
    @memset(blob2[10..14], 1);

    const blob1_id = try builder.addData(testing.allocator, &blob1);
    const blob2_id = try builder.addData(testing.allocator, &blob2);
    const shader_id = try builder.addData(testing.allocator, "@vertex fn vs() {}");
    const pipeline_id = try builder.addData(testing.allocator, "{}");

    const emitter = builder.getEmitter();

    // Create two textures and upload both
    try emitter.createTexture(testing.allocator, 0, tex_desc_id.toInt());
    try emitter.createTexture(testing.allocator, 1, tex_desc_id.toInt());
    try emitter.createImageBitmap(testing.allocator, 0, blob1_id.toInt());
    try emitter.createImageBitmap(testing.allocator, 1, blob2_id.toInt());
    try emitter.copyExternalImageToTexture(testing.allocator, 0, 0, 0, 0, 0);
    try emitter.copyExternalImageToTexture(testing.allocator, 1, 1, 0, 0, 0);

    // Pipeline and render
    try emitter.createShaderModule(testing.allocator, 0, shader_id.toInt());
    try emitter.createRenderPipeline(testing.allocator, 0, pipeline_id.toInt());
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 36, 1, 0, 0); // Cube with 36 vertices
    try emitter.endPass(testing.allocator);
    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(testing.allocator, &gpu, &module);
    try exec.executeAll(testing.allocator);

    // Count operations
    var bitmap_count: usize = 0;
    var copy_count: usize = 0;
    var last_copy_idx: usize = 0;
    var draw_idx: usize = 0;

    const calls = gpu.getCalls();
    for (calls, 0..) |call, i| {
        switch (call.call_type) {
            .create_image_bitmap => bitmap_count += 1,
            .copy_external_image_to_texture => {
                copy_count += 1;
                last_copy_idx = i;
            },
            .draw => draw_idx = i,
            else => {},
        }
    }

    // Invariant: all bitmaps created
    try testing.expectEqual(@as(usize, 2), bitmap_count);

    // Invariant: all copies executed
    try testing.expectEqual(@as(usize, 2), copy_count);

    // Invariant: all copies before draw
    try testing.expect(last_copy_idx < draw_idx);
}

// ============================================================================
// Pool Operations Tests (Ping-Pong Buffers)
// ============================================================================
//
// These tests verify the pool operations used for ping-pong buffer patterns
// in compute simulations like boids. The key formula is:
//   actual_id = base_id + (frame_counter + offset) % pool_size
//
// For boids with 2-buffer ping-pong:
// - Frame 0: compute reads buffer 0, writes buffer 1
// - Frame 1: compute reads buffer 1, writes buffer 0
// - Frame 2: compute reads buffer 0, writes buffer 1 (cycle repeats)

test "set_vertex_buffer_pool: basic ping-pong" {
    // Test set_vertex_buffer_pool with pool_size=2
    // At frame 0 with offset 0: should select buffer 0
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    // Create two buffers for ping-pong
    try emitter.createBuffer(testing.allocator, 0, 1024, .{ .vertex = true, .storage = true });
    try emitter.createBuffer(testing.allocator, 1, 1024, .{ .vertex = true, .storage = true });

    // Render pass using pooled vertex buffer
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.setVertexBufferPool(testing.allocator, 0, 0, 2, 0); // slot=0, base=0, pool=2, offset=0
    try emitter.draw(testing.allocator, 1000, 1, 0, 0);
    try emitter.endPass(testing.allocator);
    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    // Execute at frame 0
    var exec = MockDispatcher.initWithFrame(testing.allocator, &gpu, &module, 0);
    defer exec.deinit();
    try exec.executeAll(testing.allocator);

    // Find set_vertex_buffer call
    var found_vb = false;
    for (gpu.getCalls()) |call| {
        if (call.call_type == .set_vertex_buffer) {
            // At frame 0, offset 0: (0 + 0) % 2 = 0
            try testing.expectEqual(@as(u16, 0), call.params.set_vertex_buffer.buffer_id);
            found_vb = true;
            break;
        }
    }
    try testing.expect(found_vb);
}

test "set_vertex_buffer_pool: frame counter affects selection" {
    // Test that different frame counters select different buffers
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    try emitter.createBuffer(testing.allocator, 0, 1024, .{ .vertex = true });
    try emitter.createBuffer(testing.allocator, 1, 1024, .{ .vertex = true });

    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setVertexBufferPool(testing.allocator, 0, 0, 2, 0); // pool_size=2, offset=0
    try emitter.endPass(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Test frame 0, 1, 2, 3 to verify alternation
    const expected_buffers = [_]u16{ 0, 1, 0, 1 };
    for (expected_buffers, 0..) |expected_buffer, frame| {
        var gpu: MockGPU = .empty;
        defer gpu.deinit(testing.allocator);

        var exec = MockDispatcher.initWithFrame(testing.allocator, &gpu, &module, @intCast(frame));
        defer exec.deinit();
        try exec.executeAll(testing.allocator);

        // Find set_vertex_buffer call
        for (gpu.getCalls()) |call| {
            if (call.call_type == .set_vertex_buffer) {
                try testing.expectEqual(expected_buffer, call.params.set_vertex_buffer.buffer_id);
                break;
            }
        }
    }
}

test "set_vertex_buffer_pool: offset shifts selection" {
    // Test that offset parameter shifts which buffer is selected
    // offset=1 at frame 0 should select buffer 1, not buffer 0
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    try emitter.createBuffer(testing.allocator, 0, 1024, .{ .vertex = true });
    try emitter.createBuffer(testing.allocator, 1, 1024, .{ .vertex = true });

    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setVertexBufferPool(testing.allocator, 0, 0, 2, 1); // pool_size=2, offset=1
    try emitter.endPass(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    // Execute at frame 0 with offset=1
    var exec = MockDispatcher.initWithFrame(testing.allocator, &gpu, &module, 0);
    defer exec.deinit();
    try exec.executeAll(testing.allocator);

    // Find set_vertex_buffer call: (0 + 1) % 2 = 1
    for (gpu.getCalls()) |call| {
        if (call.call_type == .set_vertex_buffer) {
            try testing.expectEqual(@as(u16, 1), call.params.set_vertex_buffer.buffer_id);
            break;
        }
    }
}

test "set_bind_group_pool: basic ping-pong" {
    // Test set_bind_group_pool with pool_size=2
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const entries_data = try builder.addData(testing.allocator, "[]");
    const emitter = builder.getEmitter();

    // Create two bind groups for ping-pong
    try emitter.createBindGroup(testing.allocator, 0, 0, entries_data.toInt());
    try emitter.createBindGroup(testing.allocator, 1, 0, entries_data.toInt());

    try emitter.beginComputePass(testing.allocator);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.setBindGroupPool(testing.allocator, 0, 0, 2, 0); // slot=0, base=0, pool=2, offset=0
    try emitter.dispatch(testing.allocator, 64, 1, 1);
    try emitter.endPass(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.initWithFrame(testing.allocator, &gpu, &module, 0);
    defer exec.deinit();
    try exec.executeAll(testing.allocator);

    // At frame 0, offset 0: should use bind group 0
    for (gpu.getCalls()) |call| {
        if (call.call_type == .set_bind_group) {
            try testing.expectEqual(@as(u16, 0), call.params.set_bind_group.group_id);
            break;
        }
    }
}

test "set_bind_group_pool: frame counter affects selection" {
    // Test that different frame counters select different bind groups
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const entries_data = try builder.addData(testing.allocator, "[]");
    const emitter = builder.getEmitter();

    try emitter.createBindGroup(testing.allocator, 0, 0, entries_data.toInt());
    try emitter.createBindGroup(testing.allocator, 1, 0, entries_data.toInt());

    try emitter.beginComputePass(testing.allocator);
    try emitter.setBindGroupPool(testing.allocator, 0, 0, 2, 0);
    try emitter.endPass(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Test frame 0, 1, 2, 3 to verify alternation
    const expected_groups = [_]u16{ 0, 1, 0, 1 };
    for (expected_groups, 0..) |expected_group, frame| {
        var gpu: MockGPU = .empty;
        defer gpu.deinit(testing.allocator);

        var exec = MockDispatcher.initWithFrame(testing.allocator, &gpu, &module, @intCast(frame));
        defer exec.deinit();
        try exec.executeAll(testing.allocator);

        for (gpu.getCalls()) |call| {
            if (call.call_type == .set_bind_group) {
                try testing.expectEqual(expected_group, call.params.set_bind_group.group_id);
                break;
            }
        }
    }
}

test "pool operations: boids ping-pong pattern" {
    // Simulate the boids pattern:
    // - Compute pass: reads from buffer A, writes to buffer B
    // - Render pass: reads from buffer B (the newly computed positions)
    //
    // With pool_size=2:
    // - Compute bind group offset=0: reads buffer (frame % 2)
    // - Render vertex buffer offset=1: reads buffer ((frame + 1) % 2) = opposite buffer
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const entries_data = try builder.addData(testing.allocator, "[]");
    const emitter = builder.getEmitter();

    // Create resources
    try emitter.createBuffer(testing.allocator, 0, 4096, .{ .vertex = true, .storage = true });
    try emitter.createBuffer(testing.allocator, 1, 4096, .{ .vertex = true, .storage = true });
    try emitter.createBindGroup(testing.allocator, 0, 0, entries_data.toInt());
    try emitter.createBindGroup(testing.allocator, 1, 0, entries_data.toInt());

    // Compute pass - uses bind group (frame + 0) % 2
    try emitter.beginComputePass(testing.allocator);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.setBindGroupPool(testing.allocator, 0, 0, 2, 0);
    try emitter.dispatch(testing.allocator, 64, 1, 1);
    try emitter.endPass(testing.allocator);

    // Render pass - uses vertex buffer (frame + 1) % 2 (the output buffer)
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setPipeline(testing.allocator, 1);
    try emitter.setVertexBufferPool(testing.allocator, 0, 0, 2, 1); // offset=1 for opposite buffer
    try emitter.draw(testing.allocator, 1000, 1, 0, 0);
    try emitter.endPass(testing.allocator);
    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Test frame 0
    {
        var gpu: MockGPU = .empty;
        defer gpu.deinit(testing.allocator);

        var exec = MockDispatcher.initWithFrame(testing.allocator, &gpu, &module, 0);
        defer exec.deinit();
        try exec.executeAll(testing.allocator);

        var compute_bind_group: ?u16 = null;
        var render_vertex_buffer: ?u16 = null;

        for (gpu.getCalls()) |call| {
            switch (call.call_type) {
                .set_bind_group => compute_bind_group = call.params.set_bind_group.group_id,
                .set_vertex_buffer => render_vertex_buffer = call.params.set_vertex_buffer.buffer_id,
                else => {},
            }
        }

        // Frame 0: compute reads group 0, render reads buffer 1
        try testing.expectEqual(@as(u16, 0), compute_bind_group.?);
        try testing.expectEqual(@as(u16, 1), render_vertex_buffer.?);
    }

    // Test frame 1
    {
        var gpu: MockGPU = .empty;
        defer gpu.deinit(testing.allocator);

        var exec = MockDispatcher.initWithFrame(testing.allocator, &gpu, &module, 1);
        defer exec.deinit();
        try exec.executeAll(testing.allocator);

        var compute_bind_group: ?u16 = null;
        var render_vertex_buffer: ?u16 = null;

        for (gpu.getCalls()) |call| {
            switch (call.call_type) {
                .set_bind_group => compute_bind_group = call.params.set_bind_group.group_id,
                .set_vertex_buffer => render_vertex_buffer = call.params.set_vertex_buffer.buffer_id,
                else => {},
            }
        }

        // Frame 1: compute reads group 1, render reads buffer 0
        try testing.expectEqual(@as(u16, 1), compute_bind_group.?);
        try testing.expectEqual(@as(u16, 0), render_vertex_buffer.?);
    }
}

test "pool operations: larger pool size" {
    // Test with pool_size=4 (e.g., for triple/quad buffering)
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const emitter = builder.getEmitter();

    for (0..4) |i| {
        try emitter.createBuffer(testing.allocator, @intCast(i), 1024, .{ .vertex = true });
    }

    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setVertexBufferPool(testing.allocator, 0, 0, 4, 0); // pool_size=4
    try emitter.endPass(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Test frames 0-7 to verify cycling through all 4 buffers
    const expected_buffers = [_]u16{ 0, 1, 2, 3, 0, 1, 2, 3 };
    for (expected_buffers, 0..) |expected, frame| {
        var gpu: MockGPU = .empty;
        defer gpu.deinit(testing.allocator);

        var exec = MockDispatcher.initWithFrame(testing.allocator, &gpu, &module, @intCast(frame));
        defer exec.deinit();
        try exec.executeAll(testing.allocator);

        for (gpu.getCalls()) |call| {
            if (call.call_type == .set_vertex_buffer) {
                try testing.expectEqual(expected, call.params.set_vertex_buffer.buffer_id);
                break;
            }
        }
    }
}

test "frame counter increment on end_frame" {
    // Test that end_frame increments the frame counter
    var builder = Builder.init();
    defer builder.deinit(testing.allocator);

    const name_id = try builder.internString(testing.allocator, "testFrame");
    const emitter = builder.getEmitter();

    // Define frame with pool operation inside
    try emitter.defineFrame(testing.allocator, 0, name_id.toInt());
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store, 0xFFFF);
    try emitter.setVertexBufferPool(testing.allocator, 0, 0, 2, 0);
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

    var exec = MockDispatcher.initWithFrame(testing.allocator, &gpu, &module, 0);
    defer exec.deinit();

    // First execution: frame_counter starts at 0
    try exec.executeAll(testing.allocator);

    // After end_frame, frame_counter should be 1
    try testing.expectEqual(@as(u32, 1), exec.frame_counter);
}

// ============================================================================
// Pool Calculation Property Tests (Fuzz-style)
// ============================================================================

test "pool calculation property: always in range" {
    // Property: actual_id is always in range [base_id, base_id + pool_size - 1]
    const seed: u64 = if (std.testing.random_seed != 0)
        std.testing.random_seed
    else
        0xDEADBEEF12345678;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    const iterations = 1000;
    for (0..iterations) |_| {
        const base_id: u16 = random.intRangeAtMost(u16, 0, 200);
        const pool_size: u8 = random.intRangeAtMost(u8, 1, 16);
        const offset: u8 = random.intRangeAtMost(u8, 0, pool_size - 1);
        const frame_counter: u32 = random.int(u32);

        // This is the formula used in dispatcher.zig
        const actual_id: u16 = @intCast(base_id + (frame_counter + offset) % pool_size);

        // Property: actual_id is in valid range
        try testing.expect(actual_id >= base_id);
        try testing.expect(actual_id < base_id + pool_size);
    }
}

test "pool calculation property: deterministic" {
    // Property: same inputs always produce same output
    const test_cases = [_]struct { base: u16, pool: u8, offset: u8, frame: u32, expected: u16 }{
        .{ .base = 0, .pool = 2, .offset = 0, .frame = 0, .expected = 0 },
        .{ .base = 0, .pool = 2, .offset = 0, .frame = 1, .expected = 1 },
        .{ .base = 0, .pool = 2, .offset = 1, .frame = 0, .expected = 1 },
        .{ .base = 0, .pool = 2, .offset = 1, .frame = 1, .expected = 0 },
        .{ .base = 5, .pool = 3, .offset = 0, .frame = 7, .expected = 6 }, // 5 + (7 + 0) % 3 = 5 + 1 = 6
        .{ .base = 10, .pool = 4, .offset = 2, .frame = 5, .expected = 13 }, // 10 + (5 + 2) % 4 = 10 + 3 = 13
    };

    for (test_cases) |tc| {
        const actual_id: u16 = @intCast(tc.base + (tc.frame + tc.offset) % tc.pool);
        try testing.expectEqual(tc.expected, actual_id);
    }
}

test "pool calculation property: periodic" {
    // Property: output cycles with period = pool_size
    const base_id: u16 = 0;
    const pool_size: u8 = 3;
    const offset: u8 = 0;

    var prev_cycle: [3]u16 = undefined;
    // First cycle
    for (0..pool_size) |i| {
        prev_cycle[i] = @intCast(base_id + (@as(u32, @intCast(i)) + offset) % pool_size);
    }

    // Next several cycles should match
    for (1..10) |cycle| {
        for (0..pool_size) |i| {
            const frame: u32 = @intCast(cycle * pool_size + i);
            const actual_id: u16 = @intCast(base_id + (frame + offset) % pool_size);
            try testing.expectEqual(prev_cycle[i], actual_id);
        }
    }
}
