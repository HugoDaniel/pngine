/**
 * PNGine Loader
 *
 * Main thread entry point that proxies all GPU operations to a WebWorker.
 * Provides the same high-level API but executes everything in a Worker.
 */

import { MessageType, ErrorCode, getErrorMessage } from './pngine-protocol.js';
import { extractPngb, fetchAndExtract, hasPngb, getPngbInfo, hasPngm, extractPngm, extractAll } from './pngine-png.js';
import { isZip, extractFromZip, fetchAndExtractZip, getZipBundleInfo, ZipReader } from './pngine-zip.js';

// Re-export PNG utilities
export { extractPngb, fetchAndExtract, hasPngb, getPngbInfo, hasPngm, extractPngm, extractAll };

// Re-export ZIP utilities
export { isZip, extractFromZip, fetchAndExtractZip, getZipBundleInfo, ZipReader };

// Re-export protocol types
export { MessageType, ErrorCode, getErrorMessage };

// ============================================================================
// Debug Mode
// ============================================================================

/**
 * Debug mode state.
 * Enable via:
 *   - URL parameter: ?debug=true
 *   - Console: PNGine.setDebug(true)
 *   - Console: localStorage.setItem('pngine_debug', 'true')
 */
let debugEnabled = false;

// Check URL parameter
if (typeof window !== 'undefined') {
    const urlParams = new URLSearchParams(window.location.search);
    if (urlParams.get('debug') === 'true' || urlParams.get('debug') === '1') {
        debugEnabled = true;
    }
    // Check localStorage
    if (localStorage.getItem('pngine_debug') === 'true') {
        debugEnabled = true;
    }
}

/**
 * Debug logger - only logs when debug mode is enabled.
 */
const debug = {
    log: (...args) => debugEnabled && console.log('[PNGine]', ...args),
    warn: (...args) => debugEnabled && console.warn('[PNGine]', ...args),
    error: (...args) => console.error('[PNGine]', ...args),  // Always log errors
};

/**
 * Enable or disable debug mode.
 * @param {boolean} enabled
 */
export function setDebug(enabled) {
    debugEnabled = enabled;
    localStorage.setItem('pngine_debug', enabled ? 'true' : 'false');
    debug.log(`Debug mode ${enabled ? 'enabled' : 'disabled'}`);
}

/**
 * Check if debug mode is enabled.
 * @returns {boolean}
 */
export function isDebugEnabled() {
    return debugEnabled;
}

// ============================================================================
// WorkerRPC - Promise-based Worker Communication
// ============================================================================

/**
 * Promise-based RPC wrapper for Worker communication.
 */
class WorkerRPC {
    /**
     * @param {Worker} worker - Web Worker instance
     */
    constructor(worker) {
        this.worker = worker;
        this.pending = new Map(); // id -> { resolve, reject }
        this.nextId = 1;

        worker.onmessage = (event) => this._handleMessage(event.data);
        worker.onerror = (error) => this._handleError(error);
    }

    /**
     * Call a Worker method.
     * @param {string} type - Message type
     * @param {Object} payload - Message payload
     * @param {Transferable[]} transfer - Transferable objects
     * @returns {Promise<any>} Response payload
     */
    call(type, payload = {}, transfer = []) {
        return new Promise((resolve, reject) => {
            const id = this.nextId++;
            this.pending.set(id, { resolve, reject });
            this.worker.postMessage({ id, type, payload }, transfer);
        });
    }

    /**
     * Fire-and-forget call (no response expected).
     * Used for animation frames where we don't want to block.
     * @param {string} type - Message type
     * @param {Object} payload - Message payload
     */
    fire(type, payload = {}) {
        const id = this.nextId++;
        // Don't store in pending - we won't wait for response
        this.worker.postMessage({ id, type, payload });
    }

    /**
     * Handle incoming message from Worker.
     * @param {Object} data - Message data
     */
    _handleMessage(data) {
        const { id, type, payload } = data;

        const pending = this.pending.get(id);
        if (!pending) {
            // Fire-and-forget message or unknown ID
            return;
        }

        this.pending.delete(id);

        if (type === MessageType.ERROR) {
            const error = new Error(payload.message);
            error.name = payload.name;
            error.code = payload.code;
            pending.reject(error);
        } else {
            pending.resolve(payload);
        }
    }

    /**
     * Handle Worker error.
     * @param {ErrorEvent} error
     */
    _handleError(error) {
        // Reject all pending calls
        for (const { reject } of this.pending.values()) {
            reject(new Error(`Worker error: ${error.message}`));
        }
        this.pending.clear();
    }

    /**
     * Terminate the Worker.
     */
    terminate() {
        this.worker.terminate();
        // Reject all pending calls
        for (const { reject } of this.pending.values()) {
            reject(new Error('Worker terminated'));
        }
        this.pending.clear();
    }
}

// ============================================================================
// Format Detection
// ============================================================================

/**
 * PNG file signature for format detection.
 */
const PNG_SIGNATURE = [0x89, 0x50, 0x4E, 0x47];

/**
 * Detect format from file data.
 *
 * @param {Uint8Array} bytes - File data
 * @returns {'png'|'zip'|'pngb'|null} Detected format
 */
export function detectFormat(bytes) {
    if (bytes.length < 4) return null;

    // ZIP: starts with 'PK'
    if (bytes[0] === 0x50 && bytes[1] === 0x4B) {
        return 'zip';
    }

    // PNG: starts with signature
    if (bytes[0] === 0x89 && bytes[1] === 0x50 &&
        bytes[2] === 0x4E && bytes[3] === 0x47) {
        return 'png';
    }

    // PNGB: starts with 'PNGB'
    if (bytes[0] === 0x50 && bytes[1] === 0x4E &&
        bytes[2] === 0x47 && bytes[3] === 0x42) {
        return 'pngb';
    }

    return null;
}

/**
 * Extract bytecode from any supported format.
 *
 * Auto-detects format (PNG, ZIP, or raw PNGB) and extracts bytecode.
 *
 * @param {ArrayBuffer|Uint8Array} data - File data
 * @returns {Promise<Uint8Array>} Extracted PNGB bytecode
 */
export async function extractBytecode(data) {
    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
    const format = detectFormat(bytes);

    switch (format) {
        case 'zip':
            return extractFromZip(bytes);
        case 'png':
            return extractPngb(bytes);
        case 'pngb':
            // Already bytecode - return copy
            return new Uint8Array(bytes);
        default:
            throw new Error('Unknown file format');
    }
}

/**
 * Fetch from URL and extract bytecode (auto-detects format).
 *
 * @param {string} url - URL of PNG, ZIP, or PNGB file
 * @returns {Promise<Uint8Array>} Extracted PNGB bytecode
 */
export async function fetchBytecode(url) {
    const response = await fetch(url);
    if (!response.ok) {
        throw new Error(`Failed to fetch: ${response.status}`);
    }

    const buffer = await response.arrayBuffer();
    return extractBytecode(buffer);
}

// ============================================================================
// Initialization Functions
// ============================================================================

/**
 * Initialize PNGine with WebGPU via WebWorker.
 *
 * IMPORTANT: This function requires OffscreenCanvas support.
 * All GPU operations happen in the Worker thread.
 *
 * @param {HTMLCanvasElement} canvas - Canvas element for rendering
 * @param {string} wasmUrl - URL to pngine.wasm file
 * @param {string} workerUrl - URL to pngine-worker.js file
 * @returns {Promise<PNGine>} Initialized PNGine instance
 */

