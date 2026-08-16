//! Bundle and list commands: create/inspect ZIP bundles.
//!
//! Usage:
//!   pngine bundle <input> [-o output.zip] [--assets dir] [--no-runtime]
//!   pngine list <file.zip|file.png>

const std = @import("std");
const pngine = @import("pngine");
const zip = pngine.zip;
const utils = @import("utils.zig");
const stdio = @import("stdio.zig");
const arg_reader = @import("arg_reader.zig");
const compile = @import("compile.zig");
const build_options = @import("build_options");
const embedded_wasm: []const u8 = if (build_options.has_embedded_wasm) @embedFile("embedded_wasm") else &.{};

pub const bundle_usage =
    \\pngine bundle - Package a shader and its assets into a ZIP bundle
    \\
    \\Usage: pngine bundle <input.sjon|-> [options]
    \\
    \\Options:
    \\  -o, --output <path>    Output .zip path (default: <input>.zip)
    \\      --assets <dir>     Directory of extra assets to include
    \\      --no-runtime       Omit the JS runtime from the bundle
    \\  -h, --help             Show this help
    \\
;

pub const list_usage =
    \\pngine list - List the contents of a ZIP bundle or PNG
    \\
    \\Usage: pngine list <file.zip|file.png|->
    \\
    \\Options:
    \\  -h, --help             Show this help
    \\
;

/// Bundle command options parsed from CLI arguments.
const Options = struct {
    input_path: []const u8 = "",
    output_path: ?[]const u8 = null,
    assets_dir: ?[]const u8 = null,
    include_runtime: bool = true,
};

/// The assembled ZIP, or the exit code that stopped it.
///
/// Same shape as render.zig's `PngResult`: `data` is only valid when
/// `exit_code` is 0, because every failure here has already printed its own
/// message and only needs to carry the code out.
const ZipResult = struct {
    data: []u8,
    assets_count: u32,
    exit_code: u8,
};

/// Execute the bundle command.
pub fn runBundle(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (arg_reader.wantsHelp(args)) return arg_reader.printHelp(bundle_usage);

    var opts = Options{};
    const parse_result = parseArgs(args, &opts);
    if (parse_result != 0) return parse_result;
    std.debug.assert(opts.input_path.len > 0);

    const input = opts.input_path;
    const dest: stdio.Output = if (opts.output_path) |p|
        .borrowed(p)
    else if (stdio.isStd(input))
        .borrowed(stdio.std_path)
    else
        .owned(utils.deriveBundleOutputPath(allocator, input) catch |err| {
            std.debug.print("Error: failed to derive output path: {}\n", .{err});
            return 2;
        });
    defer dest.deinit(allocator);
    const output = dest.path;

    const in = stdio.readInput(allocator, io, input) catch |err| return stdio.reportReadError(err, input);
    defer in.deinit(allocator);
    if (in.kind != .sjon) {
        std.debug.print("Error: bundle expects SJON source, got {t} ({s})\n", .{ in.kind, stdio.displayName(input) });
        return 4;
    }

    const bytecode = compile.compileSource(allocator, io, input, in.bytes) catch |err| {
        std.debug.print("Error: compilation failed: {}\n", .{err});
        return 3;
    };
    defer allocator.free(bytecode);

    const zip_result = buildBundle(allocator, io, bytecode, opts);
    if (zip_result.exit_code != 0) return zip_result.exit_code;
    defer allocator.free(zip_result.data);

    stdio.writeOutput(io, output, zip_result.data, true) catch |err| return stdio.reportWriteError(err, output);

    if (zip_result.assets_count > 0) {
        std.debug.print("Bundled {s} -> {s} ({d} bytes, {d} assets)\n", .{ stdio.displayName(input), stdio.outName(output), zip_result.data.len, zip_result.assets_count });
    } else {
        std.debug.print("Bundled {s} -> {s} ({d} bytes)\n", .{ stdio.displayName(input), stdio.outName(output), zip_result.data.len });
    }
    return 0;
}

/// Parse bundle command arguments.
///
/// Returns 0 on success, >0 on error (the message is already printed).
fn parseArgs(args: []const []const u8, opts: *Options) u8 {
    std.debug.assert(opts.input_path.len == 0);
    std.debug.assert(opts.include_runtime);

    var reader = arg_reader.ArgReader.init(args);
    while (reader.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            opts.output_path = reader.value() catch return arg_reader.missingValue(arg);
        } else if (std.mem.eql(u8, arg, "--assets")) {
            opts.assets_dir = reader.value() catch return arg_reader.missingValue(arg);
        } else if (std.mem.eql(u8, arg, "--no-runtime")) {
            opts.include_runtime = false;
        } else if (arg_reader.ArgReader.isFlag(arg)) {
            return arg_reader.unknownOption(arg);
        } else {
            reader.addPositional(arg) catch return arg_reader.duplicateInput();
        }
    }

    if (reader.positional == null) {
        std.debug.print("Error: no input file specified\n\n", .{});
        std.debug.print("Usage: pngine bundle <input.sjon|-> [-o output.zip|-] [--assets dir]\n", .{});
        return 1;
    }
    opts.input_path = reader.positional.?;

    std.debug.assert(opts.input_path.len > 0);
    return 0;
}

