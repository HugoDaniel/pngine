// Pure playback state machine — the single owner of all play/pause/time math.
//
// State: { playing, time, startedAtMs, scene, frame }
//   startedAtMs is the performance.now() baseline chosen so that
//     startedAtMs = nowMs - time*1000   ⇒   a TICK(nowMs) recovers `time`.
// anim.js is a thin driver: it reads the clock, dispatches actions here, then
// performs the effects (audio, worker draw, requestAnimationFrame) implied by
// the state transition. No playback field is written outside reduce().
//
// BUNDLE CONTRACT: this file is TEXTUALLY inlined into the viewer/dev bundles
// (buildInlinedProfileBundle → stripImports(stripExports)), concatenated before
// anim.js. It must stay functions-only — a top-level const/let would collide
// with the other inlined modules' privates in the merged scope. Action types
// are string literals inline for exactly this reason.

// Fresh stopped machine. A new object each call so nothing shares mutable state.
export function initialPlayback() {
  return { playing: false, time: 0, startedAtMs: 0, scene: null, frame: null };
}

// Find the scene whose [startMs, endMs) window contains timeMs; past the end
// return the last scene (hold semantics), or null when there are no scenes.
export function findSceneAtTime(scenes, timeMs) {
  if (!scenes || scenes.length === 0) return null;
  for (const scene of scenes) {
    if (timeMs >= scene.startMs && timeMs < scene.endMs) return scene;
  }
  return scenes[scenes.length - 1];
}

// The end-of-timeline transition, shared by TICK (composed with a scene switch)
// and the standalone END_BEHAVIOR action. Caller guarantees time >= duration.
// Returns only the fields that change so callers can spread it over state.
function applyEndBehavior(behavior, now, duration) {
  switch (behavior) {
    case "loop":
    case "restart":
      return { time: 0, startedAtMs: now };
    case "stop":
      return { time: duration, playing: false };
    default: // "hold"
      return { time: duration };
  }
}

// Pure reducer: (state, action) → state. Unknown actions are the identity.
export function reduce(state, action) {
  switch (action.type) {
    case "PLAY":
      if (state.playing) return state;
      return { ...state, playing: true, startedAtMs: action.now - state.time * 1000 };

    case "PAUSE":
      if (!state.playing) return state;
      return { ...state, playing: false, time: (action.now - state.startedAtMs) / 1000 };

    case "STOP":
      return { ...state, playing: false, time: 0, startedAtMs: action.now };

    case "SEEK":
      return {
        ...state,
        time: action.time,
        startedAtMs: state.playing ? action.now - action.time * 1000 : state.startedAtMs,
      };

    case "TICK": {
      let { playing, time, startedAtMs, scene, frame } = state;
      time = (action.now - startedAtMs) / 1000;
      const anim = action.animation;
      if (anim) {
        const duration = anim.duration / 1000;
        if (time >= duration) {
          const e = applyEndBehavior(anim.endBehavior, action.now, duration);
          time = e.time;
          if (e.startedAtMs !== undefined) startedAtMs = e.startedAtMs;
          if (e.playing === false) {
            // 'stop' halts here without a scene switch (old loop returned early).
            return { ...state, playing: false, time, startedAtMs };
          }
        }
        const s = findSceneAtTime(anim.scenes, time * 1000);
        if (s) { scene = s; frame = s.frame; }
      }
      return { ...state, playing, time, startedAtMs, scene, frame };
    }

    case "END_BEHAVIOR":
      if (state.time < action.duration) return state;
      return { ...state, ...applyEndBehavior(action.behavior, action.now, action.duration) };

    case "DRAW": {
      let { scene, frame } = state;
      if (action.scenes && action.scenes.length) {
        const s = findSceneAtTime(action.scenes, action.time * 1000);
        if (s) { scene = s; frame = s.frame; }
      }
      const time = action.record !== undefined ? action.record : state.time;
      return { ...state, time, scene, frame };
    }

    case "SET_FRAME":
      return { ...state, frame: action.frame };

    default:
      return state;
  }
}
