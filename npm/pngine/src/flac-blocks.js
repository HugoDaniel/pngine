// The FLAC payload walker (checkpoint 02.C3): the JS twin of
// src/flac/blocks.zig's walkFlac. Spec: expansible-player
// docs/02-envelope-and-containers.md at 02:112-168.
//
// A FLAC stream is the `fLaC` marker, a metadata block chain, then audio
// frames (RFC 9639, as 02:114-131 summarizes it). The carrier is an
// APPLICATION block whose u32 ID is `pNGx` = 0x704E4778 (02:121-122), data =
// envelope + body, one payload per block; bodies too large for one block
// split across consecutive blocks with the envelope's `continued` flag set
// on all but the last (02:129-131). A PICTURE block whose bytes are a PNG is
// walked at depth 1 with `PICTURE→<chunk>` carriers (02:145-151), reusing
// payloadsOf so the mapping and skip vocabulary are the PNG carrier's own.
//
// Sibling, not dispatcher: payloadsOf stays PNG-only (its non-PNG refusal is
// a pinned public contract, tests/npm/payloads.test.js "payloadsOf throws on
// non-PNG bytes"), so the FLAC walk surfaces as payloadsOfFlac beside it and
// 03's core dispatches on the format. Both generators yield the same shapes
// ({kind, version, flags, body, carrier} and {skip:{kind, reason, flags?},
// carrier}), and the fixture set + expected inventory strings are duplicated
// verbatim in tests/npm/flac-blocks.test.js and src/flac/blocks.zig's tests,
// the same way payloads.test.js and walk_test.zig share the museum table.
//
// Trust policy (the Zig twin's docblock is the long form): FLAC metadata
// blocks carry no CRC, so the chain's length framing is the only integrity
// it has. A block header past the end of the buffer, a declared length past
// the buffer, or a type-127 block (02:117-118) all THROW, and
// flacValidateChain preflights the whole chain before the first yield, so
// the refusal is atomic exactly as the Zig walk's is (it returns a complete
// walk or an error, never half of one). There is no separate "the chain
// never sets the last-block flag" verdict, because nothing in the format
// marks where the frames start: such a chain walks into the frames, where
// the 14-bit frame sync (0xFF, RFC 9639 6.1) reads as a forbidden type-127
// block and refuses the file that way. Block CONTENT is listed, never
// thrown for: a PICTURE whose field lengths overrun its block, a picture
// that claims PNG bytes but fails PNG framing, and short or reserved-bit
// envelope records are yielded as skip listings and the walk continues
// (02:22-23). Reserved block types 7-126 are skipped by length and never
// listed (02:118); an ID3v2 tag before the marker is tolerated and skipped
// by its syncsafe size, 7 bits per byte (02:140-143).
//
// The twins cannot disagree on any input: FLAC's 24-bit length bounds every
// block under the 16 MiB ceiling walkPng applies to nested chunk data, so
// the one declared resource difference between the PNG twins (walkPng caps,
// payloadsOf does not) is unreachable at nesting depth 1.
//
// Like payloads.js, this stays concatenation-safe for the day an inlined
// profile bundles it: top-level functions only, no module-scope consts, and
// every private name carries a flac prefix so no bundler-merged sibling
// collides.

import { payloadsOf } from "./payloads.js";
import { parseEnvelope, ENVELOPE_FLAG_CONTINUED } from "./envelope.js";

/**
 * The offset of the `fLaC` marker: 0 for a bare stream, past an ID3v2 tag
 * for a prefixed one. The tag's syncsafe size is masked to 7 bits per byte
 * (ID3v2 §3.1), tolerating sloppy taggers (02:140-143).
 *
 * @param {Uint8Array} bytes
 * @returns {number}
 */
