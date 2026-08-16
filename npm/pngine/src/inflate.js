// Raw-DEFLATE inflate via the platform DecompressionStream (no zlib header).
// Shared by extract.js (PNG pNGb/pNGa payloads and DEFLATE'd ZIP entries) and
// mini.js. Kept to a single top-level function so the inlined-profile bundler,
// which concatenates this source with extract.js, can't collide names.

// Absolute output cap — a decompression-bomb guard. A tiny DEFLATE stream can
// expand to gigabytes (~1032:1); without a ceiling this loop grows an unbounded
// buffer into an OOM. Generous next to any real embedded payload. (Arc-3 §2.3)
const MAX_INFLATE_OUT = 64 * 1024 * 1024;

/**
 * Inflate raw-DEFLATE bytes, concatenating the streamed output chunks.
 * @param {Uint8Array} data
 * @param {number} [maxOut] Reject once the output exceeds this many bytes.
 * @returns {Promise<Uint8Array>}
 */
export async function inflateRaw(data, maxOut = MAX_INFLATE_OUT) {
  const ds = new DecompressionStream("deflate-raw");
  const writer = ds.writable.getWriter();
  const reader = ds.readable.getReader();

  // Fire-and-forget, but swallow their rejections: cancelling the reader on a
  // bomb (below) aborts the writable side, and an un-caught write/close promise
  // would surface as an unhandledRejection (AbortError) even though the caller
  // already gets the RangeError. (Arc-3 §3.3)
  writer.write(/** @type {BufferSource} */ (/** @type {unknown} */ (data))).catch(() => {});
  writer.close().catch(() => {});

  const chunks = [];
  let len = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    len += value.length;
    if (len > maxOut) {
      // A bomb: stop the stream and reject instead of allocating gigabytes.
      await reader.cancel();
      throw new RangeError(
        `inflateRaw: output exceeds ${maxOut} bytes (decompression bomb?)`,
      );
    }
    chunks.push(value);
  }

  const result = new Uint8Array(len);
  let off = 0;
  for (const c of chunks) {
    result.set(c, off);
    off += c.length;
  }
  return result;
}
