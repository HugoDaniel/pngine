//! Play command: generate a self-contained, fully offline HTML player from
//! SJON source or a PNG carrying one logical PNGB payload.
//!
//! ## Usage
//! ```
//! pngine play input.sjon -o player.html
//! pngine play input.png -o player.html
//! pngine play - | ...
//! ```
//!
//! Options: `-o/--output <path|->`, `--duration <seconds>` (positive finite,
//! default 10), `-h/--help`.
//!
//! ## Design
//! This module owns the pieces the command is built from: argument parsing,
//! preparing a self-contained PNG from SJON source (through render's pipeline,
//! so the player embeds exactly what `pngine render` writes), inspecting a PNG
//! for the one logical PNGB payload the page will play, and orchestration into
//! the static page. HTML generation itself lives in `play_html.zig`.
//!
//! `inspectPng` accepts the payload in either carrier generation — the legacy
//! `pNGb` chunk or a `pNGx` envelope — without rewriting a single input byte.
//! The page is built in full before the one write, so every failure leaves an
//! existing destination untouched.
//!
//! ## Exit codes
//! - 0 success (including `-h/--help`)
//! - 1 usage error
//! - 2 read or write failure
//! - 3 SJON compile/package failure
//! - 4 wrong or malformed PNG payload
//!
//! ## Invariants
//! - `inspectPng` requires exactly one logical PNGB payload, envelope version
//!   1, and returns its carrier and executor flag.
//! - `packageSelfContainedPng` returns an executor-bearing legacy-carrier PNG
//!   and never writes files; the caller owns the result.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pngine = @import("pngine");
const render = @import("render.zig");
const play_html = @import("play_html.zig");
const arg_reader = @import("arg_reader.zig");
const stdio = @import("stdio.zig");
const utils = @import("utils.zig");
const test_utils = @import("../test_utils.zig");

const build_options = @import("build_options");

/// The generic all-plugin executor. The page receives it only when the input
/// PNG carries no executor of its own. Same build-time artifact and import
/// name render.zig uses.
const embedded_wasm: []const u8 = if (build_options.has_embedded_wasm) @embedFile("embedded_wasm") else "";

/// Default playback span in seconds.
const default_duration: f32 = 10.0;

/// `pngine play` help text. `-h/--help` is intentionally absent from the
/// CLAUDE.md Play Options table (that table documents `--output` and
/// `--duration` only); it is still accepted here.
pub const usage =
    \\pngine play - Generate a self-contained, fully offline HTML player
    \\
    \\Usage:
    \\  pngine play <input.sjon|input.png|-> [options]
    \\
    \\Options:
    \\  -o, --output <path>    Output HTML path (default: <input>.html; stdin -> stdout)
    \\  --duration <seconds>   Playback span, positive and finite (default: 10)
    \\  -h, --help             Show this help
    \\
    \\The player embeds the runtime, the PNG payload and, when the PNG has no
    \\executor, the generic WASM executor. It starts paused at zero and makes no
    \\network requests.
    \\
;

/// Parsed `pngine play` options.
pub const Options = struct {
    input_path: []const u8 = "",
    output_path: ?[]const u8 = null,
    duration: f32 = default_duration,
    /// `-h/--help` was seen; `parseArgs` already printed the usage.
    help: bool = false,
};

/// Which carrier held the logical PNGB payload in the input PNG.
pub const PayloadTransport = enum {
    /// A legacy `pNGb` chunk: the page can hand the PNG to `pngine()` as-is.
    png,
    /// A `pNGx` envelope: the page must inflate and extract the PNGB first.
    pngx_pngb,
};

/// What the play command needs to know about an input PNG.
pub const InspectedPng = struct {
    transport: PayloadTransport,
    has_embedded_executor: bool,
};

