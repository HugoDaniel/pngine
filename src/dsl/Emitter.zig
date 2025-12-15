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

    // Counters for generating IDs
    next_buffer_id: u16 = 0,
    next_texture_id: u16 = 0,
    next_sampler_id: u16 = 0,
    next_shader_id: u16 = 0,
    next_pipeline_id: u16 = 0,
    next_bind_group_id: u16 = 0,
    next_pass_id: u16 = 0,
    next_frame_id: u16 = 0,

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

        // Pass 2: Emit passes
        try self.emitPasses();

        // Pass 3: Emit frames
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

        return result;
    }

    // ========================================================================
    // Resource Emission
    // ========================================================================

    fn emitShaders(self: *Self) Error!void {
        // Emit #wgsl and #shaderModule declarations
        var it = self.analysis.symbols.wgsl.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const info = entry.value_ptr.*;

            const shader_id = self.next_shader_id;
            self.next_shader_id += 1;
            try self.shader_ids.put(self.gpa, name, shader_id);

            // Get shader value and add to data section
            const value = self.findPropertyValue(info.node, "value") orelse continue;
            const code = self.getStringContent(value);
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

            // Find code property (data reference)
            const code_value = self.findPropertyValue(info.node, "code") orelse continue;
            const code = self.getStringContent(code_value);
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
        // TODO: Add create_texture opcode to bytecode emitter
        // For now, just track texture IDs
        var it = self.analysis.symbols.texture.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;

            const texture_id = self.next_texture_id;
            self.next_texture_id += 1;
            try self.texture_ids.put(self.gpa, name, texture_id);
        }
    }

    fn emitSamplers(self: *Self) Error!void {
        // TODO: Add create_sampler opcode to bytecode emitter
        // For now, just track sampler IDs
        var it = self.analysis.symbols.sampler.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;

            const sampler_id = self.next_sampler_id;
            self.next_sampler_id += 1;
            try self.sampler_ids.put(self.gpa, name, sampler_id);
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

            // Find shader reference
            const shader_id = self.resolveShaderForPipeline(info.node);

            try self.builder.getEmitter().createRenderPipeline(
                self.gpa,
                pipeline_id,
                shader_id,
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

            const shader_id = self.resolveShaderForPipeline(info.node);

            try self.builder.getEmitter().createComputePipeline(
                self.gpa,
                pipeline_id,
                shader_id,
            );
        }
    }

    fn emitBindGroups(self: *Self) Error!void {
        var it = self.analysis.symbols.bind_group.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            _ = entry.value_ptr;

            const group_id = self.next_bind_group_id;
            self.next_bind_group_id += 1;
            try self.bind_group_ids.put(self.gpa, name, group_id);

            // For now, emit a simple bind group with no entries
            try self.builder.getEmitter().createBindGroup(
                self.gpa,
                group_id,
                0, // layout_id
                0, // entry_count
            );
        }
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

        // Emit pass body commands
        try self.emitPassCommands(node);

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

        try self.emitPassCommands(node);
        try self.builder.getEmitter().endPassDef(self.gpa);
    }

    fn emitPassCommands(self: *Self, node: Node.Index) Error!void {
        // Look for specific properties that represent commands
        const data = self.ast.nodes.items(.data)[node.toInt()];
        const props = self.ast.extraData(data.extra_range);

        for (props) |prop_idx| {
            const prop_node: Node.Index = @enumFromInt(prop_idx);
            const prop_token = self.ast.nodes.items(.main_token)[prop_node.toInt()];
            const prop_name = self.getTokenSlice(prop_token);

            if (std.mem.eql(u8, prop_name, "pipeline")) {
                // Set pipeline
                if (self.findPropertyReference(prop_node)) |ref| {
                    if (self.pipeline_ids.get(ref.name)) |pipeline_id| {
                        try self.builder.getEmitter().setPipeline(self.gpa, pipeline_id);
                    }
                }
            } else if (std.mem.eql(u8, prop_name, "draw")) {
                // Draw command
                const prop_data = self.ast.nodes.items(.data)[prop_node.toInt()];
                const value_node = prop_data.node;
                const value_tag = self.ast.nodes.items(.tag)[value_node.toInt()];

                if (value_tag == .number_value) {
                    const count = self.parseNumber(value_node) orelse 3;
                    try self.builder.getEmitter().draw(self.gpa, count, 1);
                }
            } else if (std.mem.eql(u8, prop_name, "dispatch")) {
                // Dispatch command for compute
                const prop_data = self.ast.nodes.items(.data)[prop_node.toInt()];
                const value_node = prop_data.node;
                const value_tag = self.ast.nodes.items(.tag)[value_node.toInt()];

                if (value_tag == .array) {
                    // Parse [x, y, z]
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
                    // Execute pass by reference
                    if (self.getReference(elem)) |ref| {
                        if (self.pass_ids.get(ref.name)) |pass_id| {
                            try self.builder.getEmitter().execPass(self.gpa, pass_id);
                        }
                    }
                } else if (elem_tag == .identifier_value) {
                    // Execute pass by name
                    const name_token = self.ast.nodes.items(.main_token)[elem.toInt()];
                    const pass_name = self.getTokenSlice(name_token);
                    if (self.pass_ids.get(pass_name)) |pass_id| {
                        try self.builder.getEmitter().execPass(self.gpa, pass_id);
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

    fn resolveShaderForPipeline(self: *Self, node: Node.Index) u16 {
        // Look for vertex.module or compute.module
        const data = self.ast.nodes.items(.data)[node.toInt()];
        const props = self.ast.extraData(data.extra_range);

        for (props) |prop_idx| {
            const prop_node: Node.Index = @enumFromInt(prop_idx);
            const prop_token = self.ast.nodes.items(.main_token)[prop_node.toInt()];
            const prop_name = self.getTokenSlice(prop_token);

            if (std.mem.eql(u8, prop_name, "vertex") or std.mem.eql(u8, prop_name, "compute")) {
                // This is an object with module property
                const prop_data = self.ast.nodes.items(.data)[prop_node.toInt()];
                const obj_node = prop_data.node;
                const obj_tag = self.ast.nodes.items(.tag)[obj_node.toInt()];

                if (obj_tag == .object) {
                    const obj_data = self.ast.nodes.items(.data)[obj_node.toInt()];
                    const obj_props = self.ast.extraData(obj_data.extra_range);

                    for (obj_props) |obj_prop_idx| {
                        const inner_prop: Node.Index = @enumFromInt(obj_prop_idx);
                        const inner_token = self.ast.nodes.items(.main_token)[inner_prop.toInt()];
                        const inner_name = self.getTokenSlice(inner_token);

                        if (std.mem.eql(u8, inner_name, "module")) {
                            if (self.findPropertyReference(inner_prop)) |ref| {
                                if (self.shader_ids.get(ref.name)) |shader_id| {
                                    return shader_id;
                                }
                            }
                        }
                    }
                }
            }
        }

        return 0; // Default shader ID
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
