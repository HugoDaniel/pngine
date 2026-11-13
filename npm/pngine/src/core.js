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
         * Set a uniform value by name. A name the table does not carry, or
         * one whose buffer the init stream never created, is REFUSED through
         * the callback installed with setOnError (source "set-uniform") and
         * returns false — never silently dropped.
         * @param {string} name
         * @param {number|number[]|number[][]} value
         * @returns {boolean}
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
         * Install the executor's control table: the Float32Array a host
         * builds over `getControlPtr()` (65 slots — `time` at 0, controls at
         * 1..64), or null when the executor predates the export. No copy:
         * setUniform writes a control where the executor reads it, in place.
         * @param {Float32Array|null} view
         */
        setControlTable(view) {
            dispatcher.setControlTable(view);
        },

        /**
         * Install the payload's buffer names, so writeBuffers/getBuffers can
         * address a buffer by the `(buffer :name …)` the author wrote. The
         * map comes from parseUniformTable(bytecode).buffers; call this after
         * the init stream has executed, beside setUniformTable.
         * @param {Map<string, import("./gpu-host-write.js").BufferName>|Record<string, import("./gpu-host-write.js").BufferName>} names
         */
        setBufferNames(names) {
            dispatcher.setBufferNames(names);
        },

        /**
         * Put host bytes in buffers, by name: `{ particles: bytes }` or
         * `{ particles: { bytes, offset, poolIndex } }`.
         *
         * A name the runtime cannot honour (unknown, written by the frame
         * itself, a bad pool member, no copy-dst usage, misaligned, out of
         * range) is REFUSED through the callback installed with setOnError,
         * with source "write-buffer" — never silently dropped. Returns how
         * many queue writes were made. A pooled name with no poolIndex writes
         * every member; `"active"` needs the coming frame's counter
         * (`wasm.getFrameCounter()`, read before `frame()`).
         * @param {import("./gpu-host-write.js").HostWrites} buffers
         * @param {number} [frameCounter]
         * @returns {number}
         */
        writeBuffers(buffers, frameCounter) {
            return dispatcher.writeBuffers(buffers, frameCounter);
        },

        /**
         * Every named buffer: `{ size, usage, writable, pool, frameWritten }`.
         * `writable` is the copy-dst bit, which is what queue.writeBuffer
         * requires; `frameWritten` means writeBuffers will refuse it.
         * @returns {Record<string, {size: number, usage: number, writable: boolean, pool: number, frameWritten: boolean}>}
         */
        getBuffers() {
            return dispatcher.getBuffers();
        },

        /**
         * Hear command-stream faults: an unknown opcode, an empty descriptor,
         * a resource that failed validation, a refused host write. Called
         * with `{ message, source }`. Without this a core-tier host had no
         * way to install the listener the dispatcher already reports to, so
         * every one of those was console-only in this tier.
         * @param {((err: {message: string, source: string}) => void)|null} fn
         */
        setOnError(fn) {
            dispatcher.setOnError(fn);
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

        /**
         * Set the frame counter the `pngine-frame-inputs` write reads — the
         * executor's `getFrameCounter()`, the number of frames rendered since
         * `init()`, which also selects the member a `:ping-pong` pool binds.
         * One name for it on every tier: the executor ABI says frameCounter,
         * `writeBuffers` takes a frameCounter, and this is setFrameCounter.
         * (It was `setFrameIndex` for a while, which read as "which
         * `(frame …)`" beside the main API's `setFrame`.)
         *
         * One of the four runtime values the builtin uniform writes read out of
         * the dispatcher (gpu.js: setTime, setFrameCounter, setPointer,
         * setCanvasSize). This tier forwarded two of them, so a core-tier host
         * could drive time and canvas size but not the counter -- a payload
         * writing `pngine-frame-inputs` saw it frozen at 0, and nothing
         * said so (§438).
         * @param {number} n
         */
        setFrameCounter(n) {
            dispatcher.setFrameCounter(n);
        },

        /**
         * Set the pointer state a `pointer-inputs` write reads (48 bytes).
         *
         * The same gap as setFrameCounter above: the worker tier tracks the
         * pointer and pushes it every frame, and without this a core-tier host
         * had no way to, so `pointer-inputs` stayed all zeroes.
         * @param {ArrayLike<number>} s
         */
        setPointer(s) {
            dispatcher.setPointer(s);
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
