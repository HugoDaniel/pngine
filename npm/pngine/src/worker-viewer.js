// Viewer worker thread - owns WebGPU, WASM, and resources.
// Embedded-executor payloads only (no shared wasmUrl fallback).

import { createCommandDispatcher, parseUniformTable } from "./gpu.js";
import { parsePayload, getExecutorImports } from "./loader.js";

let canvas, device, context, gpu, wasm, memory;
let initialized = false;
let moduleLoaded = false;
let frameCount = 0;
let debugMode = false;
// Cached uniform map from bytecode parsing
let uniformMap = null;

// Message types
const MSG = {
  INIT: "init",
  DRAW: "draw",
  LOAD: "load",
  DESTROY: "destroy",
  SET_UNIFORM: "setUniform",
  GET_UNIFORMS: "getUniforms",
  READY: "ready",
  ERROR: "error",
  UNIFORMS: "uniforms",
};

onmessage = async (e) => {
  const { type, ...data } = e.data;

  try {
    switch (type) {
      case MSG.INIT:
        await handleInit(data);
        break;

      case MSG.DRAW:
        handleDraw(data);
        break;

      case MSG.LOAD:
        await handleLoad(data);
        break;

      case MSG.DESTROY:
        handleDestroy();
        break;

      case MSG.SET_UNIFORM:
        handleSetUniform(data);
        break;

      case MSG.GET_UNIFORMS:
        handleGetUniforms();
        break;

      default:
        throw new Error(`Unknown message: ${type}`);
    }
  } catch (err) {
    postMessage({ type: MSG.ERROR, message: err.message });
  }
};

async function handleInit(data) {
  if (initialized) throw new Error("Already initialized");

  canvas = data.canvas;
  debugMode = data.debug;

  // Initialize WebGPU
  const adapter = await navigator.gpu?.requestAdapter();
  if (!adapter) throw new Error("WebGPU not supported");

  device = await adapter.requestDevice();

  // Add error handling to catch WebGPU validation errors
  device.onuncapturederror = (event) => {
    console.error("[Worker] WebGPU uncaptured error:", event.error.message);
  };

  context = canvas.getContext("webgpu");
  const format = navigator.gpu.getPreferredCanvasFormat();
  context.configure({ device, format, alphaMode: "premultiplied" });

  // Create command dispatcher (closure-based API for minification)
  gpu = createCommandDispatcher(device, context);
  gpu.setDebug(debugMode);
  gpu.setCanvasSize(canvas.width, canvas.height);

  if (!data.bytecode) {
    throw new Error("No payload data provided");
  }

  let payloadInfo;
  try {
    payloadInfo = parsePayload(new Uint8Array(data.bytecode));
  } catch (err) {
    throw new Error(`Invalid payload for viewer: ${err.message}`);
  }

  if (!payloadInfo.hasEmbeddedExecutor || !payloadInfo.executor) {
    throw new Error("No embedded executor in payload. Use an embedded-executor PNG payload, or use pngine/dev with wasmUrl fallback.");
  }

  // Use embedded executor from PNG payload
  if (data.debug) console.log("[Worker] Using embedded executor from payload");

  const imports = getExecutorImports({
    log: (ptr, len) => {
      if (data.debug) {
        const str = new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len));
        console.log("[Executor]", str);
      }
    },
  });

  const { instance } = await WebAssembly.instantiate(payloadInfo.executor, imports);
  wasm = instance.exports;
  memory = wasm.memory;
  gpu.setMemory(memory);
  initialized = true;

  // Load full payload into executor
  await loadBytecode(payloadInfo.payload);

  // Report ready
  postMessage({
    type: MSG.READY,
    width: canvas.width,
    height: canvas.height,
    frameCount,
  });
}

async function handleLoad(data) {
  if (!initialized) throw new Error("Not initialized");
  await loadBytecode(data.bytecode);
  postMessage({ type: MSG.READY, frameCount });
}

