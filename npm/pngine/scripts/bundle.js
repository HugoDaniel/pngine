#!/usr/bin/env node

/**
 * PNGine Bundle Script
 *
 * Uses esbuild for bundling and minification.
 *
 * Usage:
 *   node scripts/bundle.js          # Production build (minified)
 *   node scripts/bundle.js --debug  # Debug build (source maps, no minify)
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const SRC_DIR = path.join(__dirname, '../src');
const DIST_DIR = path.join(__dirname, '../dist');
const DEBUG = process.argv.includes('--debug');

// Ensure dist directory exists
if (!fs.existsSync(DIST_DIR)) {
  fs.mkdirSync(DIST_DIR, { recursive: true });
}

console.log(`Bundling PNGine (${DEBUG ? 'debug' : 'production'})...\n`);

/**
 * Run esbuild with given options
 */
function esbuild(entry, outfile, opts = {}) {
  const args = [
    'esbuild',
    entry,
    `--outfile=${outfile}`,
    '--bundle',
    '--format=esm',
    '--target=es2020',
  ];

  if (!DEBUG) {
    args.push('--minify');
    args.push('--drop:console');
    args.push('--drop:debugger');
  } else {
    args.push('--sourcemap');
  }

  if (opts.external) {
    opts.external.forEach(e => args.push(`--external:${e}`));
  }

  if (opts.define) {
    Object.entries(opts.define).forEach(([k, v]) => {
      args.push(`--define:${k}=${v}`);
    });
  }

  try {
    execSync(args.join(' '), { stdio: 'pipe' });
    return true;
  } catch (e) {
    console.error(`esbuild failed: ${e.message}`);
    return false;
  }
}

/**
 * Get file size info
 */
function sizeInfo(filepath) {
  const stat = fs.statSync(filepath);
  const raw = stat.size;
  const gzipped = execSync(`gzip -c "${filepath}" | wc -c`).toString().trim();
  return { raw, gzipped: parseInt(gzipped) };
}

// Step 1: Bundle worker code (_gpu.js + _worker.js)
console.log('1. Bundling worker code...');

// Create a temporary entry that imports both worker modules
const workerEntry = path.join(DIST_DIR, '_worker-entry.js');
fs.writeFileSync(workerEntry, `
import './gpu.js';
import './worker.js';
`);

// Copy worker source files to dist for bundling
fs.copyFileSync(path.join(SRC_DIR, 'gpu.js'), path.join(DIST_DIR, 'gpu.js'));
fs.copyFileSync(path.join(SRC_DIR, 'worker.js'), path.join(DIST_DIR, 'worker.js'));

const workerOut = path.join(DIST_DIR, '_worker-bundle.js');
if (!esbuild(workerEntry, workerOut)) {
  process.exit(1);
}

// Read bundled worker code
const workerCode = fs.readFileSync(workerOut, 'utf-8');

// Cleanup temp files
fs.unlinkSync(workerEntry);
fs.unlinkSync(path.join(DIST_DIR, 'gpu.js'));
fs.unlinkSync(path.join(DIST_DIR, 'worker.js'));
fs.unlinkSync(workerOut);

// Step 2: Create browser bundle with inlined worker
console.log('2. Creating browser bundle...');

// Read source files
const extract = fs.readFileSync(path.join(SRC_DIR, 'extract.js'), 'utf-8');
const anim = fs.readFileSync(path.join(SRC_DIR, 'anim.js'), 'utf-8');
const init = fs.readFileSync(path.join(SRC_DIR, 'init.js'), 'utf-8');

