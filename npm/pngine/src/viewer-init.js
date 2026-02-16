// Viewer initialization (lean production path)
// Spawns worker with embedded-executor payloads only.

import { extractBytecode } from "./extract.js";

const PNGB_HEADER_SIZE = 40;
const PNGB_VERSION_V0 = 0;
const PNGB_FLAG_HAS_EMBEDDED_EXECUTOR = 0x01;
const NO_EMBEDDED_EXECUTOR_ERROR =
  "No embedded executor in payload. Use an embedded-executor PNG payload, or use pngine/dev with wasmUrl fallback.";

// Worker URL (replaced with blob URL by bundler for browser builds)
let workerUrl = null;

/**
 * Initialize PNGine viewer from URL or byte buffer.
 *
 * @param {string|ArrayBuffer|Uint8Array|Blob} source
 * @param {Object} options
 * @param {HTMLCanvasElement} options.canvas
 * @param {boolean} [options.debug]
 * @param {(err: Error) => void} [options.onError]
 * @returns {Promise<Pngine>}
 */
export async function pngine(source, options = {}) {
  const canvas = options.canvas;
  if (!canvas) {
    throw new Error("viewer pngine() requires options.canvas");
  }

  if (options.wasmUrl) {
    throw new Error("viewer pngine() does not support wasmUrl; use embedded executor payloads");
  }

  let bytecode;

  if (typeof source === "string") {
    // CSS selector shortcuts are intentionally dev-only to keep viewer API strict.
    const isSelector = source.startsWith("#") || (source.startsWith(".") && !source.startsWith("./") && !source.startsWith(".."));
    if (isSelector) {
      throw new Error("viewer pngine() does not support selector sources; use URL/bytes or pngine/dev");
    }

    const resp = await fetch(source);
    if (!resp.ok) throw new Error(`Fetch failed: ${resp.status}`);
    bytecode = await extractBytecode(await resp.arrayBuffer());
  } else if (
    source instanceof ArrayBuffer ||
    source instanceof Uint8Array ||
    source instanceof Blob
  ) {
    const data = source instanceof Blob ? await source.arrayBuffer() : source;
    bytecode = await extractBytecode(data);
  } else if (typeof HTMLImageElement !== "undefined" && source instanceof HTMLImageElement) {
    throw new Error("viewer pngine() does not support HTMLImageElement sources; use pngine/dev");
  } else {
    throw new Error("viewer pngine() source must be URL string or byte buffer");
  }

  // Viewer contract: only embedded-executor payloads are accepted.
  assertEmbeddedExecutorPayload(bytecode);

  const offscreen = canvas.transferControlToOffscreen();
  const worker = new Worker(getWorkerUrl(), { type: "module" });

  const result = await new Promise((resolve, reject) => {
    const timeout = setTimeout(
      () => reject(new Error("Worker init timeout")),
      15000
    );

    worker.onmessage = (e) => {
      if (e.data.type === "ready") {
        clearTimeout(timeout);
        resolve(e.data);
      } else if (e.data.type === "error") {
        clearTimeout(timeout);
        reject(new Error(e.data.message));
      }
    };

    worker.onerror = (e) => {
      clearTimeout(timeout);
      reject(new Error(e.message || "Worker error"));
    };

    worker.postMessage(
      {
        type: "init",
        canvas: offscreen,
        bytecode,
        debug: options.debug || false,
      },
      [offscreen, bytecode.buffer]
    );
  });

  worker.onmessage = (e) => {
    if (e.data.type === "error" && options.onError) {
      options.onError(new Error(e.data.message));
    }
  };

  return createPngine({
    canvas,
    worker,
    width: result.width,
    height: result.height,
    frameCount: result.frameCount,
    animation: result.animation || null,
    currentScene: null,
    currentFrame: null,
    ready: true,
    playing: false,
    time: 0,
    startTime: 0,
    animationId: null,
  });
}

/**
 * Create Pngine POJO with getters.
 */
function createPngine(internal) {
  return {
    get width() {
      return internal.width;
    },
    get height() {
      return internal.height;
    },
    get isPlaying() {
      return internal.playing;
    },
    get time() {
      return internal.time;
    },
    get frameCount() {
      return internal.frameCount;
    },
    get animation() {
      return internal.animation;
    },
    get currentScene() {
      return internal.currentScene;
    },
    get currentFrame() {
      return internal.currentFrame;
    },
    get duration() {
      return internal.animation ? internal.animation.duration / 1000 : 0;
    },

    // Internal state (for other functions)
    _: internal,
  };
}

/**
 * Destroy pngine instance.
 * @param {Pngine} p
 * @returns {Pngine}
 */
export function destroy(p) {
  const i = p._;
  if (!i) return p;

  if (i.animationId) cancelAnimationFrame(i.animationId);
  i.worker.postMessage({ type: "destroy" });
  i.worker.terminate();

  p._ = null;
  return p;
}

/**
 * Get worker URL (inline or separate file).
 */
function getWorkerUrl() {
  if (workerUrl) return workerUrl;
  return new URL("./worker-viewer.js", import.meta.url);
}

/**
 * Set worker URL (used by bundler).
 */
export function setWorkerUrl(url) {
  workerUrl = url;
}

function assertEmbeddedExecutorPayload(bytecode) {
  if (!(bytecode instanceof Uint8Array)) {
    throw new Error("Invalid payload: expected Uint8Array bytecode");
  }

  if (bytecode.length < PNGB_HEADER_SIZE) {
    throw new Error("Invalid PNGB payload: too short");
  }

  if (
    bytecode[0] !== 0x50 ||
    bytecode[1] !== 0x4e ||
    bytecode[2] !== 0x47 ||
    bytecode[3] !== 0x42
  ) {
    throw new Error("Invalid PNGB payload: bad magic");
  }

  const view = new DataView(bytecode.buffer, bytecode.byteOffset, bytecode.byteLength);
  const version = view.getUint16(4, true);
  if (version !== PNGB_VERSION_V0) {
    throw new Error(`Unsupported PNGB version: ${version}`);
  }

  const flags = view.getUint16(6, true);
  const hasEmbeddedExecutor = (flags & PNGB_FLAG_HAS_EMBEDDED_EXECUTOR) !== 0;
  const executorLength = view.getUint32(16, true);
  if (!hasEmbeddedExecutor || executorLength === 0) {
    throw new Error(NO_EMBEDDED_EXECUTOR_ERROR);
  }
}
