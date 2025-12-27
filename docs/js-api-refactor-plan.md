# PNGine JS API Refactor Plan

## Executive Summary

Refactor the PNGine web runtime from ~3300 lines across 4 files to ~600 lines
with a minimal, tree-shakeable functional API. Move GPU resource management to
WASM, making JS a thin command dispatcher.

**Current state:** Class-based, worker-centric, 50+ console.logs, frame drops,
inconsistent API **Target state:** Functional, sync draw(), <5KB gzipped, zero
frame drops

---

## Architecture Overview

```
┌────────────────────────────────────┐    ┌────────────────────────────────────┐
│           Main Thread              │    │           Worker Thread            │
├────────────────────────────────────┤    ├────────────────────────────────────┤
│  User Code                         │    │                                    │
│  ──────────                        │    │  _worker.js                        │
│  const p = await pngine(img)       │    │  ───────────                       │
│  draw(p, { time: t })              │    │  - Owns OffscreenCanvas            │
│  play(p)                           │    │  - Owns GPUDevice, GPUQueue        │
│                                    │    │  - Owns WASM instance              │
├────────────────────────────────────┤    │  - Owns resources[]                │
│  pngine.js (Public API)  ~100 lines│    │                                    │
│  ───────────────────────           │    ├────────────────────────────────────┤
│  pngine() → spawn worker → POJO    │    │  _gpu.js (Command Dispatcher)      │
│  draw() → postMessage → return     │    │  ────────────────────────          │
│  play/pause/stop/seek/destroy      │    │  executeCommands(buffer, resources)│
│                                    │    │  switch(cmd) { ... }               │
├────────────────────────────────────┤    │                                    │
│  _anim.js (Animation Loop)         │    ├────────────────────────────────────┤
│  ──────────────────────            │    │  WASM (pngine.wasm)       ~60KB    │
│  requestAnimationFrame             │    │  ──────────────────                │
│  → posts draw message each frame   │    │  - Bytecode parsing                │
│                                    │    │  - Uniform reflection              │
│         │                          │    │  - Command buffer generation       │
│         │ postMessage('draw',...)  │    │                                    │
│         └──────────────────────────┼───→│  onmessage → render_frame()        │
│                                    │    │            → executeCommands()     │
│         ←──────────────────────────┼────│            → queue.submit()        │
│           postMessage('error',...) │    │                                    │
│           postMessage('ready',...) │    │                                    │
└────────────────────────────────────┘    └────────────────────────────────────┘
```

---

## Design Decisions

### 1. Worker for Rendering (Post-and-Forget)

**Decision:** All GPU operations happen on worker thread. `draw()` posts message
and returns immediately.

**Architecture:**

```
Main Thread                          Worker Thread
────────────                         ─────────────
pngine.js (public API)               WASM instance
  ↓ postMessage                      WebGPU device
  └──────────────────────────────→   Command execution
                                     queue.submit()
```

**Why this is "sync" from caller's perspective:**

- `draw()` returns immediately (no await)
- No callback required
- No Promise returned
- postMessage() itself is synchronous (queues message, returns immediately)
- GPU work happens asynchronously on worker

**Rationale:**

- Main thread stays free for UI interactions
- Heavy compute shaders don't block UI
- Complex animations remain smooth
- OffscreenCanvas + Worker is the canonical WebGPU pattern

**Trade-off:**

- Errors are asynchronous (must use onError callback)
- Slight message queue overhead (~0.1ms per message)
- Can't read GPU state synchronously (e.g., readback buffers)

### 2. WASM Owns All State

**Decision:** All resource IDs, uniform tables, scene graphs live in WASM linear
memory.

**Rationale:**

- Cross-platform: Same WASM code for Web, iOS, Android, Desktop
- JS becomes trivially small (~200 lines for GPU dispatcher)
- Uniform reflection happens in Zig at compile time
- Scene/animation logic is platform-agnostic

**JS holds only:**

- GPUDevice, GPUQueue
- Resource array: `resources[id] = GPUBuffer | GPUTexture | ...`
- Canvas reference

### 3. Command Buffer Protocol

**Decision:** WASM generates compact command buffer, JS executes.

**Format:**

```
Header: [total_len: u32] [cmd_count: u16] [reserved: u16]
Commands: [cmd: u8] [args: varies by cmd]
```

**Command set (minimal):**

