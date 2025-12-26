//! Command Buffer Validator - State Machine and Resource Tracking
//!
//! Validates GPU command buffer correctness by tracking resource lifetimes and
//! pass state transitions. Enables LLM-friendly diagnostics without a browser.
//!
//! ## Design
//!
//! The validator is a state machine with three states: none, render, compute.
//! Resources are tracked in hash maps keyed by their 16-bit IDs.
//!
//! ## Error Codes
//!
//! - E001: missing_resource - Reference to non-existent resource
//! - E002: state_violation - Command in wrong state (draw outside pass)
//! - E004: memory_bounds - Pointer + length exceeds WASM memory bounds
//! - E005: duplicate_id - Resource ID already in use
//! - E006: invalid_descriptor - Invalid resource descriptor (bad usage flags, format, etc)
//! - E007: pass_mismatch - END_PASS without matching BEGIN
//! - E008: nested_pass - BEGIN_PASS inside active pass
//!
//! ## Warning Codes
//!
//! - W003: zero_count - Draw/dispatch with zero work (nothing will render)
//! - W004: null_pointer - Null pointer with non-zero length (suspicious)
//! - W006: suspicious_descriptor - Suspicious but valid descriptor (unusual combinations)
//!
//! ## Invariants
//!
//! - All loops bounded by MAX_COMMANDS (10000)
//! - No recursion in validation logic
//! - Errors collected in issues list, never thrown
//! - Resource maps never exceed MAX_RESOURCES (1024)

const std = @import("std");
const pngine = @import("pngine");
const Cmd = pngine.command_buffer.Cmd;

/// Maximum commands to process (safety bound).
/// Chosen to be large enough for complex scenes but bounded for safety.
const MAX_COMMANDS: u32 = 10000;

/// Maximum resources per type (safety bound).
/// WebGPU typically limits to 8192 bind groups, we use 1024 as practical limit.
const MAX_RESOURCES: u32 = 1024;

// ============================================================================
// WebGPU Buffer Usage Flags (E006 validation)
// Per WebGPU spec: https://www.w3.org/TR/webgpu/#buffer-usage
// ============================================================================

/// GPUBufferUsage flags (packed into u8 for command buffer efficiency).
/// Note: INDIRECT (0x100) and QUERY_RESOLVE (0x200) exceed u8, not supported.
pub const BufferUsage = struct {
    pub const MAP_READ: u8 = 0x01;
    pub const MAP_WRITE: u8 = 0x02;
    pub const COPY_SRC: u8 = 0x04;
    pub const COPY_DST: u8 = 0x08;
    pub const INDEX: u8 = 0x10;
    pub const VERTEX: u8 = 0x20;
    pub const UNIFORM: u8 = 0x40;
    pub const STORAGE: u8 = 0x80;

    /// All valid usage flags combined.
    pub const ALL_VALID: u8 = MAP_READ | MAP_WRITE | COPY_SRC | COPY_DST |
        INDEX | VERTEX | UNIFORM | STORAGE;

    /// Flags that MAP_READ may be combined with (only COPY_DST).
    pub const MAP_READ_ALLOWED: u8 = COPY_DST;

    /// Flags that MAP_WRITE may be combined with (only COPY_SRC).
    pub const MAP_WRITE_ALLOWED: u8 = COPY_SRC;
};

// ============================================================================
// WebGPU Texture Usage Flags (E006 validation)
// Per WebGPU spec: https://www.w3.org/TR/webgpu/#texture-usage
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

// Compile-time validation of constants
comptime {
    // MAX_COMMANDS must fit in command_index field
    std.debug.assert(MAX_COMMANDS <= std.math.maxInt(u32));
    // MAX_RESOURCES must fit in resource ID type
    std.debug.assert(MAX_RESOURCES <= std.math.maxInt(u16));
    // Buffer usage flags must not have overlapping invalid bits
    std.debug.assert(BufferUsage.ALL_VALID == 0xFF);
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
const PassState = enum {
    none,
    render,
    compute,
};

/// Buffer resource info.
const BufferInfo = struct {
    size: u32,
    usage: u8,
    created_at: u32,
};

/// Generic resource info (for textures, samplers, etc).
const ResourceInfo = struct {
    created_at: u32,
};

/// Pipeline info.
const PipelineInfo = struct {
    is_render: bool,
    created_at: u32,
};

/// Parameter types for parsed commands.
pub const CreateBufferParams = struct { id: u16, size: u32, usage: u8 };
pub const CreateResourceParams = struct { id: u16, desc_ptr: u32, desc_len: u32 };
pub const CreateShaderParams = struct { id: u16, code_ptr: u32, code_len: u32 };
pub const CreateBindGroupParams = struct { id: u16, layout_id: u16, entries_ptr: u32, entries_len: u32 };
pub const CreateTextureViewParams = struct { id: u16, texture_id: u16, desc_ptr: u32, desc_len: u32 };
pub const BeginRenderPassParams = struct { color_id: u16, load_op: u8, store_op: u8, depth_id: u16 };
pub const SetPipelineParams = struct { id: u16 };
pub const SetBindGroupParams = struct { slot: u8, id: u16 };
pub const SetVertexBufferParams = struct { slot: u8, id: u16 };
pub const SetIndexBufferParams = struct { id: u16, format: u8 };
pub const DrawParams = struct { vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32 };
pub const DrawIndexedParams = struct { index_count: u32, instance_count: u32, first_index: u32, base_vertex: u32, first_instance: u32 };
pub const DispatchParams = struct { x: u32, y: u32, z: u32 };
pub const WriteBufferParams = struct { id: u16, offset: u32, data_ptr: u32, data_len: u32 };
pub const WriteTimeUniformParams = struct { id: u16, offset: u32, size: u16 };
pub const CopyBufferParams = struct { src_id: u16, src_offset: u32, dst_id: u16, dst_offset: u32, size: u32 };
pub const CopyTextureParams = struct { src_id: u16, dst_id: u16, width: u16, height: u16 };
pub const CopyExternalImageParams = struct { bitmap_id: u16, texture_id: u16, mip_level: u8, origin_x: u16, origin_y: u16 };
pub const InitWasmModuleParams = struct { module_id: u16, data_ptr: u32, data_len: u32 };
pub const CallWasmFuncParams = struct { call_id: u16, module_id: u16, func_ptr: u32, func_len: u32, args_ptr: u32, args_len: u32 };
pub const WriteBufferFromWasmParams = struct { buffer_id: u16, buffer_offset: u32, wasm_ptr: u32, size: u32 };
pub const CreateTypedArrayParams = struct { id: u16, array_type: u8, size: u32 };
pub const FillArrayParams = struct { array_id: u16, offset: u32, count: u32, stride: u8, data_ptr: u32 };
pub const FillExpressionParams = struct { array_id: u16, offset: u32, count: u32, stride: u8, expr_ptr: u32, expr_len: u16 };
pub const WriteBufferFromArrayParams = struct { buffer_id: u16, buffer_offset: u32, array_id: u16 };

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
        write_buffer: WriteBufferParams,
        write_time_uniform: WriteTimeUniformParams,
        copy_buffer: CopyBufferParams,
        copy_texture: CopyTextureParams,
        copy_external_image: CopyExternalImageParams,
        init_wasm_module: InitWasmModuleParams,
        call_wasm_func: CallWasmFuncParams,
        write_buffer_from_wasm: WriteBufferFromWasmParams,
        create_typed_array: CreateTypedArrayParams,
        fill_array: FillArrayParams,
        fill_expression: FillExpressionParams,
        write_buffer_from_array: WriteBufferFromArrayParams,
    };
};

