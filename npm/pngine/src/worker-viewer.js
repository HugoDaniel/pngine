// Viewer worker thread — owns WebGPU, WASM, and resources.
// Embedded-executor payloads only (no shared wasmUrl fallback); self-recovers on
// device loss. Thin entry: build the browser env, enable the viewer capabilities,
// and route messages through the shared worker-core spine.

import { browserEnv, createWorkerHandlers } from "./worker-core.js";

const { dispatch } = createWorkerHandlers(browserEnv(), {
  allowWasmUrl: false,
  selfRecover: true,
});

onmessage = (e) => dispatch(e.data);
