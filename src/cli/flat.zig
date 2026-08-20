//! Flatten PNGB bytecode into a flat command buffer (pNGf format).
//!
//! Runs the dispatcher at compile time against MockGPU backend to capture
//! all GPU calls, then serializes them as flat command buffers with an
//! inline data section. The result can be embedded in a PNG as a pNGf chunk,
//! eliminating the need for WASM executor at runtime.
//!
//! ## pNGf Format
//!
//! ```
//! [version: u8]       = 2
//! [flags: u8]         bit 0: premultiplied canvas (mirrors PNGB canvas_alpha_premultiplied)
//! [init_len: u32 LE]  Length of init commands
//! [frame_len: u32 LE] Length of frame commands
//! [data_len: u32 LE]  Length of data section
//! [init_cmds: bytes]  Resource creation commands (opcode + args, no header)
//! [frame_cmds: bytes] Per-frame commands (opcode + args, no header)
//! [data: bytes]       WGSL strings, JSON descriptors, bind group entries
//! ```
//!
//! ## Limitations
//!
//! - No ping-pong buffers (frame template is static)
//! - No animation timeline / frame switching
//! - No WASM-in-WASM plugins
//! - Only write_time_uniform and write_pointer_uniform as dynamic data sources
//! - Single frame definition only
//!
//! ## Invariants
//!
//! - All data pointers in output reference the data section by offset
//! - Init commands include resource creation; frame commands include passes

const std = @import("std");
const pngine = @import("pngine");
const format = pngine.format;
const mock_gpu = pngine.mock_gpu;
const MockGPU = mock_gpu.MockGPU;
const Call = mock_gpu.Call;
const CallType = mock_gpu.CallType;
const Dispatcher = pngine.Dispatcher;
const Cmd = pngine.command_buffer.Cmd;
const call_split = @import("call_split.zig");

// 2 since spec/09 step D: begin_render_pass became 0x53 with an f32 clear
// value, so a v1 payload's 0x10 is not a command this format's reader knows any
// more. mini.js refuses a version it does not recognise rather than walking a
// stream whose first pass command it would misparse.
const PNGF_VERSION: u8 = 2;
const PNGF_HEADER_SIZE: usize = 14;

pub const FlattenError = error{
    InvalidBytecode,
    ExecutionFailed,
    /// A captured GPU call maps to a command the mini (pNGf) runtime cannot
    /// decode. Emitting it would desync mini's opcode stream (it has no
    /// per-opcode length table), so we refuse the export rather than ship a
    /// silently-broken pNGf. The offending command is reported via `Diag`.
    UnsupportedByMini,
    OutOfMemory,
};

/// Filled by `flattenPayload` only when it returns `error.UnsupportedByMini`:
/// names the command the mini runtime can't play, for the CLI diagnostic.
///
/// Deliberately NOT `dsl_sjon/diag.zig`'s `Diag`, despite the shared name: that
/// one is a located, severity-tagged, JSON-serializable sink for *author* errors
/// in the source document. This is an out-param naming one export-time capability
/// gap in an already-valid document — no location (the call log has no spans), no
/// severity (there is exactly one, fatal), no JSON channel. Sharing the type would
/// mean carrying a 16 KB arena and a 64-entry table to report a single enum.
pub const Diag = struct {
    unsupported: ?CallType = null,
    /// A non-command feature the mini runtime can't support (authored device
    /// limits, §5.3b) — named directly since it isn't a CallType. render.zig's
    /// refusal printer prefers this over `unsupported` when set.
    unsupported_feature: ?[]const u8 = null,
};

