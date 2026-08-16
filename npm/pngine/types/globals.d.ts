/// <reference types="@webgpu/types" />

// Ambient declarations for the identifiers `src/` reads but never defines.
//
// These are BUILD FLAGS, not variables: bundle.cjs passes them to esbuild as
// `--define:DEBUG=false`, which substitutes the literal for every bare
// occurrence and then drops the dead branches. In `src/` they are free
// identifiers, which is why they need declaring here.
//
// `var`, not `const`, because each is paired with a fallback guard that
// assigns it:
//
//     if (typeof DEBUG === "undefined") globalThis.DEBUG = false;
//
// and `globalThis.X =` only type-checks for a global `var`. The guards are not
// redundant with the define — they cover the paths that load `src/` directly
// (node tests, vite dev, any bundler not passing --define), where a bare
// `DEBUG` would otherwise be a ReferenceError on first read. Under --define
// they cost nothing: the condition folds to `typeof false === "undefined"`,
// so esbuild eliminates the guard and the assignment along with it.

/** Verbose `[GPU]`/`[Worker]` logging. Stripped from production bundles. */
declare var DEBUG: boolean;

/** pNGa audio support compiled in. False for the no-audio mini profile. */
declare var AUDIO: boolean;

/** Executor WASM must come from the payload; no `pngine.wasm` fetch fallback. */
declare var EMBEDDED_ONLY: boolean;
