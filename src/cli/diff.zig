//! Diff command: pixel-compare two PNGs under a tolerance model.
//!
//! Usage:
//!   pngine diff <a.png> <b.png> [--preset <name>] [--precision <f>] [--max-diff <n>] [--json]
//!
//! ## Exit codes (diff(1)-style, layered on the CLI's global scheme)
//!   0  images MATCH within tolerance
//!   1  images DIFFER beyond tolerance  (also: invalid arguments — the message
//!      disambiguates; a diff tool's characteristic failure is "not equal")
//!   2  I/O error — a file could not be read
//!   4  format error — an input is not a decodable PNG, or the two sizes disagree
//!
//! The comparator is `png/compare.zig` (a Zig port of the iOS
//! SnapshotComparator), so `pngine diff` shares ONE tolerance model with the
//! native `--frame` snapshot gate and the iOS reference-image tests. It is the
//! exit-code oracle the browser-parity harness (tests/browser/parity.ts) shells
//! out to: native `--frame` vs a browser screenshot, pass/fail by exit status.

const std = @import("std");
const pngine = @import("pngine");
const png = pngine.png;
const utils = @import("utils.zig");
const stdio = @import("stdio.zig");
const arg_reader = @import("arg_reader.zig");
const test_utils = @import("../test_utils.zig");

/// Tolerance model (precision + max per-channel delta). Shared with compare.zig.
const Config = png.CompareConfig;

const Options = struct {
    a: []const u8,
    b: []const u8,
    config: Config,
    json: bool,
};

/// Execute the diff command.
pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    // --help short-circuits before the two-positional requirement.
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return 0;
        }
    }

    const opts = parseArgs(args) orelse return 1;
    std.debug.assert(opts.a.len > 0);
    std.debug.assert(opts.b.len > 0);

    // stdin can only be consumed once. Reading it for both sides would compare
    // the bytes against themselves and always report a match — a false pass is
    // the worst possible failure mode for a comparison tool.
    if (stdio.bothStdin(opts.a, opts.b)) return stdio.reportDoubleStdin();

    const in_a = stdio.readInput(allocator, io, opts.a) catch |err| return stdio.reportReadError(err, opts.a);
    defer in_a.deinit(allocator);

    const in_b = stdio.readInput(allocator, io, opts.b) catch |err| return stdio.reportReadError(err, opts.b);
    defer in_b.deinit(allocator);

    // Name the file in the common "wrong file type" case; deep-decode errors
    // (valid signature, exotic format) fall through to diffEncoded's typed error.
    if (in_a.kind != .png) {
        std.debug.print("Error: '{s}' is not a PNG file\n", .{stdio.displayName(opts.a)});
        return 4;
    }
    if (in_b.kind != .png) {
        std.debug.print("Error: '{s}' is not a PNG file\n", .{stdio.displayName(opts.b)});
        return 4;
    }

    const outcome = png.diff.diffEncoded(allocator, in_a.bytes, in_b.bytes, opts.config) catch |err| {
        std.debug.print("Error: failed to decode PNG input: {}\n", .{err});
        return 4;
    };

    return report(io, outcome, opts);
}

/// Map an outcome to its exit code. Pure: the diff(1)-style contract
/// (0 match / 1 differ / 4 size mismatch) is identical on the human and
/// `--json` branches, so it is worth pinning on its own.
fn exitCode(outcome: png.DiffOutcome) u8 {
    return switch (outcome) {
        .dimension_mismatch => 4,
        .compared => |c| if (c.result.passed) 0 else 1,
    };
}

