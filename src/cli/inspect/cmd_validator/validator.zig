//! The command-buffer Validator state machine. Split out of the original
//! single-file cmd_validator.zig; re-exported by ../cmd_validator.zig.

const std = @import("std");
const pngine = @import("pngine");
const Cmd = pngine.command_buffer.Cmd;
const desc = pngine.types.descriptors;
const opcodes = pngine.opcodes;

const cv_shared = @import("params.zig");
const MAX_COMMANDS = cv_shared.MAX_COMMANDS;
const MAX_RESOURCES = cv_shared.MAX_RESOURCES;
const BufferUsage = cv_shared.BufferUsage;
const TextureUsage = cv_shared.TextureUsage;
const CANVAS_TEXTURE_ID = cv_shared.CANVAS_TEXTURE_ID;
const NO_DEPTH_TEXTURE_ID = cv_shared.NO_DEPTH_TEXTURE_ID;
const Severity = cv_shared.Severity;
const Issue = cv_shared.Issue;
const PassState = cv_shared.PassState;
const Symptom = cv_shared.Symptom;
const DiagnosticCheck = cv_shared.DiagnosticCheck;
const Diagnosis = cv_shared.Diagnosis;
const BufferInfo = cv_shared.BufferInfo;
const TextureInfo = cv_shared.TextureInfo;
const ResourceInfo = cv_shared.ResourceInfo;
const DescriptorType = cv_shared.DescriptorType;
const TextureField = cv_shared.TextureField;
const ValueType = cv_shared.ValueType;
const PipelineInfo = cv_shared.PipelineInfo;

