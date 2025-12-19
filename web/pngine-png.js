/**
 * PNGine PNG Extraction
 *
 * Extracts PNGB bytecode from PNG files with embedded pNGb chunks.
 * Works in browsers - parses PNG chunk structure to find and extract bytecode.
 */

/**
 * PNG file signature.
 */
const PNG_SIGNATURE = new Uint8Array([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

/**
 * pNGb chunk type as 4-byte array (bytecode).
 */
const PNGB_CHUNK_TYPE = new Uint8Array([0x70, 0x4E, 0x47, 0x62]); // 'pNGb'

/**
 * pNGm chunk type as 4-byte array (animation metadata).
 */
const PNGM_CHUNK_TYPE = new Uint8Array([0x70, 0x4E, 0x47, 0x6D]); // 'pNGm'

/**
 * Current pNGb format version.
 */
const PNGB_VERSION = 0x01;

/**
 * Flag indicating compressed payload.
 */
const FLAG_COMPRESSED = 0x01;

/**
 * Check if PNG data contains a pNGb chunk.
 *
 * @param {ArrayBuffer|Uint8Array} data - PNG file data
 * @returns {boolean} True if pNGb chunk exists
 */
export function hasPngb(data) {
    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);

    // Check PNG signature
    if (bytes.length < 8) return false;
    for (let i = 0; i < 8; i++) {
        if (bytes[i] !== PNG_SIGNATURE[i]) return false;
    }

    // Scan chunks for pNGb
    let pos = 8;
    while (pos + 12 <= bytes.length) {
        const length = readUint32BE(bytes, pos);
        const chunkType = bytes.slice(pos + 4, pos + 8);

        if (chunkTypesEqual(chunkType, PNGB_CHUNK_TYPE)) {
            return true;
        }

        // Move to next chunk: length(4) + type(4) + data(length) + crc(4)
        pos += 12 + length;
    }

    return false;
}

/**
 * Get pNGb chunk info without full extraction.
 *
 * @param {ArrayBuffer|Uint8Array} data - PNG file data
 * @returns {Object|null} Info object or null if not found
 */
export function getPngbInfo(data) {
    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);

    // Check PNG signature
    if (bytes.length < 8) return null;
    for (let i = 0; i < 8; i++) {
        if (bytes[i] !== PNG_SIGNATURE[i]) return null;
    }

    // Scan chunks for pNGb
    let pos = 8;
    while (pos + 12 <= bytes.length) {
        const length = readUint32BE(bytes, pos);
        const chunkType = bytes.slice(pos + 4, pos + 8);

        if (chunkTypesEqual(chunkType, PNGB_CHUNK_TYPE)) {
            const chunkData = bytes.slice(pos + 8, pos + 8 + length);

            if (chunkData.length < 2) return null;

            const version = chunkData[0];
            const flags = chunkData[1];
            const compressed = (flags & FLAG_COMPRESSED) !== 0;
            const payloadSize = length - 2;

            return {
                version,
                compressed,
                payloadSize,
            };
        }

        pos += 12 + length;
    }

    return null;
}

/**
 * Extract PNGB bytecode from PNG data.
 *
 * @param {ArrayBuffer|Uint8Array} data - PNG file data
 * @returns {Promise<Uint8Array>} Extracted PNGB bytecode
 * @throws {Error} If PNG is invalid or has no pNGb chunk
 */
export async function extractPngb(data) {
    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);

    // Validate PNG signature
    if (bytes.length < 8) {
        throw new Error('Invalid PNG: too short');
    }
    for (let i = 0; i < 8; i++) {
        if (bytes[i] !== PNG_SIGNATURE[i]) {
            throw new Error('Invalid PNG: bad signature');
        }
    }

    // Scan chunks for pNGb
    let pos = 8;
    while (pos + 12 <= bytes.length) {
        const length = readUint32BE(bytes, pos);
        const chunkType = bytes.slice(pos + 4, pos + 8);

        if (chunkTypesEqual(chunkType, PNGB_CHUNK_TYPE)) {
            const chunkData = bytes.slice(pos + 8, pos + 8 + length);
            return await parsePngbChunk(chunkData);
        }

        pos += 12 + length;
    }

    throw new Error('No pNGb chunk found in PNG');
}

/**
 * Parse pNGb chunk data to extract bytecode.
 *
 * @param {Uint8Array} data - pNGb chunk data (after type, before CRC)
 * @returns {Promise<Uint8Array>} Extracted bytecode
 * @throws {Error} If chunk format is invalid
 */
async function parsePngbChunk(data) {
    if (data.length < 3) {
        throw new Error('Invalid pNGb chunk: too short');
    }

    const version = data[0];
    const flags = data[1];
    const payload = data.slice(2);

    // Check version
    if (version !== PNGB_VERSION) {
        throw new Error(`Unsupported pNGb version: ${version}`);
    }

    // Check compression flag
    const isCompressed = (flags & FLAG_COMPRESSED) !== 0;
    if (isCompressed) {
        // Decompress using browser's DecompressionStream API
        return await decompressDeflateRaw(payload);
    }

    // Return raw payload (copy to ensure ownership)
    return new Uint8Array(payload);
}

