
export interface PngineOptions {
  canvas?: HTMLCanvasElement;
  debug?: boolean;
  wasmUrl?: string | URL;
  onError?: (error: Error) => void;
}

/** Uniform value: number (f32), array (vecNf), or nested array (matNxMf) */
export type UniformValue = number | number[] | number[][];

export interface DrawOptions {
  time?: number;
  frame?: string;
  /** Uniform values to set before drawing */
  uniforms?: Record<string, UniformValue>;
}

export interface PngineInstance {
  readonly width: number;
  readonly height: number;
  readonly frameCount: number;
  readonly isPlaying: boolean;
  readonly time: number;
}

export function pngine(
  source: ArrayBuffer | Uint8Array | Blob | string,
  options?: PngineOptions
): Promise<PngineInstance>;

export function destroy(instance: PngineInstance): void;
export function draw(instance: PngineInstance, options?: DrawOptions): void;
export function play(instance: PngineInstance): PngineInstance;
export function pause(instance: PngineInstance): PngineInstance;
export function stop(instance: PngineInstance): PngineInstance;
export function seek(instance: PngineInstance, time: number): PngineInstance;
export function setFrame(instance: PngineInstance, frame: string | null): PngineInstance;

/** Set a single uniform value */
export function setUniform(
  instance: PngineInstance,
  name: string,
  value: UniformValue,
  redraw?: boolean
): PngineInstance;

/** Set multiple uniforms at once */
export function setUniforms(
  instance: PngineInstance,
  uniforms: Record<string, UniformValue>,
  redraw?: boolean
): PngineInstance;

export function extractBytecode(data: ArrayBuffer | Uint8Array): Promise<Uint8Array>;
export function detectFormat(data: ArrayBuffer | Uint8Array): 'png' | 'zip' | 'pngb' | null;
export function isPng(data: ArrayBuffer | Uint8Array): boolean;
export function isZip(data: ArrayBuffer | Uint8Array): boolean;
export function isPngb(data: ArrayBuffer | Uint8Array): boolean;

// Embedded executor support (advanced)
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
