// Single-source container-format detector. A PNGine payload arrives as a PNG
// (bytecode in a pNGb/pNGa/pNGf ancillary chunk), a ZIP bundle, or bare PNGB
// bytecode; these four predicates + detectFormat pick which. extract.js imports
// them and the generated Node stubs (scripts/bundle.js) inline this file's
// source, so the classification lives in ONE place. Previously each of the
// three sites hand-copied the checks and they drifted — the stubs' isZip fell
// to a 2-byte `PK` test while extract.js kept the correct 3-byte one, so a
// `PK\x01\x02` central-directory blob (never the START of a real archive)
// misdetected as "zip".
//
// Kept to top-level functions + the one PNG_SIG const (all uniquely named) so
// the inlined-profile bundler (scripts/bundle.js concatenates this file's
// source with extract.js) can't collide names — same rule as png-chunks.js.
//
// Every predicate accepts an ArrayBuffer OR a Uint8Array (the public API
// contract, matching the .d.ts), normalizing internally.

const PNG_SIG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

function asBytes(d) {
  return d instanceof Uint8Array ? d : new Uint8Array(d);
}

/** True when `d` begins with the 8-byte PNG signature. */
export function isPng(d) {
  const b = asBytes(d);
  return b.length >= 8 && PNG_SIG.every((v, i) => b[i] === v);
}

/**
 * True when `d` begins with a ZIP signature that can START a file: a local
 * file header `PK\x03\x04` or an empty-archive end-of-central-directory
 * `PK\x05\x06`. The 3rd byte is load-bearing — a bare `PK` (2-byte) test also
 * matches `PK\x01\x02` (central directory) and `PK\x07\x08` (data descriptor),
 * which never lead a real archive.
 */
export function isZip(d) {
  const b = asBytes(d);
  return b.length >= 4 && b[0] === 0x50 && b[1] === 0x4b && (b[2] === 0x03 || b[2] === 0x05);
}

/** True when `d` begins with the "PNGB" bytecode magic. */
export function isPngb(d) {
  const b = asBytes(d);
  return b.length >= 4 && b[0] === 0x50 && b[1] === 0x4e && b[2] === 0x47 && b[3] === 0x42;
}

/**
 * Classify a payload. ZIP is tried first (a ZIP could in principle embed a PNG
 * byte pattern later, never at offset 0), then PNG, then bare PNGB.
 * @returns {'png'|'zip'|'pngb'|null}
 */
export function detectFormat(d) {
  if (isZip(d)) return "zip";
  if (isPng(d)) return "png";
  if (isPngb(d)) return "pngb";
  return null;
}
