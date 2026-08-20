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
; :group) or an explicit (bind-group-layout …). Entries are (entry …), one
; resource each (:buffer / :sampler / :texture / :texture-view); a buffer
; entry may bind a slice with :offset and :size (both need :buffer, and the
; slice must fit the declared buffer size).
(bind-group :name g :layout pipe :group 0
  (entry :binding 0 :buffer uniforms))

(render-pipeline :name pipe
  :layout auto
  (vertex :module code :entry vsMain)
  (fragment :module code :entry fsMain
    (target :format preferred-canvas-format))
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

A document is a single file; there is no import form. Numeric slots accept a
bare `(define …)` name, or a bounded expression over those constants
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
located validation error rather than a silently ignored one.

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
pipeline built on both.

**Non-indexed indirect draws + indirect dispatch**: the draw/dispatch count can
also come from a GPU-written argument buffer without an index buffer.
`(draw-indirect :buffer :offset)` reads a `GPUDrawIndirectArgs` (4×u32:
vertexCount, instanceCount, firstVertex, firstInstance); a compute pass's
`(dispatch-indirect :buffer :offset)` reads a `GPUDispatchIndirectArgs` (3×u32)
instead of the literal counts a `(dispatch …)` carries. Same two keys either
way, and both are commands, so a pass may issue several.

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
(a seed compute pass writes the args, the indirect pass reads them). All three
indirect forms execute on the viewer, `--html`, and native tiers; the `mini`
(pNGf) tier refuses them at write.

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

The name is the field as declared in the WGSL struct. Both trigger a redraw by
default; pass `false` as the last argument to set without drawing.

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
  (fragment :module mod :entry fs (target :format bgra8unorm)))

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
    (target :format preferred-canvas-format)))
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
    (target :format bgra8unorm)
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
  differently is an error; restating the same value on both is fine.

Specialisation is why `@workgroup_size(WG)` is worth doing this way: with `WG`
resolved, the reflected workgroup size is a real number again, so the
dispatch-grid and device-limit checks work instead of being skipped.

### Primitive State

`(primitive …)` mirrors `GPUPrimitiveState`. Beyond `:topology`, `:cull-mode`,
and `:front-face`, two fields cover the rest of the descriptor:

```sjon
(render-pipeline :name strip :layout auto
  (vertex :module code :entry vs)
  (fragment :module code :entry fs (target :format bgra8unorm))
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

A fragment `(target …)` carries an optional `(blend …)` mirroring
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
    (target :format preferred-canvas-format
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

A `(target …)` also takes `:write-mask`, the per-channel colour write mask:
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
  (fragment :module code :entry fs (target :format bgra8unorm))
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
  (fragment :module code :entry fs (target :format bgra8unorm))
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

`(draw …)` and `(draw-indexed …)` are positional children of a
`(render-pass …)`. Beyond the required count, every key defaults the WebGPU way
and is emitted only when authored:

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
through the CPU.

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
(pass-graph
  (pass :name <name>
    :code "<WGSL shader code>"
    :feedback true                ; optional: ping-pong texture for feedback
    :file ["a.wasm" "b.wasm"]     ; optional: WASM data files → D0, D1, …
    :init "<WGSL compute code>")) ; optional: one-shot compute init
```

**Auto-generated resources:**

| Resource     | Condition                                   | Binding |
| ------------ | ------------------------------------------- | ------- |
| Uniform buf  | Code references `pngine`                    | 0       |
| Pointer buf  | Code references `pointer`                   | next    |
| Sampler      | Code names `samp` (e.g. `textureSample`)    | next    |
| Dep textures | Prior `(pass …)` outputs                    | next    |
| Feedback tex | `:feedback true` (not on the last pass)     | next    |
| Data buffers | `:file` present                             | next    |

The prelude auto-injects `@binding(N)` declarations. For data buffers, it injects
`var<storage, read> D0: array<f32>`, `D1: array<f32>`, etc.

Two more shapes the WGSL alone selects:

- **Post-processing.** A last pass whose WGSL also declares `@fragment fn
  post(…)` renders `fs` to an intermediate texture and adds a second pass that
  runs `post` to the canvas, reading the intermediate as `postTex`
  (`textureSample(postTex, samp, uv)`); `post` may read `pngine` when `fs`
  does. `examples/pass_postprocess.sjon`.
- **Compute mains.** A pass whose WGSL declares `@compute` entry points (and no
  `@fragment`) gets a canvas-sized `screen` storage texture
  (`textureStore(screen, id.xy, …)`), one compute pipeline + pass per entry
  over the canvas grid, and, for the last pass, an auto-blit of `screen` to
  the canvas. `@workgroup_size` must be literal numbers.
  `examples/pass_compute_rainbow.sjon`.

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

### `(pass …)` with `:file` (WASM Data Buffers)

Embeds binary data from WASM files into GPU storage buffers, accessible as
`array<f32>` in the shader. Avoids verbose WGSL `const` array declarations.

**WASM file convention** (same as sointu audio):

| Export | Type       | Required | Description                       |
| ------ | ---------- | -------- | --------------------------------- |
| `m`    | memory     | Yes      | Contains the data                 |
| `l`    | i32 global | Yes      | Byte length of data               |
| `s`    | i32 global | No       | Start offset in memory (default 0)|
| `gen`  | function   | No       | Called before reading memory       |

**Static data** (pre-baked in WASM data segment):

```wat
;; colors.wat — 7 RGB colors as f32
(module
  (memory (export "m") 1)
  (data (i32.const 0)
    "\46\0f\3f\3e..."  ;; f32 little-endian bytes
  )
  (global (export "l") i32 (i32.const 84))  ;; 7 * 3 * 4 bytes
)
```

Compile: `wat2wasm colors.wat -o colors.wasm`

**Generator WASM** (computes data at runtime):

```wat
(module
  (memory (export "m") 1)
  (func (export "gen")
    ;; fill memory with computed values
  )
  (global (export "l") i32 (i32.const 420))
)
```

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