/// Validation state machine for GPU command buffers.
///
/// Tracks resource creation, pass state, and pipeline bindings to detect
/// common errors like duplicate IDs, draw outside pass, and missing resources.
///
/// ## Usage
///
/// ```zig
/// var validator = Validator.init(allocator);
/// defer validator.deinit();
/// try validator.validate(commands);
/// if (validator.hasErrors()) {
///     // Handle validation failures
/// }
/// ```
///
/// ## Invariants
///
/// - `pass_state` transitions: none → render/compute → none
/// - `current_pipeline` is null when `pass_state` is none
/// - Resource maps grow monotonically (resources never removed)
pub const Validator = struct {
    // ========================================================================
    // Fields (ordered by cache access pattern)
    // ========================================================================

    /// Allocator for dynamic data structures.
    allocator: std.mem.Allocator,

    /// Current pass state (none, render, or compute).
    ///
    /// Invariants:
    /// - Only one pass can be active at a time.
    /// - Must return to `.none` before starting a new pass.
    pass_state: PassState,

    /// Currently bound pipeline ID, or null if none set.
    ///
    /// Invariants:
    /// - Reset to null on pass begin/end.
    /// - Must be set before draw/dispatch commands.
    current_pipeline: ?u16,

    /// True if current_pipeline is a render pipeline.
    pipeline_is_render: bool,

    /// Current command index for error reporting.
    command_index: u32,

    /// Draw call count for statistics.
    draw_count: u32,

    /// Dispatch call count for statistics.
    dispatch_count: u32,

    /// WASM linear memory size in bytes (for bounds checking).
    /// When set, enables E004 memory bounds validation.
    /// When null, bounds checking is skipped.
    wasm_memory_size: ?u32,

    /// Per-pass bound vertex buffers (8 slots max).
    bound_vertex_buffers: [8]?u16,

    /// Per-pass bound bind groups (4 slots max).
    bound_bind_groups: [4]?u16,

    /// Resource tracking maps - keyed by resource ID.
    buffers: std.AutoHashMapUnmanaged(u16, BufferInfo),
    textures: std.AutoHashMapUnmanaged(u16, ResourceInfo),
    samplers: std.AutoHashMapUnmanaged(u16, ResourceInfo),
    shaders: std.AutoHashMapUnmanaged(u16, ResourceInfo),
    render_pipelines: std.AutoHashMapUnmanaged(u16, PipelineInfo),
    compute_pipelines: std.AutoHashMapUnmanaged(u16, PipelineInfo),
    bind_groups: std.AutoHashMapUnmanaged(u16, ResourceInfo),
    texture_views: std.AutoHashMapUnmanaged(u16, ResourceInfo),
    image_bitmaps: std.AutoHashMapUnmanaged(u16, ResourceInfo),
    typed_arrays: std.AutoHashMapUnmanaged(u16, ResourceInfo),
    wasm_modules: std.AutoHashMapUnmanaged(u16, ResourceInfo),

    /// Collected validation issues (errors and warnings).
    issues: std.ArrayListUnmanaged(Issue),

    // ========================================================================
    // Types
    // ========================================================================

    const Self = @This();

    // ========================================================================
    // Methods
    // ========================================================================

    /// Initialize a new validator with empty state.
    ///
    /// Complexity: O(1)
    ///
    /// Pre-condition: allocator is valid.
    /// Post-condition: All maps empty, pass_state is none.
    pub fn init(allocator: std.mem.Allocator) Self {
        const self = Self{
            .allocator = allocator,
            .pass_state = .none,
            .current_pipeline = null,
            .pipeline_is_render = false,
            .command_index = 0,
            .draw_count = 0,
            .dispatch_count = 0,
            .wasm_memory_size = null,
            .bound_vertex_buffers = .{null} ** 8,
            .bound_bind_groups = .{null} ** 4,
            .buffers = .{},
            .textures = .{},
            .samplers = .{},
            .shaders = .{},
            .render_pipelines = .{},
            .compute_pipelines = .{},
            .bind_groups = .{},
            .texture_views = .{},
            .image_bitmaps = .{},
            .typed_arrays = .{},
            .wasm_modules = .{},
            .issues = .{},
        };

        // Post-conditions: verify initial state
        std.debug.assert(self.pass_state == .none);
        std.debug.assert(self.current_pipeline == null);

        return self;
    }

    /// Free all allocated resources.
    ///
    /// Complexity: O(n) where n = total resources tracked.
    ///
    /// Pre-condition: self was initialized.
    /// Post-condition: All memory freed, self is undefined.
    pub fn deinit(self: *Self) void {
        // Pre-condition: allocator must be valid (implicit via init)
        std.debug.assert(self.issues.items.len <= MAX_COMMANDS);

        self.buffers.deinit(self.allocator);
        self.textures.deinit(self.allocator);
        self.samplers.deinit(self.allocator);
        self.shaders.deinit(self.allocator);
        self.render_pipelines.deinit(self.allocator);
        self.compute_pipelines.deinit(self.allocator);
        self.bind_groups.deinit(self.allocator);
        self.texture_views.deinit(self.allocator);
        self.image_bitmaps.deinit(self.allocator);
        self.typed_arrays.deinit(self.allocator);
        self.wasm_modules.deinit(self.allocator);
        self.issues.deinit(self.allocator);

        // Post-condition: mark as undefined to catch use-after-free
        self.* = undefined;
    }

    /// Set WASM memory size for bounds checking.
    ///
    /// When set, enables E004 memory bounds validation for all commands
    /// that reference WASM memory via pointer + length.
    ///
    /// Pre-condition: size > 0
    /// Post-condition: wasm_memory_size is set, bounds checking enabled
    pub fn setWasmMemorySize(self: *Self, size: u32) void {
        std.debug.assert(size > 0);
        self.wasm_memory_size = size;
    }

    /// Validate that ptr + len is within WASM memory bounds.
    ///
    /// Checks:
    /// 1. ptr + len doesn't overflow u32
    /// 2. If wasm_memory_size is set, ptr + len <= wasm_memory_size
    /// 3. Warns if ptr == 0 but len > 0 (null pointer with data)
    ///
    /// Returns true if bounds are valid, false if error was added.
    fn validateMemoryBounds(self: *Self, ptr: u32, len: u32, context: []const u8) !bool {
        // Pre-condition: context describes the command
        std.debug.assert(context.len > 0);

        // Check for null pointer with non-zero length (suspicious)
        if (ptr == 0 and len > 0) {
            try self.addWarning("W004", context);
        }

        // Check for u32 overflow: ptr + len must not wrap
        const end_addr = @addWithOverflow(ptr, len);
        if (end_addr[1] != 0) {
            try self.addError("E004", context);
            return false;
        }

        // Check against WASM memory size if set
        if (self.wasm_memory_size) |mem_size| {
            if (end_addr[0] > mem_size) {
                try self.addError("E004", context);
                return false;
            }
        }

        return true;
    }

    /// Validate a sequence of parsed commands.
    ///
    /// Complexity: O(n) where n = commands.len
    ///
    /// Pre-condition: commands.len <= MAX_COMMANDS
    /// Post-condition: issues contains all validation errors/warnings
    pub fn validate(self: *Self, commands: []const ParsedCommand) !void {
        // Pre-conditions
        std.debug.assert(commands.len <= MAX_COMMANDS);
        std.debug.assert(self.pass_state == .none); // Start in clean state

        const initial_issue_count = self.issues.items.len;

        for (commands) |cmd| {
            self.command_index = cmd.index;
            try self.validateCommand(cmd);
        }

        // Check for unclosed pass at end of command stream
        if (self.pass_state != .none) {
            try self.addError("E007", "Render/compute pass not ended - missing END_PASS");
        }

        // Post-condition: issues can only grow, never shrink
        std.debug.assert(self.issues.items.len >= initial_issue_count);
    }

    /// Validate a single command.
    fn validateCommand(self: *Self, cmd: ParsedCommand) !void {
        switch (cmd.cmd) {
            // Resource creation
            .create_buffer => try self.validateCreateBuffer(cmd.params.create_buffer),
            .create_texture => try self.validateCreateTexture(cmd.params.create_resource),
            .create_sampler => try self.validateCreateSampler(cmd.params.create_resource),
            .create_shader => try self.validateCreateShader(cmd.params.create_shader),
            .create_render_pipeline => try self.validateCreateRenderPipeline(cmd.params.create_resource),
            .create_compute_pipeline => try self.validateCreateComputePipeline(cmd.params.create_resource),
            .create_bind_group => try self.validateCreateBindGroup(cmd.params.create_bind_group),
            .create_texture_view => try self.validateCreateTextureView(cmd.params.create_texture_view),
            .create_image_bitmap => try self.validateCreateImageBitmap(cmd.params.create_resource),
            .create_bind_group_layout, .create_pipeline_layout, .create_query_set, .create_render_bundle => {
                // These don't need tracking for basic validation
            },

            // Pass operations
            .begin_render_pass => try self.validateBeginRenderPass(cmd.params.begin_render_pass),
            .begin_compute_pass => try self.validateBeginComputePass(),
            .end_pass => try self.validateEndPass(),
            .set_pipeline => try self.validateSetPipeline(cmd.params.set_pipeline),
            .set_bind_group => try self.validateSetBindGroup(cmd.params.set_bind_group),
            .set_vertex_buffer => try self.validateSetVertexBuffer(cmd.params.set_vertex_buffer),
            .set_index_buffer => try self.validateSetIndexBuffer(cmd.params.set_index_buffer),
            .draw => try self.validateDraw(cmd.params.draw),
            .draw_indexed => try self.validateDrawIndexed(cmd.params.draw_indexed),
            .dispatch => try self.validateDispatch(cmd.params.dispatch),
            .execute_bundles => {}, // TODO: validate bundle IDs

            // Queue operations
            .write_buffer => try self.validateWriteBuffer(cmd.params.write_buffer),
            .write_time_uniform => try self.validateWriteTimeUniform(cmd.params.write_time_uniform),
            .copy_buffer_to_buffer => try self.validateCopyBuffer(cmd.params.copy_buffer),
            .copy_texture_to_texture => try self.validateCopyTexture(cmd.params.copy_texture),
            .write_buffer_from_wasm => try self.validateWriteBufferFromWasm(cmd.params.write_buffer_from_wasm),
            .copy_external_image_to_texture => try self.validateCopyExternalImage(cmd.params.copy_external_image),

            // WASM operations
            .init_wasm_module => try self.validateInitWasmModule(cmd.params.init_wasm_module),
            .call_wasm_func => try self.validateCallWasmFunc(cmd.params.call_wasm_func),

            // Typed array operations
            .create_typed_array => try self.validateCreateTypedArray(cmd.params.create_typed_array),
            .fill_random, .fill_constant => try self.validateFillArray(cmd.params.fill_array),
            .fill_expression => try self.validateFillExpression(cmd.params.fill_expression),
            .write_buffer_from_array => try self.validateWriteBufferFromArray(cmd.params.write_buffer_from_array),

            // Control
            .submit => self.resetFrameState(),
            .end => {},
        }
    }

    // ========================================================================
    // Resource Creation Validators
    // ========================================================================

    fn validateCreateBuffer(self: *Self, params: CreateBufferParams) !void {
        // Pre-condition: params is valid struct
        std.debug.assert(params.id <= std.math.maxInt(u16));

        if (self.buffers.contains(params.id)) {
            try self.addErrorWithId("E005", "Buffer ID already in use", params.id);
            return;
        }

        // E006: Buffer size must be > 0
        if (params.size == 0) {
            try self.addErrorWithId("E006", "Buffer size must be > 0", params.id);
        }

        // E006: Buffer usage must not be 0 (must have at least one usage flag)
        if (params.usage == 0) {
            try self.addErrorWithId("E006", "Buffer usage must not be 0", params.id);
        } else {
            // E006: MAP_READ may only be combined with COPY_DST
            // Per WebGPU spec: "If the MAP_READ bit is set, only the COPY_DST bit may be set"
            if ((params.usage & BufferUsage.MAP_READ) != 0) {
                const other_flags = params.usage & ~BufferUsage.MAP_READ;
                if (other_flags != 0 and other_flags != BufferUsage.COPY_DST) {
                    try self.addErrorWithId(
                        "E006",
                        "MAP_READ may only be combined with COPY_DST",
                        params.id,
                    );
                }
            }

            // E006: MAP_WRITE may only be combined with COPY_SRC
            // Per WebGPU spec: "If the MAP_WRITE bit is set, only the COPY_SRC bit may be set"
            if ((params.usage & BufferUsage.MAP_WRITE) != 0) {
                const other_flags = params.usage & ~BufferUsage.MAP_WRITE;
                if (other_flags != 0 and other_flags != BufferUsage.COPY_SRC) {
                    try self.addErrorWithId(
                        "E006",
                        "MAP_WRITE may only be combined with COPY_SRC",
                        params.id,
                    );
                }
            }

            // E006: MAP_READ and MAP_WRITE cannot both be set
            // Per WebGPU spec: These are mutually exclusive mapping modes
            if ((params.usage & BufferUsage.MAP_READ) != 0 and
                (params.usage & BufferUsage.MAP_WRITE) != 0)
            {
                try self.addErrorWithId(
                    "E006",
                    "MAP_READ and MAP_WRITE cannot both be set",
                    params.id,
                );
            }
        }

        // Post-condition: buffer is tracked
        try self.buffers.put(self.allocator, params.id, .{
            .size = params.size,
            .usage = params.usage,
            .created_at = self.command_index,
        });
    }

    fn validateCreateTexture(self: *Self, params: CreateResourceParams) !void {
        if (self.textures.contains(params.id)) {
            try self.addErrorWithId("E005", "Texture ID already in use", params.id);
            return;
        }
        try self.textures.put(self.allocator, params.id, .{ .created_at = self.command_index });
    }

    fn validateCreateSampler(self: *Self, params: CreateResourceParams) !void {
        if (self.samplers.contains(params.id)) {
            try self.addErrorWithId("E005", "Sampler ID already in use", params.id);
            return;
        }
        try self.samplers.put(self.allocator, params.id, .{ .created_at = self.command_index });
    }

    fn validateCreateShader(self: *Self, params: CreateShaderParams) !void {
        if (self.shaders.contains(params.id)) {
            try self.addErrorWithId("E005", "Shader ID already in use", params.id);
            return;
        }

        // E004: Validate shader code pointer bounds
        _ = try self.validateMemoryBounds(
            params.code_ptr,
            params.code_len,
            "CREATE_SHADER code_ptr + code_len exceeds WASM memory",
        );

        try self.shaders.put(self.allocator, params.id, .{ .created_at = self.command_index });
    }

    fn validateCreateRenderPipeline(self: *Self, params: CreateResourceParams) !void {
        if (self.render_pipelines.contains(params.id)) {
            try self.addErrorWithId("E005", "Render pipeline ID already in use", params.id);
            return;
        }
        try self.render_pipelines.put(self.allocator, params.id, .{
            .is_render = true,
            .created_at = self.command_index,
        });
    }

    fn validateCreateComputePipeline(self: *Self, params: CreateResourceParams) !void {
        if (self.compute_pipelines.contains(params.id)) {
            try self.addErrorWithId("E005", "Compute pipeline ID already in use", params.id);
            return;
        }
        try self.compute_pipelines.put(self.allocator, params.id, .{
            .is_render = false,
            .created_at = self.command_index,
        });
    }

    fn validateCreateBindGroup(self: *Self, params: CreateBindGroupParams) !void {
        if (self.bind_groups.contains(params.id)) {
            try self.addErrorWithId("E005", "Bind group ID already in use", params.id);
            return;
        }

        // E004: Validate entries pointer bounds
        _ = try self.validateMemoryBounds(
            params.entries_ptr,
            params.entries_len,
            "CREATE_BIND_GROUP entries_ptr + entries_len exceeds WASM memory",
        );

        try self.bind_groups.put(self.allocator, params.id, .{ .created_at = self.command_index });
    }

    fn validateCreateTextureView(self: *Self, params: CreateTextureViewParams) !void {
        if (self.texture_views.contains(params.id)) {
            try self.addErrorWithId("E005", "Texture view ID already in use", params.id);
            return;
        }
        // Check that texture exists (unless it's the special canvas texture ID 0xFFFF)
        if (params.texture_id != 0xFFFF and !self.textures.contains(params.texture_id)) {
            try self.addErrorWithId("E001", "Texture view references non-existent texture", params.texture_id);
        }
        try self.texture_views.put(self.allocator, params.id, .{ .created_at = self.command_index });
    }

    fn validateCreateImageBitmap(self: *Self, params: CreateResourceParams) !void {
        if (self.image_bitmaps.contains(params.id)) {
            try self.addErrorWithId("E005", "Image bitmap ID already in use", params.id);
            return;
        }
        try self.image_bitmaps.put(self.allocator, params.id, .{ .created_at = self.command_index });
    }

    fn validateCreateTypedArray(self: *Self, params: CreateTypedArrayParams) !void {
        if (self.typed_arrays.contains(params.id)) {
            try self.addErrorWithId("E005", "Typed array ID already in use", params.id);
            return;
        }
        try self.typed_arrays.put(self.allocator, params.id, .{ .created_at = self.command_index });
    }

    fn validateInitWasmModule(self: *Self, params: InitWasmModuleParams) !void {
        if (self.wasm_modules.contains(params.module_id)) {
            try self.addErrorWithId("E005", "WASM module ID already in use", params.module_id);
            return;
        }

        // E004: Validate WASM module data pointer bounds
        _ = try self.validateMemoryBounds(
            params.data_ptr,
            params.data_len,
            "INIT_WASM_MODULE data_ptr + data_len exceeds WASM memory",
        );

        try self.wasm_modules.put(self.allocator, params.module_id, .{ .created_at = self.command_index });
    }

    // ========================================================================
    // Pass State Validators
    // ========================================================================

    fn validateBeginRenderPass(self: *Self, params: BeginRenderPassParams) !void {
        _ = params;
        if (self.pass_state != .none) {
            try self.addError("E008", "BEGIN_RENDER_PASS inside active pass - nested passes not allowed");
            return;
        }
        self.pass_state = .render;
        self.current_pipeline = null;
        self.resetPassState();
    }

    fn validateBeginComputePass(self: *Self) !void {
        if (self.pass_state != .none) {
            try self.addError("E008", "BEGIN_COMPUTE_PASS inside active pass - nested passes not allowed");
            return;
        }
        self.pass_state = .compute;
        self.current_pipeline = null;
        self.resetPassState();
    }

    fn validateEndPass(self: *Self) !void {
        if (self.pass_state == .none) {
            try self.addError("E007", "END_PASS without matching BEGIN_RENDER_PASS or BEGIN_COMPUTE_PASS");
            return;
        }
        self.pass_state = .none;
        self.current_pipeline = null;
        self.resetPassState();
    }

    fn validateSetPipeline(self: *Self, params: SetPipelineParams) !void {
        // Check pipeline exists (render or compute)
        const is_render = self.render_pipelines.contains(params.id);
        const is_compute = self.compute_pipelines.contains(params.id);

        if (!is_render and !is_compute) {
            try self.addErrorWithId("E001", "SET_PIPELINE references non-existent pipeline", params.id);
            return;
        }

        // Check pipeline type matches pass type
        if (self.pass_state == .render and is_compute) {
            try self.addError("E002", "SET_PIPELINE: compute pipeline in render pass");
        } else if (self.pass_state == .compute and is_render) {
            try self.addError("E002", "SET_PIPELINE: render pipeline in compute pass");
        }

        self.current_pipeline = params.id;
        self.pipeline_is_render = is_render;
    }

    fn validateSetBindGroup(self: *Self, params: SetBindGroupParams) !void {
        if (!self.bind_groups.contains(params.id)) {
            try self.addErrorWithId("E001", "SET_BIND_GROUP references non-existent bind group", params.id);
            return;
        }
        if (params.slot < 4) {
            self.bound_bind_groups[params.slot] = params.id;
        }
    }

    fn validateSetVertexBuffer(self: *Self, params: SetVertexBufferParams) !void {
        const buffer_info = self.buffers.get(params.id);
        if (buffer_info == null) {
            try self.addErrorWithId("E001", "SET_VERTEX_BUFFER references non-existent buffer", params.id);
            return;
        }

        // E006: Buffer must have VERTEX usage flag
        if ((buffer_info.?.usage & BufferUsage.VERTEX) == 0) {
            try self.addErrorWithId(
                "E006",
                "SET_VERTEX_BUFFER buffer missing VERTEX usage flag",
                params.id,
            );
        }

        if (params.slot < 8) {
            self.bound_vertex_buffers[params.slot] = params.id;
        }
    }

    fn validateSetIndexBuffer(self: *Self, params: SetIndexBufferParams) !void {
        const buffer_info = self.buffers.get(params.id);
        if (buffer_info == null) {
            try self.addErrorWithId("E001", "SET_INDEX_BUFFER references non-existent buffer", params.id);
            return;
        }

        // E006: Buffer must have INDEX usage flag
        if ((buffer_info.?.usage & BufferUsage.INDEX) == 0) {
            try self.addErrorWithId(
                "E006",
                "SET_INDEX_BUFFER buffer missing INDEX usage flag",
                params.id,
            );
        }
    }

    fn validateDraw(self: *Self, params: DrawParams) !void {
        if (self.pass_state != .render) {
            try self.addError("E002", "DRAW outside render pass");
            return;
        }
        if (self.current_pipeline == null) {
            try self.addError("E002", "DRAW without SET_PIPELINE");
        }
        if (params.vertex_count == 0) {
            try self.addWarning("W003", "DRAW with vertex_count=0 - nothing will render");
        }
        if (params.instance_count == 0) {
            try self.addWarning("W003", "DRAW with instance_count=0 - nothing will render");
        }
        self.draw_count += 1;
    }

    fn validateDrawIndexed(self: *Self, params: DrawIndexedParams) !void {
        if (self.pass_state != .render) {
            try self.addError("E002", "DRAW_INDEXED outside render pass");
            return;
        }
        if (self.current_pipeline == null) {
            try self.addError("E002", "DRAW_INDEXED without SET_PIPELINE");
        }
        if (params.index_count == 0) {
            try self.addWarning("W003", "DRAW_INDEXED with index_count=0 - nothing will render");
        }
        if (params.instance_count == 0) {
            try self.addWarning("W003", "DRAW_INDEXED with instance_count=0 - nothing will render");
        }
        self.draw_count += 1;
    }

    fn validateDispatch(self: *Self, params: DispatchParams) !void {
        if (self.pass_state != .compute) {
            try self.addError("E002", "DISPATCH outside compute pass");
            return;
        }
        if (self.current_pipeline == null) {
            try self.addError("E002", "DISPATCH without SET_PIPELINE");
        }
        if (params.x == 0 or params.y == 0 or params.z == 0) {
            try self.addWarning("W003", "DISPATCH with workgroup dimension=0 - compute shader won't run");
        }
        self.dispatch_count += 1;
    }

    // ========================================================================
    // Queue Operation Validators
    // ========================================================================

    fn validateWriteBuffer(self: *Self, params: WriteBufferParams) !void {
        const buffer_info = self.buffers.get(params.id);
        if (buffer_info == null) {
            try self.addErrorWithId("E001", "WRITE_BUFFER references non-existent buffer", params.id);
        } else {
            // E006: Buffer must have COPY_DST usage flag for writeBuffer
            if ((buffer_info.?.usage & BufferUsage.COPY_DST) == 0) {
                try self.addErrorWithId(
                    "E006",
                    "WRITE_BUFFER buffer missing COPY_DST usage flag",
                    params.id,
                );
            }
        }

        // E004: Validate data pointer bounds
        _ = try self.validateMemoryBounds(
            params.data_ptr,
            params.data_len,
            "WRITE_BUFFER data_ptr + data_len exceeds WASM memory",
        );
    }

    fn validateWriteTimeUniform(self: *Self, params: WriteTimeUniformParams) !void {
        const buffer_info = self.buffers.get(params.id);
        if (buffer_info == null) {
            try self.addErrorWithId("E001", "WRITE_TIME_UNIFORM references non-existent buffer", params.id);
        } else {
            // E006: Buffer must have COPY_DST usage flag for writeBuffer
            if ((buffer_info.?.usage & BufferUsage.COPY_DST) == 0) {
                try self.addErrorWithId(
                    "E006",
                    "WRITE_TIME_UNIFORM buffer missing COPY_DST usage flag",
                    params.id,
                );
            }
        }
    }

    fn validateCopyBuffer(self: *Self, params: CopyBufferParams) !void {
        const src_info = self.buffers.get(params.src_id);
        const dst_info = self.buffers.get(params.dst_id);

        if (src_info == null) {
            try self.addErrorWithId("E001", "COPY_BUFFER_TO_BUFFER references non-existent source buffer", params.src_id);
        } else {
            // E006: Source buffer must have COPY_SRC usage flag
            if ((src_info.?.usage & BufferUsage.COPY_SRC) == 0) {
                try self.addErrorWithId(
                    "E006",
                    "COPY_BUFFER_TO_BUFFER source buffer missing COPY_SRC usage flag",
                    params.src_id,
                );
            }
        }

        if (dst_info == null) {
            try self.addErrorWithId("E001", "COPY_BUFFER_TO_BUFFER references non-existent destination buffer", params.dst_id);
        } else {
            // E006: Destination buffer must have COPY_DST usage flag
            if ((dst_info.?.usage & BufferUsage.COPY_DST) == 0) {
                try self.addErrorWithId(
                    "E006",
                    "COPY_BUFFER_TO_BUFFER destination buffer missing COPY_DST usage flag",
                    params.dst_id,
                );
            }
        }

        // E006: Source and destination buffers must be different
        if (params.src_id == params.dst_id) {
            try self.addErrorWithId(
                "E006",
                "COPY_BUFFER_TO_BUFFER source and destination are the same buffer",
                params.src_id,
            );
        }
    }

    fn validateCopyTexture(self: *Self, params: CopyTextureParams) !void {
        // 0xFFFF is special canvas texture
        if (params.src_id != 0xFFFF and !self.textures.contains(params.src_id)) {
            try self.addErrorWithId("E001", "COPY_TEXTURE_TO_TEXTURE references non-existent source texture", params.src_id);
        }
        if (params.dst_id != 0xFFFF and !self.textures.contains(params.dst_id)) {
            try self.addErrorWithId("E001", "COPY_TEXTURE_TO_TEXTURE references non-existent destination texture", params.dst_id);
        }
    }

    fn validateWriteBufferFromWasm(self: *Self, params: WriteBufferFromWasmParams) !void {
        const buffer_info = self.buffers.get(params.buffer_id);
        if (buffer_info == null) {
            try self.addErrorWithId("E001", "WRITE_BUFFER_FROM_WASM references non-existent buffer", params.buffer_id);
        } else {
            // E006: Buffer must have COPY_DST usage flag for writeBuffer
            if ((buffer_info.?.usage & BufferUsage.COPY_DST) == 0) {
                try self.addErrorWithId(
                    "E006",
                    "WRITE_BUFFER_FROM_WASM buffer missing COPY_DST usage flag",
                    params.buffer_id,
                );
            }
        }

        // E004: Validate WASM memory source pointer bounds
        _ = try self.validateMemoryBounds(
            params.wasm_ptr,
            params.size,
            "WRITE_BUFFER_FROM_WASM wasm_ptr + size exceeds WASM memory",
        );
    }

    fn validateCopyExternalImage(self: *Self, params: CopyExternalImageParams) !void {
        if (!self.image_bitmaps.contains(params.bitmap_id)) {
            try self.addErrorWithId("E001", "COPY_EXTERNAL_IMAGE_TO_TEXTURE references non-existent bitmap", params.bitmap_id);
        }
        if (params.texture_id != 0xFFFF and !self.textures.contains(params.texture_id)) {
            try self.addErrorWithId("E001", "COPY_EXTERNAL_IMAGE_TO_TEXTURE references non-existent texture", params.texture_id);
        }
    }

    fn validateCallWasmFunc(self: *Self, params: CallWasmFuncParams) !void {
        if (!self.wasm_modules.contains(params.module_id)) {
            try self.addErrorWithId("E001", "CALL_WASM_FUNC references non-existent WASM module", params.module_id);
        }

        // E004: Validate function name pointer bounds
        _ = try self.validateMemoryBounds(
            params.func_ptr,
            params.func_len,
            "CALL_WASM_FUNC func_ptr + func_len exceeds WASM memory",
        );

        // E004: Validate arguments pointer bounds
        _ = try self.validateMemoryBounds(
            params.args_ptr,
            params.args_len,
            "CALL_WASM_FUNC args_ptr + args_len exceeds WASM memory",
        );
    }

    fn validateFillArray(self: *Self, params: FillArrayParams) !void {
        if (!self.typed_arrays.contains(params.array_id)) {
            try self.addErrorWithId("E001", "FILL operation references non-existent typed array", params.array_id);
        }
    }

    fn validateFillExpression(self: *Self, params: FillExpressionParams) !void {
        if (!self.typed_arrays.contains(params.array_id)) {
            try self.addErrorWithId("E001", "FILL_EXPRESSION references non-existent typed array", params.array_id);
        }

        // E004: Validate expression pointer bounds
        _ = try self.validateMemoryBounds(
            params.expr_ptr,
            @as(u32, params.expr_len),
            "FILL_EXPRESSION expr_ptr + expr_len exceeds WASM memory",
        );
    }

    fn validateWriteBufferFromArray(self: *Self, params: WriteBufferFromArrayParams) !void {
        const buffer_info = self.buffers.get(params.buffer_id);
        if (buffer_info == null) {
            try self.addErrorWithId("E001", "WRITE_BUFFER_FROM_ARRAY references non-existent buffer", params.buffer_id);
        } else {
            // E006: Buffer must have COPY_DST usage flag for writeBuffer
            if ((buffer_info.?.usage & BufferUsage.COPY_DST) == 0) {
                try self.addErrorWithId(
                    "E006",
                    "WRITE_BUFFER_FROM_ARRAY buffer missing COPY_DST usage flag",
                    params.buffer_id,
                );
            }
        }
        if (!self.typed_arrays.contains(params.array_id)) {
            try self.addErrorWithId("E001", "WRITE_BUFFER_FROM_ARRAY references non-existent typed array", params.array_id);
        }
    }

    // ========================================================================
    // State Management
    // ========================================================================

    fn resetPassState(self: *Self) void {
        self.bound_vertex_buffers = .{null} ** 8;
        self.bound_bind_groups = .{null} ** 4;
    }

    fn resetFrameState(self: *Self) void {
        // Resources persist across frames, but pass state resets
        self.pass_state = .none;
        self.current_pipeline = null;
        self.resetPassState();
    }

    // ========================================================================
    // Error Helpers
    // ========================================================================

    fn addError(self: *Self, code: []const u8, message: []const u8) !void {
        try self.issues.append(self.allocator, .{
            .code = code,
            .severity = .err,
            .message = message,
            .command_index = self.command_index,
        });
    }

    fn addErrorWithId(self: *Self, code: []const u8, message: []const u8, resource_id: u16) !void {
        try self.issues.append(self.allocator, .{
            .code = code,
            .severity = .err,
            .message = message,
            .command_index = self.command_index,
            .resource_id = resource_id,
        });
    }

    fn addWarning(self: *Self, code: []const u8, message: []const u8) !void {
        try self.issues.append(self.allocator, .{
            .code = code,
            .severity = .warning,
            .message = message,
            .command_index = self.command_index,
        });
    }

    // ========================================================================
    // Query Methods
    // ========================================================================

    /// Returns true if any errors were found.
    pub fn hasErrors(self: *const Self) bool {
        for (self.issues.items) |issue| {
            if (issue.severity == .err) return true;
        }
        return false;
    }

    /// Count of error-level issues.
    pub fn errorCount(self: *const Self) u32 {
        var count: u32 = 0;
        for (self.issues.items) |issue| {
            if (issue.severity == .err) count += 1;
        }
        return count;
    }

    /// Count of warning-level issues.
    pub fn warningCount(self: *const Self) u32 {
        var count: u32 = 0;
        for (self.issues.items) |issue| {
            if (issue.severity == .warning) count += 1;
        }
        return count;
    }

    /// Get resource counts for summary.
    pub fn getResourceCounts(self: *const Self) ResourceCounts {
        return .{
            .buffers = @intCast(self.buffers.count()),
            .textures = @intCast(self.textures.count()),
            .samplers = @intCast(self.samplers.count()),
            .shaders = @intCast(self.shaders.count()),
            .render_pipelines = @intCast(self.render_pipelines.count()),
            .compute_pipelines = @intCast(self.compute_pipelines.count()),
            .bind_groups = @intCast(self.bind_groups.count()),
        };
    }

    pub const ResourceCounts = struct {
        buffers: u32,
        textures: u32,
        samplers: u32,
        shaders: u32,
        render_pipelines: u32,
        compute_pipelines: u32,
        bind_groups: u32,
    };
};

