// Worker thread - owns WebGPU, WASM, and resources
// Uses command buffer approach for minimal bundle size

import { CommandDispatcher } from "./gpu.js";

let canvas, device, context, gpu, wasm, memory;
let initialized = false;
let moduleLoaded = false;
let frameCount = 0;
let log = () => {};

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
  log = data.debug ? console.log.bind(console, "[Worker]") : () => {};

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

  // Load WASM
  if (!data.wasmUrl) throw new Error("wasmUrl required");
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

  log("Initialized");

  // If bytecode was provided, load it
  if (data.bytecode) {
    await loadBytecode(data.bytecode);
  }

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

  // First render to create resources
  renderWithCommandBuffer(0, 0);

  log(`Loaded module: ${frameCount} frames`);
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
    // Encode name as UTF-8 bytes
    const nameBytes = encoder.encode(name);
    const namePtr = wasm.alloc(nameBytes.length);
    if (!namePtr) {
      log(`Failed to allocate memory for uniform name: ${name}`);
      continue;
    }
    new Uint8Array(memory.buffer, namePtr, nameBytes.length).set(nameBytes);

    // Convert JS value to typed array bytes
    const valueBytes = uniformValueToBytes(value);
    if (!valueBytes) {
      wasm.free(namePtr, nameBytes.length);
      log(`Unsupported uniform value type for: ${name}`);
      continue;
    }

    const valuePtr = wasm.alloc(valueBytes.length);
    if (!valuePtr) {
      wasm.free(namePtr, nameBytes.length);
      log(`Failed to allocate memory for uniform value: ${name}`);
      continue;
    }
    new Uint8Array(memory.buffer, valuePtr, valueBytes.length).set(valueBytes);

    // Call WASM setUniform
    const result = wasm.setUniform(namePtr, nameBytes.length, valuePtr, valueBytes.length);

    // Free temporary allocations
    wasm.free(namePtr, nameBytes.length);
    wasm.free(valuePtr, valueBytes.length);

    if (result !== 0) {
      const errors = ["success", "field not found", "size mismatch", "no module"];
      log(`setUniform(${name}) failed: ${errors[result] || `error ${result}`}`);
    }
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

  // Get command buffer from WASM
  const ptr = wasm.renderFrame(time, frameId);
  if (!ptr) {
    log("renderFrame returned null");
    return;
  }

  // Execute commands
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
  log("Destroyed");
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

      // gpuWriteBuffer: Used by setUniform() to write uniform values directly
      // This is called from WASM when JS calls wasm.setUniform()
      gpuWriteBuffer: (bufferId, offset, dataPtr, dataLen) => {
        const buffer = gpu?.buffers?.get(bufferId);
        if (!buffer) {
          log(`gpuWriteBuffer: buffer ${bufferId} not found`);
          return;
        }

        // Copy data from WASM memory to GPU buffer
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
      jsConsoleLog: (ptr, len) => {
        const msg = new TextDecoder().decode(
          new Uint8Array(memory.buffer, ptr, len)
        );
        log(msg);
      },
      jsConsoleLogInt: (ptr, len, value) => {
        const msg = new TextDecoder().decode(
          new Uint8Array(memory.buffer, ptr, len)
        );
        log(msg, value);
      },
    },
  };
}
