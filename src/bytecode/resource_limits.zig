//! Resource limits — one number, one place, every reader.
//!
//! Three backends implement one dispatcher contract, and each used to carry its
//! own hand-written table of "how many of this resource kind can exist". The
//! tables disagreed (bind groups were 64 on two of them and 128 on the third),
//! covered different id spaces (five in two backends, ten in one), and the
//! compiler knew none of them — so a document `pngine validate` called OK could
//! die at render with `error.InvalidResourceId`, naming neither the cap, nor the
//! resource kind, nor a line. This file is the one declaration all of them read.
//!
//! ## Design
//!
//! Three different kinds of number get called a "limit", and they have three
//! different homes. Writing the classification down is half the point of this
//! file — it is the part a later reader needs and the part a diff cannot show:
//!
//! - **Wire facts** — the width of a field in the PNGB stream. They change only
//!   when the format does, and they are *derived* here rather than restated:
//!   `MAX_EXECUTE_BUNDLES` comes from `wire_schema`, `MAX_ID` is the id type.
//!   `:pool`'s 255 is the third (it is the `count` byte; it lives at its author-
//!   facing check in `Emitter.zig` beside the schema bound it mirrors).
//! - **Spec facts** — WebGPU's own limits, identical in every runtime that
//!   implements WebGPU. `MAX_COLOR_ATTACHMENTS` is the one this engine bounds
//!   itself by.
//! - **Implementation budgets** — the size of a statically-allocated table in
//!   ONE runtime. Two runtimes have them: the shipping WASM executor
//!   (`DEFAULT_MAX_PASSES`, `DEFAULT_MAX_FRAMES`) and the native wgpu backend
//!   (the `IdSpace` budgets below). They are the only numbers here that could
//!   move without the format or the spec moving.
//!
//! ## Invariants
//!
//! - `budgetOf` is TOTAL over `IdSpace`: a new id space is a compile error here,
//!   not a silently uncapped table.
//! - Every backend's `MAX_*` constant IS `capOf(...)` rather than a copy of the
//!   number, so there is nothing for a drift gate to compare. The half that can
//!   still fall behind is the compiler's knowledge of them, and that half is
//!   gated by `Emitter.tableOf`'s own total switch.
//! - `held_by` says WHICH runtime holds the smallest table, because that decides
//!   what the emitter's refusal can honestly promise about the other two.

const std = @import("std");
const wire_schema = @import("wire_schema.zig");

// ── Wire facts ──────────────────────────────────────────────────────────────

/// The id space PNGB addresses. Ids are u16 on the wire, so this is a ceiling no
/// runtime budget can exceed — an id past it wraps, and every wrapped id ALIASES
/// a live resource rather than failing.
pub const MAX_ID: u16 = std.math.maxInt(u16);

/// Maximum render bundles a single `execute_bundles` opcode carries — a hard
/// wire limit fixed by the opcode's `[16]u16` decode buffer in BOTH the shipping
/// executor (`wasm_entry.zig`) and the reference dispatcher. Unlike
/// `DEFAULT_MAX_PASSES` it is NOT build-configurable: a pass listing more bundles
/// overflows the opcode, so the SJON emitter rejects it outright.
///
/// Derived from the wire schema rather than restated. It was an independent
/// `16` while the schema's own cap for the opcode said 50_000, and the decoders
/// read-and-discarded ids between the two — which is precisely the range where
/// they walked past where `skipParams` stopped (§320).
pub const MAX_EXECUTE_BUNDLES: u32 = wire_schema.repMaxOf(.execute_bundles);

// ── Spec facts ──────────────────────────────────────────────────────────────

/// Color attachments per render pass — WebGPU's `maxColorAttachments` floor.
///
/// One number, four consumers: the width of `begin_render_pass_mrt`'s attachment
/// array, the native backend's blend/target scratch, the emitter's per-pass
/// reject, and `(draw-graph …)`'s per-stage reject. It is a SPEC fact rather
/// than a budget — raising it would need every WebGPU implementation to raise
/// it, not just this engine — which is why it is a scalar here and not an
/// `IdSpace`: attachments are a per-pass count, not an id space.
pub const MAX_COLOR_ATTACHMENTS: u16 = 8;

comptime {
    // The MRT opcode's attachment group was sized BECAUSE the spec says 8. They
    // are two statements of one fact — a spec fact and the wire fact it forced —
    // so a change to either that leaves the other behind is a stream the emitter
    // writes and the scanner cannot skip.
    if (wire_schema.repMaxOf(.begin_render_pass_mrt) != MAX_COLOR_ATTACHMENTS) @compileError(
        "resource_limits: MAX_COLOR_ATTACHMENTS and begin_render_pass_mrt's rep cap disagree",
    );
}

// ── Browser executor budgets ────────────────────────────────────────────────

/// Default number of distinct passes the shipping WASM executor can store — the
/// fixed size of `wasm_entry.zig`'s `pass_ranges` table (`wasm_config` defaults
/// `max_passes` to this). Both sides mirror it: the executor's config default
/// derives from this constant, and the SJON emitter rejects any document that
/// defines more passes. Exceeding it is a silent-drop divergence — the executor
/// stores a range only for `pass_id < max_passes`, so a pass beyond the cap
/// vanishes at load, whereas the reference dispatcher's pass map is unbounded
/// (so the document renders in native `--frame`/tests but loses passes in every
/// browser). A custom executor build MAY raise its own `max_passes`; the
/// frontend targets the default shipping executor.
pub const DEFAULT_MAX_PASSES: u16 = 32;

