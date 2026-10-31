//! Embed and extract commands: embed/extract bytecode from PNG files, pack
//! and list payloads.
//!
//! Usage:
//!   pngine embed <image.png> <bytecode.pngb> [-o output.png]
//!   pngine extract <input.png|input.zip> [-o output.pngb]
//!   pngine extract <input.png> --list   (dump the pNG* chunk inventory)
//!   pngine extract <input.png> --kind KIND [--nth n] -o out   (one payload)
//!   pngine pack <in.png> --add KIND=path[,raw] ... -o out     (append payloads)
//!   pngine ls <file.png>        (one row per payload: kind, version, flags,
//!                                body size, stored size, carrier)

const std = @import("std");
const Allocator = std.mem.Allocator;
const pngine = @import("pngine");
const format = pngine.format;
const utils = @import("utils.zig");
const stdio = @import("stdio.zig");
const bundle = @import("bundle.zig");
const arg_reader = @import("arg_reader.zig");

/// Embed command arguments.
const EmbedArgs = struct {
    png_path: []const u8,
    pngb_path: []const u8,
    output_path: ?[]const u8,
};

pub const embed_usage =
    \\pngine embed - Embed PNGB bytecode into an existing PNG
    \\
    \\Usage: pngine embed <image.png|-> <bytecode.pngb|-> [options]
    \\
    \\Options:
    \\  -o, --output <path>    Output PNG path (default: <image>.embedded.png)
    \\                         Either input may be `-` (stdin), but not both.
    \\  -h, --help             Show this help
    \\
;

pub const extract_usage =
    \\pngine extract - Extract embedded bytecode from a PNG or ZIP bundle
    \\
    \\Usage: pngine extract <file.png|file.flac|file.zip|-> [options]
    \\
    \\Options:
    \\  -o, --output <path>    Output .pngb path (default: <input>.pngb; stdout if
    \\                         the input is `-`). Use `-` to write stdout.
    \\  -l, --list             List every PNGine ancillary chunk in the file
    \\  -k, --kind <KIND>      Extract one payload by kind (e.g. META, SNTU),
    \\                         decompressed; PNG and FLAC input
    \\  -n, --nth <n>          With --kind: the nth payload of that kind
    \\                         (1-based, default 1)
    \\  -h, --help             Show this help
    \\
;

pub const pack_usage =
    \\pngine pack - Append payloads to a PNG or FLAC
    \\
    \\Usage: pngine pack <in.png|in.flac|-> --add KIND=path[,raw] ... [-o out]
    \\
    \\One carrier per payload. In a PNG: legacy kinds keep their legacy letters
    \\(PNGB/PNGF/SNTU/META), everything else rides pNGx. In a FLAC every kind
    \\rides a pNGx APPLICATION block (02:129). Payloads are DEFLATE'd by
    \\default; `,raw` stores them verbatim. `path` may be `-` for stdin
    \\(one payload per pipe).
    \\
    \\Options:
    \\  -a, --add <KIND=path[,raw]>  A payload to append; repeatable, in order
    \\      The ,raw suffix is stripped once from the end of the argument:
    \\      KIND=foo,raw,raw embeds a file literally named foo,raw uncompressed,
    \\      and no path spelling embeds that file compressed; pipe it instead:
    \\      --add KIND=- < foo,raw
    \\      An empty payload is legal and follows the same rule: DEFLATE by
    \\      default (the empty stream), ,raw stores zero bytes.
    \\  -o, --output <path>          Output path (default: <input>_packed.png or
    \\                               <input>_packed.flac; stdout if the input is `-`)
    \\  -h, --help                   Show this help
    \\
;

pub const ls_usage =
    \\pngine ls - List the payloads a PNG or FLAC carries
    \\
    \\Usage: pngine ls <file.png|file.flac|->
    \\
    \\One row per payload: kind, version, flags, body size, stored size,
    \\carrier (pNGb / pNGx#2 / APPLICATION#1 / PICTURE→pNGf / ...). Chunks that carry no payload (unknown
    \\family letters, unreadable envelopes) are listed as skips, never
    \\dropped. The generalization of `extract --list`.
    \\
    \\Options:
    \\  -h, --help             Show this help
    \\
;

