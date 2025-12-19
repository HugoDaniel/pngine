//! DSL to PNGB Emitter
//!
//! Transforms analyzed DSL AST to PNGB bytecode format.
//! Uses the existing bytecode Builder for output generation.
//!
//! ## Emission Order
//!
//! Resources are emitted in dependency order:
//! 1. Shaders (#wgsl, #shaderModule)
//! 2. Buffers (#buffer)
//! 3. Textures (#texture)
//! 4. Samplers (#sampler)
//! 5. Pipelines (#renderPipeline, #computePipeline)
//! 6. Bind Groups (#bindGroup)
//! 7. Passes (#renderPass, #computePass)
//! 8. Frames (#frame)
//!
//! ## Design
//!
//! - **ID tracking**: Separate hashmaps map names to resource IDs
//! - **Reference resolution**: Lookups use analyzer's symbol tables
//! - **Data deduplication**: Shader content uses analyzer's hash-based dedup
//!
//! ## Invariants
//!
//! - All symbols must be resolved before emission (no analysis errors)
//! - Resource IDs are assigned sequentially in declaration order
//! - Shader content is added to data section before shader module creation
//! - Frame names are interned in string table
//! - Output is always valid PNGB (header + sections)
//!
//! ## Complexity
//!
//! - `emit()`: O(symbols + bytecode_size)
//! - Memory: O(bytecode + data + strings)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig").Ast;
const Node = @import("Ast.zig").Node;
const Analyzer = @import("Analyzer.zig").Analyzer;
const format = @import("../bytecode/format.zig");
const opcodes = @import("../bytecode/opcodes.zig");
const DescriptorEncoder = @import("DescriptorEncoder.zig").DescriptorEncoder;
const utils = @import("emitter/utils.zig");
const shaders = @import("emitter/shaders.zig");
const resources = @import("emitter/resources.zig");
const pipelines = @import("emitter/pipelines.zig");
const passes = @import("emitter/passes.zig");
const frames = @import("emitter/frames.zig");
const wasm = @import("emitter/wasm.zig");
const animations = @import("emitter/animations.zig");
const reflect = @import("../reflect.zig");

