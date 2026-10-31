// The PNGine ↔ WebGPU vocabulary map: where every schema word comes from.
//
// Three tables, one decision each:
//   ENUM_MAP          a schema value-kind → the WebGPU enum or flag namespace
//                     whose values it spells (`copy-dst` is GPUBufferUsage.COPY_DST,
//                     `line-list` is GPUPrimitiveTopology "line-list").
//   KNOWN_UNSUPPORTED the spec values a mapped kind deliberately leaves out
//                     (compressed texture formats without an upload path, …).
//   FORM_DICT_MAP     a schema form → the WebGPU dictionary it mirrors, with the
//                     keys that are PNGine's own (`sentinels`), the renames that
//                     are not mechanical (`alias`), the members that arrive as
//                     positional sub-forms (`provided`), and the members PNGine
//                     cannot express yet (`ledger`).
//
// The spelling rules the tables lean on are the two helpers at the bottom:
// kebabFromFlag (MAP_READ → map-read) and camel (front-face → frontFace).
//
// This file is DATA, and it is checked: tests/npm/webgpu-conformance.test.js
// holds every table against schema/webgpu-enums.json (the IDL snapshot the
// gpuweb spec is extracted into) and against schema/pngine.sjon, so a value
// or member named here that the spec or the schema does not have fails the
// gate, and a spec value or member named by neither a table nor a ledger fails
// it too. The docs site generates its "where these words come from" tables
// from this file, which is why the tables live under schema/ and not inside
// the test that checks them (the release cut strips tests/; schema/ ships).
//
// The default and required-ness ledgers (KNOWN_DEFAULT_DEVIATIONS,
// KNOWN_OPTIONAL_REQUIRED, KNOWN_DEFAULT_DISAGREEMENTS) stay in the test: they
// are about behaviour, not vocabulary.

// PNGine value-kind → its WebGPU source. `sentinels` are intentional PNGine-only
// members (not spec values) the SUBSET check tolerates.
export const ENUM_MAP = {
  'texture-format': { enum: 'GPUTextureFormat', sentinels: ['preferred-canvas-format'] },
  'color-target-format': { enum: 'GPUTextureFormat', sentinels: ['preferred-canvas-format'] },
  'vertex-format': { enum: 'GPUVertexFormat' },
  'blend-factor': { enum: 'GPUBlendFactor' },
  'blend-operation': { enum: 'GPUBlendOperation' },
  'primitive-topology': { enum: 'GPUPrimitiveTopology' },
  'compare-function': { enum: 'GPUCompareFunction' },
  'stencil-operation': { enum: 'GPUStencilOperation' },
  'address-mode': { enum: 'GPUAddressMode' },
  // `mipmap-filter` keys reuse `filter-mode`: GPUMipmapFilterMode's member set
  // equals GPUFilterMode's (nearest/linear), so one kind covers both.
  'filter-mode': { enum: 'GPUFilterMode' },
  'cull-mode': { enum: 'GPUCullMode' },
  'front-face': { enum: 'GPUFrontFace' },
  'index-format': { enum: 'GPUIndexFormat' },
  'step-mode': { enum: 'GPUVertexStepMode' },
  'load-op': { enum: 'GPULoadOp' },
  'store-op': { enum: 'GPUStoreOp' },
  'query-type': { enum: 'GPUQueryType' },
  'buffer-binding-type': { enum: 'GPUBufferBindingType' },
  'canvas-alpha-mode': { enum: 'GPUCanvasAlphaMode' },
  'sampler-binding-type': { enum: 'GPUSamplerBindingType' },
  'texture-sample-type': { enum: 'GPUTextureSampleType' },
  'storage-texture-access': { enum: 'GPUStorageTextureAccess' },
  'texture-aspect': { enum: 'GPUTextureAspect' },
  // Spelled as WebGPU spells them since 3.0.0 (SJON 1.3 digit-leading members;
  // they were integer codes before, invisible to this gate).
  'texture-dimension': { enum: 'GPUTextureDimension' },
  'view-dimension': { enum: 'GPUTextureViewDimension' },
  'buffer-usage': { flags: 'GPUBufferUsage' },
  'texture-usage': { flags: 'GPUTextureUsage' },
  'visibility': { flags: 'GPUShaderStage' },
  'write-mask': { flags: 'GPUColorWrite' },
};

