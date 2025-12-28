//! PNGB Opcode Definitions
//!
//! Defines the instruction set for the PNGine bytecode interpreter.
//! This module contains ONLY type definitions - no encoding utilities.
//!
//! Categories:
//! - 0x00-0x0F: Resource Creation (buffers, textures, pipelines)
//! - 0x10-0x1F: Pass Operations (render/compute pass commands)
//! - 0x20-0x2F: Queue Operations (write, copy, submit)
//! - 0x30-0x3F: Frame Control (frame/pass definitions)
//! - 0x40-0x4F: Pool Operations (resource pooling)
//! - 0x50-0x7F: Data Generation (runtime array generation)
//!
//! Invariants:
//! - Opcode 0x00 is reserved (invalid/nop)
//! - Each opcode has fixed parameter count (no variadic)

const std = @import("std");

/// Bytecode opcodes.
pub const OpCode = enum(u8) {
    // ========================================================================
    // Resource Creation (0x00-0x0F)
    // ========================================================================

    /// No operation / invalid.
    nop = 0x00,

    /// Create GPU buffer.
    /// Params: buffer_id, size, usage_flags
    create_buffer = 0x01,

    /// Create GPU texture.
    /// Params: texture_id, width, height, format, usage_flags
    create_texture = 0x02,

    /// Create sampler.
    /// Params: sampler_id, descriptor_data_id
    create_sampler = 0x03,

    /// Create shader module from data section.
    /// Params: shader_id, code_data_id
    create_shader_module = 0x04,

    /// Create shader by concatenating multiple data sections (WGSL composition).
    /// Params: shader_id, count, data_id_0, data_id_1, ...
    create_shader_concat = 0x05,

    /// Create bind group layout.
    /// Params: layout_id, descriptor_data_id
    create_bind_group_layout = 0x06,

    /// Create pipeline layout.
    /// Params: layout_id, descriptor_data_id
    create_pipeline_layout = 0x07,

    /// Create render pipeline.
    /// Params: pipeline_id, descriptor_data_id
    create_render_pipeline = 0x08,

    /// Create compute pipeline.
    /// Params: pipeline_id, descriptor_data_id
    create_compute_pipeline = 0x09,

    /// Create bind group.
    /// Params: group_id, layout_id, entry_count, entries...
    create_bind_group = 0x0A,

    /// Create image bitmap from blob data.
    /// Params: bitmap_id, blob_data_id
    create_image_bitmap = 0x0B,

    /// Create texture view.
    /// Params: view_id, texture_id, descriptor_data_id
    create_texture_view = 0x0C,

    /// Create query set.
    /// Params: query_set_id, descriptor_data_id
    create_query_set = 0x0D,

    /// Create render bundle from pre-recorded draw commands.
    /// Params: bundle_id, descriptor_data_id
    create_render_bundle = 0x0E,

    // ========================================================================
    // Pass Operations (0x10-0x1F)
    // ========================================================================

    /// Begin render pass.
    /// Params: color_texture_id, load_op, store_op, depth_texture_id (0xFFFF = none)
    begin_render_pass = 0x10,

    /// Begin compute pass.
    begin_compute_pass = 0x11,

    /// Set current pipeline.
    /// Params: pipeline_id
    set_pipeline = 0x12,

    /// Set bind group.
    /// Params: slot, group_id
    set_bind_group = 0x13,

    /// Set vertex buffer.
    /// Params: slot, buffer_id
    set_vertex_buffer = 0x14,

    /// Set index buffer.
    /// Params: buffer_id, format
    set_index_buffer = 0x15,

    /// Draw primitives.
    /// Params: vertex_count, instance_count
    draw = 0x16,

    /// Draw indexed primitives.
    /// Params: index_count, instance_count
    draw_indexed = 0x17,

    /// Dispatch compute workgroups.
    /// Params: x, y, z
    dispatch = 0x18,

    /// End current pass.
    end_pass = 0x19,

    /// Execute pre-recorded render bundles.
    /// Params: bundle_count, bundle_id_0, bundle_id_1, ...
    execute_bundles = 0x1A,

    // ========================================================================
    // Queue Operations (0x20-0x2F)
    // ========================================================================

    /// Write data to buffer.
    /// Params: buffer_id, offset, data_id
    write_buffer = 0x20,

    /// Write uniform data (runtime-resolved).
    /// Params: buffer_id, uniform_id
    write_uniform = 0x21,

    /// Copy buffer to buffer.
    /// Params: src_buffer, src_offset, dst_buffer, dst_offset, size
    copy_buffer_to_buffer = 0x22,

    /// Copy texture to texture.
    copy_texture_to_texture = 0x23,

    /// Submit command buffer to queue.
    submit = 0x24,

    /// Copy external image (ImageBitmap) to texture.
    /// Params: bitmap_id, texture_id, mip_level, origin_x, origin_y
    copy_external_image_to_texture = 0x25,

    /// Initialize WASM module from embedded data.
    /// Params: module_id, wasm_data_id
    init_wasm_module = 0x26,

    /// Call WASM exported function.
    /// Params: call_id, module_id, func_name_id, arg_count, [args...]
    call_wasm_func = 0x27,

    /// Write WASM memory to GPU buffer.
    /// Params: call_id, buffer_id, offset, byte_len
    write_buffer_from_wasm = 0x28,

    /// Write runtime-generated array to GPU buffer.
    /// Params: buffer_id, buffer_offset, array_id
    write_buffer_from_array = 0x29,

    /// Write time/canvas uniform data to buffer.
    /// Params: buffer_id, offset, size
    write_time_uniform = 0x2A,

    // ========================================================================
    // Frame Control (0x30-0x3F)
    // ========================================================================

    /// Define a frame.
    /// Params: frame_id, name_string_id
    define_frame = 0x30,

    /// End frame definition.
    end_frame = 0x31,

    /// Execute a pass within a frame.
    /// Params: pass_id
    exec_pass = 0x32,

    /// Define a pass.
    /// Params: pass_id, pass_type, descriptor_data_id
    define_pass = 0x33,

    /// End pass definition.
    end_pass_def = 0x34,

    // ========================================================================
    // Pool Operations (0x40-0x4F)
    // ========================================================================

    /// Select resource from pool (ping-pong).
    /// Params: dest_slot, pool_id, frame_offset
    select_from_pool = 0x40,

    /// Set vertex buffer from pool.
    /// Params: slot, base_buffer_id, pool_size, offset
    set_vertex_buffer_pool = 0x41,

    /// Set bind group from pool.
    /// Params: slot, base_group_id, pool_size, offset
    set_bind_group_pool = 0x42,

    // ========================================================================
    // Data Generation (0x50-0x7F)
    // ========================================================================

    /// Create typed array.
    /// Params: array_id, element_type, element_count
    create_typed_array = 0x50,

    /// Fill with constant value.
    fill_constant = 0x51,

    /// Fill with random values.
    fill_random = 0x52,

    /// Fill with linear sequence.
    fill_linear = 0x53,

    /// Fill with element index.
    fill_element_index = 0x54,

    /// Fill with expression result.
    fill_expression = 0x55,

    _,

    /// Check if opcode is valid.
    pub fn isValid(self: OpCode) bool {
        return switch (self) {
            .nop,
            .create_buffer,
            .create_texture,
            .create_sampler,
            .create_shader_module,
            .create_shader_concat,
            .create_bind_group_layout,
            .create_pipeline_layout,
            .create_render_pipeline,
            .create_compute_pipeline,
            .create_bind_group,
            .create_image_bitmap,
            .create_texture_view,
            .create_query_set,
            .create_render_bundle,
            .begin_render_pass,
            .begin_compute_pass,
            .set_pipeline,
            .set_bind_group,
            .set_vertex_buffer,
            .set_index_buffer,
            .draw,
            .draw_indexed,
            .dispatch,
            .execute_bundles,
            .end_pass,
            .write_buffer,
            .write_uniform,
            .copy_buffer_to_buffer,
            .copy_texture_to_texture,
            .submit,
            .copy_external_image_to_texture,
            .init_wasm_module,
            .call_wasm_func,
            .write_buffer_from_wasm,
            .write_buffer_from_array,
            .define_frame,
            .end_frame,
            .exec_pass,
            .define_pass,
            .end_pass_def,
            .select_from_pool,
            .set_vertex_buffer_pool,
            .set_bind_group_pool,
            .create_typed_array,
            .fill_constant,
            .fill_random,
            .fill_linear,
            .fill_element_index,
            .fill_expression,
            .write_time_uniform,
            => true,
            _ => false,
        };
    }
};

