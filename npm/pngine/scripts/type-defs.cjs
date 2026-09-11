// The published TypeScript surface — one template string per .d.ts the
// bundler writes (dist/index.d.ts is viewer.d.ts). Kept out of bundle.cjs so
// tests/npm/types-surface.test.js can read the strings without running the
// bundler: it derives the other side of every check from the CODE (module
// exports, the dispatcher's methods, the instance's getters, the init files'
// documented options, the worker's reply keys), so a drift either way fails
// there rather than in a user's editor.
//
// Every block below is a TEMPLATE LITERAL, so a backtick inside a doc comment
// ends the string and the script dies with a SyntaxError somewhere further
// down. Escape it (\`map-read\`), the way the getStats doc already does.
const sharedTypes = `
/** Uniform value: number (f32), array (vecNf), or nested array (matNxMf) */
export type UniformValue = number | number[] | number[][];

/** Bytes for a buffer: any typed array or DataView (written as the window it covers), or a bare ArrayBuffer. */
export type BufferBytes = ArrayBufferView | ArrayBuffer;

/** The long form of one \`buffers\` entry. */
export interface BufferWrite {
  bytes: BufferBytes;
  /** Byte offset into the buffer; a multiple of 4. Default 0. */
  offset?: number;
  /**
   * Which member of a pooled (\`:pool N\`) buffer: \`k\` for member k, \`"active"\`
   * for the member the coming frame reads at \`:ping-pong 0\`. Absent → every
   * member (seeding a ping-pong state).
   */
  poolIndex?: number | "active";
}

/** One named buffer, as getBuffers reports it. */
export interface BufferInfo {
  size: number;
  /** GPUBufferUsage bits, as authored in \`:usage\`. */
  usage: number;
  /** \`usage\` has copy-dst — what a queue write requires. */
  writable: boolean;
  /** Member count: 1, or N for \`:pool N\`. */
  pool: number;
  /** The frame's own queue ops write it every draw, so writeBuffer refuses it. */
  frameWritten: boolean;
}

/** A reflected uniform's type, as WGSL spells it; "unknown" for one the compiler could not reflect (written best-effort as f32). */
export type UniformTypeName =
  | "f32" | "i32" | "u32"
  | "vec2f" | "vec3f" | "vec4f"
  | "mat3x3f" | "mat4x4f"
  | "vec2i" | "vec3i" | "vec4i"
  | "vec2u" | "vec3u" | "vec4u"
  | "unknown";

/** One reflected uniform field, as getUniforms reports it. */
export interface UniformField {
  type: UniformTypeName;
  /** Byte size — the whole array for an array field. */
  size: number;
  /**
   * The \`(buffer :name …)\` it lives in — what writeBuffer and getBuffers
   * speak. Null for a payload minted before the buffer-name block (3.0.1 and
   * earlier), which names nothing.
   */
  buffer: string | null;
  /** Byte offset within that buffer. */
  offset: number;
  /** Array length; 0 for a scalar/vector/matrix field. For an array, \`type\` is the element's. */
  elemCount: number;
}

export interface DrawOptions {
  time?: number;
  /**
   * The \`(frame :name …)\` this ONE draw renders, or null for the executor's
   * own choice. Absent, the draw carries the pin setFrame holds.
   */
  frame?: string | null;
  uniforms?: Record<string, UniformValue>;
  /** Bytes for buffers by their \`(buffer :name …)\`, applied at the head of this frame. */
  buffers?: Record<string, BufferBytes | BufferWrite>;
}

/**
 * The song a \`pNGa\` chunk (an audio WASM module) carries, as \`p.audio\`
 * reads it. Its transport is the instance's: play/pause/stop/seek move the
 * song and the clock together, so there is nothing to call here.
 */
export interface AudioInfo {
  /** Song length in seconds. */
  readonly duration: number;
  readonly playing: boolean;
  /** Seconds into the song, off the audio clock; compare with \`p.time\` for drift. */
  readonly currentTime: number;
}

export interface PngineInstance {
  readonly width: number;
  readonly height: number;
  /** How many \`(frame :name …)\` the payload defines. */
  readonly frameCount: number;
  readonly isPlaying: boolean;
  readonly time: number;
  /** The pin setFrame holds: a frame name, or null for the executor's own choice. */
  readonly currentFrame: string | null;
  /** The song, when the payload carries a \`pNGa\` chunk; null otherwise. */
  readonly audio: AudioInfo | null;
}

export function destroy(instance: PngineInstance): PngineInstance;
/**
 * Render one frame now. Every verb has the one contract: an argument of the
 * wrong kind is a TypeError before anything posts, a destroyed instance
 * returns it untouched, and the instance comes back for chaining.
 */
export function draw(instance: PngineInstance, options?: DrawOptions): PngineInstance;
export function play(instance: PngineInstance): PngineInstance;
export function pause(instance: PngineInstance): PngineInstance;
export function stop(instance: PngineInstance): PngineInstance;
export function seek(instance: PngineInstance, time: number): PngineInstance;
/**
 * Pin which \`(frame :name …)\` renders and draw it. The pin rides every later
 * draw (the play loop's included) until \`setFrame(p, null)\` releases it. A
 * name the payload does not define reaches onError as a PngineGPUError with
 * source "set-frame", naming the frames it does define; the draw still
 * renders. \`p.currentFrame\` reads the pin back.
 */
export function setFrame(instance: PngineInstance, frame: string | null): PngineInstance;
/**
 * Write a reflected uniform by name. A name the payload does not reflect
 * reaches onError as a PngineGPUError with source "set-uniform" (see
 * getUniforms); with \`{ redraw: false }\` the value rides the next draw from
 * anywhere instead of drawing now — the option writeBuffer spells the same
 * way. (A positional boolean here was a documented no-op through 3.0.1 and
 * is refused as a TypeError since.)
 */
export function setUniform(instance: PngineInstance, name: string, value: UniformValue, options?: { redraw?: boolean }): PngineInstance;
export function setUniforms(instance: PngineInstance, uniforms: Record<string, UniformValue>, options?: { redraw?: boolean }): PngineInstance;
/** Every reflected uniform field by name (see UniformField). */
export function getUniforms(instance: PngineInstance): Promise<Record<string, UniformField>>;
/**
 * Put bytes in a buffer by its \`(buffer :name …)\`. With \`redraw\` (the default)
 * this is one draw carrying the write; with \`redraw: false\` the write rides the
 * next draw from anywhere (the play loop's included) and is read when that
 * draw is posted. A write the runtime cannot honour — unknown name, a buffer
 * the frame itself writes, a bad pool member, no copy-dst, misaligned, out of
 * range — reaches onError as a PngineGPUError with source "write-buffer".
 */
export function writeBuffer(
  instance: PngineInstance,
  name: string,
  bytes: BufferBytes,
  options?: { offset?: number; poolIndex?: number | "active"; redraw?: boolean },
): PngineInstance;
/** The document's buffers by name — which are writable, and why not. */
export function getBuffers(instance: PngineInstance): Promise<Record<string, BufferInfo>>;
/**
 * Live GPU-resource counts for this instance — the instrument for a
 * long-running session. \`gpu.live\` counts the objects the runtime is holding
 * right now, by kind; \`gpu.executed\` is the command buffers run so far.
 *
 * Two properties worth asserting over a soak: \`gpu.live\` stays flat as
 * \`gpu.executed\` climbs, and \`wasmBytes\` never changes (the embedded executor
 * has no allocator, so growth there is itself a bug signal).
 */
export function getStats(instance: PngineInstance): Promise<{
  gpu: { live: Record<string, number>; total: number; cachedBindGroups: number; executed: number } | null;
  wasmBytes: number;
  frameCount: number;
  moduleLoaded: boolean;
  deviceLost: boolean;
}>;
/** Rebuild the GPU device and replay the current shader after a "device-lost" PngineGPUError. */
export function restart(instance: PngineInstance): PngineInstance;

export function extractBytecode(data: ArrayBuffer | Uint8Array): Promise<Uint8Array>;
export function detectFormat(data: ArrayBuffer | Uint8Array): 'png' | 'zip' | 'pngb' | null;
export function isPng(data: ArrayBuffer | Uint8Array): boolean;
export function isZip(data: ArrayBuffer | Uint8Array): boolean;
export function isPngb(data: ArrayBuffer | Uint8Array): boolean;
`;

