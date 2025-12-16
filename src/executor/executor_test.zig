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
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 3, 1);
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

    var exec = MockDispatcher.init(&gpu, &module);
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

    var exec = MockDispatcher.init(&gpu, &module);
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
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store); // clear, store
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 36, 100); // 100 instances
    try emitter.endPass(testing.allocator);

    // Pass 2: main scene
    try emitter.beginRenderPass(testing.allocator, 1, .clear, .store); // clear, store
    try emitter.setPipeline(testing.allocator, 1);
    try emitter.draw(testing.allocator, 36, 100);
    try emitter.endPass(testing.allocator);

    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(&gpu, &module);
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
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.setVertexBuffer(testing.allocator, 0, 0);
    try emitter.draw(testing.allocator, 3, 1);
    try emitter.endPass(testing.allocator);
    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(&gpu, &module);
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
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.setBindGroup(testing.allocator, 0, 0);
    try emitter.draw(testing.allocator, 3, 1);
    try emitter.endPass(testing.allocator);
    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(&gpu, &module);
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
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store);
    try emitter.draw(testing.allocator, 10000, 1);

    // Draw with very large count (tests 4-byte varint)
    try emitter.draw(testing.allocator, 100000, 500);
    try emitter.endPass(testing.allocator);

    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(&gpu, &module);
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

    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.drawIndexed(testing.allocator, 36, 10);
    try emitter.endPass(testing.allocator);
    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(&gpu, &module);
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
    try emitter.beginRenderPass(testing.allocator, 0, .clear, .store);
    try emitter.setPipeline(testing.allocator, 0);
    try emitter.draw(testing.allocator, 3, 1);
    try emitter.endPass(testing.allocator);
    try emitter.submit(testing.allocator);

    const pngb = try builder.finalize(testing.allocator);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(testing.allocator);

    var exec = MockDispatcher.init(&gpu, &module);
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