// The explicit, tested gap. Each array is exactly the spec values the engine
// does NOT yet support, so `supported ∪ KNOWN_UNSUPPORTED === spec`. Phases move
// values OUT of these arrays as engine support lands.
export const KNOWN_UNSUPPORTED = {
  'texture-format': [
    // compressed (BC/ETC2/EAC/ASTC): encodable + feature-requestable, but need a
    // compressed-data upload path PNGine doesn't have yet — kept out so we never
    // suggest a value that won't render. (The feature-gated uncompressed formats —
    // tier1 16-bit unorm/snorm, bgra8 srgb, depth32float-stencil8 — are now
    // supported: encoded unconditionally, their device feature requested at runtime.)
    'bc1-rgba-unorm', 'bc1-rgba-unorm-srgb', 'bc2-rgba-unorm', 'bc2-rgba-unorm-srgb', 'bc3-rgba-unorm', 'bc3-rgba-unorm-srgb', 'bc4-r-unorm', 'bc4-r-snorm', 'bc5-rg-unorm', 'bc5-rg-snorm', 'bc6h-rgb-ufloat', 'bc6h-rgb-float', 'bc7-rgba-unorm', 'bc7-rgba-unorm-srgb', 'etc2-rgb8unorm', 'etc2-rgb8unorm-srgb', 'etc2-rgb8a1unorm', 'etc2-rgb8a1unorm-srgb', 'etc2-rgba8unorm', 'etc2-rgba8unorm-srgb', 'eac-r11unorm', 'eac-r11snorm', 'eac-rg11unorm', 'eac-rg11snorm', 'astc-4x4-unorm', 'astc-4x4-unorm-srgb', 'astc-5x4-unorm', 'astc-5x4-unorm-srgb', 'astc-5x5-unorm', 'astc-5x5-unorm-srgb', 'astc-6x5-unorm', 'astc-6x5-unorm-srgb', 'astc-6x6-unorm', 'astc-6x6-unorm-srgb', 'astc-8x5-unorm', 'astc-8x5-unorm-srgb', 'astc-8x6-unorm', 'astc-8x6-unorm-srgb', 'astc-8x8-unorm', 'astc-8x8-unorm-srgb', 'astc-10x5-unorm', 'astc-10x5-unorm-srgb', 'astc-10x6-unorm', 'astc-10x6-unorm-srgb', 'astc-10x8-unorm', 'astc-10x8-unorm-srgb', 'astc-10x10-unorm', 'astc-10x10-unorm-srgb', 'astc-12x10-unorm', 'astc-12x10-unorm-srgb', 'astc-12x12-unorm', 'astc-12x12-unorm-srgb'],
  'color-target-format': [
    // rgb9e5ufloat is never renderable (shared-exponent, sample-only). Every other
    // uncompressed color format is now a supported render target — the tier1-gated
    // ones (8/16-bit snorm, 16-bit unorm, rg11b10ufloat, bgra8 srgb) render where
    // the adapter has the feature the runtime requests.
    'rgb9e5ufloat',
    // depth/stencil formats are never color targets
    'stencil8', 'depth16unorm', 'depth24plus', 'depth24plus-stencil8', 'depth32float', 'depth32float-stencil8',
    // compressed: not a renderable color target (and no upload path yet)
    'bc1-rgba-unorm', 'bc1-rgba-unorm-srgb', 'bc2-rgba-unorm', 'bc2-rgba-unorm-srgb', 'bc3-rgba-unorm', 'bc3-rgba-unorm-srgb', 'bc4-r-unorm', 'bc4-r-snorm', 'bc5-rg-unorm', 'bc5-rg-snorm', 'bc6h-rgb-ufloat', 'bc6h-rgb-float', 'bc7-rgba-unorm', 'bc7-rgba-unorm-srgb', 'etc2-rgb8unorm', 'etc2-rgb8unorm-srgb', 'etc2-rgb8a1unorm', 'etc2-rgb8a1unorm-srgb', 'etc2-rgba8unorm', 'etc2-rgba8unorm-srgb', 'eac-r11unorm', 'eac-r11snorm', 'eac-rg11unorm', 'eac-rg11snorm', 'astc-4x4-unorm', 'astc-4x4-unorm-srgb', 'astc-5x4-unorm', 'astc-5x4-unorm-srgb', 'astc-5x5-unorm', 'astc-5x5-unorm-srgb', 'astc-6x5-unorm', 'astc-6x5-unorm-srgb', 'astc-6x6-unorm', 'astc-6x6-unorm-srgb', 'astc-8x5-unorm', 'astc-8x5-unorm-srgb', 'astc-8x6-unorm', 'astc-8x6-unorm-srgb', 'astc-8x8-unorm', 'astc-8x8-unorm-srgb', 'astc-10x5-unorm', 'astc-10x5-unorm-srgb', 'astc-10x6-unorm', 'astc-10x6-unorm-srgb', 'astc-10x8-unorm', 'astc-10x8-unorm-srgb', 'astc-10x10-unorm', 'astc-10x10-unorm-srgb', 'astc-12x10-unorm', 'astc-12x10-unorm-srgb', 'astc-12x12-unorm', 'astc-12x12-unorm-srgb'],
  'vertex-format': [], // CP-B (Phase 1): spec-complete — all 41 GPUVertexFormat values supported.
  'blend-factor': [], // spec-complete: all 17 GPUBlendFactor values supported. The
  // 4 dual-source factors (src1/…) are passthrough strings (Emitter writes srcFactor
  // verbatim); the runtime requests dual-source-blending so they render where allowed.
  'buffer-usage': [], // spec-complete: all 10 GPUBufferUsage flags supported.
  // transient-attachment (memoryless tile-GPU attachments) is unimplemented in
  // desktop browsers and carries a strict usage rule (must be exactly
  // TRANSIENT_ATTACHMENT | RENDER_ATTACHMENT) the schema can't express — kept out
  // so we never suggest a value that won't render.
  'texture-usage': ['transient-attachment'],
  // Spec-complete small enums, ratcheted so a new spec value fails here until
  // triaged.
  'sampler-binding-type': [],
  'texture-sample-type': [],
  'storage-texture-access': [],
  'texture-aspect': [],
  'canvas-alpha-mode': [],
  'texture-dimension': [],
  'view-dimension': [],
};

