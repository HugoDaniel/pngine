//! Generate the frame-controls fixtures (frame-program plan §7.1-§7.3, F3).
//!
//! Two payloads, built only from emitter primitives + `patchSkip` (never
//! hand-written bytes), both embedding the executor given on the command
//! line — the committed copies embed the executor of the commit that
//! regenerated them, so `tests/npm/frame-controls.test.js` pins shipping
//! behaviour, not a historical one:
//!
//!   guarded.pngb — one frame exercising the whole browser half: two declared
//!     controls (defaults 0.25, 2.0), a `write_controls`, a time guard
//!     (`:at-least 2`) over one write, and a two-arm control guard
//!     (`:is 0.25`) with an else. At the defaults the frame writes
//!     [controls, THEN]; from t=2 the LATE write joins; a host write of
//!     scene=1 flips the arm to ELSE.
//!
//!   guarded-bad-skip.pngb — frame 0's guard skips past its own end_frame
//!     onto frame 1's define_frame header (§7.3's malformed case). The guard
//!     FAILS at the authored default, so the skip is taken and frame()
//!     refuses. Frame 0 records a marker write before the guard, so a test
//!     can tell a discarded command buffer from an empty one. The reference
//!     dispatcher refuses this payload at load instead (BadSkipTarget) —
//!     only the browser executor ever runs it.
//!
//! Run from the repo root (zig exists on obs only):
//!
//!   obs sh -c 'cd <repo> && ulimit -c 0 && zig run \
//!     --dep bytecode --dep frame_controls_agreement \
//!     -Mroot=tools/gen_frame_controls_fixture.zig \
//!     --dep bytecode -Mframe_controls_agreement=tests/zig/executor/frame_controls_agreement.zig \
//!     --dep types -Mbytecode=src/bytecode/standalone.zig \
//!     -Mtypes=src/types/main.zig \
//!     -- zig-out/executors/pngine-full.wasm \
//!        tests/npm/fixtures/frame-controls'

const std = @import("std");
const Allocator = std.mem.Allocator;
const bytecode = @import("bytecode");
const agreement = @import("frame_controls_agreement");

const Builder = bytecode.format.Builder;
const BufferUsage = bytecode.opcodes.BufferUsage;
const OpCode = bytecode.opcodes.OpCode;

// The guarded fixture's shape comes from the SHARED agreement builder
// (tests/zig/executor/frame_controls_agreement.zig): the same program the
// two executor-side tests run, so the committed bytes cannot drift from
// what the agreement proves. The offsets and defaults are re-exported for
// the doc comment above; the npm test hardcodes the same numbers.
const OFFSET_CONTROLS = agreement.OFFSET_CONTROLS;
const DEFAULT_SCENE = agreement.DEFAULT_SCENE;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const usage = "usage: gen_frame_controls_fixture <executor.wasm> <out-dir>";
    if (args.len != 3) {
        std.debug.print("{s}\n", .{usage});
        return 2;
    }
    const executor_path = args[1];
    const out_dir = args[2];

    const executor = try std.Io.Dir.cwd().readFileAlloc(io, executor_path, gpa, .limited(1 << 24));
    defer gpa.free(executor);

    {
        const pngb = try buildGuarded(gpa, executor);
        defer gpa.free(pngb);
        try checkGuarded(gpa, pngb);
        const path = try std.fmt.allocPrint(arena, "{s}/guarded.pngb", .{out_dir});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = pngb });
        std.debug.print("wrote {s}: {d} B\n", .{ path, pngb.len });
    }
    {
        const pngb = try buildBadSkip(gpa, executor);
        defer gpa.free(pngb);
        try checkBadSkip(gpa, pngb);
        const path = try std.fmt.allocPrint(arena, "{s}/guarded-bad-skip.pngb", .{out_dir});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = pngb });
        std.debug.print("wrote {s}: {d} B\n", .{ path, pngb.len });
    }
    return 0;
}

/// The guarded payload, emitted by the SHARED agreement builder over this
/// generator's interned strings and data blobs (string 0 "main", data
/// 0..2 = THEN, ELSE, LATE — the ids the builder's write_buffers carry).
///
/// The two control names are interned AFTER "main" (which must stay string 0:
/// the agreement builder names frame 0 with it) and added to the uniform
/// table's control-name block in declaration order. The executor never reads
/// the block; it is the public lookup `pngine inspect` uses for `--control`
/// and the listing, so the committed fixture exercises the same name→slot
/// path a host takes — slot 1 scene, slot 2 bloom.
fn buildGuarded(gpa: Allocator, executor: []const u8) ![]u8 {
    var builder = Builder.init();
    defer builder.deinit(gpa);

    _ = try builder.internString(gpa, "main");
    const scene = try builder.internString(gpa, "scene");
    const bloom = try builder.internString(gpa, "bloom");
    try builder.addControlName(gpa, scene.toInt());
    try builder.addControlName(gpa, bloom.toInt());
    _ = try builder.addData(gpa, "THEN-arm");
    _ = try builder.addData(gpa, "ELSE-arm");
    _ = try builder.addData(gpa, "LATE-arm");

    try agreement.emitGuarded(builder.getEmitter(), gpa);

    return builder.finalizeWithOptions(gpa, .{ .executor = executor, .plugins = bytecode.PluginSet.full });
}

