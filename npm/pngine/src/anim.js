// Animation and playback control
// Runs on main thread, posts draw commands to worker.
//
// This is the thin impure DRIVER over the pure playback reducer
// (playback-state.js): every play/pause/time transition is computed by
// reduce(); this file only reads the clock, stores i.pb = reduce(i.pb, action),
// and performs the effects the transition implies (audio, worker draw,
// requestAnimationFrame). No playback field is written outside reduce().

import { reduce } from "./playback-state.js";

/** @typedef {import("./init-core.js").Pngine} Pngine */

/**
 * Draw a frame (sync, post-and-forget)
 *
 * When no frame is specified and animation is present, automatically
 * determines the correct frame based on time and the animation timeline.
 *
 * @param {Pngine} p
 * @param {Object} [opts]
 * @param {number} [opts.time]
 * @param {string|null} [opts.frame] - Explicit frame name, or null to let the
 *   animation timeline resolve it (what setFrame(p, null) restores)
 * @param {Object} [opts.uniforms]
 */
export function draw(p, opts = {}) {
  const i = p._;
  if (!i) throw new Error("Pngine destroyed");
  if (!i.ready) throw new Error("Not initialized");

  const time = opts.time ?? i.pb.time;
  let frame = opts.frame ?? null;

  // No explicit frame + an animation timeline: let the reducer resolve and
  // persist the scene/frame from the time. Otherwise just record the draw time.
  if (frame === null && i.animation && i.animation.scenes.length > 0) {
    i.pb = reduce(i.pb, { type: "DRAW", time, scenes: i.animation.scenes, record: opts.time });
    frame = i.pb.frame;
  } else if (opts.time !== undefined) {
    i.pb = reduce(i.pb, { type: "DRAW", time, record: opts.time });
  }

  i.worker.postMessage({
    type: "draw",
    time,
    frame,
    pointer: i.pointer ?? null,
    uniforms: opts.uniforms ?? null,
  });

  // Reset pointer deltas and scroll after each frame
  if (i.pointer) { i.pointer[4] = 0; i.pointer[5] = 0; i.pointer[9] = 0; i.pointer[10] = 0; }
}

/**
 * Start animation loop
 * @param {Pngine} p
 * @returns {Pngine}
 */
export function play(p) {
  const i = p._;
  if (!i || i.pb.playing) return p;

  i.pb = reduce(i.pb, { type: "PLAY", now: performance.now() });

  // Start audio synced with visual time
  if (i.audio) i.audio.play(i.pb.time);

  const loop = () => {
    if (!i.pb.playing) return;

    const prev = i.pb;
    const next = reduce(prev, { type: "TICK", now: performance.now(), animation: i.animation });
    i.pb = next;

    // Effects implied by the transition, diffed prev → next:
    if (prev.playing && !next.playing) {
      // endBehavior 'stop': halt at duration, draw once, don't reschedule.
      if (i.audio) i.audio.stop();
      draw(p, { time: next.time });
      return;
    }
    if (next.startedAtMs !== prev.startedAtMs) {
      // endBehavior loop/restart wrapped back to the start.
      if (i.audio) i.audio.seek(0);
    }

    draw(p, { time: next.time, frame: next.frame });
    i.animationId = requestAnimationFrame(loop);
  };

  i.animationId = requestAnimationFrame(loop);
  return p;
}

/**
 * Pause animation
 * @param {Pngine} p
 * @returns {Pngine}
 */
export function pause(p) {
  const i = p._;
  if (!i || !i.pb.playing) return p;

  i.pb = reduce(i.pb, { type: "PAUSE", now: performance.now() });

  if (i.audio) i.audio.pause();

  if (i.animationId) {
    cancelAnimationFrame(i.animationId);
    i.animationId = null;
  }

  return p;
}

/**
 * Stop animation and reset to start
 * @param {Pngine} p
 * @returns {Pngine}
 */
export function stop(p) {
  pause(p);

  const i = p._;
  if (!i) return p;

  if (i.audio) i.audio.stop();

  i.pb = reduce(i.pb, { type: "STOP", now: performance.now() });
  draw(p, { time: 0 });
  return p;
}

/**
 * Seek to specific time
 * @param {Pngine} p
 * @param {number} time - Time in seconds
 * @returns {Pngine}
 */
export function seek(p, time) {
  const i = p._;
  if (!i) return p;

  i.pb = reduce(i.pb, { type: "SEEK", now: performance.now(), time });

  if (i.audio) i.audio.seek(time);

  draw(p, { time });
  return p;
}

/**
 * Set specific frame to render
 * @param {Pngine} p
 * @param {string|null} frame - Frame name or null for all
 * @returns {Pngine}
 */
export function setFrame(p, frame) {
  const i = p._;
  if (!i) return p;

  i.pb = reduce(i.pb, { type: "SET_FRAME", frame });
  draw(p, { time: i.pb.time, frame });
  return p;
}

/**
 * Set uniform value and redraw.
 *
 * @param {Pngine} p - PNGine instance
 * @param {string} name - Uniform field name (as declared in WGSL struct)
 * @param {number|number[]} value - Value to set
 * @param {boolean} [redraw=true] - Whether to trigger immediate redraw
 * @returns {Pngine}
 */
