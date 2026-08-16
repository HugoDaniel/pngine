// The state bag gpu.js hands to its two command-handler modules.
//
// gpu.js is a closure: the resource tables, the clock, and the encoder are all
// local `let`/`const`s, and the extracted dispatchers (gpu-resource-pass-commands.js,
// gpu-queue-commands.js) reach them through this one object. Naming its shape
// is what makes a handler's `ops.foo` a checked reference instead of an
// undefined at frame time — the bag is assembled in one place and read in two,
// so nothing else would catch a member that was renamed on one side only.
//
// ACCESSORS vs PROPERTIES is the load-bearing distinction:
//   - Resource TABLES are plain properties. They are `const` arrays mutated in
//     place, so the reference stays valid for the dispatcher's whole life.
//   - Mutable SCALARS (mem, enc, the clock, the pointer, the callbacks) are
//     reachable only through functions. A plain property would snapshot the
//     value at bag-construction time — before the first frame sets any of them.
//     `pendingReadbacks` is a property precisely because it was changed to be
//     cleared in place rather than reassigned.

/** A WebGPU resource table, indexed by the numeric id in the command stream. */
type ResourceTable<T> = T[];

/** A pipeline of either kind — one table holds both, keyed by id. */
type GpuPipeline = GPURenderPipeline | GPUComputePipeline;

/**
 * The currently-open pass, render or compute.
 *
 * Deliberately ONE type carrying both surfaces rather than a
 * `GPURenderPassEncoder | GPUComputePassEncoder` union. Which kind is open is a
 * property of the COMMAND STREAM — a `draw` only ever arrives between a
 * begin_render_pass and its end_pass, and the Zig emitter is what guarantees
 * that. A union would make every draw handler a type error whose only available
 * fix is a cast, i.e. noise that hides the checks worth having.
 *
 * What this still catches, which is the point: a misspelled method
 * (`setViewPort`), a wrong argument type, a wrong arity. What it cannot catch
 * is dispatching a render command into a compute pass — that is the golden
 * traces' and MockGPU's job, not the type system's.
 */
interface GpuPassEncoder {
  setPipeline(pipeline: GpuPipeline): void;
  setBindGroup(index: number, group: GPUBindGroup | undefined): void;
  setVertexBuffer(slot: number, buffer: GPUBuffer): void;
  setIndexBuffer(buffer: GPUBuffer, format: GPUIndexFormat): void;
  draw(vertexCount: number, instanceCount: number, firstVertex: number, firstInstance: number): void;
  drawIndexed(indexCount: number, instanceCount: number, firstIndex: number, baseVertex: number, firstInstance: number): void;
  drawIndirect(buffer: GPUBuffer, offset: number): void;
  drawIndexedIndirect(buffer: GPUBuffer, offset: number): void;
  dispatchWorkgroups(x: number, y: number, z: number): void;
  dispatchWorkgroupsIndirect(buffer: GPUBuffer, offset: number): void;
  executeBundles(bundles: GPURenderBundle[]): void;
  setViewport(x: number, y: number, w: number, h: number, minDepth: number, maxDepth: number): void;
  setScissorRect(x: number, y: number, w: number, h: number): void;
  setStencilReference(reference: number): void;
  setBlendConstant(color: GPUColorDict): void;
  beginOcclusionQuery(index: number): void;
  endOcclusionQuery(): void;
  end(): void;
}

/** A WASM module instantiated by init_wasm_module (0x30). */
interface WasmModuleEntry {
  inst: WebAssembly.Instance;
  /** Memory passed as an import, for modules that do not export their own. */
  importedMem: WebAssembly.Memory;
}

/** The result of one call_wasm_func (0x31), consumed by write_buffer_from_wasm (0x24). */
interface WasmCallResult {
  /** Module id the call ran against — its memory is where `result` points. */
  mid: number;
  /** Whatever the exported function returned; for data buffers, a pointer. */
  result: number | null;
}

/** A MAP_READ copy scheduled by 0x22, drained after submit (0xF0). */
interface PendingReadback {
  id: number;
  offset: number;
  size: number;
}

interface GpuOps {
  // --- shared ---
  device: GPUDevice;
  /** The executor's WASM memory. An accessor: setMemory() replaces it. */
  readonly mem: WebAssembly.Memory;
  /** Read a UTF-8 string out of `mem` (string-table pointer + length). */
  rs(ptr: number, len: number): string;
  /** Debug log, already gated on the runtime debug flag. */
  log(message: string): void;

