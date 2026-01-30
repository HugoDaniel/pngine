//! Embed and extract commands: embed/extract bytecode from PNG files.
//!
//! Usage:
//!   pngine embed <image.png> <bytecode.pngb> [-o output.png]
//!   pngine extract <input.png|input.zip> [-o output.pngb]

const std = @import("std");
const pngine = @import("pngine");
const format = pngine.format;
const zip = pngine.zip;
const utils = @import("utils.zig");
const bundle = @import("bundle.zig");

/// Embed command arguments.
const EmbedArgs = struct {
    png_path: []const u8,
    pngb_path: []const u8,
    output_path: ?[]const u8,
};

/// Execute the embed command.
pub fn runEmbed(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    const parsed = parseEmbedArgs(args) orelse return 1;

    const derived = utils.deriveEmbedOutputPath(allocator, parsed.png_path);
    const output = parsed.output_path orelse derived catch |err| {
        std.debug.print("Error: failed to derive output path: {}\n", .{err});
        return 2;
    };
    defer if (parsed.output_path == null) allocator.free(output);

    return executeEmbed(allocator, io, parsed.png_path, parsed.pngb_path, output);
}

fn parseEmbedArgs(args: []const []const u8) ?EmbedArgs {
    var png_path: ?[]const u8 = null;
    var pngb_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    const args_len: u32 = @intCast(args.len);
    for (0..args_len) |idx| {
        const i: u32 = @intCast(idx);
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: -o requires an output path\n", .{});
                return null;
            }
            output_path = args[i + 1];
        } else if (arg.len > 0 and arg[0] == '-') {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return null;
        } else if (png_path == null) {
            png_path = arg;
        } else if (pngb_path == null) {
            pngb_path = arg;
        }
    }

    if (png_path == null or pngb_path == null) {
        std.debug.print("Error: embed requires both <image.png> and <bytecode.pngb>\n\n", .{});
        std.debug.print("Usage: pngine embed <image.png> <bytecode.pngb> [-o output.png]\n", .{});
        return null;
    }

    return .{ .png_path = png_path.?, .pngb_path = pngb_path.?, .output_path = output_path };
}

fn executeEmbed(allocator: std.mem.Allocator, io: std.Io, png_input: []const u8, pngb_input: []const u8, output: []const u8) u8 {
    std.debug.assert(png_input.len > 0);
    std.debug.assert(pngb_input.len > 0);

    const png_data = utils.readBinaryFile(allocator, io, png_input) catch |err| {
        std.debug.print("Error: failed to read PNG '{s}': {}\n", .{ png_input, err });
        return 2;
    };
    defer allocator.free(png_data);

    const bytecode = utils.readBinaryFile(allocator, io, pngb_input) catch |err| {
        std.debug.print("Error: failed to read PNGB '{s}': {}\n", .{ pngb_input, err });
        return 2;
    };
    defer allocator.free(bytecode);

    if (bytecode.len < format.HEADER_SIZE or !std.mem.eql(u8, bytecode[0..4], format.MAGIC)) {
        std.debug.print("Error: '{s}' is not a valid PNGB file\n", .{pngb_input});
        return 4;
    }

    const embedded = pngine.png.embedBytecode(allocator, png_data, bytecode) catch |err| {
        std.debug.print("Error: failed to embed bytecode: {}\n", .{err});
        return 4;
    };
    defer allocator.free(embedded);

    utils.writeOutputFile(io, output, embedded) catch |err| {
        std.debug.print("Error: failed to write '{s}': {}\n", .{ output, err });
        return 2;
    };

    std.debug.print("Embedded {s} ({d} bytes) into {s} -> {s} ({d} bytes)\n", .{
        pngb_input, bytecode.len, png_input, output, embedded.len,
    });

    return 0;
}

/// Execute the extract command.
pub fn runExtract(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

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
        std.debug.print("Usage: pngine extract <file.png|file.zip> [-o output.pngb]\n", .{});
        return 1;
    }

    const input = input_path.?;

    const output = output_path orelse utils.deriveExtractOutputPath(allocator, input) catch |err| {
        std.debug.print("Error: failed to derive output path: {}\n", .{err});
        return 2;
    };
    defer if (output_path == null) allocator.free(output);

    const file_data = utils.readBinaryFile(allocator, io, input) catch |err| {
        std.debug.print("Error: failed to read '{s}': {}\n", .{ input, err });
        return 2;
    };
    defer allocator.free(file_data);

    const bytecode = blk: {
        if (zip.isZip(file_data)) {
            break :blk bundle.extractFromZip(allocator, file_data) catch |err| {
                std.debug.print("Error: failed to extract from ZIP: {}\n", .{err});
                return 4;
            };
        } else if (file_data.len >= 8 and std.mem.eql(u8, file_data[0..8], &pngine.png.PNG_SIGNATURE)) {
            if (!pngine.png.hasPngb(file_data)) {
                std.debug.print("Error: '{s}' has no embedded bytecode (missing pNGb chunk)\n", .{input});
                return 4;
            }
            break :blk pngine.png.extractBytecode(allocator, file_data) catch |err| {
                std.debug.print("Error: failed to extract bytecode: {}\n", .{err});
                return 4;
            };
        } else {
            std.debug.print("Error: '{s}' is not a valid PNG or ZIP file\n", .{input});
            return 4;
        }
    };
    defer allocator.free(bytecode);

    if (bytecode.len < format.HEADER_SIZE or !std.mem.eql(u8, bytecode[0..4], format.MAGIC)) {
        std.debug.print("Error: extracted data is not valid PNGB\n", .{});
        return 4;
    }

    utils.writeOutputFile(io, output, bytecode) catch |err| {
        std.debug.print("Error: failed to write '{s}': {}\n", .{ output, err });
        return 2;
    };

    std.debug.print("Extracted {s} -> {s} ({d} bytes)\n", .{ input, output, bytecode.len });
    return 0;
}
