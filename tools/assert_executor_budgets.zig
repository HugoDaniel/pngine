//! Build guard (item 4.2 / C7b): each executor WASM variant must stay under its
//! size budget. Budgets = measured reality (2026-07, after Purity-Arc-2 Phases
//! 1-4 shrank the executor 14,973 -> ~11,600 B) + ~10% headroom, declared
//! per-variant in build.zig right next to the plugin flags. A variant growing
//! past budget is either a real regression or a deliberate feature cost — both
//! should be conscious, not a silent creep. The executor ships inside every PNG,
//! so it is the project's tightest size constraint; this gate runs on
//! `zig build executors` and the default install step.
//!
//! argv: (<name> <max_bytes> <path>) triples, one per variant. build.zig owns
//! the budget table, so this tool is a generic "each file <= its budget" check.

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 4 or (args.len - 1) % 3 != 0) {
        std.debug.print("usage: assert_executor_budgets (<name> <max_bytes> <path>)...\n", .{});
        return 2;
    }

    const count: u32 = @intCast((args.len - 1) / 3);
    var failures: u32 = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 3) {
        const name = args[i];
        const max_bytes = std.fmt.parseInt(u32, args[i + 1], 10) catch {
            std.debug.print("assert_executor_budgets: bad budget '{s}' for {s}\n", .{ args[i + 1], name });
            return 2;
        };
        const bin = try Io.Dir.cwd().readFileAlloc(io, args[i + 2], gpa, .limited(64 * 1024 * 1024));
        defer gpa.free(bin);
        const size: u32 = @intCast(bin.len);
        if (size > max_bytes) {
            std.debug.print("  x {s}: {d} B exceeds budget {d} B (+{d})\n", .{ name, size, max_bytes, size - max_bytes });
            failures += 1;
        } else {
            std.debug.print("  ok {s}: {d} / {d} B ({d} B headroom)\n", .{ name, size, max_bytes, max_bytes - size });
        }
    }

    if (failures > 0) {
        std.debug.print(
            "\nEXECUTOR SIZE GATE FAILED (item 4.2 / C7b): {d}/{d} variant(s) over budget.\n" ++
                "If the growth is deliberate, bump that variant's max_bytes in build.zig.\n",
            .{ failures, count },
        );
        return 1;
    }

    std.debug.print("executor budget guard OK: {d} variant(s) within budget.\n", .{count});
    return 0;
}
