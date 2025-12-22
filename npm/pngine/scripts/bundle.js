#!/usr/bin/env node

/**
 * Bundle script for PNGine npm package.
 *
 * Bundles web/ JavaScript modules into dist/ with inline worker.
 */

const fs = require('fs');
const path = require('path');

const WEB_DIR = path.join(__dirname, '../../../web');
const DIST_DIR = path.join(__dirname, '../dist');

// Ensure dist directory exists
if (!fs.existsSync(DIST_DIR)) {
  fs.mkdirSync(DIST_DIR, { recursive: true });
}

/**
 * Read a file and return its contents.
 */
function readFile(filename) {
  return fs.readFileSync(path.join(WEB_DIR, filename), 'utf-8');
}

/**
 * Write a file to dist.
 */
function writeFile(filename, content) {
  fs.writeFileSync(path.join(DIST_DIR, filename), content);
  console.log(`  Created: dist/${filename}`);
}

/**
 * Remove import statements from code.
 */
function removeImports(code) {
  return code.replace(/^import\s+.*?from\s+['"].*?['"];?\s*$/gm, '');
}

/**
 * Remove export statements but keep the declarations.
 */
function removeExports(code) {
  // Remove "export " prefix from declarations
  code = code.replace(/^export\s+(const|let|var|function|class|async\s+function)/gm, '$1');
  // Remove "export default"
  code = code.replace(/^export\s+default\s+/gm, '');
  // Remove "export { ... }"
  code = code.replace(/^export\s+\{[^}]*\};?\s*$/gm, '');
  return code;
}

console.log('Bundling PNGine npm package...\n');

// 1. Read all source files
console.log('Reading source files...');
const protocol = readFile('pngine-protocol.js');
const png = readFile('pngine-png.js');
const zip = readFile('pngine-zip.js');
const gpu = readFile('pngine-gpu.js');
const worker = readFile('pngine-worker.js');
const loader = readFile('pngine-loader.js');

// 2. Bundle worker code (protocol + png + zip + gpu + worker)
console.log('Bundling worker code...');
const workerBundle = [
  '// === pngine-protocol.js ===',
  removeImports(removeExports(protocol)),
  '',
  '// === pngine-png.js ===',
  removeImports(removeExports(png)),
  '',
  '// === pngine-zip.js ===',
  removeImports(removeExports(zip)),
  '',
  '// === pngine-gpu.js ===',
  removeImports(removeExports(gpu)),
  '',
  '// === pngine-worker.js ===',
  removeImports(removeExports(worker)),
].join('\n');

// 3. Create browser.mjs with inline worker
console.log('Creating browser bundle...');

// Modify loader to use inline worker
let browserLoader = loader;

// Replace the worker URL creation with blob URL
const workerUrlPattern = /const\s+worker\s*=\s*new\s+Worker\s*\(\s*workerUrl\s*,/;
const inlineWorkerCode = `
// Inline worker code as blob URL
const WORKER_CODE = ${JSON.stringify(workerBundle)};

function createWorkerBlobUrl() {
  const blob = new Blob([WORKER_CODE], { type: 'application/javascript' });
  return URL.createObjectURL(blob);
}
`;

// Find initPNGine function and modify it
browserLoader = browserLoader.replace(
  /export\s+async\s+function\s+initPNGine\s*\([^)]*\)\s*\{/,
  `${inlineWorkerCode}

export async function initPNGine(canvas, wasmUrl = 'pngine.wasm', workerUrl) {`
);

// Replace worker creation to use blob URL
browserLoader = browserLoader.replace(
  /const\s+worker\s*=\s*new\s+Worker\s*\(\s*workerUrl\s*,\s*\{\s*type:\s*['"]module['"]\s*\}\s*\)/g,
  'const worker = new Worker(createWorkerBlobUrl())'
);

writeFile('browser.mjs', browserLoader);

// 4. Create browser.js (CommonJS wrapper)
const browserCjs = `
'use strict';

// CommonJS wrapper for browser bundle
// Note: This is for bundlers that don't support ESM

const browserModule = require('./browser.mjs');
module.exports = browserModule;
`;
writeFile('browser.js', browserCjs);

// 5. Copy loader as index.mjs (ESM for Node.js)
// Node.js can't use the browser version (no OffscreenCanvas)
// So we export a version that throws helpful errors
const nodeLoader = `
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
    default: return \`Unknown error (\${code})\`;
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
    'PNGine requires a browser environment with WebGPU support.\\n' +
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
`;
writeFile('index.js', nodeLoader);

// 6. Create ESM version
const nodeLoaderEsm = `
/**
 * PNGine - Node.js ESM entry point
 */

// PNG signature
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
    default: return \`Unknown error (\${code})\`;
  }
}

export const MessageType = {
  INIT: 'init',
  TERMINATE: 'terminate',
  COMPILE: 'compile',
  LOAD_MODULE: 'loadModule',
  RESPONSE: 'response',
  ERROR: 'error',
};

export function initPNGine() {
  throw new Error(
    'PNGine requires a browser environment with WebGPU support.\\n' +
    'Use the CLI for compilation: npx pngine compile input.pngine -o output.pngb'
  );
}

export const initFromUrl = initPNGine;
export const initFromPng = initPNGine;
export const initFromZip = initPNGine;
`;
writeFile('index.mjs', nodeLoaderEsm);

console.log('\nBundle complete!');
console.log('\nNext steps:');
console.log('  1. Run: zig build web');
console.log('  2. Copy zig-out/lib/pngine.wasm to npm/pngine/wasm/');