pub const Emitter = struct {
    gpa: Allocator,
    ast: *const Ast,
    analysis: *const Analyzer.AnalysisResult,
    builder: format.Builder,
    options: Options,

    // Resource ID tracking
    buffer_ids: std.StringHashMapUnmanaged(u16),
    texture_ids: std.StringHashMapUnmanaged(u16),
    sampler_ids: std.StringHashMapUnmanaged(u16),
    shader_ids: std.StringHashMapUnmanaged(u16),
    pipeline_ids: std.StringHashMapUnmanaged(u16),
    bind_group_ids: std.StringHashMapUnmanaged(u16),
    pass_ids: std.StringHashMapUnmanaged(u16),
    frame_ids: std.StringHashMapUnmanaged(u16),
    queue_ids: std.StringHashMapUnmanaged(u16),
    data_ids: std.StringHashMapUnmanaged(u16),
    image_bitmap_ids: std.StringHashMapUnmanaged(u16),
    wasm_module_ids: std.StringHashMapUnmanaged(u16),
    wasm_call_ids: std.StringHashMapUnmanaged(u16),
    bind_group_layout_ids: std.StringHashMapUnmanaged(u16),
    pipeline_layout_ids: std.StringHashMapUnmanaged(u16),
    query_set_ids: std.StringHashMapUnmanaged(u16),
    texture_view_ids: std.StringHashMapUnmanaged(u16),
    animation_ids: std.StringHashMapUnmanaged(u16),

    /// Animation metadata extracted from #animation macro.
    /// This data is serialized separately (pNGm chunk) rather than bytecode.
    animation_metadata: ?AnimationMetadata = null,

    /// WASM data entries for #data with wasm={...} property.
    /// These are initialized at runtime by calling WASM functions.
    wasm_data_entries: std.StringHashMapUnmanaged(WasmDataEntry),

    /// Generated arrays for runtime data generation.
    /// Used when float32Array={numberOfElements=N initEachElementWith=[...]}.
    generated_arrays: std.StringHashMapUnmanaged(resources.GeneratedArrayInfo),

    /// Buffer pool info for ping-pong buffers.
    /// Maps buffer name -> PoolInfo (base_id, pool_size).
    buffer_pools: std.StringHashMapUnmanaged(resources.PoolInfo),

    /// Bind group pool info for ping-pong bind groups.
    bind_group_pools: std.StringHashMapUnmanaged(resources.PoolInfo),

    /// Cached WGSL reflection data for auto buffer sizing.
    /// Maps shader name -> reflection data.
    wgsl_reflections: std.StringHashMapUnmanaged(reflect.ReflectionData),

    /// Cache for resolved WGSL code (with imports prepended).
    /// Key is the #wgsl macro name, value is the resolved code.
    /// Moved from module-level to struct for thread safety and testability.
    resolved_wgsl_cache: std.StringHashMapUnmanaged([]const u8),

    // Counters for generating IDs
    next_buffer_id: u16 = 0,
    next_texture_id: u16 = 0,
    next_sampler_id: u16 = 0,
    next_shader_id: u16 = 0,
    next_pipeline_id: u16 = 0,
    next_bind_group_id: u16 = 0,
    next_pass_id: u16 = 0,
    next_frame_id: u16 = 0,
    next_queue_id: u16 = 0,
    next_image_bitmap_id: u16 = 0,
    next_wasm_module_id: u16 = 0,
    next_wasm_call_id: u16 = 0,
    next_data_id: u16 = 0,
    next_bind_group_layout_id: u16 = 0,
    next_pipeline_layout_id: u16 = 0,
    next_query_set_id: u16 = 0,
    next_texture_view_id: u16 = 0,
    next_animation_id: u16 = 0,

    const Self = @This();

    /// WASM data entry for runtime-generated data.
    /// Used by #data with wasm={...} property.
    pub const WasmDataEntry = struct {
        /// WASM module ID (from wasm_module_ids).
        module_id: u16,
        /// Data section ID containing the WASM bytes.
        wasm_data_id: u16,
        /// Interned function name ID.
        func_name_id: u16,
        /// Byte size of the return value.
        byte_size: u32,
    };

    /// Animation metadata extracted from #animation macro.
    /// Serialized to pNGm chunk for JS runtime consumption.
    pub const AnimationMetadata = struct {
        /// Animation name.
        name: []const u8,
        /// Total duration in seconds.
        duration: f64,
        /// Whether animation loops.
        loop: bool,
        /// Behavior when animation ends: hold, stop, restart.
        end_behavior: EndBehavior,
        /// Ordered list of scenes in the timeline.
        scenes: []const Scene,

        pub const EndBehavior = enum {
            hold, // Keep last frame
            stop, // Clear/stop
            restart, // Loop back to start
        };

        pub const Scene = struct {
            /// Scene identifier (used in draw options).
            id: []const u8,
            /// Frame name reference (from #frame).
            frame_name: []const u8,
            /// Start time in seconds.
            start: f64,
            /// End time in seconds.
            end: f64,
        };

        /// Serialize to JSON for pNGm chunk.
        pub fn toJson(self: *const AnimationMetadata, allocator: std.mem.Allocator) ![]u8 {
            var buffer = std.ArrayListUnmanaged(u8){};
            errdefer buffer.deinit(allocator);

            try buffer.appendSlice(allocator, "{\"animation\":{");

            // Name
            try buffer.appendSlice(allocator, "\"name\":\"");
            try buffer.appendSlice(allocator, self.name);
            try buffer.appendSlice(allocator, "\",");

            // Duration
            try buffer.appendSlice(allocator, "\"duration\":");
            var dur_buf: [32]u8 = undefined;
            const dur_slice = std.fmt.bufPrint(&dur_buf, "{d}", .{self.duration}) catch "0";
            try buffer.appendSlice(allocator, dur_slice);
            try buffer.appendSlice(allocator, ",");

            // Loop
            try buffer.appendSlice(allocator, "\"loop\":");
            try buffer.appendSlice(allocator, if (self.loop) "true" else "false");
            try buffer.appendSlice(allocator, ",");

            // End behavior
            try buffer.appendSlice(allocator, "\"endBehavior\":\"");
            try buffer.appendSlice(allocator, switch (self.end_behavior) {
                .hold => "hold",
                .stop => "stop",
                .restart => "restart",
            });
            try buffer.appendSlice(allocator, "\",");

            // Scenes array
            try buffer.appendSlice(allocator, "\"scenes\":[");
            for (self.scenes, 0..) |scene, i| {
                if (i > 0) try buffer.append(allocator, ',');
                try buffer.appendSlice(allocator, "{\"id\":\"");
                try buffer.appendSlice(allocator, scene.id);
                try buffer.appendSlice(allocator, "\",\"frame\":\"");
                try buffer.appendSlice(allocator, scene.frame_name);
                try buffer.appendSlice(allocator, "\",\"start\":");
                var start_buf: [32]u8 = undefined;
                const start_slice = std.fmt.bufPrint(&start_buf, "{d}", .{scene.start}) catch "0";
                try buffer.appendSlice(allocator, start_slice);
                try buffer.appendSlice(allocator, ",\"end\":");
                var end_buf: [32]u8 = undefined;
                const end_slice = std.fmt.bufPrint(&end_buf, "{d}", .{scene.end}) catch "0";
                try buffer.appendSlice(allocator, end_slice);
                try buffer.append(allocator, '}');
            }
            try buffer.appendSlice(allocator, "]}}");

            return buffer.toOwnedSlice(allocator);
        }
    };

    /// Emit options.
    pub const Options = struct {
        /// Base directory for resolving relative file paths.
        base_dir: ?[]const u8 = null,
        /// Path to miniray binary for WGSL reflection.
        /// If null, uses "miniray" from PATH.
        miniray_path: ?[]const u8 = null,
    };

    pub const Error = error{
        OutOfMemory,
        EmitError,
        DataSectionOverflow,
        TooManyDataEntries,
        StringTableOverflow,
        FileReadError,
    };

    /// Re-export Reference from utils for backward compatibility.
    pub const Reference = utils.Reference;

    pub fn init(gpa: Allocator, ast: *const Ast, analysis: *const Analyzer.AnalysisResult, options: Options) Self {
        return .{
            .gpa = gpa,
            .ast = ast,
            .analysis = analysis,
            .builder = format.Builder.init(),
            .options = options,
            .buffer_ids = .{},
            .texture_ids = .{},
            .sampler_ids = .{},
            .shader_ids = .{},
            .pipeline_ids = .{},
            .bind_group_ids = .{},
            .pass_ids = .{},
            .frame_ids = .{},
            .queue_ids = .{},
            .data_ids = .{},
            .image_bitmap_ids = .{},
            .wasm_module_ids = .{},
            .wasm_call_ids = .{},
            .bind_group_layout_ids = .{},
            .pipeline_layout_ids = .{},
            .query_set_ids = .{},
            .texture_view_ids = .{},
            .animation_ids = .{},
            .wasm_data_entries = .{},
            .generated_arrays = .{},
            .buffer_pools = .{},
            .bind_group_pools = .{},
            .wgsl_reflections = .{},
            .resolved_wgsl_cache = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.builder.deinit(self.gpa);
        self.buffer_ids.deinit(self.gpa);
        self.texture_ids.deinit(self.gpa);
        self.sampler_ids.deinit(self.gpa);
        self.shader_ids.deinit(self.gpa);
        self.pipeline_ids.deinit(self.gpa);
        self.bind_group_ids.deinit(self.gpa);
        self.pass_ids.deinit(self.gpa);
        self.frame_ids.deinit(self.gpa);
        self.queue_ids.deinit(self.gpa);
        self.data_ids.deinit(self.gpa);
        self.image_bitmap_ids.deinit(self.gpa);
        self.wasm_module_ids.deinit(self.gpa);
        self.wasm_call_ids.deinit(self.gpa);
        self.bind_group_layout_ids.deinit(self.gpa);
        self.pipeline_layout_ids.deinit(self.gpa);
        self.query_set_ids.deinit(self.gpa);
        self.texture_view_ids.deinit(self.gpa);
        self.animation_ids.deinit(self.gpa);
        self.wasm_data_entries.deinit(self.gpa);
        self.generated_arrays.deinit(self.gpa);
        self.buffer_pools.deinit(self.gpa);
        self.bind_group_pools.deinit(self.gpa);
        // Free all cached reflection data
        var it = self.wgsl_reflections.iterator();
        while (it.next()) |entry| {
            var ref_data = entry.value_ptr.*;
            ref_data.deinit();
        }
        self.wgsl_reflections.deinit(self.gpa);
        // Free resolved WGSL cache
        var wgsl_it = self.resolved_wgsl_cache.valueIterator();
        while (wgsl_it.next()) |value_ptr| {
            self.gpa.free(value_ptr.*);
        }
        self.resolved_wgsl_cache.deinit(self.gpa);
        // Free animation metadata scenes array
        if (self.animation_metadata) |meta| {
            if (meta.scenes.len > 0) {
                self.gpa.free(meta.scenes);
            }
        }
    }

    /// Emit PNGB bytecode from analyzed DSL.
    pub fn emit(gpa: Allocator, ast: *const Ast, analysis: *const Analyzer.AnalysisResult) Error![]u8 {
        return emitWithOptions(gpa, ast, analysis, .{});
    }

    /// Emit PNGB bytecode from analyzed DSL with options.
    pub fn emitWithOptions(gpa: Allocator, ast: *const Ast, analysis: *const Analyzer.AnalysisResult, options: Options) Error![]u8 {
        // Pre-conditions
        std.debug.assert(ast.nodes.len > 0);
        std.debug.assert(!analysis.hasErrors());

        var self = Self.init(gpa, ast, analysis, options);
        defer self.deinit();

        // Pass 1: Emit resource declarations in dependency order
        try resources.emitData(&self);
        try resources.emitImageBitmaps(&self);
        try wasm.emitWasmCalls(&self);
        try shaders.emitShaders(&self);
        try resources.emitBuffers(&self);
        try resources.emitTextures(&self);
        try resources.emitTextureViews(&self);
        try resources.emitSamplers(&self);
        try resources.emitQuerySets(&self);
        try resources.emitBindGroupLayouts(&self);
        try resources.emitPipelineLayouts(&self);
        try pipelines.emitPipelines(&self);
        try resources.emitBindGroups(&self);

        // Pass 2: Collect queues (no bytecode emitted, just ID tracking)
        try frames.collectQueues(&self);

        // Pass 3: Emit passes
        try passes.emitPasses(&self);

        // Pass 4: Emit frames (queues inlined via emitQueueAction)
        try frames.emitFrames(&self);

        // Pass 5: Extract animation metadata (stored for pNGm, not bytecode)
        try animations.extractAnimations(&self);

        // Finalize and return PNGB bytes
        // Note: finalize() transfers ownership of bytecode to caller,
        // deinit() in defer will clean up remaining resources
        return try self.builder.finalize(gpa);
    }

    // ========================================================================
    // Re-exported utilities for backward compatibility
    // ========================================================================

    /// Find property value in a macro node (delegated to utils).
    pub fn findPropertyValue(self: *Self, macro_node: Node.Index, prop_name: []const u8) ?Node.Index {
        return utils.findPropertyValue(self, macro_node, prop_name);
    }

    /// Find property value inside an object node (delegated to utils).
    pub fn findPropertyValueInObject(self: *Self, object_node: Node.Index, prop_name: []const u8) ?Node.Index {
        return utils.findPropertyValueInObject(self, object_node, prop_name);
    }

    /// Get token slice (delegated to utils).
    pub fn getTokenSlice(self: *Self, token_index: u32) []const u8 {
        return utils.getTokenSlice(self, token_index);
    }

    /// Get node text (delegated to utils).
    pub fn getNodeText(self: *Self, node: Node.Index) []const u8 {
        return utils.getNodeText(self, node);
    }

    /// Get string content from a string_value node (delegated to utils).
    pub fn getStringContent(self: *Self, value_node: Node.Index) []const u8 {
        return utils.getStringContent(self, value_node);
    }

    /// Parse a number_value node as u32 (delegated to utils).
    pub fn parseNumber(self: *Self, value_node: Node.Index) ?u32 {
        return utils.parseNumber(self, value_node);
    }

    /// Parse a number_value node as f64 (delegated to utils).
    pub fn parseFloatNumber(self: *Self, value_node: Node.Index) ?f64 {
        return utils.parseFloatNumber(self, value_node);
    }

    /// Resolve a node to its numeric u32 value (delegated to utils).
    pub fn resolveNumericValue(self: *Self, value_node: Node.Index) ?u32 {
        return utils.resolveNumericValue(self, value_node);
    }

    /// Resolve numeric value including string expressions (delegated to utils).
    pub fn resolveNumericValueOrString(self: *Self, value_node: Node.Index) ?u32 {
        return utils.resolveNumericValueOrString(self, value_node);
    }

    /// Get reference from a node (delegated to utils).
    pub fn getReference(self: *Self, node: Node.Index) ?Reference {
        return utils.getReference(self, node);
    }

    /// Parse buffer usage flags (delegated to utils).
    pub fn parseBufferUsage(self: *Self, node: Node.Index) opcodes.BufferUsage {
        return utils.parseBufferUsage(self, node);
    }

    /// Parse a bind group entry (delegated to utils).
    pub fn parseBindGroupEntry(self: *Self, entry_node: Node.Index) ?DescriptorEncoder.BindGroupEntry {
        return utils.parseBindGroupEntry(self, entry_node);
    }

    /// Resolve bind group layout to pipeline ID (delegated to utils).
    pub fn resolveBindGroupLayoutId(self: *Self, node: Node.Index) u16 {
        return utils.resolveBindGroupLayoutId(self, node);
    }

    /// Get bind group index (delegated to utils).
    pub fn getBindGroupIndex(self: *Self, node: Node.Index) u8 {
        return utils.getBindGroupIndex(self, node);
    }

    // ========================================================================
    // WGSL Reflection
    // ========================================================================

    /// Get WGSL reflection data for a shader.
    /// Caches results so reflection is only performed once per shader.
    ///
    /// Complexity: O(1) cache lookup, O(n) on first call (miniray subprocess).
    pub fn getWgslReflection(self: *Self, shader_name: []const u8) ?*const reflect.ReflectionData {
        // Pre-condition: shader_name is not empty
        std.debug.assert(shader_name.len > 0);

        // Check cache first
        if (self.wgsl_reflections.getPtr(shader_name)) |cached| {
            return cached;
        }

        // Get shader code from symbol table
        const shader_info = self.analysis.symbols.wgsl.get(shader_name) orelse
            self.analysis.symbols.shader_module.get(shader_name) orelse
            return null;

        // Get the WGSL code
        const code_node = utils.findPropertyValue(self, shader_info.node, "value") orelse
            utils.findPropertyValue(self, shader_info.node, "code") orelse
            return null;

        const wgsl_code = utils.getStringContent(self, code_node);
        if (wgsl_code.len == 0) return null;

        // Call miniray for reflection
        const miniray = reflect.Miniray{ .miniray_path = self.options.miniray_path };
        const reflection = miniray.reflect(self.gpa, wgsl_code) catch |err| {
            std.log.warn("WGSL reflection failed for '{s}': {}", .{ shader_name, err });
            return null;
        };

        // Cache the result
        self.wgsl_reflections.put(self.gpa, shader_name, reflection) catch {
            var ref_copy = reflection;
            ref_copy.deinit();
            return null;
        };

        return self.wgsl_reflections.getPtr(shader_name);
    }

    /// Get binding size from WGSL reflection.
    /// Reference format: "shaderName.bindingName" (e.g., "code.inputs")
    ///
    /// Complexity: O(bindings) where bindings = number of @binding declarations.
    pub fn getBindingSizeFromWgsl(self: *Self, wgsl_ref: []const u8) ?u32 {
        // Pre-condition: wgsl_ref is not empty and contains at least one dot
        std.debug.assert(wgsl_ref.len > 0);

        // Parse "shaderName.bindingName"
        const dot_pos = std.mem.indexOf(u8, wgsl_ref, ".") orelse return null;
        if (dot_pos == 0 or dot_pos >= wgsl_ref.len - 1) return null;

        const shader_name = wgsl_ref[0..dot_pos];
        const binding_name = wgsl_ref[dot_pos + 1 ..];

        // Post-condition: both parts are non-empty
        std.debug.assert(shader_name.len > 0);
        std.debug.assert(binding_name.len > 0);

        // Get reflection data
        const reflection = self.getWgslReflection(shader_name) orelse return null;

        // Find the binding by name
        const binding = reflection.getBindingByName(binding_name) orelse return null;

        // Post-condition: size is always positive for valid bindings
        std.debug.assert(binding.layout.size > 0);

        return binding.layout.size;
    }
};
