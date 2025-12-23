
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
