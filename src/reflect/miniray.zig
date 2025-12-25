//! Miniray WGSL Reflection Integration
//!
//! Calls the miniray CLI to extract reflection data from WGSL shaders.
//! Used by the DSL compiler to auto-compute buffer sizes and generate
//! input metadata for the draw() API.
//!
//! ## Usage
//!
//! ```zig
//! const reflection = try Miniray.reflect(allocator, wgsl_source);
//! defer reflection.deinit(allocator);
//!
//! // Get buffer size for a uniform binding
//! if (reflection.getBinding(0, 0)) |binding| {
//!     const size = binding.layout.size;
//! }
//! ```
//!
//! ## Invariants
//!
//! - Requires `miniray` binary in PATH or specified via `miniray_path`
//! - WGSL source must be valid (parse errors returned in result.errors)
//! - Field offsets follow WGSL memory layout specification
//! - All allocations owned by ReflectionData, freed on deinit

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

/// Field within a struct layout.
pub const Field = struct {
    /// Field name from WGSL source. Never empty.
    name: []const u8,
    /// WGSL type name (e.g., "f32", "vec4<f32>").
    type: []const u8,
    /// Byte offset from struct start. Always aligned to `alignment`.
    offset: u32,
    /// Size in bytes. Always > 0.
    size: u32,
    /// Required alignment in bytes. Always power of 2.
    alignment: u32,
};

/// Memory layout of a struct or binding.
pub const Layout = struct {
    /// Total size in bytes, including padding. Always > 0 for valid bindings.
    size: u32,
    /// Required alignment in bytes. Always power of 2.
    alignment: u32,
    /// Fields in declaration order. May be empty for scalar types.
    fields: []const Field,
};

/// A uniform/storage binding declaration.
pub const Binding = struct {
    /// Bind group index (0-3 in WebGPU).
    group: u32,
    /// Binding index within the group.
    binding: u32,
    /// Variable name from WGSL source.
    name: []const u8,
    /// Address space (uniform or storage).
    address_space: AddressSpace,
    /// WGSL type name of the binding.
    type: []const u8,
    /// Memory layout for size/alignment calculation.
    layout: Layout,

    pub const AddressSpace = enum {
        uniform,
        storage,
        unknown,

        /// O(1) lookup via StaticStringMap.
        const string_map = std.StaticStringMap(AddressSpace).initComptime(.{
            .{ "uniform", .uniform },
            .{ "storage", .storage },
        });

        pub fn fromString(s: []const u8) AddressSpace {
            return string_map.get(s) orelse .unknown;
        }
    };
};

/// An entry point (vertex, fragment, compute).
pub const EntryPoint = struct {
    /// Function name from WGSL source.
    name: []const u8,
    /// Shader stage this entry point belongs to.
    stage: Stage,

    pub const Stage = enum {
        vertex,
        fragment,
        compute,
        unknown,

        /// O(1) lookup via StaticStringMap.
        const string_map = std.StaticStringMap(Stage).initComptime(.{
            .{ "vertex", .vertex },
            .{ "fragment", .fragment },
            .{ "compute", .compute },
        });

        pub fn fromString(s: []const u8) Stage {
            return string_map.get(s) orelse .unknown;
        }
    };
};

/// Parse error from miniray.
pub const ParseError = struct {
    /// Human-readable error description.
    message: []const u8,
    /// 1-based line number in source.
    line: u32,
    /// 1-based column number in source.
    column: u32,
};

