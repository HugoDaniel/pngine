/**
 * PNGine Core Runtime
 *
 * Minimal runtime for low-level integration.
 * No Worker, no PNG extraction, no animation - just the GPU dispatcher.
 */

import { canvasAlphaMode, createCommandDispatcher, parseUniformTable, requiredFeaturesFor } from './gpu.js';

// Re-export core dispatcher (+ canvasAlphaMode, which configureCanvas's doc
// tells the caller to use — the core bundle must be able to follow its own
// advice).
export { canvasAlphaMode, createCommandDispatcher, parseUniformTable };

/**
 * Create a core PNGine dispatcher.
 *
 * This is for use when bytecode is already extracted.
 *
 * @param {GPUDevice} device - WebGPU device
 * @param {GPUCanvasContext} ctx - Canvas context (already configured)
 * @returns {Object} Minimal PNGine interface
 */
export function createCoreDispatcher(device, ctx) {
    const dispatcher = createCommandDispatcher(device, ctx);

    return {
        /**
         * Set WASM memory for string/data access.
         * @param {WebAssembly.Memory} memory
         */
        setMemory(memory) {
            dispatcher.setMemory(memory);
        },

        /**
         * Execute a command buffer at the given pointer. Returns the
         * dispatcher's promise, so a host can sequence an init stream that
         * carries an async create (image bitmap, wasm module) before its first
         * frame, and a rejection reaches the caller instead of becoming an
         * unhandled rejection.
         * @param {number} ptr - Command buffer pointer in WASM memory
         * @returns {Promise<void>|void}
         */
        execute(ptr) {
            return dispatcher.execute(ptr);
        },

        /**
         * Set a uniform value by name.
         * @param {string} name
         * @param {number|number[]} value
         */
        setUniform(name, value) {
            return dispatcher.setUniform(name, value);
        },

        /**
         * Set multiple uniforms.
         * @param {Object} uniforms
         */
        setUniforms(uniforms) {
            return dispatcher.setUniforms(uniforms);
        },

        /**
         * Set uniform table from parsed bytecode.
         * @param {Map} table
         */
        setUniformTable(table) {
            dispatcher.setUniformTable(table);
        },

        /**
         * Clean up resources.
         */
        destroy() {
            dispatcher.destroy();
        },

        /**
         * Enable/disable debug logging.
         * @param {boolean} v
         */
        setDebug(v) {
            dispatcher.setDebug(v);
        },

        /**
         * Set time for shader uniforms.
         * @param {number} t
         */
        setTime(t) {
            dispatcher.setTime(t);
        },

        /**
         * Set canvas size for shader uniforms.
         * @param {number} w
         * @param {number} h
         */
        setCanvasSize(w, h) {
            dispatcher.setCanvasSize(w, h);
        },

        // Direct access to dispatcher for advanced use
        _dispatcher: dispatcher,
    };
}

/**
 * Helper to get a WebGPU device.
 * @param {GPUAdapter} [adapter] - Optional adapter
 * @returns {Promise<GPUDevice>}
 */
export async function getDevice(adapter) {
    if (!navigator.gpu) {
        throw new Error('WebGPU not supported');
    }
    const a = adapter || await navigator.gpu.requestAdapter();
    if (!a) {
        throw new Error('No GPU adapter found');
    }
    // Opportunistically request every optional feature the adapter supports, so a
    // feature-gated value (tier1 16-bit formats, bgra8 srgb, depth32float-stencil8,
    // dual-source blend) renders where the hardware allows.
    return a.requestDevice({ requiredFeatures: requiredFeaturesFor(a) });
}

/**
 * Configure a canvas for WebGPU rendering.
 * @param {HTMLCanvasElement} canvas
 * @param {GPUDevice} device
 * @param {"opaque"|"premultiplied"} [alphaMode] - pass canvasAlphaMode(bytecode)
 *   to honor an authored `(canvas :alpha-mode …)`; defaults to the
 *   GPUCanvasConfiguration default, opaque (spec/04, spec/09 D).
 * @returns {GPUCanvasContext}
 */
export function configureCanvas(canvas, device, alphaMode = 'opaque') {
    const ctx = canvas.getContext('webgpu');
    if (!ctx) {
        throw new Error('Failed to get WebGPU context');
    }
    ctx.configure({
        device,
        format: navigator.gpu.getPreferredCanvasFormat(),
        alphaMode,
        usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC,
    });
    return ctx;
}
