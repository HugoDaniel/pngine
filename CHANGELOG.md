# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and
this project adheres to [Semantic Versioning](https://semver.org/).

## [3.0.0] - 2026-08-19

The WebGPU IDL becomes binding, and `tests/npm/webgpu-conformance.test.js`
checks it rather than asserting it. Every `required` member and every default
value in the spec's 57 descriptor dictionaries is now extracted from
`external/gpuweb` into a committed snapshot and cross-checked against
`schema/pngine.sjon` on every run. 137 spec facts that no gate could see are
now gates.

It also carries the DSL overhaul, which is the same principle applied to the
syntax: one WebGPU descriptor member is one SJON key. Bare-atom wrapper forms
(`(module M)`, `(topology T)`, `(targets …)`) are gone, and twenty-two
conditional rules the IDL states but no schema can hold are now compiler
errors with a span.

Major, because most of what that found was PNGine substituting a plausible
value for one the author never wrote, and because every `.sjon` needs
rewriting. Documents change; there are no shipped payloads to protect and none
were. `scripts/codemod-overhaul.mjs` migrates a corpus mechanically.

### Breaking

- **Required members are required.** A document that omits one is now rejected
  with a located diagnostic instead of compiled against a guess:
  `(depth-stencil :format …)`, a `(texture :size …)` (a texture that named none
  used to become 256×256 out of nowhere), a buffer's `:size` or `:data`, a
  `(render-bundle :color-formats …)`, a `(color-attachment …)`'s `:load-op`
  and `:store-op`, a stage's `:module`, and at least one `(target …)` under a
  `(fragment …)`.
- **A pipeline states its layout as a key.** `(layout auto)` becomes
  `:layout auto` — one required key over pipeline-or-`auto`, matching
  `GPUPipelineDescriptorBase.layout`, which is one required member. The
  positional form was inert (the emitter never read it), so this replaces a
  146-site ritual with a statement the validator checks.
- **Entry points are resolved, not invented.** Seven fabricated spellings
  across three runtimes (`vertexMain`, `vs_main`, `vs`, `main`, …) are gone. A
  stage with one entry point uses it; zero or many is a located error.
- **Defaults match the IDL.** Sampler `:mag-filter`/`:min-filter` default to
  `nearest`, and a canvas composites `opaque`. Both used to deviate
  deliberately (linear filtering and premultiplied alpha are friendlier for
  shader art); both meant a raw-WebGPU sample ported line for line rendered
  differently with nothing in the source saying so. Write
  `:mag-filter linear` or `(canvas :alpha-mode premultiplied)` for the old
  behaviour — `examples/pngine_background.sjon` does.
- **Clear values carry what you wrote.** `:clear-value` channels travel as f32
  per channel rather than four bytes decoding `/255`, so out-of-gamut and HDR
  clears on float targets work. Two new command opcodes (0x53/0x54) carry them;
  the 4×u8 pair is retired but still decoded, since `docs/abi.md` makes opcode
  layouts append-only. pNGf is version 2, and `mini` now reads the version byte
  it has been writing and ignoring since the format existed.
- **Texture dimensions are spelled as WebGPU spells them.** `(texture
  :dimension 3d)`, `(texture-view :view-dimension 2d-array)`, and a
  bind-group-layout `texture`/`storage-texture` `:view-dimension cube` — the
  six `GPUTextureViewDimension` values `1d 2d 2d-array cube cube-array 3d` and
  the three `GPUTextureDimension` values `1d 2d 3d`, verbatim. They were
  integer codes with a comment (`:view-dimension 3 ; cube`) because a
  digit-leading token could not be a symbol; SJON 1.2.0 lets a member-set
  spell one. The old numbers are rejected (`wrong_underlying`), and the two enums
  now sit under the same WebGPU conformance gate as every other enum in the
  schema.
- **The schema says what the emitter used to check, and a few things it
  never did** (SJON 1.2.0 vocabulary, plus the head-set counts and the
  scalar-or-reference arm SJON added after it — PNGine builds against SJON's
  main, not a release): a `(render-pipeline …)` with two
  `(vertex …)` sections, or a `(fragment …)` with no `(target …)`, or a
  `(blend (color …))` without `(alpha …)`, is a located error (the first won
  silently before; the blend died on the GPU); a render- and a
  compute-pipeline sharing a `:name` — or a render-pass, compute-pass and queue
  — is a `duplicate_cross_ref_target` at the second declaration instead of the
  bind-group binding whichever came last; a `(define …)` reference typo in a
  count slot is located instead of an unlocated "emit failed"; `write-buffer`
  and `copy-buffer-to-buffer` offsets and sizes and a `vertex-buffer`
  `:array-stride` must be multiples of 4 (`resolve-query-set` of 256), and a
  bind-group entry's `:offset`/`:size` require `:buffer`; a
  bind-group-layout `(entry …)` names exactly one resource (an entry with none
  used to become an empty `buffer` binding) and a `(data …)` at most one
  generator — those last two are counts over a whole head-set, spelled
  `:min-children` / `:max-children` and reported by the validator
  (`positional_missing` on the form's head, `positional_too_many` on the
  offending child) rather than by the emitter. Hex literals (`:write-mask 0xF`) work. SJON's advisory diagnostics (`union_ambiguous`,
  `deprecated_member`) now reach `validate` as warnings — they were dropped
  on a clean result — so `--strict` sees them.

