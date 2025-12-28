//! Validate command argument parsing.
//!
//! Parses CLI arguments for the validate command.

const std = @import("std");
const types = @import("types.zig");
const Phase = types.Phase;
const Symptom = types.Symptom;
const Options = types.Options;

/// Parse validate command arguments.
///
/// Returns 255 if help was requested, >0 on error, 0 on success.
pub fn parseArgs(args: []const []const u8, opts: *Options) u8 {
    var input_path: ?[]const u8 = null;
    const args_len: u32 = @intCast(args.len);
    var skip_count: u32 = 0;

    for (0..args_len) |idx| {
        if (skip_count > 0) {
            skip_count -= 1;
            continue;
        }
        const i: u32 = @intCast(idx);
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return 255;
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json_output = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            opts.verbose = true;
            opts.phase = .both;
        } else if (std.mem.eql(u8, arg, "--phase")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: --phase requires a value (init, frame, both)\n", .{});
                return 1;
            }
            const phase_str = args[i + 1];
            opts.phase = parsePhase(phase_str) orelse {
                std.debug.print("Error: invalid phase '{s}' (use init, frame, or both)\n", .{phase_str});
                return 1;
            };
            skip_count = 1;
        } else if (std.mem.eql(u8, arg, "--frames")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: --frames requires comma-separated indices (e.g., 0,1,10)\n", .{});
                return 1;
            }
            // Frame indices are parsed in run() where we have allocator
            skip_count = 1;
        } else if (std.mem.eql(u8, arg, "--symptom")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: --symptom requires a value\n", .{});
                return 1;
            }
            opts.symptom = parseSymptom(args[i + 1]);
            skip_count = 1;
        } else if (std.mem.eql(u8, arg, "--time") or std.mem.eql(u8, arg, "-t")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: --time requires a value\n", .{});
                return 1;
            }
            opts.time = std.fmt.parseFloat(f32, args[i + 1]) catch {
                std.debug.print("Error: invalid time value\n", .{});
                return 1;
            };
            skip_count = 1;
        } else if (std.mem.eql(u8, arg, "--time-step")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: --time-step requires a value in seconds\n", .{});
                return 1;
            }
            opts.time_step = std.fmt.parseFloat(f32, args[i + 1]) catch {
                std.debug.print("Error: invalid time-step value\n", .{});
                return 1;
            };
            skip_count = 1;
        } else if (std.mem.eql(u8, arg, "--size") or std.mem.eql(u8, arg, "-s")) {
            if (i + 1 >= args_len) {
                std.debug.print("Error: --size requires WxH\n", .{});
                return 1;
            }
            const size = parseSize(args[i + 1]) orelse {
                std.debug.print("Error: invalid size format (use WxH)\n", .{});
                return 1;
            };
            opts.width = size[0];
            opts.height = size[1];
            skip_count = 1;
        } else if (std.mem.eql(u8, arg, "--strict")) {
            opts.strict = true;
        } else if (std.mem.eql(u8, arg, "--extract-wgsl")) {
            opts.extract_wgsl = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            opts.quiet = true;
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
        printHelp();
        return 1;
    }

    opts.input_path = input_path.?;
    return 0;
}

pub fn parsePhase(s: []const u8) ?Phase {
    if (std.mem.eql(u8, s, "init")) return .init;
    if (std.mem.eql(u8, s, "frame")) return .frame;
    if (std.mem.eql(u8, s, "both")) return .both;
    return null;
}

pub fn parseSymptom(s: []const u8) Symptom {
    if (std.mem.eql(u8, s, "black")) return .black;
    if (std.mem.eql(u8, s, "colors")) return .colors;
    if (std.mem.eql(u8, s, "blend")) return .blend;
    if (std.mem.eql(u8, s, "flicker")) return .flicker;
    if (std.mem.eql(u8, s, "geometry")) return .geometry;
    return .none;
}

pub fn parseSize(s: []const u8) ?[2]u32 {
    const x_pos = std.mem.indexOfAny(u8, s, "xX") orelse return null;
    const width = std.fmt.parseInt(u32, s[0..x_pos], 10) catch return null;
    const height = std.fmt.parseInt(u32, s[x_pos + 1 ..], 10) catch return null;
    if (width == 0 or height == 0) return null;
    return .{ width, height };
}

/// Parse comma-separated frame indices (e.g., "0,1,10,60").
///
/// Complexity: O(n) where n = s.len
///
/// Pre-condition: s.len > 0
/// Post-condition: Returns owned slice with 1..100 frame indices (caller must free)
pub fn parseFrameIndices(allocator: std.mem.Allocator, s: []const u8) ![]u32 {
    // Pre-conditions
    std.debug.assert(s.len > 0);
    std.debug.assert(s.len < 1000); // Reasonable input size

    // Count commas to estimate capacity (avoids reallocation)
    var comma_count: u32 = 0;
    for (s) |c| {
        if (c == ',') comma_count += 1;
    }

    var indices = try allocator.alloc(u32, comma_count + 1);
    errdefer allocator.free(indices);

    var idx: u32 = 0;
    var start: u32 = 0;

    // Bounded loop: max 100 frame indices to prevent DoS
    for (0..100) |_| {
        var end: u32 = start;
        while (end < s.len and s[end] != ',') : (end += 1) {}

        if (end > start) {
            indices[idx] = std.fmt.parseInt(u32, s[start..end], 10) catch {
                return error.InvalidFormat; // errdefer handles free
            };
            idx += 1;
        }

        if (end >= s.len) break;
        start = end + 1;
    }

    // Post-condition: at least one index parsed
    if (idx == 0) {
        return error.InvalidFormat; // errdefer handles free
    }

    // Shrink to actual size
    if (idx < indices.len) {
        const result = try allocator.realloc(indices, idx);
        // Post-condition: bounded result
        std.debug.assert(result.len > 0 and result.len <= 100);
        return result;
    }

    // Post-condition: bounded result
    std.debug.assert(indices.len > 0 and indices.len <= 100);
    return indices;
}

