/**
 * PNGine Viewer API
 *
 * High-level animation API for playing PNGine demos with scene-based rendering.
 * Matches the pattern used in the inercia2025 demo.
 *
 * @example
 * import { viewer } from './pngine-viewer.js';
 *
 * const anim = await viewer({
 *   animation: pngBlob,   // PNG with embedded bytecode and metadata
 *   canvas: myCanvas,     // Optional: canvas element
 *   wasmUrl: 'pngine.wasm'
 * });
 *
 * // Render a specific scene at a given time
 * await anim.draw(localTime, 'sceneQ');
 *
 * // Get animation metadata
 * console.log(anim.metadata);  // { name, duration, loop, scenes }
 */

import { initPNGine, extractAll, extractBytecode, extractPngm } from './pngine-loader.js';

/**
 * Create a PNGine viewer from a PNG with embedded bytecode and metadata.
 *
 * @param {Object} options - Viewer options
 * @param {Blob|ArrayBuffer|Uint8Array} options.animation - PNG data with embedded bytecode
 * @param {HTMLCanvasElement} [options.canvas] - Canvas element (creates one if not provided)
 * @param {string} [options.wasmUrl='pngine.wasm'] - URL to pngine.wasm
 * @returns {Promise<PNGineViewer>} Viewer instance
 */
export async function viewer(options) {
    const { animation, canvas, wasmUrl = 'pngine.wasm' } = options;

    // Get PNG data as Uint8Array
    let pngData;
    if (animation instanceof Blob) {
        pngData = new Uint8Array(await animation.arrayBuffer());
    } else if (animation instanceof ArrayBuffer) {
        pngData = new Uint8Array(animation);
    } else {
        pngData = animation;
    }

    // Extract bytecode and metadata
    const { bytecode, metadata } = await extractAll(pngData);

    // Create or use provided canvas
    let targetCanvas = canvas;
    if (!targetCanvas) {
        targetCanvas = document.createElement('canvas');
        targetCanvas.width = 1920;
        targetCanvas.height = 1080;
        document.body.appendChild(targetCanvas);
    }

    // Initialize PNGine
    const pngine = await initPNGine(targetCanvas, wasmUrl);

    // Load bytecode
    pngine.loadModule(bytecode);

    // Do initial executeAll to set up resources, then wait for bitmaps
    pngine.executeAll();
    await pngine.waitForBitmaps();

    return new PNGineViewer(pngine, metadata, targetCanvas);
}

/**
 * PNGine Viewer - high-level animation player.
 */
class PNGineViewer {
    /**
     * @param {PNGine} pngine - PNGine instance
     * @param {Object|null} metadata - Animation metadata from pNGm chunk
     * @param {HTMLCanvasElement} canvas - Canvas element
     */
    constructor(pngine, metadata, canvas) {
        this.pngine = pngine;
        this.metadata = metadata?.animation || null;
        this.canvas = canvas;
        this._lastScene = null;
        this._lastTime = -1;

        // Pre-compute scene timings from metadata
        this._sceneTimings = this._buildSceneTimings();
    }

    /**
     * Build scene timing lookup from metadata.
     * @returns {Array<{scene: string, frame: string, start: number, end: number}>}
     */
    _buildSceneTimings() {
        if (!this.metadata?.scenes) return [];
        return this.metadata.scenes.map(s => ({
            scene: s.id,
            frame: s.frame,
            start: s.start,
            end: s.end,
        }));
    }

    /**
     * Get current scene and local time for a global time.
     *
     * @param {number} globalTime - Time in seconds from animation start
     * @returns {{scene: string, frame: string, localTime: number}|null}
     */
    getSceneAt(globalTime) {
        if (!this._sceneTimings.length) return null;

        const duration = this.metadata?.duration || this._sceneTimings[this._sceneTimings.length - 1].end;
        const clampedTime = Math.min(globalTime, duration - 0.001);

        for (const timing of this._sceneTimings) {
            if (clampedTime >= timing.start && clampedTime < timing.end) {
                return {
                    scene: timing.scene,
                    frame: timing.frame,
                    localTime: clampedTime - timing.start,
                };
            }
        }

        // Fallback to last scene
        const last = this._sceneTimings[this._sceneTimings.length - 1];
        return {
            scene: last.scene,
            frame: last.frame,
            localTime: clampedTime - last.start,
        };
    }

    /**
     * Render a specific scene at a given local time.
     *
     * @param {number} localTime - Time within the scene (seconds)
     * @param {string} sceneName - Frame name to render (e.g., 'sceneQ')
     */
    async draw(localTime, sceneName) {
        // Update time uniforms
        this.pngine.gpu.setTime(localTime);

        // Find and write to uniform buffer
        const uniformInfo = this.pngine.findUniformBuffer();
        if (uniformInfo !== null) {
            this.pngine.writeTimeUniform(uniformInfo.id, localTime, uniformInfo.size);
        }

        // Execute the specific frame
        try {
            this.pngine.executeFrameByName(sceneName);
        } catch (e) {
            console.warn(`[Viewer] Failed to execute frame '${sceneName}':`, e.message);
            // Fallback to executeAll if frame not found
            this.pngine.executeAll();
        }

        this._lastScene = sceneName;
        this._lastTime = localTime;
    }

    /**
     * Render at a global time, automatically selecting the correct scene.
     *
     * @param {number} globalTime - Time from animation start (seconds)
     */
    async drawAtTime(globalTime) {
        const sceneInfo = this.getSceneAt(globalTime);
        if (sceneInfo) {
            await this.draw(sceneInfo.localTime, sceneInfo.frame);
        }
    }

    /**
     * Get total animation duration in seconds.
     * @returns {number}
     */
    get duration() {
        return this.metadata?.duration || 0;
    }

    /**
     * Check if animation should loop.
     * @returns {boolean}
     */
    get loop() {
        return this.metadata?.loop || false;
    }

    /**
     * Get end behavior ('hold', 'stop', or 'restart').
     * @returns {string}
     */
    get endBehavior() {
        return this.metadata?.endBehavior || 'hold';
    }

    /**
     * Get list of scene IDs.
     * @returns {string[]}
     */
    get scenes() {
        return this._sceneTimings.map(t => t.scene);
    }

    /**
     * Get frame count in loaded module.
     * @returns {number}
     */
    get frameCount() {
        return this.pngine.getFrameCount();
    }

    /**
     * Clean up resources.
     */
    destroy() {
        this.pngine.freeModule();
    }
}

export { PNGineViewer };
