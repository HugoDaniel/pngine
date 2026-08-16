// Worker error message → Error mapping, shared by init.js and viewer-init.js
// so the dev and viewer profiles route errors to options.onError identically.
//
// Worker error message types:
//   "error"        — fatal worker exception (init/load/draw)
//   "shader-error" — WGSL compilation error from getCompilationInfo()
//   "gpu-error"    — WebGPU uncaptured error (validation/out-of-memory)
//   "device-lost"  — the GPUDevice was lost (driver reset, TDR, eviction)

/**
 * @typedef {object} WorkerErrorMessage
 * @property {string} type
 * @property {string} [message]
 * @property {number} [lineNum]   WGSL line, shader-error only
 * @property {number} [linePos]   WGSL column, shader-error only
 * @property {string} [context]   offending source line, shader-error only
 * @property {string} [source]    "validation" | "out-of-memory" | "device-lost"
 */

/**
 * An Error carrying the extra fields the host contract promises: a
 * PngineShaderError has lineNum/linePos/context, a PngineGPUError has source.
 * They are part of the documented onError surface (see viewer-init.js), not
 * incidental — hence a named type rather than loose property writes.
 *
 * @typedef {Error & {lineNum?: number, linePos?: number, context?: string, source?: string}} PngineError
 */

/**
 * Convert a worker message into an Error for the onError callback.
 * Returns null for non-error messages.
 *
 * @param {WorkerErrorMessage} data - Worker message data
 * @returns {PngineError|null}
 */
export function workerErrorFromMessage(data) {
  if (!data) return null;
  if (data.type === "error") {
    return new Error(data.message);
  }
  if (data.type === "shader-error") {
    const err = /** @type {PngineError} */ (new Error(
      `Shader compilation error at line ${data.lineNum}:${data.linePos}: ${data.message}`,
    ));
    err.name = "PngineShaderError";
    err.lineNum = data.lineNum;
    err.linePos = data.linePos;
    err.context = data.context;
    return err;
  }
  if (data.type === "gpu-error") {
    const err = /** @type {PngineError} */ (new Error(data.message));
    err.name = "PngineGPUError";
    err.source = data.source;
    return err;
  }
  // A device loss is a runtime GPU fault the host must be told about: the viewer
  // self-recovers (informational), but the dev profile stays passive until the
  // host calls restart(), so it must not stay console-only. Same shape as the
  // mini tier's device-lost surface (source "device-lost").
  if (data.type === "device-lost") {
    const err = /** @type {PngineError} */ (new Error(data.message || "GPU device lost"));
    err.name = "PngineGPUError";
    err.source = "device-lost";
    return err;
  }
  return null;
}
