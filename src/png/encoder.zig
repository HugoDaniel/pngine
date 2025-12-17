//! PNG encoder for raw pixel data.
//!
//! Encodes RGBA pixels to PNG format with proper chunk structure.
//! Uses deflate compression for IDAT chunk.
//!
//! ## Usage
//! ```zig
//! const png_data = try encoder.encode(allocator, pixels, 512, 512);
//! defer allocator.free(png_data);
//! ```
//!
//! ## Invariants
//! - Input pixels must be exactly width * height * 4 bytes (RGBA)
//! - Output is always a valid PNG file
//! - Caller owns returned memory

const std = @import("std");
const chunk = @import("chunk.zig");
const flate = std.compress.flate;

pub const Error = error{
    InvalidPixelDataSize,
    CompressionFailed,
    OutOfMemory,
};

/// PNG color type constants.
const ColorType = struct {
    const grayscale: u8 = 0;
    const rgb: u8 = 2;
    const indexed: u8 = 3;
    const grayscale_alpha: u8 = 4;
    const rgba: u8 = 6;
};

/// PNG filter method constants.
const Filter = struct {
    const none: u8 = 0;
    const sub: u8 = 1;
    const up: u8 = 2;
    const average: u8 = 3;
    const paeth: u8 = 4;
};

/// Encode RGBA pixels to PNG.
///
/// Pre-conditions:
/// - pixels.len == width * height * 4
/// - width > 0 and height > 0
/// - width and height fit in u32
///
/// Post-conditions:
/// - Returns valid PNG file data
/// - Caller owns returned slice
///
/// Complexity: O(width * height) for filtering + compression
pub fn encode(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
) Error![]u8 {
    // Pre-condition: dimensions are valid
    if (width == 0 or height == 0) {
        return Error.InvalidPixelDataSize;
    }

    const expected_size: usize = @as(usize, width) * @as(usize, height) * 4;
    if (pixels.len != expected_size) {
        return Error.InvalidPixelDataSize;
    }

    // Pre-condition assertions (after validation)
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);
    std.debug.assert(pixels.len == expected_size);

    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    // PNG signature - required magic bytes that identify file as PNG (RFC 2083)
    result.appendSlice(allocator, &chunk.PNG_SIGNATURE) catch {
        return Error.OutOfMemory;
    };

    // IHDR must be first chunk - contains critical image dimensions and format
    try writeIHDR(&result, allocator, width, height);

    // IDAT contains compressed pixel data - this is where most bytes go
    try writeIDAT(&result, allocator, pixels, width, height);

    // IEND marks end of file - required for valid PNG structure
    chunk.writeChunk(&result, allocator, chunk.ChunkType.IEND, "") catch {
        return Error.OutOfMemory;
    };

    const output = result.toOwnedSlice(allocator) catch {
        return Error.OutOfMemory;
    };

    // Post-condition: valid PNG starts with signature
    std.debug.assert(output.len >= 8);
    std.debug.assert(std.mem.eql(u8, output[0..8], &chunk.PNG_SIGNATURE));

    return output;
}

/// Write IHDR chunk to buffer.
///
/// IHDR format is defined by PNG spec (RFC 2083). All multi-byte values
/// are big-endian per PNG spec requirements.
fn writeIHDR(
    result: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
) Error!void {
    // Pre-conditions
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);

    var ihdr: [13]u8 = undefined;

    // PNG spec requires big-endian for all multi-byte integers
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);

    // 8-bit depth is sufficient for web display and keeps file size small
    ihdr[8] = 8;
    // RGBA (6) supports transparency needed for shader output compositing
    ihdr[9] = ColorType.rgba;
    // PNG only supports deflate compression (method 0)
    ihdr[10] = 0;
    // Adaptive filtering (method 0) allows per-row filter selection
    ihdr[11] = 0;
    // No interlacing - simpler and smaller for generated images
    ihdr[12] = 0;

    chunk.writeChunk(result, allocator, chunk.ChunkType.IHDR, &ihdr) catch {
        return Error.OutOfMemory;
    };

    // Post-condition: IHDR data is 13 bytes (PNG spec fixed size)
    std.debug.assert(ihdr.len == 13);
}

