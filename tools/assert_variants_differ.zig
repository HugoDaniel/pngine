//! Build guard (item 2.2 / C11): the `core` and `full` executor variants MUST
//! be byte-different. They were byte-IDENTICAL for the project's whole history
//! because src/executor/plugins.zig probed `@hasDecl(@import("root"), "plugins")`
//! — a root declaration build.zig never sets — so plugin selection was a no-op
//! and every variant compiled all-plugins-on. If this guard ever fires again,
//! the `@import("plugins")` shim has stopped reaching the executor: gating is
//! dead and the CLI is embedding several copies of one binary.
//!
//! Wired into build.zig's `executors` step and the default install step, taking
//! the two variant binaries as file args (so the build rebuilds them first).

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len != 3) {
        std.debug.print("usage: assert_variants_differ <core.wasm> <full.wasm>\n", .{});
        return 2;
    }

    const core = try Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(core);
    const full = try Io.Dir.cwd().readFileAlloc(io, args[2], gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(full);

    if (std.mem.eql(u8, core, full)) {
        std.debug.print(
            "\nBUILD GUARD FAILED (item 2.2 / C11): core and full executor variants are " ++
                "BYTE-IDENTICAL ({d} B).\nPlugin gating is a no-op — every variant compiled " ++
                "all-plugins-on.\nFix: src/executor/plugins.zig's @import(\"plugins\") shim + " ++
                "build.zig per-variant plugin options.\n",
            .{core.len},
        );
        return 1;
    }

    std.debug.print(
        "plugin-variant guard OK: core is {d} B, full is {d} B (they differ, as they must)\n",
        .{ core.len, full.len },
    );
    return 0;
}