```
Resource Creation (0x00-0x0F):
  0x01 CREATE_BUFFER     [id:u16] [size:u32] [usage:u32]
  0x02 CREATE_TEXTURE    [id:u16] [w:u16] [h:u16] [format:u8] [usage:u32]
  0x03 CREATE_SAMPLER    [id:u16] [filter:u8] [address:u8]
  0x04 CREATE_BIND_GROUP [id:u16] [layout_id:u16] [entry_count:u8] [entries...]
  0x05 CREATE_PIPELINE   [id:u16] [type:u8] [shader_id:u16] [layout_id:u16] [config...]
  0x06 CREATE_SHADER     [id:u16] [code_ptr:u32] [code_len:u32]

Resource Update (0x10-0x1F):
  0x10 WRITE_BUFFER      [id:u16] [offset:u32] [data_ptr:u32] [data_len:u32]
  0x11 WRITE_TEXTURE     [id:u16] [x:u16] [y:u16] [w:u16] [h:u16] [data_ptr:u32]

Render Pass (0x20-0x2F):
  0x20 BEGIN_RENDER_PASS [target_id:u16] [clear:u8] [r:f32] [g:f32] [b:f32] [a:f32]
  0x21 SET_PIPELINE      [id:u16]
  0x22 SET_BIND_GROUP    [slot:u8] [id:u16] [offsets...]
  0x23 SET_VERTEX_BUFFER [slot:u8] [id:u16] [offset:u32]
  0x24 SET_INDEX_BUFFER  [id:u16] [format:u8] [offset:u32]
  0x25 DRAW              [vertex_count:u32] [instance_count:u32] [first:u32]
  0x26 DRAW_INDEXED      [index_count:u32] [instance_count:u32] [first:u32]
  0x27 END_RENDER_PASS

Compute Pass (0x30-0x3F):
  0x30 BEGIN_COMPUTE_PASS
  0x31 DISPATCH          [x:u32] [y:u32] [z:u32]
  0x32 END_COMPUTE_PASS

Control (0xF0-0xFF):
  0xF0 SUBMIT            (flush command encoder)
  0xFF END               (end of command buffer)
```

### 4. Sync draw() Implementation (Post-and-Forget)

```js
// Main thread - pngine.js
export function draw(p, opts = {}) {
  // Pre-validation (throws immediately for usage errors)
  if (!p._) throw new Error("Pngine destroyed");
  if (!p._.ready) throw new Error("Not initialized");
  if (opts.frame && !p._.frames.includes(opts.frame)) {
    throw new Error(`Unknown frame: ${opts.frame}`);
  }

  // Post message to worker and return immediately
  // No await, no callback, no Promise
  p._.worker.postMessage({
    type: "draw",
    time: opts.time ?? p._.time,
    frame: opts.frame ?? null,
    uniforms: opts.uniforms ?? null,
  });

  // Update local time tracking (for getters)
  if (opts.time !== undefined) {
    p._.time = opts.time;
  }

  // Returns undefined (not a Promise)
}
```

```js
// Worker thread - _worker.js
onmessage = (e) => {
  const { type, ...data } = e.data;

  switch (type) {
    case "draw": {
      const { time, frame, uniforms } = data;

      // Write uniforms to WASM memory
      if (uniforms) {
        for (const [name, value] of Object.entries(uniforms)) {
          const info = uniformTable.get(name);
          if (info) writeUniform(memory, info, value);
        }
      }

      // Generate command buffer via WASM
      const frameId = frame ? frameIds.get(frame) : 0;
      const cmdPtr = wasm.exports.render_frame(time, frameId);

      // Execute commands on GPU
      executeCommands(memory.buffer, cmdPtr, resources, device, queue);

      // queue.submit() is fire-and-forget
      // Worker continues, GPU renders async
      break;
    }
      // ... other message types
  }
};
```

**Why this is "sync" from caller's perspective:**

1. `draw()` returns immediately (no await)
2. `postMessage()` is synchronous (queues message, returns)
3. No callback or Promise returned
4. Caller continues executing immediately
5. Worker handles GPU work asynchronously

**Error handling:**

- Usage errors (destroyed, invalid frame): throw immediately in draw()
- GPU errors (shader fail, device lost): async via onError callback

### 5. Animation Loop

```js
export function play(p) {
  if (p._playing) return p;

  p._playing = true;
  p._startTime = performance.now() - p._time * 1000;

  const loop = () => {
    if (!p._playing) return;

    const now = performance.now();
    const elapsed = (now - p._startTime) / 1000;

    // Update scene based on time
    updateScene(p, elapsed);

    // Draw frame (sync)
    draw(p, { time: elapsed });

    p._animationId = requestAnimationFrame(loop);
  };

  p._animationId = requestAnimationFrame(loop);
  return p;
}

export function pause(p) {
  if (!p._playing) return p;
  p._playing = false;
  p._time = (performance.now() - p._startTime) / 1000;
  if (p._animationId) {
    cancelAnimationFrame(p._animationId);
    p._animationId = null;
  }
  return p;
}

export function stop(p) {
  pause(p);
  p._time = 0;
  p._startTime = performance.now();
  updateScene(p, 0);
  draw(p, { time: 0 });
  return p;
}
```

**No frame drops:** Every requestAnimationFrame calls draw(). No "renderPending"
skip logic.

### 6. Image Replacement Strategy

When source is `<img>` element or querySelector:

