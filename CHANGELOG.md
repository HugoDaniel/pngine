# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and
this project adheres to [Semantic Versioning](https://semver.org/).

## [2.2.0] - 2026-08-16

The first release published from the public repositories. 2.1.0 was cut in
the repository on 2026-08-11 but never published; this release supersedes it.

### Added

- `(constant …)` specialises WGSL `override` declarations at compile time:
  the value is substituted into the module before it is validated, minified
  and shipped, so a pipeline-overridable constant costs nothing at pipeline
  creation. An `override` that nothing supplies a value for is refused by the
  compiler instead of failing at pipeline creation. `examples/pipeline_constants.sjon`.
- `validate --strict`: exit 1 on warnings. The `--json` envelope is unchanged.
- `--html` pages write a dark-mode flag into any uniform struct with a
  top-level `dark: f32` member — from `prefers-color-scheme`, overridable by
  the `pngine-dark` localStorage key, and live on change. `pngine_logo.sjon`
  flips its palette on it.
- Native `--frame`: `write_pointer_uniform`, `set_viewport`, `set_scissor_rect`,
  `copy_texture_to_texture` and `copy_buffer_to_buffer` are implemented (they
  were no-ops), and GPU validation errors print as they fire with the root
  cause first. 107 of the 122 corpus fixtures now render natively with every
  opcode implemented.
- Public repositories: `https://github.com/HugoDaniel/pngine` alongside
  `https://git.hugodaniel.com/releases/pngine.git`. The release cut carries
  the reference docs (`docs/abi.md`, `docs/architecture.md`,
  `docs/sjon-reference.md`, `docs/publishing.md`) and one commit per release.

### Fixed

- `--minify` did nothing: the option was set by every CLI call site and read
  by nothing since the previous frontend was removed. It now minifies —
  validation runs on the author's text and the payload carries the minified
  module; entry points, `@group`/`@binding` variables and uniform member names
  are preserved.
- `--flat` wrote the time data over every buffer's initial contents.
- `pngine inspect --symptom` returned slices into a dead stack frame, read
  state the frame had already cleared, and reported a bundle-only frame as
  drawless.
- `create_bind_group` used one operand for two id spaces (explicit layouts
  and `(layout auto)` pipelines); a flag now discriminates them, so a bind
  group on an explicit layout that shares a numeric id with a pipeline no
  longer resolves to the wrong one.
- WGSL type aliases are resolved through wgslender's structured tree; an
  aliased struct field no longer vanishes from the uniform table.
- The native backend treats the two stencil faces independently;
  `(stencil-back …)` no longer copies `(stencil-front …)`.
- The C ABI (`native_api.zig`) reports, frees and bounds its failure paths;
  every lowering-hook refusal names its cause and its form; `writeLeb128` is
  bounded; the `--html` used-set no longer swallows OOM into wrong output;
  `--html --unpack` renders at the same resolution as the packed page.
- Leaks and unbounded work, across the four surfaces of the second leak pass:
  - Native: per-frame wgpu references (texture views, encoders, command
    buffers, surface textures) are released each frame, and the surface and
    queue on shutdown; the C ABI no longer replays the whole payload every
    frame; the create-guard hole and the auto-layout leak are closed.
  - Executor: `exec_pass_once` runs once per loaded payload, per pass id —
    restoring a frame counter of 0 no longer re-seeds the scene; the command
    buffer's `cmd_count` and `total_len` always describe the same commands, and
    an overflow is reported instead of tearing the stream.
  - Compiler: allocation failure unwinds clean at every point; `:pool`, shape
    parameters, `(define …)` values and the per-frame step lists (2048 entries)
    are bounded; the data section deduplicates blobs by content, so a document
    that repeats a mesh no longer repeats its bytes; a duplicated `:init`
    entry is refused and a pass listed in both `:init` and `:perform` warns.
  - Browser runtime: the worker's message loop is a queue; default texture
    views are cached and explicit views are rebuilt on resize; a steady-state
    frame allocates nothing; the mini player releases the device, context and
    listeners on failure and on `destroy()` and no longer recreates resources
    every frame; `--html` pages stop cleanly.

### Changed

- One WGSL reflection per shader module instead of four.
- npm metadata (`repository`, `homepage`) points at
  `https://github.com/HugoDaniel/pngine`.
- Every example opens with a description of what it renders and which forms
  it exercises; the porting notes that used to sit there are gone.
- `pngine compile` no longer prints an estimated executor size when the
  executor is not embedded.

## [2.1.0] - 2026-08-11

Minor bump for two features — `-` piping and advisory WGSL lint — plus a
release-readiness sweep. 175 commits since 2.0.0, none of them recorded here
until this entry: `docs/publishing.md` predicted that slip and it happened
twice, so `sync-versions.mjs --check` now gates this heading against the
package version.

### Added

- `-` as an input path and as `-o` on every command, so `pngine` composes:
  `pngine extract art.png | pngine inspect -`. stdin is identified by its
  leading bytes (PNG signature, `PNGB`, `PK\x03\x04`, else SJON text) rather
  than by a name, `-o` defaults to stdout for a `-` input, binary output is
  refused on a terminal, and every diagnostic goes to stderr so `| jq` and
  `> file` stay clean. Input is capped at 16 MiB.
- Advisory WGSL lint in `validate` — wgslender's `@wgslender/recommended` pack
  plus its warning-severity diagnostics. Findings print as warnings, ride the
  `--json` `diagnostics` array, and never change the exit code.
  `no-unused-binding` is the one worth acting on: it catches the
  `(layout auto)` desync that otherwise surfaces only as an opaque native
  abort. `validate`-only, and compiled out on wasm.
- `getStats()` on a runtime instance: live GPU resource counts by kind,
  command buffers executed, and the executor's wasm byte count. Over a soak,
  live stays flat while executed climbs.
- 33 new examples, most of them ports of the upstream webgpu-samples set:
  clustered shading, per-pixel-linked-list OIT, progressive radiosity,
  bitonic sort, metaballs, MSDF text, skinned meshes, volume raymarching,
  GPU frustum culling with render bundles, compute mip generation, and a
  blend/sampler/wireframe comparison tier.
- Extension dispatch is case-insensitive (`SHADER.SJON` compiles).

### Fixed

- `@workgroup_size(64u)` hung the compiler and `@workgroup_size(0)` panicked
  it — a suffixed literal and a zero both fell out of the scanner's numeric
  path.
- `pngine/mini-no-audio` was built, budgeted, published and documented for
  four months while being reachable by nobody: it had no `exports` subpath,
  and `exports` blocks the deep import that would otherwise find it.
- The six platform packages published `"license": "MIT"` against a CC0-1.0
  project, and no package shipped its license text. Both fixed; 1.0.27 claimed
  the first one and only fixed `npm/pngine`.
- Expressions now evaluate in numeric *vector* slots, not just scalar ones —
  four example sims were seeding an eighth of their grid because of it.
- Resource-id indices are bounded in the native backend and in MockGPU;
  a descriptor list's count byte can no longer outrun its body; a 9th color
  attachment is rejected rather than silently dropped; `execute_bundles`
  no longer desyncs its rep-group count.
- Four silent-failure paths in the compiler now fail loudly.
- Browser runtime leaks: every instance releases what it acquires, every
  `create*` is guarded, and the auto-layout rebuild is cached. Pointer state
  in the mini player is per instance rather than module-global.
- Native backend: authored multisample state and color write masks are
  honored, and a default texture binding views all mips and layers instead of
  mip 0.

### Changed

- The release mirror publishes `git archive HEAD` instead of an rsync of the
  working tree, so untracked files and locally-excluded directories cannot
  leak into the public repo. A source-only clone now builds and passes
  `zig build drift`; `zig build test` says where the test suite lives instead
  of failing on the `tests/` that cut removes.
- `zig build drift` verifies nine generated artifacts, up from six: the
  `--html` JS fragments, the WebGPU enum snapshot, npm licence/repository
  metadata across all eight packages, and this file's newest version heading
  against the package version. Four skip cleanly, and say so, when their
  input is absent.
- `npm/publish.sh` runs the same gate set as the pre-push hook and builds
  `wasm/pngine-compiler.wasm`, which `prepublishOnly` requires and nothing
  produced — a clean-machine run used to publish six platform packages and
  then fail on the seventh.

## [2.0.0] - 2026-08-03

Major bump for two breaking changes: `.sjon` is the only source format (the
PBSF frontend is gone), and the package is ESM-first with its CommonJS entry
renamed to `dist/index.cjs`. Summarized by area rather than commit — roughly
1,000 commits since 1.0.27.

### Added

**Engine / CLI**
- Real GPU rendering for `--frame` via wgpu-native on Metal. Renders pixel-exact
  offscreen output instead of the previous placeholder. Requires `-Dgpu-native`
  (the default on a macOS host); the published npm binaries are built without it
  and `--frame` hard-errors there with rebuild instructions.
- `pngine diff a.png b.png` — pixel comparison under a shared tolerance model
  (`--preset`, `--precision`, `--max-diff`, `--json`; exit 0/1/2/4).
- `pngine inspect --deep` — WAMR-backed runtime analysis, with `--symptom`,
  `--frames`, and `--json` for diagnosing black screens and animation faults.
- Array uniforms: reflected element-typed with counts, carried through the
  bytecode uniform table and surfaced to the JS runtime via `parseUniformTable`.
- Device-limits table in the bytecode header; `--html` splices `requiredLimits`.
- Validator warning channel — `validate` now reports warnings, not just errors.
- SJON form coverage: explicit `(pipeline-layout …)` and `(texture-view …)`,
  full `GPUSamplerDescriptor` key set, texture `dimension` / `mip-level-count` /
  `depth-or-array-layers`, primitive strip index format, unclipped depth, and
  3D copy origins.

**npm package**
- Production JS bundle size gate.
- `extract` enumerates every `pNG*` chunk, closing an embed/extract asymmetry.
- Authoring subpath exports — `pngine/compiler`, `pngine/compiler-wasm`,
  `pngine/worker`, `pngine/schema/pngine.sjon` — plus the unbundled `src/`
  tree, so an external editor can consume the whole engine from `node_modules`
  instead of reaching into this repo.

**Studio** (`studio/`, not published to npm — split out to pstudio on
2026-08-04, the day after this release; it is no longer part of this repo)
- Browser editor and dashboard: live preview, timeline with audio-synced
  playback, tracker-module audio (`.it`/`.xm`/`.s3m`/`.mod`), self-contained
  `.zip` demo export, per-project frame limiter, and offline-first local
  persistence with a durable sync queue.

### Changed
- **Breaking**: the package is ESM-first (`"type": "module"`); the CommonJS
  entry moved from `dist/index.js` to `dist/index.cjs`.
- Bytecode opcode operand layouts are now driven by one wire-schema table shared
  by the emitter, scanner, and dispatcher, so they cannot drift apart.
- Cross-compiled npm binaries build `ReleaseFast` with symbols stripped
  (~52 MB → ~19 MB total).

### Removed
- **Breaking**: the PBSF frontend (`src/pbsf/`, its assembler and fixtures).
  `.sjon` is the sole source format — a `.pbsf` input no longer compiles.

### Fixed
- The shipping executor survives hostile bytecode without trapping, and native
  and reference decoders survive hostile headers and opcodes.
- `--html` and `--flat` now refuse loudly on commands they cannot express
  instead of emitting silently wrong output.
- Uniform struct field names survive the WGSL minifier.

## [1.0.27] - 2026-05-21

### Added
- SECURITY.md, CHANGELOG.md, .editorconfig
- Editor language support: LSP code actions, signature help, formatting,
  references, rename, go-to-type-definition, bracket matching, folding, and
  dot completion
- WGSL quickfix hints propagated through the validation pipeline
- Dashboard: soft-delete trash with undo, project forking, save-version tags
  with deep-linked pills
- WebGPU uncaptured errors surfaced in the editor error panel

### Fixed
- License field in npm package now matches root (CC0-1.0)
- Hardcoded Zig paths in package.json scripts
- README Zig version requirement (0.16+, was incorrectly 0.14+)
- Uniform struct field names preserved through the minifier

## [1.0.26] - 2026-04-09

### Added
- Website scaffolding with Astro + Starlight
- Gallery page with 17 live WebGPU sample demos
- Tutorials section with 4 step-by-step guides
- Playground and inspector pages

## [1.0.25] - 2026-04

### Added
- Marching cubes sample with GPU SDF compute pipeline
- Deferred rendering sample with G-buffer MRT and 128 dynamic lights
- Shadow mapping sample with depth-only pass and PCF sampling
- Primitive picking sample with r32uint format and MRT support
- Indexed mesh support with teapot and dragon shapes
- Arcball camera sample with extended pointer inputs
- Timestamp and occlusion query samples
- Stencil mask infrastructure and depth/stencil pass ops
- Sphere, torus, cone, cylinder shape generators

### Fixed
- Bind group recreation for cross-pipeline auto-layout compatibility
- `copyTextureToTexture` in queue operations
- `execute_bundles` opcode dispatch in WASM executor

## [1.0.0] - 2026-03

### Added
- DSL compiler with macro-based syntax (`#wgsl`, `#buffer`, `#renderPipeline`, `#pass`, etc.)
- PNGB bytecode format with DEFLATE compression
- PNG embedding/extraction via `pNGb` ancillary chunk
- Browser runtime with WebWorker + OffscreenCanvas
- npm package with native CLI binaries for 6 platforms
- Tailored executor embedding (self-contained PNGs)
- WGSL shader minification via miniray
- Compute shader support with ping-pong buffer/texture pools
- `#pass` sugar for fullscreen shader art
- `#data` with WASM data buffers
- Built-in shape generators (cube, plane, sphere)
- `pngineInputs`, `sceneTimeInputs`, `pointerInputs` runtime data sources
- CLI commands: compile, check, render, embed, extract
- `--frame` flag for GPU-rendered PNG output
- `--flat` flag for WASM-free flat PNG output
- `--html` flag for standalone HTML output via JS codegen
