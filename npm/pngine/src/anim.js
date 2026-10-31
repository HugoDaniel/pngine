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
 * One entry of a draw's `buffers` map: bytes for a buffer, by its SJON name.
 * @typedef {ArrayBufferView|ArrayBuffer} Bytes
 * @typedef {{ bytes: Bytes, offset?: number, poolIndex?: number|"active" }} BufferWrite
 */

/**
 * Take the host state stored for "the next draw, whoever posts it"
 * (setUniform/setUniforms/writeBuffer with `redraw: false`) and merge the
 * draw's own map over it — the draw's entry wins on a shared name, being the
 * later intent. The store is cleared: it rode this message.
 * @param {any} i
 * @param {"pendingUniforms"|"pendingBuffers"} key
 * @param {object|undefined} own
 */
function takePending(i, key, own) {
  const pending = i[key];
  i[key] = null;
  if (!pending) return own ?? null;
  return own ? { ...pending, ...own } : pending;
}

/**
 * A frame reference is a `(frame :name …)` string, or null for the
 * executor's own choice (its first frame, or the animation table's scene).
 * Anything else is the caller's bug: a TypeError here, before anything
 * posts, the way writeBuffer treats bytes that are not bytes.
 * @param {unknown} frame
 * @returns {string|null}
 */
function checkFrame(frame) {
  if (frame !== null && typeof frame !== "string") throw new TypeError(`frame must be a (frame :name …) string or null, got ${String(frame)}`);
  return frame;
}

/**
 * A time is a finite number of seconds — zero and negative included. NaN,
 * an Infinity or a string would reach the executor as an f32 nobody meant,
 * so it is the caller's bug, refused the way a bad frame is.
 * @param {unknown} time
 * @returns {number}
 */
function checkTime(time) {
  if (typeof time !== "number" || !Number.isFinite(time)) throw new TypeError(`time must be a finite number of seconds, got ${String(time)}`);
  return time;
}

/**
 * The trailing options of setUniform/setUniforms/writeBuffer: an object or
 * nothing. The positional boolean setUniform once took (a no-op in every
 * release that had it) is refused by name, so a caller still passing it
 * learns the spelling rather than getting a draw it asked not to have.
 * @param {string} verb
 * @param {unknown} opts
 * @returns {{ redraw?: boolean, offset?: number, poolIndex?: number|"active" }}
 */
function checkOptions(verb, opts) {
  if (opts === undefined) return {};
  if (opts === null || typeof opts !== "object") throw new TypeError(`${verb}: the trailing argument is an options object, { redraw: false }, got ${String(opts)}`);
  return opts;
}

/**
 * Draw a frame (sync, post-and-forget)
 *
 * Host state rides the message: `uniforms` (reflected struct fields, by
 * name) and `buffers` (raw bytes for a `(buffer :name …)`, by name). Both
 * are applied at the head of the frame this draw renders, before its own
 * queue ops run, and the worker never collapses a draw that carries either
 * (a superseded rAF draw is dropped; one with host state is not).
 *
 * `frame` names which `(frame …)` this ONE draw renders; it does not move
 * the pin setFrame holds. Absent, the draw carries the pin (null when none,
 * which is the executor's own choice).
 *
 * Every verb here has the one shape: arguments that are the wrong kind are a
 * TypeError before anything else happens (the call is the bug, whatever the
 * handle's state); a destroyed handle returns `p` and posts nothing; the
 * verb returns `p`. draw used to be the one exception on both counts.
 *
 * @param {Pngine} p
 * @param {Object} [opts]
 * @param {number} [opts.time]
 * @param {string|null} [opts.frame] - The frame this draw renders, or null
 *   for the executor's choice; absent → the pin from setFrame
 * @param {Object} [opts.uniforms]
 * @param {Record<string, Bytes|BufferWrite>} [opts.buffers]
 * @returns {Pngine}
 */
