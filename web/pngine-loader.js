/**
 * PNGine WASM Loader
 *
 * Orchestrates WASM instantiation with WebGPU bindings.
 * Provides a high-level API for compiling and executing PNGine bytecode.
 */

import { PNGineGPU } from './pngine-gpu.js';
import { extractPngb, fetchAndExtract, hasPngb, getPngbInfo } from './pngine-png.js';

// Re-export PNG utilities
export { extractPngb, fetchAndExtract, hasPngb, getPngbInfo };

/**
 * Error codes returned by WASM functions.
 */
export const ErrorCode = {
    SUCCESS: 0,
    NOT_INITIALIZED: 1,
    OUT_OF_MEMORY: 2,
    PARSE_ERROR: 3,
    INVALID_FORMAT: 4,
    NO_MODULE: 5,
    EXECUTION_ERROR: 6,
    // Assembler errors (10-29)
    UNKNOWN_FORM: 10,
    INVALID_FORM_STRUCTURE: 11,
    UNDEFINED_RESOURCE: 12,
    DUPLICATE_RESOURCE: 13,
    TOO_MANY_RESOURCES: 14,
    EXPECTED_ATOM: 15,
    EXPECTED_STRING: 16,
    EXPECTED_NUMBER: 17,
    EXPECTED_LIST: 18,
    INVALID_RESOURCE_ID: 19,
    UNKNOWN: 99,
};

/**
 * Initialize PNGine with WebGPU.
 *
 * @param {HTMLCanvasElement} canvas - Canvas element for rendering
 * @param {string} wasmUrl - URL to pngine.wasm file
 * @returns {Promise<PNGine>} Initialized PNGine instance
 */
export async function initPNGine(canvas, wasmUrl = 'pngine.wasm') {
    // 1. Check WebGPU support
    if (!navigator.gpu) {
        throw new Error('WebGPU not supported in this browser');
    }

    // 2. Request adapter and device
    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) {
        throw new Error('Failed to get WebGPU adapter');
    }

    const device = await adapter.requestDevice();

    // 3. Configure canvas context
    const context = canvas.getContext('webgpu');
    if (!context) {
        throw new Error('Failed to get WebGPU context');
    }

    const format = navigator.gpu.getPreferredCanvasFormat();
    context.configure({
        device,
        format,
        alphaMode: 'premultiplied',
    });

    // 4. Create GPU backend
    const gpu = new PNGineGPU(device, context);

    // 5. Load and instantiate WASM
    const response = await fetch(wasmUrl);
    if (!response.ok) {
        throw new Error(`Failed to fetch WASM: ${response.status}`);
    }

    const { instance } = await WebAssembly.instantiateStreaming(
        response,
        gpu.getImports()
    );

    // 6. Set memory reference for GPU backend
    gpu.setMemory(instance.exports.memory);

    // 7. Initialize WASM runtime
    instance.exports.onInit();

    return new PNGine(instance, gpu, device);
}

/**
 * Initialize PNGine from a PNG image with embedded bytecode.
 *
 * This is the simplest way to run a PNGine program - just point to a PNG
 * image that contains embedded PNGB bytecode.
 *
 * @param {HTMLCanvasElement} canvas - Canvas element for rendering
 * @param {string} pngUrl - URL to PNG image with embedded bytecode
 * @param {string} wasmUrl - URL to pngine.wasm file
 * @returns {Promise<PNGine>} Initialized PNGine instance with loaded module
 *
 * @example
 * const pngine = await initFromPng(canvas, 'artwork.png');
 * pngine.executeAll();
 */
export async function initFromPng(canvas, pngUrl, wasmUrl = 'pngine.wasm') {
    // 1. Fetch and extract bytecode from PNG (can happen in parallel with WASM init)
    const bytecodePromise = fetchAndExtract(pngUrl);

    // 2. Initialize PNGine with WebGPU
    const pngine = await initPNGine(canvas, wasmUrl);

    // 3. Wait for bytecode extraction
    const bytecode = await bytecodePromise;

    // 4. Load the extracted bytecode
    pngine.loadModule(bytecode);

    return pngine;
}

/**
 * PNGine runtime instance.
 */
export class PNGine {
    /**
     * @param {WebAssembly.Instance} instance - WASM instance
     * @param {PNGineGPU} gpu - GPU backend
     * @param {GPUDevice} device - WebGPU device
     */
    constructor(instance, gpu, device) {
        this.instance = instance;
        this.gpu = gpu;
        this.device = device;
        this.exports = instance.exports;
    }

    /**
     * Compile PBSF source to PNGB bytecode.
     *
     * @param {string} source - PBSF source code
     * @returns {Uint8Array} Compiled PNGB bytecode
     * @throws {Error} On compilation failure
     */
    compile(source) {
        const encoder = new TextEncoder();
        const sourceBytes = encoder.encode(source);

        // Allocate memory for source
        const srcPtr = this.exports.alloc(sourceBytes.length);
        if (!srcPtr) {
            throw new Error('Failed to allocate memory for source');
        }

        // Copy source to WASM memory
        const memory = new Uint8Array(this.exports.memory.buffer);
        memory.set(sourceBytes, srcPtr);

        // Compile
        const result = this.exports.compile(srcPtr, sourceBytes.length);

        // Free source memory
        this.exports.free(srcPtr, sourceBytes.length);

        if (result !== ErrorCode.SUCCESS) {
            throw new Error(`Compilation failed: ${this.getErrorMessage(result)}`);
        }

        // Get output
        const outPtr = this.exports.getOutputPtr();
        const outLen = this.exports.getOutputLen();

        if (!outPtr || outLen === 0) {
            throw new Error('Compilation produced no output');
        }

        // Copy output (caller owns the copy)
        const output = new Uint8Array(outLen);
        output.set(new Uint8Array(this.exports.memory.buffer, outPtr, outLen));

        // Free WASM-side output
        this.exports.freeOutput();

        return output;
    }

