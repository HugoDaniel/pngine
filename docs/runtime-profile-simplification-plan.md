# Runtime Profile Simplification Plan (Unreleased Aggressive Pass)

**Date**: 2026-02-08  
**Scope**: `npm/pngine` browser runtime profiles (`viewer`, `dev`, `core`, `executor`)

## Status update (2026-02-08)

- Phase A (contract freeze): complete.
- Phase B (compatibility alias removal): complete.
- Phase C (hard runtime split): complete.
- Phase D (gpu.js split): in progress.
- Phase E: pending.

### Phase D progress notes

- Extracted resource/pass command handling (`0x01-0x1A`) from `gpu.js` into:
  - `npm/pngine/src/gpu-resource-pass-commands.js`
- `gpu.js` now delegates those opcodes through a shared `resourcePassOps` adapter.
- `build.zig` source-copy manifests were updated so source-mode playground/website builds include the new module file.

## 1) Objective

Make the runtime model simpler, sharper, and easier to optimize by enforcing a single clear usage scenario per profile:

- `viewer` (default): minimal production player for PNG payloads with embedded executor.
- `dev`: full-feature runtime for iteration, diagnostics, and fallback paths.
- `core`: low-level integration surface.
- `executor`: payload/executor helper utilities.

This plan assumes **no release/migration constraints**. We optimize for clarity and long-term maintainability, not backward compatibility.

## 2) Why aggressive simplification is the right move now

Because the project is unreleased, this is the cheapest moment to remove accidental complexity.

1. No external compatibility debt yet.
   - There is no installed-base contract we must preserve.
   - Breaking API/internal structure now avoids shipping legacy behaviors we would have to support for years.

2. Complexity compounds faster than features.
   - Every compatibility alias, optional path, and fallback branch multiplies the test matrix.
   - Shipping first and “cleaning later” is usually more expensive than cleaning now.

3. Better optimization requires hard boundaries.
   - A lean production profile only gets lean if it has strict scope.
   - “Maybe needed” code paths in default builds prevent meaningful size and reliability improvements.

4. Team velocity improves when intent is obvious.
   - New contributors can answer “which entrypoint for which scenario?” in one sentence.
   - Documentation, examples, and support get simpler and more consistent.

5. Risk is currently low and contained.
   - We can update examples/tests/docs atomically.
   - No migration choreography, no deprecation period, no dual maintenance window.

## 3) Product shape: explicit usage scenarios

### Viewer (`pngine` / `pngine/viewer`)

Use when you want to render a PNGine PNG in production with minimal API and minimum cognitive overhead.

- Input: URL or byte data (`string | ArrayBuffer | Uint8Array | Blob`).
- Required option: `canvas`.
- Uses embedded executor from payload by default (wasm-in-wasm remains supported).
- Supports runtime interactivity via existing controls (`draw(...uniforms)`, `setUniform`, `setUniforms`, `getUniforms`, `play/pause/seek`).
- Does **not** expose `wasmUrl`, selector/image-element shortcuts, or dev-only fallback behavior.

### Dev (`pngine/dev`)

Use for local iteration and debugging.

- Includes full source resolution paths (selectors, image element flows).
- Includes fallback to shared executor (`wasmUrl`) for non-embedded payloads.
- Includes richer diagnostics and helper surface.

### Core (`pngine/core`)

Use when integrating PNGine runtime pieces into a custom rendering/app lifecycle.

- Dispatcher-centric, low-level primitives.
- Minimal policy; caller controls integration.

### Executor (`pngine/executor`)

Use for advanced tooling and manual payload/executor workflows.

- Payload parsing, executor import wiring, manual instantiation helpers.

## 4) Architectural simplification principles

1. One profile = one job.
2. No fallback branches in `viewer` that belong to `dev`.
3. Prefer deleting aliases over preserving them.
4. Keep runtime interactivity in `viewer` (uniforms/time/animation controls).
5. Split by execution responsibility, not by naming convenience.

## 5) Plan of record

### Decision log (unreleased simplification pass)

| Decision | Action | Why now |
| --- | --- | --- |
| Keep wasm-in-wasm default | Keep in `viewer` | Core product promise is self-contained PNG playback. |
| Keep runtime uniforms in viewer | Keep `draw`/`setUniform`/`getUniforms` path | Interactive scenes are a production scenario, not dev-only. |
| Remove compatibility aliases | Delete `browser` and `embedded` aliases | Unreleased project: no compatibility obligation, less confusion. |
| Keep fallback loader only in dev | Move `wasmUrl` fallback to `pngine/dev` | Keeps default path simple and predictable. |
| Keep `core` and `executor` separate | Do not merge | Different users and responsibilities. |
| No hard size budgets in this pass | Defer budgets | First make boundaries correct; optimize against stable architecture. |