// Remove import/export statements
function stripImports(code) {
  return code.replace(/^import\s+.*?from\s+['"].*?['"];?\s*$/gm, '');
}

function stripExports(code) {
  code = code.replace(/^export\s+(const|let|var|function|class|async\s+function)/gm, '$1');
  code = code.replace(/^export\s+default\s+/gm, '');
  code = code.replace(/^export\s+\{[^}]*\};?\s*$/gm, '');
  return code;
}

// Build browser bundle source
const browserSource = `
/**
 * PNGine Browser Bundle
 * ${DEBUG ? 'Debug build' : 'Production build'}
 * Generated: ${new Date().toISOString()}
 */

// Inlined worker code
const WORKER_CODE = ${JSON.stringify(workerCode)};

function createWorkerBlobUrl() {
  const blob = new Blob([WORKER_CODE], { type: 'application/javascript' });
  return URL.createObjectURL(blob);
}

// === _extract.js ===
${stripImports(stripExports(extract))}

// === _anim.js ===
${stripImports(stripExports(anim))}

// === _init.js ===
${stripImports(stripExports(init))
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

// Write unminified browser source
const browserSourcePath = path.join(DIST_DIR, '_browser-source.mjs');
fs.writeFileSync(browserSourcePath, browserSource);

// Minify with esbuild
const browserOut = path.join(DIST_DIR, 'browser.mjs');
if (!esbuild(browserSourcePath, browserOut)) {
  process.exit(1);
}

// Cleanup
fs.unlinkSync(browserSourcePath);

// Step 3: Create Node.js stubs
console.log('3. Creating Node.js stubs...');

const nodeStub = `
/**
 * PNGine - Node.js entry
 *
 * Note: PNGine requires a browser with WebGPU support.
 * Use the CLI for compilation: npx pngine compile input.pngine -o output.pngb
 */

const PNG_SIG = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

function isPng(d) {
  const b = d instanceof Uint8Array ? d : new Uint8Array(d);
  return b.length >= 8 && PNG_SIG.every((v, i) => b[i] === v);
}

function isZip(d) {
  const b = d instanceof Uint8Array ? d : new Uint8Array(d);
  return b.length >= 4 && b[0] === 0x50 && b[1] === 0x4B;
}

function isPngb(d) {
  const b = d instanceof Uint8Array ? d : new Uint8Array(d);
  return b.length >= 4 && b[0] === 0x50 && b[1] === 0x4E && b[2] === 0x47 && b[3] === 0x42;
}

function detectFormat(d) {
  if (isZip(d)) return 'zip';
  if (isPng(d)) return 'png';
  if (isPngb(d)) return 'pngb';
  return null;
}

const browserOnly = () => { throw new Error('PNGine requires browser with WebGPU'); };

module.exports = {
  pngine: browserOnly, destroy: browserOnly, draw: browserOnly,
  play: browserOnly, pause: browserOnly, stop: browserOnly,
  seek: browserOnly, setFrame: browserOnly, extractBytecode: browserOnly,
  isPng, isZip, isPngb, detectFormat,
};
`;

const nodeStubEsm = `
export function isPng(d) {
  const b = d instanceof Uint8Array ? d : new Uint8Array(d);
  const s = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  return b.length >= 8 && s.every((v, i) => b[i] === v);
}
export function isZip(d) {
  const b = d instanceof Uint8Array ? d : new Uint8Array(d);
  return b.length >= 4 && b[0] === 0x50 && b[1] === 0x4B;
}
export function isPngb(d) {
  const b = d instanceof Uint8Array ? d : new Uint8Array(d);
  return b.length >= 4 && b[0] === 0x50 && b[1] === 0x4E && b[2] === 0x47 && b[3] === 0x42;
}
export function detectFormat(d) {
  if (isZip(d)) return 'zip';
  if (isPng(d)) return 'png';
  if (isPngb(d)) return 'pngb';
  return null;
}
const browserOnly = () => { throw new Error('PNGine requires browser with WebGPU'); };
export const pngine = browserOnly, destroy = browserOnly, draw = browserOnly;
export const play = browserOnly, pause = browserOnly, stop = browserOnly;
export const seek = browserOnly, setFrame = browserOnly, extractBytecode = browserOnly;
`;

fs.writeFileSync(path.join(DIST_DIR, 'index.js'), nodeStub);
fs.writeFileSync(path.join(DIST_DIR, 'index.mjs'), nodeStubEsm);

// Step 4: Create TypeScript definitions
console.log('4. Creating TypeScript definitions...');

const typeDefs = `
export interface PngineOptions {
  canvas?: HTMLCanvasElement;
  debug?: boolean;
  wasmUrl?: string | URL;
  onError?: (error: Error) => void;
}

export interface DrawOptions {
  time?: number;
  frame?: string;
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

export function extractBytecode(data: ArrayBuffer | Uint8Array): Promise<Uint8Array>;
export function detectFormat(data: ArrayBuffer | Uint8Array): 'png' | 'zip' | 'pngb' | null;
export function isPng(data: ArrayBuffer | Uint8Array): boolean;
export function isZip(data: ArrayBuffer | Uint8Array): boolean;
export function isPngb(data: ArrayBuffer | Uint8Array): boolean;
`;

fs.writeFileSync(path.join(DIST_DIR, 'index.d.ts'), typeDefs);

// Step 5: Report sizes
console.log('\n=== Bundle Sizes ===\n');

const browserInfo = sizeInfo(browserOut);
console.log(`browser.mjs:  ${(browserInfo.raw / 1024).toFixed(1)} KB (${(browserInfo.gzipped / 1024).toFixed(1)} KB gzipped)`);

const indexInfo = sizeInfo(path.join(DIST_DIR, 'index.js'));
console.log(`index.js:     ${(indexInfo.raw / 1024).toFixed(1)} KB`);

console.log(`\nTotal gzipped: ${((browserInfo.gzipped + indexInfo.raw) / 1024).toFixed(1)} KB`);

if (DEBUG) {
  console.log('\n[Debug build - includes source maps]');
}

console.log('\nDone!');
