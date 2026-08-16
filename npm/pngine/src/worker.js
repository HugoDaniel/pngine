// Dev worker thread — owns WebGPU, WASM, and resources.
// Supports both embedded executor payloads and the shared wasmUrl fallback,
// plus the editor's timeline prefetch. Thin entry: build the browser env, enable
// the dev capabilities, and route messages through the shared worker-core spine.

import { browserEnv, createWorkerHandlers } from "./worker-core.js";
import { createPrefetch } from "./worker-prefetch.js";

const { dispatch } = createWorkerHandlers(browserEnv(), {
  allowWasmUrl: true,
  selfRecover: false,
  makePrefetch: createPrefetch,
});

onmessage = (e) => dispatch(e.data);