### Phase A: Finalize profile contracts

1. Freeze `viewer` contract:
   - `pngine(source, { canvas, debug?, onError? })`
   - Reject dev-only options at runtime with explicit error messages.
2. Freeze `dev` as superset profile.
3. Freeze `core` naming (replace `embedded` language with `core` everywhere).
4. Keep `executor` focused on helper APIs only.

**Done when**:
- Contracts are reflected in types, README, and examples.
- No ambiguous docs about which profile to use.

### Phase B: Remove compatibility ballast

1. Remove compatibility aliases from public package surface:
   - `browser` alias (viewer duplicate).
   - `embedded` alias (core duplicate).
2. Remove any alias-specific bundler plumbing.
3. Remove compatibility wording in docs and code comments.

**Why now**:
- Unreleased project means no consumer breakage cost.
- Alias removal reduces duplicate artifacts and confusion.

**Done when**:
- `exports` map only contains canonical entrypoints.
- Dist output has only canonical files.

### Phase C: Hard split runtime paths

1. Keep separate init/worker paths for `viewer` vs `dev`.
2. Ensure viewer worker has no shared-executor fallback branch.
3. Ensure dev worker keeps fallback and diagnostics.
4. Keep embedded executor loading path first-class in viewer.

**Done when**:
- Viewer behavior fails fast on payloads without embedded executor.
- Dev handles both embedded and `wasmUrl` fallback payloads.

### Phase D: Reduce `gpu.js` surface area

`gpu.js` is likely the largest remaining opportunity.

1. Partition command handling into modules:
   - Core rendering/compute command handlers.
   - Optional/advanced handlers (video/exotic paths/debug-heavy paths).
2. Compile profile-specific dispatcher builds so viewer imports only required modules.
3. Gate debug logging and instrumentation behind compile-time constants.
4. Remove dead helper utilities after split.

**Why this matters**:
- Runtime command dispatch is hot path and size-heavy path.
- This split can reduce both parse cost and maintenance complexity.

**Done when**:
- Viewer imports only core GPU command handlers.
- Dev imports full handler set.
- No duplicated handler logic between profiles.

### Phase E: Tighten docs/examples/tests around scenarios

1. Update all top-level docs to canonical imports only.
2. Ensure examples are intentionally split:
   - “Production viewer” examples use `pngine`.
   - “Debug/fallback” examples use `pngine/dev`.
3. Add/adjust tests for scenario guarantees:
   - Viewer + embedded executor payload works.
   - Viewer interactive uniforms work.
   - Dev fallback via `wasmUrl` works.
   - Core and executor imports resolve cleanly.

**Done when**:
- Docs have no conflicting guidance.
- CI verifies profile behavior instead of just generic runtime behavior.

## 6) Interactivity in viewer: explicit answer

Viewer should support interactive scenes that require uniform inputs.

That support remains by design through existing animation/control APIs that post uniform updates to the worker before draw calls.

What viewer should guarantee:

1. Time and canvas runtime inputs continue to flow as today.
2. User-provided uniforms can be set and updated at runtime.
3. Uniform reflection (`getUniforms`) remains available for UI wiring.

What viewer should not add:

1. Dev-only source conveniences.
2. Shared executor fallback complexity.
3. Tooling-oriented executor lifecycle APIs.

## 7) Non-goals (for this pass)

1. No migration shims/deprecation timeline.
2. No hard bundle-size budgets yet.
3. No broad runtime feature expansion.

We are prioritizing correctness of profile boundaries over formal budget gates in this iteration.

## 8) Success criteria

1. A new user can choose profile correctly in under 30 seconds from README.
2. Viewer default path is single-purpose and predictable.
3. Dev remains feature-rich without contaminating viewer path.
4. Core/executor are clearly advanced APIs, not alternatives for basic playback.
5. Bundle outputs and docs map one-to-one with profile intent.

## 9) Recommended execution order

1. Contract/docs freeze (`viewer` input and profile intent).
2. Alias removal (`browser`, `embedded`).
3. Worker/runtime hard split.
4. `gpu.js` modular split.
5. Scenario-focused tests and examples.

This order minimizes rework: lock semantics first, then delete compatibility, then optimize internals.