// Inline worker code as blob URL
const WORKER_CODE = "// === pngine-protocol.js ===\n/**\n * PNGine Worker Protocol\n *\n * Shared message type definitions for main thread <-> Worker communication.\n */\n\n/**\n * Message types for Worker RPC.\n */\nconst MessageType = {\n    // Lifecycle\n    INIT: 'init',\n    TERMINATE: 'terminate',\n\n    // Compilation\n    COMPILE: 'compile',\n\n    // Module management\n    LOAD_MODULE: 'loadModule',\n    LOAD_FROM_URL: 'loadFromUrl',\n    FREE_MODULE: 'freeModule',\n\n    // Execution\n    EXECUTE_ALL: 'executeAll',\n    EXECUTE_FRAME: 'executeFrame',\n    RENDER_FRAME: 'renderFrame',\n\n    // Query\n    GET_FRAME_COUNT: 'getFrameCount',\n    GET_METADATA: 'getMetadata',\n    FIND_UNIFORM_BUFFER: 'findUniformBuffer',\n\n    // Debug\n    SET_DEBUG: 'setDebug',\n\n    // Response types\n    RESPONSE: 'response',\n    ERROR: 'error',\n};\n\n/**\n * Error codes returned by WASM functions.\n */\nconst ErrorCode = {\n    SUCCESS: 0,\n    NOT_INITIALIZED: 1,\n    OUT_OF_MEMORY: 2,\n    PARSE_ERROR: 3,\n    INVALID_FORMAT: 4,\n    NO_MODULE: 5,\n    EXECUTION_ERROR: 6,\n    // Assembler errors (10-29)\n    UNKNOWN_FORM: 10,\n    INVALID_FORM_STRUCTURE: 11,\n    UNDEFINED_RESOURCE: 12,\n    DUPLICATE_RESOURCE: 13,\n    TOO_MANY_RESOURCES: 14,\n    EXPECTED_ATOM: 15,\n    EXPECTED_STRING: 16,\n    EXPECTED_NUMBER: 17,\n    EXPECTED_LIST: 18,\n    INVALID_RESOURCE_ID: 19,\n    UNKNOWN: 99,\n};\n\n/**\n * Get human-readable error message.\n * @param {number} code - Error code\n * @returns {string} Error message\n */\nfunction getErrorMessage(code) {\n    switch (code) {\n        case ErrorCode.NOT_INITIALIZED: return 'WASM not initialized';\n        case ErrorCode.OUT_OF_MEMORY: return 'Out of memory';\n        case ErrorCode.PARSE_ERROR: return 'Parse error';\n        case ErrorCode.INVALID_FORMAT: return 'Invalid bytecode format';\n        case ErrorCode.NO_MODULE: return 'No module loaded';\n        case ErrorCode.EXECUTION_ERROR: return 'Execution error';\n        case ErrorCode.UNKNOWN_FORM: return 'Unknown PBSF form';\n        case ErrorCode.INVALID_FORM_STRUCTURE: return 'Invalid form structure';\n        case ErrorCode.UNDEFINED_RESOURCE: return 'Undefined resource reference';\n        case ErrorCode.DUPLICATE_RESOURCE: return 'Duplicate resource ID';\n        case ErrorCode.TOO_MANY_RESOURCES: return 'Too many resources';\n        case ErrorCode.EXPECTED_ATOM: return 'Expected atom';\n        case ErrorCode.EXPECTED_STRING: return 'Expected string';\n        case ErrorCode.EXPECTED_NUMBER: return 'Expected number';\n        case ErrorCode.EXPECTED_LIST: return 'Expected list';\n        case ErrorCode.INVALID_RESOURCE_ID: return 'Invalid resource ID format';\n        default: return `Unknown error (${code})`;\n    }\n}\n\n\n// === pngine-png.js ===\n/**\n * PNGine PNG Extraction\n *\n * Extracts PNGB bytecode from PNG files with embedded pNGb chunks.\n * Works in browsers - parses PNG chunk structure to find and extract bytecode.\n */\n\n/**\n * PNG file signature.\n */\nconst PNG_SIGNATURE = new Uint8Array([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);\n\n/**\n * pNGb chunk type as 4-byte array (bytecode).\n */\nconst PNGB_CHUNK_TYPE = new Uint8Array([0x70, 0x4E, 0x47, 0x62]); // 'pNGb'\n\n/**\n * pNGm chunk type as 4-byte array (animation metadata).\n */\nconst PNGM_CHUNK_TYPE = new Uint8Array([0x70, 0x4E, 0x47, 0x6D]); // 'pNGm'\n\n/**\n * Current pNGb format version.\n */\nconst PNGB_VERSION = 0x01;\n\n/**\n * Flag indicating compressed payload.\n */\nconst FLAG_COMPRESSED = 0x01;\n\n/**\n * Check if PNG data contains a pNGb chunk.\n *\n * @param {ArrayBuffer|Uint8Array} data - PNG file data\n * @returns {boolean} True if pNGb chunk exists\n */\nfunction hasPngb(data) {\n    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);\n\n    // Check PNG signature\n    if (bytes.length < 8) return false;\n    for (let i = 0; i < 8; i++) {\n        if (bytes[i] !== PNG_SIGNATURE[i]) return false;\n    }\n\n    // Scan chunks for pNGb\n    let pos = 8;\n    while (pos + 12 <= bytes.length) {\n        const length = readUint32BE(bytes, pos);\n        const chunkType = bytes.slice(pos + 4, pos + 8);\n\n        if (chunkTypesEqual(chunkType, PNGB_CHUNK_TYPE)) {\n            return true;\n        }\n\n        // Move to next chunk: length(4) + type(4) + data(length) + crc(4)\n        pos += 12 + length;\n    }\n\n    return false;\n}\n\n/**\n * Get pNGb chunk info without full extraction.\n *\n * @param {ArrayBuffer|Uint8Array} data - PNG file data\n * @returns {Object|null} Info object or null if not found\n */\nfunction getPngbInfo(data) {\n    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);\n\n    // Check PNG signature\n    if (bytes.length < 8) return null;\n    for (let i = 0; i < 8; i++) {\n        if (bytes[i] !== PNG_SIGNATURE[i]) return null;\n    }\n\n    // Scan chunks for pNGb\n    let pos = 8;\n    while (pos + 12 <= bytes.length) {\n        const length = readUint32BE(bytes, pos);\n        const chunkType = bytes.slice(pos + 4, pos + 8);\n\n        if (chunkTypesEqual(chunkType, PNGB_CHUNK_TYPE)) {\n            const chunkData = bytes.slice(pos + 8, pos + 8 + length);\n\n            if (chunkData.length < 2) return null;\n\n            const version = chunkData[0];\n            const flags = chunkData[1];\n            const compressed = (flags & FLAG_COMPRESSED) !== 0;\n            const payloadSize = length - 2;\n\n            return {\n                version,\n                compressed,\n                payloadSize,\n            };\n        }\n\n        pos += 12 + length;\n    }\n\n    return null;\n}\n\n/**\n * Extract PNGB bytecode from PNG data.\n *\n * @param {ArrayBuffer|Uint8Array} data - PNG file data\n * @returns {Promise<Uint8Array>} Extracted PNGB bytecode\n * @throws {Error} If PNG is invalid or has no pNGb chunk\n */\nasync function extractPngb(data) {\n    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);\n\n    // Validate PNG signature\n    if (bytes.length < 8) {\n        throw new Error('Invalid PNG: too short');\n    }\n    for (let i = 0; i < 8; i++) {\n        if (bytes[i] !== PNG_SIGNATURE[i]) {\n            throw new Error('Invalid PNG: bad signature');\n        }\n    }\n\n    // Scan chunks for pNGb\n    let pos = 8;\n    while (pos + 12 <= bytes.length) {\n        const length = readUint32BE(bytes, pos);\n        const chunkType = bytes.slice(pos + 4, pos + 8);\n\n        if (chunkTypesEqual(chunkType, PNGB_CHUNK_TYPE)) {\n            const chunkData = bytes.slice(pos + 8, pos + 8 + length);\n            return await parsePngbChunk(chunkData);\n        }\n\n        pos += 12 + length;\n    }\n\n    throw new Error('No pNGb chunk found in PNG');\n}\n\n/**\n * Parse pNGb chunk data to extract bytecode.\n *\n * @param {Uint8Array} data - pNGb chunk data (after type, before CRC)\n * @returns {Promise<Uint8Array>} Extracted bytecode\n * @throws {Error} If chunk format is invalid\n */\nasync function parsePngbChunk(data) {\n    if (data.length < 3) {\n        throw new Error('Invalid pNGb chunk: too short');\n    }\n\n    const version = data[0];\n    const flags = data[1];\n    const payload = data.slice(2);\n\n    // Check version\n    if (version !== PNGB_VERSION) {\n        throw new Error(`Unsupported pNGb version: ${version}`);\n    }\n\n    // Check compression flag\n    const isCompressed = (flags & FLAG_COMPRESSED) !== 0;\n    if (isCompressed) {\n        // Decompress using browser's DecompressionStream API\n        return await decompressDeflateRaw(payload);\n    }\n\n    // Return raw payload (copy to ensure ownership)\n    return new Uint8Array(payload);\n}\n\n/**\n * Decompress deflate-raw data using browser's DecompressionStream.\n *\n * @param {Uint8Array} compressed - Compressed data\n * @returns {Promise<Uint8Array>} Decompressed data\n */\nasync function decompressDeflateRaw(compressed) {\n    // Use browser's built-in DecompressionStream API\n    const ds = new DecompressionStream('deflate-raw');\n    const writer = ds.writable.getWriter();\n    const reader = ds.readable.getReader();\n\n    // Write compressed data and close\n    writer.write(compressed);\n    writer.close();\n\n    // Read all decompressed chunks\n    const chunks = [];\n    let totalLength = 0;\n\n    while (true) {\n        const { done, value } = await reader.read();\n        if (done) break;\n        chunks.push(value);\n        totalLength += value.length;\n    }\n\n    // Combine into single Uint8Array\n    const result = new Uint8Array(totalLength);\n    let offset = 0;\n    for (const chunk of chunks) {\n        result.set(chunk, offset);\n        offset += chunk.length;\n    }\n\n    return result;\n}\n\n/**\n * Fetch PNG from URL and extract bytecode.\n *\n * @param {string} url - URL of PNG file\n * @returns {Promise<Uint8Array>} Extracted PNGB bytecode\n */\nasync function fetchAndExtract(url) {\n    const response = await fetch(url);\n    if (!response.ok) {\n        throw new Error(`Failed to fetch PNG: ${response.status}`);\n    }\n\n    const buffer = await response.arrayBuffer();\n    return extractPngb(buffer);\n}\n\n/**\n * Read 32-bit big-endian unsigned integer from bytes.\n *\n * @param {Uint8Array} bytes - Byte array\n * @param {number} offset - Start offset\n * @returns {number} Parsed integer\n */\nfunction readUint32BE(bytes, offset) {\n    return (\n        (bytes[offset] << 24) |\n        (bytes[offset + 1] << 16) |\n        (bytes[offset + 2] << 8) |\n        bytes[offset + 3]\n    ) >>> 0;\n}\n\n/**\n * Compare two chunk types.\n *\n * @param {Uint8Array} a - First chunk type\n * @param {Uint8Array} b - Second chunk type\n * @returns {boolean} True if equal\n */\nfunction chunkTypesEqual(a, b) {\n    return a[0] === b[0] && a[1] === b[1] && a[2] === b[2] && a[3] === b[3];\n}\n\n/**\n * Check if PNG data contains a pNGm (animation metadata) chunk.\n *\n * @param {ArrayBuffer|Uint8Array} data - PNG file data\n * @returns {boolean} True if pNGm chunk exists\n */\nfunction hasPngm(data) {\n    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);\n\n    // Check PNG signature\n    if (bytes.length < 8) return false;\n    for (let i = 0; i < 8; i++) {\n        if (bytes[i] !== PNG_SIGNATURE[i]) return false;\n    }\n\n    // Scan chunks for pNGm\n    let pos = 8;\n    while (pos + 12 <= bytes.length) {\n        const length = readUint32BE(bytes, pos);\n        const chunkType = bytes.slice(pos + 4, pos + 8);\n\n        if (chunkTypesEqual(chunkType, PNGM_CHUNK_TYPE)) {\n            return true;\n        }\n\n        // Move to next chunk: length(4) + type(4) + data(length) + crc(4)\n        pos += 12 + length;\n    }\n\n    return false;\n}\n\n/**\n * Extract animation metadata from PNG data.\n *\n * @param {ArrayBuffer|Uint8Array} data - PNG file data\n * @returns {Promise<Object|null>} Animation metadata object or null if not found\n */\nasync function extractPngm(data) {\n    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);\n\n    // Validate PNG signature\n    if (bytes.length < 8) {\n        return null;\n    }\n    for (let i = 0; i < 8; i++) {\n        if (bytes[i] !== PNG_SIGNATURE[i]) {\n            return null;\n        }\n    }\n\n    // Scan chunks for pNGm\n    let pos = 8;\n    while (pos + 12 <= bytes.length) {\n        const length = readUint32BE(bytes, pos);\n        const chunkType = bytes.slice(pos + 4, pos + 8);\n\n        if (chunkTypesEqual(chunkType, PNGM_CHUNK_TYPE)) {\n            const chunkData = bytes.slice(pos + 8, pos + 8 + length);\n            return await parsePngmChunk(chunkData);\n        }\n\n        pos += 12 + length;\n    }\n\n    return null;\n}\n\n/**\n * Parse pNGm chunk data to extract metadata.\n *\n * @param {Uint8Array} data - pNGm chunk data (after type, before CRC)\n * @returns {Promise<Object>} Parsed metadata\n */\nasync function parsePngmChunk(data) {\n    if (data.length < 2) {\n        throw new Error('Invalid pNGm chunk: too short');\n    }\n\n    const version = data[0];\n    const flags = data[1];\n    const payload = data.slice(2);\n\n    // Check version\n    if (version !== 0x01) {\n        throw new Error(`Unsupported pNGm version: ${version}`);\n    }\n\n    // Check compression flag\n    const isCompressed = (flags & FLAG_COMPRESSED) !== 0;\n    let jsonBytes;\n    if (isCompressed) {\n        jsonBytes = await decompressDeflateRaw(payload);\n    } else {\n        jsonBytes = payload;\n    }\n\n    // Parse JSON\n    const jsonStr = new TextDecoder().decode(jsonBytes);\n    return JSON.parse(jsonStr);\n}\n\n/**\n * Extract both bytecode and metadata from PNG.\n *\n * @param {ArrayBuffer|Uint8Array} data - PNG file data\n * @returns {Promise<{bytecode: Uint8Array, metadata: Object|null}>}\n */\nasync function extractAll(data) {\n    const bytecode = await extractPngb(data);\n    const metadata = await extractPngm(data);\n    return { bytecode, metadata };\n}\n\n\n// === pngine-zip.js ===\n/**\n * PNGine ZIP Extraction\n *\n * Extracts PNGB bytecode from ZIP bundles.\n * Implements minimal ZIP parsing (no external dependencies).\n *\n * ZIP Bundle Structure:\n *   manifest.json  - {\"version\":1,\"entry\":\"main.pngb\",\"runtime\":\"pngine.wasm\"}\n *   main.pngb      - Compiled bytecode\n *   pngine.wasm    - Optional WASM runtime\n *   assets/        - Optional assets\n */\n\n/**\n * ZIP file signatures.\n */\nconst LOCAL_FILE_SIGNATURE = 0x04034b50;\nconst CENTRAL_DIR_SIGNATURE = 0x02014b50;\nconst END_OF_CENTRAL_DIR_SIGNATURE = 0x06054b50;\n\n/**\n * Compression methods.\n */\nconst COMPRESSION_STORE = 0;\nconst COMPRESSION_DEFLATE = 8;\n\n/**\n * Check if data is a ZIP file by magic bytes.\n *\n * @param {ArrayBuffer|Uint8Array} data - File data\n * @returns {boolean} True if ZIP format\n */\nfunction isZip(data) {\n    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);\n    if (bytes.length < 4) return false;\n\n    // ZIP starts with 'PK\\x03\\x04' or 'PK\\x05\\x06' (empty) or 'PK\\x07\\x08' (spanned)\n    return bytes[0] === 0x50 && bytes[1] === 0x4B &&\n           (bytes[2] === 0x03 || bytes[2] === 0x05 || bytes[2] === 0x07);\n}\n\n/**\n * ZIP entry information.\n */\nclass ZipEntry {\n    constructor(filename, compressedSize, uncompressedSize, compression, dataOffset) {\n        this.filename = filename;\n        this.compressedSize = compressedSize;\n        this.uncompressedSize = uncompressedSize;\n        this.compression = compression;\n        this.dataOffset = dataOffset;\n    }\n}\n\n/**\n * Minimal ZIP reader.\n */\nclass ZipReader {\n    /**\n     * @param {ArrayBuffer|Uint8Array} data - ZIP file data\n     */\n    constructor(data) {\n        this.data = data instanceof Uint8Array ? data : new Uint8Array(data);\n        this.entries = new Map();\n        this._parse();\n    }\n\n    /**\n     * Parse ZIP structure.\n     * @private\n     */\n    _parse() {\n        // Find End of Central Directory (scan backwards)\n        const eocdOffset = this._findEocd();\n        if (eocdOffset === -1) {\n            throw new Error('Invalid ZIP: End of Central Directory not found');\n        }\n\n        // Read EOCD\n        const eocd = this._readEocd(eocdOffset);\n\n        // Parse Central Directory entries\n        let offset = eocd.centralDirOffset;\n        for (let i = 0; i < eocd.totalEntries; i++) {\n            const entry = this._readCentralDirEntry(offset);\n            this.entries.set(entry.filename, entry);\n            offset += 46 + entry.filename.length + entry.extraLen + entry.commentLen;\n        }\n    }\n\n    /**\n     * Find End of Central Directory by scanning backwards.\n     * @private\n     * @returns {number} Offset or -1 if not found\n     */\n    _findEocd() {\n        // EOCD is at least 22 bytes, with optional comment up to 65535 bytes\n        const minSize = 22;\n        const maxSearch = Math.min(this.data.length, 65557);\n\n        for (let i = minSize; i <= maxSearch; i++) {\n            const offset = this.data.length - i;\n            if (this._readUint32LE(offset) === END_OF_CENTRAL_DIR_SIGNATURE) {\n                return offset;\n            }\n        }\n        return -1;\n    }\n\n    /**\n     * Read End of Central Directory record.\n     * @private\n     */\n    _readEocd(offset) {\n        return {\n            signature: this._readUint32LE(offset),\n            diskNumber: this._readUint16LE(offset + 4),\n            centralDirDisk: this._readUint16LE(offset + 6),\n            entriesOnDisk: this._readUint16LE(offset + 8),\n            totalEntries: this._readUint16LE(offset + 10),\n            centralDirSize: this._readUint32LE(offset + 12),\n            centralDirOffset: this._readUint32LE(offset + 16),\n            commentLen: this._readUint16LE(offset + 20),\n        };\n    }\n\n    /**\n     * Read Central Directory entry.\n     * @private\n     */\n    _readCentralDirEntry(offset) {\n        const signature = this._readUint32LE(offset);\n        if (signature !== CENTRAL_DIR_SIGNATURE) {\n            throw new Error('Invalid Central Directory entry');\n        }\n\n        const compression = this._readUint16LE(offset + 10);\n        const compressedSize = this._readUint32LE(offset + 20);\n        const uncompressedSize = this._readUint32LE(offset + 24);\n        const filenameLen = this._readUint16LE(offset + 28);\n        const extraLen = this._readUint16LE(offset + 30);\n        const commentLen = this._readUint16LE(offset + 32);\n        const localHeaderOffset = this._readUint32LE(offset + 42);\n\n        // Read filename\n        const filenameBytes = this.data.slice(offset + 46, offset + 46 + filenameLen);\n        const filename = new TextDecoder().decode(filenameBytes);\n\n        // Calculate actual data offset from local file header\n        const localExtraLen = this._readUint16LE(localHeaderOffset + 28);\n        const dataOffset = localHeaderOffset + 30 + filenameLen + localExtraLen;\n\n        return {\n            filename,\n            compressedSize,\n            uncompressedSize,\n            compression,\n            dataOffset,\n            extraLen,\n            commentLen,\n        };\n    }\n\n    /**\n     * Extract file by name.\n     *\n     * @param {string} filename - File path within ZIP\n     * @returns {Promise<Uint8Array>} Extracted data\n     */\n    async extract(filename) {\n        const entry = this.entries.get(filename);\n        if (!entry) {\n            throw new Error(`File not found in ZIP: ${filename}`);\n        }\n\n        const compressedData = this.data.slice(\n            entry.dataOffset,\n            entry.dataOffset + entry.compressedSize\n        );\n\n        if (entry.compression === COMPRESSION_STORE) {\n            // No compression - return copy\n            return new Uint8Array(compressedData);\n        } else if (entry.compression === COMPRESSION_DEFLATE) {\n            // Decompress using browser's DecompressionStream\n            return await this._decompressDeflate(compressedData);\n        } else {\n            throw new Error(`Unsupported compression method: ${entry.compression}`);\n        }\n    }\n\n    /**\n     * Decompress DEFLATE data using browser API.\n     * @private\n     */\n    async _decompressDeflate(compressed) {\n        const ds = new DecompressionStream('deflate-raw');\n        const writer = ds.writable.getWriter();\n        const reader = ds.readable.getReader();\n\n        writer.write(compressed);\n        writer.close();\n\n        const chunks = [];\n        let totalLength = 0;\n\n        while (true) {\n            const { done, value } = await reader.read();\n            if (done) break;\n            chunks.push(value);\n            totalLength += value.length;\n        }\n\n        const result = new Uint8Array(totalLength);\n        let offset = 0;\n        for (const chunk of chunks) {\n            result.set(chunk, offset);\n            offset += chunk.length;\n        }\n\n        return result;\n    }\n\n    /**\n     * List all files in the archive.\n     * @returns {string[]} List of filenames\n     */\n    list() {\n        return Array.from(this.entries.keys());\n    }\n\n    /**\n     * Check if file exists.\n     * @param {string} filename - File path\n     * @returns {boolean}\n     */\n    has(filename) {\n        return this.entries.has(filename);\n    }\n\n    // Helper methods for reading little-endian integers\n    _readUint16LE(offset) {\n        return this.data[offset] | (this.data[offset + 1] << 8);\n    }\n\n    _readUint32LE(offset) {\n        return (\n            this.data[offset] |\n            (this.data[offset + 1] << 8) |\n            (this.data[offset + 2] << 16) |\n            (this.data[offset + 3] << 24)\n        ) >>> 0;\n    }\n}\n\n/**\n * Extract bytecode from a ZIP bundle.\n *\n * Reads manifest.json to find the entry point, then extracts the bytecode.\n *\n * @param {ArrayBuffer|Uint8Array} data - ZIP file data\n * @returns {Promise<Uint8Array>} Extracted PNGB bytecode\n */\nasync function extractFromZip(data) {\n    const zip = new ZipReader(data);\n\n    // Read manifest\n    if (!zip.has('manifest.json')) {\n        throw new Error('ZIP bundle missing manifest.json');\n    }\n\n    const manifestBytes = await zip.extract('manifest.json');\n    const manifestText = new TextDecoder().decode(manifestBytes);\n    const manifest = JSON.parse(manifestText);\n\n    // Validate manifest\n    if (typeof manifest.version !== 'number' || manifest.version < 1) {\n        throw new Error('Invalid manifest version');\n    }\n    if (typeof manifest.entry !== 'string') {\n        throw new Error('Manifest missing entry point');\n    }\n\n    // Extract bytecode\n    const bytecode = await zip.extract(manifest.entry);\n    return bytecode;\n}\n\n/**\n * Get ZIP bundle info without full extraction.\n *\n * @param {ArrayBuffer|Uint8Array} data - ZIP file data\n * @returns {Promise<Object>} Bundle info\n */\nasync function getZipBundleInfo(data) {\n    const zip = new ZipReader(data);\n\n    const files = zip.list();\n\n    // Try to read manifest\n    let manifest = null;\n    if (zip.has('manifest.json')) {\n        const manifestBytes = await zip.extract('manifest.json');\n        const manifestText = new TextDecoder().decode(manifestBytes);\n        manifest = JSON.parse(manifestText);\n    }\n\n    return {\n        files,\n        manifest,\n        hasRuntime: zip.has('pngine.wasm'),\n    };\n}\n\n/**\n * Fetch ZIP from URL and extract bytecode.\n *\n * @param {string} url - URL of ZIP file\n * @returns {Promise<Uint8Array>} Extracted PNGB bytecode\n */\nasync function fetchAndExtractZip(url) {\n    const response = await fetch(url);\n    if (!response.ok) {\n        throw new Error(`Failed to fetch ZIP: ${response.status}`);\n    }\n\n    const buffer = await response.arrayBuffer();\n    return extractFromZip(buffer);\n}\n\n\n// === pngine-gpu.js ===\n/**\n * PNGine WebGPU Backend\n *\n * Implements the GPU operations called by the WASM module.\n * Manages WebGPU resources and translates WASM calls to actual GPU operations.\n *\n * ## Async ImageBitmap Pattern\n *\n * createImageBitmap() is async in browsers - it returns a Promise that decodes\n * the image data. Since WASM execution is synchronous, the decode completes\n * AFTER the draw call on the first frame, causing textures to appear black.\n *\n * Solution: After the first executeAll(), call waitForBitmaps() to wait for\n * all pending ImageBitmap Promises to resolve, then re-execute:\n *\n * ```javascript\n * pngine.executeAll();              // Starts async bitmap decode\n * await pngine.waitForBitmaps();    // Waits for decode to complete\n * pngine.executeAll();              // Re-renders with textures ready\n * ```\n *\n * Version: 2024-12-21-v1\n */\n\n\nclass PNGineGPU {\n    /**\n     * @param {GPUDevice} device - WebGPU device\n     * @param {GPUCanvasContext} context - Canvas context for rendering\n     */\n    constructor(device, context) {\n        this.device = device;\n        this.context = context;\n        this.memory = null; // Set when WASM is instantiated\n\n        // Resource maps (ID -> GPU resource)\n        this.buffers = new Map();\n        this.bufferMeta = new Map();  // Buffer ID → { size, usage }\n        this.textures = new Map();\n        this.textureViews = new Map();  // TextureView ID → GPUTextureView\n        this.samplers = new Map();\n        this.shaders = new Map();\n        this.pipelines = new Map();\n        this.bindGroups = new Map();\n        this.bindGroupLayouts = new Map();  // BindGroupLayout ID → GPUBindGroupLayout\n        this.pipelineLayouts = new Map();   // PipelineLayout ID → GPUPipelineLayout\n        this.querySets = new Map();         // QuerySet ID → GPUQuerySet\n        this.imageBitmaps = new Map();  // ImageBitmap ID → ImageBitmap\n        this.renderBundles = new Map();     // RenderBundle ID → GPURenderBundle\n\n        // WASM module support\n        this.wasmModules = new Map();      // Module ID → { instance, memory }\n        this.wasmCallResults = new Map();  // Call ID → { ptr, moduleId }\n\n        // Runtime data generation\n        this.typedArrays = new Map();      // Array ID → Float32Array (or other typed arrays)\n\n        // Runtime state for dynamic arguments\n        this.currentTime = 0;              // Total time in seconds (time.total)\n        this.deltaTime = 0;                // Delta time since last frame (time.delta)\n\n        // Render state\n        this.commandEncoder = null;\n        this.currentPass = null;\n        this.passType = null; // 'render' | 'compute'\n    }\n\n    /**\n     * Set current time for animation.\n     * Called before executeAll() to provide time for WASM calls.\n     * @param {number} totalTime - Total elapsed time in seconds\n     * @param {number} deltaTime - Time since last frame in seconds\n     */\n    setTime(totalTime, deltaTime = 0) {\n        this.currentTime = totalTime;\n        this.deltaTime = deltaTime;\n        console.log(`[GPU] setTime(${totalTime.toFixed(3)}, ${deltaTime.toFixed(3)})`);\n    }\n\n    /**\n     * Set WASM memory reference for reading data.\n     * @param {WebAssembly.Memory} memory\n     */\n    setMemory(memory) {\n        this.memory = memory;\n    }\n\n    /**\n     * Read a string from WASM memory.\n     * @param {number} ptr - Pointer to string data\n     * @param {number} len - String length in bytes\n     * @returns {string}\n     */\n    readString(ptr, len) {\n        const bytes = new Uint8Array(this.memory.buffer, ptr, len);\n        return new TextDecoder().decode(bytes);\n    }\n\n    /**\n     * Read raw bytes from WASM memory.\n     * @param {number} ptr - Pointer to data\n     * @param {number} len - Data length in bytes\n     * @returns {Uint8Array}\n     */\n    readBytes(ptr, len) {\n        return new Uint8Array(this.memory.buffer, ptr, len);\n    }\n\n    // ========================================================================\n    // Resource Creation\n    // ========================================================================\n\n    /**\n     * Create a GPU buffer.\n     * Skips creation if buffer already exists (for animation loop support).\n     * @param {number} id - Buffer ID\n     * @param {number} size - Buffer size in bytes\n     * @param {number} usage - Usage flags\n     */\n    createBuffer(id, size, usage) {\n        // Skip if already exists (allows executeAll in animation loop)\n        if (this.buffers.has(id)) {\n            return;\n        }\n        const gpuUsage = this.mapBufferUsage(usage);\n        const buffer = this.device.createBuffer({\n            size,\n            usage: gpuUsage,\n        });\n        this.buffers.set(id, buffer);\n        this.bufferMeta.set(id, { size, usage: gpuUsage });\n    }\n\n    /**\n     * Find the first buffer with UNIFORM usage that matches time uniform layout.\n     * Supports:\n     * - 12 bytes: f32 time + u32 width + u32 height (simple)\n     * - 16 bytes: f32 time + u32 width + u32 height + f32 ratio (demo2025)\n     * @returns {{id: number, size: number}|null} Buffer info or null if not found\n     */\n    findUniformBuffer() {\n        // Find any uniform buffer, prefer larger sizes for more uniform data\n        let bestMatch = null;\n        for (const [id, meta] of this.bufferMeta) {\n            if (meta.usage & GPUBufferUsage.UNIFORM) {\n                console.log(`[GPU] findUniformBuffer: found buffer ${id} size=${meta.size}`);\n                if (!bestMatch || meta.size > bestMatch.size) {\n                    bestMatch = { id, size: meta.size };\n                }\n            }\n        }\n        console.log(`[GPU] findUniformBuffer: returning`, bestMatch);\n        return bestMatch;\n    }\n\n    /**\n     * Create a GPU texture.\n     * Skips creation if texture already exists (for animation loop support).\n     * @param {number} id - Texture ID\n     * @param {number} descPtr - Pointer to binary descriptor\n     * @param {number} descLen - Descriptor length\n     */\n    createTexture(id, descPtr, descLen) {\n        // Skip if already exists (allows executeAll in animation loop)\n        if (this.textures.has(id)) {\n            return;\n        }\n        const bytes = this.readBytes(descPtr, descLen);\n        const desc = this.decodeTextureDescriptor(bytes);\n        console.log(`[GPU] createTexture(${id}) format=${desc.format} size=${desc.size[0]}x${desc.size[1]} usage=0x${desc.usage.toString(16)}`);\n\n        const texture = this.device.createTexture(desc);\n        this.textures.set(id, texture);\n    }\n\n    /**\n     * Create a texture sampler.\n     * Skips creation if sampler already exists (for animation loop support).\n     * @param {number} id - Sampler ID\n     * @param {number} descPtr - Pointer to binary descriptor\n     * @param {number} descLen - Descriptor length\n     */\n    createSampler(id, descPtr, descLen) {\n        // Skip if already exists (allows executeAll in animation loop)\n        if (this.samplers.has(id)) {\n            return;\n        }\n        const bytes = this.readBytes(descPtr, descLen);\n        const desc = this.decodeSamplerDescriptor(bytes);\n\n        const sampler = this.device.createSampler(desc);\n        this.samplers.set(id, sampler);\n    }\n\n    /**\n     * Create a shader module from WGSL code.\n     * Skips creation if shader already exists (for animation loop support).\n     * @param {number} id - Shader ID\n     * @param {number} codePtr - Pointer to WGSL code\n     * @param {number} codeLen - Code length\n     */\n    createShaderModule(id, codePtr, codeLen) {\n        // Skip if already exists (allows executeAll in animation loop)\n        if (this.shaders.has(id)) {\n            return;\n        }\n        const code = this.readString(codePtr, codeLen);\n        const module = this.device.createShaderModule({ code });\n        // Check for shader compilation errors\n        module.getCompilationInfo().then(info => {\n            for (const msg of info.messages) {\n                if (msg.type === 'error') {\n                    console.error(`[GPU] Shader ${id} error: ${msg.message} at line ${msg.lineNum}`);\n                } else if (msg.type === 'warning') {\n                    console.warn(`[GPU] Shader ${id} warning: ${msg.message}`);\n                }\n            }\n        });\n        this.shaders.set(id, module);\n    }\n\n    /**\n     * Create a render pipeline.\n     * Skips creation if pipeline already exists (for animation loop support).\n     * @param {number} id - Pipeline ID\n     * @param {number} descPtr - Pointer to descriptor JSON\n     * @param {number} descLen - Descriptor length\n     */\n    createRenderPipeline(id, descPtr, descLen) {\n        // Skip if already exists (allows executeAll in animation loop)\n        if (this.pipelines.has(id)) {\n            return;\n        }\n        const descJson = this.readString(descPtr, descLen);\n        const desc = JSON.parse(descJson);\n\n        // Resolve shader module references\n        const vertexShader = this.shaders.get(desc.vertex.shader);\n        const fragmentShader = desc.fragment ? this.shaders.get(desc.fragment.shader) : null;\n        if (desc.fragment) {\n        }\n\n        const pipelineDesc = {\n            layout: 'auto',\n            vertex: {\n                module: vertexShader,\n                entryPoint: desc.vertex.entryPoint || 'vertexMain',\n            },\n        };\n\n        // Add primitive state\n        if (desc.primitive) {\n            pipelineDesc.primitive = {\n                topology: desc.primitive.topology || 'triangle-list',\n            };\n            if (desc.primitive.cullMode) {\n                pipelineDesc.primitive.cullMode = desc.primitive.cullMode;\n            }\n            if (desc.primitive.frontFace) {\n                pipelineDesc.primitive.frontFace = desc.primitive.frontFace;\n            }\n        } else {\n            pipelineDesc.primitive = { topology: 'triangle-list' };\n        }\n\n        // Add vertex buffer layouts if present\n        if (desc.vertex.buffers && desc.vertex.buffers.length > 0) {\n            pipelineDesc.vertex.buffers = desc.vertex.buffers;\n        }\n\n        if (desc.fragment) {\n            // Use target format from descriptor, or canvas format if not specified\n            const targetFormat = desc.fragment.targetFormat || navigator.gpu.getPreferredCanvasFormat();\n            console.log(`[GPU] createRenderPipeline(${id}) targetFormat=${targetFormat}`);\n            pipelineDesc.fragment = {\n                module: fragmentShader,\n                entryPoint: desc.fragment.entryPoint || 'fragmentMain',\n                targets: [{\n                    format: targetFormat,\n                }],\n            };\n        }\n\n        // Add depth/stencil state if present\n        if (desc.depthStencil) {\n            pipelineDesc.depthStencil = {\n                format: desc.depthStencil.format || 'depth24plus',\n                depthWriteEnabled: desc.depthStencil.depthWriteEnabled !== false,\n                depthCompare: desc.depthStencil.depthCompare || 'less',\n            };\n        }\n\n        // Add multisample state if present\n        if (desc.multisample) {\n            pipelineDesc.multisample = desc.multisample;\n        }\n\n        const pipeline = this.device.createRenderPipeline(pipelineDesc);\n        this.pipelines.set(id, pipeline);\n    }\n\n    /**\n     * Create a compute pipeline.\n     * Skips creation if pipeline already exists (for animation loop support).\n     * @param {number} id - Pipeline ID\n     * @param {number} descPtr - Pointer to descriptor JSON\n     * @param {number} descLen - Descriptor length\n     */\n    createComputePipeline(id, descPtr, descLen) {\n        // Skip if already exists (allows executeAll in animation loop)\n        if (this.pipelines.has(id)) {\n            return;\n        }\n        console.log(`[GPU] createComputePipeline(${id})`);\n        const descJson = this.readString(descPtr, descLen);\n        const desc = JSON.parse(descJson);\n\n        // Resolve shader module reference\n        const computeShader = this.shaders.get(desc.compute.shader);\n\n        if (!computeShader) {\n            console.error(`[GPU] ERROR: Shader ${desc.compute.shader} not found for compute pipeline ${id}`);\n            console.error(`[GPU]   Available shaders: ${[...this.shaders.keys()].join(', ')}`);\n            return;\n        }\n\n        const pipeline = this.device.createComputePipeline({\n            layout: 'auto',\n            compute: {\n                module: computeShader,\n                entryPoint: desc.compute.entryPoint || 'main',\n            },\n        });\n        this.pipelines.set(id, pipeline);\n    }\n\n    /**\n     * Create a bind group.\n     * Skips creation if bind group already exists (for animation loop support).\n     * @param {number} id - Bind group ID\n     * @param {number} pipelineId - Pipeline ID to get layout from\n     * @param {number} entriesPtr - Pointer to binary descriptor\n     * @param {number} entriesLen - Descriptor length\n     */\n    createBindGroup(id, pipelineId, entriesPtr, entriesLen) {\n        console.log(`[GPU] createBindGroup(${id}, pipeline=${pipelineId})`);\n        // Skip if already exists (allows executeAll in animation loop)\n        if (this.bindGroups.has(id)) {\n            return;\n        }\n        const bytes = this.readBytes(entriesPtr, entriesLen);\n        const desc = this.decodeBindGroupDescriptor(bytes);\n        // Log detailed entry info for debugging ping-pong buffers\n        const entryDetails = desc.entries.map(e => {\n            const type = ['buf','tex','smp'][e.resourceType];\n            const size = e.resourceType === 0 ? `,sz=${e.size}` : '';\n            return `b${e.binding}:${type}${e.resourceId}${size}`;\n        }).join(', ');\n\n        // Resolve resource references in entries\n        const entries = desc.entries.map(entry => {\n            const resolved = { binding: entry.binding };\n            if (entry.resourceType === 0) { // buffer\n                const bufferResource = { buffer: this.buffers.get(entry.resourceId) };\n                // Include offset/size if specified (critical for storage buffers!)\n                if (entry.offset !== undefined && entry.offset !== 0) {\n                    bufferResource.offset = entry.offset;\n                }\n                if (entry.size !== undefined && entry.size !== 0) {\n                    bufferResource.size = entry.size;\n                }\n                resolved.resource = bufferResource;\n            } else if (entry.resourceType === 1) { // texture_view\n                const texture = this.textures.get(entry.resourceId);\n                resolved.resource = texture.createView();\n            } else if (entry.resourceType === 2) { // sampler\n                resolved.resource = this.samplers.get(entry.resourceId);\n            }\n            return resolved;\n        });\n\n        // Get layout from pipeline\n        const pipeline = this.pipelines.get(pipelineId);\n        if (!pipeline) {\n            console.error(`[GPU] Pipeline ${pipelineId} not found for bind group ${id}`);\n            return;\n        }\n        const bindGroup = this.device.createBindGroup({\n            layout: pipeline.getBindGroupLayout(desc.groupIndex),\n            entries,\n        });\n        this.bindGroups.set(id, bindGroup);\n    }\n\n    /**\n     * Create an ImageBitmap from blob data.\n     * Blob format: [mime_len:u8][mime:bytes][data:bytes]\n     * This is async - stores a Promise that resolves to ImageBitmap.\n     * @param {number} id - ImageBitmap ID\n     * @param {number} blobPtr - Pointer to blob data\n     * @param {number} blobLen - Blob data length\n     */\n    createImageBitmap(id, blobPtr, blobLen) {\n        // Skip if already exists (allows executeAll in animation loop)\n        if (this.imageBitmaps.has(id)) {\n            return;\n        }\n\n        const bytes = this.readBytes(blobPtr, blobLen);\n\n        // Parse blob format: [mime_len:u8][mime:bytes][data:bytes]\n        const mimeLen = bytes[0];\n        const mimeBytes = bytes.slice(1, 1 + mimeLen);\n        const mimeType = new TextDecoder().decode(mimeBytes);\n        const imageData = bytes.slice(1 + mimeLen);\n\n\n        // Create Blob and decode to ImageBitmap (async)\n        const blob = new Blob([imageData], { type: mimeType });\n        const bitmapPromise = window.createImageBitmap(blob);\n\n        // Store the promise - will be awaited when copying to texture\n        this.imageBitmaps.set(id, bitmapPromise);\n    }\n\n    /**\n     * Create a texture view from an existing texture.\n     * Skips creation if view already exists (for animation loop support).\n     * @param {number} viewId - TextureView ID\n     * @param {number} textureId - Source texture ID\n     * @param {number} descPtr - Pointer to binary descriptor\n     * @param {number} descLen - Descriptor length\n     */\n    createTextureView(viewId, textureId, descPtr, descLen) {\n        // Skip if already exists (allows executeAll in animation loop)\n        if (this.textureViews.has(viewId)) {\n            return;\n        }\n\n        const texture = this.textures.get(textureId);\n        if (!texture) {\n            console.error(`[GPU] createTextureView: texture ${textureId} not found`);\n            return;\n        }\n\n        const bytes = this.readBytes(descPtr, descLen);\n        const desc = this.decodeTextureViewDescriptor(bytes);\n\n        const view = texture.createView(desc);\n        this.textureViews.set(viewId, view);\n    }\n\n    /**\n     * Create a query set for occlusion/timestamp queries.\n     * Skips creation if query set already exists (for animation loop support).\n     * @param {number} querySetId - QuerySet ID\n     * @param {number} descPtr - Pointer to binary descriptor\n     * @param {number} descLen - Descriptor length\n     */\n    createQuerySet(querySetId, descPtr, descLen) {\n        // Skip if already exists (allows executeAll in animation loop)\n        if (this.querySets.has(querySetId)) {\n            return;\n        }\n\n        const bytes = this.readBytes(descPtr, descLen);\n        // Simple format: [type:u8][count:u16]\n        const type = bytes[0] === 0 ? 'occlusion' : 'timestamp';\n        const count = bytes[1] | (bytes[2] << 8);\n\n\n        const querySet = this.device.createQuerySet({ type, count });\n        this.querySets.set(querySetId, querySet);\n    }\n\n    /**\n     * Create a bind group layout defining binding slot layouts.\n     * Skips creation if layout already exists (for animation loop support).\n     * @param {number} layoutId - BindGroupLayout ID\n     * @param {number} descPtr - Pointer to binary descriptor\n     * @param {number} descLen - Descriptor length\n     */\n    createBindGroupLayout(layoutId, descPtr, descLen) {\n        // Skip if already exists (allows executeAll in animation loop)\n        if (this.bindGroupLayouts.has(layoutId)) {\n            return;\n        }\n\n        const bytes = this.readBytes(descPtr, descLen);\n        const entries = this.decodeBindGroupLayoutDescriptor(bytes);\n\n        const layout = this.device.createBindGroupLayout({ entries });\n        this.bindGroupLayouts.set(layoutId, layout);\n    }\n\n    /**\n     * Create a pipeline layout from bind group layouts.\n     * Skips creation if layout already exists (for animation loop support).\n     * @param {number} layoutId - PipelineLayout ID\n     * @param {number} descPtr - Pointer to binary descriptor\n     * @param {number} descLen - Descriptor length\n     */\n    createPipelineLayout(layoutId, descPtr, descLen) {\n        // Skip if already exists (allows executeAll in animation loop)\n        if (this.pipelineLayouts.has(layoutId)) {\n            return;\n        }\n\n        const bytes = this.readBytes(descPtr, descLen);\n        // Simple format: [count:u8][layout_id:u16]...\n        const count = bytes[0];\n        const bindGroupLayouts = [];\n\n        let offset = 1;\n        for (let i = 0; i < count && offset + 1 < bytes.length; i++) {\n            const bglId = bytes[offset] | (bytes[offset + 1] << 8);\n            offset += 2;\n            const bgl = this.bindGroupLayouts.get(bglId);\n            if (bgl) {\n                bindGroupLayouts.push(bgl);\n            } else {\n                console.warn(`[GPU] createPipelineLayout: bind group layout ${bglId} not found`);\n            }\n        }\n\n\n        const layout = this.device.createPipelineLayout({ bindGroupLayouts });\n        this.pipelineLayouts.set(layoutId, layout);\n    }\n\n    /**\n     * Create a render bundle from pre-recorded draw commands.\n     * Skips creation if render bundle already exists (for animation loop support).\n     *\n     * Descriptor format:\n     * - colorFormats: [count:u8][format:u8]...\n     * - depthStencilFormat: u8 (0xFF = none)\n     * - sampleCount: u8\n     * - pipeline_id: u16\n     * - bindGroups: [count:u8][group_id:u16]...\n     * - vertexBuffers: [count:u8][buffer_id:u16]...\n     * - indexBuffer: [hasIndex:u8][buffer_id:u16]\n     * - drawType: u8 (0=draw, 1=drawIndexed)\n     * - drawParams: varies by type\n     *\n     * @param {number} bundleId - RenderBundle ID\n     * @param {number} descPtr - Pointer to binary descriptor\n     * @param {number} descLen - Descriptor length\n     */\n    createRenderBundle(bundleId, descPtr, descLen) {\n        // Skip if already exists (allows executeAll in animation loop)\n        if (this.renderBundles.has(bundleId)) {\n            return;\n        }\n\n        const bytes = this.readBytes(descPtr, descLen);\n        const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);\n        let offset = 0;\n\n        // Parse colorFormats\n        const colorFormatCount = bytes[offset++];\n        const colorFormats = [];\n        for (let i = 0; i < colorFormatCount && offset < bytes.length; i++) {\n            colorFormats.push(this.decodeTextureFormat(bytes[offset++]));\n        }\n\n        // Parse depthStencilFormat (0xFF = none)\n        const depthFormatByte = bytes[offset++];\n        const depthStencilFormat = depthFormatByte === 0xFF ? undefined : this.decodeTextureFormat(depthFormatByte);\n\n        // Parse sampleCount\n        const sampleCount = bytes[offset++] || 1;\n\n        // Parse pipeline_id\n        const pipelineId = view.getUint16(offset, true);\n        offset += 2;\n\n        // Parse bindGroups\n        const bindGroupCount = bytes[offset++];\n        const bindGroupIds = [];\n        for (let i = 0; i < bindGroupCount && offset + 1 < bytes.length; i++) {\n            bindGroupIds.push(view.getUint16(offset, true));\n            offset += 2;\n        }\n\n        // Parse vertexBuffers\n        const vertexBufferCount = bytes[offset++];\n        const vertexBufferIds = [];\n        for (let i = 0; i < vertexBufferCount && offset + 1 < bytes.length; i++) {\n            vertexBufferIds.push(view.getUint16(offset, true));\n            offset += 2;\n        }\n\n        // Parse indexBuffer\n        const hasIndexBuffer = bytes[offset++] === 1;\n        let indexBufferId = 0;\n        if (hasIndexBuffer) {\n            indexBufferId = view.getUint16(offset, true);\n            offset += 2;\n        }\n\n        // Parse drawType and params\n        const drawType = bytes[offset++]; // 0=draw, 1=drawIndexed\n        let vertexCount = 3, instanceCount = 1, firstVertex = 0, firstInstance = 0;\n        let indexCount = 3, firstIndex = 0, baseVertex = 0;\n\n        if (drawType === 0) { // draw\n            vertexCount = view.getUint32(offset, true); offset += 4;\n            instanceCount = view.getUint32(offset, true); offset += 4;\n            firstVertex = view.getUint32(offset, true); offset += 4;\n            firstInstance = view.getUint32(offset, true); offset += 4;\n        } else { // drawIndexed\n            indexCount = view.getUint32(offset, true); offset += 4;\n            instanceCount = view.getUint32(offset, true); offset += 4;\n            firstIndex = view.getUint32(offset, true); offset += 4;\n            baseVertex = view.getUint32(offset, true); offset += 4;\n            firstInstance = view.getUint32(offset, true); offset += 4;\n        }\n\n        console.log(`[GPU] createRenderBundle(${bundleId}) colorFormats=[${colorFormats.join(',')}] depth=${depthStencilFormat ?? 'none'} pipeline=${pipelineId}`);\n\n        // Get pipeline\n        const pipeline = this.pipelines.get(pipelineId);\n        if (!pipeline) {\n            console.error(`[GPU] createRenderBundle: pipeline ${pipelineId} not found`);\n            return;\n        }\n\n        // Create RenderBundleEncoder with format compatibility\n        const encoderDesc = {\n            colorFormats,\n            sampleCount,\n        };\n        if (depthStencilFormat) {\n            encoderDesc.depthStencilFormat = depthStencilFormat;\n        }\n\n        const encoder = this.device.createRenderBundleEncoder(encoderDesc);\n\n        // Record commands\n        encoder.setPipeline(pipeline);\n\n        // Set bind groups\n        for (let i = 0; i < bindGroupIds.length; i++) {\n            const bindGroup = this.bindGroups.get(bindGroupIds[i]);\n            if (bindGroup) {\n                encoder.setBindGroup(i, bindGroup);\n            }\n        }\n\n        // Set vertex buffers\n        for (let i = 0; i < vertexBufferIds.length; i++) {\n            const buffer = this.buffers.get(vertexBufferIds[i]);\n            if (buffer) {\n                encoder.setVertexBuffer(i, buffer);\n            }\n        }\n\n        // Set index buffer if present\n        if (hasIndexBuffer) {\n            const indexBuffer = this.buffers.get(indexBufferId);\n            if (indexBuffer) {\n                encoder.setIndexBuffer(indexBuffer, 'uint16'); // Default to uint16\n            }\n        }\n\n        // Draw\n        if (drawType === 0) {\n            encoder.draw(vertexCount, instanceCount, firstVertex, firstInstance);\n        } else {\n            encoder.drawIndexed(indexCount, instanceCount, firstIndex, baseVertex, firstInstance);\n        }\n\n        // Finish and store the bundle\n        const bundle = encoder.finish();\n        this.renderBundles.set(bundleId, bundle);\n    }\n\n    /**\n     * Execute pre-recorded render bundles in the current render pass.\n     * @param {number} bundleIdsPtr - Pointer to array of bundle IDs (u16[])\n     * @param {number} bundleCount - Number of bundles to execute\n     */\n    executeBundles(bundleIdsPtr, bundleCount) {\n        if (!this.currentPass || this.passType !== 'render') {\n            console.error('[GPU] executeBundles: no active render pass');\n            return;\n        }\n\n        const bundleIdsBytes = this.readBytes(bundleIdsPtr, bundleCount * 2);\n        const bundleIdsView = new DataView(bundleIdsBytes.buffer, bundleIdsBytes.byteOffset, bundleIdsBytes.byteLength);\n\n        const bundles = [];\n        for (let i = 0; i < bundleCount; i++) {\n            const bundleId = bundleIdsView.getUint16(i * 2, true);\n            const bundle = this.renderBundles.get(bundleId);\n            if (bundle) {\n                bundles.push(bundle);\n            } else {\n                console.warn(`[GPU] executeBundles: bundle ${bundleId} not found`);\n            }\n        }\n\n        if (bundles.length > 0) {\n            console.log(`[GPU] executeBundles(${bundles.length} bundles)`);\n            this.currentPass.executeBundles(bundles);\n        }\n    }\n\n    /**\n     * Wait for all pending ImageBitmap decoding to complete.\n     * Call this after init phase but before first frame to ensure\n     * all textures can be uploaded synchronously.\n     * @returns {Promise<void>}\n     */\n    async waitForBitmaps() {\n        const pending = [];\n        for (const [id, bitmap] of this.imageBitmaps.entries()) {\n            if (bitmap instanceof Promise) {\n                pending.push(\n                    bitmap.then(resolved => {\n                        this.imageBitmaps.set(id, resolved);\n                        return resolved;\n                    })\n                );\n            }\n        }\n        if (pending.length > 0) {\n            await Promise.all(pending);\n        }\n    }\n\n    // ========================================================================\n    // WASM Module Operations\n    // ========================================================================\n\n    /**\n     * Initialize a WASM module from embedded data.\n     * The WASM bytes come from the PNGine data section.\n     * @param {number} moduleId - Module ID\n     * @param {number} dataPtr - Pointer to WASM binary in memory\n     * @param {number} dataLen - Length of WASM binary\n     */\n    initWasmModule(moduleId, dataPtr, dataLen) {\n        // Skip if already loaded (allows executeAll in animation loop)\n        if (this.wasmModules.has(moduleId)) {\n            return;\n        }\n\n        const wasmBytes = this.readBytes(dataPtr, dataLen).slice();  // Copy bytes\n\n        try {\n            // Compile synchronously (small modules expected)\n            const module = new WebAssembly.Module(wasmBytes);\n\n            // Minimal imports for typical WASM modules\n            const imports = {\n                env: {\n                    abort: (msg, file, line, col) => {\n                        console.error(`[WASM abort] ${msg} at ${file}:${line}:${col}`);\n                    },\n                    // Math imports for AssemblyScript\n                    'Math.sin': Math.sin,\n                    'Math.cos': Math.cos,\n                    'Math.tan': Math.tan,\n                    'Math.sqrt': Math.sqrt,\n                }\n            };\n\n            const instance = new WebAssembly.Instance(module, imports);\n\n            this.wasmModules.set(moduleId, {\n                instance,\n                memory: instance.exports.memory,\n            });\n\n        } catch (err) {\n            console.error(`[GPU] Failed to load WASM module ${moduleId}:`, err);\n        }\n    }\n\n    /**\n     * Call a WASM exported function with encoded arguments.\n     * The function returns a pointer to data in WASM linear memory.\n     *\n     * @param {number} callId - Unique call ID for result tracking\n     * @param {number} moduleId - Module ID\n     * @param {number} funcNamePtr - Pointer to function name string\n     * @param {number} funcNameLen - Function name length\n     * @param {number} argsPtr - Pointer to encoded arguments\n     * @param {number} argsLen - Arguments length\n     */\n    callWasmFunc(callId, moduleId, funcNamePtr, funcNameLen, argsPtr, argsLen) {\n        const wasm = this.wasmModules.get(moduleId);\n        if (!wasm) {\n            console.error(`[GPU] callWasmFunc: module ${moduleId} not found`);\n            return;\n        }\n\n        const funcName = this.readString(funcNamePtr, funcNameLen);\n        const func = wasm.instance.exports[funcName];\n\n        if (!func) {\n            console.error(`[GPU] callWasmFunc: function '${funcName}' not found in module ${moduleId}`);\n            return;\n        }\n\n        // Decode and resolve arguments\n        const encodedArgs = this.readBytes(argsPtr, argsLen);\n        const resolvedArgs = this.resolveWasmArgs(encodedArgs);\n\n\n        // Call WASM function - returns pointer to result in WASM memory\n        const resultPtr = func(...resolvedArgs);\n\n        // Store result for writeBufferFromWasm\n        this.wasmCallResults.set(callId, { ptr: resultPtr, moduleId });\n    }\n\n    /**\n     * Write data from WASM memory to a GPU buffer.\n     * Uses the result pointer from a previous callWasmFunc.\n     *\n     * @param {number} callId - Call ID from callWasmFunc\n     * @param {number} bufferId - Target GPU buffer ID\n     * @param {number} offset - Offset in buffer\n     * @param {number} byteLen - Number of bytes to copy\n     */\n    writeBufferFromWasm(callId, bufferId, offset, byteLen) {\n        const result = this.wasmCallResults.get(callId);\n        if (!result) {\n            console.error(`[GPU] writeBufferFromWasm: call result ${callId} not found`);\n            return;\n        }\n\n        const wasm = this.wasmModules.get(result.moduleId);\n        if (!wasm || !wasm.memory) {\n            console.error(`[GPU] writeBufferFromWasm: WASM memory not available`);\n            return;\n        }\n\n        const buffer = this.buffers.get(bufferId);\n        if (!buffer) {\n            console.error(`[GPU] writeBufferFromWasm: buffer ${bufferId} not found`);\n            return;\n        }\n\n        // Read bytes from WASM linear memory\n        const data = new Uint8Array(wasm.memory.buffer, result.ptr, byteLen);\n\n\n        // Write to GPU buffer\n        this.device.queue.writeBuffer(buffer, offset, data);\n    }\n\n    /**\n     * Resolve encoded WASM arguments to JavaScript values.\n     *\n     * Argument encoding format:\n     * - [arg_count:u8][arg_type:u8, value?:4 bytes]...\n     *\n     * Arg types:\n     * - 0x00: literal f32 (4 byte value follows)\n     * - 0x01: canvas.width (no value)\n     * - 0x02: canvas.height (no value)\n     * - 0x03: time.total (no value)\n     * - 0x04: literal i32 (4 byte value follows)\n     * - 0x05: literal u32 (4 byte value follows)\n     * - 0x06: time.delta (no value)\n     *\n     * @param {Uint8Array} encoded - Encoded arguments\n     * @returns {number[]} Resolved argument values\n     */\n    resolveWasmArgs(encoded) {\n        if (encoded.length === 0) return [];\n\n        const view = new DataView(encoded.buffer, encoded.byteOffset, encoded.byteLength);\n        const argCount = encoded[0];\n        const resolved = [];\n        let offset = 1;\n\n        for (let i = 0; i < argCount && offset < encoded.length; i++) {\n            const argType = encoded[offset++];\n\n            switch (argType) {\n                case 0x00: // literal_f32\n                    if (offset + 4 <= encoded.length) {\n                        resolved.push(view.getFloat32(offset, true));\n                        offset += 4;\n                    }\n                    break;\n\n                case 0x01: // canvas_width\n                    resolved.push(this.context.canvas.width);\n                    break;\n\n                case 0x02: // canvas_height\n                    resolved.push(this.context.canvas.height);\n                    break;\n\n                case 0x03: // time_total\n                    resolved.push(this.currentTime);\n                    break;\n\n                case 0x04: // literal_i32\n                    if (offset + 4 <= encoded.length) {\n                        resolved.push(view.getInt32(offset, true));\n                        offset += 4;\n                    }\n                    break;\n\n                case 0x05: // literal_u32\n                    if (offset + 4 <= encoded.length) {\n                        resolved.push(view.getUint32(offset, true));\n                        offset += 4;\n                    }\n                    break;\n\n                case 0x06: // time_delta\n                    resolved.push(this.deltaTime);\n                    break;\n\n                default:\n                    console.warn(`[GPU] Unknown WASM arg type: 0x${argType.toString(16)}`);\n                    break;\n            }\n        }\n\n        return resolved;\n    }\n\n    /**\n     * Copy an ImageBitmap to a GPU texture.\n     * Uses WebGPU's copyExternalImageToTexture queue operation.\n     * @param {number} bitmapId - ImageBitmap ID\n     * @param {number} textureId - Destination texture ID\n     * @param {number} mipLevel - Mip level (usually 0)\n     * @param {number} originX - X origin in texture\n     * @param {number} originY - Y origin in texture\n     */\n    async copyExternalImageToTexture(bitmapId, textureId, mipLevel, originX, originY) {\n\n        // Get the ImageBitmap (may need to await promise)\n        let bitmap = this.imageBitmaps.get(bitmapId);\n        if (!bitmap) {\n            console.error(`[GPU] ImageBitmap ${bitmapId} not found`);\n            return;\n        }\n\n        // If it's a promise, await it\n        if (bitmap instanceof Promise) {\n            bitmap = await bitmap;\n            this.imageBitmaps.set(bitmapId, bitmap);  // Cache resolved bitmap\n        }\n\n        const texture = this.textures.get(textureId);\n        if (!texture) {\n            console.error(`[GPU] Texture ${textureId} not found`);\n            return;\n        }\n\n        // Copy ImageBitmap to texture\n        this.device.queue.copyExternalImageToTexture(\n            { source: bitmap },\n            { texture, mipLevel, origin: { x: originX, y: originY } },\n            { width: bitmap.width, height: bitmap.height }\n        );\n\n    }\n\n    // ========================================================================\n    // Pass Operations\n    // ========================================================================\n\n    /**\n     * Begin a render pass.\n     * @param {number} textureId - Color attachment texture (0xFFFE = canvas, other = custom texture)\n     * @param {number} loadOp - Load operation (0=load, 1=clear)\n     * @param {number} storeOp - Store operation (0=store, 1=discard)\n     * @param {number} depthTextureId - Depth attachment texture (0xFFFF = none)\n     */\n    beginRenderPass(textureId, loadOp, storeOp, depthTextureId) {\n        console.log(`[GPU] beginRenderPass(texture=${textureId}, load=${loadOp}, store=${storeOp}, depth=${depthTextureId})`);\n        // Reuse existing command encoder if available (allows compute + render in same frame)\n        if (!this.commandEncoder) {\n            this.commandEncoder = this.device.createCommandEncoder();\n        }\n\n        // Get render target (0xFFFE = current canvas texture, other = custom texture)\n        // 0xFFFE (65534) is the sentinel value for contextCurrentTexture\n        const CANVAS_TEXTURE_ID = 0xFFFE; // 65534\n        let view;\n        if (textureId === CANVAS_TEXTURE_ID || textureId === 65534) {\n            view = this.context.getCurrentTexture().createView();\n        } else {\n            // Custom render target texture\n            const texture = this.textures.get(textureId);\n            if (texture) {\n                view = texture.createView();\n            } else {\n                // Fallback to canvas if texture not found\n                console.warn(`[GPU] Render target texture ${textureId} not found, using canvas`);\n                view = this.context.getCurrentTexture().createView();\n            }\n        }\n\n        const passDesc = {\n            colorAttachments: [{\n                view,\n                loadOp: loadOp === 1 ? 'clear' : 'load',\n                storeOp: storeOp === 0 ? 'store' : 'discard',\n                clearValue: { r: 0, g: 0, b: 0, a: 1 },  // Black background (WebGPU default)\n            }],\n        };\n\n        // Add depth attachment if specified (0xFFFF = no depth)\n        if (depthTextureId !== 0xFFFF && depthTextureId !== 65535) {\n            const depthTexture = this.textures.get(depthTextureId);\n            if (depthTexture) {\n                passDesc.depthStencilAttachment = {\n                    view: depthTexture.createView(),\n                    depthClearValue: 1.0,\n                    depthLoadOp: 'clear',\n                    depthStoreOp: 'store',\n                };\n            } else {\n                console.warn(`[GPU] Depth texture ${depthTextureId} not found`);\n            }\n        }\n\n        this.currentPass = this.commandEncoder.beginRenderPass(passDesc);\n        this.passType = 'render';\n    }\n\n    /**\n     * Begin a compute pass.\n     */\n    beginComputePass() {\n        console.log('[GPU] beginComputePass()');\n        // Reuse existing command encoder if available (allows compute + render in same frame)\n        if (!this.commandEncoder) {\n            this.commandEncoder = this.device.createCommandEncoder();\n        }\n        this.currentPass = this.commandEncoder.beginComputePass();\n        this.passType = 'compute';\n    }\n\n    /**\n     * Set the current pipeline.\n     * @param {number} id - Pipeline ID\n     */\n    setPipeline(id) {\n        console.log(`[GPU] setPipeline(${id})`);\n        const pipeline = this.pipelines.get(id);\n        if (!pipeline) {\n            console.error(`[GPU] Pipeline ${id} not found! Available: ${[...this.pipelines.keys()].join(', ')}`);\n            return;\n        }\n        if (!this.currentPass) {\n            console.error(`[GPU] No active pass for setPipeline!`);\n            return;\n        }\n        this.currentPass.setPipeline(pipeline);\n    }\n\n    /**\n     * Set a bind group.\n     * @param {number} slot - Bind group slot\n     * @param {number} id - Bind group ID\n     */\n    setBindGroup(slot, id) {\n        console.log(`[GPU] setBindGroup(slot=${slot}, id=${id})`);\n        const bindGroup = this.bindGroups.get(id);\n        if (!bindGroup) {\n            console.error(`[GPU] ERROR: Bind group ${id} not found! Available: ${[...this.bindGroups.keys()].join(', ')}`);\n            return;\n        }\n        this.currentPass.setBindGroup(slot, bindGroup);\n    }\n\n    /**\n     * Set a vertex buffer.\n     * @param {number} slot - Vertex buffer slot\n     * @param {number} id - Buffer ID\n     */\n    setVertexBuffer(slot, id) {\n        const buffer = this.buffers.get(id);\n        const meta = this.bufferMeta.get(id);\n        if (!buffer) {\n            console.error(`[GPU]   Buffer ${id} not found! Available buffers: ${[...this.buffers.keys()].join(', ')}`);\n        }\n        this.currentPass.setVertexBuffer(slot, buffer);\n    }\n\n    /**\n     * Draw primitives.\n     * @param {number} vertexCount - Number of vertices\n     * @param {number} instanceCount - Number of instances\n     * @param {number} firstVertex - First vertex to draw\n     * @param {number} firstInstance - First instance to draw\n     */\n    draw(vertexCount, instanceCount, firstVertex = 0, firstInstance = 0) {\n        console.log(`[GPU] draw(${vertexCount}, ${instanceCount})`);\n        this.currentPass.draw(vertexCount, instanceCount, firstVertex, firstInstance);\n    }\n\n    /**\n     * Draw indexed primitives.\n     * @param {number} indexCount - Number of indices\n     * @param {number} instanceCount - Number of instances\n     * @param {number} firstIndex - First index to draw\n     * @param {number} baseVertex - Base vertex offset\n     * @param {number} firstInstance - First instance to draw\n     */\n    drawIndexed(indexCount, instanceCount, firstIndex = 0, baseVertex = 0, firstInstance = 0) {\n        this.currentPass.drawIndexed(indexCount, instanceCount, firstIndex, baseVertex, firstInstance);\n    }\n\n    /**\n     * Dispatch compute workgroups.\n     * @param {number} x - Workgroups in X\n     * @param {number} y - Workgroups in Y\n     * @param {number} z - Workgroups in Z\n     */\n    dispatch(x, y, z) {\n        console.log(`[GPU] dispatch(${x}, ${y}, ${z})`);\n        this.currentPass.dispatchWorkgroups(x, y, z);\n    }\n\n    /**\n     * End the current pass.\n     */\n    endPass() {\n        console.log('[GPU] endPass()');\n        if (!this.currentPass) {\n            console.error('[GPU] No active pass to end!');\n            return;\n        }\n        this.currentPass.end();\n        this.currentPass = null;\n        this.passType = null;\n    }\n\n    // ========================================================================\n    // Queue Operations\n    // ========================================================================\n\n    /**\n     * Write data to a buffer.\n     * @param {number} bufferId - Buffer ID\n     * @param {number} offset - Byte offset\n     * @param {number} dataPtr - Pointer to data\n     * @param {number} dataLen - Data length\n     */\n    writeBuffer(bufferId, offset, dataPtr, dataLen) {\n        const buffer = this.buffers.get(bufferId);\n        const data = this.readBytes(dataPtr, dataLen);\n        // Log time value if writing to uniform buffer with floats\n        if (dataLen >= 4) {\n            const floats = new Float32Array(data.buffer, data.byteOffset, Math.min(4, dataLen / 4));\n            console.log(`[GPU] writeBuffer(${bufferId}, offset=${offset}, len=${dataLen}) time=${floats[0].toFixed(3)}`);\n        } else {\n            console.log(`[GPU] writeBuffer(${bufferId}, offset=${offset}, len=${dataLen})`);\n        }\n        this.device.queue.writeBuffer(buffer, offset, data);\n    }\n\n    /**\n     * Write uniform data directly to a buffer (called from JS, not WASM).\n     * Used by the Play feature to update uniform buffers each frame.\n     * @param {number} bufferId - Buffer ID\n     * @param {Uint8Array} data - Data to write\n     */\n    writeTimeToBuffer(bufferId, data) {\n        const buffer = this.buffers.get(bufferId);\n        if (!buffer) {\n            console.warn(`[GPU] writeTimeToBuffer: buffer ${bufferId} not found`);\n            return;\n        }\n\n        // Get actual buffer size and only write what fits\n        const meta = this.bufferMeta.get(bufferId);\n        const actualSize = meta?.size ?? data.length;\n        const writeSize = Math.min(data.length, actualSize);\n\n        // Log what we're writing\n        if (writeSize >= 4) {\n            const floats = new Float32Array(data.buffer, data.byteOffset, Math.min(4, writeSize / 4));\n            console.log(`[GPU] writeTimeToBuffer(${bufferId}) time=${floats[0].toFixed(3)}`);\n        }\n\n        this.device.queue.writeBuffer(buffer, 0, data.subarray(0, writeSize));\n    }\n\n    /**\n     * Submit command buffer to queue.\n     */\n    submit() {\n        console.log('[GPU] submit()');\n        if (this.commandEncoder) {\n            const commandBuffer = this.commandEncoder.finish();\n            this.device.queue.submit([commandBuffer]);\n            this.commandEncoder = null;\n        }\n    }\n\n    // ========================================================================\n    // Helpers\n    // ========================================================================\n\n    /**\n     * Map PNGine buffer usage flags to WebGPU usage flags.\n     * @param {number} usage - PNGine usage flags (packed struct from Zig)\n     * @returns {number} WebGPU usage flags\n     *\n     * Zig BufferUsage packed struct bit layout (LSB first):\n     *   bit 0: map_read\n     *   bit 1: map_write\n     *   bit 2: copy_src\n     *   bit 3: copy_dst\n     *   bit 4: index\n     *   bit 5: vertex\n     *   bit 6: uniform\n     *   bit 7: storage\n     */\n    mapBufferUsage(usage) {\n        let gpuUsage = 0;\n\n        // PNGine usage flags (matching Zig BufferUsage packed struct)\n        const MAP_READ  = 0x01;  // bit 0\n        const MAP_WRITE = 0x02;  // bit 1\n        const COPY_SRC  = 0x04;  // bit 2\n        const COPY_DST  = 0x08;  // bit 3\n        const INDEX     = 0x10;  // bit 4\n        const VERTEX    = 0x20;  // bit 5\n        const UNIFORM   = 0x40;  // bit 6\n        const STORAGE   = 0x80;  // bit 7\n\n        if (usage & MAP_READ) gpuUsage |= GPUBufferUsage.MAP_READ;\n        if (usage & MAP_WRITE) gpuUsage |= GPUBufferUsage.MAP_WRITE;\n        if (usage & COPY_SRC) gpuUsage |= GPUBufferUsage.COPY_SRC;\n        if (usage & COPY_DST) gpuUsage |= GPUBufferUsage.COPY_DST;\n        if (usage & INDEX) gpuUsage |= GPUBufferUsage.INDEX;\n        if (usage & VERTEX) gpuUsage |= GPUBufferUsage.VERTEX;\n        if (usage & UNIFORM) gpuUsage |= GPUBufferUsage.UNIFORM;\n        if (usage & STORAGE) gpuUsage |= GPUBufferUsage.STORAGE;\n\n        return gpuUsage;\n    }\n\n    // ========================================================================\n    // Binary Descriptor Decoders\n    // ========================================================================\n\n    /**\n     * Decode a binary texture descriptor.\n     * Format: type_tag(u8) + field_count(u8) + fields...\n     * @param {Uint8Array} bytes - Binary descriptor data\n     * @returns {GPUTextureDescriptor}\n     */\n    decodeTextureDescriptor(bytes) {\n        const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);\n        let offset = 0;\n\n        // Validate type tag\n        const typeTag = bytes[offset++];\n        if (typeTag !== 0x01) { // DescriptorType.texture\n            throw new Error(`Invalid texture descriptor type tag: ${typeTag}`);\n        }\n\n        const fieldCount = bytes[offset++];\n        const desc = {\n            size: [this.context.canvas.width, this.context.canvas.height],\n            format: navigator.gpu.getPreferredCanvasFormat(),\n            usage: GPUTextureUsage.RENDER_ATTACHMENT,\n            sampleCount: 1,\n        };\n\n        // Field IDs (from DescriptorEncoder.TextureField)\n        const FIELD_WIDTH = 0x01;\n        const FIELD_HEIGHT = 0x02;\n        const FIELD_SAMPLE_COUNT = 0x05;\n        const FIELD_FORMAT = 0x07;\n        const FIELD_USAGE = 0x08;\n\n        // Value types\n        const VALUE_U32 = 0x00;\n        const VALUE_ENUM = 0x07;\n\n        for (let i = 0; i < fieldCount; i++) {\n            const fieldId = bytes[offset++];\n            const valueType = bytes[offset++];\n\n            if (valueType === VALUE_U32) {\n                const value = view.getUint32(offset, true); // little endian\n                offset += 4;\n\n                if (fieldId === FIELD_WIDTH) desc.size[0] = value;\n                else if (fieldId === FIELD_HEIGHT) desc.size[1] = value;\n                else if (fieldId === FIELD_SAMPLE_COUNT) desc.sampleCount = value;\n            } else if (valueType === VALUE_ENUM) {\n                const value = bytes[offset++];\n\n                if (fieldId === FIELD_FORMAT) {\n                    desc.format = this.decodeTextureFormat(value);\n                } else if (fieldId === FIELD_USAGE) {\n                    desc.usage = this.decodeTextureUsage(value);\n                }\n            }\n        }\n\n        return desc;\n    }\n\n    /**\n     * Decode a binary sampler descriptor.\n     * @param {Uint8Array} bytes - Binary descriptor data\n     * @returns {GPUSamplerDescriptor}\n     */\n    decodeSamplerDescriptor(bytes) {\n        let offset = 0;\n\n        // Validate type tag\n        const typeTag = bytes[offset++];\n        if (typeTag !== 0x02) { // DescriptorType.sampler\n            throw new Error(`Invalid sampler descriptor type tag: ${typeTag}`);\n        }\n\n        const fieldCount = bytes[offset++];\n        const desc = {\n            magFilter: 'linear',\n            minFilter: 'linear',\n            addressModeU: 'clamp-to-edge',\n            addressModeV: 'clamp-to-edge',\n        };\n\n        // Field IDs (from DescriptorEncoder.SamplerField)\n        const FIELD_ADDRESS_MODE_U = 0x01;\n        const FIELD_ADDRESS_MODE_V = 0x02;\n        const FIELD_MAG_FILTER = 0x04;\n        const FIELD_MIN_FILTER = 0x05;\n\n        // Value type for enum\n        const VALUE_ENUM = 0x07;\n\n        for (let i = 0; i < fieldCount; i++) {\n            const fieldId = bytes[offset++];\n            const valueType = bytes[offset++];\n\n            if (valueType === VALUE_ENUM) {\n                const value = bytes[offset++];\n\n                if (fieldId === FIELD_MAG_FILTER) {\n                    desc.magFilter = this.decodeFilterMode(value);\n                } else if (fieldId === FIELD_MIN_FILTER) {\n                    desc.minFilter = this.decodeFilterMode(value);\n                } else if (fieldId === FIELD_ADDRESS_MODE_U) {\n                    desc.addressModeU = this.decodeAddressMode(value);\n                } else if (fieldId === FIELD_ADDRESS_MODE_V) {\n                    desc.addressModeV = this.decodeAddressMode(value);\n                }\n            }\n        }\n\n        return desc;\n    }\n\n    /**\n     * Decode texture format enum.\n     * @param {number} value - Format enum value\n     * @returns {string} WebGPU format string\n     */\n    decodeTextureFormat(value) {\n        const formats = {\n            0x00: 'rgba8unorm',\n            0x01: 'rgba8snorm',\n            0x02: 'rgba8uint',\n            0x03: 'rgba8sint',\n            0x04: 'bgra8unorm',\n            0x05: 'rgba16float',\n            0x06: 'rgba32float',\n            0x10: 'depth24plus',\n            0x11: 'depth24plus-stencil8',\n            0x12: 'depth32float',\n        };\n        return formats[value] || navigator.gpu.getPreferredCanvasFormat();\n    }\n\n    /**\n     * Decode texture usage flags.\n     * @param {number} value - Usage flags packed as u8\n     * @returns {number} WebGPU usage flags\n     */\n    decodeTextureUsage(value) {\n        let usage = 0;\n        if (value & 0x01) usage |= GPUTextureUsage.COPY_SRC;\n        if (value & 0x02) usage |= GPUTextureUsage.COPY_DST;\n        if (value & 0x04) usage |= GPUTextureUsage.TEXTURE_BINDING;\n        if (value & 0x08) usage |= GPUTextureUsage.STORAGE_BINDING;\n        if (value & 0x10) usage |= GPUTextureUsage.RENDER_ATTACHMENT;\n        return usage || GPUTextureUsage.RENDER_ATTACHMENT; // Default\n    }\n\n    /**\n     * Decode filter mode enum.\n     * @param {number} value - Filter mode value\n     * @returns {string} WebGPU filter mode\n     */\n    decodeFilterMode(value) {\n        return value === 0 ? 'nearest' : 'linear';\n    }\n\n    /**\n     * Decode address mode enum.\n     * @param {number} value - Address mode value\n     * @returns {string} WebGPU address mode\n     */\n    decodeAddressMode(value) {\n        const modes = ['clamp-to-edge', 'repeat', 'mirror-repeat'];\n        return modes[value] || 'clamp-to-edge';\n    }\n\n    /**\n     * Decode a binary texture view descriptor.\n     * Format: type_tag(u8) + field_count(u8) + fields...\n     * @param {Uint8Array} bytes - Binary descriptor data\n     * @returns {GPUTextureViewDescriptor}\n     */\n    decodeTextureViewDescriptor(bytes) {\n        const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);\n        let offset = 0;\n\n        // Skip type tag (may be bind_group_layout=0x04, reused for texture view encoding)\n        const typeTag = bytes[offset++];\n        const fieldCount = bytes[offset++];\n\n        const desc = {};\n\n        // Field IDs for texture view\n        const FIELD_FORMAT = 0x01;\n        const FIELD_DIMENSION = 0x02;\n        const FIELD_BASE_MIP_LEVEL = 0x03;\n        const FIELD_MIP_LEVEL_COUNT = 0x04;\n        const FIELD_BASE_ARRAY_LAYER = 0x05;\n        const FIELD_ARRAY_LAYER_COUNT = 0x06;\n\n        // Value types\n        const VALUE_U32 = 0x00;\n        const VALUE_ENUM = 0x07;\n\n        for (let i = 0; i < fieldCount && offset < bytes.length; i++) {\n            const fieldId = bytes[offset++];\n            const valueType = bytes[offset++];\n\n            if (valueType === VALUE_U32) {\n                const value = view.getUint32(offset, true);\n                offset += 4;\n\n                if (fieldId === FIELD_BASE_MIP_LEVEL) desc.baseMipLevel = value;\n                else if (fieldId === FIELD_MIP_LEVEL_COUNT) desc.mipLevelCount = value;\n                else if (fieldId === FIELD_BASE_ARRAY_LAYER) desc.baseArrayLayer = value;\n                else if (fieldId === FIELD_ARRAY_LAYER_COUNT) desc.arrayLayerCount = value;\n            } else if (valueType === VALUE_ENUM) {\n                const value = bytes[offset++];\n\n                if (fieldId === FIELD_FORMAT) {\n                    desc.format = this.decodeTextureFormat(value);\n                } else if (fieldId === FIELD_DIMENSION) {\n                    desc.dimension = this.decodeTextureViewDimension(value);\n                }\n            }\n        }\n\n        return desc;\n    }\n\n    /**\n     * Decode texture view dimension enum.\n     * @param {number} value - Dimension enum value\n     * @returns {string} WebGPU dimension string\n     */\n    decodeTextureViewDimension(value) {\n        const dimensions = ['1d', '2d', '2d-array', 'cube', 'cube-array', '3d'];\n        return dimensions[value] || '2d';\n    }\n\n    /**\n     * Decode a binary bind group layout descriptor.\n     * Format: type_tag(u8) + field_count(u8) + entries...\n     * @param {Uint8Array} bytes - Binary descriptor data\n     * @returns {Array<GPUBindGroupLayoutEntry>}\n     */\n    decodeBindGroupLayoutDescriptor(bytes) {\n        const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);\n        let offset = 0;\n\n        // Skip type tag (0x04 = bind_group_layout)\n        const typeTag = bytes[offset++];\n        const fieldCount = bytes[offset++];\n\n        const entries = [];\n\n        // Field 0x01 = entries array\n        if (bytes[offset++] !== 0x01) return entries; // entries field\n        if (bytes[offset++] !== 0x03) return entries; // VALUE_ARRAY\n        const entryCount = bytes[offset++];\n\n        for (let i = 0; i < entryCount && offset < bytes.length; i++) {\n            const binding = bytes[offset++];\n            const visibility = bytes[offset++];\n            const resourceType = bytes[offset++];\n\n            const entry = {\n                binding,\n                visibility: this.decodeVisibilityFlags(visibility),\n            };\n\n            // Decode resource-specific layout\n            if (resourceType === 0x00) { // buffer\n                const bufType = bytes[offset++];\n                const hasDynamicOffset = bytes[offset++] === 1;\n                const minBindingSize = view.getUint32(offset, true);\n                offset += 4;\n\n                entry.buffer = {\n                    type: ['uniform', 'storage', 'read-only-storage'][bufType] || 'uniform',\n                    hasDynamicOffset,\n                    minBindingSize,\n                };\n            } else if (resourceType === 0x01) { // sampler\n                const sampType = bytes[offset++];\n                entry.sampler = {\n                    type: ['filtering', 'non-filtering', 'comparison'][sampType] || 'filtering',\n                };\n            } else if (resourceType === 0x02) { // texture\n                const sampleType = bytes[offset++];\n                const viewDimension = bytes[offset++];\n                const multisampled = bytes[offset++] === 1;\n\n                entry.texture = {\n                    sampleType: ['float', 'unfilterable-float', 'depth', 'sint', 'uint'][sampleType] || 'float',\n                    viewDimension: this.decodeTextureViewDimension(viewDimension),\n                    multisampled,\n                };\n            } else if (resourceType === 0x03) { // storageTexture\n                const format = bytes[offset++];\n                const access = bytes[offset++];\n                const viewDimension = bytes[offset++];\n\n                entry.storageTexture = {\n                    format: this.decodeTextureFormat(format),\n                    access: ['write-only', 'read-only', 'read-write'][access] || 'write-only',\n                    viewDimension: this.decodeTextureViewDimension(viewDimension),\n                };\n            } else if (resourceType === 0x04) { // externalTexture\n                entry.externalTexture = {};\n            }\n\n            entries.push(entry);\n        }\n\n        return entries;\n    }\n\n    /**\n     * Decode visibility flags to WebGPU shader stage flags.\n     * @param {number} flags - Packed visibility flags (VERTEX=1, FRAGMENT=2, COMPUTE=4)\n     * @returns {number} WebGPU GPUShaderStageFlags\n     */\n    decodeVisibilityFlags(flags) {\n        let visibility = 0;\n        if (flags & 0x01) visibility |= GPUShaderStage.VERTEX;\n        if (flags & 0x02) visibility |= GPUShaderStage.FRAGMENT;\n        if (flags & 0x04) visibility |= GPUShaderStage.COMPUTE;\n        return visibility;\n    }\n\n    /**\n     * Decode a binary bind group descriptor.\n     * Format: type_tag(u8) + field_count(u8) + fields...\n     * @param {Uint8Array} bytes - Binary descriptor data\n     * @returns {{groupIndex: number, entries: Array}}\n     */\n    decodeBindGroupDescriptor(bytes) {\n        const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);\n        let offset = 0;\n\n        // Validate type tag\n        const typeTag = bytes[offset++];\n        if (typeTag !== 0x03) { // DescriptorType.bind_group\n            throw new Error(`Invalid bind group descriptor type tag: ${typeTag}`);\n        }\n\n        const fieldCount = bytes[offset++];\n        let groupIndex = 0;\n        const entries = [];\n\n        // Field IDs (from DescriptorEncoder.BindGroupField)\n        const FIELD_LAYOUT = 0x01;\n        const FIELD_ENTRIES = 0x02;\n\n        // Value types\n        const VALUE_ARRAY = 0x03;\n        const VALUE_ENUM = 0x07;\n\n        for (let i = 0; i < fieldCount; i++) {\n            const fieldId = bytes[offset++];\n            const valueType = bytes[offset++];\n\n            if (fieldId === FIELD_LAYOUT && valueType === VALUE_ENUM) {\n                groupIndex = bytes[offset++];\n            } else if (fieldId === FIELD_ENTRIES && valueType === VALUE_ARRAY) {\n                const entryCount = bytes[offset++];\n\n                for (let j = 0; j < entryCount; j++) {\n                    const binding = bytes[offset++];\n                    const resourceType = bytes[offset++];\n                    const resourceId = view.getUint16(offset, true); // little endian\n                    offset += 2;\n\n                    const entry = { binding, resourceType, resourceId };\n\n                    // Buffer bindings have additional offset/size fields\n                    if (resourceType === 0) { // buffer\n                        entry.offset = view.getUint32(offset, true);\n                        offset += 4;\n                        entry.size = view.getUint32(offset, true);\n                        offset += 4;\n                    }\n\n                    entries.push(entry);\n                }\n            }\n        }\n\n        return { groupIndex, entries };\n    }\n\n    /**\n     * Get WASM imports object for instantiation.\n     * @returns {Object} Imports object\n     */\n    getImports() {\n        const self = this;\n        return {\n            env: {\n                gpuCreateBuffer: (id, size, usage) => self.createBuffer(id, size, usage),\n                gpuCreateTexture: (id, ptr, len) => self.createTexture(id, ptr, len),\n                gpuCreateSampler: (id, ptr, len) => self.createSampler(id, ptr, len),\n                gpuCreateShaderModule: (id, ptr, len) => self.createShaderModule(id, ptr, len),\n                gpuCreateRenderPipeline: (id, ptr, len) => self.createRenderPipeline(id, ptr, len),\n                gpuCreateComputePipeline: (id, ptr, len) => self.createComputePipeline(id, ptr, len),\n                gpuCreateBindGroup: (id, layout, ptr, len) => self.createBindGroup(id, layout, ptr, len),\n                gpuCreateImageBitmap: (id, ptr, len) => self.createImageBitmap(id, ptr, len),\n                gpuCreateTextureView: (viewId, textureId, ptr, len) => self.createTextureView(viewId, textureId, ptr, len),\n                gpuCreateQuerySet: (querySetId, ptr, len) => self.createQuerySet(querySetId, ptr, len),\n                gpuCreateBindGroupLayout: (layoutId, ptr, len) => self.createBindGroupLayout(layoutId, ptr, len),\n                gpuCreatePipelineLayout: (layoutId, ptr, len) => self.createPipelineLayout(layoutId, ptr, len),\n                gpuCreateRenderBundle: (bundleId, ptr, len) => self.createRenderBundle(bundleId, ptr, len),\n                gpuExecuteBundles: (bundleIdsPtr, bundleCount) => self.executeBundles(bundleIdsPtr, bundleCount),\n                gpuBeginRenderPass: (tex, load, store, depth) => self.beginRenderPass(tex, load, store, depth),\n                gpuBeginComputePass: () => self.beginComputePass(),\n                gpuSetPipeline: (id) => {\n                    self.setPipeline(id);\n                },\n                gpuSetBindGroup: (slot, id) => {\n                    self.setBindGroup(slot, id);\n                },\n                gpuSetVertexBuffer: (slot, id) => {\n                    self.setVertexBuffer(slot, id);\n                },\n                gpuDraw: (v, i, fv, fi) => {\n                    self.draw(v, i, fv, fi);\n                },\n                gpuDrawIndexed: (idx, i, firstIdx, baseVtx, firstInst) => self.drawIndexed(idx, i, firstIdx, baseVtx, firstInst),\n                gpuDispatch: (x, y, z) => self.dispatch(x, y, z),\n                gpuEndPass: () => self.endPass(),\n                gpuWriteBuffer: (id, off, ptr, len) => self.writeBuffer(id, off, ptr, len),\n                gpuSubmit: () => self.submit(),\n                gpuCopyExternalImageToTexture: (bitmapId, textureId, mipLevel, originX, originY) =>\n                    self.copyExternalImageToTexture(bitmapId, textureId, mipLevel, originX, originY),\n                // WASM module operations\n                gpuInitWasmModule: (moduleId, dataPtr, dataLen) =>\n                    self.initWasmModule(moduleId, dataPtr, dataLen),\n                gpuCallWasmFunc: (callId, moduleId, funcNamePtr, funcNameLen, argsPtr, argsLen) =>\n                    self.callWasmFunc(callId, moduleId, funcNamePtr, funcNameLen, argsPtr, argsLen),\n                gpuWriteBufferFromWasm: (callId, bufferId, offset, byteLen) =>\n                    self.writeBufferFromWasm(callId, bufferId, offset, byteLen),\n                // Data generation operations\n                gpuCreateTypedArray: (arrayId, elementType, elementCount) =>\n                    self.createTypedArray(arrayId, elementType, elementCount),\n                gpuFillRandom: (arrayId, offset, count, stride, minPtr, maxPtr) =>\n                    self.fillRandom(arrayId, offset, count, stride, minPtr, maxPtr),\n                gpuFillExpression: (arrayId, offset, count, stride, totalCount, exprPtr, exprLen) =>\n                    self.fillExpression(arrayId, offset, count, stride, totalCount, exprPtr, exprLen),\n                gpuFillConstant: (arrayId, offset, count, stride, valuePtr) =>\n                    self.fillConstant(arrayId, offset, count, stride, valuePtr),\n                gpuWriteBufferFromArray: (bufferId, bufferOffset, arrayId) =>\n                    self.writeBufferFromArray(bufferId, bufferOffset, arrayId),\n                gpuWriteTimeUniform: (bufferId, bufferOffset, size) =>\n                    self.writeTimeUniform(bufferId, bufferOffset, size),\n                gpuDebugLog: (msgType, value) => {\n                    // Debug logging for pass execution tracing\n                    if (msgType === 10) console.log(`[WASM] exec_pass id=${value}`);\n                    else if (msgType === 11) console.log(`[WASM]   range.start=${value}`);\n                    else if (msgType === 12) console.log(`[WASM]   range.end=${value}`);\n                    else if (msgType === 20) console.log(`[WASM] dispatch x=${value}`);\n                    else if (msgType === 21) console.log(`[WASM]   y=${value}`);\n                    else if (msgType === 22) console.log(`[WASM]   z=${value}`);\n                },\n                jsConsoleLog: (ptr, len) => {\n                    const msg = self.readString(ptr, len);\n                    console.log(msg);\n                },\n                jsConsoleLogInt: (ptr, len, value) => {\n                    const msg = self.readString(ptr, len);\n                    console.log(`${msg}${value}`);\n                },\n            },\n        };\n    }\n\n    // ========================================================================\n    // Data Generation Operations\n    // ========================================================================\n\n    /**\n     * Create a typed array for runtime data generation.\n     * Skips creation if array already exists (for animation loop support).\n     * @param {number} arrayId - Array identifier\n     * @param {number} elementType - Element type (0=f32, 1=u32, etc.)\n     * @param {number} elementCount - Number of elements\n     */\n    createTypedArray(arrayId, elementType, elementCount) {\n        // Skip if already exists (allows executeAll in animation loop)\n        if (this.typedArrays.has(arrayId)) {\n            return;\n        }\n        // elementType 0 = f32 (most common)\n        const array = new Float32Array(elementCount);\n        this.typedArrays.set(arrayId, { array, filled: false });\n    }\n\n    /**\n     * Fill array with random values in [min, max] range.\n     * Skips if array was already filled (for animation loop support).\n     * @param {number} arrayId - Array identifier\n     * @param {number} offset - Starting offset within each element\n     * @param {number} count - Number of elements to fill\n     * @param {number} stride - Floats between each element\n     * @param {number} minPtr - Pointer to min value (f32)\n     * @param {number} maxPtr - Pointer to max value (f32)\n     */\n    fillRandom(arrayId, offset, count, stride, minPtr, maxPtr) {\n        const entry = this.typedArrays.get(arrayId);\n        if (!entry || entry.filled) return;\n\n        const array = entry.array;\n\n        // Read min/max from WASM memory\n        const minView = new Float32Array(this.memory.buffer, minPtr, 1);\n        const maxView = new Float32Array(this.memory.buffer, maxPtr, 1);\n        const min = minView[0];\n        const max = maxView[0];\n        const range = max - min;\n\n\n        for (let i = 0; i < count; i++) {\n            const idx = i * stride + offset;\n            array[idx] = min + Math.random() * range;\n        }\n    }\n\n    /**\n     * Fill array by evaluating expression for each element.\n     * Expression can use: ELEMENT_ID, NUM_PARTICLES, PI, random(), sin(), cos(), sqrt()\n     * Skips if array was already filled (for animation loop support).\n     * Uses compiled function for performance instead of per-iteration eval.\n     * @param {number} arrayId - Array identifier\n     * @param {number} offset - Starting offset within each element\n     * @param {number} count - Number of elements to fill\n     * @param {number} stride - Floats between each element\n     * @param {number} totalCount - Total element count (for NUM_PARTICLES)\n     * @param {number} exprPtr - Pointer to expression string\n     * @param {number} exprLen - Length of expression string\n     */\n    fillExpression(arrayId, offset, count, stride, totalCount, exprPtr, exprLen) {\n        const entry = this.typedArrays.get(arrayId);\n        if (!entry || entry.filled) {\n            return;\n        }\n\n        const array = entry.array;\n\n        // Read expression string from WASM memory\n        const exprBytes = new Uint8Array(this.memory.buffer, exprPtr, exprLen);\n        const expr = new TextDecoder().decode(exprBytes);\n\n\n        try {\n            // Transform expression into JS function body (compile once, run many)\n            const jsExpr = expr\n                .replace(/NUM_PARTICLES/g, String(totalCount))\n                .replace(/PI/g, 'Math.PI')\n                .replace(/random\\(\\)/g, 'Math.random()')\n                .replace(/sin\\(/g, 'Math.sin(')\n                .replace(/cos\\(/g, 'Math.cos(')\n                .replace(/sqrt\\(/g, 'Math.sqrt(')\n                .replace(/ceil\\(/g, 'Math.ceil(')\n                .replace(/floor\\(/g, 'Math.floor(')\n                .replace(/abs\\(/g, 'Math.abs(');\n\n\n            // Compile the expression into a function (one compilation, many calls)\n            const fn = new Function('ELEMENT_ID', `return ${jsExpr};`);\n\n            // Execute compiled function for each element\n            for (let i = 0; i < count; i++) {\n                const idx = i * stride + offset;\n                array[idx] = fn(i);\n            }\n\n            // Debug: show sample values (first few and last)\n            const samples = [0, 1, 2, 100, 500, 1000, count-1].filter(i => i < count);\n            const sampleVals = samples.map(i => `[${i}]=${array[i*stride+offset].toFixed(4)}`).join(', ');\n        } catch (e) {\n            console.error(`Expression compile/eval error: ${expr}`, e);\n            // Fill with zeros on error\n            for (let i = 0; i < count; i++) {\n                array[i * stride + offset] = 0;\n            }\n        }\n    }\n\n    /**\n     * Fill array with constant value.\n     * Skips if array was already filled (for animation loop support).\n     * @param {number} arrayId - Array identifier\n     * @param {number} offset - Starting offset within each element\n     * @param {number} count - Number of elements to fill\n     * @param {number} stride - Floats between each element\n     * @param {number} valuePtr - Pointer to value (f32)\n     */\n    fillConstant(arrayId, offset, count, stride, valuePtr) {\n        const entry = this.typedArrays.get(arrayId);\n        if (!entry || entry.filled) return;\n\n        const array = entry.array;\n\n        const valueView = new Float32Array(this.memory.buffer, valuePtr, 1);\n        const value = valueView[0];\n\n\n        for (let i = 0; i < count; i++) {\n            const idx = i * stride + offset;\n            array[idx] = value;\n        }\n    }\n\n    /**\n     * Write generated array data to GPU buffer.\n     * Tracks which buffers have been written to (prevents re-writing on animation loop).\n     * @param {number} bufferId - Buffer identifier\n     * @param {number} bufferOffset - Offset in buffer (bytes)\n     * @param {number} arrayId - Array identifier\n     */\n    writeBufferFromArray(bufferId, bufferOffset, arrayId) {\n        console.log(`[GPU] writeBufferFromArray(buffer=${bufferId}, offset=${bufferOffset}, array=${arrayId})`);\n        const entry = this.typedArrays.get(arrayId);\n        const buffer = this.buffers.get(bufferId);\n\n        if (!entry || !buffer) {\n            console.error(`[GPU] writeBufferFromArray: missing array ${arrayId} or buffer ${bufferId}`);\n            return;\n        }\n\n        // Track which buffers this array has been written to\n        if (!entry.writtenBuffers) entry.writtenBuffers = new Set();\n\n        // Skip if already written to this specific buffer\n        if (entry.writtenBuffers.has(bufferId)) {\n            console.log(`[GPU]   -> skipped (already written)`);\n            return;\n        }\n\n        const array = entry.array;\n\n        // Debug: show first few values being written\n        const floatView = new Float32Array(array.buffer, array.byteOffset, Math.min(16, array.length));\n\n        this.device.queue.writeBuffer(buffer, bufferOffset, array);\n        entry.writtenBuffers.add(bufferId);\n\n        // Mark array as filled once written to at least one buffer\n        // (fill operations can be skipped on subsequent frames)\n        entry.filled = true;\n    }\n\n    /**\n     * Write time/canvas uniform data to GPU buffer.\n     * Writes f32 values: time, canvas_width, canvas_height[, aspect_ratio] based on size.\n     * @param {number} bufferId - Buffer identifier\n     * @param {number} bufferOffset - Offset in buffer (bytes)\n     * @param {number} size - Number of bytes to write (12 or 16)\n     */\n    writeTimeUniform(bufferId, bufferOffset, size) {\n        console.log(`[GPU] writeTimeUniform(buffer=${bufferId}, offset=${bufferOffset}, size=${size}) time=${this.currentTime?.toFixed(3) ?? 'undefined'}`);\n        const buffer = this.buffers.get(bufferId);\n        if (!buffer) {\n            console.error(`[GPU] writeTimeUniform: missing buffer ${bufferId}`);\n            return;\n        }\n\n        // Get actual buffer size from metadata\n        const meta = this.bufferMeta.get(bufferId);\n        const actualSize = meta?.size ?? size;\n        const availableSize = actualSize - bufferOffset;\n\n        // Get current time and canvas dimensions\n        const time = this.currentTime ?? 0.0;\n        const width = this.canvas?.width ?? 512;\n        const height = this.canvas?.height ?? 512;\n        const aspectRatio = width / height;\n\n        // Create uniform data based on available space\n        let data;\n        if (availableSize >= 16) {\n            data = new Float32Array([time, width, height, aspectRatio]);\n        } else if (availableSize >= 12) {\n            data = new Float32Array([time, width, height]);\n        } else if (availableSize >= 8) {\n            data = new Float32Array([time, width]);\n        } else if (availableSize >= 4) {\n            data = new Float32Array([time]);\n        } else {\n            console.warn(`[GPU] writeTimeUniform: buffer ${bufferId} too small (${availableSize} bytes available)`);\n            return;\n        }\n\n        this.device.queue.writeBuffer(buffer, bufferOffset, data);\n    }\n\n    /**\n     * Reset all state (for reloading).\n     */\n    reset() {\n        // Destroy GPU resources\n        for (const buffer of this.buffers.values()) {\n            buffer.destroy();\n        }\n        for (const texture of this.textures.values()) {\n            texture.destroy();\n        }\n\n        this.buffers.clear();\n        this.bufferMeta.clear();\n        this.textures.clear();\n        this.textureViews.clear();\n        this.samplers.clear();\n        this.shaders.clear();\n        this.pipelines.clear();\n        this.bindGroups.clear();\n        this.bindGroupLayouts.clear();\n        this.pipelineLayouts.clear();\n        this.querySets.clear();\n        this.imageBitmaps.clear();\n        this.renderBundles.clear();\n        this.wasmModules.clear();\n        this.wasmCallResults.clear();\n        this.typedArrays.clear();\n        this.commandEncoder = null;\n        this.currentPass = null;\n        this.passType = null;\n        this.currentTime = 0;\n        this.deltaTime = 0;\n    }\n}\n\n\n// === pngine-worker.js ===\n/**\n * PNGine Worker\n *\n * Worker thread that owns WebGPU device and WASM instance.\n * Receives commands from main thread via postMessage.\n */\n\n\n\n\n\n// ============================================================================\n// Worker State\n// ============================================================================\n\n/** @type {OffscreenCanvas} */\nlet canvas = null;\n\n/** @type {GPUDevice} */\nlet device = null;\n\n/** @type {GPUCanvasContext} */\nlet context = null;\n\n/** @type {PNGineGPU} */\nlet gpu = null;\n\n/** @type {WebAssembly.Instance} */\nlet wasmInstance = null;\n\n/** @type {boolean} */\nlet initialized = false;\n\n/** @type {boolean} */\nlet moduleLoaded = false;\n\n/** @type {boolean} */\nlet debugEnabled = false;\n\n/**\n * Debug logger - only logs when debug mode is enabled.\n */\nconst debug = {\n    log: (...args) => debugEnabled && console.log('[Worker]', ...args),\n    warn: (...args) => debugEnabled && console.warn('[Worker]', ...args),\n    error: (...args) => console.error('[Worker]', ...args),  // Always log errors\n};\n\n// ============================================================================\n// Message Handling\n// ============================================================================\n\n/**\n * Handle incoming messages from main thread.\n * @param {MessageEvent} event\n */\nself.onmessage = async (event) => {\n    const { id, type, payload } = event.data;\n\n    try {\n        let result;\n\n        switch (type) {\n            case MessageType.INIT:\n                result = await handleInit(payload);\n                break;\n\n            case MessageType.TERMINATE:\n                result = handleTerminate();\n                break;\n\n            case MessageType.COMPILE:\n                result = handleCompile(payload);\n                break;\n\n            case MessageType.LOAD_MODULE:\n                result = handleLoadModule(payload);\n                break;\n\n            case MessageType.LOAD_FROM_URL:\n                result = await handleLoadFromUrl(payload);\n                break;\n\n            case MessageType.FREE_MODULE:\n                result = handleFreeModule();\n                break;\n\n            case MessageType.EXECUTE_ALL:\n                result = handleExecuteAll();\n                break;\n\n            case MessageType.EXECUTE_FRAME:\n                result = handleExecuteFrame(payload);\n                break;\n\n            case MessageType.RENDER_FRAME:\n                result = handleRenderFrame(payload);\n                break;\n\n            case MessageType.GET_FRAME_COUNT:\n                result = handleGetFrameCount();\n                break;\n\n            case MessageType.GET_METADATA:\n                result = handleGetMetadata();\n                break;\n\n            case MessageType.FIND_UNIFORM_BUFFER:\n                result = handleFindUniformBuffer();\n                break;\n\n            case MessageType.SET_DEBUG:\n                debugEnabled = payload.enabled;\n                debug.log(`Debug mode ${debugEnabled ? 'enabled' : 'disabled'}`);\n                result = { success: true };\n                break;\n\n            default:\n                throw new Error(`Unknown message type: ${type}`);\n        }\n\n        // Send success response\n        self.postMessage({\n            id,\n            type: MessageType.RESPONSE,\n            payload: result,\n        });\n\n    } catch (error) {\n        // Send error response\n        self.postMessage({\n            id,\n            type: MessageType.ERROR,\n            payload: {\n                message: error.message,\n                name: error.name,\n                stack: error.stack,\n                code: error.code,\n            },\n        });\n    }\n};\n\n// ============================================================================\n// Message Handlers\n// ============================================================================\n\n/**\n * Initialize WebGPU and WASM in worker.\n * @param {Object} payload\n * @param {OffscreenCanvas} payload.canvas - Transferred canvas\n * @param {string} payload.wasmUrl - URL to pngine.wasm\n */\nasync function handleInit(payload) {\n    if (initialized) {\n        throw new Error('Worker already initialized');\n    }\n\n    canvas = payload.canvas;\n    const wasmUrl = payload.wasmUrl || 'pngine.wasm';\n\n    // 1. Check WebGPU support in worker\n    if (!navigator.gpu) {\n        throw new Error('WebGPU not supported in this worker');\n    }\n\n    // 2. Request adapter and device\n    const adapter = await navigator.gpu.requestAdapter();\n    if (!adapter) {\n        throw new Error('Failed to get WebGPU adapter');\n    }\n\n    device = await adapter.requestDevice();\n\n    // 3. Configure canvas context\n    context = canvas.getContext('webgpu');\n    if (!context) {\n        throw new Error('Failed to get WebGPU context from OffscreenCanvas');\n    }\n\n    const format = navigator.gpu.getPreferredCanvasFormat();\n    context.configure({\n        device,\n        format,\n        alphaMode: 'premultiplied',\n    });\n\n    // 4. Create GPU backend\n    gpu = new PNGineGPU(device, context);\n\n    // 5. Load and instantiate WASM\n    const response = await fetch(wasmUrl);\n    if (!response.ok) {\n        throw new Error(`Failed to fetch WASM: ${response.status}`);\n    }\n\n    const { instance } = await WebAssembly.instantiateStreaming(\n        response,\n        gpu.getImports()\n    );\n\n    wasmInstance = instance;\n\n    // 6. Set memory reference for GPU backend\n    gpu.setMemory(instance.exports.memory);\n\n    // 7. Initialize WASM runtime\n    instance.exports.onInit();\n\n    initialized = true;\n\n    return {\n        success: true,\n        canvasWidth: canvas.width,\n        canvasHeight: canvas.height,\n    };\n}\n\n/**\n * Terminate worker and clean up resources.\n */\nfunction handleTerminate() {\n    if (gpu) {\n        gpu.reset();\n    }\n    if (wasmInstance && wasmInstance.exports.freeModule) {\n        wasmInstance.exports.freeModule();\n    }\n\n    canvas = null;\n    device = null;\n    context = null;\n    gpu = null;\n    wasmInstance = null;\n    initialized = false;\n    moduleLoaded = false;\n\n    return { success: true };\n}\n\n/**\n * Compile source code to bytecode.\n * @param {Object} payload\n * @param {string} payload.source - Source code to compile\n */\nfunction handleCompile(payload) {\n    assertInitialized();\n\n    const { source } = payload;\n    const encoder = new TextEncoder();\n    const sourceBytes = encoder.encode(source);\n\n    const exports = wasmInstance.exports;\n\n    // Allocate memory for source\n    const srcPtr = exports.alloc(sourceBytes.length);\n    if (!srcPtr) {\n        throw new Error('Failed to allocate memory for source');\n    }\n\n    // Copy source to WASM memory\n    const memory = new Uint8Array(exports.memory.buffer);\n    memory.set(sourceBytes, srcPtr);\n\n    // Compile\n    const result = exports.compile(srcPtr, sourceBytes.length);\n\n    // Free source memory\n    exports.free(srcPtr, sourceBytes.length);\n\n    if (result !== ErrorCode.SUCCESS) {\n        throw new Error(`Compilation failed: ${getErrorMessage(result)}`);\n    }\n\n    // Get output\n    const outPtr = exports.getOutputPtr();\n    const outLen = exports.getOutputLen();\n\n    if (!outPtr || outLen === 0) {\n        throw new Error('Compilation produced no output');\n    }\n\n    // Copy output\n    const bytecode = new Uint8Array(outLen);\n    bytecode.set(new Uint8Array(exports.memory.buffer, outPtr, outLen));\n\n    // Free WASM-side output\n    exports.freeOutput();\n\n    return { bytecode };\n}\n\n/**\n * Load bytecode module.\n * @param {Object} payload\n * @param {Uint8Array} payload.bytecode - PNGB bytecode\n */\nfunction handleLoadModule(payload) {\n    assertInitialized();\n\n    const { bytecode } = payload;\n    const exports = wasmInstance.exports;\n\n    // Reset any previous state\n    moduleLoaded = false;\n    gpu.reset();\n    exports.freeModule();\n\n    // Allocate memory for bytecode\n    const ptr = exports.alloc(bytecode.length);\n    if (!ptr) {\n        throw new Error('Failed to allocate memory for bytecode');\n    }\n\n    // Copy bytecode to WASM memory\n    const memory = new Uint8Array(exports.memory.buffer);\n    memory.set(bytecode, ptr);\n\n    // Load module\n    const result = exports.loadModule(ptr, bytecode.length);\n\n    // Free bytecode memory\n    exports.free(ptr, bytecode.length);\n\n    if (result !== ErrorCode.SUCCESS) {\n        moduleLoaded = false;\n        throw new Error(`Failed to load module: ${getErrorMessage(result)}`);\n    }\n\n    moduleLoaded = true;\n\n    // Get frame info\n    const frameCount = exports.getFrameCount ? exports.getFrameCount() : 0;\n\n    debug.log(`Module loaded successfully, frameCount=${frameCount}`);\n\n    return {\n        success: true,\n        frameCount,\n    };\n}\n\n/**\n * Load module from URL (auto-detects format).\n * @param {Object} payload\n * @param {string} payload.url - URL to load from\n */\nasync function handleLoadFromUrl(payload) {\n    assertInitialized();\n\n    const { url } = payload;\n\n    // Fetch the file\n    const response = await fetch(url);\n    if (!response.ok) {\n        throw new Error(`Failed to fetch: ${response.status}`);\n    }\n\n    const buffer = await response.arrayBuffer();\n    const bytes = new Uint8Array(buffer);\n\n    // Detect format and extract bytecode\n    let bytecode;\n\n    if (isZip(bytes)) {\n        bytecode = extractFromZip(bytes);\n    } else if (hasPngb(bytes)) {\n        bytecode = extractPngb(bytes);\n    } else if (bytes.length >= 4 &&\n               bytes[0] === 0x50 && bytes[1] === 0x4E &&\n               bytes[2] === 0x47 && bytes[3] === 0x42) {\n        // Raw PNGB\n        bytecode = bytes;\n    } else {\n        throw new Error('Unknown file format');\n    }\n\n    // Load the bytecode\n    return handleLoadModule({ bytecode });\n}\n\n/**\n * Free loaded module.\n */\nfunction handleFreeModule() {\n    assertInitialized();\n\n    wasmInstance.exports.freeModule();\n    gpu.reset();\n    moduleLoaded = false;\n\n    debug.log('Module freed');\n\n    return { success: true };\n}\n\n/**\n * Execute all frames in the module.\n */\nfunction handleExecuteAll() {\n    assertInitialized();\n\n    const result = wasmInstance.exports.executeAll();\n\n    if (result !== ErrorCode.SUCCESS) {\n        throw new Error(`Execution failed: ${getErrorMessage(result)}`);\n    }\n\n    return { success: true };\n}\n\n/**\n * Execute a specific frame by name.\n * @param {Object} payload\n * @param {string} payload.frameName - Frame name\n */\nfunction handleExecuteFrame(payload) {\n    assertInitialized();\n\n    const { frameName } = payload;\n    debug.log(`executeFrame: frameName=\"${frameName}\"`);\n    const exports = wasmInstance.exports;\n    const encoder = new TextEncoder();\n    const nameBytes = encoder.encode(frameName);\n\n    // Allocate memory for name\n    const namePtr = exports.alloc(nameBytes.length);\n    if (!namePtr) {\n        throw new Error('Failed to allocate memory for frame name');\n    }\n\n    // Copy name to WASM memory\n    const memory = new Uint8Array(exports.memory.buffer);\n    memory.set(nameBytes, namePtr);\n\n    // Execute\n    const result = exports.executeFrameByName(namePtr, nameBytes.length);\n\n    // Free name memory\n    exports.free(namePtr, nameBytes.length);\n\n    if (result !== ErrorCode.SUCCESS) {\n        throw new Error(`Frame execution failed: ${getErrorMessage(result)}`);\n    }\n\n    return { success: true };\n}\n\n/**\n * Render a frame at the given time.\n * Used by animation loop on main thread.\n * @param {Object} payload\n * @param {number} payload.time - Time in seconds\n * @param {number} [payload.deltaTime] - Delta time since last frame\n * @param {number} [payload.uniformBufferId] - Buffer ID for time uniform\n * @param {number} [payload.uniformBufferSize] - Size of uniform buffer\n * @param {string|null} [payload.frameName] - Optional specific frame to execute\n */\nfunction handleRenderFrame(payload) {\n    assertInitialized();\n\n    if (!moduleLoaded) {\n        throw new Error('No module loaded - call loadModule() first');\n    }\n\n    const { time, deltaTime = 0, uniformBufferId, uniformBufferSize = 12, frameName = null } = payload;\n\n    // Set time for WASM calls\n    gpu.setTime(time, deltaTime);\n\n    // If uniform buffer specified, write time uniform\n    if (uniformBufferId != null && uniformBufferSize > 0) {\n        const width = canvas.width;\n        const height = canvas.height;\n\n        // Create data based on buffer size (4 bytes per float)\n        const numFloats = Math.floor(uniformBufferSize / 4);\n        const floatView = new Float32Array(numFloats);\n\n        if (numFloats >= 1) floatView[0] = time;\n        if (numFloats >= 2) floatView[1] = width;\n        if (numFloats >= 3) floatView[2] = height;\n        if (numFloats >= 4) floatView[3] = width / height;\n\n        gpu.writeTimeToBuffer(uniformBufferId, new Uint8Array(floatView.buffer));\n    }\n\n    // Execute specific frame or all frames\n    let result;\n    if (frameName) {\n        const exports = wasmInstance.exports;\n        const encoder = new TextEncoder();\n        const nameBytes = encoder.encode(frameName);\n\n        const namePtr = exports.alloc(nameBytes.length);\n        if (!namePtr) {\n            throw new Error('Failed to allocate memory for frame name');\n        }\n\n        const memory = new Uint8Array(exports.memory.buffer);\n        memory.set(nameBytes, namePtr);\n\n        result = exports.executeFrameByName(namePtr, nameBytes.length);\n        exports.free(namePtr, nameBytes.length);\n    } else {\n        result = wasmInstance.exports.executeAll();\n    }\n\n    if (result !== ErrorCode.SUCCESS) {\n        debug.error(`Render failed: result=${result}, moduleLoaded=${moduleLoaded}, frameName=${frameName}`);\n        throw new Error(`Render failed: ${getErrorMessage(result)}`);\n    }\n\n    return { success: true };\n}\n\n/**\n * Get frame count from loaded module.\n */\nfunction handleGetFrameCount() {\n    assertInitialized();\n\n    const count = wasmInstance.exports.getFrameCount\n        ? wasmInstance.exports.getFrameCount()\n        : 0;\n\n    return { frameCount: count };\n}\n\n/**\n * Get metadata from loaded module.\n */\nfunction handleGetMetadata() {\n    assertInitialized();\n\n    // Get basic info\n    const frameCount = wasmInstance.exports.getFrameCount\n        ? wasmInstance.exports.getFrameCount()\n        : 0;\n\n    return {\n        frameCount,\n        canvasWidth: canvas.width,\n        canvasHeight: canvas.height,\n    };\n}\n\n/**\n * Find the first uniform buffer.\n */\nfunction handleFindUniformBuffer() {\n    assertInitialized();\n\n    const bufferInfo = gpu.findUniformBuffer();\n\n    return { bufferInfo };\n}\n\n// ============================================================================\n// Helpers\n// ============================================================================\n\n/**\n * Assert that the worker is initialized.\n * @throws {Error} If not initialized\n */\nfunction assertInitialized() {\n    if (!initialized) {\n        const error = new Error('Worker not initialized');\n        error.code = ErrorCode.NOT_INITIALIZED;\n        throw error;\n    }\n}\n";

