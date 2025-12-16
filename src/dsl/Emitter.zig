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

pub const Emitter = struct {
    gpa: Allocator,
    ast: *const Ast,
    analysis: *const Analyzer.AnalysisResult,
    builder: format.Builder,

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

    const Self = @This();

    pub const Error = error{
        OutOfMemory,
        EmitError,
        DataSectionOverflow,
        TooManyDataEntries,
        StringTableOverflow,
    };

    pub const Reference = struct {
        namespace: []const u8,
        name: []const u8,
    };

    pub fn init(gpa: Allocator, ast: *const Ast, analysis: *const Analyzer.AnalysisResult) Self {
        return .{
            .gpa = gpa,
            .ast = ast,
            .analysis = analysis,
            .builder = format.Builder.init(),
            .buffer_ids = .{},
            .texture_ids = .{},
            .sampler_ids = .{},
            .shader_ids = .{},
            .pipeline_ids = .{},
            .bind_group_ids = .{},
            .pass_ids = .{},
            .frame_ids = .{},
            .queue_ids = .{},
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
    }

    /// Emit PNGB bytecode from analyzed DSL.
    pub fn emit(gpa: Allocator, ast: *const Ast, analysis: *const Analyzer.AnalysisResult) Error![]u8 {
        // Pre-conditions
        std.debug.assert(ast.nodes.len > 0);
        std.debug.assert(!analysis.hasErrors());

        var self = Self.init(gpa, ast, analysis);
        errdefer self.deinit();

        // Pass 1: Emit resource declarations in dependency order
        try self.emitShaders();
        try self.emitBuffers();
        try self.emitTextures();
        try self.emitSamplers();
        try self.emitPipelines();
        try self.emitBindGroups();

        // Pass 2: Collect queues (no bytecode emitted, just ID tracking)
        try self.collectQueues();

        // Pass 3: Emit passes
        try self.emitPasses();

        // Pass 4: Emit frames (queues inlined via emitQueueAction)
        try self.emitFrames();

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

        return result;
    }

    // ========================================================================
    // Resource Emission
    // ========================================================================

    /// Substitute #define values into shader code.
    /// Replaces occurrences of define names with their values.
    /// Memory: Caller owns returned slice if different from input.
    fn substituteDefines(self: *Self, code: []const u8) Error![]const u8 {
        // Pre-conditions
        std.debug.assert(code.len > 0);

        // If no defines, return original code
        if (self.analysis.symbols.define.count() == 0) {
            return code;
        }

        // Build substituted code
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.gpa);

        var pos: usize = 0;
        while (pos < code.len) {
            var found_match = false;

            // Check each define for a match at current position
            var def_it = self.analysis.symbols.define.iterator();
            while (def_it.next()) |def_entry| {
                const def_name = def_entry.key_ptr.*;
                const def_info = def_entry.value_ptr.*;

                // Check if define name matches at current position
                if (pos + def_name.len <= code.len and
                    std.mem.eql(u8, code[pos..][0..def_name.len], def_name))
                {
                    // Ensure it's a whole word (not part of larger identifier)
                    const before_ok = pos == 0 or !isIdentChar(code[pos - 1]);
                    const after_ok = pos + def_name.len >= code.len or
                        !isIdentChar(code[pos + def_name.len]);

                    if (before_ok and after_ok) {
                        // Get define value
                        const value_str = self.getDefineValue(def_info.node);
                        try result.appendSlice(self.gpa, value_str);
                        pos += def_name.len;
                        found_match = true;
                        break;
                    }
                }
            }

            if (!found_match) {
                try result.append(self.gpa, code[pos]);
                pos += 1;
            }
        }

        // Post-condition: result has content
        std.debug.assert(result.items.len > 0);

        return try result.toOwnedSlice(self.gpa);
    }

    fn isIdentChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
    }

    /// Get the string value of a #define.
    /// For string values, returns the content without quotes.
    /// For other values (numbers, expressions), returns the source text.
    fn getDefineValue(self: *Self, define_node: Node.Index) []const u8 {
        // Pre-condition
        std.debug.assert(define_node.toInt() < self.ast.nodes.len);

        // Define node's data.node is the value node
        const value_node = self.ast.nodes.items(.data)[define_node.toInt()].node;
        const value_tag = self.ast.nodes.items(.tag)[value_node.toInt()];

        // For strings, return the content (without quotes)
        // For everything else (numbers, expressions), return source text as-is
        return if (value_tag == .string_value)
            self.getStringContent(value_node)
        else
            self.getNodeText(value_node);
    }

    fn emitShaders(self: *Self) Error!void {
        // Emit #wgsl and #shaderModule declarations
        var it = self.analysis.symbols.wgsl.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const info = entry.value_ptr.*;

            const shader_id = self.next_shader_id;
            self.next_shader_id += 1;
            try self.shader_ids.put(self.gpa, name, shader_id);

            // Get shader value, substitute defines, and add to data section
            const value = self.findPropertyValue(info.node, "value") orelse continue;
            const raw_code = self.getStringContent(value);
            const code = try self.substituteDefines(raw_code);
            defer if (code.ptr != raw_code.ptr) self.gpa.free(code);

            const data_id = try self.builder.addData(self.gpa, code);

            // Emit create_shader_module opcode
            try self.builder.getEmitter().createShaderModule(
                self.gpa,
                shader_id,
                data_id.toInt(),
            );
        }

        // Also handle #shaderModule
        var sm_it = self.analysis.symbols.shader_module.iterator();
        while (sm_it.next()) |entry| {
            const name = entry.key_ptr.*;
            const info = entry.value_ptr.*;

            const shader_id = self.next_shader_id;
            self.next_shader_id += 1;
            try self.shader_ids.put(self.gpa, name, shader_id);

            // Find code property, substitute defines, and add to data section
            const code_value = self.findPropertyValue(info.node, "code") orelse continue;
            const raw_code = self.getStringContent(code_value);
            const code = try self.substituteDefines(raw_code);
            defer if (code.ptr != raw_code.ptr) self.gpa.free(code);

            const data_id = try self.builder.addData(self.gpa, code);

            try self.builder.getEmitter().createShaderModule(
                self.gpa,
                shader_id,
                data_id.toInt(),
            );
        }
    }

    fn emitBuffers(self: *Self) Error!void {
        var it = self.analysis.symbols.buffer.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const info = entry.value_ptr.*;

            const buffer_id = self.next_buffer_id;
            self.next_buffer_id += 1;
            try self.buffer_ids.put(self.gpa, name, buffer_id);

            // Get size property
            const size_value = self.findPropertyValue(info.node, "size") orelse continue;
            const size = self.parseNumber(size_value) orelse 0;

            // Get usage flags
            const usage = self.parseBufferUsage(info.node);

            try self.builder.getEmitter().createBuffer(
                self.gpa,
                buffer_id,
                @intCast(size),
                @bitCast(usage),
            );
        }
    }

    fn emitTextures(self: *Self) Error!void {
        var it = self.analysis.symbols.texture.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const info = entry.value_ptr.*;

            const texture_id = self.next_texture_id;
            self.next_texture_id += 1;
            try self.texture_ids.put(self.gpa, name, texture_id);

            // Parse texture properties
            const width = self.parsePropertyNumber(info.node, "width") orelse 256;
            const height = self.parsePropertyNumber(info.node, "height") orelse 256;
            const sample_count = self.parsePropertyNumber(info.node, "sampleCount") orelse 1;

            // Parse format
            const format_enum = self.parseTextureFormat(info.node);

            // Parse usage flags
            const usage = self.parseTextureUsage(info.node);

            // Encode descriptor
            const desc = DescriptorEncoder.encodeTexture(
                self.gpa,
                width,
                height,
                format_enum,
                usage,
                sample_count,
            ) catch return error.OutOfMemory;
            defer self.gpa.free(desc);

            const desc_id = try self.builder.addData(self.gpa, desc);

            // Emit create_texture opcode
            try self.builder.getEmitter().createTexture(
                self.gpa,
                texture_id,
                desc_id.toInt(),
            );
        }
    }

    fn emitSamplers(self: *Self) Error!void {
        var it = self.analysis.symbols.sampler.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const info = entry.value_ptr.*;

            const sampler_id = self.next_sampler_id;
            self.next_sampler_id += 1;
            try self.sampler_ids.put(self.gpa, name, sampler_id);

            // Parse sampler properties
            const mag_filter = self.parseSamplerFilter(info.node, "magFilter");
            const min_filter = self.parseSamplerFilter(info.node, "minFilter");
            const address_mode = self.parseSamplerAddressMode(info.node);

            // Encode descriptor
            const desc = DescriptorEncoder.encodeSampler(
                self.gpa,
                mag_filter,
                min_filter,
                address_mode,
            ) catch return error.OutOfMemory;
            defer self.gpa.free(desc);

            const desc_id = try self.builder.addData(self.gpa, desc);

            // Emit create_sampler opcode
            try self.builder.getEmitter().createSampler(
                self.gpa,
                sampler_id,
                desc_id.toInt(),
            );
        }
    }

    fn emitPipelines(self: *Self) Error!void {
        // Render pipelines
        var rp_it = self.analysis.symbols.render_pipeline.iterator();
        while (rp_it.next()) |entry| {
            const name = entry.key_ptr.*;
            const info = entry.value_ptr.*;

            const pipeline_id = self.next_pipeline_id;
            self.next_pipeline_id += 1;
            try self.pipeline_ids.put(self.gpa, name, pipeline_id);

            // Build pipeline descriptor JSON for runtime
            const desc = self.buildRenderPipelineDescriptor(info.node) catch |err| {
                std.debug.print("Failed to build render pipeline descriptor: {}\n", .{err});
                continue;
            };
            defer self.gpa.free(desc);

            const desc_id = try self.builder.addData(self.gpa, desc);

            try self.builder.getEmitter().createRenderPipeline(
                self.gpa,
                pipeline_id,
                desc_id.toInt(),
            );
        }

        // Compute pipelines
        var cp_it = self.analysis.symbols.compute_pipeline.iterator();
        while (cp_it.next()) |entry| {
            const name = entry.key_ptr.*;
            const info = entry.value_ptr.*;

            const pipeline_id = self.next_pipeline_id;
            self.next_pipeline_id += 1;
            try self.pipeline_ids.put(self.gpa, name, pipeline_id);

            // Build compute pipeline descriptor JSON
            const desc = self.buildComputePipelineDescriptor(info.node) catch |err| {
                std.debug.print("Failed to build compute pipeline descriptor: {}\n", .{err});
                continue;
            };
            defer self.gpa.free(desc);

            const desc_id = try self.builder.addData(self.gpa, desc);

            try self.builder.getEmitter().createComputePipeline(
                self.gpa,
                pipeline_id,
                desc_id.toInt(),
            );
        }
    }

    /// Build JSON descriptor for render pipeline.
    /// Format: {"vertex":{"shader":N,"entryPoint":"..."},"fragment":{"shader":N,"entryPoint":"..."}}
    fn buildRenderPipelineDescriptor(self: *Self, node: Node.Index) ![]u8 {
        var vertex_shader_id: u16 = 0;
        var vertex_entry: []const u8 = "vertexMain";
        var fragment_shader_id: u16 = 0;
        var fragment_entry: []const u8 = "fragmentMain";
        var has_fragment = false;

        const data = self.ast.nodes.items(.data)[node.toInt()];
        const props = self.ast.extraData(data.extra_range);

        for (props) |prop_idx| {
            const prop_node: Node.Index = @enumFromInt(prop_idx);
            const prop_token = self.ast.nodes.items(.main_token)[prop_node.toInt()];
            const prop_name = self.getTokenSlice(prop_token);

            if (std.mem.eql(u8, prop_name, "vertex")) {
                const stage_info = self.parseStageDescriptor(prop_node);
                if (stage_info.shader_id) |id| vertex_shader_id = id;
                if (stage_info.entry_point) |ep| vertex_entry = ep;
            } else if (std.mem.eql(u8, prop_name, "fragment")) {
                has_fragment = true;
                const stage_info = self.parseStageDescriptor(prop_node);
                if (stage_info.shader_id) |id| fragment_shader_id = id;
                if (stage_info.entry_point) |ep| fragment_entry = ep;
            }
        }

        // Build JSON string
        if (has_fragment) {
            return std.fmt.allocPrint(
                self.gpa,
                "{{\"vertex\":{{\"shader\":{d},\"entryPoint\":\"{s}\"}},\"fragment\":{{\"shader\":{d},\"entryPoint\":\"{s}\"}}}}",
                .{ vertex_shader_id, vertex_entry, fragment_shader_id, fragment_entry },
            );
        } else {
            return std.fmt.allocPrint(
                self.gpa,
                "{{\"vertex\":{{\"shader\":{d},\"entryPoint\":\"{s}\"}}}}",
                .{ vertex_shader_id, vertex_entry },
            );
        }
    }

    /// Build JSON descriptor for compute pipeline.
    /// Format: {"compute":{"shader":N,"entryPoint":"..."}}
    fn buildComputePipelineDescriptor(self: *Self, node: Node.Index) ![]u8 {
        var compute_shader_id: u16 = 0;
        var compute_entry: []const u8 = "main";

        const data = self.ast.nodes.items(.data)[node.toInt()];
        const props = self.ast.extraData(data.extra_range);

        for (props) |prop_idx| {
            const prop_node: Node.Index = @enumFromInt(prop_idx);
            const prop_token = self.ast.nodes.items(.main_token)[prop_node.toInt()];
            const prop_name = self.getTokenSlice(prop_token);

            if (std.mem.eql(u8, prop_name, "compute")) {
                const stage_info = self.parseStageDescriptor(prop_node);
                if (stage_info.shader_id) |id| compute_shader_id = id;
                if (stage_info.entry_point) |ep| compute_entry = ep;
            }
        }

        return std.fmt.allocPrint(
            self.gpa,
            "{{\"compute\":{{\"shader\":{d},\"entryPoint\":\"{s}\"}}}}",
            .{ compute_shader_id, compute_entry },
        );
    }

    const StageDescriptor = struct {
        shader_id: ?u16,
        entry_point: ?[]const u8,
    };

    /// Parse a shader stage descriptor (vertex, fragment, or compute).
    fn parseStageDescriptor(self: *Self, prop_node: Node.Index) StageDescriptor {
        var result = StageDescriptor{
            .shader_id = null,
            .entry_point = null,
        };

        const prop_data = self.ast.nodes.items(.data)[prop_node.toInt()];
        const obj_node = prop_data.node;
        const obj_tag = self.ast.nodes.items(.tag)[obj_node.toInt()];

        if (obj_tag != .object) return result;

        const obj_data = self.ast.nodes.items(.data)[obj_node.toInt()];
        const obj_props = self.ast.extraData(obj_data.extra_range);

        for (obj_props) |obj_prop_idx| {
            const inner_prop: Node.Index = @enumFromInt(obj_prop_idx);
            const inner_token = self.ast.nodes.items(.main_token)[inner_prop.toInt()];
            const inner_name = self.getTokenSlice(inner_token);

            if (std.mem.eql(u8, inner_name, "module")) {
                if (self.findPropertyReference(inner_prop)) |ref| {
                    result.shader_id = self.shader_ids.get(ref.name);
                }
            } else if (std.mem.eql(u8, inner_name, "entryPoint") or
                std.mem.eql(u8, inner_name, "entrypoint"))
            {
                const inner_data = self.ast.nodes.items(.data)[inner_prop.toInt()];
                const value_node = inner_data.node;
                const value_tag = self.ast.nodes.items(.tag)[value_node.toInt()];

                if (value_tag == .identifier_value) {
                    result.entry_point = self.getNodeText(value_node);
                } else if (value_tag == .string_value) {
                    var text = self.getNodeText(value_node);
                    // Strip quotes
                    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
                        text = text[1 .. text.len - 1];
                    }
                    result.entry_point = text;
                }
            }
        }

        return result;
    }

    fn emitBindGroups(self: *Self) Error!void {
        var it = self.analysis.symbols.bind_group.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const info = entry.value_ptr.*;

            const group_id = self.next_bind_group_id;
            self.next_bind_group_id += 1;
            try self.bind_group_ids.put(self.gpa, name, group_id);

            // Parse entries array
            var entries_list: std.ArrayListUnmanaged(DescriptorEncoder.BindGroupEntry) = .{};
            defer entries_list.deinit(self.gpa);

            const entries_value = self.findPropertyValue(info.node, "entries");
            if (entries_value) |ev| {
                const ev_tag = self.ast.nodes.items(.tag)[ev.toInt()];
                if (ev_tag == .array) {
                    const array_data = self.ast.nodes.items(.data)[ev.toInt()];
                    const elements = self.ast.extraData(array_data.extra_range);

                    for (elements) |elem_idx| {
                        const elem: Node.Index = @enumFromInt(elem_idx);
                        const elem_tag = self.ast.nodes.items(.tag)[elem.toInt()];

                        if (elem_tag == .object) {
                            if (self.parseBindGroupEntry(elem)) |bg_entry| {
                                entries_list.append(self.gpa, bg_entry) catch continue;
                            }
                        }
                    }
                }
            }

            // Resolve layout reference - returns pipeline ID for 'auto' layouts
            const pipeline_id = self.resolveBindGroupLayoutId(info.node);
            const group_index = self.getBindGroupIndex(info.node);

            // Encode entries with group index
            const desc = DescriptorEncoder.encodeBindGroupDescriptor(
                self.gpa,
                group_index,
                entries_list.items,
            ) catch return error.OutOfMemory;
            defer self.gpa.free(desc);

            const desc_id = try self.builder.addData(self.gpa, desc);

            try self.builder.getEmitter().createBindGroup(
                self.gpa,
                group_id,
                pipeline_id, // Pipeline ID to get layout from
                desc_id.toInt(),
            );
        }
    }

    // ========================================================================
    // Queue Collection
    // ========================================================================

    /// Collect queue IDs (queues are inlined at frame execution, not bytecode-defined).
    /// Queues don't emit bytecode here - they're inlined when frames reference them.
    fn collectQueues(self: *Self) Error!void {
        // Pre-condition: ID counter starts at expected value
        const initial_id = self.next_queue_id;
        std.debug.assert(self.queue_ids.count() == 0);

        var it = self.analysis.symbols.queue.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;

            const queue_id = self.next_queue_id;
            self.next_queue_id += 1;
            try self.queue_ids.put(self.gpa, name, queue_id);
        }

        // Post-condition: IDs assigned match symbol count
        std.debug.assert(self.next_queue_id - initial_id == self.queue_ids.count());
    }

    /// Emit a queue's actions (write_buffer commands) inline.
    /// Called when a frame references a queue in its perform array.
    fn emitQueueAction(self: *Self, queue_name: []const u8) Error!void {
        // Pre-conditions
        std.debug.assert(queue_name.len > 0);
        std.debug.assert(self.ast.nodes.len > 0);

        // Queue must exist in symbol table
        const info = self.analysis.symbols.queue.get(queue_name) orelse return;
        std.debug.assert(info.node.toInt() < self.ast.nodes.len);

        // Look for writeBuffer property in queue definition
        const write_buffer_value = self.findPropertyValue(info.node, "writeBuffer") orelse return;
        const wb_tag = self.ast.nodes.items(.tag)[write_buffer_value.toInt()];

        if (wb_tag != .object) return;

        // Parse writeBuffer object: { buffer=..., bufferOffset=..., data=... }
        const buffer_prop = self.findPropertyValueInObject(write_buffer_value, "buffer");
        const offset_prop = self.findPropertyValueInObject(write_buffer_value, "bufferOffset");
        const data_prop = self.findPropertyValueInObject(write_buffer_value, "data");

        // Resolve buffer reference
        const buffer_id = if (buffer_prop) |bp| self.resolveBufferId(bp) else null;
        if (buffer_id == null) return;

        // Parse offset (default 0)
        const offset: u32 = if (offset_prop) |op| blk: {
            break :blk self.parseNumber(op) orelse 0;
        } else 0;

        // Handle data - for now, support literal byte array or placeholder
        // TODO: Support runtime interpolation ($uniforms.x.y.data)
        if (data_prop) |dp| {
            const data_tag = self.ast.nodes.items(.tag)[dp.toInt()];

            if (data_tag == .array) {
                // Parse array of numbers as f32 values
                var data_bytes: std.ArrayListUnmanaged(u8) = .{};
                defer data_bytes.deinit(self.gpa);

                const array_data = self.ast.nodes.items(.data)[dp.toInt()];
                const elements = self.ast.extraData(array_data.extra_range);

                for (elements) |elem_idx| {
                    const elem: Node.Index = @enumFromInt(elem_idx);
                    if (self.parseFloatNumber(elem)) |num| {
                        // Write as f32
                        const f: f32 = @floatCast(num);
                        const bytes = std.mem.asBytes(&f);
                        data_bytes.appendSlice(self.gpa, bytes) catch continue;
                    }
                }

                if (data_bytes.items.len > 0) {
                    const data_id = try self.builder.addData(self.gpa, data_bytes.items);
                    try self.builder.getEmitter().writeBuffer(
                        self.gpa,
                        buffer_id.?,
                        offset,
                        data_id.toInt(),
                    );
                }
            } else if (data_tag == .string_value) {
                // String data - could be hex or runtime ref
                const data_str = self.getStringContent(dp);

                // Check for runtime interpolation (starts with $)
                if (data_str.len > 0 and data_str[0] == '$') {
                    // Runtime interpolation ($uniforms.x.y.data, $time, etc.)
                    // Skip emitting write_buffer - JS will handle via writeTimeUniform
                    // This prevents overwriting JS-managed uniform values
                    return;
                } else {
                    // Literal string data (hex bytes)
                    const data_id = try self.builder.addData(self.gpa, data_str);
                    try self.builder.getEmitter().writeBuffer(
                        self.gpa,
                        buffer_id.?,
                        offset,
                        data_id.toInt(),
                    );
                }
            }
        }
    }

    /// Find property value within an object node.
    /// Returns the value node for the named property, or null if not found.
    fn findPropertyValueInObject(self: *Self, object_node: Node.Index, prop_name: []const u8) ?Node.Index {
        // Pre-conditions: valid object node and non-empty property name
        std.debug.assert(object_node.toInt() < self.ast.nodes.len);
        std.debug.assert(prop_name.len > 0);

        const obj_data = self.ast.nodes.items(.data)[object_node.toInt()];
        const props = self.ast.extraData(obj_data.extra_range);

        for (props) |prop_idx| {
            const prop_node: Node.Index = @enumFromInt(prop_idx);
            const prop_tag = self.ast.nodes.items(.tag)[prop_node.toInt()];
            if (prop_tag != .property) continue;

            const prop_token = self.ast.nodes.items(.main_token)[prop_node.toInt()];
            const name = self.getTokenSlice(prop_token);

            if (std.mem.eql(u8, name, prop_name)) {
                const prop_data = self.ast.nodes.items(.data)[prop_node.toInt()];
                return prop_data.node;
            }
        }
        return null;
    }

    // ========================================================================
    // Pass Emission
    // ========================================================================

    fn emitPasses(self: *Self) Error!void {
        // Render passes
        var rp_it = self.analysis.symbols.render_pass.iterator();
        while (rp_it.next()) |entry| {
            const name = entry.key_ptr.*;
            const info = entry.value_ptr.*;

            const pass_id = self.next_pass_id;
            self.next_pass_id += 1;
            try self.pass_ids.put(self.gpa, name, pass_id);

            try self.emitRenderPassDefinition(pass_id, info.node);
        }

        // Compute passes
        var cp_it = self.analysis.symbols.compute_pass.iterator();
        while (cp_it.next()) |entry| {
            const name = entry.key_ptr.*;
            const info = entry.value_ptr.*;

            const pass_id = self.next_pass_id;
            self.next_pass_id += 1;
            try self.pass_ids.put(self.gpa, name, pass_id);

            try self.emitComputePassDefinition(pass_id, info.node);
        }
    }

    fn emitRenderPassDefinition(self: *Self, pass_id: u16, node: Node.Index) Error!void {
        // Create pass descriptor
        const desc = "{}";
        const desc_id = try self.builder.addData(self.gpa, desc);

        // Define pass
        try self.builder.getEmitter().definePass(
            self.gpa,
            pass_id,
            .render,
            desc_id.toInt(),
        );

        // Begin render pass (texture 0 = canvas, clear, store)
        try self.builder.getEmitter().beginRenderPass(
            self.gpa,
            0, // color texture ID (0 = canvas/surface)
            opcodes.LoadOp.clear,
            opcodes.StoreOp.store,
        );

        // Emit pass body commands
        try self.emitPassCommands(node);

        // End the render pass
        try self.builder.getEmitter().endPass(self.gpa);

        // End pass definition
        try self.builder.getEmitter().endPassDef(self.gpa);
    }

    fn emitComputePassDefinition(self: *Self, pass_id: u16, node: Node.Index) Error!void {
        const desc = "{}";
        const desc_id = try self.builder.addData(self.gpa, desc);

        try self.builder.getEmitter().definePass(
            self.gpa,
            pass_id,
            .compute,
            desc_id.toInt(),
        );

        // Begin compute pass
        try self.builder.getEmitter().beginComputePass(self.gpa);

        // Emit pass body commands
        try self.emitPassCommands(node);

        // End the compute pass
        try self.builder.getEmitter().endPass(self.gpa);

        // End pass definition
        try self.builder.getEmitter().endPassDef(self.gpa);
    }

    fn emitPassCommands(self: *Self, node: Node.Index) Error!void {
        const data = self.ast.nodes.items(.data)[node.toInt()];
        const props = self.ast.extraData(data.extra_range);

        for (props) |prop_idx| {
            const prop_node: Node.Index = @enumFromInt(prop_idx);
            const prop_token = self.ast.nodes.items(.main_token)[prop_node.toInt()];
            const prop_name = self.getTokenSlice(prop_token);

            if (std.mem.eql(u8, prop_name, "pipeline")) {
                try self.emitPipelineCommand(prop_node);
            } else if (std.mem.eql(u8, prop_name, "bindGroups")) {
                try self.emitBindGroupCommands(prop_node);
            } else if (std.mem.eql(u8, prop_name, "vertexBuffers")) {
                try self.emitVertexBufferCommands(prop_node);
            } else if (std.mem.eql(u8, prop_name, "indexBuffer")) {
                try self.emitIndexBufferCommand(prop_node);
            } else if (std.mem.eql(u8, prop_name, "draw")) {
                try self.emitDrawCommand(prop_node);
            } else if (std.mem.eql(u8, prop_name, "drawIndexed")) {
                try self.emitDrawIndexedCommand(prop_node);
            } else if (std.mem.eql(u8, prop_name, "dispatch")) {
                try self.emitDispatchCommand(prop_node);
            }
        }
    }

    /// Emit set_pipeline command.
    /// Handles both reference ($renderPipeline.x) and identifier (pipelineName) syntax.
    fn emitPipelineCommand(self: *Self, prop_node: Node.Index) Error!void {
        if (self.findPropertyReference(prop_node)) |ref| {
            if (self.pipeline_ids.get(ref.name)) |pipeline_id| {
                try self.builder.getEmitter().setPipeline(self.gpa, pipeline_id);
            }
        } else {
            // Fallback: identifier value (e.g., pipeline=myPipeline)
            const prop_data = self.ast.nodes.items(.data)[prop_node.toInt()];
            const value_node = prop_data.node;
            const value_tag = self.ast.nodes.items(.tag)[value_node.toInt()];

            if (value_tag == .identifier_value) {
                const name = self.getNodeText(value_node);
                if (self.pipeline_ids.get(name)) |pipeline_id| {
                    try self.builder.getEmitter().setPipeline(self.gpa, pipeline_id);
                }
            }
        }
    }

    /// Emit draw command with vertex/instance counts.
    fn emitDrawCommand(self: *Self, prop_node: Node.Index) Error!void {
        const prop_data = self.ast.nodes.items(.data)[prop_node.toInt()];
        const value_node = prop_data.node;
        const value_tag = self.ast.nodes.items(.tag)[value_node.toInt()];

        if (value_tag == .number_value) {
            const count = self.parseNumber(value_node) orelse 3;
            try self.builder.getEmitter().draw(self.gpa, count, 1);
        } else if (value_tag == .array) {
            const counts = self.parseCountPair(value_node, 3, 1);
            try self.builder.getEmitter().draw(self.gpa, counts[0], counts[1]);
        }
    }

    /// Emit draw_indexed command with index/instance counts.
    fn emitDrawIndexedCommand(self: *Self, prop_node: Node.Index) Error!void {
        const prop_data = self.ast.nodes.items(.data)[prop_node.toInt()];
        const value_node = prop_data.node;
        const value_tag = self.ast.nodes.items(.tag)[value_node.toInt()];

        if (value_tag == .number_value) {
            const count = self.parseNumber(value_node) orelse 3;
            try self.builder.getEmitter().drawIndexed(self.gpa, count, 1);
        } else if (value_tag == .array) {
            const counts = self.parseCountPair(value_node, 3, 1);
            try self.builder.getEmitter().drawIndexed(self.gpa, counts[0], counts[1]);
        }
    }

    /// Emit dispatch command for compute passes.
    fn emitDispatchCommand(self: *Self, prop_node: Node.Index) Error!void {
        const prop_data = self.ast.nodes.items(.data)[prop_node.toInt()];
        const value_node = prop_data.node;
        const value_tag = self.ast.nodes.items(.tag)[value_node.toInt()];

        if (value_tag == .array) {
            const array_data = self.ast.nodes.items(.data)[value_node.toInt()];
            const elements = self.ast.extraData(array_data.extra_range);
            var xyz: [3]u32 = .{ 1, 1, 1 };
            for (elements, 0..) |elem_idx, i| {
                if (i >= 3) break;
                const elem: Node.Index = @enumFromInt(elem_idx);
                xyz[i] = self.parseNumber(elem) orelse 1;
            }
            try self.builder.getEmitter().dispatch(self.gpa, xyz[0], xyz[1], xyz[2]);
        }
    }

    /// Parse array of 2 numbers (e.g., [vertex_count instance_count]).
    fn parseCountPair(self: *Self, array_node: Node.Index, default0: u32, default1: u32) [2]u32 {
        const array_data = self.ast.nodes.items(.data)[array_node.toInt()];
        const elements = self.ast.extraData(array_data.extra_range);
        var counts: [2]u32 = .{ default0, default1 };
        for (elements, 0..) |elem_idx, i| {
            if (i >= 2) break;
            const elem: Node.Index = @enumFromInt(elem_idx);
            counts[i] = self.parseNumber(elem) orelse if (i == 0) default0 else default1;
        }
        return counts;
    }

    fn emitBindGroupCommands(self: *Self, prop_node: Node.Index) Error!void {
        const prop_data = self.ast.nodes.items(.data)[prop_node.toInt()];
        const value_node = prop_data.node;
        const value_tag = self.ast.nodes.items(.tag)[value_node.toInt()];

        if (value_tag == .array) {
            const array_data = self.ast.nodes.items(.data)[value_node.toInt()];
            const elements = self.ast.extraData(array_data.extra_range);

            for (elements, 0..) |elem_idx, slot| {
                const elem: Node.Index = @enumFromInt(elem_idx);
                const group_id = self.resolveBindGroupId(elem);

                if (group_id) |id| {
                    try self.builder.getEmitter().setBindGroup(
                        self.gpa,
                        @intCast(slot),
                        id,
                    );
                }
            }
        } else {
            // Single bind group at slot 0
            const group_id = self.resolveBindGroupId(value_node);
            if (group_id) |id| {
                try self.builder.getEmitter().setBindGroup(self.gpa, 0, id);
            }
        }
    }

    /// Resolve a bind group reference to its ID.
    /// Handles both bare identifiers (inputsBinding) and references ($bindGroup.name).
    fn resolveBindGroupId(self: *Self, node: Node.Index) ?u16 {
        const tag = self.ast.nodes.items(.tag)[node.toInt()];

        if (tag == .reference) {
            if (self.getReference(node)) |ref| {
                return self.bind_group_ids.get(ref.name);
            }
        } else if (tag == .identifier_value) {
            const name = self.getNodeText(node);
            return self.bind_group_ids.get(name);
        }

        return null;
    }

    /// Resolve a buffer reference to its ID.
    /// Handles both bare identifiers (myBuffer) and references ($buffer.name).
    fn resolveBufferId(self: *Self, node: Node.Index) ?u16 {
        // Pre-conditions: valid node index
        std.debug.assert(node.toInt() < self.ast.nodes.len);
        std.debug.assert(self.ast.nodes.len > 0);

        const tag = self.ast.nodes.items(.tag)[node.toInt()];

        if (tag == .reference) {
            if (self.getReference(node)) |ref| {
                return self.buffer_ids.get(ref.name);
            }
        } else if (tag == .identifier_value) {
            const name = self.getNodeText(node);
            return self.buffer_ids.get(name);
        }

        return null;
    }

    fn emitVertexBufferCommands(self: *Self, prop_node: Node.Index) Error!void {
        const prop_data = self.ast.nodes.items(.data)[prop_node.toInt()];
        const value_node = prop_data.node;
        const value_tag = self.ast.nodes.items(.tag)[value_node.toInt()];

        if (value_tag == .array) {
            const array_data = self.ast.nodes.items(.data)[value_node.toInt()];
            const elements = self.ast.extraData(array_data.extra_range);

            for (elements, 0..) |elem_idx, slot| {
                const elem: Node.Index = @enumFromInt(elem_idx);
                const elem_tag = self.ast.nodes.items(.tag)[elem.toInt()];

                if (elem_tag == .reference) {
                    if (self.getReference(elem)) |ref| {
                        if (self.buffer_ids.get(ref.name)) |buffer_id| {
                            try self.builder.getEmitter().setVertexBuffer(
                                self.gpa,
                                @intCast(slot),
                                buffer_id,
                            );
                        }
                    }
                }
            }
        } else if (value_tag == .reference) {
            // Single vertex buffer at slot 0
            if (self.getReference(value_node)) |ref| {
                if (self.buffer_ids.get(ref.name)) |buffer_id| {
                    try self.builder.getEmitter().setVertexBuffer(self.gpa, 0, buffer_id);
                }
            }
        }
    }

    fn emitIndexBufferCommand(self: *Self, prop_node: Node.Index) Error!void {
        const prop_data = self.ast.nodes.items(.data)[prop_node.toInt()];
        const value_node = prop_data.node;
        const value_tag = self.ast.nodes.items(.tag)[value_node.toInt()];

        if (value_tag == .reference) {
            if (self.getReference(value_node)) |ref| {
                if (self.buffer_ids.get(ref.name)) |buffer_id| {
                    // Format 0 = uint16, 1 = uint32 (default to uint16)
                    try self.builder.getEmitter().setIndexBuffer(self.gpa, buffer_id, 0);
                }
            }
        }
    }

    // ========================================================================
    // Frame Emission
    // ========================================================================

    fn emitFrames(self: *Self) Error!void {
        var it = self.analysis.symbols.frame.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const info = entry.value_ptr.*;

            const frame_id = self.next_frame_id;
            self.next_frame_id += 1;
            try self.frame_ids.put(self.gpa, name, frame_id);

            // Intern frame name
            const name_id = try self.builder.internString(self.gpa, name);

            // Define frame
            try self.builder.getEmitter().defineFrame(self.gpa, frame_id, name_id.toInt());

            // Emit frame body
            try self.emitFrameBody(info.node);

            // Submit and end frame
            try self.builder.getEmitter().submit(self.gpa);
            try self.builder.getEmitter().endFrame(self.gpa);
        }
    }

    fn emitFrameBody(self: *Self, node: Node.Index) Error!void {
        // Look for perform array
        const perform_value = self.findPropertyValue(node, "perform") orelse return;
        const value_tag = self.ast.nodes.items(.tag)[perform_value.toInt()];

        if (value_tag == .array) {
            const array_data = self.ast.nodes.items(.data)[perform_value.toInt()];
            const elements = self.ast.extraData(array_data.extra_range);

            for (elements) |elem_idx| {
                const elem: Node.Index = @enumFromInt(elem_idx);
                const elem_tag = self.ast.nodes.items(.tag)[elem.toInt()];

                if (elem_tag == .reference) {
                    // Execute pass or queue by reference ($namespace.name)
                    if (self.getReference(elem)) |ref| {
                        // Check namespace to determine action type
                        if (std.mem.eql(u8, ref.namespace, "queue")) {
                            // Queue reference - inline the write_buffer commands
                            if (self.queue_ids.get(ref.name) != null) {
                                try self.emitQueueAction(ref.name);
                            }
                        } else {
                            // Pass reference (renderPass, computePass)
                            if (self.pass_ids.get(ref.name)) |pass_id| {
                                try self.builder.getEmitter().execPass(self.gpa, pass_id);
                            }
                        }
                    }
                } else if (elem_tag == .identifier_value) {
                    // Execute pass or queue by name
                    const name_token = self.ast.nodes.items(.main_token)[elem.toInt()];
                    const action_name = self.getTokenSlice(name_token);
                    if (self.pass_ids.get(action_name)) |pass_id| {
                        try self.builder.getEmitter().execPass(self.gpa, pass_id);
                    } else if (self.queue_ids.get(action_name) != null) {
                        // Queue reference - inline the write_buffer commands
                        try self.emitQueueAction(action_name);
                    }
                }
            }
        }
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    fn findPropertyValue(self: *Self, macro_node: Node.Index, prop_name: []const u8) ?Node.Index {
        const data = self.ast.nodes.items(.data)[macro_node.toInt()];
        const props = self.ast.extraData(data.extra_range);

        for (props) |prop_idx| {
            const prop_node: Node.Index = @enumFromInt(prop_idx);
            const prop_token = self.ast.nodes.items(.main_token)[prop_node.toInt()];
            const name = self.getTokenSlice(prop_token);

            if (std.mem.eql(u8, name, prop_name)) {
                const prop_data = self.ast.nodes.items(.data)[prop_node.toInt()];
                return prop_data.node;
            }
        }

        return null;
    }

    fn findPropertyReference(self: *Self, prop_node: Node.Index) ?Reference {
        const prop_data = self.ast.nodes.items(.data)[prop_node.toInt()];
        const value_node = prop_data.node;
        const value_tag = self.ast.nodes.items(.tag)[value_node.toInt()];

        if (value_tag == .reference) {
            return self.getReference(value_node);
        }
        return null;
    }

    fn getReference(self: *Self, node: Node.Index) ?Reference {
        const data = self.ast.nodes.items(.data)[node.toInt()];
        const namespace_token = data.node_and_node[0];
        const name_token = data.node_and_node[1];

        return Reference{
            .namespace = self.getTokenSlice(namespace_token),
            .name = self.getTokenSlice(name_token),
        };
    }

    fn getStringContent(self: *Self, value_node: Node.Index) []const u8 {
        const value_tag = self.ast.nodes.items(.tag)[value_node.toInt()];
        if (value_tag != .string_value) return "";

        const value_token = self.ast.nodes.items(.main_token)[value_node.toInt()];
        const raw = self.getTokenSlice(value_token);

        // Strip quotes
        if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
            return raw[1 .. raw.len - 1];
        }
        return raw;
    }

    fn parseNumber(self: *Self, value_node: Node.Index) ?u32 {
        const value_tag = self.ast.nodes.items(.tag)[value_node.toInt()];
        if (value_tag != .number_value) return null;

        const value_token = self.ast.nodes.items(.main_token)[value_node.toInt()];
        const text = self.getTokenSlice(value_token);

        return std.fmt.parseInt(u32, text, 10) catch null;
    }

    /// Parse a number node as f64.
    /// Returns null if node is not a number or parsing fails.
    fn parseFloatNumber(self: *Self, value_node: Node.Index) ?f64 {
        // Pre-conditions: valid node index
        std.debug.assert(value_node.toInt() < self.ast.nodes.len);
        std.debug.assert(self.ast.nodes.len > 0);

        const value_tag = self.ast.nodes.items(.tag)[value_node.toInt()];
        if (value_tag != .number_value) return null;

        const value_token = self.ast.nodes.items(.main_token)[value_node.toInt()];
        const text = self.getTokenSlice(value_token);

        return std.fmt.parseFloat(f64, text) catch null;
    }

    fn parseBufferUsage(self: *Self, node: Node.Index) opcodes.BufferUsage {
        var usage = opcodes.BufferUsage{};

        const usage_value = self.findPropertyValue(node, "usage") orelse return usage;
        const value_tag = self.ast.nodes.items(.tag)[usage_value.toInt()];

        if (value_tag == .array) {
            const array_data = self.ast.nodes.items(.data)[usage_value.toInt()];
            const elements = self.ast.extraData(array_data.extra_range);

            for (elements) |elem_idx| {
                const elem: Node.Index = @enumFromInt(elem_idx);
                const elem_tag = self.ast.nodes.items(.tag)[elem.toInt()];

                if (elem_tag == .identifier_value) {
                    const flag_token = self.ast.nodes.items(.main_token)[elem.toInt()];
                    const flag_name = self.getTokenSlice(flag_token);

                    if (std.mem.eql(u8, flag_name, "VERTEX")) usage.vertex = true;
                    if (std.mem.eql(u8, flag_name, "INDEX")) usage.index = true;
                    if (std.mem.eql(u8, flag_name, "UNIFORM")) usage.uniform = true;
                    if (std.mem.eql(u8, flag_name, "STORAGE")) usage.storage = true;
                    if (std.mem.eql(u8, flag_name, "COPY_SRC")) usage.copy_src = true;
                    if (std.mem.eql(u8, flag_name, "COPY_DST")) usage.copy_dst = true;
                    if (std.mem.eql(u8, flag_name, "MAP_READ")) usage.map_read = true;
                    if (std.mem.eql(u8, flag_name, "MAP_WRITE")) usage.map_write = true;
                }
            }
        }

        return usage;
    }

    // ========================================================================
    // Property Parsing Helpers
    // ========================================================================

    fn parsePropertyNumber(self: *Self, node: Node.Index, prop_name: []const u8) ?u32 {
        const value = self.findPropertyValue(node, prop_name) orelse return null;
        return self.parseNumber(value);
    }

    fn parseTextureFormat(self: *Self, node: Node.Index) DescriptorEncoder.TextureFormat {
        const value = self.findPropertyValue(node, "format") orelse return .rgba8unorm;
        const value_tag = self.ast.nodes.items(.tag)[value.toInt()];

        if (value_tag == .identifier_value or value_tag == .string_value) {
            var text = self.getNodeText(value);
            // Strip quotes if present
            if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
                text = text[1 .. text.len - 1];
            }
            return DescriptorEncoder.TextureFormat.fromString(text);
        }
        return .rgba8unorm;
    }

    fn parseTextureUsage(self: *Self, node: Node.Index) DescriptorEncoder.TextureUsage {
        var usage = DescriptorEncoder.TextureUsage{};

        const usage_value = self.findPropertyValue(node, "usage") orelse return usage;
        const value_tag = self.ast.nodes.items(.tag)[usage_value.toInt()];

        if (value_tag == .array) {
            const array_data = self.ast.nodes.items(.data)[usage_value.toInt()];
            const elements = self.ast.extraData(array_data.extra_range);

            for (elements) |elem_idx| {
                const elem: Node.Index = @enumFromInt(elem_idx);
                const elem_tag = self.ast.nodes.items(.tag)[elem.toInt()];

                if (elem_tag == .identifier_value) {
                    const flag_name = self.getNodeText(elem);

                    if (std.mem.eql(u8, flag_name, "COPY_SRC")) usage.copy_src = true;
                    if (std.mem.eql(u8, flag_name, "COPY_DST")) usage.copy_dst = true;
                    if (std.mem.eql(u8, flag_name, "TEXTURE_BINDING")) usage.texture_binding = true;
                    if (std.mem.eql(u8, flag_name, "STORAGE_BINDING")) usage.storage_binding = true;
                    if (std.mem.eql(u8, flag_name, "RENDER_ATTACHMENT")) usage.render_attachment = true;
                }
            }
        }

        return usage;
    }

    fn parseSamplerFilter(self: *Self, node: Node.Index, prop_name: []const u8) DescriptorEncoder.FilterMode {
        const value = self.findPropertyValue(node, prop_name) orelse return .linear;
        const value_tag = self.ast.nodes.items(.tag)[value.toInt()];

        if (value_tag == .identifier_value or value_tag == .string_value) {
            var text = self.getNodeText(value);
            if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
                text = text[1 .. text.len - 1];
            }
            if (std.mem.eql(u8, text, "nearest")) return .nearest;
        }
        return .linear;
    }

    fn parseSamplerAddressMode(self: *Self, node: Node.Index) DescriptorEncoder.AddressMode {
        const value = self.findPropertyValue(node, "addressModeU") orelse
            self.findPropertyValue(node, "addressMode") orelse return .clamp_to_edge;
        const value_tag = self.ast.nodes.items(.tag)[value.toInt()];

        if (value_tag == .identifier_value or value_tag == .string_value) {
            var text = self.getNodeText(value);
            if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
                text = text[1 .. text.len - 1];
            }
            if (std.mem.eql(u8, text, "repeat")) return .repeat;
            if (std.mem.eql(u8, text, "mirror-repeat")) return .mirror_repeat;
        }
        return .clamp_to_edge;
    }

    fn parseBindGroupEntry(self: *Self, entry_node: Node.Index) ?DescriptorEncoder.BindGroupEntry {
        const entry_data = self.ast.nodes.items(.data)[entry_node.toInt()];
        const entry_props = self.ast.extraData(entry_data.extra_range);

        var bg_entry = DescriptorEncoder.BindGroupEntry{
            .binding = 0,
            .resource_type = .buffer,
            .resource_id = 0,
        };

        for (entry_props) |prop_idx| {
            const prop: Node.Index = @enumFromInt(prop_idx);
            const prop_token = self.ast.nodes.items(.main_token)[prop.toInt()];
            const prop_name = self.getTokenSlice(prop_token);
            const prop_data = self.ast.nodes.items(.data)[prop.toInt()];
            const value_node = prop_data.node;

            if (std.mem.eql(u8, prop_name, "binding")) {
                bg_entry.binding = @intCast(self.parseNumber(value_node) orelse 0);
            } else if (std.mem.eql(u8, prop_name, "buffer")) {
                bg_entry.resource_type = .buffer;
                if (self.resolveResourceId(value_node, "buffer")) |id| {
                    bg_entry.resource_id = id;
                }
            } else if (std.mem.eql(u8, prop_name, "texture")) {
                bg_entry.resource_type = .texture_view;
                if (self.resolveResourceId(value_node, "texture")) |id| {
                    bg_entry.resource_id = id;
                }
            } else if (std.mem.eql(u8, prop_name, "sampler")) {
                bg_entry.resource_type = .sampler;
                if (self.resolveResourceId(value_node, "sampler")) |id| {
                    bg_entry.resource_id = id;
                }
            } else if (std.mem.eql(u8, prop_name, "offset")) {
                bg_entry.offset = self.parseNumber(value_node) orelse 0;
            } else if (std.mem.eql(u8, prop_name, "size")) {
                bg_entry.size = self.parseNumber(value_node) orelse 0;
            }
        }

        return bg_entry;
    }

    fn resolveResourceId(self: *Self, value_node: Node.Index, resource_type: []const u8) ?u16 {
        const value_tag = self.ast.nodes.items(.tag)[value_node.toInt()];

        if (value_tag == .reference) {
            if (self.getReference(value_node)) |ref| {
                if (std.mem.eql(u8, resource_type, "buffer")) {
                    return self.buffer_ids.get(ref.name);
                } else if (std.mem.eql(u8, resource_type, "texture")) {
                    return self.texture_ids.get(ref.name);
                } else if (std.mem.eql(u8, resource_type, "sampler")) {
                    return self.sampler_ids.get(ref.name);
                }
            }
        }
        return null;
    }

    /// Resolve bind group layout to pipeline ID.
    /// For auto layouts: layout={ pipeline=pipelineName index=0 }
    /// Returns the pipeline ID to get the bind group layout from.
    fn resolveBindGroupLayoutId(self: *Self, node: Node.Index) u16 {
        const value = self.findPropertyValue(node, "layout") orelse return 0;
        const value_tag = self.ast.nodes.items(.tag)[value.toInt()];

        if (value_tag == .object) {
            // Parse layout={ pipeline=name index=N }
            const obj_data = self.ast.nodes.items(.data)[value.toInt()];
            const obj_props = self.ast.extraData(obj_data.extra_range);

            for (obj_props) |prop_idx| {
                const prop_node: Node.Index = @enumFromInt(prop_idx);
                const prop_token = self.ast.nodes.items(.main_token)[prop_node.toInt()];
                const prop_name = self.getTokenSlice(prop_token);

                if (std.mem.eql(u8, prop_name, "pipeline")) {
                    // Get pipeline reference or identifier
                    const prop_data = self.ast.nodes.items(.data)[prop_node.toInt()];
                    const prop_value = prop_data.node;
                    const prop_value_tag = self.ast.nodes.items(.tag)[prop_value.toInt()];

                    if (prop_value_tag == .identifier_value) {
                        const pipeline_name = self.getNodeText(prop_value);
                        return self.pipeline_ids.get(pipeline_name) orelse 0;
                    } else if (prop_value_tag == .reference) {
                        if (self.getReference(prop_value)) |ref| {
                            return self.pipeline_ids.get(ref.name) orelse 0;
                        }
                    }
                }
            }
        } else if (value_tag == .identifier_value) {
            const text = self.getNodeText(value);
            if (std.mem.eql(u8, text, "auto")) {
                return 0; // Auto layout without pipeline reference
            }
        }
        return 0;
    }

    /// Get the bind group index from layout object.
    /// For layout={ pipeline=name index=N }, returns N (default 0).
    fn getBindGroupIndex(self: *Self, node: Node.Index) u8 {
        const value = self.findPropertyValue(node, "layout") orelse return 0;
        const value_tag = self.ast.nodes.items(.tag)[value.toInt()];

        if (value_tag == .object) {
            if (self.findPropertyValue(value, "index")) |index_value| {
                const index_tag = self.ast.nodes.items(.tag)[index_value.toInt()];
                if (index_tag == .number_value) {
                    const text = self.getNodeText(index_value);
                    return std.fmt.parseInt(u8, text, 10) catch 0;
                }
            }
        }
        return 0;
    }

    fn getNodeText(self: *Self, node: Node.Index) []const u8 {
        const token = self.ast.nodes.items(.main_token)[node.toInt()];
        return self.getTokenSlice(token);
    }

    fn getTokenSlice(self: *Self, token_index: u32) []const u8 {
        const starts = self.ast.tokens.items(.start);
        const start = starts[token_index];
        const end: u32 = if (token_index + 1 < starts.len)
            starts[token_index + 1]
        else
            @intCast(self.ast.source.len);

        // Trim whitespace
        var slice = self.ast.source[start..end];
        while (slice.len > 0 and (slice[slice.len - 1] == ' ' or
            slice[slice.len - 1] == '\n' or
            slice[slice.len - 1] == '\t' or
            slice[slice.len - 1] == '\r'))
        {
            slice = slice[0 .. slice.len - 1];
        }
        return slice;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const Parser = @import("Parser.zig").Parser;

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

// ----------------------------------------------------------------------------
// Basic Emission Tests
// ----------------------------------------------------------------------------

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
        \\#renderPipeline pipe { vertex={ module=$wgsl.shader } }
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

test "Emitter: render pass with draw" {
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#renderPipeline pipe { vertex={ module=$wgsl.shader } }
        \\#renderPass pass { pipeline=$renderPipeline.pipe draw=3 }
        \\#frame main { perform=[$renderPass.pass] }
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

// ----------------------------------------------------------------------------
// Complex Example Tests
// ----------------------------------------------------------------------------

test "Emitter: simpleTriangle example" {
    const source: [:0]const u8 =
        \\#wgsl triangleShader { value="@vertex fn vs() { } @fragment fn fs() { }" }
        \\#renderPipeline pipeline {
        \\  layout=auto
        \\  vertex={ entryPoint=vs module=$wgsl.triangleShader }
        \\  fragment={ entryPoint=fs module=$wgsl.triangleShader }
        \\}
        \\#renderPass drawPass {
        \\  pipeline=$renderPipeline.pipeline
        \\  draw=3
        \\}
        \\#frame main {
        \\  perform=[$renderPass.drawPass]
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
        \\#computePipeline pipe { compute={ module=$wgsl.computeShader } }
        \\#computePass pass { pipeline=$computePipeline.pipe dispatch=[8 8 1] }
        \\#frame main { perform=[$computePass.pass] }
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
        \\  vertex={ entrypoint=vs module=$wgsl.triangleShader }
        \\  fragment={ entrypoint=fs module=$wgsl.triangleShader }
        \\}
        \\#renderPass drawPass {
        \\  pipeline=$renderPipeline.pipeline
        \\  draw=3
        \\}
        \\#frame main {
        \\  perform=[$renderPass.drawPass]
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
        \\  vertex={ entryPoint=myVertex module=$wgsl.triangleShader }
        \\  fragment={ entryPoint=myFragment module=$wgsl.triangleShader }
        \\}
        \\#renderPass drawPass {
        \\  pipeline=$renderPipeline.pipeline
        \\  draw=3
        \\}
        \\#frame main {
        \\  perform=[$renderPass.drawPass]
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

