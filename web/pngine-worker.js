/**
 * PNGine Worker
 *
 * Worker thread that owns WebGPU device and WASM instance.
 * Receives commands from main thread via postMessage.
 */

import { PNGineGPU } from './pngine-gpu.js';
import { MessageType, ErrorCode, getErrorMessage } from './pngine-protocol.js';
import { extractPngb, hasPngb } from './pngine-png.js';
import { isZip, extractFromZip } from './pngine-zip.js';

// ============================================================================
// Worker State
// ============================================================================

/** @type {OffscreenCanvas} */
let canvas = null;

/** @type {GPUDevice} */
let device = null;

/** @type {GPUCanvasContext} */
let context = null;

/** @type {PNGineGPU} */
let gpu = null;

/** @type {WebAssembly.Instance} */
let wasmInstance = null;

/** @type {boolean} */
let initialized = false;

// ============================================================================
// Message Handling
// ============================================================================

/**
 * Handle incoming messages from main thread.
 * @param {MessageEvent} event
 */
self.onmessage = async (event) => {
    const { id, type, payload } = event.data;

    try {
        let result;

        switch (type) {
            case MessageType.INIT:
                result = await handleInit(payload);
                break;

            case MessageType.TERMINATE:
                result = handleTerminate();
                break;

            case MessageType.COMPILE:
                result = handleCompile(payload);
                break;

            case MessageType.LOAD_MODULE:
                result = handleLoadModule(payload);
                break;

            case MessageType.LOAD_FROM_URL:
                result = await handleLoadFromUrl(payload);
                break;

            case MessageType.FREE_MODULE:
                result = handleFreeModule();
                break;

            case MessageType.EXECUTE_ALL:
                result = handleExecuteAll();
                break;

            case MessageType.EXECUTE_FRAME:
                result = handleExecuteFrame(payload);
                break;

            case MessageType.RENDER_FRAME:
                result = handleRenderFrame(payload);
                break;

            case MessageType.GET_FRAME_COUNT:
                result = handleGetFrameCount();
                break;

            case MessageType.GET_METADATA:
                result = handleGetMetadata();
                break;

            case MessageType.FIND_UNIFORM_BUFFER:
                result = handleFindUniformBuffer();
                break;

            default:
                throw new Error(`Unknown message type: ${type}`);
        }

        // Send success response
        self.postMessage({
            id,
            type: MessageType.RESPONSE,
            payload: result,
        });

    } catch (error) {
        // Send error response
        self.postMessage({
            id,
            type: MessageType.ERROR,
            payload: {
                message: error.message,
                name: error.name,
                stack: error.stack,
                code: error.code,
            },
        });
    }
};

// ============================================================================
// Message Handlers
// ============================================================================

/**
 * Initialize WebGPU and WASM in worker.
 * @param {Object} payload
 * @param {OffscreenCanvas} payload.canvas - Transferred canvas
 * @param {string} payload.wasmUrl - URL to pngine.wasm
 */
async function handleInit(payload) {
    if (initialized) {
        throw new Error('Worker already initialized');
    }

    canvas = payload.canvas;
    const wasmUrl = payload.wasmUrl || 'pngine.wasm';

    // 1. Check WebGPU support in worker
    if (!navigator.gpu) {
        throw new Error('WebGPU not supported in this worker');
    }

    // 2. Request adapter and device
    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) {
        throw new Error('Failed to get WebGPU adapter');
    }

    device = await adapter.requestDevice();

    // 3. Configure canvas context
    context = canvas.getContext('webgpu');
    if (!context) {
        throw new Error('Failed to get WebGPU context from OffscreenCanvas');
    }

    const format = navigator.gpu.getPreferredCanvasFormat();
    context.configure({
        device,
        format,
        alphaMode: 'premultiplied',
    });

    // 4. Create GPU backend
    gpu = new PNGineGPU(device, context);

    // 5. Load and instantiate WASM
    const response = await fetch(wasmUrl);
    if (!response.ok) {
        throw new Error(`Failed to fetch WASM: ${response.status}`);
    }

    const { instance } = await WebAssembly.instantiateStreaming(
        response,
        gpu.getImports()
    );

    wasmInstance = instance;

    // 6. Set memory reference for GPU backend
    gpu.setMemory(instance.exports.memory);

    // 7. Initialize WASM runtime
    instance.exports.onInit();

    initialized = true;

    return {
        success: true,
        canvasWidth: canvas.width,
        canvasHeight: canvas.height,
    };
}

