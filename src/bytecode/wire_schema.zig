//! Opcode Wire Schema — single source of truth for PNGB operand layouts.
//!
//! Each opcode's operands follow a `Layout` described here in WIRE ORDER. The
//! bytecode EMITTER (`emitter.zig`) writes these bytes; two consumers read them
//! back through this ONE table so neither can drift from the emitter:
//!   - the pass-discovery SCANNER (`dispatcher/scanner.zig`) skips operands via
//!     `skipParams` (uses only each field's `.kind`);
//!   - the DISPATCHER handlers decode operands via `readOperands` (uses each
//!     field's `.name` + `.kind` to build a typed `Operands(layout)` struct).
//! The historical bug this prevents: the scanner skipped
//! `copy_external_image_to_texture` as 5 varints while the emitter writes
//! `varint, varint, BYTE (mip_level), varint, varint` (any mip ≥ 0x80 desynced
//! the scanner). The table is written FROM the emitter and locked to it by the
//! wire-conformance round-trip tests; the emit* methods are NOT rewritten
//! (their bytes are pinned by emitter_test.zig + the golden traces).
//!
//! ## Design
//! - `Kind` — one operand field's wire encoding.
//! - `Field` — a named `Kind`. Names drive `Operands(layout)`'s struct fields;
//!   `skipParams` ignores them. Shapes shared across opcodes (L_1V…L_5V) carry
//!   generic names (`v0`, `v1`, …); shapes used by a single opcode name their
//!   fields semantically.
//! - `Rep` — a count-prefixed repeated group (MRT attachments, WASM args, …).
//! - `Layout` — head fields, an optional Rep, then tail fields.
//! - `layoutOf(op)` — comptime, total over NAMED opcodes; a new OpCode without
//!   a layout is a `@compileError`, not a silent 5-varint fallback.
//! - `skipParams` / `readOperands` — both are built from the SHARED named
//!   `Layout` constants. `readOperands` decodes through them directly;
//!   `skipParams` walks a packed descriptor table compiled FROM them (see the
//!   "Skip" section), so the executor pays for one walker instead of one
//!   monomorphized body per distinct shape.
//! - `readOperands` handles FIXED-shape layouts (`rep == null`) only. The
//!   count-prefixed opcodes decode manually in their handlers because each maps
//!   onto a backend-specific shape the wire table does not describe:
//!   `begin_render_pass_mrt` → `[8]ColorAttachment`, `begin_render_pass_views` →
//!   `[8]ViewColorAttachment`, `call_wasm_func` → a re-encoded args blob,
//!   `execute_bundles` → a 16-slot store that reads and discards the overflow,
//!   `create_shader_concat` → (unimplemented handler).
//!
//! ## Invariants
//! - Field order matches the emit* method exactly (varint width is
//!   self-describing, so order is significant).
//! - `Rep.max` mirrors the EXISTING scanner clamps exactly (behaviour-preserving:
//!   MRT 8, WASM args 32, execute_bundles / shader_concat MAX_SCAN_ITERATIONS).
//! - `skipParams` never advances past `bytecode.len`; unknown/reserved opcodes
//!   advance nothing (parity with the old scanner's `_ => {}`).

const std = @import("std");
const assert = std.debug.assert;
const opcodes = @import("opcodes.zig");
const OpCode = opcodes.OpCode;
const WasmArgType = opcodes.WasmArgType;

/// The ceiling a `.byte`-encoded count can express. A rep group with no cap of
/// its own spells its bound as the encoding's own limit, so `@min(count, max)`
/// is provably a no-op rather than a large number that merely looks safe.
///
/// The predecessor of this constant was `MAX_GROUP = 50_000`, sized to mirror
/// the scanner's iteration bound. It made both rep groups that used it wrong in
/// opposite directions: unreachable for a byte count, and — for
/// `execute_bundles`, whose count is a varint — 50_000 above the real limit of
/// 16, which is what let the skipper and the decoders part company (§320).
const COUNT_BYTE_MAX: u32 = 255;

/// One operand field's wire encoding.
pub const Kind = enum {
    /// LEB128-style varint (1/2/4 bytes, self-describing width).
    varint,
    /// A single raw byte (enum tag, flag, mip level, clear channel, …).
    byte,
    /// Raw little-endian u32 (4 bytes) — e.g. an f32 bit pattern.
    u32_le,
    /// A WASM call arg: 1 type byte + WasmArgType.valueByteSize() value bytes.
    wasm_arg,
};

/// A named operand field. `name` becomes an `Operands(layout)` struct field;
/// `kind` is its wire encoding. `skipParams` reads only `kind`.
pub const Field = struct { name: [:0]const u8, kind: Kind };

/// Terse `Field` constructor for the layout table below.
fn nk(comptime name: [:0]const u8, comptime kind: Kind) Field {
    return .{ .name = name, .kind = kind };
}

/// A count-prefixed repeated group of fields.
pub const Rep = struct {
    /// How the element count is encoded on the wire.
    count: enum { byte, varint },
    /// The field sequence emitted once per element.
    elem: []const Field,
    /// Element cap the WHOLE pipeline honours — see `repMaxOf`.
    max: u32,
};