export function draw(p, opts = {}) {
  if (opts.time !== undefined) checkTime(opts.time);
  if (opts.frame !== undefined) checkFrame(opts.frame);
  const i = p._;
  if (!i) return p;

  const time = opts.time ?? i.pb.time;
  const frame = opts.frame !== undefined ? opts.frame : i.pb.frame;

  // An explicit time is recorded as the instance's time (what p.time reads).
  if (opts.time !== undefined) i.pb = reduce(i.pb, { type: "DRAW", record: opts.time });

  i.worker.postMessage({
    type: "draw",
    time,
    frame,
    pointer: i.pointer ?? null,
    uniforms: takePending(i, "pendingUniforms", opts.uniforms),
    buffers: takePending(i, "pendingBuffers", opts.buffers),
  });

  // Reset pointer deltas and scroll after each frame
  if (i.pointer) { i.pointer[4] = 0; i.pointer[5] = 0; i.pointer[9] = 0; i.pointer[10] = 0; }
  return p;
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

  // The clock runs unbounded: nothing ends the loop but pause/stop/destroy.
  const loop = () => {
    if (!i.pb.playing) return;
    i.pb = reduce(i.pb, { type: "TICK", now: performance.now() });
    draw(p, { time: i.pb.time });
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
  checkTime(time);
  const i = p._;
  if (!i) return p;

  i.pb = reduce(i.pb, { type: "SEEK", now: performance.now(), time });

  if (i.audio) i.audio.seek(time);

  draw(p, { time });
  return p;
}

/**
 * Pin which `(frame :name …)` renders, by name, and draw it.
 *
 * The pin rides every later draw from anywhere — the play loop's, a seek's,
 * a host draw() — until `setFrame(p, null)` releases it, which hands the
 * choice back to the executor (its first frame, or the animation table's
 * scene). A name the payload does not define is refused on the worker
 * through options.onError as a PngineGPUError with source "set-frame",
 * naming the frames it does define; the draw still renders. A PNG whose
 * embedded executor predates the pin reports that instead, once.
 * `p.currentFrame` reads the pin back. A frame that is not a string or null
 * is a TypeError here, before anything posts.
 *
 * @param {Pngine} p
 * @param {string|null} frame - Frame name, or null to release the pin
 * @returns {Pngine}
 */
export function setFrame(p, frame) {
  checkFrame(frame);
  const i = p._;
  if (!i) return p;

  i.pb = reduce(i.pb, { type: "SET_FRAME", frame });
  draw(p, { time: i.pb.time });
  return p;
}

/**
 * Set a uniform value and redraw.
 *
 * With `redraw: false` the value is stored and rides the NEXT draw from
 * anywhere — the play loop's, a seek's, a host draw() — which clears the
 * store. That is how a host batches several writes into one frame, or writes
 * every frame during play() without a before-draw hook. The option is
 * spelled as writeBuffer spells it; the positional boolean that stood here
 * was a documented no-op in every release that had it, and is now refused.
 *
 * @param {Pngine} p - PNGine instance
 * @param {string} name - Uniform field name (as declared in WGSL struct)
 * @param {number|number[]|number[][]} value - Value to set
 * @param {{ redraw?: boolean }} [opts]
 * @returns {Pngine}
 */
export function setUniform(p, name, value, opts) {
  return setUniforms(p, { [name]: value }, checkOptions("setUniform", opts));
}

/**
 * Set multiple uniforms at once. `redraw: false`: see setUniform.
 *
 * @param {Pngine} p - PNGine instance
 * @param {Object} uniforms - Map of name -> value
 * @param {{ redraw?: boolean }} [opts]
 * @returns {Pngine}
 */
export function setUniforms(p, uniforms, opts) {
  const { redraw = true } = checkOptions("setUniforms", opts);
  const i = p._;
  if (!i) return p;

  if (redraw) {
    draw(p, { time: i.pb.time, uniforms });
  } else {
    Object.assign(i.pendingUniforms ??= {}, uniforms);
  }

  return p;
}

/**
 * Put bytes in a buffer, by the `(buffer :name …)` the document declares.
 *
 * The one seam is the draw message: with `redraw` true (the default) this is
 * exactly `draw(p, { time, buffers: { [name]: { bytes, offset, poolIndex } } })`,
 * so the write lands at the head of the frame it draws. With `redraw` false
 * it is stored for the next draw from anywhere (see setUniform), and the
 * bytes are read when THAT draw is posted, not now. Every write is a copy:
 * structured clone, once, on the way to the worker — a slice out of an arena
 * is fine and the arena stays yours.
 *
 * A pooled name (`:pool N`) takes `poolIndex`: `k` for member k, `"active"`
 * for the member the coming frame reads at `:ping-pong 0`, absent for every
 * member (seeding a ping-pong state). What the runtime cannot honour — an
 * unknown name, a buffer the frame itself writes every draw, a bad pool
 * member, no `copy-dst` in its `:usage`, a misaligned or out-of-range write —
 * reaches options.onError as a PngineGPUError with source "write-buffer";
 * getBuffers(p) says which names are writable and why not. Bytes that are
 * not bytes are a TypeError here, before anything is posted.
 *
 * @param {Pngine} p
 * @param {string} name
 * @param {Bytes} bytes
 * @param {{ offset?: number, poolIndex?: number|"active", redraw?: boolean }} [opts]
 * @returns {Pngine}
 */
export function writeBuffer(p, name, bytes, opts) {
  const { offset, poolIndex, redraw = true } = checkOptions("writeBuffer", opts);
  if (!(ArrayBuffer.isView(bytes) || bytes instanceof ArrayBuffer)) throw new TypeError(`writeBuffer '${name}': bytes must be an ArrayBufferView or an ArrayBuffer`);
  if (offset !== undefined && !(Number.isInteger(offset) && offset >= 0)) throw new TypeError(`writeBuffer '${name}': offset must be a non-negative integer, got ${offset}`);
  if (poolIndex !== undefined && poolIndex !== "active" && !(Number.isInteger(poolIndex) && poolIndex >= 0)) {
    throw new TypeError(`writeBuffer '${name}': poolIndex must be a non-negative integer or "active", got ${poolIndex}`);
  }
  const i = p._;
  if (!i) return p;
  /** @type {BufferWrite} */
  const entry = { bytes };
  if (offset !== undefined) entry.offset = offset;
  if (poolIndex !== undefined) entry.poolIndex = poolIndex;

  if (redraw) {
    draw(p, { time: i.pb.time, buffers: { [name]: entry } });
  } else {
    (i.pendingBuffers ??= {})[name] = entry;
  }
  return p;
}

/**
 * The pointer source every draw posts: an ArrayLike of exactly twelve
 * numbers (the pointer-inputs layout), or null to hand the lanes back to the
 * instance's live tracking array. A wrong kind or a wrong length is a
 * TypeError before anything changes, the way every verb refuses a bad call.
 * @param {unknown} lanes
 */
function checkPointerLanes(lanes) {
  if (lanes === null) return;
  const length = typeof lanes === "object" ? /** @type {{ length?: unknown }} */ (lanes).length : undefined;
  if (typeof length !== "number") {
    throw new TypeError(`lanes must be an ArrayLike<number> of 12 numbers (pointer-inputs), or null, got ${String(lanes)}`);
  }
  if (length !== 12) throw new TypeError(`lanes must carry exactly 12 numbers (pointer-inputs), got length ${length}`);
}

/**
 * Set the pointer array every draw posts, by reference.
 *
 * `lanes` is an ArrayLike of exactly twelve numbers (the pointer-inputs
 * layout), or null to hand the lanes back to the instance's live tracking
 * array, which the listeners kept writing while a host array was installed.
 * The instance posts the array's current values on every draw and drains
 * lanes 4, 5, 9 and 10 in place after each one, the lifecycle the tracking
 * array already had: a host that writes its lanes between draws never calls
 * this again, and a later call replaces the source (there is no stack). The
 * verb does not draw, so the next draw from anywhere carries the new lanes.
 * A wrong kind or a wrong length is a TypeError before anything changes; a
 * destroyed handle returns `p` and changes nothing.
 *
 * @param {Pngine} p
 * @param {ArrayLike<number>|null} lanes
 * @returns {Pngine}
 */
export function setPointer(p, lanes) {
  checkPointerLanes(lanes);
  const i = p._;
  if (!i) return p;

  i.pointer = lanes === null ? (i.trackingPointer ?? null) : lanes;
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

/**
 * Restart, awaited: resolves with the instance once the worker's `restart-done`
 * echoing this call's rid says the rebuild ran — the same destroy-and-rebuild
 * `restart(p)` fires and forgets, with the answer attached.
 *
 * The use is the restart that must not overlap anything: a host re-arming a
 * piece can await this and know the renderer's reset is done before it starts
 * something of its own. `ok: true` means the worker released the old GPU
 * stack, acquired a fresh device and reloaded the bytecode — the reset is
 * complete, and draws submitted after it render on the new stack. It is NOT a
 * presentation claim: nothing here says a frame has become visible.
 *
 * The reply is correlated: each call carries a per-instance request id, and
 * only the `restart-done` echoing THAT id settles it — ridless acks (the
 * legacy restart, the viewer's self-recovery) and other requests' acks pass
 * it by. A reply that never comes rejects `restart-timeout` after the shared
 * request budget (2000 ms, post to ack, the worker's FIFO predecessors
 * included — restarts queued behind a long load pay for the queue too); a
 * late ack after that lands nowhere, on this call or a later one.
 *
 * Failure rejects with a PngineRestartError whose `code` names the case:
 * "restart-failed" — the worker skipped the rebuild (nothing initialized,
 * nothing retained) or the rebuild threw; `message` is the worker's reason.
 * "destroyed" — the instance was destroyed before the call, or by teardown
 * mid-request: a destroyed handle does not resolve vacuously the way the
 * sync verbs return `p`, because a resolved restart on a dead renderer would
 * re-create the false-READY this API exists to close. "worker-error" — the
 * worker fired an error event mid-request. A postMessage that throws rejects
 * with that error itself. Every outcome detaches the listeners, clears the
 * timer and drops the pending entry exactly once.
 *
 * The Node stubs (dist/index.cjs, dist/index.mjs) throw the browser-only
 * refusal like every other verb: there is no worker to await in Node.
 *
 * @param {Pngine} p - PNGine instance
 * @returns {Promise<Pngine>}
 */
export function restartSettled(p) {
  const i = p._;
  // Fail closed, the one deliberate break with the sync verbs' "a destroyed
  // handle returns p": restartSettled's whole product is the settle, and a
  // resolved restart on a dead renderer would re-create the false-READY this
  // API exists to close.
  if (!i) return Promise.reject(restartRefusal("destroyed", "restartSettled: the instance is destroyed"));
  // Monotonic per instance: a rid is never reused, so a late ack of an
  // earlier request can never land on a later one.
  const rid = (i.restartRid = (i.restartRid ?? 0) + 1);
  return correlatedRequest(i, { type: "restart", rid }, "restart-done", rid, p);
}

// How long a request waits for its reply before the get* queries resolve
// with their fallback — and restartSettled rejects with restart-timeout. For
// the awaited restart it is a post→ack round-trip budget: the worker handles
// one message at a time, so whatever is queued ahead of the restart is part
// of its cost.
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
 * The rejecting counterpart of workerRequest: a request whose ANSWER is the
 * product, correlated by a request id instead of matched on reply type alone.
 *
 * workerRequest resolves a fallback when its reply never comes — right for the
 * get* queries, wrong for a restart a caller awaits, whose only honest
 * non-answer is a rejection. This variant matches the reply's `type` AND its
 * `rid`, so ridless acks (the legacy restart, the viewer's self-recovery)
 * and acks of other requests pass it by, and it rejects an `ok: false` reply
 * with the worker's own message.
 *
 * @param {any} i - instance internals
 * @param {object} request - message to post (carries the rid)
 * @param {string} replyType - `type` of the reply to wait for
 * @param {number} rid - the request id the reply must echo
 * @param {Pngine} resolvesWith - what the promise resolves with on ok:true
 * @returns {Promise<Pngine>}
 */
function correlatedRequest(i, request, replyType, rid, resolvesWith) {
  const worker = i.worker;
  const pending = (i.pendingRequests ??= new Set());
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (settle, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      pending.delete(abandon);
      worker.removeEventListener("message", handler);
      worker.removeEventListener("error", crash);
      worker.removeEventListener("messageerror", crash);
      settle(value);
    };
    // destroy() drives this for every request still in flight, the same
    // registry workerRequest's abandons live in. Where those answer the
    // fallback, an awaited restart's only honest destroy answer is a
    // rejection: no reply can arrive once the worker is terminated.
    const abandon = () => finish(reject, restartRefusal("destroyed", `${request.type} request abandoned: the instance was destroyed`));
    const handler = (e) => {
      const d = e.data;
      if (d?.type !== replyType || d.rid !== rid) return;
      if (d.ok === true) finish(resolve, resolvesWith);
      else finish(reject, restartRefusal("restart-failed", d.message || `${replyType} reported failure without a message`));
    };
    // A worker that died mid-request can never ack it. These port-level
    // listeners fire beside routeWorkerMessages' onerror property — hearing
    // the crash here rejects the awaiting caller now instead of at the
    // budget.
    const crash = (e) => finish(reject, restartRefusal("worker-error", (e && e.message) || "worker error"));
    // The budget the get* requests share, rejecting here instead of resolving
    // a fallback: an awaited restart has no honest default answer.
    const timer = setTimeout(
      () => finish(reject, restartRefusal("restart-timeout", `${request.type} round trip exceeded ${REQUEST_TIMEOUT_MS} ms (post to ack, FIFO predecessors included)`)),
      REQUEST_TIMEOUT_MS,
    );
    worker.addEventListener("message", handler);
    worker.addEventListener("error", crash);
    worker.addEventListener("messageerror", crash);
    pending.add(abandon);
    try {
      worker.postMessage(request);
    } catch (err) {
      // The post itself refused (an uncloneable payload, a closed port):
      // the caller hears that error, and nothing of the request survives.
      finish(reject, err);
    }
  });
}

/**
 * A restartSettled rejection: an Error carrying the machine-readable `code`
 * its contract names, so a host can switch on the failure rather than parse
 * the message.
 *
 * @typedef {Error & {code?: string}} RestartRefusal
 * @param {string} code
 * @param {string} message
 */
function restartRefusal(code, message) {
  const err = /** @type {RestartRefusal} */ (new Error(message));
  err.name = "PngineRestartError";
  err.code = code;
  return err;
}

/**
 * Every reflected uniform field by name: its type as WGSL spells it, the
 * `(buffer :name …)` it lives in (null for a payload minted before the
 * buffer-name block), its byte offset and size, and its array length (0 for
 * a scalar/vector/matrix field).
 *
 * @param {Pngine} p - PNGine instance
 * @returns {Promise<Object>} - Map of name -> {type, size, buffer, offset, elemCount}
 */
export function getUniforms(p) {
  const i = p._;
  if (!i) return Promise.resolve({});
  return workerRequest(i, { type: "getUniforms" }, "uniforms", (d) => d.uniforms || {}, {});
}

/**
 * The document's buffers, by name: `{ size, usage, writable, pool,
 * frameWritten }` each. `writable` is whether `:usage` has `copy-dst`, which
 * is what a queue write requires; `frameWritten` means the frame's own
 * queue ops write it every draw, so writeBuffer refuses it — give the host a
 * dedicated buffer instead. Empty before the payload is loaded.
 *
 * @param {Pngine} p - PNGine instance
 * @returns {Promise<Record<string, {size: number, usage: number, writable: boolean, pool: number, frameWritten: boolean}>>}
 */
export function getBuffers(p) {
  const i = p._;
  if (!i) return Promise.resolve({});
  return workerRequest(i, { type: "getBuffers" }, "buffers", (d) => d.buffers || {}, {});
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
  if (!i) return Promise.resolve(empty);
  return workerRequest(i, { type: "getStats" }, "stats", (d) => d, empty);
}