#### The DSL is the WebGPU IDL, spelled as S-expressions

The same principle applied to the SYNTAX rather than to the defaults: one
WebGPU descriptor member is one SJON key, and a document reads like the IDL it
targets. Every `.sjon` needs migrating, and
`scripts/codemod-overhaul.mjs` does it mechanically (it is a tokenizer, not a
grep, so it leaves comments, WGSL and prose alone):

```
node scripts/codemod-overhaul.mjs <paths…>      # rewrite in place
node scripts/codemod-overhaul.mjs --check <p…>  # exit 1 if anything would change
```

- **A scalar member of a dictionary is a key.** `(module M)`, `(entry E)` and
  `(topology T)` were global forms whose only content was one bare atom. They
  are `:module`, `:entry` and `:topology`, and the three global forms are
  deleted — `entry` last, once SJON's `:produces` could name a slot-local
  head (S12); it survives only as the bind-group and bind-group-layout
  children.
- **A sequence of dictionaries is repeated children, with no wrapper.** The
  `(buffers …)` and `(targets …)` forms are gone: `(vertex-buffer …)` and
  `(target …)` are direct children of their stage. A fragment stage needs at
  least one `(target …)` — an empty list was legal WebGPU that neither of
  PNGine's backends honoured the same way.
- **A compute pipeline states its stage like the other two.** `:module`/`:entry`
  on the form become a `(compute :module … :entry …)` child, the same
  `GPUProgrammableStage` the vertex and fragment stages already were.
- **One IDL member is one key.** `GPUPipelineDescriptorBase.layout` is one
  required member, so `:layout` is one required key over pipeline-or-`auto`;
  `:pipeline-layout` is gone. A bind group's `:layout-pipeline` /
  `:layout-index` become `:layout` / `:group`.
- **A resource says its size and its bytes once.** `:mapped-at-creation` is
  gone: a buffer's initial contents are `:data`, and a buffer with `:data`
  needs no `:size`. A texture's dimensions are `:size` — an extent vector,
  `canvas`, or an image-bitmap name; `:size-from` and `:width`/`:height`/
  `:depth-or-array-layers` are gone. **A file beside the document is `:file`
  everywhere**: `(data :blob …)`, `(buffer :wasm …)`, `(wasm-data :url …)`
  and `(wasm-call :url …)` were four spellings of one thing (`url` promised a
  fetch nothing performed). And the two keys that named a mechanism instead of
  the member: `(init :shader …)` is `(init :module …)` and `(image-bitmap
  :image …)` is `(image-bitmap :data …)`.
- **A pass names its depth target the way WebGPU does.**
  `(depth-attachment …)` becomes `(depth-stencil-attachment …)`, and the copy
  forms take `(source …)` / `(destination …)` children instead of flat keys
  (`:mip-level` and `:origin` sit on the destination, where
  `GPUTexelCopyTextureInfo` puts them). `(write-buffer :data-from-wasm X)`
  folds into `:data X`: one slot over data and wasm-call names, one namespace.
- **A command is a form.** `:dispatch-workgroups N` and `:dispatch [x y z]`
  become a `(dispatch :workgroups [N])` child, `:dispatch-indirect B` (+
  `:dispatch-indirect-offset`) a `(dispatch-indirect :buffer B :offset N)`
  child — the three keys had an unwritten precedence between them —
  `:workgroups` is always a vector, and a pass runs every draw and dispatch
  it contains in document order rather than the first one the emitter
  happened to find. A render bundle records a `(draw …)` / `(draw-indexed …)`
  child, so it can state `:first-vertex` and `:base-vertex` like any other
  draw. A compute pass with no dispatch and a bundle with no draw are
  errors; a render pass with attachments and no draw is a legal clear-only
  pass.

#### Conditional rules WebGPU states, now stated by the compiler

Twenty-two validation rules that read a VALUE rather than a shape, so no schema
can hold them. Each is a located diagnostic where the author wrote the thing,
instead of a black screen, a console error on someone else's device, or a
native abort:

- **Depth-stencil state**, all five rules of "validating GPUDepthStencilState":
  the format must have the aspect it uses, `:depth-write-enabled` is required
  once the format has a depth aspect, `:depth-compare` once the pipeline writes
  depth, and depth bias must be 0 under a point or line topology.