/// Execute the embed command.
pub fn runEmbed(gpa: Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (arg_reader.wantsHelp(args)) return arg_reader.printHelp(embed_usage);

    const parsed = parseEmbedArgs(args) orelse return 1;

    // Both inputs are read in full before either is used, so `-` twice would
    // hand the same bytes to both roles.
    if (stdio.bothStdin(parsed.png_path, parsed.pngb_path)) return stdio.reportDoubleStdin();

    // A piped image leaves nothing to derive a name from; write to stdout.
    const dest: stdio.Output = if (parsed.output_path) |p|
        .borrowed(p)
    else if (stdio.isStd(parsed.png_path))
        .borrowed(stdio.std_path)
    else
        .owned(utils.deriveSiblingPath(gpa, parsed.png_path, "_embedded.png") catch |err| {
            std.debug.print("Error: failed to derive output path: {}\n", .{err});
            return 2;
        });
    defer dest.deinit(gpa);

    return executeEmbed(gpa, io, parsed.png_path, parsed.pngb_path, dest.path);
}

fn parseEmbedArgs(args: []const []const u8) ?EmbedArgs {
    var png_path: ?[]const u8 = null;
    var pngb_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    // Two positionals (png, pngb); extras are ignored as before. ArgReader
    // supplies the value lookahead and unknown-flag classification; `value()`
    // advances the cursor, so `-o out` before the positionals no longer
    // mis-captures the value as a positional (the old skip-less loop did).
    var reader = arg_reader.ArgReader.init(args);
    while (reader.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_path = reader.value() catch {
                _ = arg_reader.missingValue(arg);
                return null;
            };
        } else if (arg_reader.ArgReader.isFlag(arg)) {
            _ = arg_reader.unknownOption(arg);
            return null;
        } else if (png_path == null) {
            png_path = arg;
        } else if (pngb_path == null) {
            pngb_path = arg;
        }
    }

    if (png_path == null or pngb_path == null) {
        std.debug.print("Error: embed requires both <image.png> and <bytecode.pngb>\n\n", .{});
        std.debug.print("Usage: pngine embed <image.png|-> <bytecode.pngb|-> [-o output.png|-]\n", .{});
        return null;
    }

    return .{ .png_path = png_path.?, .pngb_path = pngb_path.?, .output_path = output_path };
}

fn executeEmbed(gpa: Allocator, io: std.Io, png_input: []const u8, pngb_input: []const u8, output: []const u8) u8 {
    std.debug.assert(png_input.len > 0);
    std.debug.assert(pngb_input.len > 0);

    const png_in = stdio.readInput(gpa, io, png_input) catch |err| return stdio.reportReadError(err, png_input);
    defer png_in.deinit(gpa);
    const png_data = png_in.bytes;

    const pngb_in = stdio.readInput(gpa, io, pngb_input) catch |err| return stdio.reportReadError(err, pngb_input);
    defer pngb_in.deinit(gpa);
    const bytecode = pngb_in.bytes;

    if (png_in.kind != .png) {
        std.debug.print("Error: '{s}' is not a PNG file\n", .{stdio.displayName(png_input)});
        return 4;
    }

    if (bytecode.len < format.HEADER_SIZE or !std.mem.eql(u8, bytecode[0..4], format.MAGIC)) {
        std.debug.print("Error: '{s}' is not a valid PNGB file\n", .{stdio.displayName(pngb_input)});
        return 4;
    }

    const embedded = pngine.png.embedBytecode(gpa, png_data, bytecode) catch |err| {
        std.debug.print("Error: failed to embed bytecode: {}\n", .{err});
        return 4;
    };
    defer gpa.free(embedded);

    stdio.writeOutput(io, output, embedded, true) catch |err| return stdio.reportWriteError(err, output);

    std.debug.print("Embedded {s} ({d} bytes) into {s} -> {s} ({d} bytes)\n", .{
        stdio.displayName(pngb_input), bytecode.len, stdio.displayName(png_input), stdio.outName(output), embedded.len,
    });

    return 0;
}

