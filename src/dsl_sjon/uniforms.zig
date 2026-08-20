//! The emitter's reflection-facing pure layer: `(reflection data + SJON-side
//! facts) → answers`, with no `Emitter` in sight.
//!
//! Everything here is a pure function or a plain type. Nothing touches the id
//! tables, the builder, the diagnostic sink or the walk — which is what makes
//! this a seam rather than a folder. The diagnostics these predicates feed are
//! emitted at the call site in `Emitter.zig`, where the source span lives.
//!
//! Two concerns share the file because they share exactly one dependency
//! (`reflect`) and nothing else:
//!
//! - **Uniform-table flattening** — turn a reflected binding's struct layout
//!   into flat dot-notation leaves with absolute offsets, sorted by name for
//!   stable slot indices. Ported from the deleted legacy emitter
//!   (`src/dsl/emitter/resources.zig`, docs/journal.md §96).
//! - **R1 cross-validation predicates** — the `(SJON declares X, shader
//!   reflects Y)` disagreements, each a `bool` or a reason string.
//!
//! ## Invariants
//! - `flattenFields` never silently drops a leaf: every skip is counted in
//!   `DropCounts` and surfaced by the caller (journal §256/§257).
//! - A `FlattenedField.path` is gpa-owned; `freeFlattenedFields` is the only
//!   correct teardown.

const std = @import("std");
const Allocator = std.mem.Allocator;

const bytecode = @import("bytecode");
const reflect = @import("reflect");

const uniform_table = bytecode.uniform_table;
const BufferUsage = bytecode.opcodes.BufferUsage;

/// The resource kind a SJON `(entry …)` declares. Lives here rather than in the
/// emitter because the predicates below are its only consumers with an opinion;
/// `Emitter.zig` re-exports it for the map it keys.
pub const BindKind = enum { buffer, texture, sampler };

// ----------------------------------------------------------------------
// Uniform-table flattening (ported from the deleted legacy emitter,
// src/dsl/emitter/resources.zig — see docs/journal.md §96). Turns a reflected
// binding's struct layout into flat dot-notation leaves with absolute offsets,
// sorted by name for stable slot indices.
// ----------------------------------------------------------------------

/// Maximum nested-struct recursion depth. A DEGRADATION bound, deliberately not
/// asserted — see the note at the top of `flattenFields`.
pub const MAX_FLATTEN_DEPTH: u8 = 8;

/// One flattened leaf field, pre slot-assignment. `path` is gpa-owned.
pub const FlattenedField = struct {
    /// Full field path with dots (e.g. "position.x"). Owned by the gpa.
    path: []const u8,
    /// Absolute byte offset from buffer start.
    offset: u16,
    /// Byte size (an array leaf keeps its TOTAL bytes).
    size: u16,
    /// WGSL type (an array leaf carries its ELEMENT type).
    uniform_type: uniform_table.UniformType,
    /// Fixed array element count; 0 = not an array (see UniformField).
    elem_count: u8 = 0,
};

/// Sort FlattenedField by path → stable compile-time slot indices.
pub fn compareFlattenedFields(_: void, a: FlattenedField, b: FlattenedField) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// Leaves flattenFields skips, by reason — the caller surfaces both counts
/// as gated warnings (a silent skip is a setUniform no-op the author can't
/// see; journal §256/§257).
pub const DropCounts = struct {
    /// Leaf offset/size past the wire's u16 cap (large storage structs).
    oversize: u32 = 0,
    /// Leaves past the table's MAX_FIELDS-per-binding cap (very wide structs).
    overflow: u32 = 0,
    /// Subtrees below MAX_FLATTEN_DEPTH — counts SUBTREES, not leaves, since
    /// the whole branch is abandoned unexplored (its leaf count is unknown).
    too_deep: u32 = 0,
};