/// Assemble the bundle ZIP: manifest, bytecode, optional assets, optional runtime.
fn buildBundle(
    allocator: std.mem.Allocator,
    io: std.Io,
    bytecode: []const u8,
    opts: Options,
) ZipResult {
    std.debug.assert(bytecode.len > 0);

    var writer = zip.ZipWriter.init(allocator);
    defer writer.deinit();

    const manifest = if (opts.include_runtime)
        "{\"version\":1,\"entry\":\"main.pngb\",\"runtime\":\"pngine.wasm\"}"
    else
        "{\"version\":1,\"entry\":\"main.pngb\"}";

    writer.addFile("manifest.json", manifest, .store) catch |err| {
        std.debug.print("Error: failed to add manifest: {}\n", .{err});
        return .{ .data = undefined, .assets_count = 0, .exit_code = 4 };
    };

    writer.addFile("main.pngb", bytecode, .deflate) catch |err| {
        std.debug.print("Error: failed to add bytecode: {}\n", .{err});
        return .{ .data = undefined, .assets_count = 0, .exit_code = 4 };
    };

    var assets_count: u32 = 0;
    if (opts.assets_dir) |dir_path| {
        assets_count = addAssetsFromDir(allocator, io, &writer, dir_path) catch |err| {
            std.debug.print("Error: {}\n", .{err});
            return .{ .data = undefined, .assets_count = 0, .exit_code = 2 };
        };
    }

    if (opts.include_runtime) {
        if (embedded_wasm.len > 0) {
            writer.addFile("pngine.wasm", embedded_wasm, .store) catch |err| {
                std.debug.print("Error: failed to add WASM runtime: {}\n", .{err});
                return .{ .data = undefined, .assets_count = 0, .exit_code = 4 };
            };
        } else {
            std.debug.print("Warning: WASM runtime not available in this build\n", .{});
        }
    }

    const zip_data = writer.finish() catch |err| {
        std.debug.print("Error: failed to create ZIP: {}\n", .{err});
        return .{ .data = undefined, .assets_count = 0, .exit_code = 4 };
    };

    std.debug.assert(zip_data.len > 0);
    return .{ .data = zip_data, .assets_count = assets_count, .exit_code = 0 };
}

fn addAssetsFromDir(allocator: std.mem.Allocator, io: std.Io, writer: *zip.ZipWriter, dir_path: []const u8) !u32 {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        return error.FailedToOpenAssetsDir;
    };
    defer dir.close(io);

    var walker = dir.walk(allocator) catch {
        return error.FailedToWalkAssetsDir;
    };
    defer walker.deinit();

    var count: u32 = 0;
    for (0..10000) |_| {
        const entry = walker.next(io) catch {
            return error.FailedToIterateAssets;
        };

        if (entry) |e| {
            if (e.kind == .file) {
                const asset_path = std.fmt.allocPrint(allocator, "assets/{s}", .{e.path}) catch {
                    return error.OutOfMemory;
                };
                defer allocator.free(asset_path);

                const content = dir.readFileAlloc(io, e.path, allocator, .limited(10 * 1024 * 1024)) catch {
                    return error.FailedToReadAsset;
                };
                defer allocator.free(content);

                const method: zip.CompressionMethod = if (isCompressedExtension(e.basename)) .store else .deflate;
                writer.addFile(asset_path, content, method) catch {
                    return error.FailedToAddAsset;
                };
                count += 1;
            }
        } else break;
    }
    return count;
}

/// Execute the list command.
pub fn runList(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (arg_reader.wantsHelp(args)) return arg_reader.printHelp(list_usage);

    if (args.len == 0) {
        std.debug.print("Error: no input file specified\n\n", .{});
        std.debug.print("Usage: pngine list <file.zip|file.png|->\n", .{});
        return 1;
    }

    const input = args[0];
    const in = stdio.readInput(allocator, io, input) catch |err| return stdio.reportReadError(err, input);
    defer in.deinit(allocator);

    return switch (in.kind) {
        .zip => listZipContents(allocator, stdio.displayName(input), in.bytes),
        .png => listPngContents(stdio.displayName(input), in.bytes),
        .pngb, .sjon => {
            std.debug.print("Error: '{s}' is not a ZIP or PNG file\n", .{stdio.displayName(input)});
            return 4;
        },
    };
}

