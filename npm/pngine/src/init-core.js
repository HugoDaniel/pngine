// Main-thread init primitives shared by the dev (init.js) and viewer
// (viewer-init.js) profiles: pointer/keyboard tracking, the Pngine POJO getter
// factory, and instance teardown.
//
// BUNDLE CONTRACT: init.js/viewer-init.js are TEXTUALLY inlined into the
// viewer/dev bundles (buildInlinedProfileBundle → stripImports(stripExports)).
// A module they import must therefore be (a) added to that concatenation before
// the init block, and (b) functions-only — a top-level const/let would collide
// with the other inlined modules' privates in the merged scope. Keep this file
// functions-only.

import { workerErrorFromMessage } from "./worker-errors.js";

// Run the worker init handshake: post `initMessage` (with `transfer`) and settle
// on the worker's `ready` reply. Shared by both profiles — the two copies of
// this were identical, and so were the two bugs in it.
//
// Every failure path TERMINATES the worker before rejecting. A rejected init
// used to leave the spawned thread alive holding its OffscreenCanvas and
// GPUDevice, with no handle left to reach it — and the editor re-inits on every
// compile, so a shader that fails init once per keystroke accumulated them.
//
// Errors arriving before the handshake settles (a shader that fails to compile
// during init) still reach options.onError; they are not init failures.
//
// Routing is handed over AT THE RESOLVE, not by the caller afterwards, and that
// is load-bearing rather than tidy. `ready` resolves this promise but both
// profiles then await the audio phase — extractAudio, then createAudioPlayer,
// where a sointu module renders the entire song during instantiation. Leaving
// these handlers installed across that window meant a worker error in it hit
// fail(): terminate the worker, then reject a promise that has already settled,
// which is a silent no-op. The host got a "ready" instance with a dead worker,
// no error delivered, and a 250ms ack timeout on every later destroy().
export function awaitWorkerReady(worker, initMessage, transfer, options) {
  return new Promise((resolve, reject) => {
    let timeout = null;
    const fail = (err) => {
      clearTimeout(timeout);
      worker.terminate();
      reject(err);
    };
    timeout = setTimeout(() => fail(new Error("Worker init timeout")), 15000);

    worker.onmessage = (e) => {
      if (e.data.type === "ready") {
        clearTimeout(timeout);
        routeWorkerMessages(worker, options);
        resolve(e.data);
      } else if (e.data.type === "error") {
        fail(new Error(e.data.message));
      } else {
        const err = workerErrorFromMessage(e.data);
        if (err && options.onError) options.onError(err);
      }
    };
    worker.onerror = (e) => fail(new Error(e.message || "Worker error"));

    worker.postMessage(initMessage, transfer);
  });
}

// Install the post-init routing: worker messages → options.onError /
// options.onQueryResult. Called by awaitWorkerReady the instant `ready`
// arrives, so there is no window in which neither this nor the init handshake
// owns the worker's messages.
//
// Repointing `onerror` is the load-bearing part. awaitWorkerReady aimed it at
// the init promise's reject; leaving it there means every worker exception
// AFTER init resolves lands on an already-settled promise, where reject() is a
// silent no-op. A worker that throws mid-animation reported nothing to the host.
export function routeWorkerMessages(worker, options) {
  worker.onmessage = (e) => {
    const err = workerErrorFromMessage(e.data);
    if (err && options.onError) options.onError(err);
    if (e.data.type === "queryResult" && options.onQueryResult) {
      options.onQueryResult(e.data.data);
    }
  };
  worker.onerror = (e) => {
    if (options.onError) options.onError(new Error(e.message || "Worker error"));
  };
}