/// Write IDAT chunk(s) with compressed pixel data.
fn writeIDAT(
    result: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
) Error!void {
    // Pre-conditions
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);
    std.debug.assert(pixels.len == @as(usize, width) * @as(usize, height) * 4);

    // Add filter bytes to pixel data
    const filtered = addFilterBytes(allocator, pixels, width, height) catch {
        return Error.OutOfMemory;
    };
    defer allocator.free(filtered);

    // Compress with deflate
    const compressed = compress(allocator, filtered) catch {
        return Error.CompressionFailed;
    };
    defer allocator.free(compressed);

    // Write as IDAT chunk
    chunk.writeChunk(result, allocator, chunk.ChunkType.IDAT, compressed) catch {
        return Error.OutOfMemory;
    };

    // Post-condition: compressed data was written
    std.debug.assert(compressed.len > 0);
}

/// Add PNG filter bytes before each row.
///
/// PNG requires a filter byte (0-4) before each scanline.
/// We use filter 0 (None) for simplicity - each row is prepended with 0x00.
fn addFilterBytes(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
) ![]u8 {
    // Pre-conditions
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);

    const row_size: usize = @as(usize, width) * 4;
    const filtered_row_size = row_size + 1; // +1 for filter byte
    const filtered_size = @as(usize, height) * filtered_row_size;

    const filtered = try allocator.alloc(u8, filtered_size);
    errdefer allocator.free(filtered);

    // Process each row (bounded loop)
    const height_usize: usize = @intCast(height);
    for (0..height_usize) |y| {
        const filtered_offset = y * filtered_row_size;
        const pixel_offset = y * row_size;

        // Filter byte (0 = None)
        filtered[filtered_offset] = Filter.none;

        // Copy row pixels
        @memcpy(
            filtered[filtered_offset + 1 ..][0..row_size],
            pixels[pixel_offset..][0..row_size],
        );
    }

    // Post-condition: all rows have filter byte
    std.debug.assert(filtered.len == filtered_size);

    return filtered;
}

/// Compress data using zlib format with real DEFLATE compression.
///
/// Uses std.compress.flate for LZ77+Huffman compression.
/// Produces valid zlib output (RFC 1950) for PNG IDAT chunks.
///
/// Pre-conditions:
/// - data.len > 0
///
/// Post-conditions:
/// - Returns valid zlib-compressed data
/// - Caller owns returned slice
fn compress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // Pre-condition: data is not empty
    std.debug.assert(data.len > 0);

    // Allocate output buffer - compressed size is usually smaller than input,
    // but worst case for incompressible data is ~0.1% larger plus headers
    // Use input size + 1KB for headers/overhead as initial estimate
    const initial_capacity = data.len + 1024;
    var output_buf = try allocator.alloc(u8, initial_capacity);
    errdefer allocator.free(output_buf);

    // Window buffer for compression (32KB history window)
    var window_buf: [flate.max_window_len]u8 = undefined;

    // Create output writer
    var output_writer: std.Io.Writer = .fixed(output_buf);

    // Create compressor with zlib container
    // Use level 6 (default) - good balance of speed and compression
    var compressor = flate.Compress.init(
        &output_writer,
        &window_buf,
        .zlib,
        flate.Compress.Options.level_6,
    ) catch {
        return error.CompressionFailed;
    };

    // Write all data through the compressor
    compressor.writer.writeAll(data) catch {
        return error.CompressionFailed;
    };

    // Flush to finalize compression
    compressor.writer.flush() catch {
        return error.CompressionFailed;
    };

    const compressed_len = output_writer.end;

    // Create result with exact size
    const result = try allocator.alloc(u8, compressed_len);
    @memcpy(result, output_buf[0..compressed_len]);
    allocator.free(output_buf);

    // Post-condition: output starts with zlib header (0x78)
    std.debug.assert(result.len > 0);
    std.debug.assert(result[0] == 0x78);

    return result;
}

/// Encode BGRA pixels to PNG (common format from GPU readbacks).
///
/// Converts BGRA to RGBA before encoding.
pub fn encodeBGRA(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
) Error![]u8 {
    // Pre-conditions
    if (width == 0 or height == 0) {
        return Error.InvalidPixelDataSize;
    }

    const expected_size: usize = @as(usize, width) * @as(usize, height) * 4;
    if (pixels.len != expected_size) {
        return Error.InvalidPixelDataSize;
    }

    std.debug.assert(width > 0);
    std.debug.assert(height > 0);

    // Convert BGRA to RGBA
    const rgba = allocator.alloc(u8, pixels.len) catch {
        return Error.OutOfMemory;
    };
    defer allocator.free(rgba);

    // Process each pixel (bounded loop)
    const pixel_count = pixels.len / 4;
    for (0..pixel_count) |i| {
        const offset = i * 4;
        rgba[offset + 0] = pixels[offset + 2]; // R <- B
        rgba[offset + 1] = pixels[offset + 1]; // G <- G
        rgba[offset + 2] = pixels[offset + 0]; // B <- R
        rgba[offset + 3] = pixels[offset + 3]; // A <- A
    }

    // Post-condition: converted all pixels
    std.debug.assert(rgba.len == pixels.len);

    return encode(allocator, rgba, width, height);
}

