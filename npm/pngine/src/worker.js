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
    wasm.freeModule();
    gpu.destroy();
    gpu = new CommandDispatcher(device, context);
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
  // Note: frame name ignored for now - frame_id 0 executes all frames
  renderWithCommandBuffer(data.time ?? 0, 0);
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
      gpuDraw: stub,
      gpuDrawIndexed: stub,
      gpuDispatch: stub,
      gpuExecuteBundles: stub,
      gpuEndPass: stub,
      gpuWriteBuffer: stub,
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
