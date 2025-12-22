// Main thread initialization
// Spawns worker, creates POJO

import { extractBytecode } from "./_extract.js";

// Worker URL (will be replaced with blob URL by bundler)
let workerUrl = null;

/**
 * Initialize PNGine from various sources
 * @param {string|ArrayBuffer|Blob|Uint8Array|HTMLImageElement} source
 * @param {Object} [options]
 * @param {HTMLCanvasElement} [options.canvas]
 * @param {boolean} [options.debug]
 * @param {string} [options.wasmUrl]
 * @param {(err: Error) => void} [options.onError]
 * @returns {Promise<Pngine>}
 */
export async function pngine(source, options = {}) {
  const log = options.debug ? console.log.bind(console, "[PNGine]") : () => {};

  // Resolve source to canvas + bytecode
  let canvas, bytecode;

  if (typeof source === "string") {
    // Check for CSS selector (# or . but not ../ which is a relative path)
    const isSelector = source.startsWith("#") || (source.startsWith(".") && !source.startsWith(".."));
    if (isSelector) {
      // Query selector
      const el = document.querySelector(source);
      if (!el) throw new Error(`Element not found: ${source}`);

      if (el instanceof HTMLImageElement) {
        ({ canvas, bytecode } = await initFromImage(el, options, log));
      } else if (el instanceof HTMLCanvasElement) {
        canvas = el;
        throw new Error("Canvas source requires URL or data");
      } else {
        throw new Error(`Invalid element type`);
      }
    } else {
      // URL
      canvas = options.canvas;
      if (!canvas) throw new Error("Canvas required for URL source");
      log(`Fetching: ${source}`);
      const resp = await fetch(source);
      if (!resp.ok) throw new Error(`Fetch failed: ${resp.status}`);
      bytecode = await extractBytecode(await resp.arrayBuffer());
    }
  } else if (source instanceof HTMLImageElement) {
    ({ canvas, bytecode } = await initFromImage(source, options, log));
  } else if (
    source instanceof ArrayBuffer ||
    source instanceof Uint8Array ||
    source instanceof Blob
  ) {
    canvas = options.canvas;
    if (!canvas) throw new Error("Canvas required for data source");
    const data = source instanceof Blob ? await source.arrayBuffer() : source;
    bytecode = await extractBytecode(data);
  } else {
    throw new Error("Invalid source type");
  }

  log(`Canvas: ${canvas.width}x${canvas.height}`);
  log(`Bytecode: ${bytecode.byteLength} bytes`);

  // Get OffscreenCanvas
  const offscreen = canvas.transferControlToOffscreen();

  // Spawn worker
  const worker = new Worker(getWorkerUrl(), { type: "module" });

  // Wait for ready
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

    // Compute WASM URL - must be absolute for worker blob context
    const wasmUrl = options.wasmUrl
      ? new URL(options.wasmUrl, window.location.href).href
      : new URL("pngine.wasm", import.meta.url).href;

    // Send init
    worker.postMessage(
      {
        type: "init",
        canvas: offscreen,
        bytecode,
        wasmUrl,
        debug: options.debug || false,
      },
      [offscreen, bytecode.buffer]
    );
  });

  // Set up error handler
  worker.onmessage = (e) => {
    if (e.data.type === "error" && options.onError) {
      options.onError(new Error(e.data.message));
    }
  };

  log(`Ready: ${result.frameCount} frames`);

  // Create POJO
  return createPngine({
    canvas,
    worker,
    width: result.width,
    height: result.height,
    frameCount: result.frameCount,
    ready: true,
    playing: false,
    time: 0,
    startTime: 0,
    animationId: null,
    debug: options.debug || false,
    log,
  });
}

/**
 * Initialize from image element
 */
async function initFromImage(img, options, log) {
  // Wait for image to load if needed
  if (!img.complete) {
    await new Promise((resolve, reject) => {
      img.onload = resolve;
      img.onerror = reject;
    });
  }

  const { naturalWidth: w, naturalHeight: h } = img;
  if (w === 0 || h === 0) throw new Error("Image has no dimensions");

  log(`Image: ${w}x${h} from ${img.src}`);

  // Create canvas
  const canvas = options.canvas || document.createElement("canvas");
  canvas.width = w;
  canvas.height = h;

  // Position canvas over image if not provided
  if (!options.canvas) {
    const parent = img.parentElement;
    if (parent && getComputedStyle(parent).position === "static") {
      parent.style.position = "relative";
    }

    Object.assign(canvas.style, {
      position: "absolute",
      top: img.offsetTop + "px",
      left: img.offsetLeft + "px",
      width: img.offsetWidth + "px",
      height: img.offsetHeight + "px",
      pointerEvents: "none",
    });

    if (parent) parent.appendChild(canvas);
  }

  // Fetch bytecode from image src
  const resp = await fetch(img.src);
  if (!resp.ok) throw new Error(`Failed to fetch image: ${resp.status}`);
  const bytecode = await extractBytecode(await resp.arrayBuffer());

  return { canvas, bytecode };
}

/**
 * Create Pngine POJO with getters
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

    // Internal state (for other functions)
    _: internal,
  };
}

/**
 * Destroy pngine instance
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
  i.log("Destroyed");
  return p;
}

/**
 * Get worker URL (inline or separate file)
 */
function getWorkerUrl() {
  if (workerUrl) return workerUrl;

  // For development: use separate file
  // For production: bundler replaces this with blob URL
  return new URL("./_worker.js", import.meta.url);
}

/**
 * Set worker URL (called by bundler)
 */
export function setWorkerUrl(url) {
  workerUrl = url;
}
