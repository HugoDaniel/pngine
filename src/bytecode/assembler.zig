//! PBSF to PNGB Assembler
//!
//! Translates a parsed PBSF AST into PNGB bytecode format.
//! Uses a two-pass approach:
//! 1. Collect pass: Gather strings and data blobs, assign resource IDs
//! 2. Emit pass: Generate bytecode using assigned IDs
//!
//! Invariants:
//! - All resource IDs ($name:N) map to valid indices
//! - Bytecode is emitted in correct execution order
//! - No recursion - uses explicit iteration

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const parser = @import("../pbsf/parser.zig");
const Ast = parser.Ast;
const Node = parser.Node;
const NodeIndex = parser.NodeIndex;
const format = @import("format.zig");
const Builder = format.Builder;
const opcodes = @import("opcodes.zig");
const StringId = @import("string_table.zig").StringId;
const DataId = @import("data_section.zig").DataId;

/// Assembler errors.
pub const AssembleError = error{
    /// Unknown form keyword (not module, data, shader, etc.)
    UnknownForm,
    /// Expected a specific form but got something else
    InvalidFormStructure,
    /// Resource ID reference not found
    UndefinedResource,
    /// Duplicate resource ID
    DuplicateResource,
    /// Too many resources of a type
    TooManyResources,
    /// Expected atom but got something else
    ExpectedAtom,
    /// Expected string but got something else
    ExpectedString,
    /// Expected number but got something else
    ExpectedNumber,
    /// Expected list but got something else
    ExpectedList,
    /// Invalid resource ID format (not $type:N)
    InvalidResourceId,
    /// Out of memory
    OutOfMemory,
};

/// Resource type for ID tracking.
pub const ResourceType = enum {
    data, // $d:N
    shader, // $shd:N
    buffer, // $buf:N
    texture, // $tex:N
    sampler, // $samp:N
    pipeline, // $pipe:N
    bind_group, // $bg:N
    pass, // $pass:N
    frame, // $frm:N

    /// Parse resource type from prefix.
    pub fn fromPrefix(prefix: []const u8) ?ResourceType {
        const map = std.StaticStringMap(ResourceType).initComptime(.{
            .{ "d", .data },
            .{ "shd", .shader },
            .{ "buf", .buffer },
            .{ "tex", .texture },
            .{ "samp", .sampler },
            .{ "pipe", .pipeline },
            .{ "bg", .bind_group },
            .{ "pass", .pass },
            .{ "frm", .frame },
        });
        return map.get(prefix);
    }
};

/// Parsed resource ID from $type:N format.
pub const ResourceId = struct {
    type: ResourceType,
    index: u16,

    /// Parse from atom like "$d:0" or "$shd:1".
    pub fn parse(atom: []const u8) ?ResourceId {
        // Must start with $
        if (atom.len < 3 or atom[0] != '$') return null;

        // Find colon separator
        const colon_pos = std.mem.indexOfScalar(u8, atom[1..], ':') orelse return null;
        const prefix = atom[1 .. colon_pos + 1];
        const index_str = atom[colon_pos + 2 ..];

        // Parse type
        const res_type = ResourceType.fromPrefix(prefix) orelse return null;

        // Parse index
        const index = std.fmt.parseInt(u16, index_str, 10) catch return null;

        return .{ .type = res_type, .index = index };
    }
};

/// Maximum resources per type.
const MAX_RESOURCES: u16 = 256;

/// PBSF form types recognized by the assembler.
const FormType = enum {
    module,
    data,
    shader,
    buffer,
    texture,
    sampler,
    render_pipeline,
    compute_pipeline,
    pipeline, // Shorthand: (pipeline N (json "..."))
    bind_group,
    pass,
    frame,
    // Pass commands
    set_pipeline,
    set_bind_group,
    set_vertex_buffer,
    draw,
    draw_indexed,
    dispatch,
    exec_pass,
    submit,
    // Frame-level commands (shorthand format)
    begin_render_pass,
    begin_compute_pass,
    end_pass,
    // Unknown/other
    unknown,

    /// Map keyword to form type.
    pub fn fromKeyword(keyword: []const u8) FormType {
        const map = std.StaticStringMap(FormType).initComptime(.{
            .{ "module", .module },
            .{ "data", .data },
            .{ "shader", .shader },
            .{ "buffer", .buffer },
            .{ "texture", .texture },
            .{ "sampler", .sampler },
            .{ "render-pipeline", .render_pipeline },
            .{ "compute-pipeline", .compute_pipeline },
            .{ "pipeline", .pipeline },
            .{ "bind-group", .bind_group },
            .{ "pass", .pass },
            .{ "frame", .frame },
            .{ "set-pipeline", .set_pipeline },
            .{ "set-bind-group", .set_bind_group },
            .{ "set-vertex-buffer", .set_vertex_buffer },
            .{ "draw", .draw },
            .{ "draw-indexed", .draw_indexed },
            .{ "dispatch", .dispatch },
            .{ "exec-pass", .exec_pass },
            .{ "submit", .submit },
            .{ "begin-render-pass", .begin_render_pass },
            .{ "begin-compute-pass", .begin_compute_pass },
            .{ "end-pass", .end_pass },
        });
        return map.get(keyword) orelse .unknown;
    }
};

