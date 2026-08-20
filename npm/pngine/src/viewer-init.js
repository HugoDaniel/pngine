// Viewer initialization (lean production path)
// Spawns worker with embedded-executor payloads only.

import { extractBytecode, extractAudio } from "./extract.js";
import { createAudioPlayer } from "./audio.js";
// routeWorkerMessages is NOT called here — awaitWorkerReady installs it at the
// instant `ready` arrives (see init.js).
import { attachPointerTracking, attachAutoResize, awaitWorkerReady, createPngine, destroy, sizeCanvasForInit } from "./init-core.js";
import { initialPlayback } from "./playback-state.js";

/** @typedef {import("./init-core.js").Pngine} Pngine */

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
 * The viewer is the strict profile: it accepts a URL string or bytes, and
 * REJECTS the conveniences pngine/dev allows (CSS-selector sources,
 * HTMLImageElement, a wasmUrl fallback). Those are named in the types below
 * because rejecting them is part of this function's contract — a caller coming
 * from dev needs the error, not an "argument of type never" from its bundler.
 *
 * @param {string|ArrayBuffer|Uint8Array|Blob|HTMLImageElement} source
 * @param {Object} [options]
 * @param {HTMLCanvasElement} [options.canvas] - Required; validated at runtime
 *   so an untyped caller gets a named error rather than a property access on
 *   undefined.
 * @param {string} [options.wasmUrl] - Rejected: viewer payloads embed their
 *   executor. Use pngine/dev for the fetch fallback.
 * @param {boolean} [options.debug]
 * @param {number} [options.dpr]
 * @param {boolean} [options.autoResize] - Leave the canvas CSS size to the page
 *   and keep the backing store synced to its rendered size (responsive). Off by
 *   default (fixed size); a DPR change re-sharpens the backing store either way.
 * @param {(err: Error) => void} [options.onError] - Receives worker errors,
 *   WGSL compilation errors (name "PngineShaderError", with lineNum/linePos/context),
 *   and WebGPU uncaptured errors (name "PngineGPUError")
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

  let bytecode, rawData;

  if (typeof source === "string") {
    // CSS selector shortcuts are intentionally dev-only to keep viewer API strict.
    const isSelector = source.startsWith("#") || (source.startsWith(".") && !source.startsWith("./") && !source.startsWith(".."));
    if (isSelector) {
      throw new Error("viewer pngine() does not support selector sources; use URL/bytes or pngine/dev");
    }

    const resp = await fetch(source);
    if (!resp.ok) throw new Error(`Fetch failed: ${resp.status}`);
    rawData = await resp.arrayBuffer();
    bytecode = await extractBytecode(rawData);
  } else if (
    source instanceof ArrayBuffer ||
    source instanceof Uint8Array ||
    source instanceof Blob
  ) {
    rawData = source instanceof Blob ? await source.arrayBuffer() : source;
    bytecode = await extractBytecode(rawData);
  } else if (typeof HTMLImageElement !== "undefined" && source instanceof HTMLImageElement) {
    throw new Error("viewer pngine() does not support HTMLImageElement sources; use pngine/dev");
  } else {
    throw new Error("viewer pngine() source must be URL string or byte buffer");
  }

  // Viewer contract: only embedded-executor payloads are accepted.
  assertEmbeddedExecutorPayload(bytecode);

  // Size the HiDPI backing store (fixed by default; responsive with autoResize).
  const { logicalW, logicalH, deviceW, deviceH } = sizeCanvasForInit(canvas, options);

  // Pointer/keyboard tracking — must attach before transferControlToOffscreen.
  const { pointer: ptr, detach: detachListeners } = attachPointerTracking(canvas);

  // Until the handle exists the listeners are ours to release — a worker that
  // fails to come up rejects from this block (see init.js for the full note).
  let worker, result;
  try {
    const offscreen = canvas.transferControlToOffscreen();
    worker = new Worker(getWorkerUrl(), { type: "module" });

    // Slice bytecode so the original buffer stays alive for extractAudio below.
    const bc = bytecode.slice();
    result = await awaitWorkerReady(
      worker,
      {
        type: "init",
        canvas: offscreen,
        bytecode: bc,
        debug: options.debug || false,
      },
      [offscreen, bc.buffer],
      options
    );
  } catch (err) {
    detachListeners();
    throw err;
  }

  // Built BEFORE the audio phase — see init.js for why: by this point the
  // device, the transferred canvas and seven listeners are all committed, and
  // this handle is the only thing that can release them.
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

  // Extract and initialize audio from PNG (pNGa chunk) on main thread.
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

// createPngine + destroy are shared with the dev profile (init-core.js).
export { destroy };

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