```js
async function initFromImage(img, options) {
  // 1. Get image dimensions
  const { naturalWidth: w, naturalHeight: h } = img;

  // 2. Create canvas
  const canvas = document.createElement("canvas");
  canvas.width = w;
  canvas.height = h;

  // 3. Position canvas over image
  const parent = img.parentElement;
  if (getComputedStyle(parent).position === "static") {
    parent.style.position = "relative";
  }

  Object.assign(canvas.style, {
    position: "absolute",
    top: img.offsetTop + "px",
    left: img.offsetLeft + "px",
    width: img.offsetWidth + "px",
    height: img.offsetHeight + "px",
    pointerEvents: "none", // Let clicks pass through to image
  });

  parent.appendChild(canvas);

  // 4. Fetch PNG data from image src
  const response = await fetch(img.src);
  const data = await response.arrayBuffer();

  // 5. Initialize with canvas and data
  return initWithCanvas(canvas, data, options);
}
```

**Progressive enhancement:** Image shows while loading. Canvas renders over it.
If JS fails, image remains.

---

## File Structure

```
web/
├── pngine.js              # Public API exports (~100 lines)
├── _init.js               # Main thread init, worker spawn (~150 lines)
├── _worker.js             # Worker entry point (~200 lines)
├── _gpu.js                # Command dispatcher (in worker) (~200 lines)
├── _anim.js               # Animation & scene logic (~100 lines)
├── _uniforms.js           # Uniform reading/writing (~80 lines)
└── _extract.js            # PNG/ZIP bytecode extraction (~80 lines)

Total: ~910 lines (down from ~3300, 72% reduction)
```

**Worker bundling:** `_worker.js` imports `_gpu.js` and `_uniforms.js`. These
are bundled into a single worker blob at build time (like current approach).

### pngine.js (Public API)

```js
// Public API - all exports are tree-shakeable
export { pngine } from "./_init.js";
export { draw } from "./_gpu.js";
export { pause, play, seek, setScene, stop } from "./_anim.js";
export { destroy } from "./_init.js";

// Re-export types for documentation
/** @typedef {import('./_init.js').Pngine} Pngine */
/** @typedef {import('./_init.js').PngineOptions} PngineOptions */
/** @typedef {import('./_gpu.js').DrawOptions} DrawOptions */
```

### _init.js (Main Thread Initialization)

```js
// Worker code inlined at build time (like current approach)
import { WORKER_BLOB_URL } from "./_worker-blob.js";

/**
 * @param {string | ArrayBuffer | Blob | Uint8Array | HTMLImageElement} source
 * @param {PngineOptions} [options]
 * @returns {Promise<Pngine>}
 */
export async function pngine(source, options = {}) {
  const log = options.debug ? console.log.bind(console, "[PNGine]") : () => {};

  // Resolve source to canvas + bytecode
  let canvas, bytecode;

  if (typeof source === "string") {
    if (source.startsWith("#") || source.startsWith(".")) {
      // Query selector
      const el = document.querySelector(source);
      if (el instanceof HTMLImageElement) {
        ({ canvas, bytecode } = await initFromImage(el, options, log));
      } else if (el instanceof HTMLCanvasElement) {
        canvas = el;
        throw new Error("Canvas source requires URL or data");
      } else {
        throw new Error(`Invalid element: ${source}`);
      }
    } else {
      // URL
      canvas = options.canvas;
      if (!canvas) throw new Error("Canvas required for URL source");
      const resp = await fetch(source);
      bytecode = await extractBytecode(await resp.arrayBuffer());
    }
  } else if (source instanceof HTMLImageElement) {
    ({ canvas, bytecode } = await initFromImage(source, options, log));
  } else if (
    source instanceof ArrayBuffer || source instanceof Uint8Array ||
    source instanceof Blob
  ) {
    canvas = options.canvas;
    if (!canvas) throw new Error("Canvas required for data source");
    const data = source instanceof Blob ? await source.arrayBuffer() : source;
    bytecode = await extractBytecode(data);
  } else {
    throw new Error("Invalid source type");
  }

  // Get OffscreenCanvas and transfer to worker
  const offscreen = canvas.transferControlToOffscreen();

  // Spawn worker
  const worker = new Worker(WORKER_BLOB_URL, { type: "module" });

  // Wait for worker to be ready
  const initResult = await new Promise((resolve, reject) => {
    const timeout = setTimeout(
      () => reject(new Error("Worker init timeout")),
      10000,
    );

    worker.onmessage = (e) => {
      clearTimeout(timeout);
      if (e.data.type === "ready") {
        resolve(e.data);
      } else if (e.data.type === "error") {
        reject(new Error(e.data.message));
      }
    };

    worker.onerror = (e) => {
      clearTimeout(timeout);
      reject(new Error(`Worker error: ${e.message}`));
    };

    // Send init message with canvas and bytecode
    worker.postMessage({
      type: "init",
      canvas: offscreen,
      bytecode: bytecode,
      wasmUrl: options.wasmUrl || null,
      debug: options.debug || false,
    }, [offscreen, bytecode.buffer]);
  });

  // Set up ongoing error handler
  worker.onmessage = (e) => {
    if (e.data.type === "error" && options.onError) {
      options.onError(new Error(e.data.message));
    }
  };

  // Create POJO with getters
  return createPngine({
    canvas,
    worker,
    width: initResult.width,
    height: initResult.height,
    frames: initResult.frames, // ['main', 'intro', ...]
    animationName: initResult.animation,
    scenes: initResult.scenes,
    durations: initResult.durations,
    totalDuration: initResult.totalDuration,
    ready: true,
    playing: false,
    time: 0,
    currentScene: initResult.scenes[0] || null,
    sceneTime: 0,
    animationId: null,
    debug: options.debug || false,
    log,
  });
}

function createPngine(internal) {
  return {
    // Public getters (read-only)
    get animation() {
      return internal.animationName;
    },
    get isPlaying() {
      return internal.playing;
    },
    get time() {
      return internal.time;
    },
    get scenes() {
      return internal.scenes.slice();
    },
    get durations() {
      return internal.durations.slice();
    },
    get scene() {
      return internal.currentScene;
    },
    get sceneTime() {
      return internal.sceneTime;
    },
    get width() {
      return internal.width;
    },
    get height() {
      return internal.height;
    },

    // Internal state (hidden but accessible to our functions via _)
    _: internal,
  };
}

export function destroy(p) {
  const i = p._;
  if (!i) return p; // Already destroyed

  if (i.animationId) cancelAnimationFrame(i.animationId);
  i.worker.postMessage({ type: "destroy" });
  i.worker.terminate();

  // Null out internal state
  p._ = null;
  return p;
}
```