/// Assembler state.
pub const Assembler = struct {
    const Self = @This();

    /// Allocator for temporary storage.
    gpa: Allocator,

    /// Builder for output PNGB.
    builder: Builder,

    /// Source AST.
    ast: *const Ast,

    /// Data ID mapping: data resource index -> DataId
    data_ids: [MAX_RESOURCES]?DataId,

    /// String ID mapping for names
    string_ids: std.StringHashMapUnmanaged(StringId),

    /// Track which resources have been defined.
    defined_shaders: std.StaticBitSet(MAX_RESOURCES),
    defined_pipelines: std.StaticBitSet(MAX_RESOURCES),
    defined_passes: std.StaticBitSet(MAX_RESOURCES),
    defined_frames: std.StaticBitSet(MAX_RESOURCES),
    defined_buffers: std.StaticBitSet(MAX_RESOURCES),

    pub fn init(gpa: Allocator, ast: *const Ast) Self {
        return .{
            .gpa = gpa,
            .builder = Builder.init(),
            .ast = ast,
            .data_ids = [_]?DataId{null} ** MAX_RESOURCES,
            .string_ids = .{},
            .defined_shaders = std.StaticBitSet(MAX_RESOURCES).initEmpty(),
            .defined_pipelines = std.StaticBitSet(MAX_RESOURCES).initEmpty(),
            .defined_passes = std.StaticBitSet(MAX_RESOURCES).initEmpty(),
            .defined_frames = std.StaticBitSet(MAX_RESOURCES).initEmpty(),
            .defined_buffers = std.StaticBitSet(MAX_RESOURCES).initEmpty(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.builder.deinit(self.gpa);
        // Free duplicated key strings before freeing the hashmap
        var it = self.string_ids.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
        }
        self.string_ids.deinit(self.gpa);
        self.* = undefined;
    }

    /// Assemble AST to PNGB bytes.
    /// Returns owned slice that caller must free.
    pub fn assemble(self: *Self) AssembleError![]u8 {
        // Pre-condition: AST has been parsed successfully
        assert(self.ast.errors.len == 0);

        // Get root children (should be single module)
        const root_children = self.ast.children(.root);
        if (root_children.len == 0) {
            const result = self.builder.finalize(self.gpa) catch return error.OutOfMemory;
            // Post-condition: empty module still has valid PNGB header
            assert(result.len >= format.HEADER_SIZE);
            return result;
        }

        // Process each top-level form
        for (root_children) |child| {
            try self.processTopLevel(child);
        }

        // Finalize and return PNGB bytes
        const result = self.builder.finalize(self.gpa) catch return error.OutOfMemory;

        // Post-condition: output has valid PNGB magic and minimum size
        assert(result.len >= format.HEADER_SIZE);
        assert(std.mem.eql(u8, result[0..4], format.MAGIC));

        return result;
    }

    /// Process a top-level form.
    /// Supports two modes:
    /// - Semantic: (module "name" ...forms...)
    /// - Shorthand: top-level (shader ...) (pipeline ...) (frame ...) without module wrapper
    fn processTopLevel(self: *Self, node: NodeIndex) AssembleError!void {
        const tag = self.ast.nodeTag(node);
        if (tag != .list) return error.ExpectedList;

        const children = self.ast.children(node);
        if (children.len == 0) return error.InvalidFormStructure;

        // First child should be keyword
        const keyword_node = children[0];
        if (self.ast.nodeTag(keyword_node) != .atom) return error.ExpectedAtom;

        const keyword = self.ast.tokenSlice(self.ast.nodeMainToken(keyword_node));
        const form_type = FormType.fromKeyword(keyword);

        switch (form_type) {
            .module => try self.processModule(children),
            // Shorthand top-level forms (no module wrapper)
            .shader, .pipeline, .frame => {
                // First do collect pass for this form
                try self.collectPass(node);
                // Then emit pass
                try self.emitPass(node);
            },
            else => return error.UnknownForm,
        }
    }

    /// Process (module "name" ...forms...).
    fn processModule(self: *Self, children: []const NodeIndex) AssembleError!void {
        // Pre-condition: children[0] is "module" keyword, children[1] is name
        assert(children.len >= 2);
        assert(self.ast.nodeTag(children[0]) == .atom);

        // children[1] should be module name
        if (self.ast.nodeTag(children[1]) != .string) return error.ExpectedString;

        // Pass 1: Collect data and strings (populates data_ids and string_ids)
        for (children[2..]) |child| {
            try self.collectPass(child);
        }

        // Pass 2: Emit bytecode (uses collected IDs to generate opcodes)
        for (children[2..]) |child| {
            try self.emitPass(child);
        }

        // Post-condition: emitter has generated some bytecode (even if just frame def)
        // For non-trivial modules, bytecode should be non-empty after emit pass
    }

    // ========================================================================
    // Pass 1: Collect data and strings
    // ========================================================================

    fn collectPass(self: *Self, node: NodeIndex) AssembleError!void {
        const tag = self.ast.nodeTag(node);
        if (tag != .list) return; // Skip non-lists in collect pass

        const children = self.ast.children(node);
        if (children.len == 0) return;

        const keyword_node = children[0];
        if (self.ast.nodeTag(keyword_node) != .atom) return;

        const keyword = self.ast.tokenSlice(self.ast.nodeMainToken(keyword_node));
        const form_type = FormType.fromKeyword(keyword);

        switch (form_type) {
            .data => try self.collectData(children),
            .pass => try self.collectPassDef(children),
            .frame => try self.collectFrame(children),
            else => {},
        }
    }

    /// Collect (data $d:N "content").
    /// Stores content in data section and maps resource ID to DataId for later use.
    fn collectData(self: *Self, children: []const NodeIndex) AssembleError!void {
        // Pre-condition: first child is "data" keyword
        assert(children.len >= 1);
        assert(self.ast.nodeTag(children[0]) == .atom);

        if (children.len < 3) return error.InvalidFormStructure;

        // children[1] is resource ID (e.g., "$d:0")
        if (self.ast.nodeTag(children[1]) != .atom) return error.ExpectedAtom;
        const id_str = self.ast.tokenSlice(self.ast.nodeMainToken(children[1]));
        const res_id = ResourceId.parse(id_str) orelse return error.InvalidResourceId;

        if (res_id.type != .data) return error.InvalidFormStructure;
        if (res_id.index >= MAX_RESOURCES) return error.TooManyResources;

        // children[2] is content string
        if (self.ast.nodeTag(children[2]) != .string) return error.ExpectedString;
        const content_raw = self.ast.tokenSlice(self.ast.nodeMainToken(children[2]));

        // Token includes surrounding quotes which aren't part of the actual content
        const content = self.stripQuotes(content_raw);

        // Add to builder's data section - returns ID for referencing in bytecode
        const data_id = self.builder.addData(self.gpa, content) catch return error.OutOfMemory;
        self.data_ids[res_id.index] = data_id;

        // Post-condition: data_ids now has mapping for this resource
        assert(self.data_ids[res_id.index] != null);
    }

    /// Collect (pass $pass:N "name" ...).
    fn collectPassDef(self: *Self, children: []const NodeIndex) AssembleError!void {
        if (children.len < 3) return error.InvalidFormStructure;

        // children[2] might be the name string
        if (children.len >= 3 and self.ast.nodeTag(children[2]) == .string) {
            const name_raw = self.ast.tokenSlice(self.ast.nodeMainToken(children[2]));
            const name = self.stripQuotes(name_raw);
            _ = try self.internString(name);
        }
    }

    /// Collect frame name string.
    /// Supports two formats:
    /// - Semantic: (frame $frm:N "name" ...) - name at children[2]
    /// - Shorthand: (frame "name" ...) - name at children[1]
    fn collectFrame(self: *Self, children: []const NodeIndex) AssembleError!void {
        if (children.len < 2) return error.InvalidFormStructure;

        // Shorthand format: (frame "name" ...)
        if (self.ast.nodeTag(children[1]) == .string) {
            const name_raw = self.ast.tokenSlice(self.ast.nodeMainToken(children[1]));
            const name = self.stripQuotes(name_raw);
            _ = try self.internString(name);
            return;
        }

        // Semantic format: (frame $frm:N "name" ...)
        if (children.len >= 3 and self.ast.nodeTag(children[2]) == .string) {
            const name_raw = self.ast.tokenSlice(self.ast.nodeMainToken(children[2]));
            const name = self.stripQuotes(name_raw);
            _ = try self.internString(name);
        }
    }

    // ========================================================================
    // Pass 2: Emit bytecode
    // ========================================================================

    fn emitPass(self: *Self, node: NodeIndex) AssembleError!void {
        const tag = self.ast.nodeTag(node);
        if (tag != .list) return;

        const children = self.ast.children(node);
        if (children.len == 0) return;

        const keyword_node = children[0];
        if (self.ast.nodeTag(keyword_node) != .atom) return;

        const keyword = self.ast.tokenSlice(self.ast.nodeMainToken(keyword_node));
        const form_type = FormType.fromKeyword(keyword);

        switch (form_type) {
            .shader => try self.emitShader(children),
            .buffer => try self.emitBuffer(children),
            .render_pipeline => try self.emitRenderPipeline(children),
            .compute_pipeline => try self.emitComputePipeline(children),
            .pipeline => try self.emitPipelineShorthand(children),
            .bind_group => try self.emitBindGroup(children),
            .pass => try self.emitPassDef(children),
            .frame => try self.emitFrame(children),
            .data => {}, // Already handled in collect pass
            else => {},
        }
    }

    /// Emit shader definition.
    /// Supports two formats:
    /// - Semantic: (shader $shd:N (code $d:N))
    /// - Shorthand: (shader N "code")
    fn emitShader(self: *Self, children: []const NodeIndex) AssembleError!void {
        if (children.len < 3) return error.InvalidFormStructure;

        const id_node = children[1];
        const id_tag = self.ast.nodeTag(id_node);

        // Shorthand format: (shader N "code") where N is a number
        if (id_tag == .number) {
            const id_str = self.ast.tokenSlice(self.ast.nodeMainToken(id_node));
            const shader_id = std.fmt.parseInt(u16, id_str, 10) catch return error.InvalidResourceId;
            if (self.defined_shaders.isSet(shader_id)) return error.DuplicateResource;
            self.defined_shaders.set(shader_id);

            // children[2] should be inline code string
            if (self.ast.nodeTag(children[2]) != .string) return error.ExpectedString;
            const code_raw = self.ast.tokenSlice(self.ast.nodeMainToken(children[2]));
            const code = self.stripQuotes(code_raw);

            // Store code in data section and emit
            const data_id = self.builder.addData(self.gpa, code) catch return error.OutOfMemory;
            const emitter = self.builder.getEmitter();
            emitter.createShaderModule(self.gpa, shader_id, data_id.toInt()) catch return error.OutOfMemory;
            return;
        }

        // Semantic format: (shader $shd:N (code $d:N))
        if (id_tag == .atom) {
            const shader_id = try self.parseResourceIndex(children[1], .shader);
            if (self.defined_shaders.isSet(shader_id)) return error.DuplicateResource;
            self.defined_shaders.set(shader_id);

            // Find (code $d:N) form
            var code_data_id: ?u16 = null;
            for (children[2..]) |child| {
                if (self.ast.nodeTag(child) == .list) {
                    const sub_children = self.ast.children(child);
                    if (sub_children.len >= 2) {
                        const sub_kw = self.ast.tokenSlice(self.ast.nodeMainToken(sub_children[0]));
                        if (std.mem.eql(u8, sub_kw, "code")) {
                            const data_idx = try self.parseResourceIndex(sub_children[1], .data);
                            const data_id = self.data_ids[data_idx] orelse return error.UndefinedResource;
                            code_data_id = data_id.toInt();
                            break;
                        }
                    }
                }
            }

            if (code_data_id == null) return error.InvalidFormStructure;

            const emitter = self.builder.getEmitter();
            emitter.createShaderModule(self.gpa, shader_id, code_data_id.?) catch return error.OutOfMemory;
            return;
        }

        return error.ExpectedAtom;
    }

    /// Emit (buffer $buf:N ...).
    fn emitBuffer(self: *Self, children: []const NodeIndex) AssembleError!void {
        if (children.len < 2) return error.InvalidFormStructure;

        const buffer_id = try self.parseResourceIndex(children[1], .buffer);
        if (self.defined_buffers.isSet(buffer_id)) return error.DuplicateResource;
        self.defined_buffers.set(buffer_id);

        // Parse size and usage from children
        var size: u32 = 0;
        var usage: opcodes.BufferUsage = @bitCast(@as(u8, 0));

        for (children[2..]) |child| {
            if (self.ast.nodeTag(child) == .list) {
                const sub_children = self.ast.children(child);
                if (sub_children.len >= 2 and self.ast.nodeTag(sub_children[0]) == .atom) {
                    const sub_kw = self.ast.tokenSlice(self.ast.nodeMainToken(sub_children[0]));
                    if (std.mem.eql(u8, sub_kw, "size")) {
                        size = try self.parseNumber(sub_children[1]);
                    } else if (std.mem.eql(u8, sub_kw, "usage")) {
                        usage = @bitCast(@as(u8, @intCast(try self.parseNumber(sub_children[1]))));
                    }
                }
            }
        }

        const emitter = self.builder.getEmitter();
        emitter.createBuffer(self.gpa, buffer_id, size, usage) catch return error.OutOfMemory;
    }

    /// Emit (render-pipeline $pipe:N ...).
    fn emitRenderPipeline(self: *Self, children: []const NodeIndex) AssembleError!void {
        if (children.len < 2) return error.InvalidFormStructure;

        const pipeline_id = try self.parseResourceIndex(children[1], .pipeline);
        if (self.defined_pipelines.isSet(pipeline_id)) return error.DuplicateResource;
        self.defined_pipelines.set(pipeline_id);

        // For now, use a placeholder descriptor
        // In a full implementation, we'd serialize the pipeline config
        const desc_id = self.builder.addData(self.gpa, "{}") catch return error.OutOfMemory;

        const emitter = self.builder.getEmitter();
        emitter.createRenderPipeline(self.gpa, pipeline_id, desc_id.toInt()) catch return error.OutOfMemory;
    }

    /// Emit (compute-pipeline $pipe:N ...).
    fn emitComputePipeline(self: *Self, children: []const NodeIndex) AssembleError!void {
        if (children.len < 2) return error.InvalidFormStructure;

        const pipeline_id = try self.parseResourceIndex(children[1], .pipeline);
        if (self.defined_pipelines.isSet(pipeline_id)) return error.DuplicateResource;
        self.defined_pipelines.set(pipeline_id);

        const desc_id = self.builder.addData(self.gpa, "{}") catch return error.OutOfMemory;

        const emitter = self.builder.getEmitter();
        emitter.createComputePipeline(self.gpa, pipeline_id, desc_id.toInt()) catch return error.OutOfMemory;
    }

    /// Emit (pipeline N (json "...")) shorthand format.
    /// Creates render pipeline with explicit JSON descriptor.
    fn emitPipelineShorthand(self: *Self, children: []const NodeIndex) AssembleError!void {
        if (children.len < 3) return error.InvalidFormStructure;

        // children[1] is numeric pipeline ID (can be .number or .atom)
        const id_tag = self.ast.nodeTag(children[1]);
        if (id_tag != .number and id_tag != .atom) return error.ExpectedAtom;
        const id_str = self.ast.tokenSlice(self.ast.nodeMainToken(children[1]));
        const pipeline_id = std.fmt.parseInt(u16, id_str, 10) catch return error.InvalidResourceId;

        if (self.defined_pipelines.isSet(pipeline_id)) return error.DuplicateResource;
        self.defined_pipelines.set(pipeline_id);

        // children[2] should be (json "...")
        if (self.ast.nodeTag(children[2]) != .list) return error.ExpectedList;
        const json_children = self.ast.children(children[2]);
        if (json_children.len < 2) return error.InvalidFormStructure;

        // First child should be "json" keyword
        if (self.ast.nodeTag(json_children[0]) != .atom) return error.ExpectedAtom;
        const kw = self.ast.tokenSlice(self.ast.nodeMainToken(json_children[0]));
        if (!std.mem.eql(u8, kw, "json")) return error.InvalidFormStructure;

        // Second child is the JSON string
        if (self.ast.nodeTag(json_children[1]) != .string) return error.ExpectedString;
        const json_raw = self.ast.tokenSlice(self.ast.nodeMainToken(json_children[1]));
        const json_str = self.stripQuotes(json_raw);

        // Store JSON in data section and emit
        const desc_id = self.builder.addData(self.gpa, json_str) catch return error.OutOfMemory;
        const emitter = self.builder.getEmitter();
        emitter.createRenderPipeline(self.gpa, pipeline_id, desc_id.toInt()) catch return error.OutOfMemory;
    }

    /// Emit (bind-group $bg:N ...).
    fn emitBindGroup(self: *Self, children: []const NodeIndex) AssembleError!void {
        if (children.len < 2) return error.InvalidFormStructure;

        const bg_id = try self.parseResourceIndex(children[1], .bind_group);

        // Parse layout reference and entries
        var layout_id: u16 = 0;
        const entries_id = self.builder.addData(self.gpa, "[]") catch return error.OutOfMemory;

        // Find layout if specified
        for (children[2..]) |child| {
            if (self.ast.nodeTag(child) == .list) {
                const sub_children = self.ast.children(child);
                if (sub_children.len >= 2 and self.ast.nodeTag(sub_children[0]) == .atom) {
                    const sub_kw = self.ast.tokenSlice(self.ast.nodeMainToken(sub_children[0]));
                    if (std.mem.eql(u8, sub_kw, "layout")) {
                        layout_id = @intCast(try self.parseNumber(sub_children[1]));
                    }
                }
            }
        }

        const emitter = self.builder.getEmitter();
        emitter.createBindGroup(self.gpa, bg_id, layout_id, entries_id.toInt()) catch return error.OutOfMemory;
    }

    /// Emit (pass $pass:N "name" (render|compute ...)).
    fn emitPassDef(self: *Self, children: []const NodeIndex) AssembleError!void {
        if (children.len < 3) return error.InvalidFormStructure;

        const pass_id = try self.parseResourceIndex(children[1], .pass);
        if (self.defined_passes.isSet(pass_id)) return error.DuplicateResource;
        self.defined_passes.set(pass_id);

        // Determine pass type and emit
        var pass_type: opcodes.PassType = .render;
        var pass_body_idx: usize = 2;

        // Check if there's a name string
        if (self.ast.nodeTag(children[2]) == .string) {
            pass_body_idx = 3;
        }

        // Find the render/compute block
        for (children[pass_body_idx..]) |child| {
            if (self.ast.nodeTag(child) == .list) {
                const sub_children = self.ast.children(child);
                if (sub_children.len > 0 and self.ast.nodeTag(sub_children[0]) == .atom) {
                    const sub_kw = self.ast.tokenSlice(self.ast.nodeMainToken(sub_children[0]));
                    if (std.mem.eql(u8, sub_kw, "render")) {
                        pass_type = .render;
                        try self.emitPassBody(sub_children, pass_id, pass_type);
                        break;
                    } else if (std.mem.eql(u8, sub_kw, "compute")) {
                        pass_type = .compute;
                        try self.emitPassBody(sub_children, pass_id, pass_type);
                        break;
                    }
                }
            }
        }
    }

    /// Emit pass body (commands within render/compute block).
    /// Uses direct begin/end pass commands for immediate execution, rather than
    /// the define/exec template pattern which would require runtime pass lookup.
    fn emitPassBody(self: *Self, children: []const NodeIndex, pass_id: u16, pass_type: opcodes.PassType) AssembleError!void {
        // Template ID not used - direct execution inlines the pass commands
        _ = pass_id;
        const emitter = self.builder.getEmitter();

        // GPU requires explicit pass begin before any draw/dispatch commands
        switch (pass_type) {
            .render => emitter.beginRenderPass(self.gpa, 0, .clear, .store) catch return error.OutOfMemory,
            .compute => emitter.beginComputePass(self.gpa) catch return error.OutOfMemory,
        }

        // Find and emit the commands block - commands are nested under (commands ...)
        // to allow future extensions like attachments before the command list
        for (children) |child| {
            if (self.ast.nodeTag(child) == .list) {
                const sub_children = self.ast.children(child);
                if (sub_children.len > 0 and self.ast.nodeTag(sub_children[0]) == .atom) {
                    const sub_kw = self.ast.tokenSlice(self.ast.nodeMainToken(sub_children[0]));
                    if (std.mem.eql(u8, sub_kw, "commands")) {
                        try self.emitCommands(sub_children);
                        break;
                    }
                }
            }
        }

        // GPU requires explicit pass end to finalize render targets
        emitter.endPass(self.gpa) catch return error.OutOfMemory;
    }

    /// Emit commands within a pass.
    fn emitCommands(self: *Self, children: []const NodeIndex) AssembleError!void {
        const emitter = self.builder.getEmitter();

        for (children[1..]) |child| {
            if (self.ast.nodeTag(child) != .list) continue;

            const cmd_children = self.ast.children(child);
            if (cmd_children.len == 0) continue;
            if (self.ast.nodeTag(cmd_children[0]) != .atom) continue;

            const cmd_kw = self.ast.tokenSlice(self.ast.nodeMainToken(cmd_children[0]));
            const form_type = FormType.fromKeyword(cmd_kw);

            switch (form_type) {
                .set_pipeline => {
                    if (cmd_children.len < 2) continue;
                    const pipe_id = try self.parseResourceIndex(cmd_children[1], .pipeline);
                    emitter.setPipeline(self.gpa, pipe_id) catch return error.OutOfMemory;
                },
                .set_bind_group => {
                    if (cmd_children.len < 3) continue;
                    const slot = @as(u8, @intCast(try self.parseNumber(cmd_children[1])));
                    const bg_id = try self.parseResourceIndex(cmd_children[2], .bind_group);
                    emitter.setBindGroup(self.gpa, slot, bg_id) catch return error.OutOfMemory;
                },
                .set_vertex_buffer => {
                    if (cmd_children.len < 3) continue;
                    const slot = @as(u8, @intCast(try self.parseNumber(cmd_children[1])));
                    const buf_id = try self.parseResourceIndex(cmd_children[2], .buffer);
                    emitter.setVertexBuffer(self.gpa, slot, buf_id) catch return error.OutOfMemory;
                },
                .draw => {
                    if (cmd_children.len < 3) continue;
                    const vertex_count = try self.parseNumber(cmd_children[1]);
                    const instance_count = try self.parseNumber(cmd_children[2]);
                    emitter.draw(self.gpa, vertex_count, instance_count) catch return error.OutOfMemory;
                },
                .draw_indexed => {
                    if (cmd_children.len < 3) continue;
                    const index_count = try self.parseNumber(cmd_children[1]);
                    const instance_count = try self.parseNumber(cmd_children[2]);
                    emitter.drawIndexed(self.gpa, index_count, instance_count) catch return error.OutOfMemory;
                },
                .dispatch => {
                    if (cmd_children.len < 4) continue;
                    const x = try self.parseNumber(cmd_children[1]);
                    const y = try self.parseNumber(cmd_children[2]);
                    const z = try self.parseNumber(cmd_children[3]);
                    emitter.dispatch(self.gpa, x, y, z) catch return error.OutOfMemory;
                },
                else => {},
            }
        }
    }

    /// Emit frame definition.
    /// Supports two formats:
    /// - Semantic: (frame $frm:N "name" (exec-pass $pass:N) (submit))
    /// - Shorthand: (frame "name" (begin-render-pass ...) (set-pipeline N) (draw ...) (end-pass) (submit))
    fn emitFrame(self: *Self, children: []const NodeIndex) AssembleError!void {
        if (children.len < 2) return error.InvalidFormStructure;

        const emitter = self.builder.getEmitter();

        // Detect format: if children[1] is a string, it's shorthand format
        const is_shorthand = self.ast.nodeTag(children[1]) == .string;

        var frame_id: u16 = 0;
        var name_id: u16 = 0;
        var cmd_start_idx: usize = 2;

        if (is_shorthand) {
            // Shorthand format: (frame "name" ...commands...)
            // Auto-assign frame ID 0 (or next available)
            while (self.defined_frames.isSet(frame_id) and frame_id < MAX_RESOURCES) {
                frame_id += 1;
            }
            if (frame_id >= MAX_RESOURCES) return error.TooManyResources;
            self.defined_frames.set(frame_id);

            const name_raw = self.ast.tokenSlice(self.ast.nodeMainToken(children[1]));
            const name = self.stripQuotes(name_raw);
            const str_id = try self.internString(name);
            name_id = str_id.toInt();
            cmd_start_idx = 2;
        } else {
            // Semantic format: (frame $frm:N "name" ...)
            if (children.len < 3) return error.InvalidFormStructure;
            frame_id = try self.parseResourceIndex(children[1], .frame);
            if (self.defined_frames.isSet(frame_id)) return error.DuplicateResource;
            self.defined_frames.set(frame_id);

            if (self.ast.nodeTag(children[2]) == .string) {
                const name_raw = self.ast.tokenSlice(self.ast.nodeMainToken(children[2]));
                const name = self.stripQuotes(name_raw);
                const str_id = try self.internString(name);
                name_id = str_id.toInt();
                cmd_start_idx = 3;
            }
        }

        emitter.defineFrame(self.gpa, frame_id, name_id) catch return error.OutOfMemory;

        // Process frame commands
        for (children[cmd_start_idx..]) |child| {
            if (self.ast.nodeTag(child) != .list) continue;

            const cmd_children = self.ast.children(child);
            if (cmd_children.len == 0) continue;
            if (self.ast.nodeTag(cmd_children[0]) != .atom) continue;

            const cmd_kw = self.ast.tokenSlice(self.ast.nodeMainToken(cmd_children[0]));
            const form_type = FormType.fromKeyword(cmd_kw);

            switch (form_type) {
                .exec_pass => {
                    if (cmd_children.len < 2) continue;
                    const pass_id = try self.parseResourceIndex(cmd_children[1], .pass);
                    emitter.execPass(self.gpa, pass_id) catch return error.OutOfMemory;
                },
                .submit => {
                    emitter.submit(self.gpa) catch return error.OutOfMemory;
                },
                // Shorthand frame-level commands
                .begin_render_pass => {
                    // Parse (begin-render-pass :texture N :load clear :store store)
                    var texture_id: u16 = 0;
                    var load_op: opcodes.LoadOp = .clear;
                    var store_op: opcodes.StoreOp = .store;

                    var i: usize = 1;
                    while (i < cmd_children.len) : (i += 1) {
                        const tag = self.ast.nodeTag(cmd_children[i]);
                        // Keywords like :texture, :load, :store are atoms
                        if (tag != .atom) continue;
                        const arg = self.ast.tokenSlice(self.ast.nodeMainToken(cmd_children[i]));

                        if (std.mem.eql(u8, arg, ":texture")) {
                            i += 1;
                            if (i < cmd_children.len and self.ast.nodeTag(cmd_children[i]) == .number) {
                                texture_id = @intCast(try self.parseNumber(cmd_children[i]));
                            }
                        } else if (std.mem.eql(u8, arg, ":load")) {
                            i += 1;
                            if (i < cmd_children.len and self.ast.nodeTag(cmd_children[i]) == .atom) {
                                const val = self.ast.tokenSlice(self.ast.nodeMainToken(cmd_children[i]));
                                load_op = if (std.mem.eql(u8, val, "load")) .load else .clear;
                            }
                        } else if (std.mem.eql(u8, arg, ":store")) {
                            i += 1;
                            if (i < cmd_children.len and self.ast.nodeTag(cmd_children[i]) == .atom) {
                                const val = self.ast.tokenSlice(self.ast.nodeMainToken(cmd_children[i]));
                                store_op = if (std.mem.eql(u8, val, "discard")) .discard else .store;
                            }
                        }
                    }
                    emitter.beginRenderPass(self.gpa, texture_id, load_op, store_op) catch return error.OutOfMemory;
                },
                .begin_compute_pass => {
                    emitter.beginComputePass(self.gpa) catch return error.OutOfMemory;
                },
                .end_pass => {
                    emitter.endPass(self.gpa) catch return error.OutOfMemory;
                },
                .set_pipeline => {
                    // Shorthand: (set-pipeline N) where N is numeric
                    if (cmd_children.len < 2) continue;
                    const pipe_tag = self.ast.nodeTag(cmd_children[1]);
                    if (pipe_tag == .number) {
                        // Numeric ID
                        const id_str = self.ast.tokenSlice(self.ast.nodeMainToken(cmd_children[1]));
                        const pipe_id = std.fmt.parseInt(u16, id_str, 10) catch continue;
                        emitter.setPipeline(self.gpa, pipe_id) catch return error.OutOfMemory;
                    } else if (pipe_tag == .atom) {
                        // Resource ID like $pipe:0
                        const pipe_id = try self.parseResourceIndex(cmd_children[1], .pipeline);
                        emitter.setPipeline(self.gpa, pipe_id) catch return error.OutOfMemory;
                    }
                },
                .draw => {
                    // (draw N M) where N=vertex_count, M=instance_count
                    if (cmd_children.len < 3) continue;
                    const vertex_count = try self.parseNumber(cmd_children[1]);
                    const instance_count = try self.parseNumber(cmd_children[2]);
                    emitter.draw(self.gpa, vertex_count, instance_count) catch return error.OutOfMemory;
                },
                .draw_indexed => {
                    if (cmd_children.len < 3) continue;
                    const index_count = try self.parseNumber(cmd_children[1]);
                    const instance_count = try self.parseNumber(cmd_children[2]);
                    emitter.drawIndexed(self.gpa, index_count, instance_count) catch return error.OutOfMemory;
                },
                .dispatch => {
                    if (cmd_children.len < 4) continue;
                    const x = try self.parseNumber(cmd_children[1]);
                    const y = try self.parseNumber(cmd_children[2]);
                    const z = try self.parseNumber(cmd_children[3]);
                    emitter.dispatch(self.gpa, x, y, z) catch return error.OutOfMemory;
                },
                else => {},
            }
        }

        emitter.endFrame(self.gpa) catch return error.OutOfMemory;
    }

    // ========================================================================
    // Helper functions
    // ========================================================================

    /// Parse resource index from a node, verifying type.
    fn parseResourceIndex(self: *Self, node: NodeIndex, expected_type: ResourceType) AssembleError!u16 {
        if (self.ast.nodeTag(node) != .atom) return error.ExpectedAtom;

        const id_str = self.ast.tokenSlice(self.ast.nodeMainToken(node));
        const res_id = ResourceId.parse(id_str) orelse return error.InvalidResourceId;

        if (res_id.type != expected_type) return error.InvalidFormStructure;
        if (res_id.index >= MAX_RESOURCES) return error.TooManyResources;

        return res_id.index;
    }

    /// Parse a number from a node.
    fn parseNumber(self: *Self, node: NodeIndex) AssembleError!u32 {
        if (self.ast.nodeTag(node) != .number) return error.ExpectedNumber;

        const num_str = self.ast.tokenSlice(self.ast.nodeMainToken(node));
        return std.fmt.parseInt(u32, num_str, 10) catch return error.ExpectedNumber;
    }

    /// Strip surrounding quotes from a string literal token.
    /// The tokenizer preserves quotes in string tokens, but for data content
    /// we need the actual string value without the delimiters.
    fn stripQuotes(self: *Self, raw: []const u8) []const u8 {
        _ = self;
        if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
            return raw[1 .. raw.len - 1];
        }
        return raw;
    }

    /// Intern a string, returning existing ID if already interned.
    /// Deduplicates identical strings to save space in the string table.
    ///
    /// Complexity: O(1) hashmap lookup on hit, O(n) string copy on miss.
    fn internString(self: *Self, str: []const u8) AssembleError!StringId {
        // Check if already interned to avoid duplicate entries
        if (self.string_ids.get(str)) |existing| {
            return existing;
        }

        const id = self.builder.internString(self.gpa, str) catch return error.OutOfMemory;

        // Must duplicate key because AST source buffer may be freed before
        // we're done using the hashmap for lookups
        const key_copy = self.gpa.dupe(u8, str) catch return error.OutOfMemory;
        self.string_ids.put(self.gpa, key_copy, id) catch {
            self.gpa.free(key_copy);
            return error.OutOfMemory;
        };

        return id;
    }
};