/// An opcode's operand layout in wire order: head, optional repeated group, tail.
pub const Layout = struct {
    head: []const Field = &.{},
    rep: ?Rep = null,
    tail: []const Field = &.{},
};

// ── Shared fixed layouts (named so identical shapes fold to one decode body and one skip row) ──
const L_NONE = Layout{};
const L_1V = Layout{ .head = &.{nk("v0", .varint)} };
const L_2V = Layout{ .head = &.{ nk("v0", .varint), nk("v1", .varint) } };
const L_3V = Layout{ .head = &.{ nk("v0", .varint), nk("v1", .varint), nk("v2", .varint) } };
const L_4V = Layout{ .head = &.{ nk("v0", .varint), nk("v1", .varint), nk("v2", .varint), nk("v3", .varint) } };
const L_5V = Layout{ .head = &.{ nk("v0", .varint), nk("v1", .varint), nk("v2", .varint), nk("v3", .varint), nk("v4", .varint) } };
const L_BYTE_V = Layout{ .head = &.{ nk("slot", .byte), nk("id", .varint) } }; // set_bind_group, set_vertex_buffer
const L_V_BYTE = Layout{ .head = &.{ nk("buffer_id", .varint), nk("index_format", .byte) } }; // set_index_buffer
const L_4BYTE = Layout{ .head = &.{ nk("depth_load_op", .byte), nk("depth_store_op", .byte), nk("stencil_load_op", .byte), nk("stencil_store_op", .byte) } }; // set_pass_depth_stencil_ops
const L_CREATE_BUFFER = Layout{ .head = &.{ nk("buffer_id", .varint), nk("size", .varint), nk("usage_lo", .byte), nk("usage_hi", .byte) } };
const L_COPY_EXT_IMG = Layout{ .head = &.{ nk("bitmap_id", .varint), nk("texture_id", .varint), nk("mip_level", .byte), nk("origin_x", .varint), nk("origin_y", .varint), nk("origin_z", .varint) } };
const L_VIEWPORT = Layout{ .head = &.{ nk("x", .varint), nk("y", .varint), nk("w", .varint), nk("h", .varint), nk("min_depth", .u32_le), nk("max_depth", .u32_le) } };
const L_BLEND_CONSTANT = Layout{ .head = &.{ nk("r", .u32_le), nk("g", .u32_le), nk("b", .u32_le), nk("a", .u32_le) } }; // set_blend_constant — 4 f32 bit patterns
const L_CLEAR_VALUES = Layout{ .head = &.{ nk("depth_bits", .u32_le), nk("stencil_value", .u32_le) } }; // set_pass_clear_values — f32 bit pattern + u32
// The four clear channels are f32 BIT PATTERNS, like set_blend_constant's and
// set_pass_clear_values' depth. They were four u8s decoding `/255` until
// spec/09 step D: that quantized every clear to 1/255 and CLAMPED to [0,1],
// so an out-of-gamut clear on a float target -- legal WebGPU -- silently
// became white.
const L_BEGIN_RP = Layout{ .head = &.{ nk("color_texture_id", .varint), nk("load_op", .byte), nk("store_op", .byte), nk("depth_texture_id", .varint), nk("clear_r_bits", .u32_le), nk("clear_g_bits", .u32_le), nk("clear_b_bits", .u32_le), nk("clear_a_bits", .u32_le), nk("resolve_texture_id", .varint) } };
const L_BEGIN_RP_POOL = Layout{ .head = &.{ nk("base_tex_id", .varint), nk("pool_size", .byte), nk("offset", .byte), nk("load_op", .byte), nk("store_op", .byte), nk("depth_tex_id", .varint), nk("clear_r_bits", .u32_le), nk("clear_g_bits", .u32_le), nk("clear_b_bits", .u32_le), nk("clear_a_bits", .u32_le) } };
const L_POOL_SET = Layout{ .head = &.{ nk("slot", .byte), nk("base_id", .varint), nk("pool_size", .byte), nk("offset", .byte) } }; // set_*_buffer/bind_group_pool
const L_SELECT_POOL = Layout{ .head = &.{ nk("slot", .byte), nk("base_id", .varint), nk("offset", .byte) } };
const L_DEFINE_PASS = Layout{ .head = &.{ nk("pass_id", .varint), nk("pass_type", .byte), nk("descriptor_data_id", .varint) } };
// Plan 02's 14-field writeTexture order. The three optional fields are ALWAYS
// on the wire (0 when absent); the trailing flags byte is what distinguishes an
// omitted stride/size from an authored zero. Never reorder: the emitter writes
// this order byte-for-byte and both decoders build from this table.
const L_WRITE_TEXTURE = Layout{ .head = &.{
    nk("texture_id", .varint),
    nk("data_id", .varint),
    nk("offset", .varint),
    nk("bytes_per_row", .varint),
    nk("rows_per_image", .varint),
    nk("mip_level", .varint),
    nk("origin_x", .varint),
    nk("origin_y", .varint),
    nk("origin_z", .varint),
    nk("aspect", .byte),
    nk("size_width", .varint),
    nk("size_height", .varint),
    nk("size_depth", .varint),
    nk("flags", .byte),
} };

