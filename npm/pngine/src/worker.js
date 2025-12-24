// Worker thread - owns WebGPU, WASM, and resources
// Uses command buffer approach for minimal bundle size
// Supports both shared executor (wasmUrl) and embedded executor (in PNG payload)

import { CommandDispatcher } from "./gpu.js";
import { parsePayload, createExecutor, getExecutorImports } from "./loader.js";

let canvas, device, context, gpu, wasm, memory;
let initialized = false;
let moduleLoaded = false;
let frameCount = 0;
let animationInfo = null;
let useEmbeddedExecutor = false;

// Message types
const MSG = {
  INIT: "init",
  DRAW: "draw",
  LOAD: "load",
  DESTROY: "destroy",
  READY: "ready",
  ERROR: "error",
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

  // Initialize WebGPU
  const adapter = await navigator.gpu?.requestAdapter();
  if (!adapter) throw new Error("WebGPU not supported");

  device = await adapter.requestDevice();
  context = canvas.getContext("webgpu");
  const format = navigator.gpu.getPreferredCanvasFormat();
  context.configure({ device, format, alphaMode: "premultiplied" });

  // Create command dispatcher
  gpu = new CommandDispatcher(device, context);
  gpu.setDebug(data.debug);
  gpu.setCanvasSize(canvas.width, canvas.height);

  // Check if bytecode has embedded executor
  let hasEmbeddedExecutor = false;
  let payloadInfo = null;

  if (data.bytecode) {
    try {
      const bytecodeArray = new Uint8Array(data.bytecode);
      payloadInfo = parsePayload(bytecodeArray);
      hasEmbeddedExecutor = payloadInfo.hasEmbeddedExecutor;
    } catch (e) {
      // Not a PNGB payload, use shared executor
      if (data.debug) console.log("[Worker] Bytecode parse failed, using shared executor:", e.message);
    }
  }

  if (hasEmbeddedExecutor && payloadInfo.executor) {
    // Use embedded executor from PNG payload
    if (data.debug) console.log("[Worker] Using embedded executor from payload");
    useEmbeddedExecutor = true;

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

    // Initialize embedded executor
    if (wasm.init) {
      wasm.init();
    } else if (wasm.onInit) {
      wasm.onInit();
    }

    initialized = true;

    // Load bytecode into embedded executor
    await loadBytecodeEmbedded(payloadInfo);
  } else {
    // Use shared executor from wasmUrl
    if (!data.wasmUrl) throw new Error("wasmUrl required (no embedded executor)");
    useEmbeddedExecutor = false;

    const resp = await fetch(data.wasmUrl);
    if (!resp.ok) throw new Error(`Failed to fetch WASM: ${resp.status}`);

    const { instance } = await WebAssembly.instantiateStreaming(
      resp,
      getWasmImports()
    );
    wasm = instance.exports;
    memory = wasm.memory;
    gpu.setMemory(memory);

    // Initialize WASM
    wasm.onInit();
    initialized = true;

    // If bytecode was provided, load it
    if (data.bytecode) {
      await loadBytecode(data.bytecode);
    }
  }

  // Report ready
  postMessage({
    type: MSG.READY,
    width: canvas.width,
    height: canvas.height,
    frameCount,
    animation: animationInfo,
  });
}

async function handleLoad(data) {
  if (!initialized) throw new Error("Not initialized");

  // Check if new bytecode has embedded executor
  let payloadInfo = null;
  try {
    const bytecodeArray = new Uint8Array(data.bytecode);
    payloadInfo = parsePayload(bytecodeArray);
  } catch (e) {
    // Not a PNGB payload, use regular loading
  }

  if (useEmbeddedExecutor && payloadInfo) {
    await loadBytecodeEmbedded(payloadInfo);
  } else {
    await loadBytecode(data.bytecode);
  }

  postMessage({ type: MSG.READY, frameCount, animation: animationInfo });
}

async function loadBytecode(bytecode) {
  // Free previous module
  if (moduleLoaded) {
    const wasDebug = gpu.debug;
    wasm.freeModule();
    gpu.destroy();
    gpu = new CommandDispatcher(device, context);
    gpu.setDebug(wasDebug);
    gpu.setMemory(memory);
    gpu.setCanvasSize(canvas.width, canvas.height);
    moduleLoaded = false;
    animationInfo = null;
  }

  // Allocate and copy bytecode
  const ptr = wasm.alloc(bytecode.byteLength);
  if (!ptr) throw new Error("Failed to allocate memory");

  new Uint8Array(memory.buffer, ptr, bytecode.byteLength).set(
    new Uint8Array(bytecode)
  );

  // Load module
  const err = wasm.loadModule(ptr, bytecode.byteLength);
  wasm.free(ptr, bytecode.byteLength);

  if (err !== 0) throw new Error(`Load failed: ${err}`);

  moduleLoaded = true;
  frameCount = wasm.getFrameCount();

  // Read animation info from WASM
  animationInfo = readAnimationInfo();

  // First render to create resources
  renderWithCommandBuffer(0, 0);
}

