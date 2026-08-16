// Timeline thumbnail prefetch — the dev/editor-only worker capability.
//
// Split out of worker-core so the viewer profile, which never imports this
// module, drops the whole block at bundle time (esbuild removes unimported
// modules; a runtime opt would not be tree-shakeable). The dev entry (worker.js)
// passes createPrefetch as opts.makePrefetch; the viewer entry passes nothing.
//
// `host` gives access to the worker-core spine this capability layers over:
//   env               — makeOffscreen, grabBitmap, defer, gpuTextureUsage
//   post(msg, xfer?)  — self.postMessage
//   render(t, w, h)   — the shared frame renderer (awaited)
//   getCanvas()       — the visible OffscreenCanvas (thumbnail source)
//   getGpu()          — the current command dispatcher
//   loaded()          — moduleLoaded (drain / prefetch guards)
//   debug()           — debugMode (capture-failure logging)
//   withRenderLock(fn) — serializes fn against handleDraw's live render, so a
//                        live 'draw' can never share the offscreen render
//                        target a still-in-flight prefetch render left active
//
// OWNERSHIP CONTRACT — `{type: "thumbnail", index, bitmap}`:
// the ImageBitmap is TRANSFERRED, so the worker gives up its only reference the
// moment it posts. The HOST owns it from there and MUST call `bitmap.close()`
// once it has drawn or uploaded it. An ImageBitmap holds decoded pixel memory
// that no GC pressure reliably reclaims on its own, and a scrubbing timeline
// emits one per thumb block — so a host that only drops the reference
// accumulates megabytes for the length of the session. This is the one
// lifetime rule the engine cannot enforce for its consumer; it is stated here
// because this file defines the message.

