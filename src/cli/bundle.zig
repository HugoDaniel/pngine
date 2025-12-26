//! Bundle and list commands: create/inspect ZIP bundles.
//!
//! Usage:
//!   pngine bundle <input> [-o output.zip] [--assets dir] [--no-runtime]
//!   pngine list <file.zip|file.png>

const std = @import("std");
const pngine = @import("pngine");
const zip = pngine.zip;
const utils = @import("utils.zig");
const compile = @import("compile.zig");
const build_options = @import("build_options");
const embedded_wasm: []const u8 = @embedFile("embedded_wasm");

/// Execute the bundle command.
pub fn runBundle(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var assets_dir: ?[]const u8 = null;
    var include_runtime = true;

    const args_len: u32 = @intCast(args.len);
    var skip_next = false;
    for (0..args_len) |idx| {
        if (skip_next) {
            skip_next = false;
            continue;
        }
        const i: u32 = @intCast(idx);
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: -o requires an output path\n", .{});
                return 1;
            }
            output_path = args[i + 1];
            skip_next = true;
        } else if (std.mem.eql(u8, arg, "--assets")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: --assets requires a directory path\n", .{});
                return 1;
            }
            assets_dir = args[i + 1];
            skip_next = true;
        } else if (std.mem.eql(u8, arg, "--no-runtime")) {
            include_runtime = false;
        } else if (arg.len > 0 and arg[0] == '-') {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return 1;
        } else {
            if (input_path != null) {
                std.debug.print("Error: multiple input files specified\n", .{});
                return 1;
            }
            input_path = arg;
        }
    }

    if (input_path == null) {
        std.debug.print("Error: no input file specified\n\n", .{});
        std.debug.print("Usage: pngine bundle <input> [-o output.zip] [--assets dir]\n", .{});
        return 1;
    }

    const input = input_path.?;
    const output = output_path orelse utils.deriveBundleOutputPath(allocator, input) catch |err| {
        std.debug.print("Error: failed to derive output path: {}\n", .{err});
        return 2;
    };
    defer if (output_path == null) allocator.free(output);

    const source = utils.readSourceFile(allocator, input) catch |err| {
        std.debug.print("Error: failed to read '{s}': {}\n", .{ input, err });
        return 2;
    };
    defer allocator.free(source);

    const bytecode = compile.compileSource(allocator, input, source) catch |err| {
        std.debug.print("Error: compilation failed: {}\n", .{err});
        return 3;
    };
    defer allocator.free(bytecode);

    var writer = zip.ZipWriter.init(allocator);
    defer writer.deinit();

    const manifest = if (include_runtime)
        "{\"version\":1,\"entry\":\"main.pngb\",\"runtime\":\"pngine.wasm\"}"
    else
        "{\"version\":1,\"entry\":\"main.pngb\"}";

    writer.addFile("manifest.json", manifest, .store) catch |err| {
        std.debug.print("Error: failed to add manifest: {}\n", .{err});
        return 4;
    };

    writer.addFile("main.pngb", bytecode, .deflate) catch |err| {
        std.debug.print("Error: failed to add bytecode: {}\n", .{err});
        return 4;
    };

    var assets_count: u32 = 0;
    if (assets_dir) |dir_path| {
        assets_count = addAssetsFromDir(allocator, &writer, dir_path) catch |err| {
            std.debug.print("Error: {}\n", .{err});
            return 2;
        };
    }

    if (include_runtime) {
        if (embedded_wasm.len > 0) {
            writer.addFile("pngine.wasm", embedded_wasm, .store) catch |err| {
                std.debug.print("Error: failed to add WASM runtime: {}\n", .{err});
                return 4;
            };
        } else {
            std.debug.print("Warning: WASM runtime not available in this build\n", .{});
        }
    }

    const zip_data = writer.finish() catch |err| {
        std.debug.print("Error: failed to create ZIP: {}\n", .{err});
        return 4;
    };
    defer allocator.free(zip_data);

    utils.writeOutputFile(output, zip_data) catch |err| {
        std.debug.print("Error: failed to write '{s}': {}\n", .{ output, err });
        return 2;
    };

    if (assets_count > 0) {
        std.debug.print("Bundled {s} -> {s} ({d} bytes, {d} assets)\n", .{ input, output, zip_data.len, assets_count });
    } else {
        std.debug.print("Bundled {s} -> {s} ({d} bytes)\n", .{ input, output, zip_data.len });
    }
    return 0;
}