function createWorkerBlobUrl() {
  const blob = new Blob([WORKER_CODE], { type: 'application/javascript' });
  return URL.createObjectURL(blob);
}


export async function initPNGine(canvas, wasmUrl = 'pngine.wasm', workerUrl) {
    // 1. Check OffscreenCanvas support
    if (!canvas.transferControlToOffscreen) {
        throw new Error('OffscreenCanvas not supported - this browser cannot run PNGine');
    }

    // 2. Transfer canvas to offscreen
    const offscreen = canvas.transferControlToOffscreen();

    // 3. Create Worker
    const worker = new Worker(createWorkerBlobUrl());
    const rpc = new WorkerRPC(worker);

    // 4. Initialize Worker with offscreen canvas
    const initResult = await rpc.call(
        MessageType.INIT,
        { canvas: offscreen, wasmUrl },
        [offscreen] // Transfer the canvas
    );

    return new PNGine(rpc, canvas.width, canvas.height);
}

/**
 * Initialize PNGine from a PNG image with embedded bytecode.
 *
 * @param {HTMLCanvasElement} canvas - Canvas element for rendering
 * @param {string} pngUrl - URL to PNG image with embedded bytecode
 * @param {string} wasmUrl - URL to pngine.wasm file
 * @returns {Promise<PNGine>} Initialized PNGine instance with loaded module
 */