// ============================================================================
// Tests
// ============================================================================

test "encoder: encode 1x1 red pixel" {
    const allocator = std.testing.allocator;

    // Single red pixel (RGBA)
    const pixels = [_]u8{ 255, 0, 0, 255 };
    const png = try encode(allocator, &pixels, 1, 1);
    defer allocator.free(png);

    // Verify PNG signature
    try std.testing.expectEqualSlices(u8, &chunk.PNG_SIGNATURE, png[0..8]);

    // Parse and verify chunks
    var iter = try chunk.parseChunks(png);

    // IHDR
    const ihdr = (try iter.next()).?;
    try std.testing.expectEqualSlices(u8, "IHDR", &ihdr.chunk_type);
    try std.testing.expectEqual(@as(usize, 13), ihdr.data.len);
    // Verify dimensions
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, ihdr.data[0..4], .big));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, ihdr.data[4..8], .big));

    // IDAT
    const idat = (try iter.next()).?;
    try std.testing.expectEqualSlices(u8, "IDAT", &idat.chunk_type);
    try std.testing.expect(idat.data.len > 0);

    // IEND
    const iend = (try iter.next()).?;
    try std.testing.expectEqualSlices(u8, "IEND", &iend.chunk_type);
    try std.testing.expectEqual(@as(usize, 0), iend.data.len);

    // No more chunks
    try std.testing.expectEqual(@as(?chunk.Chunk, null), try iter.next());
}

test "encoder: encode 2x2 gradient" {
    const allocator = std.testing.allocator;

    // 2x2 image: red, green, blue, white
    const pixels = [_]u8{
        255, 0,   0,   255, // Red
        0,   255, 0,   255, // Green
        0,   0,   255, 255, // Blue
        255, 255, 255, 255, // White
    };

    const png = try encode(allocator, &pixels, 2, 2);
    defer allocator.free(png);

    // Verify valid PNG
    try std.testing.expectEqualSlices(u8, &chunk.PNG_SIGNATURE, png[0..8]);

    // Parse and verify dimensions
    var iter = try chunk.parseChunks(png);
    const ihdr = (try iter.next()).?;
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, ihdr.data[0..4], .big));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, ihdr.data[4..8], .big));
}

test "encoder: encode larger image" {
    const allocator = std.testing.allocator;

    const width: u32 = 64;
    const height: u32 = 64;
    const size = width * height * 4;

    var pixels: [size]u8 = undefined;

    // Fill with gradient pattern
    for (0..height) |y| {
        for (0..width) |x| {
            const offset = (y * width + x) * 4;
            pixels[offset + 0] = @intCast(x * 4); // R
            pixels[offset + 1] = @intCast(y * 4); // G
            pixels[offset + 2] = 128; // B
            pixels[offset + 3] = 255; // A
        }
    }

    const png = try encode(allocator, &pixels, width, height);
    defer allocator.free(png);

    // Verify valid PNG structure
    var iter = try chunk.parseChunks(png);

    const ihdr = (try iter.next()).?;
    try std.testing.expectEqual(@as(u32, 64), std.mem.readInt(u32, ihdr.data[0..4], .big));
    try std.testing.expectEqual(@as(u32, 64), std.mem.readInt(u32, ihdr.data[4..8], .big));
}

test "encoder: invalid pixel size rejected" {
    const allocator = std.testing.allocator;

    // Wrong size: 3 bytes instead of 4 (1x1 requires 4 bytes)
    const pixels = [_]u8{ 255, 0, 0 };
    try std.testing.expectError(Error.InvalidPixelDataSize, encode(allocator, &pixels, 1, 1));
}

test "encoder: zero dimensions rejected" {
    const allocator = std.testing.allocator;

    const pixels = [_]u8{};
    try std.testing.expectError(Error.InvalidPixelDataSize, encode(allocator, &pixels, 0, 1));
    try std.testing.expectError(Error.InvalidPixelDataSize, encode(allocator, &pixels, 1, 0));
}

test "encoder: BGRA to PNG conversion" {
    const allocator = std.testing.allocator;

    // Single cyan pixel in BGRA (WebGPU typical format)
    // BGRA: B=255, G=255, R=0, A=255 = cyan
    const bgra = [_]u8{ 255, 255, 0, 255 };

    const png = try encodeBGRA(allocator, &bgra, 1, 1);
    defer allocator.free(png);

    // Verify valid PNG
    try std.testing.expectEqualSlices(u8, &chunk.PNG_SIGNATURE, png[0..8]);
}