/// Convenience function to assemble PBSF AST to PNGB bytes.
/// Caller owns the returned slice and must free it with the same allocator.
///
/// Complexity: O(n) where n is total AST nodes - two passes over the tree.
pub fn assemble(gpa: Allocator, ast: *const Ast) AssembleError![]u8 {
    // Pre-condition: AST must be error-free for assembly to succeed
    assert(ast.errors.len == 0);

    var assembler = Assembler.init(gpa, ast);
    defer assembler.deinit();

    const result = try assembler.assemble();

    // Post-condition: result is valid PNGB (checked in Assembler.assemble)
    assert(result.len >= format.HEADER_SIZE);

    return result;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "ResourceId.parse valid IDs" {
    try testing.expectEqual(ResourceId{ .type = .data, .index = 0 }, ResourceId.parse("$d:0"));
    try testing.expectEqual(ResourceId{ .type = .shader, .index = 1 }, ResourceId.parse("$shd:1"));
    try testing.expectEqual(ResourceId{ .type = .pipeline, .index = 42 }, ResourceId.parse("$pipe:42"));
    try testing.expectEqual(ResourceId{ .type = .frame, .index = 255 }, ResourceId.parse("$frm:255"));
}

test "ResourceId.parse invalid IDs" {
    try testing.expectEqual(@as(?ResourceId, null), ResourceId.parse("d:0")); // Missing $
    try testing.expectEqual(@as(?ResourceId, null), ResourceId.parse("$x:0")); // Unknown type
    try testing.expectEqual(@as(?ResourceId, null), ResourceId.parse("$d0")); // Missing colon
    try testing.expectEqual(@as(?ResourceId, null), ResourceId.parse("$d:")); // Missing index
}

test "FormType.fromKeyword" {
    try testing.expectEqual(FormType.module, FormType.fromKeyword("module"));
    try testing.expectEqual(FormType.data, FormType.fromKeyword("data"));
    try testing.expectEqual(FormType.shader, FormType.fromKeyword("shader"));
    try testing.expectEqual(FormType.render_pipeline, FormType.fromKeyword("render-pipeline"));
    try testing.expectEqual(FormType.draw, FormType.fromKeyword("draw"));
    try testing.expectEqual(FormType.unknown, FormType.fromKeyword("foobar"));
}

test "assemble minimal module" {
    const source: [:0]const u8 = "(module \"test\")";
    var ast = try parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), ast.errors.len);

    const pngb = try assemble(testing.allocator, &ast);
    defer testing.allocator.free(pngb);

    try testing.expect(pngb.len >= format.HEADER_SIZE);
    try testing.expectEqualStrings("PNGB", pngb[0..4]);
}