/// Parse raw command buffer bytes into structured commands.
///
/// The command buffer format is:
/// │ u32: total_len │ u32: frame_count │ [commands...] │
///
/// Complexity: O(n) where n = data.len
///
/// Pre-condition: data.len >= 8 (header size)
/// Post-condition: Returns owned slice of parsed commands (caller must free)
pub fn parseCommands(allocator: std.mem.Allocator, data: []const u8) ![]ParsedCommand {
    // Pre-condition: minimum header size
    if (data.len < 8) return &[_]ParsedCommand{};

    const total_len = std.mem.readInt(u32, data[0..4], .little);

    // Validate header: total_len must not exceed data size
    if (total_len > data.len) return error.InvalidFormat;
    std.debug.assert(total_len >= 8);

    var commands = std.ArrayListUnmanaged(ParsedCommand){};
    errdefer commands.deinit(allocator);

    var pos: u32 = 8; // Skip 8-byte header
    var cmd_index: u32 = 0;

    // Bounded loop: prevent infinite loops on malformed input
    for (0..MAX_COMMANDS) |_| {
        if (pos >= total_len) break;

        const tag = data[pos];
        pos += 1;

        const cmd: Cmd = @enumFromInt(tag);
        const params = try parseParams(cmd, data, &pos);

        try commands.append(allocator, .{
            .index = cmd_index,
            .cmd = cmd,
            .params = params,
        });

        cmd_index += 1;

        if (cmd == .end) break;
    } else {
        // Loop exhausted without finding .end - malformed input
        return error.InvalidFormat;
    }

    const result = try commands.toOwnedSlice(allocator);

    // Post-condition: result length bounded
    std.debug.assert(result.len <= MAX_COMMANDS);

    return result;
}