function flacMarkerOffset(bytes) {
  if (bytes.length >= 4 && bytes[0] === 0x66 && bytes[1] === 0x4c && bytes[2] === 0x61 && bytes[3] === 0x43) {
    return 0;
  }
  if (bytes.length >= 10 && bytes[0] === 0x49 && bytes[1] === 0x44 && bytes[2] === 0x33) {
    const size =
      ((bytes[6] & 0x7f) << 21) | ((bytes[7] & 0x7f) << 14) | ((bytes[8] & 0x7f) << 7) | (bytes[9] & 0x7f);
    const at = 10 + size;
    if (
      at + 4 <= bytes.length &&
      bytes[at] === 0x66 &&
      bytes[at + 1] === 0x4c &&
      bytes[at + 2] === 0x61 &&
      bytes[at + 3] === 0x43
    ) {
      return at;
    }
  }
  throw new TypeError("payloadsOfFlac: bytes must start with the fLaC marker (an ID3v2 tag before it is tolerated)");
}

/**
 * Preflight the whole block chain before the first yield, so a framing
 * refusal is atomic exactly as the Zig twin's is (it returns a complete
 * walk or an error, never half of one). A header past the end of the
 * buffer, a declared length past the buffer, or a type-127 block throws.
 * There is no separate "the chain never sets the last-block flag" verdict:
 * such a chain walks into the frames, where the frame sync (0xFF) reads as
 * a forbidden type-127 block, which is how the format itself catches it.
 *
 * @param {Uint8Array} bytes
 * @param {number} off the marker's offset
 * @returns {void}
 */
function flacValidateChain(bytes, off) {
  let pos = off + 4;
  for (;;) {
    if (pos + 4 > bytes.length) {
      throw new Error(`flac block chain: header at byte ${pos} reads past the end of the buffer`);
    }
    const flags = bytes[pos];
    const type = flags & 0x7f;
    if (type === 127) {
      throw new Error(`flac block chain: block at byte ${pos} has forbidden type 127 (RFC 9639 8.1)`);
    }
    const len = (bytes[pos + 1] << 16) | (bytes[pos + 2] << 8) | bytes[pos + 3];
    if (pos + 4 + len > bytes.length) {
      throw new Error(`flac block chain: block at byte ${pos} declares ${len} data bytes, past the end of the buffer`);
    }
    if ((flags & 0x80) !== 0) return; // the last block: the frames follow
    pos += 4 + len;
  }
}

/**
 * Parse a PICTURE block body per RFC 9639 §8.8. Null when any field length
 * overruns the block, or when the picture is not exactly the rest of the
 * block as the format says it is. The Zig twin's `parsePicture` in one
 * shape.
 *
 * @param {Uint8Array} data
 * @returns {Uint8Array|null} the picture bytes
 */
function flacPictureBytes(data) {
  let pos = 0;
  const u32 = () => {
    if (pos + 4 > data.length) return null;
    const v = (data[pos] << 24) | (data[pos + 1] << 16) | (data[pos + 2] << 8) | data[pos + 3];
    pos += 4;
    return v >>> 0;
  };
  const span = (len) => {
    if (len === null || pos + len > data.length) return null;
    const s = data.subarray(pos, pos + len);
    pos += len;
    return s;
  };
  if (u32() === null) return null; // picture type
  const mime = span(u32());
  if (mime === null) return null;
  const desc = span(u32());
  if (desc === null) return null;
  for (let i = 0; i < 4; i++) if (u32() === null) return null; // w, h, depth, colors
  const picture = span(u32());
  if (picture === null) return null;
  if (pos !== data.length) return null; // the picture is the last field
  return picture;
}

/** Concatenate a chain's parts in container order (02:20-21). Named so no
 * bundler-merged sibling collides: payloads.js ships its own private
 * concatPayloadParts into the same concatenated profile source. */