/// Buffer usage flags (matches WebGPU GPUBufferUsage).
pub const BufferUsage = packed struct(u8) {
    map_read: bool = false,
    map_write: bool = false,
    copy_src: bool = false,
    copy_dst: bool = false,
    index: bool = false,
    vertex: bool = false,
    uniform: bool = false,
    storage: bool = false,

    pub const uniform_copy_dst: BufferUsage = .{ .uniform = true, .copy_dst = true };
    pub const vertex_copy_dst: BufferUsage = .{ .vertex = true, .copy_dst = true };
    pub const storage_copy_dst: BufferUsage = .{ .storage = true, .copy_dst = true };
};

/// Load operation for render pass attachments.
pub const LoadOp = enum(u8) {
    load = 0,
    clear = 1,
};

/// Store operation for render pass attachments.
pub const StoreOp = enum(u8) {
    store = 0,
    discard = 1,
};

/// Pass type.
pub const PassType = enum(u8) {
    render = 0,
    compute = 1,
};

/// Element type for typed arrays.
pub const ElementType = enum(u8) {
    i8 = 0,
    u8 = 1,
    i16 = 2,
    u16 = 3,
    i32 = 4,
    u32 = 5,
    f32 = 6,
    f64 = 7,
};

/// WASM function argument types for call_wasm_func opcode.
pub const WasmArgType = enum(u8) {
    literal_f32 = 0x00,
    canvas_width = 0x01,
    canvas_height = 0x02,
    time_total = 0x03,
    literal_i32 = 0x04,
    literal_u32 = 0x05,
    time_delta = 0x06,

    pub fn valueByteSize(self: WasmArgType) u8 {
        return switch (self) {
            .literal_f32, .literal_i32, .literal_u32 => 4,
            .canvas_width, .canvas_height, .time_total, .time_delta => 0,
        };
    }
};

