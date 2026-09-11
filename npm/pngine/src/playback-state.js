// Pure playback state machine — the single owner of all play/pause/time math.
//
// State: { playing, time, startedAtMs, frame }
//   startedAtMs is the performance.now() baseline chosen so that
//     startedAtMs = nowMs - time*1000   ⇒   a TICK(nowMs) recovers `time`.
//   frame is the pin setFrame holds: a `(frame :name …)` string, or null for
//     the executor's own choice. It rides every draw message.
// anim.js is a thin driver: it reads the clock, dispatches actions here, then
// performs the effects (audio, worker draw, requestAnimationFrame) implied by
// the state transition. No playback field is written outside reduce().
//
// The clock runs unbounded. There used to be an animation-timeline arm here —
// scenes resolved from the time, an end behaviour that wrapped or halted it —
// over a table the worker stopped delivering in Dec 2025 and no SJON form
// emits, so it was unreachable through pngine() for as long as it existed
// (docs/plans/archive/api-audit-2026-09.md, finding 2). The executor owns scene
// selection when a payload does carry the table.
//
// BUNDLE CONTRACT: this file is TEXTUALLY inlined into the viewer/dev bundles
// (buildInlinedProfileBundle → stripImports(stripExports)), concatenated before
// anim.js. It must stay functions-only — a top-level const/let would collide
// with the other inlined modules' privates in the merged scope. Action types
// are string literals inline for exactly this reason.

// Fresh stopped machine. A new object each call so nothing shares mutable state.
export function initialPlayback() {
  return { playing: false, time: 0, startedAtMs: 0, frame: null };
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

    case "TICK":
      return { ...state, time: (action.now - state.startedAtMs) / 1000 };

    case "DRAW":
      return action.record !== undefined ? { ...state, time: action.record } : state;

    case "SET_FRAME":
      return { ...state, frame: action.frame };

    default:
      return state;
  }
}