export async function initFromPng(canvas, pngUrl, wasmUrl = 'pngine.wasm') {
    const pngine = await initPNGine(canvas, wasmUrl);
    await pngine.loadFromUrl(pngUrl);
    return pngine;
}

/**
 * Initialize PNGine from a ZIP bundle.
 *
 * @param {HTMLCanvasElement} canvas - Canvas element for rendering
 * @param {string} zipUrl - URL to ZIP bundle
 * @param {string} wasmUrl - URL to pngine.wasm (used if not in bundle)
 * @returns {Promise<PNGine>} Initialized PNGine instance with loaded module
 */
export async function initFromZip(canvas, zipUrl, wasmUrl = 'pngine.wasm') {
    const pngine = await initPNGine(canvas, wasmUrl);
    await pngine.loadFromUrl(zipUrl);
    return pngine;
}

/**
 * Initialize PNGine from any supported URL (auto-detects format).
 *
 * @param {HTMLCanvasElement} canvas - Canvas element for rendering
 * @param {string} url - URL to PNG, ZIP, or PNGB file
 * @param {string} wasmUrl - URL to pngine.wasm file
 * @returns {Promise<PNGine>} Initialized PNGine instance with loaded module
 */
export async function initFromUrl(canvas, url, wasmUrl = 'pngine.wasm') {
    const pngine = await initPNGine(canvas, wasmUrl);
    await pngine.loadFromUrl(url);
    return pngine;
}