// Attach pointer / keyboard / wheel tracking to `canvas`, filling a
// Float32Array(12) the worker reads as pointer-inputs. Must be called before
// canvas.transferControlToOffscreen(). Returns the buffer plus a `detach()`
// that removes every listener installed here.
//
// All seven listeners register through ONE AbortController, and that is
// structural rather than tidy. Five of them (the canvas pointer/wheel handlers)
// are anonymous: no reference is kept, so removeEventListener has nothing to be
// passed and they were simply unremovable. Each closes over `ptr` and `canvas`,
// so a host that retains the element — an SPA that pools canvases, a framework
// that keeps a ref — kept the whole instance's pointer state alive with it. A
// signal detaches them without giving every closure a name.
//
// Layout: x, y, clickX, clickY, dx, dy, buttons, pressure, modifiers, scrollX, scrollY, _pad
export function attachPointerTracking(canvas) {
  const ptr = new Float32Array(12);
  const ac = new AbortController();
  const signal = ac.signal;
  let lastPX = 0, lastPY = 0;
  // Modifier bitmask: 1=Shift, 2=Ctrl, 4=Alt, 8=Meta, 16=Space
  let mods = 0;
  const updateMods = (e) => {
    mods = (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0) | (mods & 16);
    ptr[8] = mods;
  };
  document.addEventListener("keydown", (e) => { if (e.code === "Space") { mods |= 16; ptr[8] = mods; } }, { signal });
  document.addEventListener("keyup", (e) => { if (e.code === "Space") { mods &= ~16; ptr[8] = mods; } }, { signal });
  canvas.addEventListener("pointerdown", (e) => {
    const r = canvas.getBoundingClientRect();
    const nx = (e.clientX - r.left) / r.width;
    const ny = (e.clientY - r.top) / r.height;
    ptr[0] = nx; ptr[1] = ny; ptr[2] = nx; ptr[3] = ny;
    ptr[6] = e.buttons; ptr[7] = e.pressure || 0.5;
    updateMods(e);
    lastPX = nx; lastPY = ny;
    // Not released explicitly: the spec auto-releases capture on pointerup and
    // pointercancel, so there is nothing left to hold after the gesture ends
    // (leak register C6 — verified, non-issue).
    canvas.setPointerCapture(e.pointerId);
  }, { signal });
  canvas.addEventListener("pointermove", (e) => {
    const r = canvas.getBoundingClientRect();
    const nx = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width));
    const ny = Math.max(0, Math.min(1, (e.clientY - r.top) / r.height));
    ptr[4] += nx - lastPX; ptr[5] += ny - lastPY;
    ptr[0] = nx; ptr[1] = ny;
    ptr[6] = e.buttons; ptr[7] = e.pressure || (e.buttons ? 0.5 : 0);
    updateMods(e);
    lastPX = nx; lastPY = ny;
  }, { passive: true, signal });
  canvas.addEventListener("pointerup", () => {
    ptr[2] = -Math.abs(ptr[2]); ptr[3] = -Math.abs(ptr[3]);
    ptr[6] = 0; ptr[7] = 0;
  }, { signal });
  canvas.addEventListener("pointercancel", () => {
    ptr[2] = -Math.abs(ptr[2]); ptr[3] = -Math.abs(ptr[3]);
    ptr[6] = 0; ptr[7] = 0;
  }, { signal });
  canvas.addEventListener("wheel", (e) => {
    e.preventDefault();
    ptr[9] += Math.sign(e.deltaX);
    ptr[10] += Math.sign(e.deltaY);
    mods = (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0) | (mods & 16);
    ptr[8] = mods;
  }, { passive: false, signal });
  return { pointer: ptr, detach: () => ac.abort() };
}

