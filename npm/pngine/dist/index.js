
/**
 * PNGine - Node.js entry point
 *
 * Note: PNGine requires a browser environment with WebGPU support.
 * This module provides utility functions that work in Node.js.
 */

// Re-export format detection and extraction utilities
// These work in Node.js for processing files

const fs = require('fs');
const path = require('path');

// PNG signature
const PNG_SIGNATURE = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/**
 * Check if data is a PNG file.
 */
function isPng(data) {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  if (bytes.length < 8) return false;
  return PNG_SIGNATURE.every((b, i) => bytes[i] === b);
}

/**
 * Check if data is a ZIP file.
 */
function isZip(data) {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  return bytes.length >= 4 && bytes[0] === 0x50 && bytes[1] === 0x4B;
}

/**
 * Check if data is PNGB bytecode.
 */
function isPngb(data) {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  return bytes.length >= 4 &&
    bytes[0] === 0x50 && bytes[1] === 0x4E &&
    bytes[2] === 0x47 && bytes[3] === 0x42;
}

/**
 * Detect file format.
 */
function detectFormat(bytes) {
  if (isZip(bytes)) return 'zip';
  if (isPng(bytes)) return 'png';
  if (isPngb(bytes)) return 'pngb';
  return null;
}

/**
 * Error codes.
 */
const ErrorCode = {
  SUCCESS: 0,
  NOT_INITIALIZED: 1,
  OUT_OF_MEMORY: 2,
  PARSE_ERROR: 3,
  INVALID_FORMAT: 4,
  NO_MODULE: 5,
  EXECUTION_ERROR: 6,
  UNKNOWN_FORM: 10,
  INVALID_FORM_STRUCTURE: 11,
  UNDEFINED_RESOURCE: 12,
  DUPLICATE_RESOURCE: 13,
  TOO_MANY_RESOURCES: 14,
  EXPECTED_ATOM: 15,
  EXPECTED_STRING: 16,
  EXPECTED_NUMBER: 17,
  EXPECTED_LIST: 18,
  INVALID_RESOURCE_ID: 19,
  UNKNOWN: 99,
};

/**
 * Get error message.
 */
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

/**
 * Message types (for reference).
 */
const MessageType = {
  INIT: 'init',
  TERMINATE: 'terminate',
  COMPILE: 'compile',
  LOAD_MODULE: 'loadModule',
  LOAD_FROM_URL: 'loadFromUrl',
  FREE_MODULE: 'freeModule',
  EXECUTE_ALL: 'executeAll',
  EXECUTE_FRAME: 'executeFrame',
  RENDER_FRAME: 'renderFrame',
  GET_FRAME_COUNT: 'getFrameCount',
  GET_METADATA: 'getMetadata',
  FIND_UNIFORM_BUFFER: 'findUniformBuffer',
  SET_DEBUG: 'setDebug',
  RESPONSE: 'response',
  ERROR: 'error',
};

/**
 * Throws an error - PNGine requires browser.
 */
function initPNGine() {
  throw new Error(
    'PNGine requires a browser environment with WebGPU support.\n' +
    'Use the CLI for compilation: npx pngine compile input.pngine -o output.pngb'
  );
}

module.exports = {
  // Browser-only (throw helpful errors)
  initPNGine,
  initFromUrl: initPNGine,
  initFromPng: initPNGine,
  initFromZip: initPNGine,

  // Utilities that work in Node.js
  detectFormat,
  isPng,
  isZip,
  isPngb,

  // Protocol
  MessageType,
  ErrorCode,
  getErrorMessage,
};