/// Inspect a PNG's logical PNGB payload without modifying its bytes.
///
/// Exactly one `PNGB` payload is accepted, in either carrier generation. The
/// body is inflated only to read its header; the input slice is never written.
/// Payload kinds other than `PNGB` (audio, metadata, flat buffers) are ignored.
///
/// Errors:
/// - `MissingPnginePayload`: no `PNGB` payload
/// - `MultiplePnginePayloads`: more than one `PNGB` payload
/// - `InvalidPnginePayload`: the body does not inflate or does not deserialize
/// - `UnsupportedPayloadVersion`: envelope version is not 1
/// - the walker's framing errors (`InvalidPng`, `ChunkTooLarge`, `OutOfMemory`)
pub fn inspectPng(gpa: Allocator, png_bytes: []const u8) !InspectedPng {
    var walk = try pngine.png.walkPng(gpa, png_bytes);
    defer walk.deinit(gpa);

    var found: ?pngine.png.WalkPayload = null;
    var count: usize = 0;
    for (walk.payloads) |p| {
        if (!std.mem.eql(u8, &p.kind, "PNGB")) continue;
        found = p;
        count += 1;
    }
    if (count == 0) return error.MissingPnginePayload;
    if (count > 1) return error.MultiplePnginePayloads;

    const payload = found.?;
    if (payload.version != pngine.png.embed.PNGB_VERSION) {
        return error.UnsupportedPayloadVersion;
    }

    const body: []u8 = if (payload.flags & pngine.payload.envelope.FLAG_COMPRESSED != 0)
        pngine.png.inflatePayload(gpa, payload.body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidPnginePayload,
        }
    else
        try gpa.dupe(u8, payload.body);
    defer gpa.free(body);

    var module = pngine.format.deserialize(gpa, body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPnginePayload,
    };
    defer module.deinit(gpa);

    return .{
        .transport = if (std.mem.eql(u8, &payload.carrier.chunk_type, &pngine.png.ChunkType.pNGb))
            .png
        else
            .pngx_pngb,
        .has_embedded_executor = module.hasEmbeddedExecutor(),
    };
}

/// Parse `play` arguments. Returns 0 on success (help included, flagged by
/// `opts.help`), or the exit code of the first usage error.
fn parseArgs(args: []const []const u8, opts: *Options) u8 {
    var reader = arg_reader.ArgReader.init(args);
    while (reader.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            opts.help = true;
            return 0;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            opts.output_path = reader.value() catch return arg_reader.missingValue(arg);
        } else if (std.mem.eql(u8, arg, "--duration")) {
            const text = reader.value() catch return arg_reader.missingValue(arg);
            const seconds = std.fmt.parseFloat(f32, text) catch {
                std.debug.print("Error: --duration expects a number of seconds, got '{s}'\n", .{text});
                return 1;
            };
            // The underflow case is the quiet one: `1e-50` parses to 0, and
            // only the value check catches that it is not a positive span.
            if (!std.math.isFinite(seconds) or seconds <= 0) {
                std.debug.print("Error: --duration must be a positive finite number of seconds, got '{s}'\n", .{text});
                return 1;
            }
            opts.duration = seconds;
        } else if (arg_reader.ArgReader.isFlag(arg)) {
            return arg_reader.unknownOption(arg);
        } else {
            reader.addPositional(arg) catch return arg_reader.duplicateInput();
        }
    }

    if (reader.positional == null) {
        std.debug.print("Error: no input file specified\n\n{s}", .{usage});
        return 1;
    }
    opts.input_path = reader.positional.?;
    return 0;
}

/// The generic executor to embed, or null when this build has none.
fn genericExecutor() ?[]const u8 {
    return if (embedded_wasm.len > 0) embedded_wasm else null;
}

/// The page plus the one allocation the command owns (the SJON-packaged PNG).
const Prepared = struct {
    page: play_html.Page,
    owned_png: ?[]u8 = null,

    fn deinit(self: *Prepared, gpa: Allocator) void {
        if (self.owned_png) |png| gpa.free(png);
        self.* = undefined;
    }
};

/// The exit categories `preparePage` can fail with. Each cause has already
/// printed its diagnostic by the time the tag travels back to `run`.
const PrepareError = error{
    OutOfMemory,
    PackageFailed,
    BadPayload,
    WrongInputKind,
};

/// Turn the read input into its page description.
///
/// SJON is packaged through render's default self-contained path, so it always
/// carries its executor. A PNG is inspected without rewriting a byte; the
/// generic executor is supplied only when the PNG lacks one, and the transport
/// decides whether the page must extract a `pNGx` envelope first.
fn preparePage(
    gpa: Allocator,
    io: std.Io,
    input: []const u8,
    in: stdio.Input,
    duration: f32,
) PrepareError!Prepared {
    switch (in.kind) {
        .sjon => {
            const packaged = render.packageSelfContainedPng(gpa, io, input, in.bytes, .{}) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                std.debug.print("Error: failed to package '{s}': {}\n", .{ stdio.displayName(input), err });
                return error.PackageFailed;
            };
            return .{
                .page = .{ .png_bytes = packaged, .duration_seconds = duration },
                .owned_png = packaged,
            };
        },
        .png => {
            const inspected = inspectPng(gpa, in.bytes) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                std.debug.print("Error: '{s}' is not a playable PNG: {s}\n", .{
                    stdio.displayName(input), @errorName(err),
                });
                return error.BadPayload;
            };
            return .{ .page = .{
                .png_bytes = in.bytes,
                .extract_pngx = inspected.transport == .pngx_pngb,
                .fallback_executor_wasm = if (inspected.has_embedded_executor) null else genericExecutor(),
                .duration_seconds = duration,
            } };
        },
        else => {
            std.debug.print("Error: play expects SJON source or a PNG, got {t} ({s})\n", .{
                in.kind, stdio.displayName(input),
            });
            return error.WrongInputKind;
        },
    }
}