- **Attachment ops follow the view's format.** A depth aspect requires
  `:depth-load-op`/`:depth-store-op` and a format without one FORBIDS them, in
  both directions and for both aspects — conditional, not unconditionally
  required, or a `stencil8` attachment becomes unwritable. And the values the
  ops read are checked the same way: `:depth-load-op clear` requires a
  `:depth-clear-value` (WebGPU has no default for it), and a `:clear-value`
  beside `:load-op load` is refused — the value is never read.
- **Formats decide what a pipeline may do.** No `(blend …)` on an integer
  target; alpha-to-coverage needs `:count > 1`, a fragment stage, and an alpha
  channel on target 0.
- **A texture descriptor must agree with itself.** `:sample-count` is 1 or 4;
  above 1 it means 2d, one mip, one layer, attachable and not storage.
- **A copy endpoint must admit the copy**, and the copy must fit: usage is
  fixed at creation, so WebGPU rejects the encoder call and the document looks
  fine.
- **A render bundle's layout must equal its pipeline's AND the replaying
  pass's** — color formats, depth/stencil format and sample count. The pass's
  side is derived from its attachments' textures, which is why this can fail
  three forms from where it is written.
- Plus: a render pass needs at least one attachment (zero used to mean "the
  canvas"); `(occlusion-query …)` needs `:occlusion-query-set`;
  `:max-anisotropy > 1` needs all three filters `linear`; `map-read` /
  `map-write` may not be combined with other usages; a `queue.writeBuffer`
  length must be a multiple of 4; `:strip-index-format` is for strip
  topologies, both ways; a render pass with a draw of its own names its
  `:pipeline` (only the bundle-replay pass may omit it — the bundles carry
  theirs); the three indirect `:offset`s are a multiple of 4
  (`indirectOffset`); a `(query-set …)` holds 1 to 4096 queries.

#### Names, numbers and symbols

- **A name is a name.** Names are one namespace across every form kind, so two
  forms cannot share one; builtin symbols (`canvas`, `context-current-texture`,
  the input sources) cannot be declared.
- **Every numeric key accepts an expression.** 39 slots read only a literal, so
  `(sampler :max-anisotropy (* N 4))` validated clean, read null, and shipped
  whatever the `orelse` said. `:depth-bias -1` was dropped the same way (a
  negative literal read as null) and depth bias is signed now.
- Symbol keys that silently accepted an unknown spelling now reject it.
- **A `(define …)` value is a real, and the slot decides.** `:value 0.5`,
  `:value -1`, `:value (/ 1 3)` and `:value OTHER` all validate (the value was
  a non-negative integer); a fractional constant in `:vertex-count` is that
  slot's located refusal, and legal in `:clear-value`. Constants resolve
  document-wide — a define may name one declared after it — and only a cycle
  is refused. **An expression that evaluates negative or fractional in an
  integer slot is refused with the value named**: `:size (- 5 10)` was a
  0-byte buffer and `:vertex-count (/ 3 2)` drew one vertex, both silently.
  A `:size` above u32 says so on the expression, like every other slot now.
- **A slot-only form at the document root is refused.** `(draw …)`, `(target
  …)`, `(pass …)` outside `(pass-graph …)` and the rest validated at the root
  and were silently skipped (the stray pass produced a payload with no
  bytecode, on which `pngine inspect` died). Each is a located reject naming
  the forms that admit it.
- **Four more spellings follow the IDL** (audit 09): a pass's WASM data files
  are `:file [paths]` (were `:data`); a texture-view's dimension is
  `:dimension` (was `:view-dimension`; the BGL resource forms keep theirs —
  it IS `viewDimension`); `(timestamp-writes …)` takes
  `:beginning-of-pass-write-index` / `:end-of-pass-write-index` (were
  `:begin` / `:end`); and `render-bundle :pipeline` and `pass :code` are
  required. The codemod carries all four renames.
- **Three keys the IDL defaults are optional here too**: `multisample
  :count`, a blend component's `:src-factor` / `:dst-factor`, a BGL
  `(buffer :type)`. `(occlusion-query …)` brackets at least one draw and
  admits the indirect pair; a `(data …)` names one source (`:float32` |
  `:file` | a generator); pixel rects, texel origins and pool offsets are
  integer vectors.

### Fixed

- **Every refusal carries a span.** 99 of the emitter's failure sites reported
  the error CLASS and nothing else — `emit failed`, with an empty `diagnostics`
  array in `--json`. 97 now name the form, the key and the line (the two left
  are generic id-table allocators that hold no node; the spelling that reaches
  them, `:pool`, is checked where it is written): an unreadable `:file` reports
  the path and the resolution rule, a cross-reference that resolves in the
  document but not at emit time says which resource and why, and a
  schema-guaranteed read that somehow fails says so as an internal error
  rather than as two words. And `validate --json`'s `message` carries the
  headline — the one refusal that is unlocatable by construction, a
  `(pass … :file …)` whose lowered buffer has no source span, used to report
  the class there while the terminal printed the cause.
- Three descriptors decoded differently on the native and browser backends, so
  a document could render on one and fail validation on the other: an absent
  depth-stencil `:format` (native substituted `depth24plus`, the browser
  errored), and a sampler's `mipmapFilter` (native applied `linear`, WebGPU
  applies `nearest`).
