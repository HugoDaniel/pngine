# SJON Syntax Reference

> The complete `.sjon` authoring reference. The schema (`schema/pngine.sjon`)
> is the single source of truth; this document is the human-readable tour.

PNGine is a SJON host: `.sjon` source is S-expression forms validated against the
`schema/pngine.sjon` WebGPU schema (the single source of truth). SJON owns the
syntax, validation, cross-reference resolution, expressions, and sugar lowering;
PNGine owns the schema, the `pngine/*` lowering hooks, and PNGB emission. Each
legacy `#macro name { … }` becomes a form `(macro-name :name name …)`; bare
identifiers are cross-references the validator resolves document-wide.

See `schema/pngine.sjon` for the authoritative vocabulary and `examples/*.sjon`
for worked programs (`simple_triangle`, `moving_triangle`, `boids`).

The vocabulary is WebGPU's, re-spelled: a form is a descriptor
(`GPUBufferDescriptor` is `(buffer …)`), a key is one of its members (`size`
is `:size`, `frontFace` is `:front-face`), a symbol value is an enum string or
a flag constant (`GPUBufferUsage.COPY_DST` is `copy-dst`). Which kind spells
which enum, which form mirrors which dictionary, which keys are PNGine's own
(`:name`, `:pool`, `:file`, …) and which spec values the engine leaves out is
declared in `schema/webgpu-mapping.mjs`, and `tests/npm/webgpu-conformance.test.js`
holds that map against the IDL snapshot in `schema/webgpu-enums.json`, so the
answer to "where does this word come from" is a lookup, not a guess. The docs
site generates a per-key table from the same files at the end of every form's
page.

```sjon
; Named constant → collected into the emitter's expression env.
(define :name NUM :value 2048)

; A named WGSL module (the source is opaque text to SJON). `"""…"""` is a
; multi-line string literal; `:code "…"` a single-line one.
(shader-module :name code :code """<shader code>""")

; One-shot compute init of a storage buffer (once per loaded payload — see
; "What `:init` means, exactly"). Lowered by the
; pngine/init-v1 hook → compute-pipeline + bind-group + compute-pass.
(init :name setup :buffer particles :module initShader :workgroups [(ceil (/ NUM 64))])

; GPU buffer. `:pool 2` creates two ping-pong ids; `:size` is a byte count
; (a literal, a constant name or an expression). A buffer filled from a
; (data …) says `:data <name>` instead and is sized by it.
(buffer :name particles :size (* NUM 4 4) :usage [vertex storage] :pool 2)

; A texture must name a size: :size [w h d], :size canvas, or :size <image-bitmap>.
(texture :name depth :size canvas :format depth24plus :usage [render-attachment])
(sampler :name samp :mag-filter linear :min-filter linear)

; Bind group. :layout names a pipeline (its auto-derived layout, picked by
; :group) or an explicit (bind-group-layout …); leave it out and the compiler
; derives one bind group per pipeline that binds the group, pruned to what
; that pipeline reaches (see "Derived bind groups" below). Entries are
; (entry …), one resource each (:buffer / :sampler / :texture / :texture-view);
; a buffer entry may bind a slice with :offset and :size (both need :buffer,
; and the slice must fit the declared buffer size).
(bind-group :name g :layout pipe :group 0
  (entry :binding 0 :buffer uniforms))

(render-pipeline :name pipe
  :layout auto
  (vertex :module code :entry vsMain)
  (fragment :module code :entry fsMain
    (color-target :format preferred-canvas-format))
  (primitive :topology triangle-list))

(compute-pipeline :name cp :layout auto (compute :module code :entry main))

(render-pass :name draw
  (color-attachment :view context-current-texture
    :clear-value [0 0 0 1] :load-op clear :store-op store)
  :pipeline pipe
  :vertex-buffers [posBuffer uvBuffer]      ; optional bare cross-refs
  :vertex-buffers-pool-offsets [1 0]        ; ping-pong offsets
  :bind-groups [g]
  (draw :vertex-count 3))                    ; or (draw-indexed :index-count N)

(compute-pass :name step :pipeline cp :bind-groups [g]
  (dispatch :workgroups [(ceil (/ NUM 64))]))    ; [x], [x y] or [x y z]

(queue :name writeInputs
  (write-buffer :buffer uniforms :offset 0 :data pngine-inputs))

(frame :name main
  :init [setup]          ; one-shot compute init (once per loaded payload)
  :before [writeInputs]  ; queue ops run before each frame
  :perform [step draw])  ; passes/queues run every frame, in order
```

A document need not be one file. `(wgsl …)` declares a named fragment, from
inline text or a `.wgsl` file, that shader modules and passes assemble ahead of
their own code (see "Fragments and imports"); `(import …)` compiles another
`.sjon` document ahead of this one, rebinding its constants, so one program can
be another program with a value changed (see "Extending a document"). Numeric
slots
accept a bare `(define …)` name, or a bounded expression over those constants
(`(* NUM 4 4)`, `(ceil (/ NUM 64))`) whose heads are SJON's core expression
table — `+ - * /` and `mod`, `min max clamp abs sign`, `floor ceil round
fract`, `sqrt pow`, the trig functions and `pi`, `lerp step smoothstep`,
comparisons and `if` (see "Expressions and `(define …)`" below).

### Declaration Order

**Write forms in whatever order reads best.** Two rules cover everything:

1. **Forms emit by kind, in a fixed order** — data, shader modules, buffers,
   textures, samplers, layouts, pipelines, bind groups, then passes and frames
   (`src/dsl_sjon/Emitter.zig`'s `phases` table is the authority). A `(texture …)`
   written above a `(buffer …)` still emits after every buffer.
2. **Everything binds by name, and a name is a name.** A pass names its
   pipeline, a bind group names its buffer. Nothing is positional. Every
   `:name` lives in **one namespace across every form kind**: a buffer and a
   texture cannot both be called `shared`, a render- and a compute-pipeline
   cannot both be called `same`, and the compiler says so at the second
   declaration (the one you can delete), naming the first by line. The
   builtin spellings — `auto`, `canvas`, `context-current-texture`,
   `preferred-canvas-format`, the input sources — are reserved and cannot be
   declared (`(buffer :name auto …)` is refused as naming a builtin). Where
   one slot accepts several kinds — a bind group's `:layout` (render-pipeline,
   compute-pipeline or bind-group-layout), a frame step (render-pass,
   compute-pass, or queue) — the validator additionally reports the clash as
   `duplicate_cross_ref_target`.

Within one kind, document order decides the numbering of the ids that kind hands
out — the first `(buffer …)` is buffer 0. Those ids are an internal detail: no
`.sjon` form takes one, and permuting the declarations permutes the ids and
nothing else. Verified on the corpus by rendering a fixture before and after a
reorder and comparing at zero tolerance
(`pngine diff --precision 1 --max-diff 0`): the pixels do not move.

Order *is* load-bearing in the places where you write a list, and only there:

- `(frame … :perform [a b c])` — passes run in that order, and `:before`/`:init`
  likewise;
- `(color-attachment …)` sub-forms — the first is `@location(0)`;
- `(vertex-buffer …)` sub-forms — the first is slot 0, and it pairs with
  `:vertex-buffers [ … ]` on the pass positionally;
- `(entry …)` sub-forms carry an explicit `:binding`, so they are the exception —
  their order is free.

One more, easy to trip over: **within a pass form, the keys are emitted in the
order you write them.** Listing `:bind-groups` above `:vertex-buffers` emits
`set_bind_group` before `set_vertex_buffer`. WebGPU does not care — both are
just state set before the draw — but the call sequence, and therefore the golden
trace, does change. It is not a correctness trap; it is why a shuffled pass form
shows up as a diff.

### What `:init` means, exactly

A `:init` step runs **once per loaded payload, keyed by the pass** — not once
per frame, not once per scene, not once per time the frame slot happens to be
the first one drawn. Load the same PNG twice and each load runs it once; seek,
pause, restart the animation, or hand the runtime a saved frame counter and it
does not run again. Only a fresh load re-arms it (`docs/abi.md` §7, clause 9).

Three consequences follow, and they are the useful ones:

- **A repeated entry is refused.** `(frame :init [spawn spawn])` asks for two
  runs and can only get one, so the compiler rejects it rather than emitting a
  second op that can never fire. This is the opposite of `:perform`, where
  repetition is meaning: `webgpu_bitonic_sort` names `passDisp2` twelve times
  because the sort needs each of them.
- **Two frames may share one `:init` pass.** It runs once in total, in whichever
  frame is rendered first — a shared setup, not a per-scene one. If you want
  per-scene setup, give each scene its own pass.
- **A pass in both `:init` and `:perform` warns.** Both lists are honoured
  exactly as written, so it runs twice on the first frame and once per frame
  after. That is defined, just rarely what "one-shot" was meant to say.

Long lists in `:init`, `:before` and `:perform` are capped at 2048 entries. The
number is the 64 KB command buffer's: even the cheapest step that emits anything
costs ~18 bytes of it, so a longer list can describe a frame the runtime cannot
execute. The corpus's longest is 82.

### Expressions and `(define …)`

Every numeric slot takes a bounded expression over `(define …)` constants, and
that includes the slots read by a lowering hook:

```sjon
(define :name NUM :value 2048)
(define :name WG  :value 64)

(buffer :name particles :size (* NUM 4 4) :usage [storage])
(init :name setup :buffer particles :module initShader
  :workgroups [(ceil (/ NUM WG))])              ; lowering-time — also evaluated
(compute-pass :name step :pipeline cp :bind-groups [g]
  (dispatch :workgroups [(ceil (/ NUM WG))]))     ; emitter-time
```

`(init … :workgroups)` is read while the `pngine/init-v1` hook lowers, before
the emitter runs, but the hook evaluates against the same document-wide define
env, so both slots behave the same.

The expression heads are SJON's core table, not a pngine subset: `+ - * /`
(`-` with one argument negates; `/` needs two), `mod`, `min` / `max` /
`clamp`, `abs` / `sign`, `floor` / `ceil` / `round` / `fract`, `sqrt` / `pow`,
`sin` / `cos` / `tan` / `atan2` and `(pi)`, `lerp` / `step` / `smoothstep` /
`saturate`, the comparisons, `if` and `let`. An unknown head is an
`unknown_form` error, not an expression diagnostic; a wrong argument count is
`arity_mismatch`. Whatever the head, the slot still judges the result: `(pi)`
in `:size` is "evaluates to 3.14…, and this slot takes an integer".

Integer slots also take hex literals — `:write-mask 0xF`,
`:stencil-read-mask 0xFF`, `:mask 0xFFFFFFFF` — read as the number they spell
(`pngine inspect` shows the decimal).

A **bare define name** is a value in every numeric slot, not just a count:

```sjon
(define :name SIZE  :value 32768)
(define :name ANISO :value 4)

(buffer :name b :size SIZE :usage [storage])          ; scalar slot
(sampler :name s :max-anisotropy ANISO
  :mag-filter linear :min-filter linear :mipmap-filter linear)
(compute-pass :name step :pipeline cp :bind-groups [g]
  (dispatch :workgroups [WG 1 1]))                    ; vector element
```

The name is checked against the document's `(define …)` forms, so a misspelling
is a validation error on the value rather than a silent default — and the slot's
own bounds still speak for a literal that misses them (`:max-anisotropy 32` says
1..16, not "no alternative matched").

Three rules:

- **A constant is a real, and the slot decides.** `(define :value …)` takes any
  real — `0.5`, `-1`, `(/ 1 3)` — a bounded expression, or another constant's
  name. Nothing about the define says "integer": the slot that reads it does.
  A fractional or negative constant is legal in `:clear-value` or `:depth-bias`
  and a located refusal in `:vertex-count` or `:size`, worded with the value:

  ```
  `:vertex-count` evaluates to 1.5, and this slot takes an integer — wrap the
  expression in (floor …) or (ceil …)
  `:size` evaluates to -5, and this slot takes a non-negative integer
  ```

  The same holds for an expression written directly in the slot: `:size (- 5 10)`
  is refused, not clamped to 0, and `(/ 3 2)` is refused, not truncated to 1
  (float noise on an integer result, `(* 0.1 30)`, is forgiven).

- **Constants resolve document-wide.** A define may name a define declared
  after it; the set is resolved to a fixed point before anything reads it. The
  one shape that cannot resolve is a cycle, refused on the first constant in it:

  ```
  `(define :name A)` depends on itself — directly, or through another constant
  that names it — and a constant cannot refer back to itself.
  ```

  A define declared after the `(init …)` or `(buffer …)` that uses it is fine
  for the same reason — the whole document's defines are collected first.
- **Two numeric slots a bare name does not fit: `:write-mask` and a
  `(wasm-call :args […])` element.** Each has a symbol spelling already taken
  by a member set — `all` for the mask, the `canvas-width` / `canvas-height` /
  `time-total` / `time-delta` builtins for the args — so write the arithmetic
  there: `:write-mask (* MASK 1)`, `:args [(* SCALE 1)]`. Everywhere else the
  bare name works, and the reason
  it took this long is worth knowing: a slot that accepts both a number and a
  name is a union, and a union used to report only the names of its arms — so
  `:size 5000000000` would have stopped saying "out of u32 range" and started
  saying "no alternative matched". SJON reports the arm the value's shape
  selected now, which is what made the trade unnecessary.

### Shape Generators (`(data …)` with a shape property)

Built-in compile-time shape generators produce vertex data (and optionally index
data) from shape parameters. The generated data is embedded in the PNGB payload.

**Procedural shapes** (deindexed, vertex data only) — a positional shape sub-form
inside `(data …)`:

```sjon
(data :name cubeVerts   (cube :format [position4 color4 uv2]))
(data :name planeVerts  (plane :format [position3 normal3]))
(data :name sphereVerts (sphere :format [position3 normal3]))
(data :name torusVerts  (torus :format [position3 normal3]))
(data :name coneVerts   (truncated-cone :format [position3 normal3]))
(data :name cylVerts    (cylinder :format [position3 normal3]))
```

The shape sub-forms are `:open true`, so generator-specific numeric config
(segments, rings, radius, thickness, …) is accepted alongside `:format`. At most
one generator per `(data …)` — it is one byte source, so a second sub-form is a
located validation error rather than a silently ignored one. The same rule
covers the two positional sources that are not generators, `(wasm-data …)` and
`(bytes …)`: a `(data …)` names exactly one source, whatever kind it is.