/// Recursively flatten a struct's fields into `out_fields` with dot-notation
/// paths and absolute offsets. Nested structs (resolved via `reflection.structs`)
/// recurse; leaves are appended. Bounded by MAX_FLATTEN_DEPTH and MAX_FIELDS.
/// Every leaf that doesn't land in `out_fields` lands in `dropped` — the
/// caller surfaces the counts (either cap was a silent skip once).
pub fn flattenFields(
    gpa: Allocator,
    reflection: *const reflect.ReflectionData,
    layout_fields: []const reflect.Field,
    base_offset: u32,
    prefix: []const u8,
    depth: u8,
    dropped: *DropCounts,
    out_fields: *std.ArrayList(FlattenedField),
) Allocator.Error!void {
    // The cap this function exists to respect, checked at EVERY exit including
    // the error ones — `emitRecord` casts each leaf's index into the wire's slot
    // field on the strength of it, and the whole `DropCounts.overflow` counter
    // is only meaningful if the list it guards actually stays bounded.
    defer std.debug.assert(out_fields.items.len <= uniform_table.MAX_FIELDS);

    // A DEGRADATION bound, not an invariant. Nesting depth comes from user WGSL,
    // so exceeding it is INPUT, not a broken assumption — the `assert(depth <=
    // MAX_FLATTEN_DEPTH)` that stood here pre-empted this `if` and turned a
    // 9-deep struct into a compiler panic (in Debug/ReleaseSafe, which is what
    // pstudio's wasm compiler ships). Count the abandoned subtree instead; the
    // caller surfaces it beside `oversize`/`overflow`.
    if (depth > MAX_FLATTEN_DEPTH) {
        dropped.too_deep += 1;
        return;
    }

    for (layout_fields) |field| {
        const absolute_offset: u32 = base_offset + field.offset;

        if (reflection.structs.getPtr(field.type)) |nested_layout| {
            // Nested struct → recurse. Still descends when the table is full
            // so every dropped leaf below is counted, never vanished.
            const path = if (prefix.len > 0)
                try std.fmt.allocPrint(gpa, "{s}.{s}", .{ prefix, field.name })
            else
                try gpa.dupe(u8, field.name);
            defer gpa.free(path);
            try flattenFields(gpa, reflection, nested_layout.fields, absolute_offset, path, depth + 1, dropped, out_fields);
        } else {
            // Leaf field. Two counted drop reasons: the per-binding field cap,
            // and offsets/sizes past the wire's u16 (a storage buffer can
            // exceed it — skip rather than @intCast-panic in safe builds).
            if (out_fields.items.len >= uniform_table.MAX_FIELDS) {
                dropped.overflow += 1;
                continue;
            }
            if (absolute_offset > std.math.maxInt(u16) or field.size > std.math.maxInt(u16)) {
                dropped.oversize += 1;
                continue;
            }
            const path = if (prefix.len > 0)
                try std.fmt.allocPrint(gpa, "{s}.{s}", .{ prefix, field.name })
            else
                try gpa.dupe(u8, field.name);
            errdefer gpa.free(path);
            const typed = leafType(field.type, field.elem_type, field.elem_count);
            try out_fields.append(gpa, .{
                .path = path,
                .offset = @intCast(absolute_offset),
                .size = @intCast(field.size),
                .uniform_type = typed.uniform_type,
                .elem_count = typed.elem_count,
            });
        }
    }
}

/// Free the gpa-owned `path` of every FlattenedField, then the list.
pub fn freeFlattenedFields(gpa: Allocator, fields: *std.ArrayList(FlattenedField)) void {
    for (fields.items) |f| gpa.free(f.path);
    fields.deinit(gpa);
}

/// Wyhash over a binding's SORTED flattened leaves (path, offset, size, type,
/// elem_count) — the "same shape" test for the dedup-by-buffer join. Two
/// modules reflecting an identical struct at the same buffer hash equal → one
/// table record; a disagreement keeps both records. Pure; caller sorts first.
pub fn shapeHashOf(fields: []const FlattenedField) u64 {
    std.debug.assert(fields.len > 0);
    // pre: sorted by path. "Caller sorts first" was documented and unchecked,
    // and an unsorted list does not crash — it hashes two IDENTICAL shapes to
    // different values, so the dedup keeps both records and the uniform table is
    // quietly wrong. Bounded by MAX_FIELDS, and Debug/ReleaseSafe only.
    for (1..fields.len) |i| {
        std.debug.assert(!compareFlattenedFields({}, fields[i], fields[i - 1]));
    }
    var h = std.hash.Wyhash.init(0x504e_4742); // "PNGB"
    for (fields) |f| {
        h.update(f.path);
        h.update(&[_]u8{0}); // path terminator (paths never contain NUL)
        h.update(std.mem.asBytes(&f.offset));
        h.update(std.mem.asBytes(&f.size));
        const ut: u8 = @intFromEnum(f.uniform_type);
        h.update(std.mem.asBytes(&ut));
        h.update(std.mem.asBytes(&f.elem_count));
    }
    return h.final();
}

/// Resolve a leaf's `(uniform_type, elem_count)` pair from its reflected type
/// strings. A fixed-size array with a wire-representable count (1..255) is
/// stamped with its ELEMENT type + count — the element may still map to
/// `.unknown` (struct elements), the count alone tells consumers it is an
/// array of size/count-stride elements. Everything else (plain fields,
/// runtime-sized or oversized arrays) keeps the direct mapping with count 0,
/// byte-identical to the pre-array behavior. Pure.
pub fn leafType(
    type_str: []const u8,
    elem_type: []const u8,
    elem_count: u32,
) struct { uniform_type: uniform_table.UniformType, elem_count: u8 } {
    if (elem_count >= 1 and elem_count <= std.math.maxInt(u8)) {
        const narrowed: u8 = @intCast(elem_count);
        // post: the narrowing is lossless. The range test above and this cast are
        // the same decision written twice; an edit to one that misses the other
        // silently reports an array of the wrong length to `setUniform`.
        std.debug.assert(narrowed == elem_count);
        return .{
            .uniform_type = uniform_table.UniformType.fromWgslType(elem_type),
            .elem_count = narrowed,
        };
    }
    return .{ .uniform_type = uniform_table.UniformType.fromWgslType(type_str), .elem_count = 0 };
}