/**
 * Decompress deflate-raw data using browser's DecompressionStream.
 *
 * @param {Uint8Array} compressed - Compressed data
 * @returns {Promise<Uint8Array>} Decompressed data
 */
async function decompressDeflateRaw(compressed) {
    // Use browser's built-in DecompressionStream API
    const ds = new DecompressionStream('deflate-raw');
    const writer = ds.writable.getWriter();
    const reader = ds.readable.getReader();

    // Write compressed data and close
    writer.write(compressed);
    writer.close();

    // Read all decompressed chunks
    const chunks = [];
    let totalLength = 0;

    while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        chunks.push(value);
        totalLength += value.length;
    }

    // Combine into single Uint8Array
    const result = new Uint8Array(totalLength);
    let offset = 0;
    for (const chunk of chunks) {
        result.set(chunk, offset);
        offset += chunk.length;
    }

    return result;
}

/**
 * Fetch PNG from URL and extract bytecode.
 *
 * @param {string} url - URL of PNG file
 * @returns {Promise<Uint8Array>} Extracted PNGB bytecode
 */
export async function fetchAndExtract(url) {
    const response = await fetch(url);
    if (!response.ok) {
        throw new Error(`Failed to fetch PNG: ${response.status}`);
    }

    const buffer = await response.arrayBuffer();
    return extractPngb(buffer);
}

/**
 * Read 32-bit big-endian unsigned integer from bytes.
 *
 * @param {Uint8Array} bytes - Byte array
 * @param {number} offset - Start offset
 * @returns {number} Parsed integer
 */
function readUint32BE(bytes, offset) {
    return (
        (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3]
    ) >>> 0;
}

/**
 * Compare two chunk types.
 *
 * @param {Uint8Array} a - First chunk type
 * @param {Uint8Array} b - Second chunk type
 * @returns {boolean} True if equal
 */
function chunkTypesEqual(a, b) {
    return a[0] === b[0] && a[1] === b[1] && a[2] === b[2] && a[3] === b[3];
}

/**
 * Check if PNG data contains a pNGm (animation metadata) chunk.
 *
 * @param {ArrayBuffer|Uint8Array} data - PNG file data
 * @returns {boolean} True if pNGm chunk exists
 */
export function hasPngm(data) {
    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);

    // Check PNG signature
    if (bytes.length < 8) return false;
    for (let i = 0; i < 8; i++) {
        if (bytes[i] !== PNG_SIGNATURE[i]) return false;
    }

    // Scan chunks for pNGm
    let pos = 8;
    while (pos + 12 <= bytes.length) {
        const length = readUint32BE(bytes, pos);
        const chunkType = bytes.slice(pos + 4, pos + 8);

        if (chunkTypesEqual(chunkType, PNGM_CHUNK_TYPE)) {
            return true;
        }

        // Move to next chunk: length(4) + type(4) + data(length) + crc(4)
        pos += 12 + length;
    }

    return false;
}

/**
 * Extract animation metadata from PNG data.
 *
 * @param {ArrayBuffer|Uint8Array} data - PNG file data
 * @returns {Promise<Object|null>} Animation metadata object or null if not found
 */
export async function extractPngm(data) {
    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);

    // Validate PNG signature
    if (bytes.length < 8) {
        return null;
    }
    for (let i = 0; i < 8; i++) {
        if (bytes[i] !== PNG_SIGNATURE[i]) {
            return null;
        }
    }

    // Scan chunks for pNGm
    let pos = 8;
    while (pos + 12 <= bytes.length) {
        const length = readUint32BE(bytes, pos);
        const chunkType = bytes.slice(pos + 4, pos + 8);

        if (chunkTypesEqual(chunkType, PNGM_CHUNK_TYPE)) {
            const chunkData = bytes.slice(pos + 8, pos + 8 + length);
            return await parsePngmChunk(chunkData);
        }

        pos += 12 + length;
    }

    return null;
}

/**
 * Parse pNGm chunk data to extract metadata.
 *
 * @param {Uint8Array} data - pNGm chunk data (after type, before CRC)
 * @returns {Promise<Object>} Parsed metadata
 */
async function parsePngmChunk(data) {
    if (data.length < 2) {
        throw new Error('Invalid pNGm chunk: too short');
    }

    const version = data[0];
    const flags = data[1];
    const payload = data.slice(2);

    // Check version
    if (version !== 0x01) {
        throw new Error(`Unsupported pNGm version: ${version}`);
    }

    // Check compression flag
    const isCompressed = (flags & FLAG_COMPRESSED) !== 0;
    let jsonBytes;
    if (isCompressed) {
        jsonBytes = await decompressDeflateRaw(payload);
    } else {
        jsonBytes = payload;
    }

    // Parse JSON
    const jsonStr = new TextDecoder().decode(jsonBytes);
    return JSON.parse(jsonStr);
}

/**
 * Extract both bytecode and metadata from PNG.
 *
 * @param {ArrayBuffer|Uint8Array} data - PNG file data
 * @returns {Promise<{bytecode: Uint8Array, metadata: Object|null}>}
 */
export async function extractAll(data) {
    const bytecode = await extractPngb(data);
    const metadata = await extractPngm(data);
    return { bytecode, metadata };
}
