//! cmd_validator shared types: usage flags, issue/diagnosis types, and the
//! per-command parameter structs + ParsedCommand. Split out of the original
//! single-file cmd_validator.zig; the public surface is re-exported by
//! ../cmd_validator.zig.

const std = @import("std");
const pngine = @import("pngine");
pub const Cmd = pngine.command_buffer.Cmd;
const desc = pngine.types.descriptors;

/// Maximum commands to process (safety bound).
/// Chosen to be large enough for complex scenes but bounded for safety.
pub const MAX_COMMANDS: u32 = 10000;

/// Maximum resources per type (safety bound).
/// WebGPU typically limits to 8192 bind groups, we use 1024 as practical limit.
pub const MAX_RESOURCES: u32 = 1024;

// ============================================================================
// WebGPU Buffer Usage Flags (E006 validation)
// Per WebGPU spec: https://www.w3.org/TR/webgpu/#buffer-usage
// ============================================================================

/// GPUBufferUsage flags (packed into u16 for command buffer).
pub const BufferUsage = struct {
    pub const MAP_READ: u16 = 0x01;
    pub const MAP_WRITE: u16 = 0x02;
    pub const COPY_SRC: u16 = 0x04;
    pub const COPY_DST: u16 = 0x08;
    pub const INDEX: u16 = 0x10;
    pub const VERTEX: u16 = 0x20;
    pub const UNIFORM: u16 = 0x40;
    pub const STORAGE: u16 = 0x80;
    pub const INDIRECT: u16 = 0x100;

    /// All valid usage flags combined.
    pub const ALL_VALID: u16 = MAP_READ | MAP_WRITE | COPY_SRC | COPY_DST |
        INDEX | VERTEX | UNIFORM | STORAGE | INDIRECT;

    /// Flags that MAP_READ may be combined with (only COPY_DST).
    pub const MAP_READ_ALLOWED: u16 = COPY_DST;

    /// Flags that MAP_WRITE may be combined with (only COPY_SRC).
    pub const MAP_WRITE_ALLOWED: u16 = COPY_SRC;
};

// ============================================================================
// WebGPU Texture Usage Flags (E006 validation)
// Per WebGPU spec: https://www.w3.org/TR/webgpu/`(texture …)`-usage
// ============================================================================

/// GPUTextureUsage flags.
pub const TextureUsage = struct {
    pub const COPY_SRC: u8 = 0x01;
    pub const COPY_DST: u8 = 0x02;
    pub const TEXTURE_BINDING: u8 = 0x04;
    pub const STORAGE_BINDING: u8 = 0x08;
    pub const RENDER_ATTACHMENT: u8 = 0x10;

    /// All valid usage flags combined.
    pub const ALL_VALID: u8 = COPY_SRC | COPY_DST | TEXTURE_BINDING |
        STORAGE_BINDING | RENDER_ATTACHMENT;
};

// ============================================================================
// Special Resource IDs
// ============================================================================

/// Special ID for canvas/surface texture (contextCurrentTexture).
/// Uses 0xFFFE to distinguish from 0xFFFF (no depth texture).
/// Canvas textures have usage=0 which is valid (browser manages them).
pub const CANVAS_TEXTURE_ID: u16 = 0xFFFE;

/// Special ID for "no depth texture" in render passes.
pub const NO_DEPTH_TEXTURE_ID: u16 = 0xFFFF;

// Compile-time validation of constants
comptime {
    // MAX_COMMANDS must fit in command_index field
    std.debug.assert(MAX_COMMANDS <= std.math.maxInt(u32));
    // MAX_RESOURCES must fit in resource ID type
    std.debug.assert(MAX_RESOURCES <= std.math.maxInt(u16));
    // Buffer usage flags must not have overlapping invalid bits
    std.debug.assert(BufferUsage.ALL_VALID == 0x1FF);
    // Texture usage flags must fit in 5 bits
    std.debug.assert(TextureUsage.ALL_VALID == 0x1F);
}

/// Severity of validation issue.
pub const Severity = enum {
    err,
    warning,
};

/// Validation issue with code, message, and context.
pub const Issue = struct {
    code: []const u8,
    severity: Severity,
    message: []const u8,
    command_index: u32,
    resource_id: ?u16 = null,
};