### _worker.js (Worker Entry Point)

```js
// Worker thread - owns WebGPU, WASM, and resources
import { executeCommands } from "./_gpu.js";
import { readUniformTable, writeUniform } from "./_uniforms.js";

let device, queue, context, format;
let wasm, memory;
let resources = [];
let uniformTable = new Map();
let frameIds = new Map();
let log = () => {};

onmessage = async (e) => {
  const { type, ...data } = e.data;

  switch (type) {
    case "init": {
      try {
        const { canvas, bytecode, wasmUrl, debug } = data;
        log = debug ? console.log.bind(console, "[Worker]") : () => {};

        // Initialize WebGPU
        const adapter = await navigator.gpu?.requestAdapter();
        if (!adapter) throw new Error("WebGPU not supported");
        device = await adapter.requestDevice();
        queue = device.queue;
        context = canvas.getContext("webgpu");
        format = navigator.gpu.getPreferredCanvasFormat();
        context.configure({ device, format, alphaMode: "premultiplied" });

        // Load WASM
        const wasmResp = await fetch(
          wasmUrl || new URL("pngine.wasm", import.meta.url),
        );
        const wasmModule = await WebAssembly.compileStreaming(wasmResp);
        memory = new WebAssembly.Memory({ initial: 256 });
        const imports = { env: { memory } };
        const instance = await WebAssembly.instantiate(wasmModule, imports);
        wasm = instance.exports;

        // Initialize runtime
        wasm.init(canvas.width, canvas.height);

        // Load bytecode
        const ptr = wasm.alloc(bytecode.byteLength);
        new Uint8Array(memory.buffer, ptr, bytecode.byteLength).set(
          new Uint8Array(bytecode),
        );
        const err = wasm.load_module(ptr, bytecode.byteLength);
        if (err !== 0) throw new Error(`Load failed: ${err}`);

        // Read metadata from WASM
        uniformTable = readUniformTable(
          memory.buffer,
          wasm.get_uniform_table(),
        );
        const animInfo = readAnimationInfo(
          memory.buffer,
          wasm.get_animation_info(),
        );

        // Build frame ID map
        animInfo.frames.forEach((name, i) => frameIds.set(name, i));

        // Report ready
        postMessage({
          type: "ready",
          width: canvas.width,
          height: canvas.height,
          ...animInfo,
        });
      } catch (err) {
        postMessage({ type: "error", message: err.message });
      }
      break;
    }

    case "draw": {
      const { time, frame, uniforms } = data;

      // Write uniforms
      if (uniforms) {
        for (const [name, value] of Object.entries(uniforms)) {
          const info = uniformTable.get(name);
          if (info) writeUniform(memory, queue, resources, info, value);
        }
      }

      // Generate and execute commands
      const frameId = frame ? (frameIds.get(frame) ?? 0) : 0;
      const cmdPtr = wasm.render_frame(time, frameId);
      executeCommands(
        memory.buffer,
        cmdPtr,
        resources,
        device,
        queue,
        context,
        format,
      );
      break;
    }

    case "destroy": {
      wasm.free_module();
      device.destroy();
      break;
    }
  }
};
```

### _gpu.js (Command Dispatcher - runs in Worker)

