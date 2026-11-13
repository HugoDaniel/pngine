//! Generate the animation-table retirement fixture (frame-program plan, F0/D1).
//!
//! Emits a `.pngb` that no compiler in this tree can produce on purpose: two
//! frames, a hand-written animation table that names frame 1 ("second") from
//! t=5 s on, and an embedded executor taken from `zig-out/executors`. The
//! committed copy embeds the executor of the commit that regenerated it, so
//! `tests/npm/animation-table-retired.test.js` pins the shipping behaviour,
//! not a historical one.
//!
//! Run from the repo root (zig exists on obs only):
//!
//!   obs sh -c 'cd <repo> && ulimit -c 0 && zig run \
//!     --dep bytecode -Mroot=tools/gen_animation_table_fixture.zig \
//!     --dep types -Mbytecode=src/bytecode/standalone.zig \
//!     -Mtypes=src/types/main.zig \
//!     -- zig-out/executors/pngine-full.wasm \
//!        tests/npm/fixtures/animation-table/two-frames-table.pngb'
//!
//! The payload is deliberately tiny: one buffer, two one-write frame bodies.
//! The two bodies differ in write offset AND data bytes, so a recording GPU
//! log tells them apart twice over.

const std = @import("std");
const bytecode = @import("bytecode");

const Builder = bytecode.format.Builder;
const Emitter = bytecode.emitter.Emitter;
const AnimationTable = bytecode.AnimationTable;
const Scene = bytecode.animation_table.Scene;
const BufferUsage = bytecode.opcodes.BufferUsage;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const usage = "usage: gen_animation_table_fixture <executor.wasm> <out.pngb>";
    if (args.len != 3) {
        std.debug.print("{s}\n", .{usage});
        return 2;
    }
    const executor_path = args[1];
    const out_path = args[2];

    const executor = try std.Io.Dir.cwd().readFileAlloc(io, executor_path, gpa, .limited(1 << 24));
    defer gpa.free(executor);

    var builder = Builder.init();
    defer builder.deinit(gpa);

    // Strings, interned in this order: 0 "first", 1 "second", then the table's
    // own names. The executor's scanFrameDefinitions reads the frame names from
    // define_frame; the table's scenes reference them by the same ids.
    const first_id = try builder.internString(gpa, "first");
    const second_id = try builder.internString(gpa, "second");
    const timeline_id = try builder.internString(gpa, "timeline");
    const scene_first_id = try builder.internString(gpa, "scene-first");
    const scene_second_id = try builder.internString(gpa, "scene-second");

    // Data blobs the two frame bodies write; distinct bytes AND distinct
    // offsets, so either alone identifies the body that ran.
    const first_blob = try builder.addData(gpa, "FIRST-frame-body");
    const second_blob = try builder.addData(gpa, "SECOND-frame-body");

    // Frame 0 "first": write the first blob at offset 0.
    // Frame 1 "second": write the second blob at offset 16.
    const e: *Emitter = builder.getEmitter();
    try e.createBuffer(gpa, 0, 64, BufferUsage{ .uniform = true, .copy_dst = true });
    try e.defineFrame(gpa, 0, first_id.toInt());
    try e.writeBuffer(gpa, 0, 0, first_blob.toInt());
    try e.endFrame(gpa);
    try e.defineFrame(gpa, 1, second_id.toInt());
    try e.writeBuffer(gpa, 0, 16, second_blob.toInt());
    try e.endFrame(gpa);

    // The table: "first" for [0, 5 s), "second" from 5 s on, hold at the end.
    // No SJON form writes this section (the builder default is `.empty`) — that
    // is exactly why this generator exists.
    const scenes = [_]Scene{
        .{ .id_string_id = scene_first_id.toInt(), .frame_string_id = first_id.toInt(), .start_ms = 0, .end_ms = 5000 },
        .{ .id_string_id = scene_second_id.toInt(), .frame_string_id = second_id.toInt(), .start_ms = 5000, .end_ms = 60000 },
    };
    builder.getAnimationTable().* = .{
        .info = .{
            .name_string_id = timeline_id.toInt(),
            .duration_ms = 60000,
            .loop = false,
            .end_behavior = .hold,
            .scenes = &scenes,
        },
        .owned_scenes = null,
    };

    const output = try builder.finalizeWithOptions(gpa, .{
        .executor = executor,
        .plugins = bytecode.PluginSet.full,
    });
    defer gpa.free(output);

    // Round-trip check: the payload must deserialize with the table intact.
    var module = try bytecode.format.deserialize(gpa, output);
    defer module.deinit(gpa);
    if (!module.animation.hasAnimation()) {
        std.debug.print("gen_animation_table_fixture: table missing after round-trip\n", .{});
        return 1;
    }
    if (module.animation.sceneCount() != 2) {
        std.debug.print("gen_animation_table_fixture: wrong scene count {d}\n", .{module.animation.sceneCount()});
        return 1;
    }
    if (module.animation.findSceneAtTime(10_000) != 1) {
        std.debug.print("gen_animation_table_fixture: table does not select scene 1 at t=10 s\n", .{});
        return 1;
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = output });

    const header = module.header;
    std.debug.print(
        "wrote {s}: {d} B (executor {d} B, animation table at {d}, scenes {d})\n",
        .{ out_path, output.len, executor.len, header.animation_table_offset, module.animation.sceneCount() },
    );
    return 0;
}