test "assemble module with data" {
    const source: [:0]const u8 =
        \\(module "test"
        \\  (data $d:0 "hello world"))
    ;
    var ast = try parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    const pngb = try assemble(testing.allocator, &ast);
    defer testing.allocator.free(pngb);

    // Deserialize and verify
    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 1), module.data.count());
    try testing.expectEqualStrings("hello world", module.data.get(@enumFromInt(0)));
}

test "assemble module with shader" {
    const source: [:0]const u8 =
        \\(module "test"
        \\  (data $d:0 "shader code")
        \\  (shader $shd:0 (code $d:0)))
    ;
    var ast = try parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    const pngb = try assemble(testing.allocator, &ast);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify bytecode contains create_shader_module
    try testing.expectEqual(@as(u8, @intFromEnum(opcodes.OpCode.create_shader_module)), module.bytecode[0]);
}

test "assemble complete pipeline" {
    const source: [:0]const u8 =
        \\(module "triangle"
        \\  (data $d:0 "vs code")
        \\  (shader $shd:0 (code $d:0))
        \\  (render-pipeline $pipe:0)
        \\  (pass $pass:0 "main"
        \\    (render
        \\      (commands
        \\        (set-pipeline $pipe:0)
        \\        (draw 3 1))))
        \\  (frame $frm:0 "frame"
        \\    (exec-pass $pass:0)
        \\    (submit)))
    ;
    var ast = try parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    const pngb = try assemble(testing.allocator, &ast);
    defer testing.allocator.free(pngb);

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify bytecode sequence
    var pos: usize = 0;

    // create_shader_module
    try testing.expectEqual(@as(u8, @intFromEnum(opcodes.OpCode.create_shader_module)), module.bytecode[pos]);
    pos += 3;

    // create_render_pipeline
    try testing.expectEqual(@as(u8, @intFromEnum(opcodes.OpCode.create_render_pipeline)), module.bytecode[pos]);
}