/**
 * Load bytecode into embedded executor.
 *
 * Embedded executors have a different interface:
 * - getBytecodePtr() / setBytecodeLen() for bytecode
 * - getDataPtr() / setDataLen() for data section
 * - init() for initialization
 * - frame(time, width, height) for rendering
 * - getCommandPtr() / getCommandLen() for command buffer output
 *
 * @param {Object} payloadInfo - Parsed payload from loader.js
 */
async function loadBytecodeEmbedded(payloadInfo) {
  // For embedded executor, bytecode is already in the payload
  // We need to copy it to the executor's memory

  if (wasm.getBytecodePtr && wasm.setBytecodeLen) {
    // Copy bytecode to embedded executor memory
    const bytecodePtr = wasm.getBytecodePtr();
    const bytecodeData = payloadInfo.bytecode;
    new Uint8Array(memory.buffer, bytecodePtr, bytecodeData.length).set(bytecodeData);
    wasm.setBytecodeLen(bytecodeData.length);
  }

  // For now, we use the full payload for shared executor compatibility
  // The embedded executor will parse its own bytecode section
  if (wasm.alloc && wasm.loadModule) {
    // Fallback to shared executor interface if present
    const fullPayload = payloadInfo.payload;
    const ptr = wasm.alloc(fullPayload.byteLength);
    if (ptr) {
      new Uint8Array(memory.buffer, ptr, fullPayload.byteLength).set(fullPayload);
      const err = wasm.loadModule(ptr, fullPayload.byteLength);
      wasm.free(ptr, fullPayload.byteLength);
      if (err !== 0) throw new Error(`Load failed: ${err}`);
    }
  }

  moduleLoaded = true;

  // Get frame count if available
  if (wasm.getFrameCount) {
    frameCount = wasm.getFrameCount();
  } else {
    frameCount = 1;
  }

  // Read animation info if available
  animationInfo = readAnimationInfo();

  // First render to create resources
  renderWithCommandBuffer(0, 0);
}

/**
 * Read animation metadata from WASM module.
 * Returns null if no animation is defined.
 */
function readAnimationInfo() {
  // Check if animation exists
  if (!wasm.hasAnimationInfo()) return null;

  const duration = wasm.getAnimationDuration();
  const loop = wasm.getAnimationLoop() === 1;
  const endBehavior = wasm.getAnimationEndBehavior();
  const sceneCount = wasm.getSceneCount();

  // Read animation name
  const name = readWasmString(wasm.getAnimationName);

  // Read scenes
  const scenes = [];
  for (let i = 0; i < sceneCount; i++) {
    const info = wasm.getSceneInfo(i);
    if (info === 0xFFFFFFFFFFFFFFFFn) continue;

    const startMs = Number(info & 0xFFFFFFFFn);
    const endMs = Number((info >> 32n) & 0xFFFFFFFFn);
    const id = readWasmStringByIndex(wasm.getSceneId, i);
    const frame = readWasmStringByIndex(wasm.getSceneFrame, i);

    scenes.push({ id, frame, startMs, endMs });
  }

  return {
    name,
    duration,
    loop,
    endBehavior: ["hold", "stop", "restart"][endBehavior] || "hold",
    scenes,
  };
}

/**
 * Read a string from WASM using a getter function that takes (ptr, len).
 */
function readWasmString(getter) {
  const bufLen = 256;
  const ptr = wasm.alloc(bufLen);
  if (!ptr) return "";

  const len = getter(ptr, bufLen);
  const str = len > 0 ? new TextDecoder().decode(
    new Uint8Array(memory.buffer, ptr, len)
  ) : "";

  wasm.free(ptr, bufLen);
  return str;
}

/**
 * Read a string from WASM using a getter function that takes (index, ptr, len).
 */
function readWasmStringByIndex(getter, index) {
  const bufLen = 256;
  const ptr = wasm.alloc(bufLen);
  if (!ptr) return "";

  const len = getter(index, ptr, bufLen);
  const str = len > 0 ? new TextDecoder().decode(
    new Uint8Array(memory.buffer, ptr, len)
  ) : "";

  wasm.free(ptr, bufLen);
  return str;
}

function handleDraw(data) {
  if (!initialized || !moduleLoaded) return;

  // Apply uniforms before rendering (if provided)
  if (data.uniforms) {
    applyUniforms(data.uniforms);
  }

  // Note: frame name ignored for now - frame_id 0 executes all frames
  renderWithCommandBuffer(data.time ?? 0, 0);
}

/**
 * Apply uniform values by calling WASM setUniform for each field.
 *
 * Why runtime uniform setting?
 * - Multiplatform: Same WASM binary works on Web, iOS, Android, Desktop
 * - No recompilation: Update values without regenerating bytecode
 * - Dynamic UI: Tools can introspect uniform table and generate sliders/pickers
 * - Decoupling: JS doesn't need to know buffer layouts, just field names
 *
 * @param {Object} uniforms - Map of uniform name -> value
 *   Values can be: number (f32), [n] array (vecNf), [[4][4]] (mat4x4f)
 */