// Size the canvas backing store for HiDPI, before transferControlToOffscreen.
// Default (fixed): scale the drawing buffer by DPR and PIN the CSS box to the
// authored logical size — the historical viewer/dev contract. With
// options.autoResize the element's rendered CSS box is measured instead and the
// style is NOT pinned, so the page's own layout drives the size and
// attachAutoResize() keeps the backing store in sync. Returns logical (CSS px)
// and device (backing-store px) dimensions. Sets canvas.width/height, which the
// OffscreenCanvas then owns — so it must run before the transfer.
export function sizeCanvasForInit(canvas, options) {
  const dpr = options.dpr ?? globalThis.devicePixelRatio ?? 1;
  let logicalW = canvas.width;
  let logicalH = canvas.height;

  if (options.autoResize) {
    // Prefer the element's rendered size; fall back to its width/height
    // attributes when it isn't laid out yet (detached / display:none).
    const rect = canvas.getBoundingClientRect?.();
    if (rect && rect.width > 0 && rect.height > 0) {
      logicalW = Math.round(rect.width);
      logicalH = Math.round(rect.height);
    }
    const deviceW = Math.max(1, Math.floor(logicalW * dpr));
    const deviceH = Math.max(1, Math.floor(logicalH * dpr));
    canvas.width = deviceW;
    canvas.height = deviceH;
    // No style pin — the page's CSS owns layout; the observer tracks it.
    return { logicalW, logicalH, deviceW, deviceH };
  }

  const deviceW = Math.floor(logicalW * dpr);
  const deviceH = Math.floor(logicalH * dpr);
  canvas.width = deviceW;
  canvas.height = deviceH;
  canvas.style.width = logicalW + "px";
  canvas.style.height = logicalH + "px";
  return { logicalW, logicalH, deviceW, deviceH };
}

// Keep the worker's offscreen backing store synced to the canvas element's
// rendered size, in DEVICE pixels, whenever it changes — a responsive/relaid-out
// canvas OR a devicePixelRatio change (dragging the window to a different-DPR
// monitor). Installed on every instance: in the fixed-size default the CSS box
// is pinned so only a DPR change fires, re-sharpening the backing store without
// disturbing layout. The worker's handleResize rebuilds canvas-bound textures
// and the next draw renders at the new size. Must run AFTER
// transferControlToOffscreen. `seedW`/`seedH` are the device dims already set at
// init so the observer's first (redundant) callback is deduped; `onSize` gets
// the logical CSS-px size for the public width/height getters. Returns a
// disconnect fn, or null when ResizeObserver is unavailable.
export function attachAutoResize(canvas, worker, seedW, seedH, onSize) {
  if (typeof ResizeObserver === "undefined") return null;
  let lastW = seedW, lastH = seedH;
  const ro = new ResizeObserver((entries) => {
    const entry = entries[entries.length - 1];
    // Logical CSS content box (for the public getters).
    const cb = entry.contentBoxSize?.[0];
    const cssW = cb ? cb.inlineSize : entry.contentRect.width;
    const cssH = cb ? cb.blockSize : entry.contentRect.height;
    // Exact device pixels when the browser reports them (DPR already applied);
    // otherwise CSS px × devicePixelRatio.
    const dpb = entry.devicePixelContentBoxSize?.[0];
    const r = globalThis.devicePixelRatio ?? 1;
    const devW = Math.floor(dpb ? dpb.inlineSize : cssW * r);
    const devH = Math.floor(dpb ? dpb.blockSize : cssH * r);
    // Skip zero-sized layout (detached / display:none) — keep the last good
    // backing store; WebGPU rejects a 0-dim texture.
    if (devW < 1 || devH < 1) return;
    if (devW === lastW && devH === lastH) return;
    lastW = devW;
    lastH = devH;
    worker.postMessage({ type: "resize", width: devW, height: devH });
    onSize?.(Math.max(1, Math.round(cssW)), Math.max(1, Math.round(cssH)));
  });
  // device-pixel-content-box fires on a DPR change even when the CSS box is
  // pinned (fixed mode) — that's the re-sharpening path. Fall back to the
  // default content-box on browsers that don't support the option.
  try {
    ro.observe(canvas, { box: "device-pixel-content-box" });
  } catch {
    ro.observe(canvas);
  }
  return () => ro.disconnect();
}

/**
 * The instance handle every public function takes. Derived from createPngine
 * rather than written out, so it cannot drift from the object it describes.
 *
 * Note this is the INTERNAL view, including `_`. The published surface is
 * `PngineInstance` in the .d.ts that bundle.cjs emits, which deliberately
 * exposes only the documented read-only getters.
 *
 * @typedef {ReturnType<typeof createPngine>} Pngine
 */

