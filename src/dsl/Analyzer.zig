//! Semantic Analyzer for PNGine DSL
//!
//! Performs semantic analysis on the parsed AST in multiple passes.
//!
//! ## Passes
//!
//! 1. **Collect Declarations**: Build symbol tables for each namespace
//! 2. **Resolve References**: Validate all `$namespace.name` references
//! 3. **Detect Cycles**: Find circular dependencies in #wgsl imports
//! 4. **Deduplicate Shaders**: Hash shader content for deduplication
//!
//! ## Design
//!
//! - **No recursion**: Cycle detection uses iterative DFS with explicit stack
//! - **Bounded loops**: DFS bounded by MAX_DFS_DEPTH
//! - **StaticStringMap**: O(1) namespace string lookup
//! - **Symbol tables per namespace**: Separate hashmaps for each resource type
//!
//! ## Invariants
//!
//! - AST must have root node at index 0 before analysis
//! - All references must be resolvable (errors collected otherwise)
//! - No circular dependencies in import chains
//! - Each symbol defined exactly once per namespace
//! - Shader fragments with identical content share data_id
//! - Errors are collected, not fatal (analysis continues)
//!
//! ## Complexity
//!
//! - `analyze()`: O(nodes + references + imports²) worst case
//! - Cycle detection: O(V + E) where V = #wgsl count, E = imports

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig").Ast;
const Node = @import("Ast.zig").Node;