- `--html` output ignored `(canvas :alpha-mode …)` entirely and configured
  without an `alphaMode`, so the same document composited two ways depending on
  which runtime opened it.
- `docs/abi.md`'s "complete" opcode table was missing `0x52`
  (`set_pass_clear_values`).
- `pngine inspect --symptom` did not know the 3.0.0 pass opcodes: every
  current payload was "No render pass in frame". It reads all four openers
  now, and its fix strings speak `.sjon` (they were `#renderPass draw=N`).
- A 6-element `:viewport` wrote its minDepth/maxDepth as integers onto a
  wire field both backends read as f32 bits (`[… 0 1]` was a maxDepth of
  1e-45).
- **A `(pass …)` binds the shared sampler only when its WGSL names it**
  (`samp` / `textureSample`). A dependency or `:feedback true` used to force
  the binding, and the pass's `:layout auto` holds only what the shader
  statically uses — so a pass that read its feedback texture with
  `textureLoad` shipped a bind group with an entry its layout did not have,
  and WebGPU refused the group (black canvas; lint W0003 on `samp` was the
  only compile-time sign). No corpus document changes.
- **`:feedback true` on the last `(pass …)` of a `(pass-graph …)` is
  refused.** The last pass renders to the canvas, and WebGPU keeps no
  previous canvas texture to feed from; it used to lower to a pooled
  rgba8unorm target under a canvas-format pipeline, which the GPU rejected at
  the first `set_pipeline`. The refusal names the shape that works — feed
  back in an earlier pass and read it from the last (`pass_bloom.sjon`).
- **An expression's refusal says why.** "`:size` does not evaluate to a
  number" now ends with the reason — `NUMM is not a (define …) constant`,
  or `it divides by zero` — and a `(define …)` whose expression names a
  constant nothing declares is told apart from a cycle (it used to be called
  one, with a parenthetical admitting the ambiguity).
- The WebGPU snapshot the conformance harness reads followed `index.bs`
  alone; the spec's `sections/copies.bs` include carried five texel-copy
  dictionaries it never saw. The copy endpoints and `timestamp-writes` are
  in the machine check now, and the required ratchet asks both directions
  (schema-required ⇒ spec-required too).

### Changed

- **A `(define …)` name is a value in every numeric slot**, not only in draw
  and dispatch counts: `(buffer :size SIZE …)`, `(sampler :max-anisotropy
  ANISO …)`, `(dispatch :workgroups [WG 1 1])`, `:viewport [0 0 W H]`. The
  name is checked against the document's `(define …)` forms, so a misspelling
  is a validation error on the value rather than a silent default, and the
  slot's own bounds still name themselves for a literal that misses them.
  Two exceptions, both slots whose symbol spelling is already a member set:
  `:write-mask` (`all`) and a `(wasm-call :args […])` element (`canvas-width`
  and the other builtins) — write `(* MASK 1)` / `(* SCALE 1)` there.
  Additive: every previously valid document is still valid and compiles to
  the same bytes.
- **`:strip-index-format` exists only under a strip topology.** It is declared
  in a variant on `triangle-strip` / `line-strip`, so writing it under a list
  topology is an `unknown_key` at validation instead of an emitter refusal —
  and the exported `.d.ts` / JSON Schema carry the condition, so an editor
  offers the key only where WebGPU reads it.
- The executor grew 110-382 bytes (~3%) and the JS bundles 550-600 bytes,
  almost all of it the cost of carrying both clear-value wire formats so
  already-shipped payloads keep decoding.
- **The exported schema is tighter where a positional slot has a closed
  head-set.** `schema/pngine.d.ts` and `schema/pngine.schema.json` now render
  `(bind-group …)`, `(bind-group-layout …)` and its `(entry …)` children as
  closed unions — the open `{ $form: string }` fallback branch is gone, since
  the validator never accepted a head outside the set — and they carry the
  per-head and per-set child counts (`contains` + `minContains`/`maxContains`,
  and `required: ["$children"]` where a floor exists). Generated from the same
  schema by the same exporter; regenerate with
  `zig build schema-export -- --regen`.

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