// ============================================================================
// PNGine Class
// ============================================================================

/**
 * PNGine runtime instance.
 *
 * All GPU operations are proxied to a WebWorker.
 * This class maintains the same API as the non-Worker version.
 */
export class PNGine {
    /**
     * @param {WorkerRPC} rpc - Worker RPC instance
     * @param {number} width - Canvas width
     * @param {number} height - Canvas height
     */
    constructor(rpc, width, height) {
        this.rpc = rpc;
        this.width = width;
        this.height = height;

        // Animation state
        this.isPlaying = false;
        this.animationId = null;
        this.startTime = 0;
        this.lastTime = 0;
        this.currentTime = 0;

        // Frame selection for animation
        this.currentFrameName = null;  // null = all frames, string = specific frame

        // Callback for time updates (UI can use this to update slider)
        this.onTimeUpdate = null;

        // Frame pacing - track pending render to prevent queue buildup
        this.renderPending = false;

        // Uniform buffer tracking (for animation)
        this.uniformBufferId = null;
        this.uniformBufferSize = 12;

        // Sync debug state with worker
        if (debugEnabled) {
            this.rpc.call(MessageType.SET_DEBUG, { enabled: true }).catch(() => {});
        }
    }

    /**
     * Enable or disable debug mode for this instance and its worker.
     * @param {boolean} enabled
     */
    async setDebug(enabled) {
        setDebug(enabled);  // Update global state
        await this.rpc.call(MessageType.SET_DEBUG, { enabled });
    }

