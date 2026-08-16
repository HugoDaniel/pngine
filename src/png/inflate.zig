//! Bomb-capped DEFLATE / zlib inflate, shared by the png module's two decoders.
//!
//! Both the pNGb-chunk extractor (raw DEFLATE) and the PNG image decoder
//! (zlib-wrapped DEFLATE) inflate an attacker-controllable compressed stream. A
//! tiny stream can expand to gigabytes — DEFLATE tops out near 1032:1 — so an
//! unbounded `allocRemaining(.unlimited)` is an out-of-memory DoS. This caps the
//! output: `allocRemaining` returns `error.StreamTooLong` the moment `max_out`
//! is exceeded, so a decompression bomb becomes a clean decode error instead of
//! an OOM kill. (Arc-3 §2.3)

const std = @import("std");
const flate = std.compress.flate;

/// Absolute output cap for a stream with no externally-known size (the pNGb
/// chunk). Generous next to any real embedded payload (<1 MB typical, a few MB
/// for large meshes) and tiny next to a bomb's gigabytes. Callers that DO know
/// the expected size (the image decoder, from IHDR) pass that exact bound
/// instead — a tighter, per-stream cap.
pub const MAX_DECOMPRESSED: usize = 64 * 1024 * 1024;

/// Inflate `data` (a `container`-wrapped DEFLATE stream) into a freshly
/// allocated buffer of AT MOST `max_out` bytes (inclusive). Returns
/// `error.StreamTooLong` once the output would exceed `max_out`. Caller owns the
/// returned slice.
///
/// `Limit` rejects the moment its cap is reached-or-exceeded, so to ALLOW an
/// output of exactly `max_out` we pass `max_out + 1` (saturating) — the stream
/// then ends via EndOfStream with one byte of headroom left instead of tripping
/// the limit on its final byte.
pub fn decompressCapped(
    allocator: std.mem.Allocator,
    data: []const u8,
    container: flate.Container,
    max_out: usize,
) ![]u8 {
    var window_buf: [flate.max_window_len]u8 = undefined;
    var input_reader: std.Io.Reader = .fixed(data);
    var decompressor: flate.Decompress = .init(&input_reader, container, &window_buf);
    return decompressor.reader.allocRemaining(allocator, .limited(max_out +| 1));
}