/// Parse command parameters from buffer.
fn parseParams(cmd: Cmd, data: []const u8, pos: *u32) !ParsedCommand.Params {
    const p = pos.*;
    const remaining = data.len - p;

    return switch (cmd) {
        .create_buffer => blk: {
            if (remaining < 7) return error.Truncated;
            pos.* += 7;
            break :blk .{ .create_buffer = .{
                .id = readU16(data, p),
                .size = readU32(data, p + 2),
                .usage = data[p + 6],
            } };
        },
        .create_texture, .create_sampler, .create_bind_group_layout, .create_pipeline_layout, .create_query_set, .create_render_bundle => blk: {
            if (remaining < 10) return error.Truncated;
            pos.* += 10;
            break :blk .{ .create_resource = .{
                .id = readU16(data, p),
                .desc_ptr = readU32(data, p + 2),
                .desc_len = readU32(data, p + 6),
            } };
        },
        .create_shader => blk: {
            if (remaining < 10) return error.Truncated;
            pos.* += 10;
            break :blk .{ .create_shader = .{
                .id = readU16(data, p),
                .code_ptr = readU32(data, p + 2),
                .code_len = readU32(data, p + 6),
            } };
        },
        .create_render_pipeline, .create_compute_pipeline => blk: {
            if (remaining < 10) return error.Truncated;
            pos.* += 10;
            break :blk .{ .create_resource = .{
                .id = readU16(data, p),
                .desc_ptr = readU32(data, p + 2),
                .desc_len = readU32(data, p + 6),
            } };
        },
        .create_bind_group => blk: {
            if (remaining < 12) return error.Truncated;
            pos.* += 12;
            break :blk .{ .create_bind_group = .{
                .id = readU16(data, p),
                .layout_id = readU16(data, p + 2),
                .entries_ptr = readU32(data, p + 4),
                .entries_len = readU32(data, p + 8),
            } };
        },
        .create_texture_view => blk: {
            if (remaining < 12) return error.Truncated;
            pos.* += 12;
            break :blk .{ .create_texture_view = .{
                .id = readU16(data, p),
                .texture_id = readU16(data, p + 2),
                .desc_ptr = readU32(data, p + 4),
                .desc_len = readU32(data, p + 8),
            } };
        },
        .create_image_bitmap => blk: {
            if (remaining < 10) return error.Truncated;
            pos.* += 10;
            break :blk .{ .create_resource = .{
                .id = readU16(data, p),
                .desc_ptr = readU32(data, p + 2),
                .desc_len = readU32(data, p + 6),
            } };
        },
        .begin_render_pass => blk: {
            if (remaining < 6) return error.Truncated;
            pos.* += 6;
            break :blk .{ .begin_render_pass = .{
                .color_id = readU16(data, p),
                .load_op = data[p + 2],
                .store_op = data[p + 3],
                .depth_id = readU16(data, p + 4),
            } };
        },
        .begin_compute_pass => .{ .none = {} },
        .set_pipeline => blk: {
            if (remaining < 2) return error.Truncated;
            pos.* += 2;
            break :blk .{ .set_pipeline = .{ .id = readU16(data, p) } };
        },
        .set_bind_group => blk: {
            if (remaining < 3) return error.Truncated;
            pos.* += 3;
            break :blk .{ .set_bind_group = .{
                .slot = data[p],
                .id = readU16(data, p + 1),
            } };
        },
        .set_vertex_buffer => blk: {
            if (remaining < 3) return error.Truncated;
            pos.* += 3;
            break :blk .{ .set_vertex_buffer = .{
                .slot = data[p],
                .id = readU16(data, p + 1),
            } };
        },
        .set_index_buffer => blk: {
            if (remaining < 3) return error.Truncated;
            pos.* += 3;
            break :blk .{ .set_index_buffer = .{
                .id = readU16(data, p),
                .format = data[p + 2],
            } };
        },
        .draw => blk: {
            if (remaining < 16) return error.Truncated;
            pos.* += 16;
            break :blk .{ .draw = .{
                .vertex_count = readU32(data, p),
                .instance_count = readU32(data, p + 4),
                .first_vertex = readU32(data, p + 8),
                .first_instance = readU32(data, p + 12),
            } };
        },
        .draw_indexed => blk: {
            if (remaining < 20) return error.Truncated;
            pos.* += 20;
            break :blk .{ .draw_indexed = .{
                .index_count = readU32(data, p),
                .instance_count = readU32(data, p + 4),
                .first_index = readU32(data, p + 8),
                .base_vertex = readU32(data, p + 12),
                .first_instance = readU32(data, p + 16),
            } };
        },
        .dispatch => blk: {
            if (remaining < 12) return error.Truncated;
            pos.* += 12;
            break :blk .{ .dispatch = .{
                .x = readU32(data, p),
                .y = readU32(data, p + 4),
                .z = readU32(data, p + 8),
            } };
        },
        .end_pass => .{ .none = {} },
        .execute_bundles => blk: {
            if (remaining < 1) return error.Truncated;
            const count = data[p];
            const skip: u32 = 1 + @as(u32, count) * 2;
            if (remaining < skip) return error.Truncated;
            pos.* += skip;
            break :blk .{ .none = {} };
        },
        .write_buffer => blk: {
            if (remaining < 14) return error.Truncated;
            pos.* += 14;
            break :blk .{ .write_buffer = .{
                .id = readU16(data, p),
                .offset = readU32(data, p + 2),
                .data_ptr = readU32(data, p + 6),
                .data_len = readU32(data, p + 10),
            } };
        },
        .write_time_uniform => blk: {
            if (remaining < 8) return error.Truncated;
            pos.* += 8;
            break :blk .{ .write_time_uniform = .{
                .id = readU16(data, p),
                .offset = readU32(data, p + 2),
                .size = readU16(data, p + 6),
            } };
        },
        .copy_buffer_to_buffer => blk: {
            if (remaining < 16) return error.Truncated;
            pos.* += 16;
            break :blk .{ .copy_buffer = .{
                .src_id = readU16(data, p),
                .src_offset = readU32(data, p + 2),
                .dst_id = readU16(data, p + 6),
                .dst_offset = readU32(data, p + 8),
                .size = readU32(data, p + 12),
            } };
        },
        .copy_texture_to_texture => blk: {
            if (remaining < 8) return error.Truncated;
            pos.* += 8;
            break :blk .{ .copy_texture = .{
                .src_id = readU16(data, p),
                .dst_id = readU16(data, p + 2),
                .width = readU16(data, p + 4),
                .height = readU16(data, p + 6),
            } };
        },
        .copy_external_image_to_texture => blk: {
            if (remaining < 9) return error.Truncated;
            pos.* += 9;
            break :blk .{ .copy_external_image = .{
                .bitmap_id = readU16(data, p),
                .texture_id = readU16(data, p + 2),
                .mip_level = data[p + 4],
                .origin_x = readU16(data, p + 5),
                .origin_y = readU16(data, p + 7),
            } };
        },
        .write_buffer_from_wasm => blk: {
            if (remaining < 14) return error.Truncated;
            pos.* += 14;
            break :blk .{ .write_buffer_from_wasm = .{
                .buffer_id = readU16(data, p),
                .buffer_offset = readU32(data, p + 2),
                .wasm_ptr = readU32(data, p + 6),
                .size = readU32(data, p + 10),
            } };
        },
        .init_wasm_module => blk: {
            if (remaining < 10) return error.Truncated;
            pos.* += 10;
            break :blk .{ .init_wasm_module = .{
                .module_id = readU16(data, p),
                .data_ptr = readU32(data, p + 2),
                .data_len = readU32(data, p + 6),
            } };
        },
        .call_wasm_func => blk: {
            if (remaining < 20) return error.Truncated;
            pos.* += 20;
            break :blk .{ .call_wasm_func = .{
                .call_id = readU16(data, p),
                .module_id = readU16(data, p + 2),
                .func_ptr = readU32(data, p + 4),
                .func_len = readU32(data, p + 8),
                .args_ptr = readU32(data, p + 12),
                .args_len = readU32(data, p + 16),
            } };
        },
        .create_typed_array => blk: {
            if (remaining < 7) return error.Truncated;
            pos.* += 7;
            break :blk .{ .create_typed_array = .{
                .id = readU16(data, p),
                .array_type = data[p + 2],
                .size = readU32(data, p + 3),
            } };
        },
        .fill_random, .fill_constant => blk: {
            if (remaining < 15) return error.Truncated;
            pos.* += 15;
            break :blk .{ .fill_array = .{
                .array_id = readU16(data, p),
                .offset = readU32(data, p + 2),
                .count = readU32(data, p + 6),
                .stride = data[p + 10],
                .data_ptr = readU32(data, p + 11),
            } };
        },
        .fill_expression => blk: {
            if (remaining < 17) return error.Truncated;
            pos.* += 17;
            break :blk .{ .fill_expression = .{
                .array_id = readU16(data, p),
                .offset = readU32(data, p + 2),
                .count = readU32(data, p + 6),
                .stride = data[p + 10],
                .expr_ptr = readU32(data, p + 11),
                .expr_len = readU16(data, p + 15),
            } };
        },
        .write_buffer_from_array => blk: {
            if (remaining < 8) return error.Truncated;
            pos.* += 8;
            break :blk .{ .write_buffer_from_array = .{
                .buffer_id = readU16(data, p),
                .buffer_offset = readU32(data, p + 2),
                .array_id = readU16(data, p + 6),
            } };
        },
        .submit, .end => .{ .none = {} },
    };
}

