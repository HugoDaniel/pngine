// The PNG payload walker over both carrier generations (02.C2): the JS twin
// of src/png/extract.zig's walkPng. Spec: expansible-player
// docs/02-envelope-and-containers.md at a7220d5.
//
// Legacy letters map onto the envelope — b→PNGB f→PNGF a→SNTU m→META w→WGSL,
// with pNGm's missing flags byte supplied as zero (02:81-83) — and a pNGx
// chunk's data IS the envelope record (02:85-87). Reserved positions
// skip-and-list and the rest of the file is still read (02:22-25); continued
// chains concatenate per kind in container order (02:19-21).
//
// Yield order matches the Zig twin's Walk exactly: payloads as they complete,
// then every skip listing in container order, then dangling chains — so both
// sides list the same inventory for the same file (02:186-187).
//
// Like png-chunks.js, this stays concatenation-safe for the inlined-profile
// bundler: top-level functions only, no module-scope consts (scripts/bundle.cjs
// concatenates it after png-chunks.js and envelope.js).

import { walkChunks } from "./png-chunks.js";
import { parseEnvelope, ENVELOPE_FLAG_CONTINUED } from "./envelope.js";

/**
 * The CRC-32 lookup table (the PNG chunk CRC polynomial 0xedb88320), built
 * per call: this module allows no module-scope consts (the inlined-profile
 * bundler concatenates it after png-chunks.js and envelope.js), and a walk
 * calls the update helper once per chunk, so the 256-entry build is noise
 * next to any chunk it then scans.
 *
 * @returns {Uint32Array}
 */
function crc32Table() {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
}

/**
 * Feed `bytes` into a running raw CRC-32 state (start at 0xffffffff).
 *
 * @param {number} state
 * @param {Uint8Array} bytes
 * @returns {number}
 */
function crc32Update(state, bytes) {
  const table = crc32Table();
  let c = state;
  for (let i = 0; i < bytes.length; i++) c = (table[(c ^ bytes[i]) & 0xff] ^ (c >>> 8)) >>> 0;
  return c;
}

/**
 * CRC-32 of `bytes` (the PNG chunk CRC: init 0xffffffff, final xor), the
 * same value zlib's crc32() and src/png/crc32.zig produce.
 *
 * @param {Uint8Array} bytes
 * @returns {number}
 */
export function crc32(bytes) {
  return (crc32Update(0xffffffff, bytes) ^ 0xffffffff) >>> 0;
}

/**
 * Strict framing preflight for {@link payloadsOf}: walk the chunks once and
 * refuse the whole input when any chunk's declared length reads past the end
 * of the buffer or its CRC does not match, BEFORE any payload is yielded.
 *
 * The frozen walkChunks is permissive by design and stays so for its own
 * callers (02:99-100: it clamps an overrunning data view and skips the CRC);
 * this is the validation layer that sits ahead of it, the JS twin of
 * walkPng's first two framing refusals. Chunk size applies no ceiling here
 * (walkPng caps in-memory data at 16 MiB; a declared resource difference
 * between the twins, owner-approved 2026-10-05 under the conditions the
 * ask 02 verdict names — no promise of unlimited memory).
 *
 * @param {Uint8Array} bytes
 * @returns {void}
 */
export function validateFraming(bytes) {
  for (const c of walkChunks(bytes)) {
    // The chunk's header position, reconstructed from the yielded view: the
    // view's byteOffset is absolute in the underlying buffer, so subtract
    // the walker's own base and the 8 header bytes ahead of the data.
    const pos = c.data.byteOffset - bytes.byteOffset - 8;
    const len = ((bytes[pos] << 24) | (bytes[pos + 1] << 16) | (bytes[pos + 2] << 8) | bytes[pos + 3]) >>> 0;
    if (pos + 12 + len > bytes.length) {
      throw new Error(`chunk at byte ${pos} declares ${len} data bytes, past the end of the buffer`);
    }
    let state = 0xffffffff;
    state = crc32Update(state, c.type);
    state = crc32Update(state, c.data);
    const stored =
      ((bytes[pos + 8 + len] << 24) | (bytes[pos + 8 + len + 1] << 16) | (bytes[pos + 8 + len + 2] << 8) | bytes[pos + 8 + len + 3]) >>> 0;
    if (((state ^ 0xffffffff) >>> 0) !== stored) {
      throw new Error(`chunk at byte ${pos} fails its CRC check`);
    }
  }
}

/**
 * The legacy family letters that are envelope carriers, and each one's kind
 * (02:81). pNGm's header is the version byte alone (02:48).
 *
 * @param {string} letter
 * @returns {{kind: string, headerLen: number}|null}
 */
function legacyLetter(letter) {
  switch (letter) {
    case "b": return { kind: "PNGB", headerLen: 2 };
    case "f": return { kind: "PNGF", headerLen: 2 };
    case "a": return { kind: "SNTU", headerLen: 2 };
    case "m": return { kind: "META", headerLen: 1 };
    case "w": return { kind: "WGSL", headerLen: 2 };
    default: return null;
  }
}