    /**
     * Compile source code to PNGB bytecode.
     *
     * @param {string} source - Source code
     * @returns {Promise<Uint8Array>} Compiled PNGB bytecode
     */
    async compile(source) {
        const result = await this.rpc.call(MessageType.COMPILE, { source });
        return result.bytecode;
    }

    /**
     * Load PNGB bytecode for execution.
     *
     * @param {Uint8Array} bytecode - PNGB bytecode
     * @returns {Promise<{frameCount: number}>} Load result
     */
    async loadModule(bytecode) {
        // Reset uniform buffer tracking
        this.uniformBufferId = null;

        // Copy bytecode before transfer (original may be reused)
        const copy = new Uint8Array(bytecode);

        // Transfer the copy's buffer for efficiency
        const result = await this.rpc.call(
            MessageType.LOAD_MODULE,
            { bytecode: copy },
            [copy.buffer]
        );

        // Note: uniform buffer detection happens after first executeAll()
        // since buffers aren't created until bytecode executes

        return result;
    }

    /**
     * Load module from any supported URL (auto-detects format).
     *
     * @param {string} url - URL of PNG, ZIP, or PNGB file
     * @returns {Promise<{frameCount: number}>} Load result
     */
    async loadFromUrl(url) {
        // Reset uniform buffer tracking
        this.uniformBufferId = null;

        const result = await this.rpc.call(MessageType.LOAD_FROM_URL, { url });

        // Auto-detect uniform buffer for animation
        await this._detectUniformBuffer();

        return result;
    }

