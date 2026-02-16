#!/usr/bin/env node

/**
 * PNGine bundle script.
 *
 * Build profiles:
 * - viewer: lean production viewer API (embedded-executor payloads)
 * - dev: full-feature browser API (shared fallback + diagnostics)
 * - core: low-level runtime API
 * - executor: advanced executor helper API
 *
 * Usage:
 *   node scripts/bundle.js         # production build
 *   node scripts/bundle.js --debug # debug build
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const SRC_DIR = path.join(__dirname, '../src');
const DIST_DIR = path.join(__dirname, '../dist');
const DEBUG = process.argv.includes('--debug');

if (!fs.existsSync(DIST_DIR)) {
  fs.mkdirSync(DIST_DIR, { recursive: true });
}

console.log(`Bundling PNGine (${DEBUG ? 'debug' : 'production'})...\n`);

function cleanupDist() {
  const generatedFiles = [
    'viewer.mjs',
    'viewer.mjs.map',
    'dev.mjs',
    'dev.mjs.map',
    'core.mjs',
    'core.mjs.map',
    'executor.mjs',
    'executor.mjs.map',
    'index.js',
    'index.mjs',
    'index.d.ts',
    'viewer.d.ts',
    'dev.d.ts',
    'core.d.ts',
    'executor.d.ts',
    // Removed compatibility outputs (keep cleaning stale artifacts).
    'browser.mjs',
    'browser.mjs.map',
    'embedded.mjs',
    'embedded.mjs.map',
    'embedded.d.ts',
  ];

  for (const file of generatedFiles) {
    const fullPath = path.join(DIST_DIR, file);
    if (fs.existsSync(fullPath)) {
      fs.unlinkSync(fullPath);
    }
  }

  for (const file of fs.readdirSync(DIST_DIR)) {
    if (/^_worker-.*\.mjs(\.map)?$/.test(file) || /^_worker-entry-.*\.js$/.test(file) || /^_.*-source\.mjs$/.test(file)) {
      fs.unlinkSync(path.join(DIST_DIR, file));
    }
  }
}

cleanupDist();

function normalizeImportPath(p) {
  const clean = p.split(path.sep).join('/');
  if (clean.startsWith('.')) return clean;
  return `./${clean}`;
}

function runEsbuild(entry, outfile, opts = {}) {
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
    args.push('--define:DEBUG=false');
    args.push('--drop:debugger');
  } else {
    args.push('--sourcemap');
    args.push('--define:DEBUG=true');
  }

  const embeddedOnly = opts.embeddedOnly === true ? 'true' : 'false';
  args.push(`--define:EMBEDDED_ONLY=${embeddedOnly}`);

  if (opts.define) {
    for (const [k, v] of Object.entries(opts.define)) {
      args.push(`--define:${k}=${v}`);
    }
  }

  if (opts.external) {
    for (const ext of opts.external) {
      args.push(`--external:${ext}`);
    }
  }

  try {
    execSync(args.join(' '), { stdio: 'pipe' });
    return true;
  } catch (e) {
    console.error(`esbuild failed for ${path.basename(outfile)}: ${e.message}`);
    return false;
  }
}

function sizeInfo(filepath) {
  const stat = fs.statSync(filepath);
  const raw = stat.size;
  const gzipped = parseInt(execSync(`gzip -c "${filepath}" | wc -c`).toString().trim(), 10);
  return { raw, gzipped };
}

function stripImports(code) {
  return code.replace(/^import\s+.*?from\s+['"].*?['"];?\s*$/gm, '');
}

function stripExports(code) {
  let out = code;
  out = out.replace(/^export\s+(const|let|var|function|class|async\s+function)/gm, '$1');
  out = out.replace(/^export\s+default\s+/gm, '');
  out = out.replace(/^export\s+\{[^}]*\};?\s*$/gm, '');
  return out;
}

function inlineWorkerInit(code) {
  return stripImports(stripExports(code))
    .replace(
      /new\s+Worker\s*\(\s*getWorkerUrl\s*\(\s*\)\s*,\s*\{\s*type:\s*["']module["']\s*\}\s*\)/g,
      'new Worker(createWorkerBlobUrl())'
    )
    .replace(
      /function\s+getWorkerUrl\s*\(\s*\)\s*\{[\s\S]*?return[^}]+\}/,
      'function getWorkerUrl() { return createWorkerBlobUrl(); }'
    );
}

function buildWorkerBundle(name, embeddedOnly, workerFile) {
  const workerEntry = path.join(DIST_DIR, `_worker-entry-${name}.js`);
  const workerOut = path.join(DIST_DIR, `_worker-${name}.mjs`);

  const relGpu = normalizeImportPath(path.relative(DIST_DIR, path.join(SRC_DIR, 'gpu.js')));
  const relLoader = normalizeImportPath(path.relative(DIST_DIR, path.join(SRC_DIR, 'loader.js')));
  const relWorker = normalizeImportPath(path.relative(DIST_DIR, path.join(SRC_DIR, workerFile)));

  fs.writeFileSync(workerEntry, `import '${relGpu}';\nimport '${relLoader}';\nimport '${relWorker}';\n`);

  if (!runEsbuild(workerEntry, workerOut, { embeddedOnly })) {
    process.exit(1);
  }

  const workerCode = fs.readFileSync(workerOut, 'utf-8');
  fs.unlinkSync(workerEntry);
  fs.unlinkSync(workerOut);
  return workerCode;
}

function buildInlinedProfileBundle(config) {
  const {
    name,
    title,
    embeddedOnly,
    workerFile,
    initFile,
    includeLoader,
    exportBlock,
  } = config;

  const workerCode = buildWorkerBundle(name, embeddedOnly, workerFile);
  const extractCode = fs.readFileSync(path.join(SRC_DIR, 'extract.js'), 'utf-8');
  const animCode = fs.readFileSync(path.join(SRC_DIR, 'anim.js'), 'utf-8');
  const initCode = fs.readFileSync(path.join(SRC_DIR, initFile), 'utf-8');
  const loaderCode = includeLoader
    ? fs.readFileSync(path.join(SRC_DIR, 'loader.js'), 'utf-8')
    : '';

  const source = `
/**
 * PNGine ${title} Bundle
 * ${DEBUG ? 'Debug build' : 'Production build'}
 * Generated: ${new Date().toISOString()}
 */