function typeString(type) {
  return String.fromCharCode(type[0], type[1], type[2], type[3]);
}

/**
 * Walk a PNG's payloads, legacy and pNGx alike.
 *
 * Yields one object per payload — `{ kind, version, flags, body, carrier }`
 * with `kind` a 4-character tag, `body` the STORED bytes (flag bit 0 says raw
 * DEFLATE; inflating is the consumer's job, after any concatenation) and
 * `carrier` the carrying chunk ("pNGb", "pNGx#2", …) — and one object per
 * listed skip, `{ skip: { kind, reason, flags? }, carrier }`, so nothing a
 * PNG carries is silently dropped.
 *
 * Framing: a CRC mismatch or a declared length past the buffer throws before
 * the first yield; chunks above 16 MiB are accepted (no ceiling, a declared,
 * owner-approved resource difference — ask 02, 2026-10-05); a record shorter
 * than an envelope header yields { skip: { kind: "\0\0\0\0", reason: "truncated" } }.
 *
 * @param {Uint8Array} bytes
 * @returns {Generator<{kind: string, version: number, flags: number, body: Uint8Array, carrier: string}|{skip: {kind: string, reason: string, flags?: number}, carrier: string}>}
 */
export function* payloadsOf(bytes) {
  // The signature gate, before anything else: walkPng refuses a non-PNG with
  // InvalidPng, and this walker is public with callers handing it arbitrary
  // bytes (the frozen walkChunks beneath starts at offset 8 unconditionally
  // and would walk garbage framing). The comparison is inline because this
  // module allows no module-scope consts; short input and wrong magic both
  // land here, in the anim.js verb style of a TypeError for a wrong
  // argument.
  if (
    bytes.length < 8 ||
    bytes[0] !== 0x89 ||
    bytes[1] !== 0x50 ||
    bytes[2] !== 0x4e ||
    bytes[3] !== 0x47 ||
    bytes[4] !== 0x0d ||
    bytes[5] !== 0x0a ||
    bytes[6] !== 0x1a ||
    bytes[7] !== 0x0a
  ) {
    throw new TypeError("payloadsOf: bytes must start with the 8-byte PNG signature");
  }
  validateFraming(bytes);
  const chains = new Map(); // kind -> {kind, version, flags, carrier, parts}
  const skips = [];
  const counters = new Map(); // chunk type -> nth occurrence

  const dropChain = (kind) => {
    chains.delete(kind);
  };

  for (const c of walkChunks(bytes)) {
    if (c.type[0] !== 0x70 || c.type[1] !== 0x4e || c.type[2] !== 0x47) continue; // "pNG"
    const t = typeString(c.type);
    const nth = (counters.get(t) ?? 0) + 1;
    counters.set(t, nth);
    const carrier = t === "pNGx" ? `pNGx#${nth}` : t;

    let record;
    if (t === "pNGx") {
      // "body = envelope + bytes" (02:85-86): the chunk data IS the record.
      record = c.data;
    } else if (legacyLetter(t[3]) !== null) {
      // Synthesize the record the letter's header maps onto (02:80-83).
      const { kind, headerLen } = /** @type {{kind: string, headerLen: number}} */ (legacyLetter(t[3]));
      if (c.data.length < headerLen) {
        // Shorter than its own header: not an envelope at all (02:12).
        dropChain(kind);
        skips.push({ skip: { kind, reason: "truncated" }, carrier });
        continue;
      }
      record = new Uint8Array(8 + c.data.length - headerLen);
      for (let i = 0; i < 4; i++) record[i] = kind.charCodeAt(i);
      record[4] = c.data[0];
      record[5] = t[3] === "m" ? 0 : c.data[1];
      record.set(c.data.subarray(headerLen), 8);
    } else {
      // A family letter with no kind (the retired pNGr still living in
      // museum PNGs): listed, never dropped (02:77-79).
      skips.push({ skip: { kind: t, reason: "unknown_letter" }, carrier });
      continue;
    }

    const parsed = parseEnvelope(record);
    if (parsed.status === "skipped") {
      // A chain of this kind can no longer complete: its pending parts are
      // dropped, silently — the offending record is the listed one.
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
          body: concatPayloadParts(chain.parts),
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
  }

  yield* skips;

  // Chains still open at the end of the file are listed, never half-yielded
  // (02:19-21).
  for (const chain of chains.values()) {
    yield { skip: { kind: chain.kind, reason: "dangling_continued" }, carrier: chain.carrier };
  }
}

/** Concatenate a chain's parts in container order (02:20-21). Named so no
 * bundler-merged sibling collides: envelope.js ships its own private
 * concatPayloadParts into the same concatenated profile source. */
function concatPayloadParts(parts) {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}