function flacConcatParts(parts) {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

/**
 * Walk a FLAC stream's payloads: every `pNGx` APPLICATION block as one
 * envelope record, and each PICTURE block's PNG walked at depth 1.
 *
 * Yields one object per payload (`{kind, version, flags, body, carrier}`,
 * `body` the STORED bytes, `carrier` a string like "APPLICATION#1" or
 * "PICTURE→pNGf", 02:108) and one per listed skip
 * (`{skip: {kind, reason, flags?}, carrier}`), payloads as they complete
 * then skips in encounter order, dangling chains last.
 *
 * @param {Uint8Array} bytes a whole FLAC stream, ID3v2-prefixed or bare
 * @returns {Generator<{kind: string, version: number, flags: number, body: Uint8Array, carrier: string}|{skip: {kind: string, reason: string, flags?: number}, carrier: string}>}
 */
export function* payloadsOfFlac(bytes) {
  const off = flacMarkerOffset(bytes);
  flacValidateChain(bytes, off);

  const chains = new Map(); // kind -> {kind, version, flags, carrier, parts}
  const skips = [];
  let appNth = 0;
  const dropChain = (kind) => chains.delete(kind);

  let pos = off + 4;
  let sawLast = false;
  while (!sawLast) {
    const flags = bytes[pos];
    const type = flags & 0x7f;
    const len = (bytes[pos + 1] << 16) | (bytes[pos + 2] << 8) | bytes[pos + 3];
    const data = bytes.subarray(pos + 4, pos + 4 + len);
    if ((flags & 0x80) !== 0) sawLast = true;
    else pos += 4 + len;

    if (type === 2) {
      // APPLICATION: an ID shorter than four bytes names no application at
      // all, and another ID's block is ordinary metadata (02:123-127).
      if (data.length < 4) continue;
      if (data[0] !== 0x70 || data[1] !== 0x4e || data[2] !== 0x47 || data[3] !== 0x78) continue;
      appNth += 1;
      const carrier = `APPLICATION#${appNth}`;
      const parsed = parseEnvelope(data.subarray(4));
      if (parsed.status === "skipped") {
        // A chain of this kind can no longer complete: its pending parts are
        // dropped, silently; the offending record is the listed one.
        dropChain(parsed.kind);
        skips.push({ skip: parsed, carrier });
        continue;
      }
      const chain = chains.get(parsed.kind);
      if (chain !== undefined) {
        chain.parts.push(parsed.body);
        if (!(parsed.flags & ENVELOPE_FLAG_CONTINUED)) {
          chains.delete(parsed.kind);
          yield {
            kind: chain.kind,
            version: chain.version,
            flags: chain.flags,
            body: flacConcatParts(chain.parts),
            carrier: chain.carrier,
          };
        }
      } else if (parsed.flags & ENVELOPE_FLAG_CONTINUED) {
        chains.set(parsed.kind, {
          kind: parsed.kind,
          version: parsed.version,
          flags: parsed.flags,
          carrier,
          parts: [parsed.body],
        });
      } else {
        yield { kind: parsed.kind, version: parsed.version, flags: parsed.flags, body: parsed.body, carrier };
      }
    } else if (type === 6) {
      // PICTURE: nesting is decided by the bytes, not the MIME string.
      const picture = flacPictureBytes(data);
      const isPng =
        picture !== null &&
        picture.length >= 8 &&
        picture[0] === 0x89 &&
        picture[1] === 0x50 &&
        picture[2] === 0x4e &&
        picture[3] === 0x47 &&
        picture[4] === 0x0d &&
        picture[5] === 0x0a &&
        picture[6] === 0x1a &&
        picture[7] === 0x0a;
      if (picture === null) {
        skips.push({ skip: { kind: "\0\0\0\0", reason: "malformed_picture" }, carrier: "PICTURE" });
        continue;
      }
      if (!isPng) continue; // ordinary cover art, not a carrier
      let nested;
      try {
        nested = [...payloadsOf(picture)];
      } catch {
        // The FLAC's own chain is fine; the picture's framing is not. List
        // it and keep walking (trust policy).
        skips.push({ skip: { kind: "\0\0\0\0", reason: "malformed_picture" }, carrier: "PICTURE" });
        continue;
      }
      for (const entry of nested) {
        if ("skip" in entry) {
          skips.push({ skip: entry.skip, carrier: `PICTURE→${entry.carrier}` });
        } else {
          yield { ...entry, carrier: `PICTURE→${entry.carrier}` };
        }
      }
    }
    // Everything else (STREAMINFO, PADDING, SEEKTABLE, VORBIS_COMMENT,
    // CUESHEET, reserved 7-126) is skipped by length, never listed (02:118).
  }

  yield* skips;

  // Chains still open at the end of the chain are listed, never half-yielded
  // (02:19-21).
  for (const chain of chains.values()) {
    yield { skip: { kind: chain.kind, reason: "dangling_continued" }, carrier: chain.carrier };
  }
}
