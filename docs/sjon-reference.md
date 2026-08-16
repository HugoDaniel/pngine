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

```
; Named constant → collected into the emitter's expression env.
(define :name NUM :value 2048)

; A named WGSL module (the source is opaque text to SJON). `"""…"""` is a
; multi-line string literal; `:code "…"` a single-line one.
(shader-module :name code :code """<shader code>""")

; One-shot compute init of a storage buffer (once per loaded payload — see
; "What `:init` means, exactly"). Lowered by the
; pngine/init-v1 hook → compute-pipeline + bind-group + compute-pass.
(init :name setup :buffer particles :shader initShader :workgroups (ceil (/ NUM 64)))

; GPU buffer. `:pool 2` creates two ping-pong ids; `:size` is a byte count, an
; expression, or a (data …) reference the buffer is sized from.
(buffer :name particles :size (* NUM 4 4) :usage [vertex storage] :pool 2)

(texture :name depth :format depth24plus :usage [render-attachment])
(sampler :name samp :mag-filter linear :min-filter linear)

; Bind group. The layout is a pipeline's auto-layout (:layout-pipeline) or an
; explicit (bind-group-layout …) via :bind-group-layout. Entries are (entry …).
(bind-group :name g :layout-pipeline pipe :layout-index 0
  (entry :binding 0 :buffer uniforms))

(render-pipeline :name pipe
  (layout auto)
  (vertex (module code) (entry vsMain))
  (fragment (module code) (entry fsMain)
    (targets (target :format preferred-canvas-format)))
  (primitive (topology triangle-list)))

(compute-pipeline :name cp :module code :entry main)

(render-pass :name draw
  (color-attachment :view context-current-texture
    :clear-value [0 0 0 1] :load-op clear :store-op store)
  :pipeline pipe
  :vertex-buffers [posBuffer uvBuffer]      ; optional bare cross-refs
  :vertex-buffers-pool-offsets [1 0]        ; ping-pong offsets
  :bind-groups [g]
  (draw :vertex-count 3))                    ; or (draw-indexed :index-count N)

(compute-pass :name step :pipeline cp :bind-groups [g]
  :dispatch-workgroups (ceil (/ NUM 64)))    ; or :dispatch [x y z]

(queue :name writeInputs
  (write-buffer :buffer uniforms :offset 0 :data pngine-inputs))

(frame :name main
  :init [setup]          ; one-shot compute init (once per loaded payload)
  :before [writeInputs]  ; queue ops run before each frame
  :perform [step draw])  ; passes/queues run every frame, in order
```

A document is a single file; there is no import form. Numeric slots accept
bounded expressions (`(* NUM 4 4)`, `(ceil (/ NUM 64))`) over `(define …)`
constants and the core funcs `* / + - ceil floor fract`.

### Declaration Order

**Write forms in whatever order reads best.** Two rules cover everything:

1. **Forms emit by kind, in a fixed order** — data, shader modules, buffers,
   textures, samplers, layouts, pipelines, bind groups, then passes and frames
   (`src/dsl_sjon/Emitter.zig`'s `phases` table is the authority). A `(texture …)`
   written above a `(buffer …)` still emits after every buffer.
2. **Everything binds by name.** A pass names its pipeline, a bind group names
   its buffer. Nothing is positional.

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

Every numeric slot takes a bounded expression over `(define …)` constants and
`* / + - ceil floor fract`, and that includes the slots read by a lowering hook:

```
(define :name NUM :value 2048)
(define :name WG  :value 64)

(buffer :name particles :size (* NUM 4 4) :usage [storage])
(init :name setup :buffer particles :shader initShader
  :workgroups (ceil (/ NUM WG)))              ; lowering-time — also evaluated
(compute-pass :name step :pipeline cp :bind-groups [g]
  :dispatch-workgroups (ceil (/ NUM WG)))     ; emitter-time
```

`(init … :workgroups)` is read while the `pngine/init-v1` hook lowers, before
the emitter runs, but the hook evaluates against the same document-wide define
env, so both slots behave the same.

Two rules:

- **Declare a define before any define that references it.** The env is built in
  document order, so a forward reference contributes no binding and the
  expression that used it fails rather than silently reading zero. The
  diagnostic says so, on the expression:

  ```
  init `initParticles`: `:workgroups` did not evaluate to a number — every name
  in it must be a `(define …)` declared before the define that uses it
  ```

  Note it is *define-to-define* order that matters. A define declared after the
  `(init …)` that uses it is fine — the whole document's defines are collected
  before lowering runs.
- **A bare define name is not a byte count in `:size`.** That slot's symbol
  branch means "size this buffer from that `(data …)`", so `:size STRIDE`
  resolves as a data cross-ref, finds no such data form, and is rejected —
  with the collision named, because the document shows which one it was:

  ```
  form `buffer` keyword `:size` expects `byte-size`, got symbol (no alternative
  matched: `byte-count` | `data-ref`) — `STRIDE` is a `(define …)` constant, and
  a bare symbol here names a `(data …)` form; write an expression to use its
  value, e.g. `(* STRIDE 1)`
  ```

  Write the arithmetic instead — `:size (* NUM STRIDE)`. Slots with no
  competing symbol meaning, such as `:workgroups`, do take a bare define name.
  The union is deliberately *not* widened with a define-ref branch: that would
  give a bare symbol in this slot two meanings, and the sentence above dissolves
  the confusion at no semantic cost.

### Shape Generators (`(data …)` with a shape property)

Built-in compile-time shape generators produce vertex data (and optionally index
data) from shape parameters. The generated data is embedded in the PNGB payload.

**Procedural shapes** (deindexed, vertex data only) — a positional shape sub-form
inside `(data …)`:

```
(data :name cubeVerts   (cube :format [position4 color4 uv2]))
(data :name planeVerts  (plane :format [position3 normal3]))
(data :name sphereVerts (sphere :format [position3 normal3]))
(data :name torusVerts  (torus :format [position3 normal3]))
(data :name coneVerts   (truncated-cone :format [position3 normal3]))
(data :name cylVerts    (cylinder :format [position3 normal3]))
```

The shape sub-forms are `:open true`, so generator-specific numeric config
(segments, rings, radius, thickness, …) is accepted alongside `:format`.

**Static meshes** (indexed — produces vertex data + an index companion):

```
(data :name teapotMesh (teapot :format [position3 normal3]))
(data :name dragonMesh (dragon :format [position3 normal3 uv2]))
```

The index buffer sources its size, initial bytes, and index-format (u16/u32) from
the indexed shape's companion via `:index-of <data-ref>` — `teapotMesh` is a real
`(data …)` cross-ref the validator resolves (a synthetic `teapotMesh_indices` name
would not):

```
(buffer :name vb :size teapotMesh :usage [vertex] :mapped-at-creation teapotMesh)
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

```
(buffer :name indexBuffer :size (* MAX_INDICES 4) :usage [index storage]
  :index-format uint32)
(buffer :name indirectArgs :size 20 :usage [indirect storage])

(render-pass :name draw
  ; …
  :index-buffer indexBuffer
  ; GPUDrawIndexedIndirectArgs (5×u32) read from the buffer at :offset
  (draw-indexed-indirect :buffer indirectArgs :offset 0))
```

See `examples/webgpu_marching_cubes.sjon` for a full per-frame GPU meshing
pipeline built on both.

**Non-indexed indirect draws + indirect dispatch**: the draw/dispatch count can
also come from a GPU-written argument buffer without an index buffer.
`(draw-indirect :buffer :offset)` reads a `GPUDrawIndirectArgs` (4×u32:
vertexCount, instanceCount, firstVertex, firstInstance); a compute pass
`:dispatch-indirect BUF` (with optional `:dispatch-indirect-offset`) reads a
`GPUDispatchIndirectArgs` (3×u32) instead of a literal `:dispatch-workgroups`.

```
(buffer :name drawArgs     :size 16 :usage [storage indirect])   ; 4×u32
(buffer :name dispatchArgs :size 12 :usage [storage indirect])   ; 3×u32

(render-pass :name draw
  ; …
  (draw-indirect :buffer drawArgs))          ; :offset defaults to 0

(compute-pass :name step :pipeline cp :bind-groups [g]
  :dispatch-indirect dispatchArgs)           ; supersedes :dispatch-workgroups
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

```
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

```
(buffer :name particles :size 32768 :usage [vertex storage] :pool 2)  ; particles_0, _1

(bind-group :name sim :layout-pipeline computeSim :layout-index 0 :pool 2
  (entry :binding 0 :buffer particles :ping-pong 0)   ; read from
  (entry :binding 1 :buffer particles :ping-pong 1))  ; write to

(compute-pass :name update :pipeline computeSim
  :bind-groups [sim]
  :bind-groups-pool-offsets [0]   ; alternates each frame
  :dispatch [64 1 1])
```

The runtime selects the actual buffer using:

```
actual_id = base_id + (frame_counter + offset) % pool_size
```

### Ping-Pong Texture Pattern

Textures support the same `pool=N` property as buffers, creating sequential
texture IDs for ping-pong render targets:

```
(texture :name feedbackTex :size canvas
  :format rgba8unorm :usage [texture-binding render-attachment] :pool 2)  ; _0, _1
```

For `(pass …)` sugar, use `:feedback true` instead (auto-generates pool textures,
bind groups, and a `prev_<name>` WGSL binding):

```
(pass-graph
  (pass :name sim :feedback true :code """
    @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
      let prev = textureLoad(prev_sim, vec2i(pos.xy), 0);
      return prev + vec4f(0.01, 0, 0, 0);
    }
  """))
```

### Textures

`(texture …)` maps to a `GPUTextureDescriptor`. Size comes from `:size canvas`
(tracks the canvas), `:size-from <image-bitmap>` (a decoded image), or explicit
`:width`/`:height`. The remaining descriptor fields are all optional and take the
WebGPU defaults when omitted (a plain texture emits none of them, so its encoding
is unchanged):

```
(texture :name volume
  :width 64 :height 64
  :dimension 3                 ; 1 = 1d, 2 = 2d (default), 3 = 3d
  :depth-or-array-layers 8     ; GPUExtent3D depthOrArrayLayers (3d slices / array layers)
  :mip-level-count 4           ; mip levels to allocate (default 1)
  :sample-count 1              ; 1 (default) or 4 (MSAA)
  :format rgba8unorm :usage [texture-binding copy-dst])
```

`:dimension` is authored numerically (`1`/`2`/`3`) rather than as `1d`/`2d`/`3d`,
because those lex as number-with-unit in SJON, not symbols. A `3d` texture needs
`:depth-or-array-layers` for its slice count; a 2d **array** keeps `:dimension 2`
and sets `:depth-or-array-layers` to the layer count. `:mip-level-count > 1`
allocates a mip chain — levels beyond what you write stay uninitialized until
generated. Note that **sampling** a 1d / 3d / array texture also needs a texture
view whose dimension matches; a default view (used when you bind a texture
directly) is always 2d.

### Texture Views

Binding a `(texture …)` directly (`(entry :texture …)`) gives the shader that
texture's **default 2d view**. To sample a 1d / 3d / **array** / cube texture you
declare an explicit `(texture-view …)` — its `:view-dimension` must match the
WGSL binding (`texture_2d_array`, `texture_3d`, `texture_cube`, …) — and bind it
with `(entry :texture-view …)`:

```
(texture :name arr :width 256 :height 256
  :dimension 2 :depth-or-array-layers 2      ; a 2-layer 2d array
  :format rgba8unorm :usage [texture-binding copy-dst])

(texture-view :name arr_view :texture arr
  :view-dimension 2)                          ; 2 = 2d-array (see table below)

(bind-group :name g :layout-pipeline pipe :layout-index 0
  (entry :binding 0 :sampler samp)
  (entry :binding 1 :texture-view arr_view))  ; binds the explicit view, not a default one
```

`:view-dimension` is authored numerically (same reason as texture `:dimension`):

| value | GPUTextureViewDimension |
|-------|-------------------------|
| `0`   | `1d`                    |
| `1`   | `2d`                    |
| `2`   | `2d-array`              |
| `3`   | `cube`                  |
| `4`   | `cube-array`            |
| `5`   | `3d`                    |

Every other key is optional and defaults to WebGPU's own default (an all-default
view is equivalent to a bare `createView()`): `:aspect` (`all` / `stencil-only` /
`depth-only`), `:base-mip-level` / `:mip-level-count` (a mip sub-range),
`:base-array-layer` / `:array-layer-count` (a layer sub-range), and `:format`
(reinterpret the texel format, e.g. an `-srgb` view of a linear texture).

### Samplers

`(sampler …)` maps directly to a `GPUSamplerDescriptor`. Every field is optional;
omitted fields take PNGine's defaults (filters `linear`, address modes
`clamp-to-edge`). Note the filter default deliberately deviates from the WebGPU
spec (whose default is `nearest`): linear is the friendlier default for shader
art. The deviation is pinned by the `KNOWN_DEFAULT_DEVIATIONS` ledger in
`tests/npm/webgpu-conformance.test.js`; a port of a raw-WebGPU sample that
relies on nearest filtering must author `:mag-filter nearest :min-filter nearest`.

```
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

By default a pipeline **auto-derives** its layout from the WGSL (`(layout auto)`).
To bind `@group(0)`, `@group(1)`, … to **distinct explicit layouts** — the only
way to pin per-group visibility that the shader alone doesn't determine — declare
`(bind-group-layout …)` forms, compose them in order with a `(pipeline-layout …)`,
and reference it from the pipeline with `:pipeline-layout`:

```
(bind-group-layout :name bglColor
  (entry :binding 0 :visibility [fragment] (buffer :type uniform)))
(bind-group-layout :name bglXform
  (entry :binding 0 :visibility [vertex] (buffer :type uniform)))

(pipeline-layout :name pl :bind-group-layouts [bglColor bglXform])   ; @group 0, 1

(render-pipeline :name pipe :pipeline-layout pl
  (vertex (module mod) (entry vs))
  (fragment (module mod) (entry fs) (targets (target :format bgra8unorm))))

(bind-group :name gColor :layout-pipeline pipe :layout-index 0
  (entry :binding 0 :buffer colorBuf))
(bind-group :name gXform :layout-pipeline pipe :layout-index 1
  (entry :binding 0 :buffer xformBuf))
```

`:bind-group-layouts` lists the `(bind-group-layout …)` at `@group` 0, 1, … in
order. `:pipeline-layout` works on both `(render-pipeline …)` and
`(compute-pipeline …)`, and supersedes the `(layout auto)` positional when
present. Bind groups take their per-group layout from the **pipeline**
(`:layout-pipeline pipe :layout-index N`), so each group resolves to
`pipeline.getBindGroupLayout(N)` — the matching entry of the explicit layout.

A BGL `(entry …)` models any of the four WebGPU binding-resource kinds, not just
buffers — the nested form picks the kind, and its enum fields are the WebGPU
spellings passed through verbatim:

```
(bind-group-layout :name bgl
  (entry :binding 0 :visibility [fragment] (buffer :type uniform))
  (entry :binding 1 :visibility [fragment] (sampler :type filtering))
  (entry :binding 2 :visibility [fragment]
    (texture :sample-type float :view-dimension 1 :multisampled false))
  (entry :binding 3 :visibility [compute]
    (storage-texture :format r32float :access read-write :view-dimension 1)))
```

`(sampler :type)` is `filtering`/`non-filtering`/`comparison`;
`(texture :sample-type)` is `float`/`unfilterable-float`/`depth`/`sint`/`uint`;
`(storage-texture :access)` is `write-only`/`read-only`/`read-write`. In both
texture kinds `:view-dimension` is the same 0..5 integer used by `(texture-view …)`
(0=`1d`, 1=`2d`, 2=`2d-array`, 3=`cube`, 4=`cube-array`, 5=`3d`). The entry
types must match the WGSL binding they front, or WebGPU rejects the pipeline —
which the native oracle now reports as a nonzero exit rather than a blank frame.
See `examples/webgpu_bgl_resources.sjon`.

### Vertex Input Layout

A `(vertex …)` stage that reads vertex buffers declares their layout with a
`(buffers …)` child — one `(vertex-buffer …)` per bound slot, in slot order,
each holding its `(attribute …)` children:

```
(render-pipeline :name pipe (layout auto)
  (vertex (module code) (entry vertMain)
    (buffers
      (vertex-buffer :array-stride 40
        (attribute :shader-location 0 :offset 0  :format float32x4)
        (attribute :shader-location 1 :offset 16 :format float32x4)
        (attribute :shader-location 2 :offset 32 :format float32x2))))
  (fragment (module code) (entry fragMain)
    (targets (target :format preferred-canvas-format))))
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

Omit `(buffers …)` entirely for pipelines that generate their vertices from
`@builtin(vertex_index)` (the fullscreen-quad and `(pass …)` cases).

See `examples/rotating_cube.sjon` (interleaved) and `examples/boids.sjon`
(`:step-mode instance` for per-instance data).

### Pipeline-overridable constants (`(constant …)`)

A WGSL `override` declaration is a value supplied when the pipeline is created.
pngine resolves it at **compile time** instead: `(constant …)` substitutes the
value into the shader text, turning the `override` into a `const` before the
module is validated, minified and shipped.

```
(shader-module :name code :code """
override QUALITY: u32 = 1u;
override SCALE: f32;
…
""")
(render-pipeline :name pipe (layout auto)
  (vertex (module code) (entry vs)
    (constant :name QUALITY :value 3))
  (fragment (module code) (entry fs)
    (targets (target :format bgra8unorm))
    (constant :name SCALE :value 0.5)))

(compute-pipeline :name cp :module code :entry cs
  (constant :name WG :value (* GROUP 1)))
```

`:value` is an ordinary numeric slot, so it takes a literal or a bounded
expression over `(define …)` constants — with the usual trap that a **bare**
define name works only in count slots, so write `(* GROUP 1)`, not `GROUP`.

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

`(primitive …)` mirrors `GPUPrimitiveState`. Beyond `(topology …)`, `:cull-mode`,
and `:front-face`, two fields cover the rest of the descriptor:

```
(render-pipeline :name strip
  (vertex (module code) (entry vs))
  (fragment (module code) (entry fs) (targets (target :format bgra8unorm)))
  (primitive (topology triangle-strip) :strip-index-format uint32 :unclipped-depth true))
```

- `:strip-index-format` (`uint16` / `uint32`) — the index byte-width WebGPU needs
  when `(draw-indexed …)` runs under a **strip** topology (`triangle-strip` /
  `line-strip`); it selects the primitive-restart value. Omit it for list
  topologies and non-indexed draws.
- `:unclipped-depth` (boolean) — disables depth clipping, clamping fragments to
  `[0, 1]` instead of discarding them (shadow casters, depth pre-passes). It needs
  the `depth-clip-control` device feature, which both the browser runtime and the
  native renderer request **opportunistically** (only when the adapter advertises
  it), so a pipeline that sets it renders wherever the GPU supports it.

Both are emitted into the pipeline descriptor only when authored — a plain
`(primitive …)` stays byte-identical to before.

### Blending & the blend constant

A fragment `(target …)` carries an optional `(blend …)` mirroring
`GPUBlendState` — a `(color …)` and an `(alpha …)` component, each with
`:src-factor`, `:dst-factor`, and `:operation` (the WebGPU spellings, e.g.
`src-alpha`, `one-minus-src-alpha`, `add`). Omit `(blend …)` for opaque targets.

When a factor is `constant` or `one-minus-constant`, the constant colour itself
is render-pass state, set with `:blend-constant [r g b a]` (four floats, default
`[0 0 0 0]`):

```
(render-pipeline :name pipe (layout auto)
  (vertex (module code) (entry vs))
  (fragment (module code) (entry fs)
    (targets
      (target :format preferred-canvas-format
        (blend
          (color :src-factor constant :dst-factor one-minus-constant :operation add)
          (alpha :src-factor one :dst-factor zero :operation add))))))

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

**Clear-value precision**: `:clear-value` channels are quantized to 8-bit UNorm
on the wire (the WebGPU spec takes doubles per channel), so out-of-[0,1] / HDR
clears on float targets are not expressible — a clear rounds to the nearest
1/255 step. Pinned as a documented deviation in
`tests/npm/webgpu-conformance.test.js` (`KNOWN_DEFAULT_DEVIATIONS`).

### Depth and Stencil

Two forms, on opposite sides of the pipeline/pass split. `(depth-stencil …)` is
**pipeline** state — how this pipeline tests and writes depth and stencil.
`(depth-attachment …)` is **pass** state — which texture it tests against and
what happens to it at the pass boundary.

```
(texture :name depthTex :size canvas :format depth24plus-stencil8
  :usage [render-attachment])

(render-pipeline :name pipe (layout auto)
  (vertex (module code) (entry vs))
  (fragment (module code) (entry fs) (targets (target :format bgra8unorm)))
  (depth-stencil :format depth24plus-stencil8
    :depth-write-enabled true :depth-compare less
    (stencil-front :compare always :pass-op replace)
    (stencil-back :compare always :pass-op keep)))

(render-pass :name draw
  (color-attachment :view context-current-texture
    :clear-value [0 0 0 1] :load-op clear :store-op store)
  (depth-attachment :view depthTex
    :depth-clear-value 1.0 :depth-load-op clear :depth-store-op store
    :stencil-clear-value 0 :stencil-load-op clear :stencil-store-op store)
  :pipeline pipe :stencil-reference 1
  (draw :vertex-count 3))
```

`(depth-stencil …)` keys, all optional and emitted only when authored:
`:format`, `:depth-write-enabled`, `:depth-compare` (a `GPUCompareFunction`:
`less`, `equal`, `always`, …), `:stencil-read-mask` / `:stencil-write-mask`
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

`(depth-attachment …)` takes `:view` (the depth `(texture …)`) plus independent
load/store pairs for each aspect: `:depth-clear-value` (must be in `[0,1]`),
`:depth-load-op` (`clear`, default / `load`), `:depth-store-op` (`store`,
default / `discard`), and `:stencil-clear-value`, `:stencil-load-op`,
`:stencil-store-op`. Author the stencil three only for a combined-format
attachment; a `depth24plus` texture has no stencil aspect to clear.

### Multisampling (MSAA)

`(multisample …)` is pipeline state mirroring `GPUMultisampleState`. Its
`:count` must equal the `:sample-count` of every attachment texture the pipeline
renders to, and the multisampled colour attachment resolves to the canvas
through `:resolve-target`:

```
(texture :name msaaTex :size canvas :format bgra8unorm
  :sample-count 4 :usage [render-attachment])

(render-pipeline :name pipe (layout auto)
  (vertex (module code) (entry vs))
  (fragment (module code) (entry fs) (targets (target :format bgra8unorm)))
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

```
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

### Viewport, Scissor and Render Bundles

A `(render-pass …)` carries three more pieces of optional state and one
alternative to inline drawing:

```
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

```
(render-bundle :name bundle :pipeline pipe
  :color-formats [bgra8unorm] :depth-stencil-format depth24plus :sample-count 1
  :vertex-buffers [verts] :bind-groups [g]
  :draw 3 :instance-count 1)

(render-pass :name draw
  (color-attachment :view context-current-texture :load-op clear :store-op store)
  (depth-attachment :view depthTex :depth-load-op clear :depth-store-op store)
  :execute-bundles [bundle])
```

`:color-formats`, `:depth-stencil-format` and `:sample-count` record the
attachment shape the bundle is compatible with; they must match the executing
pass or WebGPU rejects the replay. The recorded draw is `:draw <vertex-count>`
or `:draw-indexed <index-count>` (with `:index-buffer`), plus
`:instance-count`. See `examples/webgpu_render_bundles.sjon`.

### Canvas configuration

An optional singleton `(canvas …)` form configures how the canvas composites
with the page:

```
(canvas :alpha-mode opaque)    ; opaque | premultiplied (default premultiplied)
```

`opaque` ignores the alpha channel (the WebGPU spec default — cheaper
compositing, no fringe artifacts on colored pages); `premultiplied` blends the
canvas with the page and is PNGine's default when the form is absent (a pinned
deviation — see `KNOWN_DEFAULT_DEVIATIONS`). The value rides a PNGB header
flag, consumed at `context.configure()` before the executor runs; the pNGf
(`mini`) export mirrors it in its flags byte. Native `--frame` renders
offscreen and ignores it.

### Device limits

By default a payload runs against WebGPU's **default** device limits. Some
shaders need more — most commonly a compute entry whose `@workgroup_size`
exceeds the default `maxComputeWorkgroupSizeX` / `maxComputeInvocationsPerWorkgroup`
(both 256). Declare the raised limits with a single top-level `(limits …)` form
(one per document); each key is the WebGPU limit name in **kebab-case** and takes
a non-negative integer:

```
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

```
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
positional children are the `(draw …)` / `(draw-indexed …)` calls whose passing
samples are counted into `:query-index` of the pass's `:occlusion-query-set`.

Timestamps attach to a pass instead of bracketing draws:

```
(query-set :name ts :type timestamp :count 2)

(render-pass :name draw
  (color-attachment :view context-current-texture :load-op clear :store-op store)
  (timestamp-writes :query-set ts :begin 0 :end 1)
  :pipeline pipe
  (draw :vertex-count 3))
```

`:begin` (default 0) and `:end` (default 1) are the indices written at pass start
and end. `(resolve-query-set …)` needs `:destination` to carry `query-resolve`
usage, and WebGPU requires `:destination-offset` to be a multiple of 256. See
`examples/webgpu_occlusion_query.sjon` and `examples/webgpu_timestamp_query.sjon`.

### Copies

Three `(queue …)` actions copy between GPU resources; none of them transfers
through the CPU.

```
(queue :name copies
  (copy-buffer-to-buffer :source results :source-offset 0
    :destination readback :destination-offset 0 :size 48)
  (copy-texture-to-texture :source context-current-texture :destination history)
  (copy-external-image-to-texture :source photo :texture albedo
    :mip-level 0 :origin [0 0 0]))
```

- `(copy-buffer-to-buffer …)` — `:source` needs `copy-src` usage and
  `:destination` needs `copy-dst`; the two offsets and `:size` must all be
  multiples of 4. The usual job is moving resolved query results into a
  map-readable buffer.
- `(copy-texture-to-texture …)` — `:source` and `:destination` are each either a
  `(texture …)` name or `context-current-texture` (the canvas), which is how a
  frame keeps a copy of itself for feedback.
- `(copy-external-image-to-texture …)` — uploads a decoded `(image-bitmap …)`
  into `:texture` (needs `copy-dst`). `:mip-level` defaults to 0 and `:origin`
  to `[0 0 0]`, whose `z` selects the destination array layer or depth slice —
  that is how a cubemap's six faces load into one texture.

### Images

`(image-bitmap …)` is a decoded image. `:image` names a `(data … :blob …)`
entry, which embeds an encoded image file in the payload as
`[mime_len][mime][bytes]`; the runtime decodes it with `createImageBitmap`:

```
(data :name photoBytes :blob "textures/photo.png" :mime "image/png")
(image-bitmap :name photo :image photoBytes)

(texture :name albedo :size-from photo :format rgba8unorm
  :usage [texture-binding copy-dst render-attachment])

(queue :name upload
  (copy-external-image-to-texture :source photo :texture albedo))
```

`:size-from` sizes the texture from the decoded image, so the dimensions do not
have to be restated. `(data …)` also takes `:float32 [ … ]` for an inline
little-endian float array — the plain way to embed a lookup table or a small
mesh without a shape generator. See `examples/cubemap.sjon` and
`examples/normal_map.sjon`.

### Runtime WASM

Two forms run WebAssembly, at different times. `(wasm-data …)` is a positional
child of `(data …)` and runs **once**, at buffer-create time, filling the buffer
through `mappedAtCreation`. `(wasm-call …)` is a top-level form that runs **every
frame**, and a `(write-buffer … :data-from-wasm …)` puts its result in a buffer:

```
; once, at creation
(data :name table (wasm-data :url "gen.wasm" :func buildTable :returns "array<f32,360>"))
(buffer :name lut :size table :usage [storage] :mapped-at-creation table)

; every frame
(wasm-call :name mvp :url "mvp.wasm" :func buildMVPMatrix :returns "mat4x4"
  :args [canvas-width canvas-height time-total])
(queue :name writeMvp
  (write-buffer :buffer uniforms :offset 0 :data-from-wasm mvp))
```

`:url` is relative to the source file, and modules are deduplicated by url.
`:returns` is a type spelling the compiler turns into a byte count (`mat4x4` →
64, `vec4` → 16, `f32` → 4, `array<f32,360>` → 1440). `:args` are numeric
literals or the runtime builtins `canvas-width`, `canvas-height`, `time-total`
and `time-delta`, filled by the player each frame. `:data-from-wasm` is mutually
exclusive with `:data` on the same `(write-buffer …)`.

A `(buffer … :wasm "mod.wasm")` is the third spelling: the module's own exports
supply both the size and the initial bytes, so `:size` is not authored at all.
`pngine/pass-v1` synthesizes it for `(pass … :data …)`. See
`examples/test_wasm_data.sjon` and `examples/wasm_rotated_cube.sjon`; the WASM
tiers are stubs under native `--frame`, so these render in the browser.

### `(pass …)` Sugar (Shorthand for Shader Art)

`(pass …)` (formerly the `#pass` macro) is sugar for a fullscreen shader: write
`(pass …)` children inside a
`(pass-graph …)` container and the `pngine/pass-v1` lowering hook auto-generates
every resource (uniform buffer, pipeline, bind group, render pass), detecting
features from the WGSL and creating only what's needed. The container sees all
passes at once, so cross-pass texture ids sequence coherently.

```
(pass-graph
  (pass :name <name>
    :code "<WGSL shader code>"
    :feedback true                ; optional: ping-pong texture for feedback
    :data ["a.wasm" "b.wasm"]     ; optional: WASM data files → D0, D1, …
    :init "<WGSL compute code>")) ; optional: one-shot compute init
```

**Auto-generated resources:**

| Resource     | Condition                     | Binding |
| ------------ | ----------------------------- | ------- |
| Uniform buf  | Code references `pngine`      | 0       |
| Pointer buf  | Code references `pointer`     | next    |
| Sampler      | Has deps/feedback/texSample   | next    |
| Dep textures | Prior `(pass …)` outputs      | next    |
| Feedback tex | `feedback=true`               | next    |
| Data buffers | `data=` present               | next    |

The prelude auto-injects `@binding(N)` declarations. For data buffers, it injects
`var<storage, read> D0: array<f32>`, `D1: array<f32>`, etc.

**Example: Simple shader art**

```
(pass-graph
  (pass :name main :code """
    @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
      let uv = pos.xy / vec2f(pngine.width, pngine.height);
      return vec4f(uv, 0.5 + 0.5 * sin(pngine.time), 1);
    }
  """))
```

**Example: Multi-pass with feedback** (both passes in one `(pass-graph …)`)

```
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

### `(pass …)` with `:data` (WASM Data Buffers)

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

```
(pass-graph
  (pass :name main :data ["colors.wasm"] :code """
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

```
(pass-graph
  (pass :name main :data ["colors.wasm" "shapes.wasm"] :code """
    // D0 = colors.wasm data, D1 = shapes.wasm data
    fn get_color(i: u32) -> vec3f { ... D0 ... }
    fn get_shape(i: u32) -> vec3f { ... D1 ... }
  """))
```

**WGSL alignment note**: `array<f32>` has stride 4 (packed, no padding).
`array<vec3f>` has stride 16 (33% waste). Use `array<f32>` and index manually
for maximum compactness.