/**
 * Load bytecode using the wasm_entry.zig interface.
 *
 * Interface:
 * - getBytecodePtr() / setBytecodeLen() for bytecode input
 * - init() to parse bytecode and emit resource creation commands
 * - frame(time, width, height) for rendering
 * - getCommandPtr() / getCommandLen() for command buffer output
 *
 * @param {ArrayBuffer|Uint8Array} bytecode - Raw bytecode
 */
async function loadBytecode(bytecode) {
  // Reset GPU state if reloading
  if (moduleLoaded) {
    gpu.destroy();
    gpu = createCommandDispatcher(device, context);
    gpu.setDebug(debugMode);
    gpu.setMemory(memory);
    gpu.setCanvasSize(canvas.width, canvas.height);
    moduleLoaded = false;
    uniformMap = null;
  }

  // Copy bytecode to WASM memory
  const bytecodePtr = wasm.getBytecodePtr();
  const bytecodeArray = bytecode instanceof Uint8Array ? bytecode : new Uint8Array(bytecode);
  new Uint8Array(memory.buffer, bytecodePtr, bytecodeArray.length).set(bytecodeArray);
  wasm.setBytecodeLen(bytecodeArray.length);

  // Parse uniform table from bytecode before init (for runtime reflection)
  const { uniforms } = parseUniformTable(bytecodeArray);
  uniformMap = uniforms;
  if (debugMode && uniforms.size > 0) {
    console.log(`[Worker] Parsed ${uniforms.size} uniform fields:`, [...uniforms.keys()]);
  }

  // Initialize: parse bytecode and emit resource creation commands
  const initResult = wasm.init();
  if (initResult !== 0) {
    throw new Error(`Init failed: ${initResult}`);
  }

  // Execute the init command buffer (creates GPU resources)
  const initPtr = wasm.getCommandPtr();
  const initLen = wasm.getCommandLen();
  if (initPtr && initLen > 0) {
    await gpu.execute(initPtr);
  }

  // Set uniform table after resources are created (buffers exist now)
  gpu.setUniformTable(uniformMap);

  moduleLoaded = true;
  frameCount = 1;

  // First frame render
  render(0, canvas.width, canvas.height);
}

/**
 * Render a frame using wasm_entry.zig interface.
 */
function render(time, width, height) {
  gpu.setTime(time);

  const result = wasm.frame(time, width, height);
  if (result !== 0) {
    console.warn("[Worker] frame() returned non-zero:", result);
    return;
  }

  const ptr = wasm.getCommandPtr();
  const len = wasm.getCommandLen();
  if (!ptr || len === 0) return;

  gpu.execute(ptr);
}

function handleDraw(data) {
  if (!initialized || !moduleLoaded) return;

  // Apply uniforms before rendering (if provided)
  if (data.uniforms && typeof data.uniforms === "object") {
    const count = gpu.setUniforms(data.uniforms);
    if (debugMode && count > 0) {
      console.log(`[Worker] Set ${count} uniforms`);
    }
  }

  render(data.time ?? 0, canvas.width, canvas.height);
}

function handleDestroy() {
  moduleLoaded = false;
  uniformMap = null;
  gpu?.destroy();
  if (device) {
    device.destroy();
    device = null;
  }
  initialized = false;
}

/**
 * Handle setUniform message - set uniform value without triggering draw.
 */
function handleSetUniform(data) {
  if (!initialized || !moduleLoaded) return;

  if (data.uniforms && typeof data.uniforms === "object") {
    gpu.setUniforms(data.uniforms);
  } else if (data.name !== undefined && data.value !== undefined) {
    gpu.setUniform(data.name, data.value);
  }
}

/**
 * Handle getUniforms message - return available uniform names and types.
 */
function handleGetUniforms() {
  if (!uniformMap) {
    postMessage({ type: MSG.UNIFORMS, uniforms: {} });
    return;
  }

  // Convert Map to plain object for postMessage
  const uniforms = {};
  for (const [name, info] of uniformMap) {
    uniforms[name] = {
      type: info.type,
      size: info.size,
      bufferId: info.bufferId,
      offset: info.offset,
    };
  }
  postMessage({ type: MSG.UNIFORMS, uniforms });
}
