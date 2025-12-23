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
    let time = (now - i.startTime) / 1000;

    // Handle animation timeline if present
    if (i.animation) {
      const durationSec = i.animation.duration / 1000;

      // Check if past duration
      if (time >= durationSec) {
        switch (i.animation.endBehavior) {
          case "loop":
          case "restart":
            // Loop: reset time and continue
            i.startTime = now;
            time = 0;
            break;
          case "stop":
            // Stop: pause at end
            i.playing = false;
            i.time = durationSec;
            draw(p, { time: durationSec });
            i.log?.("Animation ended (stop)");
            return;
          case "hold":
          default:
            // Hold: stay at last frame
            time = durationSec;
            break;
        }
      }

      // Auto-scene switching based on time
      const timeMs = time * 1000;
      const newScene = findSceneAtTime(i.animation.scenes, timeMs);

      if (newScene && newScene !== i.currentScene) {
        i.currentScene = newScene;
        i.currentFrame = newScene.frame;
        i.log?.(`Scene: ${newScene.id} (frame: ${newScene.frame})`);
      }
    }

    i.time = time;
    draw(p, { time: i.time, frame: i.currentFrame });

    i.animationId = requestAnimationFrame(loop);
  };

  i.animationId = requestAnimationFrame(loop);
  i.log?.("Playing");
  return p;
}

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

/**
 * Set uniform value and redraw.
 *
 * Why use setUniform instead of draw({ uniforms })?
 * - Cleaner API for single uniform updates
 * - Stores uniforms for subsequent draws (e.g., animation loop)
 * - Can set multiple uniforms before triggering a draw
 *
 * Supported value types:
 * - number → f32
 * - [x, y] → vec2f
 * - [x, y, z] → vec3f
 * - [x, y, z, w] → vec4f
 * - 16-element array or 4x4 matrix → mat4x4f
 *
 * @param {Pngine} p - PNGine instance
 * @param {string} name - Uniform field name (as declared in WGSL struct)
 * @param {number|number[]} value - Value to set
 * @param {boolean} [redraw=true] - Whether to trigger immediate redraw
 * @returns {Pngine}
 *
 * @example
 * // Set time and color uniforms
 * setUniform(p, "time", 1.5);
 * setUniform(p, "color", [1.0, 0.0, 0.0, 1.0]);
 *
 * // Batch updates without immediate redraw
 * setUniform(p, "time", 1.5, false);
 * setUniform(p, "color", [1, 0, 0, 1], false);
 * draw(p);  // Single draw with both updates
 */
export function setUniform(p, name, value, redraw = true) {
  const i = p._;
  if (!i) return p;

  // Store for future draws
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
 *
 * @example
 * setUniforms(p, {
 *   time: 1.5,
 *   color: [1.0, 0.0, 0.0, 1.0],
 *   modelMatrix: [...16 floats...]
 * });
 */
export function setUniforms(p, uniforms, redraw = true) {
  const i = p._;
  if (!i) return p;

  // Store all for future draws
  if (!i.uniforms) i.uniforms = {};
  Object.assign(i.uniforms, uniforms);

  if (redraw) {
    draw(p, { time: i.time, uniforms });
  }

  return p;
}