// Plan 05's shared fixed buffer↔texture copy field sequence. BOTH 0x2E and
// 0x2F use this ONE layout: the direction is the opcode, never an operand. The
// three optional fields are always on the wire (0 when absent); the trailing
// flags byte distinguishes an omitted stride/size from an authored zero, with
// plan 02's exact bits (0=bytes-per-row, 1=rows-per-image, 2=size). Never
// reorder: the emitter writes this order byte-for-byte and every decoder,
// scanner and fixture builds from this table.
const L_TEXTURE_BUFFER_COPY = Layout{ .head = &.{
    nk("texture_id", .varint),
    nk("buffer_id", .varint),
    nk("offset", .varint),
    nk("bytes_per_row", .varint),
    nk("rows_per_image", .varint),
    nk("mip_level", .varint),
    nk("origin_x", .varint),
    nk("origin_y", .varint),
    nk("origin_z", .varint),
    nk("aspect", .byte),
    nk("size_width", .varint),
    nk("size_height", .varint),
    nk("size_depth", .varint),
    nk("flags", .byte),
} };

// Plan 06's fixed subresource texture→texture copy sequence, in the plan's
// order. Both endpoints carry id, mip, origin x/y/z and an aspect BYTE; the
// three size fields are always on the wire (0 when absent) and the trailing
// flags byte records presence with bit 0 (others zero). Never reorder: the
// emitter writes this order byte-for-byte and every decoder and fixture builds
// from this table.
const L_TEXTURE_SUBRESOURCE_COPY = Layout{ .head = &.{
    nk("source_id", .varint),
    nk("source_mip", .varint),
    nk("source_origin_x", .varint),
    nk("source_origin_y", .varint),
    nk("source_origin_z", .varint),
    nk("source_aspect", .byte),
    nk("destination_id", .varint),
    nk("destination_mip", .varint),
    nk("destination_origin_x", .varint),
    nk("destination_origin_y", .varint),
    nk("destination_origin_z", .varint),
    nk("destination_aspect", .byte),
    nk("size_width", .varint),
    nk("size_height", .varint),
    nk("size_depth", .varint),
    nk("flags", .byte),
} };

// ── Frame controls (0x36-0x39, frame program §7.1) ──
// `Kind` has no u16, so a skip is two `byte` fields — the same reason
// `usage_lo`/`usage_hi` exist. The skip counts bytes from the END of the
// instruction forward, little-endian.
const L_DEFINE_CONTROL = Layout{ .head = &.{nk("default_bits", .u32_le)} }; // authored default, f32 bit pattern
// Not L_3V: that shape's generic names (v0..v2) do not read semantically, and
// the dispatcher's handler reads `buffer`/`offset`/`size` by name.
const L_WRITE_CONTROLS = Layout{ .head = &.{ nk("buffer", .varint), nk("offset", .varint), nk("size", .varint) } };
const L_EXEC_IF = Layout{ .head = &.{ nk("slot", .varint), nk("comparison", .byte), nk("constant_bits", .u32_le), nk("skip_lo", .byte), nk("skip_hi", .byte) } };
const L_EXEC_SKIP = Layout{ .head = &.{ nk("skip_lo", .byte), nk("skip_hi", .byte) } };

// Both guard layouts END in the two skip bytes, in wire order (skip_lo then
// skip_hi). The reference dispatcher's load-time skip validation relies on
// this: it walks with `skipParams` only — never a second decoder — and reads
// the skip value from the two bytes immediately before the landing pc. If
// either layout ever stops ending in skip_lo/skip_hi, this fires.
comptime {
    for (.{ .{ "exec_if", L_EXEC_IF }, .{ "exec_skip", L_EXEC_SKIP } }) |pair| {
        const head = pair[1].head;
        const n = head.len;
        if (n < 2 or head[n - 2].kind != .byte or head[n - 1].kind != .byte) @compileError(
            "wire_schema: ." ++ pair[0] ++ " must end in skip_lo/skip_hi bytes",
        );
    }
}

// ── Shared count-prefixed layouts (rep-group; decoded manually in handlers) ──
const L_SHADER_CONCAT = Layout{ .head = &.{nk("shader_id", .varint)}, .rep = .{ .count = .byte, .elem = &.{nk("part_id", .varint)}, .max = COUNT_BYTE_MAX } };
// 16 is a HARD wire limit, not a storage convenience: both decoders read into a
// fixed [16]u16 and the emitter rejects a pass listing more. It lived here as
// 50_000 while both decoders read every id and discarded the surplus — which
// kept them agreeing with each other and disagreeing with `skipParams` above
// 50_000 ids. `bytecode.MAX_EXECUTE_BUNDLES` now derives from this. (§320)
const L_EXECUTE_BUNDLES = Layout{ .rep = .{ .count = .varint, .elem = &.{nk("bundle_id", .varint)}, .max = 16 } };
const L_MRT = Layout{ .rep = .{ .count = .byte, .elem = &.{ nk("texture_id", .varint), nk("load_op", .byte), nk("store_op", .byte), nk("clear_r_bits", .u32_le), nk("clear_g_bits", .u32_le), nk("clear_b_bits", .u32_le), nk("clear_a_bits", .u32_le) }, .max = 8 }, .tail = &.{nk("depth_texture_id", .varint)} };
// 0x81: the render-pass record with an explicit target (and a resolve target)
// per colour attachment. ONE layout — the emitter writes this order, the
// scanner skips it and the reference dispatcher decodes it from this table.
// `target`/`resolve_target`/`depth_target` use the shared attachment-target
// encoding in types/opcodes.zig (tagged view, texture, canvas, none).
const L_BEGIN_RP_VIEWS = Layout{
    .rep = .{
        .count = .byte,
        .elem = &.{
            nk("target", .varint),
            nk("load_op", .byte),
            nk("store_op", .byte),
            nk("clear_r_bits", .u32_le),
            nk("clear_g_bits", .u32_le),
            nk("clear_b_bits", .u32_le),
            nk("clear_a_bits", .u32_le),
            nk("resolve_target", .varint),
        },
        .max = 8,
    },
    .tail = &.{nk("depth_target", .varint)},
};
const L_CALL_WASM = Layout{ .head = &.{ nk("call_id", .varint), nk("module_id", .varint), nk("func_name_id", .varint) }, .rep = .{ .count = .byte, .elem = &.{nk("arg", .wasm_arg)}, .max = 32 } };

