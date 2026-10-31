/**
 * The sugar tier's ledger: what every key of every lowered form desugars to,
 * and the hand-written twin that proves it.
 *
 * ## Why this file exists
 *
 * `schema/pngine.sjon` is two vocabularies wearing one file. Half A is the
 * WebGPU mirror, and `webgpu-mapping.mjs` holds it against the gpuweb IDL
 * snapshot bidirectionally, so it cannot drift. Half B is the forms pngine
 * invented, and grepping the ten of them against that map scores zero hits, all
 * ten. Every key on half B landed because someone decided it should.
 *
 * The sharpest part of half B is the sugar tier: a key that only rearranges
 * forms is cheap, a key that reaches a GPU descriptor costs schema + wire +
 * four decoders + two backends + a render fixture, and on a sugar form nothing
 * made that price visible before it was paid. Four of the last fifteen
 * CONTRIBUTING pitfalls are one each from a recent `(pass …)` key.
 *
 * ## The anchor
 *
 * Sugar has no external spec, so its anchor is the hand-written twin. A hook's
 * `:produces` list names only ordinary core forms, so a sugar document is by
 * definition a document someone could have written by hand.
 *
 *   > A sugar key with no hand-written twin is not sugar. It is a core
 *   > capability wearing a sugar spelling, and that is exactly the drift.
 *
 * Each entry therefore carries either a `twin` (with the `equivalence` it was
 * measured at) or a `ledger` line saying, honestly, that nobody has written one.
 * The ledger starts nearly full and emptying it is the work — the same shape as
 * the WebGPU required-ness ratchet, which began with three unledgered
 * divergences and ended with both ledgers empty.
 *
 * ## The two equivalence levels, and which is reachable
 *
 *   - `byte`  — the twin compiles to the same payload.
 *   - `pixel` — the twin renders the same image from a different payload.
 *
 * `byte` is NOT reachable for any `(pass-graph …)` or `(draw-graph …)` twin, and
 * step 0 (journal §425) measured why. Two structural reasons, neither about any
 * particular key:
 *
 *   1. The sugar emits documents that would not validate. A `(pass :name main)`
 *      produces both a `(render-pass :name main)` and a `(frame :name main)`;
 *      hand-written that is `duplicate name 'main'`, and lowered forms never
 *      face the check. The twin must rename one of them.
 *   2. The emitter walks AUTHORED forms grouped by kind and LOWERED forms in
 *      emission order. Eleven identical resources arrive in two sequences —
 *      1,879 of 2,323 payload bytes differ while the frame half of the trace
 *      stays identical command-for-command.
 *
 * So `byte` is for twins between two AUTHORED documents (the corpus has one
 * pair: `test_derived_bind_groups` against `test_prune_unused`), and every
 * sugar twin is `pixel`.
 *
 * ## What the gate does with this
 *
 * `scripts/check-sugar-ledger.mjs`, bidirectionally, the way the WebGPU one
 * runs. It DERIVES the sugar form set from the schema — the forms declaring
 * `:lowering`, plus everything reachable through their `:positional` sections
 * that no hook `:produces` — so a new sugar form or a new key on an old one
 * fails until it is written down here.
 *
 * @see docs/plans/sugar-tier-ledger.md
 */

/**
 * Twins live in `examples/`, named `<the sugar fixture>_hand.sjon`.
 *
 * Not beside the plan that introduced them, for a reason worth keeping: a
 * `twin:` that only has to EXIST measures nothing, and the first one had
 * already drifted by the time anybody looked (§425 stopped the pass hook
 * emitting a dead last-pass texture; the twin still carried one). Gating it
 * means rendering it, rendering it means a row in
 * `tests/zig/render/render_test.zig`, and a row embeds its source through
 * `build.zig` — which `docs/plans/` cannot supply, because the release cut
 * strips it.
 *
 * `examples/` also buys the OTHER half of the claim for free. A twin asserts
 * two things: that somebody could have written this by hand, and that it is the
 * same program. `zig build test-core` proves the first by compiling every
 * example with an EMPTY lowering registry, so a twin that quietly used sugar
 * would be refused there; `render_test.zig`'s `twin_of` proves the second.
 */
export const TWIN_HOME = "examples";

/**
 * Every form of the sugar tier, and every key on it.
 *
 * `hook` is set on the three lowering containers and must match the schema's
 * `:lowering (lowering :hook …)`. The other forms are consumed by a container
 * and never reach the emitter, which is why they carry none.
 *
 * Per key, exactly one of:
 *   - `twin` (a path, relative to the repo root) + `equivalence`
 *   - `ledger` (why there is no twin yet)
 */
