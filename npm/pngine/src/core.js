/**
 * PNGine Core Runtime
 *
 * Minimal runtime for low-level integration.
 * No Worker, no PNG extraction, no animation - just the GPU dispatcher.
 */

import { createCommandDispatcher, parseUniformTable } from './gpu.js';

// Re-export core dispatcher
export { createCommandDispatcher, parseUniformTable };

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
         * Execute a command buffer at the given pointer.
         * @param {number} ptr - Command buffer pointer in WASM memory
         */
        execute(ptr) {
            dispatcher.execute(ptr);
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
    return a.requestDevice();
}

/**
 * Configure a canvas for WebGPU rendering.
 * @param {HTMLCanvasElement} canvas
 * @param {GPUDevice} device
 * @returns {GPUCanvasContext}
 */
export function configureCanvas(canvas, device) {
    const ctx = canvas.getContext('webgpu');
    if (!ctx) {
        throw new Error('Failed to get WebGPU context');
    }
    ctx.configure({
        device,
        format: navigator.gpu.getPreferredCanvasFormat(),
        alphaMode: 'premultiplied',
    });
    return ctx;
}
