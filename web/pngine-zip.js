/**
 * PNGine ZIP Extraction
 *
 * Extracts PNGB bytecode from ZIP bundles.
 * Implements minimal ZIP parsing (no external dependencies).
 *
 * ZIP Bundle Structure:
 *   manifest.json  - {"version":1,"entry":"main.pngb","runtime":"pngine.wasm"}
 *   main.pngb      - Compiled bytecode
 *   pngine.wasm    - Optional WASM runtime
 *   assets/        - Optional assets
 */

/**
 * ZIP file signatures.
 */
const LOCAL_FILE_SIGNATURE = 0x04034b50;
const CENTRAL_DIR_SIGNATURE = 0x02014b50;
const END_OF_CENTRAL_DIR_SIGNATURE = 0x06054b50;

/**
 * Compression methods.
 */
const COMPRESSION_STORE = 0;
const COMPRESSION_DEFLATE = 8;

/**
 * Check if data is a ZIP file by magic bytes.
 *
 * @param {ArrayBuffer|Uint8Array} data - File data
 * @returns {boolean} True if ZIP format
 */
export function isZip(data) {
    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
    if (bytes.length < 4) return false;

    // ZIP starts with 'PK\x03\x04' or 'PK\x05\x06' (empty) or 'PK\x07\x08' (spanned)
    return bytes[0] === 0x50 && bytes[1] === 0x4B &&
           (bytes[2] === 0x03 || bytes[2] === 0x05 || bytes[2] === 0x07);
}

/**
 * ZIP entry information.
 */
class ZipEntry {
    constructor(filename, compressedSize, uncompressedSize, compression, dataOffset) {
        this.filename = filename;
        this.compressedSize = compressedSize;
        this.uncompressedSize = uncompressedSize;
        this.compression = compression;
        this.dataOffset = dataOffset;
    }
}

/**
 * Minimal ZIP reader.
 */
export class ZipReader {
    /**
     * @param {ArrayBuffer|Uint8Array} data - ZIP file data
     */
    constructor(data) {
        this.data = data instanceof Uint8Array ? data : new Uint8Array(data);
        this.entries = new Map();
        this._parse();
    }

    /**
     * Parse ZIP structure.
     * @private
     */
    _parse() {
        // Find End of Central Directory (scan backwards)
        const eocdOffset = this._findEocd();
        if (eocdOffset === -1) {
            throw new Error('Invalid ZIP: End of Central Directory not found');
        }

        // Read EOCD
        const eocd = this._readEocd(eocdOffset);

        // Parse Central Directory entries
        let offset = eocd.centralDirOffset;
        for (let i = 0; i < eocd.totalEntries; i++) {
            const entry = this._readCentralDirEntry(offset);
            this.entries.set(entry.filename, entry);
            offset += 46 + entry.filename.length + entry.extraLen + entry.commentLen;
        }
    }

    /**
     * Find End of Central Directory by scanning backwards.
     * @private
     * @returns {number} Offset or -1 if not found
     */
    _findEocd() {
        // EOCD is at least 22 bytes, with optional comment up to 65535 bytes
        const minSize = 22;
        const maxSearch = Math.min(this.data.length, 65557);

        for (let i = minSize; i <= maxSearch; i++) {
            const offset = this.data.length - i;
            if (this._readUint32LE(offset) === END_OF_CENTRAL_DIR_SIGNATURE) {
                return offset;
            }
        }
        return -1;
    }

    /**
     * Read End of Central Directory record.
     * @private
     */
    _readEocd(offset) {
        return {
            signature: this._readUint32LE(offset),
            diskNumber: this._readUint16LE(offset + 4),
            centralDirDisk: this._readUint16LE(offset + 6),
            entriesOnDisk: this._readUint16LE(offset + 8),
            totalEntries: this._readUint16LE(offset + 10),
            centralDirSize: this._readUint32LE(offset + 12),
            centralDirOffset: this._readUint32LE(offset + 16),
            commentLen: this._readUint16LE(offset + 20),
        };
    }

    /**
     * Read Central Directory entry.
     * @private
     */
    _readCentralDirEntry(offset) {
        const signature = this._readUint32LE(offset);
        if (signature !== CENTRAL_DIR_SIGNATURE) {
            throw new Error('Invalid Central Directory entry');
        }

        const compression = this._readUint16LE(offset + 10);
        const compressedSize = this._readUint32LE(offset + 20);
        const uncompressedSize = this._readUint32LE(offset + 24);
        const filenameLen = this._readUint16LE(offset + 28);
        const extraLen = this._readUint16LE(offset + 30);
        const commentLen = this._readUint16LE(offset + 32);
        const localHeaderOffset = this._readUint32LE(offset + 42);

        // Read filename
        const filenameBytes = this.data.slice(offset + 46, offset + 46 + filenameLen);
        const filename = new TextDecoder().decode(filenameBytes);

        // Calculate actual data offset from local file header
        const localExtraLen = this._readUint16LE(localHeaderOffset + 28);
        const dataOffset = localHeaderOffset + 30 + filenameLen + localExtraLen;

        return {
            filename,
            compressedSize,
            uncompressedSize,
            compression,
            dataOffset,
            extraLen,
            commentLen,
        };
    }