// ============================================================================
// Layout table — total over named opcodes (missing layout ⇒ @compileError)
// ============================================================================

/// Wire layout for an opcode's operands. Total over NAMED opcodes: a new OpCode
/// without a layout fails the build here rather than silently mis-skipping.
/// (A break-capture chain, not `orelse`: a comptime-known-non-null category
/// would collapse the `orelse` result to a non-optional Layout.)
pub fn layoutOf(comptime op: OpCode) Layout {
    // 0x2D is dispatched before the category chain so its own `Layout` const is
    // returned without a comptime optional capture; the queue helper below
    // names the same table row, and the wire fixture pins the emitted bytes.
    return switch (op) {
        .write_texture => L_WRITE_TEXTURE,
        // Plan 06's subresource texture→texture copy has its own fixed layout;
        // no other opcode shares it.
        .copy_texture_subresource => L_TEXTURE_SUBRESOURCE_COPY,
        // 0x81 is the first free slot after the retired block; name its layout
        // here rather than relying on the category chain for a count-prefixed
        // shape (the same reason write_texture and 0x80 are named above).
        .begin_render_pass_views => L_BEGIN_RP_VIEWS,
        // Both directions of the buffer↔texture copy share ONE fixed layout;
        // the opcode alone distinguishes them.
        .copy_buffer_to_texture, .copy_texture_to_buffer => L_TEXTURE_BUFFER_COPY,
        else => blk: {
            if (layoutResource(op)) |l| break :blk l;
            if (layoutPass(op)) |l| break :blk l;
            if (layoutQueue(op)) |l| break :blk l;
            if (layoutControl(op)) |l| break :blk l;
            @compileError("wire_schema: no layout for opcode ." ++ @tagName(op));
        },
    };
}

/// The element cap for a count-prefixed opcode — the single number the emitter,
/// the scanner, both decoders and the skipper must agree on.
///
/// It is a CONTRACT, not a per-consumer clamp. `skipParams` advances past
/// exactly `@min(count, max)` elements, so a consumer that walks more (or
/// fewer) leaves its pc somewhere the skipper would not: the next opcode is
/// then read out of the middle of the previous instruction's operands. That is
/// not a contained mis-read — it desyncs the rest of the stream. Three caps sit
/// below what their count encoding can express (`call_wasm_func` 32 of a
/// possible 255, `begin_render_pass_mrt` 8, `execute_bundles` 16 of a varint's
/// range), so "count ≤ max" is a real obligation on the emitter and a real
/// check for everyone downstream.
///
/// `call_wasm_func` learned this the expensive way: the emitter had no cap, the
/// dispatcher hand-transcribed 32, and the embedded executor honoured none — so
/// a legal 40-arg `(wasm-call …)` compiled clean and desynced two of the three
/// consumers (journal §319). `execute_bundles` had the mirror-image version:
/// both decoders read every id and discarded the surplus, which kept THEM in
/// agreement while the skipper stopped at this cap — a 60_000-id stream put
/// 10_000 bytes between them (§320).
pub fn repMaxOf(comptime op: OpCode) u32 {
    const layout = comptime layoutOf(op);
    const rep = comptime layout.rep orelse
        @compileError("wire_schema: ." ++ @tagName(op) ++ " has no rep group (its layout is fixed-shape)");
    return rep.max;
}

comptime {
    // A `.byte` count cannot exceed 255, so a larger cap is a cap that never
    // applies — it reads as a bound while `@min(count, max)` is a no-op. Both
    // rep groups that carried `MAX_GROUP = 50_000` were wrong, and one of them
    // desynced the pipeline for two releases. Spell `COUNT_BYTE_MAX` when a
    // byte-counted group genuinely has no limit beyond its encoding.
    for (@typeInfo(OpCode).@"enum".fields) |f| {
        const op: OpCode = @enumFromInt(f.value);
        const layout = layoutOf(op);
        if (layout.rep) |rep| {
            if (rep.count == .byte and rep.max > COUNT_BYTE_MAX) @compileError(
                "wire_schema: ." ++ f.name ++ " has a byte-encoded count with max " ++
                    std.fmt.comptimePrint("{d}", .{rep.max}) ++
                    " — unreachable above 255; use COUNT_BYTE_MAX for 'no cap'",
            );
            if (rep.max == 0) @compileError("wire_schema: ." ++ f.name ++ " has rep.max = 0");
        }
    }
}