// Create the Pngine POJO with read-only getters over `internal`.
//
// Every getter reads through `internal`, which destroy() empties in place. That
// is the only thing that actually releases the instance: `p._ = null` does not,
// because these closures capture the `internal` PARAMETER, not the `_` property
// — so a host holding a destroyed handle used to keep the terminated Worker,
// the canvas, the audio player and the pointer buffer reachable through it.
//
// Post-destroy reads answer null/0 rather than throwing (Decision #3): it
// matches the POJO feel of the rest of the surface, and a teardown path that
// reads `p.time` one last time should not explode.
export function createPngine(internal) {
  return {
    get width() {
      return internal.width ?? 0;
    },
    get height() {
      return internal.height ?? 0;
    },
    get isPlaying() {
      return internal.pb?.playing ?? false;
    },
    get time() {
      return internal.pb?.time ?? 0;
    },
    get frameCount() {
      return internal.frameCount ?? 0;
    },
    get animation() {
      return internal.animation;
    },
    get currentScene() {
      return internal.pb?.scene ?? null;
    },
    get currentFrame() {
      return internal.pb?.frame ?? null;
    },
    get duration() {
      // Animation duration in seconds, or 0 if no animation
      return internal.animation ? internal.animation.duration / 1000 : 0;
    },
    get audio() {
      return internal.audio;
    },

    // Internal state (for other functions)
    _: internal,
  };
}

// How long destroy() waits for the worker to acknowledge before terminating it
// anyway. A wedged or already-dead agent must never strand the thread.
const DESTROY_ACK_TIMEOUT_MS = 250;

// Destroy a pngine instance: stop the RAF loop, tear down audio, detach every
// listener, let the worker release its GPU device, and terminate it.
//
// The worker teardown is ACKNOWLEDGED, not fire-and-forget. This used to post
// `destroy` and call terminate() on the very next line — and terminate()
// discards messages that have not been delivered yet, so worker-core's
// handleDestroy (gpu.destroy() + device.destroy()) was dead code on the normal
// path. Every GPU resource an instance owned was left for the browser to
// reclaim whenever it got round to collecting the worker agent, which in a
// churning SPA means many devices' worth of GPU memory outliving their players.
//
// destroy() stays synchronous — the terminate just happens on the ack, or on a
// timer if none arrives.
export function destroy(p) {
  const i = p._;
  if (!i) return p;

  if (i.animationId) cancelAnimationFrame(i.animationId);
  if (i.disconnectResize) i.disconnectResize();
  if (i.audio) i.audio.destroy();
  if (i.detachListeners) i.detachListeners();
  // Settle every in-flight worker request (anim.js workerRequest) with its
  // fallback: no reply can arrive once we terminate, and an unsettled promise
  // retains the awaiting caller's whole continuation.
  if (i.pendingRequests) {
    for (const abandon of [...i.pendingRequests]) abandon();
    i.pendingRequests = null;
  }

  const worker = i.worker;
  if (worker) {
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      worker.terminate();
    };
    const timer = setTimeout(finish, DESTROY_ACK_TIMEOUT_MS);
    // Replaces routeWorkerMessages' handler: nothing else this instance could
    // report still has anywhere to go.
    worker.onmessage = (e) => { if (e.data?.type === "destroyed") finish(); };
    worker.onerror = finish;
    worker.postMessage({ type: "destroy" });
  }

  // Empty the bag the getters read through — this is what actually releases the
  // instance, however long the host holds `p`.
  i.worker = null;
  i.canvas = null;
  i.audio = null;
  i.pointer = null;
  i.animation = null;
  i.pb = null;
  i.detachListeners = null;
  i.disconnectResize = null;
  i.animationId = null;
  i.ready = false;
  i.width = 0;
  i.height = 0;
  i.frameCount = 0;

  p._ = null;
  return p;
}
