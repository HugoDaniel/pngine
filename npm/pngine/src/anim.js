// Animation and playback control
// Runs on main thread, posts draw commands to worker

/**
 * Draw a frame (sync, post-and-forget)
 * @param {Pngine} p
 * @param {Object} [opts]
 * @param {number} [opts.time]
 * @param {string} [opts.frame]
 * @param {Object} [opts.uniforms]
 */
export function draw(p, opts = {}) {
  const i = p._;
  if (!i) throw new Error("Pngine destroyed");
  if (!i.ready) throw new Error("Not initialized");

  // Post to worker (sync - returns immediately)
  i.worker.postMessage({
    type: "draw",
    time: opts.time ?? i.time,
    frame: opts.frame ?? null,
    uniforms: opts.uniforms ?? null,
  });

  // Update local time if provided
  if (opts.time !== undefined) {
    i.time = opts.time;
  }
}

/**
 * Start animation loop
 * @param {Pngine} p
 * @returns {Pngine}
 */
export function play(p) {
  const i = p._;
  if (!i || i.playing) return p;

  i.playing = true;
  i.startTime = performance.now() - i.time * 1000;

  const loop = () => {
    if (!i.playing) return;

    const now = performance.now();
    i.time = (now - i.startTime) / 1000;

    draw(p, { time: i.time });

    i.animationId = requestAnimationFrame(loop);
  };

  i.animationId = requestAnimationFrame(loop);
  i.log?.("Playing");
  return p;
}

/**
 * Pause animation
 * @param {Pngine} p
 * @returns {Pngine}
 */
export function pause(p) {
  const i = p._;
  if (!i || !i.playing) return p;

  i.playing = false;
  i.time = (performance.now() - i.startTime) / 1000;

  if (i.animationId) {
    cancelAnimationFrame(i.animationId);
    i.animationId = null;
  }

  i.log?.("Paused");
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

  i.time = 0;
  i.startTime = performance.now();

  draw(p, { time: 0 });
  i.log?.("Stopped");
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

  i.time = time;

  if (i.playing) {
    i.startTime = performance.now() - time * 1000;
  }

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

  i.currentFrame = frame;
  draw(p, { time: i.time, frame });
  return p;
}
