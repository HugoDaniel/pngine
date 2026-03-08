//! HTML template generator for self-contained PNGine demos.
//!
//! Produces a single HTML file with:
//! - Inline mini viewer JS (from templates/mini.html)
//! - Base64-encoded PNG with embedded pNGf (and optional pNGa)
//!
//! ## Usage
//!
//! ```
//! pngine shader.pngine --html -o demo.html
//! ```
//!
//! ## Invariants
//!
//! - Output is valid HTML5
//! - PNG is base64-encoded inline (no external files)
//! - Canvas dimensions match the specified width/height

const std = @import("std");

const template = @embedFile("templates/mini.html");

/// Generate a self-contained HTML file from PNG data.
///
/// Pre-conditions:
/// - png_data is a valid PNG with pNGf chunk
/// - width and height are > 0
///
/// Post-conditions:
/// - Returns complete HTML document
/// - Caller owns returned slice
pub fn generate(
    allocator: std.mem.Allocator,
    png_data: []const u8,
    width: u32,
    height: u32,
) ![]u8 {
    // Pre-conditions
    std.debug.assert(png_data.len > 0);
    std.debug.assert(width > 0 and height > 0);

    // Base64-encode the PNG
    const base64 = try base64Encode(allocator, png_data);
    defer allocator.free(base64);

    // Format width/height as strings
    var w_buf: [16]u8 = undefined;
    var h_buf: [16]u8 = undefined;
    const w_str = std.fmt.bufPrint(&w_buf, "{d}", .{width}) catch "512";
    const h_str = std.fmt.bufPrint(&h_buf, "{d}", .{height}) catch "512";

    // Replace placeholders in template
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    var pos: usize = 0;
    while (pos < template.len) {
        if (pos + 2 < template.len and template[pos] == '{' and template[pos + 1] == '{') {
            // Find closing }}
            const end = std.mem.indexOfPos(u8, template, pos + 2, "}}") orelse {
                try result.append(allocator, template[pos]);
                pos += 1;
                continue;
            };
            const key = template[pos + 2 .. end];

            if (std.mem.eql(u8, key, "W")) {
                try result.appendSlice(allocator, w_str);
            } else if (std.mem.eql(u8, key, "H")) {
                try result.appendSlice(allocator, h_str);
            } else if (std.mem.eql(u8, key, "PNG_BASE64")) {
                try result.appendSlice(allocator, base64);
            } else {
                // Unknown placeholder, keep as-is
                try result.appendSlice(allocator, template[pos .. end + 2]);
            }

            pos = end + 2;
        } else {
            try result.append(allocator, template[pos]);
            pos += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Base64-encode binary data.
fn base64Encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const out_len = ((data.len + 2) / 3) * 4;
    const output = try allocator.alloc(u8, out_len);

    var i: usize = 0;
    var o: usize = 0;
    while (i + 2 < data.len) : ({
        i += 3;
        o += 4;
    }) {
        const n: u32 = @as(u32, data[i]) << 16 | @as(u32, data[i + 1]) << 8 | @as(u32, data[i + 2]);
        output[o] = alphabet[@intCast((n >> 18) & 63)];
        output[o + 1] = alphabet[@intCast((n >> 12) & 63)];
        output[o + 2] = alphabet[@intCast((n >> 6) & 63)];
        output[o + 3] = alphabet[@intCast(n & 63)];
    }

    // Handle remaining bytes
    if (i < data.len) {
        var n: u32 = @as(u32, data[i]) << 16;
        if (i + 1 < data.len) n |= @as(u32, data[i + 1]) << 8;
        output[o] = alphabet[@intCast((n >> 18) & 63)];
        output[o + 1] = alphabet[@intCast((n >> 12) & 63)];
        if (i + 1 < data.len) {
            output[o + 2] = alphabet[@intCast((n >> 6) & 63)];
        } else {
            output[o + 2] = '=';
        }
        output[o + 3] = '=';
    }

    return output;
}