// ---------------------------------------------------------------------------
// Field-level dictionary ratchet: what the gap
// ledger does for enum VALUES, this does for descriptor MEMBERS. For every
// schema form that mirrors a spec dictionary:
//
//     camel(keys − sentinels, aliases applied) ∪ provided ∪ ledger
//        === declared dict members, exactly.
//
// Mechanics beyond bare kebab→camel renames:
//   - `sentinels`: PNGine-only keys (`:name` is the GPUObjectDescriptorBase
//     `label` analogue; `:pool`/`:ping-pong`/`:file` are engine machinery).
//   - `alias`: schema key → dict member when the rename isn't mechanical, incl.
//     many-to-one for the flattened GPUExtent3D (width+height+layers → size).
//   - `provided`: members present as POSITIONAL SUB-FORMS, not `:key`s —
//     (stencil-front …) satisfies stencilFront, (blend …) satisfies blend.
//   - `ledger`: the tested gap — members PNGine cannot express yet. Every entry
//     is a visible TODO; supporting one means removing it here in the same
//     change (the ratchet direction).
//   - `dict` may list several dictionaries whose DECLARED members union (IDL
//     inheritance is not flattened in the snapshot — render-bundle mirrors
//     GPURenderPassLayout plus its derived encoder descriptor's two booleans).
//
// Deliberately absent (PNGine restructures rather than mirrors — absence is a
// decision, not an accident): `frame`, `render-pass`/`compute-pass` proper
// (PNGB pass model), `shader-module` (code inline vs GPUShaderModuleDescriptor
// hints), `(wgsl …)` fragments (a build-time preprocessor — a fragment is
// never a GPUShaderModule and WebGPU has no dictionary for one; what reaches
// createShaderModule is the assembled text), `(import …)` (the same, one level
// up — it composes DOCUMENTS before validation and is consumed there, so
// nothing it names survives to reach a WebGPU call), pool machinery,
// `(pass …)`/`(init …)` sugar, `(limits …)` (an
// interface, ratcheted by the device-limits block of the test), and
// GPUCanvasConfiguration (`(canvas …)` carries alphaMode alone, as a header
// flag the JS runtime reads at configure(); device/format/usage are the
// runtime's own).
// ---------------------------------------------------------------------------