/// Resource creation (0x00-0x0E).
fn layoutResource(comptime op: OpCode) ?Layout {
    return switch (op) {
        .nop => L_NONE,
        .create_buffer => L_CREATE_BUFFER,
        .create_texture,
        .create_sampler,
        .create_shader_module,
        .create_bind_group_layout,
        .create_pipeline_layout,
        .create_render_pipeline,
        .create_compute_pipeline,
        .create_image_bitmap,
        .create_query_set,
        .create_render_bundle,
        => L_2V,
        .create_shader_concat => L_SHADER_CONCAT,
        .create_bind_group, .create_texture_view => L_3V,
        else => null,
    };
}

/// Pass operations (0x10-0x1F) + pool (0x40-0x43) + extended pass (0x4A-0x52).
fn layoutPass(comptime op: OpCode) ?Layout {
    return switch (op) {
        .begin_render_pass => L_BEGIN_RP,
        .begin_render_pass_mrt => L_MRT,
        .begin_compute_pass, .end_pass, .end_occlusion_query => L_NONE,
        .set_pipeline,
        .set_pass_occlusion_query_set,
        .begin_occlusion_query,
        .set_stencil_reference,
        => L_1V,
        .set_bind_group, .set_vertex_buffer => L_BYTE_V,
        .set_index_buffer => L_V_BYTE,
        .draw, .set_scissor_rect => L_4V,
        .draw_indexed => L_5V,
        .dispatch, .set_pass_timestamp_writes => L_3V,
        .draw_indirect, .draw_indexed_indirect, .dispatch_indirect => L_2V,
        .set_viewport => L_VIEWPORT,
        .set_blend_constant => L_BLEND_CONSTANT,
        .set_pass_depth_stencil_ops => L_4BYTE,
        .set_pass_clear_values => L_CLEAR_VALUES,
        .execute_bundles => L_EXECUTE_BUNDLES,
        // Pool (0x40-0x43)
        .select_from_pool => L_SELECT_POOL,
        .set_vertex_buffer_pool, .set_bind_group_pool => L_POOL_SET,
        .begin_render_pass_pool => L_BEGIN_RP_POOL,
        else => null,
    };
}

/// Queue operations (0x20-0x2F), incl. nested-WASM ops.
///
/// `write_uniform` (0x21) and `write_audio_data` (0x2C) are RESERVED-INERT (C4):
/// their layouts stay here so both decoders skip them forever, but no frontend
/// path emits either (see types/opcodes.zig). They decode + skip in wasm_entry
/// (no command-buffer counterpart) and execute only in the reference dispatcher.
fn layoutQueue(comptime op: OpCode) ?Layout {
    return switch (op) {
        .write_buffer,
        .write_time_uniform,
        .write_pointer_uniform,
        .write_audio_data,
        => L_3V,
        .write_texture => L_WRITE_TEXTURE,
        .write_uniform, .copy_texture_to_texture, .init_wasm_module => L_2V,
        .copy_buffer_to_buffer, .resolve_query_set => L_5V,
        .copy_external_image_to_texture => L_COPY_EXT_IMG,
        .call_wasm_func => L_CALL_WASM,
        .write_buffer_from_wasm => L_4V,
        .submit => L_NONE,
        else => null,
    };
}

/// Frame control (0x30-0x39), incl. the frame-program controls and guards.
fn layoutControl(comptime op: OpCode) ?Layout {
    return switch (op) {
        .define_frame => L_2V,
        .end_frame, .end_pass_def => L_NONE,
        .exec_pass, .exec_pass_once => L_1V,
        .define_pass => L_DEFINE_PASS,
        .define_control => L_DEFINE_CONTROL,
        .write_controls => L_WRITE_CONTROLS,
        .exec_if => L_EXEC_IF,
        .exec_skip => L_EXEC_SKIP,
        else => null,
    };
}

// ============================================================================
// Skip — advance a pc past an instruction's operands
// ============================================================================
//
// The skip table is PACKED because it runs in every executor variant and is
// walked for every instruction the scanner steps over. The previous form was
// `inline else`, which monomorphized one skipper body per distinct Layout
// (2,373 B in `skipOpcodeParams` plus ~430 B of `skipLayout`/`skipKind`
// helpers). Here the same layouts are packed at comptime into one opcode→row
// map and one flat descriptor stream, walked by one function: the saving is
// the duplicate bodies, not a change in what a skip does.
//
// Each row is five header bytes followed by one kind code per wire field:
//
//     head_len, rep_kind, rep_max, rep_elem_len, tail_len,
//     [head kind codes] [rep element kind codes] [tail kind codes]
//
// `rep_kind` is 0 for no repeated group, 1 for a byte count, 2 for a varint
// count. Rows are deduplicated by KIND SEQUENCE, not by Layout value: field
// names drive `readOperands` only and cannot affect a skip, so layouts that
// differ only in names (write_texture and the buffer↔texture copy, say) share
// one row. The walker below is the old per-layout skipper over these bytes.

