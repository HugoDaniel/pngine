// Shared worker orchestration for the dev (worker.js) and viewer
// (worker-viewer.js) worker threads. Both own WebGPU + the WASM executor + GPU
// resources; this module holds the message-handling spine they share. The thin
// entry files supply the browser environment (`env`) and pick which
// capabilities are active (`opts`).
//
// The worker profiles are esbuild --bundle entries (scripts/bundle.js
// buildWorkerBundle imports gpu.js + loader.js + the worker file), so this
// import is resolved at bundle time — no textual-concatenation caveat like the
// main-thread init inlining.
//
// Every browser / non-deterministic surface is injected through `env` so the
// spine is unit-testable in node (tests/npm/worker-core.test.js):
//   postMessage(msg, transfer?)         — self.postMessage
//   gpu                                 — navigator.gpu (requestAdapter, getPreferredCanvasFormat)
//   makeDispatcher(device, context)     — createCommandDispatcher (a recording fake in tests)
//   instantiate(bytes, imports)         — WebAssembly.instantiate
//   instantiateStreaming(resp, imports) — WebAssembly.instantiateStreaming (allowWasmUrl only)
//   fetchWasm(url)                      — fetch (allowWasmUrl only)
//   makeOffscreen(w, h)                 — new OffscreenCanvas (prefetch only)
//   grabBitmap(source, opts)            — createImageBitmap (prefetch only)
//   now()                               — Date.now (selfRecover cooldown)
//   defer(fn)                           — setTimeout(fn, 0) yield (prefetch only)
//   gpuTextureUsage                     — GPUTextureUsage bit constants
//
// `opts`:
//   allowWasmUrl — handleInit accepts a shared wasmUrl executor fallback (dev);
//                  else only embedded-executor payloads are accepted (viewer).
//   selfRecover  — a device loss self-recovers with a cooldown (viewer); else
//                  the worker stays passive and the host orchestrates the
//                  restart via MSG.RESTART or the next load (dev).
//   makePrefetch — factory (worker-prefetch.createPrefetch) enabling timeline
//                  thumbnail prefetch + the editor-only prefetch / setPlaying /
//                  thumb-spacing messages (dev). Omitted for the viewer so the
//                  whole block is dropped from its bundle. (RESIZE is NOT
//                  gated — both profiles react to a canvas resize.)

import { createCommandDispatcher, parseUniformTable, parseDeviceLimits, requiredFeaturesFor, canvasAlphaMode } from "./gpu.js";
import { parsePayload, getExecutorImports } from "./loader.js";

// Build flag — read below to gate the wasmUrl fallback branch. The value
// normally arrives from loader.js's module-scope guard, which ESM guarantees has
// evaluated by the time this body runs (we import it above). This restates it
// locally so the coupling is a belt-and-braces detail rather than a load-bearing
// import side-effect: dropping the loader.js import for any reason would
// otherwise turn a build flag into a ReferenceError at message-handling time.
if (typeof EMBEDDED_ONLY === "undefined") globalThis.EMBEDDED_ONLY = false;

// Message types (superset of both workers; the viewer never wires the editor-
// only ones — they fall through to the "Unknown message" throw).
export const MSG = {
  INIT: "init",
  DRAW: "draw",
  LOAD: "load",
  DESTROY: "destroy",
  SET_UNIFORM: "setUniform",
  GET_UNIFORMS: "getUniforms",
  GET_STATS: "getStats",
  STATS: "stats",
  RESIZE: "resize",
  READY: "ready",
  ERROR: "error",
  UNIFORMS: "uniforms",
  PREFETCH: "prefetch",
  SET_PLAYING: "setPlaying",
  THUMB_SPACING: "thumb-spacing",
  RESTART: "restart",
  DEVICE_LOST: "device-lost",
  DEVICE_RESTORED: "device-restored",
  // Posted once handleDestroy has released the device. The host terminates on
  // it (init-core.js destroy()), which is what keeps handleDestroy reachable.
  DESTROYED: "destroyed",
};

const NO_EMBEDDED_EXECUTOR_ERROR =
  "No embedded executor in payload. Use an embedded-executor PNG payload, or use pngine/dev with wasmUrl fallback.";

