
/**
 * PNGine - Node.js entry point
 *
 * Note: PNGine requires a browser environment with WebGPU support.
 * This module provides utility functions that work in Node.js.
 */

// PNG signature
const PNG_SIGNATURE = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

function isPng(data) {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  if (bytes.length < 8) return false;
  return PNG_SIGNATURE.every((b, i) => bytes[i] === b);
}

function isZip(data) {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  return bytes.length >= 4 && bytes[0] === 0x50 && bytes[1] === 0x4B;
}

function isPngb(data) {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  return bytes.length >= 4 &&
    bytes[0] === 0x50 && bytes[1] === 0x4E &&
    bytes[2] === 0x47 && bytes[3] === 0x42;
}

function detectFormat(bytes) {
  if (isZip(bytes)) return 'zip';
  if (isPng(bytes)) return 'png';
  if (isPngb(bytes)) return 'pngb';
  return null;
}

const ErrorCode = {
  SUCCESS: 0,
  NOT_INITIALIZED: 1,
  OUT_OF_MEMORY: 2,
  PARSE_ERROR: 3,
  INVALID_FORMAT: 4,
  NO_MODULE: 5,
  EXECUTION_ERROR: 6,
};

function getErrorMessage(code) {
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

function pngine() {
  throw new Error(
    'PNGine requires a browser environment with WebGPU support.\n' +
    'Use the CLI for compilation: npx pngine compile input.pngine -o output.pngb'
  );
}

module.exports = {
  pngine,
  destroy: pngine,
  draw: pngine,
  play: pngine,
  pause: pngine,
  stop: pngine,
  seek: pngine,
  setFrame: pngine,
  detectFormat,
  isPng,
  isZip,
  isPngb,
  extractBytecode: pngine,
  ErrorCode,
  getErrorMessage,
};