/// Read little-endian u16 from data at offset.
/// Pre-condition: offset + 2 <= data.len
inline fn readU16(data: []const u8, offset: u32) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

/// Read little-endian u32 from data at offset.
/// Pre-condition: offset + 4 <= data.len
inline fn readU32(data: []const u8, offset: u32) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

// ============================================================================
// Tests
// ============================================================================

test "Validator: init creates clean state" {
    // Property: A new validator starts with no resources and no issues.
    // Method: Create validator, verify all maps are empty and state is none.

    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();

    try std.testing.expectEqual(@as(u32, 0), validator.buffers.count());
    try std.testing.expectEqual(PassState.none, validator.pass_state);
    try std.testing.expectEqual(@as(?u16, null), validator.current_pipeline);
    try std.testing.expectEqual(@as(usize, 0), validator.issues.items.len);
}

test "Validator: duplicate buffer ID produces E005" {
    // Property: Creating a resource with an ID that already exists is an error.
    // Method: Create two buffers with same ID, verify E005 is reported.

    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();

    // Use VERTEX (0x20) - a valid single usage flag (0x21 was MAP_READ|VERTEX which is now E006)
    const cmds = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{ .id = 1, .size = 256, .usage = BufferUsage.VERTEX } } },
        .{ .index = 1, .cmd = .create_buffer, .params = .{ .create_buffer = .{ .id = 1, .size = 512, .usage = BufferUsage.VERTEX } } },
    };

    try validator.validate(&cmds);

    try std.testing.expectEqual(@as(usize, 1), validator.issues.items.len);
    try std.testing.expectEqualStrings("E005", validator.issues.items[0].code);
    try std.testing.expectEqual(@as(?u16, 1), validator.issues.items[0].resource_id);
}

test "Validator: draw outside pass produces E002" {
    // Property: Draw commands are only valid inside a render pass.
    // Method: Issue draw without begin_render_pass, verify E002.

    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();

    const cmds = [_]ParsedCommand{
        .{ .index = 0, .cmd = .draw, .params = .{ .draw = .{ .vertex_count = 3, .instance_count = 1, .first_vertex = 0, .first_instance = 0 } } },
    };

    try validator.validate(&cmds);

    try std.testing.expect(validator.hasErrors());
    try std.testing.expectEqualStrings("E002", validator.issues.items[0].code);
}

test "Validator: nested pass produces E008" {
    // Property: Only one pass can be active at a time.
    // Method: Begin render pass twice without ending, verify E008.

    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();

    const cmds = [_]ParsedCommand{
        .{ .index = 0, .cmd = .begin_render_pass, .params = .{ .begin_render_pass = .{ .color_id = 0xFFFF, .load_op = 1, .store_op = 1, .depth_id = 0xFFFF } } },
        .{ .index = 1, .cmd = .begin_render_pass, .params = .{ .begin_render_pass = .{ .color_id = 0xFFFF, .load_op = 1, .store_op = 1, .depth_id = 0xFFFF } } },
    };

    try validator.validate(&cmds);

    try std.testing.expect(validator.hasErrors());
    try std.testing.expectEqualStrings("E008", validator.issues.items[0].code);
}

test "Validator: missing pipeline produces E001" {
    // Property: SET_PIPELINE must reference an existing pipeline.
    // Method: Set pipeline with non-existent ID, verify E001.

    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();

    const cmds = [_]ParsedCommand{
        .{ .index = 0, .cmd = .begin_render_pass, .params = .{ .begin_render_pass = .{ .color_id = 0xFFFF, .load_op = 1, .store_op = 1, .depth_id = 0xFFFF } } },
        .{ .index = 1, .cmd = .set_pipeline, .params = .{ .set_pipeline = .{ .id = 99 } } },
    };

    try validator.validate(&cmds);

    try std.testing.expect(validator.hasErrors());
    try std.testing.expectEqualStrings("E001", validator.issues.items[0].code);
}

test "Validator: valid render sequence produces no errors" {
    // Property: A properly structured render sequence passes validation.
    // Method: Create full valid sequence (create resources, begin pass, draw, end), verify no errors.

    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();

    // Use VERTEX (0x20) - a valid single usage flag (0x21 was MAP_READ|VERTEX which is now E006)
    const cmds = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{ .id = 0, .size = 256, .usage = BufferUsage.VERTEX } } },
        .{ .index = 1, .cmd = .create_shader, .params = .{ .create_shader = .{ .id = 0, .code_ptr = 0, .code_len = 100 } } },
        .{ .index = 2, .cmd = .create_render_pipeline, .params = .{ .create_resource = .{ .id = 0, .desc_ptr = 0, .desc_len = 50 } } },
        .{ .index = 3, .cmd = .begin_render_pass, .params = .{ .begin_render_pass = .{ .color_id = 0xFFFF, .load_op = 1, .store_op = 1, .depth_id = 0xFFFF } } },
        .{ .index = 4, .cmd = .set_pipeline, .params = .{ .set_pipeline = .{ .id = 0 } } },
        .{ .index = 5, .cmd = .draw, .params = .{ .draw = .{ .vertex_count = 3, .instance_count = 1, .first_vertex = 0, .first_instance = 0 } } },
        .{ .index = 6, .cmd = .end_pass, .params = .{ .none = {} } },
        .{ .index = 7, .cmd = .submit, .params = .{ .none = {} } },
    };

    try validator.validate(&cmds);

    try std.testing.expect(!validator.hasErrors());
    try std.testing.expectEqual(@as(u32, 1), validator.draw_count);
}

test "Validator: draw without pipeline produces E002" {
    // Property: Draw requires a pipeline to be set first.
    // Method: Begin pass and draw without set_pipeline, verify E002.

    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();

    const cmds = [_]ParsedCommand{
        .{ .index = 0, .cmd = .begin_render_pass, .params = .{ .begin_render_pass = .{ .color_id = 0xFFFF, .load_op = 1, .store_op = 1, .depth_id = 0xFFFF } } },
        .{ .index = 1, .cmd = .draw, .params = .{ .draw = .{ .vertex_count = 3, .instance_count = 1, .first_vertex = 0, .first_instance = 0 } } },
    };

    try validator.validate(&cmds);

    try std.testing.expect(validator.hasErrors());
    try std.testing.expectEqualStrings("E002", validator.issues.items[0].code);
}

test "parseCommands: extracts buffer parameters correctly" {
    // Property: parseCommands extracts all buffer creation parameters.
    // Method: Create buffer via CommandBuffer, parse, verify fields match.

    var buffer: [256]u8 = undefined;
    var cmds_writer = pngine.command_buffer.CommandBuffer.init(&buffer);

    cmds_writer.createBuffer(5, 1024, 0x21);
    cmds_writer.end();

    const data = cmds_writer.finish();
    const parsed = try parseCommands(std.testing.allocator, data);
    defer std.testing.allocator.free(parsed);

    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqual(Cmd.create_buffer, parsed[0].cmd);
    try std.testing.expectEqual(@as(u16, 5), parsed[0].params.create_buffer.id);
    try std.testing.expectEqual(@as(u32, 1024), parsed[0].params.create_buffer.size);
    try std.testing.expectEqual(@as(u8, 0x21), parsed[0].params.create_buffer.usage);
}

test "parseCommands: preserves command sequence order" {
    // Property: Commands are parsed in the order they appear in the buffer.
    // Method: Write multiple commands, verify parsed order matches write order.

    var buffer: [512]u8 = undefined;
    var cmds_writer = pngine.command_buffer.CommandBuffer.init(&buffer);

    cmds_writer.beginRenderPass(0xFFFF, 1, 1, 0xFFFF);
    cmds_writer.setPipeline(0);
    cmds_writer.draw(3, 1, 0, 0);
    cmds_writer.endPass();
    cmds_writer.end();

    const data = cmds_writer.finish();
    const parsed = try parseCommands(std.testing.allocator, data);
    defer std.testing.allocator.free(parsed);

    try std.testing.expectEqual(@as(usize, 5), parsed.len);
    try std.testing.expectEqual(Cmd.begin_render_pass, parsed[0].cmd);
    try std.testing.expectEqual(Cmd.set_pipeline, parsed[1].cmd);
    try std.testing.expectEqual(Cmd.draw, parsed[2].cmd);
    try std.testing.expectEqual(Cmd.end_pass, parsed[3].cmd);
    try std.testing.expectEqual(Cmd.end, parsed[4].cmd);
}

// ============================================================================
// E004 Memory Bounds Checking Tests
// ============================================================================

test "Validator: E004 detects ptr+len overflow" {
    // Property: Pointer + length that overflows u32 triggers E004.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();

    // Set a large memory size (won't matter since overflow happens first)
    validator.setWasmMemorySize(0x1000_0000);

    // Create shader command with ptr+len that overflows
    const commands = [_]ParsedCommand{
        .{
            .index = 0,
            .cmd = .create_shader,
            .params = .{ .create_shader = .{
                .id = 0,
                .code_ptr = 0xFFFF_FFF0, // Near max u32
                .code_len = 0x0000_0020, // Will overflow when added
            } },
        },
    };

    try validator.validate(&commands);

    // Should have E004 error
    try std.testing.expect(validator.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), validator.issues.items.len);
    try std.testing.expectEqualStrings("E004", validator.issues.items[0].code);
}

test "Validator: E004 detects out-of-bounds access" {
    // Property: Pointer + length exceeding memory size triggers E004.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();

    // Set small memory size (64KB)
    validator.setWasmMemorySize(65536);

    // Create shader command that exceeds memory bounds
    const commands = [_]ParsedCommand{
        .{
            .index = 0,
            .cmd = .create_shader,
            .params = .{ .create_shader = .{
                .id = 0,
                .code_ptr = 60000, // Within bounds
                .code_len = 10000, // 60000 + 10000 = 70000 > 65536
            } },
        },
    };

    try validator.validate(&commands);

    // Should have E004 error
    try std.testing.expect(validator.hasErrors());
    try std.testing.expectEqualStrings("E004", validator.issues.items[0].code);
}

test "Validator: E004 valid bounds produces no error" {
    // Property: Valid pointer + length produces no E004 error.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();

    // Set memory size (64KB)
    validator.setWasmMemorySize(65536);

    // Create shader command within bounds
    const commands = [_]ParsedCommand{
        .{
            .index = 0,
            .cmd = .create_shader,
            .params = .{ .create_shader = .{
                .id = 0,
                .code_ptr = 1000,
                .code_len = 500, // 1000 + 500 = 1500 < 65536
            } },
        },
    };

    try validator.validate(&commands);

    // Should have no errors
    try std.testing.expect(!validator.hasErrors());
}