/// Execute the extract command.
pub fn runExtract(gpa: Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (arg_reader.wantsHelp(args)) return arg_reader.printHelp(extract_usage);

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var list_chunks = false;
    var kind_arg: ?[]const u8 = null;
    var nth: usize = 1;
    // Whether --nth was spelled at all: the selector is only read by the
    // --kind path, so a bare --nth (or one beside --list) would otherwise be
    // accepted and ignored.
    var nth_given = false;

    var reader = arg_reader.ArgReader.init(args);
    while (reader.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_path = reader.value() catch return arg_reader.missingValue(arg);
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
            list_chunks = true;
        } else if (std.mem.eql(u8, arg, "-k") or std.mem.eql(u8, arg, "--kind")) {
            kind_arg = reader.value() catch return arg_reader.missingValue(arg);
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--nth")) {
            const nth_str = reader.value() catch return arg_reader.missingValue(arg);
            nth = std.fmt.parseInt(usize, nth_str, 10) catch {
                std.debug.print("Error: invalid --nth '{s}' (expected a 1-based count)\n", .{nth_str});
                return 1;
            };
            if (nth < 1) {
                std.debug.print("Error: --nth is 1-based, got {d}\n", .{nth});
                return 1;
            }
            nth_given = true;
        } else if (arg_reader.ArgReader.isFlag(arg)) {
            return arg_reader.unknownOption(arg);
        } else {
            reader.addPositional(arg) catch return arg_reader.duplicateInput();
        }
    }
    input_path = reader.positional;

    if (input_path == null) {
        std.debug.print("Error: no input file specified\n\n", .{});
        std.debug.print("Usage: pngine extract <file.png|file.flac|file.zip|-> [-o output.pngb|-] [--list]\n", .{});
        return 1;
    }

    const input = input_path.?;

    // Selector guards, before either dispatch: `--list` runs first below, so
    // a `--kind` or `--nth` beside it would be silently ignored, and a bare
    // `--nth` never reaches the one path that reads it. Both are usage
    // errors the caller can fix, not input failures: exit 1.
    if (nth_given and (kind_arg == null or list_chunks)) {
        std.debug.print("Error: --nth selects one --kind payload; it needs --kind and cannot combine with --list\n", .{});
        return 1;
    }
    if (list_chunks and kind_arg != null) {
        std.debug.print("Error: --kind cannot combine with --list\n", .{});
        return 1;
    }

    // `--list`: enumerate every PNGine ancillary chunk (pNGb/pNGm/pNGa/pNGf/…)
    // the file carries — the read-side inventory of whatever `embed` wrote (A7).
    // A diagnostic dump; writes no output file.
    if (list_chunks) return runExtractList(gpa, io, input);

    // `--kind`: one payload, decompressed (02.C2, spec 02:109). The walker is
    // the same one `ls` lists through; only the selection is new.
    if (kind_arg) |kind| return runExtractKind(gpa, io, input, kind, nth, output_path);

    // Piped input has no name to derive an output from, so it defaults to
    // stdout — which is what makes `pngine extract - | pngine inspect -` work
    // without a `-o -` on every stage.
    const dest: stdio.Output = if (output_path) |p|
        .borrowed(p)
    else if (stdio.isStd(input))
        .borrowed(stdio.std_path)
    else
        .owned(utils.deriveSiblingPath(gpa, input, ".pngb") catch |err| {
            std.debug.print("Error: failed to derive output path: {}\n", .{err});
            return 2;
        });
    defer dest.deinit(gpa);
    const output = dest.path;

    const in = stdio.readInput(gpa, io, input) catch |err| return stdio.reportReadError(err, input);
    defer in.deinit(gpa);
    const file_data = in.bytes;

    const bytecode = carvedBytecode(gpa, in.kind, file_data, input) orelse return 4;
    defer gpa.free(bytecode);

    stdio.writeOutput(io, output, bytecode, true) catch |err| return stdio.reportWriteError(err, output);

    std.debug.print("Extracted {s} -> {s} ({d} bytes)\n", .{ stdio.displayName(input), stdio.outName(output), bytecode.len });
    return 0;
}

