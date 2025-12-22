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
export async function initPNGine(canvas, wasmUrl = 'pngine.wasm', workerUrl = './pngine-worker.js') {
    // 1. Check OffscreenCanvas support
    if (!canvas.transferControlToOffscreen) {
        throw new Error('OffscreenCanvas not supported - this browser cannot run PNGine');
    }

    // 2. Transfer canvas to offscreen
    const offscreen = canvas.transferControlToOffscreen();

    // 3. Create Worker
    const worker = new Worker(workerUrl, { type: 'module' });
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