const viewerTypes = `
export interface ViewerOptions {
  canvas: HTMLCanvasElement;
  debug?: boolean;
  dpr?: number;
  /**
   * Leave the canvas CSS size to the page and keep the backing store synced to
   * its rendered size (responsive). Off by default (fixed size); a DPR change
   * re-sharpens the backing store either way.
   */
  autoResize?: boolean;
  /**
   * REJECTED at runtime, and declared here deliberately. The viewer throws
   * Error("viewer pngine() does not support wasmUrl; use embedded executor
   * payloads"). A caller moving over from pngine/dev needs that message, not an
   * excess-property error from their bundler, so the rejection is part of this
   * interface rather than hidden from it.
   */
  wasmUrl?: string | URL;
  onError?: (error: Error) => void;
  /**
   * Receives the contents of every \`map-read\` buffer the frame copies into,
   * once per submit, as one number per 64-bit lane. The path was written for
   * timestamp and occlusion query results, which are 64-bit; a compute readback
   * has to write 64-bit lanes, \`vec2u(value, 0u)\`, to survive it.
   */
  onQueryResult?: (values: number[]) => void;
}

export function pngine(
  // HTMLImageElement is in the union for the reason wasmUrl is in the options:
  // the viewer rejects it at runtime with a message naming pngine/dev, and that
  // message is more use to a caller than a compile error. A CSS-selector string
  // is rejected the same way and needs no arm of its own, being a string.
  source: ArrayBuffer | Uint8Array | Blob | string | HTMLImageElement,
  options: ViewerOptions
): Promise<PngineInstance>;
${sharedTypes}
`;

