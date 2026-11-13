// Pure playback state machine — the single owner of all play/pause/time math.
//
// State: { playing, time, startedAtMs, frame, loop }
//   startedAtMs is the performance.now() baseline chosen so that
//     startedAtMs = nowMs - time*1000   ⇒   a TICK(nowMs) recovers `time`.
//   frame is the pin setFrame holds: a `(frame :name …)` string, or null for
//     the executor's own choice. It rides every draw message.
//   loop is the clock length in seconds, or null for unbounded. A TICK, PAUSE
//     or SEEK whose time reaches it wraps into [0, loop) with the floor form
//     below and rebases startedAtMs, so the invariant above keeps holding and
//     a tab that stalled for several periods lands inside the range in one
//     tick. DRAW records the time it was given, unwrapped.
// anim.js is a thin driver: it reads the clock, dispatches actions here, then
// performs the effects (audio, worker draw, requestAnimationFrame) implied by
// the state transition. No playback field is written outside reduce().
//
// The clock runs unbounded until a host sets a loop. There used to be an
// animation-timeline arm here —
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
  return { playing: false, time: 0, startedAtMs: 0, frame: null, loop: null };
}

// The floor form from frame-program §6.5. It stays in [0, loop) for a negative
// time, where `time % loop` goes negative; null (or a state from before the
// loop existed) is the unbounded clock.
function wrapToLoop(time, loop) {
  if (loop === null || loop === undefined) return time;
  return (time / loop - Math.floor(time / loop)) * loop;
}

// Pure reducer: (state, action) → state. Unknown actions are the identity.
export function reduce(state, action) {
  switch (action.type) {
    case "SET_LOOP": {
      const time = action.loop === null ? state.time : wrapToLoop(state.time, action.loop);
      return {
        ...state,
        loop: action.loop,
        time,
        startedAtMs: state.playing && time !== state.time ? action.now - time * 1000 : state.startedAtMs,
      };
    }

    case "PLAY":
      if (state.playing) return state;
      return { ...state, playing: true, startedAtMs: action.now - state.time * 1000 };

    case "PAUSE": {
      if (!state.playing) return state;
      const raw = (action.now - state.startedAtMs) / 1000;
      const time = wrapToLoop(raw, state.loop);
      return {
        ...state,
        playing: false,
        time,
        startedAtMs: time === raw ? state.startedAtMs : action.now - time * 1000,
      };
    }

    case "STOP":
      return { ...state, playing: false, time: 0, startedAtMs: action.now };

    case "SEEK": {
      const time = wrapToLoop(action.time, state.loop);
      return {
        ...state,
        time,
        startedAtMs: state.playing ? action.now - time * 1000 : state.startedAtMs,
      };
    }

    case "TICK": {
      const raw = (action.now - state.startedAtMs) / 1000;
      const time = wrapToLoop(raw, state.loop);
      return time === raw ? { ...state, time } : { ...state, time, startedAtMs: action.now - time * 1000 };
    }

    case "DRAW":
      return action.record !== undefined ? { ...state, time: action.record } : state;

    case "SET_FRAME":
      return { ...state, frame: action.frame };

    default:
      return state;
  }
}