/// Return type size mapping for WASM call results.
pub const WasmReturnType = struct {
    pub fn byteSize(type_name: []const u8) ?u32 {
        const map = std.StaticStringMap(u32).initComptime(.{
            .{ "f32", 4 },
            .{ "i32", 4 },
            .{ "u32", 4 },
            .{ "vec2", 8 },
            .{ "vec3", 12 },
            .{ "vec4", 16 },
            .{ "mat3x3", 36 },
            .{ "mat4x4", 64 },
        });
        return map.get(type_name);
    }
};

/// Expression opcodes for fill_expression data generation.
/// These opcodes are used in the expression bytecode stored in the data section.
///
/// Binary format:
/// - Nullary ops (index, count, random, etc.): just the opcode byte
/// - Unary ops (sin, cos, sqrt): opcode + child expression bytes
/// - Binary ops (add, sub, mul, div): opcode + left expression + right expression
/// - Literals: opcode + 4 bytes value
pub const ExpressionOp = enum(u8) {
    // Literals (0x00-0x0F) - followed by 4-byte value
    literal_f32 = 0x00, // followed by f32 (4 bytes, little-endian)
    canvas_width = 0x01, // runtime canvas width
    canvas_height = 0x02, // runtime canvas height
    time = 0x03, // runtime time in seconds
    literal_i32 = 0x04, // followed by i32 (4 bytes)
    literal_u32 = 0x05, // followed by u32 (4 bytes)

    // Binary operators (0x10-0x1F) - left operand + right operand follow
    add = 0x10,
    sub = 0x11,
    mul = 0x12,
    div = 0x13,

    // Unary functions (0x20-0x2F) - operand follows
    sin = 0x20,
    cos = 0x21,
    sqrt = 0x22,

    // Variables (0x30-0x3F) - no additional bytes
    element_index = 0x30, // ELEMENT_ID - current element index
    element_count = 0x31, // NUM_PARTICLES - total element count
    random = 0x32, // random() - random value [0, 1)
    pi = 0x33, // PI constant

    /// Get the size of the fixed data following this opcode (not including children).
    pub fn immediateSize(self: ExpressionOp) u8 {
        return switch (self) {
            .literal_f32, .literal_i32, .literal_u32 => 4,
            else => 0,
        };
    }

    /// Get the number of child expressions this opcode expects.
    pub fn childCount(self: ExpressionOp) u8 {
        return switch (self) {
            // Binary operators
            .add, .sub, .mul, .div => 2,
            // Unary functions
            .sin, .cos, .sqrt => 1,
            // Nullary (literals and variables)
            else => 0,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "opcode validity" {
    try testing.expect(OpCode.create_buffer.isValid());
    try testing.expect(OpCode.draw.isValid());
    try testing.expect(OpCode.submit.isValid());

    const invalid: OpCode = @enumFromInt(0xFF);
    try testing.expect(!invalid.isValid());
}

test "buffer usage flags" {
    const usage = BufferUsage.uniform_copy_dst;
    try testing.expect(usage.uniform);
    try testing.expect(usage.copy_dst);
    try testing.expect(!usage.vertex);
}

test "WasmArgType value byte sizes" {
    try testing.expectEqual(@as(u8, 4), WasmArgType.literal_f32.valueByteSize());
    try testing.expectEqual(@as(u8, 0), WasmArgType.canvas_width.valueByteSize());
}