const devTypes = `
export interface DevOptions {
  canvas?: HTMLCanvasElement;
  debug?: boolean;
  dpr?: number;
  /**
   * Leave the canvas CSS size to the page and keep the backing store synced to
   * its rendered size (responsive). Off by default (fixed size); a DPR change
   * re-sharpens the backing store either way.
   */
  autoResize?: boolean;
  wasmUrl?: string | URL;
  onError?: (error: Error) => void;
  /**
   * Receives the contents of every \`map-read\` buffer the frame copies into,
   * once per submit, as one number per 64-bit lane. The path was written for
   * timestamp and occlusion query results, which are 64-bit; a compute readback
   * has to write 64-bit lanes, \`vec2u(value, 0u)\`, to survive it.
   */
  onQueryResult?: (values: number[]) => void;
}

export function pngine(
  source: ArrayBuffer | Uint8Array | Blob | string | HTMLImageElement,
  options?: DevOptions
): Promise<PngineInstance>;
${sharedTypes}

export interface PayloadInfo {
  version: number;
  hasEmbeddedExecutor: boolean;
  hasAnimationTable: boolean;
  plugins: {
    core: boolean;
    render: boolean;
    compute: boolean;
    wasm: boolean;
    animation: boolean;
    texture: boolean;
  };
  executor: Uint8Array | null;
  bytecode: Uint8Array;
  payload: Uint8Array;
  offsets: {
    executor: number;
    executorLength: number;
    bytecode: number;
    bytecodeLength: number;
    stringTable: number;
    data: number;
    wgsl: number;
    uniform: number;
    animation: number;
  };
}

export interface ExecutorInstance {
  instance: WebAssembly.Instance;
  memory: WebAssembly.Memory;
  exports: WebAssembly.Exports;
  getBytecodePtr(): number;
  setBytecodeLen(len: number): void;
  getDataPtr(): number;
  setDataLen(len: number): void;
  init(): void;
  frame(time: number, width: number, height: number): void;
  getCommandPtr(): number;
  getCommandLen(): number;
}

export interface ExecutorCallbacks {
  log?: (ptr: number, len: number) => void;
  wasmInstantiate?: (id: number, ptr: number, len: number) => void;
  wasmCall?: (callId: number, modId: number, namePtr: number, nameLen: number, argsPtr: number, argsLen: number) => void;
  wasmGetResult?: (callId: number, outPtr: number, outLen: number) => number;
}

export function parsePayload(pngb: Uint8Array): PayloadInfo;
export function createExecutor(wasmBytes: Uint8Array, imports?: WebAssembly.Imports): Promise<ExecutorInstance>;
export function getExecutorImports(callbacks?: ExecutorCallbacks): WebAssembly.Imports;
export function getExecutorVariantName(plugins: PayloadInfo['plugins']): string;
`;

