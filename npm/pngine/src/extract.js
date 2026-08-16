// Bytecode extraction from PNG and ZIP files
// Runs on main thread

import { findChunk } from "./png-chunks.js";
import { inflateRaw } from "./inflate.js";
import { isPng, isZip, isPngb, detectFormat } from "./detect.js";

// Re-exported so `import { isPng, … } from "pngine/dev"` (viewer/dev entry
// points) keeps resolving them here. Their single definition lives in
// detect.js; the generated Node stubs inline it too (scripts/bundle.js).
export { isPng, isZip, isPngb, detectFormat };

const PNGB_CHUNK = [0x70, 0x4e, 0x47, 0x62]; // 'pNGb'
const PNGA_CHUNK = [0x70, 0x4e, 0x47, 0x61]; // 'pNGa'

/**
 * Extract bytecode from any supported format
 * @param {ArrayBuffer|Uint8Array} data
 * @returns {Promise<Uint8Array>}
 */
export async function extractBytecode(data) {
  const b = data instanceof Uint8Array ? data : new Uint8Array(data);
  const fmt = detectFormat(b);

  if (fmt === "pngb") return b;
  if (fmt === "png") return extractFromPng(b);
  if (fmt === "zip") return extractFromZip(b);

  throw new Error("Unknown format");
}

/**
 * Extract bytecode from PNG with pNGb chunk
 * @param {Uint8Array} b
 * @returns {Promise<Uint8Array>}
 */
async function extractFromPng(b) {
  if (!isPng(b)) throw new Error("Invalid PNG");
  const chunk = findChunk(b, PNGB_CHUNK);
  if (!chunk) throw new Error("No pNGb chunk found");
  return parsePngbChunk(chunk);
}

/**
 * Parse pNGb chunk data
 * @param {Uint8Array} data
 * @returns {Promise<Uint8Array>}
 */
async function parsePngbChunk(data) {
  if (data.length < 2) throw new Error("Invalid pNGb chunk");

  const version = data[0];
  const flags = data[1];
  const payload = data.subarray(2);

  if (version !== 1) throw new Error(`Unsupported pNGb version: ${version}`);

  // Compressed?
  if (flags & 1) {
    return inflateRaw(payload);
  }
  return new Uint8Array(payload);
}

/**
 * Extract bytecode from ZIP bundle
 * @param {Uint8Array} b
 * @returns {Promise<Uint8Array>}
 */
async function extractFromZip(b) {
  // Find End of Central Directory
  let eocd = -1;
  for (let i = 22; i <= Math.min(b.length, 65557); i++) {
    const off = b.length - i;
    if (readU32LE(b, off) === 0x06054b50) {
      eocd = off;
      break;
    }
  }
  if (eocd === -1) throw new Error("Invalid ZIP");

  const entries = readU16LE(b, eocd + 10);
  let cdOff = readU32LE(b, eocd + 16);

  // Find manifest.json or first .pngb file
  let manifestEntry = null;
  let pngbEntry = null;

  for (let i = 0; i < entries; i++) {
    if (readU32LE(b, cdOff) !== 0x02014b50) break;

    const compression = readU16LE(b, cdOff + 10);
    const compSize = readU32LE(b, cdOff + 20);
    const uncompSize = readU32LE(b, cdOff + 24);
    const nameLen = readU16LE(b, cdOff + 28);
    const extraLen = readU16LE(b, cdOff + 30);
    const commentLen = readU16LE(b, cdOff + 32);
    const localOff = readU32LE(b, cdOff + 42);

    const name = new TextDecoder().decode(b.subarray(cdOff + 46, cdOff + 46 + nameLen));

    const localExtraLen = readU16LE(b, localOff + 28);
    const dataOff = localOff + 30 + nameLen + localExtraLen;

    const entry = { name, compression, compSize, uncompSize, dataOff };

    if (name === "manifest.json") manifestEntry = entry;
    else if (name.endsWith(".pngb") && !pngbEntry) pngbEntry = entry;

    cdOff += 46 + nameLen + extraLen + commentLen;
  }

  // Try manifest first
  if (manifestEntry) {
    const manifest = JSON.parse(
      new TextDecoder().decode(await extractEntry(b, manifestEntry))
    );
    if (manifest.entry) {
      // Find entry file
      cdOff = readU32LE(b, eocd + 16);
      for (let i = 0; i < entries; i++) {
        if (readU32LE(b, cdOff) !== 0x02014b50) break;
        const nameLen = readU16LE(b, cdOff + 28);
        const name = new TextDecoder().decode(b.subarray(cdOff + 46, cdOff + 46 + nameLen));
        if (name === manifest.entry) {
          const compression = readU16LE(b, cdOff + 10);
          const compSize = readU32LE(b, cdOff + 20);
          const uncompSize = readU32LE(b, cdOff + 24);
          const extraLen = readU16LE(b, cdOff + 30);
          const commentLen = readU16LE(b, cdOff + 32);
          const localOff = readU32LE(b, cdOff + 42);
          const localExtraLen = readU16LE(b, localOff + 28);
          const dataOff = localOff + 30 + nameLen + localExtraLen;
          return extractEntry(b, { compression, compSize, uncompSize, dataOff });
        }
        cdOff += 46 + nameLen + readU16LE(b, cdOff + 30) + readU16LE(b, cdOff + 32);
      }
    }
  }

  // Fallback to first .pngb
  if (pngbEntry) {
    return extractEntry(b, pngbEntry);
  }

  throw new Error("No bytecode found in ZIP");
}

/**
 * Extract ZIP entry data
 */
async function extractEntry(b, entry) {
  const data = b.subarray(entry.dataOff, entry.dataOff + entry.compSize);
  if (entry.compression === 0) return new Uint8Array(data);
  if (entry.compression === 8) return inflateRaw(data);
  throw new Error(`Unsupported compression: ${entry.compression}`);
}

/**
 * Extract audio WASM from PNG with pNGa chunk
 * @param {ArrayBuffer|Uint8Array} data
 * @returns {Promise<Uint8Array|null>} Audio WASM bytes or null if no audio
 */
export async function extractAudio(data) {
  const b = data instanceof Uint8Array ? data : new Uint8Array(data);
  if (!isPng(b)) return null;
  const chunk = findChunk(b, PNGA_CHUNK);
  return chunk ? parsePngaChunk(chunk) : null;
}

/**
 * Parse pNGa chunk data (same format as pNGb: version + flags + data)
 * @param {Uint8Array} data
 * @returns {Promise<Uint8Array>}
 */
async function parsePngaChunk(data) {
  if (data.length < 2) throw new Error("Invalid pNGa chunk");

  const flags = data[1];
  const payload = data.subarray(2);

  if (flags & 1) {
    return inflateRaw(payload);
  }
  return new Uint8Array(payload);
}

// Little-endian readers (ZIP central directory / local headers)
const readU16LE = (b, o) => b[o] | (b[o + 1] << 8);
const readU32LE = (b, o) => (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0;