    /**
     * Load module from PNG ArrayBuffer/Uint8Array.
     *
     * @param {ArrayBuffer|Uint8Array} pngData - PNG file data
     * @returns {Promise<{frameCount: number}>} Load result
     */
    async loadFromPngData(pngData) {
        const bytecode = extractPngb(pngData);
        return this.loadModule(bytecode);
    }

    /**
     * Load module from ZIP ArrayBuffer/Uint8Array.
     *
     * @param {ArrayBuffer|Uint8Array} zipData - ZIP file data
     * @returns {Promise<{frameCount: number}>} Load result
     */
    async loadFromZipData(zipData) {
        const bytecode = extractFromZip(zipData);
        return this.loadModule(bytecode);
    }

    /**
     * Load module from any supported data format (auto-detects).
     *
     * @param {ArrayBuffer|Uint8Array} data - PNG, ZIP, or PNGB data
     * @returns {Promise<{frameCount: number}>} Load result
     */
    async loadFromData(data) {
        const bytecode = await extractBytecode(data);
        return this.loadModule(bytecode);
    }

    /**
     * Free the loaded module.
     *
     * @returns {Promise<void>}
     */
    async freeModule() {
        await this.rpc.call(MessageType.FREE_MODULE);
        this.uniformBufferId = null;
    }