export function setUniform(p, name, value, redraw = true) {
  const i = p._;
  if (!i) return p;

  if (redraw) {
    draw(p, { time: i.pb.time, uniforms: { [name]: value } });
  }

  return p;
}

/**
 * Set multiple uniforms at once.
 *
 * @param {Pngine} p - PNGine instance
 * @param {Object} uniforms - Map of name -> value
 * @param {boolean} [redraw=true] - Whether to trigger immediate redraw
 * @returns {Pngine}
 */
export function setUniforms(p, uniforms, redraw = true) {
  const i = p._;
  if (!i) return p;

  if (redraw) {
    draw(p, { time: i.pb.time, uniforms });
  }

  return p;
}

/**
 * Rebuild the GPU device and replay the current shader after a device loss.
 *
 * The device can be lost out from under a running instance (driver reset, TDR,
 * GPU eviction). A "PngineGPUError" with source "device-lost" is delivered to
 * options.onError when this happens. The viewer profile self-recovers; the dev
 * profile stays passive — draws become no-ops — until the host calls restart().
 * The worker acquires a fresh device and replays the last-loaded bytecode, so
 * playback (still driven by the main-thread RAF loop) resumes on its own.
 *
 * A no-op recovery is harmless: on a live device the worker simply rebuilds the
 * GPU stack from the retained bytecode.
 *
 * @param {Pngine} p - PNGine instance
 * @returns {Pngine}
 */
export function restart(p) {
  const i = p._;
  if (!i) return p;

  i.worker.postMessage({ type: "restart" });
  return p;
}

// How long a request waits for its reply before resolving with the fallback.
const REQUEST_TIMEOUT_MS = 2000;

/**
 * One request/reply round-trip with the worker.
 *
 * Both the listener and the promise are guaranteed to settle. The hand-rolled
 * version of this removed its listener ONLY when the reply arrived, so a
 * destroy (or a device loss, or a worker that threw) between the post and the
 * reply orphaned the listener and left the promise pending forever — an awaiting
 * caller's whole continuation, retained. A player torn down mid-request leaked
 * one of these per request.
 *
 * The worker reference is captured locally rather than read back through `i`,
 * because destroy() nulls that field — cleanup has to reach the same worker the
 * listener was installed on.
 *
 * @template T
 * @param {any} i - instance internals
 * @param {object} request - message to post
 * @param {string} replyType - `type` of the reply to wait for
 * @param {(data: any) => T} read - extract the result from the reply
 * @param {T} fallback - resolved value if no reply arrives
 * @returns {Promise<T>}
 */
function workerRequest(i, request, replyType, read, fallback) {
  const worker = i.worker;
  const pending = (i.pendingRequests ??= new Set());
  return new Promise((resolve) => {
    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      pending.delete(abandon);
      worker.removeEventListener("message", handler);
      resolve(value);
    };
    // destroy() calls this for every request still in flight, so teardown
    // settles them at once rather than leaving each to time out.
    const abandon = () => finish(fallback);
    const handler = (e) => {
      if (e.data?.type === replyType) finish(read(e.data));
    };
    // Backstop for a worker that is wedged but NOT destroyed — a device loss
    // mid-request, or a handler that threw before replying.
    const timer = setTimeout(abandon, REQUEST_TIMEOUT_MS);
    pending.add(abandon);
    worker.addEventListener("message", handler);
    worker.postMessage(request);
  });
}

/**
 * Get available uniform names from the loaded shader.
 * Returns a promise that resolves to an object with uniform metadata.
 *
 * @param {Pngine} p - PNGine instance
 * @returns {Promise<Object>} - Map of name -> {type, size, bufferId, offset}
 */
export function getUniforms(p) {
  const i = p._;
  if (!i || !i.ready) return Promise.resolve({});
  return workerRequest(i, { type: "getUniforms" }, "uniforms", (d) => d.uniforms || {}, {});
}

/**
 * Live resource counts for this instance — the instrument for a long-running
 * session.
 *
 * Resolves to `{gpu: {live, total, cachedBindGroups, executed}, wasmBytes,
 * frameCount, moduleLoaded, deviceLost}`, or nulls if the instance is torn down.
 * `gpu.live` counts the GPU objects the dispatcher is holding right now, by
 * kind; `wasmBytes` is the executor's WASM memory size.
 *
 * The two properties worth asserting over a soak: `gpu.live.*` stays flat as
 * `gpu.executed` climbs (nothing is created per frame), and `wasmBytes` never
 * changes (the shipped executor has no allocator at all, so growth there would
 * itself be a bug).
 *
 * @param {Pngine} p - PNGine instance
 * @returns {Promise<Object>}
 */
export function getStats(p) {
  const i = p._;
  const empty = { gpu: null, wasmBytes: 0, frameCount: 0, moduleLoaded: false, deviceLost: false };
  if (!i || !i.ready) return Promise.resolve(empty);
  return workerRequest(i, { type: "getStats" }, "stats", (d) => d, empty);
}