/// Complete reflection data for a WGSL shader.
///
/// Invariants:
/// - All slices are valid for the lifetime of ReflectionData
/// - All string data is owned by the internal arena
/// - Bindings are unique by (group, binding) pair
pub const ReflectionData = struct {
    /// All uniform/storage bindings. Max 256 bindings (WebGPU limit).
    bindings: []const Binding,
    /// Named struct layouts. Keys are struct names from WGSL.
    structs: std.StringHashMapUnmanaged(Layout),
    /// Shader entry points. Typically 1-3 (vertex, fragment, compute).
    entry_points: []const EntryPoint,
    /// Parse errors if WGSL was invalid. Empty on success.
    errors: []const ParseError,

    /// Arena that owns all allocated memory.
    arena: std.heap.ArenaAllocator,

    /// Maximum bindings to search (WebGPU spec limit).
    const MAX_BINDINGS: usize = 256;

    pub fn deinit(self: *ReflectionData) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Find a binding by group and binding index.
    /// Complexity: O(n) where n = bindings.len, bounded by MAX_BINDINGS.
    pub fn getBinding(self: *const ReflectionData, group: u32, binding: u32) ?*const Binding {
        // Pre-condition: group is valid WebGPU bind group (0-3)
        std.debug.assert(group <= 3);

        // Bounded search
        const search_len = @min(self.bindings.len, MAX_BINDINGS);
        for (self.bindings[0..search_len]) |*b| {
            if (b.group == group and b.binding == binding) {
                return b;
            }
        }
        return null;
    }

    /// Find a binding by variable name.
    /// Complexity: O(n) where n = bindings.len, bounded by MAX_BINDINGS.
    pub fn getBindingByName(self: *const ReflectionData, name: []const u8) ?*const Binding {
        // Pre-condition: name is not empty
        std.debug.assert(name.len > 0);

        // Bounded search
        const search_len = @min(self.bindings.len, MAX_BINDINGS);
        for (self.bindings[0..search_len]) |*b| {
            if (std.mem.eql(u8, b.name, name)) {
                return b;
            }
        }
        return null;
    }

    /// Get struct layout by name.
    /// Complexity: O(1) hash lookup.
    pub fn getStruct(self: *const ReflectionData, name: []const u8) ?*const Layout {
        // Pre-condition: name is not empty
        std.debug.assert(name.len > 0);
        return self.structs.getPtr(name);
    }

    /// Check if reflection had parse errors.
    pub fn hasErrors(self: *const ReflectionData) bool {
        return self.errors.len > 0;
    }
};