pub const Analyzer = struct {
    /// General-purpose allocator for analysis structures.
    gpa: Allocator,

    /// Reference to the AST being analyzed.
    /// Invariant: ast.nodes[0].tag == .root.
    ast: *const Ast,

    /// Symbol tables mapping names to definitions, organized by namespace.
    /// Each namespace (wgsl, buffer, etc.) has its own hashmap.
    symbols: SymbolTable,

    /// Collected analysis errors. Errors don't stop analysis.
    /// Invariant: all error nodes are valid indices in ast.nodes.
    errors: std.ArrayListUnmanaged(AnalysisError),

    /// Deduplicated shader fragments for bytecode emission.
    /// Fragments with identical content share the same data_id.
    shader_fragments: std.ArrayListUnmanaged(ShaderFragment),

    /// Map from identifier_value node index to resolved namespace.
    /// Used for bare name resolution (e.g., `module=code` → `$shaderModule.code`).
    resolved_identifiers: std.AutoHashMapUnmanaged(u32, ResolvedIdentifier),

    /// Map from uniform_access node index to resolved uniform metadata.
    /// Used by emitter to generate write_time_uniform opcodes.
    resolved_uniforms: std.AutoHashMapUnmanaged(u32, UniformInfo),

    /// Dependency graph for cycle detection in #wgsl imports.
    /// Only populated for symbols with dependencies.
    dep_graph: DependencyGraph,

    const Self = @This();

    pub const Error = error{
        OutOfMemory,
        AnalysisError,
    };

    pub const AnalysisError = struct {
        /// Category of the error for programmatic handling.
        kind: Kind,

        /// AST node where the error occurred.
        node: Node.Index,

        /// Human-readable error description.
        message: []const u8,

        pub const Kind = enum {
            /// Reference to undefined symbol ($namespace.missing).
            undefined_reference,
            /// Symbol defined more than once in same namespace.
            duplicate_definition,
            /// Circular dependency in #wgsl imports.
            circular_dependency,
            /// Reference uses invalid namespace name.
            invalid_reference_namespace,
            /// Required property not provided.
            missing_required_property,
            /// Property value has wrong type.
            type_mismatch,
        };
    };

    /// Global symbol info for cross-namespace uniqueness checking.
    /// Stores which namespace a name was first defined in.
    pub const GlobalSymbolInfo = struct {
        namespace: Namespace,
        node: u32,
    };

    pub const SymbolTable = struct {
        /// Global map: name -> first definition (for uniqueness check).
        /// All resource IDs must be unique across the entire bundled DSL.
        all_names: std.StringHashMapUnmanaged(GlobalSymbolInfo),

        // Maps name -> SymbolInfo for each namespace
        wgsl: std.StringHashMapUnmanaged(SymbolInfo),
        buffer: std.StringHashMapUnmanaged(SymbolInfo),
        texture: std.StringHashMapUnmanaged(SymbolInfo),
        sampler: std.StringHashMapUnmanaged(SymbolInfo),
        bind_group: std.StringHashMapUnmanaged(SymbolInfo),
        bind_group_layout: std.StringHashMapUnmanaged(SymbolInfo),
        pipeline_layout: std.StringHashMapUnmanaged(SymbolInfo),
        render_pipeline: std.StringHashMapUnmanaged(SymbolInfo),
        compute_pipeline: std.StringHashMapUnmanaged(SymbolInfo),
        render_pass: std.StringHashMapUnmanaged(SymbolInfo),
        compute_pass: std.StringHashMapUnmanaged(SymbolInfo),
        frame: std.StringHashMapUnmanaged(SymbolInfo),
        shader_module: std.StringHashMapUnmanaged(SymbolInfo),
        data: std.StringHashMapUnmanaged(SymbolInfo),
        define: std.StringHashMapUnmanaged(SymbolInfo),
        queue: std.StringHashMapUnmanaged(SymbolInfo),
        image_bitmap: std.StringHashMapUnmanaged(SymbolInfo),
        wasm_call: std.StringHashMapUnmanaged(SymbolInfo),
        query_set: std.StringHashMapUnmanaged(SymbolInfo),
        texture_view: std.StringHashMapUnmanaged(SymbolInfo),
        animation: std.StringHashMapUnmanaged(SymbolInfo),

        pub fn init() SymbolTable {
            return .{
                .all_names = .{},
                .wgsl = .{},
                .buffer = .{},
                .texture = .{},
                .sampler = .{},
                .bind_group = .{},
                .bind_group_layout = .{},
                .pipeline_layout = .{},
                .render_pipeline = .{},
                .compute_pipeline = .{},
                .render_pass = .{},
                .compute_pass = .{},
                .frame = .{},
                .shader_module = .{},
                .data = .{},
                .define = .{},
                .queue = .{},
                .image_bitmap = .{},
                .wasm_call = .{},
                .query_set = .{},
                .texture_view = .{},
                .animation = .{},
            };
        }

        pub fn deinit(self: *SymbolTable, gpa: Allocator) void {
            self.all_names.deinit(gpa);
            self.wgsl.deinit(gpa);
            self.buffer.deinit(gpa);
            self.texture.deinit(gpa);
            self.sampler.deinit(gpa);
            self.bind_group.deinit(gpa);
            self.bind_group_layout.deinit(gpa);
            self.pipeline_layout.deinit(gpa);
            self.render_pipeline.deinit(gpa);
            self.compute_pipeline.deinit(gpa);
            self.render_pass.deinit(gpa);
            self.compute_pass.deinit(gpa);
            self.frame.deinit(gpa);
            self.shader_module.deinit(gpa);
            self.data.deinit(gpa);
            self.define.deinit(gpa);
            self.queue.deinit(gpa);
            self.image_bitmap.deinit(gpa);
            self.wasm_call.deinit(gpa);
            self.query_set.deinit(gpa);
            self.texture_view.deinit(gpa);
            self.animation.deinit(gpa);
        }

        pub fn getNamespace(self: *SymbolTable, ns: Namespace) *std.StringHashMapUnmanaged(SymbolInfo) {
            return switch (ns) {
                .wgsl => &self.wgsl,
                .buffer => &self.buffer,
                .texture => &self.texture,
                .sampler => &self.sampler,
                .bind_group => &self.bind_group,
                .bind_group_layout => &self.bind_group_layout,
                .pipeline_layout => &self.pipeline_layout,
                .render_pipeline => &self.render_pipeline,
                .compute_pipeline => &self.compute_pipeline,
                .render_pass => &self.render_pass,
                .compute_pass => &self.compute_pass,
                .frame => &self.frame,
                .shader_module => &self.shader_module,
                .data => &self.data,
                .define => &self.define,
                .queue => &self.queue,
                .image_bitmap => &self.image_bitmap,
                .wasm_call => &self.wasm_call,
                .query_set => &self.query_set,
                .texture_view => &self.texture_view,
                .animation => &self.animation,
            };
        }
    };

    pub const SymbolInfo = struct {
        node: Node.Index,
        data_id: ?u16 = null, // Assigned after dedup
        dependencies: []const Dependency = &.{},
    };

    pub const Dependency = struct {
        namespace: Namespace,
        name: []const u8,
        node: Node.Index, // Reference node for error reporting
    };

    pub const Namespace = enum {
        wgsl,
        buffer,
        texture,
        sampler,
        bind_group,
        bind_group_layout,
        pipeline_layout,
        render_pipeline,
        compute_pipeline,
        render_pass,
        compute_pass,
        frame,
        shader_module,
        data,
        define,
        queue,
        image_bitmap,
        wasm_call,
        query_set,
        texture_view,
        animation,

        pub fn fromString(s: []const u8) ?Namespace {
            const map = std.StaticStringMap(Namespace).initComptime(.{
                .{ "wgsl", .wgsl },
                .{ "buffer", .buffer },
                .{ "texture", .texture },
                .{ "sampler", .sampler },
                .{ "bindGroup", .bind_group },
                .{ "bindGroupLayout", .bind_group_layout },
                .{ "pipelineLayout", .pipeline_layout },
                .{ "renderPipeline", .render_pipeline },
                .{ "computePipeline", .compute_pipeline },
                .{ "renderPass", .render_pass },
                .{ "computePass", .compute_pass },
                .{ "frame", .frame },
                .{ "shaderModule", .shader_module },
                .{ "data", .data },
                .{ "queue", .queue },
                .{ "imageBitmap", .image_bitmap },
                .{ "imageBitmaps", .image_bitmap }, // Alias for plural form
                .{ "wasmCall", .wasm_call },
                .{ "wasmCalls", .wasm_call }, // Alias for plural form
                .{ "querySet", .query_set },
                .{ "textureView", .texture_view },
                .{ "animation", .animation },
                .{ "pipeline", .render_pipeline }, // Alias
                .{ "pass", .render_pass }, // Alias
            });
            return map.get(s);
        }
    };

    pub const ShaderFragment = struct {
        name: []const u8,
        content_hash: u64,
        data_id: u16,
        dependencies: []const []const u8, // Other #wgsl names
    };

    /// Resolution of a bare identifier to a specific namespace.
    /// Used for resolving `module=code` to `$shaderModule.code`.
    pub const ResolvedIdentifier = struct {
        /// The resolved namespace (e.g., .shader_module)
        namespace: Namespace,
        /// The identifier name (e.g., "code")
        name: []const u8,
    };

    /// Resolved uniform metadata for uniform_access nodes.
    /// Used by emitter to generate write_time_uniform opcodes.
    pub const UniformInfo = struct {
        /// Byte size of uniform data (default: 12 for time + canvas)
        size: u16,
        /// Bind group index from uniforms=[] metadata
        bind_group: u8,
        /// Binding index within group
        binding: u8,
        /// Module name (e.g., "code")
        module_name: []const u8,
        /// Uniform var name (e.g., "inputs")
        var_name: []const u8,
    };

    /// Property context for bare name resolution.
    ///
    /// Enables shorthand syntax like `module=code` instead of `module=$shaderModule.code`.
    /// The DSL allows bare identifiers in known property contexts, and this struct
    /// defines which namespaces to search for resolution.
    ///
    /// Example:
    /// - `module=myShader` in vertex config → searches shaderModule, then wgsl namespaces
    /// - `pipeline=main` in render pass → searches renderPipeline, computePipeline
    /// - `perform=[draw sim]` in frame → searches renderPass, computePass, queue
    ///
    /// Thread-safe: Yes (immutable after init).
    pub const PropertyContext = struct {
        /// Namespaces to search (in order) when resolving bare identifiers.
        /// First match wins.
        namespaces: []const Namespace,

        // Pre-defined namespace lists for compile-time map initialization.
        // Separate consts needed for StaticStringMap initComptime.
        const module_ns: []const Namespace = &.{ .shader_module, .wgsl };
        const pipeline_ns: []const Namespace = &.{ .render_pipeline, .compute_pipeline };
        const texture_ns: []const Namespace = &.{.texture};
        const buffer_ns: []const Namespace = &.{.buffer};
        const layout_ns: []const Namespace = &.{ .pipeline_layout, .bind_group_layout };
        const sampler_ns: []const Namespace = &.{.sampler};
        // Array property namespaces
        const pass_ns: []const Namespace = &.{ .render_pass, .compute_pass, .queue };
        const bind_group_ns: []const Namespace = &.{.bind_group};
        const wgsl_ns: []const Namespace = &.{ .wgsl, .shader_module };
        const frame_ns: []const Namespace = &.{.frame};
        const data_ns: []const Namespace = &.{.data};

        /// Map from property name to resolution context.
        /// Used during bare identifier resolution pass.
        pub const map = std.StaticStringMap(PropertyContext).initComptime(.{
            // Single-value properties
            .{ "module", PropertyContext{ .namespaces = module_ns } },
            .{ "pipeline", PropertyContext{ .namespaces = pipeline_ns } },
            .{ "view", PropertyContext{ .namespaces = texture_ns } },
            .{ "resolveTarget", PropertyContext{ .namespaces = texture_ns } },
            .{ "buffer", PropertyContext{ .namespaces = buffer_ns } },
            .{ "layout", PropertyContext{ .namespaces = layout_ns } },
            .{ "sampler", PropertyContext{ .namespaces = sampler_ns } },
            // Array properties
            .{ "perform", PropertyContext{ .namespaces = pass_ns } },
            .{ "before", PropertyContext{ .namespaces = pass_ns } },
            .{ "after", PropertyContext{ .namespaces = pass_ns } },
            .{ "bindGroups", PropertyContext{ .namespaces = bind_group_ns } },
            .{ "vertexBuffers", PropertyContext{ .namespaces = buffer_ns } },
            .{ "imports", PropertyContext{ .namespaces = wgsl_ns } },
            // Nested object properties
            .{ "frame", PropertyContext{ .namespaces = frame_ns } },
            .{ "data", PropertyContext{ .namespaces = data_ns } },
            .{ "mappedAtCreation", PropertyContext{ .namespaces = data_ns } },
        });
    };

    pub const DependencyGraph = struct {
        // Adjacency list: symbol name -> list of dependencies
        edges: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),

        pub fn init() DependencyGraph {
            return .{ .edges = .{} };
        }

        pub fn deinit(self: *DependencyGraph, gpa: Allocator) void {
            var it = self.edges.valueIterator();
            while (it.next()) |list| {
                list.deinit(gpa);
            }
            self.edges.deinit(gpa);
        }
    };

    pub const AnalysisResult = struct {
        symbols: SymbolTable,
        shader_fragments: []const ShaderFragment,
        errors: []const AnalysisError,
        /// Map from identifier_value node index to resolved namespace.
        /// Used by emitter to resolve bare names like `module=code`.
        resolved_identifiers: std.AutoHashMapUnmanaged(u32, ResolvedIdentifier),
        /// Map from uniform_access node index to resolved uniform metadata.
        /// Used by emitter to generate write_time_uniform opcodes.
        resolved_uniforms: std.AutoHashMapUnmanaged(u32, UniformInfo),

        pub fn deinit(self: *AnalysisResult, gpa: Allocator) void {
            self.symbols.deinit(gpa);
            gpa.free(self.shader_fragments);
            gpa.free(self.errors);
            self.resolved_identifiers.deinit(gpa);
            self.resolved_uniforms.deinit(gpa);
            self.* = undefined;
        }

        pub fn hasErrors(self: AnalysisResult) bool {
            return self.errors.len > 0;
        }

        /// Get the resolved namespace for a bare identifier node.
        /// Returns null if the node was not resolved (explicit reference or special value).
        pub fn getResolvedIdentifier(self: AnalysisResult, node_idx: u32) ?ResolvedIdentifier {
            return self.resolved_identifiers.get(node_idx);
        }
    };

    pub fn init(gpa: Allocator, ast: *const Ast) Self {
        return .{
            .gpa = gpa,
            .ast = ast,
            .symbols = SymbolTable.init(),
            .errors = .{},
            .shader_fragments = .{},
            .resolved_identifiers = .{},
            .resolved_uniforms = .{},
            .dep_graph = DependencyGraph.init(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.symbols.deinit(self.gpa);
        self.errors.deinit(self.gpa);
        self.shader_fragments.deinit(self.gpa);
        self.resolved_identifiers.deinit(self.gpa);
        self.resolved_uniforms.deinit(self.gpa);
        self.dep_graph.deinit(self.gpa);
    }

    /// Run all analysis passes on the AST.
    pub fn analyze(gpa: Allocator, ast: *const Ast) Error!AnalysisResult {
        // Pre-conditions
        std.debug.assert(ast.nodes.len > 0);
        std.debug.assert(ast.nodes.items(.tag)[0] == .root);

        var self = Self.init(gpa, ast);
        errdefer self.deinit();

        // Pass 1: Collect all declarations
        try self.collectDeclarations();

        // Pass 2: Validate required properties
        try self.validateRequiredProperties();

        // Pass 3: Resolve references
        try self.resolveReferences();

        // Pass 4: Resolve bare identifiers (e.g., module=code → $shaderModule.code)
        try self.resolveBareIdentifiers();

        // Pass 5: Check for cycles
        try self.detectCycles();

        // Pass 6: Deduplicate shader fragments
        try self.deduplicateShaders();

        // Pass 7: Resolve uniform access nodes (code.inputs → UniformInfo)
        try self.resolveUniformAccess();

        // Post-condition
        std.debug.assert(self.symbols.wgsl.count() + self.symbols.buffer.count() +
            self.symbols.frame.count() >= 0);

        // Clean up dependency graph (no longer needed after analysis)
        self.dep_graph.deinit(self.gpa);

        return AnalysisResult{
            .symbols = self.symbols,
            .shader_fragments = try self.shader_fragments.toOwnedSlice(self.gpa),
            .errors = try self.errors.toOwnedSlice(self.gpa),
            .resolved_identifiers = self.resolved_identifiers,
            .resolved_uniforms = self.resolved_uniforms,
        };
    }

    // ========================================================================
    // Pass 1: Collect Declarations
    // ========================================================================

    fn collectDeclarations(self: *Self) Error!void {
        // Pre-condition: AST has root node
        std.debug.assert(self.ast.nodes.len > 0);
        std.debug.assert(self.ast.nodes.items(.tag)[0] == .root);

        const root_data = self.ast.nodes.items(.data)[0];
        const children = self.ast.extraData(root_data.extra_range);

        for (children) |child_idx| {
            const node_idx: Node.Index = @enumFromInt(child_idx);
            try self.collectDeclaration(node_idx);
        }
    }

    fn collectDeclaration(self: *Self, node_idx: Node.Index) Error!void {
        const tags = self.ast.nodes.items(.tag);
        const main_tokens = self.ast.nodes.items(.main_token);
        const tag = tags[node_idx.toInt()];
        const main_token = main_tokens[node_idx.toInt()];

        const namespace: Namespace = switch (tag) {
            .macro_wgsl => .wgsl,
            .macro_buffer => .buffer,
            .macro_texture => .texture,
            .macro_sampler => .sampler,
            .macro_bind_group => .bind_group,
            .macro_bind_group_layout => .bind_group_layout,
            .macro_pipeline_layout => .pipeline_layout,
            .macro_render_pipeline => .render_pipeline,
            .macro_compute_pipeline => .compute_pipeline,
            .macro_render_pass => .render_pass,
            .macro_compute_pass => .compute_pass,
            .macro_frame => .frame,
            .macro_shader_module => .shader_module,
            .macro_data => .data,
            .macro_define => .define,
            .macro_queue => .queue,
            .macro_image_bitmap => .image_bitmap,
            .macro_wasm_call => .wasm_call,
            .macro_query_set => .query_set,
            .macro_texture_view => .texture_view,
            .macro_animation => .animation,
            else => return, // Skip non-declaration nodes
        };

        // Name is the token after the macro keyword
        const name_token = main_token + 1;
        const name = self.getTokenSlice(name_token);

        // Check for global uniqueness - IDs must be unique across ALL namespaces
        if (self.symbols.all_names.get(name)) |existing| {
            // Format error message with existing namespace info
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "'{s}' already defined as #{s}", .{
                name,
                @tagName(existing.namespace),
            }) catch "duplicate definition";

            try self.errors.append(self.gpa, .{
                .kind = .duplicate_definition,
                .node = node_idx,
                .message = msg,
            });
            return;
        }

        // Register in global map
        try self.symbols.all_names.put(self.gpa, name, .{
            .namespace = namespace,
            .node = node_idx.toInt(),
        });

        // Register in namespace-specific table
        const table = self.symbols.getNamespace(namespace);
        try table.put(self.gpa, name, .{
            .node = node_idx,
        });
    }

    // ========================================================================
    // Pass 2: Validate Required Properties
    // ========================================================================

    /// Required properties per macro type, based on WebGPU spec.
    ///
    /// WebGPU descriptors have mandatory fields (e.g., GPUBufferDescriptor
    /// requires `size`). This struct maps DSL macro types to their
    /// required properties for validation.
    ///
    /// Reference: https://www.w3.org/TR/webgpu/#dictdef-gpubufferdescriptor
    const RequiredProperties = struct {
        /// Property names that must be present for this macro type.
        /// Checked during validation pass.
        required: []const []const u8,
        /// Human-readable macro name for error messages (e.g., "#buffer").
        name: []const u8,
    };

    /// Map of macro types to their required properties.
    /// Mirrors WebGPU spec requirements to catch missing fields at compile time
    /// rather than at runtime when device.createBuffer() would fail.
    const required_props_map = std.StaticStringMap(RequiredProperties).initComptime(.{
        // GPUBufferDescriptor: size determines allocation, usage enables operations
        .{ "buffer", RequiredProperties{ .required = &.{ "size", "usage" }, .name = "#buffer" } },
        // GPUTextureDescriptor: width/height for dimensions, format for memory layout, usage for binding
        .{ "texture", RequiredProperties{ .required = &.{ "format", "usage" }, .name = "#texture" } },
        // GPURenderPipelineDescriptor: vertex stage is the minimum for rasterization
        .{ "render_pipeline", RequiredProperties{ .required = &.{"vertex"}, .name = "#renderPipeline" } },
        // GPUShaderModuleDescriptor: code is the actual WGSL source
        .{ "shader_module", RequiredProperties{ .required = &.{"code"}, .name = "#shaderModule" } },
        // #wgsl macro stores shader fragments for concatenation
        .{ "wgsl", RequiredProperties{ .required = &.{"value"}, .name = "#wgsl" } },
        // GPUBindGroupLayoutDescriptor: entries define the binding slots
        .{ "bind_group_layout", RequiredProperties{ .required = &.{"entries"}, .name = "#bindGroupLayout" } },
    });

    /// Validate that all declarations have their required properties.
    ///
    /// Checks macro declarations against WebGPU spec requirements
    /// (e.g., #buffer requires size and usage).
    ///
    /// Errors are appended to self.errors; does not stop on first error.
    fn validateRequiredProperties(self: *Self) Error!void {
        // Pre-condition: AST must have nodes to validate
        std.debug.assert(self.ast.nodes.len > 0);

        const tags = self.ast.nodes.items(.tag);
        const data = self.ast.nodes.items(.data);
        const main_tokens = self.ast.nodes.items(.main_token);
        const initial_error_count = self.errors.items.len;

        // Iterate over all macro declarations
        for (tags, 0..) |tag, i| {
            const namespace_str: ?[]const u8 = switch (tag) {
                .macro_buffer => "buffer",
                .macro_texture => "texture",
                .macro_render_pipeline => "render_pipeline",
                .macro_shader_module => "shader_module",
                .macro_wgsl => "wgsl",
                .macro_bind_group_layout => "bind_group_layout",
                else => null,
            };

            if (namespace_str) |ns| {
                const req_info = required_props_map.get(ns) orelse continue;
                const node_idx: Node.Index = @enumFromInt(i);

                // Get the properties block for this macro
                const props_range = data[i].extra_range;
                const prop_indices = self.ast.extraData(props_range);

                // Check each required property
                for (req_info.required) |required_name| {
                    var found = false;

                    for (prop_indices) |prop_idx| {
                        const prop_tag = tags[prop_idx];
                        if (prop_tag == .property) {
                            const prop_token = main_tokens[prop_idx];
                            const prop_name = self.getTokenSlice(prop_token);
                            if (std.mem.eql(u8, prop_name, required_name)) {
                                found = true;
                                break;
                            }
                        }
                    }

                    if (!found) {
                        try self.errors.append(self.gpa, .{
                            .kind = .missing_required_property,
                            .node = node_idx,
                            .message = required_name,
                        });
                    }
                }
            }
        }

        // Post-condition: error count can only grow (never removes errors)
        std.debug.assert(self.errors.items.len >= initial_error_count);
    }

    // ========================================================================
    // Pass 3: Resolve References
    // ========================================================================

    fn resolveReferences(self: *Self) Error!void {
        // Pre-condition: declarations collected first
        // (symbols tables may be populated)

        // Walk all nodes looking for references
        const tags = self.ast.nodes.items(.tag);

        for (tags, 0..) |tag, i| {
            if (tag == .reference) {
                try self.resolveReference(@enumFromInt(i));
            }
        }

        // Post-condition: all references checked
        // (errors may have been added)
    }

    fn resolveReference(self: *Self, node_idx: Node.Index) Error!void {
        // Pre-condition: node is a reference
        std.debug.assert(self.ast.nodes.items(.tag)[node_idx.toInt()] == .reference);

        const data = self.ast.nodes.items(.data)[node_idx.toInt()];
        const node_and_node = data.node_and_node;

        const namespace_token = node_and_node[0];
        const name_token = node_and_node[1];

        const namespace_str = self.getTokenSlice(namespace_token);

        // For multi-part references like $wgsl.shader.inputs, we need to look up
        // the first name part ("shader"), not the last ("inputs").
        // For 2-part refs (namespace_token+2 == name_token), use name_token directly.
        // For 3+ part refs (namespace_token+2 < name_token), use namespace_token+2.
        const first_name_token = if (namespace_token + 2 < name_token)
            namespace_token + 2
        else
            name_token;
        const name_str = self.getTokenSlice(first_name_token);

        // Parse namespace
        const namespace = Namespace.fromString(namespace_str) orelse {
            try self.errors.append(self.gpa, .{
                .kind = .invalid_reference_namespace,
                .node = node_idx,
                .message = "invalid namespace in reference",
            });
            return;
        };

        // Look up symbol
        const table = self.symbols.getNamespace(namespace);
        if (table.get(name_str) == null) {
            try self.errors.append(self.gpa, .{
                .kind = .undefined_reference,
                .node = node_idx,
                .message = "undefined reference",
            });
        }
    }

    // ========================================================================
    // Pass 4: Resolve Bare Identifiers
    // ========================================================================

    /// Resolve bare identifiers to their namespaces based on property context.
    /// For example, `module=code` in a renderPipeline vertex property
    /// resolves to `$shaderModule.code`.
    ///
    /// Handles both single values and arrays:
    /// - `module=code` → resolves single identifier
    /// - `perform=[draw sim]` → resolves each array element
    fn resolveBareIdentifiers(self: *Self) Error!void {
        // Walk all property nodes and check their values
        const tags = self.ast.nodes.items(.tag);
        const main_tokens = self.ast.nodes.items(.main_token);
        const data = self.ast.nodes.items(.data);

        for (tags, 0..) |tag, i| {
            if (tag != .property) continue;

            const prop_token = main_tokens[i];
            const prop_name = self.getTokenSlice(prop_token);

            // Check if this property name has a known context
            const context = PropertyContext.map.get(prop_name) orelse continue;

            // Get the value node
            const value_node: Node.Index = data[i].node;
            const value_tag = tags[value_node.toInt()];

            switch (value_tag) {
                .identifier_value => {
                    // Single bare identifier
                    try self.resolveIdentifier(value_node, context);
                },
                .array => {
                    // Array of identifiers - resolve each element
                    try self.resolveArrayElements(value_node, context);
                },
                else => {},
            }
        }
    }

    /// Resolve array elements that are bare identifiers.
    fn resolveArrayElements(self: *Self, array_node: Node.Index, context: PropertyContext) Error!void {
        const data = self.ast.nodes.items(.data)[array_node.toInt()];
        const elements = self.ast.extraData(data.extra_range);
        const tags = self.ast.nodes.items(.tag);

        for (elements) |elem_idx| {
            const elem: Node.Index = @enumFromInt(elem_idx);
            if (tags[elem.toInt()] == .identifier_value) {
                try self.resolveIdentifier(elem, context);
            }
        }
    }

    /// Resolve a single bare identifier in the given context.
    fn resolveIdentifier(self: *Self, node: Node.Index, context: PropertyContext) Error!void {
        const main_tokens = self.ast.nodes.items(.main_token);
        const token = main_tokens[node.toInt()];
        const identifier = self.getTokenSlice(token);

        // Skip special values
        if (isSpecialValue(identifier)) return;

        // Try to resolve in each namespace (first match wins)
        for (context.namespaces) |namespace| {
            const table = self.symbols.getNamespace(namespace);
            if (table.get(identifier) != null) {
                // Found it! Record the resolution
                try self.resolved_identifiers.put(self.gpa, node.toInt(), .{
                    .namespace = namespace,
                    .name = identifier,
                });
                return;
            }
        }

        // Not found - add error with helpful message
        try self.reportUndefinedReference(node, identifier, context);
    }

    /// Report undefined reference with context about expected namespaces.
    fn reportUndefinedReference(
        self: *Self,
        node: Node.Index,
        identifier: []const u8,
        context: PropertyContext,
    ) Error!void {
        _ = identifier; // Used in error reporting (identifier visible in AST)

        // Use static message based on first expected namespace
        // (Full message would require allocator - keeping it simple)
        const message: []const u8 = if (context.namespaces.len > 0)
            switch (context.namespaces[0]) {
                .render_pass, .compute_pass, .queue => "undefined reference - expected pass or queue",
                .buffer => "undefined reference - expected buffer",
                .bind_group => "undefined reference - expected bind group",
                .texture => "undefined reference - expected texture",
                .wgsl, .shader_module => "undefined reference - expected shader module",
                .data => "undefined reference - expected data",
                .frame => "undefined reference - expected frame",
                else => "undefined reference",
            }
        else
            "undefined reference";

        try self.errors.append(self.gpa, .{
            .kind = .undefined_reference,
            .node = node,
            .message = message,
        });
    }

    /// Check if an identifier is a special/reserved value that shouldn't be resolved.
    fn isSpecialValue(identifier: []const u8) bool {
        const specials = std.StaticStringMap(void).initComptime(.{
            // Layout values
            .{ "auto", {} },
            // Special texture views
            .{ "contextCurrentTexture", {} },
            // Load/store operations
            .{ "clear", {} },
            .{ "load", {} },
            .{ "store", {} },
            .{ "discard", {} },
            // Topology values
            .{ "triangle-list", {} },
            .{ "triangle-strip", {} },
            .{ "line-list", {} },
            .{ "line-strip", {} },
            .{ "point-list", {} },
            // Cull mode
            .{ "none", {} },
            .{ "front", {} },
            .{ "back", {} },
            // Front face
            .{ "ccw", {} },
            .{ "cw", {} },
            // Filter modes
            .{ "nearest", {} },
            .{ "linear", {} },
            // Address modes
            .{ "clamp-to-edge", {} },
            .{ "repeat", {} },
            .{ "mirror-repeat", {} },
            // Compare functions
            .{ "never", {} },
            .{ "less", {} },
            .{ "equal", {} },
            .{ "less-equal", {} },
            .{ "greater", {} },
            .{ "not-equal", {} },
            .{ "greater-equal", {} },
            .{ "always", {} },
            // Texture formats
            .{ "preferredCanvasFormat", {} },
            .{ "rgba8unorm", {} },
            .{ "bgra8unorm", {} },
            .{ "depth24plus", {} },
            .{ "depth32float", {} },
        });
        return specials.get(identifier) != null;
    }

    // ========================================================================
    // Pass 5: Cycle Detection
    // ========================================================================

    fn detectCycles(self: *Self) Error!void {
        // Build dependency graph for #wgsl macros (they can import each other)
        try self.buildDependencyGraph();

        // DFS-based cycle detection
        var visited = std.StringHashMapUnmanaged(VisitState){};
        defer visited.deinit(self.gpa);

        var it = self.symbols.wgsl.keyIterator();
        while (it.next()) |name| {
            try self.detectCyclesDFS(name.*, &visited);
        }
    }

    const VisitState = enum { visiting, visited };

    /// Maximum depth for cycle detection (prevents infinite loops).
    const MAX_DFS_DEPTH: u32 = 1024;

    /// Iterative DFS entry for cycle detection.
    const DFSEntry = struct {
        name: []const u8,
        dep_idx: usize, // Current index in dependencies
    };

    /// Detect cycles using iterative DFS with explicit stack.
    /// Invariant: Stack depth bounded by MAX_DFS_DEPTH.
    fn detectCyclesDFS(
        self: *Self,
        start_name: []const u8,
        visited: *std.StringHashMapUnmanaged(VisitState),
    ) Error!void {
        // Pre-condition
        std.debug.assert(start_name.len > 0);

        // Check if already fully processed
        if (visited.get(start_name)) |state| {
            if (state == .visited) return;
            if (state == .visiting) {
                // Found cycle at start
                if (self.symbols.wgsl.get(start_name)) |info| {
                    try self.errors.append(self.gpa, .{
                        .kind = .circular_dependency,
                        .node = info.node,
                        .message = "circular dependency detected",
                    });
                }
                return;
            }
        }

        // Explicit stack for iterative DFS
        var stack = std.ArrayListUnmanaged(DFSEntry){};
        defer stack.deinit(self.gpa);

        try stack.append(self.gpa, .{ .name = start_name, .dep_idx = 0 });
        try visited.put(self.gpa, start_name, .visiting);

        // Bounded iteration
        for (0..MAX_DFS_DEPTH) |_| {
            if (stack.items.len == 0) break;

            const entry = &stack.items[stack.items.len - 1];
            const deps = self.dep_graph.edges.get(entry.name);

            if (deps == null or entry.dep_idx >= deps.?.items.len) {
                // Done with this node - mark visited and pop
                try visited.put(self.gpa, entry.name, .visited);
                _ = stack.pop();
                continue;
            }

            const dep_name = deps.?.items[entry.dep_idx];
            entry.dep_idx += 1;

            if (visited.get(dep_name)) |state| {
                if (state == .visiting) {
                    // Found cycle
                    if (self.symbols.wgsl.get(dep_name)) |info| {
                        try self.errors.append(self.gpa, .{
                            .kind = .circular_dependency,
                            .node = info.node,
                            .message = "circular dependency detected",
                        });
                    }
                }
                // Already visited or visiting, don't push
                continue;
            }

            // Push new node to explore
            try visited.put(self.gpa, dep_name, .visiting);
            try stack.append(self.gpa, .{ .name = dep_name, .dep_idx = 0 });
        } else {
            // Loop bound exceeded - should never happen with valid input
            unreachable;
        }

        // Post-condition: all reachable nodes from start are visited
        std.debug.assert(visited.get(start_name) != null);
    }

    fn buildDependencyGraph(self: *Self) Error!void {
        // For each #wgsl declaration, find its imports property
        var it = self.symbols.wgsl.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const info = entry.value_ptr.*;

            // Get the macro node and look for imports property
            var deps = try self.findWgslImports(info.node);
            if (deps.items.len > 0) {
                try self.dep_graph.edges.put(self.gpa, name, deps);
            } else {
                // Empty list, clean it up (not stored in graph)
                deps.deinit(self.gpa);
            }
        }
    }

    fn findWgslImports(self: *Self, macro_node: Node.Index) Error!std.ArrayListUnmanaged([]const u8) {
        var deps = std.ArrayListUnmanaged([]const u8){};
        errdefer deps.deinit(self.gpa);

        const data = self.ast.nodes.items(.data)[macro_node.toInt()];
        const props = self.ast.extraData(data.extra_range);

        for (props) |prop_idx| {
            const prop_node: Node.Index = @enumFromInt(prop_idx);
            const prop_token = self.ast.nodes.items(.main_token)[prop_node.toInt()];
            const prop_name = self.getTokenSlice(prop_token);

            if (std.mem.eql(u8, prop_name, "imports")) {
                // Value is an array of references
                const prop_data = self.ast.nodes.items(.data)[prop_node.toInt()];
                const value_node = prop_data.node;
                const value_tag = self.ast.nodes.items(.tag)[value_node.toInt()];

                if (value_tag == .array) {
                    const array_data = self.ast.nodes.items(.data)[value_node.toInt()];
                    const elements = self.ast.extraData(array_data.extra_range);

                    for (elements) |elem_idx| {
                        const elem_node: Node.Index = @enumFromInt(elem_idx);
                        const elem_tag = self.ast.nodes.items(.tag)[elem_node.toInt()];

                        if (elem_tag == .reference) {
                            const ref_data = self.ast.nodes.items(.data)[elem_node.toInt()];
                            const name_token = ref_data.node_and_node[1];
                            const dep_name = self.getTokenSlice(name_token);
                            try deps.append(self.gpa, dep_name);
                        }
                    }
                }
                break;
            }
        }

        return deps;
    }

    // ========================================================================
    // Pass 6: Shader Deduplication
    // ========================================================================

    fn deduplicateShaders(self: *Self) Error!void {
        // Hash shader content and assign data IDs
        var content_to_id = std.AutoHashMapUnmanaged(u64, u16){};
        defer content_to_id.deinit(self.gpa);

        var next_data_id: u16 = 0;

        var it = self.symbols.wgsl.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const info = entry.value_ptr.*;

            // Find value property
            const content = self.findWgslValue(info.node) orelse continue;
            const hash = std.hash.Wyhash.hash(0, content);

            const data_id = content_to_id.get(hash) orelse blk: {
                const id = next_data_id;
                next_data_id += 1;
                try content_to_id.put(self.gpa, hash, id);
                break :blk id;
            };

            // Update symbol info with data_id
            entry.value_ptr.*.data_id = data_id;

            try self.shader_fragments.append(self.gpa, .{
                .name = name,
                .content_hash = hash,
                .data_id = data_id,
                .dependencies = &.{}, // TODO(Analyzer) Populate from imports for cross-module dependencies
            });
        }
    }

    fn findWgslValue(self: *Self, macro_node: Node.Index) ?[]const u8 {
        const data = self.ast.nodes.items(.data)[macro_node.toInt()];
        const props = self.ast.extraData(data.extra_range);

        for (props) |prop_idx| {
            const prop_node: Node.Index = @enumFromInt(prop_idx);
            const prop_token = self.ast.nodes.items(.main_token)[prop_node.toInt()];
            const prop_name = self.getTokenSlice(prop_token);

            if (std.mem.eql(u8, prop_name, "value")) {
                const prop_data = self.ast.nodes.items(.data)[prop_node.toInt()];
                const value_node = prop_data.node;
                const value_tag = self.ast.nodes.items(.tag)[value_node.toInt()];

                if (value_tag == .string_value) {
                    const value_token = self.ast.nodes.items(.main_token)[value_node.toInt()];
                    const raw = self.getTokenSlice(value_token);
                    // Strip quotes
                    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
                        return raw[1 .. raw.len - 1];
                    }
                    return raw;
                }
            }
        }

        return null;
    }

    // ========================================================================
    // Pass 7: Uniform Access Resolution
    // ========================================================================

    /// Resolve uniform_access nodes (code.inputs) to UniformInfo.
    /// Validates module exists and extracts metadata from uniforms=[] property.
    fn resolveUniformAccess(self: *Self) Error!void {
        // Iterate all nodes looking for uniform_access
        const tags = self.ast.nodes.items(.tag);
        const data = self.ast.nodes.items(.data);

        for (0..self.ast.nodes.len) |i| {
            if (tags[i] != .uniform_access) continue;

            const node_idx: Node.Index = @enumFromInt(i);
            const node_data = data[i];
            const module_token = node_data.node_and_node[0];
            const var_token = node_data.node_and_node[1];

            const module_name = self.getTokenSlice(module_token);
            const var_name = self.getTokenSlice(var_token);

            // Find shader module (check both shader_module and wgsl namespaces)
            const shader_node: ?Node.Index = blk: {
                if (self.symbols.shader_module.get(module_name)) |info| break :blk info.node;
                if (self.symbols.wgsl.get(module_name)) |info| break :blk info.node;
                break :blk null;
            };

            if (shader_node == null) {
                // Module not found - add error
                try self.errors.append(self.gpa, .{
                    .kind = .undefined_reference,
                    .node = node_idx,
                    .message = "undefined shader module in uniform access",
                });
                continue;
            }

            // Look up uniform metadata from uniforms=[] property
            const uniform_meta = self.findUniformMetadata(shader_node.?, var_name);

            // Store resolved info
            try self.resolved_uniforms.put(self.gpa, @intCast(i), .{
                .size = if (uniform_meta) |u| u.size else 12, // default: time + canvas
                .bind_group = if (uniform_meta) |u| u.bind_group else 0,
                .binding = if (uniform_meta) |u| u.binding else 0,
                .module_name = module_name,
                .var_name = var_name,
            });
        }
    }

    /// Extracted uniform metadata from WGSL reflection or uniforms=[] property.
    const UniformMeta = struct {
        size: u16,
        bind_group: u8,
        binding: u8,
    };

    /// Find uniform metadata by reflection from WGSL source code.
    /// Looks for patterns like: @group(0) @binding(0) var<uniform> name : Type;
    fn findUniformMetadata(self: *Self, shader_node: Node.Index, var_name: []const u8) ?UniformMeta {
        // First, try WGSL reflection from source code
        const wgsl_source = self.getShaderSource(shader_node);
        if (wgsl_source) |source| {
            if (self.extractUniformFromWgsl(source, var_name)) |info| {
                return info;
            }
        }

        // Fall back to explicit uniforms=[] property
        const data = self.ast.nodes.items(.data)[shader_node.toInt()];
        const props = self.ast.extraData(data.extra_range);

        for (props) |prop_idx| {
            const prop_node: Node.Index = @enumFromInt(prop_idx);
            const prop_token = self.ast.nodes.items(.main_token)[prop_node.toInt()];
            const prop_name = self.getTokenSlice(prop_token);

            if (!std.mem.eql(u8, prop_name, "uniforms")) continue;

            const prop_data = self.ast.nodes.items(.data)[prop_node.toInt()];
            const uniforms_node = prop_data.node;
            const uniforms_tag = self.ast.nodes.items(.tag)[uniforms_node.toInt()];
            if (uniforms_tag != .array) continue;

            const array_data = self.ast.nodes.items(.data)[uniforms_node.toInt()];
            const elements = self.ast.extraData(array_data.extra_range);

            for (elements) |elem_idx| {
                const elem: Node.Index = @enumFromInt(elem_idx);
                const elem_tag = self.ast.nodes.items(.tag)[elem.toInt()];
                if (elem_tag != .object) continue;

                const var_value = self.findObjectPropertyValue(elem, "var") orelse continue;
                const var_value_str = self.getNodeStringValue(var_value) orelse continue;
                if (!std.mem.eql(u8, var_value_str, var_name)) continue;

                const bind_group = self.findObjectPropertyNumber(elem, "bindGroup") orelse 0;
                const binding = self.findObjectPropertyNumber(elem, "binding") orelse 0;

                return .{
                    .size = 12,
                    .bind_group = @intCast(bind_group),
                    .binding = @intCast(binding),
                };
            }
        }
        return null;
    }

    /// Get shader source code from a #wgsl or #shaderModule node.
    fn getShaderSource(self: *Self, shader_node: Node.Index) ?[]const u8 {
        const data = self.ast.nodes.items(.data)[shader_node.toInt()];
        const props = self.ast.extraData(data.extra_range);

        for (props) |prop_idx| {
            const prop_node: Node.Index = @enumFromInt(prop_idx);
            const prop_token = self.ast.nodes.items(.main_token)[prop_node.toInt()];
            const prop_name = self.getTokenSlice(prop_token);

            // #wgsl uses "value=", #shaderModule uses "code="
            if (std.mem.eql(u8, prop_name, "value") or std.mem.eql(u8, prop_name, "code")) {
                const prop_data = self.ast.nodes.items(.data)[prop_node.toInt()];
                return self.getNodeStringValue(prop_data.node);
            }
        }
        return null;
    }

    /// Extract uniform binding info from WGSL source code.
    /// Scans for pattern: @group(N) @binding(M) var<uniform> name : Type;
    fn extractUniformFromWgsl(self: *Self, source: []const u8, var_name: []const u8) ?UniformMeta {
        _ = self;

        // Search for the variable declaration pattern
        // Pattern: @group(G) @binding(B) var<uniform> NAME : TYPE;
        var pos: usize = 0;
        const max_iterations = source.len;

        for (0..max_iterations) |_| {
            // Find @group
            const group_start = std.mem.indexOfPos(u8, source, pos, "@group(") orelse break;
            const group_end = std.mem.indexOfPos(u8, source, group_start + 7, ")") orelse break;
            const group_str = source[group_start + 7 .. group_end];
            const group = std.fmt.parseInt(u8, group_str, 10) catch {
                pos = group_end;
                continue;
            };

            // Find @binding after @group
            const binding_start = std.mem.indexOfPos(u8, source, group_end, "@binding(") orelse break;
            // Ensure @binding is close to @group (within 20 chars)
            if (binding_start > group_end + 20) {
                pos = group_end + 1;
                continue;
            }
            const binding_end = std.mem.indexOfPos(u8, source, binding_start + 9, ")") orelse break;
            const binding_str = source[binding_start + 9 .. binding_end];
            const binding = std.fmt.parseInt(u8, binding_str, 10) catch {
                pos = binding_end;
                continue;
            };

            // Find var<uniform> after @binding
            const var_start = std.mem.indexOfPos(u8, source, binding_end, "var<uniform>") orelse {
                pos = binding_end + 1;
                continue;
            };
            // Ensure var<uniform> is close to @binding (within 30 chars)
            if (var_start > binding_end + 30) {
                pos = binding_end + 1;
                continue;
            }

            // Extract variable name (after "var<uniform>" and whitespace)
            var name_start = var_start + 12; // len("var<uniform>")
            while (name_start < source.len and (source[name_start] == ' ' or source[name_start] == '\t')) {
                name_start += 1;
            }

            // Find end of variable name (at ':' or whitespace)
            var name_end = name_start;
            while (name_end < source.len and source[name_end] != ':' and source[name_end] != ' ' and source[name_end] != '\t') {
                name_end += 1;
            }

            const found_name = source[name_start..name_end];
            if (std.mem.eql(u8, found_name, var_name)) {
                // Found it! Default size is 12 bytes (time + canvas)
                return .{
                    .size = 12,
                    .bind_group = group,
                    .binding = binding,
                };
            }

            pos = name_end;
        } else {
            // Exhausted source without finding match - valid termination
        }
        return null;
    }

    /// Find a property value node in an object.
    fn findObjectPropertyValue(self: *Self, obj_node: Node.Index, prop_name: []const u8) ?Node.Index {
        const obj_data = self.ast.nodes.items(.data)[obj_node.toInt()];
        const props = self.ast.extraData(obj_data.extra_range);

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

    /// Get string value from a node (handles string_value and identifier_value).
    fn getNodeStringValue(self: *Self, node: Node.Index) ?[]const u8 {
        const tag = self.ast.nodes.items(.tag)[node.toInt()];
        const main_token = self.ast.nodes.items(.main_token)[node.toInt()];
        const raw = self.getTokenSlice(main_token);

        if (tag == .string_value) {
            // Strip quotes
            if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
                return raw[1 .. raw.len - 1];
            }
            return raw;
        } else if (tag == .identifier_value) {
            return raw;
        }
        return null;
    }

    /// Find a numeric property in an object and parse it.
    fn findObjectPropertyNumber(self: *Self, obj_node: Node.Index, prop_name: []const u8) ?u32 {
        const value_node = self.findObjectPropertyValue(obj_node, prop_name) orelse return null;
        const tag = self.ast.nodes.items(.tag)[value_node.toInt()];

        if (tag == .number_value) {
            const main_token = self.ast.nodes.items(.main_token)[value_node.toInt()];
            const raw = self.getTokenSlice(main_token);
            return std.fmt.parseInt(u32, raw, 10) catch return null;
        }
        return null;
    }

    // ========================================================================
    // Expression Evaluation (compile-time arithmetic)
    // ========================================================================

    /// Maximum expression tree depth for iterative evaluation.
    /// Bounds stack size to prevent unbounded memory growth.
    const MAX_EXPR_DEPTH: usize = 64;

    /// Work item for iterative expression evaluation.
    /// Uses explicit stack instead of recursion for bounded execution.
    const EvalWork = union(enum) {
        /// Push node's children, then apply operator
        eval_node: Node.Index,
        /// Apply binary operator to top two values on stack
        apply_binary: Node.Tag,
        /// Apply unary operator to top value on stack
        apply_unary: Node.Tag,
    };

    /// Evaluate an expression node to a numeric value at compile time.
    ///
    /// Uses iterative post-order traversal instead of recursion to ensure
    /// bounded stack usage. Expression depth limited to MAX_EXPR_DEPTH.
    ///
    /// Returns null if:
    /// - Node is not an evaluable expression
    /// - Division by zero encountered
    /// - Expression depth exceeds MAX_EXPR_DEPTH
    pub fn evaluateExpression(self: *Self, node_idx: Node.Index) ?f64 {
        // Pre-conditions
        std.debug.assert(node_idx.toInt() < self.ast.nodes.len);

        const tags = self.ast.nodes.items(.tag);
        const data = self.ast.nodes.items(.data);
        const main_tokens = self.ast.nodes.items(.main_token);

        // Explicit stacks for iterative evaluation (no recursion)
        var work_stack: [MAX_EXPR_DEPTH]EvalWork = undefined;
        var work_len: usize = 0;
        var value_stack: [MAX_EXPR_DEPTH]f64 = undefined;
        var value_len: usize = 0;

        // Start with the root node
        work_stack[0] = .{ .eval_node = node_idx };
        work_len = 1;

        // Process work items until stack is empty
        const MAX_ITERATIONS: usize = MAX_EXPR_DEPTH * 3;
        for (0..MAX_ITERATIONS) |_| {
            if (work_len == 0) break;

            // Pop work item
            work_len -= 1;
            const work = work_stack[work_len];

            switch (work) {
                .eval_node => |idx| {
                    const tag = tags[idx.toInt()];

                    switch (tag) {
                        .number_value => {
                            // Leaf node: parse and push value
                            const value = self.parseNumberLiteral(main_tokens[idx.toInt()]) orelse return null;
                            if (value_len >= MAX_EXPR_DEPTH) return null;
                            value_stack[value_len] = value;
                            value_len += 1;
                        },
                        .expr_add, .expr_sub, .expr_mul, .expr_div => {
                            // Binary operator: push apply task, then children (right first so left is evaluated first)
                            const operands = data[idx.toInt()].node_and_node;
                            if (work_len + 3 > MAX_EXPR_DEPTH) return null;

                            work_stack[work_len] = .{ .apply_binary = tag };
                            work_len += 1;
                            work_stack[work_len] = .{ .eval_node = @enumFromInt(operands[1]) };
                            work_len += 1;
                            work_stack[work_len] = .{ .eval_node = @enumFromInt(operands[0]) };
                            work_len += 1;
                        },
                        .expr_negate => {
                            // Unary operator: push apply task, then operand
                            const operand_idx = data[idx.toInt()].node;
                            if (work_len + 2 > MAX_EXPR_DEPTH) return null;

                            work_stack[work_len] = .{ .apply_unary = tag };
                            work_len += 1;
                            work_stack[work_len] = .{ .eval_node = operand_idx };
                            work_len += 1;
                        },
                        else => return null, // Not an expression node
                    }
                },
                .apply_binary => |op| {
                    // Pop two values and apply operator
                    if (value_len < 2) return null;
                    value_len -= 1;
                    const rhs = value_stack[value_len];
                    value_len -= 1;
                    const lhs = value_stack[value_len];

                    const result = switch (op) {
                        .expr_add => lhs + rhs,
                        .expr_sub => lhs - rhs,
                        .expr_mul => lhs * rhs,
                        .expr_div => if (rhs == 0) return null else lhs / rhs,
                        else => unreachable,
                    };

                    value_stack[value_len] = result;
                    value_len += 1;
                },
                .apply_unary => |op| {
                    // Pop one value and apply operator
                    if (value_len < 1) return null;
                    value_len -= 1;
                    const operand = value_stack[value_len];

                    const result = switch (op) {
                        .expr_negate => -operand,
                        else => unreachable,
                    };

                    value_stack[value_len] = result;
                    value_len += 1;
                },
            }
        } else {
            // Exceeded MAX_ITERATIONS - malformed expression or too deep
            return null;
        }

        // Post-condition: exactly one value remains
        std.debug.assert(value_len == 1);
        std.debug.assert(work_len == 0);

        return value_stack[0];
    }

    /// Parse a number literal token to f64.
    ///
    /// Handles formats used in WebGPU DSL:
    /// - Decimal integers: 123
    /// - Decimal floats: 3.14
    /// - Hexadecimal: 0xFF (for usage flags, colors)
    ///
    /// Returns null for invalid number formats.
    fn parseNumberLiteral(self: *Self, token_index: u32) ?f64 {
        // Pre-condition: valid token index
        std.debug.assert(token_index < self.ast.tokens.len);

        const slice = self.getTokenSlice(token_index);

        // Post-condition check variable
        var result: ?f64 = null;

        // O(1) lookup for math constants
        const math_constants = std.StaticStringMap(f64).initComptime(.{
            .{ "PI", std.math.pi },
            .{ "E", std.math.e },
            .{ "TAU", std.math.tau },
        });

        // Check for math constants: PI, E, TAU
        if (math_constants.get(slice)) |value| {
            result = value;
        } else if (slice.len == 0) {
            // Empty slice is invalid
        } else if (slice.len > 2 and slice[0] == '0' and (slice[1] == 'x' or slice[1] == 'X')) {
            // Hex format: 0xDEADBEEF (WebGPU usage flags, color values)
            const hex_digits = slice[2..];
            if (std.fmt.parseInt(i64, hex_digits, 16)) |value| {
                result = @floatFromInt(value);
            } else |_| {}
        } else if (slice.len > 3 and slice[0] == '-' and slice[1] == '0' and (slice[2] == 'x' or slice[2] == 'X')) {
            // Negative hex: -0xFF (rare but valid)
            const hex_digits = slice[3..];
            if (std.fmt.parseInt(i64, hex_digits, 16)) |value| {
                result = @floatFromInt(-value);
            } else |_| {}
        } else {
            // Decimal integer or float
            result = std.fmt.parseFloat(f64, slice) catch null;
        }

        // Post-condition: result is null or a valid f64 (not NaN, not Inf for valid input)
        if (result) |r| {
            std.debug.assert(!std.math.isNan(r));
        }

        return result;
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    fn getTokenSlice(self: *Self, token_index: u32) []const u8 {
        const starts = self.ast.tokens.items(.start);
        const start = starts[token_index];
        const end: u32 = if (token_index + 1 < starts.len)
            starts[token_index + 1]
        else
            @intCast(self.ast.source.len);

        // Trim whitespace/newlines that may be included
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