pub const FlatPayload = struct {
    data: []u8,

    pub fn deinit(self: *FlatPayload, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// The three sinks every serializer threads through: the growing data section,
/// the id→offset memo over it, and the module the ids index into. Bundled so
/// the per-family emitters take one context rather than repeating four
/// parameters that always travel together.
const Ctx = struct {
    data_section: *std.ArrayList(u8),
    data_map: *std.AutoHashMapUnmanaged(u16, u32),
    module: *const format.Module,
};

/// Flatten PNGB bytecode into pNGf format.
///
/// Runs the dispatcher with MockGPU to capture all GPU calls, then
/// serializes them as command buffers with inline data.
pub fn flattenPayload(allocator: std.mem.Allocator, bytecode: []const u8, diag: ?*Diag) FlattenError!FlatPayload {
    if (bytecode.len < format.HEADER_SIZE or !std.mem.eql(u8, bytecode[0..4], format.MAGIC)) {
        return FlattenError.InvalidBytecode;
    }

    var module = format.deserialize(allocator, bytecode) catch {
        return FlattenError.InvalidBytecode;
    };
    defer module.deinit(allocator);

    // Authored device limits (Arc-3 §5.3b) can't be requested by the mini
    // runtime (it does a bare requestDevice, and Decision 2 keeps mini tiny) —
    // refuse the pNGf export loudly rather than ship a player that silently
    // ignores the required limits.
    if (module.limits.count() > 0) {
        if (diag) |d| d.unsupported_feature = "device requiredLimits";
        return FlattenError.UnsupportedByMini;
    }

    // Execute bytecode with MockGPU to capture call sequence
    var gpu: MockGPU = .empty;
    defer gpu.deinit(allocator);

    var dispatcher = Dispatcher(MockGPU).init(allocator, &gpu, &module);
    defer dispatcher.deinit();
    dispatcher.execute_all(allocator) catch {
        return FlattenError.ExecutionFailed;
    };

    const calls = gpu.get_calls();
    const split_idx = try splitInitFromFrame(calls, diag);
    std.debug.assert(split_idx <= calls.len);

    var data_section = std.ArrayList(u8).empty;
    defer data_section.deinit(allocator);

    var init_cmds = std.ArrayList(u8).empty;
    defer init_cmds.deinit(allocator);

    var frame_cmds = std.ArrayList(u8).empty;
    defer frame_cmds.deinit(allocator);

    // Map from data_id to data section offset
    var data_map = std.AutoHashMapUnmanaged(u16, u32){};
    defer data_map.deinit(allocator);

    const ctx = Ctx{ .data_section = &data_section, .data_map = &data_map, .module = &module };

    try serializeRange(allocator, &init_cmds, ctx, calls[0..split_idx], diag);
    try injectUniformWrites(allocator, &frame_cmds, &module);
    try serializeRange(allocator, &frame_cmds, ctx, calls[split_idx..], diag);

    const output = try packPayload(
        allocator,
        module.header.flags.canvas_alpha_premultiplied,
        init_cmds.items,
        frame_cmds.items,
        data_section.items,
    );
    return FlatPayload{ .data = output };
}

/// Index of the first per-frame call: the pNGf init section is everything up to
/// the first PASS command, and the frame section is that command onwards.
///
/// Defined by what STARTS the frame rather than by what ends the prologue. The
/// negative spelling ("run while the call is a create") looks equivalent and is
/// not: `:data` captures create_buffer, **write_buffer**, and only
/// then the shader module and pipeline, so a single write in the middle of an
/// ordinary prologue put every later create in the per-frame range — a create
/// mini replays at 60Hz. It has never shipped only because write_buffer is
/// itself refused (`serializeCall`); the coincidence is not the invariant.
///
/// The list below is exactly `serializePassCall`'s. It does not need to name
/// every pass command in existence — a command absent from both emitters is
/// refused before the split can matter — but it must name every one the writer
/// can actually emit.
///
/// A create at or after the split is REFUSED, not split around. The frame
/// section is replayed every frame, and mini's create arms are idempotent
/// (pitfall 35 rule 1) only as of §349 — an older player mints a fresh GPU
/// object per frame and repoints its id table away from whatever the bind groups
/// already hold. Even guarded, a per-frame create means the writer decided a
/// resource's parameters can change between frames, which a static frame
/// template cannot express. Unreachable from any compiled document today
/// (`emitFrame` cannot emit a `create_*`), but this writer runs on arbitrary
/// PNGB, including hand-built and corrupt input (the r1-03 lesson).
///
/// Post-condition: the result is a valid split point into `calls`, and no create
/// call appears at or after it.
pub fn splitInitFromFrame(calls: []const Call, diag: ?*Diag) FlattenError!usize {
    // The refusal is SHARED with the `--html` writer (call_split.zig): both
    // consume this call log, and a log that breaks the invariant made them fail
    // in opposite directions with nothing gating either.
    if (call_split.createAtOrAfterFrameStart(calls)) |i| {
        if (diag) |d| {
            d.unsupported = calls[i].call_type;
            d.unsupported_feature = "a resource created after the frame's first pass command";
        }
        return FlattenError.UnsupportedByMini;
    }

    const split_idx = call_split.firstFrameCall(calls);
    std.debug.assert(split_idx <= calls.len);
    return split_idx;
}

/// Serialize one contiguous run of captured calls, naming the first command the
/// mini runtime can't play in `diag` before propagating the refusal.
fn serializeRange(
    allocator: std.mem.Allocator,
    cmds: *std.ArrayList(u8),
    ctx: Ctx,
    calls: []const Call,
    diag: ?*Diag,
) FlattenError!void {
    std.debug.assert(ctx.data_section.items.len <= std.math.maxInt(u32));
    for (calls) |call| {
        serializeCall(allocator, cmds, ctx, call) catch |err| {
            if (err == error.UnsupportedByMini) if (diag) |d| {
                d.unsupported = call.call_type;
                d.unsupported_feature = featureNameFor(call.call_type);
            };
            return err;
        };
    }
    std.debug.assert(ctx.data_section.items.len <= std.math.maxInt(u32));
}

/// What the *author* wrote, for refusals whose opcode name would send them
/// looking for something they never typed. Null keeps the opcode tag, which is
/// the right answer whenever the source form and the command share a name.
fn featureNameFor(call_type: CallType) ?[]const u8 {
    return switch (call_type) {
        // Nobody writes `write_buffer`: they write `:data` or
        // `(write-buffer :data …)`, and both mean "this buffer starts with
        // these bytes" — which pNGf's create_buffer (id, size, usage) has
        // nowhere to put.
        .write_buffer => "initial buffer contents (:data / (write-buffer :data …))",
        // The only way a create_bind_group reaches the refusal is an explicit
        // layout — `(bind-group … :layout <pipeline> …)` serializes fine. Naming the
        // form beats naming the opcode, which the author never typed.
        .create_bind_group => "an explicit (bind-group-layout …) as a bind group's :layout",
        else => null,
    };
}

/// Upper bound on the bytecode walk below. Every iteration consumes at least
/// the opcode byte, so this can only be hit by a stream longer than the 1 MB
/// `scan_pass_definitions` already asserts.
const MAX_BYTECODE_WALK: u32 = 1 << 20;

/// Prepend the per-frame runtime-uniform writes to `cmds`.
///
/// `write_time_uniform` (PNGB 0x2A) and `write_pointer_uniform` (0x2B) stream
/// time/canvas/pointer data into a buffer; MockGPU has no buffer contents to
/// mutate, so it records them outside the call log and they never reach
/// `serializeCall`. Recover them from the bytecode.
///
/// The walk is the whole point. This used to scan raw bytes for 0x2A/0x2B with
/// no notion of where an instruction starts, so any OPERAND byte holding those
/// values fabricated a record: `:size 42` is the varint 0x2A, and so are ids,
/// offsets and lengths. The phantom's own operands were whatever bytes followed
/// it, so it either threw inside mini's per-frame try/catch — killing a valid
/// document at first frame — or, with a live buffer id, overwrote that buffer
/// with [time, w, h, aspect] sixty times a second. Stepping instruction by
/// instruction through `wire_schema.skipParams` (the single source of truth the
/// emitter and both dispatchers follow) is what makes 0x2A mean the opcode.
fn injectUniformWrites(
    allocator: std.mem.Allocator,
    cmds: *std.ArrayList(u8),
    module: *const format.Module,
) !void {
    std.debug.assert(cmds.items.len == 0); // injected before any frame command
    const bc = module.bytecode;
    var pc: u32 = 0;
    for (0..MAX_BYTECODE_WALK) |_| {
        if (pc >= bc.len) break;
        const op: pngine.opcodes.OpCode = @enumFromInt(bc[pc]);
        const operands = pc + 1;
        // `skipParams` never advances past `bc.len`, and never below `operands`
        // — so the walk consumes at least the opcode byte per iteration and
        // cannot spin, even on a reserved opcode (which skips nothing).
        pc = pngine.wire_schema.skipParams(bc, operands, op);
        std.debug.assert(pc >= operands and pc <= bc.len);
        if (op != .write_time_uniform and op != .write_pointer_uniform) continue;

        const cmd: Cmd = if (op == .write_time_uniform) .write_time_uniform else .write_pointer_uniform;
        const r1 = decodeVarint(bc[operands..]);
        const r2 = decodeVarint(bc[operands + r1.len ..]);
        const r3 = decodeVarint(bc[operands + r1.len + r2.len ..]);
        // A truncated stream: the opcode is real but its operands are not there.
        if (r1.len == 0 or r2.len == 0 or r3.len == 0) return FlattenError.InvalidBytecode;
        // The emitter writes these as u16/u32/u16, so a wider value means the
        // bytecode was not built by it. Re-checked rather than @intCast'd —
        // arbitrary PNGB reaches this writer, and a panic is not a diagnostic.
        if (r1.value > std.math.maxInt(u16) or r3.value > std.math.maxInt(u16)) {
            return FlattenError.InvalidBytecode;
        }
        try cmds.append(allocator, @intFromEnum(cmd));
        try appendU16(allocator, cmds, @intCast(r1.value));
        try appendU32(allocator, cmds, r2.value);
        try appendU16(allocator, cmds, @intCast(r3.value));
    }
    std.debug.assert(cmds.items.len % 9 == 0); // whole 1+2+4+2 records only
}

/// Build the finished pNGf image: fixed header, then the three sections in
/// wire order. Caller owns the returned buffer.
fn packPayload(
    allocator: std.mem.Allocator,
    premultiplied_canvas: bool,
    init_cmds: []const u8,
    frame_cmds: []const u8,
    data: []const u8,
) FlattenError![]u8 {
    const total = PNGF_HEADER_SIZE + init_cmds.len + frame_cmds.len + data.len;
    std.debug.assert(total >= PNGF_HEADER_SIZE);
    const output = allocator.alloc(u8, total) catch return FlattenError.OutOfMemory;
    errdefer allocator.free(output);

    // Header. Flags bit 0 mirrors the PNGB header's canvas_alpha_premultiplied
    // (bit 3): the mini runtime configures the canvas premultiplied when set,
    // and opaque (the GPUCanvasConfiguration default) when clear.
    // (spec/04, spec/09 D)
    output[0] = PNGF_VERSION;
    output[1] = if (premultiplied_canvas) 1 else 0;
    std.mem.writeInt(u32, output[2..6], @intCast(init_cmds.len), .little);
    std.mem.writeInt(u32, output[6..10], @intCast(frame_cmds.len), .little);
    std.mem.writeInt(u32, output[10..14], @intCast(data.len), .little);

    var pos: usize = PNGF_HEADER_SIZE;
    @memcpy(output[pos..][0..init_cmds.len], init_cmds);
    pos += init_cmds.len;
    @memcpy(output[pos..][0..frame_cmds.len], frame_cmds);
    pos += frame_cmds.len;
    @memcpy(output[pos..][0..data.len], data);

    std.debug.assert(pos + data.len == total);
    return output;
}

/// Resolve a data_id to its offset in the data section, adding it if needed.
fn resolveData(allocator: std.mem.Allocator, ctx: Ctx, data_id: u16) !u32 {
    std.debug.assert(ctx.data_section.items.len <= std.math.maxInt(u32));
    if (ctx.data_map.get(data_id)) |offset| return offset;

    const data = ctx.module.data.get(@enumFromInt(data_id));
    const offset: u32 = @intCast(ctx.data_section.items.len);
    try ctx.data_map.put(allocator, data_id, offset);
    try ctx.data_section.appendSlice(allocator, data);
    std.debug.assert(ctx.data_section.items.len >= offset);
    return offset;
}

/// Upper bound on include-resolution work. Each iteration either marks one
/// module included or re-pushes it behind its unmet deps, so a well-formed
/// table converges in O(modules + edges); exhausting the bound means the deps
/// form a cycle, which the concatenation cannot express.
const MAX_WGSL_WALK: u32 = 1024;

/// The WGSL-table index `id` refers to, or null when it names data directly.
///
/// Callers pass either a wgsl-table index or a raw data-section id (the two id
/// spaces overlap), so an id absent from the table is re-tried as the `data_id`
/// of some entry before giving up.
fn wgslEntryFor(module: *const format.Module, id: u16) ?u16 {
    if (module.wgsl.get(id) != null) return id;
    for (0..module.wgsl.count()) |i| {
        const entry = module.wgsl.get(@intCast(i)) orelse continue;
        if (entry.data_id == id) return @intCast(i);
    }
    return null;
}

/// Fill `order` with `root` and its transitive deps, dependencies first.
///
/// Iterative (mastery rule 1: no recursion) — a node with unmet deps is pushed
/// back under them, so it is only appended once everything it needs is in.
fn collectIncludeOrder(
    allocator: std.mem.Allocator,
    module: *const format.Module,
    root: u16,
    order: *std.ArrayList(u16),
) !void {
    std.debug.assert(order.items.len == 0);

    var included = std.AutoHashMapUnmanaged(u16, void){};
    defer included.deinit(allocator);
    var stack = std.ArrayList(u16).empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, root);

    for (0..MAX_WGSL_WALK) |_| {
        if (stack.items.len == 0) break;
        const current = stack.pop() orelse break;
        if (included.contains(current)) continue;

        const entry = module.wgsl.get(current) orelse continue;

        var all_deps_ready = true;
        for (entry.deps) |dep| {
            if (!included.contains(dep)) {
                all_deps_ready = false;
                break;
            }
        }

        if (all_deps_ready) {
            try included.put(allocator, current, {});
            try order.append(allocator, current);
        } else {
            try stack.append(allocator, current);
            for (entry.deps) |dep| {
                if (!included.contains(dep)) try stack.append(allocator, dep);
            }
        }
    }

    // Draining the stack is the termination condition. Stopping on the bound
    // instead would emit a *shorter* shader — a silent truncation the compiler
    // would then hand to the GPU as if complete.
    if (stack.items.len != 0) return FlattenError.InvalidBytecode;
    std.debug.assert(order.items.len <= module.wgsl.count());
}

/// Resolve WGSL data (with imports) to its offset in the data section.
/// Uses two map keys per WGSL: offset at (wgsl_id | 0x8000), length at (wgsl_id | 0xC000).
fn resolveWgsl(allocator: std.mem.Allocator, ctx: Ctx, wgsl_id: u16) !struct { offset: u32, len: u32 } {
    std.debug.assert(ctx.data_section.items.len <= std.math.maxInt(u32));

    const offset_key: u16 = wgsl_id | 0x8000;
    const len_key: u16 = wgsl_id | 0xC000;
    if (ctx.data_map.get(offset_key)) |offset| {
        return .{ .offset = offset, .len = ctx.data_map.get(len_key) orelse 0 };
    }

    const root = wgslEntryFor(ctx.module, wgsl_id) orelse {
        // Not a WGSL module at all: the id names data-section bytes directly,
        // which have no imports to splice.
        const data = ctx.module.data.get(@enumFromInt(wgsl_id));
        const offset: u32 = @intCast(ctx.data_section.items.len);
        try ctx.data_section.appendSlice(allocator, data);
        try ctx.data_map.put(allocator, offset_key, offset);
        try ctx.data_map.put(allocator, len_key, @intCast(data.len));
        return .{ .offset = offset, .len = @intCast(data.len) };
    };

    var order = std.ArrayList(u16).empty;
    defer order.deinit(allocator);
    try collectIncludeOrder(allocator, ctx.module, root, &order);

    const offset: u32 = @intCast(ctx.data_section.items.len);
    for (order.items) |id| {
        const entry = ctx.module.wgsl.get(id) orelse continue;
        try ctx.data_section.appendSlice(allocator, ctx.module.data.get(@enumFromInt(entry.data_id)));
    }
    const total_size: u32 = @intCast(ctx.data_section.items.len - offset);

    try ctx.data_map.put(allocator, offset_key, offset);
    try ctx.data_map.put(allocator, len_key, total_size);
    return .{ .offset = offset, .len = total_size };
}

/// Serialize a MockGPU call to command buffer format.
///
/// A router, not a worker: it names which family owns each captured call and
/// which calls have no pNGf spelling at all. The per-family emitters below hold
/// the wire layouts.
fn serializeCall(
    allocator: std.mem.Allocator,
    cmds: *std.ArrayList(u8),
    ctx: Ctx,
    call: Call,
) !void {
    const before = cmds.items.len;
    switch (call.call_type) {
        .create_buffer,
        .create_shader_module,
        .create_render_pipeline,
        .create_compute_pipeline,
        .create_bind_group,
        => try serializeResourceCall(allocator, cmds, ctx, call),

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
        => try serializePassCall(allocator, cmds, call),

        // Every command the mini (pNGf) runtime cannot decode. Emitting any of
        // these would either desync mini's opcode stream (create_texture/sampler/
        // texture_view/set_index_buffer — the four it has no `case` for) or drop
        // functionality silently (MRT, copies, indirects, queries, viewport/
        // scissor, wasm, bundles). Refuse the whole export so a broken-but-silent
        // pNGf can't exist; the caller reports the offending command (Diag).
        // (Decision 2: refuse at write, keep mini tiny — do NOT extend mini here.)
        //
        // `write_buffer` is here for a sharper reason than the rest: mini's only
        // buffer write is `write_time_uniform` (case 33), which writes the four
        // pngineInputs floats at offset 0 and ignores both the offset and length
        // operands. This arm used to emit exactly that for every write_buffer —
        // so an authored `(write-buffer :data …)` of static bytes silently became
        // time/canvas data landing on top of them. It fired on real programs
        // (boids' two simParams blocks, 24 B and 28 B), and every time it fired
        // it was wrong. The runtime-inputs writes are a *different* PNGB opcode
        // (0x2A/0x2B) that never reaches this switch — `injectUniformWrites`
        // recovers those.
        .write_buffer,
        .create_texture,
        .create_sampler,
        .create_texture_view,
        .set_index_buffer,
        .begin_render_pass_mrt,
        .copy_buffer_to_buffer,
        .copy_texture_to_texture,
        .write_uniform,
        .create_query_set,
        .create_bind_group_layout,
        .create_pipeline_layout,
        .create_image_bitmap,
        .create_render_bundle,
        .execute_bundles,
        .copy_external_image_to_texture,
        .init_wasm_module,
        .call_wasm_func,
        .write_buffer_from_wasm,
        .draw_indirect,
        .draw_indexed_indirect,
        .dispatch_indirect,
        .set_viewport,
        .set_stencil_reference,
        .set_scissor_rect,
        .set_blend_constant,
        .set_pass_occlusion_query_set,
        .set_pass_timestamp_writes,
        .set_pass_depth_stencil_ops,
        .set_pass_clear_values,
        .begin_occlusion_query,
        .end_occlusion_query,
        .resolve_query_set,
        => return error.UnsupportedByMini,
    }
    // A serialized call is at least its opcode byte: mini reads the stream
    // positionally, so an arm that emitted nothing would shift every command
    // after it.
    std.debug.assert(cmds.items.len > before);
}

/// Resource creation: the calls that place bytes in the data section and refer
/// to them by (offset, length).
fn serializeResourceCall(
    allocator: std.mem.Allocator,
    cmds: *std.ArrayList(u8),
    ctx: Ctx,
    call: Call,
) !void {
    std.debug.assert(ctx.data_section.items.len <= std.math.maxInt(u32));
    switch (call.call_type) {
        .create_buffer => {
            const p = call.params.create_buffer;
            try cmds.append(allocator, @intFromEnum(Cmd.create_buffer));
            try appendU16(allocator, cmds, p.buffer_id);
            try appendU32(allocator, cmds, p.size);
            try appendU16(allocator, cmds, p.usage);
        },
        .create_shader_module => {
            const p = call.params.create_shader_module;
            const wgsl = try resolveWgsl(allocator, ctx, p.code_data_id);
            try cmds.append(allocator, @intFromEnum(Cmd.create_shader));
            try appendU16(allocator, cmds, p.shader_id);
            try appendU32(allocator, cmds, wgsl.offset);
            try appendU32(allocator, cmds, wgsl.len);
        },
        // The (offset, length) pairs below are written out per arm rather than
        // funnelled through a shared helper on purpose: `mini-conformance.test.js`
        // derives each command's operand width by counting the appendU16/appendU32
        // calls *in the arm's own text* and pins it against mini.js's `p += N`.
        // Bytes emitted inside a callee are invisible to that scraper, so hiding
        // them would silently under-count the width and retire the pin.
        .create_render_pipeline => {
            const p = call.params.create_render_pipeline;
            const offset = try resolveData(allocator, ctx, p.descriptor_data_id);
            const data = ctx.module.data.get(@enumFromInt(p.descriptor_data_id));
            try cmds.append(allocator, @intFromEnum(Cmd.create_render_pipeline));
            try appendU16(allocator, cmds, p.pipeline_id);
            try appendU32(allocator, cmds, offset);
            try appendU32(allocator, cmds, @intCast(data.len));
        },
        .create_compute_pipeline => {
            const p = call.params.create_compute_pipeline;
            const offset = try resolveData(allocator, ctx, p.descriptor_data_id);
            const data = ctx.module.data.get(@enumFromInt(p.descriptor_data_id));
            try cmds.append(allocator, @intFromEnum(Cmd.create_compute_pipeline));
            try appendU16(allocator, cmds, p.pipeline_id);
            try appendU32(allocator, cmds, offset);
            try appendU32(allocator, cmds, @intCast(data.len));
        },
        .create_bind_group => {
            const p = call.params.create_bind_group;
            // mini resolves a bind group's layout as `(pp[pl]||cp[pl]).getBindGroupLayout(gi)`
            // — pipelines only. A tagged layout_id names a standalone
            // (bind-group-layout …), which mini has no table for, so serializing it
            // would silently bind whatever pipeline shares that number.
            //
            // UNREACHABLE from any compiled document today: a tagged id implies a
            // create_bind_group_layout, and that command is refused by the arm below,
            // which always comes first in the call log. It is here anyway for the two
            // cases that outlive that coincidence — a hand-built or corrupt PNGB (this
            // writer runs on arbitrary `.png` input, the r1-03 lesson), and the day
            // mini learns create_bind_group_layout, where the refusal above would
            // vanish and this one would be the only thing standing between a tagged id
            // and the wrong layout. Decision 2 / pitfall 58. §339.
            if (pngine.opcodes.layoutIdIsBindGroupLayout(p.layout_id)) return error.UnsupportedByMini;
            const offset = try resolveData(allocator, ctx, p.entry_data_id);
            const data = ctx.module.data.get(@enumFromInt(p.entry_data_id));
            try cmds.append(allocator, @intFromEnum(Cmd.create_bind_group));
            try appendU16(allocator, cmds, p.group_id);
            try appendU16(allocator, cmds, p.layout_id);
            try appendU32(allocator, cmds, offset);
            try appendU32(allocator, cmds, @intCast(data.len));
        },
        else => unreachable, // routed by serializeCall
    }
}

/// Pass and queue commands: everything that references resources by id only,
/// so none of them touch the data section.
fn serializePassCall(
    allocator: std.mem.Allocator,
    cmds: *std.ArrayList(u8),
    call: Call,
) !void {
    switch (call.call_type) {
        .begin_render_pass => {
            const p = call.params.begin_render_pass;
            try cmds.append(allocator, @intFromEnum(Cmd.begin_render_pass_f32));
            try appendU16(allocator, cmds, p.color_texture_id);
            try cmds.append(allocator, p.load_op);
            try cmds.append(allocator, p.store_op);
            try appendU16(allocator, cmds, p.depth_texture_id);
            try appendU32(allocator, cmds, p.clear_r_bits);
            try appendU32(allocator, cmds, p.clear_g_bits);
            try appendU32(allocator, cmds, p.clear_b_bits);
            try appendU32(allocator, cmds, p.clear_a_bits);
        },
        .begin_compute_pass => try cmds.append(allocator, @intFromEnum(Cmd.begin_compute_pass)),
        .end_pass => try cmds.append(allocator, @intFromEnum(Cmd.end_pass)),
        .submit => try cmds.append(allocator, @intFromEnum(Cmd.submit)),
        .set_pipeline => {
            const p = call.params.set_pipeline;
            try cmds.append(allocator, @intFromEnum(Cmd.set_pipeline));
            try appendU16(allocator, cmds, p.pipeline_id);
        },
        .set_bind_group => {
            const p = call.params.set_bind_group;
            try cmds.append(allocator, @intFromEnum(Cmd.set_bind_group));
            try cmds.append(allocator, p.slot);
            try appendU16(allocator, cmds, p.group_id);
        },
        .set_vertex_buffer => {
            const p = call.params.set_vertex_buffer;
            try cmds.append(allocator, @intFromEnum(Cmd.set_vertex_buffer));
            try cmds.append(allocator, p.slot);
            try appendU16(allocator, cmds, p.buffer_id);
        },
        .draw => {
            const p = call.params.draw;
            try cmds.append(allocator, @intFromEnum(Cmd.draw));
            try appendU32(allocator, cmds, p.vertex_count);
            try appendU32(allocator, cmds, p.instance_count);
            try appendU32(allocator, cmds, p.first_vertex);
            try appendU32(allocator, cmds, p.first_instance);
        },
        .draw_indexed => {
            const p = call.params.draw_indexed;
            try cmds.append(allocator, @intFromEnum(Cmd.draw_indexed));
            try appendU32(allocator, cmds, p.index_count);
            try appendU32(allocator, cmds, p.instance_count);
            try appendU32(allocator, cmds, p.first_index);
            try appendU32(allocator, cmds, p.base_vertex);
            try appendU32(allocator, cmds, p.first_instance);
        },
        .dispatch => {
            const p = call.params.dispatch;
            try cmds.append(allocator, @intFromEnum(Cmd.dispatch));
            try appendU32(allocator, cmds, p.x);
            try appendU32(allocator, cmds, p.y);
            try appendU32(allocator, cmds, p.z);
        },
        else => unreachable, // routed by serializeCall
    }
}

fn appendU16(allocator: std.mem.Allocator, list: *std.ArrayList(u8), value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, value, .little);
    try list.appendSlice(allocator, &buf);
}

fn appendU32(allocator: std.mem.Allocator, list: *std.ArrayList(u8), value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try list.appendSlice(allocator, &buf);
}

/// Length-tolerant varint decode over possibly-truncated bytecode.
/// Single-sourced with the canonical decoder (opcodes.decode_varint_safe).
const decodeVarint = pngine.opcodes.decode_varint_safe;