test "Validator: W004 warns on null pointer with non-zero length" {
    // Property: ptr=0 with len>0 is suspicious and triggers W004 warning.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();

    validator.setWasmMemorySize(65536);

    // Create shader command with null pointer but non-zero length
    const commands = [_]ParsedCommand{
        .{
            .index = 0,
            .cmd = .create_shader,
            .params = .{ .create_shader = .{
                .id = 0,
                .code_ptr = 0, // Null pointer
                .code_len = 100, // But claims 100 bytes
            } },
        },
    };

    try validator.validate(&commands);

    // Should have W004 warning (not error)
    try std.testing.expect(!validator.hasErrors());
    try std.testing.expect(validator.warningCount() >= 1);
}

test "Validator: E004 checks multiple commands" {
    // Property: E004 checking works for different command types.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();

    validator.setWasmMemorySize(1024);

    // Multiple commands with bounds issues
    const commands = [_]ParsedCommand{
        .{
            .index = 0,
            .cmd = .create_buffer,
            .params = .{ .create_buffer = .{ .id = 0, .size = 64, .usage = 0x40 } },
        },
        .{
            .index = 1,
            .cmd = .write_buffer,
            .params = .{ .write_buffer = .{
                .id = 0,
                .offset = 0,
                .data_ptr = 500,
                .data_len = 600, // 500 + 600 = 1100 > 1024
            } },
        },
    };

    try validator.validate(&commands);

    // Should have E004 error for write_buffer
    try std.testing.expect(validator.hasErrors());
    var found_e004 = false;
    for (validator.issues.items) |issue| {
        if (std.mem.eql(u8, issue.code, "E004")) {
            found_e004 = true;
            break;
        }
    }
    try std.testing.expect(found_e004);
}

test "Validator: bounds checking skipped when memory size not set" {
    // Property: When wasm_memory_size is null, bounds checking is skipped.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();

    // Don't set memory size - bounds checking should be skipped

    // Create shader command that would fail if bounds were checked
    const commands = [_]ParsedCommand{
        .{
            .index = 0,
            .cmd = .create_shader,
            .params = .{ .create_shader = .{
                .id = 0,
                .code_ptr = 0x8000_0000, // Large address
                .code_len = 0x1000_0000, // Large length (but no overflow)
            } },
        },
    };

    try validator.validate(&commands);

    // Should have no E004 errors (bounds checking skipped)
    for (validator.issues.items) |issue| {
        if (std.mem.eql(u8, issue.code, "E004")) {
            try std.testing.expect(false); // Fail if E004 found
        }
    }
}

// ============================================================================
// E004 Boundary Edge Case Tests
// ============================================================================

test "Validator: E004 boundary - ptr=0 len=0 passes" {
    // Property: Empty range at start of memory is valid.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(65536);

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 0,
            .code_ptr = 0,
            .code_len = 0,
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(!validator.hasErrors());
}

test "Validator: E004 boundary - ptr=mem_size len=0 passes" {
    // Property: Empty range at exact end of memory is valid.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(65536);

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 0,
            .code_ptr = 65536, // At boundary
            .code_len = 0, // Zero length
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(!validator.hasErrors());
}

test "Validator: E004 boundary - exactly at limit passes" {
    // Property: ptr + len == mem_size is valid (last byte).
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(65536);

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 0,
            .code_ptr = 65535, // Last byte
            .code_len = 1, // One byte: 65535 + 1 = 65536 <= 65536
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(!validator.hasErrors());
}

test "Validator: E004 boundary - one byte past limit fails" {
    // Property: ptr + len == mem_size + 1 is invalid.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(65536);

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 0,
            .code_ptr = 65535,
            .code_len = 2, // 65535 + 2 = 65537 > 65536
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
    try std.testing.expectEqualStrings("E004", validator.issues.items[0].code);
}

test "Validator: E004 boundary - entire memory is valid" {
    // Property: Using all of memory (ptr=0, len=mem_size) is valid.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(65536);

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 0,
            .code_ptr = 0,
            .code_len = 65536, // Entire memory
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(!validator.hasErrors());
}

test "Validator: E004 boundary - entire memory plus one fails" {
    // Property: ptr=0, len=mem_size+1 exceeds bounds.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(65536);

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 0,
            .code_ptr = 0,
            .code_len = 65537, // One past entire memory
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
}

test "Validator: E004 boundary - start past end fails" {
    // Property: ptr >= mem_size with non-zero len fails.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(65536);

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 0,
            .code_ptr = 65536, // At boundary
            .code_len = 1, // Can't read even one byte
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
}

// ============================================================================
// E004 Overflow Edge Case Tests
// ============================================================================

test "Validator: E004 overflow - max ptr with zero len passes" {
    // Property: ptr=MAX with len=0 doesn't overflow, and end_addr == mem_size is valid.
    // This tests the boundary condition where end_addr equals memory size exactly.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(0xFFFFFFFF); // Max memory

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 0,
            .code_ptr = 0xFFFFFFFF,
            .code_len = 0,
        } } },
    };

    try validator.validate(&commands);
    // end_addr (0xFFFFFFFF) == mem_size (0xFFFFFFFF), so no E004 error
    // (would only be error if end_addr > mem_size)
    try std.testing.expect(!validator.hasErrors());
}

test "Validator: E004 overflow - half max values overflow" {
    // Property: 0x80000000 + 0x80000000 = overflow.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(0xFFFFFFFF);

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 0,
            .code_ptr = 0x80000000,
            .code_len = 0x80000000, // Overflows to 0
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
    try std.testing.expectEqualStrings("E004", validator.issues.items[0].code);
}

test "Validator: E004 overflow - near max without overflow passes" {
    // Property: 0x7FFFFFFF + 0x7FFFFFFF = 0xFFFFFFFE (no overflow).
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(0xFFFFFFFF);

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 0,
            .code_ptr = 0x7FFFFFFF,
            .code_len = 0x7FFFFFFF, // Sum = 0xFFFFFFFE, no overflow
        } } },
    };

    try validator.validate(&commands);
    // No overflow, and 0xFFFFFFFE < 0xFFFFFFFF, so valid
    try std.testing.expect(!validator.hasErrors());
}

// ============================================================================
// E004 Multi-Command Tests
// ============================================================================

test "Validator: E004 continues checking after first error" {
    // Property: Validator doesn't short-circuit on first E004.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(1024);

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 0,
            .code_ptr = 2000, // Exceeds 1024
            .code_len = 100,
        } } },
        .{ .index = 1, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 1,
            .code_ptr = 3000, // Also exceeds 1024
            .code_len = 100,
        } } },
    };

    try validator.validate(&commands);

    // Should have 2 E004 errors
    var e004_count: u32 = 0;
    for (validator.issues.items) |issue| {
        if (std.mem.eql(u8, issue.code, "E004")) e004_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), e004_count);
}

test "Validator: E004 valid command between invalid ones" {
    // Property: Valid commands aren't affected by invalid neighbors.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(1024);

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 0,
            .code_ptr = 2000, // Invalid
            .code_len = 100,
        } } },
        .{ .index = 1, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 1,
            .code_ptr = 100, // Valid
            .code_len = 100,
        } } },
        .{ .index = 2, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 2,
            .code_ptr = 5000, // Invalid
            .code_len = 100,
        } } },
    };

    try validator.validate(&commands);

    // Should have exactly 2 E004 errors (indices 0 and 2)
    var e004_count: u32 = 0;
    for (validator.issues.items) |issue| {
        if (std.mem.eql(u8, issue.code, "E004")) e004_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), e004_count);
}

// ============================================================================
// E004 Different Command Types Tests
// ============================================================================

test "Validator: E004 checks WRITE_BUFFER bounds" {
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(1024);

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = 0x40,
        } } },
        .{ .index = 1, .cmd = .write_buffer, .params = .{ .write_buffer = .{
            .id = 0,
            .offset = 0,
            .data_ptr = 2000, // Exceeds 1024
            .data_len = 100,
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
}

test "Validator: E004 checks WRITE_BUFFER_FROM_WASM bounds" {
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(1024);

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = 0x40,
        } } },
        .{ .index = 1, .cmd = .write_buffer_from_wasm, .params = .{ .write_buffer_from_wasm = .{
            .buffer_id = 0,
            .buffer_offset = 0,
            .wasm_ptr = 500,
            .size = 600, // 500 + 600 = 1100 > 1024
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
}

test "Validator: E004 checks CREATE_BIND_GROUP bounds" {
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(1024);

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_bind_group, .params = .{ .create_bind_group = .{
            .id = 0,
            .layout_id = 0,
            .entries_ptr = 900,
            .entries_len = 200, // 900 + 200 = 1100 > 1024
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
}

test "Validator: E004 checks CALL_WASM_FUNC both pointers" {
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(1024);

    // Pre-create the WASM module
    try validator.wasm_modules.put(validator.allocator, 0, .{ .created_at = 0 });

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .call_wasm_func, .params = .{ .call_wasm_func = .{
            .call_id = 0,
            .module_id = 0,
            .func_ptr = 500,
            .func_len = 600, // Invalid
            .args_ptr = 100,
            .args_len = 50, // Valid
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
}

test "Validator: E004 checks FILL_EXPRESSION bounds" {
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(1024);

    // Pre-create the typed array
    try validator.typed_arrays.put(validator.allocator, 0, .{ .created_at = 0 });

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .fill_expression, .params = .{ .fill_expression = .{
            .array_id = 0,
            .offset = 0,
            .count = 10,
            .stride = 4,
            .expr_ptr = 900,
            .expr_len = 200, // 900 + 200 = 1100 > 1024
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
}

// ============================================================================
// E004 Fuzz Test
// ============================================================================

test "Validator: E004 fuzz - property: error iff overflow or exceeds bounds" {
    // Property: E004 error occurs if and only if:
    // 1. ptr + len overflows u32, OR
    // 2. ptr + len > wasm_memory_size
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();

    // Test 1000 random cases
    for (0..1000) |_| {
        var validator = Validator.init(std.testing.allocator);
        defer validator.deinit();

        // Random memory size (at least 1 to avoid edge case)
        const mem_size = random.intRangeAtMost(u32, 1, 0x10000000);
        validator.setWasmMemorySize(mem_size);

        // Random ptr and len
        const ptr = random.int(u32);
        const len = random.int(u32);

        const commands = [_]ParsedCommand{
            .{ .index = 0, .cmd = .create_shader, .params = .{ .create_shader = .{
                .id = 0,
                .code_ptr = ptr,
                .code_len = len,
            } } },
        };

        try validator.validate(&commands);

        // Compute expected result
        const overflow = @addWithOverflow(ptr, len);
        const should_error = (overflow[1] != 0) or (overflow[0] > mem_size);

        // Verify
        var has_e004 = false;
        for (validator.issues.items) |issue| {
            if (std.mem.eql(u8, issue.code, "E004")) {
                has_e004 = true;
                break;
            }
        }

        if (should_error != has_e004) {
            std.debug.print(
                "Fuzz failure: ptr=0x{X}, len=0x{X}, mem_size=0x{X}, overflow={}, expected_error={}, got_error={}\n",
                .{ ptr, len, mem_size, overflow[1] != 0, should_error, has_e004 },
            );
            try std.testing.expect(false);
        }
    }
}

// ============================================================================
// E004 Unusual Scenario Tests (Long Tail)
// ============================================================================

test "Validator: E004 minimal memory size of 1 byte" {
    // Property: Memory size of 1 should work correctly.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(1);

    // Valid: ptr=0, len=1
    const valid = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 0,
            .code_ptr = 0,
            .code_len = 1,
        } } },
    };
    try validator.validate(&valid);
    try std.testing.expect(!validator.hasErrors());

    // Reset
    validator.issues.clearRetainingCapacity();

    // Invalid: ptr=0, len=2
    const invalid = [_]ParsedCommand{
        .{ .index = 1, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 1,
            .code_ptr = 0,
            .code_len = 2,
        } } },
    };
    try validator.validate(&invalid);
    try std.testing.expect(validator.hasErrors());
}

test "Validator: E004 very large memory (near u32 max)" {
    // Property: Large memory sizes near u32 max should work.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(0xFFFFFFFE); // Max minus 1

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 0,
            .code_ptr = 0xFFFFFFF0,
            .code_len = 0x0E, // Sum = 0xFFFFFFFE, exactly at limit
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(!validator.hasErrors());
}

test "Validator: E004 sparse allocations across memory" {
    // Property: Multiple non-contiguous valid allocations.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(10000);

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 0,
            .code_ptr = 0,
            .code_len = 100,
        } } },
        .{ .index = 1, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 1,
            .code_ptr = 5000,
            .code_len = 100,
        } } },
        .{ .index = 2, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 2,
            .code_ptr = 9900,
            .code_len = 100, // Exactly at end
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(!validator.hasErrors());
}