const WORKER_CODE = ${JSON.stringify(workerCode)};

function createWorkerBlobUrl() {
  const blob = new Blob([WORKER_CODE], { type: 'application/javascript' });
  return URL.createObjectURL(blob);
}

// === extract.js ===
${stripImports(stripExports(extractCode))}

${includeLoader ? `// === loader.js ===\n${stripImports(stripExports(loaderCode))}\n` : ''}
// === anim.js ===
${stripImports(stripExports(animCode))}

// === ${initFile} ===
${inlineWorkerInit(initCode)}

// === Exports ===
${exportBlock}
`;

  const sourcePath = path.join(DIST_DIR, `_${name}-source.mjs`);
  const outPath = path.join(DIST_DIR, `${name}.mjs`);

  fs.writeFileSync(sourcePath, source);
  if (!runEsbuild(sourcePath, outPath, { embeddedOnly })) {
    process.exit(1);
  }
  fs.unlinkSync(sourcePath);

  return outPath;
}

function writeNodeStubs() {
  console.log('4. Creating Node.js stubs...');

  const nodeStub = `
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
  pngine: browserOnly,
  destroy: browserOnly,
  draw: browserOnly,
  play: browserOnly,
  pause: browserOnly,
  stop: browserOnly,
  seek: browserOnly,
  setFrame: browserOnly,
  setUniform: browserOnly,
  setUniforms: browserOnly,
  getUniforms: browserOnly,
  extractBytecode: browserOnly,
  isPng,
  isZip,
  isPngb,
  detectFormat,
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
export const pngine = browserOnly;
export const destroy = browserOnly;
export const draw = browserOnly;
export const play = browserOnly;
export const pause = browserOnly;
export const stop = browserOnly;
export const seek = browserOnly;
export const setFrame = browserOnly;
export const setUniform = browserOnly;
export const setUniforms = browserOnly;
export const getUniforms = browserOnly;
export const extractBytecode = browserOnly;
`;

  fs.writeFileSync(path.join(DIST_DIR, 'index.js'), nodeStub);
  fs.writeFileSync(path.join(DIST_DIR, 'index.mjs'), nodeStubEsm);
}

function writeTypeDefs() {
  console.log('5. Creating TypeScript definitions...');

  const sharedTypes = `
/** Uniform value: number (f32), array (vecNf), or nested array (matNxMf) */
export type UniformValue = number | number[] | number[][];

export interface DrawOptions {
  time?: number;
  frame?: string;
  uniforms?: Record<string, UniformValue>;
}

export interface PngineInstance {
  readonly width: number;
  readonly height: number;
  readonly frameCount: number;
  readonly isPlaying: boolean;
  readonly time: number;
}

export function destroy(instance: PngineInstance): void;
export function draw(instance: PngineInstance, options?: DrawOptions): void;
export function play(instance: PngineInstance): PngineInstance;
export function pause(instance: PngineInstance): PngineInstance;
export function stop(instance: PngineInstance): PngineInstance;
export function seek(instance: PngineInstance, time: number): PngineInstance;
export function setFrame(instance: PngineInstance, frame: string | null): PngineInstance;
export function setUniform(instance: PngineInstance, name: string, value: UniformValue, redraw?: boolean): PngineInstance;
export function setUniforms(instance: PngineInstance, uniforms: Record<string, UniformValue>, redraw?: boolean): PngineInstance;
export function getUniforms(instance: PngineInstance): Promise<Record<string, { type: number; size: number; bufferId: number; offset: number }>>;

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
  onError?: (error: Error) => void;
}