/// Execute the play command.
///
/// Pre-condition: args is the slice after "play" command.
/// Post-condition: returns the exit code; the HTML is built in full before the
/// one write, so every failure leaves the destination untouched.
pub fn run(gpa: Allocator, io: std.Io, args: []const []const u8) !u8 {
    var opts: Options = .{};
    const parse_result = parseArgs(args, &opts);
    if (parse_result != 0) return parse_result;
    if (opts.help) return 0;
    std.debug.assert(opts.input_path.len > 0);

    const input = opts.input_path;

    // Derive the default output beside the input. Piped input has no name to
    // derive from, so it goes to stdout rather than a file called `-.html`.
    const dest: stdio.Output = if (opts.output_path) |p|
        .borrowed(p)
    else if (stdio.isStd(input))
        .borrowed(stdio.std_path)
    else
        .owned(utils.deriveSiblingPath(gpa, input, ".html") catch |err| {
            std.debug.print("Error: failed to derive output path: {}\n", .{err});
            return 2;
        });
    defer dest.deinit(gpa);

    // One read for both input kinds: a real path by extension, stdin by bytes.
    // The buffer stays alive through page generation; a PNG's bytes are embedded
    // from it unchanged, and only a packaged SJON PNG is separately owned.
    const in = stdio.readInput(gpa, io, input) catch |err| return stdio.reportReadError(err, input);
    defer in.deinit(gpa);

    var prepared = preparePage(gpa, io, input, in, opts.duration) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.PackageFailed => return 3,
        error.BadPayload, error.WrongInputKind => return 4,
    };
    defer prepared.deinit(gpa);

    // Build the entire page before the write: a failure here is never a
    // half-written destination.
    const html = play_html.renderPage(gpa, prepared.page) catch |err| {
        if (err == error.OutOfMemory) return err;
        std.debug.print("Error: failed to generate the player page: {}\n", .{err});
        return 1;
    };
    defer gpa.free(html);

    // Text, so `-o -` may go to a terminal.
    stdio.writeOutput(io, dest.path, html, false) catch |err| return stdio.reportWriteError(err, dest.path);

    std.debug.print("Generated player {s} -> {s} ({d} bytes)\n", .{
        stdio.displayName(input), stdio.outName(dest.path), html.len,
    });
    return 0;
}

// ============================================================================
// Tests
// ============================================================================

/// A valid 1x1 transparent PNG, the carrier every fixture starts from.
fn makeBasePng(gpa: Allocator) ![]u8 {
    const pixels = [_]u8{ 0, 0, 0, 0 };
    return pngine.png.encode(gpa, &pixels, 1, 1);
}

/// Compile `examples/simple_triangle.sjon` into a real PNGB body (no executor).
fn compileFixture(gpa: Allocator, io: std.Io) ![]u8 {
    const input = "examples/simple_triangle.sjon";
    const in = try stdio.readInput(gpa, io, input);
    defer in.deinit(gpa);
    return pngine.dsl_sjon.compileWithOptions(gpa, in.bytes, .{
        .base_dir = stdio.baseDir(input),
        .io = io,
    });
}

/// Insert a compressed `PNGB` payload as a `pNGx` envelope record before IEND.
///
/// `packPng` keeps `PNGB` on its legacy carrier (the museum promise), so the
/// envelope-carried fixture is assembled from the same public chunk primitives
/// the writer uses — without touching the writer's carrier policy.
fn insertEnvelopePayload(gpa: Allocator, base_png: []const u8, body: []const u8, version: u8) ![]u8 {
    const stored = try pngine.png.embed.compressDeflateRaw(gpa, body);
    defer gpa.free(stored);
    const record = try pngine.payload.envelope.encode(
        gpa,
        "PNGB".*,
        version,
        pngine.payload.envelope.FLAG_COMPRESSED,
        stored,
    );
    defer gpa.free(record);

    var iter = try pngine.png.chunk.parseChunks(base_png);
    var iend_offset: ?usize = null;
    while (try iter.next()) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &pngine.png.ChunkType.IEND)) {
            iend_offset = c.offset;
            break;
        }
    }
    const at = iend_offset orelse return error.MissingIend;

    const envelope_len = pngine.png.chunk.chunkSize(record.len);
    const out = try gpa.alloc(u8, base_png.len + envelope_len);
    errdefer gpa.free(out);
    @memcpy(out[0..at], base_png[0..at]);
    const written = pngine.png.chunk.writeChunkToBuffer(out[at..], pngine.png.ChunkType.pNGx, record);
    std.debug.assert(written == envelope_len);
    @memcpy(out[at + envelope_len ..], base_png[at..]);
    return out;
}
