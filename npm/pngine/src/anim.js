// Animation and playback control
// Runs on main thread, posts draw commands to worker

/**
 * Find scene at given time
 * @param {Array} scenes - Array of scene objects
 * @param {number} timeMs - Time in milliseconds
 * @returns {Object|null} - Scene object or null
 */
function findSceneAtTime(scenes, timeMs) {
  if (!scenes || scenes.length === 0) return null;

  for (const scene of scenes) {
    if (timeMs >= scene.startMs && timeMs < scene.endMs) {
      return scene;
    }
  }

  // If past all scenes, return last scene (for hold behavior)
  return scenes[scenes.length - 1];
}

/**
 * Draw a frame (sync, post-and-forget)
 *
 * When no frame is specified and animation is present, automatically
 * determines the correct frame based on time and the animation timeline.
 *
 * @param {Pngine} p
 * @param {Object} [opts]
 * @param {number} [opts.time]
 * @param {string} [opts.frame] - Explicit frame name (bypasses animation timeline)
 * @param {Object} [opts.uniforms]
 */
export function draw(p, opts = {}) {
  const i = p._;
  if (!i) throw new Error("Pngine destroyed");
  if (!i.ready) throw new Error("Not initialized");

  const time = opts.time ?? i.time;
  let frame = opts.frame ?? null;

  // If no frame specified and we have animation, determine frame from time
  if (frame === null && i.animation && i.animation.scenes.length > 0) {
    const scene = findSceneAtTime(i.animation.scenes, time * 1000);
    if (scene) {
      frame = scene.frame;
      if (scene !== i.currentScene) {
        i.currentScene = scene;
        i.currentFrame = scene.frame;
      }
    }
  }

  i.worker.postMessage({
    type: "draw",
    time,
    frame,
    uniforms: opts.uniforms ?? null,
  });

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
    let time = (now - i.startTime) / 1000;

    // Handle animation timeline if present
    if (i.animation) {
      const durationSec = i.animation.duration / 1000;

      // Check if past duration
      if (time >= durationSec) {
        switch (i.animation.endBehavior) {
          case "loop":
          case "restart":
            i.startTime = now;
            time = 0;
            break;
          case "stop":
            i.playing = false;
            i.time = durationSec;
            draw(p, { time: durationSec });
            return;
          case "hold":
          default:
            time = durationSec;
            break;
        }
      }

      // Auto-scene switching based on time
      const newScene = findSceneAtTime(i.animation.scenes, time * 1000);
      if (newScene && newScene !== i.currentScene) {
        i.currentScene = newScene;
        i.currentFrame = newScene.frame;
      }
    }

    i.time = time;
    draw(p, { time: i.time, frame: i.currentFrame });
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
  if (!i || !i.playing) return p;

  i.playing = false;
  i.time = (performance.now() - i.startTime) / 1000;

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

  i.time = 0;
  i.startTime = performance.now();
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

  if (!i.uniforms) i.uniforms = {};
  i.uniforms[name] = value;

  if (redraw) {
    draw(p, { time: i.time, uniforms: { [name]: value } });
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

  if (!i.uniforms) i.uniforms = {};
  Object.assign(i.uniforms, uniforms);

  if (redraw) {
    draw(p, { time: i.time, uniforms });
  }

  return p;
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
  if (!i || !i.ready) {
    return Promise.resolve({});
  }

  return new Promise((resolve) => {
    const handler = (e) => {
      if (e.data.type === "uniforms") {
        i.worker.removeEventListener("message", handler);
        resolve(e.data.uniforms || {});
      }
    };
    i.worker.addEventListener("message", handler);
    i.worker.postMessage({ type: "getUniforms" });
  });
}