/// Current pass state.
pub const PassState = enum {
    none,
    render,
    compute,
};

// ============================================================================
// Symptom-Based Diagnosis (Feature 2)
// ============================================================================

/// Supported symptoms for diagnosis.
/// Maps to visual issues users commonly report.
pub const Symptom = enum {
    /// Canvas is completely black - no output visible.
    black_screen,
    /// Wrong or unexpected colors in output.
    wrong_colors,
    /// Transparency or blending not working as expected.
    blend_issues,
    /// Nothing renders, output is fully transparent.
    transparent_output,
    /// Flickering or strobing effects.
    flickering,
    /// Geometry is wrong, distorted, or missing.
    geometry_issues,

    /// Parse symptom from string (for CLI).
    pub fn fromString(s: []const u8) ?Symptom {
        const map = std.StaticStringMap(Symptom).initComptime(.{
            .{ "black", .black_screen },
            .{ "black_screen", .black_screen },
            .{ "colors", .wrong_colors },
            .{ "wrong_colors", .wrong_colors },
            .{ "blend", .blend_issues },
            .{ "blend_issues", .blend_issues },
            .{ "transparent", .transparent_output },
            .{ "transparent_output", .transparent_output },
            .{ "flicker", .flickering },
            .{ "flickering", .flickering },
            .{ "geometry", .geometry_issues },
            .{ "geometry_issues", .geometry_issues },
        });
        return map.get(s);
    }
};

/// Result of a single diagnostic check.
pub const DiagnosticCheck = struct {
    name: []const u8,
    passed: bool,
    severity: Severity,
    message: []const u8,
    value: ?CheckValue = null,

    /// Optional value for the check (for JSON output).
    pub const CheckValue = union(enum) {
        boolean: bool,
        integer: i64,
        float: f64,
        string: []const u8,
    };
};

/// Full diagnosis result for a symptom.
pub const Diagnosis = struct {
    symptom: Symptom,
    checks: []const DiagnosticCheck,
    likely_cause: ?[]const u8 = null,
    probability: u8 = 0, // 0-100
};

/// Buffer resource info.
pub const BufferInfo = struct {
    size: u32,
    usage: u16,
    created_at: u32,
};

/// Texture resource info - parsed from binary descriptor.
/// Stores properties for E006 validation and texture operation checks.
pub const TextureInfo = struct {
    width: u32 = 1,
    height: u32 = 1,
    depth: u32 = 1,
    format: u8 = 0, // TextureFormat.rgba8unorm
    usage: u8 = 0,
    sample_count: u8 = 1,
    mip_level_count: u8 = 1,
    dimension: TextureDimension = .@"2d",
    created_at: u32,

    /// Texture dimension enum matching WebGPU.
    pub const TextureDimension = enum(u8) {
        @"1d" = 0,
        @"2d" = 1,
        @"3d" = 2,
    };
};

/// Generic resource info (for samplers, etc).
pub const ResourceInfo = struct {
    created_at: u32,
};

// ============================================================================
// Descriptor Parsing Types (from shared types module)
// ============================================================================

/// Descriptor type tags - imported from src/types/descriptors.zig
pub const DescriptorType = desc.DescriptorType;

/// Texture field IDs - imported from src/types/descriptors.zig
pub const TextureField = desc.TextureField;

/// Value type tags for TLV encoding - imported from src/types/descriptors.zig
pub const ValueType = desc.ValueType;

/// Pipeline info.
pub const PipelineInfo = struct {
    is_render: bool,
    created_at: u32,
};

