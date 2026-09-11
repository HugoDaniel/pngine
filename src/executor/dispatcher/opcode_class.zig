//! Opcode Class — single source of truth for which handler owns which opcode.
//!
//! The `class` dimension of `OpCode`, the counterpart to the `layout` dimension
//! `bytecode/wire_schema.zig` owns. Same principle, stated there: *"`layoutOf(op)`
//! — comptime, total over NAMED opcodes; a new OpCode without a layout is a
//! `@compileError`, not a silent 5-varint fallback."* `classOf` is that for
//! routing.
//!
//! ## What this replaced
//!
//! Six hand-written `is_*_opcode` predicates (one per handler module), each
//! listing the opcodes of one category, plus each handler's `handle()` switch
//! listing the same opcodes again — 60 opcodes, 120 arms, held in step by
//! nothing. The `assert(is_*_opcode(op))` that opened every `handle` looked like
//! the guard on the pair and could not fire: `handle` is called from one place,
//! and only after the predicate already returned true.
//!
//! Both directions of drift were measured (r3-02 step 0), on a tree where the
//! two lists agreed exactly:
//!
//!   - predicate lists an opcode `handle` does not → the router's `_ = try …`
//!     discarded the `false`, `step()` returned SUCCESSFULLY with `pc` advanced
//!     by one byte, and the operands were then read as opcodes. `pngine inspect
//!     examples/pass_bloom.sjon` printed "Execution OK" and exit 0 while the
//!     desynced stream produced a garbage descriptor tag.
//!   - `handle` has an arm the predicate does not → the arm is unreachable dead
//!     code, compiled with no warning, and the opcode falls through to
//!     `error.InvalidOpcode`.
//!
//! Both silent in the shipping build: assertions compile out at ReleaseSmall.
//!
//! ## Design
//!
//! - `Class` names the handler modules of `handlers.zig` one-for-one, plus
//!   `special` for the three opcodes no handler owns.
//! - `classOf(op)` — total over NAMED opcodes, by Zig's own switch
//!   exhaustiveness rather than a hand-rolled `@compileError`: the switch has no
//!   `else`, so a new `OpCode` member without a class fails the build with
//!   `unhandled enumeration value: '<name>'`. Only the UNNAMED `_` range (a byte
//!   the enum has no member for) maps to `null`.
//! - The dispatcher switches on `classOf(op)` ONCE instead of asking six
//!   predicates in order — there was never a priority to preserve, the six sets
//!   are disjoint (proven by `opcode_class_test.zig`).
//! - Each `handle` still returns `!bool`; the router now REFUSES on `false`
//!   (`error.InvalidOpcode`) rather than discarding it, so a class/arm
//!   disagreement is a refusal in every build, not a stream desync in the
//!   stripped one.
//!
//! ## Invariants
//!
//! - Total over `OpCode`'s named members (enforced by `classOf`'s exhaustive
//!   switch, and re-derived at runtime by `opcode_class_test.zig`).
//! - `special` opcodes are exactly the three the dispatcher does not execute:
//!   `nop` (no effect), and `create_shader_concat` / `select_from_pool`
//!   (RESERVED-INERT — never emitted, error by design; see types/opcodes.zig).

const bytecode_mod = @import("bytecode");
const OpCode = bytecode_mod.opcodes.OpCode;

/// Which handler module owns an opcode. One member per module in `handlers.zig`,
/// plus `special` for the opcodes the dispatcher handles inline.
pub const Class = enum {
    resource,
    pass,
    queue,
    frame,
    pool,
    wasm,
    /// Handled inline by the dispatcher: `nop` executes nothing, the other two
    /// are reserved-inert and refused.
    special,
};

/// The handler class of an opcode, or null for an UNNAMED byte (`OpCode`'s `_`
/// range — a reserved/garbage opcode the enum has no member for).
///
/// The switch has NO `else`: every named member must appear, so adding one
/// without a class fails the build here rather than falling through to
/// `error.InvalidOpcode` at runtime in whichever payload first uses it.
///
/// Grouped by handler module rather than by opcode number: the numeric ranges
/// and the modules do NOT coincide (pool ops 0x41-0x43 and the extended pass
/// state 0x4A-0x52 share the 0x4x block but split across two handlers; the
/// nested-WASM ops sit at 0x26-0x28 inside the queue block). The grouping here
/// is the routing fact; `types/opcodes.zig`'s section comments are the numbering.
pub fn classOf(op: OpCode) ?Class {
    return switch (op) {
        // ── resource.zig — GPU object creation (0x01-0x0E, minus 0x05) ──
        .create_buffer,
        .create_texture,
        .create_sampler,
        .create_shader_module,
        .create_bind_group_layout,
        .create_pipeline_layout,
        .create_render_pipeline,
        .create_compute_pipeline,
        .create_bind_group,
        .create_image_bitmap,
        .create_texture_view,
        .create_query_set,
        .create_render_bundle,
        => .resource,

        // ── pass.zig — render/compute pass commands and pre-pass state ──
        .begin_render_pass,
        .begin_render_pass_mrt,
        .begin_compute_pass,
        .set_pipeline,
        .set_bind_group,
        .set_vertex_buffer,
        .set_index_buffer,
        .draw,
        .draw_indexed,
        .dispatch,
        .draw_indirect,
        .draw_indexed_indirect,
        .dispatch_indirect,
        .set_viewport,
        .set_pass_occlusion_query_set,
        .set_pass_timestamp_writes,
        .begin_occlusion_query,
        .end_occlusion_query,
        .set_stencil_reference,
        .set_scissor_rect,
        .set_pass_depth_stencil_ops,
        .set_blend_constant,
        .set_pass_clear_values,
        .execute_bundles,
        .end_pass,
        => .pass,

        // ── queue.zig — writes, copies, submit ──
        .write_buffer,
        .write_uniform,
        .write_time_uniform,
        .write_pointer_uniform,
        .write_audio_data,
        .copy_buffer_to_buffer,
        .copy_texture_to_texture,
        .copy_external_image_to_texture,
        .resolve_query_set,
        .submit,
        => .queue,

        // ── frame.zig — frame/pass definition and invocation ──
        .define_frame,
        .end_frame,
        .define_pass,
        .end_pass_def,
        .exec_pass,
        .exec_pass_once,
        => .frame,

        // ── pool.zig — ping-pong pool selection (0x41-0x43) ──
        .set_vertex_buffer_pool,
        .set_bind_group_pool,
        .begin_render_pass_pool,
        => .pool,

        // ── wasm_ops.zig — nested WASM (0x26-0x28) ──
        .init_wasm_module,
        .call_wasm_func,
        .write_buffer_from_wasm,
        => .wasm,

        // ── dispatcher.zig, inline ──
        .nop,
        .create_shader_concat,
        .select_from_pool,
        => .special,

        // NOT an `else`. `_` covers only the UNNAMED range — bytes the enum has
        // no member for, which a hostile payload can carry. A named member left
        // off the lists above is `unhandled enumeration value` at build time,
        // which is the entire point of this table.
        _ => null,
    };
}