    /**
     * Load PNGB bytecode for execution.
     *
     * @param {Uint8Array} bytecode - PNGB bytecode
     * @throws {Error} On load failure
     */
    loadModule(bytecode) {
        // Allocate memory for bytecode
        const ptr = this.exports.alloc(bytecode.length);
        if (!ptr) {
            throw new Error('Failed to allocate memory for bytecode');
        }

        // Copy bytecode to WASM memory
        const memory = new Uint8Array(this.exports.memory.buffer);
        memory.set(bytecode, ptr);

        // Load module
        const result = this.exports.loadModule(ptr, bytecode.length);

        // Free bytecode memory (module makes its own copy)
        this.exports.free(ptr, bytecode.length);

        if (result !== ErrorCode.SUCCESS) {
            throw new Error(`Failed to load module: ${this.getErrorMessage(result)}`);
        }
    }

    /**
     * Execute all bytecode in the loaded module.
     *
     * @throws {Error} On execution failure
     */
    executeAll() {
        const result = this.exports.executeAll();
        if (result !== ErrorCode.SUCCESS) {
            throw new Error(`Execution failed: ${this.getErrorMessage(result)}`);
        }
    }

    /**
     * Compile and execute PBSF source in one step.
     *
     * @param {string} source - PBSF source code
     */
    run(source) {
        const bytecode = this.compile(source);
        this.loadModule(bytecode);
        this.executeAll();
    }

    /**
     * Free the loaded module.
     */
    freeModule() {
        this.exports.freeModule();
        this.gpu.reset();
    }

    /**
     * Load module from a PNG with embedded bytecode.
     *
     * @param {string} url - URL of PNG file with embedded bytecode
     * @throws {Error} On load failure
     */
    async loadFromPng(url) {
        const bytecode = await fetchAndExtract(url);
        this.loadModule(bytecode);
    }

    /**
     * Load module from PNG ArrayBuffer/Uint8Array.
     *
     * @param {ArrayBuffer|Uint8Array} pngData - PNG file data
     * @throws {Error} On extraction or load failure
     */
    async loadFromPngData(pngData) {
        const bytecode = await extractPngb(pngData);
        this.loadModule(bytecode);
    }

    /**
     * Write uniforms to a buffer (time + canvas dimensions).
     * Writes: f32 time, u32 canvasW, u32 canvasH (12 bytes total)
     *
     * @param {number} bufferId - Buffer ID to write to
     * @param {number} time - Time value in seconds (f32)
     */
    writeTimeUniform(bufferId, time) {
        // Get canvas dimensions
        const canvas = this.gpu.context.canvas;
        const width = canvas.width;
        const height = canvas.height;

        // Create buffer: f32 time + u32 width + u32 height = 12 bytes
        const buffer = new ArrayBuffer(12);
        const floatView = new Float32Array(buffer, 0, 1);
        const uintView = new Uint32Array(buffer, 4, 2);

        floatView[0] = time;
        uintView[0] = width;
        uintView[1] = height;

        // Write to GPU buffer
        this.gpu.writeTimeToBuffer(bufferId, new Uint8Array(buffer));
    }

    /**
     * Find the first buffer with UNIFORM usage.
     * Useful for auto-detecting which buffer to write time uniforms to.
     * @returns {number|null} Buffer ID or null if not found
     */
    findUniformBuffer() {
        return this.gpu.findUniformBuffer();
    }

    /**
     * Get human-readable error message.
     * @param {number} code - Error code
     * @returns {string} Error message
     */
    getErrorMessage(code) {
        switch (code) {
            case ErrorCode.NOT_INITIALIZED: return 'WASM not initialized';
            case ErrorCode.OUT_OF_MEMORY: return 'Out of memory';
            case ErrorCode.PARSE_ERROR: return 'Parse error';
            case ErrorCode.INVALID_FORMAT: return 'Invalid bytecode format';
            case ErrorCode.NO_MODULE: return 'No module loaded';
            case ErrorCode.EXECUTION_ERROR: return 'Execution error';
            // Assembler errors
            case ErrorCode.UNKNOWN_FORM: return 'Unknown PBSF form (use shader, pipeline, frame)';
            case ErrorCode.INVALID_FORM_STRUCTURE: return 'Invalid form structure';
            case ErrorCode.UNDEFINED_RESOURCE: return 'Undefined resource reference';
            case ErrorCode.DUPLICATE_RESOURCE: return 'Duplicate resource ID';
            case ErrorCode.TOO_MANY_RESOURCES: return 'Too many resources';
            case ErrorCode.EXPECTED_ATOM: return 'Expected atom (identifier or number)';
            case ErrorCode.EXPECTED_STRING: return 'Expected string';
            case ErrorCode.EXPECTED_NUMBER: return 'Expected number';
            case ErrorCode.EXPECTED_LIST: return 'Expected list';
            case ErrorCode.INVALID_RESOURCE_ID: return 'Invalid resource ID format';
            default: return `Unknown error (${code})`;
        }
    }
}