/// Parameter types for parsed commands.
pub const CreateBufferParams = struct { id: u16, size: u32, usage: u16 };
pub const CreateResourceParams = struct { id: u16, desc_ptr: u32, desc_len: u32 };
pub const CreateShaderParams = struct { id: u16, code_ptr: u32, code_len: u32 };
pub const CreateBindGroupParams = struct { id: u16, layout_id: u16, entries_ptr: u32, entries_len: u32 };
pub const CreateTextureViewParams = struct { id: u16, texture_id: u16, desc_ptr: u32, desc_len: u32 };
pub const BeginRenderPassParams = struct { color_id: u16, load_op: u8, store_op: u8, depth_id: u16, clear_r: u8 = 0, clear_g: u8 = 0, clear_b: u8 = 0, clear_a: u8 = 0 };
pub const SetPipelineParams = struct { id: u16 };
pub const SetBindGroupParams = struct { slot: u8, id: u16 };
pub const SetVertexBufferParams = struct { slot: u8, id: u16 };
pub const SetIndexBufferParams = struct { id: u16, format: u8 };
pub const DrawParams = struct { vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32 };
pub const DrawIndexedParams = struct { index_count: u32, instance_count: u32, first_index: u32, base_vertex: u32, first_instance: u32 };
pub const DispatchParams = struct { x: u32, y: u32, z: u32 };
/// DRAW_INDIRECT / DRAW_INDEXED_INDIRECT / DISPATCH_INDIRECT all carry the same
/// pair: the buffer holding the argument struct, and a byte offset into it.
pub const IndirectParams = struct { id: u16, offset: u32 };
pub const WriteBufferParams = struct { id: u16, offset: u32, data_ptr: u32, data_len: u32 };
pub const WriteTimeUniformParams = struct { id: u16, offset: u32, size: u16 };
pub const CopyBufferParams = struct { src_id: u16, src_offset: u32, dst_id: u16, dst_offset: u32, size: u32 };
pub const CopyTextureParams = struct { src_id: u16, dst_id: u16, width: u16, height: u16 };
pub const CopyExternalImageParams = struct { bitmap_id: u16, texture_id: u16, mip_level: u8, origin_x: u16, origin_y: u16, origin_z: u16 };
pub const InitWasmModuleParams = struct { module_id: u16, data_ptr: u32, data_len: u32 };
/// CALL_WASM_FUNC carries its arguments *inline* (see `CommandBuffer.callWasmFunc`),
/// so `args_len` is a byte count of the bytes that follow — not the length half of
/// a pointer/length pair. There is no `args_ptr` to bounds-check.
pub const CallWasmFuncParams = struct { call_id: u16, module_id: u16, func_ptr: u32, func_len: u32, args_len: u8 };
pub const WriteBufferFromWasmParams = struct { buffer_id: u16, buffer_offset: u32, wasm_ptr: u32, size: u32 };
/// Parsed command with extracted parameters.
pub const ParsedCommand = struct {
    index: u32,
    cmd: Cmd,
    params: Params,

    pub const Params = union {
        none: void,
        create_buffer: CreateBufferParams,
        create_resource: CreateResourceParams,
        create_shader: CreateShaderParams,
        create_bind_group: CreateBindGroupParams,
        create_texture_view: CreateTextureViewParams,
        begin_render_pass: BeginRenderPassParams,
        set_pipeline: SetPipelineParams,
        set_bind_group: SetBindGroupParams,
        set_vertex_buffer: SetVertexBufferParams,
        set_index_buffer: SetIndexBufferParams,
        draw: DrawParams,
        draw_indexed: DrawIndexedParams,
        dispatch: DispatchParams,
        indirect: IndirectParams,
        write_buffer: WriteBufferParams,
        write_time_uniform: WriteTimeUniformParams,
        write_pointer_uniform: WriteTimeUniformParams,
        copy_buffer: CopyBufferParams,
        copy_texture: CopyTextureParams,
        copy_external_image: CopyExternalImageParams,
        init_wasm_module: InitWasmModuleParams,
        call_wasm_func: CallWasmFuncParams,
        write_buffer_from_wasm: WriteBufferFromWasmParams,
    };
};

// ============================================================================
// JSON Serialization Helpers
// ============================================================================

/// Write a JSON-escaped string to a writer.
/// Escapes: \ " newline tab carriage-return and control characters.
///
/// Complexity: O(n) where n = input.len
pub fn writeJsonEscaped(writer: anytype, input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\t' => try writer.writeAll("\\t"),
            '\r' => try writer.writeAll("\\r"),
            // Other control characters (excluding \n=0x0a, \t=0x09, \r=0x0d)
            0x00...0x08, 0x0b...0x0c, 0x0e...0x1f => {
                // Control characters as \uXXXX
                try writer.print("\\u{X:0>4}", .{c});
            },
            else => try writer.writeByte(c),
        }
    }
}
