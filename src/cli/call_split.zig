//! Where a captured call log stops building the scene and starts being a frame.
//!
//! Two writers consume the same MockGPU call log and have to agree about that
//! boundary: `flat.zig` (pNGf, replayed by mini.js) and `js_codegen.zig`
//! (`--html`, emitted as JS text). They used to answer it with two private
//! heuristics — flat with the FIRST frame call, js_codegen with the LAST create
//! — which coincide on every log the emitter actually produces and diverge the
//! moment one doesn't:
//!
//!   - flat put the trailing creates into the per-frame stream (a create
//!     replayed at 60Hz, LEAK-05-B);
//!   - js_codegen hoisted the frame commands into module scope, so the page
//!     rendered once and then nothing.
//!
//! Same payload, opposite wrong answers, neither gated. The fix is not to teach
//! two heuristics to agree: it is to name the invariant the emitter already
//! guarantees — **every resource is created before the frame's first pass
//! command** — assert it in both consumers, and refuse the export when it fails.
//! Each writer keeps its own split rule (they legitimately differ on where a
//! mid-prologue `write_buffer` belongs); what they share is the refusal.
//!
//! ## Invariants
//!
//! - `isCreateCall` and `isFrameCall` are exhaustive over `CallType`: a new call
//!   type is a compile error here, in one place, rather than a silent `false` in
//!   two.
//! - `createAtOrAfterFrameStart` returns an index into `calls` or null; it never
//!   allocates and never fails.

const std = @import("std");
const pngine = @import("pngine");
const CallType = pngine.mock_gpu.CallType;
const Call = pngine.mock_gpu.Call;

/// A command that belongs to the frame: it draws, or sets state for something
/// that draws, or submits. The list is exactly what `flat.zig`'s
/// `serializePassCall` emits — it does not need to name every pass command in
/// existence, because a command absent from both writers is refused before the
/// split can matter, but it must name every one a writer can emit.
pub fn isFrameCall(call_type: CallType) bool {
    return switch (call_type) {
        .begin_render_pass,
        .begin_compute_pass,
        .end_pass,
        .set_pipeline,
        .set_bind_group,
        .set_vertex_buffer,
        .draw,
        .draw_indexed,
        .dispatch,
        .submit,
        => true,
        else => false,
    };
}

/// A command that mints a GPU object. Thirteen of them, matching the thirteen
/// create opcodes of the wire format (`Cmd` in executor/command_buffer.zig) —
/// which has no destroy of any kind, so one of these in a replayed frame is
/// unbounded growth with nothing to balance it (pitfall 35).
pub fn isCreateCall(call_type: CallType) bool {
    return switch (call_type) {
        .create_buffer,
        .create_texture,
        .create_sampler,
        .create_shader_module,
        .create_render_pipeline,
        .create_compute_pipeline,
        .create_bind_group,
        .create_texture_view,
        .create_query_set,
        .create_bind_group_layout,
        .create_pipeline_layout,
        .create_image_bitmap,
        .create_render_bundle,
        => true,
        else => false,
    };
}

/// Index of the frame's first pass command, or `calls.len` when the log has no
/// frame at all (a creation-only payload).
///
/// Defined by what STARTS the frame rather than by what ends the prologue. The
/// negative spelling ("run while the call is a create") looks equivalent and is
/// not: `:mapped-at-creation` captures create_buffer, **write_buffer**, and only
/// then the shader module and pipeline, so a single write in the middle of an
/// ordinary prologue puts every later create after the split.
pub fn firstFrameCall(calls: []const Call) usize {
    for (calls, 0..) |call, i| {
        if (isFrameCall(call.call_type)) return i;
    }
    return calls.len;
}

/// The shared refusal test: the index of the first create call that appears at
/// or after the frame's first pass command, or null when the log is well-formed.
///
/// Unreachable from any compiled document today — `emitFrame` cannot emit a
/// `create_*` — but both writers run on arbitrary PNGB, including hand-built and
/// corrupt input (the r1-03 lesson). There is no split that saves such a log:
/// the create is *inside* the frame, so any boundary either replays it or drops
/// the pass commands around it.
///
/// Post-condition: the returned index, when present, is `>= firstFrameCall`.
pub fn createAtOrAfterFrameStart(calls: []const Call) ?usize {
    const start = firstFrameCall(calls);
    std.debug.assert(start <= calls.len);
    for (calls[start..], start..) |call, i| {
        if (isCreateCall(call.call_type)) {
            std.debug.assert(i >= start);
            return i;
        }
    }
    return null;
}
