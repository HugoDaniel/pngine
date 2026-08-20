//! SJON → PNGB emitter.
//!
//! Walks the validated/lowered SJON forest (`HostResult`) and emits PNGB by
//! calling the **unchanged** `bytecode/format.Builder` + `bytecode/emitter` API.
//! Emission follows a fixed phase order (data → shaders → buffers →
//! render-pipelines → compute-pipelines → bind-groups → pass-definitions →
//! frames), and that order is pinned byte-for-byte by the frozen golden MockGPU
//! traces (`tests/zig/golden/*.trace`, run by `test-sjon-golden`) — reorder a
//! phase and a trace digest shifts. Resource IDs are assigned in forest order.
//!
//! ## Walk set
//! Every `data_forest` form that is NOT a `lowering_provenance` source (skips the
//! `(init …)` sugar) plus every `lowered_tree.root` form (the `pngine/init-v1`
//! outputs). Source forms read through `materialized_defaults`; lowered forms
//! read through an empty overlay (the hook emits every key explicitly).
//!
//! ## Descriptor formats (must match the legacy emitter for the comparator)
//! - render pipeline: JSON `{"vertex":{…},"fragment":{…},"primitive":{…}}`
//! - compute pipeline: binary `[0x06][shader u16 LE][entry_len u8][entry]`
//! - bind group entries: `[0x03][2][0x01 0x07 group][0x02 0x03 n]` + per-entry
//!   `[binding][0x00][id u16 LE][offset u32 LE][size u32 LE]`
//! - render/compute pass descriptor: the 2-byte blob `"{}"`

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const sjon = @import("sjon");
const bytecode = @import("bytecode");
// WGSL semantic validation + entry-point reflection (wgslender, freestanding-clean
// — already used by the in-browser compiler). Drives the `validate_shaders`
// emit-time diagnostics: bad-WGSL rejection + pipeline entry-point existence.
const reflect = @import("reflect");

const Ast = sjon.Ast;
const Expr = sjon.Expr;
const Schema = sjon.Schema;
const Host = sjon.Host;
const NodeIndex = Ast.NodeIndex;

const format = bytecode.format;
const opcodes = bytecode.opcodes;
// Uniform-reflection table (UniformField / UniformType / MAX_*); populated by
// `populateUniformTable` so the runtime can `setUniform(name, …)` by field name.
const uniform_table = bytecode.uniform_table;
const BufferUsage = opcodes.BufferUsage;
const LoadOp = opcodes.LoadOp;
const StoreOp = opcodes.StoreOp;
const PassType = opcodes.PassType;
const ColorAttachment = bytecode.Emitter.ColorAttachment;

/// Args per `(wasm-call …)`, from the wire schema. The emitter is the one place
/// this cap has to be a REJECT rather than a clamp: everything downstream can
/// only refuse a stream that breaks it, and only this end knows the source line.
const MAX_WASM_ARGS: usize = bytecode.wire_schema.repMaxOf(.call_wasm_func);

/// Color attachments per render pass. WebGPU's `maxColorAttachments` floor, the
/// width of `begin_render_pass_mrt`'s attachment array, and the native backend's
/// own `MAX_COLOR_ATTACHMENTS` — one number, three consumers, so the emitter
/// rejects at the same boundary the runtime asserts at.
const MAX_COLOR_ATTACHMENTS: usize = 8;

/// Instances in a `:pool` ping-pong run. The pool index is a byte everywhere the
/// wire carries it — `IdTable.Entry.count`, the descriptor encoders, the
/// executor's pool arithmetic — so 255 is the wire's number, not a policy. Kept
/// in lockstep with `pool-size`'s `:max` in schema/pngine.sjon: the schema
/// rejects an out-of-range LITERAL, `reservePool` rejects the expression
/// spelling the schema's repr check cannot see.
const MAX_POOL_SIZE: u32 = 255;

/// Ceiling on the bytes a document's shape generators may produce in total
/// (32 MiB). A payload is data embedded in a PNG — the largest honest mesh in
/// the corpus (the dragon, 8 attributes) is ~0.7 MB, and every legitimate
/// document is far below this; a document at the ceiling has asked the
/// compiler for more mesh than any PNG should carry. See `generated_bytes`.
const MAX_GENERATED_BYTES: u64 = 32 * 1024 * 1024;

/// Steps a single frame may carry, counting a `(queue …)`'s positional actions.
///
/// The command buffer is 64 KB and the cheapest step that emits anything is a
/// compute pass (~18 B), so ~3,640 steps alone exhaust it — and `CommandBuffer`
/// does not truncate past that, it TEARS: `writeCmd` counts the command before
/// the bounds-checked byte write, so the header claims operands that were never
/// written and the JS reader parses the next opcode as the previous command's
/// argument. 2048 is below that with headroom, and 25x the corpus's longest list.
///
/// The schema carries the same number as `:max-len` on the three frame list
/// kinds. It cannot carry the queue half: `(queue …)` actions are POSITIONAL
/// sub-forms, which have no length for a `vector-shape` to bound — hence the
/// counted check here (§348, LEAK-11-E).
const MAX_FRAME_STEPS: usize = 2048;

const values = @import("values.zig");
const Reader = values.Reader;
const Env = values.Env;

// Reused, unchanged backend modules (no Ast/Analyzer coupling — see CONTRIBUTING
// §17): compile-time shape vertex/index generators + the binary descriptor
// encoder, wired as modules in build.zig (file imports can't escape dsl_sjon/).
const shapes = @import("shapes");
const DescriptorEncoder = @import("descriptor_encoder").DescriptorEncoder;
// Minimal WASM parser (vendored) — reads `l`/`s`/`gen` exports to size + fill a
// `(pass … :file …)` storage buffer from the WASM file's data segment.
const wasm_data = @import("wasm_data");
// R4 Tier 2 — pure typed-agreement comparators (texture/sampler descriptor class
// vs the shader's reflected types), consumed at the populateUniformTable join.
const type_agree = @import("type_agree.zig");
// The reflection-facing pure layer: uniform-struct flattening + the R1
// cross-validation predicates. Extracted (r1-07) so the half of the emitter that
// talks to wgslender cannot reach the id tables, the builder or the walk — the
// seam is enforced by what that file does not import, not by convention.
const uniforms = @import("uniforms.zig");
const FlattenedField = uniforms.FlattenedField;
const DropCounts = uniforms.DropCounts;
// Re-exported: the emitter holds a `BindKind`-valued map and a `WgLimits` field,
// but only `uniforms`' predicates have an opinion about either.
const BindKind = uniforms.BindKind;
const WgLimits = uniforms.WgLimits;

const StringMapU16 = std.StringHashMapUnmanaged(u16);

/// Ping-pong pool info: `pool` sequential ids starting at `base`.
const PoolInfo = struct { base: u16, size: u8 };

/// A name→id registry for ONE resource kind: the name map, the id counter and
/// the teardown as a single value.
///
/// Each kind used to be three separate declarations — a
/// `StringHashMapUnmanaged(u16)`, a `next_*_id: u16`, and a line in `deinit` —
/// with nothing tying them together, plus a fourth (`*_pools`) for the three
/// kinds that ping-pong. A forgotten `deinit` line leaked silently: only under
/// `testing.allocator`, and only if a test happened to exercise that kind.
/// Grouped into `Tables`, whose `deinit` is a comptime field loop, the
/// forgotten line stops being possible rather than merely being caught.
///
/// The backing store stays `std.StringHashMapUnmanaged` DELIBERATELY. Ids are
/// handed out in walk order and never in iteration order, so map order does not
/// reach the emitted bytes — but that is a property worth keeping by not
/// touching the store rather than by re-proving it. Swapping in an ordered map
/// is a separate decision with its own gate (docs/plans/r1/09).
fn IdTable(comptime Id: type) type {
    return struct {
        const Self = @This();

        /// `count` sequential ids starting at `base`. `count > 1` is a ping-pong
        /// pool, whose BASE is the anchor every cross-validation join keys on.
        const Entry = struct { base: Id, count: u8 };

        map: std.StringHashMapUnmanaged(Entry) = .empty,
        /// The next unallocated id — read directly by the cap check in
        /// `allocPassId` and by the `id < next` pre-conditions.
        next: Id = 0,

        /// Reserve `count` sequential ids under `name`; returns the base.
        ///
        /// `EmitError` on exhaustion: ids are u16 on the wire, and `next +=
        /// count` used to wrap silently — every id past the wrap ALIASES a live
        /// resource, so a document large enough to reach it would emit bytecode
        /// that binds the wrong buffers rather than being refused. Reachable
        /// from a 16 MiB CLI input, and from ~258 `(buffer :pool 255)` forms
        /// (~11 KB) before the pool cap landed. The `:pool` sites pre-check this
        /// with a located diagnostic; this is the backstop for the ~20 plain
        /// `intern` call sites, which have no author-facing number to point at.
        ///
        /// The two exhaustion returns below are the ONLY `error.EmitError`s in
        /// this file that carry no message (05 §6 swept the rest). Deliberate:
        /// `IdTable` is generic over the id type and holds no reader, no node and
        /// no diagnostic sink, so it has nothing to point at — and threading one
        /// in would put a sink on twenty call sites to describe a document with
        /// 65,535 resources of one kind. The reachable spelling of that document,
        /// `(buffer :pool …)`, is pre-checked where the author wrote the number.
        fn reserve(self: *Self, gpa: Allocator, name: []const u8, count: u8) error{ OutOfMemory, EmitError }!Id {
            std.debug.assert(name.len > 0); // pre: named form (validator guarantees it)
            std.debug.assert(count > 0); // pre: a pool of nothing is not a resource
            if (@as(u32, self.next) + count > std.math.maxInt(Id)) return error.EmitError;
            const base = self.next;
            try self.map.put(gpa, name, .{ .base = base, .count = count });
            self.next += count;
            std.debug.assert(self.next == base + count); // post: exactly count ids
            return base;
        }

        /// Reserve exactly one id under `name`.
        fn intern(self: *Self, gpa: Allocator, name: []const u8) error{ OutOfMemory, EmitError }!Id {
            return self.reserve(gpa, name, 1);
        }

        /// Reserve one id with NO name — the emitter's own bookkeeping ids (a
        /// `(pass … :file …)` module, the synthesized `gen()` call) that nothing ever
        /// looks up by name. No map entry, so no allocation; the id space is the
        /// one thing it can still run out of.
        fn allocAnonymous(self: *Self) error{EmitError}!Id {
            if (self.next == std.math.maxInt(Id)) return error.EmitError;
            const id = self.next;
            self.next += 1;
            return id;
        }

        fn get(self: *const Self, name: []const u8) ?Id {
            return if (self.map.get(name)) |e| e.base else null;
        }

        /// The pool `name` declares, or null when it is a single resource —
        /// exactly the presence test the separate `*_pools` maps answered, now
        /// derived from the one entry instead of duplicated beside it.
        fn pool(self: *const Self, name: []const u8) ?PoolInfo {
            const e = self.map.get(name) orelse return null;
            return if (e.count > 1) .{ .base = e.base, .size = e.count } else null;
        }

        /// Reverse-map an id to the name that reserved it (bounded scan over the
        /// registry; warning messages only — off every hot path). A pool answers
        /// for its whole range; the ranges are disjoint by construction.
        fn nameOf(self: *const Self, id: Id) ?[]const u8 {
            var it = self.map.iterator();
            while (it.next()) |e| {
                const base = e.value_ptr.base;
                if (id >= base and id < base + e.value_ptr.count) return e.key_ptr.*;
            }
            return null;
        }

        fn deinit(self: *Self, gpa: Allocator) void {
            self.map.deinit(gpa);
        }
    };
}

/// A `StringHashMapUnmanaged` whose VALUES own heap memory, released by
/// `freeValue` at teardown.
///
/// Exists so `Tables.deinit` can stay a comptime field loop: a map needing
/// custom teardown would otherwise be the one field the loop cannot cover, and
/// therefore the one field that leaks when someone forgets it — which is exactly
/// the bug class the grouping removes. Two maps need it (`shader_analysis` frees
/// its WGSL and its reflection arena, `shader_entries` frees its entry-set keys), and two hand-written
/// exceptions are two too many.
fn OwningStringMap(comptime V: type, comptime freeValue: fn (Allocator, *V) void) type {
    return struct {
        const Self = @This();

        map: std.StringHashMapUnmanaged(V) = .empty,

        fn deinit(self: *Self, gpa: Allocator) void {
            var it = self.map.valueIterator();
            while (it.next()) |v| freeValue(gpa, v);
            self.map.deinit(gpa);
        }
    };
}

/// One shader module's post-emission truth: the bytes that SHIPPED, and the
/// reflection OF those bytes. Built once in `emitShaderModule`, read by every
/// gated pipeline check and by `populateUniformTable`.
///
/// This replaced a `name → owned WGSL` map that four sites each re-reflected,
/// costing a full tokenize→parse→analyze apiece: measured 3.87 `reflectNative`
/// calls per module across the corpus (690 for 178 modules), at ~2 ms each.
/// wgslender hands back minification AND reflection from ONE parse, so under
/// `--minify` the reflection here is free — it is the other half of a call the
/// emit already makes.
///
/// `reflection` is null only when the reflect INFRA failed (realistically OOM
/// inside wgslender). That is a state worth naming: it used to be indistinguish-
/// able from "module not found", because each site opened with an `orelse
/// return` that silently skipped its check.
///
/// Lifetime: each `ReflectionData` owns an arena, so N live analyses are N
/// independent arenas with no cross-references. The predecessor's
/// reflect-consume-free-immediately policy was defending against a slice from
/// module A outliving A's arena; audited, nothing stores one — `EmittedShape`
/// and `FieldOwner` hold `ref.name` (a SOURCE slice, which outlives the emit)
/// and gpa-owned path dupes.
const ModuleAnalysis = struct {
    /// gpa-owned; the shipped text (minified when `--minify`, else the author's).
    /// `const` because the minify path hands back a `[]const u8` — ownership is
    /// what matters here, not mutability, and `Allocator.free` takes either.
    wgsl: []const u8,
    /// Reflection of `wgsl`. Null iff reflection infrastructure failed.
    reflection: ?reflect.ReflectionData,
};

/// Release one `shader_analysis` value. Spelled out because `OwningStringMap`
/// takes a function, not a method.
fn freeModuleAnalysis(gpa: Allocator, analysis: *ModuleAnalysis) void {
    gpa.free(analysis.wgsl);
    if (analysis.reflection) |*r| r.deinit();
}

/// Index data emitted alongside an indexed shape (teapot/dragon). Keyed by the
/// shape's `(data :name …)` name; consumed by a buffer's `:index-of` key.
const IndexData = struct { data_id: u16, byte_len: u32, format: u8 };
// Static `(wasm-data …)` mesh generator, keyed by data name; consumed by a buffer's
// `:size` (byte_size) and `:data` (call_wasm_func + write_buffer_from_wasm).
const WasmMeshData = struct { module_id: u16, func_name_id: u16, byte_size: u32 };

/// Correlation key joining a reflected uniform/storage binding to the GPU buffer
/// bound at its `(group, binding)`. Recorded in `emitBindGroup`, consumed by
/// `populateUniformTable`.
const UniformBindingKey = struct { group: u8, binding: u8 };

/// One (shader module → pipeline) instantiation row, recorded per stage by the
/// pipeline phases. Joined against `scoped_bindings` by the uniform-table pass
/// to resolve a reflected binding's buffer PER PIPELINE — under `:layout auto`
/// a (group, binding) slot is pipeline-scoped, not document-global.
const ModulePipeline = struct { module: []const u8, pipeline: u16 };

/// One (pipeline, group, binding) → BASE buffer id row, recorded in
/// `emitBindGroup` for groups whose `:layout` names a pipeline
/// (a group whose `:layout` names a bind-group-layout has no pipeline scope → no row; the global
/// `uniform_bindings` join covers it). A flat multimap over bounded scans.
const ScopedBinding = struct { pipeline: u16, group: u8, binding: u8, buffer: u16 };

/// One shader module in EMIT order (+ whether it lowered from `(pass …)`/`(init …)`
/// sugar). `populateUniformTable` iterates this list instead of `shader_analysis`'s
/// hash order so the uniform table is deterministic; `lowered` exempts the
/// sugar's per-pass prelude modules (identical field names by construction)
/// from the cross-buffer name-collision warning.
const ShaderRef = struct { name: []const u8, lowered: bool };

/// Cap on distinct buffers one module's (group, binding) can resolve to across
/// its pipelines (9+ distinct reuses of one slot is beyond any real document;
/// extras are silently capped — the table just lists the first 8).
const MAX_UNIFORM_CANDIDATES = 8;

/// The buffers a module's (group, binding) resolves to: the per-pipeline
/// scoped join's distinct hits, or (when it finds none) the single global
/// `uniform_bindings` fallback. `scoped` marks which — a scoped resolution is
/// authoritative (the R1 buffer checks always run), a global one only when the
/// slot isn't ambiguous.
const Candidates = struct {
    ids: [MAX_UNIFORM_CANDIDATES]u16 = undefined,
    len: u8 = 0,
    scoped: bool = false,

    /// Append a distinct id (bounded, capped — see MAX_UNIFORM_CANDIDATES).
    fn add(self: *Candidates, id: u16) void {
        std.debug.assert(self.len <= MAX_UNIFORM_CANDIDATES);
        for (self.ids[0..self.len]) |existing| if (existing == id) return;
        if (self.len >= MAX_UNIFORM_CANDIDATES) return;
        self.ids[self.len] = id;
        self.len += 1;
    }
};

/// What the uniform table already holds for a buffer: the flattened-shape hash
/// (the dedup test — same buffer + same shape → one record) and the first
/// module that emitted it (named in the shape-disagreement warning).
const EmittedShape = struct { shape_hash: u64, module: []const u8 };

/// The first buffer/module a leaf field name was emitted for, plus whether
/// that module lowered from sugar (two lowered modules sharing prelude names
/// are exempt from the ambiguity warning). Keys of the owning map are
/// gpa-owned path dupes.
const FieldOwner = struct { buffer: u16, module: []const u8, lowered: bool };
const FieldOwners = std.StringHashMapUnmanaged(FieldOwner);

/// Free the gpa-owned path keys, then the map.
fn freeFieldOwners(gpa: Allocator, owners: *FieldOwners) void {
    var it = owners.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    owners.deinit(gpa);
}

/// Bound-buffer facts the R1 cross-validation checks join against reflection at
/// the `populateUniformTable` reflection join: the declared byte-size (for the
/// size-adequacy check) and usage bits (for the address-space agreement check).
/// Recorded in `emitBuffer` at the BASE id — the same id `uniform_bindings`
/// records. Read under `validate_shaders` by the R1 joins, and unconditionally
/// by `checkBufferSlice` (bind-group `:offset/:size` bounds).
const BufferMeta = struct { size: u32, usage: BufferUsage, loc: ?Diag.Located = null };

/// Bound-texture facts the R4 texture sample-class check joins against reflection:
/// the declared `:format` (mapped to a sample class) + the `(texture …)` form's
/// user span for the squiggle. Recorded in `emitTexture` at the BASE id — the id
/// `bind_texture_ids` records — and read only under `validate_shaders`. `format_str`
/// is the AUTHOR spelling (for the R5a attachment-agreement messages — there is no
/// enum→string helper, and `@tagName` misprints the hyphenated formats).
const TextureMeta = struct {
    format: values.TextureFormat,
    format_str: []const u8 = "",
    /// The RAW author `:sample-count` (null when omitted) — NOT the `orelse 1`
    /// emission default. A spelled count is always known: `optU32` evaluates
    /// expressions and bare defines (a literal-only read used to return null for
    /// them). The R5b #9 sample-count check fires only on an EXPLICIT count > 1,
    /// so an omitted count (the simple_triangle_msaa quirk) stays null → skip.
    sample_count: ?u32 = null,
    /// The declared `:usage` set. C22 reads it: a copy endpoint has to admit the
    /// copy, and usage is fixed at texture creation.
    usage: values.TextureUsage = .{},
    loc: ?Diag.Located = null,
};

/// One declared color target of a render-pipeline: its `:format` enum (for the
/// exact-equality #7b compare) + the author spelling (for the message).
const TargetMeta = struct { fmt: values.TextureFormat, spelling: []const u8 };

/// The draw-time attachment state a `(render-pipeline …)` declares — the facts the
/// R5a render-pass ↔ pipeline agreement checks (#7/#8) join a pass against.
/// Recorded by `recordRenderPipelineMeta` at the END of `emitRenderPipeline` (keyed
/// by pipeline id), gated on `validate_shaders`; a compute pipeline records nothing
/// (no entry → the join skips). `targets_known == false` marks a fragment stage
/// with zero `(target …)` children → the count/format checks skip; validation
/// (`fragment-section` `:min 1`, 02 R3) keeps a document from getting there, and
/// `pngine/pass-v1` spells its canvas target out. A pipeline with NO fragment
/// stage is depth-only (known M = 0). Author spellings are borrowed from the
/// (source OR lowered) tree, which lives for the whole emit.
const PipelineMeta = struct {
    targets: [8]TargetMeta = undefined,
    targets_len: u8 = 0, // number stored in `targets` (min(total, 8))
    targets_total: u16 = 0, // full declared color-target count (for the #7a compare)
    targets_known: bool = false, // false ⇔ zero targets, unreachable once validated (skip #7a/b/c)
    ds_present: bool = false,
    ds_format: ?values.TextureFormat = null, // set together with ds_present (`:format` is required)
    ds_spelling: []const u8 = "",
    ms_count: ?u32 = null, // raw `:count` (Phase 3 #9); null ⇔ omitted/expression
    // Whether `(multisample :count …)` was WRITTEN. `ms_count` alone cannot say:
    // it is null for an omitted key and for an expression alike, and the two mean
    // different things to C19 — an omitted count is 1, the IDL's default and a
    // definite value, while an unreadable one is unknown and must skip.
    ms_stated: bool = false,
    // C8: the primitive facts the pass join needs. `topology` is the EFFECTIVE
    // spelling — the schema defaults it to triangle-list for the variant's sake,
    // so it is "" only when the `(primitive …)` form itself is absent, which
    // reads as triangle-list too; `strip_index_format` records key presence.
    topology: []const u8 = "",
    strip_index_format: bool = false,
};

/// The render-target layout a `(render-bundle …)` declares — WebGPU's
/// `GPURenderPassLayout`, written down rather than derived. Recorded by
/// `emitRenderBundle` keyed by bundle id, read by `checkReplayedBundles` when a
/// pass replays it (bundles emit before passes — see the `phases` table).
///
/// Three objects carry one of these and WebGPU requires all three to be EQUAL:
/// the bundle states it, the pipeline it records derives one, and the pass that
/// replays it derives one from its attachments. `PipelineMeta` is the pipeline's
/// side of the same shape; this is the bundle's.
const BundleMeta = struct {
    /// Author spellings + mapped formats of `:color-formats`, in slot order. The
    /// key is required with `:min-len 1`, so `len` is never 0 for a bundle that
    /// validated; the tail beyond `len` is undefined.
    formats: [MAX_COLOR_ATTACHMENTS]TargetMeta = undefined,
    len: u8 = 0,
    /// FULL declared count, which may exceed what `formats` stores (the wire
    /// takes up to 255) — the length compare uses this, the per-slot compare
    /// `len`.
    total: u16 = 0,
    ds_format: ?values.TextureFormat = null,
    ds_spelling: []const u8 = "",
    /// The bundle's `:sample-count`: absent reads as the IDL default 1 (a definite
    /// value), a spelled one is evaluated by `optU32` — so null only when nothing
    /// recorded it.
    sample_count: ?u32 = null,
};

/// Bound-sampler facts the R4 sampler comparison-ness check joins against
/// reflection: whether the SJON sampler declared `:compare` (a comparison sampler)
/// + the `(sampler …)` form's user span. Recorded in `emitSampler`, read only under
/// `validate_shaders`.
const SamplerMeta = struct { comparison: bool, loc: ?Diag.Located = null };

/// A form to emit, paired with the reader for its owning tree.
const FormRef = struct { reader: *const Reader, idx: NodeIndex };

/// Entry-point names reflected from a shader module's WGSL (a membership set).
/// Built when `validate_shaders` is on; consumed by the pipeline entry-existence
/// check. Keys are gpa-owned dupes (the reflection arena that produced them is
/// freed immediately after); freed in `deinit`.
const EntrySet = std.StringHashMapUnmanaged(void);

/// Compile diagnostics sink — see `diag.zig`. Re-exported here (and as
/// `Compiler.Diag`) so every existing `Emitter.Diag.…` call site is unchanged
/// by the move out of this file.
pub const Diag = @import("diag.zig").Diag;

/// The emit -> validate join: what each emission phase recorded about which
/// resource it bound where, consumed after the walk by the R1/R4/R5
/// cross-validation checks and by the uniform-table population.
///
/// Lifted out of the Emitter's field list because it is a distinct concern with
/// a distinct lifetime: written during emission, read once at the end, and —
/// apart from `uniform_bindings`, which the unconditional uniform table needs —
/// read ONLY under `validate_shaders`. The golden/parity harnesses fill these
/// maps and never look at them. Grouping them makes that gate legible instead
/// of spreading 14 more hashmaps through the emitter's other 63 fields.
///
/// The checks themselves stay Emitter methods: each needs `diagnose*`,
/// `builder` and `bufferNameOf` as much as it needs these maps, so moving them
/// here would turn every call into `self.binds.check(self, ...)` — the same
/// coupling, spelled worse. What is extracted is the STATE and its teardown.
const BindJoin = struct {
    // Uniform-table reflection state (revives runtime setUniform-by-name, dead
    // since the SJON migration dropped the legacy emitter's table population —
    // docs/journal.md §96). Maps a bind group's (group, binding) → the BASE buffer
    // id bound there, recorded in emitBindGroup; populateUniformTable joins these
    // against reflected uniform/storage bindings at the end of run().
    uniform_bindings: std.AutoHashMapUnmanaged(UniformBindingKey, u16) = .empty,
    // Buffer BASE id → {size, usage}, recorded in emitBuffer. Feeds the R1
    // cross-validation checks (buffer-too-small-for-struct + address-space
    // agreement) at the populateUniformTable join; read only under
    // validate_shaders, so the golden/parity path ignores it.
    buffer_meta: std.AutoHashMapUnmanaged(u16, BufferMeta) = .empty,
    // (group, binding) slots bound to MORE THAN ONE distinct buffer across the
    // document — e.g. a compute pipeline's storage buffer and a render pipeline's
    // uniform both reusing (0,0). The global `uniform_bindings` join keeps only
    // the last writer, so its buffer is NOT authoritative for such a slot: the R1
    // buffer-specific checks (size adequacy, address-space agreement) skip these
    // to stay false-positive-free. Recorded in emitBindGroup; read only under
    // validate_shaders.
    uniform_binding_ambiguous: std.AutoHashMapUnmanaged(UniformBindingKey, void) = .empty,
    // (group, binding) → the SJON-declared resource kind bound there, recorded in
    // emitBindGroup for EVERY (entry …) entry (buffer/texture/sampler, not just
    // buffers). Feeds the R1 bind resource-kind agreement check at the
    // populateUniformTable join; read only under validate_shaders.
    bind_kinds: std.AutoHashMapUnmanaged(UniformBindingKey, BindKind) = .empty,
    // (group, binding) slots bound to MORE THAN ONE distinct kind across the
    // document (e.g. a buffer in one pipeline's group and a texture in another's).
    // The global bind_kinds join isn't authoritative for such a slot, so the R1
    // kind check skips it — the exact non-authoritative-join caveat as
    // uniform_binding_ambiguous, applied to kinds. Read only under validate_shaders.
    bind_kind_ambiguous: std.AutoHashMapUnmanaged(UniformBindingKey, void) = .empty,
    // (group, binding) → the resolved user-source location of the `(entry …)` entry
    // recorded there (R2b), for the bind resource-kind check's squiggle. Populated
    // alongside bind_kinds in emitBindGroup under validate_shaders; a lowered/`(pass …)`
    // entry (no user span) simply isn't recorded → the check degrades to an
    // unlocated headline. Read only at the populateUniformTable join.
    bind_kind_locs: std.AutoHashMapUnmanaged(UniformBindingKey, Diag.Located) = .empty,
    // R4 Tier 2 — texture/sampler descriptor facts + their bind joins. Texture BASE
    // id → {format, loc} (emitTexture) and sampler id → {comparison, loc}
    // (emitSampler); (group, binding) → the texture/sampler id bound there
    // (emitBindGroup). Consumed at the populateUniformTable join by the R4 sample-
    // class / comparison checks. Read only under validate_shaders.
    texture_meta: std.AutoHashMapUnmanaged(u16, TextureMeta) = .empty,
    sampler_meta: std.AutoHashMapUnmanaged(u16, SamplerMeta) = .empty,
    // R5a — render-pipeline attachment state (color targets, depth format, sample
    // count) keyed by pipeline id, recorded by recordRenderPipelineMeta at the end
    // of emitRenderPipeline. Consumed by checkRenderPassPipeline in emitRenderPass
    // (both run after all pipelines emit — see run()). Read only under validate_shaders.
    pipeline_meta: std.AutoHashMapUnmanaged(u16, PipelineMeta) = .empty,
    // C19 — the layout a render-bundle DECLARES, keyed by bundle id, recorded by
    // emitRenderBundle. Consumed by checkReplayedBundles in emitRenderPass (bundles
    // emit before passes — see the `phases` table). Read only under validate_shaders.
    bundle_meta: std.AutoHashMapUnmanaged(u16, BundleMeta) = .empty,
    bind_texture_ids: std.AutoHashMapUnmanaged(UniformBindingKey, u16) = .empty,
    bind_sampler_ids: std.AutoHashMapUnmanaged(UniformBindingKey, u16) = .empty,
    // (group, binding) slots bound to MORE THAN ONE distinct texture OR sampler id
    // across the document — the global handle join isn't authoritative there, so the
    // R4 texture/sampler checks skip these (the same non-authoritative-join caveat
    // as uniform_binding_ambiguous, applied to handle bindings). A slot can't hold
    // both a texture and a sampler (bind_kind_ambiguous already guards kind reuse),
    // so one shared set covers both. Read only under validate_shaders.
    bind_handle_ambiguous: std.AutoHashMapUnmanaged(UniformBindingKey, void) = .empty,

    // The two sides of the per-pipeline uniform-table join: (module → pipeline)
    // instantiation rows (render/compute pipeline phases) and
    // (pipeline, group, binding) → BASE buffer rows (emitBindGroup, for
    // pipeline-layout groups). Flat lists — every consumer is a bounded scan.
    module_pipelines: std.ArrayList(ModulePipeline) = .empty,
    scoped_bindings: std.ArrayList(ScopedBinding) = .empty,

    /// Comptime field loop, for the reason spelled out on `Tables.deinit`: a
    /// hand-written list of 14 teardown calls is a list you can forget to
    /// extend, and forgetting leaks under `testing.allocator` only.
    fn deinit(self: *BindJoin, gpa: Allocator) void {
        inline for (@typeInfo(BindJoin).@"struct".fields) |f| {
            @field(self, f.name).deinit(gpa);
        }
    }
};

/// Every heap-owned table the emitter allocates, and its teardown, in one place.
///
/// This is the answer to the finding that adding a resource kind meant touching
/// three (sometimes four) places with no compiler help: a map, a counter, an
/// optional pool side-map, and a line in a 40-line hand-written `deinit`. Now it
/// is ONE declaration, and `deinit` is a comptime field loop — the forgotten
/// teardown line is unrepresentable, the same property `wire_schema.layoutOf`
/// gives opcodes and `DslSjonDeps` gives build imports.
///
/// The contract the loop enforces at compile time: every field's type exposes
/// `deinit(gpa)`. `IdTable`, `OwningStringMap`, `std.*HashMapUnmanaged` and
/// `std.ArrayList` all do. A scalar does not — which is why
/// `next_frame_id` stays an `Emitter` field: frames are the one id space with no
/// registry (nothing looks a frame up by name), and a counter owns no memory, so
/// it has nothing to forget.
/// One authored `(constant :name X :value V)`, resolved against the `(define …)`
/// environment and attributed to the shader module its stage names.
///
/// Authored per STAGE (mirroring WebGPU's `GPUProgrammableStage.constants`) but
/// stored per MODULE, because specialisation rewrites the shader text — an
/// early binding the whole module shares. That mismatch is the feature's real
/// limitation, and `addConstant` refuses it rather than letting one stage
/// silently redefine another's shader.
const AuthoredConstant = struct {
    module: []const u8,
    name: []const u8,
    value: f64,
    /// The `(constant …)` form and the tree it lives in, for a located
    /// diagnostic on the losing side of a disagreement.
    ref: FormRef,
};

const Tables = struct {
    // `(data …)` names → the BUILDER's data-section id. Not an `IdTable`: the
    // emitter does not allocate these ids, `format.Builder` does, so there is no
    // counter here to own.
    data: StringMapU16 = .empty,
    // `(data …)` name → its byte length, for buffers that size from it.
    data_byte_len: std.StringHashMapUnmanaged(u32) = .empty,

    // ---- name→id registries, one declaration per resource kind ----
    shaders: IdTable(u16) = .{},
    buffers: IdTable(u16) = .{},
    textures: IdTable(u16) = .{},
    // A SEPARATE id space from textures: `(entry :texture …)` binds a default
    // view keyed by texture id, `(entry :texture-view …)` binds one of these.
    texture_views: IdTable(u16) = .{},
    samplers: IdTable(u16) = .{},
    image_bitmaps: IdTable(u16) = .{},
    pipelines: IdTable(u16) = .{},
    bind_groups: IdTable(u16) = .{},
    bind_group_layouts: IdTable(u16) = .{},
    pipeline_layouts: IdTable(u16) = .{},
    render_bundles: IdTable(u16) = .{},
    query_sets: IdTable(u16) = .{},
    passes: IdTable(u16) = .{},
    wasm_calls: IdTable(u16) = .{},
    // Keyed by URL rather than by declared name — that IS the dedup: several
    // `(wasm-call …)` forms sharing a url share one module id.
    wasm_modules: IdTable(u16) = .{},

    // ---- side tables: attributes of an already-registered resource ----
    // Pass name → render/compute, for the frame walk.
    pass_types: std.StringHashMapUnmanaged(PassType) = .empty,
    // Queue name → (reader, action node). The reader carries the tree (source OR
    // the lowered tree, for the pass-v1 per-pass uniform-write queues), so the
    // action is read from the tree it was emitted into.
    queue_actions: std.StringHashMapUnmanaged(FormRef) = .empty,
    // Call name → module id. Distinct from `wasm_modules` (url-keyed): this is
    // the per-call resolution of that dedup.
    wasm_call_module_ids: StringMapU16 = .empty,
    // Call name → source form node, re-read at frame time for :func/:returns/:args.
    wasm_call_forms: std.StringHashMapUnmanaged(NodeIndex) = .empty,
    // Static `(wasm-data …)` mesh generators: data name → {module id, func name id,
    // byte size}, consumed by a buffer's :size and :data.
    wasm_mesh_data: std.StringHashMapUnmanaged(WasmMeshData) = .empty,
    // Indexed-shape index data, keyed by shape name; consumed by `:index-of`.
    shape_index: std.StringHashMapUnmanaged(IndexData) = .empty,
    // Buffer id → index format (0=uint16, 1=uint32). Keyed by INSTANCE id, not
    // by base: pool members can carry different formats.
    buffer_index_formats: std.AutoHashMapUnmanaged(u16, u8) = .empty,

    // ---- shader-module state ----
    // Module name → the shipped WGSL and ONE reflection of it, built by
    // emitShaderModule. Decoupled from the validate_shaders-gated validateShader
    // (the golden/parity harness leaves validation off, but the uniform table
    // must still populate there), which is why the analysis is unconditional
    // while the checks that read it are not.
    shader_analysis: OwningStringMap(ModuleAnalysis, freeModuleAnalysis) = .{},
    // Per-shader reflected entry-point sets (populated by emitShaderModule when
    // validate_shaders is on). Drives the pipeline entry-point existence check.
    shader_entries: OwningStringMap(EntrySet, freeEntrySet) = .{},
    // Shader modules in EMIT order (source phase first, then lowered) — the
    // deterministic iteration index over `shader_analysis` for populateUniformTable
    // (StringHashMap order previously decided both table order and slot-collision
    // winners). Names borrow the same tree slices `shaders` keys do.
    shader_order: std.ArrayList(ShaderRef) = .empty,
    // CONST-04: every `(constant :name X :value V)` authored on a pipeline
    // stage, resolved and keyed by the MODULE the stage names. Collected before
    // any phase runs, because the override→const rewrite has to land before
    // wgslender validates the text that ships.
    //
    // A flat list scanned linearly, like `binds.module_pipelines`: a document
    // holds a handful of constants, and keeping it flat is what makes the
    // "two stages specialise one module differently" check a plain scan rather
    // than a nested map.
    module_constants: std.ArrayList(AuthoredConstant) = .empty,

    fn deinit(self: *Tables, gpa: Allocator) void {
        inline for (@typeInfo(Tables).@"struct".fields) |f| {
            @field(self, f.name).deinit(gpa);
        }
    }
};

pub const Emitter = struct {
    /// `ValidationError` is raised by the `validate_shaders` emit-time diagnostics
    /// (bad WGSL, missing pipeline entry point); `EmitError` covers the semantic
    /// emit-time checks (buffer too small for its mapped data, undersized uniform)
    /// and structural resolution failures. Both are a subset of `Compiler.Error`.
    pub const Error = error{ OutOfMemory, EmitError, ValidationError };

    gpa: Allocator,
    result: *const Host.HostResult,
    schema: Schema.Schema,
    builder: format.Builder,

    // File-IO context for `(pass … :file …)` WASM embedding (null → no IO, e.g. the
    // freestanding wasm compiler; the data buffer is then a compile error). Mirrors
    // the legacy emitter's `options.base_dir` / `options.io`.
    base_dir: ?[]const u8 = null,
    io: ?std.Io = null,

    // Strict-validation toggle (the CLI `validate` command + the in-browser
    // compiler set it; the parity/golden harnesses leave it false). Gates the
    // emit-time diagnostics — WGSL semantic validation + entry-point reflection
    // (shaders), buffer-size-vs-mapped-data, and undersized-uniform — so the
    // default compile path stays lenient and parity-/golden-stable.
    validate_shaders: bool = false,
    // Advisory WGSL lint (wgslender's `@wgslender/recommended` pack), on top of
    // the validation `validate_shaders` already does. Separate toggle because it
    // is strictly MORE than validation and costs more: `lint` drives DCE and one
    // read-only walk per enabled rule. Only `pngine validate` — where a human is
    // explicitly asking for a report — turns it on; compile/render/golden paths
    // must not pay for it.
    //
    // It is also the only path that surfaces wgslender's WARNING-severity
    // validator diagnostics (uniformity E0700–E0703 and friends), which
    // `validateShader` otherwise drops. That, too, is gated: several Emitter
    // tests assert exact `warningCount(&diag)` values on the default path.
    //
    // Findings are ALWAYS advisory — they warn and never set `shader_error_count`,
    // so lint can never fail a compile. (Implies `validate_shaders`.)
    lint_shaders: bool = false,
    // WGSL minification (`compile --minify`, `render --minify`). Strictly
    // INDEPENDENT of `validate_shaders`: the author's text is what gets
    // validated, the minified text is what gets shipped, stashed and reflected
    // (see `emitShaderModule`). Off by default — the golden/parity traces hash
    // shader code (`code=len=N fnv=…`), so every trace would move the day this
    // defaulted on.
    minify_shaders: bool = false,
    // Compute-workgroup limits fed to checkWorkgroupSize — WebGPU defaults until a
    // top-level (limits …) form raises them (collectDeviceLimits). (Arc-3 §5.3b)
    wg_limits: WgLimits = .{},
    // F5 collect-across-forms: how many shader modules failed WGSL validation this
    // walk. `validateShader` bumps it (and stops halting mid-walk) so every broken
    // module reports; `run()` raises `ValidationError` once the whole shader-module
    // phase is emitted — before any pipeline phase runs against a broken module.
    shader_error_count: u32 = 0,
    // Optional domain-labeled diagnostic sink (set by the caller after `init`,
    // before `run`). The WGSL/entry-point checks report into it so the editor
    // panel reads "WGSL error in shader 'X'…" instead of "SJON validation failed".
    // Null on the golden/parity paths.
    diag: ?*Diag = null,
    // User source, set by the Compiler after init() (empty on the golden/parity
    // path). `locate` maps a source-tree span into a 1-based user (line, col) for a
    // squiggle. F9: the tree parses `source` at offset 0 (the schema is preloaded,
    // not prepended), so spans are already document-local — no prefix to subtract.
    user_source: []const u8 = "",

    src: Reader,
    low: Reader,
    has_low: bool,

    forms: std.ArrayList(FormRef) = .empty,
    env_bindings: std.ArrayList(Env.Binding) = .empty,
    env: Env = .{},

    /// Every name→id registry and side table, with its teardown. See `Tables`.
    tables: Tables = .{},
    /// The (group, binding) cross-validation state. See `BindJoin`.
    binds: BindJoin = .{},

    /// The one id space with no registry: nothing looks a frame up by name, so
    /// there is no map to pair this counter with and nothing for `Tables` to own.
    next_frame_id: u16 = 0,
    /// Bytes the shape generators have produced for this document so far —
    /// held to `MAX_GENERATED_BYTES` (below). `DataSection.add` dedupes
    /// IDENTICAL blobs, which LEAK-11 D counted on as the bound; distinct
    /// `:format` vectors (6 attributes, up to 8 slots, repeats allowed) defeat
    /// it — twelve `(dragon :format …)` forms with different vectors, 1.7 KB of
    /// source, made an 8.5 MB payload, and the editor's 256 KiB source admits
    /// ~1,800 such forms. A budget over what is generated, not over what is
    /// kept, is the bound the dedupe cannot be.
    generated_bytes: u64 = 0,

    pub fn init(gpa: Allocator, result: *const Host.HostResult, base_dir: ?[]const u8, io: ?std.Io, validate_shaders: bool) Emitter {
        const src_reader = Reader.init(&result.tree, &result.materialized_defaults);
        var low_reader = src_reader;
        var has_low = false;
        if (result.lowered_tree) |*lt| {
            low_reader = Reader.init(lt, &values.empty_overlay);
            has_low = true;
        }
        return .{
            .gpa = gpa,
            .result = result,
            .base_dir = base_dir,
            .io = io,
            .validate_shaders = validate_shaders,
            // PNGine author-position expressions (sizes, counts, dispatch) use
            // only the `core` plugin's arithmetic (`* / + ceil floor …`).
            // `HostResult.schema` deliberately omits core (it lives only in the
            // host's internal eval schema), so build a core-only schema here for
            // `Expr.eval`. Symbols resolve through the `#define` env, not the
            // schema, so core-only is sufficient.
            .schema = Schema.Schema.init(&.{sjon.plugins.core.plugin}),
            .builder = format.Builder.init(),
            .src = src_reader,
            .low = low_reader,
            .has_low = has_low,
        };
    }

    /// Four group teardowns, each a comptime field loop, in place of the 40 lines
    /// this used to be. The list that remains is a list of *categories* — walk
    /// state, id state, join state — which changes about once a year; the list
    /// that grew every time a resource kind was added is gone.
    pub fn deinit(self: *Emitter) void {
        self.builder.deinit(self.gpa);
        self.forms.deinit(self.gpa);
        self.env_bindings.deinit(self.gpa);
        self.tables.deinit(self.gpa);
        self.binds.deinit(self.gpa);
        self.* = undefined;
    }

    /// Convenience: build an emitter, run the walk, and finalize to PNGB bytes.
    /// `base_dir`/`io` enable `(pass … :file …)` WASM file embedding (null → disabled).
    pub fn emit(gpa: Allocator, result: *const Host.HostResult, base_dir: ?[]const u8, io: ?std.Io, validate_shaders: bool) Error![]u8 {
        var em = init(gpa, result, base_dir, io, validate_shaders);
        defer em.deinit();
        try em.run();
        return em.builder.finalize(gpa) catch error.OutOfMemory;
    }

    /// One head→emitter mapping. `run()` walks the source forms phase-by-phase
    /// in `phases` order; `emitLowered()` dispatches each lowered-tree form's
    /// head through the SAME table — so the source walk and the lowered walk
    /// cannot drift. (Pre-2.3 the lowered walk kept its own hand-list `if/else`
    /// chain that omitted `image-bitmap`/`wasm-call`, so a hook emitting those
    /// heads was silently dropped.)
    const Phase = struct {
        head: []const u8,
        emit: *const fn (*Emitter, *const Reader, NodeIndex) Error!void,
    };

    /// The single, frozen phase order. The golden MockGPU traces
    /// (`tests/zig/golden/*.trace`, test-sjon-golden) pin the create-call
    /// sequence position-by-position, so reordering a phase shifts a digest.
    /// Each placement also satisfies a real dependency (a resource must exist
    /// before the descriptor that references it) — noted per phase.
    ///
    /// `collectQueues()` + `emitLowered()` interpose at `phases_split` (the
    /// first pass phase): phases before it emit source resources ahead of the
    /// lowered `(init …)`/`(pass …)` outputs; phases after it emit source passes/frames
    /// behind them.
    const phases = [_]Phase{
        .{ .head = "data", .emit = emitData },
        // Image bitmaps land right after data and before shaders: they read the
        // blob `(data …)` ids the data phase just registered.
        .{ .head = "image-bitmap", .emit = emitImageBitmap },
        // `(wasm-call …)` modules: init_wasm_module up front (deduped by path), so it is
        // the first create-call. The call + buffer write happen later, at frame
        // time (a write-buffer :data naming a wasm-call).
        .{ .head = "wasm-call", .emit = emitWasmCallModule },
        .{ .head = "shader-module", .emit = emitShaderModule },
        .{ .head = "buffer", .emit = emitBuffer },
        // Textures land after buffers and before pipelines; samplers follow
        // textures and precede pipelines (pipelines/bind-groups reference them).
        .{ .head = "texture", .emit = emitTexture },
        .{ .head = "sampler", .emit = emitSampler },
        // Explicit texture views land after textures (their source) and before
        // bind-groups (which bind them). No existing fixture authors one, so this
        // phase emits nothing for them → the golden create-call sequence is
        // unchanged and the traces stay byte-identical.
        .{ .head = "texture-view", .emit = emitTextureView },
        // Query sets (timestamp/occlusion) land after samplers and before
        // bind-group-layouts.
        .{ .head = "query-set", .emit = emitQuerySet },
        // Explicit bind-group-layouts (uniform_access) land after samplers and
        // before pipelines (a pipeline layout references them).
        .{ .head = "bind-group-layout", .emit = emitBindGroupLayout },
        // Explicit pipeline-layouts land after bind-group-layouts (which they
        // compose) and before pipelines (which reference them via :layout).
        .{ .head = "pipeline-layout", .emit = emitPipelineLayout },
        .{ .head = "render-pipeline", .emit = emitRenderPipeline },
        .{ .head = "compute-pipeline", .emit = emitComputePipeline },
        .{ .head = "bind-group", .emit = emitBindGroup },
        // Pre-recorded render bundles land after bind-groups and before the
        // lowered sugar. A bundle's descriptor references pipeline / vertex
        // buffers / bind groups already emitted above.
        .{ .head = "render-bundle", .emit = emitRenderBundle },
        // ── phases_split: collectQueues() + emitLowered() run here ──
        .{ .head = "render-pass", .emit = emitRenderPass },
        .{ .head = "compute-pass", .emit = emitComputePass },
        .{ .head = "frame", .emit = emitFrame },
    };

    /// Count of pre-lowered phases, derived from the table so it can't drift:
    /// the split is exactly where the pass phases begin (`render-pass`).
    /// `phases[0..phases_split]` emit source resources before the lowered
    /// outputs; `phases[phases_split..]` (passes + frame) after them.
    const phases_split = blk: {
        for (phases, 0..) |ph, i| {
            if (std.mem.eql(u8, ph.head, "render-pass")) break :blk i;
        }
        @compileError("phases table must contain a 'render-pass' phase");
    };

    /// Populate `self.builder` by walking the forest. The caller finalizes.
    pub fn run(self: *Emitter) Error!void {
        try self.collectForms();
        // Audit 09 C3: a slot-only form at the root is refused before anything
        // else — SJON has no root restriction, and a stray one used to be
        // skipped by the head-keyed phase walk below.
        try self.checkDocumentForms();
        // R10's opinion half, before anything reads a name: one namespace across
        // every named form, and the builtin symbols are reserved. Neither is a
        // check SJON can make (see the function's doc comment), and both must
        // run before `buildEnv` so a shadowed `(define …)` is reported as a
        // collision rather than silently winning the env.
        try self.checkNameNamespace();
        try self.buildEnv();
        // Before any phase: fold the optional (limits …) form into the builder's
        // device-limits table and capture the compute-workgroup limits so the
        // compute-phase workgroup-size check sees the AUTHORED caps. (§5.3b)
        try self.collectDeviceLimits();
        // …and the optional (canvas …) form into the header flag. (spec/04)
        try self.collectCanvasConfig();
        // CONST-04: and every `(constant …)`, which the shader-module phase
        // needs BEFORE it validates — the rewrite has to be in the text
        // wgslender sees. Needs `buildEnv` above (a value may be an expression
        // over `(define …)`).
        try self.collectConstants();

        // User (source) resources first. `self.forms` holds source forms only,
        // so each phase naturally emits user resources. The pre-split phases run
        // ahead of the lowered `(init …)`/`(pass …)` outputs (see `phases`).
        inline for (phases[0..phases_split]) |ph| {
            try self.emitPhase(ph.head, ph.emit);
            // F5: the shader-module phase collects EVERY broken module's WGSL error
            // (validateShader no longer halts mid-walk); halt here, once the phase
            // is complete, before buffers/pipelines run any check against a broken
            // (unreflected) module. Comptime-selected — a no-op on other phases.
            if (comptime std.mem.eql(u8, ph.head, "shader-module")) {
                if (self.shader_error_count > 0) return error.ValidationError;
            }
        }

        // Then the lowering-hook outputs (`(init …)`, `(pass …)`) as a unit, walked in
        // emitted order — the sugar emits resources interleaved (not grouped by
        // type), so the golden traces' strict call-type sequence only matches if
        // the lowered walk preserves emission order. For `(init …)` this lands the
        // synthesized compute-pipeline + bind-group + compute-pass-define here;
        // for `(pass …)` it lands the whole per-pass resource set + the auto-frame.
        // Collect queues (source + lowered) BEFORE emitLowered: the pass-v1
        // auto-frame is a lowered form emitted inside emitLowered, and it
        // resolves its per-pass uniform-write queue steps against this map.
        try self.collectQueues();
        try self.emitLowered();
        // F5: the `(init …)`/`(pass …)` sugar emits its own shader modules interleaved with
        // pipelines here; a broken lowered module records into the same counter, so
        // halt before the post-split pass/frame phases. (A broken SOURCE module
        // already returned above, never reaching emitLowered — no double count.)
        if (self.shader_error_count > 0) return error.ValidationError;

        // Post-split phases: source passes + frames, behind the lowered outputs.
        inline for (phases[phases_split..]) |ph| {
            try self.emitPhase(ph.head, ph.emit);
        }

        // Uniform-table reflection runs LAST: every buffer + bind group (source
        // AND lowered `(pass …)`/`(init …)`) has populated `uniform_bindings` by now, and
        // every shader's WGSL is stashed. Joins reflected uniform/storage bindings
        // to their buffers → runtime setUniform(name, …), `--types` .d.ts, and the
        // worker's "Parsed N uniform fields" log all light up from this one pass.
        try self.populateUniformTable();
    }

    // ----------------------------------------------------------------------
    // Form collection + define environment
    // ----------------------------------------------------------------------

    /// Collect the source (user-authored) forms to walk, skipping any that
    /// lowered (their node index is a `lowering_provenance` source — i.e. the
    /// `(init …)` sugar). Lowered outputs are walked separately by
    /// `emitLoweredInit` so they land in the legacy phase position.
    fn collectForms(self: *Emitter) Error!void {
        var lowered_src: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer lowered_src.deinit(self.gpa);
        for (self.result.lowering_provenance.entries) |e| {
            try lowered_src.put(self.gpa, @intFromEnum(e.source_form_idx), {});
        }

        for (self.result.data_forest) |idx| {
            if (self.result.tree.tagOf(idx) != .form) continue;
            if (lowered_src.contains(@intFromEnum(idx))) continue;
            try self.forms.append(self.gpa, .{ .reader = &self.src, .idx = idx });
        }
    }

    /// The heads the emitter reads at the document root: the phase table, the
    /// pre-phase collectors (`define`, `limits`, `canvas`, `queue`) and the
    /// two lowering sugars (`init`, `pass-graph` — lowering sources, so
    /// normally absent from `self.forms`; listed for a registry-less validate).
    /// Derived from `phases` so a new phase cannot be forgotten here.
    const document_heads = blk: {
        const extra = [_][]const u8{ "define", "limits", "canvas", "queue", "init", "pass-graph" };
        var heads: [phases.len + extra.len][]const u8 = undefined;
        for (phases, 0..) |ph, i| heads[i] = ph.head;
        for (extra, 0..) |h, i| heads[phases.len + i] = h;
        break :blk heads;
    };

    /// Refuse a slot-only form written at the document root (audit 09 C3).
    ///
    /// SJON has no root restriction — a document is "a flat list of roots" —
    /// so `(draw …)`, `(target …)`, `(entry …)`, `(cube …)`, `(pass …)` all
    /// validate at the root, and the phase walk (keyed by head) simply never
    /// visited them: a stray draw vanished, and a `(pass …)` outside its
    /// `(pass-graph …)` compiled to a payload with no bytecode at all. The
    /// check is the emitter's because only the emitter knows which heads it
    /// walks at the root; the parents named in the message come from the
    /// schema — every form whose positional kind admits the head — so the
    /// sentence cannot drift from the head-sets.
    fn checkDocumentForms(self: *Emitter) Error!void {
        for (self.forms.items) |f| {
            const head = f.reader.head(f.idx);
            std.debug.assert(head.len > 0);
            var known = false;
            for (document_heads) |h| {
                if (std.mem.eql(u8, h, head)) {
                    known = true;
                    break;
                }
            }
            if (known) continue;

            var buf: [512]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            var named: u32 = 0;
            // `self.schema` is the core-only expression schema; the pngine
            // manifest — the head-sets — is the host's.
            for (self.result.schema.plugins) |plugin| {
                for (plugin.value_kinds) |kind| {
                    const set = kind.heads orelse continue;
                    var admits = false;
                    for (set.heads) |kh| {
                        if (std.mem.eql(u8, kh.name, head)) {
                            admits = true;
                            break;
                        }
                    }
                    if (!admits) continue;
                    for (plugin.forms) |form| {
                        const ref = switch (form.positional) {
                            .kind => |k| k,
                            else => continue,
                        };
                        if (!std.mem.eql(u8, ref.name, kind.name)) continue;
                        w.print("{s}`({s} …)`", .{ if (named == 0) "" else " / ", form.name }) catch break;
                        named += 1;
                    }
                }
            }
            const parents: []const u8 = if (named == 0) "another form" else w.buffered();
            self.diagnose(.sjon, self.locate(f.reader, f.idx), "", "`({s} …)` is a child of {s}, not a document form — at the root it would be silently skipped", .{ head, parents });
            return error.ValidationError;
        }
    }

    /// Emit the lowering-hook outputs by walking `lowered_tree.root` in emitted
    /// order, dispatching each head to its phase emitter. Order is load-bearing:
    /// the `(init …)`/`(pass …)` sugar emits resources interleaved (not grouped by
    /// type), and the golden traces pin the call-type sequence position-by-
    /// position — so the lowered walk must preserve the hook's emission order
    /// rather than re-grouping into phases. `pngine/init-v1` emits
    /// `[compute-pipeline, bind-group, compute-pass]`; `pngine/pass-v1` emits, per
    /// pass, `[buffer?, texture, shader-module, render-pipeline, bind-group,
    /// render-pass]` (a shared sampler first, an auto-frame last).
    fn emitLowered(self: *Emitter) Error!void {
        if (!self.has_low) return;
        const lt = &self.result.lowered_tree.?;
        const r = &self.low;
        for (lt.root) |idx| {
            if (lt.tagOf(idx) != .form) continue;
            const head = r.head(idx);
            // Dispatch through the SAME `phases` table run() walks (image-bitmap
            // and wasm-call included). Non-phase heads — e.g. `queue`, handled by
            // collectQueues() — match nothing and are skipped, as before.
            inline for (phases) |ph| {
                if (std.mem.eql(u8, head, ph.head)) {
                    try ph.emit(self, r, idx);
                    break;
                }
            }
        }
    }

    /// Builtin symbols that appear in reference slots. Each is a member-set
    /// alternative beside a ref kind, and a member arm is not a cross-ref
    /// claimant — SJON matches the member first and never consults a form that
    /// shares the spelling. So a `(texture :name canvas …)` is not ambiguous to
    /// the validator; it is invisible to it. Reserved here instead.
    const reserved_names = [_][]const u8{
        "auto",
        "canvas",
        "context-current-texture",
        "preferred-canvas-format",
        "pngine-inputs",
        "scene-time-inputs",
        "pointer-inputs",
        "all",
        "canvas-width",
        "canvas-height",
        "time-total",
        "time-delta",
    };

    /// R10: a `:name` is one namespace across EVERY named form in the document,
    /// and no form may take a builtin symbol's spelling. Both halves are pngine
    /// opinions the schema cannot carry:
    ///
    /// - SJON checks duplicate names per cross-ref BUCKET — the set of forms one
    ///   slot can target. `buffer-ref` and `texture-ref` are different buckets,
    ///   so a buffer and a texture sharing a name never meet, each reference
    ///   resolves to its own kind, and the document validates clean. Where kinds
    ///   DO meet in one slot the schema already says it (`(cross-ref :target
    ///   [a b …])`, one bucket, S4b) — that is the soundness half and it is not
    ///   this function's job. This is the readability half: a name is a name.
    /// - A reserved builtin is not a cross-ref claimant at all (see
    ///   `reserved_names`).
    ///
    /// Walks the SOURCE forest, not `self.forms`: `collectForms` drops the forms
    /// that lowered, and `(init :name …)`/`(pass :name …)` are exactly those —
    /// the author wrote those names and owns them.
    ///
    /// Complexity: O(n²) in top-level named forms, n ≤ a few hundred; the linear
    /// scan keeps the FIRST declaration's span, which is what the message needs.
    fn checkNameNamespace(self: *Emitter) Error!void {
        const Decl = struct { name: []const u8, head: []const u8, idx: NodeIndex };
        var decls: std.ArrayListUnmanaged(Decl) = .empty;
        defer decls.deinit(self.gpa);

        for (self.result.data_forest) |idx| {
            if (self.result.tree.tagOf(idx) != .form) continue;
            const name = self.src.symbol(idx, "name") orelse continue;
            const head = self.src.head(idx);
            std.debug.assert(name.len > 0);
            std.debug.assert(head.len > 0);

            for (reserved_names) |builtin_name| {
                if (!std.mem.eql(u8, name, builtin_name)) continue;
                self.diagnose(.sjon, self.locate(&self.src, idx), "", "'{s}' is a builtin symbol and cannot name a ({s} …) — pngine reads it as the builtin wherever it appears, so this declaration can never be referenced", .{ name, head });
                return error.ValidationError;
            }

            for (decls.items) |prior| {
                if (!std.mem.eql(u8, prior.name, name)) continue;
                const first = self.locate(&self.src, prior.idx);
                const line: u32 = if (first) |l| l.line else 0;
                self.diagnose(.sjon, self.locate(&self.src, idx), "", "duplicate name '{s}': already declared as a ({s} …) at line {d} — names are one namespace across every form, whatever kind declares them", .{ name, prior.head, line });
                return error.ValidationError;
            }

            try decls.append(self.gpa, .{ .name = name, .head = head, .idx = idx });
        }
    }

    /// Resolve every `(define …)` into the expression env. A constant's value
    /// is a REAL (02 R7 — negative and fractional allowed; the slot that reads
    /// it decides integrality and range), and it may name another constant
    /// declared before OR after it: the set resolves to a fixed point, each
    /// pass evaluating the constants whose names are all bound by then. The
    /// only shape that never resolves is a cycle, refused with a span on the
    /// first constant still pending. Bounded: a pass that binds nothing ends
    /// the loop, and there are at most `pending` productive passes.
    ///
    /// Until audit 09 C1 this evaluated in document order through
    /// `evalNodeU32` with a bare `try`: a fractional or negative constant was
    /// truncated / refused before it reached any slot, and a forward
    /// reference was an unlocated "emit failed".
    fn buildEnv(self: *Emitter) Error!void {
        const Pending = struct { name: []const u8, form: NodeIndex, vnode: NodeIndex, reader: *const Reader, done: bool };
        var pending: std.ArrayListUnmanaged(Pending) = .empty;
        defer pending.deinit(self.gpa);
        for (self.forms.items) |f| {
            if (!std.mem.eql(u8, f.reader.head(f.idx), "define")) continue;
            const name = f.reader.symbol(f.idx, "name") orelse continue;
            const vnode = f.reader.authorNode(f.idx, "value") orelse continue;
            try pending.append(self.gpa, .{ .name = name, .form = f.idx, .vnode = vnode, .reader = f.reader, .done = false });
        }
        std.debug.assert(self.env_bindings.items.len == 0);

        var remaining: usize = pending.items.len;
        for (0..pending.items.len + 1) |_| {
            if (remaining == 0) break;
            var bound_this_pass: usize = 0;
            for (pending.items) |*p| {
                if (p.done) continue;
                self.env = .{ .bindings = self.env_bindings.items };
                const n = values.evalDefineValue(self.gpa, p.reader.tree, self.schema, &self.env, p.vnode) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // Names a constant not bound yet — a later declaration, or
                    // a cycle. The next pass tells them apart.
                    error.UnknownBinding => continue,
                    error.EmitError => {
                        self.diagnose(.sjon, self.locate(p.reader, p.vnode), "", "`(define :name {s})`: the value does not evaluate to a number", .{p.name});
                        return error.ValidationError;
                    },
                };
                try self.env_bindings.append(self.gpa, .{ .name = p.name, .value = .{ .number = n } });
                p.done = true;
                bound_this_pass += 1;
            }
            if (bound_this_pass == 0) break;
            remaining -= bound_this_pass;
        } else unreachable; // ≤ pending.len productive passes, then a pass binds nothing

        if (remaining != 0) {
            // A stuck constant is a cycle or a misspelling; they used to read the
            // same. A name in its expression that NO define declares (not merely
            // one still unbound) is the misspelling, and is named on the value.
            for (pending.items) |p| {
                if (p.done) continue;
                if (values.firstUnboundSymbol(p.reader.tree, &self.env, p.vnode)) |name| {
                    var declared = false;
                    for (pending.items) |q| {
                        if (std.mem.eql(u8, q.name, name)) declared = true;
                    }
                    if (!declared) {
                        self.diagnose(.sjon, self.locate(p.reader, p.vnode), "", "`(define :name {s})`: `{s}` is not a (define …) constant", .{ p.name, name });
                        return error.ValidationError;
                    }
                }
            }
            for (pending.items) |p| {
                if (p.done) continue;
                self.diagnose(.sjon, self.locate(p.reader, p.form), "", "`(define :name {s})` depends on itself — directly, or through another constant that names it — and a constant cannot refer back to itself", .{p.name});
                return error.ValidationError;
            }
        }
        self.env = .{ .bindings = self.env_bindings.items };
        std.debug.assert(self.env_bindings.items.len == pending.items.len);
    }

    /// Fold the optional top-level `(limits …)` form into the builder's
    /// device-limits table (each present key → an interned WebGPU camelCase name +
    /// its u64 value) and capture the four compute-workgroup limits for
    /// `checkWorkgroupSize`. A buildEnv-style pass — "limits" is not a phase head,
    /// so run()'s phase loop skips it, exactly like `define`/`queue`. At most one
    /// `(limits …)` form is allowed. (Arc-3 §5.3b)
    fn collectDeviceLimits(self: *Emitter) Error!void {
        var seen = false;
        for (self.forms.items) |f| {
            if (!std.mem.eql(u8, f.reader.head(f.idx), "limits")) continue;
            if (seen) {
                self.diagnose(.sjon, self.locate(f.reader, f.idx), "", "duplicate (limits …) form — declare device limits at most once", .{});
                return error.ValidationError;
            }
            seen = true;
            inline for (device_limit_pairs) |p| {
                // A limit is a non-negative integer (repr u32) — `optU32` holds
                // an expression or define-ref to that, where an `optF64` +
                // `@intFromFloat` let `(- 0 5)` through to a float→int trap.
                // Values ride the wire as u64 (forward-compat) even though the
                // schema caps at u32.
                if (try self.optU32(f.reader, f.idx, p.kebab)) |limit| {
                    const value: u64 = limit;
                    const name_id = self.builder.internString(self.gpa, p.camel) catch return error.OutOfMemory;
                    self.builder.addDeviceLimit(self.gpa, @intCast(@intFromEnum(name_id)), value) catch return error.OutOfMemory;
                    if (comptime std.mem.eql(u8, p.camel, "maxComputeWorkgroupSizeX")) self.wg_limits.x = limit;
                    if (comptime std.mem.eql(u8, p.camel, "maxComputeWorkgroupSizeY")) self.wg_limits.y = limit;
                    if (comptime std.mem.eql(u8, p.camel, "maxComputeWorkgroupSizeZ")) self.wg_limits.z = limit;
                    if (comptime std.mem.eql(u8, p.camel, "maxComputeInvocationsPerWorkgroup")) self.wg_limits.invocations = limit;
                }
            }
        }
    }

    /// Fold the optional top-level `(canvas …)` form into the builder's header
    /// flag: `:alpha-mode premultiplied` sets `canvas_alpha_premultiplied`
    /// (bit 3), consumed by the JS runtime BEFORE the executor runs (canvas
    /// configure happens at init, so an opcode is the wrong vehicle). Form
    /// absent, or `opaque` → flag clear, byte-identical output. The bit marks
    /// the deviation from `GPUCanvasConfiguration.alphaMode`, which is `opaque`;
    /// it used to mark the opposite, back when PNGine's own default was
    /// premultiplied (spec/09 step D). Native `--frame` renders offscreen and
    /// may ignore it (alpha-mode only affects compositing). At most one
    /// `(canvas …)` form. A buildEnv-style pass like `collectDeviceLimits`.
    /// (docs/plans/spec/04)
    fn collectCanvasConfig(self: *Emitter) Error!void {
        var seen = false;
        for (self.forms.items) |f| {
            if (!std.mem.eql(u8, f.reader.head(f.idx), "canvas")) continue;
            if (seen) {
                self.diagnose(.sjon, self.locate(f.reader, f.idx), "", "duplicate (canvas …) form — declare canvas configuration at most once", .{});
                return error.ValidationError;
            }
            seen = true;
            if (f.reader.symbol(f.idx, "alpha-mode")) |mode| {
                self.builder.canvas_alpha_premultiplied = std.mem.eql(u8, mode, "premultiplied");
            }
        }
    }

    /// Iterate collected forms, dispatching those whose head matches `head`.
    fn emitPhase(self: *Emitter, head: []const u8, emit_fn: *const fn (*Emitter, *const Reader, NodeIndex) Error!void) Error!void {
        for (self.forms.items) |ref| {
            if (!std.mem.eql(u8, ref.reader.head(ref.idx), head)) continue;
            try emit_fn(self, ref.reader, ref.idx);
        }
    }

    // ----------------------------------------------------------------------
    // Phase emitters
    // ----------------------------------------------------------------------

    fn emitData(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const name = try self.requiredSymbol(r, form, "name");

        // A positional sub-form: a shape generator (cube/teapot/…) or a `(wasm-data …)`
        // static WASM mesh generator → both expand to vertex bytes at compile time.
        // At most one: the loop returns on the FIRST such child, so a second one
        // used to be silently ignored. The schema says it now
        // (`data-shape-section :max-children 1`, SJON 1.4), so validation rejects
        // the second before this runs.
        //
        // One SOURCE per (data …) — audit 09 D22. The schema's exclusive-group
        // covers `:float32` | `:file`; a generator beside either is this check
        // (a head-set cannot count against a key), and so is a (data …) with
        // no source at all. Both used to compile: the generator won in
        // silence, and the empty form emitted zero bytes.
        const has_inline = r.authorNode(form, "float32") != null;
        const has_file = r.authorNode(form, "file") != null;
        for (r.children(form)) |c| {
            if (r.tree.tagOf(c) != .form) continue;
            const head = r.head(c);
            const is_generator = std.mem.eql(u8, head, "wasm-data") or values.shapeTypeFromHead(head) != null;
            if (!is_generator) continue;
            if (has_inline or has_file) {
                self.diagnose(.sjon, self.locate(r, c), "", "(data :name {s}) has a `({s} …)` generator AND `:{s}` — a data entry has one source", .{ name, head, if (has_inline) "float32" else "file" });
                return error.ValidationError;
            }
            if (std.mem.eql(u8, head, "wasm-data")) {
                try self.emitWasmMeshData(r, name, c);
                return;
            }
            if (values.shapeTypeFromHead(head)) |shape| {
                try self.emitShapeData(r, name, c, shape);
                return;
            }
        }
        if (!has_inline and !has_file) {
            self.diagnose(.sjon, self.locate(r, form), "", "(data :name {s}) has no source — give it `:float32 […]`, `:file \"…\"`, or a shape generator such as `(cube …)`", .{name});
            return error.ValidationError;
        }

        // A `:file` image → embedded [mime_len][mime][file bytes] (the source
        // for an (image-bitmap …)). The file is read from disk at compile time.
        if (r.string(form, "file")) |url| {
            return self.emitBlobData(r, form, name, url, r.string(form, "mime") orelse "application/octet-stream");
        }

        // Otherwise: inline float32 array → little-endian bytes.
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.gpa);
        if (r.vectorNodes(form, "float32")) |elems| {
            for (elems) |e| {
                const v: f32 = @floatCast(try self.elemF64(r, e, 0));
                const le: [4]u8 = @bitCast(v);
                try bytes.appendSlice(self.gpa, &le);
            }
        }
        const data_id = self.builder.addData(self.gpa, bytes.items) catch return error.OutOfMemory;
        try self.tables.data.put(self.gpa, name, data_id.toInt());
        try self.tables.data_byte_len.put(self.gpa, name, @intCast(bytes.items.len));
    }

    /// Generate vertex (and, for teapot/dragon, index) data via the reused
    /// compile-time generators. Records vertex bytes under `name`; for indexed
    /// shapes also records the index companion in `shape_index[name]` for a
    /// buffer's `:index-of` to consume.
    fn emitShapeData(self: *Emitter, r: *const Reader, name: []const u8, shape_form: NodeIndex, shape: shapes.ShapeType) Error!void {
        var format_buf: [8]shapes.Format = undefined;
        var config = shapes.ShapeConfig{ .formats = self.readShapeFormats(r, shape_form, shape, &format_buf) };
        try self.readShapeConfig(r, shape_form, shape, &config);

        if (shape.isIndexed()) {
            const result = (switch (shape) {
                .teapot => shapes.generateTeapot(self.gpa, config),
                .dragon => shapes.generateDragon(self.gpa, config),
                else => unreachable,
            }) catch return error.OutOfMemory;
            defer self.gpa.free(result.vertex_bytes);
            defer self.gpa.free(result.index_bytes);
            try self.chargeGenerated(r, shape_form, shape, result.vertex_bytes.len + result.index_bytes.len);

            const vid = self.builder.addData(self.gpa, result.vertex_bytes) catch return error.OutOfMemory;
            try self.tables.data.put(self.gpa, name, vid.toInt());
            try self.tables.data_byte_len.put(self.gpa, name, @intCast(result.vertex_bytes.len));

            const iid = self.builder.addData(self.gpa, result.index_bytes) catch return error.OutOfMemory;
            try self.tables.shape_index.put(self.gpa, name, .{
                .data_id = iid.toInt(),
                .byte_len = @intCast(result.index_bytes.len),
                .format = result.index_format,
            });
            return;
        }

        const bytes = (switch (shape) {
            .cube => shapes.generateCube(self.gpa, config),
            .plane => shapes.generatePlane(self.gpa, config),
            .sphere => shapes.generateSphere(self.gpa, config),
            .torus => shapes.generateTorus(self.gpa, config),
            .truncated_cone => shapes.generateTruncatedCone(self.gpa, config),
            .cylinder => shapes.generateCylinder(self.gpa, config),
            .teapot, .dragon => unreachable,
        }) catch |e| switch (e) {
            // A mesh past the cap is an authoring mistake, not an allocation
            // failure. Folding it into OutOfMemory is what made
            // `(truncated-cone :radial-subdivisions 2000 …)` — 24 million
            // indices — report as "out of memory" with no location at all.
            error.ShapeTooLarge, error.InvalidShapeConfig => {
                self.diagnose(.sjon, self.locate(r, shape_form), "", "({s} …) describes a mesh larger than the {d}-index cap on generated shapes", .{ @tagName(shape), shapes.MAX_VERTICES });
                return error.ValidationError;
            },
            else => return error.OutOfMemory,
        };
        defer self.gpa.free(bytes);
        try self.chargeGenerated(r, shape_form, shape, bytes.len);

        const data_id = self.builder.addData(self.gpa, bytes) catch return error.OutOfMemory;
        try self.tables.data.put(self.gpa, name, data_id.toInt());
        try self.tables.data_byte_len.put(self.gpa, name, @intCast(bytes.len));
    }

    /// Charge `len` generated bytes against the document's budget; refuse,
    /// located on the generator form, once it is spent.
    fn chargeGenerated(self: *Emitter, r: *const Reader, shape_form: NodeIndex, shape: shapes.ShapeType, len: usize) Error!void {
        self.generated_bytes += len;
        if (self.generated_bytes <= MAX_GENERATED_BYTES) return;
        self.diagnose(.sjon, self.locate(r, shape_form), "", "({s} …) brings the document's generated mesh data to {d} bytes, past the {d} MiB budget — a payload is data in a PNG; reuse one (data …) entry instead of generating the mesh again", .{ @tagName(shape), self.generated_bytes, MAX_GENERATED_BYTES / (1024 * 1024) });
        return error.ValidationError;
    }

    /// Emit a static `(data :name … (wasm-data :file … :func … :returns …))` mesh
    /// generator (port of legacy `resources.emitWasmData`): read the WASM file,
    /// embed it, `init_wasm_module`, and record a `wasm_mesh_data` entry so a buffer's
    /// `:data` can size it and fill it at create time. The
    /// init_wasm_module emits here in the data phase, so it is the first create-call
    /// in the log (matching the legacy `emitData` position). IO unavailable → emit error.
    fn emitWasmMeshData(self: *Emitter, r: *const Reader, name: []const u8, form: NodeIndex) Error!void {
        std.debug.assert(name.len > 0);
        const url = try self.requiredString(r, form, "file");
        const func = try self.requiredSymbol(r, form, "func");
        const returns = try self.requiredString(r, form, "returns");
        const byte_size = values.wgslReturnByteSize(returns) orelse {
            self.diagnose(.sjon, self.locate(r, form), "", "(wasm-data …) declares :returns '{s}', which is not a WGSL type the emitter can size", .{returns});
            return error.EmitError;
        };

        const wasm_bytes = self.readDataFile(url) catch |e| return self.unreadableFile(r, form, url, e);
        defer self.gpa.free(wasm_bytes);
        const data_id = self.builder.addData(self.gpa, wasm_bytes) catch return error.OutOfMemory;

        const module_id = try self.tables.wasm_modules.allocAnonymous();
        self.builder.getEmitter().initWasmModule(self.gpa, module_id, data_id.toInt()) catch return error.OutOfMemory;

        const func_name_id = self.builder.internString(self.gpa, func) catch return error.OutOfMemory;
        try self.tables.wasm_mesh_data.put(self.gpa, name, .{
            .module_id = module_id,
            .func_name_id = func_name_id.toInt(),
            .byte_size = byte_size,
        });
    }

    /// Emit a blob `(data :name … :file "path" :mime "…")` (port of legacy
    /// `resources.emitBlobData`): read the image file relative to `base_dir` and
    /// embed it as `[mime_len:u8][mime][file bytes]` in the data section. Recorded
    /// in `data_ids` only (not `data_byte_len`) — a blob can't size a buffer; it is
    /// the source for an (image-bitmap …). An unreadable file is the same located
    /// refusal the other three file readers give (`unreadableFile`, on the form);
    /// it used to be an UNLOCATED headline, which `--json` drops from the array.
    fn emitBlobData(self: *Emitter, r: *const Reader, form: NodeIndex, name: []const u8, url: []const u8, mime: []const u8) Error!void {
        std.debug.assert(name.len > 0);
        const file_data = self.readDataFile(url) catch |e| return self.unreadableFile(r, form, url, e);
        defer self.gpa.free(file_data);

        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.gpa);
        const mime_len: u8 = @intCast(@min(mime.len, 255));
        try bytes.append(self.gpa, mime_len);
        try bytes.appendSlice(self.gpa, mime[0..mime_len]);
        try bytes.appendSlice(self.gpa, file_data);

        const data_id = self.builder.addData(self.gpa, bytes.items) catch return error.OutOfMemory;
        try self.tables.data.put(self.gpa, name, data_id.toInt());
    }

    /// Emit an `(image-bitmap :name … :data <data-ref>)`: the `:data` blob must
    /// already be in `data_ids` (the data phase runs first). Mirrors the legacy
    /// `resources.emitImageBitmaps` — a decode-on-CPU step whose result a
    /// (copy-external-image-to-texture …) uploads to a texture.
    fn emitImageBitmap(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const name = try self.requiredSymbol(r, form, "name");
        const data_name = try self.requiredSymbol(r, form, "data");
        const blob_data_id = self.tables.data.get(data_name) orelse return self.unresolvedRef(r, form, "the (data …) blob", data_name);

        const bitmap_id = try self.tables.image_bitmaps.intern(self.gpa, name);
        self.builder.getEmitter().createImageBitmap(self.gpa, bitmap_id, blob_data_id) catch return error.OutOfMemory;
    }

    fn emitShaderModule(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const name = try self.requiredSymbol(r, form, "name");
        const code = try self.requiredString(r, form, "code");
        // Inline math constants (PI/TAU/E) so the WGSL matches the legacy path.
        const subst = values.substituteMathConstants(self.gpa, code) catch return error.OutOfMemory;
        defer if (subst) |s| self.gpa.free(s);
        const authored = subst orelse code;

        // CONST-04: substitute any `(constant …)` values BEFORE validation, so
        // wgslender validates — and every downstream check reflects — the text
        // that actually ships. A specialised value can be invalid where the
        // override was fine (`@workgroup_size(0)`), and that error has to be
        // reachable. The rewrite is line-preserving, so wgslender's line:col
        // still lands on the author's own code.
        const specialised = try self.specialiseModule(name, authored);
        defer if (specialised) |s| self.gpa.free(s);
        const source = specialised orelse authored;

        // ORDERING IS LOAD-BEARING: validate the author's text, ship/stash the
        // minified text. wgslender's diagnostics carry line and column, and
        // minified WGSL is one long line — validating after minification would
        // point every error at 1:n of bytes the author never wrote. This call
        // used to sit below `createShaderModule`, which was harmless only while
        // the shipped bytes and the validated bytes were the same slice.
        const validated = if (self.validate_shaders) try self.validateShader(name, source) else false;

        // Minify (when asked) and reflect, in ONE wgslender parse. What this
        // returns is the module's post-emission truth: the bytes that ship and
        // the reflection OF those bytes. Every reflected check downstream reads
        // it, so a stash holding the author's text while the payload holds the
        // minified text would describe a shader that is not in the file.
        var analysis = try self.analyzeModule(name, source);
        errdefer freeModuleAnalysis(self.gpa, &analysis);

        // The WGSL table holds MAX_WGSL_MODULES entries and `add` asserts the
        // bound — an invariant for the emitter to uphold here, where the
        // document can be told which module broke it, not a trap for the
        // 1,025th `(shader-module …)` to hit.
        if (self.builder.wgsl_table.count() >= bytecode.format.MAX_WGSL_MODULES) {
            self.diagnose(.sjon, self.locate(r, form), "", "shader module '{s}' is module #{d}, but a payload's WGSL table holds at most {d} modules", .{ name, self.builder.wgsl_table.count() + 1, bytecode.format.MAX_WGSL_MODULES });
            return error.ValidationError;
        }
        const data_id = self.builder.addData(self.gpa, analysis.wgsl) catch return error.OutOfMemory;
        _ = self.builder.addWgsl(self.gpa, data_id.toInt(), &.{}) catch return error.OutOfMemory;
        const shader_id = try self.tables.shaders.intern(self.gpa, name);
        self.builder.getEmitter().createShaderModule(self.gpa, shader_id, data_id.toInt()) catch return error.OutOfMemory;

        // Entry points come from the SAME reflection, so a valid module costs no
        // extra parse for the pipeline existence check. Skipped when the module
        // was rejected (a broken shader cannot reflect meaningfully) — leaving
        // `name` out of `shader_entries`, which every pipeline check bails on.
        if (validated) {
            if (analysis.reflection) |*rd| try self.recordEntryPoints(name, rd);
        }

        // Record the module in EMIT order (+ lowered-ness — the same tree test
        // `locate` uses): the deterministic walk index for populateUniformTable.
        // BEFORE the put, so the put is the last fallible operation in this
        // function — see below.
        try self.tables.shader_order.append(self.gpa, .{ .name = name, .lowered = r.tree != self.src.tree });

        // Ownership of `analysis` transfers here, and this is the ONLY place it
        // can. The `errdefer` above covers every fallible step between the build
        // and this line; a failing `put` leaves the map empty, so the errdefer
        // still owns the free. Freeing explicitly in a `catch` here would double
        // free with it, and any fallible statement AFTER this line would too
        // (the map would own the analysis while the errdefer freed it) — which
        // is why the order append moved above. Keyed by module name (a stable
        // source slice, unique per schema cross-ref), mirroring `tables.shaders`.
        //
        // The key is unique because the validator says so: a second module of
        // this name — including a hand-written `main__shader` colliding with the
        // `pngine/pass-v1`-synthesized one — is a `duplicate_cross_ref_target`
        // reject that never reaches emit (pinned here by
        // `examples/invalid/pass_shader_name_collision.sjon`). Restated as an
        // assert because the guard lives in another repo and an overwrite would
        // leak the whole displaced `ModuleAnalysis` — dup'd WGSL text plus a
        // wgslender arena — silently (LEAK-10 C).
        const gop = self.tables.shader_analysis.map.getOrPut(self.gpa, name) catch return error.OutOfMemory;
        std.debug.assert(!gop.found_existing);
        gop.value_ptr.* = analysis;
    }

    /// CONST-04: apply this module's `(constant …)` values to its WGSL, or null
    /// when it has none — which is every module in the corpus today, so the
    /// common path allocates nothing and reflects nothing extra.
    ///
    /// The one module that DOES carry constants pays a second parse: the rewrite
    /// needs the `override` declaration spans, which only a reflection of the
    /// unmodified source can give. That is a deliberate exception to the
    /// one-parse-per-module budget (min1-02), bought by the modules that opt in
    /// rather than charged to every module.
    ///
    /// A refusal here is the AUTHOR's error, not infrastructure: an unknown
    /// override name or a value its declared type cannot hold. Both are located
    /// on the `(constant …)` form rather than the shader module, because that is
    /// the text to change.
    fn specialiseModule(self: *Emitter, name: []const u8, source: []const u8) Error!?[]u8 {
        const specs = try self.specsFor(name);
        defer self.gpa.free(specs);
        if (specs.len == 0) return null;
        if (source.len == 0) return null; // nothing to rewrite; the empty-module path warns already

        var spec_err: ?reflect.wgslender_native.SpecialiseError = null;
        return reflect.wgslender_native.specialiseOverrides(self.gpa, source, specs, &spec_err) catch |e| {
            const se = spec_err orelse {
                // No cause recorded ⇒ an allocation failure, not an authoring
                // error. Propagate it as one.
                return if (e == error.OutOfMemory) error.OutOfMemory else error.EmitError;
            };
            switch (se) {
                .unknown => |oname| {
                    const loc = if (self.constantRef(name, oname)) |ref| self.locate(ref.reader, ref.idx) else null;
                    self.diagnose(.wgsl, loc, "", "shader module '{s}' declares no override '{s}' to specialise", .{ name, oname });
                },
                .type_mismatch => |tm| {
                    const loc = if (self.constantRef(name, tm.name)) |ref| self.locate(ref.reader, ref.idx) else null;
                    self.diagnose(.wgsl, loc, "", "override '{s}' of shader module '{s}' is declared '{s}', which cannot hold the given value", .{ tm.name, name, tm.typ });
                },
            }
            return error.ValidationError;
        };
    }

    /// Build one module's `ModuleAnalysis`: the bytes to ship, and ONE
    /// reflection of exactly those bytes.
    ///
    /// Under `--minify` both halves come out of a SINGLE wgslender parse —
    /// `minifyAndReflect` maps reflection onto the minified names, which is
    /// precisely what the invariant needs ("reflect what ships"), so the
    /// reflection is free. Otherwise it is one `reflectNative` of the source.
    /// Either way: one parse per module, where four used to be.
    ///
    /// Never fatal. A minify failure is INFRA, not author error: the module
    /// already passed validation above, so the emit proceeds with the original
    /// bytes and warns. A reflect failure yields a null `reflection`, which the
    /// consumers read as "no reflected checks for this module".
    ///
    /// Three names survive minification, and pngine binds by all three: entry
    /// points (marked API-facing before DCE), `@group`/`@binding` vars
    /// (`mangle_external_bindings` defaults false), and uniform struct MEMBER
    /// names (gpu.js keys `setUniform` by bare field name). Everything else is
    /// unreachable by name from outside the shader, so `keep_names` is null.
    fn analyzeModule(self: *Emitter, name: []const u8, source: []const u8) Error!ModuleAnalysis {
        std.debug.assert(name.len > 0); // schema-required cross-ref key

        if (self.minify_shaders and source.len > 0) {
            if (reflect.wgslender_native.minifyAndReflectNative(self.gpa, source, null)) |result| {
                var r = result;
                // Non-empty in, empty out means a comment/whitespace-only module
                // or a wgslender edge case. Ship the original rather than an
                // empty module: emitting nothing where the author wrote
                // something is a behaviour change no size win justifies.
                if (r.code.len > 0) return .{ .wgsl = r.code, .reflection = r.reflection };
                self.gpa.free(r.code);
                r.reflection.deinit();
            } else |_| {
                self.warnMinifyInfraFailed(name);
            }
        }

        // `source` borrows `subst`/the tree, both of which outlive this call but
        // not the emit — the map owns its bytes.
        const owned = self.gpa.dupe(u8, source) catch return error.OutOfMemory;
        errdefer self.gpa.free(owned);
        // `reflectNative` asserts a non-empty source; an empty module simply has
        // nothing to reflect and contributes no checks.
        if (owned.len == 0) return .{ .wgsl = owned, .reflection = null };
        const rd = reflect.wgslender_native.reflectNative(self.gpa, owned) catch {
            self.warnReflectInfraFailed(name);
            return .{ .wgsl = owned, .reflection = null };
        };
        return .{ .wgsl = owned, .reflection = rd };
    }

    /// The cached reflection for `module`, or null when there is none: unknown
    /// module, empty module, or a reflect-infra failure (already warned ONCE at
    /// `analyzeModule` — the callers stay quiet rather than repeating it per
    /// pipeline). Every gated join reads through here, so "we have no reflection
    /// for this module" is a state the code names instead of an `orelse return`
    /// that silently skipped a check.
    fn reflectionOf(self: *const Emitter, module: []const u8) ?*const reflect.ReflectionData {
        const analysis = self.tables.shader_analysis.map.getPtr(module) orelse return null;
        if (analysis.reflection) |*rd| return rd;
        return null;
    }

    /// Minify-INFRA failure (wgslender errored on a module that just passed
    /// validation): the module ships as the author wrote it. The payload is
    /// correct, only larger than `--minify` implies — so this warns rather than
    /// failing, and warns rather than going dark, because "minification silently
    /// did nothing" is the precise failure mode that let the flag stay dead.
    ///
    /// Ungated, unlike `warnReflectInfraFailed`: minification is independent of
    /// `validate_shaders`, and its only caller is already behind `minify_shaders`.
    fn warnMinifyInfraFailed(self: *Emitter, name: []const u8) void {
        self.diagnoseWarn(.wgsl, null, name, "shader module '{s}': WGSL minification failed — the module ships UNMINIFIED (the emit is unaffected)", .{name});
    }

    /// Strict-validation pass over one shader module's WGSL (gated on
    /// `validate_shaders`): (1) run wgslender's semantic validator and raise
    /// `ValidationError` on any error-severity diagnostic (catches the
    /// `bad_wgsl_syntax` negative); (2) reflect the module's entry points into
    /// `shader_entries` so the pipeline phases can check that a declared entry
    /// actually exists (catches `missing_entry_point`). An infra failure (not a
    /// WGSL error) is non-fatal — a VALIDATOR failure warns that the module went
    /// unchecked; a post-validation REFLECT failure skips the entry check and
    /// warns too (`warnReflectInfraFailed`) — never blocking an otherwise-valid
    /// emit. Both are REPORTED, not merely tolerated: the reflect path used to
    /// lean on populateUniformTable's table-drop warning, which covers only this
    /// one of the four reflect sites.
    fn validateShader(self: *Emitter, name: []const u8, code: []const u8) Error!bool {
        std.debug.assert(self.validate_shaders); // call site (emitShaderModule) gates
        if (code.len == 0) return false;

        // Under `lint_shaders` one `lintNative` call answers both questions —
        // its analysis pass IS the validation pass, so linting costs one parse,
        // not two. Advisories are reported only when the module is otherwise
        // clean: a shader with a real error must be fixed before rule findings
        // are worth reading, and the error path below returns early anyway.
        // `lint_available` is comptime false on wasm (the rule engine is 88 KB
        // the in-browser compiler never uses — the editor lints via
        // wgslender-lsp instead), so this whole branch compiles out there and
        // the plain validate path below is what runs.
        if (self.lint_shaders and reflect.wgslender_native.lint_available) {
            var lr = reflect.wgslender_native.lintNative(self.gpa, code, 0) catch {
                self.warnValidatorInfraFailed(name);
                return false;
            };
            defer lr.deinit();
            if (self.reportShaderError(name, lr.diagnostics)) return false;
            self.reportShaderAdvisories(name, lr.diagnostics, lr.lint);
        } else {
            var vr = reflect.wgslender_native.validateNative(self.gpa, code) catch {
                self.warnValidatorInfraFailed(name);
                return false;
            };
            defer vr.deinit();
            if (self.reportShaderError(name, vr.diagnostics)) return false;
        }
        return true;
    }

    /// Validator-INFRA failure (wgslender errored, not a WGSL diagnostic): the
    /// module compiles completely unchecked — no semantic validation, no
    /// entry-point reflection — so any WGSL error surfaces only at runtime in
    /// the browser. Warn instead of going dark; no gate needed, every caller is
    /// already behind `validate_shaders`.
    fn warnValidatorInfraFailed(self: *Emitter, name: []const u8) void {
        self.diagnoseWarn(.wgsl, null, name, "shader module '{s}': WGSL validation infrastructure failed — the module was NOT validated (shader errors will only surface at runtime)", .{name});
    }

    /// `warnValidatorInfraFailed`'s counterpart for a post-validation REFLECT
    /// failure. Control flow is unchanged and deliberately so: reflection feeds
    /// *advisory* cross-checks (entry-point existence, workgroup size, vertex
    /// attributes, fragment targets), and a reflect failure must never block an
    /// otherwise-valid emit. What was wrong is that it was also SILENT — the
    /// realistic trigger is OOM inside wgslender, and only one of the sites had a
    /// downstream warn to lean on, so the compiler could emit an artifact with
    /// every reflected check quietly skipped.
    ///
    /// ONE call site now (`analyzeModule`), where there were four — each of
    /// which had to pass its own description of what it was about to skip.
    /// Reflection happens once per module, so the failure is a property of the
    /// module rather than of whichever check noticed first, and the message can
    /// simply name them all.
    ///
    /// Gated internally: `analyzeModule` runs unconditionally (the uniform table
    /// must populate on the golden/parity path, where validation is off), and
    /// several Emitter tests assert exact `warningCount` values on that path.
    fn warnReflectInfraFailed(self: *Emitter, name: []const u8) void {
        if (!self.validate_shaders) return;
        self.diagnoseWarn(.wgsl, null, name, "shader module '{s}': WGSL reflection failed — entry-point, @workgroup_size, vertex-attribute, fragment-target and uniform-table checks were ALL SKIPPED for this module (the emit is unaffected)", .{name});
    }

    /// Report the first error-severity diagnostic, if any. Returns true when the
    /// module is rejected, so the caller skips reflection.
    fn reportShaderError(self: *Emitter, name: []const u8, diagnostics: []const reflect.wgslender_native.ValidationDiagnostic) bool {
        for (diagnostics) |d| {
            if (d.severity != .@"error") continue;
            // Surface the first error-severity diagnostic (correctly labeled)
            // rather than the generic "SJON validation failed": to stderr for the
            // CLI human and, when a sink is attached, into the editor's WGSL view
            // (the `name` module tag routes it, shader-relative line/col). One
            // representative located entry per shader module — consistent with the
            // rest of the emit-time checks (one squiggle per offending form); the
            // WGSL view's squiggles (wgslender-lsp) carry the remaining diagnostics.
            self.diagnose(
                .wgsl,
                .{ .line = d.line, .col = d.column, .end_line = d.end_line, .end_col = d.end_column },
                name, // WGSL module tag → routes the squiggle to the editor's WGSL view
                "WGSL error in shader module '{s}' at {d}:{d}: {s}",
                .{ name, d.line, d.column, d.message },
            );
            // F5 collect-across-forms: record the reject and stop validating THIS
            // module (a broken shader can't reflect meaningfully), but DON'T halt
            // the walk — `run()` checks `shader_error_count` after the whole
            // shader-module phase so a second broken module still reports. Skipping
            // reflection leaves `name` out of `shader_entries`, and every pipeline
            // check bails on an unknown/unreflected module (never a false reject).
            self.shader_error_count += 1;
            return true;
        }
        return false;
    }

    /// Report advisory findings for an otherwise-valid module: wgslender's
    /// warning-severity VALIDATOR diagnostics (uniformity `E0700`–`E0703` and
    /// friends), which `validateShader` drops on the default path, followed by
    /// the `@wgslender/recommended` LINT findings.
    ///
    /// Both are warnings by construction — nothing here touches
    /// `shader_error_count`, so no advisory can fail a compile. Each carries its
    /// shader-relative location and the `name` module tag, so the editor routes
    /// the squiggle into its WGSL view exactly like an error.
    fn reportShaderAdvisories(
        self: *Emitter,
        name: []const u8,
        validator: []const reflect.wgslender_native.ValidationDiagnostic,
        lint: []const reflect.wgslender_native.ValidationDiagnostic,
    ) void {
        std.debug.assert(self.lint_shaders); // only the opt-in path reports these
        for (validator) |d| {
            if (d.severity != .warning) continue; // errors handled; info/note/hint are noise here
            self.warnShaderDiagnostic(name, d, "WGSL warning");
        }
        for (lint) |d| {
            if (d.severity == .@"error") continue; // recommended pack is all warnings; belt-and-braces
            self.warnShaderDiagnostic(name, d, "WGSL lint");
        }
    }

    /// One advisory line. `kind` labels the source ("WGSL warning" vs "WGSL
    /// lint") so a reader can tell a spec-level complaint from a style rule, and
    /// the rule/error code rides along when wgslender supplies one.
    fn warnShaderDiagnostic(
        self: *Emitter,
        name: []const u8,
        d: reflect.wgslender_native.ValidationDiagnostic,
        comptime kind: []const u8,
    ) void {
        const loc: Diag.Located = .{ .line = d.line, .col = d.column, .end_line = d.end_line, .end_col = d.end_column };
        if (d.code.len > 0) {
            self.diagnoseWarn(.wgsl, loc, name, kind ++ " in shader module '{s}' at {d}:{d}: {s} ({s})", .{ name, d.line, d.column, d.message, d.code });
        } else {
            self.diagnoseWarn(.wgsl, loc, name, kind ++ " in shader module '{s}' at {d}:{d}: {s}", .{ name, d.line, d.column, d.message });
        }
    }

    /// Record a valid module's reflected entry points so the pipeline phases can
    /// check that a declared `:entry` actually exists.
    fn recordEntryPoints(self: *Emitter, name: []const u8, rd: *const reflect.ReflectionData) Error!void {
        var set: EntrySet = .empty;
        for (rd.entry_points) |ep| {
            if (ep.name.len == 0) continue;
            const dup = self.gpa.dupe(u8, ep.name) catch {
                freeEntrySet(self.gpa, &set);
                return error.OutOfMemory;
            };
            set.put(self.gpa, dup, {}) catch {
                self.gpa.free(dup);
                freeEntrySet(self.gpa, &set);
                return error.OutOfMemory;
            };
        }
        // Same uniqueness invariant (and same silent-leak-on-overwrite risk) as
        // `shader_analysis` above: an overwrite would strand the displaced
        // `EntrySet`'s dup'd entry-point names.
        const gop = self.tables.shader_entries.map.getOrPut(self.gpa, name) catch {
            freeEntrySet(self.gpa, &set);
            return error.OutOfMemory;
        };
        std.debug.assert(!gop.found_existing);
        gop.value_ptr.* = set;
    }

    /// Resolve `node`'s user-source (line, col) span for a diagnostic squiggle, or
    /// null when it has no user location: a lowered/`(pass …)` form (its synthetic tree
    /// is not `src`, so its byte offsets don't map to the user source), or the
    /// golden/parity path (source never threaded). 1-based. F9: the source tree
    /// parses at offset 0, so a `src` span is already a user offset — no manifest
    /// prefix to subtract. Complexity: O(offset).
    fn locate(self: *const Emitter, r: *const Reader, node: NodeIndex) ?Diag.Located {
        if (self.user_source.len == 0) return null; // golden/parity: source not threaded
        if (r.tree != self.src.tree) return null; // lowered/synthetic tree → no user span
        const span = r.tree.spanOf(node);
        const lc = Diag.lineColOf(self.user_source, span.start);
        var end_line: u32 = 0;
        var end_col: u32 = 0;
        if (span.end > span.start) {
            const lce = Diag.lineColOf(self.user_source, span.end);
            end_line = lce.line;
            end_col = lce.col;
        }
        std.debug.assert(lc.line >= 1 and lc.col >= 1);
        return .{ .line = lc.line, .col = lc.col, .end_line = end_line, .end_col = end_col };
    }

    /// Read an OPTIONAL numeric slot: the value, or null when the key is absent
    /// and undefaulted. `requiredU32`'s sibling for the keys a document may
    /// legitimately leave out, and the reason both exist: a numeric slot accepts
    /// a literal, a bounded expression, or a bare `(define …)` name, and only an
    /// evaluating read sees all three. A literal-only reader (`Reader.number`;
    /// the retired `u32Of`) returns null for an expression, which a call site's
    /// `orelse` then turns into a default the author did not write — §307's
    /// silent-fallback defect, one family over. Do not reach for them here.
    fn optU32(self: *Emitter, r: *const Reader, form: NodeIndex, key: []const u8) Error!?u32 {
        std.debug.assert(key.len > 0);
        return r.evalU32(self.gpa, self.schema, &self.env, form, key) catch |e| self.refuseNumericKey(r, form, key, e);
    }

    /// `optU32` for a slot whose wire form is a real (lod clamps, depth bias,
    /// depth clear value, shape-generator dimensions).
    fn optF64(self: *Emitter, r: *const Reader, form: NodeIndex, key: []const u8) Error!?f64 {
        std.debug.assert(key.len > 0);
        return r.evalF64(self.gpa, self.schema, &self.env, form, key) catch |e| self.refuseNumericKey(r, form, key, e);
    }

    /// A wire bound for a numeric slot narrower than u32, or floored above 0.
    ///
    /// The schema states these bounds (`numeric-bounds :min … :max …`), and the
    /// validator holds LITERALS to them — but an expression or a `(define …)`
    /// reference evaluates here, after validation, and used to go straight into
    /// an `@intCast`/`@intFromFloat`/assert: a panic in Debug, undefined
    /// behaviour in the ReleaseSmall editor compiler (`:group G` with G = 1000
    /// became group 232, silently). Every such read goes through `optBounded` /
    /// `elemBounded`, which re-check the evaluated value and refuse, located on
    /// the value the author wrote, saying WHY the slot is that narrow.
    const Bound = struct {
        min: u32 = 0,
        max: u32 = std.math.maxInt(u32),
        why: []const u8,

        /// A one-byte wire slot: binding / group / pool index, a pass's
        /// vertex-buffer or bind-group slot, a copy's destination mip level.
        const byte: Bound = .{ .max = 255, .why = "the wire encodes it in one byte" };
        /// A count WebGPU requires to be at least 1: an extent dimension, a
        /// mip-level / array-layer count.
        const positive: Bound = .{ .min = 1, .why = "WebGPU requires at least 1" };
        /// GPUSamplerDescriptor.maxAnisotropy.
        const anisotropy: Bound = .{ .min = 1, .max = 16, .why = "GPUSamplerDescriptor.maxAnisotropy is 1..16" };
        /// A copy origin component: u16 on the wire.
        const origin: Bound = .{ .max = std.math.maxInt(u16), .why = "the wire encodes a copy origin in 16 bits" };
        /// GPUQuerySetDescriptor.count — createQuerySet's own bound.
        const query_count: Bound = .{ .min = 1, .max = 4096, .why = "GPUQuerySetDescriptor.count is 1..4096" };
    };

    /// `optU32` held to `bound` — the read for every narrow scalar slot.
    fn optBounded(self: *Emitter, r: *const Reader, form: NodeIndex, key: []const u8, bound: Bound) Error!?u32 {
        std.debug.assert(key.len > 0);
        std.debug.assert(bound.min <= bound.max);
        const v = (try self.optU32(r, form, key)) orelse return null;
        try self.checkBound(r, r.authorNode(form, key) orelse form, key, v, bound);
        return v;
    }

    /// `elemU32` held to `bound` — the read for every narrow vector element.
    fn elemBounded(self: *Emitter, r: *const Reader, elem: NodeIndex, default: u32, bound: Bound) Error!u32 {
        std.debug.assert(bound.min <= bound.max);
        std.debug.assert(default >= bound.min and default <= bound.max);
        const v = try self.elemU32(r, elem, default);
        try self.checkBound(r, elem, null, v, bound);
        return v;
    }

    /// The one refusal for an evaluated value outside its wire bound. `key` is
    /// null for a vector element (the span says which one).
    fn checkBound(self: *Emitter, r: *const Reader, node: NodeIndex, key: ?[]const u8, v: u32, bound: Bound) Error!void {
        std.debug.assert(bound.why.len > 0);
        if (v >= bound.min and v <= bound.max) return;
        var what_buf: [64]u8 = undefined;
        const what: []const u8 = if (key) |k| (std.fmt.bufPrint(&what_buf, "`:{s}`", .{k}) catch "the value") else "the value";
        self.diagnose(.sjon, self.locate(r, node), "", "{s} evaluates to {d}, outside this slot's range {d}..{d} — {s}", .{ what, v, bound.min, bound.max, bound.why });
        return error.ValidationError;
    }

    /// The located refusal for a numeric KEY that did not evaluate or did not
    /// fit — the squiggle goes on the value the author wrote (audit 09 C2).
    fn refuseNumericKey(self: *Emitter, r: *const Reader, form: NodeIndex, key: []const u8, e: values.EvalError) Error {
        std.debug.assert(key.len > 0);
        if (e == error.OutOfMemory) return error.OutOfMemory;
        const node = r.authorNode(form, key) orelse form;
        return self.refuseNumeric(r, node, key, e);
    }

    /// One wording per way a number can miss the wire. `key` is null for a
    /// vector element (the span says which one). The value is re-evaluated for
    /// the message — this is the failure path, so the second walk is free — and
    /// omitted when it cannot be.
    fn refuseNumeric(self: *Emitter, r: *const Reader, node: NodeIndex, key: ?[]const u8, e: values.EvalError) Error {
        std.debug.assert(e != error.OutOfMemory);
        var what_buf: [64]u8 = undefined;
        const what: []const u8 = if (key) |k| (std.fmt.bufPrint(&what_buf, "`:{s}`", .{k}) catch "the value") else "the value";
        const loc = self.locate(r, node);
        const n: f64 = values.evalNodeF64(self.gpa, r.tree, self.schema, &self.env, node) catch std.math.nan(f64);
        switch (e) {
            error.OutOfMemory => unreachable,
            error.EmitError => switch (values.evalFailure(self.gpa, r.tree, self.schema, &self.env, node) orelse error.TypeMismatch) {
                // The evaluator raises UnknownBinding without the name; walk the
                // expression for it, so the message says which constant is
                // missing rather than only that something is (audit 09 sweep).
                error.UnknownBinding => if (values.firstUnboundSymbol(r.tree, &self.env, node)) |name|
                    self.diagnose(.sjon, loc, "", "{s} does not evaluate to a number — `{s}` is not a (define …) constant", .{ what, name })
                else
                    self.diagnose(.sjon, loc, "", "{s} does not evaluate to a number — a name in it is not a (define …) constant", .{what}),
                error.DivisionByZero => self.diagnose(.sjon, loc, "", "{s} does not evaluate to a number — it divides by zero", .{what}),
                else => self.diagnose(.sjon, loc, "", "{s} does not evaluate to a number", .{what}),
            },
            error.NotFinite => self.diagnose(.sjon, loc, "", "{s} does not evaluate to a finite number", .{what}),
            error.Negative => self.diagnose(.sjon, loc, "", "{s} evaluates to {d}, and this slot takes a non-negative integer", .{ what, n }),
            error.NotAnInteger => self.diagnose(.sjon, loc, "", "{s} evaluates to {d}, and this slot takes an integer — wrap the expression in (floor …) or (ceil …)", .{ what, n }),
            error.AboveU32 => self.diagnose(.sjon, loc, "", "{s} evaluates to {d}, above the u32 ceiling {d}", .{ what, n, std.math.maxInt(u32) }),
        }
        return error.ValidationError;
    }

    /// Read a numeric slot the SCHEMA guarantees is materialized — either the key
    /// is required, or it carries a `:default` so `getEffectiveValue` always
    /// answers. `evalU32` returns null only when neither holds.
    ///
    /// `orelse unreachable` states that invariant literally, and 21 sites did.
    /// But this file ships at ReleaseSmall (the in-browser compiler) and
    /// ReleaseFast (the cross-compiled CLI), where `unreachable` is undefined
    /// behaviour rather than a panic — so a schema edit that made one of these
    /// keys optional would be a silent miscompile in the shipped binary, not a
    /// crash anyone would see. The invariant is worth stating; it is not worth
    /// betting release codegen on.
    ///
    /// So: panic in safe builds (Debug/ReleaseSafe — the whole test suite, where
    /// a broken invariant should be loud and immediate), and in release degrade
    /// to a located EmitError that names the offending key.
    fn requiredU32(self: *Emitter, r: *const Reader, form: NodeIndex, key: []const u8) Error!u32 {
        std.debug.assert(key.len > 0);
        if (try self.optU32(r, form, key)) |v| return v;
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            std.debug.panic("schema invariant broken: `:{s}` is neither required nor defaulted", .{key});
        }
        self.diagnose(.sjon, self.locate(r, form), "", "internal: required numeric key ':{s}' is missing after validation", .{key});
        return error.EmitError;
    }

    /// `requiredU32`'s sibling for a symbol slot the schema guarantees — either
    /// required outright, or the surviving arm of an `(exclusive-group … exactly-one)`
    /// whose other arms returned earlier. Same release-UB reasoning.
    fn requiredSymbol(self: *Emitter, r: *const Reader, form: NodeIndex, key: []const u8) Error![]const u8 {
        std.debug.assert(key.len > 0);
        if (r.symbol(form, key)) |v| return v;
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            std.debug.panic("schema invariant broken: `:{s}` is neither required nor exclusive-group-guaranteed", .{key});
        }
        self.diagnose(.sjon, self.locate(r, form), "", "internal: required symbol key ':{s}' is missing after validation", .{key});
        return error.EmitError;
    }

    /// `requiredSymbol`'s sibling for a STRING slot the schema guarantees
    /// (`(shader-module :code …)`, `(wasm-call :file …)`). Same release-UB
    /// reasoning: the validator has already rejected its absence, so reaching
    /// this means the schema and the emitter disagree about what is required.
    fn requiredString(self: *Emitter, r: *const Reader, form: NodeIndex, key: []const u8) Error![]const u8 {
        std.debug.assert(key.len > 0);
        if (r.string(form, key)) |v| return v;
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            std.debug.panic("schema invariant broken: `:{s}` is neither required nor exclusive-group-guaranteed", .{key});
        }
        self.diagnose(.sjon, self.locate(r, form), "", "internal: required string key ':{s}' is missing after validation", .{key});
        return error.EmitError;
    }

    /// `requiredSymbol`'s sibling for a VECTOR slot the schema guarantees.
    fn requiredVector(self: *Emitter, r: *const Reader, form: NodeIndex, key: []const u8) Error![]const NodeIndex {
        std.debug.assert(key.len > 0);
        if (r.vectorNodes(form, key)) |v| return v;
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            std.debug.panic("schema invariant broken: `:{s}` is neither required nor exclusive-group-guaranteed", .{key});
        }
        self.diagnose(.sjon, self.locate(r, form), "", "internal: required list key ':{s}' is missing after validation", .{key});
        return error.EmitError;
    }

    /// `requiredSymbol`'s sibling for a positional CHILD the schema's head-set
    /// floors at one (`(vertex …)` on a render-pipeline, `(source …)` on a copy).
    /// A `:min 1` head is as guaranteed as a required key, and reaching this means
    /// the head-set and the emitter disagree.
    fn requiredChild(self: *Emitter, r: *const Reader, form: NodeIndex, head: []const u8) Error!NodeIndex {
        std.debug.assert(head.len > 0);
        if (r.child(form, head)) |c| return c;
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            std.debug.panic("schema invariant broken: head `{s}` is not floored at 1 by its head-set", .{head});
        }
        self.diagnose(.sjon, self.locate(r, form), "", "internal: required ({s} …) sub-form is missing after validation", .{head});
        return error.EmitError;
    }

    /// The refusal for a cross-reference that resolves in the FOREST but has no
    /// id at this point in emission (05 §6).
    ///
    /// Not "unreachable by construction", which is why it is a message rather
    /// than an assert — it is `bundleRef`'s defect class, generalized. The
    /// validator resolves cross-refs document-wide, INCLUDING the forms
    /// `(pass …)`/`(init …)` lowering synthesizes; the emitter walks in a fixed
    /// phase order (see `phases`), so a form naming a resource interned in a
    /// later phase validates cleanly and misses here. Every one of these used to
    /// be a bare `return error.EmitError`, which the CLI prints as "emit failed"
    /// and nothing else: no form, no key, no line.
    /// `node` must be a FORM node (its head names the referencing form in the
    /// message); pass the owning form, not a vector element.
    fn unresolvedRef(self: *Emitter, r: *const Reader, node: NodeIndex, kind: []const u8, sym: []const u8) Error {
        std.debug.assert(kind.len > 0);
        std.debug.assert(r.tree.tagOf(node) == .form); // pre: a form, so `head` is meaningful
        self.diagnose(.sjon, self.locate(r, node), "", "({s} …) references {s} '{s}', which has no id at this point in emission — a form can only name resources declared in the source document, and the forms `(pass …)`/`(init …)` lowering synthesizes are emitted after most phases", .{ r.head(node), kind, sym });
        return error.EmitError;
    }

    /// `unresolvedRef` for the call sites that hold a NAME and no node — the
    /// `(wasm-call …)` write path, which is reached from a buffer's `:data` and
    /// carries the call's name only. Unlocated, but it still says what is missing.
    fn unresolvedRefUnlocated(self: *Emitter, kind: []const u8, sym: []const u8) Error {
        std.debug.assert(kind.len > 0);
        self.diagnose(.sjon, null, "", "references {s} '{s}', which has no id at this point in emission — a form can only name resources declared in the source document", .{ kind, sym });
        return error.EmitError;
    }

    /// The refusal for a referenced FILE the compiler could not read (05 §6). The
    /// path is the author's, so the message names it; the causes are ordinary
    /// (a typo, a moved asset, a `base_dir` that is not the document's directory,
    /// or a host with no IO at all — the browser compiler).
    fn unreadableFile(self: *Emitter, r: *const Reader, node: NodeIndex, path: []const u8, err: anyerror) Error {
        self.diagnose(.sjon, self.locate(r, node), "", "cannot read '{s}': {s} — the path is resolved against the document's directory (the cwd for piped source)", .{ path, @errorName(err) });
        return error.EmitError;
    }

    /// The single strict-validation diagnostic entry point. Formats `fmt`/`args`
    /// and (1) prints it to stderr for the CLI human — freestanding-guarded, the
    /// role the deleted `log*` helpers played (so `pngine compile`/`render`, which
    /// attach NO sink, still surface the message), and (2) routes a structured,
    /// optionally-located entry into the Diag sink when one IS attached (the
    /// editor squiggle channel + the first-writer `.message()` headline the WASM
    /// `error_buffer` reads). Every check that was `log*(…)` + `if (self.diag) |s|
    /// s.reportAt(…)` now calls this once. Printing is unconditional when reached,
    /// but every caller is `validate_shaders`-gated, so the golden/parity path
    /// (validation off, `diag == null`) never reaches it and stays silent. `loc ==
    /// null` → an UNLOCATED headline (a used-but-unbound binding has no SJON node).
    fn diagnose(
        self: *Emitter,
        domain: Diag.Domain,
        loc: ?Diag.Located,
        shader: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        comptime std.debug.assert(fmt.len > 0);
        if (loc) |l| std.debug.assert(l.line >= 1 and l.col >= 1);
        // stderr is the CLI human fallback ONLY when no sink owns rendering: a
        // sink-holder (validate.zig prints `diag.message()`; wasm_compiler reads
        // `error_buffer`) surfaces the message itself, so a stderr dump would
        // double-print (and pollute `validate --json`'s clean stdout). No-sink
        // `compile`/`render` still gets the message here. The freestanding guard
        // stays: stderr is absent there (std.debug.print would pull std.Io.Threaded);
        // the target check is comptime-known so the branch is pruned off-host.
        if (builtin.target.os.tag != .freestanding and self.diag == null)
            std.debug.print("\n" ++ fmt ++ "\n", args);
        if (self.diag) |sink| sink.reportAt(domain, loc, shader, fmt, args);
    }

    /// The advisory counterpart to `diagnose`: warning severity, never fails the
    /// compile, never claims the error headline. Same rendering split — stderr
    /// (with a `warning:` prefix) for the sink-less CLI human, the Diag sink's
    /// warning channel when one is attached (freestanding-guarded identically).
    /// Every caller is `validate_shaders`-gated, so the golden/parity path
    /// (validation off, `diag == null`) never reaches it and stays silent.
    fn diagnoseWarn(
        self: *Emitter,
        domain: Diag.Domain,
        loc: ?Diag.Located,
        shader: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        comptime std.debug.assert(fmt.len > 0);
        if (loc) |l| std.debug.assert(l.line >= 1 and l.col >= 1);
        if (builtin.target.os.tag != .freestanding and self.diag == null)
            std.debug.print("\nwarning: " ++ fmt ++ "\n", args);
        if (self.diag) |sink| sink.warnAt(domain, loc, shader, fmt, args);
    }

    /// Verify that an explicitly-declared pipeline stage entry point exists in its
    /// shader module's reflected set (gated on `validate_shaders`). Only explicit
    /// entries are checked — an omitted `:entry` is inferred from the module's
    /// sole entry for the stage (`inferStageEntry`, spec/09 C.3), which reflects
    /// it and so needs no membership check. Unknown module / no reflected entries
    /// → skip (never a false reject).
    fn checkStageEntry(self: *Emitter, r: *const Reader, section: NodeIndex) Error!void {
        if (!self.validate_shaders) return;
        const mname = r.symbol(section, "module") orelse return;
        const entry = r.symbol(section, "entry") orelse return; // explicit entries only
        try self.assertEntryExists(mname, entry, self.locate(r, r.authorNode(section, "entry") orelse section));
    }

    /// Shared membership check: `entry` must be in module `mname`'s reflected set
    /// (when one exists). Used by both render-stage and compute-pipeline checks;
    /// `loc` anchors the squiggle on the caller's `:entry` value (null → headline).
    fn assertEntryExists(self: *Emitter, mname: []const u8, entry: []const u8, loc: ?Diag.Located) Error!void {
        const set = self.tables.shader_entries.map.getPtr(mname) orelse return;
        if (set.count() == 0) return; // reflection found no entries → skip
        if (!set.contains(entry)) {
            // A declared pipeline stage referencing a missing entry point is a
            // WGSL-domain problem (the entry lives in the shader), so label it as
            // such rather than letting it read as a generic SJON reject.
            self.diagnose(.wgsl, loc, "", "entry point '{s}' not found in shader module '{s}'", .{ entry, mname });
            return error.ValidationError;
        }
    }

    /// WebGPU's rule for an ABSENT `GPUProgrammableStage.entryPoint`, verbatim:
    /// use the module's sole entry point for that stage, and make it an error
    /// when there is not exactly one.
    ///
    /// PNGine used to fabricate a name instead — `"vertexMain"`,
    /// `"fragmentMain"` and `"main"` here, plus `"vs_main"`/`"fs_main"` in
    /// gpu.js and `"vs"`/`"fs"` in mini.js: seven spellings across three layers,
    /// none of them a fact about the shader. A module whose entry was called
    /// anything else compiled clean, passed `validate`, produced an IDENTICAL
    /// MockGPU trace, and then aborted on a real GPU. Inferring from reflection
    /// is what turns that silent wrong render into a located diagnostic.
    ///
    /// UNGATED by `validate_shaders`: the resolved name is written into the
    /// artifact on every path (`analyzeModule` reflects unconditionally, for the
    /// uniform table), so `--no-validate` must not be a licence to emit a name
    /// that does not exist. The returned slice is borrowed from the module's
    /// reflection arena, which outlives the emit.
    fn inferStageEntry(
        self: *Emitter,
        mname: []const u8,
        stage: reflect.EntryPoint.Stage,
        loc: ?Diag.Located,
    ) Error![]const u8 {
        const stage_name = @tagName(stage);
        const rd = self.reflectionOf(mname) orelse {
            // No reflection (unknown/empty module, or an infra failure that has
            // already warned once). There is nothing to infer FROM, and guessing
            // is the bug — so say what is missing and what the author can do.
            self.diagnose(.wgsl, loc, mname, "shader module '{s}': cannot infer the {s} entry point because the module did not reflect — name it explicitly", .{ mname, stage_name });
            return error.ValidationError;
        };
        var sole: ?[]const u8 = null;
        var count: u32 = 0;
        for (rd.entry_points) |ep| {
            if (ep.stage != stage) continue;
            count += 1;
            if (sole == null) sole = ep.name;
        }
        if (count == 1) return sole.?;
        if (count == 0) {
            self.diagnose(.wgsl, loc, mname, "shader module '{s}' has no {s} entry point, so this stage cannot be created", .{ mname, stage_name });
        } else {
            self.diagnose(.wgsl, loc, mname, "shader module '{s}' declares {d} {s} entry points, so pngine cannot infer which one this stage uses — name it explicitly", .{ mname, count, stage_name });
        }
        return error.ValidationError;
    }

    /// A render stage's entry point: the explicit `:entry` symbol, else the
    /// module's sole entry for `stage` (`inferStageEntry`). Every site that needs
    /// a stage's entry goes through here, so the checks and the emitted
    /// descriptor cannot disagree about which entry the pipeline instantiates.
    fn resolveStageEntry(
        self: *Emitter,
        r: *const Reader,
        section: NodeIndex,
        stage: reflect.EntryPoint.Stage,
    ) Error![]const u8 {
        if (r.symbol(section, "entry")) |name| return name;
        const mname = try self.requiredSymbol(r, section, "module");
        return self.inferStageEntry(mname, stage, self.locate(r, section));
    }

    /// R1 Task 3, check ④: reject a compute entry whose reflected `@workgroup_size`
    /// exceeds WebGPU's limits (gated on `validate_shaders`). Reflects the module's
    /// stashed WGSL and matches the entry this pipeline actually uses (explicit
    /// `:entry`, or the module's sole compute entry). Only entries a pipeline instantiates are checked —
    /// mirroring WebGPU's own pipeline-creation validation timing, so an unused
    /// over-limit entry is never flagged. A reflection-infra failure or an unknown
    /// module/entry is non-fatal (never a false reject); the size check itself is
    /// the pure `workgroupSizeExceedsLimits`.
    fn checkWorkgroupSize(self: *Emitter, module: []const u8, entry: []const u8, loc: ?Diag.Located) Error!void {
        const rd = self.reflectionOf(module) orelse return;
        for (rd.entry_points) |ep| {
            if (ep.stage != .compute) continue;
            if (!std.mem.eql(u8, ep.name, entry)) continue;
            if (!ep.has_workgroup_size) return;
            if (uniforms.workgroupSizeExceedsLimits(ep.workgroup_size, self.wg_limits)) |reason| {
                self.diagnose(.wgsl, loc, "", "compute entry '{s}' @workgroup_size({d}, {d}, {d}) exceeds WebGPU limits ({s})", .{ entry, ep.workgroup_size[0], ep.workgroup_size[1], ep.workgroup_size[2], reason });
                return error.ValidationError;
            }
            return;
        }
    }

    /// CONST-01: reject a pipeline stage whose entry point reads a WGSL
    /// `override` that nothing can give a value (gated on `validate_shaders`).
    ///
    /// An `override` with no `= …` is supplied at pipeline creation through
    /// `GPUProgrammableStage.constants` — a channel pngine does not model. So a
    /// default-less override makes the pipeline UNCREATABLE in every runtime,
    /// and the author's only signal today is a device error in a browser
    /// console, on an artifact that compiled clean.
    ///
    /// Scoped to the resolved entry point, never the module: a module may
    /// declare an override only its *compute* entry reaches, and a render
    /// pipeline over that same module is unaffected and must not be refused.
    /// `EntryPoint.overrides` is the transitive list that makes this precise.
    /// An unknown module / unmatched entry is non-fatal (never a false reject).
    fn checkStageOverrides(self: *Emitter, module: []const u8, entry: []const u8, loc: ?Diag.Located) Error!void {
        if (!self.validate_shaders) return;
        const rd = self.reflectionOf(module) orelse return;
        if (rd.overrides.len == 0) return; // the overwhelming majority of modules
        for (rd.entry_points) |ep| {
            if (!std.mem.eql(u8, ep.name, entry)) continue;
            for (ep.overrides) |oname| {
                // A name with no matching declaration is a reflection gap, not
                // an authoring error — skip rather than invent a reject.
                const ov = rd.getOverride(oname) orelse continue;
                if (!ov.needsValue()) continue;
                self.diagnose(.wgsl, loc, "", "entry point '{s}' reads WGSL override '{s}', which declares no default — this pipeline cannot be created, and pngine has no way to supply a value", .{ entry, ov.name });
                return error.ValidationError;
            }
            return; // entry matched and cleared
        }
    }

    /// Render-stage adapter for `checkStageOverrides`: resolve the section's
    /// module and its entry (explicit, else the module's sole entry for the
    /// stage) the same way the JSON appenders do, so the check sees exactly the
    /// entry that ships.
    fn checkStageOverridesOf(self: *Emitter, r: *const Reader, section: NodeIndex, stage: reflect.EntryPoint.Stage) Error!void {
        const mname = r.symbol(section, "module") orelse return;
        const entry = try self.resolveStageEntry(r, section, stage);
        try self.checkStageOverrides(mname, entry, self.locate(r, section));
    }

    /// CONST-01: say why the `@workgroup_size` checks went quiet. An
    /// override-driven axis reflects as `0`, and `workgroupSizeExceedsLimits`
    /// tests upper bounds only — so the check runs, passes, and learns nothing.
    /// (`has_workgroup_size` stays SET here, so nothing skips on it; that is
    /// the easy misreading of this case.) Warning, not error: the pipeline is
    /// fine once the override has a value — only pngine's checks are blind.
    fn warnBlindWorkgroupSize(self: *Emitter, module: []const u8, entry: []const u8, loc: ?Diag.Located) void {
        if (!self.validate_shaders) return;
        const rd = self.reflectionOf(module) orelse return;
        for (rd.entry_points) |ep| {
            if (ep.stage != .compute) continue;
            if (!std.mem.eql(u8, ep.name, entry)) continue;
            if (ep.overrides.len == 0) return;
            const axis: ?u8 = for (ep.workgroup_size, 0..) |v, i| {
                if (v == 0) break @intCast(i);
            } else null;
            const a = axis orelse return; // no zero axis → the size is fully known
            // Name the override only when the entry reads exactly one, so the
            // name is unambiguously the cause. wgslender's per-entry list is
            // the UNION of workgroup-size operands and call-graph references
            // with no field separating them — picking `overrides[0]` would be
            // relying on an undocumented append order to guess. The axis
            // letter locates the cause on its own.
            if (ep.overrides.len == 1) {
                self.diagnoseWarn(.wgsl, loc, "", "compute entry '{s}': the @workgroup_size {c} axis is set by override '{s}', so the workgroup-size and device-limit checks were SKIPPED for this entry (the emit is unaffected)", .{ entry, "xyz"[a], ep.overrides[0] });
            } else {
                self.diagnoseWarn(.wgsl, loc, "", "compute entry '{s}': the @workgroup_size {c} axis is set by an override, so the workgroup-size and device-limit checks were SKIPPED for this entry (the emit is unaffected)", .{ entry, "xyz"[a] });
            }
            return;
        }
    }

    /// R1 Task 4: reject a vertex pipeline whose shader reads a `@location(n)`
    /// input that no declared vertex-buffer attribute provides (gated on
    /// `validate_shaders`). Reflects the vertex module, matches the entry this
    /// pipeline instantiates, and requires each `@location` input to appear in
    /// the layout's attributes — gathered across ALL vertex-buffer slots
    /// regardless of step-mode, so per-instance attributes count. Only
    /// `@location` inputs are required: `@builtin` inputs (vertex_index,
    /// instance_index, …) carry no vertex-buffer attribute, so a fully-procedural
    /// vertex shader with no `(vertex-buffer …)` is never flagged. Fragment/compute
    /// entries are skipped (their `@location` inputs are inter-stage, not
    /// buffer-fed). A reflection-infra failure or an unmatched entry is non-fatal
    /// (never a false reject). `vtx` is the pipeline's `(vertex …)` form.
    fn checkVertexAttributes(self: *Emitter, r: *const Reader, vtx: NodeIndex) Error!void {
        if (!self.validate_shaders) return;
        const mname = r.symbol(vtx, "module") orelse return;
        const entry = try self.resolveStageEntry(r, vtx, .vertex);
        const rd = self.reflectionOf(mname) orelse return;

        // Declared attributes across every vertex-buffer slot: each carries its
        // location, its `:format` string, and its node (for the located #5
        // diagnostic). Owned + freed here; an OOM while gathering bails the check
        // (never a false reject).
        const DeclaredAttr = struct { location: u32, format: []const u8, node: NodeIndex };
        var declared = std.ArrayList(DeclaredAttr).empty;
        defer declared.deinit(self.gpa);
        var vb_it = r.childrenWithHead(vtx, "vertex-buffer");
        while (vb_it.next()) |vb| {
            var attr_it = r.childrenWithHead(vb, "attribute");
            while (attr_it.next()) |attr| {
                const loc = (try self.optU32(r, attr, "shader-location")) orelse continue;
                declared.append(self.gpa, .{
                    .location = loc,
                    .format = r.symbol(attr, "format") orelse "",
                    .node = attr,
                }) catch return;
            }
        }

        for (rd.entry_points) |ep| {
            if (ep.stage != .vertex) continue;
            if (!std.mem.eql(u8, ep.name, entry)) continue;
            for (ep.inputs) |io| {
                // @builtin inputs have no vertex-buffer attribute; only @location
                // inputs must be provided by the declared layout.
                if (io.builtin.len != 0) continue;
                const need = io.location orelse continue;
                var match: ?DeclaredAttr = null;
                for (declared.items) |d| {
                    if (d.location == need) {
                        match = d;
                        break;
                    }
                }
                const da = match orelse {
                    self.diagnose(.wgsl, self.locate(r, vtx), "", "vertex entry '{s}' reads @location({d}) but no vertex-buffer attribute provides it", .{ entry, need });
                    return error.ValidationError;
                };
                // R4 Tier 2 (#5): the attribute EXISTS; does its `:format` scalar
                // class agree with the shader input's WGSL type? Skip when either
                // side is unclassifiable (a non-scalar shader type, a packed/unknown
                // format) — conservative, never a false reject. Only an unambiguous
                // cross-class disagreement (float ⟂ uint/sint, etc.) is flagged;
                // WebGPU rejects such a pairing at pipeline creation.
                const shader_class = type_agree.wgslScalarClass(io.typ) orelse continue;
                const fmt_class = type_agree.vertexFormatClass(da.format) orelse continue;
                if (shader_class.class != fmt_class.class) {
                    self.diagnose(.wgsl, self.locate(r, da.node), "", "vertex attribute @location({d}) declares a {s}-class :format '{s}' but the shader reads it as {s}", .{ need, type_agree.className(fmt_class.class), da.format, io.typ });
                    return error.ValidationError;
                }
            }
            return;
        }
    }

    /// R4 Tier 2 (#6): reject a fragment pipeline whose shader writes a color
    /// output that disagrees with the declared color targets (gated on
    /// `validate_shaders`). Two disagreements, both a black-screen class WebGPU
    /// rejects at pipeline creation:
    ///   (1) an `@location(n)` output with no color target at index `n` (the
    ///       pipeline declares fewer targets than the shader writes), and
    ///   (2) an output whose scalar class (float/sint/uint) differs from target
    ///       `n`'s `:format` class.
    /// Reflects the fragment module, matches the entry THIS pipeline instantiates
    /// (explicit `:entry`, or the module's sole fragment entry), and compares each
    /// `@location` output against the target at that position. Only `@location`
    /// outputs map to color targets — `@builtin` outputs (`frag_depth`,
    /// `sample_mask`) carry no target and are skipped. Conservative like every R1
    /// check: a reflect-infra failure, no matching fragment entry, an
    /// unclassifiable output type, or a depth/stencil/unknown target format → skip,
    /// never a false reject. `frag` is the pipeline's `(fragment …)` form.
    fn checkFragmentTargets(self: *Emitter, r: *const Reader, frag: NodeIndex) Error!void {
        if (!self.validate_shaders) return;
        const mname = r.symbol(frag, "module") orelse return;
        const entry = try self.resolveStageEntry(r, frag, .fragment);
        const rd = self.reflectionOf(mname) orelse return;

        // Declared color targets in author order: each carries its `:format` string
        // (required since spec/09 B; the `orelse` is a guard, not a default) and its
        // node (for the located #6 diagnostic). Owned + freed here; an OOM
        // while gathering bails the check (never a false reject).
        const DeclaredTarget = struct { format: []const u8, node: NodeIndex };
        var targets = std.ArrayList(DeclaredTarget).empty;
        defer targets.deinit(self.gpa);
        var t_it = r.childrenWithHead(frag, "target");
        while (t_it.next()) |t| {
            targets.append(self.gpa, .{
                .format = r.symbol(t, "format") orelse "preferred-canvas-format",
                .node = t,
            }) catch return;
        }

        // No declared color targets → the target set is IMPLICIT: the target list
        // isn't knowable at compile time, so SKIP the whole check (never a false
        // reject). Unreachable from a validated document since `fragment-section`
        // carries `(head :name target :min 1)`; kept because this is a check, and
        // a check that assumes its input has been checked is not one.
        if (targets.items.len == 0) return;

        for (rd.entry_points) |ep| {
            if (ep.stage != .fragment) continue;
            if (!std.mem.eql(u8, ep.name, entry)) continue;
            for (ep.outputs) |io| {
                // @builtin outputs (frag_depth, sample_mask) are not color targets.
                if (io.builtin.len != 0) continue;
                const loc = io.location orelse continue;
                // (1) Count: an output location beyond the declared targets can't be
                // written — WebGPU requires a target for every @location a fragment
                // emits. Anchor on the `(fragment …)` stage (there is no target node
                // to point at — the target is MISSING).
                if (loc >= targets.items.len) {
                    self.diagnose(.wgsl, self.locate(r, frag), "", "fragment entry '{s}' writes @location({d}) but the pipeline declares only {d} color target(s)", .{ entry, loc, targets.items.len });
                    return error.ValidationError;
                }
                // (2) Class agreement: skip when either side is unclassifiable (a
                // non-scalar output, a depth/stencil/unknown target format) —
                // conservative, never a false reject. Only an unambiguous
                // cross-class disagreement (a uint output to a float/unorm target,
                // etc.) is flagged; WebGPU rejects such a pairing.
                const out_class = type_agree.wgslScalarClass(io.typ) orelse continue;
                const target = targets.items[loc];
                const target_class = type_agree.colorTargetFormatClass(target.format) orelse continue;
                if (out_class.class != target_class) {
                    self.diagnose(.wgsl, self.locate(r, target.node), "", "fragment output @location({d}) writes {s} but color target {d} declares a {s}-class :format '{s}'", .{ loc, io.typ, loc, type_agree.className(target_class), target.format });
                    return error.ValidationError;
                }
            }
            return;
        }
    }

    /// C18 (05 §5) — the mappable-usage rule. WebGPU lets `MAP_READ` combine with
    /// `COPY_DST` and nothing else, and `MAP_WRITE` with `COPY_SRC` and nothing
    /// else: a mappable buffer is host memory the GPU may only copy in or out of,
    /// so binding one as `storage` (or as both mappable kinds at once) is a
    /// createBuffer validation error.
    ///
    /// Reads the AUTHORED vector, not the usage the emitter goes on to emit — a
    /// `:data` buffer gains `copy-dst` on its own, which is the legal companion
    /// anyway but is not something the author wrote.
    ///
    /// Not the schema's: `usage-list` is a vector of a member-set, so the schema
    /// says which symbols exist and cannot say which SUBSETS do.
    fn checkMappableUsage(self: *Emitter, r: *const Reader, form: NodeIndex, name: []const u8) Error!void {
        const elems = r.vectorNodes(form, "usage") orelse return;
        var map_read = false;
        var map_write = false;
        for (elems) |e| {
            const sym = r.elemSymbol(e) orelse continue;
            if (std.mem.eql(u8, sym, "map-read")) map_read = true;
            if (std.mem.eql(u8, sym, "map-write")) map_write = true;
        }
        if (!map_read and !map_write) return;
        if (map_read and map_write) {
            self.diagnose(.sjon, self.locate(r, form), "", "buffer '{s}' is :usage [map-read map-write] — WebGPU allows one mappable usage per buffer", .{name});
            return error.ValidationError;
        }
        const mappable: []const u8 = if (map_read) "map-read" else "map-write";
        const companion: []const u8 = if (map_read) "copy-dst" else "copy-src";
        for (elems) |e| {
            const sym = r.elemSymbol(e) orelse continue;
            if (std.mem.eql(u8, sym, mappable) or std.mem.eql(u8, sym, companion)) continue;
            self.diagnose(.sjon, self.locate(r, form), "", "buffer '{s}' is :usage [{s} … {s} …] — WebGPU allows {s} to combine with {s} and nothing else", .{ name, mappable, sym, mappable, companion });
            return error.ValidationError;
        }
    }

    /// PNGine fills a buffer's initial contents with `queue.writeBuffer`, and
    /// WebGPU requires the written size to be a multiple of 4 — the same rule the
    /// schema already spells on the offset side (`byte-count-4-aligned`).
    ///
    /// Not a plan row: it turned up writing C18's negatives. The length is never
    /// in the document, which is why only the emitter can check it — it comes
    /// from a `(wasm-data …)` export, from a shape generator's index companion
    /// (an ODD triangle count with uint16 indices lands here), or from a
    /// `(data …)` blob. A violation is a writeBuffer error in the browser and an
    /// abort natively, with nothing in the source to point at.
    fn checkWriteLength(self: *Emitter, r: *const Reader, form: NodeIndex, name: []const u8, len: u32, source: []const u8) Error!void {
        if (len % 4 == 0) return;
        self.diagnose(.sjon, self.locate(r, form), "", "buffer '{s}' is initialized from {s} with {d} bytes — WebGPU writes a buffer in multiples of 4", .{ name, source, len });
        return error.ValidationError;
    }

    fn emitBuffer(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const name = try self.requiredSymbol(r, form, "name");
        std.debug.assert(name.len > 0); // pre: named form (validator guarantees it)

        try self.checkMappableUsage(r, form, name);

        // usage bitfield from the symbol vector
        var usage: BufferUsage = .{};
        if (r.vectorNodes(form, "usage")) |elems| {
            for (elems) |e| values.applyUsage(&usage, r.elemSymbol(e) orelse "");
        }

        // `(buffer … :file "x.wasm")` (authored, or synthesized by `pngine/pass-v1`
        // for `(pass … :file …)`): size + initial bytes come from the WASM file's
        // data segment, not `:size`.
        if (r.string(form, "file")) |wasm_path| {
            return self.emitWasmDataBuffer(r, form, name, wasm_path, usage);
        }

        // `index-of S` sources size + initial bytes + index format from indexed
        // shape S's index companion (recorded by emitShapeData).
        const index_src: ?IndexData = if (r.symbol(form, "index-of")) |sname| self.tables.shape_index.get(sname) else null;

        const size = try self.resolveBufferSize(r, form, index_src);

        const mapped = r.symbol(form, "data");
        if (mapped != null or index_src != null) usage.copy_dst = true;

        try self.checkBufferSize(r, form, name, size, usage, mapped);
        if (index_src) |ix| try self.checkWriteLength(r, form, name, ix.byte_len, "its :index-of index data");
        if (mapped) |dname| {
            const written: u32 = if (self.tables.wasm_mesh_data.get(dname)) |w| w.byte_size else self.dataByteLen(dname);
            try self.checkWriteLength(r, form, name, written, "its :data source");
        }

        const reserved = try self.reservePool(r, form, &self.tables.buffers, name);
        const base = reserved.base;
        const pool_size = reserved.size;
        // Record {size, usage} at the BASE id so the R1 checks can join it from a
        // reflected binding's (group, binding) → base buffer id. Pool instances
        // share the base's size/usage; the reflection anchor is the base. `loc` (the
        // `(buffer …)` form's user span) anchors the address-space check's squiggle
        // (R2b; validate_shaders only — null on the golden/parity path).
        try self.binds.buffer_meta.put(self.gpa, base, .{ .size = size, .usage = usage, .loc = if (self.validate_shaders) self.locate(r, form) else null });

        for (0..pool_size) |i| {
            const buffer_id = base + @as(u16, @intCast(i));
            self.builder.getEmitter().createBuffer(self.gpa, buffer_id, size, usage) catch return error.OutOfMemory;
            try self.initBufferData(r, form, buffer_id, index_src, mapped);
        }
    }

    /// Resolve a buffer's byte size: an `index-of` shape's index byte length, or
    /// an author `:size` number/expression, or a bare `(data …)`/`(wasm-data …)` name's
    /// recorded byte length.
    ///
    /// GPUBufferDescriptor.size is REQUIRED and these (plus `:file`, handled by
    /// the caller) are the arms that fill it, so naming none of them is a
    /// diagnostic. It was already refused — as a bare `EmitError`, i.e. "emit
    /// failed" with no span, which tells the author everything except where to
    /// look (spec/09 C.4).
    fn resolveBufferSize(self: *Emitter, r: *const Reader, form: NodeIndex, index_src: ?IndexData) Error!u32 {
        std.debug.assert(r.tree.tagOf(form) == .form); // pre: called on a (buffer …) form
        if (index_src) |ix| return ix.byte_len;
        const size_node = r.authorNode(form, "size") orelse {
            // `:data` sizes the buffer it fills. This was `byte-size`'s data-ref
            // arm — `:size verts` beside `:data verts`, the same
            // data named twice in 39 documents (02 R6/R10). An explicit numeric
            // `:size` still wins, because over-allocating past the data is a real
            // thing to want and the author said so.
            if (r.symbol(form, "data")) |dname| return self.dataByteLen(dname);
            const bname = r.symbol(form, "name") orelse "";
            self.diagnose(.sjon, self.locate(r, form), "", "buffer '{s}' names no size: give it :size (bytes or an expression), or :data a (data …) entry, or :index-of an indexed shape, or :file a data WASM", .{bname});
            return error.ValidationError;
        };
        // A bare name in `:size` is a `(define …)` reference since 05 §2's R7 gave
        // `byte-count` the reference arm, and the validator has already checked
        // that it resolves. This arm used to read it as a `(data …)` name — safe
        // while the type made a symbol unreachable, and a silent zero-byte buffer
        // the moment it stopped being (`dataByteLen` answers 0 for a name it does
        // not know). The define wins; the data reading survives for the caller
        // the arm was kept for, a lowering hook synthesizing a buffer, whose
        // nodes no validator has seen.
        if (r.tree.tagOf(size_node) == .symbol) {
            const sym = r.tree.symbolText(size_node);
            if (self.env.lookup(sym) == null) return self.dataByteLen(sym);
        }
        // The same funnel every numeric slot uses (`refuseNumeric`): a `:size`
        // that does not fit u32 (`(* NUM NUM)` with an over-large define), goes
        // negative, or lands on a fraction squiggles the expression and says
        // which rule refused it.
        return values.evalNodeU32(self.gpa, r.tree, self.schema, &self.env, size_node) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => self.refuseNumeric(r, size_node, "size", e),
        };
    }

    /// Byte length of a `(data …)` entry: inline bytes (`data_byte_len`) or a
    /// static `(wasm-data …)` mesh generator (`wasm_mesh_data.byte_size`). Zero
    /// for a name neither table knows — the cross-ref validator has already
    /// rejected a dangling one, so this is the unreachable arm.
    fn dataByteLen(self: *Emitter, name: []const u8) u32 {
        std.debug.assert(name.len > 0);
        if (self.tables.data_byte_len.get(name)) |n| return n;
        if (self.tables.wasm_mesh_data.get(name)) |w| return w.byte_size;
        return 0;
    }

    /// Strict emit-time buffer checks (gated on validate_shaders; the parity/golden
    /// harnesses leave it off):
    ///  - a buffer mapped from a `(data …)` entry must be large enough to hold it
    ///    (the `buffer_too_small` negative; mirrors the legacy
    ///    resources.validateBufferDataSize warning+EmitError);
    ///  - a uniform buffer must be at least 16 bytes (the `unaligned_uniform`
    ///    negative — a 12-byte vec3f uniform can't satisfy WebGPU's 16-byte uniform
    ///    layout floor). A 16-byte *multiple* rule is deliberately NOT used: boids'
    ///    valid 28-byte all-f32 uniform (`(* 7 4)`) is not a multiple of 16, so the
    ///    floor catches the negative without that false positive.
    fn checkBufferSize(self: *Emitter, r: *const Reader, form: NodeIndex, name: []const u8, size: u32, usage: BufferUsage, mapped: ?[]const u8) Error!void {
        std.debug.assert(name.len > 0); // pre: named buffer (for the diagnostics)
        if (!self.validate_shaders) return;
        if (mapped) |dname| {
            if (self.tables.data_byte_len.get(dname)) |dlen| {
                if (size < dlen) {
                    self.diagnose(.sjon, self.locate(r, form), "", "buffer '{s}' size ({d} bytes) is smaller than data '{s}' ({d} bytes)", .{ name, size, dname, dlen });
                    return error.EmitError;
                }
            }
        }
        if (usage.uniform and size > 0 and size < 16) {
            self.diagnose(.sjon, self.locate(r, form), "", "uniform buffer '{s}' size ({d} bytes) is below WebGPU's 16-byte uniform floor", .{ name, size });
            return error.EmitError;
        }
    }

    /// Initialize one buffer instance: record its explicit `:index-format`, then
    /// write initial bytes from an `index-of` source, a static `(wasm-data …)`
    /// generator, or a `(data …)` blob (`:data`).
    fn initBufferData(self: *Emitter, r: *const Reader, form: NodeIndex, buffer_id: u16, index_src: ?IndexData, mapped: ?[]const u8) Error!void {
        std.debug.assert(buffer_id < self.tables.buffers.next); // pre: id already allocated
        // Explicit `:index-format` for buffers bound as :index-buffer without an
        // :index-of source (e.g. GPU-generated indices); set_index_buffer reads
        // the same map the :index-of path fills below.
        if (index_src == null) {
            if (r.symbol(form, "index-format")) |fmt|
                try self.tables.buffer_index_formats.put(self.gpa, buffer_id, values.mapIndexFormat(fmt));
        }
        if (index_src) |ix| {
            self.builder.getEmitter().writeBuffer(self.gpa, buffer_id, 0, ix.data_id) catch return error.OutOfMemory;
            try self.tables.buffer_index_formats.put(self.gpa, buffer_id, ix.format);
        } else if (mapped) |dname| {
            if (self.tables.wasm_mesh_data.get(dname)) |w| {
                // Static `(wasm-data …)`: generate the bytes at create time. Legacy
                // uses call_id=0 with a zero-arg encoding (`&.{0}`); the read pairs
                // to it by the same call_id (see resources.emitBufferInitialization).
                const em = self.builder.getEmitter();
                em.callWasmFunc(self.gpa, 0, w.module_id, w.func_name_id, &.{0}) catch return error.OutOfMemory;
                em.writeBufferFromWasm(self.gpa, 0, buffer_id, 0, w.byte_size) catch return error.OutOfMemory;
            } else {
                const did = self.tables.data.get(dname) orelse return self.unresolvedRef(r, form, "the (data …) blob", dname);
                self.builder.getEmitter().writeBuffer(self.gpa, buffer_id, 0, did) catch return error.OutOfMemory;
            }
        }
    }

    /// Emit a `(pass … :file …)` storage buffer filled from a WASM file (port of legacy
    /// `pass_sugar.loadDataWasm`): parse `l`/`s`/`gen`, embed the WASM bytes in the
    /// data section, create the buffer (size from the `l` export), then init the
    /// module + optionally call `gen()` + copy its memory into the buffer at
    /// runtime. The write reads from `module_id` (legacy reuses it as the call id;
    /// preserved for call-log parity). IO unavailable → emit error.
    fn emitWasmDataBuffer(self: *Emitter, r: *const Reader, form: NodeIndex, name: []const u8, wasm_path: []const u8, usage: BufferUsage) Error!void {
        std.debug.assert(name.len > 0);
        const wasm_bytes = self.readDataFile(wasm_path) catch |e| return self.unreadableFile(r, form, wasm_path, e);
        defer self.gpa.free(wasm_bytes);
        const info = wasm_data.parseWasmDataInfo(wasm_bytes) orelse {
            self.diagnose(.sjon, self.locate(r, form), "", "'{s}' is not a data WASM the compiler can read — it needs an exported `l` (byte length) and a data segment, and may export `gen`", .{wasm_path});
            return error.EmitError;
        };
        try self.checkWriteLength(r, form, name, info.byte_length, "its :file WASM `l` export");

        const wasm_data_id = self.builder.addData(self.gpa, wasm_bytes) catch return error.OutOfMemory;

        const buffer_id = try self.tables.buffers.intern(self.gpa, name);
        try self.binds.buffer_meta.put(self.gpa, buffer_id, .{ .size = info.byte_length, .usage = usage });
        const em = self.builder.getEmitter();
        em.createBuffer(self.gpa, buffer_id, info.byte_length, usage) catch return error.OutOfMemory;

        const module_id = try self.tables.wasm_modules.allocAnonymous();
        em.initWasmModule(self.gpa, module_id, wasm_data_id.toInt()) catch return error.OutOfMemory;

        if (info.has_gen) {
            const gen_name_id = self.builder.internString(self.gpa, "gen") catch return error.OutOfMemory;
            const gen_call_id = try self.tables.wasm_calls.allocAnonymous();
            em.callWasmFunc(self.gpa, gen_call_id, module_id, gen_name_id.toInt(), &.{0}) catch return error.OutOfMemory;
        }
        em.writeBufferFromWasm(self.gpa, module_id, buffer_id, info.start_offset, info.byte_length) catch return error.OutOfMemory;
    }

    /// Emit `init_wasm_module` for a `(wasm-call …)` declaration, deduped by `:file` path
    /// across calls (multiple calls may share one module). Records the call id + the
    /// source form so the frame-time write can read :func/:returns/:args. Runs in the
    /// legacy `wasm.emitWasmCalls` phase position (before shaders), so init_wasm_module
    /// is the first create-call in the log.
    fn emitWasmCallModule(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const name = try self.requiredSymbol(r, form, "name");
        _ = try self.tables.wasm_calls.intern(self.gpa, name);
        try self.tables.wasm_call_forms.put(self.gpa, name, form);

        // Check `:args` HERE, at the declaration, not only where the call is
        // inlined into a frame: a `(wasm-call …)` nothing references still has to
        // reject, and this runs before the `:file` read below so the diagnostic is
        // about the args rather than a missing file. The encode is pure — it reads
        // the form and fills a scratch buffer — so doing it twice is free of
        // consequence, and keeping ONE encoder means the check can't drift from
        // what actually gets written.
        var check_buf: [256]u8 = undefined;
        _ = try self.encodeWasmArgs(r, form, &check_buf);

        const url = try self.requiredString(r, form, "file");
        if (self.tables.wasm_modules.get(url)) |mid| {
            try self.tables.wasm_call_module_ids.put(self.gpa, name, mid);
            return;
        }
        // Registered under the file path, which is what the dedup above looks up.
        const module_id = try self.tables.wasm_modules.intern(self.gpa, url);
        const wasm_bytes = self.readDataFile(url) catch |e| return self.unreadableFile(r, form, url, e);
        defer self.gpa.free(wasm_bytes);
        const data_id = self.builder.addData(self.gpa, wasm_bytes) catch return error.OutOfMemory;
        self.builder.getEmitter().initWasmModule(self.gpa, module_id, data_id.toInt()) catch return error.OutOfMemory;
        try self.tables.wasm_call_module_ids.put(self.gpa, name, module_id);
    }

    /// Inline a `(write-buffer :data <call>)` whose `:data` names a (wasm-call …)
    /// into the current frame: call the WASM function, then write its
    /// `:returns`-many result bytes into the buffer.
    /// `call_id` ties the two opcodes together (the runtime caches the call result).
    /// Mirrors the legacy `wasm.emitWasmCallForBuffer`.
    fn emitWasmCallWrite(self: *Emitter, call_name: []const u8, buffer_id: u16, offset: u32) Error!void {
        const call_id = self.tables.wasm_calls.get(call_name) orelse return self.unresolvedRefUnlocated("(wasm-call …)", call_name);
        const module_id = self.tables.wasm_call_module_ids.get(call_name) orelse return self.unresolvedRefUnlocated("the WASM module of (wasm-call …)", call_name);
        const form = self.tables.wasm_call_forms.get(call_name) orelse return self.unresolvedRefUnlocated("the form of (wasm-call …)", call_name);
        const r = &self.src; // wasm-call lives in the source tree
        const func = try self.requiredSymbol(r, form, "func");
        const func_name_id = self.builder.internString(self.gpa, func) catch return error.OutOfMemory;
        const returns = try self.requiredString(r, form, "returns");
        const byte_len = opcodes.WasmReturnType.byteSize(returns) orelse {
            self.diagnose(.sjon, self.locate(r, form), "", "(wasm-call …) declares :returns '{s}', which is not a return type the wire can carry", .{returns});
            return error.EmitError;
        };
        var args_buf: [256]u8 = undefined;
        const args = try self.encodeWasmArgs(r, form, &args_buf);
        const em = self.builder.getEmitter();
        em.callWasmFunc(self.gpa, call_id, module_id, func_name_id.toInt(), args) catch return error.OutOfMemory;
        em.writeBufferFromWasm(self.gpa, call_id, buffer_id, offset, byte_len) catch return error.OutOfMemory;
    }

    /// Encode a `(wasm-call :args …)` vector to the runtime arg buffer:
    /// `[count:u8] ( [type:u8] [value:4]? )…`. Builtins (canvas-width / time-total / …)
    /// carry no value bytes — the runtime supplies them each frame; numeric literals
    /// carry 4 (u32 for integers, f32 otherwise). MockGPU does not record args, so the
    /// golden traces can't gate this; it is kept faithful for the real browser executor.
    ///
    /// Both rejects below are source errors the SCHEMA cannot catch: `wasm-arg` is
    /// an unconstrained `union [symbol number]` and `wasm-arg-list` an unbounded
    /// vector, so the validator passes anything shaped like a symbol or a number.
    fn encodeWasmArgs(self: *Emitter, r: *const Reader, form: NodeIndex, buf: *[256]u8) Error![]const u8 {
        const elems = r.vectorNodes(form, "args") orelse {
            buf[0] = 0;
            return buf[0..1];
        };
        // Over-cap is not a truncation to warn about — the count byte and the
        // wire schema's cap disagree, and every consumer resolves that
        // differently: the skipper and dispatcher walk 32 args and read the
        // surplus bytes as opcodes, the embedded executor walked all of them.
        // A 40-arg call compiled clean and panicked `pngine inspect` (§319).
        if (elems.len > MAX_WASM_ARGS) {
            self.diagnose(.sjon, self.locate(r, form), "", "wasm-call ':args' lists {d} arguments, but the call opcode carries at most {d} — the extra {d} cannot be encoded", .{ elems.len, MAX_WASM_ARGS, elems.len - MAX_WASM_ARGS });
            return error.ValidationError;
        }
        var off: usize = 1;
        var count: u8 = 0;
        for (elems) |e| {
            // Guaranteed by the cap above: MAX_WASM_ARGS args × 5 bytes + count.
            std.debug.assert(off + 5 <= buf.len);
            if (r.elemSymbol(e)) |sym| {
                // An unrecognised symbol used to encode as literal_f32 with four
                // zero bytes, so `:args [canvas-widht]` passed a silent 0.0 to
                // the WASM function forever. The schema's `wasm-arg-builtin`
                // member-set rejects the typo first (05 §4), which leaves this
                // arm meaning "the schema and `mapWasmArgType` disagree".
                const t = values.mapWasmArgType(sym) orelse {
                    self.diagnose(.sjon, self.locate(r, form), "", "internal: wasm-call ':args' builtin '{s}' passed validation but the emitter has no encoding for it", .{sym});
                    return error.ValidationError;
                };
                buf[off] = @intFromEnum(t);
                off += 1;
                count += 1;
                const vb = t.valueByteSize();
                if (vb > 0) {
                    @memset(buf[off .. off + vb], 0);
                    off += vb;
                }
            } else if (try self.elemF64Opt(r, e)) |num| {
                // A non-negative integer rides as u32; anything else (a fraction,
                // a negative) as f32 — `@intFromFloat` into u32 would trap on -1.
                const is_int = num >= 0 and num == @floor(num) and num <= @as(f64, std.math.maxInt(u32));
                const t: opcodes.WasmArgType = if (is_int) .literal_u32 else .literal_f32;
                buf[off] = @intFromEnum(t);
                off += 1;
                count += 1;
                if (is_int) {
                    const v: u32 = @intFromFloat(num);
                    @memcpy(buf[off .. off + 4], std.mem.asBytes(&v));
                } else {
                    const v: f32 = @floatCast(num);
                    @memcpy(buf[off .. off + 4], std.mem.asBytes(&v));
                }
                off += 4;
            } else {
                // Neither a symbol nor an evaluable number. The schema's
                // `wasm-arg` union admits only those two, so this is a broken
                // invariant rather than input — but dropping the element would
                // silently shorten the call's argument list, so it fails.
                std.debug.assert(false);
                self.diagnose(.sjon, self.locate(r, form), "", "internal: a (wasm-call …) :args element is neither a symbol nor an evaluable number after validation", .{});
                return error.EmitError;
            }
        }
        std.debug.assert(count == elems.len);
        buf[0] = count;
        return buf[0..off];
    }

    /// Read a WASM data file relative to `base_dir`. Freestanding-guarded — the
    /// in-browser compiler has no filesystem (data files are resolved before
    /// compile), so the IO path compiles out for wasm32.
    fn readDataFile(self: *Emitter, rel_path: []const u8) ![]u8 {
        if (comptime @import("builtin").os.tag == .freestanding) return error.FileReadError;
        std.debug.assert(rel_path.len > 0);
        const base = self.base_dir orelse return error.FileReadError;
        const io = self.io orelse return error.FileReadError;
        var path_buf: [512]u8 = undefined;
        const full = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base, rel_path });
        return std.Io.Dir.cwd().readFileAlloc(io, full, self.gpa, .limited(8 * 1024 * 1024));
    }

    /// Read shape vertex formats from a shape sub-form's `:format` list, defaulting
    /// per shape kind (indexed → pos3+normal3, else → pos4+color4+uv2) as the
    /// legacy emitter does. Returns a slice into `buf`.
    ///
    /// The two failure modes here look alike and are NOT:
    ///   * an unrecognised symbol is unreachable — `shape-format`'s member-set in
    ///     `schema/pngine.sjon` lists exactly the six names `Format.fromString`
    ///     accepts, so a typo'd `norml3` is a `not_member` reject that never
    ///     reaches emit. Assert; in release fall back to the old silent skip.
    ///     That "exactly" was a hand-maintained mirror across two files until
    ///     r2-07: `fromString` is now `stringToEnum` (domain == the tag set by
    ///     construction) and `schema_parity_test.zig` asserts the member-set and
    ///     the tag set are equal, so the assertion below rests on a gate rather
    ///     than on a promise. Break either side and that test fails, not this.
    ///   * the 8-slot cap IS reachable, because members may REPEAT — a 9-element
    ///     `:format` validates cleanly. Truncating in silence builds a short
    ///     vertex layout that surfaces only as garbage geometry, so warn with the
    ///     dropped count (gated like every other `diagnoseWarn` caller).
    fn readShapeFormats(self: *Emitter, r: *const Reader, shape_form: NodeIndex, shape: shapes.ShapeType, buf: *[8]shapes.Format) []const shapes.Format {
        var n: usize = 0;
        if (r.vectorNodes(shape_form, "format")) |elems| {
            for (elems) |e| {
                if (n >= buf.len) break;
                const sym = r.elemSymbol(e) orelse continue;
                if (shapes.Format.fromString(sym)) |fmt| {
                    buf[n] = fmt;
                    n += 1;
                } else std.debug.assert(false); // schema member-set guarantees this
            }
            if (elems.len > buf.len and self.validate_shaders) {
                self.diagnoseWarn(.sjon, self.locate(r, shape_form), "", "shape ':format' lists {d} attributes but the vertex layout holds at most {d} — the last {d} were dropped", .{ elems.len, buf.len, elems.len - buf.len });
            }
        }
        if (n == 0) {
            if (shape.isIndexed()) {
                buf[0] = .position3;
                buf[1] = .normal3;
                n = 2;
            } else {
                buf[0] = .position4;
                buf[1] = .color4;
                buf[2] = .uv2;
                n = 3;
            }
        }
        return buf[0..n];
    }

    /// Read optional shape generator config (segments/rings/radius/… ) off a shape
    /// sub-form and bounds-check it. Absent keys keep the `ShapeConfig` defaults.
    ///
    /// The bounds live here rather than in the schema because shape sub-forms are
    /// `:open true` (`schema/pngine.sjon`: generator-specific config is accepted
    /// without enumerating it per shape), so these keys carry no value-kind and
    /// no numeric bounds at all. That left the generators asserting author input
    /// — a panic in the CLI, and in the ReleaseSmall wasm compiler an assert
    /// compiled out, so `(sphere :segments 0)` walked into the math (LEAK-11 B).
    fn readShapeConfig(self: *Emitter, r: *const Reader, shape_form: NodeIndex, shape: shapes.ShapeType, config: *shapes.ShapeConfig) Error!void {
        try self.readShapeConfigKeys(r, shape_form, config);
        if (shapes.checkConfig(shape, config.*)) |v| {
            self.diagnose(.sjon, self.locate(r, shape_form), "", "({s} …) :{s} is {d}, outside the generatable range {d}..{d} — no mesh with that many subdivisions fits the {d}-index cap", .{ @tagName(shape), v.key, v.value, v.min, v.max, shapes.MAX_VERTICES });
            return error.ValidationError;
        }
    }

    fn readShapeConfigKeys(self: *Emitter, r: *const Reader, shape_form: NodeIndex, config: *shapes.ShapeConfig) Error!void {
        if (try self.optU32(r, shape_form, "segments")) |v| config.segments = v;
        if (try self.optU32(r, shape_form, "rings")) |v| config.rings = v;
        if (try self.optF64(r, shape_form, "radius")) |v| config.radius = @floatCast(v);
        if (try self.optF64(r, shape_form, "thickness")) |v| config.thickness = @floatCast(v);
        if (try self.optF64(r, shape_form, "bottom-radius")) |v| config.bottom_radius = @floatCast(v);
        if (try self.optF64(r, shape_form, "top-radius")) |v| config.top_radius = @floatCast(v);
        if (try self.optF64(r, shape_form, "height")) |v| config.cone_height = @floatCast(v);
        if (try self.optU32(r, shape_form, "radial-subdivisions")) |v| config.radial_subdivisions = v;
        if (try self.optU32(r, shape_form, "body-subdivisions")) |v| config.body_subdivisions = v;
        if (try self.optU32(r, shape_form, "vertical-subdivisions")) |v| config.vertical_subdivisions = v;
        if (r.boolean(shape_form, "top-cap")) |v| config.top_cap = v;
        if (r.boolean(shape_form, "bottom-cap")) |v| config.bottom_cap = v;
        if (r.boolean(shape_form, "faceted")) |v| config.faceted = v;
    }

    fn emitTexture(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const name = try self.requiredSymbol(r, form, "name");

        const format_str = r.symbol(form, "format") orelse "rgba8unorm";
        const tex_format = values.mapTextureFormat(format_str);
        var usage: values.TextureUsage = .{};
        if (r.vectorNodes(form, "usage")) |elems| {
            for (elems) |e| values.applyTextureUsage(&usage, r.elemSymbol(e) orelse "");
        }
        const sample_count_raw: ?u32 = try self.optU32(r, form, "sample-count");
        const sample_count: u32 = sample_count_raw orelse 1;

        // Extended GPUTextureDescriptor fields (all optional, default to the WebGPU
        // defaults so an untouched texture stays byte-identical). `:dimension` is
        // spelled `1d`/`2d`/`3d` (a symbol member-set since SJON 1.3, §366) and
        // lowered to the encoder's 0/1/2.
        const dimension: u8 = (try self.dimensionCode(r, form, "dimension", values.textureDimensionCode)) orelse 1;
        const mip_level_count: u32 = (try self.optBounded(r, form, "mip-level-count", .positive)) orelse 1;

        // `:size` is GPUTextureDescriptor.size, one required member with three
        // spellings (02 R5): an `[w h d]` extent, `canvas` for a canvas-tracking
        // descriptor, or an `(image-bitmap …)` to take the decoded image's size.
        // The schema requires it, so "names no size" is unreachable from a
        // validated document — it used to be 256×256 out of nowhere, which is how
        // examples/webgpu_shadow_mapping.sjon ended up sampling a 256² shadow map
        // with a PCF kernel written for 1024² (spec/09 C.4).
        //
        // depthOrArrayLayers rides the extent's third element instead of its own
        // key: it is one member of GPUExtent3D, and a dictionary's members are
        // spelled together (02 R4).
        var depth_or_array_layers: u32 = 1;
        const size: DescriptorEncoder.TextureSize = size_blk: {
            if (r.vectorNodes(form, "size")) |elems| {
                std.debug.assert(elems.len >= 1 and elems.len <= 3); // extent3 bounds
                // GPUExtent3DDict's own defaults fill the absent dimensions: height
                // 1, depthOrArrayLayers 1. Not pngine's guess — WebGPU's, which is
                // why they are spelled here rather than materialized by the schema.
                const width = try self.elemBounded(r, elems[0], 1, .positive);
                const height: u32 = if (elems.len > 1) try self.elemBounded(r, elems[1], 1, .positive) else 1;
                if (elems.len > 2) depth_or_array_layers = try self.elemBounded(r, elems[2], 1, .positive);
                break :size_blk .{ .explicit = .{ .width = width, .height = height } };
            }
            const size_name = r.symbol(form, "size") orelse {
                self.diagnose(.sjon, self.locate(r, form), "", "internal: texture '{s}' has no :size after validation — :size is required", .{name});
                return error.ValidationError;
            };
            if (std.mem.eql(u8, size_name, "canvas")) break :size_blk .canvas;
            // The bitmap id is embedded in the descriptor (created in the image-bitmap
            // phase, which runs before textures), so the raw descriptor compare ties
            // the two paths only when bitmap ids match (single bitmap → 0 == 0).
            const ib_id = self.tables.image_bitmaps.get(size_name) orelse return self.unresolvedRef(r, form, "image-bitmap", size_name);
            break :size_blk .{ .image_bitmap = ib_id };
        };
        try self.checkTextureShape(r, form, name, .{
            .sample_count = sample_count,
            .mip_level_count = mip_level_count,
            .layers = depth_or_array_layers,
            .dimension = dimension,
            .usage = usage,
        });

        const desc = DescriptorEncoder.encodeTextureOpts(self.gpa, .{
            .size = size,
            .format = tex_format,
            .usage = usage,
            .depth_or_array_layers = depth_or_array_layers,
            .dimension = dimension,
            .mip_level_count = mip_level_count,
            .sample_count = sample_count,
        }) catch return error.OutOfMemory;
        defer self.gpa.free(desc);
        const desc_id = self.builder.addData(self.gpa, desc) catch return error.OutOfMemory;

        const reserved = try self.reservePool(r, form, &self.tables.textures, name);
        const base = reserved.base;
        const pool_size = reserved.size;
        // Record {format, loc} at the BASE id so the R4 texture sample-class check
        // can join it from a reflected binding's (group, binding) → base texture id.
        // Pool instances share the base's descriptor (same format). `loc` (the
        // `(texture …)` form's user span) anchors the check's squiggle (R2b;
        // validate_shaders only — null on the golden/parity path).
        try self.binds.texture_meta.put(self.gpa, base, .{ .format = tex_format, .format_str = format_str, .sample_count = sample_count_raw, .usage = usage, .loc = if (self.validate_shaders) self.locate(r, form) else null });

        for (0..pool_size) |i| {
            const texture_id = base + @as(u16, @intCast(i));
            self.builder.getEmitter().createTexture(self.gpa, texture_id, desc_id.toInt()) catch return error.OutOfMemory;
        }
    }

    /// Emit an explicit `(texture-view …)`: encode its GPUTextureViewDescriptor and
    /// emit a create_texture_view over the source texture's BASE id. The view gets
    /// its own id (a separate space from texture ids); a `(entry :texture-view …)`
    /// binds it as resource_type explicit_texture_view.
    /// The descriptor facts `checkTextureShape` judges, already resolved by
    /// `emitTexture` (defaults applied, expressions evaluated). `dimension` is the
    /// encoder's code: 0 = 1d, 1 = 2d, 2 = 3d.
    const TextureShape = struct {
        sample_count: u32,
        mip_level_count: u32,
        layers: u32,
        dimension: u8,
        usage: values.TextureUsage,
    };

    /// C16 (05 §5) — what a texture's own descriptor has to agree with. Every rule
    /// here is one line of WebGPU's "validating GPUTextureDescriptor", and every
    /// one of them is a createTexture error the author currently meets as a blank
    /// canvas and a console line:
    ///
    /// - `sampleCount` is 1 or 4, and nothing else. The schema bounds the key as a
    ///   count, which cannot say "one of these two".
    /// - Above 1 it means multisampling, which is defined for a 2d texture with
    ///   one mip level and one layer, usable as an attachment and not as storage —
    ///   a storage write addresses a texel, and a multisampled texel is N samples.
    /// - The attachment usage itself needs a 2d or 3d texture: a render pass
    ///   rasterizes, and there is nothing to rasterize into along one axis.
    ///
    /// Left out deliberately: "the format must support multisampling", which needs
    /// the capability table rather than the format enum, and the extent-derived
    /// rules (a 1d texture's height, the mip-count ceiling), which are unknowable
    /// when `:size` is `canvas` or an `(image-bitmap …)`.
    fn checkTextureShape(self: *Emitter, r: *const Reader, form: NodeIndex, name: []const u8, shape: TextureShape) Error!void {
        const loc = self.locate(r, form);
        if (shape.sample_count != 1 and shape.sample_count != 4) {
            self.diagnose(.sjon, loc, "", "texture '{s}' sets :sample-count {d} — WebGPU takes 1 or 4 and nothing between", .{ name, shape.sample_count });
            return error.ValidationError;
        }
        if (shape.sample_count > 1) {
            if (shape.dimension != 1) {
                self.diagnose(.sjon, loc, "", "texture '{s}' sets :sample-count {d} on a {s} texture — multisampling is defined for 2d textures only", .{ name, shape.sample_count, if (shape.dimension == 0) "1d" else "3d" });
                return error.ValidationError;
            }
            if (shape.mip_level_count != 1) {
                self.diagnose(.sjon, loc, "", "texture '{s}' sets :sample-count {d} with :mip-level-count {d} — a multisampled texture has one level, because N samples per texel cannot be filtered down a mip chain", .{ name, shape.sample_count, shape.mip_level_count });
                return error.ValidationError;
            }
            if (shape.layers != 1) {
                self.diagnose(.sjon, loc, "", "texture '{s}' sets :sample-count {d} with {d} array layers — a multisampled texture has one", .{ name, shape.sample_count, shape.layers });
                return error.ValidationError;
            }
            if (shape.usage.storage_binding) {
                self.diagnose(.sjon, loc, "", "texture '{s}' is :sample-count {d} and storage-binding — a storage write addresses one texel, and a multisampled texel is {d} samples", .{ name, shape.sample_count, shape.sample_count });
                return error.ValidationError;
            }
            if (!shape.usage.render_attachment) {
                self.diagnose(.sjon, loc, "", "texture '{s}' is :sample-count {d} without render-attachment usage — multisampling happens during rasterization, so a multisampled texture has to be attachable", .{ name, shape.sample_count });
                return error.ValidationError;
            }
        }
        if (shape.usage.render_attachment and shape.dimension == 0) {
            self.diagnose(.sjon, loc, "", "texture '{s}' is :dimension 1d with render-attachment usage — a render pass rasterizes into a 2d or 3d target", .{name});
            return error.ValidationError;
        }
    }

    fn emitTextureView(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const name = try self.requiredSymbol(r, form, "name");
        const tex_name = try self.requiredSymbol(r, form, "texture");
        const texture_id = self.tables.textures.get(tex_name) orelse return self.unresolvedRef(r, form, "texture", tex_name);

        // `:aspect` maps all→0, stencil-only→1, depth-only→2. `:format` overrides the
        // view's texel format (default = the texture's own). Both encoded as enum bytes.
        const aspect: ?u8 = if (r.symbol(form, "aspect")) |a|
            (if (std.mem.eql(u8, a, "stencil-only")) @as(u8, 1) else if (std.mem.eql(u8, a, "depth-only")) @as(u8, 2) else @as(u8, 0))
        else
            null;
        const view_format: ?u8 = if (r.symbol(form, "format")) |f| @intFromEnum(values.mapTextureFormat(f)) else null;

        const desc = DescriptorEncoder.encodeTextureView(self.gpa, .{
            // `:dimension` — the IDL member (GPUTextureViewDescriptor.dimension);
            // the BGL resource forms below keep `:view-dimension`, theirs IS
            // `viewDimension` (audit 09 D19).
            .dimension = try self.dimensionCode(r, form, "dimension", values.viewDimensionCode),
            .aspect = aspect,
            .base_mip_level = (try self.optU32(r, form, "base-mip-level")) orelse 0,
            .mip_level_count = try self.optBounded(r, form, "mip-level-count", .positive),
            .base_array_layer = (try self.optU32(r, form, "base-array-layer")) orelse 0,
            .array_layer_count = try self.optBounded(r, form, "array-layer-count", .positive),
            .format = view_format,
        }) catch return error.OutOfMemory;
        defer self.gpa.free(desc);
        const desc_id = self.builder.addData(self.gpa, desc) catch return error.OutOfMemory;

        const view_id = try self.tables.texture_views.intern(self.gpa, name);
        self.builder.getEmitter().createTextureView(self.gpa, view_id, texture_id, desc_id.toInt()) catch return error.OutOfMemory;
    }

    fn emitSampler(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const name = try self.requiredSymbol(r, form, "name");
        try self.checkAnisotropyFilters(r, form, name);
        const compare: ?u8 = if (r.symbol(form, "compare")) |c| values.mapCompareFunction(c) else null;

        // Per-axis address modes: `:address-mode` is the all-three shorthand;
        // `:address-mode-u/v/w` override a single axis. U and V are always emitted
        // (default clamp-to-edge, as they were before this key set existed). W is
        // emitted only when explicitly addressed OR the shorthand is present — a
        // plain sampler omits it and the runtime defaults W to clamp, keeping the
        // old encoding byte-identical.
        const shorthand = r.symbol(form, "address-mode");
        const w_sym = r.symbol(form, "address-mode-w") orelse shorthand;
        const opts: DescriptorEncoder.SamplerOptions = .{
            .mag_filter = values.mapFilterMode(r.symbol(form, "mag-filter")),
            .min_filter = values.mapFilterMode(r.symbol(form, "min-filter")),
            .address_mode_u = values.mapAddressMode(r.symbol(form, "address-mode-u") orelse shorthand),
            .address_mode_v = values.mapAddressMode(r.symbol(form, "address-mode-v") orelse shorthand),
            .address_mode_w = if (w_sym) |s| values.mapAddressMode(s) else null,
            .mipmap_filter = if (r.symbol(form, "mipmap-filter")) |s| values.mapFilterMode(s) else null,
            .lod_min_clamp = if (try self.optF64(r, form, "lod-min-clamp")) |n| @floatCast(n) else null,
            .lod_max_clamp = if (try self.optF64(r, form, "lod-max-clamp")) |n| @floatCast(n) else null,
            .max_anisotropy = if (try self.optBounded(r, form, "max-anisotropy", .anisotropy)) |n| @intCast(n) else null,
            .compare = compare,
        };

        const desc = DescriptorEncoder.encodeSamplerOpts(self.gpa, opts) catch return error.OutOfMemory;
        defer self.gpa.free(desc);
        const desc_id = self.builder.addData(self.gpa, desc) catch return error.OutOfMemory;

        const sampler_id = try self.tables.samplers.intern(self.gpa, name);
        // Record {comparison, loc} so the R4 sampler check can join it from a
        // reflected binding's (group, binding) → sampler id. A `:compare` function
        // makes this a comparison sampler (the WGSL `sampler_comparison` shape).
        // `loc` (the `(sampler …)` form's user span) anchors the squiggle (R2b;
        // validate_shaders only — null on the golden/parity path).
        try self.binds.sampler_meta.put(self.gpa, sampler_id, .{ .comparison = r.symbol(form, "compare") != null, .loc = if (self.validate_shaders) self.locate(r, form) else null });
        self.builder.getEmitter().createSampler(self.gpa, sampler_id, desc_id.toInt()) catch return error.OutOfMemory;
    }

    /// Emits a JSON descriptor, not `DescriptorEncoder` TLV bytes. That is the
    /// rule, not an oversight: the render-pipeline dictionary is arrays of
    /// dictionaries of optional dictionaries (`vertex.buffers[].attributes[]`,
    /// `fragment.targets[].blend.{color,alpha}`, depthStencil, multisample),
    /// which a flat `[tag][field][value]` table cannot express — and gpu.js
    /// passes most of the parsed object to WebGPU verbatim. Flat descriptors
    /// (texture, sampler, bind-group entries, COMPUTE pipeline) go binary. The
    /// choice is frozen per opcode by docs/abi.md §6.1-6.5; see the full rule in
    /// descriptor_encoder.zig's header.
    fn emitRenderPipeline(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const name = try self.requiredSymbol(r, form, "name");
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.gpa);
        // One descriptor path for both hand-authored and pngine/pass-v1 pipelines:
        // the hook emits the canonical positional (vertex …)(fragment …) stages (§86
        // retired the legacy flat `:flat-module` shape).
        // Stage validation up front (gated on validate_shaders; a no-op on the
        // golden/parity path) so the appenders below are pure JSON emission. Vertex
        // checks before fragment — the same order the in-appender checks ran in.
        const vtx = try self.requiredChild(r, form, "vertex");
        // Not gated on validate_shaders: this one reads the document, not the
        // shaders, so it holds on every path the emitter has.
        try self.checkMultisample(r, form, name);
        try self.checkDepthStencilState(r, form, name);
        try self.checkStageEntry(r, vtx);
        try self.checkVertexAttributes(r, vtx);
        try self.checkStageOverridesOf(r, vtx, .vertex);
        if (r.child(form, "fragment")) |frag| {
            try self.checkBlendableTargets(r, frag, name);
            try self.checkStageEntry(r, frag);
            try self.checkFragmentTargets(r, frag);
            try self.checkStageOverridesOf(r, frag, .fragment);
        }

        try json.append(self.gpa, '{');
        // Explicit pipeline layout (superseding the auto-derived layout). Emitted
        // first so the appenders below (which lead with a comma-free "vertex":…)
        // remain a valid continuation. Absent → no key → auto-layout, byte-identical.
        if (pipelineLayoutName(r, form)) |pl_name| {
            const pl_id = self.tables.pipeline_layouts.get(pl_name) orelse return self.unresolvedRef(r, form, "pipeline-layout", pl_name);
            try json.appendSlice(self.gpa, "\"layoutId\":");
            try appendInt(self.gpa, &json, pl_id);
            try json.append(self.gpa, ',');
        }
        try self.appendVertexStage(&json, r, form);
        if (r.child(form, "fragment")) |_| try self.appendFragmentStage(&json, r, form);
        if (r.child(form, "primitive")) |prim| try self.appendPrimitive(&json, r, prim);
        if (r.child(form, "depth-stencil")) |ds| try self.appendDepthStencil(&json, r, ds);
        if (r.child(form, "multisample")) |ms| try self.appendMultisample(&json, r, ms);
        try json.append(self.gpa, '}');

        const data_id = self.builder.addData(self.gpa, json.items) catch return error.OutOfMemory;
        const pid = try self.tables.pipelines.intern(self.gpa, name);
        self.builder.getEmitter().createRenderPipeline(self.gpa, pid, data_id.toInt()) catch return error.OutOfMemory;
        // Per-pipeline uniform join: record (module → pid) for each stage.
        try self.recordStageModule(r, vtx, pid);
        if (r.child(form, "fragment")) |frag| try self.recordStageModule(r, frag, pid);
        // R5a: record this pipeline's attachment state for the render-pass join
        // (no-op with validation off — the golden/parity path never reads it).
        try self.recordRenderPipelineMeta(r, form, pid);
    }

    /// Record a render stage's (module → pipeline) instantiation row, the module
    /// name read the `stageShader` way. A stage with no resolvable module
    /// records nothing (the emitter's own resolution already errored or defaulted).
    fn recordStageModule(self: *Emitter, r: *const Reader, section: NodeIndex, pid: u16) Error!void {
        const mname = r.symbol(section, "module") orelse return;
        try self.recordModulePipeline(mname, pid);
    }

    /// Append one (module → pipeline) row, skipping an exact duplicate (a
    /// pipeline whose vertex and fragment stages share one module). Bounded
    /// linear scan — documents hold a handful of pipelines × stages.
    fn recordModulePipeline(self: *Emitter, module: []const u8, pid: u16) Error!void {
        std.debug.assert(module.len > 0);
        std.debug.assert(pid < self.tables.pipelines.next);
        for (self.binds.module_pipelines.items) |mp| {
            if (mp.pipeline == pid and std.mem.eql(u8, mp.module, module)) return;
        }
        try self.binds.module_pipelines.append(self.gpa, .{ .module = module, .pipeline = pid });
    }

    /// Record a render-pipeline's draw-time attachment state (color target formats,
    /// depth format presence/value, sample count) for the R5a render-pass ↔ pipeline
    /// agreement checks. Gated on `validate_shaders`; a re-walk of the just-emitted
    /// `(render-pipeline …)` form (precedent: `checkFragmentTargets`). Author
    /// spellings are borrowed from `r`'s tree (source OR lowered — both live for the
    /// whole emit). See `PipelineMeta` for the `targets_known` semantics.
    fn recordRenderPipelineMeta(self: *Emitter, r: *const Reader, form: NodeIndex, pid: u16) Error!void {
        if (!self.validate_shaders) return;
        var meta: PipelineMeta = .{};

        if (r.child(form, "fragment")) |frag| {
            var total: u16 = 0;
            var t_it = r.childrenWithHead(frag, "target");
            while (t_it.next()) |t| {
                // `:format` is required (spec/09 B); the `orelse` is a guard, not a default.
                const spelling = r.symbol(t, "format") orelse "preferred-canvas-format";
                if (meta.targets_len < meta.targets.len) {
                    meta.targets[meta.targets_len] = .{ .fmt = values.mapTextureFormat(spelling), .spelling = spelling };
                    meta.targets_len += 1;
                }
                total += 1;
            }
            meta.targets_total = total;
            // Zero targets is degenerate — treat as unknown (skip), never "the
            // pipeline writes zero color targets". `fragment-section`'s `:min 1`
            // means a validated document cannot get here.
            meta.targets_known = total > 0;
        } else {
            // No fragment stage → a depth-only pipeline (shadow map / depth pre-pass);
            // the color-target count is KNOWN to be zero.
            meta.targets_known = true;
            meta.targets_total = 0;
        }

        if (r.child(form, "depth-stencil")) |ds| {
            meta.ds_present = true;
            // `:format` is REQUIRED (GPUDepthStencilState.format, spec/09 C.1) —
            // the validator rejects its absence, so this is not the old
            // "omitted :format skips check #8b" path.
            const f = try self.requiredSymbol(r, ds, "format");
            meta.ds_format = values.mapTextureFormat(f);
            meta.ds_spelling = f;
        }

        if (r.child(form, "multisample")) |ms| {
            meta.ms_count = try self.optU32(r, ms, "count");
            meta.ms_stated = r.authorNode(ms, "count") != null;
        }

        if (r.child(form, "primitive")) |prim| {
            meta.topology = r.symbol(prim, "topology") orelse "";
            meta.strip_index_format = r.symbol(prim, "strip-index-format") != null;
        }

        try self.binds.pipeline_meta.put(self.gpa, pid, meta);
    }

    fn emitComputePipeline(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const name = try self.requiredSymbol(r, form, "name");
        // The stage is a `(compute …)` child, the same GPUProgrammableStage the
        // vertex and fragment stages carry (02 R2 / D10). `compute-pipeline-section`
        // requires exactly one, so its absence here is an internal error.
        const stage = try self.requiredChild(r, form, "compute");
        const module = try self.requiredSymbol(r, stage, "module");
        const shader_id = self.tables.shaders.get(module) orelse return self.unresolvedRef(r, form, "shader-module", module);
        // Explicit `:entry` must exist in the module; an omitted one resolves to
        // the module's SOLE compute entry, per WebGPU's rule for an absent
        // `GPUProgrammableStage.entryPoint` (`inferStageEntry`) — it used to
        // default to the literal "main", which is a guess, not a fact about the
        // shader. The workgroup-size limit check runs on the resolved entry this
        // pipeline actually instantiates.
        const entry = try self.resolveStageEntry(r, stage, .compute);
        if (self.validate_shaders) {
            // Squiggle the `:entry` value when explicit, else the stage form.
            const eloc = self.locate(r, r.authorNode(stage, "entry") orelse stage);
            if (r.symbol(stage, "entry")) |explicit| try self.assertEntryExists(module, explicit, eloc);
            try self.checkWorkgroupSize(module, entry, self.locate(r, form));
            try self.checkStageOverrides(module, entry, self.locate(r, form));
            self.warnBlindWorkgroupSize(module, entry, self.locate(r, form));
        }

        var blob: std.ArrayList(u8) = .empty;
        defer blob.deinit(self.gpa);
        try blob.append(self.gpa, 0x06); // DescriptorType.compute_pipeline
        try blob.append(self.gpa, @intCast(shader_id & 0xFF));
        try blob.append(self.gpa, @intCast((shader_id >> 8) & 0xFF));
        const entry_len: u8 = @intCast(@min(entry.len, 255));
        try blob.append(self.gpa, entry_len);
        try blob.appendSlice(self.gpa, entry[0..entry_len]);
        // Optional trailing u16 pipeline-layout id at offset 4+entry_len (the slot
        // gpu.js and native both probe past the entry point). Absent → the runtimes
        // read no id → auto-layout, and the blob is byte-identical to before.
        if (pipelineLayoutName(r, form)) |pl_name| {
            const pl_id = self.tables.pipeline_layouts.get(pl_name) orelse return self.unresolvedRef(r, form, "pipeline-layout", pl_name);
            try blob.append(self.gpa, @intCast(pl_id & 0xFF));
            try blob.append(self.gpa, @intCast((pl_id >> 8) & 0xFF));
        }

        const data_id = self.builder.addData(self.gpa, blob.items) catch return error.OutOfMemory;
        const pid = try self.tables.pipelines.intern(self.gpa, name);
        self.builder.getEmitter().createComputePipeline(self.gpa, pid, data_id.toInt()) catch return error.OutOfMemory;
        // Per-pipeline uniform join: record (module → pid) for the compute stage.
        try self.recordModulePipeline(module, pid);
    }

    /// Emit an explicit `(bind-group-layout :name … (entry …)…)` (uniform_access):
    /// build the legacy JSON descriptor `{"entries":[{"binding":N,"visibility":F,
    /// "buffer":{"type":"T"}}]}` (hand-rolled, like `emitRenderPipeline`'s), add it
    /// to the data section, and `createBindGroupLayout`. Recorded in
    /// `tables.bind_group_layouts` for a (bind-group … :layout …) to target.
    fn emitBindGroupLayout(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const name = try self.requiredSymbol(r, form, "name");

        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.gpa);
        try json.appendSlice(self.gpa, "{\"entries\":[");
        var first = true;
        var bgle_it = r.childrenWithHead(form, "entry");
        while (bgle_it.next()) |c| {
            // GPUBindGroupLayoutEntry: exactly one resource — the schema's
            // (`bgl-resource :min-children 1 :max-children 1`, SJON 1.4), so
            // every entry reaching here has exactly one. Two used to bind
            // whichever `appendBglEntry` tested first; none emitted `"buffer":{}`
            // — a fabricated uniform binding (the spec/09 bug class).
            if (!first) try json.append(self.gpa, ',');
            first = false;
            try self.appendBglEntry(&json, r, c);
        }
        try json.appendSlice(self.gpa, "]}");

        const data_id = self.builder.addData(self.gpa, json.items) catch return error.OutOfMemory;
        const layout_id = try self.tables.bind_group_layouts.intern(self.gpa, name);
        self.builder.getEmitter().createBindGroupLayout(self.gpa, layout_id, data_id.toInt()) catch return error.OutOfMemory;
    }

    /// `:dimension` / `:view-dimension`: absent → null; present → its encoder
    /// code. The members are spelled as WebGPU spells them (`2d`, `2d-array`,
    /// `cube`; SJON 1.3, §366), and a digit-leading spelling reaches the tree as
    /// a `number_with_unit`, so this reads through `Reader.memberSpelling`, not
    /// `symbol()`. A present value the mapper does not know is a schema/emitter
    /// desync — the validator accepted it — and is an internal error, never a
    /// silent default (spec/09's bug class).
    fn dimensionCode(
        self: *Emitter,
        r: *const Reader,
        form: NodeIndex,
        key: []const u8,
        comptime map: fn ([]const u8) ?u8,
    ) Error!?u8 {
        std.debug.assert(key.len > 0);
        const node = r.authorNode(form, key) orelse return null;
        var buf: [32]u8 = undefined;
        const spelling = r.memberSpelling(form, key, &buf) orelse "";
        const code = map(spelling) orelse {
            self.diagnose(.sjon, self.locate(r, node), "", "internal: :{s} value is not a member the emitter maps ({s})", .{ key, spelling });
            return error.EmitError;
        };
        std.debug.assert(code <= 5);
        return code;
    }

    /// Emit an explicit `(pipeline-layout :name … :bind-group-layouts [bgl0 …])`:
    /// resolve each referenced (bind-group-layout …) to its id and emit the JSON
    /// descriptor `{"bindGroupLayouts":[id0,id1,…]}` (the shape gpu.js's
    /// create_pipeline_layout and native's JSON parser both consume), then
    /// `createPipelineLayout`. Recorded in `tables.pipeline_layouts` for a
    /// (render-pipeline … :layout …) to embed as its `layoutId`.
    fn emitPipelineLayout(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const name = try self.requiredSymbol(r, form, "name");
        const elems = try self.requiredVector(r, form, "bind-group-layouts");

        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.gpa);
        try json.appendSlice(self.gpa, "{\"bindGroupLayouts\":[");
        for (elems, 0..) |e, i| {
            const bgl_name = r.elemSymbol(e) orelse {
                self.diagnose(.sjon, self.locate(r, form), "", "internal: :bind-group-layouts element {d} is not a symbol after validation", .{i});
                return error.EmitError;
            };
            const bgl_id = self.tables.bind_group_layouts.get(bgl_name) orelse return self.unresolvedRef(r, form, "bind-group-layout", bgl_name);
            if (i != 0) try json.append(self.gpa, ',');
            try appendInt(self.gpa, &json, bgl_id);
        }
        try json.appendSlice(self.gpa, "]}");

        const data_id = self.builder.addData(self.gpa, json.items) catch return error.OutOfMemory;
        const layout_id = try self.tables.pipeline_layouts.intern(self.gpa, name);
        self.builder.getEmitter().createPipelineLayout(self.gpa, layout_id, data_id.toInt()) catch return error.OutOfMemory;
    }

    /// Append one BGL entry `{"binding":N,"visibility":F,"buffer":{"type":"T"}}`,
    /// structurally the legacy `buildBGLEntryJson`. visibility is the OR of the
    /// `:visibility [vertex fragment …]` stage bits. All four resource kinds are
    /// modeled — `(buffer …)`, `(sampler …)`, `(texture …)`, `(storage-texture …)`
    /// — one JSON member each. The golden traces compare descriptors structurally,
    /// so key order is irrelevant.
    ///
    /// JSON while a bind GROUP is binary — the entries differ in shape, which is
    /// what decides: a bind-group entry is a fixed `[binding][type][id]` row, a
    /// LAYOUT entry is a dictionary with four mutually-exclusive optional
    /// sub-dictionaries. gpu.js hands this straight to createBindGroupLayout.
    /// See descriptor_encoder.zig's header; frozen by docs/abi.md.
    fn appendBglEntry(self: *Emitter, json: *std.ArrayList(u8), r: *const Reader, bgle: NodeIndex) Error!void {
        const binding: u32 = (try self.optU32(r, bgle, "binding")) orelse 0;
        var visibility: u8 = 0;
        if (r.vectorNodes(bgle, "visibility")) |elems| {
            for (elems) |e| visibility |= values.mapVisibility(r.elemSymbol(e) orelse "");
        }
        try json.appendSlice(self.gpa, "{\"binding\":");
        try appendInt(self.gpa, json, binding);
        try json.appendSlice(self.gpa, ",\"visibility\":");
        try appendInt(self.gpa, json, visibility);
        if (r.child(bgle, "buffer")) |bb| {
            try json.appendSlice(self.gpa, ",\"buffer\":{\"type\":\"");
            try json.appendSlice(self.gpa, values.mapBufferBindingType(r.symbol(bb, "type") orelse "uniform"));
            try json.appendSlice(self.gpa, "\"}");
        } else if (r.child(bgle, "sampler")) |sb| {
            try json.appendSlice(self.gpa, ",\"sampler\":{\"type\":\"");
            try json.appendSlice(self.gpa, values.mapSamplerBindingType(r.symbol(sb, "type") orelse "filtering"));
            try json.appendSlice(self.gpa, "\"}");
        } else if (r.child(bgle, "texture")) |tb| {
            try json.appendSlice(self.gpa, ",\"texture\":{\"sampleType\":\"");
            try json.appendSlice(self.gpa, values.mapTextureSampleType(r.symbol(tb, "sample-type") orelse "float"));
            try json.appendSlice(self.gpa, "\",\"viewDimension\":\"");
            try json.appendSlice(self.gpa, values.viewDimensionString((try self.dimensionCode(r, tb, "view-dimension", values.viewDimensionCode)) orelse 1));
            try json.appendSlice(self.gpa, "\",\"multisampled\":");
            try json.appendSlice(self.gpa, if (r.boolean(tb, "multisampled") orelse false) "true" else "false");
            try json.append(self.gpa, '}');
        } else if (r.child(bgle, "storage-texture")) |st| {
            try json.appendSlice(self.gpa, ",\"storageTexture\":{\"access\":\"");
            try json.appendSlice(self.gpa, values.mapStorageTextureAccess(r.symbol(st, "access") orelse "write-only"));
            try json.appendSlice(self.gpa, "\",\"format\":\"");
            // texture-format symbols ARE the WebGPU spellings → verbatim (default rgba8unorm).
            try json.appendSlice(self.gpa, r.symbol(st, "format") orelse "rgba8unorm");
            try json.appendSlice(self.gpa, "\",\"viewDimension\":\"");
            try json.appendSlice(self.gpa, values.viewDimensionString((try self.dimensionCode(r, st, "view-dimension", values.viewDimensionCode)) orelse 1));
            try json.appendSlice(self.gpa, "\"}");
        } else {
            // The schema's `bgl-resource :min-children 1` rejected the
            // resource-less entry before this ran; this used to emit
            // `"buffer":{}` — a uniform binding the author never wrote.
            self.diagnose(.sjon, self.locate(r, bgle), "", "internal: (entry …) has no resource sub-form after validation", .{});
            return error.EmitError;
        }
        try json.append(self.gpa, '}');
    }

    fn emitBindGroup(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const name = try self.requiredSymbol(r, form, "name");
        // `:layout` names ONE thing (02 R5): the pipeline whose auto-layout this
        // group targets, or an explicit (bind-group-layout …). Which one it is,
        // the emitter's own tables answer — `bind-group-layout-spec` is a target
        // GROUP, so the three forms share one namespace and the name resolves to
        // exactly one declaration by construction. Order is therefore free; the
        // pipeline table is tried first only because most groups name one.
        //
        // A pipeline-arm group additionally scopes its bindings to that pipeline
        // (scope_pid) for the per-pipeline uniform-table join; a bgl-arm group
        // has no pipeline scope (null → global join).
        //
        // The two tables are numbered independently from 0, so the bgl branch
        // TAGS its id (opcodes.BIND_GROUP_LAYOUT_TAG) — this is the only place
        // that still knows which space the author named. Untagged, the two
        // collide and every consumer downstream has to guess (journal §339).
        const layout_name = try self.requiredSymbol(r, form, "layout");
        var scope_pid: ?u16 = null;
        const layout_id = if (self.tables.pipelines.get(layout_name)) |pid| blk: {
            std.debug.assert(!opcodes.layoutIdIsBindGroupLayout(pid)); // pipeline ids never carry the tag
            scope_pid = pid;
            break :blk pid;
        } else if (self.tables.bind_group_layouts.get(layout_name)) |bglid|
            opcodes.tagBindGroupLayoutId(bglid)
        else
            return self.unresolvedRef(r, form, "as its :layout the pipeline or bind-group-layout", layout_name);
        const group_index: u8 = @intCast((try self.optBounded(r, form, "group", .byte)) orelse 0);
        // `:group` selects `pipeline.getBindGroupLayout(N)`, so it says nothing
        // in the bgl arm — the explicit layout IS the layout. A warning, not a
        // reject: the value is still encoded, so nothing about the artifact
        // changes, and the author is told the key is inert rather than left to
        // infer a layout choice from an index that never chose one.
        if (scope_pid == null and r.authorNode(form, "group") != null and group_index != 0) {
            self.diagnoseWarn(.sjon, self.locate(r, r.authorNode(form, "group") orelse form), "", "bind-group '{s}' names an explicit (bind-group-layout …) as its :layout, so :group {d} selects nothing — an index picks a @group out of a PIPELINE's layout, and an explicit layout is already the one being bound", .{ name, group_index });
        }

        var entry_nodes: std.ArrayList(NodeIndex) = .empty;
        defer entry_nodes.deinit(self.gpa);
        var be_it = r.childrenWithHead(form, "entry");
        while (be_it.next()) |c| try entry_nodes.append(self.gpa, c);

        // Harvest the (group, binding) → resource cross-validation side tables from
        // this group's entries — BEFORE emission, so populateUniformTable's R1/R4
        // joins (run at the end of run()) see them. Fires for source AND lowered
        // (`(pass …)`/`(init …)`) groups because it lives in this shared emit path.
        try self.harvestBindMetadata(r, entry_nodes.items, group_index, scope_pid);

        const reserved = try self.reservePool(r, form, &self.tables.bind_groups, name);
        const base = reserved.base;
        const pool_size = reserved.size;

        for (0..pool_size) |i| {
            const pool_idx: u8 = @intCast(i);
            const group_id = base + @as(u16, pool_idx);

            // Build the entry list (resolving ping-pong per pool instance) and let
            // the reused encoder produce the blob — byte-identical to the legacy path.
            var entries: std.ArrayList(DescriptorEncoder.BindGroupEntry) = .empty;
            defer entries.deinit(self.gpa);
            for (entry_nodes.items) |e| try entries.append(self.gpa, try self.bindGroupEntry(r, e, pool_idx));

            const blob = DescriptorEncoder.encodeBindGroupDescriptor(self.gpa, group_index, entries.items) catch return error.OutOfMemory;
            defer self.gpa.free(blob);
            const data_id = self.builder.addData(self.gpa, blob) catch return error.OutOfMemory;
            self.builder.getEmitter().createBindGroup(self.gpa, group_id, layout_id, data_id.toInt()) catch return error.OutOfMemory;
        }
    }

    /// Record the (group, binding) → BASE resource id side tables `emitBindGroup`
    /// needs for the end-of-run cross-validation joins (never emission): the
    /// SJON-declared resource kind (R1 ⑤), the texture/sampler ids (R4), and the
    /// base buffer id (R1 ①/②/③ — pre-ping-pong, the reflection anchor). Every
    /// slot reused across pipelines with a DIFFERENT kind/id marks its
    /// ambiguity set so the corresponding check skips the non-authoritative join.
    fn harvestBindMetadata(self: *Emitter, r: *const Reader, entry_nodes: []const NodeIndex, group_index: u8, scope_pid: ?u16) Error!void {
        for (entry_nodes) |e| {
            const eb: u8 = @intCast((try self.optBounded(r, e, "binding", .byte)) orelse 0);
            const bk = UniformBindingKey{ .group = group_index, .binding = eb };
            // Record the SJON-declared resource kind at this slot for the R1 bind
            // resource-kind check — EVERY entry (texture/sampler too), not just
            // buffers. Reuse of the slot with a DIFFERENT kind across pipelines
            // makes the global join ambiguous → the check skips it (same
            // non-authoritative-join caveat as the buffer-id ambiguity below).
            if (bindEntryKind(r, e)) |kind| {
                if (self.binds.bind_kinds.get(bk)) |prev| {
                    if (prev != kind) try self.binds.bind_kind_ambiguous.put(self.gpa, bk, {});
                }
                try self.binds.bind_kinds.put(self.gpa, bk, kind);
                // Record the (entry …) entry's user-source location for the bind-kind
                // check's squiggle (R2b; validate_shaders only — a lowered/`(pass …)` entry
                // has no user span, so `locate` returns null and it's simply skipped).
                if (self.validate_shaders) {
                    if (self.locate(r, e)) |loc| try self.binds.bind_kind_locs.put(self.gpa, bk, loc);
                }
            }
            // R4: record the texture/sampler id bound at this slot for the sample-
            // class / comparison checks (mirrors the uniform_bindings buffer join, but
            // for handle bindings). Textures/samplers are emitted before bind-groups
            // (the phase order), so the id lookups resolve. Slot reuse with a DIFFERENT
            // id across pipelines makes the global handle join non-authoritative → mark
            // ambiguous so the R4 checks skip it (the buffer-id ambiguity, for handles).
            if (r.symbol(e, "texture")) |tname| {
                if (self.tables.textures.get(tname)) |tid| {
                    if (self.binds.bind_texture_ids.get(bk)) |prev| {
                        if (prev != tid) try self.binds.bind_handle_ambiguous.put(self.gpa, bk, {});
                    }
                    try self.binds.bind_texture_ids.put(self.gpa, bk, tid);
                }
            } else if (r.symbol(e, "sampler")) |sname| {
                if (self.tables.samplers.get(sname)) |sid| {
                    if (self.binds.bind_sampler_ids.get(bk)) |prev| {
                        if (prev != sid) try self.binds.bind_handle_ambiguous.put(self.gpa, bk, {});
                    }
                    try self.binds.bind_sampler_ids.put(self.gpa, bk, sid);
                }
            }
            const bname = r.symbol(e, "buffer") orelse continue;
            const base_id = self.tables.buffers.get(bname) orelse continue;
            // Slot reuse across pipelines (a different buffer already recorded at
            // this (group, binding)) makes the global join ambiguous → the R1
            // buffer-specific checks skip it (see populateUniformTable).
            if (self.binds.uniform_bindings.get(bk)) |prev| {
                if (prev != base_id) try self.binds.uniform_binding_ambiguous.put(self.gpa, bk, {});
            }
            try self.binds.uniform_bindings.put(self.gpa, bk, base_id);
            // The scoped join side: a pipeline-layout group pins this slot's
            // buffer TO THAT PIPELINE (a group whose :layout is an explicit bgl records no row
            // and stays on the global-fallback join above).
            if (scope_pid) |pid| try self.recordScopedBinding(pid, bk, base_id);
        }
    }

    /// Append one (pipeline, group, binding) → buffer row, skipping an exact
    /// duplicate (two groups may legitimately re-declare the same bind).
    /// Bounded linear scan — documents hold a handful of bind entries.
    fn recordScopedBinding(self: *Emitter, pid: u16, bk: UniformBindingKey, buffer: u16) Error!void {
        std.debug.assert(pid < self.tables.pipelines.next);
        std.debug.assert(buffer < self.tables.buffers.next); // a BASE id from tables.buffers
        for (self.binds.scoped_bindings.items) |sb| {
            if (sb.pipeline == pid and sb.group == bk.group and sb.binding == bk.binding and sb.buffer == buffer) return;
        }
        try self.binds.scoped_bindings.append(self.gpa, .{ .pipeline = pid, .group = bk.group, .binding = bk.binding, .buffer = buffer });
    }

    /// Resolve one `(entry …)` entry to a BindGroupEntry, picking the present resource
    /// (buffer / sampler / texture) and applying the ping-pong offset for buffers.
    fn bindGroupEntry(self: *Emitter, r: *const Reader, entry: NodeIndex, pool_idx: u8) Error!DescriptorEncoder.BindGroupEntry {
        const binding: u8 = @intCast((try self.optBounded(r, entry, "binding", .byte)) orelse 0);
        // GPUBufferBinding.offset/size describe a buffer slice — reject them on
        // a sampler/texture entry rather than silently dropping them. Since
        // SJON 1.3 the schema says the same (`:offset`/`:size` carry
        // `:requires [buffer]` → `dependent_key_missing`), so this arm is an
        // internal guard for a validated document.
        if (r.symbol(entry, "buffer") == null and
            (r.authorNode(entry, "offset") != null or r.authorNode(entry, "size") != null))
        {
            self.diagnose(.sjon, self.locate(r, entry), "", "(entry …) :offset/:size are a buffer slice (GPUBufferBinding) and require :buffer", .{});
            return error.ValidationError;
        }
        if (r.symbol(entry, "buffer")) |bname| {
            const buf_base = self.tables.buffers.get(bname) orelse return self.unresolvedRef(r, entry, "buffer", bname);
            var resource_id = buf_base;
            if (try self.optU32(r, entry, "ping-pong")) |pp| {
                if (self.tables.buffers.pool(bname)) |bp| {
                    resource_id = poolResolve(bp.base, pp, pool_idx, bp.size);
                }
            }
            // GPUBufferBinding.offset/size — a buffer slice; 0/0 = whole buffer
            // (the wire's historical encoding, so unauthored entries stay
            // byte-identical).
            const offset = (try self.optU32(r, entry, "offset")) orelse 0;
            const size = (try self.optU32(r, entry, "size")) orelse 0;
            try self.checkBufferSlice(r, entry, bname, buf_base, offset, size);
            return .{ .binding = binding, .resource_type = .buffer, .resource_id = resource_id, .offset = offset, .size = size };
        }
        if (r.symbol(entry, "sampler")) |sname| {
            const sid = self.tables.samplers.get(sname) orelse return self.unresolvedRef(r, entry, "sampler", sname);
            return .{ .binding = binding, .resource_type = .sampler, .resource_id = sid };
        }
        if (r.symbol(entry, "texture")) |tname| {
            const tex_base = self.tables.textures.get(tname) orelse return self.unresolvedRef(r, entry, "texture", tname);
            var resource_id = tex_base;
            // Texture ping-pong: feedback reads the previous frame's output, a
            // pooled cross-pass dependency reads the partner this frame wrote.
            // Same `base + (pp + pool_idx) % size` rule as the buffer path.
            if (try self.optU32(r, entry, "ping-pong")) |pp| {
                if (self.tables.textures.pool(tname)) |tp| {
                    resource_id = poolResolve(tp.base, pp, pool_idx, tp.size);
                }
            }
            return .{ .binding = binding, .resource_type = .texture_view, .resource_id = resource_id };
        }
        if (r.symbol(entry, "texture-view")) |vname| {
            const vid = self.tables.texture_views.get(vname) orelse return self.unresolvedRef(r, entry, "texture-view", vname);
            return .{ .binding = binding, .resource_type = .explicit_texture_view, .resource_id = vid };
        }
        unreachable; // schema (exclusive-group … exactly-one) on be: one resource present
    }

    /// Author-time bounds for a `(entry …)` buffer slice. The declared buffer
    /// size is known at compile time (`buffer_meta`, recorded at the base id),
    /// so a slice past the end gets a located diagnostic here instead of a
    /// runtime GPUBufferBinding validation error (clean in the browser, but
    /// anonymous — and the compiler can name the form). Pool instances share
    /// the base's size, so the base-id join covers ping-pong entries too.
    fn checkBufferSlice(self: *Emitter, r: *const Reader, entry: NodeIndex, bname: []const u8, buf_base: u16, offset: u32, size: u32) Error!void {
        std.debug.assert(bname.len > 0); // pre: resolved cross-ref
        if (offset == 0 and size == 0) return; // whole buffer — the wire default
        std.debug.assert(offset != 0 or size != 0); // post the default early-out
        const meta = self.binds.buffer_meta.get(buf_base) orelse return;
        if (size == 0) {
            // Rest-of-buffer slice: empty when the offset is at or past the end.
            if (offset >= meta.size) {
                self.diagnose(.sjon, self.locate(r, entry), "", "(entry …) :offset {d} is at or past the end of buffer '{s}' ({d} bytes) — the rest-of-buffer slice is empty", .{ offset, bname, meta.size });
                return error.ValidationError;
            }
        } else if (@as(u64, offset) + size > meta.size) {
            self.diagnose(.sjon, self.locate(r, entry), "", "(entry …) :offset/:size slice ends at byte {d}, past the end of buffer '{s}' ({d} bytes)", .{ @as(u64, offset) + size, bname, meta.size });
            return error.ValidationError;
        }
    }

    /// Populate the PNGB uniform table from WGSL reflection so the runtime can
    /// `setUniform(name, value)` by field name (and `--types` can emit a real
    /// interface). For each stashed shader module: reflect its WGSL, and for every
    /// uniform/storage binding, join it to the buffer recorded for its
    /// `(group, binding)` in `emitBindGroup`. Fields are flattened (nested structs →
    /// dot-notation paths), sorted by name for stable slot indices, interned, and
    /// handed to the unchanged `builder.addUniformBinding`.
    ///
    /// Runs UNCONDITIONALLY (not gated on `validate_shaders`): the golden/parity
    /// harnesses leave validation off, yet the table must populate there too. Costs
    /// at most one extra reflect per shader module.
    /// Complexity: O(shaders × bindings × fields × log fields).
    fn populateUniformTable(self: *Emitter) Error!void {
        // Dedup by RESOLVED BUFFER + flattened shape: several modules binding
        // the same buffer with the same struct emit ONE record, while one slot
        // reused for DIFFERENT buffers across pipelines emits one record PER
        // buffer. (Previously keyed by (group, binding) — the first module
        // claimed the slot and every later module's binding there was silently
        // dropped, but under :layout auto a slot is per-pipeline, not
        // doc-global; §256.)
        var emitted: std.AutoHashMapUnmanaged(u16, EmittedShape) = .empty;
        defer emitted.deinit(self.gpa);
        // Doc-wide leaf-name → first-owner map for the setUniform-ambiguity
        // warning (gpu.js keys uniforms by BARE field name). Keys are gpa-owned
        // dupes (flattened paths die per binding); written only under
        // validate_shaders, so the golden/parity path pays nothing.
        var owners: FieldOwners = .empty;
        defer freeFieldOwners(self.gpa, &owners);

        // Walk modules in EMIT order (shader_order), not shader_analysis's hash
        // order — table order and buffer attribution are deterministic.
        std.debug.assert(self.tables.shader_order.items.len >= self.tables.shader_analysis.map.count());
        for (self.tables.shader_order.items) |ref| {
            // The reflection built at emit time, not a fresh one. A null here is
            // a reflect-infra failure already warned at `analyzeModule`: the
            // module contributes NOTHING to the uniform table, so setUniform
            // cannot target its fields and `--types` omits them.
            const rd = self.reflectionOf(ref.name) orelse continue;

            for (rd.bindings) |binding| try self.joinBinding(&emitted, &owners, ref, rd, binding);
        }
    }

    /// Join ONE reflected binding to the resources bound at its (group, binding):
    /// run the gated R1/R4 agreement checks, then emit its uniform-table records.
    ///
    /// Split out of `populateUniformTable` so that function is just the
    /// module→reflection loop. Every early `return` here is the per-binding
    /// `continue` it replaced — this runs once per binding and owns no state
    /// beyond the two caller-owned maps it threads through.
    fn joinBinding(
        self: *Emitter,
        emitted: *std.AutoHashMapUnmanaged(u16, EmittedShape),
        owners: *FieldOwners,
        ref: ShaderRef,
        rd: *const reflect.ReflectionData,
        binding: reflect.Binding,
    ) Error!void {
        // Group sanity FIRST — applies to ALL bindings, incl. the handle
        // (texture/sampler) ones the bind-kind check must see. A valid-but-
        // unusual @group(N>3) must not trip addBinding's `group <= 3` assert
        // (WebGPU caps groups at 4 anyway) and keeps the u8 key valid.
        if (binding.group > 3) return;
        // @binding(N>255) is valid WGSL but past the wire's u8 — and
        // unbindable anyway (the schema caps `:binding` at 255). Skip
        // rather than @intCast-panic, but say so: this is a PNGine cap,
        // not a WebGPU one, and the R1 checks never see the slot.
        if (binding.binding > std.math.maxInt(u8)) {
            if (self.validate_shaders) {
                self.diagnoseWarn(.wgsl, null, "", "binding '{s}' (@group({d}) @binding({d})): binding index is beyond PNGine's wire cap (255) — no (entry …) can bind it, and it is ignored", .{ binding.name, binding.group, binding.binding });
            }
            return;
        }
        const key = UniformBindingKey{ .group = @intCast(binding.group), .binding = @intCast(binding.binding) };

        // R1 ⑤ (bind resource-kind) + R4 (handle typed-descriptor) agreement
        // — both gated, and run BEFORE the buffer filter below so texture/
        // sampler slots are validated too (they'd otherwise be dropped).
        try self.checkHandleAgreement(binding, key);

        // Only buffer-backed uniform/storage bindings carry a setUniform story.
        if (binding.address_space != .uniform and binding.address_space != .storage) return;

        // Per-pipeline join: which buffers is THIS module's slot bound
        // to, across the pipelines that instantiate it? No candidate →
        // the preserved R1 ② used-but-unbound check, else a benign skip.
        const cands = self.candidateBuffersFor(ref.name, key);
        if (cands.len == 0) return try self.checkUnboundBinding(rd, binding);
        // Collision (a): ONE module's slot fanning out to ≥2 buffers
        // across its pipelines. Every record still emits (below) —
        // setUniform reaches each buffer via its own record — but the
        // fan-out is usually a copy-paste slot clash worth seeing.
        if (self.validate_shaders and cands.len >= 2) {
            self.diagnoseWarn(.wgsl, self.binds.bind_kind_locs.get(key), "", "binding '{s}' (@group({d}) @binding({d})) in module '{s}' is bound to {d} different buffers across its pipelines", .{ binding.name, binding.group, binding.binding, ref.name, cands.len });
        }

        // Flatten ONCE per module binding — the shape is buffer-independent.
        var flattened: std.ArrayList(FlattenedField) = .empty;
        defer uniforms.freeFlattenedFields(self.gpa, &flattened);
        if (!self.flattenBinding(rd, binding, &flattened)) return;

        try self.emitCandidates(emitted, owners, ref, binding, key, cands, flattened.items);
    }

    /// Emit one table record per candidate buffer for a flattened binding,
    /// deduping by (buffer, shape hash) and reporting the two gated collision
    /// warnings: (b) one buffer bound with DISAGREEING shapes by two modules
    /// (both records emit — consumers key by field name, but the disagreement
    /// usually means two structs drifted apart), and — via `noteFieldOwners` —
    /// (c) one leaf name living in two different buffers.
    fn emitCandidates(
        self: *Emitter,
        emitted: *std.AutoHashMapUnmanaged(u16, EmittedShape),
        owners: *FieldOwners,
        ref: ShaderRef,
        binding: reflect.Binding,
        key: UniformBindingKey,
        cands: Candidates,
        flattened: []const FlattenedField,
    ) Error!void {
        std.debug.assert(cands.len > 0);
        std.debug.assert(flattened.len > 0);
        const shape_hash = uniforms.shapeHashOf(flattened);
        for (cands.ids[0..cands.len]) |buffer_id| {
            // Buffer-side R1 checks (③ address space, ① size) — a scoped
            // resolution is authoritative, so they run where the old global
            // join had to skip as ambiguous.
            try self.checkBufferBinding(binding, key, buffer_id, cands.scoped);
            if (emitted.get(buffer_id)) |prev| {
                if (prev.shape_hash == shape_hash) continue; // same buffer, same shape → one record
                if (self.validate_shaders) {
                    self.diagnoseWarn(.wgsl, null, ref.name, "buffer '{s}' is bound with different struct shapes by modules '{s}' and '{s}' (@group({d}) @binding({d})) — both field maps are listed", .{ self.bufferNameOf(buffer_id), prev.module, ref.name, binding.group, binding.binding });
                }
            }
            // Bound the binding count below addBinding's MAX_BINDINGS assert.
            if (self.builder.getUniformTable().bindings.items.len >= uniform_table.MAX_BINDINGS) return;
            if (try self.emitRecord(binding, buffer_id, flattened)) {
                // `try`, not `catch {}`: this IS the dedup record. Dropping it on
                // OOM does not lose a diagnostic, it silently changes the OUTPUT —
                // the next module binding this same buffer with this same shape
                // finds no `prev`, skips the `continue` above, and emits a second
                // record for one buffer. Fail the compile instead.
                try emitted.put(self.gpa, buffer_id, .{ .shape_hash = shape_hash, .module = ref.name });
                if (self.validate_shaders) try self.noteFieldOwners(owners, flattened, buffer_id, ref);
            }
        }
    }

    /// Record each leaf path's FIRST owning buffer and warn on a cross-buffer
    /// duplicate: gpu.js's setUniform keys by bare field name doc-wide, so the
    /// same name in two buffers is runtime-ambiguous (the last-parsed record
    /// wins). Two LOWERED modules colliding are exempt — the `(pass …)` prelude
    /// gives every pass module identical field names (time, width, …) by
    /// construction. A same-module fan-out already warned as collision (a).
    fn noteFieldOwners(self: *Emitter, owners: *FieldOwners, flattened: []const FlattenedField, buffer_id: u16, ref: ShaderRef) Error!void {
        std.debug.assert(self.validate_shaders);
        std.debug.assert(flattened.len > 0);
        for (flattened) |f| {
            if (owners.get(f.path)) |prev| {
                if (prev.buffer != buffer_id and !std.mem.eql(u8, prev.module, ref.name) and !(prev.lowered and ref.lowered)) {
                    self.diagnoseWarn(.wgsl, null, ref.name, "setUniform(\"{s}\") is ambiguous — the field exists in buffer '{s}' (module '{s}') and buffer '{s}' (module '{s}'); the last-parsed binding wins", .{ f.path, self.bufferNameOf(prev.buffer), prev.module, self.bufferNameOf(buffer_id), ref.name });
                }
                continue; // first owner kept — one warning per later collision
            }
            // OOM propagates (a `catch continue` here silently dropped the
            // owner and with it the ambiguity warning); the map owns the key.
            const key = try self.gpa.dupe(u8, f.path);
            errdefer self.gpa.free(key);
            try owners.put(self.gpa, key, .{ .buffer = buffer_id, .module = ref.name, .lowered = ref.lowered });
        }
    }

    /// Reverse-map a BASE buffer id to its SJON name (bounded scan over the
    /// registry; warning messages only — off every hot path).
    fn bufferNameOf(self: *const Emitter, id: u16) []const u8 {
        return self.tables.buffers.nameOf(id) orelse "?";
    }

    /// The distinct BASE buffer ids bound at `key` across every pipeline that
    /// instantiates `module_name` — the per-pipeline join (`module_pipelines` ×
    /// `scoped_bindings`). Falls back to the global `uniform_bindings` map when
    /// no scoped row matches: a module bound only via explicit-bgl `:layout`
    /// groups, or referenced by no pipeline (`scoped=false` marks the fallback —
    /// its buffer is authoritative only when the slot isn't ambiguous). Pure
    /// bounded scans; both-miss returns len 0 (≡ the old global-miss, since
    /// every scoped row also writes the global map).
    fn candidateBuffersFor(self: *const Emitter, module_name: []const u8, key: UniformBindingKey) Candidates {
        std.debug.assert(module_name.len > 0);
        std.debug.assert(key.group <= 3);
        var c = Candidates{};
        for (self.binds.module_pipelines.items) |mp| {
            if (!std.mem.eql(u8, mp.module, module_name)) continue;
            for (self.binds.scoped_bindings.items) |sb| {
                if (sb.pipeline != mp.pipeline or sb.group != key.group or sb.binding != key.binding) continue;
                c.add(sb.buffer);
            }
        }
        if (c.len > 0) {
            c.scoped = true;
            return c;
        }
        if (self.binds.uniform_bindings.get(key)) |global| c.add(global);
        return c;
    }

    /// R1 check ②: a uniform/storage binding the shader actually USES but the
    /// SJON never bound (no scoped row AND no global entry) → a runtime black
    /// screen on whoever later loads the PNG. Filtered by the reflected
    /// per-entry resources[] usage list, so a declared-but-unused binding under
    /// :layout auto is never a false positive. Gated: the default path keeps
    /// the lenient silent skip.
    fn checkUnboundBinding(self: *Emitter, rd: *const reflect.ReflectionData, binding: reflect.Binding) Error!void {
        if (!self.validate_shaders) return;
        if (!uniforms.bindingUsedByAnyEntry(rd, binding.name)) return;
        // Intentionally UNLOCATED: the binding is USED by the shader but never
        // written in SJON, so there is no `(entry …)` node to squiggle — it
        // surfaces as a headline (the fix is to add the missing bind).
        self.diagnose(.wgsl, null, "", "binding '{s}' (@group({d}) @binding({d})) is used by the shader but never bound in SJON", .{ binding.name, binding.group, binding.binding });
        return error.ValidationError;
    }

    /// R1 Task 3 check ⑤ (bind resource-kind agreement) + R4 Tier 2 (typed
    /// descriptor agreement for HANDLE bindings). Both gated on validate_shaders and
    /// run BEFORE populateUniformTable's uniform/storage filter, so texture/sampler
    /// mismatches are caught (they'd otherwise be skipped as non-buffer). Each skips
    /// a kind-/handle-ambiguous slot (a (group, binding) bound to several kinds/ids
    /// across pipelines — the global join isn't authoritative there). The R4
    /// comparators are conservative: an unknown/depth/storage class returns false →
    /// the check silently skips, never a false reject.
    fn checkHandleAgreement(self: *Emitter, binding: reflect.Binding, key: UniformBindingKey) Error!void {
        if (self.validate_shaders and !self.binds.bind_kind_ambiguous.contains(key)) {
            if (self.binds.bind_kinds.get(key)) |sjon_kind| {
                if (uniforms.reflectedKindMismatch(binding.resource, sjon_kind)) {
                    self.diagnose(.wgsl, self.binds.bind_kind_locs.get(key), "", "binding '{s}' (@group({d}) @binding({d})) is bound as a {s} in SJON but the shader declares a {s}", .{ binding.name, binding.group, binding.binding, @tagName(sjon_kind), uniforms.reflectedKindName(binding.resource) });
                    return error.ValidationError;
                }
            }
        }

        // R4 runs after the bind-kind check (so the shape already agrees — a .texture
        // reflected here is bound as a texture in SJON) and before the buffer-only
        // filter (handle bindings have the .handle address space, which that drops).
        if (self.validate_shaders and !self.binds.bind_kind_ambiguous.contains(key) and !self.binds.bind_handle_ambiguous.contains(key)) {
            switch (binding.resource) {
                .texture => |tex| if (self.binds.bind_texture_ids.get(key)) |tid| {
                    if (self.binds.texture_meta.get(tid)) |meta| {
                        if (type_agree.textureSampleClassMismatch(tex, meta.format)) {
                            const shader_class = type_agree.textureSampleClass(tex).?;
                            const declared_class = type_agree.textureFormatClass(meta.format).?;
                            self.diagnose(.wgsl, meta.loc, "", "texture '{s}' (@group({d}) @binding({d})) has a {s}-class :format but the shader samples it as {s}", .{ binding.name, binding.group, binding.binding, type_agree.className(declared_class), type_agree.className(shader_class) });
                            return error.ValidationError;
                        }
                        // R5b (#10): storage textures need EXACT format equality
                        // (not just the scalar class #4 checks). Disjoint from #4
                        // by construction — a storage texture reflects an empty
                        // sample_type (so #4 above skipped) but a real texel
                        // format (so this fires). Author spelling both sides
                        // (meta.format_str = SJON, tex.format = WGSL).
                        if (type_agree.storageTextureFormatMismatch(tex, meta.format)) {
                            self.diagnose(.wgsl, meta.loc, "", "storage texture '{s}' (@group({d}) @binding({d})) is :format '{s}' in SJON but the shader's texture_storage declares '{s}'", .{ binding.name, binding.group, binding.binding, meta.format_str, tex.format });
                            return error.ValidationError;
                        }
                    }
                },
                .sampler => |samp| if (self.binds.bind_sampler_ids.get(key)) |sid| {
                    if (self.binds.sampler_meta.get(sid)) |meta| {
                        if (type_agree.samplerComparisonMismatch(samp, meta.comparison)) {
                            self.diagnose(.wgsl, meta.loc, "", "sampler '{s}' (@group({d}) @binding({d})) is a {s} sampler in SJON but the shader declares {s}", .{ binding.name, binding.group, binding.binding, if (meta.comparison) "comparison" else "non-comparison", if (samp.comparison) "sampler_comparison" else "a plain sampler" });
                            return error.ValidationError;
                        }
                    }
                },
                .buffer => {},
            }
        }
    }

    /// Buffer-side R1 checks at a RESOLVED (binding, buffer) pair: ③ (address-
    /// space agreement) before ① (size adequacy — a wrong-space bind makes the
    /// size comparison meaningless). Gated on `validate_shaders`. They run when
    /// the resolution is SCOPED (the per-pipeline join is authoritative — this
    /// un-suppresses slots the old global join had to skip as ambiguous) or the
    /// slot is globally unambiguous; a global-fallback resolution of an
    /// ambiguous slot still skips (the old false-positive guard).
    fn checkBufferBinding(self: *Emitter, binding: reflect.Binding, key: UniformBindingKey, buffer_id: u16, scoped: bool) Error!void {
        if (!self.validate_shaders) return;
        if (!scoped and self.binds.uniform_binding_ambiguous.contains(key)) return;
        const meta = self.binds.buffer_meta.get(buffer_id) orelse return;
        if (uniforms.addressSpaceMismatch(binding.address_space, meta.usage)) {
            const want = @tagName(binding.address_space);
            self.diagnose(.wgsl, meta.loc, "", "buffer '{s}' is bound as var<{s}> but its :usage lacks {s}", .{ binding.name, want, want });
            return error.ValidationError;
        }
        if (meta.size > 0 and binding.layout.size > meta.size) {
            self.diagnose(.wgsl, meta.loc, "", "buffer '{s}' size ({d} bytes) is smaller than the shader struct it binds ({d} bytes)", .{ binding.name, meta.size, binding.layout.size });
            return error.EmitError;
        }
    }

    /// Flatten one reflected uniform/storage binding into sorted dot-notation
    /// leaves (`flattened` — caller-owned, freed via freeFlattenedFields).
    /// Returns false when nothing flattened — each a benign skip, never a crash.
    ///
    /// A BARE binding (`var<uniform> env: array<vec4f, 2>` / `var<uniform> u:
    /// vec4f` — no struct, so no layout fields) synthesizes ONE leaf named after
    /// the binding var itself, provided its type is representable (a mappable
    /// UniformType or a fixed-size array). Runtime-sized storage arrays
    /// (`array<Particle>`) stay unreflected as before — no whole-value
    /// setUniform story exists for them.
    fn flattenBinding(self: *Emitter, rd: *const reflect.ReflectionData, binding: reflect.Binding, flattened: *std.ArrayList(FlattenedField)) bool {
        std.debug.assert(flattened.items.len == 0);
        if (binding.layout.fields.len == 0) {
            const typed = uniforms.leafType(binding.type, binding.elem_type, binding.elem_count);
            const representable = typed.elem_count > 0 or typed.uniform_type != .unknown;
            if (!representable or binding.layout.size == 0 or binding.layout.size > std.math.maxInt(u16)) {
                self.warnBareBindingSkip(binding, representable);
                return false;
            }
            const path = self.gpa.dupe(u8, binding.name) catch return false;
            flattened.append(self.gpa, .{
                .path = path,
                .offset = 0,
                .size = @intCast(binding.layout.size),
                .uniform_type = typed.uniform_type,
                .elem_count = typed.elem_count,
            }) catch {
                self.gpa.free(path);
                return false;
            };
        } else {
            var dropped: DropCounts = .{};
            uniforms.flattenFields(self.gpa, rd, binding.layout.fields, 0, "", 0, &dropped, flattened) catch return false;
            // Leaves past the wire's u16 offset/size cap were skipped (a large
            // storage struct) — surface the count instead of vanishing (gated).
            if (dropped.oversize > 0 and self.validate_shaders) {
                self.diagnoseWarn(.wgsl, null, "", "binding '{s}' (@group({d}) @binding({d})): {d} field(s) beyond the uniform table's 64 KiB offset/size limit were dropped — setUniform cannot target them", .{ binding.name, binding.group, binding.binding, dropped.oversize });
            }
            // A very wide struct flattens past the per-binding field cap — the
            // tail was dropped in declaration order; surface it (gated).
            if (dropped.overflow > 0 and self.validate_shaders) {
                self.diagnoseWarn(.wgsl, null, "", "binding '{s}' (@group({d}) @binding({d})): {d} leaf field(s) beyond the uniform table's {d}-fields-per-binding cap were dropped — setUniform cannot target them", .{ binding.name, binding.group, binding.binding, dropped.overflow, uniform_table.MAX_FIELDS });
            }
            // Struct nesting deeper than the flatten bound — the whole subtree is
            // unexplored, so this counts branches, not leaves (gated).
            if (dropped.too_deep > 0 and self.validate_shaders) {
                self.diagnoseWarn(.wgsl, null, "", "binding '{s}' (@group({d}) @binding({d})): {d} struct(s) nested deeper than {d} levels were not flattened — setUniform cannot target anything inside them", .{ binding.name, binding.group, binding.binding, dropped.too_deep, uniforms.MAX_FLATTEN_DEPTH });
            }
        }
        if (flattened.items.len == 0) return false;
        // Sort by path for stable compile-time slot assignment.
        std.mem.sort(FlattenedField, flattened.items, {}, uniforms.compareFlattenedFields);
        return true;
    }

    /// Explain a skipped BARE binding (gated; was a silent `return false`).
    /// Runtime-sized storage arrays (`array<Particle>` — no element count, or a
    /// zero-size layout) are the EXPECTED compute-buffer shape and stay silent
    /// (boids/particles must not warn); a SIZED binding that is oversize or
    /// unmappable is user-actionable — it silently lacks a setUniform story.
    fn warnBareBindingSkip(self: *Emitter, binding: reflect.Binding, representable: bool) void {
        if (!self.validate_shaders) return;
        if (binding.layout.size == 0) return; // runtime-sized → expected, silent
        if (binding.elem_count == 0 and std.mem.startsWith(u8, binding.type, "array<")) return; // runtime-sized array<T>
        if (binding.layout.size > std.math.maxInt(u16)) {
            self.diagnoseWarn(.wgsl, null, "", "binding '{s}' (@group({d}) @binding({d})) is {d} bytes — beyond the uniform table's 64 KiB limit; setUniform cannot target it", .{ binding.name, binding.group, binding.binding, binding.layout.size });
            return;
        }
        if (!representable) {
            self.diagnoseWarn(.wgsl, null, "", "binding '{s}' (@group({d}) @binding({d})) has type '{s}', which the uniform table cannot represent; setUniform cannot target it", .{ binding.name, binding.group, binding.binding, binding.type });
        }
    }

    /// Intern one flattened binding's field paths + var name and append the
    /// table record for `buffer_id` (the unchanged builder.addUniformBinding
    /// API). Called once per CANDIDATE buffer — the flatten is shared. Returns
    /// true when a record was added (an intern/append infra failure is a benign
    /// false, never a crash).
    /// Returns whether a record was emitted. OOM propagates; a string table
    /// that has no room left for a field's name (64 KiB of names) WARNS and
    /// drops the binding from the table — `setUniform` for it then no-ops at
    /// runtime, which is exactly what the warning says, where a silent
    /// `catch continue` said nothing.
    fn emitRecord(self: *Emitter, binding: reflect.Binding, buffer_id: u16, flattened: []const FlattenedField) Error!bool {
        std.debug.assert(flattened.len > 0);
        std.debug.assert(binding.group <= 3);
        // pre: the flatten cap reached here intact — `@intCast(slot)` below and
        // `addUniformBinding`'s own bound both rest on it, and this is the seam
        // where a future caller could hand over an unbounded list.
        std.debug.assert(flattened.len <= uniform_table.MAX_FIELDS);
        var fields: std.ArrayList(uniform_table.UniformField) = .empty;
        defer fields.deinit(self.gpa);
        for (flattened, 0..) |flat, slot| {
            const name_id = self.builder.internString(self.gpa, flat.path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return self.warnUniformTableFull(binding.name, flat.path),
            };
            try fields.append(self.gpa, .{
                .slot = @intCast(slot),
                .name_string_id = name_id.toInt(),
                .offset = flat.offset,
                .size = flat.size,
                .uniform_type = flat.uniform_type,
                .elem_count = flat.elem_count,
            });
        }
        std.debug.assert(fields.items.len == flattened.len);

        const binding_name_id = self.builder.internString(self.gpa, binding.name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.warnUniformTableFull(binding.name, binding.name),
        };
        // Only OOM can fail here: the binding count is bounded by the caller
        // (`MAX_BINDINGS`), the field count by the flatten cap above.
        self.builder.addUniformBinding(
            self.gpa,
            buffer_id,
            binding_name_id.toInt(),
            @intCast(binding.group),
            @intCast(binding.binding),
            fields.items,
        ) catch return error.OutOfMemory;
        return true;
    }

    /// The uniform/string table could not take one more name: say which
    /// binding is left out and what that costs, and report "not emitted".
    fn warnUniformTableFull(self: *Emitter, binding_name: []const u8, path: []const u8) bool {
        std.debug.assert(binding_name.len > 0);
        self.diagnoseWarn(.wgsl, null, binding_name, "uniform binding '{s}' is left out of the runtime uniform table — no room left for the name '{s}' (the table's names total at most 64 KiB); setUniform() for its fields will not reach the GPU", .{ binding_name, path });
        return false;
    }

    /// CONST-04: gather every `(constant …)` in the document, source and lowered,
    /// and attribute it to the module its stage names.
    ///
    /// Runs before any phase because `emitShaderModule` needs the values in hand:
    /// the rewrite must precede WGSL validation so wgslender validates the bytes
    /// that ship (a substituted value can be invalid where the override was fine
    /// — `@workgroup_size(0)` is the obvious one).
    ///
    /// Walks the lowered tree too, so a `(pass …)`-synthesized pipeline is
    /// covered exactly like an authored one. Nothing lowers into `(constant …)`
    /// today; this costs one bounded walk and means the day something does, it
    /// is not a silent hole.
    fn collectConstants(self: *Emitter) Error!void {
        for (self.forms.items) |ref| {
            try self.collectPipelineConstants(ref.reader, ref.idx);
        }
        if (self.has_low) {
            const lt = &self.result.lowered_tree.?;
            for (lt.root) |idx| {
                if (lt.tagOf(idx) != .form) continue;
                try self.collectPipelineConstants(&self.low, idx);
            }
        }
    }

    /// Dispatch one form to its constant-bearing stages. All three stage forms
    /// are the same shape now, so there is one reader for all of them; before
    /// D10 a compute pipeline carried its `(constant …)` children directly and
    /// needed its `:module` threaded in. Any other head is skipped.
    fn collectPipelineConstants(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const head = r.head(form);
        if (std.mem.eql(u8, head, "render-pipeline")) {
            if (r.child(form, "vertex")) |vtx| try self.collectStageConstants(r, vtx);
            if (r.child(form, "fragment")) |frag| try self.collectStageConstants(r, frag);
        } else if (std.mem.eql(u8, head, "compute-pipeline")) {
            if (r.child(form, "compute")) |cs| try self.collectStageConstants(r, cs);
        }
    }

    /// Read the `(constant …)` children of one stage, against that stage's own
    /// `:module`.
    fn collectStageConstants(self: *Emitter, r: *const Reader, section: NodeIndex) Error!void {
        const module = r.symbol(section, "module") orelse return;
        var it = r.childrenWithHead(section, "constant");
        while (it.next()) |c| {
            const name = r.symbol(c, "name") orelse continue;
            const vnode = r.authorNode(c, "value") orelse continue;
            const value = values.evalNodeF64(self.gpa, r.tree, self.schema, &self.env, vnode) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return self.refuseNumeric(r, vnode, "value", e),
            };
            try self.addConstant(module, name, value, .{ .reader = r, .idx = c });
        }
    }

    /// Record one constant, refusing a disagreement.
    ///
    /// Restating the same name at the same value is ORDINARY: a pipeline whose
    /// vertex and fragment stages share a module may carry the constant on both,
    /// and WebGPU's own per-stage dict would require exactly that. Two DIFFERENT
    /// values for one module is the early-binding cliff — under a passthrough
    /// design the two stages would simply get different dicts, but specialisation
    /// rewrites the module, so one value would silently win. Refuse instead:
    /// duplicating the module to satisfy both is a size cliff hiding behind a
    /// convenience, and nothing in the corpus asks for it.
    fn addConstant(self: *Emitter, module: []const u8, name: []const u8, value: f64, ref: FormRef) Error!void {
        std.debug.assert(module.len > 0);
        std.debug.assert(name.len > 0);
        for (self.tables.module_constants.items) |prev| {
            if (!std.mem.eql(u8, prev.module, module)) continue;
            if (!std.mem.eql(u8, prev.name, name)) continue;
            if (prev.value == value) return; // same value restated — idempotent
            self.diagnose(.sjon, self.locate(ref.reader, ref.idx), "", "override '{s}' of shader module '{s}' is specialised twice with different values ({d} and {d}) — pngine substitutes the value into the shader text, so one module cannot hold both", .{ name, module, prev.value, value });
            return error.ValidationError;
        }
        try self.tables.module_constants.append(self.gpa, .{
            .module = module,
            .name = name,
            .value = value,
            .ref = ref,
        });
    }

    /// The specialisations for one module, caller-owned. Empty (and
    /// allocation-free) for every module in the corpus today.
    fn specsFor(self: *Emitter, module: []const u8) Error![]reflect.wgslender_native.Specialisation {
        var out = std.ArrayList(reflect.wgslender_native.Specialisation).empty;
        errdefer out.deinit(self.gpa);
        for (self.tables.module_constants.items) |c| {
            if (!std.mem.eql(u8, c.module, module)) continue;
            try out.append(self.gpa, .{ .name = c.name, .value = c.value });
        }
        return out.toOwnedSlice(self.gpa) catch return error.OutOfMemory;
    }

    /// The `(constant …)` form that named `override` on `module`, for locating a
    /// specialisation failure on the SJON the author wrote rather than on the
    /// shader module it names.
    fn constantRef(self: *const Emitter, module: []const u8, override: []const u8) ?FormRef {
        for (self.tables.module_constants.items) |c| {
            if (std.mem.eql(u8, c.module, module) and std.mem.eql(u8, c.name, override)) return c.ref;
        }
        return null;
    }

    fn collectQueues(self: *Emitter) Error!void {
        // Source (user-authored) queues.
        for (self.forms.items) |ref| {
            const r = ref.reader;
            if (!std.mem.eql(u8, r.head(ref.idx), "queue")) continue;
            const name = r.symbol(ref.idx, "name") orelse continue;
            // Store the queue FORM node: a queue may hold several positional actions
            // (e.g. resolveOps = (resolve-query-set …) then (copy-buffer-to-buffer …)),
            // all inlined in order when a frame references it (see emitQueueActions).
            try self.tables.queue_actions.put(self.gpa, name, .{ .reader = r, .idx = ref.idx });
        }
        // Lowered queues: `pngine/pass-v1` emits a per-pass `(queue (write-buffer
        // … :data pngine-inputs))` so a `(pass …)` that references `pngine`/`pointer`
        // writes its uniform buffer each frame. Collected with the lowered reader
        // (and BEFORE `emitLowered` runs) so the lowered auto-frame resolves them.
        if (self.has_low) {
            const lt = &self.result.lowered_tree.?;
            for (lt.root) |idx| {
                if (lt.tagOf(idx) != .form) continue;
                if (!std.mem.eql(u8, self.low.head(idx), "queue")) continue;
                const name = self.low.symbol(idx, "name") orelse continue;
                try self.tables.queue_actions.put(self.gpa, name, .{ .reader = &self.low, .idx = idx });
            }
        }
    }

    /// A render-pass attachment view's declared `:format` (enum + author spelling),
    /// or null to SKIP the exact-equality attachment checks: the canvas
    /// (`context-current-texture` — the runtime picks the format at load time) or a
    /// view name that isn't a declared `(texture …)`. Deliberately does NOT fall back
    /// to the canvas like `resolveAttachmentView` — an unresolved view must skip, not
    /// silently compare against the canvas. A pooled texture resolves via its base id
    /// (the id `texture_meta` is keyed by), so pooled attachments join correctly.
    /// The `TextureMeta` of a render-pass attachment view, or null to SKIP: the
    /// canvas (`context-current-texture`) or a name that isn't a declared
    /// `(texture …)`. A pooled texture resolves via its base id (the id `texture_meta`
    /// is keyed by). Shared by the format (#7b/c/8b) and sample-count (#9) checks.
    fn attachmentTextureMeta(self: *const Emitter, view_name: []const u8) ?TextureMeta {
        if (view_name.len == 0) return null;
        if (std.mem.eql(u8, view_name, "context-current-texture")) return null;
        const tid = self.tables.textures.get(view_name) orelse return null;
        return self.binds.texture_meta.get(tid);
    }

    const AttFormat = struct { fmt: values.TextureFormat, str: []const u8 };
    fn attachmentTextureFormat(self: *const Emitter, view_name: []const u8) ?AttFormat {
        const meta = self.attachmentTextureMeta(view_name) orelse return null;
        return .{ .fmt = meta.format, .str = meta.format_str };
    }

    /// A texture-format sentinel the exact-equality attachment checks must SKIP:
    /// `preferred-canvas-format` (resolved at load time to bgra8/rgba8) and `invalid`
    /// (an unknown spelling). Comparing either is meaningless → never a false reject.
    /// A strip topology, the two WebGPU spellings: triangle-strip / line-strip.
    /// An empty spelling is an absent `:topology`, which is triangle-list.
    ///
    /// C8's FIRST half — `:strip-index-format` only under a strip — used to be a
    /// check here too. It is the schema's since SJON 1.5 gave `(variant …)` a
    /// value list (06 S14): the key is declared inside
    /// `(variant :when [triangle-strip line-strip] …)`, so a list topology makes
    /// it `unknown_key` at validation. This helper serves the half that crosses
    /// pipeline and pass, which no schema can see.
    fn isStripTopology(topology: []const u8) bool {
        return std.mem.eql(u8, topology, "triangle-strip") or std.mem.eql(u8, topology, "line-strip");
    }

    /// C9 (05 §5) — `alphaToCoverageEnabled` turns the fragment's alpha into a
    /// coverage mask over the samples of a pixel, so WebGPU requires more than
    /// one sample: at `:count 1` there is nothing to cover and createRenderPipeline
    /// rejects the descriptor.
    ///
    /// Not the schema's, and not for want of a mechanism: `(variant …)` keys on a
    /// discriminant that resolves to a closed SYMBOL member-set, and this condition
    /// is a number (`> 1`).
    fn checkMultisample(self: *Emitter, r: *const Reader, form: NodeIndex, name: []const u8) Error!void {
        const ms = r.child(form, "multisample") orelse return;
        if (!(r.boolean(ms, "alpha-to-coverage-enabled") orelse false)) return;
        const count = (try self.optU32(r, ms, "count")) orelse 1;
        if (count <= 1) {
            self.diagnose(.sjon, self.locate(r, ms), "", "render-pipeline '{s}' enables :alpha-to-coverage-enabled at :count {d} — alpha to coverage spreads the fragment's alpha across a pixel's samples, so WebGPU needs more than one", .{ name, count });
            return error.ValidationError;
        }
        // …and the mask has to come from somewhere: WebGPU requires a fragment
        // state, a first target, and that target's format to be blendable WITH an
        // alpha channel. A depth-only pipeline that kept the (multisample …) block
        // it was copied with lands on the first of these.
        const frag = r.child(form, "fragment") orelse {
            self.diagnose(.sjon, self.locate(r, ms), "", "render-pipeline '{s}' enables :alpha-to-coverage-enabled with no (fragment …) — the coverage mask is the fragment's alpha, and there is no fragment stage to produce one", .{name});
            return error.ValidationError;
        };
        var t_it = r.childrenWithHead(frag, "target");
        const first = t_it.next() orelse return; // no target: `(head :name target :min 1)` says it first
        const fmt_sym = r.symbol(first, "format") orelse "preferred-canvas-format";
        const fmt = values.mapTextureFormat(fmt_sym);
        if (fmt == .invalid) return; // unknown spelling → its own diagnostic; never a false reject
        if (fmt.hasAlpha()) return;
        self.diagnose(.sjon, self.locate(r, first), "", "render-pipeline '{s}' enables :alpha-to-coverage-enabled but color target 0 is :format {s}, which has no alpha channel to derive the coverage mask from", .{ name, fmt_sym });
        return error.ValidationError;
    }

    /// C10 (05 §5) — blending is arithmetic on normalized or floating-point
    /// values, so WebGPU requires a target's format to be BLENDABLE once blend
    /// state is provided, and no uint or sint format is. The pipeline is rejected
    /// outright, so the whole document renders nothing — a picking or id G-buffer
    /// that acquires a `(blend …)` block by copy-paste fails this way.
    ///
    /// Conservative on purpose: only the integer classes are flagged. The 32-bit
    /// float formats are blendable only with the `float32-blendable` feature,
    /// which the runtime requests opportunistically, so rejecting them here would
    /// refuse documents that render on the adapters that have it.
    fn checkBlendableTargets(self: *Emitter, r: *const Reader, frag: NodeIndex, name: []const u8) Error!void {
        var t_it = r.childrenWithHead(frag, "target");
        var idx: u8 = 0;
        while (t_it.next()) |t| : (idx += 1) {
            if (r.child(t, "blend") == null) continue;
            const fmt_sym = r.symbol(t, "format") orelse "preferred-canvas-format";
            const class = type_agree.colorTargetFormatClass(fmt_sym) orelse continue;
            if (class == .float) continue;
            self.diagnose(.sjon, self.locate(r, t), "", "render-pipeline '{s}' gives color target {d} a (blend …) but its :format {s} is {s}-class — WebGPU blends only blendable formats, and no integer format is", .{ name, idx, fmt_sym, type_agree.className(class) });
            return error.ValidationError;
        }
    }

    /// Is either stencil face state departing from its spec defaults? WebGPU's
    /// "stencilFront or stencilBack are not the default values" predicate:
    /// `compare` defaults to `always` and all three ops to `keep`. A face form
    /// that spells only defaults is still the default state, so this reads the
    /// values rather than the form's presence.
    fn stencilFaceStated(r: *const Reader, ds: NodeIndex) bool {
        for ([_][]const u8{ "stencil-front", "stencil-back" }) |head| {
            const face = r.child(ds, head) orelse continue;
            if (r.symbol(face, "compare")) |c| if (!std.mem.eql(u8, c, "always")) return true;
            for ([_][]const u8{ "fail-op", "depth-fail-op", "pass-op" }) |op_key| {
                if (r.symbol(face, op_key)) |op| if (!std.mem.eql(u8, op, "keep")) return true;
            }
        }
        return false;
    }

    /// Does either stencil face state a `:depth-fail-op` other than `keep`? That
    /// op consults the depth test, which is one of the two things that make
    /// `depthCompare` required.
    fn stencilReadsDepth(r: *const Reader, ds: NodeIndex) bool {
        for ([_][]const u8{ "stencil-front", "stencil-back" }) |head| {
            const face = r.child(ds, head) orelse continue;
            if (r.symbol(face, "depth-fail-op")) |op| if (!std.mem.eql(u8, op, "keep")) return true;
        }
        return false;
    }

    /// C4 (05 §5) — the whole of WebGPU's "validating GPUDepthStencilState", which
    /// is five rules, not the one the plan's row names:
    ///
    /// 1. `:format` must be a depth-or-stencil format.
    /// 2. A depth write, or a depth compare other than `always`, needs a depth
    ///    aspect.
    /// 3. A non-default stencil face state needs a stencil aspect.
    /// 4. A depth aspect makes `:depth-write-enabled` REQUIRED, and
    ///    `:depth-compare` required too once the pipeline writes depth or a face
    ///    consults it. This is the row's headline: the keys stay optional in the
    ///    schema (a stencil-only pipeline legitimately omits both), so the
    ///    requirement is conditional on a value the schema cannot reach.
    /// 5. Depth bias is computed from a TRIANGLE's depth slope, so all three bias
    ///    fields must be 0 under a point or line topology — a fact split across
    ///    `(primitive …)` and `(depth-stencil …)`.
    ///
    /// Rule 1 is a value set, normally the schema's job, and it is here for a
    /// measured reason: the conformance ratchet models a narrowed enum kind as a
    /// support gap (`KNOWN_UNSUPPORTED`), so a `depth-stencil-format` member-set
    /// would have to declare all ~90 colour formats unsupported to keep the
    /// ledgers at zero. They are not unsupported; they are inapplicable.
    fn checkDepthStencilState(self: *Emitter, r: *const Reader, form: NodeIndex, name: []const u8) Error!void {
        const ds = r.child(form, "depth-stencil") orelse return;
        const fmt_sym = r.symbol(ds, "format") orelse return; // schema-required; absent is its diagnostic
        const fmt = values.mapTextureFormat(fmt_sym);
        const has_depth = fmt.hasDepth();
        const has_stencil = fmt.hasStencil();
        const loc = self.locate(r, ds);

        // #1 — a depth-or-stencil format. The sentinels answer false to both and
        // land here too, which is right: neither is a depth/stencil attachment.
        if (!has_depth and !has_stencil) {
            self.diagnose(.sjon, loc, "", "render-pipeline '{s}' declares (depth-stencil :format {s}) — GPUDepthStencilState.format must be a depth or stencil format", .{ name, fmt_sym });
            return error.ValidationError;
        }

        const write = r.boolean(ds, "depth-write-enabled");
        const compare = r.symbol(ds, "depth-compare");

        // #2 — depth use needs a depth aspect.
        if (!has_depth) {
            if (write orelse false) {
                self.diagnose(.sjon, loc, "", "render-pipeline '{s}' sets :depth-write-enabled true on :format {s}, which has no depth aspect", .{ name, fmt_sym });
                return error.ValidationError;
            }
            if (compare) |c| {
                if (!std.mem.eql(u8, c, "always")) {
                    self.diagnose(.sjon, loc, "", "render-pipeline '{s}' sets :depth-compare {s} on :format {s}, which has no depth aspect", .{ name, c, fmt_sym });
                    return error.ValidationError;
                }
            }
        }

        // #3 — stencil face state needs a stencil aspect.
        if (!has_stencil and stencilFaceStated(r, ds)) {
            self.diagnose(.sjon, loc, "", "render-pipeline '{s}' states a stencil face state on :format {s}, which has no stencil aspect", .{ name, fmt_sym });
            return error.ValidationError;
        }

        // #4 — what a depth aspect makes required.
        if (has_depth) {
            const w = write orelse {
                self.diagnose(.sjon, loc, "", "render-pipeline '{s}' declares (depth-stencil :format {s}) without :depth-write-enabled — WebGPU requires it for a depth format and has no default", .{ name, fmt_sym });
                return error.ValidationError;
            };
            if (compare == null and (w or stencilReadsDepth(r, ds))) {
                const why: []const u8 = if (w) "the pipeline writes depth" else "a stencil face's :depth-fail-op consults the depth test";
                self.diagnose(.sjon, loc, "", "render-pipeline '{s}' omits :depth-compare, but {s} — WebGPU requires the comparison and has no default", .{ name, why });
                return error.ValidationError;
            }
        }

        // #5 — depth bias is a triangle's slope, so a point/line topology takes none.
        const topology = if (r.child(form, "primitive")) |prim| r.symbol(prim, "topology") orelse "triangle-list" else "triangle-list";
        if (std.mem.eql(u8, topology, "triangle-list") or std.mem.eql(u8, topology, "triangle-strip")) return;
        for ([_][]const u8{ "depth-bias", "depth-bias-slope-scale", "depth-bias-clamp" }) |bias_key| {
            const bias = (try self.optF64(r, ds, bias_key)) orelse continue;
            if (bias == 0) continue;
            self.diagnose(.sjon, loc, "", "render-pipeline '{s}' sets :{s} {d} under :topology {s} — depth bias is derived from a triangle's depth slope, so WebGPU requires 0 for points and lines", .{ name, bias_key, bias, topology });
            return error.ValidationError;
        }
    }

    /// C17 (05 §5) — anisotropic filtering refines a LINEAR tap, so WebGPU
    /// requires magFilter, minFilter and mipmapFilter to all be `linear` when
    /// `maxAnisotropy > 1`. An absent filter is `nearest`, the IDL's default.
    ///
    /// The trap this closes is recent: pngine used to default the filters to
    /// linear, so a sampler that stated only `:max-anisotropy` came out legal by
    /// accident. spec/09 step D handed the defaults back to the IDL, which turned
    /// the same document into a createSampler error.
    fn checkAnisotropyFilters(self: *Emitter, r: *const Reader, form: NodeIndex, name: []const u8) Error!void {
        const aniso = (try self.optU32(r, form, "max-anisotropy")) orelse return;
        if (aniso <= 1) return;
        // `:mipmap-filter` has no schema default (an absent one is not emitted at
        // all), so read all three the same way: absent → WebGPU's `nearest`.
        for ([_][]const u8{ "mag-filter", "min-filter", "mipmap-filter" }) |key| {
            const mode = r.symbol(form, key) orelse "nearest";
            if (std.mem.eql(u8, mode, "linear")) continue;
            self.diagnose(.sjon, self.locate(r, form), "", "sampler '{s}' sets :max-anisotropy {d} but :{s} is {s} — WebGPU allows anisotropy above 1 only when the mag, min and mipmap filters are all linear", .{ name, aniso, key, mode });
            return error.ValidationError;
        }
    }

    fn isFormatSentinel(fmt: values.TextureFormat) bool {
        return fmt == .preferred_canvas_format or fmt == .invalid;
    }

    /// R5a — render-pass ↔ render-pipeline attachment-state agreement (gated on
    /// `validate_shaders`). WebGPU requires draw-time attachment compatibility: the
    /// color formats must match element- AND length-wise, and the depth format must
    /// match in presence and value. A disagreement is a silent black screen on the
    /// loader's device (a beginRenderPass / setPipeline error), never a compile error
    /// today. A self-contained re-walk of the pass form; joins against the
    /// `PipelineMeta` recorded by `emitRenderPipeline` (all pipelines emit before all
    /// passes — see `run()`). Conservative — a bundle-only pass (no `:pipeline`), a
    /// compute pipeline, a zero-target pipeline, a canvas view, an unknown
    /// texture, or a sentinel format all SKIP, never a false reject. Both sides are
    /// SJON, so a disagreement reports the `.sjon` domain. `pass_name` names the pass.
    /// A render pass's attachments gathered for the R5a pipeline-agreement checks:
    /// up to 8 stored color attachments (nodes + view names) plus the total color
    /// count (ALL forms, for the effective-count compare) and the depth attachment.
    /// The `nodes`/`views` tails beyond `stored` are undefined — read `[0..stored]`.
    const PassAttachments = struct {
        nodes: [8]NodeIndex,
        views: [8][]const u8,
        stored: u8,
        count: u16,
        depth: ?NodeIndex,
    };

    /// Gather a render pass's color attachments (author order) + its depth
    /// attachment — a self-contained re-walk (the head filter excludes
    /// timestamp/occlusion/draw children). Stores up to 8 views (the WebGPU max)
    /// and counts ALL color forms, so the effective-count compare sees a surplus
    /// the store dropped. Pure: reads the tree, allocates nothing, diagnoses
    /// nothing. Shared by the pipeline join (R5a) and the bundle join (C19), which
    /// is the point — two walks of the same children could disagree about what an
    /// attachment is.
    fn gatherPassAttachments(r: *const Reader, form: NodeIndex) PassAttachments {
        var atts = PassAttachments{ .nodes = undefined, .views = undefined, .stored = 0, .count = 0, .depth = null };
        var att_it = r.childrenWithHead(form, "color-attachment");
        while (att_it.next()) |c| {
            if (atts.stored < atts.nodes.len) {
                atts.nodes[atts.stored] = c;
                atts.views[atts.stored] = r.symbol(c, "view") orelse "";
                atts.stored += 1;
            }
            atts.count += 1;
        }
        atts.depth = r.child(form, "depth-stencil-attachment");
        std.debug.assert(atts.stored <= atts.count); // post: stored is a prefix of the counted forms
        return atts;
    }

    fn checkRenderPassPipeline(self: *Emitter, r: *const Reader, form: NodeIndex, pass_name: []const u8) Error!void {
        if (!self.validate_shaders) return;

        // #1 — resolve the pass's pipeline. No `:pipeline` (a bundle-executing pass),
        // an unknown name, or a compute pipeline (no meta recorded) → skip the pass.
        const pname = r.symbol(form, "pipeline") orelse return;
        const pid = self.tables.pipelines.get(pname) orelse return;
        const meta = self.binds.pipeline_meta.get(pid) orelse return;

        const atts = gatherPassAttachments(r, form);

        // The concern checks, in the original #7a → #7b/#7c → #8a/#8b → #9 order;
        // the first disagreement short-circuits (each returns a ValidationError).
        try self.checkAttachmentCount(r, form, pass_name, pname, atts, meta);
        try self.checkAttachmentFormats(r, pass_name, pname, atts, meta);
        try self.checkDepthAttachment(r, form, pass_name, pname, atts, meta);
        try self.checkSampleCounts(r, pass_name, pname, atts, meta);
        try self.checkStripIndexDraw(r, form, pass_name, pname, meta);
    }

    /// C8, second half (05 §5) — an INDEXED draw under a strip topology needs the
    /// pipeline's `:strip-index-format`. WebGPU derives the primitive-restart
    /// value from it, so `drawIndexed` on a strip pipeline that omits it is a
    /// validation error in the browser and an abort natively; the pairing is a
    /// pipeline↔pass fact, which is why it is here and not in the schema.
    ///
    /// Only the pass's own indexed draws are checked. A `:bundles` replay can
    /// also draw indexed, and the bundle records against its own pipeline — that
    /// join is the bundle's, not this pass's.
    fn checkStripIndexDraw(self: *Emitter, r: *const Reader, form: NodeIndex, pass_name: []const u8, pname: []const u8, meta: PipelineMeta) Error!void {
        if (!isStripTopology(meta.topology) or meta.strip_index_format) return;
        const indexed = r.child(form, "draw-indexed") orelse r.child(form, "draw-indexed-indirect") orelse return;
        self.diagnose(.sjon, self.locate(r, indexed), "", "render-pass '{s}' draws indexed with pipeline '{s}', whose :topology is '{s}' — a strip needs (primitive … :strip-index-format uint16|uint32) so WebGPU knows the primitive-restart value", .{ pass_name, pname, meta.topology });
        return error.ValidationError;
    }

    /// R5a #7a — effective color-attachment count vs the pipeline's declared target
    /// count. N attachments → N; 0 + depth → 0 (depth-only). The `else 1` arm is
    /// the retired implicit-canvas default (overhaul/05 C14, `0f8e759`): a pass with no attachment at all
    /// is refused by `emitRenderPass` before this runs. Skips when the pipeline's
    /// target list is unknown (zero targets; see `PipelineMeta`).
    fn checkAttachmentCount(self: *Emitter, r: *const Reader, form: NodeIndex, pass_name: []const u8, pname: []const u8, atts: PassAttachments, meta: PipelineMeta) Error!void {
        if (!meta.targets_known) return;
        const effective: u16 = if (atts.count > 0) atts.count else if (atts.depth != null) 0 else 1;
        if (effective != meta.targets_total) {
            // Anchor the SURPLUS attachment when the pass provides more than the
            // pipeline; else the pass form (an under-count has no form to point at).
            const anchor = if (meta.targets_total < atts.stored) atts.nodes[@as(usize, meta.targets_total)] else form;
            self.diagnose(.sjon, self.locate(r, anchor), "", "render-pass '{s}' has {d} color attachment(s) but pipeline '{s}' declares {d} color target(s)", .{ pass_name, effective, pname, meta.targets_total });
            return error.ValidationError;
        }
    }

    /// R5a #7b/#7c — per-slot color format equality (attachment view vs pipeline
    /// target) and resolve-target/view format equality. Skips a canvas view, an
    /// unresolved texture, or a sentinel format on either side.
    fn checkAttachmentFormats(self: *Emitter, r: *const Reader, pass_name: []const u8, pname: []const u8, atts: PassAttachments, meta: PipelineMeta) Error!void {
        // #7b — per-slot color format equality.
        if (meta.targets_known) {
            const n = @min(atts.stored, meta.targets_len);
            var i: u8 = 0;
            while (i < n) : (i += 1) {
                const af = self.attachmentTextureFormat(atts.views[i]) orelse continue;
                if (isFormatSentinel(af.fmt)) continue;
                const target = meta.targets[i];
                if (isFormatSentinel(target.fmt)) continue;
                if (af.fmt != target.fmt) {
                    self.diagnose(.sjon, self.locate(r, atts.nodes[i]), "", "color attachment {d} of render-pass '{s}' writes texture '{s}' with :format '{s}' but pipeline '{s}' declares color target {d} as :format '{s}'", .{ i, pass_name, atts.views[i], af.str, pname, i, target.spelling });
                    return error.ValidationError;
                }
            }
        }

        // #7c — a resolve target's format must equal its attachment view's format
        // (the msaa-quirk file resolves a real texture to the canvas → skipped).
        var i: u8 = 0;
        while (i < atts.stored) : (i += 1) {
            const rt = r.symbol(atts.nodes[i], "resolve-target") orelse continue;
            const rt_af = self.attachmentTextureFormat(rt) orelse continue;
            const view_af = self.attachmentTextureFormat(atts.views[i]) orelse continue;
            if (isFormatSentinel(rt_af.fmt) or isFormatSentinel(view_af.fmt)) continue;
            if (rt_af.fmt != view_af.fmt) {
                self.diagnose(.sjon, self.locate(r, atts.nodes[i]), "", "resolve-target '{s}' (:format '{s}') of render-pass '{s}' must match color attachment {d}'s texture '{s}' :format '{s}'", .{ rt, rt_af.str, pass_name, i, atts.views[i], view_af.str });
                return error.ValidationError;
            }
        }
    }

    /// R5a #8a/#8b — depth attachment presence must agree in BOTH directions, and
    /// (when both present) the depth format must match exactly (depth24plus ≠
    /// depth24plus-stencil8). #8b skips only when the depth texture is
    /// canvas/unresolved/sentinel: `:format` itself is required (spec/09 C.1).
    fn checkDepthAttachment(self: *Emitter, r: *const Reader, form: NodeIndex, pass_name: []const u8, pname: []const u8, atts: PassAttachments, meta: PipelineMeta) Error!void {
        const pass_has_depth = atts.depth != null;
        if (pass_has_depth != meta.ds_present) {
            if (meta.ds_present) {
                self.diagnose(.sjon, self.locate(r, form), "", "pipeline '{s}' declares a depth-stencil state but render-pass '{s}' has no depth attachment", .{ pname, pass_name });
            } else {
                self.diagnose(.sjon, self.locate(r, atts.depth.?), "", "render-pass '{s}' has a depth attachment but pipeline '{s}' declares no depth-stencil state", .{ pass_name, pname });
            }
            return error.ValidationError;
        }

        if (pass_has_depth and meta.ds_present) {
            {
                const dsf = meta.ds_format.?; // ds_present ⇒ :format was authored
                const dview = r.symbol(atts.depth.?, "view") orelse "";
                if (self.attachmentTextureFormat(dview)) |df| {
                    if (!isFormatSentinel(df.fmt) and !isFormatSentinel(dsf) and df.fmt != dsf) {
                        self.diagnose(.sjon, self.locate(r, atts.depth.?), "", "depth attachment of render-pass '{s}' writes texture '{s}' with :format '{s}' but pipeline '{s}' declares depth-stencil :format '{s}'", .{ pass_name, dview, df.str, pname, meta.ds_spelling });
                        return error.ValidationError;
                    }
                }
            }
        }
    }

    /// R5a #9 — sample-count agreement (color AND depth attachment views). Fires ONLY
    /// when a texture's :sample-count is EXPLICIT and > 1 and disagrees with the
    /// pipeline's (multisample :count …). An omitted/expression count (null) or an
    /// explicit 1 is the simple_triangle_msaa quirk pattern (an omitted count reads
    /// as 1 while the pipeline stays 4) → SKIP, never a false reject.
    fn checkSampleCounts(self: *Emitter, r: *const Reader, pass_name: []const u8, pname: []const u8, atts: PassAttachments, meta: PipelineMeta) Error!void {
        const pipe_ms: u32 = meta.ms_count orelse 1;
        var i: u8 = 0;
        while (i < atts.stored) : (i += 1) {
            const tm = self.attachmentTextureMeta(atts.views[i]) orelse continue;
            const sc = tm.sample_count orelse continue;
            if (sc > 1 and sc != pipe_ms) {
                self.diagnose(.sjon, self.locate(r, atts.nodes[i]), "", "color attachment {d} of render-pass '{s}' writes texture '{s}' with :sample-count {d} but pipeline '{s}' has sample count {d}", .{ i, pass_name, atts.views[i], sc, pname, pipe_ms });
                return error.ValidationError;
            }
        }
        if (atts.depth) |da| {
            const dview = r.symbol(da, "view") orelse "";
            if (self.attachmentTextureMeta(dview)) |tm| {
                if (tm.sample_count) |sc| {
                    if (sc > 1 and sc != pipe_ms) {
                        self.diagnose(.sjon, self.locate(r, da), "", "depth attachment of render-pass '{s}' writes texture '{s}' with :sample-count {d} but pipeline '{s}' has sample count {d}", .{ pass_name, dview, sc, pname, pipe_ms });
                        return error.ValidationError;
                    }
                }
            }
        }
    }

    /// The gathered `(color-attachment …)` records of a render pass, ready for the
    /// begin-pass opcode selection. `resolve` + `first_view_name` reflect the FIRST
    /// attachment only (the single-attachment path keeps the resolve target; MRT
    /// carries none). The `atts` tail beyond `count` is undefined — read `[0..count]`.
    const GatheredColorAttachments = struct {
        atts: [MAX_COLOR_ATTACHMENTS]ColorAttachment,
        count: usize,
        resolve: u16,
        first_view_name: ?[]const u8,
    };

    /// Gather a render-pass's `(color-attachment …)` sub-forms in author order
    /// (capped at the WebGPU max of 8), resolving each view id, load/store op, and
    /// clear value. Emission-prep — writes no opcodes, but errors: a clear-value
    /// element may be an expression, and a malformed one is an emit error.
    fn gatherColorAttachments(self: *Emitter, r: *const Reader, form: NodeIndex) Error!GatheredColorAttachments {
        var atts: [MAX_COLOR_ATTACHMENTS]ColorAttachment = undefined;
        var att_count: usize = 0;
        var resolve: u16 = values.NO_TEXTURE_ID;
        var first_view_name: ?[]const u8 = null;
        var att_it = r.childrenWithHead(form, "color-attachment");
        while (att_it.next()) |c| {
            // Over-cap is a reject, not a truncation. `break` here silently
            // dropped every attachment past the 8th: the pass rendered without
            // them, `checkAttachmentCount` compared the TRUNCATED count against
            // the pipeline's targets and saw no disagreement, and the author got
            // a wrong image with a zero exit code. Same shape as `allocPassId`'s
            // browser pass cap and `checkDescListFits`' one-byte count.
            if (att_count >= atts.len) {
                self.diagnose(.sjon, self.locate(r, form), "", "render pass declares more than {d} (color-attachment …) sub-forms, which is WebGPU's maxColorAttachments and the width of the MRT opcode — the extra attachments cannot be encoded", .{MAX_COLOR_ATTACHMENTS});
                return error.ValidationError;
            }
            var att = ColorAttachment{
                .texture_id = values.CANVAS_TEXTURE_ID,
                .load_op = .clear,
                .store_op = .store,
                .clear_r_bits = 0,
                .clear_g_bits = 0,
                .clear_b_bits = 0,
                .clear_a_bits = 0,
            };
            if (r.symbol(c, "view")) |v| {
                att.texture_id = self.resolveAttachmentView(v);
                if (att_count == 0) first_view_name = v;
            }
            // Both are REQUIRED (spec/09 step D), so the validator has already
            // rejected their absence — `orelse return error.EmitError` here rather
            // than a silent fall-back to the struct's initialiser, which is what
            // used to encode the clear/store opinion.
            const lo = try self.requiredSymbol(r, c, "load-op");
            att.load_op = if (std.mem.eql(u8, lo, "load")) .load else .clear;
            const so = try self.requiredSymbol(r, c, "store-op");
            att.store_op = if (std.mem.eql(u8, so, "discard")) .discard else .store;
            // GPUColor channels are doubles and the wire carries f32 — no
            // quantization and no [0,1] clamp. Both used to happen here:
            // `floatToU8` rounded to 1/255 AND clamped, so `[2.0 0 0 1]` on an
            // rgba16float target — legal WebGPU, and the reason HDR clears exist
            // — arrived as pure red. (spec/09 step D)
            if (r.vectorNodes(c, "clear-value")) |cv| {
                if (cv.len > 0) att.clear_r_bits = floatBits(try self.elemF64(r, cv[0], 0));
                if (cv.len > 1) att.clear_g_bits = floatBits(try self.elemF64(r, cv[1], 0));
                if (cv.len > 2) att.clear_b_bits = floatBits(try self.elemF64(r, cv[2], 0));
                if (cv.len > 3) att.clear_a_bits = floatBits(try self.elemF64(r, cv[3], 0));
            }
            // The MRT opcode carries no resolve target (matches the legacy); the
            // single-attachment path keeps it, sourced from the only attachment.
            if (att_count == 0) {
                if (r.symbol(c, "resolve-target")) |rt| resolve = self.resolveAttachmentView(rt);
            }
            atts[att_count] = att;
            att_count += 1;
        }
        std.debug.assert(att_count <= atts.len); // post: the reject above holds
        return .{ .atts = atts, .count = att_count, .resolve = resolve, .first_view_name = first_view_name };
    }

    /// Emit the begin-render-pass opcode for the gathered color attachments + depth:
    /// a single pooled view → begin_render_pass_pool (feedback ping-pong); >1 → MRT;
    /// else the single/zero-attachment path (0 color + depth ⇒ a depth-only pass at
    /// NO_TEXTURE_ID, else the canvas). Mirrors legacy passes.zig:172-175.
    fn beginPassForAttachments(self: *Emitter, cols: GatheredColorAttachments, depth_texture_id: u16) Error!void {
        const em = self.builder.getEmitter();
        // A single color attachment whose view names a pooled texture is a feedback
        // ping-pong target → begin_render_pass_pool(base, size, 0): the render-time
        // analog of the pool bind groups (the dispatcher resolves the actual target
        // per frame, just like setBindGroupPool). Mirrors legacy beginRenderPassPool.
        const pool_target: ?PoolInfo = if (cols.count == 1) blk: {
            const vn = cols.first_view_name orelse break :blk null;
            break :blk self.tables.textures.pool(vn);
        } else null;

        if (pool_target) |tp| {
            const a0 = cols.atts[0];
            em.beginRenderPassPool(self.gpa, tp.base, tp.size, 0, a0.load_op, a0.store_op, depth_texture_id, a0.clear_r_bits, a0.clear_g_bits, a0.clear_b_bits, a0.clear_a_bits) catch return error.OutOfMemory;
        } else if (cols.count > 1) {
            em.beginRenderPassMRT(self.gpa, cols.atts[0..cols.count], depth_texture_id) catch return error.OutOfMemory;
        } else {
            // Zero color attachments: a depth attachment present makes this a
            // depth-only pass (no color target → 0xFFFF, e.g. a shadow-map / depth
            // pre-pass); otherwise default to the canvas (the pre-MRT fullscreen-
            // pass behavior every existing fixture relies on).
            const zero_att_color = if (depth_texture_id != values.NO_TEXTURE_ID)
                values.NO_TEXTURE_ID
            else
                values.CANVAS_TEXTURE_ID;
            const a0 = if (cols.count == 1) cols.atts[0] else ColorAttachment{
                .texture_id = zero_att_color,
                .load_op = .clear,
                .store_op = .store,
                .clear_r_bits = 0,
                .clear_g_bits = 0,
                .clear_b_bits = 0,
                .clear_a_bits = 0,
            };
            em.beginRenderPass(self.gpa, a0.texture_id, a0.load_op, a0.store_op, depth_texture_id, a0.clear_r_bits, a0.clear_g_bits, a0.clear_b_bits, a0.clear_a_bits, cols.resolve) catch return error.OutOfMemory;
        }
    }

    /// Read `:pool` off `form` and reserve that many sequential ids under `name`,
    /// refusing a pool the wire cannot encode and an id space that would wrap.
    ///
    /// `:pool` is a `pool-size` (`:min 1 :max 255`), so a LITERAL out of range is
    /// already a schema reject with its own squiggle. This is the other half:
    /// the schema's repr check covers literals only, so `:pool (* 100 3)` — an
    /// expression — arrives here unchecked, and used to reach `@intCast(u8)`.
    /// That panics the CLI and, in the ReleaseSmall wasm compiler where the
    /// safety check is compiled out, silently truncates: `:pool 300` would build
    /// a 44-instance pool and every ping-pong index would then address the wrong
    /// resource.
    ///
    /// The expression itself is fine — it is the count it evaluates to that has
    /// to fit. This used to refuse the whole spelling ("a pool count must be a
    /// literal"), because the read was the literal-only `u32Of` and an expression came back null,
    /// which the `orelse 1` then turned into a one-instance pool. The read
    /// evaluates now, so the range check below is the only guard needed and
    /// `:pool (* COPIES 3)` is rejected for the reason its author cares about.
    fn reservePool(self: *Emitter, r: *const Reader, form: NodeIndex, table: *IdTable(u16), name: []const u8) Error!struct { base: u16, size: u8 } {
        const requested = (try self.optU32(r, form, "pool")) orelse 1;
        if (requested < 1 or requested > MAX_POOL_SIZE) {
            self.diagnose(.sjon, self.locate(r, form), "", "'{s}' declares :pool {d}, but a pool holds at most {d} instances (the pool index is a byte everywhere the wire encodes it)", .{ name, requested, MAX_POOL_SIZE });
            return error.ValidationError;
        }
        const pool_size: u8 = @intCast(requested);
        if (@as(u32, table.next) + pool_size > std.math.maxInt(u16)) {
            self.diagnose(.sjon, self.locate(r, form), "", "'{s}' does not fit: this document has already reserved {d} of the {d} resource ids of its kind that the bytecode can address", .{ name, table.next, std.math.maxInt(u16) });
            return error.ValidationError;
        }
        return .{ .base = try table.reserve(self.gpa, name, pool_size), .size = pool_size };
    }

    /// Allocate the next document-wide pass id for `name` (kind render/compute),
    /// registering it — but reject before overflowing the shipping executor's
    /// fixed pass table. wasm_entry.zig stores a pass range only when the id is
    /// < wasm_config.max_passes (default bytecode.DEFAULT_MAX_PASSES); a pass
    /// beyond that index is silently dropped at load, so the frame renders in
    /// native `--frame`/tests (the reference dispatcher's pass map is unbounded)
    /// but loses passes in every browser. Caught here, at the boundary, rather
    /// than shipping a PNG that renders differently than it previews. The
    /// silent-drop behavior it guards against is pinned by
    /// tests/zig/executor/wasm_entry_pass_cap_test.zig.
    fn allocPassId(self: *Emitter, r: *const Reader, form: NodeIndex, name: []const u8, kind: PassType) Error!u16 {
        std.debug.assert(name.len > 0);
        if (self.tables.passes.next >= bytecode.DEFAULT_MAX_PASSES) {
            self.diagnose(.sjon, self.locate(r, form), "", "pass '{s}' is pass #{d}, but the browser executor stores at most {d} passes — passes beyond that are silently dropped at load (native `--frame` has no such cap, so this renders in a preview but not in a browser)", .{ name, self.tables.passes.next + 1, bytecode.DEFAULT_MAX_PASSES });
            return error.ValidationError;
        }
        const pass_id = try self.tables.passes.intern(self.gpa, name);
        try self.tables.pass_types.put(self.gpa, name, kind);
        std.debug.assert(self.tables.passes.next <= bytecode.DEFAULT_MAX_PASSES);
        return pass_id;
    }

    /// C6 / D9 and D12 (05 §5) — a clear value belongs with a `clear`.
    ///
    /// Two rules, one per direction, over the colour attachments and the depth
    /// one:
    ///
    /// - **Stated beside `load`** — WebGPU ignores it, so the document says a
    ///   colour (or a depth) that never happens. Stricter than the spec on
    ///   purpose: the schema description used to carry "(ignored for load)",
    ///   which is the DSL telling an author their input is inert.
    /// - **Missing under `clear`, for DEPTH only** — `depthClearValue` has no
    ///   spec default, so an absent one used to bake the emitter's 1.0. That is
    ///   the single number in a depth pass that decides whether anything is
    ///   visible, and PNGine was picking it. The colour attachment is left
    ///   alone: `clearValue` DOES have a spec default (transparent black), so
    ///   an omission there means something.
    ///
    /// Not the schema's, though `(variant :when clear …)` is exactly this shape:
    /// SJON's variants are positional, so adopting one would require
    /// `:load-op` to be written before `:clear-value` in every document — a key
    /// ORDER rule inside a form, which WebGPU does not have.
    fn checkAttachmentClearValues(self: *Emitter, r: *const Reader, form: NodeIndex, pass_name: []const u8) Error!void {
        var it = r.childrenWithHead(form, "color-attachment");
        var idx: u8 = 0;
        while (it.next()) |att| : (idx += 1) {
            const load_op = r.symbol(att, "load-op") orelse continue;
            if (std.mem.eql(u8, load_op, "load") and r.authorNode(att, "clear-value") != null) {
                self.diagnose(.sjon, self.locate(r, att), "", "color attachment {d} of render-pass '{s}' states a :clear-value beside ':load-op load' — WebGPU loads the existing contents and never reads the value", .{ idx, pass_name });
                return error.ValidationError;
            }
        }
        const da = r.child(form, "depth-stencil-attachment") orelse return;
        const depth_op = r.symbol(da, "depth-load-op") orelse return;
        const has_depth_clear = r.authorNode(da, "depth-clear-value") != null;
        if (std.mem.eql(u8, depth_op, "load") and has_depth_clear) {
            self.diagnose(.sjon, self.locate(r, da), "", "depth attachment of render-pass '{s}' states a :depth-clear-value beside ':depth-load-op load' — WebGPU loads the existing depth and never reads the value", .{pass_name});
            return error.ValidationError;
        }
        if (std.mem.eql(u8, depth_op, "clear") and !has_depth_clear) {
            self.diagnose(.sjon, self.locate(r, da), "", "depth attachment of render-pass '{s}' clears without a :depth-clear-value — WebGPU has no default for it, so the depth every fragment tests against would be PNGine's guess", .{pass_name});
            return error.ValidationError;
        }
        if (r.symbol(da, "stencil-load-op")) |stencil_op| {
            if (std.mem.eql(u8, stencil_op, "load") and r.authorNode(da, "stencil-clear-value") != null) {
                self.diagnose(.sjon, self.locate(r, da), "", "depth attachment of render-pass '{s}' states a :stencil-clear-value beside ':stencil-load-op load' — WebGPU loads the existing stencil and never reads the value", .{pass_name});
                return error.ValidationError;
            }
        }
    }

    /// C14 (05 §5) — a render pass needs somewhere to write. WebGPU's
    /// beginRenderPass rejects a descriptor with an empty `colorAttachments` and
    /// no `depthStencilAttachment`.
    ///
    /// PNGine used to fill the gap by inventing one: zero attachments meant "the
    /// canvas". That is R6's defect — a value the IDL does not default, supplied
    /// by the DSL — and nothing relied on it (all 237 corpus render-passes state
    /// their attachments, and `pngine/pass-v1` synthesizes a colour attachment of
    /// its own). The zero-attachment arm below stays for the DEPTH-ONLY pass,
    /// which is legal and reaches it with `depth_texture_id` set.
    ///
    /// Not the schema's: a head-set's `:min-children` counts the whole set, and
    /// this counts two heads of eight (a `(draw …)` must not satisfy it).
    fn checkPassHasAttachment(self: *Emitter, r: *const Reader, form: NodeIndex, name: []const u8) Error!void {
        if (r.child(form, "depth-stencil-attachment") != null) return;
        var it = r.childrenWithHead(form, "color-attachment");
        if (it.next() != null) return;
        self.diagnose(.sjon, self.locate(r, form), "", "render-pass '{s}' has no (color-attachment …) and no (depth-stencil-attachment …) — WebGPU needs at least one attachment to begin a render pass", .{name});
        return error.ValidationError;
    }

    /// Audit 09 §7 — a pass that draws needs the pipeline its draws run under.
    /// WebGPU validates every draw against the pass's current pipeline, so a
    /// pass that never called setPipeline fails at its first draw; `:pipeline`
    /// is optional on a render pass only for the bundle-replay pass, whose
    /// bundles carry their own. This compiled to begin → draw → end until the
    /// site sweep probed it.
    ///
    /// Not the schema's: `:requires` relates two KEYS, and this relates the
    /// absence of a key to the presence of any of five positional heads.
    fn checkDrawsHavePipeline(self: *Emitter, r: *const Reader, form: NodeIndex, name: []const u8) Error!void {
        if (r.symbol(form, "pipeline") != null) return;
        const draw_heads = [_][]const u8{ "draw", "draw-indexed", "draw-indirect", "draw-indexed-indirect", "occlusion-query" };
        for (r.children(form)) |c| {
            if (r.tree.tagOf(c) != .form) continue;
            const head = r.head(c);
            for (draw_heads) |h| {
                if (!std.mem.eql(u8, head, h)) continue;
                self.diagnose(.sjon, self.locate(r, form), "", "render-pass '{s}' has a ({s} …) and no :pipeline — a draw runs under the pass's pipeline, so name one (a pass that only replays bundles may omit it; the bundles carry theirs)", .{ name, head });
                return error.ValidationError;
            }
        }
    }

    /// C15 (05 §5) — an `(occlusion-query …)` bracket lowers to
    /// beginOcclusionQuery, which WebGPU rejects unless the pass descriptor named
    /// an `occlusionQuerySet`: there is no pool to count the passing samples into.
    ///
    /// Not the schema's: `:requires` relates two KEYS, and this relates a key to
    /// the presence of a positional CHILD.
    fn checkOcclusionQuerySet(self: *Emitter, r: *const Reader, form: NodeIndex, name: []const u8) Error!void {
        if (r.symbol(form, "occlusion-query-set") != null) return;
        var it = r.childrenWithHead(form, "occlusion-query");
        const bracket = it.next() orelse return;
        self.diagnose(.sjon, self.locate(r, bracket), "", "render-pass '{s}' brackets draws in an (occlusion-query …) but states no :occlusion-query-set — WebGPU has no query pool to count the passing samples into", .{name});
        return error.ValidationError;
    }

    /// C5 (05 §5) — the depth/stencil attachment's ops must match the VIEW's
    /// aspects, in both directions. WebGPU requires `depthLoadOp` and
    /// `depthStoreOp` when the format has a depth aspect and FORBIDS them when it
    /// has none; likewise the stencil pair. An attachment cannot leave half of its
    /// own format unaddressed, and cannot address an aspect the texture lacks.
    ///
    /// This is also the correction to D13. That decision made the depth pair
    /// unconditionally required in the schema, which is right for a depth format
    /// and wrong for `stencil8`: it made a stencil-only attachment unwritable. The
    /// requirement is conditional on the view's format, three forms away, so the
    /// schema cannot hold either direction and both live here.
    ///
    /// Skips a canvas view and an unresolved texture (`attachmentTextureFormat`
    /// returns null) and the two format sentinels — never a false reject.
    fn checkDepthAttachmentAspects(self: *Emitter, r: *const Reader, form: NodeIndex, pass_name: []const u8) Error!void {
        const da = r.child(form, "depth-stencil-attachment") orelse return;
        const view = r.symbol(da, "view") orelse return;
        const af = self.attachmentTextureFormat(view) orelse return;
        if (isFormatSentinel(af.fmt)) return;
        const loc = self.locate(r, da);

        if (!af.fmt.hasDepth() and !af.fmt.hasStencil()) {
            self.diagnose(.sjon, loc, "", "render-pass '{s}' attaches texture '{s}' with :format '{s}' as its depth/stencil target — a depth-stencil attachment takes a depth or stencil format", .{ pass_name, view, af.str });
            return error.ValidationError;
        }

        // Two aspects, the same rule each: present iff the format carries it.
        const aspects = [_]struct { has: bool, name: []const u8, load: []const u8, store: []const u8 }{
            .{ .has = af.fmt.hasDepth(), .name = "depth", .load = "depth-load-op", .store = "depth-store-op" },
            .{ .has = af.fmt.hasStencil(), .name = "stencil", .load = "stencil-load-op", .store = "stencil-store-op" },
        };
        for (aspects) |a| {
            const has_load = r.symbol(da, a.load) != null;
            const has_store = r.symbol(da, a.store) != null;
            if (a.has) {
                if (has_load and has_store) continue;
                const missing: []const u8 = if (!has_load) a.load else a.store;
                self.diagnose(.sjon, loc, "", "the depth/stencil attachment of render-pass '{s}' omits :{s}, but its view '{s}' is :format '{s}', which has a {s} aspect — WebGPU requires both {s} ops and defaults neither", .{ pass_name, missing, view, af.str, a.name, a.name });
                return error.ValidationError;
            }
            if (!has_load and !has_store) continue;
            const stated: []const u8 = if (has_load) a.load else a.store;
            self.diagnose(.sjon, loc, "", "the depth/stencil attachment of render-pass '{s}' states :{s}, but its view '{s}' is :format '{s}', which has no {s} aspect", .{ pass_name, stated, view, af.str, a.name });
            return error.ValidationError;
        }
    }

    /// C19 (05 §5), part three — `executeBundles` requires the replaying pass's
    /// layout to EQUAL each replayed bundle's. The pass's side is not written
    /// anywhere: WebGPU derives it from the attachments, taking each color format
    /// from the attachment's texture, the depth format from the depth attachment's,
    /// and the sample count from the texture too. So the three facts this compares
    /// live one form away from the pass and were, until now, joined against nothing
    /// at all — a pass that replays bundles states no `:pipeline`, which is exactly
    /// the condition under which `checkRenderPassPipeline` returns early.
    ///
    /// Gated on `validate_shaders` (that is what fills `bundle_meta`), and
    /// conservative in the same places as the pipeline join: a canvas view, an
    /// unresolved texture and a sentinel format all skip the format compare, and
    /// the sample-count compare fires only on an EXPLICIT count above 1 (an
    /// omitted or expression `:sample-count` on the texture is the
    /// simple_triangle_msaa pattern, never a false reject).
    fn checkReplayedBundles(self: *Emitter, r: *const Reader, form: NodeIndex, pass_name: []const u8) Error!void {
        if (!self.validate_shaders) return;
        const bundles = r.vectorNodes(form, "execute-bundles") orelse return;
        const atts = gatherPassAttachments(r, form);

        for (bundles) |b| {
            const bname = r.elemSymbol(b) orelse continue;
            const bid = self.tables.render_bundles.get(bname) orelse continue;
            const layout = self.binds.bundle_meta.get(bid) orelse continue;

            // Color count. A pass replaying bundles has no pipeline and no
            // default to allow for: the count is what is written.
            if (atts.count != layout.total) {
                self.diagnose(.sjon, self.locate(r, form), "", "render-pass '{s}' has {d} color attachment(s) but replays render-bundle '{s}', recorded against {d} color format(s)", .{ pass_name, atts.count, bname, layout.total });
                return error.ValidationError;
            }

            // Per-slot color format, against the ATTACHMENT's texture.
            const n = @min(atts.stored, layout.len);
            var i: u8 = 0;
            while (i < n) : (i += 1) {
                const declared = layout.formats[i];
                const af = self.attachmentTextureFormat(atts.views[i]) orelse continue;
                if (isFormatSentinel(af.fmt) or isFormatSentinel(declared.fmt)) continue;
                if (af.fmt != declared.fmt) {
                    self.diagnose(.sjon, self.locate(r, atts.nodes[i]), "", "color attachment {d} of render-pass '{s}' writes texture '{s}' with :format '{s}' but replayed render-bundle '{s}' was recorded against '{s}'", .{ i, pass_name, atts.views[i], af.str, bname, declared.spelling });
                    return error.ValidationError;
                }
            }

            try self.checkReplayedBundleDepth(r, form, pass_name, bname, atts, layout);
            try self.checkReplayedBundleSamples(r, pass_name, bname, atts, layout);
        }
    }

    /// C19's depth half — presence in both directions, then the format. The pass's
    /// depthStencilFormat is its depth attachment's texture format, and an absent
    /// attachment derives an absent format, which does not equal a stated one.
    fn checkReplayedBundleDepth(self: *Emitter, r: *const Reader, form: NodeIndex, pass_name: []const u8, bname: []const u8, atts: PassAttachments, layout: BundleMeta) Error!void {
        const pass_depth = atts.depth;
        if ((pass_depth != null) != (layout.ds_format != null)) {
            if (layout.ds_format != null) {
                self.diagnose(.sjon, self.locate(r, form), "", "render-pass '{s}' has no depth attachment but replays render-bundle '{s}', recorded against :depth-stencil-format '{s}'", .{ pass_name, bname, layout.ds_spelling });
            } else {
                self.diagnose(.sjon, self.locate(r, pass_depth.?), "", "render-pass '{s}' has a depth attachment but replays render-bundle '{s}', which records no :depth-stencil-format", .{ pass_name, bname });
            }
            return error.ValidationError;
        }
        const da = pass_depth orelse return;
        const bf = layout.ds_format.?; // presence agreed one branch up
        const dview = r.symbol(da, "view") orelse "";
        const df = self.attachmentTextureFormat(dview) orelse return;
        if (isFormatSentinel(df.fmt) or isFormatSentinel(bf) or df.fmt == bf) return;
        self.diagnose(.sjon, self.locate(r, da), "", "depth attachment of render-pass '{s}' writes texture '{s}' with :format '{s}' but replayed render-bundle '{s}' was recorded against '{s}'", .{ pass_name, dview, df.str, bname, layout.ds_spelling });
        return error.ValidationError;
    }

    /// C19's sample-count half. The pass's sampleCount comes from the attachment's
    /// TEXTURE — three forms away from the bundle it disagrees with — so this is the
    /// one field of the layout no one reading the pass can see.
    fn checkReplayedBundleSamples(self: *Emitter, r: *const Reader, pass_name: []const u8, bname: []const u8, atts: PassAttachments, layout: BundleMeta) Error!void {
        const bundle_ms = layout.sample_count orelse return; // nothing recorded → skip
        var i: u8 = 0;
        while (i < atts.stored) : (i += 1) {
            try self.compareBundleSamples(r, atts.nodes[i], pass_name, bname, atts.views[i], bundle_ms);
        }
        if (atts.depth) |da| {
            try self.compareBundleSamples(r, da, pass_name, bname, r.symbol(da, "view") orelse "", bundle_ms);
        }
    }

    /// One attachment's texture sample count against the bundle's. Fires only on an
    /// EXPLICIT count above 1, the same conservatism as `checkSampleCounts`: an
    /// omitted or unreadable `:sample-count` reads as 1 while the rest of the
    /// document may legitimately be multisampled (the simple_triangle_msaa pattern).
    fn compareBundleSamples(self: *Emitter, r: *const Reader, node: NodeIndex, pass_name: []const u8, bname: []const u8, view: []const u8, bundle_ms: u32) Error!void {
        const tm = self.attachmentTextureMeta(view) orelse return;
        const sc = tm.sample_count orelse return;
        if (sc <= 1 or sc == bundle_ms) return;
        self.diagnose(.sjon, self.locate(r, node), "", "render-pass '{s}' writes texture '{s}' with :sample-count {d} but replays render-bundle '{s}', recorded against {d} sample(s)", .{ pass_name, view, sc, bname, bundle_ms });
        return error.ValidationError;
    }

    fn emitRenderPass(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const name = try self.requiredSymbol(r, form, "name");
        std.debug.assert(name.len > 0); // pre: named form (validator guarantees it)
        const pass_id = try self.allocPassId(r, form, name, .render);
        std.debug.assert(pass_id < bytecode.DEFAULT_MAX_PASSES); // post: within browser cap

        // R5a: the render-pass ↔ pipeline attachment-agreement checks (gated on
        // validate_shaders; a no-op on the golden/parity path). Runs before any
        // emission so a disagreement is reported before opcodes are written.
        // Attachment EXISTENCE first: `checkRenderPassPipeline` compares an
        // attachment count against the pipeline's target count, so a pass with no
        // attachments at all would otherwise be reported as a count mismatch.
        try self.checkPassHasAttachment(r, form, name);
        try self.checkDrawsHavePipeline(r, form, name);
        try self.checkOcclusionQuerySet(r, form, name);
        try self.checkDepthAttachmentAspects(r, form, name);
        try self.checkRenderPassPipeline(r, form, name);
        try self.checkReplayedBundles(r, form, name);
        try self.checkAttachmentClearValues(r, form, name);

        const em = self.builder.getEmitter();
        const desc_id = self.builder.addData(self.gpa, "{}") catch return error.OutOfMemory;
        em.definePass(self.gpa, pass_id, .render, desc_id.toInt()) catch return error.OutOfMemory;

        // Pre-pass state, in the legacy emission order occlusion → timestamp →
        // depth-stencil-ops (passes.zig:98/123/155).
        try self.emitPrePassState(r, form);

        // depth attachment → depth texture id (+ non-default load/store ops, which
        // the legacy emits as a pre-pass set_pass_depth_stencil_ops).
        var depth_texture_id: u16 = values.NO_TEXTURE_ID;
        if (r.child(form, "depth-stencil-attachment")) |da| {
            if (r.symbol(da, "view")) |v| depth_texture_id = self.tables.textures.get(v) orelse values.NO_TEXTURE_ID;
            try self.emitDepthStencilOps(r, da);
            try self.emitPassClearValues(r, da);
        }

        // color attachment(s) → begin the pass. Gather the (color-attachment …)
        // sub-forms (author order, MRT-capable; a view/resolve-target is the canvas
        // context-current-texture or a declared MSAA/G-buffer texture), then pick
        // and emit the begin opcode (pooled feedback / MRT / single-or-zero).
        const cols = try self.gatherColorAttachments(r, form);
        try self.beginPassForAttachments(cols, depth_texture_id);

        // pipeline
        if (r.symbol(form, "pipeline")) |p| {
            const pid = self.tables.pipelines.get(p) orelse return self.unresolvedRef(r, form, "pipeline", p);
            em.setPipeline(self.gpa, pid) catch return error.OutOfMemory;
        }

        // vertex/index buffers + bind groups, in document order.
        try self.emitPassBindings(r, form);

        // Stencil reference (before draw, after bind groups — matching the legacy
        // source-order emission of the pass body).
        if (try self.optU32(r, form, "stencil-reference")) |sref|
            em.setStencilReference(self.gpa, sref) catch return error.OutOfMemory;

        // Blend constant (before draw): the value the `constant`/`one-minus-constant`
        // blend factors multiply by. Read [r g b a] as f32 → raw bit patterns.
        if (r.vectorNodes(form, "blend-constant")) |bc| {
            var bits: [4]u32 = .{ 0, 0, 0, 0 };
            for (bc, 0..) |elem, i| {
                if (i >= 4) break;
                bits[i] = @bitCast(@as(f32, @floatCast(try self.elemF64(r, elem, 0.0))));
            }
            em.setBlendConstant(self.gpa, bits[0], bits[1], bits[2], bits[3]) catch return error.OutOfMemory;
        }

        try self.emitViewportScissor(r, form);
        try self.emitPassDraws(r, form, name);
        try self.emitExecuteBundles(r, form, name);

        em.endPass(self.gpa) catch return error.OutOfMemory;
        em.endPassDef(self.gpa) catch return error.OutOfMemory;
    }

    /// Pre-`begin_render_pass` state: occlusion-query-set selection then
    /// timestamp-writes, in the legacy passes.zig order (occlusion → timestamp).
    fn emitPrePassState(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        std.debug.assert(r.tree.tagOf(form) == .form); // pre: called on a render-pass form
        const em = self.builder.getEmitter();
        // An :occlusion-query-set names the (query-set :type occlusion) the
        // bracketed draws below write into.
        if (r.symbol(form, "occlusion-query-set")) |oqs| {
            const qs_id = self.tables.query_sets.get(oqs) orelse return self.unresolvedRef(r, form, "query-set", oqs);
            em.setPassOcclusionQuerySet(self.gpa, qs_id) catch return error.OutOfMemory;
        }
        // timestamp-writes (before begin_render_pass) — the legacy passes.zig:123 position.
        if (r.child(form, "timestamp-writes")) |tw| {
            const qs_name = try self.requiredSymbol(r, tw, "query-set");
            const qs_id = self.tables.query_sets.get(qs_name) orelse return self.unresolvedRef(r, tw, "query-set", qs_name);
            // timestamp-writes is never hook-emitted: the schema :default 0/1 always materializes.
            const begin = try self.requiredU32(r, tw, "beginning-of-pass-write-index");
            const end = try self.requiredU32(r, tw, "end-of-pass-write-index");
            em.setPassTimestampWrites(self.gpa, qs_id, begin, end) catch return error.OutOfMemory;
        }
    }

    /// Emit set_vertex_buffer / set_index_buffer / set_bind_group in document
    /// order — mirroring the legacy pass-property loop (passes.zig:506). Their
    /// relative order is author-controlled (e.g. textured_rotating_cube lists
    /// bindGroups before vertexBuffers) and the golden traces pin the call
    /// sequence position-by-position, so a fixed order would diverge.
    fn emitPassBindings(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        std.debug.assert(r.tree.tagOf(form) == .form); // pre: called on a render-pass form
        for (r.children(form)) |c| {
            if (r.tree.tagOf(c) != .kvpair) continue;
            const key = r.tree.kvpairHeader(c).key;
            if (std.mem.eql(u8, key, "vertex-buffers")) {
                try self.emitVertexBuffers(r, form);
            } else if (std.mem.eql(u8, key, "index-buffer")) {
                try self.emitIndexBuffer(r, form);
            } else if (std.mem.eql(u8, key, "bind-groups")) {
                try self.emitBindGroups(r, form);
            }
        }
    }

    /// Emit the pass's draw commands in DOCUMENT order: every `(draw …)`,
    /// `(draw-indexed …)`, `(draw-indirect …)`, `(draw-indexed-indirect …)` and
    /// `(occlusion-query …)` bracket, as it comes.
    ///
    /// It used to emit ONE draw, chosen by a priority over the four heads
    /// (`draw` first, then `draw-indexed`, …). A pass with two draws — legal
    /// WebGPU, and the whole point of binding a vertex buffer once — silently
    /// drew the first and dropped the rest; a pass whose second draw was
    /// `draw-indexed` and whose first was `draw` dropped the indexed one no
    /// matter which the author wrote first (F3). The occlusion brackets were a
    /// second, separate walk for exactly this reason; they are the same walk now,
    /// because a bracket is a draw with a begin/end around it.
    fn emitPassDraws(self: *Emitter, r: *const Reader, form: NodeIndex, name: []const u8) Error!void {
        std.debug.assert(r.tree.tagOf(form) == .form); // pre: called on a render-pass form
        std.debug.assert(name.len > 0);
        const em = self.builder.getEmitter();
        var commands: u32 = 0;
        for (r.children(form)) |c| {
            if (r.tree.tagOf(c) != .form) continue;
            const head = r.head(c);
            if (std.mem.eql(u8, head, "draw") or std.mem.eql(u8, head, "draw-indexed")) {
                try self.emitDrawForm(r, c);
            } else if (std.mem.eql(u8, head, "draw-indirect")) {
                // Args buffer + byte offset; the 4×u32 GPUDrawIndirectArgs are read
                // GPU-side (no index buffer needed, unlike draw-indexed-indirect).
                try self.emitDrawIndirect(r, c, false);
            } else if (std.mem.eql(u8, head, "draw-indexed-indirect")) {
                // Args buffer + byte offset; the 5×u32 GPUDrawIndexedIndirectArgs are
                // read GPU-side (mirrors legacy emitDrawIndexedIndirectCommand).
                try self.emitDrawIndirect(r, c, true);
            } else if (std.mem.eql(u8, head, "occlusion-query")) {
                // A bracket: begin_occlusion_query(N) → its inner draw(s) →
                // end_occlusion_query. The GPU samples-passed counter is read back
                // later via a (resolve-query-set …) queue op.
                // occlusion-query is never hook-emitted: the schema :default 0 always materializes.
                const qidx = try self.requiredU32(r, c, "query-index");
                em.beginOcclusionQuery(self.gpa, qidx) catch return error.OutOfMemory;
                for (r.children(c)) |dc| {
                    if (r.tree.tagOf(dc) != .form) continue;
                    const h = r.head(dc);
                    // Any of the four draws (audit 09 D24) — the schema's
                    // head-set is the closed list, this is the dispatch.
                    if (std.mem.eql(u8, h, "draw") or std.mem.eql(u8, h, "draw-indexed")) {
                        try self.emitDrawForm(r, dc);
                    } else if (std.mem.eql(u8, h, "draw-indirect")) {
                        try self.emitDrawIndirect(r, dc, false);
                    } else if (std.mem.eql(u8, h, "draw-indexed-indirect")) {
                        try self.emitDrawIndirect(r, dc, true);
                    }
                }
                em.endOcclusionQuery(self.gpa) catch return error.OutOfMemory;
            } else continue;
            commands += 1;
            try self.checkCommandsFit(r, form, name, "render-pass", commands);
        }
    }

    /// `(draw-indirect …)` / `(draw-indexed-indirect …)`: the args live in a
    /// buffer and are read GPU-side. Same two keys either way.
    fn emitDrawIndirect(self: *Emitter, r: *const Reader, node: NodeIndex, indexed: bool) Error!void {
        const bname = try self.requiredSymbol(r, node, "buffer");
        const bid = self.tables.buffers.get(bname) orelse return self.unresolvedRef(r, node, "buffer", bname);
        const offset = (try self.optU32(r, node, "offset")) orelse 0;
        const em = self.builder.getEmitter();
        if (indexed)
            em.drawIndexedIndirect(self.gpa, bid, offset) catch return error.OutOfMemory
        else
            em.drawIndirect(self.gpa, bid, offset) catch return error.OutOfMemory;
    }

    /// Refuse a pass whose command count alone can tear the frame's command
    /// buffer. The same cap `checkQueueActionsFit` counts for a queue's actions —
    /// commands became repeatable in this cut, so they need the same bound.
    fn checkCommandsFit(self: *Emitter, r: *const Reader, form: NodeIndex, name: []const u8, kind: []const u8, commands: u32) Error!void {
        std.debug.assert(name.len > 0);
        std.debug.assert(commands > 0);
        if (commands <= MAX_FRAME_STEPS) return;
        self.diagnose(.sjon, self.locate(r, form), "", "{s} '{s}' issues more than {d} commands — the 64 KB command buffer cannot describe them all", .{ kind, name, MAX_FRAME_STEPS });
        return error.ValidationError;
    }

    /// Emit execute_bundles for pre-recorded render bundles replayed in this pass.
    /// A bundle-executing pass carries no inline pipeline/draw (the bundle records
    /// them), so this is the only command between begin and end. The execute_bundles
    /// opcode carries at most bytecode.MAX_EXECUTE_BUNDLES ids — a fixed [16]u16
    /// decode buffer in BOTH wasm_entry and the reference dispatcher — so a pass
    /// listing more would silently lose bundles at load (item 1.6). Reject it up
    /// front rather than truncate.
    fn emitExecuteBundles(self: *Emitter, r: *const Reader, form: NodeIndex, name: []const u8) Error!void {
        std.debug.assert(name.len > 0); // pre: named pass (for the over-cap diagnostic)
        const em = self.builder.getEmitter();
        if (r.vectorNodes(form, "execute-bundles")) |bundles| {
            if (bundles.len > bytecode.MAX_EXECUTE_BUNDLES) {
                self.diagnose(.sjon, self.locate(r, form), "", "render-pass '{s}' replays {d} bundles, but the execute_bundles opcode carries at most {d} — bundles beyond that are silently dropped at load", .{ name, bundles.len, bytecode.MAX_EXECUTE_BUNDLES });
                return error.ValidationError;
            }
            var ids: [bytecode.MAX_EXECUTE_BUNDLES]u16 = undefined;
            var n: usize = 0;
            for (bundles) |b| {
                // The length guard above already rejected an over-long list, so
                // this bound is defensive only — it can no longer truncate.
                if (n >= ids.len) break;
                const sym = try self.descListSymbol(r, b);
                ids[n] = self.tables.render_bundles.get(sym) orelse {
                    // Same class as `bundleRef`, and it was erroring UNLOCATED —
                    // `validate` printed a bare "emit failed" with no clue which
                    // name failed. Say which one, and where.
                    self.diagnose(.sjon, self.locate(r, form), "", "render-pass '{s}' replays bundle '{s}', which has no id at pass-emit time — a pass can only replay (render-bundle …) forms declared in the source document", .{ name, sym });
                    return error.EmitError;
                };
                n += 1;
            }
            if (n > 0) em.executeBundles(self.gpa, ids[0..n]) catch return error.OutOfMemory;
        }
    }

    /// Emit a `#renderBundle` as a create_render_bundle opcode + descriptor blob.
    /// The descriptor packs the recorded draw state (legacy `emitRenderBundles`
    /// format, byte-for-byte): colorFormats count+ids (u8), depthStencilFormat
    /// (u8, 0xFF=none), sampleCount (u8), pipeline_id (u16 LE), bindGroups
    /// count+ids (u16 LE), vertexBuffers count+ids (u16 LE), hasIndexBuffer (u8)
    /// [+ id u16 LE], drawType (u8: 0=draw/1=drawIndexed), draw params (u32 LE).
    /// Read the `GPURenderPassLayout` a `(render-bundle …)` writes down. A re-walk
    /// of the three layout keys, kept separate from the descriptor emission below
    /// so the checks run before a single byte is appended.
    fn gatherBundleLayout(self: *Emitter, r: *const Reader, form: NodeIndex) Error!BundleMeta {
        var layout: BundleMeta = .{};
        if (r.vectorNodes(form, "color-formats")) |cfs| {
            layout.total = @intCast(@min(cfs.len, std.math.maxInt(u16)));
            for (cfs) |c| {
                if (layout.len >= layout.formats.len) break;
                const sym = try self.descListSymbol(r, c);
                layout.formats[layout.len] = .{ .fmt = values.mapTextureFormat(sym), .spelling = sym };
                layout.len += 1;
            }
        }
        if (r.symbol(form, "depth-stencil-format")) |ds| {
            layout.ds_format = values.mapTextureFormat(ds);
            layout.ds_spelling = ds;
        }
        layout.sample_count = if (r.authorNode(form, "sample-count") == null)
            1 // absent ⇒ the IDL default, a definite 1 — not "unknown"
        else
            try self.optU32(r, form, "sample-count");
        return layout;
    }

    /// C19 (05 §5), part one — the two rules `createRenderBundleEncoder` states
    /// about the formats it is handed, before any pipeline or pass is involved:
    /// every color slot takes a color-renderable format, and the depth slot takes
    /// a depth-or-stencil one. Its third rule ("there must exist at least one
    /// attachment") is already the schema's, as `:color-formats` `:min-len 1`.
    ///
    /// Document-local — nothing outside the form is read — so it is ungated, and
    /// it runs before either join: a bundle whose own descriptor is malformed
    /// should say so rather than report the disagreement that follows from it.
    fn checkBundleFormatClasses(self: *Emitter, r: *const Reader, form: NodeIndex, name: []const u8, layout: BundleMeta) Error!void {
        std.debug.assert(name.len > 0); // pre: named form (validator guarantees it)
        const loc = self.locate(r, form);
        var i: u8 = 0;
        while (i < layout.len) : (i += 1) {
            const f = layout.formats[i];
            if (!f.fmt.hasDepth() and !f.fmt.hasStencil()) continue;
            self.diagnose(.sjon, loc, "", "render-bundle '{s}' lists '{s}' at :color-formats slot {d} — that list holds COLOR attachment formats, and a depth/stencil format can only be the :depth-stencil-format", .{ name, f.spelling, i });
            return error.ValidationError;
        }
        const ds = layout.ds_format orelse return;
        if (ds.hasDepth() or ds.hasStencil()) return;
        self.diagnose(.sjon, loc, "", "render-bundle '{s}' sets :depth-stencil-format '{s}', which has neither a depth nor a stencil aspect", .{ name, layout.ds_spelling });
        return error.ValidationError;
    }

    /// C19 (05 §5), part two — `setPipeline` inside the bundle encoder requires the
    /// layout the bundle DECLARES to equal the layout DERIVED from the pipeline it
    /// records. Same three fields as the pass join below, read from `PipelineMeta`
    /// instead of from attachments.
    ///
    /// Gated on `validate_shaders` (that is what fills `pipeline_meta`), and
    /// conservative in the same places as the pipeline↔pass check: a
    /// zero-target pipeline, an unresolved name, a compute pipeline or a
    /// sentinel format on either side all SKIP.
    fn checkBundlePipeline(self: *Emitter, r: *const Reader, form: NodeIndex, name: []const u8, layout: BundleMeta) Error!void {
        if (!self.validate_shaders) return;
        const pname = r.symbol(form, "pipeline") orelse return;
        const pid = self.tables.pipelines.get(pname) orelse return;
        const meta = self.binds.pipeline_meta.get(pid) orelse return;
        const loc = self.locate(r, form);

        if (meta.targets_known) {
            if (layout.total != meta.targets_total) {
                self.diagnose(.sjon, loc, "", "render-bundle '{s}' records {d} color format(s) but pipeline '{s}' declares {d} color target(s) — a bundle's layout must EQUAL its pipeline's", .{ name, layout.total, pname, meta.targets_total });
                return error.ValidationError;
            }
            const n = @min(layout.len, meta.targets_len);
            var i: u8 = 0;
            while (i < n) : (i += 1) {
                const declared = layout.formats[i];
                const target = meta.targets[i];
                if (isFormatSentinel(declared.fmt) or isFormatSentinel(target.fmt)) continue;
                if (declared.fmt != target.fmt) {
                    self.diagnose(.sjon, loc, "", "render-bundle '{s}' records :color-formats slot {d} as '{s}' but pipeline '{s}' declares color target {d} as :format '{s}'", .{ name, i, declared.spelling, pname, i, target.spelling });
                    return error.ValidationError;
                }
            }
        }

        if ((layout.ds_format != null) != meta.ds_present) {
            if (meta.ds_present) {
                self.diagnose(.sjon, loc, "", "pipeline '{s}' declares a depth-stencil state but render-bundle '{s}' records no :depth-stencil-format — an absent format is a value ('no depth attachment'), not a wildcard", .{ pname, name });
            } else {
                self.diagnose(.sjon, loc, "", "render-bundle '{s}' records :depth-stencil-format '{s}' but pipeline '{s}' declares no depth-stencil state", .{ name, layout.ds_spelling, pname });
            }
            return error.ValidationError;
        }
        if (layout.ds_format) |bf| {
            const pf = meta.ds_format.?; // ds_present ⇒ `:format` was authored
            if (!isFormatSentinel(bf) and !isFormatSentinel(pf) and bf != pf) {
                self.diagnose(.sjon, loc, "", "render-bundle '{s}' records :depth-stencil-format '{s}' but pipeline '{s}' declares depth-stencil :format '{s}'", .{ name, layout.ds_spelling, pname, meta.ds_spelling });
                return error.ValidationError;
            }
        }

        // An omitted count on either side is 1 — the IDL default, a definite value.
        // An UNREADABLE one (an expression) is null on both sides and skips.
        const pipe_ms = if (meta.ms_stated) meta.ms_count else 1;
        if (layout.sample_count) |bms| {
            if (pipe_ms) |pms| {
                if (bms != pms) {
                    self.diagnose(.sjon, loc, "", "render-bundle '{s}' records {d} sample(s) but pipeline '{s}' has sample count {d} — sampleCount is part of the layout, so the two must be equal", .{ name, bms, pname, pms });
                    return error.ValidationError;
                }
            }
        }
    }

    fn emitRenderBundle(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const name = try self.requiredSymbol(r, form, "name");
        const bundle_id = try self.tables.render_bundles.intern(self.gpa, name);

        // C19 — the bundle's declared GPURenderPassLayout: checked against itself
        // and against the pipeline it records, then RECORDED for the pass that
        // replays it (passes emit after bundles — see the `phases` table). All of
        // it runs before the descriptor is built, so a disagreement is reported
        // before any byte is written.
        const layout = try self.gatherBundleLayout(r, form);
        try self.checkBundleFormatClasses(r, form, name, layout);
        try self.checkBundlePipeline(r, form, name, layout);
        if (self.validate_shaders) try self.binds.bundle_meta.put(self.gpa, bundle_id, layout);

        var desc = std.ArrayList(u8).empty;
        defer desc.deinit(self.gpa);

        // colorFormats: count (u8) + texture-format ids (u8). `:color-formats` is
        // required, so the absent arm (count 0) is unreachable once validated.
        if (r.vectorNodes(form, "color-formats")) |cfs| {
            try self.checkDescListFits(r, form, name, "color-formats", cfs.len);
            try desc.append(self.gpa, @intCast(cfs.len));
            for (cfs) |c| {
                const sym = try self.descListSymbol(r, c);
                try desc.append(self.gpa, @intFromEnum(values.mapTextureFormat(sym)));
            }
        } else try desc.append(self.gpa, 0);

        // depthStencilFormat (u8, 0xFF = none).
        if (r.symbol(form, "depth-stencil-format")) |ds| {
            try desc.append(self.gpa, @intFromEnum(values.mapTextureFormat(ds)));
        } else try desc.append(self.gpa, 0xFF);

        // sampleCount (u8, default 1).
        const sample_count = (try self.optU32(r, form, "sample-count")) orelse 1;
        try desc.append(self.gpa, @intCast(sample_count & 0xFF));

        // pipeline_id (u16 LE). A bundle without a pipeline is degenerate → 0.
        // A bundle WITH one that fails to resolve is not (see `bundleRef`).
        const pipeline_id: u16 = if (r.symbol(form, "pipeline")) |p|
            try self.bundleRef(r, form, name, "pipeline", p, &self.tables.pipelines)
        else
            0;
        try appendU16LE(self.gpa, &desc, pipeline_id);

        // bindGroups: count (u8) + ids (u16 LE).
        try appendRefList(self, r, &desc, form, name, "bind-groups", "bind group", &self.tables.bind_groups);
        // vertexBuffers: count (u8) + ids (u16 LE).
        try appendRefList(self, r, &desc, form, name, "vertex-buffers", "vertex buffer", &self.tables.buffers);

        // indexBuffer: hasIndexBuffer (u8) [+ id u16 LE].
        if (r.symbol(form, "index-buffer")) |ib| {
            try desc.append(self.gpa, 1);
            try appendU16LE(self.gpa, &desc, try self.bundleRef(r, form, name, "index buffer", ib, &self.tables.buffers));
        } else try desc.append(self.gpa, 0);

        // draw command: drawType (u8) + params, read off the bundle's one
        // `(draw …)` / `(draw-indexed …)` child. The head-set makes it exactly
        // one, so this is a decode, not a choice — it used to be `:draw N` and
        // `:draw-indexed N` as sibling keys with "indexed wins if present"
        // between them, a third spelling of a draw that could state neither
        // `:first-vertex` nor `:base-vertex`. Now the recorded draw is the same
        // form, with the same keys, that the pass issues.
        const draw = r.child(form, "draw-indexed") orelse r.child(form, "draw") orelse {
            if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
                std.debug.panic("schema invariant broken: `render-bundle-command` does not floor its head-set at 1", .{});
            }
            self.diagnose(.sjon, self.locate(r, form), "", "internal: render-bundle '{s}' has no (draw …) / (draw-indexed …) child after validation", .{name});
            return error.EmitError;
        };
        if (std.mem.eql(u8, r.head(draw), "draw-indexed")) {
            try desc.append(self.gpa, 1); // drawIndexed
            try appendU32LE(self.gpa, &desc, try self.requiredU32(r, draw, "index-count"));
            try appendU32LE(self.gpa, &desc, try self.requiredU32(r, draw, "instance-count"));
            try appendU32LE(self.gpa, &desc, try self.requiredU32(r, draw, "first-index"));
            try appendU32LE(self.gpa, &desc, try self.requiredU32(r, draw, "base-vertex"));
            try appendU32LE(self.gpa, &desc, try self.requiredU32(r, draw, "first-instance"));
        } else {
            try desc.append(self.gpa, 0); // draw
            try appendU32LE(self.gpa, &desc, try self.requiredU32(r, draw, "vertex-count"));
            try appendU32LE(self.gpa, &desc, try self.requiredU32(r, draw, "instance-count"));
            try appendU32LE(self.gpa, &desc, try self.requiredU32(r, draw, "first-vertex"));
            try appendU32LE(self.gpa, &desc, try self.requiredU32(r, draw, "first-instance"));
        }

        const desc_id = self.builder.addData(self.gpa, desc.items) catch return error.OutOfMemory;
        self.builder.getEmitter().createRenderBundle(self.gpa, bundle_id, desc_id.toInt()) catch return error.OutOfMemory;
    }

    /// Emit a `(query-set …)` as a create_query_set opcode + descriptor blob. The blob
    /// is `[type:u8][count:u16-LE]` (legacy resources.zig:emitQuerySets), where type
    /// is 0=occlusion (default) / 1=timestamp.
    fn emitQuerySet(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const name = try self.requiredSymbol(r, form, "name");
        const qs_id = try self.tables.query_sets.intern(self.gpa, name);

        const query_type: u8 = if (r.symbol(form, "type")) |t|
            (if (std.mem.eql(u8, t, "timestamp")) @as(u8, 1) else 0)
        else
            0;
        // query-set is never hook-emitted and the schema requires :count. The
        // descriptor carries it in two bytes; the schema's 4096 ceiling is
        // re-checked here because a define-ref or expression skips the
        // validator's literal check — 70000 used to ship as its low 16 bits.
        const count = (try self.optBounded(r, form, "count", .query_count)) orelse
            try self.requiredU32(r, form, "count"); // null only if the schema invariant broke; requiredU32 says so

        const desc = [3]u8{ query_type, @intCast(count & 0xFF), @intCast((count >> 8) & 0xFF) };
        const did = self.builder.addData(self.gpa, &desc) catch return error.OutOfMemory;
        self.builder.getEmitter().createQuerySet(self.gpa, qs_id, did.toInt()) catch return error.OutOfMemory;
    }

    /// Resolve one render-bundle cross-ref to its emitted id, or fail loudly.
    ///
    /// A miss here is NOT "unreachable by construction", which is why this is a
    /// located diagnostic rather than an assert. The validator resolves
    /// cross-refs across the WHOLE forest — including the forms `(pass …)`/`(init …)`
    /// lowering synthesizes (`main__pipe`, `main__bg`, …) — but the
    /// `render-bundle` phase runs before `emitLowered()` (see the `phases`
    /// table), so a source bundle naming one of those validates cleanly and then
    /// misses here. The `orelse 0` this replaces encoded slot 0 for that miss:
    /// `(render-bundle :pipeline main__pipe)` alongside any other pipeline
    /// recorded the WRONG pipeline and rendered garbage with a zero exit code.
    /// Erroring matches what the sibling `execute-bundles` path already does.
    fn bundleRef(
        self: *Emitter,
        r: *const Reader,
        form: NodeIndex,
        bundle: []const u8,
        kind: []const u8,
        sym: []const u8,
        id_map: *const IdTable(u16),
    ) Error!u16 {
        std.debug.assert(kind.len > 0);
        std.debug.assert(sym.len > 0);
        if (id_map.get(sym)) |id| return id;
        self.diagnose(
            .sjon,
            self.locate(r, form),
            "",
            "render-bundle '{s}' references {s} '{s}', which has no id at bundle-record time — a bundle can only reference resources declared in the source document, not ones synthesized by `(pass …)`/`(init …)` lowering (those are emitted after bundles)",
            .{ bundle, kind, sym },
        );
        return error.EmitError;
    }

    /// Append a `name-list` of cross-refs to a descriptor: count (u8) + each id
    /// (u16 LE) resolved through `id_map`, via `bundleRef` (a miss is an error,
    /// not slot 0). Shared by bind-groups / vertex-buffers; `kind` is the
    /// singular human name for the diagnostic.
    fn appendRefList(
        self: *Emitter,
        r: *const Reader,
        desc: *std.ArrayList(u8),
        form: NodeIndex,
        bundle: []const u8,
        key: []const u8,
        kind: []const u8,
        id_map: *const IdTable(u16),
    ) Error!void {
        if (r.vectorNodes(form, key)) |elems| {
            try self.checkDescListFits(r, form, bundle, key, elems.len);
            try desc.append(self.gpa, @intCast(elems.len));
            for (elems) |e| {
                const sym = try self.descListSymbol(r, e);
                try appendU16LE(self.gpa, desc, try self.bundleRef(r, form, bundle, kind, sym, id_map));
            }
        } else try desc.append(self.gpa, 0);
    }

    /// Guard a `[count:u8][entry…]` descriptor list against a count that cannot
    /// describe its own body.
    ///
    /// The bundle descriptor is a flat blob with no field framing: the JS reader
    /// takes the count byte and then consumes exactly that many entries
    /// (`gpu-resource-pass-commands.js`). Writing `@min(len, 255)` as the count
    /// while appending ALL of them therefore desyncs everything downstream — the
    /// reader stops at 255, then parses the 256th entry's bytes as the next
    /// field, corrupting the vertex-buffer list, the index buffer, and the draw
    /// PARAMETERS. It emitted a clean exit code and drew garbage.
    ///
    /// Rejecting beats truncating: silently dropping the tail to match the count
    /// is the same silent-cap defect one layer up, and 256 bind groups is far
    /// past what any device accepts anyway, so no real document loses.
    /// A pass's `:vertex-buffers` / `:bind-groups` bind slots 0..N in order, and
    /// the wire carries a slot index in one byte — so the list holds at most 256
    /// names. The schema's ref-list has no `:max-len` (WebGPU's own maxBindGroups
    /// / maxVertexBuffers are device limits, far smaller); this is the wire's
    /// ceiling, refused here instead of at the `@intCast` on the slot.
    fn checkSlotListFits(self: *Emitter, r: *const Reader, form: NodeIndex, key: []const u8, len: usize) Error!void {
        std.debug.assert(key.len > 0);
        if (len <= 256) return;
        self.diagnose(.sjon, self.locate(r, r.authorNode(form, key) orelse form), "", "':{s}' lists {d} entries, but a slot index is one byte on the wire — at most 256 fit", .{ key, len });
        return error.ValidationError;
    }

    fn checkDescListFits(self: *Emitter, r: *const Reader, form: NodeIndex, bundle: []const u8, key: []const u8, len: usize) Error!void {
        std.debug.assert(key.len > 0);
        if (len <= 255) return;
        self.diagnose(.sjon, self.locate(r, form), "", "render-bundle '{s}': ':{s}' lists {d} entries, but the descriptor encodes its count in ONE byte — at most 255 fit", .{ bundle, key, len });
        return error.ValidationError;
    }

    /// Read a descriptor-list element as a symbol. Every such list is a schema
    /// symbol/cross-ref vector, so a non-symbol element is a broken invariant,
    /// not input — but it is the OTHER way a count can outrun its body (skipping
    /// the element while the count already claimed it), so it fails the emit
    /// instead of continuing. The descriptor is discarded on error, so a
    /// desynced blob is never handed to the builder.
    fn descListSymbol(self: *Emitter, r: *const Reader, elem: NodeIndex) Error![]const u8 {
        return r.elemSymbol(elem) orelse {
            std.debug.assert(false); // schema: descriptor lists hold symbols only
            self.diagnose(.sjon, self.locate(r, elem), "", "internal: a descriptor list element is not a symbol after validation", .{});
            return error.EmitError;
        };
    }

    /// Emit set_index_buffer for the render pass's `:index-buffer`, using the
    /// auto-detected index format recorded when the buffer was `:index-of` a shape.
    fn emitIndexBuffer(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const bname = r.symbol(form, "index-buffer") orelse return;
        const bid = self.tables.buffers.get(bname) orelse return self.unresolvedRef(r, form, "buffer", bname);
        // NOT the `orelse 0` defect `bundleRef` replaces, despite reading like it:
        // `buffer_index_formats` is SPARSE (only buffers that were `:index-of` a
        // shape are in it), and 0 is `mapIndexFormat`'s uint16 — a real default
        // for an absent entry, not a failed lookup encoding slot zero.
        const fmt = self.tables.buffer_index_formats.get(bid) orelse 0;
        self.builder.getEmitter().setIndexBuffer(self.gpa, bid, fmt) catch return error.OutOfMemory;
    }

    /// `Reader.elemU32` / `.elemEval` bound to this emitter's allocator, schema
    /// and `#define` env — the vector-element counterpart of the `evalU32` calls
    /// used for scalar slots. Every numeric vector element goes through one of
    /// these two; reaching for `Reader.elemNumber` directly reintroduces §307
    /// (an expression element silently becoming the `orelse` default).
    fn elemU32(self: *Emitter, r: *const Reader, elem: NodeIndex, default: u32) Error!u32 {
        return r.elemU32(self.gpa, self.schema, &self.env, elem, default) catch |e| self.refuseElem(r, elem, e);
    }

    fn elemF64(self: *Emitter, r: *const Reader, elem: NodeIndex, default: f64) Error!f64 {
        const n = r.elemEval(self.gpa, self.schema, &self.env, elem) catch |e| return self.refuseElem(r, elem, e);
        return n orelse default;
    }

    /// `elemF64` without a default: null for a non-numeric element (the wasm-arg
    /// list mixes builtin symbols and numbers), a located refusal for a
    /// malformed one.
    fn elemF64Opt(self: *Emitter, r: *const Reader, elem: NodeIndex) Error!?f64 {
        return r.elemEval(self.gpa, self.schema, &self.env, elem) catch |e| self.refuseElem(r, elem, e);
    }

    /// `refuseNumericKey` for a vector ELEMENT: the span is the element itself.
    fn refuseElem(self: *Emitter, r: *const Reader, elem: NodeIndex, e: values.EvalError) Error {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return self.refuseNumeric(r, elem, null, e);
    }

    /// Ping-pong pool offset for one slot of a `:*-pool-offsets` vector. Inside
    /// the struct (it used to be a free function) because the element read now
    /// evaluates against the expr env — `:bind-groups-pool-offsets [PHASE 0]`
    /// resolves like any other numeric slot rather than silently reading 0 (§307).
    /// A pool offset names an instance of the pool it is applied to — `offset`
    /// must be below `pool_size`. The wire layer asserts exactly that, and a
    /// `:…-pool-offsets [2]` on a 2-instance pool (an off-by-one) reached the
    /// assert from a validated document. Refused here, located on the element.
    fn checkPoolOffsetFits(self: *Emitter, r: *const Reader, offsets: ?[]const NodeIndex, slot: usize, key: []const u8, name: []const u8, offset: u8, pool_size: u8) Error!void {
        std.debug.assert(pool_size > 0);
        if (offset < pool_size) return;
        const node = if (offsets) |os| (if (slot < os.len) os[slot] else null) else null;
        self.diagnose(.sjon, if (node) |n| self.locate(r, n) else null, "", "':{s}' names instance {d} of '{s}', but its pool has {d} instances (offsets count from 0)", .{ key, offset, name, pool_size });
        return error.ValidationError;
    }

    fn poolOffset(self: *Emitter, r: *const Reader, offsets: ?[]const NodeIndex, slot: usize) Error!u8 {
        const os = offsets orelse return 0;
        if (slot >= os.len) return 0;
        return @intCast(try self.elemBounded(r, os[slot], 0, .byte));
    }

    /// Emit set_viewport / set_scissor_rect for the pass's `:viewport` /
    /// `:scissor-rect` rect vectors. viewport is `[x y w h]` (minDepth/maxDepth
    /// default to f32 0.0/1.0) or `[x y w h minDepth maxDepth]`; scissor is
    /// `[x y w h]` — element-by-element, mirroring the legacy pass-command parse.
    fn emitViewportScissor(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const em = self.builder.getEmitter();
        if (r.vectorNodes(form, "viewport")) |vp| {
            var vals: [4]u32 = .{ 0, 0, 512, 512 };
            for (vp, 0..) |elem, i| {
                if (i >= 4) break;
                vals[i] = try self.elemU32(r, elem, 0);
            }
            // Only the 6-element form carries explicit min/max depth. The wire
            // (and both backends) read those two fields as f32 BITS, so they are
            // evaluated as reals and bit-cast — reading them through `elemU32`
            // put the integer 1 on the wire for `maxDepth 1`, which a backend
            // decoded as 1e-45 (audit 09 C2's neighbour, found on the way).
            const min_d: u32 = if (vp.len >= 5) @bitCast(@as(f32, @floatCast(try self.elemF64(r, vp[4], 0.0)))) else @bitCast(@as(f32, 0.0));
            const max_d: u32 = if (vp.len >= 6) @bitCast(@as(f32, @floatCast(try self.elemF64(r, vp[5], 1.0)))) else @bitCast(@as(f32, 1.0));
            em.setViewport(self.gpa, vals[0], vals[1], vals[2], vals[3], min_d, max_d) catch return error.OutOfMemory;
        }
        if (r.vectorNodes(form, "scissor-rect")) |sc| {
            var vals: [4]u32 = .{ 0, 0, 512, 512 };
            for (sc, 0..) |elem, i| {
                if (i >= 4) break;
                vals[i] = try self.elemU32(r, elem, 0);
            }
            em.setScissorRect(self.gpa, vals[0], vals[1], vals[2], vals[3]) catch return error.OutOfMemory;
        }
    }

    /// Emit a single draw / draw-indexed command from its form node. Shared by the
    /// top-level pass draw and the inner draws of an (occlusion-query …) bracket.
    fn emitDrawForm(self: *Emitter, r: *const Reader, node: NodeIndex) Error!void {
        const em = self.builder.getEmitter();
        if (std.mem.eql(u8, r.head(node), "draw-indexed")) {
            // draw-indexed is never hook-emitted: schema requires :index-count and
            // materializes :default for the rest — absence is unreachable post-validation.
            const ic = try self.requiredU32(r, node, "index-count");
            const inst = try self.requiredU32(r, node, "instance-count");
            const fi = try self.requiredU32(r, node, "first-index");
            const bv = try self.requiredU32(r, node, "base-vertex");
            const finst = try self.requiredU32(r, node, "first-instance");
            em.drawIndexed(self.gpa, ic, inst, fi, bv, finst) catch return error.OutOfMemory;
        } else {
            // draw IS hook-emitted (pass-v1's fullscreen triangle). Lowered trees are
            // re-validated, so the required :vertex-count is guaranteed on both origins
            // — but their materialized-defaults overlay is not exposed in HostResult
            // (lowered forms read through empty_overlay), so the three defaulted keys
            // keep a live backstop for hook draws that only carry :vertex-count.
            const vc = try self.requiredU32(r, node, "vertex-count");
            const ic = (try self.optU32(r, node, "instance-count")) orelse 1;
            const fv = (try self.optU32(r, node, "first-vertex")) orelse 0;
            const fi = (try self.optU32(r, node, "first-instance")) orelse 0;
            em.draw(self.gpa, vc, ic, fv, fi) catch return error.OutOfMemory;
        }
    }

    /// Emit set_pass_depth_stencil_ops before begin_render_pass when the depth
    /// attachment's (required) ops are not the clear/store pair the opcode's
    /// absence means (matches the legacy path; no-op for the common clear/store case).
    fn emitDepthStencilOps(self: *Emitter, r: *const Reader, da: NodeIndex) Error!void {
        var depth_load: LoadOp = .clear;
        var depth_store: StoreOp = .store;
        var non_default = false;
        if (r.symbol(da, "depth-load-op")) |lo| {
            if (std.mem.eql(u8, lo, "load")) {
                depth_load = .load;
                non_default = true;
            }
        }
        if (r.symbol(da, "depth-store-op")) |so| {
            if (std.mem.eql(u8, so, "discard")) {
                depth_store = .discard;
                non_default = true;
            }
        }
        var stencil_load: LoadOp = .clear;
        var stencil_store: StoreOp = .store;
        if (r.symbol(da, "stencil-load-op")) |lo| {
            if (std.mem.eql(u8, lo, "load")) {
                stencil_load = .load;
                non_default = true;
            }
        }
        if (r.symbol(da, "stencil-store-op")) |so| {
            if (std.mem.eql(u8, so, "discard")) {
                stencil_store = .discard;
                non_default = true;
            }
        }
        if (!non_default) return;
        self.builder.getEmitter().setPassDepthStencilOps(self.gpa, depth_load, depth_store, stencil_load, stencil_store) catch return error.OutOfMemory;
    }

    /// Emit set_pass_clear_values before begin_render_pass when the depth
    /// attachment authors a non-default :depth-clear-value / :stencil-clear-value
    /// (runtime defaults: depth 1.0, stencil 0 — no opcode for the common case,
    /// keeping unauthored payloads byte-identical).
    fn emitPassClearValues(self: *Emitter, r: *const Reader, da: NodeIndex) Error!void {
        const depth_clear: f32 = if (try self.optF64(r, da, "depth-clear-value")) |d| @floatCast(d) else 1.0;
        const stencil_clear: u32 = (try self.optU32(r, da, "stencil-clear-value")) orelse 0;
        if (depth_clear == 1.0 and stencil_clear == 0) return;
        std.debug.assert(depth_clear >= 0.0 and depth_clear <= 1.0); // schema type is unorm
        self.builder.getEmitter().setPassClearValues(self.gpa, @bitCast(depth_clear), stencil_clear) catch return error.OutOfMemory;
    }

    fn emitComputePass(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const name = try self.requiredSymbol(r, form, "name");
        const pass_id = try self.allocPassId(r, form, name, .compute);

        const em = self.builder.getEmitter();
        const desc_id = self.builder.addData(self.gpa, "{}") catch return error.OutOfMemory;
        em.definePass(self.gpa, pass_id, .compute, desc_id.toInt()) catch return error.OutOfMemory;
        em.beginComputePass(self.gpa) catch return error.OutOfMemory;

        if (r.symbol(form, "pipeline")) |p| {
            const pid = self.tables.pipelines.get(p) orelse return self.unresolvedRef(r, form, "pipeline", p);
            em.setPipeline(self.gpa, pid) catch return error.OutOfMemory;
        }
        try self.emitBindGroups(r, form);

        try self.emitDispatches(r, form, name);

        em.endPass(self.gpa) catch return error.OutOfMemory;
        em.endPassDef(self.gpa) catch return error.OutOfMemory;
    }

    /// Emit the compute pass's `(dispatch …)` / `(dispatch-indirect …)` commands
    /// in DOCUMENT order — the same walk the render pass does over its draws.
    ///
    /// This replaced a precedence rule over three keys: indirect beat the 3-D
    /// `:dispatch [x y z]` beat the scalar `:dispatch-workgroups N`. A pass that
    /// stated two dispatched once, silently, and which one it was depended on a
    /// ranking written nowhere the author could see. The head-set's
    /// `:min-children 1` (D8) makes the zero-command case a validator reject, so
    /// there is no default dispatch left to fall through to either.
    fn emitDispatches(self: *Emitter, r: *const Reader, form: NodeIndex, name: []const u8) Error!void {
        std.debug.assert(r.tree.tagOf(form) == .form); // pre: called on a compute-pass form
        std.debug.assert(name.len > 0);
        const em = self.builder.getEmitter();
        var commands: u32 = 0;
        for (r.children(form)) |c| {
            if (r.tree.tagOf(c) != .form) continue;
            const head = r.head(c);
            if (std.mem.eql(u8, head, "dispatch")) {
                const d = try self.requiredVector(r, c, "workgroups");
                std.debug.assert(d.len >= 1 and d.len <= 3); // schema: 1..3 elements
                const dx: u32 = try self.elemU32(r, d[0], 1);
                const dy: u32 = if (d.len > 1) try self.elemU32(r, d[1], 1) else 1;
                const dz: u32 = if (d.len > 2) try self.elemU32(r, d[2], 1) else 1;
                em.dispatch(self.gpa, dx, dy, dz) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, head, "dispatch-indirect")) {
                const bname = try self.requiredSymbol(r, c, "buffer");
                const bid = self.tables.buffers.get(bname) orelse return self.unresolvedRef(r, c, "buffer", bname);
                const offset = (try self.optU32(r, c, "offset")) orelse 0;
                em.dispatchIndirect(self.gpa, bid, offset) catch return error.OutOfMemory;
            } else continue;
            commands += 1;
            try self.checkCommandsFit(r, form, name, "compute-pass", commands);
        }
        std.debug.assert(commands >= 1); // post: the head-set floor holds
    }

    fn emitFrame(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const name = try self.requiredSymbol(r, form, "name");
        // The one id space outside `IdTable.reserve`'s exhaustion check, so the
        // cap is stated here: past `DEFAULT_MAX_FRAMES` the shipping executor's
        // frame scan stops indexing (a silent drop the browser sees and the
        // native preview does not — `allocPassId`'s reasoning for passes), and
        // at 65,536 the u16 id would wrap. Refused, located, like a pass.
        if (self.next_frame_id >= bytecode.DEFAULT_MAX_FRAMES) {
            self.diagnose(.sjon, self.locate(r, form), "", "frame '{s}' is frame #{d}, but the browser executor indexes at most {d} frames — frames beyond that are silently dropped at load", .{ name, @as(u32, self.next_frame_id) + 1, bytecode.DEFAULT_MAX_FRAMES });
            return error.ValidationError;
        }
        const frame_id = self.next_frame_id;
        self.next_frame_id += 1;
        const name_id = self.builder.internString(self.gpa, name) catch return error.OutOfMemory;
        const em = self.builder.getEmitter();
        em.defineFrame(self.gpa, frame_id, name_id.toInt()) catch return error.OutOfMemory;

        try self.emitFrameInit(r, form, name);
        try self.emitFrameSteps(r, form, "before");
        try self.emitFrameSteps(r, form, "perform");

        em.submit(self.gpa) catch return error.OutOfMemory;
        em.endFrame(self.gpa) catch return error.OutOfMemory;
    }

    // ----------------------------------------------------------------------
    // Shared helpers
    // ----------------------------------------------------------------------

    /// Emit the frame's one-shot `:init` steps, refusing a repeat and warning
    /// about a pass that is also performed every frame.
    ///
    /// The asymmetry with `:perform` is the reason this list gets its own walk.
    /// A repeated `:perform` step RUNS again — webgpu_bitonic_sort names
    /// `passDisp2` twelve times because the sort needs each one — so repetition
    /// there is meaning, not a mistake. A repeated `:init` entry cannot run
    /// again: `exec_pass_once` is once per loaded payload, keyed per pass id
    /// (abi.md §7 clause 9, §347). Emitting the dead second op is the LEAK-11-A
    /// defect in another slot — a document asking for two runs quietly getting
    /// one — so it is refused with the count, not deduped in silence.
    fn emitFrameInit(self: *Emitter, r: *const Reader, form: NodeIndex, frame: []const u8) Error!void {
        const steps = r.vectorNodes(form, "init") orelse return;
        const em = self.builder.getEmitter();

        // Bounded by the schema's `:max-len` on compute-pass-ref-list, and
        // re-checked here rather than asserted: this runs in the editor's
        // ReleaseSmall build, where an assert is compiled out and the overrun is
        // silent (the LEAK-11-B lesson — input is not an invariant).
        var seen: [MAX_FRAME_STEPS]u16 = undefined;
        var seen_len: usize = 0;

        for (steps) |s| {
            const sname = r.elemSymbol(s) orelse continue;
            const pid = self.tables.passes.get(sname) orelse continue;
            if (seen_len == seen.len) {
                self.diagnose(.sjon, self.locate(r, form), "", "frame '{s}': ':init' lists more than {d} steps", .{ frame, MAX_FRAME_STEPS });
                return error.ValidationError;
            }
            for (seen[0..seen_len]) |prev| {
                if (prev != pid) continue;
                self.diagnose(.sjon, self.locate(r, form), "", "frame '{s}': ':init' names '{s}' more than once, but a one-shot pass runs once per loaded payload — the repeat can never run", .{ frame, sname });
                return error.ValidationError;
            }
            seen[seen_len] = pid;
            seen_len += 1;
            em.execPassOnce(self.gpa, pid) catch return error.OutOfMemory;
            self.warnIfAlsoPerformed(r, form, frame, sname, pid);
        }
        std.debug.assert(seen_len <= steps.len);
    }

    /// Warn when a `:init` pass is also a `:perform` step. Both lists are then
    /// honoured exactly as written — the pass runs once as an init AND once per
    /// frame, so it runs twice on the first frame — which is defined behaviour,
    /// just almost certainly not what "one-shot" meant. That is the line: refuse
    /// what pngine cannot do, warn about what it can do but you likely did not
    /// mean.
    fn warnIfAlsoPerformed(self: *Emitter, r: *const Reader, form: NodeIndex, frame: []const u8, sname: []const u8, pid: u16) void {
        const performs = r.vectorNodes(form, "perform") orelse return;
        for (performs) |p| {
            const pname = r.elemSymbol(p) orelse continue;
            const other = self.tables.passes.get(pname) orelse continue;
            if (other != pid) continue;
            self.diagnoseWarn(.sjon, self.locate(r, form), "", "frame '{s}': '{s}' runs as a one-shot :init AND every frame via :perform, so it runs twice on the first frame", .{ frame, sname });
            return;
        }
    }

    fn emitFrameSteps(self: *Emitter, r: *const Reader, form: NodeIndex, key: []const u8) Error!void {
        const steps = r.vectorNodes(form, key) orelse return;
        const em = self.builder.getEmitter();
        for (steps) |s| {
            const sname = r.elemSymbol(s) orelse continue;
            if (self.tables.passes.get(sname)) |pid| {
                em.execPass(self.gpa, pid) catch return error.OutOfMemory;
            } else if (self.tables.queue_actions.get(sname)) |queue| {
                try self.emitQueueActions(queue);
            }
            // else: a step that resolved to neither a pass nor a queue is dropped
            // (the source/lowered cross-ref validator already rejected dangling names).
        }
    }

    /// Inline every positional action of a queue, in document order, dispatching
    /// each by head to the matching emitter. Reads from the tree the queue was
    /// collected from (source or lowered). A queue with one action (write-buffer)
    /// emits one op; resolveOps emits resolve-query-set then copy-buffer-to-buffer.
    fn emitQueueActions(self: *Emitter, queue: FormRef) Error!void {
        const r = queue.reader;
        try self.checkQueueActionsFit(r, queue.idx);
        for (r.children(queue.idx)) |c| {
            if (r.tree.tagOf(c) != .form) continue;
            const head = r.head(c);
            if (std.mem.eql(u8, head, "write-buffer")) {
                try self.emitQueueWrite(r, c);
            } else if (std.mem.eql(u8, head, "copy-texture-to-texture")) {
                try self.emitCopyTexture(r, c);
            } else if (std.mem.eql(u8, head, "copy-external-image-to-texture")) {
                try self.emitCopyExternalImage(r, c);
            } else if (std.mem.eql(u8, head, "resolve-query-set")) {
                try self.emitResolveQuerySet(r, c);
            } else if (std.mem.eql(u8, head, "copy-buffer-to-buffer")) {
                try self.emitCopyBufferToBuffer(r, c);
            }
        }
    }

    /// Refuse a queue whose action count alone can tear the frame's command
    /// buffer. The schema bounds the three frame LISTS with `:max-len`; a queue's
    /// actions are positional sub-forms with no length to bound, so this is the
    /// same cap counted by hand.
    ///
    /// Checked per reference rather than at collection time, which is the useful
    /// side of the two: a queue nobody performs emits nothing and multiplies
    /// nothing, so it is not an error to declare one.
    fn checkQueueActionsFit(self: *Emitter, r: *const Reader, queue: NodeIndex) Error!void {
        std.debug.assert(r.tree.tagOf(queue) == .form);
        var actions: usize = 0;
        for (r.children(queue)) |c| {
            if (r.tree.tagOf(c) == .form) actions += 1;
        }
        if (actions <= MAX_FRAME_STEPS) return;
        const name = r.symbol(queue, "name") orelse "";
        self.diagnose(.sjon, self.locate(r, queue), "", "queue '{s}' holds {d} actions, but a frame carries at most {d} steps — the 64 KB command buffer cannot describe them all", .{ name, actions, MAX_FRAME_STEPS });
        return error.ValidationError;
    }

    /// Inline a queue's resolve-query-set op: copy resolved query results into a
    /// destination buffer (QUERY_RESOLVE usage) → resolve_query_set.
    fn emitResolveQuerySet(self: *Emitter, r: *const Reader, rqs: NodeIndex) Error!void {
        const qs_name = try self.requiredSymbol(r, rqs, "query-set");
        const qs_id = self.tables.query_sets.get(qs_name) orelse return self.unresolvedRef(r, rqs, "query-set", qs_name);
        // resolve-query-set is never hook-emitted: :query-count is schema-required,
        // :first-query / :destination-offset materialize their :default 0.
        const first = try self.requiredU32(r, rqs, "first-query");
        const count = try self.requiredU32(r, rqs, "query-count");
        const dst_name = try self.requiredSymbol(r, rqs, "destination");
        const dst_id = self.tables.buffers.get(dst_name) orelse return self.unresolvedRef(r, rqs, "buffer", dst_name);
        const dst_off = try self.requiredU32(r, rqs, "destination-offset");
        self.builder.getEmitter().resolveQuerySet(self.gpa, qs_id, first, count, dst_id, dst_off) catch return error.OutOfMemory;
    }

    /// C22 (05 §5) — a copy endpoint has to admit the copy. Buffer and texture
    /// usage is fixed at creation, so WebGPU rejects the ENCODER call, not the
    /// resource: the document looks fine and the copy silently never happens.
    /// The schema's own descriptions have said "needs copy-src usage" since the
    /// forms were written; this makes the sentence enforceable.
    ///
    /// `dir` is "source"/"destination" and `key` the keyword to name in the
    /// message, so one function covers both ends of all three copy forms.
    fn checkBufferCopyUsage(self: *Emitter, r: *const Reader, op: NodeIndex, name: []const u8, id: u16, comptime dir: []const u8, key: []const u8) Error!void {
        const meta = self.binds.buffer_meta.get(id) orelse return;
        const ok = if (std.mem.eql(u8, dir, "source")) meta.usage.copy_src else meta.usage.copy_dst;
        if (ok) return;
        const need: []const u8 = if (std.mem.eql(u8, dir, "source")) "copy-src" else "copy-dst";
        self.diagnose(.sjon, self.locate(r, op), "", "buffer '{s}' is the :{s} of a copy but its :usage has no {s} — a buffer's usage is fixed when it is created", .{ name, key, need });
        return error.ValidationError;
    }

    /// C22's arithmetic half — a copy has to fit at both ends. WebGPU requires
    /// sourceOffset + size within the source and destinationOffset + size within
    /// the destination. Every term is in the document; the schema bounds each on
    /// its own and cannot add two of them together.
    fn checkCopyFits(self: *Emitter, r: *const Reader, op: NodeIndex, name: []const u8, id: u16, offset: u32, size: u32, comptime dir: []const u8) Error!void {
        const meta = self.binds.buffer_meta.get(id) orelse return;
        const end = @as(u64, offset) + @as(u64, size);
        if (end <= meta.size) return;
        self.diagnose(.sjon, self.locate(r, op), "", "the copy reads {d} bytes from offset {d} of {s} buffer '{s}', which is {d} bytes long", .{ size, offset, dir, name, meta.size });
        return error.ValidationError;
    }

    /// Inline a queue's copy-buffer-to-buffer op (e.g. resolved queries → a
    /// MAP_READ readback buffer) → copy_buffer_to_buffer.
    fn emitCopyBufferToBuffer(self: *Emitter, r: *const Reader, cbb: NodeIndex) Error!void {
        const src_name = try self.requiredSymbol(r, cbb, "source");
        const src_id = self.tables.buffers.get(src_name) orelse return self.unresolvedRef(r, cbb, "buffer", src_name);
        // copy-buffer-to-buffer is never hook-emitted: :size is schema-required,
        // the offsets materialize their :default 0.
        const src_off = try self.requiredU32(r, cbb, "source-offset");
        const dst_name = try self.requiredSymbol(r, cbb, "destination");
        const dst_id = self.tables.buffers.get(dst_name) orelse return self.unresolvedRef(r, cbb, "buffer", dst_name);
        const dst_off = try self.requiredU32(r, cbb, "destination-offset");
        const size = try self.requiredU32(r, cbb, "size");
        try self.checkBufferCopyUsage(r, cbb, src_name, src_id, "source", "source");
        try self.checkBufferCopyUsage(r, cbb, dst_name, dst_id, "destination", "destination");
        try self.checkCopyFits(r, cbb, src_name, src_id, src_off, size, "source");
        try self.checkCopyFits(r, cbb, dst_name, dst_id, dst_off, size, "destination");
        self.builder.getEmitter().copyBufferToBuffer(self.gpa, src_id, src_off, dst_id, dst_off, size) catch return error.OutOfMemory;
    }

    /// Inline a queue's copy-external-image-to-texture op (upload a decoded image
    /// into a texture) into the current frame body. mip-level / origin default to 0.
    fn emitCopyExternalImage(self: *Emitter, r: *const Reader, ceit: NodeIndex) Error!void {
        const src_form = try self.requiredChild(r, ceit, "source");
        const dst_form = try self.requiredChild(r, ceit, "destination");
        const src_name = try self.requiredSymbol(r, src_form, "image");
        const bitmap_id = self.tables.image_bitmaps.get(src_name) orelse return self.unresolvedRef(r, src_form, "image-bitmap", src_name);
        const tex_name = try self.requiredSymbol(r, dst_form, "texture");
        const texture_id = self.tables.textures.get(tex_name) orelse return self.unresolvedRef(r, dst_form, "texture", tex_name);
        // `:mip-level` / `:origin` are the DESTINATION's subresource, so they are
        // read off the destination form (D5), not off the copy.
        const mip: u8 = @intCast((try self.optBounded(r, dst_form, "mip-level", .byte)) orelse 0);
        var origin_x: u16 = 0;
        var origin_y: u16 = 0;
        var origin_z: u16 = 0;
        if (r.vectorNodes(dst_form, "origin")) |elems| {
            if (elems.len >= 1) origin_x = @intCast(try self.elemBounded(r, elems[0], 0, .origin));
            if (elems.len >= 2) origin_y = @intCast(try self.elemBounded(r, elems[1], 0, .origin));
            if (elems.len >= 3) origin_z = @intCast(try self.elemBounded(r, elems[2], 0, .origin));
        }
        self.builder.getEmitter().copyExternalImageToTexture(self.gpa, bitmap_id, texture_id, mip, origin_x, origin_y, origin_z) catch return error.OutOfMemory;
    }

    /// Inline a queue's copy-texture-to-texture op into the current frame body.
    fn emitCopyTexture(self: *Emitter, r: *const Reader, ctt: NodeIndex) Error!void {
        // Both endpoints are child forms (D5); the head-set floors make them
        // present, so a missing one is a validator reject, never a default here.
        const src_form = try self.requiredChild(r, ctt, "source");
        const dst_form = try self.requiredChild(r, ctt, "destination");
        const src_name = try self.requiredSymbol(r, src_form, "texture");
        const dst_name = try self.requiredSymbol(r, dst_form, "texture");
        const src = self.resolveCopyTexture(src_name);
        const dst = self.resolveCopyTexture(dst_name);
        try self.checkTextureCopyUsage(r, src_form, src_name, true);
        try self.checkTextureCopyUsage(r, dst_form, dst_name, false);
        self.builder.getEmitter().copyTextureToTexture(self.gpa, src, dst) catch return error.OutOfMemory;
    }

    /// C22 for textures. The canvas (`context-current-texture`) is exempt: the
    /// runtime configures it, so its usage is not the document's to declare.
    fn checkTextureCopyUsage(self: *Emitter, r: *const Reader, endpoint: NodeIndex, name: []const u8, is_source: bool) Error!void {
        if (std.mem.eql(u8, name, "context-current-texture")) return;
        const tid = self.tables.textures.get(name) orelse return;
        const meta = self.binds.texture_meta.get(tid) orelse return;
        if (if (is_source) meta.usage.copy_src else meta.usage.copy_dst) return;
        const need: []const u8 = if (is_source) "copy-src" else "copy-dst";
        const dir: []const u8 = if (is_source) "source" else "destination";
        self.diagnose(.sjon, self.locate(r, endpoint), "", "texture '{s}' is the {s} of a copy but its :usage has no {s} — a texture's usage is fixed when it is created", .{ name, dir, need });
        return error.ValidationError;
    }

    /// Resolve a copy source/destination symbol to a texture id: the canvas
    /// sentinel for `context-current-texture`, else a declared (texture …) id.
    fn resolveCopyTexture(self: *Emitter, name: []const u8) u16 {
        if (std.mem.eql(u8, name, "context-current-texture")) return values.CANVAS_TEXTURE_ID;
        return self.tables.textures.get(name) orelse values.NO_TEXTURE_ID;
    }

    /// Resolve a color-attachment view / resolve-target symbol to a texture id:
    /// the canvas for `context-current-texture`, else a declared (texture …) id.
    fn resolveAttachmentView(self: *Emitter, name: []const u8) u16 {
        if (std.mem.eql(u8, name, "context-current-texture")) return values.CANVAS_TEXTURE_ID;
        return self.tables.textures.get(name) orelse values.CANVAS_TEXTURE_ID;
    }

    /// Inline a queue's write-buffer op into the current frame body, reading the
    /// write-buffer node from `r` (the source tree, or the lowered tree for a
    /// pass-v1 per-pass uniform-write queue).
    fn emitQueueWrite(self: *Emitter, r: *const Reader, wb: NodeIndex) Error!void {
        const buffer_name = try self.requiredSymbol(r, wb, "buffer");
        const buffer_id = self.tables.buffers.get(buffer_name) orelse return self.unresolvedRef(r, wb, "buffer", buffer_name);
        const offset = (try self.optU32(r, wb, "offset")) orelse 0;
        // queue.writeBuffer is a copy like any other, so its destination admits one.
        try self.checkBufferCopyUsage(r, wb, buffer_name, buffer_id, "destination", "buffer");
        // `:data` names one of three things, and the schema's cross-ref target
        // group makes the name resolve to exactly one declaration — so the table
        // that answers decides the opcode, and the order below cannot pick the
        // wrong one. Builtin first (a reserved spelling, plan 05 §1), then the
        // two declared kinds.
        const data = try self.requiredSymbol(r, wb, "data");
        const em = self.builder.getEmitter();
        if (values.mapDataSource(data)) |src_kind| {
            switch (src_kind) {
                .time_uniform => |size| em.writeTimeUniform(self.gpa, buffer_id, offset, size) catch return error.OutOfMemory,
                .pointer_uniform => |size| em.writePointerUniform(self.gpa, buffer_id, offset, size) catch return error.OutOfMemory,
            }
            return;
        }
        if (self.tables.data.get(data)) |did| {
            em.writeBuffer(self.gpa, buffer_id, offset, did) catch return error.OutOfMemory;
            return;
        }
        // A (wasm-call …): call the function, then write its `:returns`-many
        // result bytes. Two opcodes for one key.
        if (self.tables.wasm_calls.get(data) != null) return self.emitWasmCallWrite(data, buffer_id, offset);
        return self.unresolvedRef(r, wb, "as its :data the builtin source, (data …) or (wasm-call …)", data);
    }

    fn emitVertexBuffers(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const names = r.vectorNodes(form, "vertex-buffers") orelse return;
        try self.checkSlotListFits(r, form, "vertex-buffers", names.len);
        const offsets = r.vectorNodes(form, "vertex-buffers-pool-offsets");
        const em = self.builder.getEmitter();
        for (names, 0..) |nnode, slot_usize| {
            const slot: u8 = @intCast(slot_usize);
            const bname = r.elemSymbol(nnode) orelse continue;
            const base = self.tables.buffers.get(bname) orelse return self.unresolvedRef(r, form, "buffer", bname);
            const off = try self.poolOffset(r, offsets, slot_usize);
            if (self.tables.buffers.pool(bname)) |bp| {
                try self.checkPoolOffsetFits(r, offsets, slot_usize, "vertex-buffers-pool-offsets", bname, off, bp.size);
                em.setVertexBufferPool(self.gpa, slot, bp.base, bp.size, off) catch return error.OutOfMemory;
            } else {
                em.setVertexBuffer(self.gpa, slot, base) catch return error.OutOfMemory;
            }
        }
    }

    fn emitBindGroups(self: *Emitter, r: *const Reader, form: NodeIndex) Error!void {
        const names = r.vectorNodes(form, "bind-groups") orelse return;
        try self.checkSlotListFits(r, form, "bind-groups", names.len);
        const offsets = r.vectorNodes(form, "bind-groups-pool-offsets");
        const em = self.builder.getEmitter();
        for (names, 0..) |nnode, slot_usize| {
            const slot: u8 = @intCast(slot_usize);
            const gname = r.elemSymbol(nnode) orelse continue;
            const base = self.tables.bind_groups.get(gname) orelse return self.unresolvedRef(r, form, "bind-group", gname);
            const off = try self.poolOffset(r, offsets, slot_usize);
            if (self.tables.bind_groups.pool(gname)) |bp| {
                try self.checkPoolOffsetFits(r, offsets, slot_usize, "bind-groups-pool-offsets", gname, off, bp.size);
                em.setBindGroupPool(self.gpa, slot, bp.base, bp.size, off) catch return error.OutOfMemory;
            } else {
                em.setBindGroup(self.gpa, slot, base) catch return error.OutOfMemory;
            }
        }
    }

    // ---- render pipeline JSON pieces ----

    /// Pure JSON emission — the caller (emitRenderPipeline) runs the stage checks.
    fn appendVertexStage(self: *Emitter, json: *std.ArrayList(u8), r: *const Reader, form: NodeIndex) Error!void {
        const vtx = try self.requiredChild(r, form, "vertex");
        const shader_id = try self.stageShader(r, vtx);
        const entry = try self.resolveStageEntry(r, vtx, .vertex);
        try json.appendSlice(self.gpa, "\"vertex\":{\"shader\":");
        try appendInt(self.gpa, json, shader_id);
        try json.appendSlice(self.gpa, ",\"entryPoint\":\"");
        try json.appendSlice(self.gpa, entry);
        try json.append(self.gpa, '"');
        var vb_it = r.childrenWithHead(vtx, "vertex-buffer");
        if (vb_it.next() != null) {
            try json.appendSlice(self.gpa, ",\"buffers\":");
            try self.appendVertexBuffersJson(json, r, vtx);
        }
        try json.append(self.gpa, '}');
    }

    /// Pure JSON emission — the caller (emitRenderPipeline) runs the stage checks.
    fn appendFragmentStage(self: *Emitter, json: *std.ArrayList(u8), r: *const Reader, form: NodeIndex) Error!void {
        const frag = r.child(form, "fragment") orelse return;
        const shader_id = try self.stageShader(r, frag);
        const entry = try self.resolveStageEntry(r, frag, .fragment);
        try json.appendSlice(self.gpa, ",\"fragment\":{\"shader\":");
        try appendInt(self.gpa, json, shader_id);
        try json.appendSlice(self.gpa, ",\"entryPoint\":\"");
        try json.appendSlice(self.gpa, entry);
        try json.append(self.gpa, '"');
        // `GPUFragmentState.targets` is REQUIRED. Omitting it used to emit a
        // fragment stage with no targets at all, which every runtime then papered
        // over with its own guess: gpu.js substituted
        // `[{format: preferredCanvasFormat}]`, native substituted BGRA8Unorm. The
        // pipeline "worked" while nobody looked at the attachment it wrote to.
        // `fragment-section`'s `(head :name target :min 1)` now says it, so this
        // is the unreachable half of a belt-and-braces pair — kept because a
        // lowering hook builds these forms too.
        var t_it = r.childrenWithHead(frag, "target");
        if (t_it.next() == null) {
            self.diagnose(.sjon, self.locate(r, frag), "", "(fragment …) declares no (target …) — a fragment stage must name the color targets it writes", .{});
            return error.ValidationError;
        }
        t_it = r.childrenWithHead(frag, "target");
        try json.appendSlice(self.gpa, ",\"targets\":[");
        var first = true;
        while (t_it.next()) |c| {
            if (!first) try json.append(self.gpa, ',');
            first = false;
            try self.appendTarget(json, r, c);
        }
        try json.append(self.gpa, ']');
        try json.append(self.gpa, '}');
    }

    fn appendPrimitive(self: *Emitter, json: *std.ArrayList(u8), r: *const Reader, prim: NodeIndex) Error!void {
        try json.appendSlice(self.gpa, ",\"primitive\":{");
        var first = true;
        // `:topology` carries a schema `:default triangle-list` since S14 — the
        // `(variant :when [triangle-strip line-strip] …)` that owns
        // `:strip-index-format` needs a discriminant, and SJON requires one
        // present or defaulted. A default is MATERIALIZED into the effective
        // view, and this form mirrors the source, so the key is emitted only
        // when the AUTHOR wrote it. Reading it through `symbol` here would bake
        // `"topology":"triangle-list"` into every descriptor that omits one:
        // measured at +27 bytes on 09_multiple_objects, the corpus's only
        // `(primitive …)` with no topology.
        if (r.authorNode(prim, "topology") != null) {
            if (r.symbol(prim, "topology")) |t| try self.appendJsonStr(json, &first, "topology", t);
        }
        if (r.symbol(prim, "cull-mode")) |cm| try self.appendJsonStr(json, &first, "cullMode", cm);
        if (r.symbol(prim, "front-face")) |ff| try self.appendJsonStr(json, &first, "frontFace", ff);
        if (r.symbol(prim, "strip-index-format")) |sif| try self.appendJsonStr(json, &first, "stripIndexFormat", sif);
        if (r.boolean(prim, "unclipped-depth")) |ud| {
            if (!first) try json.append(self.gpa, ',');
            first = false;
            try json.appendSlice(self.gpa, "\"unclippedDepth\":");
            try json.appendSlice(self.gpa, if (ud) "true" else "false");
        }
        try json.append(self.gpa, '}');
    }

    /// Append a `depthStencil` object. Emits only authored keys (no defaults), so
    /// it structurally matches the legacy property-by-property JSON.
    fn appendDepthStencil(self: *Emitter, json: *std.ArrayList(u8), r: *const Reader, ds: NodeIndex) Error!void {
        try json.appendSlice(self.gpa, ",\"depthStencil\":{");
        var first = true;
        if (r.symbol(ds, "format")) |f| try self.appendJsonStr(json, &first, "format", f);
        if (r.boolean(ds, "depth-write-enabled")) |b| try self.appendJsonBool(json, &first, "depthWriteEnabled", b);
        if (r.symbol(ds, "depth-compare")) |c| try self.appendJsonStr(json, &first, "depthCompare", c);
        // Depth bias (shadow maps / depth pre-pass) — legacy pipelines.zig:663-673
        // emits depthBias as an int, slope-scale/clamp as floats. The oracle
        // compares descriptors structurally, so key order here is irrelevant.
        // Signed: `GPUDepthBiasValue` is a `long`, and a NEGATIVE constant bias is
        // the useful one (it pulls fragments toward the viewer, which is how a
        // wireframe pass layers over the solid one it traces). Read as a real and
        // truncate, because the u32 readers return null for a negative literal —
        // which is how `:depth-bias -1` used to vanish between validation and the
        // descriptor with nothing reported.
        if (try self.optF64(r, ds, "depth-bias")) |m| try self.appendJsonInt(json, &first, "depthBias", @intFromFloat(m));
        if (try self.optF64(r, ds, "depth-bias-slope-scale")) |v| try self.appendJsonFloat(json, &first, "depthBiasSlopeScale", v);
        if (try self.optF64(r, ds, "depth-bias-clamp")) |v| try self.appendJsonFloat(json, &first, "depthBiasClamp", v);
        if (try self.optU32(r, ds, "stencil-read-mask")) |m| try self.appendJsonNum(json, &first, "stencilReadMask", m);
        if (try self.optU32(r, ds, "stencil-write-mask")) |m| try self.appendJsonNum(json, &first, "stencilWriteMask", m);
        if (r.child(ds, "stencil-front")) |sf| try self.appendStencilFace(json, &first, r, sf, "stencilFront");
        if (r.child(ds, "stencil-back")) |sb| try self.appendStencilFace(json, &first, r, sb, "stencilBack");
        try json.append(self.gpa, '}');
    }

    /// Append a stencil face object `"key":{compare,failOp,depthFailOp,passOp}`
    /// (only authored keys), mirroring the legacy `buildStencilFaceJson`.
    fn appendStencilFace(self: *Emitter, json: *std.ArrayList(u8), first: *bool, r: *const Reader, face: NodeIndex, key: []const u8) Error!void {
        if (!first.*) try json.append(self.gpa, ',');
        first.* = false;
        try json.append(self.gpa, '"');
        try json.appendSlice(self.gpa, key);
        try json.appendSlice(self.gpa, "\":{");
        var f2 = true;
        if (r.symbol(face, "compare")) |c| try self.appendJsonStr(json, &f2, "compare", c);
        if (r.symbol(face, "fail-op")) |o| try self.appendJsonStr(json, &f2, "failOp", o);
        if (r.symbol(face, "depth-fail-op")) |o| try self.appendJsonStr(json, &f2, "depthFailOp", o);
        if (r.symbol(face, "pass-op")) |o| try self.appendJsonStr(json, &f2, "passOp", o);
        try json.append(self.gpa, '}');
    }

    /// Append `"key":"val"`, prefixing a comma after the first property.
    fn appendJsonStr(self: *Emitter, json: *std.ArrayList(u8), first: *bool, key: []const u8, val: []const u8) Error!void {
        if (!first.*) try json.append(self.gpa, ',');
        first.* = false;
        try json.append(self.gpa, '"');
        try json.appendSlice(self.gpa, key);
        try json.appendSlice(self.gpa, "\":\"");
        try json.appendSlice(self.gpa, val);
        try json.append(self.gpa, '"');
    }

    /// Append a `multisample` object. Emits only authored keys.
    fn appendMultisample(self: *Emitter, json: *std.ArrayList(u8), r: *const Reader, ms: NodeIndex) Error!void {
        try json.appendSlice(self.gpa, ",\"multisample\":{");
        var first = true;
        if (try self.optU32(r, ms, "count")) |c| try self.appendJsonNum(json, &first, "count", c);
        if (try self.optU32(r, ms, "mask")) |m| try self.appendJsonNum(json, &first, "mask", m);
        if (r.boolean(ms, "alpha-to-coverage-enabled")) |b| try self.appendJsonBool(json, &first, "alphaToCoverageEnabled", b);
        try json.append(self.gpa, '}');
    }

    /// Append `"key":<num>`, prefixing a comma after the first property.
    fn appendJsonNum(self: *Emitter, json: *std.ArrayList(u8), first: *bool, key: []const u8, val: u32) Error!void {
        if (!first.*) try json.append(self.gpa, ',');
        first.* = false;
        try json.append(self.gpa, '"');
        try json.appendSlice(self.gpa, key);
        try json.appendSlice(self.gpa, "\":");
        try appendInt(self.gpa, json, val);
    }

    /// `appendJsonNum` for a SIGNED field (`depthBias`). Separate because the
    /// unsigned helper takes a u32 and there is exactly one signed descriptor
    /// field; both runtimes read it as a JSON integer.
    fn appendJsonInt(self: *Emitter, json: *std.ArrayList(u8), first: *bool, key: []const u8, val: i32) Error!void {
        if (!first.*) try json.append(self.gpa, ',');
        first.* = false;
        try json.append(self.gpa, '"');
        try json.appendSlice(self.gpa, key);
        try json.appendSlice(self.gpa, "\":");
        const entry = std.fmt.allocPrint(self.gpa, "{d}", .{val}) catch return error.OutOfMemory;
        defer self.gpa.free(entry);
        try json.appendSlice(self.gpa, entry);
    }

    /// Append `"key":<float>` using the legacy `{d}` formatting (1.0 → "1",
    /// 0.5 → "0.5"), mirroring pipelines.zig appendFloatProperty. The parity
    /// oracle compares pipeline descriptors structurally, so an integral float
    /// (1) and its decimal form (1.0) are equivalent.
    fn appendJsonFloat(self: *Emitter, json: *std.ArrayList(u8), first: *bool, key: []const u8, val: f64) Error!void {
        if (!first.*) try json.append(self.gpa, ',');
        first.* = false;
        try json.append(self.gpa, '"');
        try json.appendSlice(self.gpa, key);
        try json.appendSlice(self.gpa, "\":");
        const entry = std.fmt.allocPrint(self.gpa, "{d}", .{val}) catch return error.OutOfMemory;
        defer self.gpa.free(entry);
        try json.appendSlice(self.gpa, entry);
    }

    /// Append `"key":true|false`, prefixing a comma after the first property.
    fn appendJsonBool(self: *Emitter, json: *std.ArrayList(u8), first: *bool, key: []const u8, val: bool) Error!void {
        if (!first.*) try json.append(self.gpa, ',');
        first.* = false;
        try json.append(self.gpa, '"');
        try json.appendSlice(self.gpa, key);
        try json.appendSlice(self.gpa, "\":");
        try json.appendSlice(self.gpa, if (val) "true" else "false");
    }

    /// Append `"key":` (an object/array value follows), comma-prefixed after the first.
    fn appendJsonKey(self: *Emitter, json: *std.ArrayList(u8), first: *bool, key: []const u8) Error!void {
        if (!first.*) try json.append(self.gpa, ',');
        first.* = false;
        try json.append(self.gpa, '"');
        try json.appendSlice(self.gpa, key);
        try json.appendSlice(self.gpa, "\":");
    }

    /// Append one fragment color target: optional format (preferred-canvas-format
    /// omitted, matching legacy), optional blend object, optional writeMask.
    fn appendTarget(self: *Emitter, json: *std.ArrayList(u8), r: *const Reader, target: NodeIndex) Error!void {
        try json.append(self.gpa, '{');
        var first = true;
        if (r.symbol(target, "format")) |fmt| {
            if (!std.mem.eql(u8, fmt, "preferred-canvas-format")) try self.appendJsonStr(json, &first, "format", fmt);
        }
        if (r.child(target, "blend")) |blend| {
            try self.appendJsonKey(json, &first, "blend");
            try self.appendBlend(json, r, blend);
        }
        if (r.authorNode(target, "write-mask")) |_| {
            try self.appendJsonNum(json, &first, "writeMask", try writeMaskValue(self, r, target));
        }
        try json.append(self.gpa, '}');
    }

    /// Append a blend object `{"color":{…},"alpha":{…}}`.
    fn appendBlend(self: *Emitter, json: *std.ArrayList(u8), r: *const Reader, blend: NodeIndex) Error!void {
        try json.append(self.gpa, '{');
        var first = true;
        if (r.child(blend, "color")) |c| {
            try self.appendJsonKey(json, &first, "color");
            try self.appendBlendComponent(json, r, c);
        }
        if (r.child(blend, "alpha")) |a| {
            try self.appendJsonKey(json, &first, "alpha");
            try self.appendBlendComponent(json, r, a);
        }
        try json.append(self.gpa, '}');
    }

    /// Append a blend component `{"srcFactor":…,"dstFactor":…[,"operation":…]}`.
    fn appendBlendComponent(self: *Emitter, json: *std.ArrayList(u8), r: *const Reader, comp: NodeIndex) Error!void {
        try json.append(self.gpa, '{');
        var first = true;
        if (r.symbol(comp, "src-factor")) |sf| try self.appendJsonStr(json, &first, "srcFactor", sf);
        if (r.symbol(comp, "dst-factor")) |df| try self.appendJsonStr(json, &first, "dstFactor", df);
        if (r.symbol(comp, "operation")) |op| try self.appendJsonStr(json, &first, "operation", op);
        try json.append(self.gpa, '}');
    }

    /// `stage` is the `(vertex …)` form itself: the `(vertex-buffer …)` layouts
    /// are its direct children since 02 R3 dropped the `(buffers …)` wrapper.
    fn appendVertexBuffersJson(self: *Emitter, json: *std.ArrayList(u8), r: *const Reader, stage: NodeIndex) Error!void {
        try json.append(self.gpa, '[');
        var first = true;
        var vb_it = r.childrenWithHead(stage, "vertex-buffer");
        while (vb_it.next()) |vb| {
            if (!first) try json.append(self.gpa, ',');
            first = false;
            try json.appendSlice(self.gpa, "{\"arrayStride\":");
            // vertex-buffer children only exist on authored pipelines (hook-emitted
            // pipelines carry targets only) and the schema requires :array-stride.
            const stride = try self.requiredU32(r, vb, "array-stride");
            try appendInt(self.gpa, json, stride);
            // stepMode only when explicitly authored (matches legacy "emit if present").
            if (r.authorNode(vb, "step-mode")) |_| {
                if (r.symbol(vb, "step-mode")) |sm| {
                    try json.appendSlice(self.gpa, ",\"stepMode\":\"");
                    try json.appendSlice(self.gpa, sm);
                    try json.append(self.gpa, '"');
                }
            }
            try json.appendSlice(self.gpa, ",\"attributes\":[");
            var afirst = true;
            var attr_it = r.childrenWithHead(vb, "attribute");
            while (attr_it.next()) |attr| {
                if (!afirst) try json.append(self.gpa, ',');
                afirst = false;
                // attribute is source-only; all three keys are schema-required.
                const loc = try self.requiredU32(r, attr, "shader-location");
                const off = try self.requiredU32(r, attr, "offset");
                const fmt = try self.requiredSymbol(r, attr, "format");
                try json.appendSlice(self.gpa, "{\"shaderLocation\":");
                try appendInt(self.gpa, json, loc);
                try json.appendSlice(self.gpa, ",\"offset\":");
                try appendInt(self.gpa, json, off);
                try json.appendSlice(self.gpa, ",\"format\":\"");
                try json.appendSlice(self.gpa, fmt);
                try json.appendSlice(self.gpa, "\"}");
            }
            try json.appendSlice(self.gpa, "]}");
        }
        try json.append(self.gpa, ']');
    }

    /// A pipeline stage's shader id. `GPUProgrammableStage.module` is REQUIRED
    /// in the IDL, and the schema demands it — `:module` is a required key of
    /// `(vertex …)`/`(fragment …)`/`(compute …)` (overhaul/03: the stage is a form
    /// with keys), so a stage with no `:module` is a located `missing_required_key`
    /// at validation and the missing arm below is unreachable (kept as an internal
    /// guard, since a wrong id is the worst possible answer here).
    ///
    /// It used to `return 0` three times over: a stage with no `(module …)`, an
    /// unparseable one, or a name absent from the shader table all silently bound
    /// shader 0 — whatever module happened to be declared first. The document
    /// compiled clean and aborted on a real GPU with "RenderPipeline with ''
    /// label is invalid" (reproduced). Zero is a valid id, which is precisely
    /// why it makes such a bad "missing". (spec/09 step B; the schema half was
    /// SJON 1.2.0's S1 head bounds, then overhaul/03's required `:module` key.)
    fn stageShader(self: *Emitter, r: *const Reader, section: NodeIndex) Error!u16 {
        const loc = self.locate(r, section);
        const mname = r.symbol(section, "module") orelse {
            self.diagnose(.sjon, loc, "", "internal: pipeline stage has no :module after validation — every stage must name the (shader-module …) it runs", .{});
            return error.ValidationError;
        };
        return self.tables.shaders.get(mname) orelse {
            self.diagnose(.sjon, loc, "", "pipeline stage names shader module '{s}', which no (shader-module …) form declares", .{mname});
            return error.ValidationError;
        };
    }
};

// ----------------------------------------------------------------------
// Free helpers
// ----------------------------------------------------------------------

/// Free a reflected entry-point set: its keys are gpa-owned dupes.
fn freeEntrySet(gpa: Allocator, set: *EntrySet) void {
    var it = set.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    set.deinit(gpa);
}

/// A pipeline's `:layout`: null when it is `auto` (the union's first arm, and
/// the value that reserves the name), else the `(pipeline-layout …)` it names.
/// One reader for both pipeline kinds, so their descriptors cannot disagree
/// about what `auto` means — which is what the two-keys-and-an-exclusive-group
/// spelling made possible.
fn pipelineLayoutName(r: *const Reader, form: NodeIndex) ?[]const u8 {
    const lay = r.symbol(form, "layout") orelse return null;
    std.debug.assert(lay.len > 0);
    if (std.mem.eql(u8, lay, "auto")) return null;
    return lay;
}

/// `write-mask` is an integer bitmask or the symbol `all` (→ 15).
///
/// The symbol arm is read FIRST and by name. It used to be read by not being
/// read: the numeric reader returned null for a symbol and the fallback below
/// meant "all", which was right for `all` and equally right for `everything` —
/// the F8 hole 05 §4 closes with a one-member set. It also stopped being merely
/// sloppy the moment the numeric read started evaluating: `all` is not a
/// binding in the expr env, so an evaluating read of it is an emit error.
fn writeMaskValue(em: *Emitter, r: *const Reader, target: NodeIndex) Emitter.Error!u32 {
    if (r.symbol(target, "write-mask")) |sym| {
        if (std.mem.eql(u8, sym, "all")) return 0xF;
        // The schema's member-set makes this unreachable; if it fires, the
        // schema and this function disagree about the member list.
        em.diagnose(.sjon, em.locate(r, target), "", "internal: ':write-mask {s}' is not a write-mask symbol the emitter knows", .{sym});
        return error.EmitError;
    }
    if (try em.optU32(r, target, "write-mask")) |n| return n;
    return 0xF; // absent → WebGPU's own default, ALL
}

/// Ping-pong / pool index resolution shared by the buffer and texture bind paths:
/// `base + (pp + pool_idx) % size` — the pool instance a `(entry … :ping-pong P)`
/// entry reads in pool slot `pool_idx`.
fn poolResolve(base: u16, pp: u32, pool_idx: u8, size: u8) u16 {
    return base + @as(u16, @intCast((pp + pool_idx) % size));
}

/// Authored device-limit keys: the SJON kebab-case key ↔ the EXACT WebGPU
/// camelCase limit name interned into the string table (so gpu.js/native need no
/// hardcoded name map). kebab→camel is NOT mechanical (`…-2d` → `…2D`, capital
/// D) — this table is the single source of truth. Mirrors the schema's
/// `(form :name limits …)` keys 1:1. (Arc-3 §5.3b)
const device_limit_pairs = [_]struct { kebab: []const u8, camel: []const u8 }{
    .{ .kebab = "max-texture-dimension-1d", .camel = "maxTextureDimension1D" },
    .{ .kebab = "max-texture-dimension-2d", .camel = "maxTextureDimension2D" },
    .{ .kebab = "max-texture-dimension-3d", .camel = "maxTextureDimension3D" },
    .{ .kebab = "max-texture-array-layers", .camel = "maxTextureArrayLayers" },
    .{ .kebab = "max-bind-groups", .camel = "maxBindGroups" },
    .{ .kebab = "max-bind-groups-plus-vertex-buffers", .camel = "maxBindGroupsPlusVertexBuffers" },
    .{ .kebab = "max-bindings-per-bind-group", .camel = "maxBindingsPerBindGroup" },
    .{ .kebab = "max-dynamic-uniform-buffers-per-pipeline-layout", .camel = "maxDynamicUniformBuffersPerPipelineLayout" },
    .{ .kebab = "max-dynamic-storage-buffers-per-pipeline-layout", .camel = "maxDynamicStorageBuffersPerPipelineLayout" },
    .{ .kebab = "max-sampled-textures-per-shader-stage", .camel = "maxSampledTexturesPerShaderStage" },
    .{ .kebab = "max-samplers-per-shader-stage", .camel = "maxSamplersPerShaderStage" },
    .{ .kebab = "max-storage-buffers-per-shader-stage", .camel = "maxStorageBuffersPerShaderStage" },
    .{ .kebab = "max-storage-buffers-in-vertex-stage", .camel = "maxStorageBuffersInVertexStage" },
    .{ .kebab = "max-storage-buffers-in-fragment-stage", .camel = "maxStorageBuffersInFragmentStage" },
    .{ .kebab = "max-storage-textures-per-shader-stage", .camel = "maxStorageTexturesPerShaderStage" },
    .{ .kebab = "max-storage-textures-in-vertex-stage", .camel = "maxStorageTexturesInVertexStage" },
    .{ .kebab = "max-storage-textures-in-fragment-stage", .camel = "maxStorageTexturesInFragmentStage" },
    .{ .kebab = "max-immediate-size", .camel = "maxImmediateSize" },
    .{ .kebab = "max-uniform-buffers-per-shader-stage", .camel = "maxUniformBuffersPerShaderStage" },
    .{ .kebab = "max-uniform-buffer-binding-size", .camel = "maxUniformBufferBindingSize" },
    .{ .kebab = "max-storage-buffer-binding-size", .camel = "maxStorageBufferBindingSize" },
    .{ .kebab = "min-uniform-buffer-offset-alignment", .camel = "minUniformBufferOffsetAlignment" },
    .{ .kebab = "min-storage-buffer-offset-alignment", .camel = "minStorageBufferOffsetAlignment" },
    .{ .kebab = "max-vertex-buffers", .camel = "maxVertexBuffers" },
    .{ .kebab = "max-buffer-size", .camel = "maxBufferSize" },
    .{ .kebab = "max-vertex-attributes", .camel = "maxVertexAttributes" },
    .{ .kebab = "max-vertex-buffer-array-stride", .camel = "maxVertexBufferArrayStride" },
    .{ .kebab = "max-inter-stage-shader-variables", .camel = "maxInterStageShaderVariables" },
    .{ .kebab = "max-color-attachments", .camel = "maxColorAttachments" },
    .{ .kebab = "max-color-attachment-bytes-per-sample", .camel = "maxColorAttachmentBytesPerSample" },
    .{ .kebab = "max-compute-workgroup-storage-size", .camel = "maxComputeWorkgroupStorageSize" },
    .{ .kebab = "max-compute-invocations-per-workgroup", .camel = "maxComputeInvocationsPerWorkgroup" },
    .{ .kebab = "max-compute-workgroup-size-x", .camel = "maxComputeWorkgroupSizeX" },
    .{ .kebab = "max-compute-workgroup-size-y", .camel = "maxComputeWorkgroupSizeY" },
    .{ .kebab = "max-compute-workgroup-size-z", .camel = "maxComputeWorkgroupSizeZ" },
    .{ .kebab = "max-compute-workgroups-per-dimension", .camel = "maxComputeWorkgroupsPerDimension" },
};

/// The resource kind a SJON `(entry …)` entry declares — mirrors `bindGroupEntry`'s
/// present-resource resolution (buffer / sampler / texture). Returns null when no
/// resource sub-key is present (the schema's exclusive-group makes that
/// unreachable in practice, but a null keeps the caller total). Pure.
fn bindEntryKind(r: *const Reader, entry: NodeIndex) ?BindKind {
    if (r.symbol(entry, "buffer") != null) return .buffer;
    if (r.symbol(entry, "sampler") != null) return .sampler;
    if (r.symbol(entry, "texture") != null) return .texture;
    // An explicit (texture-view …) is a texture binding to the shader (WGSL
    // reflects it as a `texture_*` resource), so the R1 bind-kind check treats it
    // the same as a direct texture.
    if (r.symbol(entry, "texture-view") != null) return .texture;
    return null;
}

/// A clear-value channel's f32 bit pattern, the shape the wire carries.
/// Replaces `floatToU8`, which quantized to 1/255 AND clamped to [0,1].
fn floatBits(v: f64) u32 {
    return @bitCast(@as(f32, @floatCast(v)));
}

fn appendU16LE(gpa: Allocator, list: *std.ArrayList(u8), v: u16) Allocator.Error!void {
    try list.append(gpa, @intCast(v & 0xFF));
    try list.append(gpa, @intCast(v >> 8));
}

fn appendU32LE(gpa: Allocator, list: *std.ArrayList(u8), v: u32) Allocator.Error!void {
    try list.append(gpa, @intCast(v & 0xFF));
    try list.append(gpa, @intCast((v >> 8) & 0xFF));
    try list.append(gpa, @intCast((v >> 16) & 0xFF));
    try list.append(gpa, @intCast(v >> 24));
}

fn appendInt(gpa: Allocator, list: *std.ArrayList(u8), v: u32) Allocator.Error!void {
    var buf: [12]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    try list.appendSlice(gpa, s);
}
