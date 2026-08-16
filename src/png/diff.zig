//! Encoded-PNG differ: the reusable core behind `pngine diff`.
//!
//! Decodes two PNG byte streams and runs the RGBA8 comparator (`compare.zig`)
//! over their pixels. This is the pure half of the `diff` command — no argv, no
//! file I/O, no stderr — so it unit-tests fast under the `png` standalone module
//! and is equally usable by the browser-parity harness's exit-code path.
//!
//! ## Model
//! - Both streams decode via `decoder.zig` (8-bit truecolor, all five filters);
//!   anything it can't decode is a typed error, never a guess.
//! - Differing dimensions are a distinct outcome (`dimension_mismatch`), NOT a
//!   comparator run: two images of different sizes are incomparable, so we
//!   report the sizes instead of forcing a hard-fail through the pixel path.
//! - Same dimensions ⇒ same buffer length ⇒ the comparator's tolerance model
//!   decides pass/fail.

const std = @import("std");
const assert = std.debug.assert;

const decoder = @import("decoder.zig");
const compare = @import("compare.zig");

/// Re-export so callers can spell `diff.Config` without reaching into compare.
pub const Config = compare.Config;

/// A decode failure in either stream. Mirrors the decoder's typed errors.
pub const Error = decoder.Error;

/// The two images shared a size and the comparator ran.
pub const Compared = struct {
    width: u32,
    height: u32,
    result: compare.Result,
};

/// The two images decoded but their dimensions disagree — incomparable.
pub const DimensionMismatch = struct {
    a_width: u32,
    a_height: u32,
    b_width: u32,
    b_height: u32,
};

/// Outcome of diffing two encoded PNGs. A decode failure surfaces as an `Error`
/// instead (the union only models the both-decoded cases).
pub const Outcome = union(enum) {
    compared: Compared,
    dimension_mismatch: DimensionMismatch,
};

/// Decode `png_a` and `png_b`, then compare their pixels under `config`.
///
/// Pre-condition: both slices are candidate PNGs (validated by the decoder, not
/// assumed here — an empty or corrupt stream returns a typed `Error`).
/// Post-condition: on `.compared`, the match fraction is in [0, 1].
pub fn diffEncoded(
    allocator: std.mem.Allocator,
    png_a: []const u8,
    png_b: []const u8,
    config: Config,
) Error!Outcome {
    var img_a = try decoder.decode(allocator, png_a);
    defer img_a.deinit(allocator);
    var img_b = try decoder.decode(allocator, png_b);
    defer img_b.deinit(allocator);

    // Decoder post-conditions we rely on (RGBA8, tight buffer).
    assert(img_a.pixels.len == @as(usize, img_a.width) * img_a.height * 4);
    assert(img_b.pixels.len == @as(usize, img_b.width) * img_b.height * 4);

    if (img_a.width != img_b.width or img_a.height != img_b.height) {
        return .{ .dimension_mismatch = .{
            .a_width = img_a.width,
            .a_height = img_a.height,
            .b_width = img_b.width,
            .b_height = img_b.height,
        } };
    }

    // Equal dimensions ⇒ equal buffer lengths ⇒ the comparator runs its pixel
    // path (its own size-mismatch guard is unreachable from here).
    assert(img_a.pixels.len == img_b.pixels.len);
    const result = compare.compare(img_a.pixels, img_b.pixels, config);

    // Post-condition.
    assert(result.match_percentage >= 0.0 and result.match_percentage <= 1.0);
    return .{ .compared = .{
        .width = img_a.width,
        .height = img_a.height,
        .result = result,
    } };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const encoder = @import("encoder.zig");

/// Encode a solid-color `w`×`h` RGBA image. Caller frees the returned PNG.
fn encodeSolid(allocator: std.mem.Allocator, w: u32, h: u32, rgba: [4]u8) ![]u8 {
    const pixels = try allocator.alloc(u8, @as(usize, w) * h * 4);
    defer allocator.free(pixels);
    for (0..@as(usize, w) * h) |p| {
        const base = p * 4;
        pixels[base + 0] = rgba[0];
        pixels[base + 1] = rgba[1];
        pixels[base + 2] = rgba[2];
        pixels[base + 3] = rgba[3];
    }
    return encoder.encode(allocator, pixels, w, h);
}

/// Encode an image that is solid `rgba` except pixel 0, whose red channel is
/// bumped by `delta`. Exercises the "one differing pixel" path.
fn encodeSolidWithBlemish(allocator: std.mem.Allocator, w: u32, h: u32, rgba: [4]u8, delta: u8) ![]u8 {
    const pixels = try allocator.alloc(u8, @as(usize, w) * h * 4);
    defer allocator.free(pixels);
    for (0..@as(usize, w) * h) |p| {
        const base = p * 4;
        pixels[base + 0] = rgba[0];
        pixels[base + 1] = rgba[1];
        pixels[base + 2] = rgba[2];
        pixels[base + 3] = rgba[3];
    }
    pixels[0] +%= delta;
    return encoder.encode(allocator, pixels, w, h);
}
