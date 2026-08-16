//! wgslender WGSL Reflection Integration
//!
//! Provides WGSL shader reflection for the DSL compiler via native
//! wgslender Zig module.
//!
//! ## Usage
//!
//! ```zig
//! const reflection = try Wgslender.reflect(allocator, wgsl_source);
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
//! - WGSL source must be valid (parse errors returned in result.errors)
//! - Field offsets follow WGSL memory layout specification
//! - All allocations owned by ReflectionData, freed on deinit

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const wgslender_native = @import("wgslender_native.zig");

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
    /// For an `array<E, N>` field: the element's WGSL type name (e.g.
    /// "vec4<f32>"; a struct element carries the struct name). Empty when the
    /// field is not an array (or the element is unrepresentable, e.g. a
    /// nested array).
    elem_type: []const u8 = "",
    /// For an `array<E, N>` field: the const-evaluated element count N.
    /// 0 when the field is not an array or the array is runtime-sized.
    elem_count: u32 = 0,
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

/// Structured texture description for a handle binding. Mirrors
/// wgslender's `Reflect.TextureInfo`, but with the dimension/kind/access
/// enums flattened to their string spelling (`@tagName` / `.string()`) so
/// consumers need no wgslender-Ast dependency. All strings live for the
/// lifetime of the owning `ReflectionData`.
pub const TextureInfo = struct {
    /// Dimension: "1d", "2d", "2d_array", "3d", "cube", "cube_array".
    dim: []const u8 = "",
    /// Kind: "sampled", "multisampled", "storage", "depth",
    /// "depth_multisampled", "external".
    kind: []const u8 = "",
    /// Sample-type leaf for sampled/multisampled textures ("f32"/"i32"/
    /// "u32"); empty otherwise.
    sample_type: []const u8 = "",
    /// Texel format for storage textures (e.g. "rgba8unorm"); empty otherwise.
    format: []const u8 = "",
    /// Access mode for storage textures ("read"/"write"/"read_write");
    /// empty otherwise.
    access: []const u8 = "",
};

/// Structured sampler description for a handle binding.
pub const SamplerInfo = struct {
    /// True for `sampler_comparison`.
    comparison: bool = false,
};

/// What a binding actually binds. `buffer` covers uniform/storage buffers
/// (the default so existing consumers are unchanged); `texture`/`sampler`
/// cover handle bindings. Drives the bind resource-kind agreement check.
pub const Resource = union(enum) {
    buffer,
    texture: TextureInfo,
    sampler: SamplerInfo,
};

/// A uniform/storage/handle binding declaration.
pub const Binding = struct {
    /// Bind group index (0-3 in WebGPU).
    group: u32,
    /// Binding index within the group.
    binding: u32,
    /// Variable name from WGSL source.
    name: []const u8,
    /// Address space (uniform, storage, or handle for texture/sampler).
    address_space: AddressSpace,
    /// WGSL type name of the binding.
    type: []const u8,
    /// Memory layout for size/alignment calculation.
    layout: Layout,
    /// What this binding binds: buffer (default), texture, or sampler.
    resource: Resource = .buffer,
    /// Access mode for storage bindings ("read"/"write"/"read_write"); empty
    /// for uniform buffers and handle bindings.
    access_mode: []const u8 = "",
    /// For a bare `var<…> name: array<E, N>` binding: the element's WGSL type
    /// name. Empty when the binding's type is not an array.
    elem_type: []const u8 = "",
    /// For a bare array binding: the const-evaluated element count N.
    /// 0 when not an array or runtime-sized.
    elem_count: u32 = 0,

    pub const AddressSpace = enum {
        uniform,
        storage,
        /// Texture/sampler handle bindings (wgslender tags these "handle").
        handle,
        unknown,

        /// O(1) lookup via StaticStringMap.
        const string_map = std.StaticStringMap(AddressSpace).initComptime(.{
            .{ "uniform", .uniform },
            .{ "storage", .storage },
            .{ "handle", .handle },
        });

        pub fn fromString(s: []const u8) AddressSpace {
            return string_map.get(s) orelse .unknown;
        }
    };
};

