#!/usr/bin/env node

/**
 * Bundle script for PNGine npm package.
 *
 * Bundles web/ JavaScript modules into dist/ with inline worker.
 * Uses command buffer approach for minimal bundle size.
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

console.log('Bundling PNGine npm package (command buffer)...\n');

// 1. Read source files for command buffer approach
console.log('Reading source files...');
const gpu = readFile('_gpu.js');
const worker = readFile('_worker.js');
const init = readFile('_init.js');
const anim = readFile('_anim.js');
const extract = readFile('_extract.js');

// 2. Bundle worker code (_gpu.js + _worker.js)
console.log('Bundling worker code...');
const workerBundle = [
  '// === _gpu.js (CommandDispatcher) ===',
  removeImports(removeExports(gpu)),
  '',
  '// === _worker.js ===',
  removeImports(removeExports(worker)),
].join('\n');

// 3. Create browser.mjs with inline worker
console.log('Creating browser bundle...');

// Build main thread code
const mainBundle = `
/**
 * PNGine Browser Bundle
 * Command buffer approach for minimal size
 */

// === Inline Worker Code ===
const WORKER_CODE = ${JSON.stringify(workerBundle)};

function createWorkerBlobUrl() {
  const blob = new Blob([WORKER_CODE], { type: 'application/javascript' });
  return URL.createObjectURL(blob);
}

// === _extract.js ===
${removeImports(removeExports(extract))}

// === _anim.js ===
${removeImports(removeExports(anim))}

// === _init.js (modified for inline worker) ===
${removeImports(removeExports(init))
  .replace(
    /new\s+Worker\s*\(\s*getWorkerUrl\s*\(\s*\)\s*,\s*\{\s*type:\s*["']module["']\s*\}\s*\)/g,
    'new Worker(createWorkerBlobUrl())'
  )
  .replace(
    /function\s+getWorkerUrl\s*\(\s*\)\s*\{[\s\S]*?return[^}]+\}/,
    'function getWorkerUrl() { return createWorkerBlobUrl(); }'
  )
}

// === Exports ===
export { pngine, destroy };
export { draw, play, pause, stop, seek, setFrame };
export { extractBytecode, detectFormat, isPng, isZip, isPngb };
`;

writeFile('browser.mjs', mainBundle);

// 4. Create browser.js (CommonJS wrapper)
const browserCjs = `
'use strict';

// CommonJS wrapper for browser bundle
// Note: This is for bundlers that don't support ESM

const browserModule = require('./browser.mjs');
module.exports = browserModule;
`;
writeFile('browser.js', browserCjs);

// 5. Create index.js (Node.js CJS)
const nodeLoader = `
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
    default: return \`Unknown error (\${code})\`;
  }
}

function pngine() {
  throw new Error(
    'PNGine requires a browser environment with WebGPU support.\\n' +
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
`;
writeFile('index.js', nodeLoader);

// 6. Create index.mjs (Node.js ESM)
const nodeLoaderEsm = `
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
    default: return \`Unknown error (\${code})\`;
  }
}

function browserOnly() {
  throw new Error(
    'PNGine requires a browser environment with WebGPU support.\\n' +
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
`;
writeFile('index.mjs', nodeLoaderEsm);

console.log('\nBundle complete!');

// Show bundle size
const browserSize = fs.statSync(path.join(DIST_DIR, 'browser.mjs')).size;
console.log(`\nBrowser bundle size: ${(browserSize / 1024).toFixed(1)} KB`);

console.log('\nNext steps:');
console.log('  1. Run: zig build web');
console.log('  2. Copy zig-out/web/pngine.wasm to npm/pngine/wasm/');
