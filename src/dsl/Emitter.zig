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

    /// Emit options.
    pub const Options = struct {
        /// Base directory for resolving relative file paths.
        base_dir: ?[]const u8 = null,
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
            .wasm_data_entries = .{},
            .generated_arrays = .{},
            .buffer_pools = .{},
            .bind_group_pools = .{},
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
        self.wasm_data_entries.deinit(self.gpa);
        self.generated_arrays.deinit(self.gpa);
        self.buffer_pools.deinit(self.gpa);
        self.bind_group_pools.deinit(self.gpa);
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
        errdefer self.deinit();

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

        // Finalize and return PNGB bytes
        const result = try self.builder.finalize(gpa);
        errdefer gpa.free(result);

        // Clean up all resources
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
        self.wasm_data_entries.deinit(self.gpa);
        self.generated_arrays.deinit(self.gpa);
        self.buffer_pools.deinit(self.gpa);
        self.bind_group_pools.deinit(self.gpa);

        return result;
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
};