export const camel = (k) => k.replace(/-(\w)/g, (_, c) => c.toUpperCase());

export const FORM_DICT_MAP = [
  {
    form: 'texture', dict: 'GPUTextureDescriptor',
    // `:scale` joins them as a third compile-time key (§420): it narrows a
    // `:size canvas` texture to a fraction of the canvas and is resolved into
    // the `size` member before any descriptor exists, so it is not a member and
    // never will be.
    sentinels: ['name', 'pool', 'scale'],
    // `:size` IS the one `size` member, schema-required, with three spellings
    // (an extent vector, `canvas`, an image-bitmap ref) inside one kind — so the
    // plain `satisfied` path covers it. It was `:width`/`:height`/`:size-from`
    // aliased many-to-one plus an `enforced:` escape until 3.0.0.
    ledger: ['viewFormats', 'textureBindingViewDimension'], // no reinterpret-list; compat-only member
  },
  {
    form: 'texture-view', dict: 'GPUTextureViewDescriptor',
    sentinels: ['name', 'texture'], // the createView receiver, not a member
    // `:dimension` IS the member since 3.0.0 (it was aliased from
    // `:view-dimension`, which is the BGL resource forms' word).
    ledger: ['usage', 'swizzle'], // view-usage narrowing; component swizzle (new in spec)
  },
  {
    form: 'sampler', dict: 'GPUSamplerDescriptor',
    sentinels: ['name', 'address-mode'], // PNGine sugar: one key seeds all three axes
    ledger: [],
  },
  {
    form: 'buffer', dict: 'GPUBufferDescriptor',
    // index-of/index-format/file source bytes at compile time; pool is ping-pong.
    // `:data` IS `mappedAtCreation` — present ⇒ the buffer is created mapped —
    // and additionally names the bytes, which WebGPU has no member for because
    // the write is a separate call on the mapped range. It was `:mapped-at-creation`,
    // which named the mechanism; the bytes for a resource are `:data`.
    sentinels: ['name', 'pool', 'index-of', 'index-format', 'file'],
    alias: { data: 'mappedAtCreation' },
    enforced: { size: 'resolveBufferSize rejects a buffer naming none of :size/:data/:index-of/:file' },
    ledger: [],
  },
  { form: 'primitive', dict: 'GPUPrimitiveState', ledger: [] },
  {
    form: 'depth-stencil', dict: 'GPUDepthStencilState',
    provided: ['stencilFront', 'stencilBack'],
    ledger: [],
  },
  { form: 'stencil-front', dict: 'GPUStencilFaceState', ledger: [] },
  { form: 'stencil-back', dict: 'GPUStencilFaceState', ledger: [] },
  { form: 'multisample', dict: 'GPUMultisampleState', ledger: [] },
  { form: 'color-target', dict: 'GPUColorTargetState', provided: ['blend'], ledger: [] },
  { form: 'color', dict: 'GPUBlendComponent', ledger: [] },
  { form: 'alpha', dict: 'GPUBlendComponent', ledger: [] },
  {
    form: 'color-attachment', dict: 'GPURenderPassColorAttachment',
    ledger: ['depthSlice'], // 3d-attachment slice selection
  },
  {
    form: 'depth-stencil-attachment', dict: 'GPURenderPassDepthStencilAttachment',
    ledger: ['depthReadOnly', 'stencilReadOnly'], // read-only pass aspects
  },
  { form: 'query-set', dict: 'GPUQuerySetDescriptor', sentinels: ['name'], ledger: [] },
  // The IDL words; the baked indices are ledgered in the conformance test's
  // KNOWN_DEFAULT_DISAGREEMENTS (the wire has no absent marker).
  { form: 'timestamp-writes', dict: 'GPURenderPassTimestampWrites', ledger: [] },
  // The copy endpoints were outside this map until 3.0.0, because the
  // snapshot had no texel-copy dictionaries at all: they live in
  // `spec/sections/copies.bs`, which the extractor did not follow.
  // The wire is two ids for a texture→texture copy (whole-texture, mip 0,
  // origin 0 — the schema says so beside the form), so the subresource
  // members are ledgered as the capability they are.
  {
    form: 'source', within: 'copy-texture-to-texture', dict: 'GPUTexelCopyTextureInfo',
    ledger: ['mipLevel', 'origin', 'aspect'],
  },
  {
    form: 'destination', within: 'copy-texture-to-texture', dict: 'GPUTexelCopyTextureInfo',
    ledger: ['mipLevel', 'origin', 'aspect'],
  },
  {
    form: 'source', within: 'copy-external-image-to-texture', dict: 'GPUCopyExternalImageSourceInfo',
    // `:image` for `source`: a readability call — `(source :source bm)` is
    // the literal rule — recorded the way `entry` keeps its arms.
    alias: { image: 'source' },
    ledger: ['origin', 'flipY'],
  },
  {
    form: 'destination', within: 'copy-external-image-to-texture',
    dict: ['GPUCopyExternalImageDestInfo', 'GPUTexelCopyTextureInfo'], // the dest info inherits the texel-copy info
    ledger: ['colorSpace', 'premultipliedAlpha', 'aspect'],
  },
  {
    form: 'buffer', within: 'bind-group-layout', dict: 'GPUBufferBindingLayout',
    ledger: ['hasDynamicOffset', 'minBindingSize'], // dynamic offsets; early-validation size
  },
  { form: 'sampler', within: 'bind-group-layout', dict: 'GPUSamplerBindingLayout', ledger: [] },
  { form: 'texture', within: 'bind-group-layout', dict: 'GPUTextureBindingLayout', ledger: [] },
  { form: 'storage-texture', within: 'bind-group-layout', dict: 'GPUStorageTextureBindingLayout', ledger: [] },
  {
    form: 'render-bundle', dict: ['GPURenderPassLayout', 'GPURenderBundleEncoderDescriptor'],
    // PNGine records the bundle's commands declaratively in the same form. The
    // recorded draw is a `(draw …)` child now, so the three
    // draw KEYS that used to need a sentinel here are gone from the schema.
    sentinels: ['name', 'pipeline', 'vertex-buffers', 'bind-groups', 'index-buffer'],
    ledger: ['depthReadOnly', 'stencilReadOnly'],
  },
  {
    form: 'vertex-buffer', dict: 'GPUVertexBufferLayout', provided: ['attributes'],
    // Satisfied by construction rather than by a reject: PNGine always emits an
    // attributes array, and an empty one is a legal GPUVertexBufferLayout. A
    // shader that actually reads a @location with none declared is a separate,
    // already-tested error (examples/invalid/vertex_location_unbound.sjon).
    enforced: { attributes: 'always emitted; empty is legal' },
    ledger: [],
  },
  { form: 'attribute', dict: 'GPUVertexAttribute', ledger: [] },
  {
    // The entry form flattens GPUBindGroupEntry + its GPUBufferBinding
    // resource: :buffer/:sampler/:texture/:texture-view all express the one
    // `resource` member (:offset/:size slice a buffer).
    form: 'entry', within: 'bind-group', dict: ['GPUBindGroupEntry', 'GPUBufferBinding'],
    sentinels: ['ping-pong'],
    alias: { buffer: 'buffer', sampler: 'resource', texture: 'resource', 'texture-view': 'resource' },
    provided: ['resource'], // the buffer alias also IS the resource
    // Declaratively required: the form's (exclusive-group :cardinality
    // exactly-one) over :buffer/:sampler/:texture/:texture-view.
    enforced: { resource: 'schema (exclusive-group :cardinality exactly-one)' },
    ledger: [],
  },
  // ── The pipeline descriptors ───────────────────────────────────────────────
  // Absent from this table until now, which is why `layout` (required in
  // GPUPipelineDescriptorBase) and `entryPoint` were caught by nothing at all.
  // These four forms are almost entirely POSITIONAL, so nearly every member
  // arrives via `provided:` — and that is exactly the case the required ratchet
  // below had been skipping in silence.
  {
    form: 'render-pipeline', dict: ['GPURenderPipelineDescriptor', 'GPUPipelineDescriptorBase'],
    sentinels: ['name'],
    // GPUPipelineDescriptorBase.layout is `GPUPipelineLayout | "auto"`: ONE
    // member, so ONE required key whose type is that union. It was the
    // positional `(layout auto)` before 3.0.0, then two keys and an
    // exactly-one exclusive-group, and is now the `pipeline-layout-spec`
    // union — which is why the alias pair collapsed.
    provided: ['vertex', 'fragment', 'primitive', 'depthStencil', 'multisample'],
    enforced: { vertex: "pipeline-section's (head :name vertex :min 1 :max 1) → positional_missing at validation" },
    ledger: [],
  },
  {
    // The stage is a `(compute …)` SUB-FORM now, so this entry
    // covers the pipeline descriptor alone and `compute` arrives positionally.
    // It used to list GPUProgrammableStage alongside, because `:module`/`:entry`
    // were flattened onto the pipeline — the one stage of three that was.
    form: 'compute-pipeline', dict: ['GPUComputePipelineDescriptor', 'GPUPipelineDescriptorBase'],
    sentinels: ['name'],
    provided: ['compute'],
    enforced: { compute: "compute-pipeline-section's (head :name compute :min 1 :max 1) → positional_missing" },
    ledger: [],
  },
  {
    form: 'vertex', dict: ['GPUVertexState', 'GPUProgrammableStage'],
    // `module`/`entryPoint` are KEYS since 3.0.0; `buffers` is the sequence of
    // positional `(vertex-buffer …)` children, wrapper-free since 3.0.0.
    alias: { entry: 'entryPoint' },
    provided: ['buffers', 'constants'],
    ledger: [],
  },
  {
    form: 'fragment', dict: ['GPUFragmentState', 'GPUProgrammableStage'],
    alias: { entry: 'entryPoint' },
    provided: ['targets', 'constants'],
    enforced: {
      targets: "fragment-section's (head :name color-target :min 1) → positional_missing (examples/invalid/fragment_no_targets.sjon)",
    },
    ledger: [],
  },
  {
    // The third stage, and the reason the other two stopped being special: one
    // GPUProgrammableStage shape, spelled one way, wherever it appears.
    form: 'compute', dict: 'GPUProgrammableStage',
    alias: { entry: 'entryPoint' },
    provided: ['constants'],
    ledger: [],
  },
];

/** MAP_READ → map-read: how a flag constant is spelled as a schema member. */
export const kebabFromFlag = (s) => s.toLowerCase().replaceAll('_', '-');