```js
// Command opcodes
const CMD = {
  CREATE_BUFFER: 0x01,
  CREATE_TEXTURE: 0x02,
  CREATE_SAMPLER: 0x03,
  CREATE_BIND_GROUP: 0x04,
  CREATE_PIPELINE: 0x05,
  CREATE_SHADER: 0x06,
  WRITE_BUFFER: 0x10,
  BEGIN_RENDER_PASS: 0x20,
  SET_PIPELINE: 0x21,
  SET_BIND_GROUP: 0x22,
  SET_VERTEX_BUFFER: 0x23,
  SET_INDEX_BUFFER: 0x24,
  DRAW: 0x25,
  DRAW_INDEXED: 0x26,
  END_RENDER_PASS: 0x27,
  BEGIN_COMPUTE_PASS: 0x30,
  DISPATCH: 0x31,
  END_COMPUTE_PASS: 0x32,
  SUBMIT: 0xF0,
  END: 0xFF,
};

/**
 * @param {Pngine} p
 * @param {DrawOptions} [opts]
 */
export function draw(p, opts = {}) {
  const i = p._;

  // Write uniforms
  if (opts.uniforms) {
    writeUniforms(
      i.memory.buffer,
      i.uniformTable,
      opts.uniforms,
      i.queue,
      i.resources,
    );
  }

  // Generate command buffer
  const time = opts.time ?? i.time;
  const frameId = opts.frame ? (i.frameIds.get(opts.frame) ?? 0) : 0;
  const cmdPtr = i.wasm.exports.render_frame(time, frameId);

  // Execute commands
  executeCommands(i, cmdPtr);
}

function executeCommands(i, ptr) {
  const view = new DataView(i.memory.buffer);
  const u8 = new Uint8Array(i.memory.buffer);

  let encoder = null;
  let pass = null;

  // Read header
  const totalLen = view.getUint32(ptr, true);
  const cmdCount = view.getUint16(ptr + 4, true);
  ptr += 8;

  const endPtr = ptr + totalLen - 8;

  while (ptr < endPtr) {
    const cmd = u8[ptr++];

    switch (cmd) {
      case CMD.CREATE_BUFFER: {
        const id = view.getUint16(ptr, true);
        ptr += 2;
        const size = view.getUint32(ptr, true);
        ptr += 4;
        const usage = view.getUint32(ptr, true);
        ptr += 4;
        i.resources[id] = i.device.createBuffer({ size, usage });
        break;
      }

      case CMD.WRITE_BUFFER: {
        const id = view.getUint16(ptr, true);
        ptr += 2;
        const offset = view.getUint32(ptr, true);
        ptr += 4;
        const dataPtr = view.getUint32(ptr, true);
        ptr += 4;
        const dataLen = view.getUint32(ptr, true);
        ptr += 4;
        i.queue.writeBuffer(
          i.resources[id],
          offset,
          i.memory.buffer,
          dataPtr,
          dataLen,
        );
        break;
      }

      case CMD.BEGIN_RENDER_PASS: {
        encoder = i.device.createCommandEncoder();
        const targetId = view.getUint16(ptr, true);
        ptr += 2;
        const clear = u8[ptr++];

        let colorAttachment;
        if (targetId === 0xFFFF) {
          // Render to canvas
          colorAttachment = {
            view: i.context.getCurrentTexture().createView(),
            loadOp: clear ? "clear" : "load",
            storeOp: "store",
          };
        } else {
          colorAttachment = {
            view: i.resources[targetId].createView(),
            loadOp: clear ? "clear" : "load",
            storeOp: "store",
          };
        }

        if (clear) {
          colorAttachment.clearValue = {
            r: view.getFloat32(ptr, true),
            g: view.getFloat32(ptr + 4, true),
            b: view.getFloat32(ptr + 8, true),
            a: view.getFloat32(ptr + 12, true),
          };
          ptr += 16;
        }

        pass = encoder.beginRenderPass({ colorAttachments: [colorAttachment] });
        break;
      }

      case CMD.SET_PIPELINE: {
        const id = view.getUint16(ptr, true);
        ptr += 2;
        pass.setPipeline(i.resources[id]);
        break;
      }

      case CMD.SET_BIND_GROUP: {
        const slot = u8[ptr++];
        const id = view.getUint16(ptr, true);
        ptr += 2;
        pass.setBindGroup(slot, i.resources[id]);
        break;
      }

      case CMD.SET_VERTEX_BUFFER: {
        const slot = u8[ptr++];
        const id = view.getUint16(ptr, true);
        ptr += 2;
        const offset = view.getUint32(ptr, true);
        ptr += 4;
        pass.setVertexBuffer(slot, i.resources[id], offset);
        break;
      }

      case CMD.DRAW: {
        const vertexCount = view.getUint32(ptr, true);
        ptr += 4;
        const instanceCount = view.getUint32(ptr, true);
        ptr += 4;
        const firstVertex = view.getUint32(ptr, true);
        ptr += 4;
        pass.draw(vertexCount, instanceCount, firstVertex);
        break;
      }

      case CMD.END_RENDER_PASS: {
        pass.end();
        pass = null;
        break;
      }

      case CMD.SUBMIT: {
        i.queue.submit([encoder.finish()]);
        encoder = null;
        break;
      }

      case CMD.END: {
        return;
      }

      default:
        throw new Error(`Unknown command: 0x${cmd.toString(16)}`);
    }
  }
}
```

