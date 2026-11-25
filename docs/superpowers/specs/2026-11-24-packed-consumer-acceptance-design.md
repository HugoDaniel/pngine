# Packed-consumer acceptance — design

**Date:** 2026-11-24 · **Status:** draft, awaiting owner approval · **Supersedes:** the
owner-carried 03.5 leg of `docs/plans/memcap/`

## Intent

Prove that a PNGine release is fit to be consumed **as a published package**, inside this
repo, without installing a downstream project.

Today nothing in the repo consumes its own packed artifacts. `npm/publish.sh --prepare`
packs, inspects and hashes them, which says the files are present and well-formed; it never
says a consumer can *use* them. The one real consumer, pstudio, lives in another repository,
pins `pngine: ^3.0.0`, and is the kind of project that may be deprecated — so making it the
gate would test a moving target and would still leave this repo unable to answer the question
on its own.

The reference is pstudio's actual usage, read from its tree, not imagined:

- `editor/main.js` — `await import('pngine/compiler')`, `createCompiler(url)`, and the two
  runtime assets addressed by the app itself (`new URL('pngine-compiler.wasm', import.meta.url)`).
- `scripts/sync-wasm.mjs` — copies `pngine.wasm` and `pngine-compiler.wasm` **out of the
  installed package** into `editor/public`, resolved through the dependency, never from a checkout.
- `editor/vite.config.js` — `pnginePlugin({ singleFile: true })` from `vite-plugin-pngine`, and
  (per its own comment) the engine resolving `pngine/compiler`, `pngine/schema/pngine.sjon?raw`
  from `node_modules`.
- It never spawns the `pngine` CLI binary, so the packed platform binaries are **not** on this
  consumer's path.

## Goals

1. One command that installs the packed tarballs into an empty home and exercises the three
   consumer doors, each failing narrowly and by name.
2. Tiered, so the cheap tiers run always and the expensive one runs when its prerequisites exist.
3. Cover the long tail a release actually breaks on: subpath exports, shipped wasm assets, the
   raw schema import, a Vite production build, `--ignore-scripts`, offline install, the
   wrapper-without-platform-binary case, and the wrapper/compiler-wasm version pairing.
4. Replace 03.5 as the release's packed-consumer evidence, and be the thing a future release
   re-runs unchanged.

## Non-goals

- Publishing anything, tagging, or touching `npm publish`.
- Testing pstudio, or reproducing an editor's UI, timeline, audio or git features.
- Executing the Windows/macOS platform binaries (no such host here); proving presence and the
  shim's refusal path is the boundary.
- Replacing `publish.sh`'s packing, licence or hash gates.

## Anti-goals (failures even if the harness is green)

- A tier that passes by reading the source tree instead of the installed package.
- A tier that silently skips when its prerequisite is absent; absence is a named skip or a red.
- A consumer fixture that has to be updated whenever an unrelated feature ships.

## Approaches considered

**A. Extend `publish.sh --prepare` to consume.** Cheap to wire, but it conflates packaging with
acceptance: prepare's job is to decide what bytes ship, and a consuming tier there makes every
pack run minutes long and tempts a skip flag that silently drops the acceptance. Rejected.

**B. A tiered fixture inside the repo (`tests/packed-consumer/`).** Installs the tarballs, then
exercises Node → compiler → browser → Vite build. Standalone, sub-second for the cheap tiers,
no network. **Chosen.**

**C. Drive pstudio in CI.** Would prove the real consumer, but it is a separate repo pinned to
`^3.0.0` (so it does not even install this candidate), it is large and Astro/pnpm-shaped, and it
is exactly the deprecation risk the owner named. Rejected as the gate; kept as the reference.

## The tiers

Everything installs from tarballs into a fresh temporary home. Nothing resolves through the
registry, and no tier may read the working tree for the artifact under test.

- **T0 — package shape (always, seconds).** Install `--offline` from a lockfile whose resolved
  URLs are the tarballs, then: every `exports` subpath imports by name; `pngine.wasm` and
  `pngine-compiler.wasm` resolve through the package and hash-equal the built files; the
  `schema/` document resolves (and through a `?raw`-equivalent read); `.d.ts` files present for
  each typed subpath; the installed version equals the candidate's; the packed file list equals
  the declared allowlist by name and count (`npm pack --json`, not the notice text).
- **T1 — compiler acceptance, Node only (always, seconds).** Through the installed
  `pngine/compiler`: a ≥1.25 MiB document compiles byte-identically twice; its PNG exceeds
  1 MiB; twenty successive edits all compile; a deliberate error returns its named diagnostic
  and the next good edit compiles again; a compiler wasm without `allocSource` is refused with
  the version-pairing message rather than a crash.