pub fn printHelp() void {
    std.debug.print(
        \\PNGine Validate - Runtime validation via WAMR
        \\
        \\Usage: pngine validate <input> [options]
        \\
        \\Options:
        \\  --json                 Output JSON (default: human-readable)
        \\  --verbose, -v          Include full command trace (init + frame)
        \\  --phase <phase>        Show specific phase only: init, frame, or both
        \\  --frames <list>        Test multiple frames (default: 0)
        \\                         Example: --frames 0,1,10,60
        \\  --time, -t <seconds>   Base time for frame 0 (default: 0.0)
        \\  --time-step <seconds>  Time between frames (default: 1/60)
        \\  --size, -s <WxH>       Canvas size for validation (default: 512x512)
        \\  --symptom <desc>       Focus diagnosis on symptom:
        \\                         black, colors, blend, flicker, geometry
        \\  --strict               Exit code 1 on warnings (for CI)
        \\  --extract-wgsl         Include WGSL source in output
        \\  --quiet, -q            Only output errors
        \\  -h, --help             Show this help
        \\
        \\Examples:
        \\  pngine validate shader.pngine
        \\  pngine validate shader.pngine --json > report.json
        \\  pngine validate shader.pngine --json --phase init
        \\  pngine validate shader.pngine --symptom black --json
        \\  pngine validate shader.pngine --frames 0,30,60 --json
        \\  pngine validate shader.pngine --frames 0,1,2 --time-step 0.5
        \\
        \\Multi-Frame Testing:
        \\  Use --frames to test animation behavior across multiple frames.
        \\  The output includes diff analysis to detect animation issues:
        \\  - time_is_varying: true if time changes between frames
        \\  - draw_counts_consistent: true if all frames draw same amount
        \\
        \\Supported formats: .pngine, .pbsf, .pngb, .png (with embedded bytecode)
        \\
    , .{});
}

// ============================================================================
// Tests
// ============================================================================

test "parseSize: valid formats" {
    const size1 = parseSize("640x480").?;
    try std.testing.expectEqual(@as(u32, 640), size1[0]);
    try std.testing.expectEqual(@as(u32, 480), size1[1]);

    const size2 = parseSize("1920X1080").?;
    try std.testing.expectEqual(@as(u32, 1920), size2[0]);
    try std.testing.expectEqual(@as(u32, 1080), size2[1]);
}

test "parseSize: invalid formats" {
    try std.testing.expect(parseSize("640") == null);
    try std.testing.expect(parseSize("640-480") == null);
    try std.testing.expect(parseSize("0x480") == null);
    try std.testing.expect(parseSize("640x0") == null);
}

test "parsePhase: valid phases" {
    try std.testing.expectEqual(Phase.init, parsePhase("init").?);
    try std.testing.expectEqual(Phase.frame, parsePhase("frame").?);
    try std.testing.expectEqual(Phase.both, parsePhase("both").?);
}

test "parsePhase: invalid phase" {
    try std.testing.expect(parsePhase("invalid") == null);
}

test "parseSymptom: known symptoms" {
    try std.testing.expectEqual(Symptom.black, parseSymptom("black"));
    try std.testing.expectEqual(Symptom.colors, parseSymptom("colors"));
    try std.testing.expectEqual(Symptom.none, parseSymptom("unknown"));
}

test "parseFrameIndices: single frame" {
    const indices = try parseFrameIndices(std.testing.allocator, "0");
    defer std.testing.allocator.free(indices);

    try std.testing.expectEqual(@as(usize, 1), indices.len);
    try std.testing.expectEqual(@as(u32, 0), indices[0]);
}

test "parseFrameIndices: multiple frames" {
    const indices = try parseFrameIndices(std.testing.allocator, "0,1,10,60");
    defer std.testing.allocator.free(indices);

    try std.testing.expectEqual(@as(usize, 4), indices.len);
    try std.testing.expectEqual(@as(u32, 0), indices[0]);
    try std.testing.expectEqual(@as(u32, 1), indices[1]);
    try std.testing.expectEqual(@as(u32, 10), indices[2]);
    try std.testing.expectEqual(@as(u32, 60), indices[3]);
}

test "parseFrameIndices: non-sequential frames" {
    const indices = try parseFrameIndices(std.testing.allocator, "30,0,60,15");
    defer std.testing.allocator.free(indices);

    try std.testing.expectEqual(@as(usize, 4), indices.len);
    try std.testing.expectEqual(@as(u32, 30), indices[0]);
    try std.testing.expectEqual(@as(u32, 0), indices[1]);
    try std.testing.expectEqual(@as(u32, 60), indices[2]);
    try std.testing.expectEqual(@as(u32, 15), indices[3]);
}

test "parseFrameIndices: invalid format returns error" {
    const result = parseFrameIndices(std.testing.allocator, "abc");
    try std.testing.expectError(error.InvalidFormat, result);
}