// --- R1 semantic cross-validation (SJON ↔ WGSL reflection) ------------------
//
// Two pure predicates, each `(SJON-side facts + reflection) → bool`, joined at
// the populateUniformTable reflection join under `validate_shaders`. Their
// diagnostics — like every strict-validation check — are emitted at the call
// site through `Emitter.diagnose` (stderr for the CLI + the Diag sink).

/// R1 check ②: is a reflected binding referenced by any entry point's transitive
/// call graph (i.e. a resource the shader actually uses)? Filters the "used but
/// unbound" diagnostic to bindings that matter, so a declared-but-unused binding
/// under `:layout auto` is never a false positive. Pure over ReflectionData.
pub fn bindingUsedByAnyEntry(rd: *const reflect.ReflectionData, binding_name: []const u8) bool {
    for (rd.entry_points) |ep| {
        for (ep.resources) |res| {
            if (std.mem.eql(u8, res, binding_name)) return true;
        }
    }
    return false;
}

/// R1 check ③: does the buffer's declared usage satisfy the address space the
/// shader binds it at? A `var<uniform>` needs UNIFORM usage; a `var<storage>`
/// needs STORAGE usage — a disagreement WebGPU rejects at bind time. Other
/// address spaces never reach here (the caller filters to uniform/storage
/// buffer-backed bindings). Pure.
pub fn addressSpaceMismatch(space: reflect.Binding.AddressSpace, usage: BufferUsage) bool {
    return switch (space) {
        .uniform => !usage.uniform,
        .storage => !usage.storage,
        else => false,
    };
}

// --- R1 Task 3: pipeline/entry cross-validation --------------------------------
//
// Two more pure predicates joined under `validate_shaders`: an over-limit compute
// @workgroup_size (checked at compute-pipeline emit) and a bind resource-kind
// disagreement (checked at the populateUniformTable join). Both label their
// diagnostic `.wgsl` — the fix lives in the shader / the shader↔binding pairing.

/// Compute-workgroup limits consumed by `checkWorkgroupSize`. Defaults are the
/// WebGPU spec minimums; a top-level `(limits …)` form raises any of them via
/// `collectDeviceLimits`. (Arc-3 §5.3b)
pub const WgLimits = struct {
    x: u32 = 256,
    y: u32 = 256,
    z: u32 = 64,
    invocations: u32 = 256,
};

/// R1 Task 3, check ④: does a reflected compute `@workgroup_size(x,y,z)` exceed
/// the effective limits? Defaults are WebGPU's minimums (per-axis 256/256/64,
/// product `maxComputeInvocationsPerWorkgroup` 256); an authored `(limits …)` form
/// raises them, so `@workgroup_size(512)` compiles once the matching limit is
/// declared. Returns a short reason on violation, or null when within limits. An
/// axis of 0 is an `@override` wgslender can't resolve at compile time — every
/// check passes vacuously for it (0 ≤ each cap, and a 0 factor makes the product
/// 0), so an override-driven size is never flagged. We validate only what we can
/// see. Pure.
pub fn workgroupSizeExceedsLimits(wg: [3]u32, lim: WgLimits) ?[]const u8 {
    if (wg[0] > lim.x) return "x exceeds maxComputeWorkgroupSizeX";
    if (wg[1] > lim.y) return "y exceeds maxComputeWorkgroupSizeY";
    if (wg[2] > lim.z) return "z exceeds maxComputeWorkgroupSizeZ";
    const total = @as(u64, wg[0]) * @as(u64, wg[1]) * @as(u64, wg[2]);
    if (total > lim.invocations) return "x*y*z exceeds maxComputeInvocationsPerWorkgroup";
    return null;
}

/// R1 Task 3, check ⑤: does the SJON-declared bind kind disagree with what the
/// shader reflects at this `(group, binding)`? A `var<uniform>`/`var<storage>`
/// buffer, a `texture_*`, and a `sampler` are three distinct bind-group entry
/// shapes WebGPU rejects mixing. Pure.
pub fn reflectedKindMismatch(resource: reflect.Resource, sjon_kind: BindKind) bool {
    return switch (resource) {
        .buffer => sjon_kind != .buffer,
        .texture => sjon_kind != .texture,
        .sampler => sjon_kind != .sampler,
    };
}

/// Human name of a reflected `Resource` tag, for the diagnostic message.
pub fn reflectedKindName(resource: reflect.Resource) []const u8 {
    return switch (resource) {
        .buffer => "buffer",
        .texture => "texture",
        .sampler => "sampler",
    };
}

// --- Tests ------------------------------------------------------------------