fn listZipContents(allocator: std.mem.Allocator, input: []const u8, data: []const u8) u8 {
    var reader = zip.ZipReader.init(allocator, data) catch |err| {
        std.debug.print("Error: failed to read ZIP: {}\n", .{err});
        return 4;
    };
    defer reader.deinit();

    const entries = reader.getEntries();
    std.debug.print("ZIP: {s}\n  {d} file(s)\n\n", .{ input, entries.len });

    if (entries.len == 0) {
        std.debug.print("  (empty archive)\n", .{});
        return 0;
    }

    std.debug.print("  {s:<40} {s:>12} {s:>12}\n", .{ "Name", "Compressed", "Size" });
    std.debug.print("  {s:-<40} {s:->12} {s:->12}\n", .{ "", "", "" });

    var total_compressed: u64 = 0;
    var total_uncompressed: u64 = 0;

    for (entries) |entry| {
        std.debug.print("  {s:<40} {d:>12} {d:>12}\n", .{ entry.filename, entry.compressed_size, entry.uncompressed_size });
        total_compressed += entry.compressed_size;
        total_uncompressed += entry.uncompressed_size;
    }

    std.debug.print("  {s:-<40} {s:->12} {s:->12}\n", .{ "", "", "" });
    std.debug.print("  {s:<40} {d:>12} {d:>12}\n", .{ "Total", total_compressed, total_uncompressed });
    return 0;
}

fn listPngContents(input: []const u8, data: []const u8) u8 {
    std.debug.print("PNG: {s}\n", .{input});

    if (pngine.png.hasPngb(data)) {
        const info = pngine.png.getPngbInfo(data) catch |err| {
            std.debug.print("  Error reading pNGb chunk: {}\n", .{err});
            return 4;
        };
        std.debug.print("  Embedded bytecode (pNGb): yes\n", .{});
        std.debug.print("    Version: {d}\n", .{info.version});
        std.debug.print("    Compressed: {s}\n", .{if (info.compressed) "yes" else "no"});
        std.debug.print("    Payload size: {d} bytes\n", .{info.payload_size});
    } else {
        std.debug.print("  Embedded bytecode (pNGb): no\n", .{});
    }

    return 0;
}

/// Check if file extension indicates already-compressed content.
pub fn isCompressedExtension(filename: []const u8) bool {
    const ext = std.fs.path.extension(filename);
    const compressed_exts = [_][]const u8{
        ".png",   ".jpg", ".jpeg", ".gif", ".webp",
        ".zip",   ".gz",  ".zst",  ".br",  ".xz",
        ".mp3",   ".mp4", ".webm", ".ogg", ".woff",
        ".woff2",
    };
    for (compressed_exts) |cext| {
        if (std.ascii.eqlIgnoreCase(ext, cext)) return true;
    }
    return false;
}

/// Extract bytecode from a ZIP bundle.
pub fn extractFromZip(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var reader = zip.ZipReader.init(allocator, data) catch {
        return error.InvalidZip;
    };
    defer reader.deinit();

    var entry_name_buf: [256]u8 = undefined;
    const entry_name: []const u8 = blk: {
        if (reader.extract("manifest.json")) |manifest_data| {
            defer allocator.free(manifest_data);
            if (findJsonValue(manifest_data, "\"entry\"")) |entry_value| {
                if (entry_value.len <= entry_name_buf.len) {
                    @memcpy(entry_name_buf[0..entry_value.len], entry_value);
                    break :blk entry_name_buf[0..entry_value.len];
                }
            }
        } else |_| {}
        break :blk "main.pngb";
    };

    return reader.extract(entry_name) catch {
        return error.FileNotFound;
    };
}

/// Find a JSON string value (simple parser for single field).
pub fn findJsonValue(data: []const u8, field: []const u8) ?[]const u8 {
    const field_start = std.mem.indexOf(u8, data, field) orelse return null;
    const after_field = field_start + field.len;

    var pos = after_field;
    while (pos < data.len and (data[pos] == ':' or data[pos] == ' ' or data[pos] == '"')) {
        pos += 1;
    }

    if (pos >= data.len) return null;

    if (pos > 0 and data[pos - 1] == '"') {
        const start = pos;
        while (pos < data.len and data[pos] != '"') {
            pos += 1;
        }
        return data[start..pos];
    }

    return null;
}

// ============================================================================
// Tests
// ============================================================================

// `bundle` was the last command still hand-rolling the option loop that
// `arg_reader` exists to own — a `skip_next` cursor, a per-flag `i + 1 >= len`
// guard, and its own duplicate-input and unknown-option branches. ArgReader's
// own tests cover the mechanics; these cover this command's flag set, which
// nothing did before.