fn addAssetsFromDir(allocator: std.mem.Allocator, writer: *zip.ZipWriter, dir_path: []const u8) !u32 {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        return error.FailedToOpenAssetsDir;
    };
    defer dir.close();

    var walker = dir.walk(allocator) catch {
        return error.FailedToWalkAssetsDir;
    };
    defer walker.deinit();

    var count: u32 = 0;
    for (0..10000) |_| {
        const entry = walker.next() catch {
            return error.FailedToIterateAssets;
        };

        if (entry) |e| {
            if (e.kind == .file) {
                const asset_path = std.fmt.allocPrint(allocator, "assets/{s}", .{e.path}) catch {
                    return error.OutOfMemory;
                };
                defer allocator.free(asset_path);

                const content = dir.readFileAlloc(e.path, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch {
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
pub fn runList(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len == 0) {
        std.debug.print("Error: no input file specified\n\n", .{});
        std.debug.print("Usage: pngine list <file.zip|file.png>\n", .{});
        return 1;
    }

    const input = args[0];
    const data = utils.readBinaryFile(allocator, input) catch |err| {
        std.debug.print("Error: failed to read '{s}': {}\n", .{ input, err });
        return 2;
    };
    defer allocator.free(data);

    if (zip.isZip(data)) {
        return listZipContents(allocator, input, data);
    } else if (data.len >= 8 and std.mem.eql(u8, data[0..8], &pngine.png.PNG_SIGNATURE)) {
        return listPngContents(input, data);
    } else {
        std.debug.print("Error: '{s}' is not a ZIP or PNG file\n", .{input});
        return 4;
    }
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

    if (pngine.png.hasPngr(data)) {
        const info = pngine.png.getPngrInfo(data) catch |err| {
            std.debug.print("  Error reading pNGr chunk: {}\n", .{err});
            return 4;
        };
        std.debug.print("  Embedded runtime (pNGr): yes\n", .{});
        std.debug.print("    Version: {d}\n", .{info.version});
        std.debug.print("    Compressed: {s}\n", .{if (info.compressed) "yes" else "no"});
        std.debug.print("    Payload size: {d} bytes\n", .{info.payload_bytes});
    } else {
        std.debug.print("  Embedded runtime (pNGr): no\n", .{});
    }

    return 0;
}

/// Check if file extension indicates already-compressed content.
pub fn isCompressedExtension(filename: []const u8) bool {
    const ext = std.fs.path.extension(filename);
    const compressed_exts = [_][]const u8{
        ".png", ".jpg", ".jpeg", ".gif", ".webp",
        ".zip", ".gz", ".zst", ".br", ".xz",
        ".mp3", ".mp4", ".webm", ".ogg",
        ".woff", ".woff2",
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

test "isCompressedExtension: image formats" {
    try std.testing.expect(isCompressedExtension("test.png"));
    try std.testing.expect(isCompressedExtension("test.jpg"));
    try std.testing.expect(isCompressedExtension("test.PNG"));
}

test "isCompressedExtension: uncompressed formats return false" {
    try std.testing.expect(!isCompressedExtension("test.txt"));
    try std.testing.expect(!isCompressedExtension("test.json"));
    try std.testing.expect(!isCompressedExtension("test.wgsl"));
}

test "findJsonValue: basic extraction" {
    const json = "{\"entry\":\"main.pngb\",\"version\":1}";
    const result = findJsonValue(json, "\"entry\"");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("main.pngb", result.?);
}

test "findJsonValue: field not found" {
    const json = "{\"other\":\"value\"}";
    const result = findJsonValue(json, "\"entry\"");
    try std.testing.expect(result == null);
}
