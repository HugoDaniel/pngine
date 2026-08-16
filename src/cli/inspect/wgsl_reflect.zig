//! Inspect's view of a shader's entry points and bindings, adapted from
//! wgslender reflection.
//!
//! ## Why this exists rather than a parser
//!
//! This module replaced `wgsl_parser.zig`, an 883-line hand-rolled WGSL
//! declaration scanner that self-described as "Does NOT fully parse WGSL
//! grammar". It extracted the same two things wgslender already extracts
//! authoritatively, which meant two WGSL front-ends had to track the language
//! as it evolved — and the weaker one was the one inspect reported from.
//!
//! What survives here is not parsing but *vocabulary*: inspect's
//! `AddressSpace` is finer-grained than wgslender's raw `address_space` tag,
//! distinguishing a read-only storage buffer from a read-write one and naming
//! texture/sampler handles by what they bind. That distinction is what makes
//! the JSON report useful, so it is mapped explicitly below.
//!
//! ## Invariants
//!
//! - All strings and slices are owned by the caller-supplied arena.
//! - Entry points and bindings preserve wgslender's declaration order.
//! - Bounded: at most MAX_ENTRY_POINTS / MAX_BINDINGS are reported per shader.

const std = @import("std");
const pngine = @import("pngine");

const reflect = pngine.reflect;

/// Maximum number of entry points reported per shader.
pub const MAX_ENTRY_POINTS: u8 = 16;

/// Maximum number of bindings reported per shader.
pub const MAX_BINDINGS: u8 = 32;

/// Entry point stage. Values match WebGPU's GPUShaderStage flags.
pub const Stage = enum(u8) {
    vertex = 1,
    fragment = 2,
    compute = 4,

    pub fn toString(self: Stage) []const u8 {
        return @tagName(self);
    }
};

/// What a binding binds, at the granularity inspect reports.
///
/// Finer than wgslender's `address_space`: a `var<storage, read>` and a
/// `var<storage, read_write>` share one address space but are different things
/// to a reader diagnosing a pipeline, and `handle` says nothing about whether
/// the resource is a texture or a sampler.
pub const AddressSpace = enum(u8) {
    uniform,
    storage,
    storage_read,
    storage_write,
    storage_read_write,
    texture,
    sampler,
    unknown,

    pub fn toString(self: AddressSpace) []const u8 {
        return switch (self) {
            .storage_read => "storage,read",
            .storage_write => "storage,write",
            .storage_read_write => "storage,read_write",
            else => @tagName(self),
        };
    }
};

/// A shader entry point.
pub const EntryPoint = struct {
    /// Function name. Borrowed from the arena.
    name: []const u8,
    stage: Stage,
    /// `@workgroup_size(x, y, z)` for compute entries; `.{0, 0, 0}` when the
    /// entry declares none (and for non-compute stages). Omitted axes read as
    /// 1, per WGSL — not 0, which is what the retired parser reported.
    workgroup_size: [3]u32 = .{ 0, 0, 0 },
};

/// A `@group(N) @binding(M)` declaration.
pub const Binding = struct {
    /// Variable name. Borrowed from the arena.
    name: []const u8,
    group: u32,
    binding: u32,
    address_space: AddressSpace,
    /// WGSL type name. Borrowed from the arena.
    type_name: []const u8,
};

/// One shader's reflected declarations. Slices are arena-owned.
pub const ShaderReflection = struct {
    entry_points: []const EntryPoint = &.{},
    bindings: []const Binding = &.{},
    /// False only when reflection could not run at all (empty source, or an
    /// allocation/reflect failure). It is NOT a "did this shader parse" flag:
    /// wgslender collects parse errors inside its result and still returns
    /// successfully, so unparseable source arrives here as `valid = true` with
    /// no entry points. Zero entry points is the signal for that.
    valid: bool = true,

    pub fn getEntryPoints(self: *const ShaderReflection) []const EntryPoint {
        return self.entry_points;
    }

    pub fn getBindings(self: *const ShaderReflection) []const Binding {
        return self.bindings;
    }

    pub fn hasEntryPoint(self: *const ShaderReflection, name: []const u8, stage: Stage) bool {
        for (self.entry_points) |ep| {
            if (ep.stage == stage and std.mem.eql(u8, ep.name, name)) return true;
        }
        return false;
    }
};

/// Map a wgslender binding onto inspect's finer address-space vocabulary.
fn addressSpaceOf(b: *const reflect.Binding) AddressSpace {
    return switch (b.address_space) {
        .uniform => .uniform,
        .handle => switch (b.resource) {
            .texture => .texture,
            .sampler => .sampler,
            // A handle that is neither is not something we can name.
            .buffer => .unknown,
        },
        .storage => blk: {
            if (std.mem.eql(u8, b.access_mode, "read")) break :blk .storage_read;
            if (std.mem.eql(u8, b.access_mode, "write")) break :blk .storage_write;
            if (std.mem.eql(u8, b.access_mode, "read_write")) break :blk .storage_read_write;
            break :blk .storage;
        },
        .unknown => .unknown,
    };
}

/// Reflect `wgsl_source` into inspect's shapes, allocating into `arena`.
///
/// Never fails: a shader that cannot be reflected yields an empty result, so
/// inspect can still report on the rest of a broken bundle. See `valid` for
/// what that flag does and does not tell you.
///
/// Complexity: O(source length) in wgslender, then O(entries + bindings).
pub fn reflectShader(arena: std.mem.Allocator, wgsl_source: []const u8) ShaderReflection {
    // Pre-condition: reflect() asserts a non-empty source.
    if (wgsl_source.len == 0) return .{ .valid = false };

    const wgslender = reflect.Wgslender{};
    var data = wgslender.reflect(arena, wgsl_source) catch return .{ .valid = false };
    defer data.deinit();

    const ep_count = @min(data.entry_points.len, MAX_ENTRY_POINTS);
    const b_count = @min(data.bindings.len, MAX_BINDINGS);

    const eps = arena.alloc(EntryPoint, ep_count) catch return .{ .valid = false };
    const binds = arena.alloc(Binding, b_count) catch return .{ .valid = false };

    var ep_out: usize = 0;
    for (data.entry_points[0..ep_count]) |ep| {
        // wgslender reports `unknown` for a function we cannot stage; there is
        // no inspect vocabulary for it, so it is not an entry point to report.
        const stage: Stage = switch (ep.stage) {
            .vertex => .vertex,
            .fragment => .fragment,
            .compute => .compute,
            .unknown => continue,
        };
        eps[ep_out] = .{
            .name = arena.dupe(u8, ep.name) catch return .{ .valid = false },
            .stage = stage,
            .workgroup_size = if (ep.has_workgroup_size) ep.workgroup_size else .{ 0, 0, 0 },
        };
        ep_out += 1;
    }

    for (data.bindings[0..b_count], 0..) |b, i| {
        binds[i] = .{
            .name = arena.dupe(u8, b.name) catch return .{ .valid = false },
            .group = b.group,
            .binding = b.binding,
            .address_space = addressSpaceOf(&b),
            .type_name = arena.dupe(u8, b.type) catch return .{ .valid = false },
        };
    }

    // Post-condition: reported counts stay within the documented bounds.
    std.debug.assert(ep_out <= MAX_ENTRY_POINTS);
    std.debug.assert(b_count <= MAX_BINDINGS);

    return .{ .entry_points = eps[0..ep_out], .bindings = binds, .valid = true };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Reflect into a caller-managed arena, for tests.
fn reflectForTest(arena: *std.heap.ArenaAllocator, src: []const u8) ShaderReflection {
    return reflectShader(arena.allocator(), src);
}