/// Sentinel in the opcode→row map: reserved/unknown opcode, skip nothing.
const SKIP_NO_ROW: u8 = 0xff;

/// Bytes of row header before the field kind codes.
const SKIP_HEADER_LEN: usize = 5;

/// Kind codes as stored in the descriptor stream; indexes `skipKindCode`.
const SKIP_KIND_VARINT: u8 = 0;
const SKIP_KIND_BYTE: u8 = 1;
const SKIP_KIND_U32_LE: u8 = 2;
const SKIP_KIND_WASM_ARG: u8 = 3;

/// Upper bound on distinct kind sequences. Checked at comptime so the fixed
/// scratch array below can never be overrun.
const MAX_SKIP_LAYOUTS = 64;

/// True when two layouts skip identically: same head kinds, same rep shape and
/// element kinds, same tail kinds. Names are deliberately ignored.
fn layoutSkipEql(a: Layout, b: Layout) bool {
    if (a.head.len != b.head.len) return false;
    for (a.head, b.head) |x, y| if (x.kind != y.kind) return false;
    if ((a.rep == null) != (b.rep == null)) return false;
    if (a.rep) |ra| {
        const rb = b.rep.?;
        if (ra.count != rb.count or ra.max != rb.max or ra.elem.len != rb.elem.len) return false;
        for (ra.elem, rb.elem) |x, y| if (x.kind != y.kind) return false;
    }
    if (a.tail.len != b.tail.len) return false;
    for (a.tail, b.tail) |x, y| if (x.kind != y.kind) return false;
    return true;
}

/// The distinct layouts, in first-seen opcode order. Built by the same scan
/// that `buildSkipLayouts` repeats; both must see the same sequence.
const skip_layout_count: u8 = blk: {
    @setEvalBranchQuota(100_000);
    var seen: [MAX_SKIP_LAYOUTS]Layout = undefined;
    var n: u8 = 0;
    for (@typeInfo(OpCode).@"enum".fields) |f| {
        if (f.value >= 256) @compileError("wire_schema: opcode value does not fit the [256]u8 skip map");
        const layout = layoutOf(@enumFromInt(f.value));
        var found = false;
        for (seen[0..n]) |s| {
            if (layoutSkipEql(s, layout)) {
                found = true;
                break;
            }
        }
        if (!found) {
            if (n == MAX_SKIP_LAYOUTS) @compileError("wire_schema: more distinct skip layouts than MAX_SKIP_LAYOUTS");
            seen[n] = layout;
            n += 1;
        }
    }
    break :blk n;
};

/// The distinct layouts again, as a dense array.
fn buildSkipLayouts(comptime n: u8) [n]Layout {
    @setEvalBranchQuota(200_000);
    var seen: [MAX_SKIP_LAYOUTS]Layout = undefined;
    var out: [n]Layout = undefined;
    var count: u8 = 0;
    for (@typeInfo(OpCode).@"enum".fields) |f| {
        const layout = layoutOf(@enumFromInt(f.value));
        var found = false;
        for (seen[0..count]) |s| {
            if (layoutSkipEql(s, layout)) {
                found = true;
                break;
            }
        }
        if (!found) {
            seen[count] = layout;
            out[count] = layout;
            count += 1;
        }
    }
    if (count != n) @compileError("wire_schema: skip-layout scans disagree");
    return out;
}

const skip_layouts = buildSkipLayouts(skip_layout_count);

/// Bytes in the flat descriptor stream (the header + kinds of every row).
const skip_desc_total: u16 = blk: {
    @setEvalBranchQuota(100_000);
    var total: u16 = 0;
    for (skip_layouts) |layout| {
        total += SKIP_HEADER_LEN + @as(u16, @intCast(layout.head.len)) +
            (if (layout.rep) |rep| @as(u16, @intCast(rep.elem.len)) else 0) +
            @as(u16, @intCast(layout.tail.len));
    }
    break :blk total;
};

/// The packed descriptor stream plus each row's start offset. The opcode→row
/// map is a separate top-level const below: keeping large arrays out of one
/// comptime-built struct stops the compiler materializing them twice.
const SkipDescriptors = struct {
    bytes: [skip_desc_total]u8,
    starts: [skip_layout_count]u16,
};

/// Encode `kind` as its descriptor byte.
fn skipKindCode(kind: Kind) u8 {
    return switch (kind) {
        .varint => SKIP_KIND_VARINT,
        .byte => SKIP_KIND_BYTE,
        .u32_le => SKIP_KIND_U32_LE,
        .wasm_arg => SKIP_KIND_WASM_ARG,
    };
}