/// Pull the PNGB payload out of whatever container `kind` says this is.
///
/// Null means the failure was already reported and the caller should exit 4 —
/// every way this can fail (wrong container, no pNGb chunk, corrupt payload)
/// carries a different message but the same code.
fn carvedBytecode(
    gpa: Allocator,
    kind: stdio.Kind,
    file_data: []const u8,
    input: []const u8,
) ?[]u8 {
    std.debug.assert(input.len > 0);

    const bytecode = switch (kind) {
        .zip => bundle.extractFromZip(gpa, file_data) catch |err| {
            std.debug.print("Error: failed to extract from ZIP: {}\n", .{err});
            return null;
        },
        .png => blk: {
            if (!pngine.png.hasPngb(file_data)) {
                std.debug.print("Error: '{s}' has no embedded bytecode (missing pNGb chunk)\n", .{stdio.displayName(input)});
                return null;
            }
            break :blk pngine.png.extractBytecode(gpa, file_data) catch |err| {
                std.debug.print("Error: failed to extract bytecode: {}\n", .{err});
                return null;
            };
        },
        // FLAC has no legacy chunks to find (every payload rides a pNGx
        // APPLICATION block, 02:129), so bare extract has nothing to carve;
        // --kind is the FLAC route.
        .flac => {
            std.debug.print("Error: '{s}' is a FLAC file; use extract --kind KIND for its payloads\n", .{stdio.displayName(input)});
            return null;
        },
        .pngb, .sjon => {
            std.debug.print("Error: '{s}' is not a valid PNG or ZIP file\n", .{stdio.displayName(input)});
            return null;
        },
    };

    if (bytecode.len < format.HEADER_SIZE or !std.mem.eql(u8, bytecode[0..4], format.MAGIC)) {
        std.debug.print("Error: extracted data is not valid PNGB\n", .{});
        gpa.free(bytecode);
        return null;
    }
    return bytecode;
}

/// `pngine extract --list`: dump the PNGine ancillary-chunk inventory of a PNG —
/// the read-side counterpart to the `embed*` writers (A7). PNG-only (a ZIP bundle
/// has no chunk namespace); writes no output file.
fn runExtractList(gpa: Allocator, io: std.Io, input: []const u8) !u8 {
    const in = stdio.readInput(gpa, io, input) catch |err| return stdio.reportReadError(err, input);
    defer in.deinit(gpa);
    const file_data = in.bytes;

    if (in.kind != .png) {
        std.debug.print("Error: '{s}' is not a PNG file (--list inspects PNG chunks)\n", .{stdio.displayName(input)});
        return 4;
    }

    const chunks = pngine.png.enumerateChunks(gpa, file_data) catch |err| {
        std.debug.print("Error: failed to enumerate chunks in '{s}': {}\n", .{ stdio.displayName(input), err });
        return 4;
    };
    defer gpa.free(chunks);

    if (chunks.len == 0) {
        std.debug.print("{s}: no PNGine (pNG*) chunks\n", .{stdio.displayName(input)});
        return 0;
    }

    std.debug.print("{s}: {d} PNGine chunk(s)\n", .{ stdio.displayName(input), chunks.len });
    for (chunks) |c| {
        const ver: i32 = if (c.version) |v| v else -1;
        std.debug.print("  {s}  {d} bytes on wire, {d}-byte payload, v{d}{s} — {s}\n", .{
            c.chunk_type,
            c.total_size,
            c.payload_size,
            ver,
            if (c.isCompressed()) " compressed" else "",
            chunkRole(c.chunk_type),
        });
    }
    return 0;
}

/// A one-line human label for a PNGine chunk family (its `pNG<letter>` tail).
/// Documents intended CONSUMER so the listing shows why a chunk exists —
/// mirrors the taxonomy in docs/architecture.md.
fn chunkRole(chunk_type: [4]u8) []const u8 {
    return switch (chunk_type[3]) {
        'b' => "bytecode (PNGB)",
        'm' => "animation metadata (JSON; JS runtime)",
        'a' => "audio WASM (JS runtime)",
        'f' => "flat command buffer (mini viewer)",
        'w' => "WGSL source (--html compression)",
        'x' => "payload envelope (any kind)",
        else => "unknown PNGine chunk",
    };
}