test "Validator: E004 overlapping ranges are allowed" {
    // Property: Overlapping memory ranges don't cause E004.
    // (E004 only checks bounds, not overlaps)
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(10000);

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 0,
            .code_ptr = 100,
            .code_len = 200, // 100-300
        } } },
        .{ .index = 1, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 1,
            .code_ptr = 150,
            .code_len = 200, // 150-350, overlaps with first
        } } },
    };

    try validator.validate(&commands);
    // No E004 - bounds are valid even if ranges overlap
    var has_e004 = false;
    for (validator.issues.items) |issue| {
        if (std.mem.eql(u8, issue.code, "E004")) has_e004 = true;
    }
    try std.testing.expect(!has_e004);
}

test "Validator: E004 null pointer with zero length is fine" {
    // Property: ptr=0, len=0 should not trigger W004.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(65536);

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 0,
            .code_ptr = 0,
            .code_len = 0, // Null with zero length is OK
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(!validator.hasErrors());
    try std.testing.expectEqual(@as(usize, 0), validator.warningCount());
}

test "Validator: E004 stress test with many commands" {
    // Property: Validator handles many commands efficiently.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    validator.setWasmMemorySize(1_000_000);

    // Create 500 valid shader commands
    var commands: [500]ParsedCommand = undefined;
    for (&commands, 0..) |*cmd, i| {
        cmd.* = .{
            .index = @intCast(i),
            .cmd = .create_shader,
            .params = .{ .create_shader = .{
                .id = @intCast(i),
                .code_ptr = @as(u32, @intCast(i)) * 1000,
                .code_len = 500,
            } },
        };
    }

    try validator.validate(&commands);
    try std.testing.expect(!validator.hasErrors());
}

// ============================================================================
// OOM Resilience Tests (FailingAllocator)
// ============================================================================

test "Validator: OOM during init" {
    // Property: Validator.init handles OOM gracefully.
    var fail_index: usize = 0;
    while (fail_index < 10) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });

        var validator = Validator.init(failing.allocator());
        defer validator.deinit();

        // If we get here without OOM, init succeeded
        if (!failing.has_induced_failure) {
            // Validator initialized successfully, test complete
            break;
        }
    }
}

test "Validator: OOM during validation with errors" {
    // Property: validate() handles OOM when adding errors.
    // Use a DRAW command outside of a pass to trigger E002 state violation
    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .draw, .params = .{ .draw = .{
            .vertex_count = 3,
            .instance_count = 1,
            .first_vertex = 0,
            .first_instance = 0,
        } } },
    };

    var fail_index: usize = 0;
    while (fail_index < 20) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });

        var validator = Validator.init(failing.allocator());
        defer validator.deinit();

        // This should try to add an error (draw outside pass)
        const result = validator.validate(&commands);
        if (result) |_| {
            if (!failing.has_induced_failure) {
                // Validation succeeded, OOM didn't affect this path
                break;
            }
        } else |err| {
            // Expected OOM or other error
            try std.testing.expect(err == error.OutOfMemory);
        }
    }
}

test "Validator: OOM during resource tracking" {
    // Property: Resource map insertions handle OOM.
    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = 0x40,
        } } },
        .{ .index = 1, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 1,
            .size = 64,
            .usage = 0x40,
        } } },
        .{ .index = 2, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 2,
            .size = 64,
            .usage = 0x40,
        } } },
    };

    var fail_index: usize = 0;
    while (fail_index < 30) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });

        var validator = Validator.init(failing.allocator());
        defer validator.deinit();

        const result = validator.validate(&commands);
        if (result) |_| {
            if (!failing.has_induced_failure) {
                // All allocations succeeded
                break;
            }
        } else |err| {
            try std.testing.expect(err == error.OutOfMemory);
        }
    }
}

test "Validator: OOM during E004 error reporting" {
    // Property: E004 bounds check error reporting handles OOM.
    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_shader, .params = .{ .create_shader = .{
            .id = 0,
            .code_ptr = 5000, // Out of bounds
            .code_len = 100,
        } } },
    };

    var fail_index: usize = 0;
    while (fail_index < 20) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });

        var validator = Validator.init(failing.allocator());
        defer validator.deinit();
        validator.setWasmMemorySize(1024);

        const result = validator.validate(&commands);
        if (result) |_| {
            if (!failing.has_induced_failure) {
                // Should have E004 error
                try std.testing.expect(validator.hasErrors());
                break;
            }
        } else |err| {
            try std.testing.expect(err == error.OutOfMemory);
        }
    }
}

// ============================================================================
// E006 Descriptor Validation Tests
// ============================================================================

test "Validator: E006 buffer size must be > 0" {
    // Property: Buffer with size=0 produces E006.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 0, // Invalid: size must be > 0
            .usage = BufferUsage.VERTEX,
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
    try std.testing.expectEqual(@as(u32, 1), validator.errorCount());
    try std.testing.expectEqualStrings("E006", validator.issues.items[0].code);
}

test "Validator: E006 buffer usage must not be 0" {
    // Property: Buffer with usage=0 produces E006.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = 0, // Invalid: usage must not be 0
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
    try std.testing.expectEqual(@as(u32, 1), validator.errorCount());
    try std.testing.expectEqualStrings("E006", validator.issues.items[0].code);
}

test "Validator: E006 MAP_READ only with COPY_DST" {
    // Property: MAP_READ with flags other than COPY_DST produces E006.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    // MAP_READ + VERTEX is invalid
    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = BufferUsage.MAP_READ | BufferUsage.VERTEX, // Invalid
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
    try std.testing.expectEqualStrings("E006", validator.issues.items[0].code);
    try std.testing.expect(std.mem.indexOf(u8, validator.issues.items[0].message, "MAP_READ") != null);
}

test "Validator: E006 MAP_WRITE only with COPY_SRC" {
    // Property: MAP_WRITE with flags other than COPY_SRC produces E006.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    // MAP_WRITE + UNIFORM is invalid
    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = BufferUsage.MAP_WRITE | BufferUsage.UNIFORM, // Invalid
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
    try std.testing.expectEqualStrings("E006", validator.issues.items[0].code);
    try std.testing.expect(std.mem.indexOf(u8, validator.issues.items[0].message, "MAP_WRITE") != null);
}

test "Validator: E006 MAP_READ and MAP_WRITE cannot both be set" {
    // Property: Having both MAP_READ and MAP_WRITE produces E006.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = BufferUsage.MAP_READ | BufferUsage.MAP_WRITE, // Invalid
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
    // Should have multiple errors: both MAP_READ and MAP_WRITE violations
    try std.testing.expect(validator.errorCount() >= 1);
}

test "Validator: E006 valid MAP_READ + COPY_DST" {
    // Property: MAP_READ + COPY_DST is valid per WebGPU spec.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = BufferUsage.MAP_READ | BufferUsage.COPY_DST, // Valid
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(!validator.hasErrors());
}

test "Validator: E006 valid MAP_WRITE + COPY_SRC" {
    // Property: MAP_WRITE + COPY_SRC is valid per WebGPU spec.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = BufferUsage.MAP_WRITE | BufferUsage.COPY_SRC, // Valid
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(!validator.hasErrors());
}

test "Validator: E006 valid MAP_READ alone" {
    // Property: MAP_READ alone is valid (no other flags needed).
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = BufferUsage.MAP_READ, // Valid
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(!validator.hasErrors());
}

test "Validator: E006 valid MAP_WRITE alone" {
    // Property: MAP_WRITE alone is valid.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = BufferUsage.MAP_WRITE, // Valid
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(!validator.hasErrors());
}

test "Validator: E006 all non-mapping usages are freely combinable" {
    // Property: INDEX, VERTEX, UNIFORM, STORAGE, COPY_SRC, COPY_DST can combine.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    // Common real-world combination: VERTEX | STORAGE | COPY_DST for compute output
    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = BufferUsage.VERTEX | BufferUsage.STORAGE | BufferUsage.COPY_DST,
        } } },
        .{ .index = 1, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 1,
            .size = 128,
            .usage = BufferUsage.UNIFORM | BufferUsage.COPY_DST, // Common uniform buffer
        } } },
        .{ .index = 2, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 2,
            .size = 256,
            .usage = BufferUsage.INDEX | BufferUsage.COPY_DST, // Index buffer
        } } },
        .{ .index = 3, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 3,
            .size = 512,
            .usage = BufferUsage.STORAGE | BufferUsage.COPY_SRC | BufferUsage.COPY_DST,
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(!validator.hasErrors());
}

test "Validator: E006 all single-flag usages are valid" {
    // Property: Each individual usage flag alone is valid.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const all_flags = [_]u8{
        BufferUsage.MAP_READ,
        BufferUsage.MAP_WRITE,
        BufferUsage.COPY_SRC,
        BufferUsage.COPY_DST,
        BufferUsage.INDEX,
        BufferUsage.VERTEX,
        BufferUsage.UNIFORM,
        BufferUsage.STORAGE,
    };

    var commands: [8]ParsedCommand = undefined;
    for (all_flags, 0..) |flag, i| {
        commands[i] = .{ .index = @intCast(i), .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = @intCast(i),
            .size = 64,
            .usage = flag,
        } } };
    }

    try validator.validate(&commands);
    try std.testing.expect(!validator.hasErrors());
}

test "Validator: E006 MAP_READ with multiple invalid flags" {
    // Property: MAP_READ with COPY_DST + VERTEX still fails (extra flag).
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = BufferUsage.MAP_READ | BufferUsage.COPY_DST | BufferUsage.VERTEX,
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
}

test "Validator: E006 MAP_WRITE with COPY_SRC + STORAGE fails" {
    // Property: MAP_WRITE + COPY_SRC + STORAGE fails (extra flag).
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = BufferUsage.MAP_WRITE | BufferUsage.COPY_SRC | BufferUsage.STORAGE,
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
}

test "Validator: E006 buffer size and usage both invalid" {
    // Property: Buffer with both size=0 and usage=0 produces multiple E006 errors.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 0, // Invalid
            .usage = 0, // Also invalid
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
    try std.testing.expectEqual(@as(u32, 2), validator.errorCount());
}

test "Validator: E006 comprehensive invalid MAP combinations" {
    // Property: All invalid MAP_READ combinations are caught.
    const allocator = std.testing.allocator;

    // MAP_READ with each invalid flag
    const invalid_with_map_read = [_]u8{
        BufferUsage.MAP_READ | BufferUsage.COPY_SRC, // Invalid
        BufferUsage.MAP_READ | BufferUsage.INDEX, // Invalid
        BufferUsage.MAP_READ | BufferUsage.VERTEX, // Invalid
        BufferUsage.MAP_READ | BufferUsage.UNIFORM, // Invalid
        BufferUsage.MAP_READ | BufferUsage.STORAGE, // Invalid
    };

    for (invalid_with_map_read) |usage| {
        var validator = Validator.init(allocator);
        defer validator.deinit();

        const commands = [_]ParsedCommand{
            .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
                .id = 0,
                .size = 64,
                .usage = usage,
            } } },
        };

        try validator.validate(&commands);
        try std.testing.expect(validator.hasErrors());
    }
}

test "Validator: E006 comprehensive invalid MAP_WRITE combinations" {
    // Property: All invalid MAP_WRITE combinations are caught.
    const allocator = std.testing.allocator;

    // MAP_WRITE with each invalid flag
    const invalid_with_map_write = [_]u8{
        BufferUsage.MAP_WRITE | BufferUsage.COPY_DST, // Invalid
        BufferUsage.MAP_WRITE | BufferUsage.INDEX, // Invalid
        BufferUsage.MAP_WRITE | BufferUsage.VERTEX, // Invalid
        BufferUsage.MAP_WRITE | BufferUsage.UNIFORM, // Invalid
        BufferUsage.MAP_WRITE | BufferUsage.STORAGE, // Invalid
    };

    for (invalid_with_map_write) |usage| {
        var validator = Validator.init(allocator);
        defer validator.deinit();

        const commands = [_]ParsedCommand{
            .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
                .id = 0,
                .size = 64,
                .usage = usage,
            } } },
        };

        try validator.validate(&commands);
        try std.testing.expect(validator.hasErrors());
    }
}