  // --- resource tables ---
  buf: ResourceTable<GPUBuffer>;
  tex: ResourceTable<GPUTexture>;
  txv: ResourceTable<GPUTextureView>;
  /**
   * How each explicit view in `txv` was made. The resize rebuild destroys and
   * recreates canvas-bound textures, and a view of one has to be remade from
   * its source id + descriptor — which the command stream no longer holds by
   * then (it is rewritten every frame).
   */
  txs: ResourceTable<{ tid: number; desc: object }>;
  smp: ResourceTable<GPUSampler>;
  pip: ResourceTable<GpuPipeline>;
  bg: ResourceTable<GPUBindGroup>;
  bgl: ResourceTable<GPUBindGroupLayout>;
  ppl: ResourceTable<GPUPipelineLayout>;
  bmp: ResourceTable<ImageBitmap>;
  bun: ResourceTable<GPURenderBundle>;
  qs: ResourceTable<GPUQuerySet>;
  /**
   * Bind-group descriptors, kept for auto-layout recreation on 0x13. `alt`
   * caches those rebuilds per bound-pipeline id — an auto-layout bind group
   * belongs to the pipeline that produced its layout, so one group can need a
   * distinct GPUBindGroup per pipeline that binds it. Null until the first
   * cross-pipeline bind; reset by gpu.js's resize rebuild.
   */
  bgd: ResourceTable<{
    layoutId: number;
    gi: number;
    entries: unknown;
    alt: Map<number, GPUBindGroup> | null;
  }>;
  /** Buffer usage flags, kept so 0x22 can spot MAP_READ destinations. */
  bufUsage: ResourceTable<number>;
  wm: ResourceTable<WasmModuleEntry>;
  wcr: ResourceTable<WasmCallResult>;

  // --- resource creation (0x01-0x07), implemented in gpu.js ---
  createBuffer(id: number, size: number, usage: number): void;
  createTexture(id: number, ptr: number, len: number): void;
  createSampler(id: number, ptr: number, len: number): void;
  createShader(id: number, ptr: number, len: number): void;
  createRenderPipeline(id: number, ptr: number, len: number): void;
  createComputePipeline(id: number, ptr: number, len: number): void;
  createBindGroup(id: number, layoutId: number, ptr: number, len: number): void;
  buildBindGroupEntries(entries: unknown): GPUBindGroupEntry[];
  /** Decode a texture-format byte (enums.js, byte-pinned to descriptors.zig). */
  dtf(code: number): GPUTextureFormat;

  // --- pass state (0x10-0x51) ---
  beginRenderPass(
    colorId: number, loadOp: number, storeOp: number, depthId: number,
    cr: number, cg: number, cb: number, ca: number, resolveId: number,
  ): void;
  beginRenderPassMRT(
    attachments: { tid: number; load: number; store: number; r: number; g: number; b: number; a: number }[],
    depthId: number,
  ): void;
  beginComputePass(): void;
  getPass(): GpuPassEncoder | null;
  setPass(pass: null): void;
  /** Pipeline id currently bound, or -1. Drives auto-layout bind-group rebuild. */
  curPip: number;
  setPendingOcclusionQS(qs: GPUQuerySet): void;
  setPendingTimestampWrites(writes: {
    querySet: GPUQuerySet;
    beginningOfPassWriteIndex: number;
    endOfPassWriteIndex: number;
  }): void;
  setPendingDepthStencilOps(dl: string, ds: string, sl: string, ss: string): void;
  setPendingClearValues(depth: number, stencil: number): void;

  // --- queue / WASM / control (0x20-0xFF) ---
  /** The render-target context; swapped during thumbnail prefetch. */
  targetCtx(): GPUCanvasContext;
  /** The frame's command encoder, created on first use. */
  encoder(): GPUCommandEncoder;
  /** Take the encoder and clear it, so submit cannot leave a finished one installed. */
  takeEnc(): GPUCommandEncoder | null;
  clock(): { time: number; cw: number; ch: number };
  /**
   * Staging for the two built-in uniform writes, allocated once per dispatcher
   * and refilled in place — the frame path must not build a typed array per
   * write (tests/npm/frame-churn.test.js).
   *
   * A plain property, like the resource tables and for the same reason: the
   * object identity never changes, only its contents. `ptr` is also the live
   * pointer state (setPointer writes into it), in pointer-inputs layout order,
   * with index 11 the layout's padding float. The `*Bytes` views are the same
   * memory as bytes, so a queue write can be counted in the byte units the wire
   * uses rather than writeBuffer's typed-array elements.
   */
  scratch: {
    time: Float32Array<ArrayBuffer>;
    timeBytes: Uint8Array<ArrayBuffer>;
    ptr: Float32Array<ArrayBuffer>;
    ptrBytes: Uint8Array<ArrayBuffer>;
  };
  /** Decode a call_wasm_func arg blob, resolving its runtime tags. */
  decodeWasmArgs(blob: Uint8Array): number[];
  pendingReadbacks: PendingReadback[];
  getOnQueryResult(): ((values: number[]) => void) | null;
  /** The raw debug flag, for call sites that must not build a log string. */
  debug(): boolean;
  reportError(err: { message: string; source: string }): void;
  /**
   * False once destroy() has released this dispatcher. The two asynchronous
   * creates (0x0B image bitmap, 0x30 wasm module) must check it before writing
   * their result: their `.then` closes over tables destroy() has emptied, so a
   * late write strands megabytes of pixel memory / a WebAssembly.Memory in an
   * array nobody will walk again.
   */
  alive(): boolean;
}