/// One `create_bind_group` layout reference, kept until end of stream so the
/// resolvability check does not depend on creation order (see
/// `checkBindGroupLayoutsResolve`).
const BindGroupLayoutRef = struct { layout_id: u16, command_index: u32 };
const ParsedCommand = cv_shared.ParsedCommand;
const writeJsonEscaped = cv_shared.writeJsonEscaped;
const CreateBufferParams = cv_shared.CreateBufferParams;
const CreateResourceParams = cv_shared.CreateResourceParams;
const CreateShaderParams = cv_shared.CreateShaderParams;
const CreateBindGroupParams = cv_shared.CreateBindGroupParams;
const CreateTextureViewParams = cv_shared.CreateTextureViewParams;
const BeginRenderPassParams = cv_shared.BeginRenderPassParams;
const SetPipelineParams = cv_shared.SetPipelineParams;
const SetBindGroupParams = cv_shared.SetBindGroupParams;
const SetVertexBufferParams = cv_shared.SetVertexBufferParams;
const SetIndexBufferParams = cv_shared.SetIndexBufferParams;
const DrawParams = cv_shared.DrawParams;
const DrawIndexedParams = cv_shared.DrawIndexedParams;
const DispatchParams = cv_shared.DispatchParams;
const IndirectParams = cv_shared.IndirectParams;
const WriteBufferParams = cv_shared.WriteBufferParams;
const WriteTimeUniformParams = cv_shared.WriteTimeUniformParams;
const CopyBufferParams = cv_shared.CopyBufferParams;
const CopyTextureParams = cv_shared.CopyTextureParams;
const CopyExternalImageParams = cv_shared.CopyExternalImageParams;
const InitWasmModuleParams = cv_shared.InitWasmModuleParams;
const CallWasmFuncParams = cv_shared.CallWasmFuncParams;
const WriteBufferFromWasmParams = cv_shared.WriteBufferFromWasmParams;

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

    /// WASM linear memory contents (for descriptor parsing).
    /// When set, enables E006 texture/buffer descriptor validation.
    /// When null, descriptor parsing is skipped.
    wasm_memory: ?[]const u8,

    /// Per-pass bound vertex buffers (8 slots max).
    bound_vertex_buffers: [8]?u16,

    /// Per-pass bound bind groups (4 slots max).
    bound_bind_groups: [4]?u16,

    /// Cumulative record of what the command stream *did*, as opposed to what
    /// is bound *right now*.
    ///
    /// The `bound_*` arrays above are live per-pass state: `resetPassState`
    /// clears them at every END_PASS and `resetFrameState` at every SUBMIT.
    /// Post-hoc analysis (`detectPatterns`, `detectMissingOperations`,
    /// `analyzeLikelyCauses`) runs *after* the stream's final SUBMIT, so reading
    /// live state from there always observes the cleared value — which is why
    /// every well-formed frame used to be reported as "bind group created but
    /// never bound" and "no vertex buffers, likely a fullscreen quad" (§337).
    /// Anything an analysis wants to know about the stream as a whole belongs
    /// here, not in `bound_*`.
    observed: Observed,

    /// Resource tracking maps - keyed by resource ID.
    buffers: std.AutoHashMapUnmanaged(u16, BufferInfo),
    textures: std.AutoHashMapUnmanaged(u16, TextureInfo),
    samplers: std.AutoHashMapUnmanaged(u16, ResourceInfo),
    shaders: std.AutoHashMapUnmanaged(u16, ResourceInfo),
    render_pipelines: std.AutoHashMapUnmanaged(u16, PipelineInfo),
    compute_pipelines: std.AutoHashMapUnmanaged(u16, PipelineInfo),
    /// Standalone bind-group-layout ids, so a bind group naming one can be
    /// checked against a layout that actually exists (§339).
    bind_group_layouts: std.AutoHashMapUnmanaged(u16, void),
    /// Each create_bind_group's layout reference, resolved at end of stream.
    bind_group_layout_refs: std.ArrayList(BindGroupLayoutRef),
    bind_groups: std.AutoHashMapUnmanaged(u16, ResourceInfo),
    texture_views: std.AutoHashMapUnmanaged(u16, ResourceInfo),
    image_bitmaps: std.AutoHashMapUnmanaged(u16, ResourceInfo),
    wasm_modules: std.AutoHashMapUnmanaged(u16, ResourceInfo),

    /// Collected validation issues (errors and warnings).
    issues: std.ArrayList(Issue),

    /// Uniform buffer IDs for conflict detection (W009).
    /// Buffers in this set have uniform fields and may be written via setUniform().
    /// WRITE_BUFFER to these buffers triggers a conflict warning.
    uniform_buffer_ids: std.AutoHashMapUnmanaged(u16, void),

    // ========================================================================
    // Types
    // ========================================================================

    const Self = @This();

    /// Monotonic tallies over the whole command stream. Never reset by pass or
    /// frame boundaries — that is the entire point of the type.
    pub const Observed = struct {
        /// SET_BIND_GROUP commands accepted (any slot, any pass).
        bind_group_binds: u32 = 0,
        /// SET_VERTEX_BUFFER commands accepted.
        vertex_buffer_binds: u32 = 0,
        /// Commands that put bytes into a buffer: WRITE_BUFFER,
        /// WRITE_TIME_UNIFORM, WRITE_POINTER_UNIFORM, WRITE_BUFFER_FROM_WASM,
        /// and COPY_BUFFER_TO_BUFFER's destination.
        buffer_writes: u32 = 0,
        /// DRAW_INDIRECT / DRAW_INDEXED_INDIRECT.
        indirect_draws: u32 = 0,
        /// DISPATCH_INDIRECT.
        indirect_dispatches: u32 = 0,
        /// EXECUTE_BUNDLES commands. The draws they replay were recorded when
        /// the bundle was built, so they are not in this stream — but their
        /// presence means the pass does draw.
        bundle_executions: u32 = 0,
    };

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
            .wasm_memory = null,
            .bound_vertex_buffers = .{null} ** 8,
            .bound_bind_groups = .{null} ** 4,
            .observed = .{},
            .buffers = .{},
            .textures = .{},
            .samplers = .{},
            .shaders = .{},
            .render_pipelines = .{},
            .compute_pipelines = .{},
            .bind_group_layouts = .{},
            .bind_group_layout_refs = .empty,
            .bind_groups = .{},
            .texture_views = .{},
            .image_bitmaps = .{},
            .wasm_modules = .{},
            .issues = .empty,
            .uniform_buffer_ids = .{},
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
        // No assert on `issues.len` here: the list grows with whatever the
        // stream under inspection did wrong (several per malformed command),
        // and a bound on INPUT is not an invariant to assert at teardown.

        self.buffers.deinit(self.allocator);
        self.textures.deinit(self.allocator);
        self.samplers.deinit(self.allocator);
        self.shaders.deinit(self.allocator);
        self.render_pipelines.deinit(self.allocator);
        self.compute_pipelines.deinit(self.allocator);
        self.bind_group_layouts.deinit(self.allocator);
        self.bind_group_layout_refs.deinit(self.allocator);
        self.bind_groups.deinit(self.allocator);
        self.texture_views.deinit(self.allocator);
        self.image_bitmaps.deinit(self.allocator);
        self.wasm_modules.deinit(self.allocator);
        self.issues.deinit(self.allocator);
        self.uniform_buffer_ids.deinit(self.allocator);

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

    /// Set WASM memory for descriptor parsing.
    ///
    /// When set, enables E006 texture/buffer descriptor validation by reading
    /// descriptor contents from the provided memory.
    ///
    /// Pre-condition: memory is valid WASM linear memory
    /// Post-condition: wasm_memory is set, also sets wasm_memory_size
    pub fn setWasmMemory(self: *Self, memory: []const u8) void {
        std.debug.assert(memory.len > 0);
        self.wasm_memory = memory;
        self.wasm_memory_size = @intCast(memory.len);
    }

    /// Set uniform buffer IDs for conflict detection (W009).
    ///
    /// Buffers in this set have uniform fields in the uniform table.
    /// WRITE_BUFFER to these buffers triggers a conflict warning because
    /// the setUniform() API may also write to the same buffer.
    ///
    /// Pre-condition: buffer_ids contains valid buffer IDs from uniform table
    /// Post-condition: uniform_buffer_ids is populated
    pub fn setUniformBufferIds(self: *Self, buffer_ids: []const u16) !void {
        for (buffer_ids) |id| {
            try self.uniform_buffer_ids.put(self.allocator, id, {});
        }
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

        try self.checkBindGroupLayoutsResolve();

        // Post-condition: issues can only grow, never shrink
        std.debug.assert(self.issues.items.len >= initial_issue_count);
    }

    /// Validate a single command.
    ///
    /// Exception to the 70-line rule: a dispatch table, one arm per opcode,
    /// each delegating to a named checker — the same shape as
    /// `dispatcher/pass.zig:handle`. Splitting it by family would only move the
    /// arms; what makes it readable is that every opcode appears exactly once,
    /// in enum order, and the compiler enforces that.
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
            // Tracked only so validateCreateBindGroup can resolve a tagged layout_id.
            .create_bind_group_layout => try self.bind_group_layouts.put(
                self.allocator,
                cmd.params.create_resource.id,
                {},
            ),
            .create_pipeline_layout, .create_query_set, .create_render_bundle => {
                // These don't need tracking for basic validation
            },

            // Pass operations
            .begin_render_pass => try self.validateBeginRenderPass(cmd.params.begin_render_pass),
            // The f32-clear forms (spec/09 D) open a pass exactly as their 4×u8
            // predecessors do; the pass-state machine never looked at the clear
            // value, which is why they share the arms rather than the decoders.
            .begin_render_pass_f32 => try self.beginRenderPassState(
                "BEGIN_RENDER_PASS_F32 inside active pass - nested passes not allowed",
            ),
            .begin_render_pass_mrt_f32 => try self.beginRenderPassState(
                "BEGIN_RENDER_PASS_MRT_F32 inside active pass - nested passes not allowed",
            ),
            .begin_compute_pass => try self.validateBeginComputePass(),
            .end_pass => try self.validateEndPass(),
            .set_pipeline => try self.validateSetPipeline(cmd.params.set_pipeline),
            .set_bind_group => try self.validateSetBindGroup(cmd.params.set_bind_group),
            .set_vertex_buffer => try self.validateSetVertexBuffer(cmd.params.set_vertex_buffer),
            .set_index_buffer => try self.validateSetIndexBuffer(cmd.params.set_index_buffer),
            .draw => try self.validateDraw(cmd.params.draw),
            .draw_indexed => try self.validateDrawIndexed(cmd.params.draw_indexed),
            .dispatch => try self.validateDispatch(cmd.params.dispatch),
            // MRT opens a render pass just as BEGIN_RENDER_PASS does. Leaving it
            // in the "TODO: validate" arm below meant pass_state stayed .none, so
            // every draw in an MRT pass was reported "outside render pass" and the
            // closing END_PASS "without matching BEGIN" — pure false positives on
            // any multi-target program (webgpu_deferred_rendering, primitive_picking).
            .begin_render_pass_mrt => try self.beginRenderPassState(
                "BEGIN_RENDER_PASS_MRT inside active pass - nested passes not allowed",
            ),
            .draw_indirect, .draw_indexed_indirect => try self.validateIndirectDraw(cmd.cmd, cmd.params.indirect),
            .dispatch_indirect => try self.validateIndirectDispatch(cmd.params.indirect),
            .execute_bundles => try self.validateExecuteBundles(),

            // In-pass state setters: these encode into the open pass, so
            // issuing one outside a pass is an error. Until §337 this arm let
            // all of them through unlooked-at.
            .set_viewport => try self.validateInPass("SET_VIEWPORT"),
            .set_scissor_rect => try self.validateInPass("SET_SCISSOR_RECT"),
            .set_stencil_reference => try self.validateInPass("SET_STENCIL_REFERENCE"),
            .set_blend_constant => try self.validateInPass("SET_BLEND_CONSTANT"),
            .begin_occlusion_query => try self.validateInPass("BEGIN_OCCLUSION_QUERY"),
            .end_occlusion_query => try self.validateInPass("END_OCCLUSION_QUERY"),

            // Pre-pass state: these configure the pass that follows, so they
            // are emitted *between* passes, not inside one.
            .set_pass_depth_stencil_ops => try self.validatePrePass("SET_PASS_DEPTH_STENCIL_OPS"),
            .set_pass_clear_values => try self.validatePrePass("SET_PASS_CLEAR_VALUES"),
            .set_pass_occlusion_query_set => try self.validatePrePass("SET_PASS_OCCLUSION_QUERY_SET"),
            .set_pass_timestamp_writes => try self.validatePrePass("SET_PASS_TIMESTAMP_WRITES"),

            // RESOLVE_QUERY_SET is a queue-level encoder command: it runs
            // between passes, not inside one, so it gets no pass-state check.
            .resolve_query_set => {},

            // Queue operations
            .write_buffer => try self.validateWriteBuffer(cmd.params.write_buffer),
            .write_time_uniform => try self.validateWriteTimeUniform(cmd.params.write_time_uniform),
            .write_pointer_uniform => try self.validateWriteTimeUniform(cmd.params.write_pointer_uniform),
            .copy_buffer_to_buffer => try self.validateCopyBuffer(cmd.params.copy_buffer),
            .copy_texture_to_texture => try self.validateCopyTexture(cmd.params.copy_texture),
            .write_buffer_from_wasm => try self.validateWriteBufferFromWasm(cmd.params.write_buffer_from_wasm),
            .copy_external_image_to_texture => try self.validateCopyExternalImage(cmd.params.copy_external_image),

            // WASM operations
            .init_wasm_module => try self.validateInitWasmModule(cmd.params.init_wasm_module),
            .call_wasm_func => try self.validateCallWasmFunc(cmd.params.call_wasm_func),

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

        // E007: Buffer size exceeds WebGPU maxBufferSize (256MB)
        const max_buffer_size: u32 = 268435456; // 256 * 1024 * 1024
        if (params.size > max_buffer_size) {
            try self.addErrorWithId("E007", "Buffer size exceeds maxBufferSize (256MB)", params.id);
        }

        // W004: UNIFORM buffer size should be aligned to 16 bytes (minUniformBufferOffsetAlignment)
        if ((params.usage & BufferUsage.UNIFORM) != 0 and (params.size % 16) != 0) {
            try self.addWarningWithContext(
                "W004",
                "UNIFORM buffer size not aligned to 16 bytes",
                params.id,
            );
        }

        // W004: STORAGE buffer size should be aligned to 4 bytes
        if ((params.usage & BufferUsage.STORAGE) != 0 and (params.size % 4) != 0) {
            try self.addWarningWithContext(
                "W004",
                "STORAGE buffer size not aligned to 4 bytes",
                params.id,
            );
        }

        // E006: usage-flag validation (non-zero + MAP_READ/MAP_WRITE combination rules)
        try self.checkBufferUsage(params.usage, params.id);

        // Post-condition: buffer is tracked
        try self.buffers.put(self.allocator, params.id, .{
            .size = params.size,
            .usage = params.usage,
            .created_at = self.command_index,
        });
    }

    /// E006 buffer usage-flag validation per WebGPU spec: usage must be non-zero,
    /// MAP_READ pairs only with COPY_DST, MAP_WRITE only with COPY_SRC, and the two
    /// MAP modes are mutually exclusive.
    fn checkBufferUsage(self: *Self, usage: u32, id: u16) !void {
        if (usage == 0) {
            try self.addErrorWithId("E006", "Buffer usage must not be 0", id);
            return;
        }

        // MAP_READ may only be combined with COPY_DST
        if ((usage & BufferUsage.MAP_READ) != 0) {
            const other_flags = usage & ~BufferUsage.MAP_READ;
            if (other_flags != 0 and other_flags != BufferUsage.COPY_DST) {
                try self.addErrorWithId("E006", "MAP_READ may only be combined with COPY_DST", id);
            }
        }

        // MAP_WRITE may only be combined with COPY_SRC
        if ((usage & BufferUsage.MAP_WRITE) != 0) {
            const other_flags = usage & ~BufferUsage.MAP_WRITE;
            if (other_flags != 0 and other_flags != BufferUsage.COPY_SRC) {
                try self.addErrorWithId("E006", "MAP_WRITE may only be combined with COPY_SRC", id);
            }
        }

        // MAP_READ and MAP_WRITE are mutually exclusive
        if ((usage & BufferUsage.MAP_READ) != 0 and (usage & BufferUsage.MAP_WRITE) != 0) {
            try self.addErrorWithId("E006", "MAP_READ and MAP_WRITE cannot both be set", id);
        }
    }

    fn validateCreateTexture(self: *Self, params: CreateResourceParams) !void {
        // Pre-conditions
        std.debug.assert(self.command_index < MAX_COMMANDS);

        // E005: Check for duplicate texture ID
        if (self.textures.contains(params.id)) {
            try self.addErrorWithId("E005", "Texture ID already in use", params.id);
            return;
        }

        // E004: Validate descriptor pointer bounds
        const bounds_valid = try self.validateMemoryBounds(
            params.desc_ptr,
            params.desc_len,
            "CREATE_TEXTURE desc_ptr + desc_len exceeds WASM memory",
        );

        // Parse texture descriptor and validate per WebGPU spec
        var texture_info = TextureInfo{ .created_at = self.command_index };
        var descriptor_parsed = false;

        // Only parse if we can access the descriptor memory
        if (bounds_valid and params.desc_len >= 2 and self.wasm_memory != null) {
            const mem = self.wasm_memory.?;
            const desc_ptr = params.desc_ptr;
            const desc_len = params.desc_len;

            // Read descriptor from WASM memory
            if (desc_ptr + desc_len <= mem.len) {
                const desc_data = mem[desc_ptr .. desc_ptr + desc_len];
                if (parseTextureDescriptor(desc_data)) |parsed| {
                    texture_info = parsed;
                    texture_info.created_at = self.command_index;
                    descriptor_parsed = true;
                }
            }

            // Warn on unusually large descriptors
            if (params.desc_len > 256) {
                try self.addWarning("W006", "Texture descriptor unusually large (>256 bytes)");
            }
        }

        // E006: Validate texture properties per WebGPU spec
        // Skip usage=0 check if descriptor wasn't parsed (can't determine actual usage)
        try self.validateTextureDescriptor(&texture_info, params.id, descriptor_parsed);

        // Post-condition: texture is tracked
        try self.textures.put(self.allocator, params.id, texture_info);

        // Post-condition: texture entry exists
        std.debug.assert(self.textures.contains(params.id));
    }

    /// Validate texture descriptor per WebGPU spec.
    /// See: https://www.w3.org/TR/webgpu/#abstract-opdef-validating-gputexturedescriptor
    ///
    /// Validates:
    /// - usage must not be 0 (except CANVAS_TEXTURE_ID which has browser-managed usage)
    /// - sampleCount must be 1 or 4
    /// - 1D textures: height=1, depth=1, sampleCount=1, no depth-stencil formats
    /// - 3D textures: sampleCount=1
    /// - MSAA textures (sampleCount > 1): mipLevelCount=1, depth=1,
    ///   no STORAGE_BINDING, must have RENDER_ATTACHMENT
    ///
    /// When descriptor_parsed is false, skip usage=0 check (can't determine actual usage).
    fn validateTextureDescriptor(self: *Self, info: *const TextureInfo, id: u16, descriptor_parsed: bool) !void {
        // Pre-condition: info is valid
        std.debug.assert(info.sample_count >= 1);

        // E006: usage must not be 0 (except for canvas texture or when descriptor not parsed)
        // - CANVAS_TEXTURE_ID (0xFFFE): browser-managed, usage=0 is valid
        // - descriptor not parsed: can't determine actual usage, skip check
        if (info.usage == 0 and id != CANVAS_TEXTURE_ID and descriptor_parsed) {
            try self.addErrorWithId("E006", "Texture usage cannot be 0", id);
        }

        // E006: sampleCount must be 1 or 4
        if (info.sample_count != 1 and info.sample_count != 4) {
            try self.addErrorWithId("E006", "Texture sampleCount must be 1 or 4", id);
        }

        // E006: 1D texture constraints
        if (info.dimension == .@"1d") {
            if (info.height != 1) {
                try self.addErrorWithId("E006", "1D texture height must be 1", id);
            }
            if (info.depth != 1) {
                try self.addErrorWithId("E006", "1D texture depthOrArrayLayers must be 1", id);
            }
            if (info.sample_count != 1) {
                try self.addErrorWithId("E006", "1D texture sampleCount must be 1", id);
            }
            // Check for depth-stencil format (0x10-0x1F range)
            if (info.format >= 0x10 and info.format <= 0x1F) {
                try self.addErrorWithId("E006", "1D texture cannot use depth-stencil format", id);
            }
        }

        // E006: 3D texture constraints
        if (info.dimension == .@"3d") {
            if (info.sample_count != 1) {
                try self.addErrorWithId("E006", "3D texture sampleCount must be 1", id);
            }
        }

        // E006: MSAA texture constraints (sampleCount > 1)
        if (info.sample_count > 1) {
            if (info.mip_level_count != 1) {
                try self.addErrorWithId("E006", "MSAA texture mipLevelCount must be 1", id);
            }
            if (info.depth != 1) {
                try self.addErrorWithId("E006", "MSAA texture depthOrArrayLayers must be 1", id);
            }
            // Check for STORAGE_BINDING flag (bit 3)
            if ((info.usage & TextureUsage.STORAGE_BINDING) != 0) {
                try self.addErrorWithId("E006", "MSAA texture cannot have STORAGE_BINDING usage", id);
            }
            // Must have RENDER_ATTACHMENT flag (bit 4)
            if ((info.usage & TextureUsage.RENDER_ATTACHMENT) == 0) {
                try self.addErrorWithId("E006", "MSAA texture must have RENDER_ATTACHMENT usage", id);
            }
        }

        // E006: Check for invalid usage flags (bits 5-7 should be 0)
        if ((info.usage & ~TextureUsage.ALL_VALID) != 0) {
            try self.addErrorWithId("E006", "Texture has invalid usage flags", id);
        }

        // Post-condition: no assertion needed, errors are collected
    }

    /// Parse texture descriptor from binary format.
    ///
    /// Binary format (matching DescriptorEncoder.zig):
    /// - Byte 0: DescriptorType.texture (0x02)
    /// - Byte 1: field_count
    /// - For each field: [field_id:u8] [value_type:u8] [value:...]
    ///
    /// Returns null if descriptor is invalid or too short.
    ///
    /// Complexity: O(n) where n = descriptor length
    pub fn parseTextureDescriptor(data: []const u8) ?TextureInfo {
        // Pre-condition: need at least 2 bytes (type + field count)
        if (data.len < 2) return null;

        // Verify type tag
        if (data[0] != @intFromEnum(DescriptorType.texture)) return null;

        var info = TextureInfo{ .created_at = 0 };

        // Walk the fields with the shared TlvReader rather than a local switch
        // over value types. The hand-rolled walk this replaces understood only
        // u32_val and enum_val and *broke out of the loop* on anything else, so
        // a texture sized from an image-bitmap — whose leading `size_from_image_bitmap` field
        // is a u16_val — aborted the walk at field 0. Every later field, `usage`
        // among them, was left at its zero default, and the caller still marked
        // the descriptor "parsed": a texture declared `:usage [texture-binding
        // copy-dst render-attachment]` was reported as E006 "usage cannot be 0".
        // TlvReader strides by ValueType.scalarByteSize(), so a value type this
        // function does not care about is skipped, not fatal.
        var reader = desc.TlvReader.init(data) orelse return null;
        for (0..MAX_DESCRIPTOR_FIELDS) |_| {
            const f = reader.next() orelse break;
            const field = std.enums.fromInt(TextureField, f.id) orelse continue;
            switch (field) {
                .width => info.width = f.scalar,
                .height => info.height = f.scalar,
                .depth => info.depth = f.scalar,
                .format => info.format = @truncate(f.scalar),
                .usage => info.usage = @truncate(f.scalar),
                .sample_count => info.sample_count = @truncate(f.scalar),
                .mip_level_count => info.mip_level_count = @truncate(f.scalar),
                .dimension => info.dimension = std.enums.fromInt(
                    @TypeOf(info.dimension),
                    @as(u8, @truncate(f.scalar)),
                ) orelse info.dimension,
                .view_formats, .size_from_image_bitmap => {},
            }
        } else {
            // Field-count bound reached - valid parse.
        }

        return info;
    }

    /// Upper bound on descriptor fields walked, so a corrupt field count cannot
    /// spin the loop. Comfortably above TextureField's cardinality.
    const MAX_DESCRIPTOR_FIELDS: usize = 32;

    /// Validate a texture with explicit properties (for testing).
    ///
    /// Creates a texture entry and validates it per WebGPU spec.
    /// Returns true if texture was created (may still have validation errors).
    pub fn validateTextureWithInfo(self: *Self, id: u16, info: TextureInfo) !bool {
        // Pre-condition
        std.debug.assert(id < MAX_RESOURCES);

        if (self.textures.contains(id)) {
            try self.addErrorWithId("E005", "Texture ID already in use", id);
            return false;
        }

        // Validate per WebGPU spec
        // Pass true for descriptor_parsed since info is explicitly provided
        try self.validateTextureDescriptor(&info, id, true);

        // Track texture
        try self.textures.put(self.allocator, id, info);
        return true;
    }

    // ========================================================================
    // Symptom-Based Diagnosis (Feature 2)
    // ========================================================================

    /// Diagnose a visual symptom by performing targeted checks.
    ///
    /// Returns a diagnosis with relevant checks, likely cause, and probability.
    /// The checks array is static and does not require deallocation.
    ///
    /// Pre-condition: validate() has been called
    /// Post-condition: Returns diagnosis with targeted checks for symptom
    pub fn diagnoseSymptom(self: *const Self, symptom: Symptom) Diagnosis {
        // Pre-condition: validation has run (has some state to analyze)
        // Note: we can't assert on command_index since it might be 0 for empty command buffers

        return switch (symptom) {
            .black_screen => self.diagnoseBlackScreen(),
            .wrong_colors => self.diagnoseWrongColors(),
            .blend_issues => self.diagnoseBlendIssues(),
            .transparent_output => self.diagnoseTransparentOutput(),
            .flickering => self.diagnoseFlickering(),
            .geometry_issues => self.diagnoseGeometryIssues(),
        };
    }

    /// Diagnose black screen issues.
    fn diagnoseBlackScreen(self: *const Self) Diagnosis {
        const checks = &[_]DiagnosticCheck{
            .{
                .name = "has_draw_command",
                .passed = self.drawsPerformed() > 0,
                .severity = .err,
                .message = if (self.drawsPerformed() > 0)
                    "DRAW commands found"
                else
                    "No DRAW commands - nothing will render",
                .value = .{ .integer = @as(i64, self.draw_count) },
            },
            .{
                .name = "has_render_pass",
                .passed = self.hasRenderPass(),
                .severity = .err,
                .message = if (self.hasRenderPass())
                    "Render pass commands found"
                else
                    "No BEGIN_RENDER_PASS - draw commands have no effect",
            },
            .{
                .name = "has_render_pipeline",
                .passed = self.render_pipelines.count() > 0,
                .severity = .err,
                .message = if (self.render_pipelines.count() > 0)
                    "Render pipeline created"
                else
                    "No render pipeline - GPU doesn't know how to draw",
            },
            .{
                .name = "has_shader",
                .passed = self.shaders.count() > 0,
                .severity = .err,
                .message = if (self.shaders.count() > 0)
                    "Shader module created"
                else
                    "No shader module - can't create pipeline",
            },
        };

        // Determine likely cause based on failed checks
        var likely_cause: ?[]const u8 = null;
        var probability: u8 = 0;

        if (self.drawsPerformed() == 0) {
            likely_cause = "No DRAW commands in command buffer";
            probability = 95;
        } else if (!self.hasRenderPass()) {
            likely_cause = "DRAW commands outside of render pass";
            probability = 90;
        } else if (self.render_pipelines.count() == 0) {
            likely_cause = "No render pipeline created";
            probability = 85;
        } else if (self.shaders.count() == 0) {
            likely_cause = "No shader module created";
            probability = 80;
        }

        return .{
            .symptom = .black_screen,
            .checks = checks,
            .likely_cause = likely_cause,
            .probability = probability,
        };
    }

    /// Diagnose wrong color issues.
    fn diagnoseWrongColors(self: *const Self) Diagnosis {
        _ = self;
        const checks = &[_]DiagnosticCheck{
            .{
                .name = "check_clear_color",
                .passed = true, // We don't track clear color in current implementation
                .severity = .warning,
                .message = "Check clear color in render pass - may be overriding shader output",
            },
            .{
                .name = "check_blend_state",
                .passed = true,
                .severity = .warning,
                .message = "Check blend state in pipeline - may be overwriting instead of blending",
            },
            .{
                .name = "check_color_format",
                .passed = true,
                .severity = .warning,
                .message = "Check color format - BGRA vs RGBA can swap red/blue",
            },
        };

        return .{
            .symptom = .wrong_colors,
            .checks = checks,
            .likely_cause = "Color format mismatch or blend state issue",
            .probability = 50,
        };
    }

    /// Diagnose blend/transparency issues.
    fn diagnoseBlendIssues(self: *const Self) Diagnosis {
        _ = self;
        const checks = &[_]DiagnosticCheck{
            .{
                .name = "blend_enabled",
                .passed = true, // We don't track blend state in current implementation
                .severity = .err,
                .message = "Check if blend is enabled in pipeline - alpha ignored if not",
            },
            .{
                .name = "blend_factors",
                .passed = true,
                .severity = .warning,
                .message = "Check blend factors - srcFactor and dstFactor determine blending",
            },
            .{
                .name = "alpha_component",
                .passed = true,
                .severity = .warning,
                .message = "Check if alpha blend component is configured",
            },
        };

        return .{
            .symptom = .blend_issues,
            .checks = checks,
            .likely_cause = "Blend not enabled or wrong blend factors",
            .probability = 60,
        };
    }

    /// Diagnose transparent/invisible output issues.
    fn diagnoseTransparentOutput(self: *const Self) Diagnosis {
        const has_draws = self.drawsPerformed() > 0;
        const has_dispatches = self.dispatch_count > 0;

        const checks = &[_]DiagnosticCheck{
            .{
                .name = "has_draw_or_dispatch",
                .passed = has_draws or has_dispatches,
                .severity = .err,
                .message = if (has_draws or has_dispatches)
                    "Draw/dispatch commands found"
                else
                    "No draw or dispatch commands - nothing will produce output",
            },
            .{
                .name = "check_store_op",
                .passed = true, // We don't track store_op
                .severity = .err,
                .message = "Check storeOp in render pass - 'discard' throws away content",
            },
            .{
                .name = "check_clear_alpha",
                .passed = true,
                .severity = .warning,
                .message = "Check clear alpha value - 0 means fully transparent canvas",
            },
        };

        var likely_cause: ?[]const u8 = null;
        var probability: u8 = 0;

        if (!has_draws and !has_dispatches) {
            likely_cause = "No rendering commands in buffer";
            probability = 90;
        } else {
            likely_cause = "storeOp='discard' or clear alpha=0";
            probability = 50;
        }

        return .{
            .symptom = .transparent_output,
            .checks = checks,
            .likely_cause = likely_cause,
            .probability = probability,
        };
    }

    /// Diagnose flickering issues.
    fn diagnoseFlickering(self: *const Self) Diagnosis {
        _ = self;
        const checks = &[_]DiagnosticCheck{
            .{
                .name = "ping_pong_offsets",
                .passed = true, // We don't track ping-pong in current implementation
                .severity = .err,
                .message = "Check ping-pong buffer offsets - both 0 means reading/writing same buffer",
            },
            .{
                .name = "multiple_submits",
                .passed = true,
                .severity = .warning,
                .message = "Check for multiple SUBMIT commands per frame",
            },
            .{
                .name = "frame_counter_usage",
                .passed = true,
                .severity = .warning,
                .message = "Check if frame counter is used for buffer selection",
            },
        };

        return .{
            .symptom = .flickering,
            .checks = checks,
            .likely_cause = "Ping-pong buffer offsets both 0 or sync issues",
            .probability = 40,
        };
    }

    /// Diagnose geometry issues.
    fn diagnoseGeometryIssues(self: *const Self) Diagnosis {
        const has_vertex_buffers = self.countVertexBuffers() > 0;

        const checks = &[_]DiagnosticCheck{
            .{
                .name = "has_vertex_buffer",
                .passed = has_vertex_buffers,
                .severity = .err,
                .message = if (has_vertex_buffers)
                    "Vertex buffer(s) created"
                else
                    "No vertex buffers - vertices may be at origin",
            },
            .{
                .name = "check_vertex_format",
                .passed = true,
                .severity = .warning,
                .message = "Check vertex format in pipeline matches buffer layout",
            },
            .{
                .name = "check_uniform_buffer",
                .passed = true,
                .severity = .warning,
                .message = "Check uniform buffer size - MVP matrix needs 64 bytes",
            },
        };

        var likely_cause: ?[]const u8 = null;
        var probability: u8 = 0;

        if (!has_vertex_buffers) {
            likely_cause = "No vertex buffers created";
            probability = 80;
        } else {
            likely_cause = "Vertex format mismatch or missing MVP matrix";
            probability = 50;
        }

        return .{
            .symptom = .geometry_issues,
            .checks = checks,
            .likely_cause = likely_cause,
            .probability = probability,
        };
    }

    /// Helper: Check if any render pass was started.
    fn hasRenderPass(self: *const Self) bool {
        // If we've seen any render pass-related issues or have draw count > 0
        // with no E002 errors about draw outside pass, we had a render pass
        for (self.issues.items) |issue| {
            if (std.mem.eql(u8, issue.code, "E007") or std.mem.eql(u8, issue.code, "E008")) {
                return true; // Pass-related error means passes were attempted
            }
        }
        // If we have draws without E002, passes were used correctly
        return self.drawsPerformed() > 0 and !self.hasDrawOutsidePassError();
    }

    /// Helper: Check for draw-outside-pass error.
    fn hasDrawOutsidePassError(self: *const Self) bool {
        for (self.issues.items) |issue| {
            if (std.mem.eql(u8, issue.code, "E002") and
                std.mem.indexOf(u8, issue.message, "outside") != null)
            {
                return true;
            }
        }
        return false;
    }

    /// Helper: Count buffers with VERTEX usage.
    fn countVertexBuffers(self: *const Self) u32 {
        var count: u32 = 0;
        var iter = self.buffers.iterator();
        while (iter.next()) |entry| {
            if ((entry.value_ptr.usage & BufferUsage.VERTEX) != 0) {
                count += 1;
            }
        }
        return count;
    }

    // ========================================================================
    // Missing Operations Detection (Feature 3)
    // ========================================================================

    /// Missing operation detection result.
    pub const MissingOperation = struct {
        operation: []const u8,
        severity: Severity,
        message: []const u8,
        context: ?[]const u8 = null,
    };

    /// Detect missing operations required for rendering.
    ///
    /// Checks for operations that should exist but don't, such as:
    /// - No DRAW command in render pass
    /// - Pipeline not set before draw
    /// - No shader module created
    /// - No submit command
    ///
    /// Returns a struct with detected missing operations and count.
    ///
    /// Pre-condition: validate() has been called
    pub fn detectMissingOperations(self: *const Self) MissingOperationsResult {
        var result = MissingOperationsResult{};
        self.detectMissingRenderOps(&result);
        self.detectMissingComputeOps(&result);

        // Check for common missing operations (warnings)
        if (self.bind_groups.count() > 0 and !self.hasBindGroupUsage()) {
            result.add(.{
                .operation = "SET_BIND_GROUP",
                .severity = .warning,
                .message = "Bind group created but never bound - resources not accessible to shader",
            });
        }

        if (self.hasUniformBuffer() and !self.hasWriteBuffer()) {
            result.add(.{
                .operation = "WRITE_BUFFER",
                .severity = .warning,
                .message = "Uniform buffer created but never written - using uninitialized data",
            });
        }

        return result;
    }

    /// Render-pipeline requirement checks for detectMissingOperations.
    fn detectMissingRenderOps(self: *const Self, result: *MissingOperationsResult) void {
        if (!(self.render_pipelines.count() > 0 or self.drawsPerformed() > 0)) return;

        if (self.shaders.count() == 0) {
            result.add(.{
                .operation = "CREATE_SHADER",
                .severity = .err,
                .message = "No shader module created - cannot create pipeline",
            });
        }

        if (self.render_pipelines.count() == 0 and self.drawsPerformed() > 0) {
            result.add(.{
                .operation = "CREATE_RENDER_PIPELINE",
                .severity = .err,
                .message = "No render pipeline created - draw commands have no effect",
            });
        }

        if (self.drawsPerformed() == 0 and self.render_pipelines.count() > 0) {
            result.add(.{
                .operation = "DRAW",
                .severity = .err,
                .message = "Render pipeline created but no DRAW command - nothing will render",
            });
        }

        if (!self.hasRenderPass() and self.drawsPerformed() > 0) {
            result.add(.{
                .operation = "BEGIN_RENDER_PASS",
                .severity = .err,
                .message = "DRAW commands found but no render pass started",
            });
        }
    }

    /// Compute-pipeline requirement checks for detectMissingOperations.
    fn detectMissingComputeOps(self: *const Self, result: *MissingOperationsResult) void {
        if (!(self.compute_pipelines.count() > 0 or self.dispatch_count > 0)) return;

        if (self.compute_pipelines.count() == 0 and self.dispatch_count > 0) {
            result.add(.{
                .operation = "CREATE_COMPUTE_PIPELINE",
                .severity = .err,
                .message = "DISPATCH commands found but no compute pipeline created",
            });
        }

        if (self.dispatch_count == 0 and self.compute_pipelines.count() > 0) {
            result.add(.{
                .operation = "DISPATCH",
                .severity = .err,
                .message = "Compute pipeline created but no DISPATCH command - compute shader won't run",
            });
        }
    }

    /// Result container for missing operations detection.
    pub const MissingOperationsResult = struct {
        items: [16]MissingOperation = undefined,
        count: u8 = 0,

        pub fn add(self: *MissingOperationsResult, op: MissingOperation) void {
            if (self.count < 16) {
                self.items[self.count] = op;
                self.count += 1;
            }
        }

        pub fn slice(self: *const MissingOperationsResult) []const MissingOperation {
            return self.items[0..self.count];
        }

        pub fn hasErrors(self: *const MissingOperationsResult) bool {
            for (self.slice()) |op| {
                if (op.severity == .err) return true;
            }
            return false;
        }

        pub fn hasWarnings(self: *const MissingOperationsResult) bool {
            for (self.slice()) |op| {
                if (op.severity == .warning) return true;
            }
            return false;
        }
    };

    // ========================================================================
    // Parameter Validation (Feature 4)
    // ========================================================================

    /// Parameter validation issue.
    pub const ParameterIssue = struct {
        parameter: []const u8,
        severity: Severity,
        message: []const u8,
        value: u32 = 0,
        limit: u32 = 0,
    };

    /// Result container for parameter validation.
    pub const ParameterValidationResult = struct {
        items: [16]ParameterIssue = undefined,
        count: u8 = 0,

        pub fn add(self: *ParameterValidationResult, issue: ParameterIssue) void {
            if (self.count < 16) {
                self.items[self.count] = issue;
                self.count += 1;
            }
        }

        pub fn slice(self: *const ParameterValidationResult) []const ParameterIssue {
            return self.items[0..self.count];
        }

        pub fn hasErrors(self: *const ParameterValidationResult) bool {
            for (self.slice()) |issue| {
                if (issue.severity == .err) return true;
            }
            return false;
        }

        pub fn hasWarnings(self: *const ParameterValidationResult) bool {
            for (self.slice()) |issue| {
                if (issue.severity == .warning) return true;
            }
            return false;
        }
    };

    /// WebGPU device limits for validation.
    pub const Limits = struct {
        maxBufferSize: u32 = 268435456, // 256MB
        maxComputeWorkgroupsPerDimension: u32 = 65535,
        maxTextureDimension1D: u32 = 8192,
        maxTextureDimension2D: u32 = 8192,
        maxTextureDimension3D: u32 = 2048,
        minUniformBufferOffsetAlignment: u32 = 256,
        minStorageBufferOffsetAlignment: u32 = 256,
    };

    /// Validate parameter values against WebGPU limits.
    ///
    /// This method validates parameter values (sizes, counts, dimensions)
    /// against WebGPU device limits and returns a structured result.
    ///
    /// Pre-condition: validate() has been called
    ///
    /// Returns: ParameterValidationResult with any limit violations
    pub fn validateParameterValues(self: *const Self) ParameterValidationResult {
        return self.validateParameterValuesWithLimits(Limits{});
    }

    /// Validate parameter values with custom limits.
    pub fn validateParameterValuesWithLimits(self: *const Self, limits: Limits) ParameterValidationResult {
        var result = ParameterValidationResult{};
        self.checkBufferSizeLimits(limits, &result);
        self.checkDispatchLimits(limits, &result);
        self.checkTextureDimensionLimits(limits, &result);
        return result;
    }

    /// Highest key in a u16-keyed resource map, or null when empty.
    ///
    /// The maps iterate in hash order; report surfaces that emit per-resource
    /// output instead walk ids 0..max (ids are compiler-assigned and
    /// sequential), giving deterministic ascending-id order (§260).
    fn maxKeyU16(map: anytype) ?u16 {
        var max: ?u16 = null;
        var it = map.iterator();
        while (it.next()) |entry| {
            if (max == null or entry.key_ptr.* > max.?) max = entry.key_ptr.*;
        }
        std.debug.assert((max == null) == (map.count() == 0));
        return max;
    }

    /// Buffer-size limit checks for validateParameterValuesWithLimits.
    /// Walks buffers in ascending-id order so issue order is deterministic.
    fn checkBufferSizeLimits(self: *const Self, limits: Limits, result: *ParameterValidationResult) void {
        const max_id = maxKeyU16(&self.buffers) orelse return;
        var id: u32 = 0;
        while (id <= max_id) : (id += 1) {
            const info = self.buffers.get(@intCast(id)) orelse continue;
            if (info.size > limits.maxBufferSize) {
                result.add(.{
                    .parameter = "buffer.size",
                    .severity = .err,
                    .message = "Buffer size exceeds maxBufferSize",
                    .value = info.size,
                    .limit = limits.maxBufferSize,
                });
            }
        }
    }

    /// Dispatch workgroup-count limit checks (surfaced via prior issue messages).
    fn checkDispatchLimits(self: *const Self, limits: Limits, result: *ParameterValidationResult) void {
        for (self.issues.items) |issue| {
            if (std.mem.indexOf(u8, issue.message, "workgroupCountX exceeds") != null or
                std.mem.indexOf(u8, issue.message, "workgroupCountY exceeds") != null or
                std.mem.indexOf(u8, issue.message, "workgroupCountZ exceeds") != null)
            {
                result.add(.{
                    .parameter = "dispatch.workgroupCount",
                    .severity = .err,
                    .message = "Dispatch workgroup count exceeds limit",
                    .value = 0, // Value not available from issue
                    .limit = limits.maxComputeWorkgroupsPerDimension,
                });
            }
        }
    }

    /// Texture dimension limit checks (1D/2D/3D) for validateParameterValuesWithLimits.
    /// Walks textures in ascending-id order so issue order is deterministic.
    fn checkTextureDimensionLimits(self: *const Self, limits: Limits, result: *ParameterValidationResult) void {
        const max_id = maxKeyU16(&self.textures) orelse return;
        var id: u32 = 0;
        while (id <= max_id) : (id += 1) {
            const info = self.textures.get(@intCast(id)) orelse continue;
            switch (info.dimension) {
                .@"1d" => overLimit(result, "texture.width", "1D texture width exceeds maxTextureDimension1D", info.width, limits.maxTextureDimension1D),
                .@"2d" => {
                    overLimit(result, "texture.width", "2D texture width exceeds maxTextureDimension2D", info.width, limits.maxTextureDimension2D);
                    overLimit(result, "texture.height", "2D texture height exceeds maxTextureDimension2D", info.height, limits.maxTextureDimension2D);
                },
                .@"3d" => {
                    overLimit(result, "texture.width", "3D texture width exceeds maxTextureDimension3D", info.width, limits.maxTextureDimension3D);
                    overLimit(result, "texture.height", "3D texture height exceeds maxTextureDimension3D", info.height, limits.maxTextureDimension3D);
                    overLimit(result, "texture.depth", "3D texture depth exceeds maxTextureDimension3D", info.depth, limits.maxTextureDimension3D);
                },
            }
        }
    }

    /// Record an error when `value` exceeds `limit`, and nothing otherwise.
    ///
    /// The predicate lives here rather than at each call site so a dimension
    /// cannot be checked against its own limit with the neighbouring field's
    /// value — the copy-paste that a column of near-identical `if` blocks
    /// invites, and that no test would notice until a texture hit the bound.
    fn overLimit(
        result: *ParameterValidationResult,
        parameter: []const u8,
        message: []const u8,
        value: u32,
        limit: u32,
    ) void {
        std.debug.assert(parameter.len > 0);
        if (value <= limit) return;
        result.add(.{
            .parameter = parameter,
            .severity = .err,
            .message = message,
            .value = value,
            .limit = limit,
        });
    }

    // ========================================================================
    // Pattern Detection (Feature 5)
    // ========================================================================

    /// Detected rendering/compute pattern.
    pub const Pattern = struct {
        name: []const u8,
        description: []const u8,
        confidence: u8, // 0-100
        details: ?[]const u8 = null,
    };

    /// Pattern detection result container.
    pub const PatternDetectionResult = struct {
        items: [8]Pattern = undefined,
        count: u8 = 0,

        pub fn add(self: *PatternDetectionResult, pattern: Pattern) void {
            if (self.count < 8) {
                self.items[self.count] = pattern;
                self.count += 1;
            }
        }

        pub fn slice(self: *const PatternDetectionResult) []const Pattern {
            return self.items[0..self.count];
        }

        pub fn hasPattern(self: *const PatternDetectionResult, name: []const u8) bool {
            for (self.slice()) |p| {
                if (std.mem.eql(u8, p.name, name)) return true;
            }
            return false;
        }
    };

    /// Detect common rendering and compute patterns.
    ///
    /// Identifies patterns like:
    /// - Fullscreen quad (vertex_count=6 or 4, no vertex buffers)
    /// - Instanced rendering (instance_count > 1)
    /// - Ping-pong buffers (STORAGE buffers with same size)
    /// - Compute simulation (compute + render pipeline)
    ///
    /// Pre-condition: validate() has been called
    ///
    /// Returns: PatternDetectionResult with detected patterns
    pub fn detectPatterns(self: *const Self) PatternDetectionResult {
        var result = PatternDetectionResult{};

        // Detect fullscreen quad pattern
        if (self.detectFullscreenQuad()) |confidence| {
            result.add(.{
                .name = "fullscreen_quad",
                .description = "Fullscreen quad rendering (no vertex buffers, 3-6 vertices)",
                .confidence = confidence,
            });
        }

        // Detect instanced rendering
        if (self.detectInstancedRendering()) |confidence| {
            result.add(.{
                .name = "instanced_rendering",
                .description = "Instanced rendering (instance_count > 1)",
                .confidence = confidence,
            });
        }

        // Detect ping-pong buffer pattern
        if (self.detectPingPongBuffers()) |confidence| {
            result.add(.{
                .name = "ping_pong_buffers",
                .description = "Ping-pong buffer pattern for GPU simulation",
                .confidence = confidence,
            });
        }

        // Detect compute simulation pattern
        if (self.detectComputeSimulation()) |confidence| {
            result.add(.{
                .name = "compute_simulation",
                .description = "Compute shader simulation with render output",
                .confidence = confidence,
            });
        }

        // Detect particle system pattern
        if (self.detectParticleSystem()) |confidence| {
            result.add(.{
                .name = "particle_system",
                .description = "Particle system with compute update and instanced rendering",
                .confidence = confidence,
            });
        }

        return result;
    }

    /// Detect fullscreen quad pattern.
    fn detectFullscreenQuad(self: *const Self) ?u8 {
        // Fullscreen quad: vertex_count=3 or 4 or 6, no vertex buffers
        // Check issues for W003 (vertex_count warnings would indicate fullscreen)
        // Also check if draw_count > 0 and no vertex buffers bound

        if (self.draw_count == 0) return null;

        // `observed`, not `bound_vertex_buffers`: the live slots are cleared by
        // the final SUBMIT, so reading them here classified every drawing
        // program — teapot and rotating_cube included — as a fullscreen quad.
        if (self.observed.vertex_buffer_binds == 0) {
            return 85; // High confidence
        }

        return null;
    }

    /// Detect instanced rendering pattern.
    fn detectInstancedRendering(self: *const Self) ?u8 {
        // Look for draws with instance_count > 1
        // Since we don't track actual draw params, look for specific conditions
        if (self.draw_count == 0) return null;

        // Check if there are STORAGE buffers (often used with instanced)
        var has_storage = false;
        var iter = self.buffers.iterator();
        while (iter.next()) |entry| {
            if ((entry.value_ptr.usage & BufferUsage.STORAGE) != 0) {
                has_storage = true;
                break;
            }
        }

        // Instanced often uses storage buffers for per-instance data
        if (has_storage and self.render_pipelines.count() > 0) {
            return 60; // Medium confidence
        }

        return null;
    }

    /// Detect ping-pong buffer pattern.
    fn detectPingPongBuffers(self: *const Self) ?u8 {
        // Ping-pong: two STORAGE buffers of same size. Samples the 8
        // LOWEST-ID storage buffers (ascending-id walk — deterministic, §260;
        // hash-order iteration made the sample, and thus the reported
        // confidence boost, build-dependent past 8 storage buffers).
        var storage_sizes: [8]u32 = undefined;
        var storage_count: u8 = 0;

        const max_id = maxKeyU16(&self.buffers) orelse return null;
        var id: u32 = 0;
        while (id <= max_id) : (id += 1) {
            const info = self.buffers.get(@intCast(id)) orelse continue;
            if ((info.usage & BufferUsage.STORAGE) != 0) {
                if (storage_count < 8) {
                    storage_sizes[storage_count] = info.size;
                    storage_count += 1;
                }
            }
        }

        // Need at least 2 storage buffers
        if (storage_count < 2) return null;

        // Check if any two buffers have the same size (ping-pong)
        for (0..storage_count) |i| {
            for ((i + 1)..storage_count) |j| {
                if (storage_sizes[i] == storage_sizes[j]) {
                    return 75; // Good confidence for matching sizes
                }
            }
        }

        return null;
    }

    /// Detect compute simulation pattern.
    fn detectComputeSimulation(self: *const Self) ?u8 {
        // Compute simulation: compute pipeline + render pipeline + dispatch
        if (self.compute_pipelines.count() == 0) return null;
        if (self.dispatch_count == 0) return null;

        // If we also have render pipeline, it's likely compute simulation
        if (self.render_pipelines.count() > 0 and self.draw_count > 0) {
            return 80; // High confidence
        }

        // Just compute with dispatch is medium confidence
        if (self.dispatch_count > 0) {
            return 50;
        }

        return null;
    }

    /// Detect particle system pattern.
    fn detectParticleSystem(self: *const Self) ?u8 {
        // Particle system combines:
        // - Compute pipeline for update
        // - Storage buffers (for particle data)
        // - Instanced rendering

        if (self.compute_pipelines.count() == 0) return null;
        if (self.dispatch_count == 0) return null;

        // Count storage + vertex buffers (particles often use both)
        var storage_vertex_count: u32 = 0;
        var iter = self.buffers.iterator();
        while (iter.next()) |entry| {
            const usage = entry.value_ptr.usage;
            if ((usage & BufferUsage.STORAGE) != 0 and (usage & BufferUsage.VERTEX) != 0) {
                storage_vertex_count += 1;
            }
        }

        if (storage_vertex_count > 0 and self.draw_count > 0) {
            return 75; // Good confidence
        }

        return null;
    }

    /// Helper: Check if any bind group is used.
    fn hasBindGroupUsage(self: *const Self) bool {
        // `observed`, not `bound_bind_groups`: this runs after the final SUBMIT
        // has cleared the live slots, so the live view is always empty here.
        return self.observed.bind_group_binds > 0;
    }

    /// Helper: Check if there's a uniform buffer.
    fn hasUniformBuffer(self: *const Self) bool {
        var iter = self.buffers.iterator();
        while (iter.next()) |entry| {
            if ((entry.value_ptr.usage & BufferUsage.UNIFORM) != 0) {
                return true;
            }
        }
        return false;
    }

    /// Draws the stream performs, counting a bundle replay as one.
    ///
    /// `draw_count` alone answers "how many draw commands are in this stream",
    /// which is the right number for the reported statistic but the wrong one
    /// for "does anything render": EXECUTE_BUNDLES replays draws recorded when
    /// the bundle was built, so they are not in this stream at all and their
    /// number is unknowable here. One is enough to answer the question, and
    /// answering it wrongly is what made `inspect examples/webgpu_render_bundles.sjon`
    /// report a pipeline that never draws (§337).
    ///
    /// Public because the distinction does not stop at this file: reaching past
    /// it to `validator.draw_count` is how `--symptom black` went on telling the
    /// author of a bundle-drawing program to "Add draw=N", at high probability,
    /// after §337 fixed every reader inside these braces.
    pub fn drawsPerformed(self: *const Self) u32 {
        return self.draw_count + self.observed.bundle_executions;
    }

    /// Helper: Check whether any command put bytes into a buffer.
    ///
    /// This returned a hardcoded `false` until §337, which made its one caller —
    /// "uniform buffer created but never written" — fire on every program that
    /// has a uniform buffer at all, including the ones writing it every frame.
    fn hasWriteBuffer(self: *const Self) bool {
        return self.observed.buffer_writes > 0;
    }

    // ========================================================================
    // Likely Causes Analysis (Feature 6)
    // ========================================================================

    /// A likely cause for a rendering issue with probability ranking.
    pub const LikelyCause = struct {
        name: []const u8,
        probability: u8, // 0-100, higher = more likely
        description: []const u8,
        category: Category,
        related_code: ?[]const u8 = null,

        pub const Category = enum {
            missing_resource,
            invalid_state,
            parameter_error,
            binding_error,
            shader_error,
            unknown,

            pub fn toString(self: Category) []const u8 {
                return switch (self) {
                    .missing_resource => "missing_resource",
                    .invalid_state => "invalid_state",
                    .parameter_error => "parameter_error",
                    .binding_error => "binding_error",
                    .shader_error => "shader_error",
                    .unknown => "unknown",
                };
            }
        };

        /// Write this cause as JSON to a writer.
        pub fn writeJson(self: LikelyCause, writer: anytype) !void {
            try writer.writeAll("{");
            try writer.writeAll("\"name\":\"");
            try writeJsonEscaped(writer, self.name);
            try writer.writeAll("\",\"probability\":");
            try writer.print("{d}", .{self.probability});
            try writer.writeAll(",\"description\":\"");
            try writeJsonEscaped(writer, self.description);
            try writer.writeAll("\",\"category\":\"");
            try writer.writeAll(self.category.toString());
            try writer.writeAll("\"");
            if (self.related_code) |code| {
                try writer.writeAll(",\"related_code\":\"");
                try writeJsonEscaped(writer, code);
                try writer.writeAll("\"");
            }
            try writer.writeAll("}");
        }

        /// Serialize to JSON string using allocator.
        pub fn toJsonAlloc(self: LikelyCause, allocator: std.mem.Allocator) ![]u8 {
            var aw: std.Io.Writer.Allocating = .init(allocator);
            errdefer aw.deinit();
            try self.writeJson(&aw.writer);
            return aw.toOwnedSlice();
        }
    };

    /// Result container for likely causes analysis.
    pub const LikelyCausesResult = struct {
        items: [16]LikelyCause = undefined,
        count: u8 = 0,

        pub fn add(self: *LikelyCausesResult, cause: LikelyCause) void {
            if (self.count < 16) {
                self.items[self.count] = cause;
                self.count += 1;
            }
        }

        pub fn slice(self: *const LikelyCausesResult) []const LikelyCause {
            return self.items[0..self.count];
        }

        /// Get causes sorted by probability (descending). Returns new sorted array.
        pub fn sortedByProbability(self: *const LikelyCausesResult) [16]LikelyCause {
            var sorted = self.items;
            // No sorting needed for 0 or 1 elements
            if (self.count <= 1) return sorted;
            // Simple insertion sort (small array, bounded)
            for (1..self.count) |i| {
                const key = sorted[i];
                var j: usize = i;
                while (j > 0 and sorted[j - 1].probability < key.probability) {
                    sorted[j] = sorted[j - 1];
                    j -= 1;
                }
                sorted[j] = key;
            }
            return sorted;
        }

        /// Get the number of top N causes by probability.
        /// Note: Use sortedByProbability() and take first n elements for actual sorted values.
        pub fn topNCount(self: *const LikelyCausesResult, n: u8) u8 {
            return @min(n, self.count);
        }

        /// Check if any cause has probability > threshold.
        pub fn hasHighProbability(self: *const LikelyCausesResult, threshold: u8) bool {
            for (self.slice()) |cause| {
                if (cause.probability >= threshold) return true;
            }
            return false;
        }

        /// Write all causes as a JSON array to a writer.
        /// Causes are sorted by probability (descending) before output.
        pub fn writeJson(self: *const LikelyCausesResult, writer: anytype) !void {
            try writer.writeAll("[");
            const sorted = self.sortedByProbability();
            for (sorted[0..self.count], 0..) |cause, i| {
                if (i > 0) try writer.writeAll(",");
                try cause.writeJson(writer);
            }
            try writer.writeAll("]");
        }

        /// Serialize to JSON string using allocator.
        /// Causes are sorted by probability (descending) before output.
        pub fn toJsonAlloc(self: *const LikelyCausesResult, allocator: std.mem.Allocator) ![]u8 {
            var aw: std.Io.Writer.Allocating = .init(allocator);
            errdefer aw.deinit();
            try self.writeJson(&aw.writer);
            return aw.toOwnedSlice();
        }
    };

    /// Analyze validation results and return likely causes with probabilities.
    ///
    /// Combines:
    /// - Validation errors/warnings
    /// - Missing operations detection
    /// - Pattern detection
    ///
    /// Returns ranked list of likely causes for rendering issues.
    ///
    /// Pre-condition: validate() has been called
    pub fn analyzeLikelyCauses(self: *const Self) LikelyCausesResult {
        var result = LikelyCausesResult{};

        // Analyze validation errors
        for (self.issues.items) |issue| {
            const cause = self.issueToCause(issue);
            if (cause) |c| {
                result.add(c);
            }
        }

        // Analyze missing operations
        const missing = self.detectMissingOperations();
        for (missing.slice()) |op| {
            const prob: u8 = if (op.severity == .err) 90 else 60;
            result.add(.{
                .name = op.operation,
                .probability = prob,
                .description = op.message,
                .category = .missing_resource,
                .related_code = op.context,
            });
        }

        // Boost probabilities based on detected patterns
        const patterns = self.detectPatterns();
        self.adjustProbabilitiesFromPatterns(&result, patterns);

        return result;
    }

    /// Static map from validation error code to its likely-cause metadata.
    /// `issueToCause` fills in the per-issue `description` (the issue's message).
    const CauseMapping = struct {
        code: []const u8,
        name: []const u8,
        probability: u8,
        category: LikelyCause.Category,
    };
    const cause_mappings = [_]CauseMapping{
        .{ .code = "E001", .name = "undefined_resource", .probability = 95, .category = .missing_resource },
        .{ .code = "E002", .name = "invalid_pass_state", .probability = 90, .category = .invalid_state },
        .{ .code = "E003", .name = "mismatched_pass_type", .probability = 85, .category = .invalid_state },
        .{ .code = "E004", .name = "memory_bounds_error", .probability = 95, .category = .parameter_error },
        .{ .code = "E005", .name = "duplicate_resource_id", .probability = 85, .category = .binding_error },
        .{ .code = "E006", .name = "invalid_resource_params", .probability = 80, .category = .parameter_error },
        .{ .code = "E007", .name = "exceeds_device_limits", .probability = 90, .category = .parameter_error },
        .{ .code = "E009", .name = "unresolvable_bind_group_layout", .probability = 95, .category = .missing_resource },
    };

    /// Convert a validation issue to a likely cause. Known error codes map through
    /// `cause_mappings`; unmatched warnings fall back to a low-probability entry.
    fn issueToCause(_: *const Self, issue: Issue) ?LikelyCause {
        for (cause_mappings) |m| {
            if (std.mem.eql(u8, issue.code, m.code)) {
                return .{
                    .name = m.name,
                    .probability = m.probability,
                    .description = issue.message,
                    .category = m.category,
                };
            }
        }

        // Warnings that don't match a known code still surface as a potential issue.
        if (issue.severity == .warning) {
            return .{
                .name = "potential_issue",
                .probability = 40,
                .description = issue.message,
                .category = .unknown,
            };
        }

        return null;
    }

    /// Adjust cause probabilities based on detected patterns.
    fn adjustProbabilitiesFromPatterns(
        self: *const Self,
        result: *LikelyCausesResult,
        patterns: PatternDetectionResult,
    ) void {
        _ = self;

        // If fullscreen quad detected, reduce probability of vertex buffer issues
        if (patterns.hasPattern("fullscreen_quad")) {
            for (0..result.count) |i| {
                if (std.mem.indexOf(u8, result.items[i].name, "vertex") != null) {
                    // Reduce probability - fullscreen quads don't need vertex buffers
                    if (result.items[i].probability > 30) {
                        result.items[i].probability -= 30;
                    } else {
                        result.items[i].probability = 0;
                    }
                }
            }
        }

        // If compute simulation detected, increase probability of compute-related issues
        if (patterns.hasPattern("compute_simulation")) {
            for (0..result.count) |i| {
                if (std.mem.indexOf(u8, result.items[i].name, "compute") != null or
                    std.mem.indexOf(u8, result.items[i].name, "dispatch") != null or
                    std.mem.indexOf(u8, result.items[i].name, "DISPATCH") != null)
                {
                    // Increase probability for compute issues
                    const boost: u8 = 15;
                    if (result.items[i].probability + boost <= 100) {
                        result.items[i].probability += boost;
                    } else {
                        result.items[i].probability = 100;
                    }
                }
            }
        }

        // If ping-pong detected, increase probability of buffer synchronization issues
        if (patterns.hasPattern("ping_pong_buffers")) {
            for (0..result.count) |i| {
                if (std.mem.indexOf(u8, result.items[i].name, "buffer") != null or
                    std.mem.indexOf(u8, result.items[i].name, "BUFFER") != null)
                {
                    // Increase probability for buffer issues
                    const boost: u8 = 10;
                    if (result.items[i].probability + boost <= 100) {
                        result.items[i].probability += boost;
                    } else {
                        result.items[i].probability = 100;
                    }
                }
            }
        }
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

        // Remember the layout reference; it is checked after the whole stream is
        // walked, not here — see checkBindGroupLayoutsResolve.
        try self.bind_group_layout_refs.append(self.allocator, .{
            .layout_id = params.layout_id,
            .command_index = self.command_index,
        });

        try self.bind_groups.put(self.allocator, params.id, .{ .created_at = self.command_index });
    }

    /// E009 — every `create_bind_group` must name a layout that exists in the id
    /// space its tag selects (opcodes.BIND_GROUP_LAYOUT_TAG). Both backends drop a
    /// bind group whose layout does not resolve, silently; the miss then surfaces
    /// far away as a blank frame or a draw-time complaint about an unset slot. This
    /// is the check that makes the class visible from a `.png` alone (§339).
    ///
    /// Deferred to end-of-stream ON PURPOSE. Nothing in the ABI orders creations,
    /// so a payload may legitimately create a bind group before the pipeline it
    /// names; checking inline would report that as an error, and a validator that
    /// makes false claims is worse than one that stays quiet (pitfall 56).
    fn checkBindGroupLayoutsResolve(self: *Self) !void {
        for (self.bind_group_layout_refs.items) |ref| {
            const id = opcodes.layoutIdValue(ref.layout_id);
            const tagged = opcodes.layoutIdIsBindGroupLayout(ref.layout_id);
            const resolves = if (tagged)
                self.bind_group_layouts.contains(id)
            else
                self.render_pipelines.contains(id) or self.compute_pipelines.contains(id);
            if (resolves) continue;
            self.command_index = ref.command_index;
            try self.addErrorWithId(
                "E009",
                if (tagged)
                    "CREATE_BIND_GROUP names a bind-group-layout that is never created"
                else
                    "CREATE_BIND_GROUP names a pipeline that is never created",
                id,
            );
        }
    }

    fn validateCreateTextureView(self: *Self, params: CreateTextureViewParams) !void {
        if (self.texture_views.contains(params.id)) {
            try self.addErrorWithId("E005", "Texture view ID already in use", params.id);
            return;
        }
        // Check that texture exists (unless it's a special texture: canvas or "no depth")
        const is_special_texture = params.texture_id == CANVAS_TEXTURE_ID or
            params.texture_id == NO_DEPTH_TEXTURE_ID;
        if (!is_special_texture and !self.textures.contains(params.texture_id)) {
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
        try self.beginRenderPassState("BEGIN_RENDER_PASS inside active pass - nested passes not allowed");
    }

    /// Open a render pass. Shared by the single-attachment and MRT forms: the
    /// pass-state machine cares only that a render pass is now open, not how
    /// many colour attachments it has.
    fn beginRenderPassState(self: *Self, nested_message: []const u8) !void {
        if (self.pass_state != .none) {
            try self.addError("E008", nested_message);
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
        self.observed.bind_group_binds += 1;
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

        self.observed.vertex_buffer_binds += 1;
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

    /// DRAW_INDIRECT / DRAW_INDEXED_INDIRECT: same checks as a direct draw,
    /// plus the argument buffer must exist and carry INDIRECT usage.
    ///
    /// The vertex/instance counts live in that buffer and may be produced by a
    /// compute pass on the GPU, so the "nothing will render" count checks a
    /// direct draw performs have no counterpart here.
    fn validateIndirectDraw(self: *Self, cmd: Cmd, params: IndirectParams) !void {
        std.debug.assert(cmd == .draw_indirect or cmd == .draw_indexed_indirect);
        // A draw_indirect is a draw call, so it belongs in the reported
        // statistic as well as in the analysis tallies. Before §337 neither saw
        // it, and `inspect examples/webgpu_indirect_draw.sjon` led with "render
        // pipeline created but no DRAW command - nothing will render".
        self.draw_count += 1;
        self.observed.indirect_draws += 1;

        if (self.pass_state != .render) {
            try self.addError("E002", "DRAW_INDIRECT outside render pass");
            return;
        }
        if (self.current_pipeline == null) {
            try self.addError("E002", "DRAW_INDIRECT without SET_PIPELINE");
        }
        try self.checkIndirectBuffer("DRAW_INDIRECT", params.id);
    }

    /// DISPATCH_INDIRECT: the compute-pass counterpart of `validateIndirectDraw`.
    fn validateIndirectDispatch(self: *Self, params: IndirectParams) !void {
        self.dispatch_count += 1;
        self.observed.indirect_dispatches += 1;

        if (self.pass_state != .compute) {
            try self.addError("E002", "DISPATCH_INDIRECT outside compute pass");
            return;
        }
        if (self.current_pipeline == null) {
            try self.addError("E002", "DISPATCH_INDIRECT without SET_PIPELINE");
        }
        try self.checkIndirectBuffer("DISPATCH_INDIRECT", params.id);
    }

    /// The argument buffer behind an indirect draw or dispatch.
    fn checkIndirectBuffer(self: *Self, comptime what: []const u8, id: u16) !void {
        const info = self.buffers.get(id) orelse {
            try self.addErrorWithId("E001", what ++ " references non-existent buffer", id);
            return;
        };
        if ((info.usage & BufferUsage.INDIRECT) == 0) {
            try self.addErrorWithId("E006", what ++ " buffer missing INDIRECT usage flag", id);
        }
    }

    /// EXECUTE_BUNDLES replays a render bundle recorded at build time.
    ///
    /// Non-goal: checking the bundle ids. They are variable-length operands this
    /// parser does not decode, and a dangling bundle reference cannot reach here
    /// through the supported path — the SJON validator rejects it at compile
    /// time (`examples/invalid/bundle_ref_lowered.sjon`).
    fn validateExecuteBundles(self: *Self) !void {
        self.observed.bundle_executions += 1;
        if (self.pass_state != .render) {
            try self.addError("E002", "EXECUTE_BUNDLES outside render pass");
        }
    }

    /// Commands that encode into an open render pass.
    ///
    /// Non-goal: the operands. Viewport rects, blend constants and stencil
    /// references are floats and ints with no cross-references to resolve, so
    /// there is nothing here for a *reference* validator to check. What was
    /// actually missing was the pass state, which is this validator's own state
    /// machine.
    fn validateInPass(self: *Self, comptime what: []const u8) !void {
        switch (self.pass_state) {
            .none => try self.addError("E002", what ++ " outside any pass"),
            .compute => try self.addError("E002", what ++ " in a compute pass - it is a render-pass command"),
            .render => {},
        }
    }

    /// Commands that configure the *next* pass rather than the open one.
    ///
    /// The `SET_PASS_*` family is pre-pass state: the backend stores it as
    /// `pending_*` and consumes it at the following BEGIN_RENDER_PASS (see
    /// `wgpu_native_gpu.zig`). Issuing one while a pass is open is therefore not
    /// an error — it silently applies to a *later* pass than the author meant,
    /// which is worth a warning and nothing stronger.
    ///
    /// This distinction is the reason the first version of these checks was
    /// wrong: the names read as "set state on the pass", and 21 of the 120
    /// corpus fixtures failed before the shared `SET_PASS_*` prefix was traced
    /// to `pending_*` (§337).
    fn validatePrePass(self: *Self, comptime what: []const u8) !void {
        if (self.pass_state != .none) {
            try self.addWarning("W010", what ++ " inside an open pass - it configures the next pass, not this one");
        }
    }

    fn validateDraw(self: *Self, params: DrawParams) !void {
        // Always increment draw count - the draw was attempted even if it fails validation
        self.draw_count += 1;

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
    }

    fn validateDrawIndexed(self: *Self, params: DrawIndexedParams) !void {
        // Always increment draw count - the draw was attempted even if it fails validation
        self.draw_count += 1;

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
    }

    fn validateDispatch(self: *Self, params: DispatchParams) !void {
        // Always increment dispatch count - the dispatch was attempted even if it fails validation
        self.dispatch_count += 1;

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

        // E007: Workgroup count exceeds WebGPU limits
        // WebGPU maxComputeWorkgroupsPerDimension = 65535
        const max_workgroups: u32 = 65535;
        if (params.x > max_workgroups) {
            try self.addError("E007", "DISPATCH workgroupCountX exceeds max (65535)");
        }
        if (params.y > max_workgroups) {
            try self.addError("E007", "DISPATCH workgroupCountY exceeds max (65535)");
        }
        if (params.z > max_workgroups) {
            try self.addError("E007", "DISPATCH workgroupCountZ exceeds max (65535)");
        }
    }

    // ========================================================================
    // Queue Operation Validators
    // ========================================================================

    fn validateWriteBuffer(self: *Self, params: WriteBufferParams) !void {
        self.observed.buffer_writes += 1;
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

        // W009: Warn if writing to a buffer with uniform fields
        // Bytecode writes may conflict with setUniform() API calls
        if (self.uniform_buffer_ids.contains(params.id)) {
            try self.addWarningWithContext(
                "W009",
                "WRITE_BUFFER targets buffer with uniform fields - may conflict with setUniform() API",
                params.id,
            );
        }
    }

    fn validateWriteTimeUniform(self: *Self, params: WriteTimeUniformParams) !void {
        self.observed.buffer_writes += 1;
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
        self.observed.buffer_writes += 1; // the destination receives bytes
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
        // Special texture IDs (canvas, no-depth) don't need to be tracked
        const src_is_special = params.src_id == CANVAS_TEXTURE_ID or params.src_id == NO_DEPTH_TEXTURE_ID;
        const dst_is_special = params.dst_id == CANVAS_TEXTURE_ID or params.dst_id == NO_DEPTH_TEXTURE_ID;

        if (!src_is_special and !self.textures.contains(params.src_id)) {
            try self.addErrorWithId("E001", "COPY_TEXTURE_TO_TEXTURE references non-existent source texture", params.src_id);
        }
        if (!dst_is_special and !self.textures.contains(params.dst_id)) {
            try self.addErrorWithId("E001", "COPY_TEXTURE_TO_TEXTURE references non-existent destination texture", params.dst_id);
        }
    }

    fn validateWriteBufferFromWasm(self: *Self, params: WriteBufferFromWasmParams) !void {
        self.observed.buffer_writes += 1;
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

        // W009: Warn if writing to a buffer with uniform fields
        // Bytecode writes may conflict with setUniform() API calls
        if (self.uniform_buffer_ids.contains(params.buffer_id)) {
            try self.addWarningWithContext(
                "W009",
                "WRITE_BUFFER_FROM_WASM targets buffer with uniform fields - may conflict with setUniform() API",
                params.buffer_id,
            );
        }
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

        // E004: Validate function name pointer bounds. The arguments are carried
        // inline in the command buffer, so there is no second pointer to check —
        // this used to bounds-check `args_ptr`, a field the wire format has not
        // had since args went inline, so it was validating operand bytes.
        _ = try self.validateMemoryBounds(
            params.func_ptr,
            params.func_len,
            "CALL_WASM_FUNC func_ptr + func_len exceeds WASM memory",
        );
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

    fn addWarningWithContext(self: *Self, code: []const u8, message: []const u8, resource_id: u16) !void {
        try self.issues.append(self.allocator, .{
            .code = code,
            .severity = .warning,
            .message = message,
            .command_index = self.command_index,
            .resource_id = resource_id,
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