test "Validator: E006 fuzz - random buffer usage validation" {
    // Property: For any random usage value, validation correctly identifies
    // valid vs invalid based on WebGPU rules.
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();

    for (0..100) |i| {
        const usage = random.int(u8);
        const size: u32 = if (random.boolean()) 64 else 0;

        var validator = Validator.init(allocator);
        defer validator.deinit();

        const commands = [_]ParsedCommand{
            .{ .index = @intCast(i), .cmd = .create_buffer, .params = .{ .create_buffer = .{
                .id = 0,
                .size = size,
                .usage = usage,
            } } },
        };

        // Should not crash
        try validator.validate(&commands);

        // Verify expected behavior
        const has_map_read = (usage & BufferUsage.MAP_READ) != 0;
        const has_map_write = (usage & BufferUsage.MAP_WRITE) != 0;
        const other_than_map_read = usage & ~BufferUsage.MAP_READ;
        const other_than_map_write = usage & ~BufferUsage.MAP_WRITE;

        var should_have_error = false;

        // Size = 0 is always an error
        if (size == 0) should_have_error = true;

        // Usage = 0 is always an error
        if (usage == 0) should_have_error = true;

        // MAP_READ + MAP_WRITE together is an error
        if (has_map_read and has_map_write) should_have_error = true;

        // MAP_READ with anything other than COPY_DST is an error
        if (has_map_read and other_than_map_read != 0 and other_than_map_read != BufferUsage.COPY_DST) {
            should_have_error = true;
        }

        // MAP_WRITE with anything other than COPY_SRC is an error
        if (has_map_write and other_than_map_write != 0 and other_than_map_write != BufferUsage.COPY_SRC) {
            should_have_error = true;
        }

        try std.testing.expectEqual(should_have_error, validator.hasErrors());
    }
}

test "Validator: E006 OOM during buffer validation" {
    // Property: Buffer usage validation handles OOM gracefully.
    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 0, // Triggers E006
            .usage = 0, // Triggers another E006
        } } },
    };

    var fail_index: usize = 0;
    while (fail_index < 20) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });

        var validator = Validator.init(failing.allocator());
        defer validator.deinit();

        const result = validator.validate(&commands);
        if (result) |_| {
            if (!failing.has_induced_failure) {
                // Should have E006 errors
                try std.testing.expect(validator.hasErrors());
                break;
            }
        } else |err| {
            try std.testing.expect(err == error.OutOfMemory);
        }
    }
}

test "Validator: E006 edge case - max u32 size is valid" {
    // Property: Maximum buffer size is valid (size validation only checks for 0).
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = std.math.maxInt(u32),
            .usage = BufferUsage.STORAGE,
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(!validator.hasErrors());
}

test "Validator: E006 edge case - size=1 is valid" {
    // Property: Minimum non-zero buffer size is valid.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 1,
            .usage = BufferUsage.UNIFORM,
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(!validator.hasErrors());
}

test "Validator: E006 reports correct resource ID" {
    // Property: E006 error includes the buffer ID for debugging.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 42,
            .size = 0, // Triggers E006
            .usage = BufferUsage.VERTEX,
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
    try std.testing.expectEqual(@as(?u16, 42), validator.issues.items[0].resource_id);
}

test "Validator: E006 multiple buffers with mixed validity" {
    // Property: Validator correctly identifies errors in some buffers, not all.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        // Valid buffer
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = BufferUsage.VERTEX,
        } } },
        // Invalid: MAP_READ + VERTEX
        .{ .index = 1, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 1,
            .size = 64,
            .usage = BufferUsage.MAP_READ | BufferUsage.VERTEX,
        } } },
        // Valid buffer
        .{ .index = 2, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 2,
            .size = 128,
            .usage = BufferUsage.STORAGE | BufferUsage.COPY_DST,
        } } },
        // Invalid: size = 0
        .{ .index = 3, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 3,
            .size = 0,
            .usage = BufferUsage.UNIFORM,
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
    try std.testing.expectEqual(@as(u32, 2), validator.errorCount());
    // All buffers should still be tracked
    try std.testing.expectEqual(@as(u32, 4), validator.getResourceCounts().buffers);
}

// ============================================================================
// E006 Buffer Usage Context Validation Tests
// ============================================================================

test "Validator: E006 SET_VERTEX_BUFFER requires VERTEX usage" {
    // Property: Using a buffer without VERTEX usage in SET_VERTEX_BUFFER produces E006.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        // Create buffer WITHOUT VERTEX usage
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = BufferUsage.UNIFORM, // Missing VERTEX
        } } },
        .{ .index = 1, .cmd = .begin_render_pass, .params = .{ .begin_render_pass = .{
            .color_id = 0,
            .load_op = 0,
            .store_op = 0,
            .depth_id = 0xFFFF,
        } } },
        // Try to use as vertex buffer - should fail
        .{ .index = 2, .cmd = .set_vertex_buffer, .params = .{ .set_vertex_buffer = .{
            .slot = 0,
            .id = 0,
        } } },
        .{ .index = 3, .cmd = .end_pass, .params = .{ .none = {} } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
    try std.testing.expectEqualStrings("E006", validator.issues.items[0].code);
    try std.testing.expect(std.mem.indexOf(u8, validator.issues.items[0].message, "VERTEX") != null);
}

test "Validator: E006 SET_VERTEX_BUFFER with VERTEX usage passes" {
    // Property: Buffer with VERTEX usage in SET_VERTEX_BUFFER produces no error.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = BufferUsage.VERTEX,
        } } },
        .{ .index = 1, .cmd = .begin_render_pass, .params = .{ .begin_render_pass = .{
            .color_id = 0,
            .load_op = 0,
            .store_op = 0,
            .depth_id = 0xFFFF,
        } } },
        .{ .index = 2, .cmd = .set_vertex_buffer, .params = .{ .set_vertex_buffer = .{
            .slot = 0,
            .id = 0,
        } } },
        .{ .index = 3, .cmd = .end_pass, .params = .{ .none = {} } },
    };

    try validator.validate(&commands);
    try std.testing.expect(!validator.hasErrors());
}

test "Validator: E006 SET_INDEX_BUFFER requires INDEX usage" {
    // Property: Using a buffer without INDEX usage in SET_INDEX_BUFFER produces E006.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        // Create buffer WITHOUT INDEX usage
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = BufferUsage.VERTEX, // Missing INDEX
        } } },
        .{ .index = 1, .cmd = .begin_render_pass, .params = .{ .begin_render_pass = .{
            .color_id = 0,
            .load_op = 0,
            .store_op = 0,
            .depth_id = 0xFFFF,
        } } },
        .{ .index = 2, .cmd = .set_index_buffer, .params = .{ .set_index_buffer = .{
            .id = 0,
            .format = 0,
        } } },
        .{ .index = 3, .cmd = .end_pass, .params = .{ .none = {} } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
    try std.testing.expectEqualStrings("E006", validator.issues.items[0].code);
    try std.testing.expect(std.mem.indexOf(u8, validator.issues.items[0].message, "INDEX") != null);
}

test "Validator: E006 WRITE_BUFFER requires COPY_DST usage" {
    // Property: Using a buffer without COPY_DST usage in WRITE_BUFFER produces E006.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        // Create buffer WITHOUT COPY_DST usage
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = BufferUsage.UNIFORM, // Missing COPY_DST
        } } },
        .{ .index = 1, .cmd = .write_buffer, .params = .{ .write_buffer = .{
            .id = 0,
            .offset = 0,
            .data_ptr = 0,
            .data_len = 16,
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
    try std.testing.expectEqualStrings("E006", validator.issues.items[0].code);
    try std.testing.expect(std.mem.indexOf(u8, validator.issues.items[0].message, "COPY_DST") != null);
}

test "Validator: E006 WRITE_BUFFER with COPY_DST usage passes" {
    // Property: Buffer with COPY_DST usage in WRITE_BUFFER produces no error.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = BufferUsage.UNIFORM | BufferUsage.COPY_DST,
        } } },
        .{ .index = 1, .cmd = .write_buffer, .params = .{ .write_buffer = .{
            .id = 0,
            .offset = 0,
            .data_ptr = 0,
            .data_len = 16,
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(!validator.hasErrors());
}

test "Validator: E006 COPY_BUFFER_TO_BUFFER requires COPY_SRC and COPY_DST" {
    // Property: Source needs COPY_SRC, destination needs COPY_DST.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        // Source without COPY_SRC
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = BufferUsage.STORAGE, // Missing COPY_SRC
        } } },
        // Destination without COPY_DST
        .{ .index = 1, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 1,
            .size = 64,
            .usage = BufferUsage.STORAGE, // Missing COPY_DST
        } } },
        .{ .index = 2, .cmd = .copy_buffer_to_buffer, .params = .{ .copy_buffer = .{
            .src_id = 0,
            .src_offset = 0,
            .dst_id = 1,
            .dst_offset = 0,
            .size = 32,
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
    // Should have 2 errors: missing COPY_SRC and missing COPY_DST
    try std.testing.expectEqual(@as(u32, 2), validator.errorCount());
}

test "Validator: E006 COPY_BUFFER_TO_BUFFER same buffer fails" {
    // Property: Source and destination must be different buffers.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = BufferUsage.COPY_SRC | BufferUsage.COPY_DST,
        } } },
        // Copy to same buffer
        .{ .index = 1, .cmd = .copy_buffer_to_buffer, .params = .{ .copy_buffer = .{
            .src_id = 0,
            .src_offset = 0,
            .dst_id = 0, // Same as source!
            .dst_offset = 32,
            .size = 16,
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, validator.issues.items[0].message, "same buffer") != null);
}

test "Validator: E006 COPY_BUFFER_TO_BUFFER valid copy passes" {
    // Property: Valid copy operation with correct usage flags passes.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = BufferUsage.STORAGE | BufferUsage.COPY_SRC,
        } } },
        .{ .index = 1, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 1,
            .size = 64,
            .usage = BufferUsage.STORAGE | BufferUsage.COPY_DST,
        } } },
        .{ .index = 2, .cmd = .copy_buffer_to_buffer, .params = .{ .copy_buffer = .{
            .src_id = 0,
            .src_offset = 0,
            .dst_id = 1,
            .dst_offset = 0,
            .size = 32,
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(!validator.hasErrors());
}

test "Validator: E006 WRITE_TIME_UNIFORM requires COPY_DST usage" {
    // Property: Buffer for WRITE_TIME_UNIFORM must have COPY_DST.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 16,
            .usage = BufferUsage.UNIFORM, // Missing COPY_DST
        } } },
        .{ .index = 1, .cmd = .write_time_uniform, .params = .{ .write_time_uniform = .{
            .id = 0,
            .offset = 0,
            .size = 4,
        } } },
    };

    try validator.validate(&commands);
    try std.testing.expect(validator.hasErrors());
    try std.testing.expectEqualStrings("E006", validator.issues.items[0].code);
}

test "Validator: E006 buffer used with multiple correct usages" {
    // Property: Buffer with multiple usage flags can be used in multiple contexts.
    const allocator = std.testing.allocator;
    var validator = Validator.init(allocator);
    defer validator.deinit();

    // Buffer with VERTEX + INDEX + COPY_DST can be used in all three contexts
    const commands = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{
            .id = 0,
            .size = 64,
            .usage = BufferUsage.VERTEX | BufferUsage.INDEX | BufferUsage.COPY_DST,
        } } },
        .{ .index = 1, .cmd = .write_buffer, .params = .{ .write_buffer = .{
            .id = 0,
            .offset = 0,
            .data_ptr = 0,
            .data_len = 16,
        } } },
        .{ .index = 2, .cmd = .begin_render_pass, .params = .{ .begin_render_pass = .{
            .color_id = 0,
            .load_op = 0,
            .store_op = 0,
            .depth_id = 0xFFFF,
        } } },
        .{ .index = 3, .cmd = .set_vertex_buffer, .params = .{ .set_vertex_buffer = .{
            .slot = 0,
            .id = 0,
        } } },
        .{ .index = 4, .cmd = .set_index_buffer, .params = .{ .set_index_buffer = .{
            .id = 0,
            .format = 0,
        } } },
        .{ .index = 5, .cmd = .end_pass, .params = .{ .none = {} } },
    };

    try validator.validate(&commands);
    try std.testing.expect(!validator.hasErrors());
}
