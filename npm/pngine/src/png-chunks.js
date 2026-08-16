// Shared PNG chunk walker. A PNG is an 8-byte signature followed by a sequence
// of chunks, each [length:u32be][type:4 bytes][data:length][crc:u32]. PNGine
// stores its payloads in ancillary chunks (pNGb bytecode, pNGa audio, pNGf flat
// mini-format). extract.js and mini.js used to inline this walk once per chunk
// type; this is the single source.
//
// Note: kept to top-level *functions only* (no module-scoped const) so the
// inlined-profile bundler (scripts/bundle.js concatenates this file's source
// with extract.js) can't collide names with extract.js's private readers.

/**
 * Iterate the chunks of a PNG, yielding { type, data } where type is the 4-byte
 * Uint8Array tag and data is a subarray view of the chunk payload. The trailing
 * CRC is skipped, not validated. Stops before any header that would read past
 * the end of the buffer.
 * @param {Uint8Array} bytes
 */
export function* walkChunks(bytes) {
  let pos = 8; // skip the PNG signature
  while (pos + 12 <= bytes.length) {
    const len = ((bytes[pos] << 24) | (bytes[pos + 1] << 16) | (bytes[pos + 2] << 8) | bytes[pos + 3]) >>> 0;
    yield {
      type: bytes.subarray(pos + 4, pos + 8),
      data: bytes.subarray(pos + 8, pos + 8 + len),
    };
    pos += 12 + len;
  }
}

/**
 * Return the payload of the first chunk matching `type` (a 4-byte value array
 * or a 4-character string), or null if absent.
 * @param {Uint8Array} bytes
 * @param {number[]|string} type
 * @returns {Uint8Array|null}
 */
export function findChunk(bytes, type) {
  const t = typeof type === "string"
    ? [type.charCodeAt(0), type.charCodeAt(1), type.charCodeAt(2), type.charCodeAt(3)]
    : type;
  for (const c of walkChunks(bytes)) {
    if (c.type[0] === t[0] && c.type[1] === t[1] && c.type[2] === t[2] && c.type[3] === t[3]) {
      return c.data;
    }
  }
  return null;
}