    /**
     * Extract file by name.
     *
     * @param {string} filename - File path within ZIP
     * @returns {Promise<Uint8Array>} Extracted data
     */
    async extract(filename) {
        const entry = this.entries.get(filename);
        if (!entry) {
            throw new Error(`File not found in ZIP: ${filename}`);
        }

        const compressedData = this.data.slice(
            entry.dataOffset,
            entry.dataOffset + entry.compressedSize
        );

        if (entry.compression === COMPRESSION_STORE) {
            // No compression - return copy
            return new Uint8Array(compressedData);
        } else if (entry.compression === COMPRESSION_DEFLATE) {
            // Decompress using browser's DecompressionStream
            return await this._decompressDeflate(compressedData);
        } else {
            throw new Error(`Unsupported compression method: ${entry.compression}`);
        }
    }

    /**
     * Decompress DEFLATE data using browser API.
     * @private
     */
    async _decompressDeflate(compressed) {
        const ds = new DecompressionStream('deflate-raw');
        const writer = ds.writable.getWriter();
        const reader = ds.readable.getReader();

        writer.write(compressed);
        writer.close();

        const chunks = [];
        let totalLength = 0;

        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            chunks.push(value);
            totalLength += value.length;
        }

        const result = new Uint8Array(totalLength);
        let offset = 0;
        for (const chunk of chunks) {
            result.set(chunk, offset);
            offset += chunk.length;
        }

        return result;
    }

    /**
     * List all files in the archive.
     * @returns {string[]} List of filenames
     */
    list() {
        return Array.from(this.entries.keys());
    }

    /**
     * Check if file exists.
     * @param {string} filename - File path
     * @returns {boolean}
     */
    has(filename) {
        return this.entries.has(filename);
    }

    // Helper methods for reading little-endian integers
    _readUint16LE(offset) {
        return this.data[offset] | (this.data[offset + 1] << 8);
    }

    _readUint32LE(offset) {
        return (
            this.data[offset] |
            (this.data[offset + 1] << 8) |
            (this.data[offset + 2] << 16) |
            (this.data[offset + 3] << 24)
        ) >>> 0;
    }
}

/**
 * Extract bytecode from a ZIP bundle.
 *
 * Reads manifest.json to find the entry point, then extracts the bytecode.
 *
 * @param {ArrayBuffer|Uint8Array} data - ZIP file data
 * @returns {Promise<Uint8Array>} Extracted PNGB bytecode
 */
export async function extractFromZip(data) {
    const zip = new ZipReader(data);

    // Read manifest
    if (!zip.has('manifest.json')) {
        throw new Error('ZIP bundle missing manifest.json');
    }

    const manifestBytes = await zip.extract('manifest.json');
    const manifestText = new TextDecoder().decode(manifestBytes);
    const manifest = JSON.parse(manifestText);

    // Validate manifest
    if (typeof manifest.version !== 'number' || manifest.version < 1) {
        throw new Error('Invalid manifest version');
    }
    if (typeof manifest.entry !== 'string') {
        throw new Error('Manifest missing entry point');
    }

    // Extract bytecode
    const bytecode = await zip.extract(manifest.entry);
    return bytecode;
}

/**
 * Get ZIP bundle info without full extraction.
 *
 * @param {ArrayBuffer|Uint8Array} data - ZIP file data
 * @returns {Promise<Object>} Bundle info
 */
export async function getZipBundleInfo(data) {
    const zip = new ZipReader(data);

    const files = zip.list();

    // Try to read manifest
    let manifest = null;
    if (zip.has('manifest.json')) {
        const manifestBytes = await zip.extract('manifest.json');
        const manifestText = new TextDecoder().decode(manifestBytes);
        manifest = JSON.parse(manifestText);
    }

    return {
        files,
        manifest,
        hasRuntime: zip.has('pngine.wasm'),
    };
}

/**
 * Fetch ZIP from URL and extract bytecode.
 *
 * @param {string} url - URL of ZIP file
 * @returns {Promise<Uint8Array>} Extracted PNGB bytecode
 */
export async function fetchAndExtractZip(url) {
    const response = await fetch(url);
    if (!response.ok) {
        throw new Error(`Failed to fetch ZIP: ${response.status}`);
    }

    const buffer = await response.arrayBuffer();
    return extractFromZip(buffer);
}