/// Maximum `(frame …)` definitions the shipping executor indexes by name
/// (`wasm_entry.zig`'s `frame_entries` table). A frame past this count is
/// silently skipped by the executor's frame scan — the same asymmetry as
/// `DEFAULT_MAX_PASSES` (the reference dispatcher has no such table), so the
/// frontend refuses the document instead of shipping one the browser reads
/// differently from the preview.
pub const DEFAULT_MAX_FRAMES: u16 = 64;

// ── Resource id spaces ──────────────────────────────────────────────────────

/// One id space the PNGB stream addresses — exactly the compiler's id
/// registries, so `Emitter.tableOf` can be total over this enum.
pub const IdSpace = enum {
    buffers,
    textures,
    texture_views,
    samplers,
    shaders,
    /// Render and compute pipelines share ONE id space: `set_pipeline` carries a
    /// single id and the backends index both of their arrays with it. The budget
    /// is therefore the smaller of the two arrays, not their sum.
    pipelines,
    bind_groups,
    bind_group_layouts,
    pipeline_layouts,
    image_bitmaps,
    render_bundles,
    query_sets,
    passes,
    wasm_modules,
    wasm_calls,
};

/// Which runtime holds the smallest table for an id space. It decides what a
/// compile-time refusal can honestly say about the runtimes that are NOT the
/// binding one — the two answers point in opposite directions, and a message
/// that guessed would be worse than no message.
pub const HeldBy = enum {
    /// No runtime table is smaller than the wire's own id space.
    wire,
    /// The native wgpu backend's fixed array. The browser has no such table, so
    /// a document past this loads in a browser and fails `--frame`.
    native,
    /// The shipping WASM executor's fixed table. Native has no such cap, so a
    /// document past this previews natively and silently loses work in a browser.
    browser,
};

/// What one id space costs and who bounds it. `noun`/`plural` are the words a
/// diagnostic uses, so the message reads as prose rather than as a field name.
pub const Budget = struct {
    max: u16,
    held_by: HeldBy,
    noun: []const u8,
    plural: []const u8,
};

/// The budget for `space`. TOTAL over `IdSpace` — a new member without a budget
/// is a compile error, which is the whole reason the enum exists.
///
/// The native numbers are the sizes of `WgpuNativeGPU`'s arrays; the `.wire`
/// ones are the id spaces the native backend STUBS (bundles, query sets, image
/// bitmaps, nested WASM), where nothing smaller than the wire ceiling exists to
/// enforce. A stub growing a real table is the event that moves one of those.
pub fn budgetOf(space: IdSpace) Budget {
    return switch (space) {
        .buffers => .{ .max = 256, .held_by = .native, .noun = "buffer", .plural = "buffers" },
        .textures => .{ .max = 256, .held_by = .native, .noun = "texture", .plural = "textures" },
        .texture_views => .{ .max = 256, .held_by = .native, .noun = "texture view", .plural = "texture views" },
        .samplers => .{ .max = 64, .held_by = .native, .noun = "sampler", .plural = "samplers" },
        .shaders => .{ .max = 64, .held_by = .native, .noun = "shader module", .plural = "shader modules" },
        .pipelines => .{ .max = 64, .held_by = .native, .noun = "pipeline", .plural = "pipelines" },
        // 128, not 64. The two recording backends said 64 because that was the
        // width of a `StaticBitSet` they keep for reporting, not a resource
        // budget — and the number that actually stops a render was always the
        // native backend's 128. Lowering native to 64 would refuse documents
        // that render today; raising the bitsets costs eight bytes each.
        .bind_groups => .{ .max = 128, .held_by = .native, .noun = "bind group", .plural = "bind groups" },
        .bind_group_layouts => .{ .max = 64, .held_by = .native, .noun = "bind-group layout", .plural = "bind-group layouts" },
        .pipeline_layouts => .{ .max = 64, .held_by = .native, .noun = "pipeline layout", .plural = "pipeline layouts" },
        .image_bitmaps => .{ .max = MAX_ID, .held_by = .wire, .noun = "image bitmap", .plural = "image bitmaps" },
        .render_bundles => .{ .max = MAX_ID, .held_by = .wire, .noun = "render bundle", .plural = "render bundles" },
        .query_sets => .{ .max = MAX_ID, .held_by = .wire, .noun = "query set", .plural = "query sets" },
        .passes => .{ .max = DEFAULT_MAX_PASSES, .held_by = .browser, .noun = "pass", .plural = "passes" },
        .wasm_modules => .{ .max = MAX_ID, .held_by = .wire, .noun = "wasm module", .plural = "wasm modules" },
        .wasm_calls => .{ .max = MAX_ID, .held_by = .wire, .noun = "wasm call", .plural = "wasm calls" },
    };
}

/// The count `space` admits. The spelling every backend's `MAX_*` uses.
pub fn capOf(space: IdSpace) u16 {
    return budgetOf(space).max;
}