---

## WASM Interface

### Exports (Zig → JS)

```zig
// wasm.zig - New exports for command buffer API

/// Initialize runtime with canvas dimensions
export fn init(width: u32, height: u32) void;

/// Allocate memory for bytecode
export fn alloc(size: u32) [*]u8;

/// Load compiled bytecode module
export fn load_module(ptr: [*]const u8, len: u32) ErrorCode;

/// Free current module
export fn free_module() void;

/// Generate command buffer for a frame
/// Returns pointer to command buffer in linear memory
export fn render_frame(time: f32, frame_id: u16) [*]u8;

/// Get uniform reflection table
/// Returns pointer to table: [count:u32] [entries...]
export fn get_uniform_table() [*]u8;

/// Get animation info
/// Returns pointer to: [name_ptr:u32] [name_len:u32] [scene_count:u32] [scenes...]
export fn get_animation_info() [*]u8;

/// Get resource info for JS initialization
export fn get_resource_count() u32;
```

### Imports (JS → Zig)

```zig
// Minimal imports - mostly for debugging
extern fn log_write(ptr: [*]const u8, len: u32) void;
extern fn log_flush() void;
extern fn panic(ptr: [*]const u8, len: u32) noreturn;
```

**Note:** No WebGPU imports! All GPU operations are via command buffer.

### Memory Layout

```
Linear Memory (16MB initial):
┌──────────────────────────────────────┐ 0x000000
│ WASM globals & stack (1MB)           │
├──────────────────────────────────────┤ 0x100000
│ Bytecode module (loaded)             │
├──────────────────────────────────────┤
│ Resource table                       │
│ - IDs, sizes, types                  │
├──────────────────────────────────────┤
│ Uniform reflection table             │
│ - name → buffer, offset, type        │
├──────────────────────────────────────┤
│ Animation/scene data                 │
│ - scene names, durations, frames     │
├──────────────────────────────────────┤
│ Command buffer (double-buffered)     │
│ - Buffer A: being written            │
│ - Buffer B: being executed           │
├──────────────────────────────────────┤
│ Shader code strings                  │
├──────────────────────────────────────┤
│ Heap (remaining)                     │
└──────────────────────────────────────┘ 0x1000000
```

---

## Uniform Reflection

### Table Format

```
[count: u32]
For each uniform:
  [name_len: u16] [name: u8...] (padded to 4 bytes)
  [buffer_id: u16]
  [offset: u16]
  [type: u8]  // 0=f32, 1=vec2, 2=vec3, 3=vec4, 4=mat4, ...
  [_pad: u8]
```

### JS Reading

```js
function readUniformTable(buffer, ptr) {
  const view = new DataView(buffer);
  const u8 = new Uint8Array(buffer);
  const table = new Map();

  const count = view.getUint32(ptr, true);
  ptr += 4;

  for (let i = 0; i < count; i++) {
    const nameLen = view.getUint16(ptr, true);
    ptr += 2;
    const name = new TextDecoder().decode(u8.slice(ptr, ptr + nameLen));
    ptr += (nameLen + 3) & ~3; // Align to 4

    const bufferId = view.getUint16(ptr, true);
    ptr += 2;
    const offset = view.getUint16(ptr, true);
    ptr += 2;
    const type = u8[ptr++];
    ptr++; // Skip padding

    table.set(name, { bufferId, offset, type });
  }

  return table;
}
```

### Usage in draw()

```js
draw(p, {
  uniforms: {
    time: 1.5, // f32 → 4 bytes
    resolution: [800, 600], // vec2 → 8 bytes
    color: [1, 0.5, 0.2, 1], // vec4 → 16 bytes
  },
});
```

JS looks up each name in table, writes to correct buffer at correct offset.

---

## Animation Info

### Table Format

```
[animation_name_len: u16] [animation_name: u8...] (padded)
[scene_count: u16]
[total_duration: f32]
For each scene:
  [name_len: u16] [name: u8...] (padded)
  [duration: f32]
  [frame_id: u16]
  [_pad: u16]
```

### Scene Selection Algorithm

```js
function updateScene(p, globalTime) {
  const i = p._;

  // Loop time if past total duration
  const t = globalTime % i.totalDuration;

  // Find current scene
  let elapsed = 0;
  for (let s = 0; s < i.scenes.length; s++) {
    const dur = i.durations[s];
    if (t < elapsed + dur) {
      i.currentScene = i.scenes[s];
      i.sceneTime = t - elapsed;
      i.currentFrameId = i.frameIds[s];
      return;
    }
    elapsed += dur;
  }

  // Fallback to last scene
  i.currentScene = i.scenes[i.scenes.length - 1];
  i.sceneTime = i.durations[i.durations.length - 1];
}
```

---

## Error Handling

### Sync Errors (thrown immediately)

```js
// In draw()
if (!p._) throw new Error("Pngine destroyed");
if (!p._.loaded) throw new Error("No module loaded");
if (opts.frame && !p._.frameIds.has(opts.frame)) {
  throw new Error(`Unknown frame: ${opts.frame}`);
}
```

