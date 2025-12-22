
/**
 * PNGine - Node.js ESM entry point
 */

const PNG_SIGNATURE = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

export function isPng(data) {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  if (bytes.length < 8) return false;
  return PNG_SIGNATURE.every((b, i) => bytes[i] === b);
}

export function isZip(data) {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  return bytes.length >= 4 && bytes[0] === 0x50 && bytes[1] === 0x4B;
}

export function isPngb(data) {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  return bytes.length >= 4 &&
    bytes[0] === 0x50 && bytes[1] === 0x4E &&
    bytes[2] === 0x47 && bytes[3] === 0x42;
}

export function detectFormat(bytes) {
  if (isZip(bytes)) return 'zip';
  if (isPng(bytes)) return 'png';
  if (isPngb(bytes)) return 'pngb';
  return null;
}

export const ErrorCode = {
  SUCCESS: 0,
  NOT_INITIALIZED: 1,
  OUT_OF_MEMORY: 2,
  PARSE_ERROR: 3,
  INVALID_FORMAT: 4,
  NO_MODULE: 5,
  EXECUTION_ERROR: 6,
};

export function getErrorMessage(code) {
  switch (code) {
    case ErrorCode.NOT_INITIALIZED: return 'WASM not initialized';
    case ErrorCode.OUT_OF_MEMORY: return 'Out of memory';
    case ErrorCode.PARSE_ERROR: return 'Parse error';
    case ErrorCode.INVALID_FORMAT: return 'Invalid bytecode format';
    case ErrorCode.NO_MODULE: return 'No module loaded';
    case ErrorCode.EXECUTION_ERROR: return 'Execution error';
    default: return `Unknown error (${code})`;
  }
}

function browserOnly() {
  throw new Error(
    'PNGine requires a browser environment with WebGPU support.\n' +
    'Use the CLI for compilation: npx pngine compile input.pngine -o output.pngb'
  );
}

export const pngine = browserOnly;
export const destroy = browserOnly;
export const draw = browserOnly;
export const play = browserOnly;
export const pause = browserOnly;
export const stop = browserOnly;
export const seek = browserOnly;
export const setFrame = browserOnly;
export const extractBytecode = browserOnly;