/// Frame 0's guard fails at the authored default (5.0 `is_not` 5.0) and its
/// skip lands on frame 1's define_frame — past frame 0's end_frame. The
/// landing bytes must exist inside the stream for patchSkip's own asserts.
///
/// Frame 0 also RECORDS a marker write before the guard: the command buffer
/// demonstrably holds a publishable command when the refusal lands, so the
/// npm bad-skip tests' "the host published nothing" assertion is falsifiable —
/// a host that executed the buffer despite the status (or checked the status
/// only after publishing) would show the marker's write.
fn buildBadSkip(gpa: Allocator, executor: []const u8) ![]u8 {
    var builder = Builder.init();
    defer builder.deinit(gpa);

    const first_id = try builder.internString(gpa, "first");
    const second_id = try builder.internString(gpa, "second");
    const marker = try builder.addData(gpa, "frame-zero-marker");
    const blob = try builder.addData(gpa, "frame-one-body");

    const em = builder.getEmitter();
    try em.createBuffer(gpa, 0, 64, BufferUsage{ .uniform = true, .copy_dst = true });
    try em.emitDefineControl(gpa, 5.0); // slot 1
    try em.defineFrame(gpa, 0, first_id.toInt());
    try em.writeBuffer(gpa, 0, 0, marker.toInt()); // the publication probe
    const if_pos = try em.emitExecIf(gpa, 1, .is_not, 5.0); // 5.0 != 5.0: FALSE → skip taken
    try em.submit(gpa); // the guarded arm (never reached)
    try em.endFrame(gpa);
    const frame1_at = em.len();
    try em.defineFrame(gpa, 1, second_id.toInt());
    try em.writeBuffer(gpa, 0, 0, blob.toInt());
    try em.endFrame(gpa);
    em.patchSkip(if_pos, @intCast(frame1_at - (if_pos + 2)));

    return builder.finalizeWithOptions(gpa, .{ .executor = executor, .plugins = bytecode.PluginSet.full });
}

/// Round-trip checks: the payload must deserialize, and the opcodes the
/// tests steer must be where the emitter said they were. Light on purpose —
/// the behavioural proof is the test suite's job, not the generator's.
fn checkGuarded(gpa: Allocator, pngb: []u8) !void {
    var module = try bytecode.format.deserialize(gpa, pngb);
    defer module.deinit(gpa);

    const bc = module.bytecode;
    if (std.mem.indexOfScalar(u8, bc, @intFromEnum(OpCode.define_control)) == null) return fail("guarded: no define_control");
    if (std.mem.indexOfScalar(u8, bc, @intFromEnum(OpCode.write_controls)) == null) return fail("guarded: no write_controls");
    if (std.mem.indexOfScalar(u8, bc, @intFromEnum(OpCode.exec_if)) == null) return fail("guarded: no exec_if");
    if (std.mem.indexOfScalar(u8, bc, @intFromEnum(OpCode.exec_skip)) == null) return fail("guarded: no exec_skip");
    // The public name block, in declaration order — the CLI's `--control` and
    // the listing both start here, so the committed bytes must carry it.
    if ((module.uniforms.controlSlotByName(&module.strings, "scene") orelse 0) != 1) return fail("guarded: scene is not slot 1");
    if ((module.uniforms.controlSlotByName(&module.strings, "bloom") orelse 0) != 2) return fail("guarded: bloom is not slot 2");
}

fn checkBadSkip(gpa: Allocator, pngb: []u8) !void {
    var module = try bytecode.format.deserialize(gpa, pngb);
    defer module.deinit(gpa);
    // The skip must overshoot a frame boundary: at least two end_frames.
    var ends: usize = 0;
    for (module.bytecode) |b| {
        if (b == @intFromEnum(OpCode.end_frame)) ends += 1;
    }
    if (ends < 2) return fail("bad-skip: expected two frames");
}

fn fail(what: []const u8) error{FixtureCheck} {
    std.debug.print("gen_frame_controls_fixture: {s}\n", .{what});
    return error.FixtureCheck;
}