// ----------------------------------------------------------------------------
// Error Handling Tests
// ----------------------------------------------------------------------------

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

// ----------------------------------------------------------------------------
// Regression Tests - setPipeline emission
// ----------------------------------------------------------------------------

test "Emitter: setPipeline with identifier value" {
    // Regression test: pipeline=pipelineName should emit set_pipeline
    // Previously only $renderPipeline.name references worked.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#renderPipeline myPipeline { vertex={ module=$wgsl.shader } }
        \\#renderPass pass { pipeline=myPipeline draw=3 }
        \\#frame main { perform=[$renderPass.pass] }
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

test "Emitter: setPipeline with reference syntax" {
    // Verify that $renderPipeline.name syntax still works
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#renderPipeline myPipeline { vertex={ module=$wgsl.shader } }
        \\#renderPass pass { pipeline=$renderPipeline.myPipeline draw=3 }
        \\#frame main { perform=[$renderPass.pass] }
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
        \\#renderPipeline pipe { vertex={ module=$wgsl.shader } }
        \\#renderPass pass { pipeline=pipe draw=3 }
        \\#frame main { perform=[$renderPass.pass] }
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
    // Previously only $bindGroup.name references worked, not bare identifiers.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@group(0) @binding(0) var<uniform> u: f32; @vertex fn vs() { } @fragment fn fs() { }" }
        \\#buffer uniformBuf { size=4 usage=[UNIFORM COPY_DST] }
        \\#renderPipeline pipe { layout=auto vertex={ module=$wgsl.shader } fragment={ module=$wgsl.shader } }
        \\#bindGroup bg { layout={ pipeline=pipe index=0 } entries=[{ binding=0 resource={ buffer=uniformBuf } }] }
        \\#renderPass pass { pipeline=pipe bindGroups=[bg] draw=3 }
        \\#frame main { perform=[$renderPass.pass] }
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

test "Emitter: bind group with bare identifier reference" {
    // Tests that bindGroups=[name] works without $ prefix.
    // This is the common DSL syntax users expect.
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() { }" }
        \\#buffer buf { size=16 usage=[UNIFORM] }
        \\#renderPipeline pipe { layout=auto vertex={ module=$wgsl.shader } }
        \\#bindGroup myBindGroup { layout={ pipeline=pipe index=0 } entries=[{ binding=0 resource={ buffer=buf } }] }
        \\#renderPass pass { pipeline=pipe bindGroups=[myBindGroup] draw=3 }
        \\#frame main { perform=[$renderPass.pass] }
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

// ----------------------------------------------------------------------------
// Queue Tests
// ----------------------------------------------------------------------------

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
    // Test that queue can reference buffer by $buffer.name syntax
    const source: [:0]const u8 =
        \\#buffer uniformBuf { size=16 usage=[UNIFORM COPY_DST] }
        \\#queue writeUniforms { writeBuffer={ buffer=$buffer.uniformBuf data=[1.0 2.0 3.0 4.0] } }
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
        \\#renderPipeline pipe { vertex={ module=$wgsl.shader } }
        \\#renderPass pass { pipeline=pipe draw=3 }
        \\#queue writeUniforms { writeBuffer={ buffer=uniformBuf data=[0.5] } }
        \\#frame main { perform=[writeUniforms $renderPass.pass] }
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

test "Emitter: queue writeBuffer with $queue.name reference in perform" {
    // Test that $queue.name syntax works in perform array
    const source: [:0]const u8 =
        \\#buffer uniformBuf { size=4 usage=[UNIFORM COPY_DST] }
        \\#queue writeUniforms { writeBuffer={ buffer=uniformBuf data=[0.5] } }
        \\#frame main { perform=[$queue.writeUniforms] }
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

    // Property: shader code in data section should have substituted values
    var found_substituted = false;
    for (module.data.blobs.items) |data| {
        // Should contain "(2.0 * PI)" from FOV substitution
        if (std.mem.indexOf(u8, data, "(2.0 * PI)")) |_| {
            found_substituted = true;
            break;
        }
    }
    try testing.expect(found_substituted);
}