test "encoder: filter bytes added correctly" {
    const allocator = std.testing.allocator;

    // 2x1 image
    const pixels = [_]u8{
        255, 0, 0, 255, // Red
        0, 255, 0, 255, // Green
    };

    const filtered = try addFilterBytes(allocator, &pixels, 2, 1);
    defer allocator.free(filtered);

    // Should be: [filter=0] [R G B A] [R G B A]
    try std.testing.expectEqual(@as(usize, 9), filtered.len); // 1 + 8
    try std.testing.expectEqual(@as(u8, 0), filtered[0]); // Filter byte
    try std.testing.expectEqual(@as(u8, 255), filtered[1]); // R of first pixel
}

test "encoder: multiple rows with filter bytes" {
    const allocator = std.testing.allocator;

    // 1x2 image (2 rows, 1 pixel each)
    const pixels = [_]u8{
        255, 0, 0, 255, // Row 0: Red
        0, 255, 0, 255, // Row 1: Green
    };

    const filtered = try addFilterBytes(allocator, &pixels, 1, 2);
    defer allocator.free(filtered);

    // Should be: [filter=0][RGBA] [filter=0][RGBA]
    try std.testing.expectEqual(@as(usize, 10), filtered.len); // (1 + 4) * 2
    try std.testing.expectEqual(@as(u8, 0), filtered[0]); // Row 0 filter
    try std.testing.expectEqual(@as(u8, 0), filtered[5]); // Row 1 filter
}

test "encoder: compression produces valid zlib output" {
    const allocator = std.testing.allocator;

    // Repetitive data compresses well
    const data = "Hello, PNG compression! This is a test string with some repetition. " ++
        "Hello, PNG compression! This is a test string with some repetition.";
    const compressed = try compress(allocator, data);
    defer allocator.free(compressed);

    // Compressed data should exist and be smaller than input (with repetitive data)
    try std.testing.expect(compressed.len > 0);
    try std.testing.expect(compressed.len < data.len);

    // Verify zlib header - CMF byte indicates deflate with 32K window
    try std.testing.expectEqual(@as(u8, 0x78), compressed[0]);

    // Verify header checksum (CMF*256 + FLG must be divisible by 31)
    const header_check = @as(u16, compressed[0]) * 256 + compressed[1];
    try std.testing.expectEqual(@as(u16, 0), header_check % 31);

    // Verify minimum zlib structure: 2 byte header + some data + 4 byte adler32
    try std.testing.expect(compressed.len >= 7);
}

test "encoder: solid color image compresses significantly" {
    const allocator = std.testing.allocator;

    // Create 256x256 solid red image (highly compressible)
    const width: u32 = 256;
    const height: u32 = 256;
    const raw_size = width * height * 4;
    var pixels: [raw_size]u8 = undefined;

    // Fill with solid red
    for (0..width * height) |i| {
        pixels[i * 4 + 0] = 255; // R
        pixels[i * 4 + 1] = 0; // G
        pixels[i * 4 + 2] = 0; // B
        pixels[i * 4 + 3] = 255; // A
    }

    const png = try encode(allocator, &pixels, width, height);
    defer allocator.free(png);

    // Solid color should compress extremely well (>10x ratio)
    // Raw pixels = 256KB, compressed PNG should be <25KB
    try std.testing.expect(png.len < raw_size / 10);
}

test "encoder: OOM handling with FailingAllocator" {
    // Test that encode handles OOM gracefully at each allocation point
    const pixels = [_]u8{ 255, 0, 0, 255 }; // 1x1 red pixel

    var fail_index: usize = 0;
    while (fail_index < 20) : (fail_index += 1) {
        var failing_alloc = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });

        const result = encode(failing_alloc.allocator(), &pixels, 1, 1);

        if (failing_alloc.has_induced_failure) {
            // OOM occurred - verify graceful handling
            // Both OutOfMemory and CompressionFailed are acceptable
            // (CompressionFailed wraps OOM in compress())
            if (result) |png| {
                failing_alloc.allocator().free(png);
                return error.TestUnexpectedResult;
            } else |err| {
                try std.testing.expect(err == Error.OutOfMemory or err == Error.CompressionFailed);
            }
        } else {
            // No OOM - operation succeeded
            const png = try result;
            failing_alloc.allocator().free(png);
            break;
        }
    }
}