test "assemble handles OOM gracefully" {
    // Parse with normal allocator first (parsing is separate from assembly)
    const source: [:0]const u8 =
        \\(module "test"
        \\  (data $d:0 "shader code")
        \\  (shader $shd:0 (code $d:0))
        \\  (render-pipeline $pipe:0)
        \\  (frame $frm:0 "main"
        \\    (submit)))
    ;
    var ast = try parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    // Now test assembly with failing allocator at each allocation point
    var fail_index: usize = 0;
    const max_iterations: usize = 500;

    for (0..max_iterations) |_| {
        var failing_alloc = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });

        const result = assemble(failing_alloc.allocator(), &ast);

        if (failing_alloc.has_induced_failure) {
            // OOM occurred - verify graceful handling (no crash, returns error)
            try testing.expectError(error.OutOfMemory, result);
        } else {
            // No OOM - operation succeeded, test complete
            const pngb = try result;
            failing_alloc.allocator().free(pngb);
            break;
        }

        fail_index += 1;
    } else {
        unreachable; // Should complete within max_iterations
    }
}

test "fuzz assembler properties" {
    // Property-based test: assembler should never crash on valid AST
    // and should produce valid PNGB on valid input
    try std.testing.fuzz(.{}, fuzzAssemblerProperties, .{});
}