/// A module-scope WGSL `override` declaration — a pipeline-overridable
/// constant, supplied at pipeline creation via `GPUProgrammableStage.constants`.
///
/// An override is the one programmable-stage input pngine cannot satisfy from
/// the payload: it is neither a binding (no `@group`/`@binding`) nor baked into
/// the shader text. One without a `default` and without a value therefore makes
/// its pipeline *uncreatable* — which is why `default` is carried here rather
/// than left in wgslender's result.
pub const Override = struct {
    /// Declared identifier, as written in source.
    name: []const u8,
    /// `@id(N)`, or null when absent. WebGPU keys `constants` by the numeric id
    /// when a declaration has one and by name otherwise — a distinction the
    /// constants work needs and this type only records.
    id: ?u32 = null,
    /// Type spelled in source (e.g. "f32"); empty when the declaration omitted
    /// it and the type is inferred from the initializer.
    typ: []const u8 = "",
    /// Default-value expression text, exactly as written. Empty when the
    /// declaration has no `= …` — THE field the diagnostic turns on.
    default: []const u8 = "",
    /// Byte range `[start, end)` of the whole declaration (attributes through
    /// `;`) in the reflected source. The edit range for an override→const
    /// rewrite; `{0,0}` when unknown.
    decl_start: u32 = 0,
    decl_end: u32 = 0,

    /// Whether this override must be supplied a value for its pipeline to be
    /// created. Reads as the predicate it is at every call site.
    pub fn needsValue(self: *const Override) bool {
        return self.default.len == 0;
    }
};

/// A pipeline-stage input or output slot (`@location(N)` or
/// `@builtin(name)`). Struct-typed parameters/returns are flattened to one
/// `IoVar` per attributed member upstream.
pub const IoVar = struct {
    /// Parameter/member name; empty for a directly-attributed return value.
    name: []const u8 = "",
    /// `@location(N)` value, or null when bound by `@builtin`.
    location: ?u32 = null,
    /// `@builtin(name)` value (e.g. "position", "vertex_index"); empty when
    /// bound by `@location`.
    builtin: []const u8 = "",
    /// Type spelled in source (e.g. "vec3<f32>").
    typ: []const u8 = "",
};

/// An entry point (vertex, fragment, compute).
pub const EntryPoint = struct {
    /// Function name from WGSL source.
    name: []const u8,
    /// Shader stage this entry point belongs to.
    stage: Stage,
    /// `@workgroup_size(x, y, z)` (compute only); `.{1,1,1}` when absent.
    /// An axis set from an `@override` constant is reported as 0.
    workgroup_size: [3]u32 = .{ 1, 1, 1 },
    /// Whether this entry declared an explicit `@workgroup_size`.
    has_workgroup_size: bool = false,
    /// Names of the bindings (module-scope `@group/@binding` vars) reachable
    /// from this entry's transitive call graph — i.e. the resources it
    /// actually uses. Drives the "used but unbound" check.
    resources: []const []const u8 = &.{},
    /// Stage inputs (one per attributed `@location`/`@builtin` slot).
    inputs: []const IoVar = &.{},
    /// Stage outputs (one per attributed `@location`/`@builtin` slot).
    outputs: []const IoVar = &.{},
    /// Names of the `override` constants reachable from this entry's transitive
    /// call graph, plus any driving its `@workgroup_size`. THE reason override
    /// checks belong at pipeline emission rather than at module emission: a
    /// module-wide override list would refuse a render pipeline over a module
    /// whose *compute* entry is the only one that reaches the override.
    /// Names index `ReflectionData.overrides`.
    overrides: []const []const u8 = &.{},

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

/// Parse error from wgslender.
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
    /// Module-scope `override` declarations, in source order. Empty for the
    /// overwhelming majority of modules.
    overrides: []const Override = &.{},
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

    /// Find a module-scope `override` declaration by name.
    /// Complexity: O(n) where n = overrides.len — a handful in practice, and
    /// zero for every module that declares none.
    pub fn getOverride(self: *const ReflectionData, name: []const u8) ?*const Override {
        // Pre-condition: name is not empty
        std.debug.assert(name.len > 0);
        for (self.overrides) |*o| {
            if (std.mem.eql(u8, o.name, name)) return o;
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

/// Wgslender reflection interface.
pub const Wgslender = struct {
    pub const Error = error{
        OutOfMemory,
        InvalidJson,
        ReflectFailed,
    };

    /// Reflect on WGSL source code.
    ///
    /// Returns reflection data with bindings, structs, and entry points.
    /// Caller owns the returned data and must call deinit().
    pub fn reflect(self: *const Wgslender, gpa: Allocator, wgsl_source: []const u8) Error!ReflectionData {
        _ = self;
        // Pre-conditions
        std.debug.assert(wgsl_source.len > 0);

        return wgslender_native.reflectNative(gpa, wgsl_source) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.ReflectFailed => error.ReflectFailed,
            };
        };
    }

    /// Parse JSON reflection output into ReflectionData.
    /// Kept for backward compatibility with JSON-based unit tests.
    pub fn parseJson(gpa: Allocator, json_data: []const u8) Error!ReflectionData {
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
        var bindings: std.ArrayList(Binding) = .empty;
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
        var entry_points: std.ArrayList(EntryPoint) = .empty;
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
        var errors: std.ArrayList(ParseError) = .empty;
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

        var fields: std.ArrayList(Field) = .empty;
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