/// `pngine extract --kind KIND [--nth n] -o out`: one payload, decompressed
/// (02:109). PNG and FLAC input; a ZIP bundle has no payload chunks.
fn runExtractKind(
    gpa: Allocator,
    io: std.Io,
    input: []const u8,
    kind_arg: []const u8,
    nth: usize,
    output_path: ?[]const u8,
) !u8 {
    if (kind_arg.len != 4) {
        std.debug.print("Error: --kind takes a 4-character tag, got '{s}'\n", .{kind_arg});
        return 1;
    }

    const in = stdio.readInput(gpa, io, input) catch |err| return stdio.reportReadError(err, input);
    defer in.deinit(gpa);

    if (in.kind != .png and in.kind != .flac) {
        std.debug.print("Error: --kind reads PNG and FLAC payloads; '{s}' is neither\n", .{stdio.displayName(input)});
        return 4;
    }

    const kind: [4]u8 = kind_arg[0..4].*;
    var seen: usize = 0;
    var outcome: ?u8 = null;
    if (in.kind == .png) {
        var walk = pngine.png.walkPng(gpa, in.bytes) catch |err| {
            std.debug.print("Error: failed to walk '{s}': {}\n", .{ stdio.displayName(input), err });
            return 4;
        };
        defer walk.deinit(gpa);
        for (walk.payloads) |p| {
            if (!std.mem.eql(u8, &p.kind, &kind)) continue;
            seen += 1;
            if (seen != nth) continue;
            outcome = try writeSelectedPayload(gpa, io, input, output_path, kind_arg, p.flags, p.body);
            break;
        }
    } else {
        var walk = pngine.flac.walkFlac(gpa, in.bytes) catch |err| {
            std.debug.print("Error: failed to walk '{s}': {}\n", .{ stdio.displayName(input), err });
            return 4;
        };
        defer walk.deinit(gpa);
        for (walk.payloads) |p| {
            if (!std.mem.eql(u8, &p.kind, &kind)) continue;
            seen += 1;
            if (seen != nth) continue;
            outcome = try writeSelectedPayload(gpa, io, input, output_path, kind_arg, p.flags, p.body);
            break;
        }
    }
    if (outcome) |code| return code;

    if (seen == 0) {
        std.debug.print("Error: '{s}' carries no {s} payload\n", .{ stdio.displayName(input), kind_arg });
    } else {
        std.debug.print("Error: '{s}' carries only {d} {s} payload(s), --nth {d} is past them\n", .{ stdio.displayName(input), seen, kind_arg, nth });
    }
    return 4;
}

/// Write the one selected payload: decompressed when its flag bit says raw
/// DEFLATE (the consumer's half of the walker's contract, after any
/// concatenation the walker already did), through the same output policy as
/// every artifact. Shared by the PNG and FLAC branches of runExtractKind.
fn writeSelectedPayload(
    gpa: Allocator,
    io: std.Io,
    input: []const u8,
    output_path: ?[]const u8,
    kind_arg: []const u8,
    flags: u8,
    stored: []const u8,
) !u8 {
    const body: []u8 = if (flags & pngine.payload.envelope.FLAG_COMPRESSED != 0)
        pngine.png.inflatePayload(gpa, stored) catch {
            std.debug.print("Error: failed to decompress the {s} payload\n", .{kind_arg});
            return 4;
        }
    else
        gpa.dupe(u8, stored) catch return 2;
    defer gpa.free(body);

    // Piped input defaults to stdout, the same convention as the
    // bytecode path above.
    const dest: stdio.Output = if (output_path) |o|
        .borrowed(o)
    else if (stdio.isStd(input))
        .borrowed(stdio.std_path)
    else
        .owned(utils.deriveSiblingPath(gpa, input, ".payload") catch {
            std.debug.print("Error: failed to derive output path\n", .{});
            return 2;
        });
    defer dest.deinit(gpa);

    // A zero-length body is a legal empty payload (02:12): an empty
    // artifact, written through the same output policy (file create or
    // truncate, the stdout binary-to-TTY refusal) rather than bypassing
    // it.
    if (body.len == 0) {
        stdio.writeEmptyOutput(io, dest.path, true) catch |err| return stdio.reportWriteError(err, dest.path);
    } else {
        stdio.writeOutput(io, dest.path, body, true) catch |err| return stdio.reportWriteError(err, dest.path);
    }
    std.debug.print("Extracted {s} payload -> {s} ({d} bytes)\n", .{ kind_arg, stdio.outName(dest.path), body.len });
    return 0;
}