export const SUGAR_FORMS = {
  "pass-graph": {
    hook: "pngine/pass-v1",
    keys: {
      name: {
        desugars_to: "step-group :name (instead of the emitted frame)",
        twin: "examples/graph_compose_hand.sjon",
        equivalence: "pixel",
      },
      before: {
        desugars_to: "the head of the emitted frame's :perform",
        twin: "examples/pass_reads_depth_hand.sjon",
        equivalence: "pixel",
      },
      expose: {
        desugars_to: "the compute auto-blit machinery per named pass (`<pass>__blit_shader`, `<pass>__blit_pipe`, `<pass>__blit_bg` and `<pass>__blit` reading `<pass>__tex`), emitted into NO step list so only a frame that names `<pass>__blit` runs it",
        ledger:
          "no twin: the only hand-written equivalent reads `<pass>__tex`, the hook's internal intermediate naming, which this key exists to keep off the authoring surface (the alternative the verdict set aside)",
      },
    },
  },

  pass: {
    keys: {
      name: {
        desugars_to: "the names of every form the pass emits (`<name>__ubuf`, `__tex`, `__shader`, `__pipe`, `__bg`) and the render pass itself",
        twin: "examples/pass_half_res_hand.sjon",
        equivalence: "pixel",
      },
      code: {
        desugars_to: "shader-module :code, the author's text after the injected binding prelude",
        twin: "examples/pass_half_res_hand.sjon",
        equivalence: "pixel",
      },
      scale: {
        desugars_to: "texture :scale (and `const PASS_SCALE: f32` in the prelude)",
        twin: "examples/pass_half_res_hand.sjon",
        equivalence: "pixel",
      },
      feedback: {
        desugars_to: "texture :pool 2 + bind-group :pool 2 + a `prev_<name>` prelude binding + (entry … :ping-pong 1) on the pass's own slot and :ping-pong 0 on every consumer's",
        twin: "examples/pass_bloom_hand.sjon",
        equivalence: "pixel",
      },
      format: {
        desugars_to: "texture :format and the pipeline's (color-target :format …), which must agree",
        twin: "examples/pass_hdr_tonemap_hand.sjon",
        equivalence: "pixel",
      },
      init: {
        desugars_to: "a shader-module whose prelude binds this pass's target as `screen`, a compute-pipeline + bind-group + compute-pass per @compute entry, named into the emitted frame's :init — plus `storage-binding` on that texture's usage",
        twin: "examples/pass_game_of_life_hand.sjon",
        equivalence: "pixel",
      },
      file: {
        desugars_to: "buffer :file per entry (`<pass>__d0`, `__d1`, … with storage|copy-dst usage) + the prelude's `var<storage, read> D{i}: array<f32>` and the entries that bind them",
        twin: "examples/test_data_pass_hand.sjon",
        equivalence: "pixel",
      },
      reads: {
        desugars_to: "bind-group (entry :binding N :texture …), after the dependency entries, plus the prelude declaration that names it",
        twin: "examples/graph_compose_hand.sjon",
        equivalence: "pixel",
      },
      imports: {
        desugars_to: "shader-module :imports, forwarded unchanged onto every module built from the author's text",
        twin: "examples/pass_acid_cubes_hand.sjon",
        equivalence: "pixel",
      },
    },
  },

  "draw-graph": {
    hook: "pngine/draw-v1",
    keys: {
      name: {
        desugars_to: "step-group :name (instead of the emitted frame)",
        twin: "examples/graph_compose_hand.sjon",
        equivalence: "pixel",
      },
      before: {
        desugars_to: "the head of the emitted frame's :perform",
        twin: "examples/webgpu_shadow_mapping.sjon",
        equivalence: "pixel",
      },
      after: {
        desugars_to: "the tail of the emitted frame's :perform",
        twin: "examples/draw_graph_after_hand.sjon",
        equivalence: "pixel",
      },
    },
  },

  stage: {
    keys: {
      name: {
        desugars_to: "the name of every render pass and pipeline this stage's cross product emits",
        twin: "examples/webgpu_shadow_mapping.sjon",
        equivalence: "pixel",
      },
    },
  },

  geometry: {
    keys: {
      name: {
        desugars_to: "the geometry half of every emitted (stage, geometry) render-pass name",
        twin: "examples/webgpu_shadow_mapping.sjon",
        equivalence: "pixel",
      },
      "vertex-buffers": {
        desugars_to: "render-pass :vertex-buffers, on every pass this geometry generates",
        twin: "examples/webgpu_shadow_mapping.sjon",
        equivalence: "pixel",
      },
      "index-buffer": {
        desugars_to: "render-pass :index-buffer, with the format propagated from the buffer's :index-of",
        twin: "examples/webgpu_shadow_mapping.sjon",
        equivalence: "pixel",
      },
    },
  },

  in: {
    keys: {
      stage: {
        desugars_to: "which (stage …) of the graph this geometry's pipeline and pass are built for",
        twin: "examples/webgpu_shadow_mapping.sjon",
        equivalence: "pixel",
      },
    },
  },

  init: {
    hook: "pngine/init-v1",
    keys: {
      name: {
        desugars_to: "the compute pass's name, so a frame's :init [N] resolves to it",
        twin: "examples/boids_init_only_hand.sjon",
        equivalence: "pixel",
      },
      buffer: {
        desugars_to: "bind-group (entry :binding 0 :buffer …) — one entry, which is the whole of what an init hook assumes about a seeding shader",
        twin: "examples/boids_init_only_hand.sjon",
        equivalence: "pixel",
      },
      module: {
        desugars_to: "compute-pipeline (compute :module … :entry main)",
        twin: "examples/boids_init_only_hand.sjon",
        equivalence: "pixel",
      },
      workgroups: {
        desugars_to: "dispatch :workgroups, expressions over (define …) included",
        twin: "examples/boids_init_only_hand.sjon",
        equivalence: "pixel",
      },
    },
  },
};

/** The equivalence levels an entry may claim. */
export const EQUIVALENCE_LEVELS = ["byte", "pixel"];