### Async Errors (via callback)

```js
// In pngine()
device.lost.then((info) => {
  if (options.onError) {
    options.onError(new Error(`GPU device lost: ${info.reason}`));
  }
});

// Shader compilation errors
device.pushErrorScope("validation");
// ... create pipeline ...
device.popErrorScope().then((error) => {
  if (error && options.onError) {
    options.onError(new Error(`Shader error: ${error.message}`));
  }
});
```

### WASM Errors

```js
// Error codes from WASM
const ErrorCode = {
  SUCCESS: 0,
  INVALID_BYTECODE: 1,
  OUT_OF_MEMORY: 2,
  INVALID_RESOURCE: 3,
  // ...
};

// In pngine()
const err = exports.load_module(ptr, bytecode.length);
if (err !== 0) {
  throw new Error(`Load failed: ${ErrorCode[err] || err}`);
}
```

---

## Bundle Configuration

### esbuild Config

```js
// build.js
import * as esbuild from "esbuild";

const result = await esbuild.build({
  entryPoints: ["web/pngine.js"],
  bundle: true,
  minify: true,
  format: "esm",
  target: "es2020",
  outfile: "dist/pngine.min.js",
  metafile: true,

  // Tree-shaking hints
  pure: ["console.log", "console.debug", "console.info"],

  // Dead code elimination
  define: {
    "DEBUG": "false",
  },

  // Preserve function names for debugging
  keepNames: false,

  // Source maps for debugging
  sourcemap: "external",
});

// Write metafile for analysis
import fs from "fs";
fs.writeFileSync("dist/meta.json", JSON.stringify(result.metafile));

// Report size
const stat = fs.statSync("dist/pngine.min.js");
console.log(`Bundle: ${(stat.size / 1024).toFixed(1)}KB`);

// Gzip size
import { gzipSync } from "zlib";
const gzipped = gzipSync(fs.readFileSync("dist/pngine.min.js"));
console.log(`Gzipped: ${(gzipped.length / 1024).toFixed(1)}KB`);
```

### Expected Sizes

**Main bundle** (loaded on page):

| File           | Lines   | Minified  | Gzipped   |
| -------------- | ------- | --------- | --------- |
| pngine.js      | 100     | 1.5KB     | 0.6KB     |
| _init.js       | 150     | 2KB       | 0.8KB     |
| _anim.js       | 100     | 1KB       | 0.4KB     |
| _extract.js    | 80      | 1KB       | 0.4KB     |
| **Main Total** | **430** | **5.5KB** | **2.2KB** |

**Worker bundle** (loaded lazily):

| File             | Lines   | Minified | Gzipped   |
| ---------------- | ------- | -------- | --------- |
| _worker.js       | 200     | 2.5KB    | 1KB       |
| _gpu.js          | 200     | 2.5KB    | 1KB       |
| _uniforms.js     | 80      | 1KB      | 0.4KB     |
| **Worker Total** | **480** | **6KB**  | **2.4KB** |

**Combined:** ~910 lines, ~11.5KB min, ~4.6KB gzip

Compare to current: ~3300 lines, ~25KB min, ~8KB gzip

**72% reduction in lines, 42% reduction in bundle size**

Note: Worker bundle is inlined as blob URL in production, so total download is
~4.6KB gzip.

---

## Migration Path

### Phase 1: New Files (Non-breaking)

1. Create `web/pngine.js` with new API
2. Create internal `web/_*.js` files
3. Keep old files working
4. Add `build-new.js` for new bundle
5. Test with examples

### Phase 2: WASM Changes

1. Add command buffer generation to `src/wasm.zig`
2. Add uniform table export
3. Add animation info export
4. Test with existing bytecode

### Phase 3: Integration

1. Wire new JS to new WASM exports
2. Test all examples with new API
3. Verify bundle sizes
4. Generate metafile, analyze

### Phase 4: Cleanup

1. Update examples to use new API
2. Remove old JS files:
   - `pngine-loader.js`
   - `pngine-worker.js`
   - `pngine-protocol.js`
   - `pngine-gpu.js`
   - `pngine-viewer.js`
3. Update npm package
4. Update documentation

### Phase 5: Optimization

1. Analyze metafile for size issues
2. Add `@__PURE__` annotations where needed
3. Profile render_frame() performance
4. Optimize command buffer generation

---

## Testing Strategy

### Unit Tests (Zig)

```zig
test "command buffer generation" {
    var emitter = CommandEmitter.init(buffer);
    emitter.createBuffer(0, 1024, .{ .vertex = true });
    emitter.beginRenderPass(0xFFFF, true, .{ 0, 0, 0, 1 });
    emitter.draw(3, 1, 0);
    emitter.endRenderPass();
    emitter.submit();

    const cmds = emitter.finish();
    try expectEqual(cmds.len, 42); // Verify size
}
```

### Integration Tests (JS)