/// `pngine pack <in.png> --add KIND=path[,raw] ... -o out` (02:107): append
/// payloads to a PNG — the one writer (packPng) behind every --add.
pub fn runPack(gpa: Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (arg_reader.wantsHelp(args)) return arg_reader.printHelp(pack_usage);

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var adds: std.ArrayList([]const u8) = .empty;
    defer adds.deinit(gpa);

    var reader = arg_reader.ArgReader.init(args);
    while (reader.next()) |arg| {
        if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--add")) {
            const value = reader.value() catch return arg_reader.missingValue(arg);
            adds.append(gpa, value) catch return 2;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_path = reader.value() catch return arg_reader.missingValue(arg);
        } else if (arg_reader.ArgReader.isFlag(arg)) {
            return arg_reader.unknownOption(arg);
        } else {
            reader.addPositional(arg) catch return arg_reader.duplicateInput();
        }
    }
    input_path = reader.positional;

    if (input_path == null) {
        std.debug.print("Error: no input file specified\n\n", .{});
        std.debug.print("Usage: pngine pack <in.png|in.flac|-> --add KIND=path[,raw] ... [-o out]\n", .{});
        return 1;
    }
    const input = input_path.?;

    if (adds.items.len == 0) {
        std.debug.print("Error: pack needs at least one --add KIND=path[,raw]\n\n", .{});
        return 1;
    }
    if (adds.items.len > pngine.png.embed.MAX_EMBED_CHUNKS) {
        std.debug.print("Error: at most {d} payloads per pack, got {d}\n", .{ pngine.png.embed.MAX_EMBED_CHUNKS, adds.items.len });
        return 1;
    }

    // Read the base container first so its kind is checked before any
    // payload read. PNG and FLAC both pack (02.C3); the kind decides the
    // writer and the default output suffix below.
    const in = stdio.readInput(gpa, io, input) catch |err| return stdio.reportReadError(err, input);
    defer in.deinit(gpa);
    if (in.kind != .png and in.kind != .flac) {
        std.debug.print("Error: '{s}' is not a PNG or FLAC file\n", .{stdio.displayName(input)});
        return 4;
    }

    // --add KIND=path[,raw]: split the kind, then the path, then the modifier.
    var specs: [pngine.png.embed.MAX_EMBED_CHUNKS]pngine.png.PackSpec = undefined;
    var flac_specs: [pngine.png.embed.MAX_EMBED_CHUNKS]pngine.flac.PackSpec = undefined;
    var payloads: [pngine.png.embed.MAX_EMBED_CHUNKS][]u8 = undefined;
    var n: usize = 0;
    defer for (payloads[0..n]) |p| gpa.free(p);

    var stdin_used = stdio.isStd(input);
    for (adds.items) |add| {
        const eq = std.mem.indexOfScalar(u8, add, '=') orelse {
            std.debug.print("Error: --add takes KIND=path[,raw], got '{s}'\n", .{add});
            return 1;
        };
        const kind_arg = add[0..eq];
        const rest = add[eq + 1 ..];
        if (kind_arg.len != 4) {
            std.debug.print("Error: KIND is a 4-character tag, got '{s}'\n", .{kind_arg});
            return 1;
        }
        // `,raw` is the one modifier (02:107); a comma that does not spell
        // it is part of the path.
        var path = rest;
        var raw = false;
        if (std.mem.endsWith(u8, rest, ",raw")) {
            path = rest[0 .. rest.len - 4];
            raw = true;
        }

        // An empty rest, or one that was exactly `,raw`, leaves the path
        // empty; letting it through would reach readPayloadBytes' empty-path
        // assert and panic on a user flag, where every neighbouring bad input
        // gets a clean code.
        if (path.len == 0) {
            std.debug.print("Error: --add KIND=path[,raw] needs a non-empty path, got '{s}'\n", .{add});
            return 1;
        }

        if (stdio.isStd(path)) {
            if (stdin_used) {
                std.debug.print("Error: only one input per command may be `-` (stdin)\n", .{});
                return 1;
            }
            stdin_used = true;
        }

        // A payload is any bytes: no extension gate, no sniff (02:107). The
        // sentinel-terminated type stays: freeing it as a plain slice would
        // drop the sentinel byte from the size the allocator expects.
        const payload_bytes = stdio.readPayloadBytes(gpa, io, path) catch |err| return stdio.reportReadError(err, path);
        defer gpa.free(payload_bytes);
        // An empty payload is legal (02:12: eight bytes, then the body, no
        // minimum): it packs like any other, DEFLATE'd to `03 00` by default
        // or stored as zero bytes with `,raw`.

        // The bytes must outlive the loop iteration's free above.
        payloads[n] = gpa.dupe(u8, payload_bytes) catch return 2;
        specs[n] = .{
            .kind = kind_arg[0..4].*,
            .body = payloads[n],
            .raw = raw,
        };
        // The FLAC PackSpec carries the same fields; both are filled from
        // the one parse so the two writers cannot disagree about an --add.
        flac_specs[n] = .{
            .kind = kind_arg[0..4].*,
            .body = payloads[n],
            .raw = raw,
        };
        n += 1;
    }

    const packed_out = if (in.kind == .png)
        pngine.png.packPng(gpa, in.bytes, specs[0..n]) catch |err| {
            std.debug.print("Error: failed to pack payloads: {}\n", .{err});
            return 4;
        }
    else
        pngine.flac.packFlac(gpa, in.bytes, flac_specs[0..n]) catch |err| {
            std.debug.print("Error: failed to pack payloads: {}\n", .{err});
            return 4;
        };
    defer gpa.free(packed_out);

    const packed_suffix: []const u8 = if (in.kind == .png) "_packed.png" else "_packed.flac";
    const dest: stdio.Output = if (output_path) |o|
        .borrowed(o)
    else if (stdio.isStd(input))
        .borrowed(stdio.std_path)
    else
        .owned(utils.deriveSiblingPath(gpa, input, packed_suffix) catch {
            std.debug.print("Error: failed to derive output path\n", .{});
            return 2;
        });
    defer dest.deinit(gpa);

    stdio.writeOutput(io, dest.path, packed_out, true) catch |err| return stdio.reportWriteError(err, dest.path);
    std.debug.print("Packed {d} payload(s) into {s} ({d} bytes)\n", .{ n, stdio.outName(dest.path), packed_out.len });
    return 0;
}