    /**
     * Execute all bytecode in the loaded module.
     *
     * @returns {Promise<void>}
     */
    async executeAll() {
        await this.rpc.call(MessageType.EXECUTE_ALL);

        // Detect uniform buffer after first execution (buffers created during execute)
        if (this.uniformBufferId == null) {
            await this._detectUniformBuffer();
        }
    }

    /**
     * Execute a specific frame by name.
     *
     * @param {string} frameName - Name of the frame to execute
     * @returns {Promise<void>}
     */
    async executeFrameByName(frameName) {
        await this.rpc.call(MessageType.EXECUTE_FRAME, { frameName });
    }

    /**
     * Compile and execute source in one step.
     *
     * @param {string} source - Source code
     * @returns {Promise<void>}
     */
    async run(source) {
        const bytecode = await this.compile(source);
        await this.loadModule(new Uint8Array(bytecode));
        await this.executeAll();
    }

    /**
     * Get the number of frames in the loaded module.
     *
     * @returns {Promise<number>} Frame count
     */
    async getFrameCount() {
        const result = await this.rpc.call(MessageType.GET_FRAME_COUNT);
        return result.frameCount;
    }

    /**
     * Get metadata from loaded module.
     *
     * @returns {Promise<Object>} Metadata
     */
    async getMetadata() {
        return this.rpc.call(MessageType.GET_METADATA);
    }

    /**
     * Find the first buffer with UNIFORM usage.
     *
     * @returns {Promise<{id: number, size: number}|null>} Buffer info or null
     */
    async findUniformBuffer() {
        const result = await this.rpc.call(MessageType.FIND_UNIFORM_BUFFER);
        return result.bufferInfo;
    }

    // ========================================================================
    // Animation API
    // ========================================================================

    /**
     * Start animation loop.
     * Renders frames continuously at 60fps.
     */
    startAnimation() {
        if (this.isPlaying) return;

        this.isPlaying = true;
        this.startTime = performance.now();
        this.lastTime = this.startTime;

        this._animationLoop();
    }

    /**
     * Stop animation loop.
     */
    stopAnimation() {
        this.isPlaying = false;
        this.renderPending = false;
        if (this.animationId !== null) {
            cancelAnimationFrame(this.animationId);
            this.animationId = null;
        }
    }

    /**
     * Set the frame to render during animation.
     * @param {string|null} frameName - Frame name or null for all frames
     */
    setFrame(frameName) {
        this.currentFrameName = frameName;
    }

    /**
     * Get current animation time in seconds.
     * @returns {number}
     */
    getTime() {
        return this.currentTime;
    }

    /**
     * Render a single frame at the given time.
     * Does not start animation loop.
     *
     * @param {number} time - Time in seconds
     * @param {string} [frameName] - Optional specific frame to render (null = all frames)
     * @returns {Promise<void>}
     */
    async renderFrame(time, frameName = null) {
        await this.rpc.call(MessageType.RENDER_FRAME, {
            time,
            deltaTime: 0,
            uniformBufferId: this.uniformBufferId,
            uniformBufferSize: this.uniformBufferSize,
            frameName,
        });
    }

    /**
     * Internal animation loop.
     * Uses frame pacing to prevent message queue buildup.
     */
    _animationLoop() {
        if (!this.isPlaying) return;

        const now = performance.now();
        const time = (now - this.startTime) / 1000;
        const deltaTime = (now - this.lastTime) / 1000;
        this.lastTime = now;
        this.currentTime = time;

        // Call time update callback if set (for UI slider updates)
        if (this.onTimeUpdate) {
            this.onTimeUpdate(time);
        }

        // Skip frame if previous render is still pending (prevents queue buildup)
        if (this.renderPending) {
            this.animationId = requestAnimationFrame(() => this._animationLoop());
            return;
        }

        // Mark render as pending
        this.renderPending = true;

        // Send render request with frame name and await completion
        this.rpc.call(MessageType.RENDER_FRAME, {
            time,
            deltaTime,
            uniformBufferId: this.uniformBufferId,
            uniformBufferSize: this.uniformBufferSize,
            frameName: this.currentFrameName,
        }).then(() => {
            this.renderPending = false;
        }).catch((err) => {
            console.error('[PNGine] Render error:', err);
            this.renderPending = false;
        });

        this.animationId = requestAnimationFrame(() => this._animationLoop());
    }

    /**
     * Detect uniform buffer for animation updates.
     */
    async _detectUniformBuffer() {
        const bufferInfo = await this.findUniformBuffer();
        debug.log(`_detectUniformBuffer: bufferInfo=`, bufferInfo);
        if (bufferInfo) {
            this.uniformBufferId = bufferInfo.id;
            this.uniformBufferSize = bufferInfo.size;
            debug.log(`uniformBufferId=${this.uniformBufferId}, size=${this.uniformBufferSize}`);
        } else {
            debug.log(`No uniform buffer found`);
        }
    }

    // ========================================================================
    // Lifecycle
    // ========================================================================

    /**
     * Terminate the Worker and clean up resources.
     */
    terminate() {
        this.stopAnimation();
        this.rpc.call(MessageType.TERMINATE).catch(() => {});
        this.rpc.terminate();
    }
}