fn fuzzAssemblerProperties(_: @TypeOf(.{}), input: []const u8) !void {
    // Convert to sentinel-terminated for parser
    var buf: [4096]u8 = undefined;
    if (input.len + 1 > buf.len) return;
    @memcpy(buf[0..input.len], input);
    buf[input.len] = 0;
    const source = buf[0..input.len :0];

    // Try to parse - may fail on invalid input, that's expected
    var ast = parser.parse(testing.allocator, source) catch return;
    defer ast.deinit(testing.allocator);

    // If parsing succeeded but has errors, skip assembly
    if (ast.errors.len > 0) return;

    // Try to assemble - may fail on semantically invalid AST
    const pngb = assemble(testing.allocator, &ast) catch return;
    defer testing.allocator.free(pngb);

    // Property 1: Output has valid PNGB magic
    try testing.expect(pngb.len >= 4);
    try testing.expectEqualStrings("PNGB", pngb[0..4]);

    // Property 2: Output can be deserialized without crash
    var module = format.deserialize(testing.allocator, pngb) catch return;
    defer module.deinit(testing.allocator);

    // Property 3: Bytecode length is bounded by input size
    // (bytecode shouldn't be exponentially larger than input)
    try testing.expect(module.bytecode.len <= input.len * 10 + 100);
}
