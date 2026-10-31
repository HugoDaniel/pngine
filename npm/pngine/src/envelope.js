// The payload envelope, FROZEN v1 at X0 (checkpoint 02.C1); the JS reader
// twin of src/payload/envelope.zig. Spec: expansible-player
// docs/02-envelope-and-containers.md at a7220d5.
//
// Eight bytes, then the body (02:12-26):
//   kind:[4]u8 ASCII tag · version:u8 · flags:u8 · reserved:u16 (zero)
// flags bit0 = body is raw DEFLATE (0x01, 02:17-19), bit1 = continued: the
// next envelope of the same kind, in container order, carries the rest of
// this body (02:19-21), bits 2-7 reserved, must be zero (02:22-23).
//
// The walker NEVER checks `version`; the handler does (02:16, 02:36-39); a
// reserved flag bit (or a nonzero reserved u16, a short record, an unhandled
// kind, or a `continued` chain nothing completes) SKIPS the payload and
// LISTS it; the rest of the file is still read (02:22-23). Readers
// concatenate `continued` bodies in container order, per kind.
//
// Like png-chunks.js, this stays concatenation-safe for the inlined-profile
// bundler: consts carry an ENVELOPE_/V1_ prefix and no module-scope name
// here collides with a bundler-merged sibling (02.C2 wires it into bundles).

export const ENVELOPE_HEADER_SIZE = 8;
export const ENVELOPE_FLAG_COMPRESSED = 0x01;
export const ENVELOPE_FLAG_CONTINUED = 0x02;
export const ENVELOPE_RESERVED_FLAGS_MASK = 0xfc;

const KIND_LEN = 4;

/**
 * @typedef {Object} ParsedEnvelope
 * @property {"envelope"} status
 * @property {string} kind 4-character tag
 * @property {number} version
 * @property {number} flags
 * @property {Uint8Array} body
 */

/**
 * @typedef {Object} ParsedSkip
 * @property {"skipped"} status
 * @property {string} kind
 * @property {"unreadable_flags"|"nonzero_reserved"|"truncated"} reason
 * @property {number} [flags] the offending flags byte, for unreadable_flags
 */

/** @typedef {ParsedEnvelope|ParsedSkip} ParsedRecord */

function kindString(b, off) {
  return String.fromCharCode(b[off], b[off + 1], b[off + 2], b[off + 3]);
}

/**
 * Parse one envelope-prefixed record. Total: any input yields
 * `{ status: "envelope", kind, version, flags, body }` or
 * `{ status: "skipped", kind, reason, flags? }` with reason one of
 * "unreadable_flags" | "nonzero_reserved" | "truncated". The version byte is
 * reported and never judged here (02:16, 02:36-39).
 * @param {Uint8Array} record
 * @returns {ParsedRecord}
 */
export function parseEnvelope(record) {
  if (record.length < ENVELOPE_HEADER_SIZE) {
    return { status: "skipped", kind: "\0\0\0\0", reason: "truncated" };
  }
  const kind = kindString(record, 0);
  const flags = record[5];
  if (flags & ENVELOPE_RESERVED_FLAGS_MASK) {
    return { status: "skipped", kind, reason: "unreadable_flags", flags };
  }
  const reserved = (record[6] << 8) | record[7];
  if (reserved !== 0) {
    return { status: "skipped", kind, reason: "nonzero_reserved" };
  }
  return {
    status: "envelope",
    kind,
    version: record[4],
    flags,
    body: record.subarray(ENVELOPE_HEADER_SIZE),
  };
}

/**
 * Encode one envelope: the eight header bytes, then the body, zero in every
 * reserved position (02:12-26). Throws on reserved flag bits or a tag byte
 * outside printable ASCII; a writer never guesses either.
 * @param {string} kind 4-character tag
 * @param {number} version
 * @param {number} flags
 * @param {Uint8Array} body
 * @returns {Uint8Array}
 */
export function encodeEnvelope(kind, version, flags, body) {
  if (typeof kind !== "string" || kind.length !== KIND_LEN) {
    throw new Error(`envelope tag must be 4 characters, got ${JSON.stringify(kind)}`);
  }
  for (const c of kind) {
    const v = c.charCodeAt(0);
    // "ASCII tag" (02:15): printable bytes only, as in every fourcc
    // precedent (02:29-31). The spec does not spell out the writer-side
    // bound; this is the recorded judgement, matching the Zig twin.
    if (v < 0x20 || v > 0x7e) {
      throw new Error(`envelope tag byte outside printable ASCII: 0x${v.toString(16)}`);
    }
  }
  if (flags & ENVELOPE_RESERVED_FLAGS_MASK) {
    throw new Error(`envelope flags use reserved bits 2-7: 0x${flags.toString(16)}`);
  }
  const out = new Uint8Array(ENVELOPE_HEADER_SIZE + body.length);
  for (let i = 0; i < KIND_LEN; i++) out[i] = kind.charCodeAt(i);
  out[4] = version;
  out[5] = flags;
  out[6] = 0;
  out[7] = 0;
  out.set(body, ENVELOPE_HEADER_SIZE);
  return out;
}

/**
 * Walk records (each an envelope-prefixed record, in container order) and
 * assemble each kind's `continued` chains by concatenation (02:19-21).
 * `opts.handled` is the caller's list of handled kind strings; anything else
 * is skipped and listed with reason "no_handler"; the same
 * never-refuse-the-file treatment as unreadable flags (02:22-23, 02:36-39).
 * Payloads are emitted in completion order (a walker cannot yield a body
 * before its last part arrives); skip listings follow container order, with
 * dangling chains listed after the walk.
 * @param {Uint8Array[]} records
 * @param {{ handled?: string[] }} [opts]
 * @returns {{ payloads: Array<{kind: string, version: number, body: Uint8Array}>, skipped: Array<{kind: string, reason: string, flags?: number}> }}
 */
export function assembleEnvelopes(records, opts = {}) {
  const handled = new Set(opts.handled ?? []);
  const payloads = [];
  const skipped = [];
  // Insertion-ordered: the dangling listing at walk's end follows open order.
  const chains = new Map();

  for (const record of records) {
    const parsed = parseEnvelope(record);
    if (parsed.status === "envelope") {
      if (!handled.has(parsed.kind)) {
        skipped.push({ kind: parsed.kind, reason: "no_handler" });
        continue;
      }
      const continued = (parsed.flags & ENVELOPE_FLAG_CONTINUED) !== 0;
      const chain = chains.get(parsed.kind);
      if (chain) {
        chain.parts.push(parsed.body);
        if (!continued) {
          payloads.push({ kind: parsed.kind, version: chain.version, body: concatParts(chain.parts) });
          chains.delete(parsed.kind);
        }
      } else if (continued) {
        chains.set(parsed.kind, { version: parsed.version, parts: [parsed.body] });
      } else {
        payloads.push({ kind: parsed.kind, version: parsed.version, body: parsed.body.slice() });
      }
    } else {
      const listed = { kind: parsed.kind, reason: parsed.reason };
      if (parsed.flags !== undefined) listed.flags = parsed.flags;
      skipped.push(listed);
      // A chain of this kind can no longer complete: its pending parts are
      // dropped. The offending record is the listed one; the half-body it
      // was accumulating is never guessed at.
      chains.delete(parsed.kind);
    }
  }

  for (const kind of chains.keys()) {
    skipped.push({ kind, reason: "dangling_continued" });
  }
  return { payloads, skipped };
}

function concatParts(parts) {
  let total = 0;
  for (const p of parts) total += p.length;
  const out = new Uint8Array(total);
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}