/// Format the `--json` line into `buf`. Pure, and separate from the write for
/// a reason worth stating: under the Zig test runner, **stdout is the
/// test-runner↔build-runner protocol pipe**. A unit test that called the
/// writing path would inject this JSON straight into that protocol, and the
/// build runner would block forever waiting for a message length it had
/// already mis-parsed — a hang with no failing test to point at. So tests
/// exercise this function and `exitCode`; only `report` writes.
fn formatJson(buf: []u8, outcome: png.DiffOutcome, opts: Options) []const u8 {
    std.debug.assert(buf.len >= 256);
    return switch (outcome) {
        .dimension_mismatch => |m| std.fmt.bufPrint(
            buf,
            "{{\"result\":\"dimension_mismatch\",\"a\":{{\"width\":{d},\"height\":{d}}},\"b\":{{\"width\":{d},\"height\":{d}}}}}\n",
            .{ m.a_width, m.a_height, m.b_width, m.b_height },
        ) catch "",
        .compared => |c| std.fmt.bufPrint(
            buf,
            "{{\"result\":\"{s}\",\"width\":{d},\"height\":{d},\"match_percentage\":{d:.6}," ++
                "\"differing_pixels\":{d},\"total_pixels\":{d},\"max_difference\":{d}," ++
                "\"precision\":{d:.6},\"max_pixel_difference\":{d}}}\n",
            .{
                if (c.result.passed) "match" else "differ",
                c.width,
                c.height,
                c.result.match_percentage,
                c.result.differing_pixel_count,
                c.result.total_pixel_count,
                c.result.max_difference,
                opts.config.precision,
                opts.config.max_pixel_difference,
            },
        ) catch "",
    };
}

/// Render the human line for `outcome` on stderr.
fn printHuman(outcome: png.DiffOutcome, opts: Options) void {
    switch (outcome) {
        .dimension_mismatch => |m| std.debug.print(
            "Error: dimension mismatch — '{s}' is {d}x{d}, '{s}' is {d}x{d}\n",
            .{ stdio.displayName(opts.a), m.a_width, m.a_height, stdio.displayName(opts.b), m.b_width, m.b_height },
        ),
        .compared => |c| {
            const r = c.result;
            const pct: f64 = @as(f64, r.match_percentage) * 100.0;
            std.debug.assert(pct >= 0.0 and pct <= 100.0);
            std.debug.print(
                "{s}  {d:.2}%  {d}x{d}  ({d}/{d} differing, max \u{0394}{d})  [precision {d:.3}, max \u{0394}{d}]\n",
                .{
                    if (r.passed) "match " else "DIFFER",
                    pct,
                    c.width,
                    c.height,
                    r.differing_pixel_count,
                    r.total_pixel_count,
                    r.max_difference,
                    opts.config.precision,
                    opts.config.max_pixel_difference,
                },
            );
        },
    }
}

/// Render `outcome` and map it to an exit code.
///
/// `--json` goes to **stdout**, where a machine can read it. Before this it
/// went through `std.debug.print` like the human line — i.e. to stderr — so
/// `pngine diff a.png b.png --json | jq` received nothing at all.
/// `validate --json` and `inspect --json` already wrote to stdout; this makes
/// the third one agree. Human lines stay on stderr in all three, so a report
/// and a piped artifact never interleave.
fn report(io: std.Io, outcome: png.DiffOutcome, opts: Options) u8 {
    std.debug.assert(opts.a.len > 0 and opts.b.len > 0);
    if (opts.json) {
        var buf: [512]u8 = undefined;
        const line = formatJson(&buf, outcome, opts);
        if (line.len > 0) utils.writeStdout(io, line) catch {};
    } else {
        printHuman(outcome, opts);
    }
    return exitCode(outcome);
}

