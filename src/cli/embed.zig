//! Embed and extract commands: embed/extract bytecode from PNG files.
//!
//! Usage:
//!   pngine embed <image.png> <bytecode.pngb> [-o output.png]
//!   pngine extract <input.png|input.zip> [-o output.pngb]
//!   pngine extract <input.png> --list   (dump the pNG* chunk inventory)

const std = @import("std");
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
    \\Usage: pngine extract <file.png|file.zip|-> [options]
    \\
    \\Options:
    \\  -o, --output <path>    Output .pngb path (default: <input>.pngb; stdout if
    \\                         the input is `-`). Use `-` to write stdout.
    \\  -l, --list             List every PNGine ancillary chunk in the file
    \\  -h, --help             Show this help
    \\
;

/// Execute the embed command.
pub fn runEmbed(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
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
        .owned(utils.deriveEmbedOutputPath(allocator, parsed.png_path) catch |err| {
            std.debug.print("Error: failed to derive output path: {}\n", .{err});
            return 2;
        });
    defer dest.deinit(allocator);

    return executeEmbed(allocator, io, parsed.png_path, parsed.pngb_path, dest.path);
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

fn executeEmbed(allocator: std.mem.Allocator, io: std.Io, png_input: []const u8, pngb_input: []const u8, output: []const u8) u8 {
    std.debug.assert(png_input.len > 0);
    std.debug.assert(pngb_input.len > 0);

    const png_in = stdio.readInput(allocator, io, png_input) catch |err| return stdio.reportReadError(err, png_input);
    defer png_in.deinit(allocator);
    const png_data = png_in.bytes;

    const pngb_in = stdio.readInput(allocator, io, pngb_input) catch |err| return stdio.reportReadError(err, pngb_input);
    defer pngb_in.deinit(allocator);
    const bytecode = pngb_in.bytes;

    if (png_in.kind != .png) {
        std.debug.print("Error: '{s}' is not a PNG file\n", .{stdio.displayName(png_input)});
        return 4;
    }

    if (bytecode.len < format.HEADER_SIZE or !std.mem.eql(u8, bytecode[0..4], format.MAGIC)) {
        std.debug.print("Error: '{s}' is not a valid PNGB file\n", .{stdio.displayName(pngb_input)});
        return 4;
    }

    const embedded = pngine.png.embedBytecode(allocator, png_data, bytecode) catch |err| {
        std.debug.print("Error: failed to embed bytecode: {}\n", .{err});
        return 4;
    };
    defer allocator.free(embedded);

    stdio.writeOutput(io, output, embedded, true) catch |err| return stdio.reportWriteError(err, output);

    std.debug.print("Embedded {s} ({d} bytes) into {s} -> {s} ({d} bytes)\n", .{
        stdio.displayName(pngb_input), bytecode.len, stdio.displayName(png_input), stdio.outName(output), embedded.len,
    });

    return 0;
}

/// Execute the extract command.
pub fn runExtract(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (arg_reader.wantsHelp(args)) return arg_reader.printHelp(extract_usage);

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var list_chunks = false;

    var reader = arg_reader.ArgReader.init(args);
    while (reader.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_path = reader.value() catch return arg_reader.missingValue(arg);
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
            list_chunks = true;
        } else if (arg_reader.ArgReader.isFlag(arg)) {
            return arg_reader.unknownOption(arg);
        } else {
            reader.addPositional(arg) catch return arg_reader.duplicateInput();
        }
    }
    input_path = reader.positional;

    if (input_path == null) {
        std.debug.print("Error: no input file specified\n\n", .{});
        std.debug.print("Usage: pngine extract <file.png|file.zip|-> [-o output.pngb|-] [--list]\n", .{});
        return 1;
    }

    const input = input_path.?;

    // `--list`: enumerate every PNGine ancillary chunk (pNGb/pNGm/pNGa/pNGf/…)
    // the file carries — the read-side inventory of whatever `embed` wrote (A7).
    // A diagnostic dump; writes no output file.
    if (list_chunks) return runExtractList(allocator, io, input);

    // Piped input has no name to derive an output from, so it defaults to
    // stdout — which is what makes `pngine extract - | pngine inspect -` work
    // without a `-o -` on every stage.
    const dest: stdio.Output = if (output_path) |p|
        .borrowed(p)
    else if (stdio.isStd(input))
        .borrowed(stdio.std_path)
    else
        .owned(utils.deriveExtractOutputPath(allocator, input) catch |err| {
            std.debug.print("Error: failed to derive output path: {}\n", .{err});
            return 2;
        });
    defer dest.deinit(allocator);
    const output = dest.path;

    const in = stdio.readInput(allocator, io, input) catch |err| return stdio.reportReadError(err, input);
    defer in.deinit(allocator);
    const file_data = in.bytes;

    const bytecode = carvedBytecode(allocator, in.kind, file_data, input) orelse return 4;
    defer allocator.free(bytecode);

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
    allocator: std.mem.Allocator,
    kind: stdio.Kind,
    file_data: []const u8,
    input: []const u8,
) ?[]u8 {
    std.debug.assert(input.len > 0);

    const bytecode = switch (kind) {
        .zip => bundle.extractFromZip(allocator, file_data) catch |err| {
            std.debug.print("Error: failed to extract from ZIP: {}\n", .{err});
            return null;
        },
        .png => blk: {
            if (!pngine.png.hasPngb(file_data)) {
                std.debug.print("Error: '{s}' has no embedded bytecode (missing pNGb chunk)\n", .{stdio.displayName(input)});
                return null;
            }
            break :blk pngine.png.extractBytecode(allocator, file_data) catch |err| {
                std.debug.print("Error: failed to extract bytecode: {}\n", .{err});
                return null;
            };
        },
        .pngb, .sjon => {
            std.debug.print("Error: '{s}' is not a valid PNG or ZIP file\n", .{stdio.displayName(input)});
            return null;
        },
    };

    if (bytecode.len < format.HEADER_SIZE or !std.mem.eql(u8, bytecode[0..4], format.MAGIC)) {
        std.debug.print("Error: extracted data is not valid PNGB\n", .{});
        allocator.free(bytecode);
        return null;
    }
    return bytecode;
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
        else => "unknown PNGine chunk",
    };
}

/// `pngine extract --list`: dump the PNGine ancillary-chunk inventory of a PNG —
/// the read-side counterpart to the `embed*` writers (A7). PNG-only (a ZIP bundle
/// has no chunk namespace); writes no output file.
fn runExtractList(allocator: std.mem.Allocator, io: std.Io, input: []const u8) !u8 {
    const in = stdio.readInput(allocator, io, input) catch |err| return stdio.reportReadError(err, input);
    defer in.deinit(allocator);
    const file_data = in.bytes;

    if (in.kind != .png) {
        std.debug.print("Error: '{s}' is not a PNG file (--list inspects PNG chunks)\n", .{stdio.displayName(input)});
        return 4;
    }

    const chunks = pngine.png.enumerateChunks(allocator, file_data) catch |err| {
        std.debug.print("Error: failed to enumerate chunks in '{s}': {}\n", .{ stdio.displayName(input), err });
        return 4;
    };
    defer allocator.free(chunks);

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
