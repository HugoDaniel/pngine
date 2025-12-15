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

    pub const SymbolTable = struct {
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

        pub fn init() SymbolTable {
            return .{
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
            };
        }

        pub fn deinit(self: *SymbolTable, gpa: Allocator) void {
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

        pub fn deinit(self: *AnalysisResult, gpa: Allocator) void {
            self.symbols.deinit(gpa);
            gpa.free(self.shader_fragments);
            gpa.free(self.errors);
            self.* = undefined;
        }

        pub fn hasErrors(self: AnalysisResult) bool {
            return self.errors.len > 0;
        }
    };

    pub fn init(gpa: Allocator, ast: *const Ast) Self {
        return .{
            .gpa = gpa,
            .ast = ast,
            .symbols = SymbolTable.init(),
            .errors = .{},
            .shader_fragments = .{},
            .dep_graph = DependencyGraph.init(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.symbols.deinit(self.gpa);
        self.errors.deinit(self.gpa);
        self.shader_fragments.deinit(self.gpa);
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

        // Pass 2: Resolve references
        try self.resolveReferences();

        // Pass 3: Check for cycles
        try self.detectCycles();

        // Pass 4: Deduplicate shader fragments
        try self.deduplicateShaders();

        // Post-condition
        std.debug.assert(self.symbols.wgsl.count() + self.symbols.buffer.count() +
            self.symbols.frame.count() >= 0);

        // Clean up dependency graph (no longer needed after analysis)
        self.dep_graph.deinit(self.gpa);

        return AnalysisResult{
            .symbols = self.symbols,
            .shader_fragments = try self.shader_fragments.toOwnedSlice(self.gpa),
            .errors = try self.errors.toOwnedSlice(self.gpa),
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
            else => return, // Skip non-declaration nodes
        };

        // Name is the token after the macro keyword
        const name_token = main_token + 1;
        const name = self.getTokenSlice(name_token);

        const table = self.symbols.getNamespace(namespace);

        // Check for duplicate
        if (table.get(name)) |_| {
            try self.errors.append(self.gpa, .{
                .kind = .duplicate_definition,
                .node = node_idx,
                .message = "duplicate definition",
            });
            return;
        }

        try table.put(self.gpa, name, .{
            .node = node_idx,
        });
    }

    // ========================================================================
    // Pass 2: Resolve References
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
        const name_str = self.getTokenSlice(name_token);

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
    // Pass 3: Cycle Detection
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
    // Pass 4: Shader Deduplication
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
                .dependencies = &.{}, // TODO: populate from imports
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

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const Parser = @import("Parser.zig").Parser;

fn parseAndAnalyze(source: [:0]const u8) !Analyzer.AnalysisResult {
    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);
    return Analyzer.analyze(testing.allocator, &ast);
}

// ----------------------------------------------------------------------------
// Reference Resolution Tests
// ----------------------------------------------------------------------------

test "Analyzer: valid reference" {
    const source: [:0]const u8 =
        \\#wgsl shader { value="fn main() {}" }
        \\#renderPipeline pipe { vertex={ module=$wgsl.shader } }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "Analyzer: undefined reference" {
    const source: [:0]const u8 =
        \\#renderPipeline pipe { vertex={ module=$wgsl.missing } }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.errors.len);
    try testing.expectEqual(Analyzer.AnalysisError.Kind.undefined_reference, result.errors[0].kind);
}

test "Analyzer: multiple undefined references" {
    const source: [:0]const u8 =
        \\#renderPipeline pipe {
        \\  vertex={ module=$wgsl.missing1 }
        \\  fragment={ module=$wgsl.missing2 }
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.errors.len);
}

test "Analyzer: invalid namespace" {
    const source: [:0]const u8 =
        \\#renderPipeline pipe { vertex={ module=$invalid.name } }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.errors.len);
    try testing.expectEqual(Analyzer.AnalysisError.Kind.invalid_reference_namespace, result.errors[0].kind);
}

test "Analyzer: reference to buffer" {
    const source: [:0]const u8 =
        \\#buffer vertices { size=100 }
        \\#renderPass pass { vertexBuffer=$buffer.vertices }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
}

// ----------------------------------------------------------------------------
// Duplicate Definition Tests
// ----------------------------------------------------------------------------

test "Analyzer: duplicate definition" {
    const source: [:0]const u8 =
        \\#wgsl shader { value="fn a() {}" }
        \\#wgsl shader { value="fn b() {}" }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), result.errors.len);
    try testing.expectEqual(Analyzer.AnalysisError.Kind.duplicate_definition, result.errors[0].kind);
}

test "Analyzer: same name different namespace" {
    const source: [:0]const u8 =
        \\#wgsl main { value="" }
        \\#buffer main { size=100 }
        \\#frame main { perform=[] }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // Same name in different namespaces is OK
    try testing.expectEqual(@as(usize, 0), result.errors.len);
}

// ----------------------------------------------------------------------------
// Cycle Detection Tests
// ----------------------------------------------------------------------------

test "Analyzer: circular import detected" {
    const source: [:0]const u8 =
        \\#wgsl a { imports=[$wgsl.b] value="" }
        \\#wgsl b { imports=[$wgsl.a] value="" }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expect(result.errors.len > 0);

    var has_cycle_error = false;
    for (result.errors) |err| {
        if (err.kind == .circular_dependency) {
            has_cycle_error = true;
            break;
        }
    }
    try testing.expect(has_cycle_error);
}

test "Analyzer: self-import cycle" {
    const source: [:0]const u8 =
        \\#wgsl a { imports=[$wgsl.a] value="" }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    var has_cycle_error = false;
    for (result.errors) |err| {
        if (err.kind == .circular_dependency) {
            has_cycle_error = true;
            break;
        }
    }
    try testing.expect(has_cycle_error);
}

test "Analyzer: valid import chain" {
    const source: [:0]const u8 =
        \\#wgsl common { value="fn helper() {}" }
        \\#wgsl shader { imports=[$wgsl.common] value="fn main() { helper(); }" }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    // No cycles, should pass
    var has_cycle_error = false;
    for (result.errors) |err| {
        if (err.kind == .circular_dependency) {
            has_cycle_error = true;
            break;
        }
    }
    try testing.expect(!has_cycle_error);
}

test "Analyzer: three-way cycle" {
    const source: [:0]const u8 =
        \\#wgsl a { imports=[$wgsl.b] value="" }
        \\#wgsl b { imports=[$wgsl.c] value="" }
        \\#wgsl c { imports=[$wgsl.a] value="" }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    var has_cycle_error = false;
    for (result.errors) |err| {
        if (err.kind == .circular_dependency) {
            has_cycle_error = true;
            break;
        }
    }
    try testing.expect(has_cycle_error);
}

// ----------------------------------------------------------------------------
// Shader Deduplication Tests
// ----------------------------------------------------------------------------

test "Analyzer: shader deduplication" {
    const source: [:0]const u8 =
        \\#wgsl common { value="fn helper() {}" }
        \\#wgsl shaderA { value="@vertex fn vs() {}" }
        \\#wgsl shaderB { value="@fragment fn fs() {}" }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
    try testing.expectEqual(@as(usize, 3), result.shader_fragments.len);

    // All different content, so different data_ids
    var ids = std.AutoHashMap(u16, void).init(testing.allocator);
    defer ids.deinit();

    for (result.shader_fragments) |frag| {
        try ids.put(frag.data_id, {});
    }
    try testing.expectEqual(@as(usize, 3), ids.count());
}

test "Analyzer: identical shaders share data_id" {
    const source: [:0]const u8 =
        \\#wgsl shaderA { value="fn same() {}" }
        \\#wgsl shaderB { value="fn same() {}" }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.shader_fragments.len);

    // Same content, should have same data_id
    try testing.expectEqual(result.shader_fragments[0].data_id, result.shader_fragments[1].data_id);
}

// ----------------------------------------------------------------------------
// Symbol Table Tests
// ----------------------------------------------------------------------------

test "Analyzer: symbol table population" {
    const source: [:0]const u8 =
        \\#wgsl shader { value="" }
        \\#buffer buf { size=100 }
        \\#frame main { perform=[] }
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), result.symbols.wgsl.count());
    try testing.expectEqual(@as(u32, 1), result.symbols.buffer.count());
    try testing.expectEqual(@as(u32, 1), result.symbols.frame.count());

    try testing.expect(result.symbols.wgsl.get("shader") != null);
    try testing.expect(result.symbols.buffer.get("buf") != null);
    try testing.expect(result.symbols.frame.get("main") != null);
}

// ----------------------------------------------------------------------------
// Complex Example Tests
// ----------------------------------------------------------------------------

test "Analyzer: simpleTriangle example" {
    const source: [:0]const u8 =
        \\#wgsl triangleShader { value="@vertex fn vs() {}" }
        \\#renderPipeline pipeline {
        \\  layout=auto
        \\  vertex={ entryPoint=vs module=$wgsl.triangleShader }
        \\}
        \\#renderPass pass {
        \\  pipeline=$renderPipeline.pipeline
        \\  draw=3
        \\}
        \\#frame main {
        \\  perform=[$renderPass.pass]
        \\}
    ;

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
    try testing.expectEqual(@as(u32, 1), result.symbols.wgsl.count());
    try testing.expectEqual(@as(u32, 1), result.symbols.render_pipeline.count());
    try testing.expectEqual(@as(u32, 1), result.symbols.render_pass.count());
    try testing.expectEqual(@as(u32, 1), result.symbols.frame.count());
}

test "Analyzer: empty input" {
    const source: [:0]const u8 = "";

    var result = try parseAndAnalyze(source);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.errors.len);
}