```js
// test/draw.test.js
import { destroy, draw, pngine } from "../web/pngine.js";

test("sync draw does not return promise", async () => {
  const canvas = createTestCanvas();
  const p = await pngine(testBytecode, { canvas });

  const result = draw(p, { time: 0 });

  // draw() returns undefined, not a Promise
  // (posts to worker and returns immediately)
  expect(result).toBeUndefined();
  expect(result instanceof Promise).toBe(false);

  destroy(p);
});

test("draw with uniforms", async () => {
  const p = await pngine(uniformTestBytecode, { canvas: createTestCanvas() });

  // Should not throw
  draw(p, {
    time: 1.5,
    uniforms: {
      color: [1, 0, 0, 1],
      scale: 2.0,
    },
  });

  destroy(p);
});

test("animation loop no frame drops", async () => {
  const p = await pngine(animTestBytecode, { canvas: createTestCanvas() });

  let frameCount = 0;
  const originalDraw = draw;

  // Monkey-patch to count frames
  global.draw = (...args) => {
    frameCount++;
    return originalDraw(...args);
  };

  play(p);
  await sleep(100); // ~6 frames at 60fps
  pause(p);

  expect(frameCount).toBeGreaterThanOrEqual(5);

  destroy(p);
});
```

### Visual Tests

```html
<!-- test/visual.html -->
<img id="test" src="test.png" width="512" height="512">
<script type="module">
  import { play, pngine } from "../web/pngine.js";

  const p = await pngine("#test", { debug: true });
  play(p);

  // Verify: canvas overlays image, animation runs
</script>
```

---

## TypeScript Definitions

```typescript
// pngine.d.ts

export interface Pngine {
  readonly animation: string;
  readonly isPlaying: boolean;
  readonly time: number;
  readonly scenes: readonly string[];
  readonly durations: readonly number[];
  readonly scene: string;
  readonly sceneTime: number;
  readonly width: number;
  readonly height: number;
}

export interface PngineOptions {
  canvas?: HTMLCanvasElement;
  debug?: boolean;
  wasmUrl?: string | URL;
  onError?: (error: Error) => void;
}

export interface DrawOptions {
  time?: number;
  frame?: string;
  uniforms?: Record<string, number | number[]>;
}

export function pngine(
  source: string | ArrayBuffer | Blob | Uint8Array | HTMLImageElement,
  options?: PngineOptions,
): Promise<Pngine>;

export function draw(pngine: Pngine, options?: DrawOptions): void;
export function play(pngine: Pngine): Pngine;
export function pause(pngine: Pngine): Pngine;
export function stop(pngine: Pngine): Pngine;
export function seek(pngine: Pngine, time: number): Pngine;
export function setScene(pngine: Pngine, scene: string): Pngine;
export function destroy(pngine: Pngine): Pngine;
```

---

## Open Questions

### 1. Multiple Canvases?

Current design: one Pngine per canvas. For multiple canvases with same shader:

```js
const p1 = await pngine(shader, { canvas: canvas1 });
const p2 = await pngine(shader, { canvas: canvas2 });
// Two separate WASM instances, two GPUDevices
```

Alternative: shared WASM, multiple contexts:

```js
const p = await pngine(shader, { canvases: [canvas1, canvas2] });
// Single WASM, single GPUDevice, multiple contexts
```

**Recommendation:** Single canvas for MVP. Multi-canvas is optimization for
later.

### 2. Resize Handling?

When canvas resizes:

A) Automatic: observe resize, reconfigure context B) Manual: user calls
`resize(p, w, h)` C) Ignore: user recreates Pngine

**Recommendation:** B. Explicit is better than magic.

```js
export function resize(pngine: Pngine, width: number, height: number): void;
```

### 3. HDR / Wide Gamut?

WebGPU supports HDR canvas formats. Go with:

User option: `{ hdr: true }`

---

## Implementation Order

1. **_gpu.js** - Command dispatcher (worker side, can test with mock commands)
2. **_uniforms.js** - Uniform table reading/writing (worker side)
3. **_extract.js** - PNG/ZIP extraction (main thread, reuse existing)
4. **WASM changes** - Command buffer generation + new exports
5. **_worker.js** - Worker entry point, message handling
6. **_init.js** - Main thread init, worker spawn, POJO creation
7. **_anim.js** - Animation logic (main thread, posts to worker)
8. **pngine.js** - Public API exports
9. **Bundle script** - esbuild config, worker inlining, size verification
10. **Testing** - Integration tests, visual tests
11. **Migration** - Update examples, remove old files

---

## Success Criteria

1. **Bundle size**: <5KB gzipped (currently ~8KB)
2. **API surface**: 8 exports (currently ~20)
3. **Lines of code**: <1000 (currently ~3300)
4. **Frame drops**: Zero (currently possible)
5. **sync draw()**: No await, no Promise, returns immediately (post-and-forget
   to worker)
6. **Main thread free**: All GPU work on worker, UI never blocked
7. **Tree-shakeable**: Importing only `pngine` + `draw` excludes animation code
8. **Zero console.log in production**: All logging gated by debug flag