/**
 * Terminate worker and clean up resources.
 */
function handleTerminate() {
    if (gpu) {
        gpu.reset();
    }
    if (wasmInstance && wasmInstance.exports.freeModule) {
        wasmInstance.exports.freeModule();
    }

    canvas = null;
    device = null;
    context = null;
    gpu = null;
    wasmInstance = null;
    initialized = false;

    return { success: true };
}

/**
 * Compile source code to bytecode.
 * @param {Object} payload
 * @param {string} payload.source - Source code to compile
 */
function handleCompile(payload) {
    assertInitialized();

    const { source } = payload;
    const encoder = new TextEncoder();
    const sourceBytes = encoder.encode(source);

    const exports = wasmInstance.exports;

    // Allocate memory for source
    const srcPtr = exports.alloc(sourceBytes.length);
    if (!srcPtr) {
        throw new Error('Failed to allocate memory for source');
    }

    // Copy source to WASM memory
    const memory = new Uint8Array(exports.memory.buffer);
    memory.set(sourceBytes, srcPtr);

    // Compile
    const result = exports.compile(srcPtr, sourceBytes.length);

    // Free source memory
    exports.free(srcPtr, sourceBytes.length);

    if (result !== ErrorCode.SUCCESS) {
        throw new Error(`Compilation failed: ${getErrorMessage(result)}`);
    }

    // Get output
    const outPtr = exports.getOutputPtr();
    const outLen = exports.getOutputLen();

    if (!outPtr || outLen === 0) {
        throw new Error('Compilation produced no output');
    }

    // Copy output
    const bytecode = new Uint8Array(outLen);
    bytecode.set(new Uint8Array(exports.memory.buffer, outPtr, outLen));

    // Free WASM-side output
    exports.freeOutput();

    return { bytecode };
}

/**
 * Load bytecode module.
 * @param {Object} payload
 * @param {Uint8Array} payload.bytecode - PNGB bytecode
 */
function handleLoadModule(payload) {
    assertInitialized();

    const { bytecode } = payload;
    const exports = wasmInstance.exports;

    // Reset any previous state
    gpu.reset();
    exports.freeModule();

    // Allocate memory for bytecode
    const ptr = exports.alloc(bytecode.length);
    if (!ptr) {
        throw new Error('Failed to allocate memory for bytecode');
    }

    // Copy bytecode to WASM memory
    const memory = new Uint8Array(exports.memory.buffer);
    memory.set(bytecode, ptr);

    // Load module
    const result = exports.loadModule(ptr, bytecode.length);

    // Free bytecode memory
    exports.free(ptr, bytecode.length);

    if (result !== ErrorCode.SUCCESS) {
        throw new Error(`Failed to load module: ${getErrorMessage(result)}`);
    }

    // Get frame info
    const frameCount = exports.getFrameCount ? exports.getFrameCount() : 0;

    return {
        success: true,
        frameCount,
    };
}

/**
 * Load module from URL (auto-detects format).
 * @param {Object} payload
 * @param {string} payload.url - URL to load from
 */
async function handleLoadFromUrl(payload) {
    assertInitialized();

    const { url } = payload;

    // Fetch the file
    const response = await fetch(url);
    if (!response.ok) {
        throw new Error(`Failed to fetch: ${response.status}`);
    }

    const buffer = await response.arrayBuffer();
    const bytes = new Uint8Array(buffer);

    // Detect format and extract bytecode
    let bytecode;

    if (isZip(bytes)) {
        bytecode = extractFromZip(bytes);
    } else if (hasPngb(bytes)) {
        bytecode = extractPngb(bytes);
    } else if (bytes.length >= 4 &&
               bytes[0] === 0x50 && bytes[1] === 0x4E &&
               bytes[2] === 0x47 && bytes[3] === 0x42) {
        // Raw PNGB
        bytecode = bytes;
    } else {
        throw new Error('Unknown file format');
    }

    // Load the bytecode
    return handleLoadModule({ bytecode });
}