fn buildSkipDescriptors(comptime n: u8) SkipDescriptors {
    @setEvalBranchQuota(200_000);
    var bytes: [skip_desc_total]u8 = undefined;
    var starts: [n]u16 = undefined;
    var len: u16 = 0;
    for (skip_layouts, 0..) |layout, row| {
        starts[row] = len;
        const rep_kind: u8 = if (layout.rep) |rep| switch (rep.count) {
            .byte => 1,
            .varint => 2,
        } else 0;
        const rep_max: u8 = if (layout.rep) |rep| @intCast(rep.max) else 0;
        const rep_elem_len: u8 = if (layout.rep) |rep| @intCast(rep.elem.len) else 0;
        bytes[len] = @intCast(layout.head.len);
        bytes[len + 1] = rep_kind;
        bytes[len + 2] = rep_max;
        bytes[len + 3] = rep_elem_len;
        bytes[len + 4] = @intCast(layout.tail.len);
        len += SKIP_HEADER_LEN;
        for (layout.head) |field| {
            bytes[len] = skipKindCode(field.kind);
            len += 1;
        }
        if (layout.rep) |rep| for (rep.elem) |field| {
            bytes[len] = skipKindCode(field.kind);
            len += 1;
        };
        for (layout.tail) |field| {
            bytes[len] = skipKindCode(field.kind);
            len += 1;
        }
    }
    return .{ .bytes = bytes, .starts = starts };
}

const skip_descriptors = buildSkipDescriptors(skip_layout_count);

/// Opcode byte → row index, or `SKIP_NO_ROW` for reserved/unknown opcodes.
/// Every named opcode must find its row; a miss would silently skip nothing.
const skip_op_row: [256]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var map = [_]u8{SKIP_NO_ROW} ** 256;
    for (@typeInfo(OpCode).@"enum".fields) |f| {
        const layout = layoutOf(@enumFromInt(f.value));
        var found = false;
        for (skip_layouts, 0..) |candidate, row| {
            if (layoutSkipEql(candidate, layout)) {
                map[f.value] = @intCast(row);
                found = true;
                break;
            }
        }
        if (!found) @compileError("wire_schema: opcode ." ++ f.name ++ " has no skip row");
    }
    break :blk map;
};

comptime {
    // The map's sentinel must be unreachable as a row index.
    if (skip_layout_count >= SKIP_NO_ROW) @compileError("wire_schema: skip row index collides with SKIP_NO_ROW");
}

/// Advance `pc` past the operands of `op` in `bytecode`, returning the new pc.
/// Clamped to `bytecode.len`; unknown/reserved opcodes advance nothing.
pub fn skipParams(bytecode: []const u8, pc: u32, op: OpCode) u32 {
    // Pre-condition: pc is at or before an operand region.
    assert(pc <= bytecode.len);

    const row = skip_op_row[@intFromEnum(op)];
    if (row == SKIP_NO_ROW) return pc; // reserved / unknown opcode — skip nothing
    const start: usize = skip_descriptors.starts[row];
    return skipLayoutDesc(skip_descriptors.bytes[start..], bytecode, pc);
}

/// Skip one instruction's operands by walking its packed descriptor row.
fn skipLayoutDesc(desc: []const u8, bytecode: []const u8, pc_in: u32) u32 {
    var pc = pc_in;
    var i: usize = SKIP_HEADER_LEN;
    var k: usize = 0;
    while (k < desc[0]) : (k += 1) {
        pc = skipKindCodeAt(desc[i], bytecode, pc);
        i += 1;
    }

    const rep_kind = desc[1];
    const rep_max: u32 = desc[2];
    const rep_elem_len: usize = desc[3];
    if (rep_kind != 0) {
        var count: u32 = 0;
        switch (rep_kind) {
            1 => if (pc < bytecode.len) {
                count = bytecode[pc];
                pc += 1;
            },
            // The length-tolerant decoder, like `skipKindCodeAt` below: a
            // truncated count clamps (pc unchanged, count 0) instead of
            // asserting in Debug and over-reading 1–3 bytes in the stripped
            // ReleaseSmall executor — this skipper runs in every shipped binary.
            2 => if (pc < bytecode.len) {
                const r = opcodes.decode_varint_safe(bytecode[pc..]);
                count = r.value;
                pc += r.len;
            },
            else => unreachable, // comptime-built table: only 0/1/2 exist
        }
        const elem_start = i;
        var rep: u32 = 0;
        while (rep < @min(count, rep_max)) : (rep += 1) {
            k = 0;
            while (k < rep_elem_len) : (k += 1) {
                pc = skipKindCodeAt(desc[elem_start + k], bytecode, pc);
            }
        }
        i += rep_elem_len;
    }

    k = 0;
    while (k < desc[4]) : (k += 1) {
        pc = skipKindCodeAt(desc[i], bytecode, pc);
        i += 1;
    }
    return pc;
}

/// Advance past one operand field named by a packed kind code, clamped to the
/// buffer end.
fn skipKindCodeAt(code: u8, bytecode: []const u8, pc: u32) u32 {
    if (pc >= bytecode.len) return pc;
    return switch (code) {
        // decode_varint_safe returns len 0 on a truncated varint (the encoding
        // runs past bytecode.len) instead of asserting — so a hostile mid-varint
        // truncation clamps here (pc unchanged; the caller's bounded scan loop
        // terminates) rather than panicking in Debug / OOB-reading in the stripped
        // ReleaseSmall build, honoring this function's clamp-to-buffer-end
        // contract. Byte-identical to decode_varint for well-formed input, so the
        // scanner and skip parity are unchanged. (Arc-3 §5.4)
        SKIP_KIND_VARINT => pc + @as(u32, opcodes.decode_varint_safe(bytecode[pc..]).len),
        SKIP_KIND_BYTE => pc + 1,
        SKIP_KIND_U32_LE => clampEnd(pc + 4, bytecode.len),
        SKIP_KIND_WASM_ARG => clampEnd(pc + 1 + @as(u32, @as(WasmArgType, @enumFromInt(bytecode[pc])).valueByteSize()), bytecode.len),
        else => unreachable, // comptime-built table: only the four codes exist
    };
}