/// Miniray reflection interface.
pub const Miniray = struct {
    /// Path to miniray binary. If null, uses "miniray" from PATH.
    miniray_path: ?[]const u8 = null,

    pub const Error = error{
        OutOfMemory,
        SpawnFailed,
        MinirayNotFound,
        ProcessFailed,
        InvalidJson,
        Timeout,
    };

    /// Reflect on WGSL source code.
    ///
    /// Returns reflection data with bindings, structs, and entry points.
    /// Caller owns the returned data and must call deinit().
    pub fn reflect(self: *const Miniray, gpa: Allocator, wgsl_source: []const u8) Error!ReflectionData {
        // Pre-conditions
        std.debug.assert(wgsl_source.len > 0);

        // Spawn miniray reflect subprocess
        const argv = [_][]const u8{
            self.miniray_path orelse "miniray",
            "reflect",
        };

        var child = std.process.Child.init(&argv, gpa);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch |err| {
            return switch (err) {
                error.FileNotFound => error.MinirayNotFound,
                else => error.SpawnFailed,
            };
        };

        // Write WGSL to stdin
        if (child.stdin) |stdin| {
            stdin.writeAll(wgsl_source) catch return error.ProcessFailed;
            stdin.close();
            child.stdin = null;
        }

        // Read stdout into buffer
        const stdout = child.stdout orelse return error.ProcessFailed;
        const max_output: u32 = 10 * 1024 * 1024; // 10MB max
        var output = std.ArrayListUnmanaged(u8){};
        defer output.deinit(gpa);

        var buf: [4096]u8 = undefined;
        for (0..max_output / 4096 + 1) |_| {
            const n = stdout.read(&buf) catch break;
            if (n == 0) break;
            output.appendSlice(gpa, buf[0..n]) catch return error.OutOfMemory;
        }

        // Wait for process
        const term = child.wait() catch return error.ProcessFailed;
        if (term.Exited != 0) {
            return error.ProcessFailed;
        }

        // Parse JSON output
        return parseJson(gpa, output.items);
    }

    /// Parse JSON reflection output into ReflectionData.
    fn parseJson(gpa: Allocator, json_data: []const u8) Error!ReflectionData {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        var parsed = json.parseFromSlice(json.Value, alloc, json_data, .{}) catch {
            return error.InvalidJson;
        };
        defer parsed.deinit();
        const root = parsed.value;

        if (root != .object) return error.InvalidJson;
        const obj = root.object;

        // Parse bindings
        var bindings: std.ArrayListUnmanaged(Binding) = .{};
        if (obj.get("bindings")) |bindings_val| {
            if (bindings_val == .array) {
                for (bindings_val.array.items) |item| {
                    if (parseBinding(alloc, item)) |binding| {
                        bindings.append(alloc, binding) catch return error.OutOfMemory;
                    }
                }
            }
        }

        // Parse structs
        var structs: std.StringHashMapUnmanaged(Layout) = .{};
        if (obj.get("structs")) |structs_val| {
            if (structs_val == .object) {
                var iter = structs_val.object.iterator();
                while (iter.next()) |entry| {
                    if (parseLayout(alloc, entry.value_ptr.*)) |layout| {
                        const name = alloc.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory;
                        structs.put(alloc, name, layout) catch return error.OutOfMemory;
                    }
                }
            }
        }

        // Parse entry points
        var entry_points: std.ArrayListUnmanaged(EntryPoint) = .{};
        if (obj.get("entryPoints")) |eps_val| {
            if (eps_val == .array) {
                for (eps_val.array.items) |item| {
                    if (parseEntryPoint(alloc, item)) |ep| {
                        entry_points.append(alloc, ep) catch return error.OutOfMemory;
                    }
                }
            }
        }

        // Parse errors
        var errors: std.ArrayListUnmanaged(ParseError) = .{};
        if (obj.get("errors")) |errors_val| {
            if (errors_val == .array) {
                for (errors_val.array.items) |item| {
                    if (parseParseError(alloc, item)) |err| {
                        errors.append(alloc, err) catch return error.OutOfMemory;
                    }
                }
            }
        }

        return ReflectionData{
            .bindings = bindings.toOwnedSlice(alloc) catch return error.OutOfMemory,
            .structs = structs,
            .entry_points = entry_points.toOwnedSlice(alloc) catch return error.OutOfMemory,
            .errors = errors.toOwnedSlice(alloc) catch return error.OutOfMemory,
            .arena = arena,
        };
    }

    fn parseBinding(alloc: Allocator, val: json.Value) ?Binding {
        if (val != .object) return null;
        const obj = val.object;

        const layout = if (obj.get("layout")) |l| parseLayout(alloc, l) orelse return null else return null;

        return Binding{
            .group = @intCast(obj.get("group").?.integer),
            .binding = @intCast(obj.get("binding").?.integer),
            .name = alloc.dupe(u8, obj.get("name").?.string) catch return null,
            .address_space = Binding.AddressSpace.fromString(obj.get("addressSpace").?.string),
            .type = alloc.dupe(u8, obj.get("type").?.string) catch return null,
            .layout = layout,
        };
    }

    fn parseLayout(alloc: Allocator, val: json.Value) ?Layout {
        if (val != .object) return null;
        const obj = val.object;

        var fields: std.ArrayListUnmanaged(Field) = .{};
        if (obj.get("fields")) |fields_val| {
            if (fields_val == .array) {
                for (fields_val.array.items) |item| {
                    if (parseField(alloc, item)) |field| {
                        fields.append(alloc, field) catch return null;
                    }
                }
            }
        }

        return Layout{
            .size = @intCast(obj.get("size").?.integer),
            .alignment = @intCast(obj.get("alignment").?.integer),
            .fields = fields.toOwnedSlice(alloc) catch return null,
        };
    }

    fn parseField(alloc: Allocator, val: json.Value) ?Field {
        if (val != .object) return null;
        const obj = val.object;

        return Field{
            .name = alloc.dupe(u8, obj.get("name").?.string) catch return null,
            .type = alloc.dupe(u8, obj.get("type").?.string) catch return null,
            .offset = @intCast(obj.get("offset").?.integer),
            .size = @intCast(obj.get("size").?.integer),
            .alignment = @intCast(obj.get("alignment").?.integer),
        };
    }

    fn parseEntryPoint(alloc: Allocator, val: json.Value) ?EntryPoint {
        if (val != .object) return null;
        const obj = val.object;

        return EntryPoint{
            .name = alloc.dupe(u8, obj.get("name").?.string) catch return null,
            .stage = EntryPoint.Stage.fromString(obj.get("stage").?.string),
        };
    }

    fn parseParseError(alloc: Allocator, val: json.Value) ?ParseError {
        if (val != .object) return null;
        const obj = val.object;

        return ParseError{
            .message = alloc.dupe(u8, obj.get("message").?.string) catch return null,
            .line = @intCast(obj.get("line").?.integer),
            .column = @intCast(obj.get("column").?.integer),
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Miniray: parse simple uniform binding" {
    const json_data =
        \\{"bindings":[{"group":0,"binding":0,"name":"u","addressSpace":"uniform","type":"Inputs","layout":{"size":16,"alignment":8,"fields":[{"name":"time","type":"f32","offset":0,"size":4,"alignment":4}]}}],"structs":{},"entryPoints":[]}
    ;

    var reflection = try Miniray.parseJson(std.testing.allocator, json_data);
    defer reflection.deinit();

    // Verify binding
    try std.testing.expectEqual(@as(usize, 1), reflection.bindings.len);
    const binding = reflection.bindings[0];
    try std.testing.expectEqual(@as(u32, 0), binding.group);
    try std.testing.expectEqual(@as(u32, 0), binding.binding);
    try std.testing.expectEqualStrings("u", binding.name);
    try std.testing.expectEqual(Binding.AddressSpace.uniform, binding.address_space);
    try std.testing.expectEqual(@as(u32, 16), binding.layout.size);

    // Verify field
    try std.testing.expectEqual(@as(usize, 1), binding.layout.fields.len);
    const field = binding.layout.fields[0];
    try std.testing.expectEqualStrings("time", field.name);
    try std.testing.expectEqual(@as(u32, 0), field.offset);
    try std.testing.expectEqual(@as(u32, 4), field.size);
}

test "Miniray: parse multiple bindings" {
    const json_data =
        \\{"bindings":[
        \\  {"group":0,"binding":0,"name":"uniforms","addressSpace":"uniform","type":"U","layout":{"size":64,"alignment":16,"fields":[]}},
        \\  {"group":0,"binding":1,"name":"storage","addressSpace":"storage","type":"S","layout":{"size":256,"alignment":4,"fields":[]}}
        \\],"structs":{},"entryPoints":[]}
    ;

    var reflection = try Miniray.parseJson(std.testing.allocator, json_data);
    defer reflection.deinit();

    try std.testing.expectEqual(@as(usize, 2), reflection.bindings.len);

    // Test getBinding lookup
    const b0 = reflection.getBinding(0, 0).?;
    try std.testing.expectEqualStrings("uniforms", b0.name);
    try std.testing.expectEqual(Binding.AddressSpace.uniform, b0.address_space);

    const b1 = reflection.getBinding(0, 1).?;
    try std.testing.expectEqualStrings("storage", b1.name);
    try std.testing.expectEqual(Binding.AddressSpace.storage, b1.address_space);

    // Test getBindingByName lookup
    const by_name = reflection.getBindingByName("storage").?;
    try std.testing.expectEqual(@as(u32, 1), by_name.binding);
}

test "Miniray: parse entry points" {
    const json_data =
        \\{"bindings":[],"structs":{},"entryPoints":[
        \\  {"name":"vertexMain","stage":"vertex"},
        \\  {"name":"fragmentMain","stage":"fragment"}
        \\]}
    ;

    var reflection = try Miniray.parseJson(std.testing.allocator, json_data);
    defer reflection.deinit();

    try std.testing.expectEqual(@as(usize, 2), reflection.entry_points.len);
    try std.testing.expectEqualStrings("vertexMain", reflection.entry_points[0].name);
    try std.testing.expectEqual(EntryPoint.Stage.vertex, reflection.entry_points[0].stage);
    try std.testing.expectEqual(EntryPoint.Stage.fragment, reflection.entry_points[1].stage);
}

test "Miniray: parse struct definitions" {
    const json_data =
        \\{"bindings":[],"structs":{
        \\  "Inputs":{"size":32,"alignment":16,"fields":[
        \\    {"name":"time","type":"f32","offset":0,"size":4,"alignment":4},
        \\    {"name":"resolution","type":"vec2<f32>","offset":8,"size":8,"alignment":8}
        \\  ]}
        \\},"entryPoints":[]}
    ;

    var reflection = try Miniray.parseJson(std.testing.allocator, json_data);
    defer reflection.deinit();

    const layout = reflection.getStruct("Inputs").?;
    try std.testing.expectEqual(@as(u32, 32), layout.size);
    try std.testing.expectEqual(@as(u32, 16), layout.alignment);
    try std.testing.expectEqual(@as(usize, 2), layout.fields.len);
}

test "Miniray: invalid JSON returns error" {
    const result = Miniray.parseJson(std.testing.allocator, "not valid json");
    try std.testing.expectError(error.InvalidJson, result);
}

test "Miniray: empty object parses successfully" {
    const json_data = \\{"bindings":[],"structs":{},"entryPoints":[]}
    ;

    var reflection = try Miniray.parseJson(std.testing.allocator, json_data);
    defer reflection.deinit();

    try std.testing.expectEqual(@as(usize, 0), reflection.bindings.len);
    try std.testing.expectEqual(@as(usize, 0), reflection.entry_points.len);
    try std.testing.expect(!reflection.hasErrors());
}

test "Miniray: integration test with real binary" {
    // Use explicit path to miniray in development
    const miniray = Miniray{ .miniray_path = "/Users/hugo/Development/miniray/miniray" };
    const wgsl =
        \\struct Uniforms {
        \\    time: f32,
        \\    resolution: vec2<u32>,
        \\}
        \\@group(0) @binding(0) var<uniform> u: Uniforms;
        \\
        \\@vertex fn vs() -> @builtin(position) vec4<f32> {
        \\    return vec4f(0.0);
        \\}
    ;

    var reflection = miniray.reflect(std.testing.allocator, wgsl) catch |err| {
        if (err == error.MinirayNotFound) {
            // Skip test if miniray is not installed
            return;
        }
        return err;
    };
    defer reflection.deinit();

    // Verify binding was parsed
    try std.testing.expectEqual(@as(usize, 1), reflection.bindings.len);
    const binding = reflection.bindings[0];
    try std.testing.expectEqual(@as(u32, 0), binding.group);
    try std.testing.expectEqual(@as(u32, 0), binding.binding);
    try std.testing.expectEqualStrings("u", binding.name);
    try std.testing.expectEqual(Binding.AddressSpace.uniform, binding.address_space);

    // Verify struct layout
    try std.testing.expectEqual(@as(u32, 16), binding.layout.size); // time(4) + padding(4) + resolution(8)
    try std.testing.expectEqual(@as(usize, 2), binding.layout.fields.len);

    // Verify entry point
    try std.testing.expectEqual(@as(usize, 1), reflection.entry_points.len);
    try std.testing.expectEqualStrings("vs", reflection.entry_points[0].name);
    try std.testing.expectEqual(EntryPoint.Stage.vertex, reflection.entry_points[0].stage);
}