function applyUniforms(uniforms) {
  const encoder = new TextEncoder();

  for (const [name, value] of Object.entries(uniforms)) {
    const nameBytes = encoder.encode(name);
    const namePtr = wasm.alloc(nameBytes.length);
    if (!namePtr) continue;
    new Uint8Array(memory.buffer, namePtr, nameBytes.length).set(nameBytes);

    const valueBytes = uniformValueToBytes(value);
    if (!valueBytes) {
      wasm.free(namePtr, nameBytes.length);
      continue;
    }

    const valuePtr = wasm.alloc(valueBytes.length);
    if (!valuePtr) {
      wasm.free(namePtr, nameBytes.length);
      continue;
    }
    new Uint8Array(memory.buffer, valuePtr, valueBytes.length).set(valueBytes);

    wasm.setUniform(namePtr, nameBytes.length, valuePtr, valueBytes.length);

    wasm.free(namePtr, nameBytes.length);
    wasm.free(valuePtr, valueBytes.length);
  }
}

/**
 * Convert JS value to raw bytes for GPU uniform.
 *
 * Supported types:
 * - number → f32 (4 bytes)
 * - [x, y] → vec2f (8 bytes)
 * - [x, y, z] → vec3f (12 bytes)
 * - [x, y, z, w] → vec4f (16 bytes)
 * - [[4][4]] flattened 16 numbers → mat4x4f (64 bytes)
 *
 * @param {*} value - JS value
 * @returns {Uint8Array|null} - Byte representation or null if unsupported
 */
function uniformValueToBytes(value) {
  if (typeof value === "number") {
    // f32
    return new Uint8Array(new Float32Array([value]).buffer);
  }

  if (Array.isArray(value)) {
    // Flatten nested arrays (for matrices)
    const flat = value.flat(2);

    if (flat.length === 2 || flat.length === 3 || flat.length === 4 ||
        flat.length === 9 || flat.length === 16) {
      return new Uint8Array(new Float32Array(flat).buffer);
    }
  }

  return null;
}

function renderWithCommandBuffer(time, frameId) {
  gpu.setTime(time);

  const ptr = wasm.renderFrame(time, frameId);
  if (!ptr) return;

  gpu.execute(ptr);
}

function handleDestroy() {
  if (moduleLoaded) {
    wasm.freeModule();
    moduleLoaded = false;
  }
  gpu?.destroy();
  if (device) {
    device.destroy();
    device = null;
  }
  initialized = false;
}

// WASM imports - mostly stubs since command buffer doesn't need them
function getWasmImports() {
  // Stub for all the old gpu* extern functions
  const stub = () => {};

  return {
    env: {
      // Old GPU functions (not used with command buffer, but WASM still imports them)
      gpuCreateBuffer: stub,
      gpuCreateTexture: stub,
      gpuCreateSampler: stub,
      gpuCreateShaderModule: stub,
      gpuCreateRenderPipeline: stub,
      gpuCreateComputePipeline: stub,
      gpuCreateBindGroup: stub,
      gpuCreateImageBitmap: stub,
      gpuCreateTextureView: stub,
      gpuCreateQuerySet: stub,
      gpuCreateBindGroupLayout: stub,
      gpuCreatePipelineLayout: stub,
      gpuCreateRenderBundle: stub,
      gpuBeginRenderPass: stub,
      gpuBeginComputePass: stub,
      gpuSetPipeline: stub,
      gpuSetBindGroup: stub,
      gpuSetVertexBuffer: stub,
      gpuSetIndexBuffer: stub,
      gpuDraw: stub,
      gpuDrawIndexed: stub,
      gpuDispatch: stub,
      gpuExecuteBundles: stub,
      gpuEndPass: stub,

      // gpuWriteBuffer: Used by setUniform() to write uniform values
      gpuWriteBuffer: (bufferId, offset, dataPtr, dataLen) => {
        const buffer = gpu?.buffers?.get(bufferId);
        if (!buffer) return;
        const data = new Uint8Array(memory.buffer, dataPtr, dataLen);
        device.queue.writeBuffer(buffer, offset, data);
      },

      gpuSubmit: stub,
      gpuCopyExternalImageToTexture: stub,
      gpuInitWasmModule: stub,
      gpuCallWasmFunc: stub,
      gpuWriteBufferFromWasm: stub,
      gpuCreateTypedArray: stub,
      gpuFillRandomData: stub,
      gpuFillExpression: stub,
      gpuFillConstant: stub,
      gpuWriteBufferFromArray: stub,
      gpuWriteTimeUniform: stub,
      gpuDebugLog: stub,
      jsConsoleLog: stub,
      jsConsoleLogInt: stub,
    },
  };
}