// The default browser environment, wired from worker globals. Only called from
// the worker entries (never node), so the global references are safe here.
export function browserEnv() {
  return {
    postMessage: (msg, transfer) => (transfer ? self.postMessage(msg, transfer) : self.postMessage(msg)),
    gpu: navigator.gpu,
    makeDispatcher: createCommandDispatcher,
    instantiate: (bytes, imports) => WebAssembly.instantiate(bytes, imports),
    instantiateStreaming: (resp, imports) => WebAssembly.instantiateStreaming(resp, imports),
    fetchWasm: (url) => fetch(url),
    makeOffscreen: (w, h) => new OffscreenCanvas(w, h),
    grabBitmap: (source, opts) => createImageBitmap(source, opts),
    now: () => Date.now(),
    defer: (fn) => setTimeout(fn, 0),
    gpuTextureUsage: GPUTextureUsage,
  };
}

export function createWorkerHandlers(env, opts = {}) {
  const { allowWasmUrl = false, selfRecover = false, makePrefetch = null } = opts;
  const post = env.postMessage;

  let canvas, device, context, gpu, wasm, memory;
  let initialized = false;
  let moduleLoaded = false;
  // True once the current dispatcher has executed a command stream — the
  // reset key for loadBytecode (a FAILED init leaves it dirty too).
  let gpuDirty = false;
  let frameCount = 0;
  let debugMode = false;
  // Executor↔host ABI version (docs/abi.md); binaries without the export are v1.
  let abiVersion = 1;
  // Last WebGPU uncaptured-error message; dedupes per-frame repeats so the
  // editor's panel gets one postMessage per distinct failure. Reset on load.
  let lastUncapturedError = null;
  // Last command-stream error (gpu.js onError: unknown opcode / empty descriptor)
  // OR a non-zero frame() status. Same per-frame dedupe as lastUncapturedError so
  // a persistently-malformed stream posts one message per distinct fault, not one
  // every RAF. Reset on device setup + load.
  let lastCommandError = null;
  // True while the GPUDevice is lost: draws/prefetch become no-ops so we stop
  // submitting to a dead device. Cleared when a fresh device is acquired.
  let deviceLost = false;
  // Most recent bytecode, retained so device-loss recovery can rebuild every
  // GPU resource on a fresh device without the host re-sending it.
  let lastBytecode = null;
  let uniformMap = null;

  // Normalize a posted payload (ArrayBuffer or view) to a Uint8Array for parsing.
  const toU8 = (b) => (b instanceof Uint8Array ? b : new Uint8Array(b));

  // Self-recovery cooldown (selfRecover capability only) so a shader that
  // re-kills the GPU on reload can't loop lost↔recover.
  let lastRecoverAt = 0;
  const RECOVER_COOLDOWN_MS = 4000;

  // Timeline thumbnail prefetch (dev only) — a separately-bundled capability the
  // viewer never imports. Built below once the spine functions exist.
  let prefetch = null;

  // Serializes every render()-and-render-target-sensitive section. handleDraw
  // (the live playhead) and worker-prefetch's drain() (offscreen thumbnails)
  // both call the shared render() → gpu.execute(), which resolves gpu.js's
  // single mutable `targetCtx` (set via setRenderTargetContext). Each incoming
  // Worker message is its own task, so a live 'draw' can be dispatched WHILE a
  // prefetch render is still suspended awaiting the GPU — landing its commands
  // on whichever context drain() last set, and vice versa. This FIFO lock
  // ensures only one of {live draw, prefetch render} ever holds the render
  // target at a time.
  let renderLock = Promise.resolve();
  function withRenderLock(fn) {
    const run = renderLock.then(fn, fn);
    renderLock = run.then(
      () => {},
      () => {},
    );
    return run;
  }

  // Build a fresh command dispatcher and (re)apply the 5 setters. Shared by
  // setupGpuStack and loadBytecode's reload reset — the block that was copied
  // four times across the two workers.
  function wireDispatcher() {
    gpu = env.makeDispatcher(device, context);
    gpu.setDebug(debugMode);
    if (memory) gpu.setMemory(memory); // null at first init; handleInit binds it post-executor
    gpu.setCanvasSize(canvas.width, canvas.height);
    gpu.setOnShaderError((err) => { post({ type: "shader-error", ...err }); });
    gpu.setOnError((err) => {
      if (err.message === lastCommandError) return;
      lastCommandError = err.message;
      console.error("[Worker] GPU command error:", err.message);
      post({ type: "gpu-error", ...err });
    });
    gpu.setOnQueryResult((results) => { post({ type: "queryResult", data: results }); });
  }

  // Acquire a GPUDevice, wire its error/lost handlers, configure the visible
  // (+ prefetch) contexts, and build a fresh dispatcher. Shared by first init
  // and device-loss recovery: the executor + OffscreenCanvas survive a loss.
  async function setupGpuStack(bytecode) {
    const adapter = await env.gpu?.requestAdapter();
    if (!adapter) throw new Error("WebGPU not supported");

    // Opportunistically request every optional feature the adapter supports so a
    // bytecode using a feature-gated value (tier1 16-bit formats, bgra8 srgb,
    // depth32float-stencil8, dual-source blend) renders wherever hardware allows.
    const descriptor = { requiredFeatures: requiredFeaturesFor(adapter) };

    // Authored device limits (flags bit 2) are REQUIREMENTS, unlike the
    // opportunistic features above — pass them VERBATIM into requestDevice. An
    // unsatisfiable limit rejects requestDevice → the loud error surface (dispatch
    // catch → MSG.ERROR). No clamping to the adapter (§5.3b fail-loud).
    const limits = bytecode ? parseDeviceLimits(toU8(bytecode)) : null;
    if (limits) descriptor.requiredLimits = limits;

    device = await adapter.requestDevice(descriptor);
    deviceLost = false;
    lastUncapturedError = null;
    lastCommandError = null;

    // Surface WebGPU validation / OOM / internal errors to the main thread.
    // Dedupe identical consecutive messages — a single bad draw fires per-frame.
    device.onuncapturederror = (event) => {
      const message = event.error.message;
      if (message === lastUncapturedError) return;
      lastUncapturedError = message;
      console.error("[Worker] WebGPU uncaptured error:", message);
      post({ type: "gpu-error", message, source: "uncaptured" });
    };
    watchDeviceLost(device);

    context = canvas.getContext("webgpu");
    const format = env.gpu.getPreferredCanvasFormat();
    // Header flag bit 3 → "premultiplied"; no payload → the spec default.
    const alphaMode = bytecode ? canvasAlphaMode(toU8(bytecode)) : "opaque";
    context.configure({ device, format, alphaMode, usage: env.gpuTextureUsage.RENDER_ATTACHMENT | env.gpuTextureUsage.COPY_SRC });

    prefetch?.configure(device, format, alphaMode);

    wireDispatcher();
    gpuDirty = false;
  }

  // Attach a one-shot lost handler. `reason === 'destroyed'` is our own
  // device.destroy() (teardown) — ignore it. A genuine loss stops draws and
  // notifies the host. With selfRecover the worker rebuilds itself once (cooldown
  // guarded); otherwise it stays passive and the host decides when to restart.
  function watchDeviceLost(dev) {
    dev.lost
      .then((info) => {
        if (dev !== device) return; // superseded by a newer device (already recovered)
        if (info.reason === "destroyed") return; // intentional teardown
        deviceLost = true;
        console.error("[Worker] WebGPU device lost:", info.message);
        post({ type: MSG.DEVICE_LOST, message: info.message || "GPU device lost", reason: info.reason });
        if (selfRecover) {
          const nowMs = env.now();
          if (nowMs - lastRecoverAt > RECOVER_COOLDOWN_MS) {
            lastRecoverAt = nowMs;
            // Through the FIFO, like every other state change: a direct call
            // ran recovery beside the dispatch chain, and a LOAD landing while
            // it awaited its device saw `deviceLost` still true and began a
            // second one — two devices for one loss, one never destroyed.
            dispatch({ type: MSG.RESTART });
          }
        }
      })
      .catch(() => {});
  }

  // Rebuild the GPU stack on a fresh device and reload a shader — the new one if
  // supplied, else the last good bytecode — then report ready.
  //
  // The stack being replaced is RELEASED first, not abandoned: the old
  // dispatcher's destroy() closes its bitmaps, drops its tables and flips
  // `alive` so a create still suspended in it lands nowhere; the old device's
  // destroy() is a spec no-op on a lost device and frees a LIVE one — the
  // limits-exceed reload replaces a device nothing lost, and every buffer and
  // texture of the previous payload stayed allocated with it until GC.
  // `watchDeviceLost` ignores the resulting `destroyed` reason. (Third leak
  // pass, LEAK-06's edge)
  async function recoverDevice(bytecode) {
    if (!initialized) return;
    const bc = bytecode ?? lastBytecode;
    // selfRecover fires auto-recovery, which can race a loss before the first
    // load lands a bytecode — the viewer bails then; the passive (dev) path
    // rebuilds an empty stack unconditionally, matching the original workers.
    if (!bc && selfRecover) return;
    moduleLoaded = false;
    gpu?.destroy();
    gpuDirty = false;
    device?.destroy();
    await setupGpuStack(bc); // fresh device clears deviceLost; re-applies authored limits
    if (bc) await loadBytecode(bc);
    post({ type: MSG.DEVICE_RESTORED });
    post({ type: MSG.READY, frameCount, abiVersion });
  }

  async function handleInit(data) {
    if (initialized) throw new Error("Already initialized");

    canvas = data.canvas;
    debugMode = data.debug;

    // Acquire the GPU device + contexts + dispatcher (shared with device-loss
    // recovery). Memory isn't bound yet (the executor instantiates below). The
    // raw PNGB carries any authored requiredLimits, applied at device creation.
    await setupGpuStack(data.bytecode);

    let payloadInfo = null;
    let hasEmbeddedExecutor = false;
    if (data.bytecode) {
      try {
        payloadInfo = parsePayload(new Uint8Array(data.bytecode));
        hasEmbeddedExecutor = payloadInfo.hasEmbeddedExecutor;
      } catch (e) {
        // Viewer refuses anything but a valid embedded payload; dev falls back.
        const why = e instanceof Error ? e.message : String(e);
        if (!allowWasmUrl) throw new Error(`Invalid payload for viewer: ${why}`);
        if (data.debug) console.log("[Worker] Bytecode parse failed, using shared executor:", why);
      }
    } else if (!allowWasmUrl) {
      throw new Error("No payload data provided");
    }

    if (hasEmbeddedExecutor && payloadInfo.executor) {
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

      const { instance } = await env.instantiate(payloadInfo.executor, imports);
      wasm = instance.exports;
      memory = wasm.memory;
      abiVersion = wasm.getAbiVersion?.() ?? 1;
      if (data.debug) console.log("[Worker] Executor ABI version:", abiVersion);
      gpu.setMemory(memory);
      initialized = true;

      await loadBytecode(payloadInfo.payload);
    } else if (!EMBEDDED_ONLY && allowWasmUrl) {
      // Use shared executor from wasmUrl fallback (dev only). The EMBEDDED_ONLY
      // guard lets esbuild drop this whole branch (and getWasmImports) from the
      // viewer worker bundle, which is built --define:EMBEDDED_ONLY=true — the
      // same per-profile define loader.js already uses. `allowWasmUrl` still
      // gates it at runtime for the raw (un-defined) module path.
      if (!data.wasmUrl) throw new Error("wasmUrl required (no embedded executor)");

      const resp = await env.fetchWasm(data.wasmUrl);
      if (!resp.ok) throw new Error(`Failed to fetch WASM: ${resp.status}`);

      const { instance } = await env.instantiateStreaming(resp, getWasmImports());
      wasm = instance.exports;
      memory = wasm.memory;
      abiVersion = wasm.getAbiVersion?.() ?? 1;
      if (data.debug) console.log("[Worker] Executor ABI version:", abiVersion);
      gpu.setMemory(memory);
      initialized = true;

      if (data.bytecode) await loadBytecode(data.bytecode);
    } else {
      throw new Error(NO_EMBEDDED_EXECUTOR_ERROR);
    }

    post({ type: MSG.READY, width: canvas.width, height: canvas.height, frameCount, abiVersion });
  }

  async function handleLoad(data) {
    if (!initialized) throw new Error("Not initialized");
    // A load arriving while the device is lost (the user edited past the crash)
    // rebuilds the device first, then loads the NEW shader — the natural restart.
    if (deviceLost) {
      await recoverDevice(data.bytecode);
      return;
    }
    // A reload whose authored limits exceed the LIVE device's limits can't run on
    // the existing device (its pipelines would fail validation with no
    // explanation) — rebuild a fresh device with the higher requiredLimits.
    // recoverDevice → setupGpuStack re-reads the limits from this same bytecode.
    const wanted = parseDeviceLimits(toU8(data.bytecode));
    if (wanted && exceedsDeviceLimits(wanted, device.limits)) {
      await recoverDevice(data.bytecode);
      return;
    }
    // New bytecode → new failure surface; don't let a stale dedupe key silence
    // the first uncaptured / command error produced by the reloaded shader.
    lastUncapturedError = null;
    lastCommandError = null;
    await loadBytecode(data.bytecode);
    post({ type: MSG.READY, frameCount, abiVersion });
  }

  // True if any authored limit exceeds what the live device grants (undefined =
  // a name this device doesn't expose → not comparable, treated as non-exceeding;
  // it never applied to the live device and requestDevice would have rejected it).
  function exceedsDeviceLimits(wanted, deviceLimits) {
    for (const name in wanted) {
      const have = deviceLimits[name];
      if (typeof have === "number" && wanted[name] > have) return true;
    }
    return false;
  }

  // Load bytecode via the wasm_entry.zig interface: getBytecodePtr/setBytecodeLen
  // for input, init() to emit resource-creation commands, frame() to render,
  // getCommandPtr/getCommandLen for the command-buffer output.
  async function loadBytecode(bytecode) {
    // Reset GPU state if the dispatcher has executed anything. Keyed on
    // `gpuDirty`, not `moduleLoaded`: the latter is set only on SUCCESS, so a
    // load whose init stream rejected midway (an undecodable image blob, a
    // refused wasm module) left its half-filled dispatcher in place and the
    // next load ran on it — every create guard then skipped the new payload's
    // resources for ids the failed one had filled. (Third leak pass)
    if (gpuDirty) {
      gpu.destroy();
      wireDispatcher();
      gpuDirty = false;
    }
    moduleLoaded = false;
    uniformMap = null;

    // Split PNGB: bytecode (small) → bytecodePtr, data section (large) → dataPtr
    const bytecodeArray = bytecode instanceof Uint8Array ? bytecode : new Uint8Array(bytecode);
    lastBytecode = bytecodeArray; // retain so device-loss recovery can rebuild resources
    const payloadOffsets = parsePayload(bytecodeArray).offsets;
    const dataOffset = payloadOffsets.data;
    const dataEnd = payloadOffsets.wgsl;

    // Header + executor + opcodes + strings → bytecode buffer
    const bytecodePtr = wasm.getBytecodePtr();
    new Uint8Array(memory.buffer, bytecodePtr, dataOffset).set(bytecodeArray.subarray(0, dataOffset));
    wasm.setBytecodeLen(dataOffset);

    // Data section → separate data buffer (avoids bytecode buffer overflow for large payloads).
    // setDataLen is called EVERY load — with 0 for an empty section, which the
    // ABI defines as single-buffer mode — so a reload never inherits the
    // previous payload's data length.
    const dataLen = dataEnd - dataOffset;
    if (dataLen > 0) {
      const dataPtr = wasm.getDataPtr();
      new Uint8Array(memory.buffer, dataPtr, dataLen).set(bytecodeArray.subarray(dataOffset, dataEnd));
    }
    wasm.setDataLen(dataLen);

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

    // Execute the init command buffer (creates GPU resources). The dispatcher
    // is dirty from here on, whether or not the stream completes.
    const initPtr = wasm.getCommandPtr();
    const initLen = wasm.getCommandLen();
    if (initPtr && initLen > 0) {
      gpuDirty = true;
      await gpu.execute(initPtr);
    }

    // Set uniform table after resources are created (buffers exist now)
    gpu.setUniformTable(uniformMap);

    moduleLoaded = true;
    frameCount = 1;
    prefetch?.reset();

    // First frame render
    await render(0, canvas.width, canvas.height);
  }

  async function render(time, width, height) {
    gpu.setTime(time);

    const result = wasm.frame(time, width, height);
    if (result !== 0) {
      // The executor refused to build this frame's command buffer — the host was
      // never told before (console-only). Surface it as a gpu-error (deduped so a
      // persistently-failing frame posts once, not every RAF).
      const message = `frame() returned status ${result}`;
      if (message !== lastCommandError) {
        lastCommandError = message;
        console.warn("[Worker]", message);
        post({ type: "gpu-error", message, source: "frame" });
      }
      return;
    }

    const ptr = wasm.getCommandPtr();
    const len = wasm.getCommandLen();
    if (!ptr || len === 0) return;

    await gpu.execute(ptr);
  }

  async function handleDraw(data) {
    if (!initialized || !moduleLoaded || deviceLost) return;

    // Apply pointer state before rendering (if provided)
    if (data.pointer) gpu.setPointer(data.pointer);

    // Apply uniforms before rendering (if provided)
    if (data.uniforms && typeof data.uniforms === "object") {
      const count = gpu.setUniforms(data.uniforms);
      if (debugMode && count > 0) {
        console.log(`[Worker] Set ${count} uniforms`);
      }
    }

    const t = data.time ?? 0;
    await withRenderLock(() => render(t, canvas.width, canvas.height));

    // Opportunistic thumbnail emission + prefetch drain (dev capability).
    prefetch?.afterDraw(t);
  }

  function handleResize(data) {
    if (canvas) {
      canvas.width = data.width;
      canvas.height = data.height;
    }
    prefetch?.resize(data.width, data.height);
    // Rebuild canvas-bound textures (e.g. depth attachments sized to the canvas)
    // so they stay in sync with the swap chain.
    gpu?.resizeCanvasBound?.(data.width, data.height);
  }

  // Release everything this worker owns and tell the host it may terminate us.
  //
  // The ack is what makes this run at all: destroy() used to post `destroy` and
  // terminate on the very next line, which discards the undelivered message —
  // so this function was dead code on the normal path and the GPUDevice was
  // left to the browser's reclamation of the worker agent. Now the host waits
  // for MSG.DESTROYED (or a 250ms fallback), which also means the nulling below
  // is load-bearing rather than ceremony: between the ack and the terminate
  // this worker genuinely outlives its device.
  function handleDestroy() {
    moduleLoaded = false;
    initialized = false;
    uniformMap = null;
    prefetch?.destroy();
    gpu?.destroy();
    if (device) {
      device.destroy();
      device = null;
    }
    // Drop the big retained references: the executor's WASM memory (its .bss
    // arrays are the executor's entire state), the last payload, and the
    // canvas/context pair holding the OffscreenCanvas.
    gpu = null;
    wasm = null;
    memory = null;
    lastBytecode = null;
    context = null;
    canvas = null;
    prefetch = null;
    // The lock's tail retains the last render closure (canvas, dims) on a
    // worker that the destroy ack deliberately lets outlive its device.
    renderLock = Promise.resolve();
    post({ type: MSG.DESTROYED });
  }

  // Set a uniform value without triggering a draw.
  function handleSetUniform(data) {
    if (!initialized || !moduleLoaded) return;

    if (data.uniforms && typeof data.uniforms === "object") {
      gpu.setUniforms(data.uniforms);
    } else if (data.name !== undefined && data.value !== undefined) {
      gpu.setUniform(data.name, data.value);
    }
  }

  // Return the available uniform names and types.
  function handleGetUniforms() {
    if (!uniformMap) {
      post({ type: MSG.UNIFORMS, uniforms: {} });
      return;
    }

    const uniforms = {};
    for (const [name, info] of uniformMap) {
      uniforms[name] = {
        type: info.type,
        size: info.size,
        bufferId: info.bufferId,
        offset: info.offset,
        elemCount: info.elemCount,
      };
    }
    post({ type: MSG.UNIFORMS, uniforms });
  }

  // Report live GPU-resource counts + the executor's WASM memory size.
  //
  // The instrument for a long-running session: everything else the host can see
  // (heap size, frame rate) is downstream of GC timing, while these are what
  // the runtime believes it still owns. Two properties are worth asserting in a
  // soak, and both are stated here rather than inferred:
  //   • `gpu.live.*` flat across frames — the runtime creates nothing per frame.
  //   • `wasmBytes` constant — the shipped executor has NO allocator (its state
  //     is static .bss arrays, and nothing in src/ calls @wasmMemoryGrow), so a
  //     growing WASM memory is itself a bug signal, not normal churn.
  function handleGetStats() {
    post({
      type: MSG.STATS,
      gpu: gpu?.getStats?.() ?? null,
      wasmBytes: memory?.buffer?.byteLength ?? 0,
      frameCount,
      moduleLoaded,
      deviceLost,
    });
  }

  // WASM imports for the shared wasmUrl executor path (dev only).
  function getWasmImports() {
    return {
      env: {
        log: (ptr, len) => {
          const str = new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len));
          console.log("[Executor]", str);
        },
      },
    };
  }

  // Editor-only messages, active only under the prefetch capability. Returns
  // true when handled so the viewer (prefetch off) still throws on them.
  // (RESIZE is handled in the main dispatch switch for both profiles.)
  function dispatchEditorMessage(type, data) {
    switch (type) {
      case MSG.PREFETCH:
        prefetch.handlePrefetch(data);
        return true;
      case MSG.SET_PLAYING:
        // Kept for protocol compatibility; prefetch now runs during playback.
        prefetch.drain();
        return true;
      case MSG.THUMB_SPACING:
        prefetch.setSpacing(data);
        return true;
      default:
        return false;
    }
  }

  async function dispatchOne(message) {
    const { type, ...data } = message;
    try {
      switch (type) {
        case MSG.INIT:
          await handleInit(data);
          break;
        case MSG.DRAW:
          await handleDraw(data);
          break;
        case MSG.LOAD:
          await handleLoad(data);
          break;
        case MSG.RESTART:
          try {
            await recoverDevice(data.bytecode);
          } catch (err) {
            throw new Error(`GPU recovery failed: ${err instanceof Error ? err.message : String(err)}`);
          }
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
        case MSG.GET_STATS:
          handleGetStats();
          break;
        case MSG.RESIZE:
          handleResize(data);
          break;
        default:
          if (prefetch && dispatchEditorMessage(type, data)) break;
          throw new Error(`Unknown message: ${type}`);
      }
    } catch (err) {
      post({ type: MSG.ERROR, message: err instanceof Error ? err.message : String(err) });
    }
  }

  // One message at a time.
  //
  // Each Worker message is delivered as its own task, and both entries wire
  // `onmessage = (e) => dispatch(e.data)` — so two handler BODIES overlap
  // whenever the first is suspended when the second arrives. The window is
  // narrower than "any two messages" and worth naming precisely: a chain of
  // awaits that all settle as microtasks finishes before the next task is even
  // delivered, so overlap needs a genuinely async step. gpu.execute() has two
  // (create_image_bitmap 0x0B, init_wasm_module 0x30), which means any payload
  // carrying a `(texture … :data …)` suspends its load across tasks — where the
  // editor's compile-per-keystroke meets its own rAF draw loop.
  //
  // Overlap is not a scheduling nicety there. `load` runs
  // `gpu.destroy(); wireDispatcher()` underneath a suspended `await
  // gpu.execute()`, and the resumed execute keeps driving the dispatcher just
  // released — creating GPU objects into tables nothing will walk again. The
  // mirror case is quieter and worse: a second load arriving while the first
  // holds `moduleLoaded` false skips the reset branch entirely and inherits a
  // LIVE dispatcher's tables, so the payload it replaced is never released at
  // all. `withRenderLock` serializes only draw-vs-prefetch and cannot see any
  // of this.
  //
  // FIFO, and the chain never rejects — dispatchOne reports its own errors —
  // mirroring withRenderLock's shape.
  let chain = Promise.resolve();
  // Superseded rAF draws are dropped rather than rendered back-to-back once the
  // stall clears: a frame whose time has already been overtaken is work nobody
  // will see. A draw carrying `uniforms` is NEVER dropped — that state is
  // host-supplied (anim.js draw(p, {uniforms})) and the next frame does not
  // re-send it, so collapsing it would silently lose a write.
  let queuedDraws = 0;
  function dispatch(message) {
    const supersedable = message.type === MSG.DRAW && !message.uniforms;
    if (supersedable) queuedDraws++;
    const run = () => {
      if (supersedable && --queuedDraws > 0) return;
      return dispatchOne(message);
    };
    const done = chain.then(run, run);
    chain = done.then(
      () => {},
      () => {},
    );
    return done;
  }

  // Build the prefetch capability now that the spine it layers over exists.
  if (makePrefetch) {
    prefetch = makePrefetch({
      env,
      post,
      render,
      // Thumbnails must be side-effect-free: wasm.frame() advances the
      // executor's frame_counter, which IS the ping-pong pool phase, so an
      // odd number of thumbnail renders between live frames would invert
      // every pooled binding. Save/restore the counter around the render;
      // executors older than the additive setFrameCounter export keep the
      // historical drift (`wasm` is read at call time — it is null while
      // this capability is being built).
      renderEphemeral: async (t, w, h) => {
        const save = typeof wasm?.setFrameCounter === "function" ? wasm.getFrameCounter() : undefined;
        try {
          await render(t, w, h);
        } finally {
          if (save !== undefined) wasm.setFrameCounter(save);
        }
      },
      getCanvas: () => canvas,
      getGpu: () => gpu,
      loaded: () => moduleLoaded,
      debug: () => debugMode,
      withRenderLock,
    });
  }

  return { dispatch };
}
