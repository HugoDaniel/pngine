// Shim: set DEBUG before importing the real worker
// (Vite define doesn't propagate to @fs worker imports)
globalThis.DEBUG = true;
export * from "../../npm/pngine/src/worker-viewer.js";

// Re-run the onmessage setup from worker-viewer.js
// Since worker-viewer.js sets `onmessage` at module scope, the export
// above already executed it. Nothing else needed.