/**
 * Free loaded module.
 */
function handleFreeModule() {
    assertInitialized();

    wasmInstance.exports.freeModule();
    gpu.reset();

    return { success: true };
}

/**
 * Execute all frames in the module.
 */
function handleExecuteAll() {
    assertInitialized();

    const result = wasmInstance.exports.executeAll();

    if (result !== ErrorCode.SUCCESS) {
        throw new Error(`Execution failed: ${getErrorMessage(result)}`);
    }

    return { success: true };
}

/**
 * Execute a specific frame by name.
 * @param {Object} payload
 * @param {string} payload.frameName - Frame name
 */
function handleExecuteFrame(payload) {
    assertInitialized();

    const { frameName } = payload;
    const exports = wasmInstance.exports;
    const encoder = new TextEncoder();
    const nameBytes = encoder.encode(frameName);

    // Allocate memory for name
    const namePtr = exports.alloc(nameBytes.length);
    if (!namePtr) {
        throw new Error('Failed to allocate memory for frame name');
    }

    // Copy name to WASM memory
    const memory = new Uint8Array(exports.memory.buffer);
    memory.set(nameBytes, namePtr);

    // Execute
    const result = exports.executeFrameByName(namePtr, nameBytes.length);

    // Free name memory
    exports.free(namePtr, nameBytes.length);

    if (result !== ErrorCode.SUCCESS) {
        throw new Error(`Frame execution failed: ${getErrorMessage(result)}`);
    }

    return { success: true };
}

/**
 * Render a frame at the given time.
 * Used by animation loop on main thread.
 * @param {Object} payload
 * @param {number} payload.time - Time in seconds
 * @param {number} [payload.deltaTime] - Delta time since last frame
 * @param {number} [payload.uniformBufferId] - Buffer ID for time uniform
 * @param {number} [payload.uniformBufferSize] - Size of uniform buffer
 */
function handleRenderFrame(payload) {
    assertInitialized();

    const { time, deltaTime = 0, uniformBufferId, uniformBufferSize = 12 } = payload;

    // Set time for WASM calls
    gpu.setTime(time, deltaTime);

    // If uniform buffer specified, write time uniform
    if (uniformBufferId !== undefined && uniformBufferSize > 0) {
        const width = canvas.width;
        const height = canvas.height;

        // Create data based on buffer size (4 bytes per float)
        const numFloats = Math.floor(uniformBufferSize / 4);
        const floatView = new Float32Array(numFloats);

        if (numFloats >= 1) floatView[0] = time;
        if (numFloats >= 2) floatView[1] = width;
        if (numFloats >= 3) floatView[2] = height;
        if (numFloats >= 4) floatView[3] = width / height;

        gpu.writeTimeToBuffer(uniformBufferId, new Uint8Array(floatView.buffer));
    }

    // Execute all (renders the frame)
    const result = wasmInstance.exports.executeAll();

    if (result !== ErrorCode.SUCCESS) {
        throw new Error(`Render failed: ${getErrorMessage(result)}`);
    }

    return { success: true };
}

/**
 * Get frame count from loaded module.
 */
function handleGetFrameCount() {
    assertInitialized();

    const count = wasmInstance.exports.getFrameCount
        ? wasmInstance.exports.getFrameCount()
        : 0;

    return { frameCount: count };
}

/**
 * Get metadata from loaded module.
 */
function handleGetMetadata() {
    assertInitialized();

    // Get basic info
    const frameCount = wasmInstance.exports.getFrameCount
        ? wasmInstance.exports.getFrameCount()
        : 0;

    return {
        frameCount,
        canvasWidth: canvas.width,
        canvasHeight: canvas.height,
    };
}

/**
 * Find the first uniform buffer.
 */
function handleFindUniformBuffer() {
    assertInitialized();

    const bufferInfo = gpu.findUniformBuffer();

    return { bufferInfo };
}

// ============================================================================
// Helpers
// ============================================================================

/**
 * Assert that the worker is initialized.
 * @throws {Error} If not initialized
 */
function assertInitialized() {
    if (!initialized) {
        const error = new Error('Worker not initialized');
        error.code = ErrorCode.NOT_INITIALIZED;
        throw error;
    }
}