/// Parse argv into `Options`, or null after printing a specific error.
fn parseArgs(args: []const []const u8) ?Options {
    std.debug.assert(args.len <= arg_reader.max_args);

    var a: ?[]const u8 = null;
    var b: ?[]const u8 = null;
    var config = Config.default;
    var json = false;

    var reader = arg_reader.ArgReader.init(args);
    while (reader.next()) |arg| {
        if (std.mem.eql(u8, arg, "--preset")) {
            const name = reader.value() catch return nullMissing(arg);
            config = presetByName(name) orelse {
                std.debug.print("Error: unknown preset '{s}' (default|high-precision|compute-tolerant)\n", .{name});
                return null;
            };
        } else if (std.mem.eql(u8, arg, "--precision")) {
            const v = reader.value() catch return nullMissing(arg);
            const p = std.fmt.parseFloat(f32, v) catch {
                std.debug.print("Error: --precision expects a number in [0,1], got '{s}'\n", .{v});
                return null;
            };
            if (p < 0.0 or p > 1.0) {
                std.debug.print("Error: --precision must be in [0,1], got {d}\n", .{p});
                return null;
            }
            config.precision = p;
        } else if (std.mem.eql(u8, arg, "--max-diff")) {
            const v = reader.value() catch return nullMissing(arg);
            config.max_pixel_difference = std.fmt.parseInt(u8, v, 10) catch {
                std.debug.print("Error: --max-diff expects an integer in [0,255], got '{s}'\n", .{v});
                return null;
            };
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (arg_reader.ArgReader.isFlag(arg)) {
            _ = arg_reader.unknownOption(arg);
            return null;
        } else if (a == null) {
            a = arg;
        } else if (b == null) {
            b = arg;
        } else {
            std.debug.print("Error: diff takes exactly two PNG files\n", .{});
            return null;
        }
    }

    if (a == null or b == null) {
        std.debug.print("Error: diff requires two PNG files\n\n", .{});
        std.debug.print("Usage: pngine diff <a.png|-> <b.png|-> [--preset <name>] [--precision <f>] [--max-diff <n>] [--json]\n", .{});
        return null;
    }

    std.debug.assert(a != null and b != null);
    return .{ .a = a.?, .b = b.?, .config = config, .json = json };
}

/// Uniform "flag requires a value" error → null (parseArgs sentinel).
fn nullMissing(flag: []const u8) ?Options {
    _ = arg_reader.missingValue(flag);
    return null;
}

/// Map a preset name (with short aliases) to a `Config`, or null if unknown.
fn presetByName(name: []const u8) ?Config {
    if (std.mem.eql(u8, name, "default")) return Config.default;
    if (std.mem.eql(u8, name, "high-precision") or std.mem.eql(u8, name, "high")) return Config.high_precision;
    if (std.mem.eql(u8, name, "compute-tolerant") or std.mem.eql(u8, name, "compute")) return Config.compute_tolerant;
    return null;
}

fn printHelp() void {
    std.debug.print(
        \\pngine diff — pixel-compare two PNGs under a tolerance model
        \\
        \\Usage: pngine diff <a.png|-> <b.png|-> [options]  (at most one `-`)
        \\
        \\Options:
        \\  --preset <name>    default | high-precision | compute-tolerant
        \\  --precision <f>    Fraction of pixels that must match, 0..1 (override)
        \\  --max-diff <n>     Max per-channel absolute delta, 0..255 (override)
        \\  --json             Emit a structured JSON line instead of text
        \\  -h, --help         Show this help
        \\
        \\Presets (precision / max-diff):
        \\  default            0.985 / 5    high-precision   0.99 / 2
        \\  compute-tolerant   0.95  / 10
        \\
        \\Exit codes:
        \\  0 match   1 differ   2 read error   4 not-a-PNG / size mismatch
        \\
    , .{});
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

// The diff(1)-style contract (0 match / 1 differ / 4 size mismatch) is pinned
// on `exitCode`, and the wire shape of `--json` on `formatJson` — both pure.
//
// ⚠️ Do NOT call `report()` here with `json = true`. Under the Zig test runner
// stdout IS the test-runner↔build-runner protocol pipe, so writing a JSON line
// to it corrupts the protocol: the build runner mis-parses the next message
// length and blocks forever, and the suite hangs with no failing test naming
// the cause. Splitting the formatter out is what makes this branch testable at
// all.
const dummy_opts: Options = .{ .a = "a.png", .b = "b.png", .config = Config.default, .json = false };

fn comparedOutcome(passed: bool) png.DiffOutcome {
    return .{ .compared = .{
        .width = 4,
        .height = 4,
        .result = .{
            .passed = passed,
            .match_percentage = if (passed) 1.0 else 0.5,
            .differing_pixel_count = if (passed) 0 else 8,
            .total_pixel_count = 16,
            .max_difference = if (passed) 0 else 200,
        },
    } };
}

const mismatch_outcome: png.DiffOutcome = .{ .dimension_mismatch = .{
    .a_width = 256,
    .a_height = 256,
    .b_width = 128,
    .b_height = 128,
} };