export function createPrefetch(host) {
  const { env, post } = host;

  // Seconds per thumb block. Host sets this via THUMB_SPACING whenever the
  // timeline's thumb width changes (canvas aspect toggle, etc.). Thumb index i
  // maps to render time (i + 0.5) * thumbSecondsPerBlock. Defaults to 1.0 so a
  // legacy host with no spacing message keeps the one-second-per-block behaviour.
  let thumbSecondsPerBlock = 1.0;
  let lastThumbIndex = -1;
  let thumbInFlight = false;

  // Ceiling on a thumbnail's render/eval time, mirroring the live playhead's
  // loopRenderTime clamp (preview.ts): the armed score's loop length (minus one
  // frame), or Infinity when no score/loop is armed. The host recomputes this
  // fresh on every 'prefetch' message (it can change with bpm/duration) and
  // sends it as `maxTime`. Without it, a thumb block whose nominal center time
  // lands at or past the loop boundary renders a score wrapped to ~t=0
  // (pacer.eval(L) === eval(0)) — the opening frame instead of the loop's end.
  let thumbMaxTime = Infinity;

  // Prefetch queue: thumb-block index → the pacer uniforms to apply before
  // rendering that block (null when the project has no score). Drained to an
  // offscreen canvas so prefetch renders never touch the visible canvas —
  // allowing drain during playback without flicker.
  const prefetchQueue = new Map();
  let prefetchDraining = false;
  let prefetchCanvas = null;
  let prefetchCtx = null;

  // Offscreen swap-target for thumbnail prefetch. Shares the GPUDevice so all
  // pipelines/buffers/bind groups stay valid across target swaps; the only
  // per-target variance is which context resolves the canvas-magic id. The
  // canvas survives a device loss, so reuse it across recoveries.
  function configure(device, format, alphaMode = "premultiplied") {
    const canvas = host.getCanvas();
    if (!prefetchCanvas) prefetchCanvas = env.makeOffscreen(canvas.width, canvas.height);
    prefetchCtx = prefetchCanvas.getContext("webgpu");
    prefetchCtx.configure({ device, format, alphaMode, usage: env.gpuTextureUsage.RENDER_ATTACHMENT });
  }

  // Invalidate cached thumbnails: any frames on the host belong to the previous
  // shader compilation. Called after each (re)load.
  function reset() {
    lastThumbIndex = -1;
    prefetchQueue.clear();
  }

  function destroy() {
    lastThumbIndex = -1;
    prefetchQueue.clear();
    prefetchCtx = null;
    prefetchCanvas = null;
    thumbMaxTime = Infinity;
  }

  function resize(width, height) {
    if (prefetchCanvas) {
      prefetchCanvas.width = width;
      prefetchCanvas.height = height;
    }
  }

  // Called after each live draw at time t. Emit one capture per thumb block as
  // the playhead crosses into a new one, then kick the prefetch drain.
  function afterDraw(t) {
    const idx = Math.floor(t / thumbSecondsPerBlock);
    if (idx >= 0 && idx !== lastThumbIndex && !thumbInFlight) {
      lastThumbIndex = idx;
      // Deliberately do NOT drop a pending prefetch entry for this index here.
      // This opportunistic capture grabs whatever's on the LIVE canvas the
      // instant the playhead crosses into the block — i.e. near its LEFT edge
      // — while a queued prefetch entry (if any) renders at the block's
      // CENTER time. For fast/discrete-changing content the two can show
      // visibly different frames; leaving the queued entry in place lets
      // drain() correct it (a second, later 'thumbnail' post for this index)
      // shortly after instead of caching the left-edge frame permanently.
      emitThumbnail(idx);
    }
    drain();
  }

  function handlePrefetch(data) {
    if (!host.loaded() || !Array.isArray(data.indices)) return;
    if (typeof data.maxTime === "number" && !Number.isNaN(data.maxTime)) {
      thumbMaxTime = data.maxTime;
    }
    for (const i of data.indices) {
      if (typeof i === "number" && i >= 0 && Number.isFinite(i)) {
        // Carry the score's uniforms for this index, or null when no score.
        prefetchQueue.set(i | 0, data.uniforms?.[i] ?? null);
      }
    }
    drain();
  }

  function setSpacing(data) {
    const sec = Number(data.sec);
    if (!(sec > 0) || !Number.isFinite(sec)) return;
    if (sec === thumbSecondsPerBlock) return;
    thumbSecondsPerBlock = sec;
    // Indices are tied to spacing: after a change, queued prefetches + the
    // last-emitted index point at different render times than the host expects.
    lastThumbIndex = -1;
    prefetchQueue.clear();
  }

  // Drain the queue one-at-a-time, rendering each index to the *offscreen*
  // canvas and capturing a bitmap. The visible canvas is never touched, so this
  // runs safely during playback without flicker.
  async function drain() {
    if (prefetchDraining) return;
    if (!host.loaded()) return;
    if (!prefetchCtx || !prefetchCanvas) return;
    if (prefetchQueue.size === 0) return;
    prefetchDraining = true;
    const gpu = host.getGpu();
    try {
      while (prefetchQueue.size > 0 && host.loaded()) {
        // The queue is a Map (index → uniforms): read its uniforms before delete.
        const idx = prefetchQueue.keys().next().value;
        const uniforms = prefetchQueue.get(idx);
        prefetchQueue.delete(idx);
        if (idx < 0) continue;
        // withRenderLock serializes this section against handleDraw's live
        // render: both share one mutable GPU render target (setRenderTargetContext),
        // and each incoming Worker message is its own task, so a live 'draw'
        // could otherwise be dispatched while this render is still suspended
        // awaiting the GPU, landing its commands on the offscreen prefetch
        // context (or capturing this block's frame onto the visible canvas).
        await host.withRenderLock(async () => {
          gpu.setRenderTargetContext(prefetchCtx);
          try {
            // Apply this block's score uniforms (when present) so the thumbnail
            // renders the animation's value at its center time, exactly as the
            // live frame does. null/absent leaves the shader's own defaults.
            if (uniforms) gpu.setUniforms(uniforms);
            const centerTime = Math.min((idx + 0.5) * thumbSecondsPerBlock, thumbMaxTime);
            // renderEphemeral restores the executor frame counter afterwards
            // (thumbnails must not shift ping-pong pool phase); fall back for
            // hosts built before it existed.
            await (host.renderEphemeral ?? host.render)(centerTime, prefetchCanvas.width, prefetchCanvas.height);
          } finally {
            gpu.setRenderTargetContext(null);
          }
        });
        await capturePrefetchThumbnail(idx);
        // Yield so incoming messages (draw / setPlaying / load) can preempt.
        await new Promise((r) => env.defer(r));
      }
    } finally {
      prefetchDraining = false;
    }
  }

  async function capturePrefetchThumbnail(index) {
    if (!prefetchCanvas || !prefetchCanvas.width || !prefetchCanvas.height) return;
    try {
      const bitmap = await grabScaled(prefetchCanvas);
      post({ type: "thumbnail", index, bitmap }, [bitmap]);
    } catch (err) {
      if (host.debug()) console.warn("[Worker] prefetch capture failed:", err instanceof Error ? err.message : err);
    }
  }

  async function emitThumbnail(index) {
    const canvas = host.getCanvas();
    if (!canvas || !canvas.width || !canvas.height) return;
    thumbInFlight = true;
    try {
      const bitmap = await grabScaled(canvas);
      post({ type: "thumbnail", index, bitmap }, [bitmap]);
    } catch (err) {
      if (host.debug()) console.warn("[Worker] thumbnail capture failed:", err instanceof Error ? err.message : err);
    } finally {
      thumbInFlight = false;
    }
  }

  // Capture a 90px-tall thumbnail preserving the source aspect ratio.
  function grabScaled(source) {
    const targetH = 90;
    const ratio = source.width / source.height;
    const targetW = Math.max(1, Math.round(targetH * (Number.isFinite(ratio) ? ratio : 1)));
    return env.grabBitmap(source, { resizeWidth: targetW, resizeHeight: targetH, resizeQuality: "low" });
  }

  return { configure, reset, destroy, resize, afterDraw, handlePrefetch, setSpacing, drain };
}