- **T2 — runtime render, browser (skips loudly without hardware).** Load a payload compiled in
  T1, draw, and assert the centre pixel through the existing `QEMUS_TEST_CDP` lane
  (`tests/e2e/qemus-test.js` precedent). A software adapter skips with the named reason; it is
  never counted as a pass.
- **T3 — the Vite build path (the door nobody consumes today).** A small app in the fixture
  that mirrors the editor's shape: `import { pngine } from 'pngine'`, `import { createCompiler } from
  'pngine/compiler'`, `import schema from 'pngine/schema/pngine.sjon?raw'`, wasm addressed with
  `new URL(...)`, built by `vite build` with `pnginePlugin()` from the packed
  `vite-plugin-pngine`. Asserts the build succeeds, the bundle contains no absolute checkout
  path, and the built page renders in the browser tier's lane.
- **Long tail, inside T0/T1 (each a named assertion, not a vibe).** `--ignore-scripts` install
  produces an identical tree; the wrapper refuses with a named remedy when the platform package
  is removed; the `dev`/`mini`/`core`/`viewer`/`executor` subpaths all resolve; importing
  `pngine/core` under plain Node (no DOM) does not throw.

## Decisions taken here (owner may override)

Settled after the builder check, with the reason its question forced:

- **Tarballs are an input, not a side effect.** The harness takes `--tarballs <dir>`
  (`publish.sh --prepare`'s staging) and, when absent, packs into a temp dir as step zero —
  the one unavoidable read of the working tree — then pins the SHA-256 of every installed
  tarball and asserts the installed tree matches those hashes. A run never silently mixes
  repacked and staged bytes.
- **Stale `dist/` is a red, not a shrug.** `dist/*.mjs` are gitignored build products that
  `drift` cannot compare, so T0 rebuilds the bundles into a temp dir with `bundle.cjs` and
  byte-compares them against `npm/pngine/dist/` before packing. Without that, every tier can
  go green on a stale `viewer`/`core`/`dev` — precisely the shipped-asset failure this exists
  to catch.
- **Tooling may come from the repo; the artifact under test may not.** T3's temp app links
  `vite` (and the plugin under test) from the repo's own `node_modules` via `file:` specs, so
  the Vite tier is hermetic and network-free. The no-registry rule binds `pngine`,
  `vite-plugin-pngine` and the platform packages — the things being accepted.
- **The heap soak is inherited.** T1 keeps a warm-then-flat `heapBytes()` assertion and
  records the high-water mark through the installed wrapper. Dropping it would supersede the
  03.5 leg while quietly discarding the one memory claim that plan existed to measure.
- **The file-list oracle is derived, with teeth.** T0 expands `files` over the packed tree and
  asserts both directions by name and count, plus an extension allowlist inside each declared
  directory (a stray `.map`, `.tsbuildinfo` or `.DS_Store` fails). A frozen 58-path manifest
  would catch strays but rot on every unrelated ship, which the anti-goals forbid.
- **Fail-closed means a named prerequisite, not a stack.** A missing build product is red with
  the exact command that produces it. `test:consumer` is not in pre-push (its prerequisites are
  tens of megabytes of cross-built binaries); it is a standalone script, and only the hardware
  browser tier may skip, by name.
- **One run, per-leg provenance.** T0/T1/T3-build run on this host; the browser legs run over
  the `QEMUS_TEST_CDP` lane from the same run (proven reachable), each leg recording which host
  and adapter produced it. A skipped browser leg is recorded as skipped, never as passed.
- Location `tests/packed-consumer/`, entrypoint `node tests/packed-consumer/run.mjs --tier=all`.
  Named `test:consumer` in the root `package.json`.
- Fixture apps are generated into the temp home from templates in the fixture directory, so no
  `node_modules` or build output is ever committed.

## Open — resolved by the owner, 2026-11-24

1. **`--publish` does not gate on the attestation.** The acceptance is advisory: it produces
   evidence a human reads before deciding to publish, and `publish.sh` neither looks for it nor
   refuses without it. Consequently there is no freshness rule to invent, no tracked attestation
   file, and no change to `publish.sh`'s control flow.
2. **Manual, on a machine like this one. No CI, ever.** No pre-push hook, no workflow file, no
   `pretest` wiring. `npm run test:consumer` is a command a person runs here before a cut, and
   its output is the record. This also settles the merged-run question by construction: the same
   run covers T0/T1/T3-build locally and the browser legs over `QEMUS_TEST_CDP`, with per-leg
   provenance printed.

Because nothing enforces it, the report must be readable and complete on its own — a person
decides from it. Every tier prints one line of verdict plus its numbers, and a run ends with an
explicit list of what was proven, what skipped, and on which host/adapter.


## Left to the builder

Exact tier internals, the temp-home layout, how the lockfile is generated, the diagnostic text
assertions, and whether T3 reuses T2's CDP helper. The plan that follows settles them.