const coreTypes = `
export interface UniformInfo {
  bufferId: number;
  offset: number;
  size: number;
  type: number;
  /** Fixed array element count (type is then the ELEMENT's tag); 0 = not an array. */
  elemCount: number;
}

/** One \`(buffer :name …)\` from the payload's buffer-name block. */
export interface BufferName {
  /** Dispatcher id of the pool's first member. */
  id: number;
  /** Member count: 1, or N for \`:pool N\`. */
  pool: number;
  /** The frame's own queue ops write it every draw. */
  frameWritten: boolean;
}

export interface UniformTableResult {
  uniforms: Map<string, UniformInfo>;
  strings: string[];
  /** Empty for a payload minted before the block (header flag bit 4 clear). */
  buffers: Map<string, BufferName>;
}

/** One named buffer, as getBuffers reports it. */
export interface BufferInfo {
  size: number;
  usage: number;
  writable: boolean;
  pool: number;
  frameWritten: boolean;
}

export interface CoreDispatcher {
  setMemory(memory: WebAssembly.Memory): void;
  execute(ptr: number): Promise<void> | void;
  /** Refusals (an unreflected name, a buffer the stream never created) reach setOnError with source "set-uniform". */
  setUniform(name: string, value: number | number[] | number[][]): boolean;
  setUniforms(uniforms: Record<string, number | number[] | number[][]>): number;
  setUniformTable(table: Map<string, UniformInfo>): void;
  /** Install parseUniformTable(bytecode).buffers, after the init stream ran. */
  setBufferNames(names: Map<string, BufferName> | Record<string, BufferName>): void;
  /**
   * Host bytes into buffers by name. Refusals reach setOnError with source
   * "write-buffer". \`frameCounter\` is the coming frame's counter
   * (\`getFrameCounter()\`, read before \`frame()\`), needed for \`poolIndex: "active"\`.
   * Returns the number of queue writes made.
   */
  writeBuffers(
    buffers: Record<string, ArrayBufferView | ArrayBuffer | { bytes: ArrayBufferView | ArrayBuffer; offset?: number; poolIndex?: number | "active" }>,
    frameCounter?: number,
  ): number;
  getBuffers(): Record<string, BufferInfo>;
  /** Hear command-stream faults, refused host writes included: \`{ message, source }\`. */
  setOnError(fn: ((err: { message: string; source: string }) => void) | null): void;
  destroy(): void;
  setDebug(v: boolean): void;
  /**
   * The four runtime values the builtin uniform writes read (\`pngine-inputs\`,
   * \`pngine-frame-inputs\`, \`pointer-inputs\`): time, the frame counter the
   * executor reports before each \`frame()\` (\`getFrameCounter()\`), the
   * 12-float pointer block, and the canvas size. A core-tier host drives all
   * four itself.
   */
  setTime(t: number): void;
  setFrameCounter(n: number): void;
  setPointer(s: ArrayLike<number>): void;
  setCanvasSize(w: number, h: number): void;
  _dispatcher: unknown;
}

export function createCommandDispatcher(device: GPUDevice, ctx: GPUCanvasContext): unknown;
export function parseUniformTable(bytecode: Uint8Array): UniformTableResult;
export function createCoreDispatcher(device: GPUDevice, ctx: GPUCanvasContext): CoreDispatcher;
export function getDevice(adapter?: GPUAdapter): Promise<GPUDevice>;
/** The authored \`(canvas :alpha-mode …)\` of a payload (header flag), for configureCanvas. */
export function canvasAlphaMode(bytecode: Uint8Array): "opaque" | "premultiplied";
export function configureCanvas(canvas: HTMLCanvasElement, device: GPUDevice, alphaMode?: "opaque" | "premultiplied"): GPUCanvasContext;
`;

const executorTypes = `
export interface PayloadInfo {
  version: number;
  hasEmbeddedExecutor: boolean;
  hasAnimationTable: boolean;
  plugins: {
    core: boolean;
    render: boolean;
    compute: boolean;
    wasm: boolean;
    animation: boolean;
    texture: boolean;
  };
  executor: Uint8Array | null;
  bytecode: Uint8Array;
  payload: Uint8Array;
  offsets: {
    executor: number;
    executorLength: number;
    bytecode: number;
    bytecodeLength: number;
    stringTable: number;
    data: number;
    wgsl: number;
    uniform: number;
    animation: number;
  };
}

export interface ExecutorInstance {
  instance: WebAssembly.Instance;
  memory: WebAssembly.Memory;
  exports: WebAssembly.Exports;
  getBytecodePtr(): number;
  setBytecodeLen(len: number): void;
  getDataPtr(): number;
  setDataLen(len: number): void;
  init(): void;
  frame(time: number, width: number, height: number): void;
  getCommandPtr(): number;
  getCommandLen(): number;
}

export interface ExecutorCallbacks {
  log?: (ptr: number, len: number) => void;
  wasmInstantiate?: (id: number, ptr: number, len: number) => void;
  wasmCall?: (callId: number, modId: number, namePtr: number, nameLen: number, argsPtr: number, argsLen: number) => void;
  wasmGetResult?: (callId: number, outPtr: number, outLen: number) => number;
}

export function parsePayload(pngb: Uint8Array): PayloadInfo;
export function createExecutor(wasmBytes: Uint8Array, imports?: WebAssembly.Imports): Promise<ExecutorInstance>;
export function getExecutorImports(callbacks?: ExecutorCallbacks): WebAssembly.Imports;
export function getExecutorVariantName(plugins: PayloadInfo['plugins']): string;
`;

const miniTypes = `
export interface MiniOptions {
  autoplay?: boolean;
  /**
   * Runtime faults after the promise resolves (an undecodable opcode mid-frame,
   * a WebGPU validation error, device loss). Setup failures reject instead.
   * Without a handler they are console.error'd.
   */
  onError?: (error: Error) => void;
}

export interface MiniInstance {
  play(): void;
  pause(): void;
  stop(): void;
  destroy(): void;
  readonly time: number;
  readonly isPlaying: boolean;
}

export function miniPngine(
  canvas: HTMLCanvasElement,
  source: string | ArrayBuffer | Uint8Array,
  opts?: MiniOptions
): Promise<MiniInstance>;
`;

module.exports = { indexTypes: viewerTypes, viewerTypes, devTypes, coreTypes, executorTypes, miniTypes };
