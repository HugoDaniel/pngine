# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and
this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [4.2.1] - 2026-11-03

### Changed

- **The SJON clone pin is v1.7.1.** README.md and CONTRIBUTING.md clone
  `--branch v1.7.1`, the language-server polish release: goto-declaration,
  key completion that offers a completed key's values, and a textEdit
  whose range spans the whole typed key. The comptime floor in
  `src/dsl_sjon/Compiler.zig` stays 1.7.0, and that is the honest
  statement rather than a stale one: 1.7.1 changes nothing on the
  language side (binary wire v5, the diagnostic-code enum, export
  format 2 and the conformance corpus are untouched), pngine consumes
  SJON's schema, validator and lowering but never its language server,
  and the schema artifacts regenerate byte-identical, so a floor that
  refused 1.7.0 would describe a failure that cannot happen. `zig build
  drift` is green against both tags. An editor pairing pngine's schema
  with SJON's `sjon-lsp.wasm` picks the completion and declaration
  fixes up from the pinned checkout.

### Fixed

- **A frame can name a declared `(pass-graph …)` or `(draw-graph …)`.**
  `frame-step`'s cross-ref targeted `[render-pass compute-pass queue
  step-group]`, so a frame step naming an authored graph failed
  validation: in the authored aggregate the graph is a `(pass-graph …)`
  / `(draw-graph …)` declaration, and the `(step-group …)` its hook
  emits does not exist yet at validation time, which rejected every
  graph a frame actually names. The cross-ref gains `pass-graph` and
  `draw-graph` as targets (`2089e59`), the generated TypeScript and
  JSON Schema are regenerated from the corrected manifest, and the npm
  payload's schema copy ships the fix (`eafebe6`).

## [4.2.0] - 2026-11-03

### Breaking

- **The generated TypeScript enforces exclusive groups structurally.**
  `schema/pngine.d.ts` moves to export format 2, so `Pngine_Wgsl`,
  `Pngine_ShaderModule`, `Pngine_Data` and `Pngine_Bytes` are type aliases
  now: a base object intersected with one arm-union per exclusive group,
  instead of an interface whose grouped keys were all optional. Three
  consequences for a consumer of that file. `interface X extends
  Pngine_Wgsl {}` fails with TS2312 (an interface cannot extend an
  intersection containing a union), declaration merging over those four
  names is gone, and a document carrying both alternatives of a group,
  `(wgsl :code … :file …)`, is a compile error instead of a silent
  mismatch with the validator that already refused it. The inline
  `bind-group` entry shape gains the same treatment. The npm tarball ships
  only `schema/pngine.sjon`, so nothing in the published package changes;
  the diff is for editors and anyone pointing `tsc` at
  `schema/pngine.d.ts`. The JSON Schema artifact differs only in its
  `x-sjon-export-version` stamp.

### Changed

- **The SJON path dependency is 1.7.0.** `src/dsl_sjon/Compiler.zig` now
  refuses 1.5.x and 1.6.x at comptime, `README.md` and `CONTRIBUTING.md`
  clone `--branch v1.7.0`, and `schema/pngine.{d.ts,schema.json}` are
  regenerated from it. The floor moves with the artifacts rather than
  ahead of them: once the committed files carry the version-2 stamp, a
  1.5.0 checkout fails `schema-export` no matter what the compiler accepts,
  so leaving the floor at 1.5.0 would only make the error message lie.
  1.6.0 is the language-server release and 1.7.0 the schema-export
  release; the binary wire stays v5 and the diagnostic-code enum is
  unchanged, so no document, bytecode or runtime behaviour moves.

## [4.1.1] - 2026-11-02

### Fixed

- build: the native npm CLI builds on Linux again. `893f829` passes the
  target's platform define through to the WAMR layer instead of always
  compiling with `-DBH_PLATFORM_DARWIN`, so `@pngine/linux-x64@4.1.1` is the
  first Linux binary produced from a revision that can build it.

## [4.1.0] - 2026-10-31

### Breaking

- **The colour target head is `color-target`.** pngine's `(target …)` form and
  its `target-section` positional value-kind are renamed `(color-target …)` and
  `color-target-section`. The old spelling collided with pacer's animation
  `target` in a scope that loads both plugins, so every document, codemod and
  hook that spells the pngine head moves to the new name. `target` remains
  pacer's word; `color-target-format`, `color-attachment` and
  `depth-stencil-attachment` already spell the colour target natively.

### Fixed

- extract --list: pNGm lists without a flags byte (02:82-83) and unknown pNG
  letters list as v-1 with the chunk's full payload size.
- npm bundle: the inlined viewer/dev profiles build again. payloads.js was
  concatenated in at 02.C2 with a private concatParts that collides with
  envelope.js's own, and without the size-budget bump its bytes cost, so the
  first bundler run since then failed twice; the helper is renamed, the
  budgets are bumped for the walker plus its framing preflight, and
  bundle-closure now refuses any top-level name declared by two concatenated
  modules.
- npm types: payloadsOf is exported by the viewer and dev profiles and
  declared in the published d.ts (PayloadEntry, PayloadSkip), with a
  consumer compile against the emitted declarations.
- npm payloadsOf: refuses non-PNG bytes with a TypeError instead of walking
  them from offset 8.
- readers: payloadsOf verifies CRC and chunk bounds before the first yield,
  matching walkPng; walkPng reports an over-16-MiB chunk as its own error,
  not as corruption.
- pack and extract --kind: empty payloads are legal; the default spelling
  stores the empty DEFLATE stream, `,raw` stores zero bytes, and generic
  extraction writes an empty artifact (empty file to -o, zero bytes to
  stdout); legacy PNGB extraction still refuses them.
- pass-v1: a scaled pass's `post()` can name `PASS_SCALE`. The main prelude
  declares the const whenever `:scale` is authored, but the post module's own
  prelude never did, so the one stage that reads the scaled intermediate back
  up to the canvas had to restate the fraction by hand — a restatement that
  silently broke the day `:scale` changed. The post prelude now declares its
  own copy, gated on the post fn actually naming the const (`namesIdent`, so
  a comment does not count), because its prelude is root text and an unread
  const there would warn W0001 on every scaled pass with a post().

## [4.0.1] - 2026-10-29

### Fixed

- **macOS binaries link the vendored wgpu-native archive instead of resolving
  a dylib beside it.** wgpu-native's macOS zip vendors a
  `libwgpu_native.dylib` next to the `libwgpu_native.a` the build probes, and
  the old by-name `-lwgpu_native` search preferred the dylib — shipping a CLI
  that recorded `@rpath/libwgpu_native.dylib` and died on every machine but
  the one that built it (`Library not loaded`). build.zig now hands the
  linker the exact archive it probed (one expression decides both presence
  and link input) and links Foundation on darwin (the archive's members
  reference `NSKeyValueChangeNewKey`, which the dylib satisfied internally),
  and the install now refuses a binary that still names `libwgpu_native` in
  any `LC_LOAD_*_DYLIB`/`DT_NEEDED` entry:
  `tools/assert_wgpu_static.zig` fails the default install whenever the
  produced CLI carries any dynamic `wgpu_native` dependency (Mach-O load
  commands / ELF `DT_NEEDED`). This is what the release acceptance on
  darwin-arm64 proved on 2026-10-28: the binary the gate built, installed and
  smoked carries no dynamic `libwgpu_native` reference.

## [4.0.0] - 2026-09-11

A WGSL document stops being one file, the sugar tier gets an anchor, and the
JavaScript API gets one contract.

Shader text can now be named, imported, held open at a hole and specialised
per module; a document can be another document plus a rebinding; a bind group
can leave its pipeline open; and the graph sugars grow the keys the corpus was
already asking them for. Separately, every key of every lowered form now has a
hand-written twin in `examples/` that renders identically, and a drift gate
that says so. On the host side, every `(buffer :name …)` is writable by name,
and `setFrame` and `setUniform(…, { redraw: false })`, both documented and both
inert through 3.0.1, now do what their documentation says.

Major, because the JavaScript API changed where a host can see it:
`getUniforms` answers in names, `p.audio` is read-only, three instance getters
that always answered `null` or `0` are gone, and calls that used to do nothing
now throw a `TypeError`. A document that compiled under 3.0.1 compiles
unchanged unless it hits one of the refusals listed below, and every one of
those except the symlink rule is a document that failed at runtime or rendered
something it did not ask for.

### Breaking

- **`getUniforms` speaks names.** Each field's `type` is the WGSL spelling
  (`"vec4f"`) where it was the payload's numeric wire tag, and `bufferId`, a
  dispatcher index that no public call accepted, is replaced by `buffer`: the
  `(buffer :name …)` holding the field, the same name `writeBuffer` and
  `getBuffers` take. `buffer` is `null` for a payload compiled before 4.0.0,
  because those payloads carry no buffer names. A tag this runtime does not
  know reads `"unknown"`. The types are published as `UniformField` and
  `UniformTypeName`.
- **`p.audio` is read-only.** It resolves to `duration`, `playing` and
  `currentTime` getters, and assigning through it throws. Through 3.0.1 it
  handed out the whole audio player, whose `play`, `pause`, `stop` and `seek`
  moved the song without moving the animation clock; the instance verbs
  (`play(p)`, `seek(p, t)` and the rest) drive both. The published
  `AudioPlayer` interface is now `AudioInfo`.
- **The instance getters `animation`, `duration` and `currentScene` are
  removed.** No payload has reached the runtime with an animation table since
  the loader rewrite of December 2025, so they answered `null`, `0` and `null`
  on every instance.
- **The instance verbs share one contract.** Arguments are checked first, and
  one of the wrong kind is a `TypeError` before anything is posted, including a
  non-finite time (`seek(p, NaN)`, `draw(p, { time: "1" })`), and including on
  a destroyed instance. A verb on a destroyed instance otherwise returns `p`
  and posts nothing, so `draw(p, …)` no longer throws there, and `draw` returns
  `p` like every other verb. The `pngine()` rejections for a source of the
  wrong kind, a missing `options.canvas` and the viewer's dev-only options are
  `TypeError`s for the same reason.
- **`setUniform(p, name, value, false)` throws.** The trailing boolean never did
  anything in a release (see Fixed). The spelling is
  `setUniform(p, name, value, { redraw: false })`, the trailing options object
  `writeBuffer` also takes, and the `TypeError` names it.
- **Documents the compiler now refuses.** A `:file` path with a symbolic link
  in any component below the document's directory, even a link that points
  back inside it: a downloaded project is a directory, so whoever wrote the
  document also placed its links, and "no links on the path" is a rule an
  author can check by looking. The rest used to compile and then fail or
  misrender: a document over one of the runtime's resource caps (it validated
  clean and died at render with `InvalidResourceId`; it is now refused at its
  source line, naming the cap and the backend that holds it), a
  `write-buffer` whose builtin or `(data …)` source is larger than the buffer
  it writes, a `(bind-group …)` with more than 255 entries, and a `gen` data
  WASM that exports its memory under a name other than `memory`, which no
  runtime reads.

### Added

- **`writeBuffer(p, name, bytes, opts)` and `getBuffers(p)`.** Every
  `(buffer :name …)` is host-writable by the name the author wrote — a bare
  `array<T>` no uniform reflects, a vertex buffer, an indirect-args buffer —
  where before the only route onto the GPU was a reflected struct leaf through
  `setUniform`. The compiler writes the names into the payload as a block at
  the tail of the uniform-table section behind header flag bit 4 (median +36
  bytes over the corpus; a document with no buffers is byte-identical), and
  the runtime resolves them. A write needs `copy-dst` in the buffer's
  `:usage`; a buffer the frame's own queue ops write every draw is refused
  (`getBuffers` reports it as `frameWritten`); a pooled buffer takes
  `poolIndex` (`k`, `"active"`, or absent for every member). Every refusal
  reaches `onError` as a `PngineGPUError` with source `"write-buffer"`, never a
  silent no-op. `draw(p, { buffers })` is the primitive both are sugar over,
  and `--types` writes `Buffers` / `BufferName` into the `.d.ts`.
- **`(wgsl …)` fragments.** A named block of WGSL, `:code` inline or `:file` on
  disk, that shader modules and passes assemble ahead of their own text with
  `:imports [name]`. A fragment is never a GPU object: what reaches wgslender
  and the payload is one assembled text per root, so minification renames
  across fragment boundaries and dead-code elimination drops what a root does
  not reach. `(shader-module … :file …)` reads a whole module the same way.
- **Holes (`:requires`).** A fragment may leave names open for the importing
  module to supply, which is how one library serves several variants with no
  WGSL extension. `validate` checks the list against the fragment's own
  unresolved names, both ways.
- **`(import :file "./base.sjon" …)`.** A document can be another document plus
  a rebinding of its consumed forms: the base compiles ahead of this one with
  the named `(define …)` constants and `(wgsl …)` fragments replaced,
  byte-identical to the base with those edits made by hand.
- **Derived bind groups.** Leave `:layout` out of a `(bind-group …)` and the
  compiler emits one GPU bind group per pipeline that binds it, each holding
  only the entries that pipeline's entry points reach. One resource set, any
  number of pipelines. `(bind-group … :prune-unused true)` is the same pruning
  for a group that does name a `:layout`.
- **`(draw-graph …)`.** One conceptual draw expanded into many concrete ones:
  a table of `(stage …)`s (what to draw into, and the pipeline state a stage
  shares) and `(geometry …)`s (what to draw, and the stages it appears in),
  lowered to one pipeline, one bind group per stage group and one render pass
  per pair. A stage can render into a texture rather than the canvas, and can
  state how its colour targets blend.
- **`(step-group …)` and named graphs.** A graph with a `:name` emits a step
  group instead of a frame, so two graphs — or a graph and hand-written passes
  — compose inside one `(frame …)`.
- **Five keys on `(pass …)`.** `(constant …)` children specialise the
  `override`s of the modules a pass builds; `:format` chooses the format of the
  texture it renders into; `:reads` binds textures the graph did not produce;
  `:scale` renders the intermediate at a fraction of the canvas; `:init` seeds
  that intermediate with a compute shader that runs once.
- **`pngine-frame-inputs`.** A 20-byte `write-buffer` source: `pngine-inputs`
  followed by the frame counter as a `u32`, for shaders that need the pool
  phase rather than the clock.
- **Diagnostics say which file they are in.** A finding inside an imported
  fragment names the FILE and its line inside that file, once per compile
  rather than once per importing module; `--json` entries carry a `"file"` key
  saying which file `line`/`column` belong to. The two reachability advisories
  (`W0001`, `W0002`) are not reported inside an imported fragment — a library
  declaration this document does not reach is a finding about the library —
  and `validate --verbose` prints how many were suppressed, with `--json`
  carrying the count as `suppressed`.
- **The browser compiler takes a file table** and reports what it needs, so a
  host with no filesystem can resolve `:file` and follow an import chain.
- **The sugar tier has a ledger.** `schema/sugar-ledger.mjs` records, for every
  key of every hook-lowered form, what it desugars to and which hand-written
  document proves it is sugar; `zig build drift` derives the key set from the
  schema and fails on a key that is not written down. All 23 are twinned, each
  gated on pixels by a row in the render suite. `zig build test-core` compiles
  every example with an EMPTY lowering registry, so a document either compiles
  byte-identically (it is core) or is refused with `lowering_hook_missing` (it
  is sugar), with nothing in between.
- **`(bytes …)`, verbatim bytes as a `(data …)` source.** `(bytes :file
  "table.bin")` embeds a sidecar file read at compile time and `(bytes :base64
  """…""")` carries the bytes inline (whitespace inside the literal is
  ignored, so a wrapped block diffs by line). The bytes are stored with no
  MIME prefix and sized like an inline array, so a `(buffer … :data …)` can
  size and fill from them, which `(data … :file …)` cannot.
- **`compiler.heapBytes()`** on `pngine/compiler`: the browser compiler's live
  heap, the compile-side counterpart of `getStats(p).wasmBytes`, for a host
  that recompiles on every keystroke and wants to see it stay flat.
- **An `unlocated` array in the `--json` envelopes.** Thirteen of the
  emitter's warnings have no position in the document (a finding about a WGSL
  binding has no SJON node to point at). They were left out of `--json`, so
  `validate --strict` could exit 1 against a report listing no diagnostics.
  They now ride their own array, the same object shape minus `line` and
  `column`, so an editor that turns each `diagnostics` entry into a squiggle
  never meets a line 0.
- Native `--frame` requests `depth32float-stencil8`,
  `rg11b10ufloat-renderable` and `timestamp-query` when the adapter has them,
  as the browser runtime does. `primitive-index`, `texture-formats-tier1` and
  `core-features-and-limits` do not exist in the vendored wgpu-native, so a
  document that needs one renders in the browser only.
- Forty-four examples and seventy-six rejection fixtures. Among the examples:
  `pass_acid_cubes` and `pass_acid_lattice` (a compute.toys cube-space march),
  `pass_game_of_life`, `pass_hdr_tonemap`, `pass_half_res`, `pass_reads_depth`,
  `pass_feedback_compute` (a hand-written compute pass beside a feedback pass
  in one frame), `graph_compose`, three `draw_graph_*` fixtures,
  `frame_index`, `test_data_gen`, ten `_hand.sjon` twins and six
  `_fragments.sjon` pairs that render pixel-identically to the document they
  were split out of. `examples/lib/` holds the 28 WGSL files those documents
  share.

### Fixed

- **`setUniform(…, { redraw: false })` was a no-op.** Its doc promised
  "batch updates without immediate redraw" from the API's first commit; the
  store it wrote was deleted as write-only, and the branch returned `p`. Both
  `setUniform` and `setUniforms` with `redraw: false` now store the values for
  the next draw from anywhere — the play loop's, a seek's, a host `draw()` —
  which carries and clears them. `writeBuffer` follows the same rule, and the
  option is spelled the way `writeBuffer` spells it, as a trailing options
  object (the old positional boolean is under Breaking).
- **`setFrame(p, name)` did nothing.** The draw message has carried the pinned
  frame since the API's first commit and the worker never read it, so a
  document with several `(frame …)` forms always ran its first. The pin now
  reaches the executor through three additive exports (`setFrame`,
  `getFrameCount` and `getFrameNameId`, in `docs/abi.md`); `setFrame(p, null)`
  releases it, `p.currentFrame` reads it back, and an unknown name reaches
  `onError` with source `"set-frame"` while the draw still renders. The
  `ready` message reports the payload's real frame count, where it always said
  1.
- **`(pass … :init …)` did nothing.** The key validated and was documented,
  but the pass lowering never read it, so a pass with it and the same pass
  without it compiled to identical bytes. It now seeds the pass's texture with
  a compute shader that runs once, before the first frame's feedback read. A
  document that carried the key renders the seed now.
- **A `setUniform` that could not land said nothing.** An unknown uniform name,
  or one whose buffer the init stream never created, was a debug-only console
  warning. It reaches `onError` with source `"set-uniform"`, once per distinct
  message, and the call still returns `false`.
- **The core tier could not hear command faults or see the pointer.**
  `pngine/core`'s `createCoreDispatcher` forwarded eight of the twelve
  dispatcher methods the worker tier calls. Without `setOnError`, an unknown
  opcode, an empty descriptor or a failed resource validation was console-only
  there; without the pointer and frame-counter setters, `pointer-inputs` stayed
  zeroed and the frame counter never advanced. All twelve are forwarded now,
  with `setBufferNames`, `writeBuffers` and `getBuffers` beside them.
- **`--html` exported wrong numbers.** Every float needing more than 24
  characters in decimal (`1e30`, `1e-30`, the largest `f32`) reached the page
  as `0`; `inf` and `nan` reached it as bare identifiers the browser rejects
  with a `ReferenceError`; and a very small `:depth-bias-clamp` emitted the key
  with no value. A 12-byte `scene-time-inputs` write overran its buffer, so
  WebGPU refused it. Each builtin source now writes exactly its own size.
- **A diagnostic that did not fit was blanked.** When the diagnostic store
  overflowed, an entry kept an empty message and read as a diagnostic with
  nothing to say. It is dropped and counted in `dropped`, the field that
  already means "this report is a prefix". A line number too large for the
  `--json` writer no longer leaves `"line":` with no value.
- **`miniPngine(canvas, view)` read a `Uint8Array` from byte 0 of its
  buffer**, so a view over part of a larger buffer (a slice of a bundle, a
  fetch body with a prefix) found no pNGf chunk. It reads the view's own bytes.
- **The published `.d.ts` disagreed with the runtime in eight places**, among
  them `destroy` typed as `void` while it returns the instance,
  `DrawOptions.frame` refusing the `null` that `setFrame(p, null)` takes, an
  exported `canvasAlphaMode` with no declaration, `getUniforms` missing
  `elemCount`, and `PngineInstance` hiding `currentFrame` and `audio`. The
  type strings now live in one file that a test derives from the code.
- **`(pass … :file …)` never worked on any shipping backend.**
  `write_buffer_from_wasm`'s first operand is a CALL id and the lowering passed
  a MODULE id, so the browser looked up a call that a `gen`-less data module
  never makes and wrote no bytes: a black canvas where the fixture's own
  comment said orange. A module with no `gen` export is now read at compile
  time and shipped as bytes through an ordinary `write_buffer`, which also
  drops two opcodes the native backend stubs (`test_data_pass` renders on
  native, and its payload is 1,098 bytes smaller).
- **A `gen` data buffer wrote to the wrong place.** The same operand family one
  slot to the left: `write_buffer_from_wasm`'s `buffer_off` is the destination
  in the GPU buffer, and the lowering passed `s`, which addresses the module's
  memory. Correct for every fixture that had `s` = 0 and past the end of an
  `l`-byte buffer for the first that did not. A `gen` module that exports its
  memory under a name other than `memory` is now refused at compile time — the
  runtime reads `exports.memory` or the `env.memory` import, so any other
  spelling generated bytes nobody could read.
- **A pass feature named only in a comment is not a feature.** The `(pass …)`
  lowering detected `post()`, pointer input and sampler use with a substring
  scan over the author's text, so a mention inside a comment enabled a feature
  the shader did not use — three live `wgpu` aborts, and a fourth reader that
  silently produced the wrong module.
- **A root or pass that opens with a directive can import.** `enable` and
  `requires` must precede every declaration in WGSL, so a document whose own
  text began with one could not have a fragment assembled ahead of it. The
  directives are hoisted to the top of the assembled text.
- **The used-but-unbound check asks per PIPELINE, not per document.** A binding
  that some entry point in the document reaches was treated as reached by every
  pipeline, which refused documents that were correct and let the reverse pass.
- A colour target with no authored blend gets no blend state on native, rather
  than a default one the document never asked for.
- The time uniform saturates at the payload's own size rather than at 16 bytes,
  so a 20-byte `pngine-frame-inputs` buffer is filled rather than truncated.
- An imported document's error names the file its line belongs to.

### Changed

- **`pngine/core`: `setFrameCounter`.** The core dispatcher's frame-counter
  setter carries the one name the executor's counter (`getFrameCounter`,
  frames rendered since `init()`) has on every tier. It was briefly
  `setFrameIndex` during development, which beside the main API's `setFrame`
  read as "which `(frame …)`"; no release carried that name.
- A `(pass …)` that draws to the canvas no longer allocates an output texture
  that nothing renders into or reads. Fifteen of the nineteen pass-graph
  examples paid for one: 8.29 MB at 1920×1080, reallocated on every resize.
- `docs/sjon-reference.md` gains sections for fragments and imports, extending
  a document, derived bind groups, pipeline-overridable constants,
  `(draw-graph …)` and `(step-group …)`.
- The corpus stops copying its shared WGSL. Six one-function libraries under
  `examples/lib/` (`perspective`, `look_at`, `inverse_camera`,
  `inv_perspective`, `rotate_vec`, `hash`) are imported by 51 documents
  between them — 37 for `perspective` alone — where each had carried its own
  copy.

## [3.0.1] - 2026-08-24

A patch on the published type declarations, the native backend's blend
factors and the migration tool, plus four samples and the vocabulary map the
documentation site now reads.

### Added

- `schema/webgpu-mapping.mjs` ships: the map from every schema value-kind to
  the WebGPU enum or flag namespace it spells, from every mirrored form to its
  dictionary, with the keys that are PNGine's own and the spec values the
  engine leaves out. It lived inside the conformance test, which the release
  cut strips. The documentation site generates the "Where these words come
  from" table at the end of every reference page from it.
- Native `--frame` renders dual-source blending: the four `src1*` blend
  factors are honoured, and `dual-source-blending` is requested from an
  adapter that has it. The native ledger of unsupported blend factors is
  empty, and the conformance gate keeps it that way.
- Four samples: `compute_subdivision` (a 24-vertex octahedron amplified to
  512 triangles by a compute pass and drawn by `vertex_index` out of the
  storage buffer), `subdivision_bundles` (the same mesh drawn from two
  `(render-bundle …)` forms through `:execute-bundles` alone),
  `dual_source_glass` (three coloured panes in one unsorted draw, each with
  its own transmission and highlight) and `30_collatz_search` (two compute
  passes and a copy, no render pass, the result read back through a
  `map-read` buffer).

### Fixed

- The published type declarations were missing options the runtime reads:
  `autoResize` and `onQueryResult` on `ViewerOptions` and `DevOptions`,
  `onError` on `MiniOptions`. A typed caller could not pass an option the
  documentation told it to pass.
- `ViewerOptions` declares `wasmUrl`, and the viewer's source union includes
  `HTMLImageElement`, so the two inputs `pngine/viewer` rejects on purpose
  reach the runtime's named error instead of a compile error at the call site.
- `scripts/codemod-overhaul.mjs` rewrites the positional `(layout auto)` to
  `:layout auto`, the one 3.0.0 spelling change it did not migrate; `--check`
  had reported such a document as already migrated.

### Changed

- `docs/sjon-reference.md` documents the indirect draw and dispatch forms
  under their own heading, and states the spelling rule that maps the
  vocabulary onto WebGPU's.

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
