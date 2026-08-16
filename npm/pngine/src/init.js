// Main thread initialization
// Spawns worker, creates POJO

import { extractBytecode, extractAudio } from "./extract.js";
import { createAudioPlayer } from "./audio.js";
// routeWorkerMessages is NOT called here: awaitWorkerReady installs it at the
// instant `ready` arrives, so no window exists in which neither owns the
// worker's messages (the audio phase below used to be exactly that window).
import { attachPointerTracking, attachAutoResize, awaitWorkerReady, createPngine, destroy, sizeCanvasForInit } from "./init-core.js";
import { initialPlayback } from "./playback-state.js";

/** @typedef {import("./init-core.js").Pngine} Pngine */

// Worker URL (will be replaced with blob URL by bundler)
let workerUrl = null;

/**
 * Initialize PNGine from various sources
 * @param {string|ArrayBuffer|Blob|Uint8Array|HTMLImageElement} source
 * @param {Object} [options]
 * @param {HTMLCanvasElement} [options.canvas]
 * @param {boolean} [options.debug]
 * @param {number} [options.dpr]
 * @param {boolean} [options.autoResize] - Leave the canvas CSS size to the page
 *   and keep the backing store synced to its rendered size (responsive). Off by
 *   default (fixed size); a DPR change re-sharpens the backing store either way.
 * @param {string} [options.wasmUrl]
 * @param {(err: Error) => void} [options.onError] - Receives worker errors,
 *   WGSL compilation errors (name "PngineShaderError", with lineNum/linePos/context),
 *   and WebGPU uncaptured errors (name "PngineGPUError")
 * @returns {Promise<Pngine>}
 */
export async function pngine(source, options = {}) {
  // Resolve source to canvas + bytecode + raw PNG data
  let canvas, bytecode, rawData;

  if (typeof source === "string") {
    // Check for CSS selector (# or . but not relative paths like ./ or ../)
    const isSelector = source.startsWith("#") || (source.startsWith(".") && !source.startsWith("./") && !source.startsWith(".."));
    if (isSelector) {
      const el = document.querySelector(source);
      if (!el) throw new Error(`Element not found: ${source}`);

      if (el instanceof HTMLImageElement) {
        ({ canvas, bytecode, rawData } = await initFromImage(el, options));
      } else if (el instanceof HTMLCanvasElement) {
        canvas = el;
        throw new Error("Canvas source requires URL or data");
      } else {
        throw new Error(`Invalid element type`);
      }
    } else {
      canvas = options.canvas;
      if (!canvas) throw new Error("Canvas required for URL source");
      const resp = await fetch(source);
      if (!resp.ok) throw new Error(`Fetch failed: ${resp.status}`);
      rawData = await resp.arrayBuffer();
      bytecode = await extractBytecode(rawData);
    }
  } else if (source instanceof HTMLImageElement) {
    ({ canvas, bytecode, rawData } = await initFromImage(source, options));
  } else if (
    source instanceof ArrayBuffer ||
    source instanceof Uint8Array ||
    source instanceof Blob
  ) {
    canvas = options.canvas;
    if (!canvas) throw new Error("Canvas required for data source");
    rawData = source instanceof Blob ? await source.arrayBuffer() : source;
    bytecode = await extractBytecode(rawData);
  } else {
    throw new Error("Invalid source type");
  }

  // Size the HiDPI backing store (fixed by default; responsive with autoResize).
  const { logicalW, logicalH, deviceW, deviceH } = sizeCanvasForInit(canvas, options);

  // Pointer/keyboard tracking — must attach before transferControlToOffscreen.
  const { pointer: ptr, detach: detachListeners } = attachPointerTracking(canvas);

  // Get OffscreenCanvas
  const offscreen = canvas.transferControlToOffscreen();

  // Spawn worker
  const worker = new Worker(getWorkerUrl(), { type: "module" });

  // Compute WASM URL - must be absolute for worker blob context.
  // ../wasm/ resolves from both src/ (repo dev) and dist/ (published bundle)
  // to the package's wasm/pngine.wasm fallback.
  const wasmUrl = options.wasmUrl
    ? new URL(options.wasmUrl, window.location.href).href
    : new URL("../wasm/pngine.wasm", import.meta.url).href;

  // Wait for ready — slice bytecode so the original buffer stays alive for
  // extractAudio below.
  const bc = bytecode.slice();
  const result = await awaitWorkerReady(
    worker,
    {
      type: "init",
      canvas: offscreen,
      bytecode: bc,
      wasmUrl,
      debug: options.debug || false,
    },
    [offscreen, bc.buffer],
    options
  );

  // The instance exists BEFORE the audio phase, because the audio phase is the
  // first thing that can fail after the worker reports ready — and by then the
  // GPUDevice is live, the canvas has been transferred, the bytecode went with
  // it, and seven listeners are attached through an AbortController that only
  // this handle can reach. A truncated pNGa is enough: createAudioPlayer's
  // first act is WebAssembly.instantiate. Rejecting from here without a handle
  // stranded every one of those for the page's life.
  //
  // (Report logical/CSS dimensions, not physical.)
  const p = createPngine({
    canvas,
    worker,
    pointer: ptr,
    detachListeners,
    width: logicalW,
    height: logicalH,
    frameCount: result.frameCount,
    animation: result.animation || null,
    ready: true,
    pb: initialPlayback(),
    animationId: null,
    audio: null,
  });

  // Extract and initialize audio from PNG (pNGa chunk) on main thread. A
  // failed setup and a host teardown are the same release, so they are the
  // same call — destroy() acks the worker's device release before terminating.
  try {
    if (rawData) {
      const audioWasm = await extractAudio(rawData);
      if (audioWasm) p._.audio = await createAudioPlayer(audioWasm);
    }
  } catch (err) {
    destroy(p);
    throw err;
  }

  // Keep the backing store synced to the canvas's rendered size / DPR.
  p._.disconnectResize = attachAutoResize(canvas, worker, deviceW, deviceH, (w, h) => {
    p._.width = w;
    p._.height = h;
  });

  return p;
}

/**
 * Initialize from image element
 */
async function initFromImage(img, options) {
  // Wait for image to load if needed. Both handlers are CLEARED once settled:
  // each closes over the promise's continuation — i.e. the rest of pngine() —
  // and they are pinned to an element the host owns, so leaving them attached
  // keeps the whole init alive for as long as the page keeps the <img>.
  if (!img.complete) {
    try {
      await new Promise((resolve, reject) => {
        img.onload = resolve;
        img.onerror = reject;
      });
    } finally {
      img.onload = img.onerror = null;
    }
  }

  const { naturalWidth: w, naturalHeight: h } = img;
  if (w === 0 || h === 0) throw new Error("Image has no dimensions");

  // Create canvas — set logical dimensions (DPR scaling happens in pngine())
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
  const rawData = await resp.arrayBuffer();
  const bytecode = await extractBytecode(rawData);

  return { canvas, bytecode, rawData };
}

// createPngine + destroy are shared with the viewer profile (init-core.js).
export { destroy };

/**
 * Get worker URL (inline or separate file)
 */
function getWorkerUrl() {
  if (workerUrl) return workerUrl;

  // For development: use separate file
  // For production: bundler replaces this with blob URL
  return new URL("./worker.js", import.meta.url);
}

/**
 * Set worker URL (called by bundler)
 */
export function setWorkerUrl(url) {
  workerUrl = url;
}