/// Clamp a would-be end position to the buffer length.
fn clampEnd(np: u32, len: usize) u32 {
    return if (np <= len) np else @intCast(len);
}

// ============================================================================
// Decode — read an instruction's operands into a typed struct
// ============================================================================

/// The Zig type a `Kind` decodes into. Rep-group encodings (`wasm_arg`) have no
/// scalar decode type; `readOperands` rejects them (rep groups decode manually).
fn KindType(comptime kind: Kind) type {
    return switch (kind) {
        .varint, .u32_le => u32,
        .byte => u8,
        .wasm_arg => @compileError("wire_schema: wasm_arg has no scalar decode type (call_wasm_func decodes manually)"),
    };
}

/// The typed operands struct for a FIXED-shape layout: one field per head entry,
/// named by the layout. Fails the build for count-prefixed layouts — those
/// opcodes decode manually (see the module doc). Folds by Layout value, so two
/// opcodes sharing a layout share one struct type.
pub fn Operands(comptime layout: Layout) type {
    if (layout.rep != null) @compileError("wire_schema.Operands: rep-group layout decodes manually, not via readOperands");
    comptime var names: [layout.head.len][]const u8 = undefined;
    comptime var types: [layout.head.len]type = undefined;
    comptime var attrs: [layout.head.len]std.builtin.Type.StructField.Attributes = undefined;
    inline for (layout.head, 0..) |field, i| {
        names[i] = field.name;
        types[i] = KindType(field.kind);
        attrs[i] = .{};
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

/// Decode a fixed-shape instruction's operands from `reader` into `Operands(layout)`.
/// `reader` is duck-typed: it must expose `read_varint() !u32`, `read_byte() !u8`
/// and `read_raw_u32() !u32` (the dispatcher `Self`). Reads fields in wire order,
/// identical to the hand-written handler sequence it replaces, so golden traces
/// stay byte-identical.
pub fn readOperands(comptime layout: Layout, reader: anytype) !Operands(layout) {
    var out: Operands(layout) = undefined;
    inline for (layout.head) |field| {
        @field(out, field.name) = switch (field.kind) {
            .varint => try reader.read_varint(),
            .byte => try reader.read_byte(),
            .u32_le => try reader.read_raw_u32(),
            .wasm_arg => @compileError("wire_schema.readOperands: wasm_arg decodes manually"),
        };
    }
    return out;
}

/// Narrow a decoded u32 operand to a resource/pass id (u16). `readOperands`
/// widens every varint field to u32, but the resource/pass tables are
/// u16-indexed and the emitter never emits an id past u16 — so a larger value
/// is a hostile or corrupt stream. Error instead of letting the handler's
/// `@intCast` panic (Debug/ReleaseSafe — the native dispatcher's default) or
/// silently wrap (ReleaseFast tooling). (Arc-3 §2.2c)
pub fn narrowU16(v: u32) error{InvalidResourceId}!u16 {
    if (v > std.math.maxInt(u16)) return error.InvalidResourceId;
    return @intCast(v);
}

/// Narrow a decoded operand to an id a `max`-sized backend table can hold.
///
/// `narrowU16` answers "does this fit the wire type?"; this answers "does this
/// fit the table?" — a strictly narrower question, and the one that matters for
/// memory safety. `buffer_id = 65535` passes `narrowU16` cleanly and then
/// indexes 65279 slots past a 256-entry array.
///
/// Deliberately NOT called from the shared dispatcher: backends size their
/// tables differently (MockGPU caps pipelines at 64, the native backend splits
/// render/compute at 64 each), so a single shared cap would either be wrong for
/// one of them or move the frozen golden traces. Each backend enforces its own
/// caps at the point of use; this is for callers that know the table they are
/// about to index — the native C ABI entry points above all.
pub fn narrowResourceId(v: u32, max: u16) error{InvalidResourceId}!u16 {
    if (v >= max) return error.InvalidResourceId;
    return @intCast(v);
}

// ============================================================================
// WASM args blob validation (used by emitter.callWasmFunc asserts)
// ============================================================================

/// Bytes consumed by a pre-encoded call_wasm_func args blob:
/// `[count:u8]( [type:u8][value:0-4] )*`. Returns null if truncated.
/// Pre-condition (debug): every type byte is a valid WasmArgType.
pub fn wasmArgsBlobLen(blob: []const u8) ?usize {
    if (blob.len == 0) return null;
    const count = blob[0];
    var pos: usize = 1;
    for (0..count) |_| {
        if (pos >= blob.len) return null;
        const arg_type: WasmArgType = @enumFromInt(blob[pos]);
        pos += 1 + arg_type.valueByteSize();
    }
    return if (pos <= blob.len) pos else null;
}
