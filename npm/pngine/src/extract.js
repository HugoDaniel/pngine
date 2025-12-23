// Bytecode extraction from PNG and ZIP files
// Runs on main thread

const PNG_SIG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const PNGB_CHUNK = [0x70, 0x4e, 0x47, 0x62]; // 'pNGb'

/**
 * Check if data is PNG
 * @param {Uint8Array} b
 */
export const isPng = (b) =>
  b.length >= 8 && PNG_SIG.every((v, i) => b[i] === v);

/**
 * Check if data is ZIP
 * @param {Uint8Array} b
 */
export const isZip = (b) =>
  b.length >= 4 && b[0] === 0x50 && b[1] === 0x4b && (b[2] === 0x03 || b[2] === 0x05);

/**
 * Check if data is PNGB bytecode
 * @param {Uint8Array} b
 */
export const isPngb = (b) =>
  b.length >= 4 && b[0] === 0x50 && b[1] === 0x4e && b[2] === 0x47 && b[3] === 0x42;

/**
 * Detect format
 * @param {Uint8Array} b
 * @returns {'png'|'zip'|'pngb'|null}
 */
export function detectFormat(b) {
  if (isZip(b)) return "zip";
  if (isPng(b)) return "png";
  if (isPngb(b)) return "pngb";
  return null;
}

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

  let pos = 8;
  while (pos + 12 <= b.length) {
    const len = readU32BE(b, pos);
    const type = b.subarray(pos + 4, pos + 8);

    if (type[0] === PNGB_CHUNK[0] && type[1] === PNGB_CHUNK[1] &&
        type[2] === PNGB_CHUNK[2] && type[3] === PNGB_CHUNK[3]) {
      const chunk = b.subarray(pos + 8, pos + 8 + len);
      return parsePngbChunk(chunk);
    }
    pos += 12 + len;
  }

  throw new Error("No pNGb chunk found");
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
    return decompress(payload);
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
  if (entry.compression === 8) return decompress(data);
  throw new Error(`Unsupported compression: ${entry.compression}`);
}

/**
 * Decompress deflate-raw data
 * @param {Uint8Array} data
 * @returns {Promise<Uint8Array>}
 */
async function decompress(data) {
  const ds = new DecompressionStream("deflate-raw");
  const writer = ds.writable.getWriter();
  const reader = ds.readable.getReader();

  writer.write(data);
  writer.close();

  const chunks = [];
  let len = 0;

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    len += value.length;
  }

  const result = new Uint8Array(len);
  let off = 0;
  for (const c of chunks) {
    result.set(c, off);
    off += c.length;
  }

  return result;
}

// Little-endian readers
const readU16LE = (b, o) => b[o] | (b[o + 1] << 8);
const readU32LE = (b, o) => (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0;
const readU32BE = (b, o) => ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) >>> 0;