For bytes no generator can make — a table a bake step packed, a font subset —
see [Raw Bytes](#raw-bytes).

**Static meshes** (indexed — produces vertex data + an index companion):

```sjon
(data :name teapotMesh (teapot :format [position3 normal3]))
(data :name dragonMesh (dragon :format [position3 normal3 uv2]))
```

The index buffer sources its size, initial bytes, and index-format (u16/u32) from
the indexed shape's companion via `:index-of <data-ref>` — `teapotMesh` is a real
`(data …)` cross-ref the validator resolves (a synthetic `teapotMesh_indices` name
would not):

```sjon
(buffer :name vb :usage [vertex] :data teapotMesh)
(buffer :name ib :index-of teapotMesh :usage [index])

(render-pass :name draw
  ; …
  :vertex-buffers [vb]
  :index-buffer ib
  (draw-indexed :index-count 2976))   ; teapot: 992 triangles × 3
```

The index format is propagated to `set_index_buffer` at runtime.

**GPU-generated indexed geometry** (no `:index-of` companion): when a compute
pass writes the indices itself, declare the format explicitly with
`:index-format`, and drive the draw from a GPU-written argument buffer with
`(draw-indexed-indirect …)`:

```sjon
(define :name MAX_INDICES :value 65536)
(buffer :name indexBuffer :size (* MAX_INDICES 4) :usage [index storage]
  :index-format uint32)
(buffer :name indirectArgs :size 20 :usage [indirect storage])

(render-pass :name draw
  (color-attachment :view context-current-texture :clear-value [0 0 0 1] :load-op clear :store-op store)
  :pipeline pipe
  :index-buffer indexBuffer
  ; GPUDrawIndexedIndirectArgs (5×u32) read from the buffer at :offset
  (draw-indexed-indirect :buffer indirectArgs :offset 0))
```

See `examples/webgpu_marching_cubes.sjon` for a full per-frame GPU meshing
pipeline built on both. The argument-buffer forms themselves (all three of
them) are covered in the Indirect Draws and Dispatch section below.

**Format specifiers**: `position3`, `position4`, `normal3`, `color3`, `color4`,
`uv2`. For indexed meshes, UVs are computed via XY-plane projection if `uv2` is
in the format list.

| Shape          | Type    | Vertices | Triangles | Indexed Size (pos3+normal3) |
| -------------- | ------- | -------- | --------- | --------------------------- |
| cube           | proc    | 36       | 12        | 864B                        |
| plane          | proc    | 6        | 2         | 144B                        |
| sphere (24×12) | proc    | 1728     | 576       | 41KB                        |
| teapot         | static  | 792      | 992       | ~25KB                       |
| dragon         | static  | 6710     | 11102     | ~222KB                      |

**Note**: The teapot (~25KB) fits PNGine's <50KB payload target. The dragon
(~222KB) is for non-size-constrained use cases (HTML output, desktop rendering).

### Built-in Data Sources

Runtime-provided uniform data that can be used in `(queue …)` `write-buffer`
operations:

| Identifier          | Size     | Description                                             |
| ------------------- | -------- | ------------------------------------------------------- |
| `pngine-inputs`     | 16 bytes | time(f32), width(f32), height(f32), aspect(f32)         |
| `scene-time-inputs` | 12 bytes | time(f32), width(f32), height(f32) — the first 12 bytes of `pngine-inputs` |
| `pngine-frame-inputs` | 20 bytes | the 16 bytes of `pngine-inputs`, then frameIndex(u32) — the executor's frame counter, which is also the ping-pong pool phase |
| `pointer-inputs`    | 48 bytes | x(f32), y(f32), clickX(f32), clickY(f32), dx(f32), dy(f32), buttons(f32), pressure(f32), modifiers(f32), scrollX(f32), scrollY(f32), _pad(f32) |

**Example: Writing runtime inputs to a uniform buffer**

```sjon
(buffer :name uniforms :size 16 :usage [uniform copy-dst])

(queue :name writeInputs
  ; pngine-inputs: runtime provides time/canvas data each frame
  (write-buffer :buffer uniforms :offset 0 :data pngine-inputs))

(frame :name main :perform [writeInputs myRenderPass])  ; queue listed explicitly
```

**In WGSL (shader developer chooses binding):**

```wgsl
struct PngineInputs {
    time: f32,           // elapsed seconds since start
    canvasWidth: f32,    // canvas width in pixels
    canvasHeight: f32,   // canvas height in pixels
    aspect: f32,         // width / height
}

@group(0) @binding(0) var<uniform> pngine: PngineInputs;
```

### Built-in Math Constants

Three names are substituted into every WGSL body at compile time, so a shader
can spell them symbolically and the GPU still sees a plain literal:

| Name  | Inlined value       |
| ----- | ------------------- |
| `TAU` | 6.283185307179586   |
| `PI`  | 3.141592653589793   |
| `E`   | 2.718281828459045   |

The match is whole-word and skips declarations, so a longer name that merely
contains one (`TWO_PI`, `PIE`) is untouched.

Because the *uses* are replaced but a declaration is not, declaring one of
these yourself leaves the declaration behind with nothing referring to it:

```wgsl
const TAU: f32 = 6.2831853;         // don't — TAU is already built in
fn f(t: f32) -> f32 { return cos(TAU * t); }
```

The `cos(TAU * t)` becomes `cos(6.283185307179586 * t)`, the `const` is now
unread, and `validate` reports it as `'TAU' is declared but never used`
(W0001). Just use `TAU` without declaring it.

### Uniforms (runtime reflection)

There is no `(uniform …)` form. Uniforms are declared in **WGSL** and the
compiler reflects them: every `var<uniform>` binding is scanned with wgslender
and recorded in the bytecode's uniform table, so the runtime can address fields
by name without recompiling.

Nested structs are flattened at compile time into dot-notation paths, so a
`material.albedo` field is addressed as `"material.albedo"`. Fields are keyed
by name, not by declaration order — renaming a WGSL field renames the runtime
key.

From JS:

```js
import { setUniform, setUniforms } from 'pngine';

setUniform(p, 'colorShift', 0.25);
setUniforms(p, { colorShift: 0.25, 'material.albedo': [1, 0.5, 0, 1] });
```

The name is the field as declared in the WGSL struct. Both draw at once by
default; `{ redraw: false }` as the trailing options stores the value for the
next draw instead, spelled the way `writeBuffer` spells it.

**Array uniforms.** A fixed-size array (`array<vec4f, 2>`) is reflected as a
single field whose recorded type is the *element* type and whose `elem_count`
is the array length; `size` is the total byte span. A non-array field records
`elem_count = 0`. Older payloads predate the field and read back as 0, so
"not an array" and "old payload" are the same value by design.

A whole array uniform accepts either a flat list or one nested array per
element — both write the same bytes:

```js
setUniform(p, 'env', [r0, g0, b0, a0, r1, g1, b1, a1]);      // flat
setUniform(p, 'env', [[r0, g0, b0, a0], [r1, g1, b1, a1]]);  // nested
```

A short value is not an error: elements past the end of the input keep their
zero bytes rather than the write being rejected.

Individual elements are addressed with a **dotted** index — `env.1`, not
`env[1]` — so that an element target is a single token in animation scores.

⚠️ The uniform-table tags are a **coupling point**: the browser editor
(pstudio) maps them to animation lane counts (see the `UniformType` comment in
`src/bytecode/uniform_table.zig`). Changing the tag set here breaks it, and no
build edge crosses the repo boundary to catch it.

### Host-writable buffers

Every `(buffer :name …)` is addressable from JS by that name, whatever it
holds — a bare `array<vec2f>` no uniform reflects, a vertex buffer, an
indirect-args buffer. The compiler writes the names into the payload (a block
at the tail of the uniform-table section, behind header flag bit 4, six bytes
plus the name each) and the runtime resolves them:

```js
import { draw, getBuffers, writeBuffer } from 'pngine';

await getBuffers(p);
// { particles: { size: 16384, usage: 0x88, writable: true,  pool: 1, frameWritten: false },
//   uniforms:  { size: 16,    usage: 0x48, writable: true,  pool: 1, frameWritten: true  } }

writeBuffer(p, 'particles', bytes);                     // one draw, carrying the write
writeBuffer(p, 'particles', bytes, { offset: 4096 });
writeBuffer(p, 'particles', bytes, { redraw: false });  // rides the NEXT draw, whoever posts it
draw(p, { time, buffers: { particles: bytes } });       // the primitive both are sugar over
```

Three rules, each refused loudly — `onError` gets a `PngineGPUError` with
source `"write-buffer"` — never dropped:

- **`copy-dst` makes a buffer writable.** `queue.writeBuffer` requires it, and
  `:usage [storage]`, the natural spelling for GPU-computed state, does not
  carry it. Add it: `(buffer :name particles :size … :usage [storage copy-dst])`.
  A buffer with `:data` or `:index-of` gets it implied, because its initial
  bytes arrive the same way.
- **A buffer the frame itself writes every draw is refused.** A host write
  lands at the head of the frame; the frame's own `(write-buffer …)` targets and
  its copy and query-resolve destinations run after it and would overwrite it
  every draw. `getBuffers` reports these as `frameWritten`. Give the host a
  dedicated buffer. An `:init` seed is not frame-written: it runs once per load.
- **A pooled buffer names its member.** `poolIndex: k` for member `k`,
  `"active"` for the member the coming frame reads at `:ping-pong 0`, or no
  `poolIndex` for every member — which is what seeding a ping-pong state means,
  and the one form that needs no frame counter.

Offset and length are multiples of 4, as for an authored `(write-buffer …)`.
Every write is a copy (the draw message is structured-cloned, once), so a slice
out of a host arena is fine and the arena stays the host's. With `redraw:
false` the bytes are read when the next draw is posted, not when `writeBuffer`
returns; `setUniform(p, name, value, { redraw: false })` follows the same rule. `pngine
render … --types` writes `Buffers` and `BufferName` into the `.d.ts` beside
`Uniforms`.

### Ping-Pong Buffer Pattern

For compute simulations (e.g., boids, particles), use pool buffers with offsets:

```sjon
(buffer :name particles :size 32768 :usage [vertex storage] :pool 2)  ; particles_0, _1

(bind-group :name sim :layout computeSim :group 0 :pool 2
  (entry :binding 0 :buffer particles :ping-pong 0)   ; read from
  (entry :binding 1 :buffer particles :ping-pong 1))  ; write to

(compute-pass :name update :pipeline computeSim
  :bind-groups [sim]
  :bind-groups-pool-offsets [0]   ; alternates each frame
  (dispatch :workgroups [64 1 1]))
```

The runtime selects the actual buffer using:

```
actual_id = base_id + (frame_counter + offset) % pool_size
```

### Ping-Pong Texture Pattern

Textures support the same `:pool N` key as buffers, creating sequential
texture IDs for ping-pong render targets:

```sjon
(texture :name feedbackTex :size canvas
  :format rgba8unorm :usage [texture-binding render-attachment] :pool 2)  ; _0, _1
```

For `(pass …)` sugar, use `:feedback true` instead (auto-generates pool textures,
bind groups, and a `prev_<name>` WGSL binding). Feedback lives on an earlier
pass: the last pass renders to the canvas, which has no previous texture to
read, so `:feedback true` there is refused. The last pass reads the fed-back
pass by name:

```sjon
(pass-graph
  (pass :name sim :feedback true :code """
    @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
      let prev = textureLoad(prev_sim, vec2i(pos.xy), 0);
      return prev + vec4f(0.01, 0, 0, 0);
    }
  """)
  (pass :name main :code """
    @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
      return textureLoad(sim, vec2i(pos.xy), 0);
    }
  """))
```

### Textures

`(texture …)` maps to a `GPUTextureDescriptor`. `:size` is **required** — the
IDL member is — and is one key with three spellings: an extent vector
`[w]` / `[w h]` / `[w h d]` (the missing dimensions default to 1, as
`GPUExtent3DDict` does), the symbol `canvas` (tracks the canvas size at
runtime), or an `(image-bitmap …)` name (takes the decoded image's size).
Omitting it is an error rather than a texture. The remaining descriptor fields
are optional and take the WebGPU defaults when omitted (a plain texture emits
none of them, so its encoding is unchanged):

```sjon
(texture :name volume
  :size [64 64 8]              ; the third element is GPUExtent3D depthOrArrayLayers (3d slices / array layers)
  :dimension 3d                ; 1d, 2d (default) or 3d — spelled as WebGPU spells it
  :mip-level-count 4           ; mip levels to allocate (default 1)
  :sample-count 1              ; 1 (default) or 4 (MSAA)
  :format rgba8unorm :usage [texture-binding copy-dst])
```

`:dimension` takes the WebGPU spellings `1d` / `2d` / `3d` (they lex as
unit-bearing numbers, which is why the schema can only spell them since SJON
1.2.0 — a bare `:dimension 3` is a `wrong_underlying` error now, not the old
numeric code, and a non-member like `4d` is a `not_member` that lists the
spellings). A `3d` texture needs a
third `:size` element for its slice count; a 2d **array** keeps `:dimension 2d`
and puts the layer count in that same third element. `:mip-level-count > 1`
allocates a mip chain — levels beyond what you write stay uninitialized until
generated. Note that **sampling** a 1d / 3d / array texture also needs a texture
view whose dimension matches; a default view (used when you bind a texture
directly) is always 2d.

### Texture Views

Binding a `(texture …)` directly (`(entry :texture …)`) gives the shader that
texture's **default 2d view**. To sample a 1d / 3d / **array** / cube texture you
declare an explicit `(texture-view …)` — its `:dimension` must match the
WGSL binding (`texture_2d_array`, `texture_3d`, `texture_cube`, …) — and bind it
with `(entry :texture-view …)`:

```sjon
(texture :name arr :size [256 256 2]
  :dimension 2d      ; a 2-layer 2d array
  :format rgba8unorm :usage [texture-binding copy-dst])

(texture-view :name arr_view :texture arr
  :dimension 2d-array)                        ; the WGSL binding is texture_2d_array

(bind-group :name g :layout pipe :group 0
  (entry :binding 0 :sampler samp)
  (entry :binding 1 :texture-view arr_view))  ; binds the explicit view, not a default one
```

`:dimension` is one of the six `GPUTextureViewDimension` spellings, verbatim
(the IDL member is `GPUTextureViewDescriptor.dimension`; the BGL resource
forms' `:view-dimension` is theirs, `viewDimension`):
`1d`, `2d`, `2d-array`, `cube`, `cube-array`, `3d`. (Before SJON 1.2.0 it was an
integer `0`–`5` in that order; a number there is now a `wrong_underlying`
error, and a misspelled member is a `not_member` whose message lists the six.)

Every other key is optional and defaults to WebGPU's own default (an all-default
view is equivalent to a bare `createView()`): `:aspect` (`all` / `stencil-only` /
`depth-only`), `:base-mip-level` / `:mip-level-count` (a mip sub-range),
`:base-array-layer` / `:array-layer-count` (a layer sub-range), and `:format`
(reinterpret the texel format, e.g. an `-srgb` view of a linear texture).

### Samplers

`(sampler …)` maps directly to a `GPUSamplerDescriptor`. Every field is optional
and every omitted field takes the WebGPU default: filters `nearest`, address
modes `clamp-to-edge`. A sampler that should smooth says so, with
`:mag-filter linear :min-filter linear`.

The filters used to default to `linear` here, on the reasoning that smoothing is
the friendlier default for shader art. That is defensible taste and it was still
wrong: it meant a raw-WebGPU sample ported line for line rendered differently,
and the difference was invisible in the source. `tests/npm/webgpu-conformance.test.js`
now checks every schema default against the extracted IDL, so a default that
drifts from the spec is a failing test rather than a paragraph.

```sjon
(sampler :name samp
  :mag-filter linear :min-filter linear       ; magnification / minification (nearest|linear)
  :mipmap-filter linear                        ; filtering between mip levels
  :address-mode repeat                         ; shorthand: all three axes
  :address-mode-u repeat                        ; per-axis override (U/S)
  :address-mode-v mirror-repeat                 ; per-axis override (V/T)
  :address-mode-w clamp-to-edge                 ; per-axis override (W/R; 3D / cube)
  :lod-min-clamp 0 :lod-max-clamp 8            ; mip level-of-detail window
  :max-anisotropy 4                            ; anisotropic filtering (see note)
  :compare less)                               ; makes it a comparison sampler
```

`:address-mode` sets all three axes at once; a per-axis `:address-mode-u/v/w`
overrides just that axis. Address modes are `clamp-to-edge`, `repeat`, or
`mirror-repeat`.

`:max-anisotropy` is an integer in `[1,16]`; **values > 1 require `linear` mag,
min, and mipmap filters** (WebGPU rejects the sampler otherwise). `:lod-min-clamp`
/ `:lod-max-clamp` are non-negative reals (defaults 0 and 32) and only matter for a
mipmapped texture. `:compare` (a `compare-function`: `never`, `less`, `equal`,
`less-equal`, `greater`, `not-equal`, `greater-equal`, `always`) turns the sampler
into a `sampler_comparison` — required for depth/shadow sampling.

### Pipeline Layouts

Every pipeline states its layout, because WebGPU requires one. `:layout auto`
**auto-derives** it from the WGSL, which is what most documents want.
To bind `@group(0)`, `@group(1)`, … to **distinct explicit layouts** — the only
way to pin per-group visibility that the shader alone doesn't determine — declare
`(bind-group-layout …)` forms, compose them in order with a `(pipeline-layout …)`,
and name it as the pipeline's `:layout`:

```sjon
(bind-group-layout :name bglColor
  (entry :binding 0 :visibility [fragment] (buffer :type uniform)))
(bind-group-layout :name bglXform
  (entry :binding 0 :visibility [vertex] (buffer :type uniform)))

(pipeline-layout :name pl :bind-group-layouts [bglColor bglXform])   ; @group 0, 1

(render-pipeline :name pipe :layout pl
  (vertex :module mod :entry vs)
  (fragment :module mod :entry fs (color-target :format bgra8unorm)))

(bind-group :name gColor :layout pipe :group 0
  (entry :binding 0 :buffer colorBuf))
(bind-group :name gXform :layout pipe :group 1
  (entry :binding 0 :buffer xformBuf))
```

`:bind-group-layouts` lists the `(bind-group-layout …)` at `@group` 0, 1, … in
order. `:layout` is one required key on both `(render-pipeline …)` and
`(compute-pipeline …)` — `GPUPipelineDescriptorBase.layout` is one required
member — and its value is either `auto` or the name of a `(pipeline-layout …)`,
never both and never neither. Bind groups take their per-group layout from the **pipeline**
(`:layout pipe :group N`), so each group resolves to
`pipeline.getBindGroupLayout(N)` — the matching entry of the explicit layout.

A BGL `(entry …)` models any of the four WebGPU binding-resource kinds, not just
buffers — the nested form picks the kind, and its enum fields are the WebGPU
spellings passed through verbatim. Exactly one per entry, as
`GPUBindGroupLayoutEntry` says: two resources or none is a located validation
error, not a binding chosen for you.

```sjon
(bind-group-layout :name bgl
  (entry :binding 0 :visibility [fragment] (buffer :type uniform))
  (entry :binding 1 :visibility [fragment] (sampler :type filtering))
  (entry :binding 2 :visibility [fragment]
    (texture :sample-type float :view-dimension 2d :multisampled false))
  (entry :binding 3 :visibility [compute]
    (storage-texture :format r32float :access read-write :view-dimension 2d)))
```

`(sampler :type)` is `filtering`/`non-filtering`/`comparison`;
`(texture :sample-type)` is `float`/`unfilterable-float`/`depth`/`sint`/`uint`;
`(storage-texture :access)` is `write-only`/`read-only`/`read-write`. In both
texture kinds `:view-dimension` takes the same `GPUTextureViewDimension`
spellings as a `(texture-view …)`'s `:dimension` (`1d`, `2d`, `2d-array`, `cube`, `cube-array`,
`3d`). The entry
types must match the WGSL binding they front, or WebGPU rejects the pipeline —
which the native oracle now reports as a nonzero exit rather than a blank frame.
See `examples/webgpu_bgl_resources.sjon`.

#### `:prune-unused` — one bind group, several variants

`:layout auto` keeps only the bindings a pipeline's **entry points statically
reach**. Two pipelines over one module therefore get two different layouts, and
a bind group written for the larger one desyncs from the smaller. WebGPU does
not warn about that: it aborts at the first `set_bind_group` with

```text
Number of bindings in bind group descriptor (2) does not match the number of
bindings defined in the bind group layout (1)
```

on whoever's machine loads the payload. `:prune-unused true` drops those entries
at compile time instead, so one description serves both:

```sjon
(shader-module :name code :code """
struct Cam { m: mat4x4f }
@group(0) @binding(0) var<uniform> cam: Cam;
@group(0) @binding(1) var<uniform> tint: vec4f;
@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  return cam.m * vec4f(f32(i), 0.0, 0.0, 1.0);
}
@fragment fn depthOnlyFs() -> @location(0) vec4f { return vec4f(1.0); }
@fragment fn litFs() -> @location(0) vec4f { return tint; }
""")
(buffer :name camBuf :size 64 :usage [uniform copy-dst])
(buffer :name tintBuf :size 16 :usage [uniform copy-dst])

(render-pipeline :name depthPipe :layout auto
  (vertex :module code :entry vs)
  (fragment :module code :entry depthOnlyFs (color-target :format preferred-canvas-format)))
(render-pipeline :name litPipe :layout auto
  (vertex :module code :entry vs)
  (fragment :module code :entry litFs (color-target :format preferred-canvas-format)))

; The same two entries against both layouts. Only the depth one prunes.
(bind-group :name depthGroup :layout depthPipe :group 0 :prune-unused true
  (entry :binding 0 :buffer camBuf)
  (entry :binding 1 :buffer tintBuf))
(bind-group :name litGroup :layout litPipe :group 0 :prune-unused true
  (entry :binding 0 :buffer camBuf)
  (entry :binding 1 :buffer tintBuf))
```

Each drop is a warning naming the slot and the pipeline, so pruning is never
silent. Three things to know:

- **It needs an auto-derived layout.** On a group whose `:layout` names an
  explicit `(bind-group-layout …)` there is nothing to prune against — that
  layout *is* the one being bound — and the key is a validation error rather
  than a no-op, because a key that reads as applied and did nothing is the
  failure this feature exists to prevent.
- **Pruning to nothing is refused.** A group that loses every entry either sits
  below the highest group index the pipeline reaches, where WebGPU still
  requires a bind group to be set, or above it, where it belongs out of the
  pass's `:bind-groups` list. Only you can say which, so the compiler asks.
- **The used-but-unbound check agrees with it.** That check asks whether the
  entry points *this pipeline* instantiates reach a binding, not whether any
  entry point of the module does — so what pruning removes is exactly what the
  check no longer demands. Before those two were aligned, the document above
  could not compile at all.

`examples/test_prune_unused.sjon` is the worked version.

### Derived bind groups: leave `:layout` out

`:layout` names the pipeline whose auto-derived layout a group is built
against, so a resource set that several pipelines share costs one form per
pipeline, identical but for that key. Leave the key out and the compiler
derives the groups: one GPU bind group per pipeline that binds the group
through a `render-pass`, `compute-pass` or `render-bundle`, each holding only
the entries that pipeline's entry points reach. The two `:prune-unused` groups
above become one form:

```sjon
(shader-module :name code :code """
struct Cam { m: mat4x4f }
@group(0) @binding(0) var<uniform> cam: Cam;
@group(0) @binding(1) var<uniform> tint: vec4f;
@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  return cam.m * vec4f(f32(i), 0.0, 0.0, 1.0);
}
@fragment fn depthOnlyFs() -> @location(0) vec4f { return vec4f(1.0); }
@fragment fn litFs() -> @location(0) vec4f { return tint; }
""")
(buffer :name camBuf :size 64 :usage [uniform copy-dst])
(buffer :name tintBuf :size 16 :usage [uniform copy-dst])

(render-pipeline :name depthPipe :layout auto
  (vertex :module code :entry vs)
  (fragment :module code :entry depthOnlyFs (color-target :format preferred-canvas-format)))
(render-pipeline :name litPipe :layout auto
  (vertex :module code :entry vs)
  (fragment :module code :entry litFs (color-target :format preferred-canvas-format)))

; One resource set. Each pass's pipeline decides what it becomes: one entry
; for depthPipe, two for litPipe.
(bind-group :name scene :group 0
  (entry :binding 0 :buffer camBuf)
  (entry :binding 1 :buffer tintBuf))

(render-pass :name depthDraw
  (color-attachment :view context-current-texture :clear-value [0 0 0 1] :load-op clear :store-op store)
  :pipeline depthPipe :bind-groups [scene]
  (draw :vertex-count 3))
(render-pass :name litDraw
  (color-attachment :view context-current-texture :load-op load :store-op store)
  :pipeline litPipe :bind-groups [scene]
  (draw :vertex-count 3))
(frame :name main :perform [depthDraw litDraw])
```

Written with two `:layout` groups and `:prune-unused`, this document compiles
to the same bytes. The derived groups are numbered in form order and then in
pipeline order, which is the order two authored groups, one per pipeline,
take, so nothing in the payload moves when you fold them.
`examples/test_derived_bind_groups.sjon` is the worked version; it is
`test_prune_unused.sjon` with one group, and the two traces are pinned equal.

The rules, each one a compile-time answer:

- **`:group` and `:pool` keep their meaning.** `:group` is the `@group` index
  the derived layout is picked at; `:pool N` reserves N ids for each pipeline.
- **A pipeline with an explicit `(pipeline-layout …)` cannot bind a derived
  group.** Its bind-group-layouts are the layout, so there is no reachable set
  to derive from, and pruning by reflection would drop entries they still
  demand. Name the `(bind-group-layout …)` as `:layout` instead, as the
  explicit arm always has.
- **`:prune-unused` on a derived group is refused as redundant.** The group is
  already pruned for every pipeline that binds it.
- **An instance that prunes to nothing is omitted or refused.** Above the
  highest group index the pipeline reaches, nothing is emitted and the pass
  sets nothing at that slot (a material group at `:group 1` that a depth
  pipeline never touches). At or below it, WebGPU requires an empty bind group
  to be set, which pngine does not build, so the document is refused; give
  that pipeline a binding at every group index up to its highest.
- **A bundle's list is dense.** Its `:bind-groups` reaches the wire as entry i
  at slot i, so an omitted instance cannot be skipped there. Remove the group
  from that bundle's list.
- **Two advisories under `validate`.** A derived group that no pass or bundle
  binds emits nothing and says so; an entry that no binding pipeline reaches
  is dropped from every instance and says so, because that is a typo's shape
  as often as a design's.

### Vertex Input Layout

A `(vertex …)` stage that reads vertex buffers declares their layout with one
`(vertex-buffer …)` child per bound slot, in slot order, each holding its
`(attribute …)` children:

```sjon
(render-pipeline :name pipe :layout auto
  (vertex :module code :entry vertMain
    (vertex-buffer :array-stride 40
      (attribute :shader-location 0 :offset 0  :format float32x4)
      (attribute :shader-location 1 :offset 16 :format float32x4)
      (attribute :shader-location 2 :offset 32 :format float32x2)))
  (fragment :module code :entry fragMain
    (color-target :format preferred-canvas-format)))
```

| Key                | Form            | Notes                                          |
| ------------------ | --------------- | ---------------------------------------------- |
| `:array-stride`    | `vertex-buffer` | Bytes between elements; multiple of 4          |
| `:step-mode`       | `vertex-buffer` | `vertex` (default) or `instance`               |
| `:shader-location` | `attribute`     | The `@location(N)` it feeds                    |
| `:offset`          | `attribute`     | Byte offset within one element                 |
| `:format`          | `attribute`     | `float32x4`, `uint32`, … (GPUVertexFormat)     |

Ordering is positional: the first `(vertex-buffer …)` is slot 0 and pairs with
the first entry of the render pass's `:vertex-buffers [...]` list. The strides
and offsets are not derived from the WGSL — a mismatch between `:array-stride`
and the real packing yields garbled geometry rather than a compile error.

Omit the `(vertex-buffer …)` children entirely for pipelines that generate
their vertices from `@builtin(vertex_index)` (the fullscreen-quad and
`(pass …)` cases).

See `examples/rotating_cube.sjon` (interleaved) and `examples/boids.sjon`
(`:step-mode instance` for per-instance data).

### Fragments and imports (`(wgsl …)`)

Shader code repeats. Across the corpus `fn perspective` is written 37 times and
`fn hash` 20 times, and single documents restate a struct across their own
modules. A **fragment** is a named piece of WGSL that exists only to be
imported:

```sjon
(wgsl :name noise :code """
fn hash(p: vec2f) -> f32 { return fract(sin(dot(p, vec2f(12.9898, 78.233))) * 43758.5453); }
fn vnoise(p: vec2f) -> f32 {
  let i = floor(p); let f = fract(p);
  let u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2f(1.0, 0.0)), u.x),
             mix(hash(i + vec2f(0.0, 1.0)), hash(i + vec2f(1.0, 1.0)), u.x), u.y);
}
""")
(shader-module :name art :imports [noise] :code """
@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  return vec4f(vnoise(vec2f(f32(i))), 0.0, 0.0, 1.0);
}
@fragment fn fs(@builtin(position) c: vec4f) -> @location(0) vec4f {
  return vec4f(vnoise(c.xy * 0.01), 0.0, 0.0, 1.0);
}
""")
```

A fragment is **not a GPU object**. It has no bytecode, no data blob and no
`GPUShaderModule`. What reaches WebGPU is the **assembled module**: every
fragment the root imports, transitively, in dependency order, each exactly once,
followed by the root's own text. Validation, `(constant …)` substitution,
minification and reflection all run once over that whole text, which is why
renames stay consistent across fragment boundaries and why dead-code
elimination drops the fragment functions a root never calls.

A fragment carries exactly one of `:code` or `:file`, and may import others:

| Key | Meaning |
| --- | --- |
| `:name` | The name other forms write in their `:imports`. |
| `:code` | Inline WGSL. Exactly one of `:code` or `:file`. |
| `:file` | A path to a `.wgsl` file, relative to the document. |
| `:imports` | Fragments assembled ahead of this one. Acyclic; at most 64. |
| `:requires` | WGSL names this fragment uses but does not declare. `validate` checks the list against the fragment's own text, both ways. |

`(shader-module …)` gains `:imports` and the same `:code` / `:file` choice;
`(pass …)` gains `:imports`.

#### Holes: one fragment, several instances

WGSL does not care what order module-scope declarations appear in, so an
assembled module is one unit and a fragment may **call something it does not
define**. The importing module supplies it. That is how one library serves
several variants without any WGSL extension:

```sjon
(wgsl :name fbm :requires [noise2] :code """
fn fbm(p: vec2f) -> f32 {
  var sum = 0.0; var amp = 0.5; var q = p;
  for (var i = 0; i < 5; i = i + 1) { sum = sum + amp * noise2(q); q = q * 2.0; amp = amp * 0.5; }
  return sum;
}
""")
(wgsl :name valueInstance :code """
fn noise2(p: vec2f) -> f32 { return fract(sin(dot(p, vec2f(12.9898, 78.233))) * 43758.5453); }
""")
(shader-module :name valueArt :imports [valueInstance fbm] :code """
@fragment fn fs(@builtin(position) c: vec4f) -> @location(0) vec4f {
  return vec4f(fbm(c.xy * 0.01), 0.0, 0.0, 1.0);
}
""")
```

`:requires` is optional but worth writing: it names the holes, so a module that
forgets one is told which fragment wanted it, instead of getting an unresolved
identifier pointing into assembled text nobody wrote.

The list is checked, not trusted. `pngine validate` validates each fragment on
its own (with its imports, before any module assembles it) and reads the names
wgslender cannot resolve on the fragment's lines; those are its holes. A listed
name that is not a hole warns (it is unused, or the fragment or one of its
imports declares it); a hole that is not listed warns, at its first use. Both
are advisory and `validate`-only, like the rest of the lint channel: `compile`
and `render` never run the check, and `--strict` turns either into exit 1.

**Every hole must be filled, whether or not it is reached.** Validation runs
before dead-code elimination, so a fragment's unused function still has to
resolve. Splitting a library finely is how you avoid carrying a declaration only
to satisfy a function you never call.

#### Rules

- **Fragments declare no entry points.** No `@vertex`, `@fragment` or
  `@compute` in a `(wgsl …)`. Two roots importing one fragment would each
  declare that stage, and a `(pass …)` decides what kind of pass it is by
  reading its own body, which never sees fragment text.
- **A fragment imported by a `(pass …)` declares no bindings.** The pass
  prelude numbers `@group(0)` itself — uniforms, sampler, one texture per prior
  pass, the data buffers — so a fragment's `@group`/`@binding` variable has
  nowhere to be bound. The same fragment is fine under a `(shader-module …)`,
  whose bind groups you write yourself.
- **Feature detection reads the pass body only.** A fragment that mentions
  `pngine.time` does not make the prelude declare the uniform; the assembled
  module then fails validation with an ordinary unresolved-identifier error.
  Mention `pngine` in the pass's own `:code`.
- **The import graph is acyclic**, each fragment appears once per assembled
  module, and a name that no `(wgsl …)` declares is a cross-reference error.
- **Fragments share the document's namespace**, so a fragment named like a
  buffer is a duplicate declaration.

#### File-backed fragments

`:file` reads a plain `.wgsl` file next to the document. It is ordinary WGSL —
nothing pngine-specific, no extension — so it opens in any editor and pastes
into any other tool:

```text
(wgsl :name mesh :file "./lib/mesh.wgsl" :imports [camera])
(shader-module :name lit :file "./lit.wgsl" :imports [mesh])
```

Paths are relative to the document and may not climb out of its directory. In
the browser there is no filesystem: the host supplies the bytes, and the
compiler reports every file it is missing at once — see `compileWithLoader` in
the npm package.

### Extending a document (`(import …)`)

A `(wgsl …)` fragment shares shader text between documents. `(import …)` shares
the **forms**: it compiles another `.sjon` document ahead of this one, so a
program that differs from another only in a value, or in one fragment, does
not copy the rest.

The imported document is written to be extended — it names the knob as a
`(define …)` with a default, and reads it wherever the value is used:

```sjon
(define :name SHADOW_SIZE :value 256)
(texture :name shadowMap :size [SHADOW_SIZE SHADOW_SIZE]
  :format depth32float :usage [render-attachment texture-binding])
```

and the extending document is the import plus its rebindings, which are
children of the import itself:

```text
(import :file "./shadow_scene.sjon"
  (define :name SHADOW_SIZE :value 1024))
```

A `(wgsl …)` fragment is rebound the same way. Where the imported document
keeps a function in a fragment of its own, the importer supplies another body:

```sjon
(import :file "./pass_acid_cubes.sjon"
  (wgsl :name cellDist :code """
  fn cellDist(d_star: f32, d_wall: f32) -> f32 {
    return min(d_star, d_wall);
  }
"""))
```

Every module that `:imports` that fragment in the imported document now
assembles the importer's text in its place. `examples/pass_acid_lattice.sjon`
is exactly this: its twin with one function swapped, and nothing copied.

Rules, all of them:

- **The imported forms come first**, then this document's own. Cross-references
  resolve across the whole composition, exactly as they do inside one file.
- **Only a consumed form may be rebound: `(define …)` and `(wgsl …)`.** Both
  lower to nothing and emit nothing, so rebinding one changes a value or a
  fragment's text and moves no byte of anything else. Everything else is
  shared as written. Re-declaring an imported `(texture …)` is not an
  override, it is two forms with one name, and the validator refuses it as
  `duplicate_cross_ref_target`; writing one inside the import is refused
  against the schema.
- **A rebound name must be declared by the imported document, under the same
  head.** A misspelt one is refused rather than silently ignored, and a
  `(wgsl :name N …)` does not rebind a `(define :name N …)`, which is what
  makes the rebinding safe to write.
- **Imports are transitive**, a document is composed at most once however many
  paths reach it, and a cycle is refused.
- **Paths are relative** to the compile's root and may not climb out of it, the
  same rule every other `:file` follows. In the browser there is no filesystem:
  the host supplies each document's bytes, and because an import is found by
  parsing, a document that imports a document that imports something takes one
  fetch round per level.
- The imported document still compiles on its own. Its defines have defaults,
  so it is a program, not a template.

The payload is the one the imported document would have produced, with the
value or the fragment changed: neither a define nor a fragment has an emission
position (a fragment's place in a module comes from `:imports` order, never
from where the form sits), so rebinding one moves nothing and renames nothing.

### Pipeline-overridable constants (`(constant …)`)

A WGSL `override` declaration is a value supplied when the pipeline is created.
pngine resolves it at **compile time** instead: `(constant …)` substitutes the
value into the shader text, turning the `override` into a `const` before the
module is validated, minified and shipped.

```sjon
(define :name GROUP :value 64)
(shader-module :name code :code """
override QUALITY: u32 = 1u;
override SCALE: f32;
override WG: u32 = 64u;
@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  return vec4f(f32(i) * SCALE, f32(QUALITY), 0, 1);
}
@fragment fn fs() -> @location(0) vec4f { return vec4f(SCALE, 0, 0, 1); }
@compute @workgroup_size(64) fn cs(@builtin(global_invocation_id) id: vec3u) {
  _ = id.x / WG;
}
""")
(render-pipeline :name pipe :layout auto
  (vertex :module code :entry vs
    (constant :name QUALITY :value 3))
  (fragment :module code :entry fs
    (color-target :format bgra8unorm)
    (constant :name SCALE :value 0.5)))

(compute-pipeline :name cp :layout auto
  (compute :module code :entry cs
    (constant :name WG :value (* GROUP 1))))
```

`:value` is an ordinary numeric slot, so it takes a literal, a bounded
expression over `(define …)` constants, or a bare define name — `GROUP` and
`(* GROUP 1)` both work.

Because the value is substituted, an `override` with no default — which no
runtime can create a pipeline for, and which pngine rejects outright — becomes
authorable:

```
override SCALE: f32;    ; alone: "declares no default", a compile error
                        ; with (constant :name SCALE :value 0.5): fine
```

Four rules, all enforced at compile time:

- The name must be a real `override` in that stage's module. A typo is an error,
  not a silently ignored key.
- The value must fit the override's **declared WGSL type**: a fractional value
  for a `u32`/`i32`, or anything but 0/1 for a `bool`, is rejected. The schema
  cannot check this — the width lives in the shader.
- An `@id(N)`-annotated override is still named by its **identifier**. The
  numeric id is a runtime key, and no value reaches a runtime here.
- Constants are written per stage (mirroring `GPUProgrammableStage.constants`)
  but applied per **module**. Two stages specialising one module's override
  differently is an error; restating the same value on both is fine. Two
  *modules* may of course differ, which is what makes an `override` in a
  shared fragment useful: each importing module fixes it at its own value,
  because each assembles its own text.
- A `(pass …)` has no stage form to write these on, so it takes `(constant …)`
  children directly and the sugar forwards them; see
  [`(pass …)` Sugar](#pass--sugar-shorthand-for-shader-art).
- Turning an `override` into a `const` does **not** remove an untaken branch.
  Dead-code elimination works by reachability from entry points, not by folding
  conditions, so `if (QUALITY > 1u)` keeps both arms. What specialisation buys
  is a fixed value and a renameable name; to drop code, put the variants in
  different fragments and import the one you want.

Specialisation is why `@workgroup_size(WG)` is worth doing this way: with `WG`
resolved, the reflected workgroup size is a real number again, so the
dispatch-grid and device-limit checks work instead of being skipped.

### Primitive State

`(primitive …)` mirrors `GPUPrimitiveState`. Beyond `:topology`, `:cull-mode`,
and `:front-face`, two fields cover the rest of the descriptor:

```sjon
(render-pipeline :name strip :layout auto
  (vertex :module code :entry vs)
  (fragment :module code :entry fs (color-target :format bgra8unorm))
  (primitive :topology triangle-strip :strip-index-format uint32 :unclipped-depth true))
```

- `:strip-index-format` (`uint16` / `uint32`) — the index byte-width WebGPU needs
  when `(draw-indexed …)` runs under a **strip** topology (`triangle-strip` /
  `line-strip`); it selects the primitive-restart value. Omit it for list
  topologies and non-indexed draws — and that is checked both ways now. Under a
  list topology the key does not exist at all: the schema declares it inside
  `(variant :when [triangle-strip line-strip] …)`, so writing it there is an
  `unknown_key` at validation (WebGPU would ignore it). The other way is the
  emitter's, because it crosses two forms: an indexed draw in a pass whose
  pipeline is a strip without it is an error too (WebGPU rejects the draw).
- `:unclipped-depth` (boolean) — disables depth clipping, clamping fragments to
  `[0, 1]` instead of discarding them (shadow casters, depth pre-passes). It needs
  the `depth-clip-control` device feature, which both the browser runtime and the
  native renderer request **opportunistically** (only when the adapter advertises
  it), so a pipeline that sets it renders wherever the GPU supports it.

Both are emitted into the pipeline descriptor only when authored — a plain
`(primitive …)` stays byte-identical to before.

### Blending & the blend constant

A fragment `(color-target …)` carries an optional `(blend …)` mirroring
`GPUBlendState` — a `(color …)` and an `(alpha …)` component, **both required**
(a `(blend …)` with only one is a validation error), each with
`:src-factor`, `:dst-factor`, and `:operation` (the WebGPU spellings, e.g.
`src-alpha`, `one-minus-src-alpha`, `add`). Omit `(blend …)` for opaque targets.

When a factor is `constant` or `one-minus-constant`, the constant colour itself
is render-pass state, set with `:blend-constant [r g b a]` (four floats, default
`[0 0 0 0]`):

```sjon
(render-pipeline :name pipe :layout auto
  (vertex :module code :entry vs)
  (fragment :module code :entry fs
    (color-target :format preferred-canvas-format
      (blend
        (color :src-factor constant :dst-factor one-minus-constant :operation add)
        (alpha :src-factor one :dst-factor zero :operation add)))))

(render-pass :name draw
  (color-attachment :view context-current-texture
    :clear-value [0 0 0 1] :load-op clear :store-op store)
  :pipeline pipe
  :blend-constant [0.9 0.4 0.1 1.0]              ; consumed by the constant factors
  (draw :vertex-count 3))
```

Both the authored blend state and `:blend-constant` execute on every non-`mini`
tier (the `mini` pNGf tier refuses a payload that sets a blend constant at
write). See `examples/webgpu_blend_constant.sjon`.

A `(color-target …)` also takes `:write-mask`, the per-channel colour write mask:
either an integer bitmask (`R=1 G=2 B=4 A=8`, so `5` writes red and blue) or the
symbol `all` (15, the WebGPU default). `:write-mask 0` writes no colour at all —
the idiom for a depth-only or occlusion pre-pass that still needs a fragment
stage, as in `examples/webgpu_a_buffer.sjon`.

**`:load-op` and `:store-op` are required.** WebGPU gives neither a default, on
purpose: whether a pass clears its target or draws over what is already there is
not something a renderer should guess. A first pass usually wants
`:load-op clear :store-op store`; a pass compositing over an earlier one wants
`:load-op load`.

**Clear-value precision**: `:clear-value` channels travel as f32 per channel, so
they arrive as authored — including values outside `[0,1]`, which are legal
WebGPU on a float target. They used to be quantized to 8-bit UNorm and clamped,
which is invisible on an 8-bit canvas (the round trip is the identity there) and
wrong the moment a pass clears an `rgba16float` attachment.

### Depth and Stencil

Two forms, on opposite sides of the pipeline/pass split. `(depth-stencil …)` is
**pipeline** state — how this pipeline tests and writes depth and stencil.
`(depth-stencil-attachment …)` is **pass** state — which texture it tests against and
what happens to it at the pass boundary.

```sjon
(texture :name depthTex :size canvas :format depth24plus-stencil8
  :usage [render-attachment])

(render-pipeline :name pipe :layout auto
  (vertex :module code :entry vs)
  (fragment :module code :entry fs (color-target :format bgra8unorm))
  (depth-stencil :format depth24plus-stencil8
    :depth-write-enabled true :depth-compare less
    (stencil-front :compare always :pass-op replace)
    (stencil-back :compare always :pass-op keep)))

(render-pass :name draw
  (color-attachment :view context-current-texture
    :clear-value [0 0 0 1] :load-op clear :store-op store)
  (depth-stencil-attachment :view depthTex
    :depth-clear-value 1.0 :depth-load-op clear :depth-store-op store
    :stencil-clear-value 0 :stencil-load-op clear :stencil-store-op store)
  :pipeline pipe :stencil-reference 1
  (draw :vertex-count 3))
```

`:format` is **required** — it names the depth/stencil attachment format this
pipeline renders to, and WebGPU requires it. The rest are optional and emitted
only when authored: `:depth-write-enabled`, `:depth-compare` (a
`GPUCompareFunction`: `less`, `equal`, `always`, …),
`:stencil-read-mask` / `:stencil-write-mask`
(default `0xFFFFFFFF`), and the three depth-bias fields
`:depth-bias` / `:depth-bias-slope-scale` / `:depth-bias-clamp` (constant and
slope-scaled offsets that kill shadow-map acne; triangles only, default 0).

Per-face stencil state is positional: `(stencil-front …)` for front-facing
primitives and `(stencil-back …)` for back-facing ones, each taking `:compare`
plus `:fail-op`, `:depth-fail-op` and `:pass-op` (`keep`, `replace`, `zero`,
`invert`, `increment-clamp`, …). **The two faces are independent**: an
unauthored face takes the spec default (compare `always`, all ops `keep`), *not*
a copy of the other one. Which face a triangle uses follows its winding under
`(primitive :front-face …)`, so a mask that works on one face does nothing on
the other — see `examples/test_stencil.sjon` (front) and
`examples/test_stencil_back.sjon` (back). The reference value the compare and
`replace` use is pass state, `:stencil-reference`, not pipeline state.

`(depth-stencil-attachment …)` takes `:view` (the depth `(texture …)`) plus independent
load/store pairs for each aspect: `:depth-clear-value` (must be in `[0,1]`),
`:depth-load-op` (`clear` / `load`), `:depth-store-op` (`store` / `discard`),
and `:stencil-clear-value`, `:stencil-load-op`, `:stencil-store-op`.

**Each aspect's op pair is required exactly when the view's format carries that
aspect, and rejected when it does not.** A `depth24plus` view takes the depth
pair and no stencil ops; a `stencil8` view takes the stencil pair and no depth
ops; a `depth24plus-stencil8` view takes both pairs, because an attachment
cannot leave half of its own format unaddressed. WebGPU defaults none of the
four, so a pass that does not say whether it clears or loads is a pass whose
depth depends on what was left in the texture.

**A clear value belongs with a `clear`.** `:depth-clear-value` is required when
`:depth-load-op` is `clear` — `depthClearValue` has no spec default either, so
an omitted one used to mean PNGine picked the depth every fragment tests
against. And stating any clear value beside a `load` is an error rather than
inert input: WebGPU never reads it, so the document would be saying something
that does not happen. Both directions hold for the colour `:clear-value` and
the stencil pair too, with one exception — a colour attachment that clears may
omit `:clear-value`, because `clearValue` *does* have a spec default
(transparent black).

### Multisampling (MSAA)

`(multisample …)` is pipeline state mirroring `GPUMultisampleState`. Its
`:count` must equal the `:sample-count` of every attachment texture the pipeline
renders to, and the multisampled colour attachment resolves to the canvas
through `:resolve-target`:

```sjon
(texture :name msaaTex :size canvas :format bgra8unorm
  :sample-count 4 :usage [render-attachment])

(render-pipeline :name pipe :layout auto
  (vertex :module code :entry vs)
  (fragment :module code :entry fs (color-target :format bgra8unorm))
  (multisample :count 4))

(render-pass :name draw
  (color-attachment :view msaaTex :resolve-target context-current-texture
    :clear-value [0 0 0 1] :load-op clear :store-op discard)
  :pipeline pipe
  (draw :vertex-count 3))
```

`:count` is 1 (default, no MSAA) or 4. `:mask` is the sample coverage bitmask
(default `0xFFFFFFFF`), and `:alpha-to-coverage-enabled` derives coverage from
fragment alpha instead — it requires `:count` > 1. `:store-op discard` on the
multisampled view is the normal choice: the resolved single-sample image is the
output, so keeping the 4× buffer costs bandwidth for nothing. See
`examples/simple_triangle_msaa.sjon` and `examples/alpha_to_coverage.sjon`.

### Draw Calls

A render pass draws through four heads: `(draw …)`, `(draw-indexed …)`, and
their indirect twins `(draw-indirect …)` / `(draw-indexed-indirect …)` (next
section). All four are positional children of the `(render-pass …)`. For the
direct pair, beyond the required count every key defaults the WebGPU way and
is emitted only when authored:

```sjon
(render-pass :name draw
  (color-attachment :view context-current-texture :load-op clear :store-op store)
  :pipeline pipe :vertex-buffers [verts] :index-buffer indices
  (draw-indexed :index-count 36 :instance-count 4
                :first-index 0 :base-vertex 0 :first-instance 0))
```

- `(draw …)`: `:vertex-count` (required), `:instance-count` (default 1),
  `:first-vertex` (default 0, an offset into the vertex buffers **in vertices**),
  `:first-instance` (default 0).
- `(draw-indexed …)`: `:index-count` (required), `:instance-count`,
  `:first-index` (an offset **in indices**), `:base-vertex` (added to each index
  before vertex lookup; signed), `:first-instance`. It needs the pass's
  `:index-buffer`.
- `(draw-indirect …)` / `(draw-indexed-indirect …)`: no counts in the document
  at all; `:buffer` and `:offset` name GPU-written arguments instead. See the
  next section.

Instancing reads per-instance attributes from a vertex buffer declared
`:step-mode instance` — see the Vertex Input Layout section above.

A pass may issue **several** draws, and they run in the order they are written:
a render pass records a command stream, so binding the state once and drawing
the parts is the normal way to draw a scene. `(occlusion-query …)` brackets
count as draws and take their place in the same order.

```sjon
(render-pass :name scene :pipeline pipe
  (color-attachment :view context-current-texture :load-op clear :store-op store)
  :vertex-buffers [verts] :index-buffer indices
  (draw-indexed :index-count 2976)
  (draw :vertex-count 3)
  (draw :vertex-count 3 :first-vertex 3))
```

PNGine used to emit exactly one draw per pass, chosen by a fixed priority over
the four draw heads rather than by document order, so the second and later ones
were dropped in silence. See `examples/test_multi_draw.sjon`.

### Indirect Draws and Dispatch

The draw or dispatch counts can come from a GPU-written argument buffer
instead of the document, which lets a compute pass decide how much geometry
the frame draws. `(draw-indirect :buffer :offset)` reads a
`GPUDrawIndirectArgs` (4×u32: vertexCount, instanceCount, firstVertex,
firstInstance); `(draw-indexed-indirect :buffer :offset)` reads a
`GPUDrawIndexedIndirectArgs` (5×u32) and needs the pass's `:index-buffer`; a
compute pass's `(dispatch-indirect :buffer :offset)` reads a
`GPUDispatchIndirectArgs` (3×u32) instead of the literal counts a
`(dispatch …)` carries. The same two keys every time: `:buffer` names a buffer
with `indirect` usage, and `:offset` (default 0) is a byte offset that WebGPU
requires to be a multiple of 4. All three are commands like their direct
counterparts, so a pass may issue several, and render bundles admit the draw
pair too.

```sjon
(buffer :name drawArgs     :size 16 :usage [storage indirect])   ; 4×u32
(buffer :name dispatchArgs :size 12 :usage [storage indirect])   ; 3×u32

(render-pass :name draw
  ; …
  (draw-indirect :buffer drawArgs))          ; :offset defaults to 0

(compute-pass :name step :pipeline cp :bind-groups [g]
  (dispatch-indirect :buffer dispatchArgs))           ; :offset defaults to 0
```

See `examples/webgpu_indirect_draw.sjon` and `webgpu_indirect_dispatch.sjon`
(a seed compute pass writes the args, the indirect pass reads them), and
`examples/webgpu_marching_cubes.sjon` for the pattern at scale: its compute
pipeline counts the indices it emitted and writes the argument buffer a
`(draw-indexed-indirect …)` then reads, every frame. All three indirect forms
execute on the viewer, `--html`, and native tiers; the `mini` (pNGf) tier
refuses them at write.

### Viewport, Scissor and Render Bundles

A `(render-pass …)` carries three more pieces of optional state and one
alternative to inline drawing:

```sjon
(render-pass :name draw
  (color-attachment :view context-current-texture :load-op clear :store-op store)
  :pipeline pipe
  :viewport [0 0 256 256]          ; [x y w h] or [x y w h minDepth maxDepth]
  :scissor-rect [64 64 128 128]    ; [x y w h] in integer pixels
  :stencil-reference 1
  (draw :vertex-count 3))
```

`:viewport` accepts four numbers (`minDepth`/`maxDepth` default to 0 and 1) or
all six. `:scissor-rect` discards fragments outside the rectangle.
`:stencil-reference` is the value the pipeline's stencil `:compare` tests
against and `replace` writes.

A `(render-bundle …)` pre-records a pipeline plus its buffers, bind groups and
one draw, and a pass replays it through `:execute-bundles` instead of declaring
an inline pipeline and draw:

```sjon
(render-bundle :name bundle :pipeline pipe
  :color-formats [bgra8unorm] :depth-stencil-format depth24plus :sample-count 1
  :vertex-buffers [verts] :bind-groups [g]
  (draw :vertex-count 3 :instance-count 1))

(render-pass :name draw
  (color-attachment :view context-current-texture :load-op clear :store-op store)
  (depth-stencil-attachment :view depthTex :depth-load-op clear :depth-store-op store)
  :execute-bundles [bundle])
```

`:color-formats`, `:depth-stencil-format` and `:sample-count` record the
attachment shape the bundle is compatible with. Together they are WebGPU's
`GPURenderPassLayout`, and three things have to agree on it: the bundle states
it, the `:pipeline` it records derives one from its color targets, depth-stencil
state and multisample count, and the replaying pass derives one from its
attachments. Any disagreement between the three is a compile error, and each is
checked where it is written.

Two of those are easy to miss because the value is not in the form you are
reading. A pass never states its formats or its sample count: WebGPU takes them
from the attachments' textures, so a bundle can lose to a `(texture …)` three
forms away. And an omitted `:sample-count` is 1, so a bundle that says nothing
disagrees with a 4-sample pipeline.

`:color-formats` holds color formats only, and `:depth-stencil-format` a depth
or stencil one. A depth format in the color list is not a way to record a
depth-only bundle; it is rejected on the spot.

`:color-formats` is **required** and needs at least one entry, matching
`GPURenderPassLayout.colorFormats`. Write `[preferred-canvas-format]` for a
bundle replayed into a pass that draws to the canvas. It used to be optional,
and an omitted list left the runtime to guess the canvas format for you, which
is right until the bundle targets an offscreen texture and wrong silently.

The recorded draw is a `(draw …)` or `(draw-indexed …)` child — the same two
forms a render pass issues, with the same keys — and a bundle records exactly
one. See `examples/webgpu_render_bundles.sjon`.

### Canvas configuration

An optional singleton `(canvas …)` form configures how the canvas composites
with the page:

```sjon
(canvas :alpha-mode premultiplied)    ; opaque | premultiplied (default opaque)
```

`opaque` ignores the alpha channel — cheaper compositing, no fringe artifacts
on colored pages — and is the default, as `GPUCanvasConfiguration.alphaMode`.
`premultiplied` blends the canvas with the page, so a transparent clear lets
the page show through; `examples/pngine_background.sjon` is the worked case.

Only the deviation costs anything. The value rides a PNGB header flag that is
CLEAR for `opaque`, so a document that says nothing and a document that says
`opaque` compile to the same bytes; the pNGf (`mini`) export mirrors the flag in
its flags byte, and `--html` emits a second `configure()` only when it is set.
Native `--frame` renders offscreen and ignores alpha-mode entirely.

### Device limits

By default a payload runs against WebGPU's **default** device limits. Some
shaders need more — most commonly a compute entry whose `@workgroup_size`
exceeds the default `maxComputeWorkgroupSizeX` / `maxComputeInvocationsPerWorkgroup`
(both 256). Declare the raised limits with a single top-level `(limits …)` form
(one per document); each key is the WebGPU limit name in **kebab-case** and takes
a non-negative integer:

```sjon
(limits
  :max-compute-workgroup-size-x 512
  :max-compute-invocations-per-workgroup 512)

(shader-module :name code :code """
@compute @workgroup_size(512, 1, 1) fn main() { /* … */ }
""")
```

Without the form the compiler **rejects** `@workgroup_size(512)` (it exceeds the
default cap) — the same message you would otherwise only hit as an unexplained
pipeline-creation failure at load time.

Authored limits are **requirements**, not hints (unlike device *features*, which
are requested opportunistically). They are passed verbatim to `requestDevice`'s
`requiredLimits` on the viewer and `--html` tiers and to the native `--frame`
renderer; an **unsatisfiable** limit fails **loudly** — `requestDevice` rejects
(surfaced via the worker error channel / a nonzero native exit) — never silently
clamped to the adapter. Names cover the full `GPUSupportedLimits` set (e.g.
`:max-buffer-size`, `:max-storage-buffer-binding-size`, `:max-texture-dimension-2d`);
a few newer ones (e.g. `:max-bind-groups-plus-vertex-buffers`) have uneven browser
support and will simply reject on a device that lacks them. The `mini` pNGf tier
refuses a limits-bearing payload at write (it requests a bare device by design).
See `examples/webgpu_compute_512.sjon`.

### Queries (occlusion and timestamp)

A `(query-set …)` declares a pool of `:count` queries of one `:type` —
`occlusion` (samples that passed depth/stencil) or `timestamp` (GPU clock).
Results live on the GPU until a `(resolve-query-set …)` queue action copies them
into a buffer, 8 bytes per query.

```sjon
(query-set :name occ :type occlusion :count 6)
(buffer :name results :size 48 :usage [query-resolve copy-src])

(render-pass :name draw
  (color-attachment :view context-current-texture :load-op clear :store-op store)
  :pipeline pipe :occlusion-query-set occ
  (occlusion-query :query-index 0 (draw :vertex-count 36 :first-instance 0))
  (occlusion-query :query-index 1 (draw :vertex-count 36 :first-instance 1)))

(queue :name readback
  (resolve-query-set :query-set occ :first-query 0 :query-count 6
    :destination results :destination-offset 0))
```

`(occlusion-query …)` **brackets** draws rather than sitting beside them: its
positional children are the draws — any of the four, `(draw …)`,
`(draw-indexed …)`, `(draw-indirect …)`, `(draw-indexed-indirect …)`, at least
one — whose passing samples are counted into `:query-index` of the pass's
`:occlusion-query-set`.

Timestamps attach to a pass instead of bracketing draws:

```sjon
(query-set :name ts :type timestamp :count 2)

(render-pass :name draw
  (color-attachment :view context-current-texture :load-op clear :store-op store)
  (timestamp-writes :query-set ts :beginning-of-pass-write-index 0 :end-of-pass-write-index 1)
  :pipeline pipe
  (draw :vertex-count 3))
```

`:beginning-of-pass-write-index` (default 0) and `:end-of-pass-write-index`
(default 1) are the indices written at pass start and end — the IDL's own
words, long as they are. WebGPU leaves both optional and absent means "not
written"; pngine bakes 0 and 1 because the opcode carries two indices and no
absent marker, so "write only the end" is not expressible yet (a recorded
capability). `(resolve-query-set …)` needs `:destination` to carry `query-resolve`
usage, and WebGPU requires `:destination-offset` to be a multiple of 256. See
`examples/webgpu_occlusion_query.sjon` and `examples/webgpu_timestamp_query.sjon`.

### Copies

Three `(queue …)` actions copy between GPU resources; none of them transfers
through the CPU. That absence is a contract, not an accident of these three
forms: nothing a copy produces decides what a frame executes (the full
statement lives in `docs/architecture.md`'s Core Concepts), and a copy into a
`map-read` buffer is a buffer the host may map, never one the schedule reads.

```sjon
(texture :name history :size canvas :format preferred-canvas-format
  :usage [copy-dst texture-binding])

(queue :name copies
  (copy-buffer-to-buffer :source results :source-offset 0
    :destination readback :destination-offset 0 :size 48)
  (copy-texture-to-texture (source :texture context-current-texture) (destination :texture history))
  (copy-external-image-to-texture
    (source :image photo)
    (destination :texture albedo :mip-level 0 :origin [0 0 0])))
```

- `(copy-buffer-to-buffer …)` — `:source` needs `copy-src` usage and
  `:destination` needs `copy-dst`; the two offsets and `:size` must all be
  multiples of 4. The usual job is moving resolved query results into a
  map-readable buffer.
- `(copy-texture-to-texture …)` — the two endpoints are child forms, each
  naming a `(texture …)` or `context-current-texture` (the canvas), which is how
  a frame keeps a copy of itself for feedback.
- `(copy-external-image-to-texture …)` — uploads a decoded `(image-bitmap …)`
  into the destination texture (needs `copy-dst`). `:mip-level` defaults to 0
  and `:origin` to `[0 0 0]`, whose `z` selects the destination array layer or
  depth slice — that is how a cubemap's six faces load into one texture. Both
  belong to the destination, not to the copy.

Each side of a copy is a dictionary in WebGPU, so each is a form: `(source …)`
and `(destination …)`, exactly one of each. Neither copy takes a size — pngine
copies the whole source.

### Images

`(image-bitmap …)` is a decoded image. `:data` names a `(data … :file …)`
entry, which embeds an encoded image file in the payload as
`[mime_len][mime][bytes]`; the runtime decodes it with `createImageBitmap`:

```sjon
(data :name photoBytes :file "textures/photo.png" :mime "image/png")
(image-bitmap :name photo :data photoBytes)

(texture :name albedo :size photo :format rgba8unorm
  :usage [texture-binding copy-dst render-attachment])

(queue :name upload
  (copy-external-image-to-texture (source :image photo) (destination :texture albedo)))
```

`:size photo` sizes the texture from the decoded image, so the dimensions do
not have to be restated. `(data …)` also takes `:float32 [ … ]` for an inline
little-endian float array — the plain way to embed a lookup table or a small
mesh without a shape generator. See `examples/cubemap.sjon` and
`examples/normal_map.sjon`.

**`:file` on a `(data …)` means an image, and only an image.** The bytes are
stored behind their MIME header, and the entry is deliberately not given a byte
length, so a buffer's `:data` cannot size or fill from it. For bytes that are
not an image, use `(bytes …)` below.

### Raw Bytes

`(bytes …)` is a positional child of `(data …)` carrying bytes verbatim: no
MIME header, and a byte length, so a `(buffer :data …)` sizes and fills from it
like an inline array. The bytes come from a sidecar file or from base64 in the
document, and a `(bytes …)` names exactly one of the two:

```sjon
; a sidecar the compiler reads at build time
(data :name palette (bytes :file "palette.bin"))
(buffer :name paletteBuf :usage [uniform copy-dst] :data palette)
```

The same bytes inline, for a document that must stand alone:

```sjon
(data :name palette (bytes :base64 "/4AA/wCAgP//AP///////w=="))
```

Both spellings compile to the same payload, byte for byte
(`examples/test_data_bytes.sjon` and `examples/test_data_base64.sjon` are that
pair). `:base64` is standard base64 with `=` padding; ASCII whitespace is
ignored, so a long literal may be wrapped across lines inside a `"""…"""`
string and will still diff by line.

**Which source to reach for.** A shape generator when the bytes are geometry a
generator already knows how to make. `:float32` when the values are floats an
author reads and edits, and there are few enough to read. `(bytes …)` when the
bytes were packed by something else — a bake step, a font subsetter, a lowering
hook — and their layout is not the compiler's business. `:file` only for an
image. A generated table larger than a few kilobytes belongs on the GPU rather
than in any of them: seed it from a compute pass.

`(bytes …)` is also the one `(data …)` source a host can reach from a SJON
lowering hook. A hook emits forms, never bytes, so it emits the path (or the
base64) and the compiler does the reading; a host with no filesystem supplies
the file through `Compiler.Options.resolver`, the same seam the in-browser
compiler uses.

### Runtime WASM

Two forms run WebAssembly, at different times. `(wasm-data …)` is a positional
child of `(data …)` and runs **once**, at buffer-create time, filling the buffer
through `mappedAtCreation`. `(wasm-call …)` is a top-level form that runs **every
frame**, and a `(write-buffer … :data …)` naming it puts its result in a buffer:

```sjon
; once, at creation
(data :name table (wasm-data :file "gen.wasm" :func buildTable :returns "array<f32,360>"))
(buffer :name lut :usage [storage] :data table)

; every frame
(wasm-call :name mvp :file "mvp.wasm" :func buildMVPMatrix :returns "mat4x4"
  :args [canvas-width canvas-height time-total])
(queue :name writeMvp
  (write-buffer :buffer uniforms :offset 0 :data mvp))
```

`:file` is relative to the source file, and modules are deduplicated by path.
`:returns` is a type spelling the compiler turns into a byte count (`mat4x4` →
64, `vec4` → 16, `f32` → 4, `array<f32,360>` → 1440). `:args` are numeric
literals or the runtime builtins `canvas-width`, `canvas-height`, `time-total`
and `time-delta`, filled by the player each frame. `(write-buffer … :data X)`
takes one key for the three things X can be — a runtime builtin, a `(data …)`,
or a `(wasm-call …)` — and which one it is follows from what X was declared as.
There was a second key, `:data-from-wasm`, for the third case alone.

A `(buffer … :file "mod.wasm")` is the third spelling: the module's own exports
supply both the size and the initial bytes, so `:size` is not authored at all.
`pngine/pass-v1` synthesizes it for `(pass … :file …)`. See
`examples/test_wasm_data.sjon` and `examples/wasm_rotated_cube.sjon`; the WASM
tiers are stubs under native `--frame`, so these render in the browser.

### `(pass …)` Sugar (Shorthand for Shader Art)

`(pass …)` (formerly the `#pass` macro) is sugar for a fullscreen shader: write
`(pass …)` children inside a
`(pass-graph …)` container and the `pngine/pass-v1` lowering hook auto-generates
every resource (uniform buffer, pipeline, bind group, render pass), detecting
features from the WGSL and creating only what's needed. The container sees all
passes at once, so cross-pass texture ids sequence coherently.

```text
(pass-graph :before [<step> …]           ; optional: frame steps run before the graph
  (pass :name <name>
    :code "<WGSL shader code>"
    :feedback true                ; optional: ping-pong texture for feedback
    :format rgba16float           ; optional: the intermediate's texel format
    :reads [<texture> …]          ; optional: textures the graph did not produce
    :scale 0.5                    ; optional: the intermediate at a fraction of the canvas
    :file ["a.wasm" "b.wasm"]     ; optional: WASM data files → D0, D1, …
    :init "<WGSL compute code>")) ; optional: one-shot compute init
```

**Auto-generated resources:**

| Resource     | Condition                                   | Binding |
| ------------ | ------------------------------------------- | ------- |
| Uniform buf  | Code names `pngine`                         | 0       |
| Pointer buf  | Code names `pointer`                        | next    |
| Sampler      | Code names `samp`                           | next    |
| Dep textures | Prior `(pass …)` outputs the code names     | next    |
| Read textures| `:reads` entries (see below)                 | next    |
| Feedback tex | `:feedback true` (not on the last pass)     | next    |
| Data buffers | `:file` present                             | next    |

**Names** means the same thing in every row: a whole identifier, outside
comments. `pngine` in a `// …` line is prose and builds nothing, `pointer` in
the middle of `pointerCount` is a different name, and `textureSample` on its own
does not ask for a sampler — the sampler is the one your code binds by naming
`samp`. Writing about a resource in a comment used to declare and bind it, which
`:layout auto` then refused at render time.

The prelude auto-injects `@binding(N)` declarations. For data buffers, it injects
`var<storage, read> D0: array<f32>`, `D1: array<f32>`, etc.

A pass binds an earlier output only when its WGSL names that pass
(`textureSample(name, samp, uv)`, `textureLoad(name, …)`), so a graph may fan
in: several passes that read nothing, then one that reads them all
(`examples/pass_fbm_noise.sjon`). The
name of every earlier pass a pass reads is a declaration in that pass's
module (`var name: texture_2d<f32>`), so its own functions cannot reuse it.

Two more shapes the WGSL alone selects:

- **Post-processing.** A last pass whose WGSL also declares `@fragment fn
  post(…)` renders `fs` to an intermediate texture and adds a second pass that
  runs `post` to the canvas, reading the intermediate as `postTex`
  (`textureSample(postTex, samp, uv)`); `post` may read `pngine` when `fs`
  does. Commenting the function out removes the second pass, as it reads —
  entry points are read past comments, so disabled text stays disabled.
  `examples/pass_postprocess.sjon`.
- **Compute mains.** A pass whose WGSL declares `@compute` entry points (and no
  `@fragment`) gets a canvas-sized `screen` storage texture
  (`textureStore(screen, id.xy, …)`), one compute pipeline + pass per entry
  over the canvas grid, and, for the last pass, an auto-blit of `screen` to
  the canvas. `@workgroup_size` must be literal numbers.
  `examples/pass_compute_rainbow.sjon`.

**The intermediate's format.** A pass that is not the last one renders into a
texture the passes after it sample, and a pass carrying a `post()` renders into
one its own `post()` samples. `:format` is the texel format of that texture, and
of the color target of the pipeline that writes it, which in WebGPU are one
value and so are one key here. It defaults to `rgba8unorm`, which is what the
sugar always used.

```sjon
(pass-graph
  (pass :name radiance :format rgba16float :code """
    @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
      let uv = pos.xy / vec2f(pngine.width, pngine.height);
      let e = 12.0 * exp(-distance(uv, vec2f(0.5)) * 8.0);
      return vec4f(e, e * 0.55, e * 0.15, 1.0);
    }
  """)
  (pass :name main :code """
    @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
      let uv = pos.xy / vec2f(pngine.width, pngine.height);
      let hdr = textureSample(radiance, samp, uv).rgb;
      return vec4f(hdr / (hdr + vec3f(1.0)), 1.0);
    }
  """))
```

Radiance above 1.0 survives the trip through an `rgba16float` texture and is
clipped at write time by the default `rgba8unorm`, so the two spellings render
differently — `examples/pass_hdr_tonemap.sjon` is that document, and its
committed snapshot is the difference.

Four shapes are refused rather than served:

- **A pass that renders straight to the canvas.** It has no intermediate; its
  target is the context's texture, in the context's format. Add a `post()`, or
  put the key on an earlier pass.
- **A depth or stencil format.** A `(pass …)` writes a color attachment. A depth
  target is a `(depth-stencil-attachment …)` on a hand-authored
  `(render-pass …)`.
- **A compute pass.** Its `screen` is a storage texture, whose format has to be
  spelled inside `texture_storage_2d<…, write>` and which pngine's own blit
  samples as `texture_2d<f32>`.
- **An unfilterable format read through `samp`.** `r32float`, `rg32float` and
  `rgba32float` are `unfilterable-float` without the `float32-filterable`
  feature, and the sampler the sugar shares is `linear`. Read such a texture
  with `textureLoad` instead, or pick a filterable format.

Whatever the format, a pass that reads it gets a binding whose type follows the
format's sample class: `texture_2d<f32>` for a float format, `texture_2d<u32>`
for a uint one, `texture_2d<i32>` for a sint one. The prelude writes that
declaration, so it cannot disagree with the texture.

**Rendering the intermediate smaller.** `:scale` is the fraction of the canvas
this pass's texture takes in each dimension, which is how a half-resolution
ambient-occlusion stage or a bloom downsample chain is built. The texture tracks
the canvas as always, so it follows a resize; the runtime rounds and never goes
below one texel.

`pngine.width` and `pngine.height` keep meaning the CANVAS in every pass, so the
prelude declares `const PASS_SCALE: f32` for a scaled pass to find its own
extent with:

```sjon
(pass-graph
  (pass :name coarse :scale 0.25 :code """
    @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
      // `pos` is in THIS target's texels, of which there are a quarter as many.
      let uv = pos.xy / (vec2f(pngine.width, pngine.height) * PASS_SCALE);
      return vec4f(uv, 0.5, 1.0);
    }
  """)
  (pass :name main :code """
    @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
      let uv = pos.xy / vec2f(pngine.width, pngine.height);
      return textureSample(coarse, samp, uv);
    }
  """))
```

`examples/pass_half_res.sjon` is a document whose picture reads the scale back:
an 8-texel checker in a quarter-size pass covers 32 canvas pixels.

The key is spelled the same way on the form it lowers to. `(texture :size canvas
:scale 0.5 …)` is an ordinary canvas-tracking texture at half resolution, and
that is exactly what a scaled pass emits. Three shapes refuse it, all for one
reason — there is no intermediate for the fraction to describe. On a texture
whose `:size` is an explicit extent there is nothing for a fraction to be a
fraction of. On a compute pass a `screen` storage texture is written at the
dispatch grid pngine chooses, which the key does not resize. And on a pass that
draws to the canvas — the last of its graph, carrying no `post()` — there is no
intermediate texture at all, so the key would size nothing and `PASS_SCALE`
would describe nothing.

**Reading textures the graph did not produce.** A pass samples an earlier pass
by naming it. `:reads` extends that to textures the graph never wrote: a depth
buffer, a G-buffer, an uploaded image. Each entry is a declared `(texture …)`,
bound by its own name, after the dependency bindings and in the order written.

The binding type comes from the texture's `:format`, so the author does not
repeat it: a depth format binds as `texture_depth_2d`, a colour format as
`texture_2d<T>` for T from its sample class.

**Read depth with `textureLoad`, not `textureSample`.** A sampler a shader uses
with a depth texture is `non-filtering` in the pipeline's auto layout, and the
sampler this prelude binds is linear, so sampling one is a bind group the
browser refuses. `textureLoad(gDepth, vec2i(pos.xy), 0)` needs no sampler and
returns the same `f32`. The compiler refuses the other spelling, because the
native CLI renders it and only the browser rejects it.

Because the graph emits the document's `(frame …)`, anything that has to run
before it goes in `(pass-graph :before […])`, whose steps become the head of
that frame's `:perform`. A document that declares its own `(frame …)` beside a
`(pass-graph …)` is refused: it would compile two frames, and the runtime runs
the first.

```sjon
(texture :name gColor :size canvas :format rgba8unorm
  :usage [render-attachment texture-binding])
(texture :name gDepth :size canvas :format depth32float
  :usage [render-attachment texture-binding])
; … the (shader-module …), (render-pipeline …) and (render-pass :name geo …)
;   that write them, hand-authored …
(pass-graph :before [geo]
  (pass :name main :reads [gColor gDepth] :code """
    @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
      let uv = pos.xy / vec2f(pngine.width, pngine.height);
      let colour = textureSample(gColor, samp, uv).rgb;
      let d = textureLoad(gDepth, vec2i(pos.xy), 0);
      return vec4f(mix(colour, vec3f(0.05, 0.06, 0.12), clamp(d, 0.0, 1.0)), 1.0);
    }
  """))
```

`examples/pass_reads_depth.sjon` is that document with the geometry filled in.

What a `:reads` entry must be, each refused with the reason when it is not:

- **Named by this pass's WGSL.** The pipeline's `:layout auto` holds only the
  bindings its entry points reach, so binding one they do not is a bind group
  WebGPU refuses — at render time, as a blank canvas. Naming it only inside
  `post()` does not count: `post()` has its own bind group.
- **Created with `texture-binding` usage.**
- **A single-layer, unmultisampled 2d texture.** A texture bound directly gets
  its default view, and for a 3d, 1d, array or multisampled texture that view is
  not a `texture_2d`.
- **Not a stencil-only format**, which WGSL reads through a view this prelude
  does not build.
- **Not sampled, if it is a depth format** — see above.
- **Not sharing a name with a `(pass …)` in the graph**, because the prelude
  binds a prior pass by its name too. Nothing else catches that collision: a
  texture and a pass may share a name until a `:reads` list puts both in one
  prelude.

**Seeding a feedback chain.** `:feedback true` gives a pass a ping-pong pair and
lets it read what it wrote last frame. On the first frame there is nothing to
read: the pool starts as zeroes, and a simulation whose next state is a function
of its current one never leaves that state. `:init` is the compute program that
writes that texture once, before the first frame's steps run, which is the only
moment at which the chain can be given a starting state.

```sjon
(pass-graph
  (pass :name life :feedback true
    :init """
      @compute @workgroup_size(8, 8) fn seed(@builtin(global_invocation_id) id: vec3u) {
        let dim = textureDimensions(screen);
        if (id.x >= dim.x || id.y >= dim.y) { return; }
        var h = id.x * 1973u + id.y * 9277u + 26699u;
        h = (h ^ (h >> 15u)) * 2246822519u;
        let alive = f32(h % 100u < 28u);
        textureStore(screen, vec2i(id.xy), vec4f(alive, alive, alive, 1.0));
      }
    """
    :code """
      @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
        let was = textureLoad(prev_life, vec2i(pos.xy), 0).r;
        return vec4f(vec3f(was), 1.0);
      }
    """)
  (pass :name main :code """
    @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
      return textureLoad(life, vec2i(pos.xy), 0);
    }
  """))
```

`examples/pass_game_of_life.sjon` is that document with Conway's rules filled
in, and deleting the key from it flattens the canvas to one colour.

The seed's own binding is `screen`, a `texture_storage_2d<…, write>` over the
pass's target — the same name a compute `(pass …)` writes through. One compute
pipeline and one compute pass are emitted per `@compute` entry point, dispatched
over pngine's reference extent, and their names go into the emitted frame's
`:init` list, which runs once per loaded payload ahead of `:before` and
`:perform`. `@workgroup_size` must be literal numbers, as it must on a compute
pass.

Four shapes are refused rather than served:

- **A seed that names `pngine`.** The uniform buffer is filled by a `(queue …)`
  step in `:perform`, and `:init` runs before it, so every field would read 0.
  `textureDimensions(screen)` is the extent a seed wants, and there is no time
  yet.
- **A pass that renders straight to the canvas.** There is no intermediate to
  seed, and WebGPU keeps no handle on the canvas texture that a compute shader
  could store into. Turn `:feedback true` on, add a `post()`, or seed a
  hand-written `(texture …)` with a top-level `(init …)`.
- **A named `(pass-graph …)`.** A named graph emits a `(step-group …)`, and only
  a `(frame …)` has an `:init` list.
- **A `:format` outside WebGPU's core storage list.** Seeding adds
  `storage-binding` to the target's usage, which `bgra8unorm` cannot carry
  without a device feature pngine does not request.

**Example: Simple shader art**

```sjon
(pass-graph
  (pass :name main :code """
    @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
      let uv = pos.xy / vec2f(pngine.width, pngine.height);
      return vec4f(uv, 0.5 + 0.5 * sin(pngine.time), 1);
    }
  """))
```

**Example: Multi-pass with feedback** (both passes in one `(pass-graph …)`)

```sjon
(pass-graph
  (pass :name sim :feedback true :code """
    @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
      let prev = textureLoad(prev_sim, vec2i(pos.xy), 0);
      return prev + vec4f(0.01, 0, 0, 0);
    }
  """)
  (pass :name main :code """
    @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
      return textureLoad(sim, vec2i(pos.xy), 0);
    }
  """))
```

**Example: Specialising an `override`**

A `(pass …)` builds its own shader modules, so there is no `(vertex …)` or
`(fragment …)` stage to hang a `(constant …)` on the way a hand-authored
pipeline does. Write them on the pass instead:

```sjon
(wgsl :name noise :code """
override OCTAVES: u32 = 1u;
fn fbm(p: vec2f) -> f32 {
  var sum = 0.0;
  var amp = 0.5;
  var q = p;
  for (var i = 0u; i < OCTAVES; i = i + 1u) {
    sum = sum + amp * fract(sin(q.x * 12.9898 + q.y * 78.233) * 43758.5453);
    q = q * 2.0;
    amp = amp * 0.5;
  }
  return sum;
}
""")
(pass-graph
  (pass :name main :imports [noise] :code """
    @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
      let uv = pos.xy / vec2f(pngine.width, pngine.height);
      return vec4f(fbm(uv * 8.0), 0, 0, 1);
    }
  """
    (constant :name OCTAVES :value 6)))
```

Everything [Pipeline-overridable constants](#pipeline-overridable-constants-constant)
says still holds: the value is substituted into the shipped text, per module, at
compile time. Two rules are the pass's own, and both follow from which modules
the sugar builds:

- **A `post()` shares a constant only through `:imports`.** The post shader is a
  prelude, the fullscreen vertex shader and the extracted `post()` function, and
  a function body cannot declare a module-scope `override`. So an override your
  `:code` declares is specialised in the main module alone; one an imported
  fragment declares is specialised in both, because both import the same list.
- **With no `:imports`, a name your WGSL does not declare is refused at the
  pass**, naming the pass and the override you wrote. With fragments in play the
  refusal comes from the emitter instead and names the generated module
  (`<pass>__shader`), because only the emitter has assembled that text.

Constants never reach pngine's own auto-blit shader, exactly as `:imports` do
not. `examples/test_pass_constants.sjon` fixes one fragment's `OCTAVES` at two
different values in two passes of one graph.

### `(pass …)` with `:file` (WASM Data Buffers)

Embeds binary data from WASM files into GPU storage buffers, accessible as
`array<f32>` in the shader. Avoids verbose WGSL `const` array declarations.

`:file` on a `(pass …)` is sugar for one `(buffer … :file …)` per path —
`<pass>__d0`, `__d1`, … with `storage|copy-dst` usage — plus the
`var<storage, read> D{i}: array<f32>` the prelude declares and the bind-group
entries that bind them. `(buffer :name b :file "x.wasm" :usage [storage copy-dst])`
is the core spelling and needs no `:size`: the WASM's `l` export is the size.

A module with no `gen` is a container and nothing else, so bytes that are
merely static do not need one: `(data :name t (bytes :file "t.bin"))` says the
same thing with no envelope to write. Reach for a WASM here when the bytes are
computed — by `gen` at runtime, or by a toolchain that emits `.wasm` anyway.

**WASM file convention:**

| Export   | Type       | Required | Description                                     |
| -------- | ---------- | -------- | ----------------------------------------------- |
| `l`      | i32 global | Yes      | Byte length of the data                          |
| `s`      | i32 global | No       | Where those bytes start in the module's memory (default 0) |
| `gen`    | function   | No       | `() -> i32`: computes the bytes, returns their pointer |
| `memory` | memory     | With `gen` | Exported under this exact name, or imported as `env.memory` |

**Which side reads the module depends on `gen`, and that is the whole
distinction.**

Without `gen` the module is a *container*: it has no function to call, so its
memory is whatever its data segments put there, and the compiler reads them at
build time and ships the bytes alone. Nothing about the module reaches a
runtime, which is why this shape works identically on native and in a browser.
Its memory export name is nobody's business — `examples/test_data.wat` calls it
`m`.

```wat
;; colors.wat — 7 RGB colors as f32, read by the COMPILER
(module
  (memory (export "m") 1)
  (data (i32.const 0)
    "\46\0f\3f\3e..."  ;; f32 little-endian bytes
  )
  (global (export "l") i32 (i32.const 84))  ;; 7 * 3 * 4 bytes
  (global (export "s") i32 (i32.const 0))
)
```

Compile: `wat2wasm colors.wat -o colors.wasm`

With `gen` the module is a *program*: it is embedded whole, the runtime
instantiates it, calls `gen` once when the buffer is created, and copies `l`
bytes out of its memory. Two rules follow from that and neither is optional:

- **`gen` returns the pointer** it wrote to (`(result i32)`). That return value
  is the source of the copy; a `gen` with no result writes nothing.
- **The memory must be reachable by name.** The runtime reads
  `exports.memory`, falling back to the `env.memory` it handed in as an import.
  A module exporting its memory as `m` runs, writes, and is then read from a
  memory nobody wrote — a black canvas with no error — so the compiler refuses
  it. Export no memory at all (writing into the imported one) or export it as
  `memory`.

`s` addresses the *module's* memory. The GPU buffer is exactly `l` bytes long
and is always written from 0.

```wat
;; ramp.wat — three floats computed at runtime, read by the RUNTIME.
;; examples/assets/gen_ramp.wat is this file, with the arithmetic filled in.
(module
  (memory (export "memory") 1)
  (global (export "l") i32 (i32.const 12))
  (global (export "s") i32 (i32.const 16))
  (func (export "gen") (result i32)
    ;; …write l bytes starting at s…
    (global.get 1))          ;; return where they are
)
```

The `[wasm]` plugin is a browser capability: the native `--frame` backend stubs
`init_wasm_module`, `call_wasm_func` and `write_buffer_from_wasm`, so a `gen`
document renders black under the CLI and correctly in a browser. A container
document has no such split — `examples/test_data_pass.sjon` renders orange on
both. `examples/test_data_gen.sjon` is the worked generator.

**Usage in `(pass …)`:**

```sjon
(pass-graph
  (pass :name main :file ["colors.wasm"] :code """
    // D0 auto-injected: @group(0) @binding(N) var<storage, read> D0: array<f32>;
    fn gv(i: u32) -> vec3f {
      let b = i * 3u;
      return vec3f(D0[b], D0[b+1u], D0[b+2u]);
    }

    @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
      let col = gv(0u);  // first color from WASM data
      return vec4f(col, 1);
    }
  """))
```

**Multiple data files:**

```sjon
(pass-graph
  (pass :name main :file ["colors.wasm" "shapes.wasm"] :code """
    // D0 = colors.wasm data, D1 = shapes.wasm data
    fn get_color(i: u32) -> vec3f { return vec3f(D0[i * 3u], D0[i * 3u + 1u], D0[i * 3u + 2u]); }
    fn get_shape(i: u32) -> f32 { return D1[i]; }
    @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
      let uv = pos.xy / vec2f(pngine.width, pngine.height);
      let i = u32(uv.x * get_shape(0u));
      return vec4f(get_color(i), 1);
    }
  """))
```

**WGSL alignment note**: `array<f32>` has stride 4 (packed, no padding).
`array<vec3f>` has stride 16 (33% waste). Use `array<f32>` and index manually
for maximum compactness.

### `(draw-graph …)` Sugar (one draw into many)

`(pass …)` is the shorthand for a fullscreen effect. `(draw-graph …)` is the
shorthand for the other repetition: the same geometry drawn in several stages,
and several geometries drawn in the same stage. A render pipeline is keyed by
(entry points × state × target formats) and a bind group by pipeline, so a
2×2 table of two meshes over a shadow stage and a lit stage costs four
pipelines, four passes and two bind groups written out by hand. The graph is
that table:

```sjon
(shader-module :name scene :code """
struct Cam { m: mat4x4f }
@group(0) @binding(0) var<uniform> cam: Cam;
@vertex fn depthVs(@location(0) p: vec3f) -> @builtin(position) vec4f {
  return cam.m * vec4f(p, 1.0);
}
@vertex fn litVs(@location(0) p: vec3f) -> @builtin(position) vec4f {
  return cam.m * vec4f(p, 1.0);
}
@vertex fn groundVs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var q = array<vec2f, 6>(
    vec2f(-1, -1), vec2f(1, -1), vec2f(-1, 1),
    vec2f(-1, 1), vec2f(1, -1), vec2f(1, 1));
  return vec4f(q[i], 0.5, 1.0);
}
@fragment fn litFs() -> @location(0) vec4f { return vec4f(0.8, 0.7, 0.5, 1.0); }
@fragment fn groundFs() -> @location(0) vec4f { return vec4f(0.2, 0.2, 0.3, 1.0); }
""")

(data :name mesh (cube :format [position3]))
(buffer :name meshVB :usage [vertex] :data mesh)
(buffer :name cam :size 64 :usage [uniform copy-dst])
(texture :name shadowMap :size [512 512] :format depth32float
  :usage [render-attachment texture-binding])
(texture :name sceneDepth :size canvas :format depth24plus :usage [render-attachment])
(queue :name writeCam (write-buffer :buffer cam :offset 0 :data pngine-inputs))

(draw-graph :before [writeCam]
  ; A stage is the attachments a pass writes, plus the pipeline state every
  ; geometry drawn in it shares.
  (stage :name shadow
    (depth-stencil-attachment :view shadowMap
      :depth-clear-value 1.0 :depth-load-op clear :depth-store-op store)
    (depth-stencil :format depth32float :depth-write-enabled true :depth-compare less)
    (primitive :topology triangle-list))
  (stage :name color
    (color-attachment :view context-current-texture
      :clear-value [0 0 0 1] :load-op clear :store-op store)
    (depth-stencil-attachment :view sceneDepth
      :depth-clear-value 1.0 :depth-load-op clear :depth-store-op store)
    (depth-stencil :format depth24plus :depth-write-enabled true :depth-compare less)
    (bind-group :name sceneBG :group 0
      (entry :binding 0 :buffer cam)))

  ; A geometry is its buffers, its vertex layout, ONE draw command, and an
  ; (in …) for each stage it appears in.
  (geometry :name mesh :vertex-buffers [meshVB]
    (vertex-buffer :array-stride (* 4 3)
      (attribute :shader-location 0 :offset 0 :format float32x3))
    (draw :vertex-count 36)
    (in :stage shadow (vertex :module scene :entry depthVs))
    (in :stage color
      (vertex :module scene :entry litVs)
      (fragment :module scene :entry litFs)
      (primitive :topology triangle-list :cull-mode back)))
  (geometry :name ground
    (draw :vertex-count 6)
    (in :stage color
      (vertex :module scene :entry groundVs)
      (fragment :module scene :entry groundFs))))
```

That compiles to three pipelines, two bind groups and three render passes, run
in stage order: `shadow__mesh`, `color__mesh`, `color__ground`. Written by
hand it is roughly twice the lines, and every one of them repeats something.

Every child form above is the ordinary form of that name — the
`(depth-stencil …)` a pipeline takes, the `(color-attachment …)` a pass takes,
the `(bind-group …)` with `:layout` left out from *Derived bind groups*. The
graph copies what you wrote into what it emits, so nothing here is a second
spelling to learn.

What the graph fills in for you:

- **The `(color-target …)` list**, one per color attachment of the stage, in order:
  `preferred-canvas-format` for `context-current-texture`, otherwise the named
  texture's own `:format`. This is why an `(in …)`'s `(fragment …)` states no
  targets and why blending is not expressible in a graph yet — write those
  passes by hand.
- **The bind group's `:layout`**, per generated pipeline, with
  `:prune-unused` always on. One entry list therefore serves stages whose
  entry points reach different subsets of it, and the auto-layout desync that
  aborts at `set_bind_group` cannot be written here at all.
- **The load/store sequencing.** The stage's `:load-op` / `:depth-load-op` and
  its clear values land on the FIRST pass of the stage; every later pass
  loads. Its `:store-op` / `:depth-store-op` land on the LAST; every earlier
  pass stores. So `shadowMap` is cleared once and then accumulated, and
  reordering the geometries cannot move the clear.
- **The frame.** The graph emits the document's `(frame …)` and names its
  passes in stage order. `:before` and `:after` are the way a hand-authored
  queue or pass composes with it — `examples/draw_graph_after.sjon` writes the
  uniforms in `:before` and blends a border over the finished scene in
  `:after`. The two are not interchangeable: the stage clears its attachment,
  so the same overlay moved to `:before` renders and is then wiped.

The names are `<stage>__<geometry>` for the pass, `<stage>__<geometry>__pipe`
for the pipeline and `<group>__<geometry>` for each bind group, which is what
you will see in `pngine inspect` and in a diagnostic.

The rules, each one a compile-time answer:

- **A geometry states its draw once,** and appears in a stage through an
  `(in :stage …)`. A geometry with no `(in …)` is refused (it is drawn
  nowhere); a stage no `(in …)` names is refused too, since it would emit no
  pass and its attachments would never be cleared.
- **State merges one way.** A `(primitive …)` inside an `(in …)` replaces the
  stage's; `(depth-stencil …)` is the stage's alone. A stage whose geometries
  wanted different depth state is two stages.
- **The vertex layout belongs to the geometry.** The `(in …)`'s `(vertex …)`
  admits `(constant …)` and nothing else — the `(vertex-buffer …)` children
  sit on the geometry, where they are written once for every stage.
- **A stage's bind groups are `:group 0..N-1`,** distinct, because a pass
  binds them as a dense positional list.
- **The graph owns the frame.** A `(frame …)` or a `(pass-graph …)` elsewhere
  in the document is refused: two frames compile and the runtime runs the
  first, which is not visible in the source.
- **Multisampling is out.** The graph emits no `(multisample …)`, so an
  attachment texture with `:sample-count` above 1 is refused rather than
  paired with a single-sampled pipeline.
- **A stage renders wherever a pass can.** `(color-attachment :view …)` takes
  `context-current-texture` or a `(texture …)` name, and the stage's
  `(color-target :format …)` is derived from whichever it is — the canvas format, or
  that texture's own `:format`. `examples/draw_graph_offscreen.sjon` is two
  stages over one intermediate.
- **Blending is a stage's, through a `(color-target …)` child.** It carries the blend
  state and the write mask and *not* the format, which is the attachment's; a
  stage's targets pair with its `(color-attachment …)` children by position, so
  it declares one per attachment or none at all. Two geometries that wanted
  different blending are two stages, the same way two that wanted different
  depth state are — and since the load/store rewrite is per stage, a second
  stage over the same attachment with `:load-op load` composes with the first
  for free. `examples/draw_graph_blend.sjon` is that shape: an opaque base,
  then an additive pass.

`examples/webgpu_shadow_mapping_graph.sjon` is the worked version: it is
`webgpu_shadow_mapping_fragments.sjon` with its four pipelines, four passes
and one bind group replaced by a 2×2 graph, and the two render the same
pixels.
### `(step-group …)` and running two graphs in one frame

A graph is several passes, and a frame step is one name. That is the whole
reason each container used to emit the document's `(frame …)` and refuse the
other: there was no name for the SET of passes a graph builds, so a
hand-written frame had nothing to say.

`(step-group :name … :perform […])` is that name. It is a compile-time form —
the emitter inlines a group's steps wherever the group is named, so a frame over
groups emits exactly the ops the same passes listed by hand would, and nothing
about it reaches the wire.

**A graph with a `:name` emits a step group instead of a frame**, and the
document writes the frame:

```sjon
(shader-module :name sceneShader :code """
@vertex fn vs(@builtin(vertex_index) i : u32) -> @builtin(position) vec4f {
  var p = array<vec2f, 3>(vec2f(-0.8, -0.6), vec2f(0.8, -0.6), vec2f(0.0, 0.7));
  return vec4f(p[i], 0.0, 1.0);
}
@fragment fn fs() -> @location(0) vec4f { return vec4f(0.95, 0.6, 0.25, 1.0); }
""")
(texture :name sceneColor :size canvas :format rgba8unorm
  :usage [render-attachment texture-binding])

(draw-graph :name scene
  (stage :name main
    (color-attachment :view sceneColor
      :clear-value [0 0 0 1] :load-op clear :store-op store))
  (geometry :name tri
    (draw :vertex-count 3)
    (in :stage main
      (vertex :module sceneShader :entry vs)
      (fragment :module sceneShader :entry fs))))

(pass-graph :name post
  (pass :name vignette :reads [sceneColor] :code """
    @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
      let uv = pos.xy / vec2f(pngine.width, pngine.height);
      let c = textureSample(sceneColor, samp, uv).rgb;
      let vig = 1.0 - smoothstep(0.35, 0.85, distance(uv, vec2f(0.5, 0.5)));
      return vec4f(c * vig, 1.0);
    }
  """))

(frame :name main :perform [scene post])
```

The order is the frame's, stated once, where a reader looks for it — not the
order the two hooks happened to emit in. `examples/graph_compose.sjon` is the
worked version, with three lit cubes into the intermediate.

**A frame over a named graph performs a selection, and per-pass selection by
name is a designed surface, not an accident of the emitter.** The names are
the author's own, carried through lowering deliberately (a frame step is one
namespace across render-pass, compute-pass, queue and step-group names, so a
pass name collides with nothing), and the emitter resolves each step by name
against lowered and hand-written passes alike, which is why frames are emitted
after passes on purpose. The group's `:perform` is the menu, stated in the
document's own text: in front of each pass sit the two uniform-write queues
the hook spliced there (`<pass>__uq`, `<pass>__pq`), so the unit of removal is
visible without knowing the lowering. The frame may perform any sublist.
Leaving a pass's steps out mutes it: the pass stays in the graph, and its
textures are created at load like every other resource, so a later pass that
samples it by name keeps a valid binding and reads zero-initialised contents
until something writes them (or, in a live session that toggles the mute,
whatever was last rendered); nothing requires a group's every step to be
performed, and nothing withholds an unperformed pass's resources, so the
frame stays whole. The mute is the frame's `:perform`, which is the point:
view state in the document's own text, undoable, recorded, and answerable
later. One boundary: the canvas destination is fixed at lowering time (the
graph's last pass, or one named `main`, is the one lowered to
`context-current-texture`), so selection chooses what runs, not what the
canvas receives; mute the canvas-bound pass and the canvas keeps whatever it
last held.

**Soloing needs one step past selection: a canvas destination.** Performing a
middle pass shows nothing, because it renders into its own intermediate and
nothing targets the canvas. `:expose` publishes that intermediate as a render
pass of its own: `:expose [warp]` emits `warp__blit` (pngine's own blit shader
over `warp`'s intermediate, onto the canvas) and puts it in NO step list, so it
runs only when a frame names it. A named graph hands the frame to the document,
which makes the solo the frame's own `:perform`:
`[warp__uq warp warp__blit]` runs the pass's uniform write, the pass, and its
blit (the `<pass>__uq` entry is present when the pass names `pngine`, the same
queue mute's unit of removal includes). Restoring `[g]` runs the whole graph
again. Both edits are the document's own text, so solo carries mute's
properties: undoable, recorded, and answerable later. An absent or empty
`:expose` compiles to the same bytes as before the key existed; a name no pass
in the graph carries, a pass that already draws to the canvas, and a pass whose
`:format` pngine's blit cannot sample are each refused at lowering.

```sjon
(pass-graph :name g :expose [warp]
  (pass :name warp :code """
    @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
      let uv = pos.xy / vec2f(pngine.width, pngine.height);
      return vec4f(uv, 0.5 + 0.5 * sin(pngine.time), 1.0);
    }
  """)
  (pass :name main :code """
    @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
      return vec4f(0.05, 0.05, 0.08, 1.0);
    }
  """))

(frame :name main :perform [warp__uq warp warp__blit])
```

`examples/pass_expose.sjon` is that document, and its committed trace shows the
solo: `warp` renders into its intermediate, `warp__blit` samples it onto the
canvas, and `main`'s steps are never executed.

**A graph with no `:name` still owns the frame**, exactly as both containers
always have, with `:before` / `:after` around its own steps. Every graph
document written before groups existed compiles to the same bytes.

The rules that follow, each a refusal:

- **An unnamed graph is the document's only frame owner.** A `(frame …)` beside
  it is refused at load, and so is another graph; the refusal names both ways
  out (give the graphs `:name` and perform them from one `(frame …)`, or drop
  the frame and put the step in `:before`).
- **A named graph needs a frame.** It emits a group and nothing else, so a
  document that names its graph and declares no `(frame …)` builds resources
  that never run.
- **`:before` / `:after` belong to the unnamed case.** A named graph does not
  emit the frame, so there is nothing for them to sit before or after; put the
  step in the `(frame …)` that performs the graph, on the side you want it.
- **A group chain that names its way back to its start has no expansion**, and
  is refused rather than expanded until the emitter gives up.

Groups are worth writing by hand too: a sequence named once and performed by
several `(frame …)` forms is the same shape, and they nest up to eight deep.