/// The carrier column of `ls` (02:108): `pNGb` plain, `pNGx` numbered.
/// Takes a pointer: the plain-letter branch returns a view of the carrier's
/// own bytes, which a by-value parameter would dangle.
fn carrierLabel(buf: []u8, carrier: *const pngine.png.WalkCarrier) []const u8 {
    if (std.mem.eql(u8, &carrier.chunk_type, "pNGx")) {
        return std.fmt.bufPrint(buf, "pNGx#{d}", .{carrier.nth}) catch "pNGx";
    }
    return carrier.chunk_type[0..];
}

/// The stored size of a payload: its body plus the header bytes each of its
/// carriers put ahead of it. The walker accumulates `stored_overhead` per
/// part (8 for a pNGx envelope, 2 for the legacy letters, 1 for pNGm), so a
/// chain counts every carrier, not only the first one.
fn storedSize(p: pngine.png.WalkPayload) usize {
    return p.body.len + p.stored_overhead;
}

fn skipReasonText(reason: pngine.png.WalkSkipReason) []const u8 {
    return switch (reason) {
        .unreadable_flags => "unreadable flags",
        .nonzero_reserved => "nonzero reserved u16",
        .truncated => "truncated envelope",
        .dangling_continued => "dangling continued chain",
        .unknown_letter => "unknown family letter",
    };
}

/// The FLAC carrier column of `ls` (02:108): `APPLICATION#1` for pNGx
/// blocks, `PICTURE→pNGf` / `PICTURE→pNGx#2` for a picture's nested chunks,
/// `PICTURE` for the block itself.
fn flacCarrierLabel(buf: []u8, carrier: pngine.flac.WalkCarrier) []const u8 {
    switch (carrier) {
        .application => |nth| return std.fmt.bufPrint(buf, "APPLICATION#{d}", .{nth}) catch "APPLICATION",
        .picture => |pic| {
            if (std.mem.eql(u8, &pic.chunk_type, "pNGx")) {
                return std.fmt.bufPrint(buf, "PICTURE\u{2192}pNGx#{d}", .{pic.nth}) catch "PICTURE";
            }
            return std.fmt.bufPrint(buf, "PICTURE\u{2192}{s}", .{pic.chunk_type}) catch "PICTURE";
        },
        .picture_block => return "PICTURE",
    }
}

