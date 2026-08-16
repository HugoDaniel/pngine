//! PNGine schema-export golden runner.
//!
//! Generates the editor-facing artifacts from the single source of truth
//! `schema/pngine.sjon`, via SJON's `SchemaExport`:
//!   - `schema/pngine.d.ts`        — TypeScript types (one `interface` per form,
//!                                    `type` alias per value-kind, a `SjonPngine`
//!                                    barrel union) describing the canonical
//!                                    `sjon to-json` shape a `.sjon` document
//!                                    serializes to.
//!   - `schema/pngine.schema.json` — JSON Schema 2020-12 (`oneOf` over every form,
//!                                    `$defs/form.*` + `$defs/kind.*`) for editor
//!                                    validation / autocomplete.
//!
//! Run modes (mirrors SJON's `examples/export-schema-demo.zig`):
//!   - default: re-export from the embedded schema and diff against the two
//!     committed artifacts. Exits 1 on any drift — this is the build-time gate
//!     (`zig build schema-export`, joined to `test-standalone`). It guarantees
//!     the committed `.d.ts`/`.schema.json` faithfully reflect the current forms,
//!     value-kinds, and enums.
//!   - `--regen`: write the freshly-exported bytes to the artifact paths. Run
//!     after intentionally editing `schema/pngine.sjon`
//!     (`zig build schema-export -- --regen`), then review the diff and commit.
//!
//! The schema is `@embedFile`'d (the `pngine_schema` build import) — the exact
//! bytes `src/dsl_sjon/Compiler.zig` embeds — so the artifacts can never drift
//! from what the compiler actually validates against. Only the OUTPUT artifacts
//! touch disk; the export itself is pure (`SchemaExport` does no file IO).

const std = @import("std");
const sjon = @import("sjon");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The PNGine WebGPU schema, embedded as a portable SJON manifest (the same
/// `pngine_schema` anonymous import the compiler embeds).
const manifest_src: [:0]const u8 = @embedFile("pngine_schema");

const ts_path = "schema/pngine.d.ts";
const json_path = "schema/pngine.schema.json";

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var regen = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--regen")) regen = true;
    }

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file = Io.File.stderr();
    var stderr_writer = stderr_file.writer(io, &stderr_buf);
    defer stderr_writer.interface.flush() catch {};
    const stderr = &stderr_writer.interface;

    // parse → ManifestLoader.load → Schema → exportSchema. PNGine's plugin is
    // self-contained (every cross-ref target is one of its own forms), so a
    // single-plugin schema exports cleanly — no `core` plugin needed (mirrors
    // SJON's manifest-fixture export path).
    var tree = try sjon.parse(gpa, manifest_src);
    defer tree.deinit();

    var loaded = try sjon.ManifestLoader.load(gpa, tree);
    defer loaded.deinit();
    if (loaded.hasErrors()) {
        try stderr.print("schema/pngine.sjon: manifest load failed ({d} diagnostic(s))\n", .{loaded.diagnostics.len});
        return 1;
    }

    const schema: sjon.Schema.Schema = .{ .plugins = &.{loaded.plugin} };
    var result = try sjon.SchemaExport.exportSchema(gpa, schema, .{
        .target = .{ .json_schema = true, .ts_types = true },
    });
    defer result.deinit();

    // Warnings are informational (cross-refs are unenforceable in JSON Schema,
    // unions emit as `anyOf`, …) and are already baked into the artifacts (the
    // `.d.ts` header + `x-sjon-export-warnings`). Echo them only when the
    // developer is regenerating or on error, so the routine check gate (joined
    // to `test-standalone`) stays quiet on success.
    if (regen or result.hasErrors()) {
        for (result.warnings) |w| {
            try stderr.print("  [{s}] {s}\n", .{ @tagName(w.severity), w.message });
        }
    }
    if (result.hasErrors()) {
        try stderr.writeAll("schema-export: exporter reported errors (see above)\n");
        return 1;
    }

    var any_diff = false;
    try handle(gpa, io, regen, stderr, ts_path, result.ts_types_bytes.?, &any_diff);
    try handle(gpa, io, regen, stderr, json_path, result.json_schema_bytes.?, &any_diff);

    if (any_diff and !regen) {
        try stderr.writeAll(
            "schema-export: a committed artifact differs from schema/pngine.sjon; " ++
                "run `zig build schema-export -- --regen` and commit the result\n",
        );
        return 1;
    }
    return 0;
}

/// Write `bytes` to `path` (regen), or diff it against the committed file
/// (default), flagging `any_diff` and printing the first divergence on mismatch.
fn handle(
    gpa: Allocator,
    io: Io,
    regen: bool,
    stderr: *Io.Writer,
    path: []const u8,
    bytes: []const u8,
    any_diff: *bool,
) !void {
    if (regen) {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
        try stderr.print("wrote {s} ({d} bytes)\n", .{ path, bytes.len });
        return;
    }
    const existing = Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| {
        try stderr.print("schema-export: cannot read {s}: {s} (run with --regen)\n", .{ path, @errorName(err) });
        any_diff.* = true;
        return;
    };
    defer gpa.free(existing);
    if (std.mem.eql(u8, existing, bytes)) return;
    any_diff.* = true;
    try stderr.print(
        "schema-export: {s} differs (committed {d} bytes, fresh {d} bytes)\n",
        .{ path, existing.len, bytes.len },
    );
    try printFirstDiffLine(stderr, existing, bytes);
}

/// Locate the first byte where `expected` and `actual` diverge and print a
/// short windowed context around it, so an unexpected drift is legible.
fn printFirstDiffLine(stderr: *Io.Writer, expected: []const u8, actual: []const u8) !void {
    var line: usize = 1;
    var col: usize = 1;
    const n = @min(expected.len, actual.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (expected[i] != actual[i]) break;
        if (expected[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    try stderr.print("  first diff at line {d} col {d}\n", .{ line, col });
    const ctx: usize = 60;
    const lo: usize = if (i >= ctx) i - ctx else 0;
    const hi_e: usize = @min(expected.len, i + ctx);
    const hi_a: usize = @min(actual.len, i + ctx);
    try stderr.print("  expected: {s}\n", .{expected[lo..hi_e]});
    try stderr.print("  actual:   {s}\n", .{actual[lo..hi_a]});
}