export function pngine(
  source: ArrayBuffer | Uint8Array | Blob | string,
  options: ViewerOptions
): Promise<PngineInstance>;
${sharedTypes}
`;

  const devTypes = `
export interface DevOptions {
  canvas?: HTMLCanvasElement;
  debug?: boolean;
  wasmUrl?: string | URL;
  onError?: (error: Error) => void;
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
}

export interface UniformTableResult {
  uniforms: Map<string, UniformInfo>;
  strings: string[];
}

export interface CoreDispatcher {
  setMemory(memory: WebAssembly.Memory): void;
  execute(ptr: number): Promise<void> | void;
  setUniform(name: string, value: number | number[]): boolean;
  setUniforms(uniforms: Record<string, number | number[]>): number;
  setUniformTable(table: Map<string, UniformInfo>): void;
  destroy(): void;
  setDebug(v: boolean): void;
  setTime(t: number): void;
  setCanvasSize(w: number, h: number): void;
  _dispatcher: unknown;
}

export function createCommandDispatcher(device: GPUDevice, ctx: GPUCanvasContext): unknown;
export function parseUniformTable(bytecode: Uint8Array): UniformTableResult;
export function createCoreDispatcher(device: GPUDevice, ctx: GPUCanvasContext): CoreDispatcher;
export function getDevice(adapter?: GPUAdapter): Promise<GPUDevice>;
export function configureCanvas(canvas: HTMLCanvasElement, device: GPUDevice): GPUCanvasContext;
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

  fs.writeFileSync(path.join(DIST_DIR, 'index.d.ts'), viewerTypes);
  fs.writeFileSync(path.join(DIST_DIR, 'viewer.d.ts'), viewerTypes);
  fs.writeFileSync(path.join(DIST_DIR, 'dev.d.ts'), devTypes);
  fs.writeFileSync(path.join(DIST_DIR, 'core.d.ts'), coreTypes);
  fs.writeFileSync(path.join(DIST_DIR, 'executor.d.ts'), executorTypes);
}

console.log('1. Building viewer profile...');
const viewerOut = buildInlinedProfileBundle({
  name: 'viewer',
  title: 'Viewer',
  embeddedOnly: true,
  workerFile: 'worker-viewer.js',
  initFile: 'viewer-init.js',
  includeLoader: false,
  exportBlock: `
export { pngine, destroy };
export { draw, play, pause, stop, seek, setFrame, setUniform, setUniforms, getUniforms };
export { extractBytecode, detectFormat, isPng, isZip, isPngb };`,
});

console.log('2. Building dev profile...');
const devOut = buildInlinedProfileBundle({
  name: 'dev',
  title: 'Dev',
  embeddedOnly: false,
  workerFile: 'worker.js',
  initFile: 'init.js',
  includeLoader: true,
  exportBlock: `
export { pngine, destroy };
export { draw, play, pause, stop, seek, setFrame, setUniform, setUniforms, getUniforms };
export { extractBytecode, detectFormat, isPng, isZip, isPngb };
export { parsePayload, createExecutor, getExecutorImports, getExecutorVariantName };`,
});

console.log('3. Building core/executor profiles...');
const coreOut = path.join(DIST_DIR, 'core.mjs');
if (!runEsbuild(path.join(SRC_DIR, 'core.js'), coreOut, { embeddedOnly: true })) {
  process.exit(1);
}

const executorOut = path.join(DIST_DIR, 'executor.mjs');
if (!runEsbuild(path.join(SRC_DIR, 'executor.js'), executorOut, { embeddedOnly: false })) {
  process.exit(1);
}

writeNodeStubs();
writeTypeDefs();

console.log('\n=== Bundle Sizes ===\n');

const files = [
  ['viewer.mjs', viewerOut],
  ['dev.mjs', devOut],
  ['core.mjs', coreOut],
  ['executor.mjs', executorOut],
  ['index.js (node stub)', path.join(DIST_DIR, 'index.js')],
];

for (const [label, file] of files) {
  const info = sizeInfo(file);
  const rawKb = (info.raw / 1024).toFixed(1);
  const gzKb = (info.gzipped / 1024).toFixed(1);
  if (label.includes('node stub')) {
    console.log(`${label}: ${rawKb} KB`);
  } else {
    console.log(`${label}: ${rawKb} KB (${gzKb} KB gzipped)`);
  }
}

if (DEBUG) {
  console.log('\n[Debug build - includes source maps]');
}

console.log('\nDone!');