fn flacSkipReasonText(reason: pngine.flac.WalkSkipReason) []const u8 {
    return switch (reason) {
        .unreadable_flags => "unreadable flags",
        .nonzero_reserved => "nonzero reserved u16",
        .truncated => "truncated envelope",
        .dangling_continued => "dangling continued chain",
        .unknown_letter => "unknown family letter",
        .malformed_picture => "malformed PICTURE block",
    };
}

/// `pngine ls <file>` (02:108): one row per payload — kind, version, flags,
/// body size, stored size, carrier — and one skip row per chunk that carries
/// no payload, so the inventory never silently drops anything. The
/// generalization of `extract --list` through walkPng, and through walkFlac
/// for a FLAC (02.C3).
pub fn runLs(gpa: Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (arg_reader.wantsHelp(args)) return arg_reader.printHelp(ls_usage);

    var input_path: ?[]const u8 = null;
    var reader = arg_reader.ArgReader.init(args);
    while (reader.next()) |arg| {
        if (arg_reader.ArgReader.isFlag(arg)) {
            return arg_reader.unknownOption(arg);
        } else {
            reader.addPositional(arg) catch return arg_reader.duplicateInput();
        }
    }
    input_path = reader.positional;

    const input = input_path orelse {
        std.debug.print("Error: no input file specified\n\n", .{});
        std.debug.print("Usage: pngine ls <file.png|file.flac|->\n", .{});
        return 1;
    };

    const in = stdio.readInput(gpa, io, input) catch |err| return stdio.reportReadError(err, input);
    defer in.deinit(gpa);

    if (in.kind != .png and in.kind != .flac) {
        std.debug.print("Error: '{s}' is not a PNG or FLAC file (ls lists payloads)\n", .{stdio.displayName(input)});
        return 4;
    }

    if (in.kind == .png) {
        var walk = pngine.png.walkPng(gpa, in.bytes) catch |err| {
            std.debug.print("Error: failed to walk '{s}': {}\n", .{ stdio.displayName(input), err });
            return 4;
        };
        defer walk.deinit(gpa);

        if (walk.payloads.len == 0 and walk.skipped.len == 0) {
            std.debug.print("{s}: no payloads\n", .{stdio.displayName(input)});
            return 0;
        }

        std.debug.print("{s}: {d} payload(s)\n", .{ stdio.displayName(input), walk.payloads.len });
        for (walk.payloads) |p| {
            var carrier_buf: [16]u8 = undefined;
            std.debug.print("  {s}  v{d}  flags 0x{X:0>2}  body {d}  stored {d}  carrier {s}\n", .{
                p.kind, p.version, p.flags, p.body.len, storedSize(p), carrierLabel(&carrier_buf, &p.carrier),
            });
        }
        for (walk.skipped) |s| {
            var carrier_buf: [16]u8 = undefined;
            std.debug.print("  skip  {s}  {s}  carrier {s}\n", .{
                s.kind, skipReasonText(s.reason), carrierLabel(&carrier_buf, &s.carrier),
            });
        }
        return 0;
    }

    var walk = pngine.flac.walkFlac(gpa, in.bytes) catch |err| {
        std.debug.print("Error: failed to walk '{s}': {}\n", .{ stdio.displayName(input), err });
        return 4;
    };
    defer walk.deinit(gpa);

    if (walk.payloads.len == 0 and walk.skipped.len == 0) {
        std.debug.print("{s}: no payloads\n", .{stdio.displayName(input)});
        return 0;
    }

    std.debug.print("{s}: {d} payload(s)\n", .{ stdio.displayName(input), walk.payloads.len });
    for (walk.payloads) |p| {
        var carrier_buf: [24]u8 = undefined;
        std.debug.print("  {s}  v{d}  flags 0x{X:0>2}  body {d}  stored {d}  carrier {s}\n", .{
            p.kind, p.version, p.flags, p.body.len, p.body.len + p.stored_overhead, flacCarrierLabel(&carrier_buf, p.carrier),
        });
    }
    for (walk.skipped) |s| {
        var carrier_buf: [24]u8 = undefined;
        std.debug.print("  skip  {s}  {s}  carrier {s}\n", .{
            s.kind, flacSkipReasonText(s.reason), flacCarrierLabel(&carrier_buf, s.carrier),
        });
    }
    return 0;
}
