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
 *   node scripts/bundle.cjs         # production build
 *   node scripts/bundle.cjs --debug # debug build
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const SRC_DIR = path.join(__dirname, '../src');
const DIST_DIR = path.join(__dirname, '../dist');
const DEBUG = process.argv.includes('--debug');

// Resolve esbuild binary: prefer local node_modules, fall back to global
const ESBUILD = (() => {
  const localBin = path.join(__dirname, '../../../node_modules/.bin/esbuild');
  if (fs.existsSync(localBin)) return localBin;
  return 'esbuild';
})();

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
    'mini.mjs',
    'mini.mjs.map',
    'mini-no-audio.mjs',
    'mini-no-audio.mjs.map',
    'index.js', // pre-type:module stale artifact
    'index.cjs',
    'index.mjs',
    'index.d.ts',
    'viewer.d.ts',
    'dev.d.ts',
    'core.d.ts',
    'executor.d.ts',
    'mini.d.ts',
    'mini-no-audio.d.ts',
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
    ESBUILD,
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

// Assert the inlined profile bundle is import-CLOSED: every `./x.js` a
// concatenated module imports is itself concatenated.
//
// stripImports() deletes each `import … from './x.js'` line on the assumption
// that x.js appears in the same concatenation. When it does not, the imported
// names survive as FREE IDENTIFIERS — and nothing downstream objects: esbuild
// treats an undefined identifier as a global, warns nothing, and (being unable
// to prove it local) leaves it unmangled. The bundle builds clean and throws
// ReferenceError at runtime, only on the path that reaches the call.
//
// That shipped. audio.js and worker-errors.js were imported by init.js and
// viewer-init.js but never listed here, so in every published viewer/dev bundle
// the post-init `worker.onmessage` threw on the first message it handled —
// taking out onError delivery (shader errors, GPU errors) and onQueryResult —
// while any pNGa-audio payload failed init outright. src/ was fine throughout;
// only the bundle was broken, which is exactly what the node tests don't load.
//
// So: check the closure rather than trusting the hand-maintained read list.
function assertInlineClosure(profile, modules) {
  const missing = [];
  for (const [file, code] of Object.entries(modules)) {
    for (const m of code.matchAll(/^import\s+.*?from\s+['"]\.\/([\w-]+\.js)['"]/gm)) {
      if (!(m[1] in modules)) missing.push(`${file} imports ./${m[1]}`);
    }
  }
  if (missing.length) {
    console.error(`\n=== INLINE CLOSURE FAILED (${profile}) ===`);
    for (const m of missing) console.error(`  x ${m}, which is not concatenated into the bundle`);
    console.error(
      '\nIts imported names would survive as undefined globals and throw\n' +
      'ReferenceError at runtime. Read the module in buildInlinedProfileBundle\n' +
      'and add it to the concatenation (before the block that uses it).',
    );
    process.exit(1);
  }
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
  const pngChunksCode = fs.readFileSync(path.join(SRC_DIR, 'png-chunks.js'), 'utf-8');
  const envelopeCode = fs.readFileSync(path.join(SRC_DIR, 'envelope.js'), 'utf-8');
  const payloadsCode = fs.readFileSync(path.join(SRC_DIR, 'payloads.js'), 'utf-8');
  const inflateCode = fs.readFileSync(path.join(SRC_DIR, 'inflate.js'), 'utf-8');
  const detectCode = fs.readFileSync(path.join(SRC_DIR, 'detect.js'), 'utf-8');
  const extractCode = fs.readFileSync(path.join(SRC_DIR, 'extract.js'), 'utf-8');
  const playbackCode = fs.readFileSync(path.join(SRC_DIR, 'playback-state.js'), 'utf-8');
  const animCode = fs.readFileSync(path.join(SRC_DIR, 'anim.js'), 'utf-8');
  const audioCode = fs.readFileSync(path.join(SRC_DIR, 'audio.js'), 'utf-8');
  const workerErrorsCode = fs.readFileSync(path.join(SRC_DIR, 'worker-errors.js'), 'utf-8');
  const initCoreCode = fs.readFileSync(path.join(SRC_DIR, 'init-core.js'), 'utf-8');
  const initCode = fs.readFileSync(path.join(SRC_DIR, initFile), 'utf-8');
  const loaderCode = includeLoader
    ? fs.readFileSync(path.join(SRC_DIR, 'loader.js'), 'utf-8')
    : '';

  assertInlineClosure(name, {
    'png-chunks.js': pngChunksCode,
    'envelope.js': envelopeCode,
    'payloads.js': payloadsCode,
    'inflate.js': inflateCode,
    'detect.js': detectCode,
    'extract.js': extractCode,
    'playback-state.js': playbackCode,
    'anim.js': animCode,
    'audio.js': audioCode,
    'worker-errors.js': workerErrorsCode,
    'init-core.js': initCoreCode,
    [initFile]: initCode,
    ...(includeLoader ? { 'loader.js': loaderCode } : {}),
  });

  const source = `
/**
 * PNGine ${title} Bundle
 * ${DEBUG ? 'Debug build' : 'Production build'}
 * Generated: ${new Date().toISOString()}
 */

const WORKER_CODE = ${JSON.stringify(workerCode)};

// One blob URL per document, shared by every instance. A blob URL is rooted in
// the document's URL registry until it is revoked, and the blob it names holds
// the whole worker source — so minting one per pngine() call (with no
// revokeObjectURL anywhere) grew without bound in an SPA or a multi-embed page.
// Memoizing beats revoke-after-construct: there is no timing argument to get
// wrong, and the worker source is identical for every instance anyway.
let WORKER_URL = null;
function createWorkerBlobUrl() {
  return WORKER_URL ??= URL.createObjectURL(new Blob([WORKER_CODE], { type: 'application/javascript' }));
}

// === png-chunks.js ===
${stripImports(stripExports(pngChunksCode))}

// === envelope.js ===
${stripImports(stripExports(envelopeCode))}

// === payloads.js ===
${stripImports(stripExports(payloadsCode))}

// === inflate.js ===
${stripImports(stripExports(inflateCode))}

// === detect.js ===
${stripImports(stripExports(detectCode))}

// === extract.js ===
${stripImports(stripExports(extractCode))}

${includeLoader ? `// === loader.js ===\n${stripImports(stripExports(loaderCode))}\n` : ''}
// === playback-state.js ===
${stripImports(stripExports(playbackCode))}

// === anim.js ===
${stripImports(stripExports(animCode))}

// === audio.js ===
${stripImports(stripExports(audioCode))}

// === worker-errors.js ===
${stripImports(stripExports(workerErrorsCode))}

// === init-core.js ===
${stripImports(stripExports(initCoreCode))}

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
  console.log('5. Creating Node.js stubs...');

  // The format detectors are single-sourced from src/detect.js — inline its
  // source (CJS: strip the `export ` keywords; ESM: verbatim) so the stubs
  // can't drift from extract.js the way the old hand-copied checks did.
  const detectSource = fs.readFileSync(path.join(SRC_DIR, 'detect.js'), 'utf-8');
  const detectCjs = stripExports(detectSource);

  const nodeStub = `
${detectCjs}

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
  writeBuffer: browserOnly,
  setPointer: browserOnly,
  getBuffers: browserOnly,
  getStats: browserOnly,
  restart: browserOnly,
  restartSettled: browserOnly,
  extractBytecode: browserOnly,
  isPng,
  isZip,
  isPngb,
  detectFormat,
};
`;

  const nodeStubEsm = `
${detectSource}
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
export const writeBuffer = browserOnly;
export const setPointer = browserOnly;
export const getBuffers = browserOnly;
export const getStats = browserOnly;
export const restart = browserOnly;
export const restartSettled = browserOnly;
export const extractBytecode = browserOnly;
`;

  fs.writeFileSync(path.join(DIST_DIR, 'index.cjs'), nodeStub);
  fs.writeFileSync(path.join(DIST_DIR, 'index.mjs'), nodeStubEsm);
}

// The .d.ts strings live in scripts/type-defs.cjs — the published API surface
// for TypeScript callers, gated against the runtime by
// tests/npm/types-surface.test.js (module exports, dispatcher methods,
// instance getters, the init files' documented options, the worker's reply
// keys). An option missing there is an option an object literal cannot pass,
// because excess-property checks reject it.
function writeTypeDefs() {
  console.log('6. Creating TypeScript definitions...');
  const { viewerTypes, devTypes, coreTypes, executorTypes, miniTypes } = require('./type-defs.cjs');

  fs.writeFileSync(path.join(DIST_DIR, 'index.d.ts'), viewerTypes);
  fs.writeFileSync(path.join(DIST_DIR, 'viewer.d.ts'), viewerTypes);
  fs.writeFileSync(path.join(DIST_DIR, 'dev.d.ts'), devTypes);
  fs.writeFileSync(path.join(DIST_DIR, 'core.d.ts'), coreTypes);
  fs.writeFileSync(path.join(DIST_DIR, 'executor.d.ts'), executorTypes);
  fs.writeFileSync(path.join(DIST_DIR, 'mini.d.ts'), miniTypes);
  fs.writeFileSync(path.join(DIST_DIR, 'mini-no-audio.d.ts'), miniTypes);
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
export { draw, play, pause, stop, seek, setFrame, setUniform, setUniforms, getUniforms, writeBuffer, setPointer, getBuffers, getStats, restart, restartSettled };
export { extractBytecode, detectFormat, isPng, isZip, isPngb };
export { payloadsOf };`,
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
export { draw, play, pause, stop, seek, setFrame, setUniform, setUniforms, getUniforms, writeBuffer, setPointer, getBuffers, getStats, restart, restartSettled };
export { extractBytecode, detectFormat, isPng, isZip, isPngb };
export { parsePayload, createExecutor, getExecutorImports, getExecutorVariantName };
export { payloadsOf };`,
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

console.log('4. Building mini profile...');
const miniOut = path.join(DIST_DIR, 'mini.mjs');
if (!runEsbuild(path.join(SRC_DIR, 'mini.js'), miniOut, { embeddedOnly: true, define: { AUDIO: 'true' } })) {
  process.exit(1);
}

console.log('4b. Building mini-no-audio profile...');
const miniNoAudioOut = path.join(DIST_DIR, 'mini-no-audio.mjs');
if (!runEsbuild(path.join(SRC_DIR, 'mini.js'), miniNoAudioOut, { embeddedOnly: true, define: { AUDIO: 'false' } })) {
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
  ['mini.mjs', miniOut],
  ['mini-no-audio.mjs', miniNoAudioOut],
  ['index.cjs (node stub)', path.join(DIST_DIR, 'index.cjs')],
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

// Size gates (item 4.2 / A8): production bundles must stay under budget.
// Budgets = measured reality (2026-07, minified) + ~10% headroom. A bundle
// growing past its budget is either a regression or a deliberate feature cost —
// both should be a conscious budget bump here, not a silent creep. Skipped for
// --debug builds (source maps + no minify make the sizes meaningless as a gate).
// Sibling to the executor budget guard in build.zig (item 4.2 / C7b).
if (!DEBUG) {
  const SIZE_BUDGETS = {
    // viewer/dev bumped 2026-07-19 (+1.2 KB): audio.js and worker-errors.js are
    // now actually concatenated into them. The bundles were previously UNDER
    // budget only because they were missing code they call — see
    // assertInlineClosure. Paying for it is the fix, not a regression.
    // viewer/core nudged again same-day (+200/+100): decodeWasmArgs replaced a
    // decode loop that was wrong in four ways and gave every runtime-arg
    // #wasmCall zero arguments. The feature did not work before; this is the
    // first build in which it costs anything.
    // Bumped 2026-07-19 (+600/+400/+700) for the gpu-queue-commands.js split.
    // This one buys NO runtime feature — it is spent on the ops-bag accessors
    // the extracted module reads closure state through. What it buys instead is
    // testability: with dispatch() inside the gpu.js closure, opcodes 0x20-0xFF
    // could not be driven from a test at all, so command-buffer-widths.test.js
    // now pins all 49 commands against the Zig emitter rather than the 37 that
    // happened to already live in a module. Judged worth ~1% of the viewer.
    // core/viewer/dev bumped 2026-07-20 (+200 each): set_pass_clear_values
    // (0x52) — authored depth/stencil clear values reach the runtime
    // (docs/plans/spec/02). A real feature cost, partly offset by deleting the
    // dead BLEND_FACTOR/BLEND_OPERATION tables (spec/08 item 1).
    // viewer/dev +200 again same day: canvasAlphaMode() — the (canvas
    // :alpha-mode …) header flag reaches every configure site (spec/04).
    // core +200 same day: canvasAlphaMode re-exported from the core profile —
    // configureCanvas's doc says "pass canvasAlphaMode(bytecode)", so the
    // bundle that doc ships in must actually export it.
    // viewer/dev/core bumped 2026-08-07 (+1400/+1400/+800) for the browser
    // resource-lifetime work. What it buys, in rough order of bytes: the
    // acknowledged worker teardown (destroy() waits for MSG.DESTROYED so
    // handleDestroy's device.destroy() actually runs — it was dead code),
    // destroy() emptying the instance's internal bag, the AbortController the
    // seven pointer/key listeners now register through, the per-(bind group,
    // pipeline) auto-layout cache, guards on the five unguarded create
    // handlers, and the extra release work in gpu.destroy(). All of it is
    // teardown and lifetime correctness, none of it runs per frame.
    // +1000/+1000/+300 again, same day, for the stats channel: getStats(p) and
    // the worker's MSG.STATS reply. That is observability rather than
    // correctness, and it is the deliverable for long-running sessions —
    // `gpu.live.*` flat while `gpu.executed` climbs is a property a soak can
    // assert, where heap size cannot (a GPU object is a few bytes of JS wrapper
    // over driver memory the heap never sees).
    // viewer/dev/core bumped 2026-08-14 (+400/+400/+100) for LEAK-06: the
    // dispatch queue in worker-core (one Worker message at a time, superseded
    // rAF draws dropped) and the `alive` flag gpu.js's execute loop and its two
    // async creates check. Both are ordering correctness rather than features —
    // pre-§350, eight reloads of a textured payload overlapped NINE handler
    // bodies, stranded seven decoded ImageBitmaps in replaced dispatchers, and
    // desynced the shared WASM command buffer ("unknown GPU command 0x0").
    // viewer/dev/core +600 and mini +100 on 2026-08-16 for spec/09 step D: the
    // render-pass clear value widened from 4×u8 to 4×f32, which means two new
    // command opcodes (0x53/0x54) decoded alongside the two they replace. The
    // legacy pair stays because docs/abi.md clause 1 makes opcode layouts
    // append-only and this runtime decodes every executor ever shipped — so
    // most of these bytes are the price of NOT breaking old payloads, not the
    // price of the feature. mini pays less: pNGf is versioned rather than
    // frozen, so it carries the f32 arm alone and refuses a v1 chunk outright.
    // viewer/dev +400 each on 2026-08-19 (third leak pass): recovery releases
    // the stack it replaces, a failed load's dispatcher is not inherited
    // (`gpuDirty`), self-recovery rides the dispatch FIFO, `scoped()` pops its
    // error scope in a `finally`, and a failed worker bring-up detaches its
    // listeners. Lifecycle correctness, ~100–230 B minified.
    // viewer/dev/core bumped 2026-09-02 (+3400/+3500/+3700 over two commits)
    // for two things found together. First, the gate was already RED on a
    // clean tree at 6a29562 by +285/+406/+500 (esbuild 0.24.2) — the blind
    // spot this comment block records twice already: nothing in `npm test`
    // runs it. Second, host buffer writes (gpu-host-write.js,
    // docs/plans/public-write-buffer.md): ~2.9 KB minified per bundle. The
    // name map, pools (one member, the active member, every member), the
    // getBuffers listing, and the eight refusal messages a host hears instead
    // of a silent no-op — unknown name, frame-written, bad pool member, no
    // copy-dst (with the fix spelled out), misaligned, out of range. About
    // 1.1 KB of it is the messages, which are the feature. core also gains
    // setOnError, without which its writeBuffers would have been exactly the
    // silent no-op the plan's D6 forbids. viewer/dev +400 more, same day, for
    // the worker seam: `buffers` on the draw message (applied inside the
    // render lock, with the frame counter), the supersession exemption, and
    // the GET_BUFFERS/BUFFERS pair. All three +300 on 2026-09-03 for the
    // block reader: parseUniformTable's third key, `buffers`, read behind
    // header flag bit 4 and bounded by the section end. viewer/dev +1000 the
    // same day for the public surface: writeBuffer(p, name, bytes, opts) and
    // getBuffers(p) in anim.js, `buffers` on the draw message, and the
    // `redraw: false` store both APIs now share (setUniform's doc promised it
    // from the first commit; the branch was a no-op). ~1 KB minified, a third
    // of it the three TypeErrors a malformed call gets before anything posts.
    // core +300 2026-09-03 (measured +80): setUniform's refusals reach onError
    // (source "set-uniform") instead of a DEBUG-gated console.warn — the same
    // route writeBuffer's take. Three message strings, no per-frame cost; a
    // typo in a uniform name used to ship a write that never landed with no
    // signal to the host (docs/plans/archive/api-audit-2026-09.md finding 5).
    // dev +200 on 2026-09-05 (measured +235 on all three; viewer and core had
    // the room): getUniforms speaks names — each field's type as WGSL spells
    // it and its buffer by its `(buffer :name …)` — where the reply carried
    // the wire tag and the dispatcher id, neither of which anything public
    // accepts. The 14-name table, indexed by tag, is also what setUniform's
    // "could not be packed" refusal names the type with.
    // viewer/dev bumped 2026-10-05 (+2900/+2800) for payloads.js, the 02.C2
    // payload walker: legacy-letter mapping, pNGx envelope records, continued
    // chains, the CRC/bounds framing preflight (finding 2) and the PNG
    // signature gate (finding 7). It was concatenated into both profiles at
    // f3d7f4cd but never built. The same blind spot is recorded twice above:
    // nothing in `npm test` runs the bundler, so the bundles were UNDER
    // budget only because they were missing the code they export. Paying for
    // it is the fix, not a regression.
    // +500 each 2026-10-05: setPointer(p, lanes), the posted-pointer seam (ask
    // 05). The verb, its two refusals before anything changes, and the export
    // line are +443 B minified on both profiles (59112 -> 59555 viewer,
    // 63954 -> 64397 dev), a real feature cost, not a regression.
    // viewer/dev +2000/+2000 on 2026-10-17 for restartSettled(p), the awaited
    // restart (the animader demo's restart-while-audio-starts bug): the
    // rid-correlated request/reply in anim.js (listener-before-post, the
    // shared-budget timer, the destroy abandon, the crash listeners, the
    // four refusal codes) and the worker's restart-done echo with its skip
    // and failure arms. Measured 59987 -> 61496 viewer and 64831 -> 66340 dev
    // (+1509 each; the baseline was rebuilt at 57f5f379 for the comparison).
    // Two things this bump records beyond the feature: first, the gate was
    // already RED on that clean tree (+287/+331 — the blind spot this
    // comment has recorded twice before: nothing in `npm test` runs the
    // bundler), so +287/+331 of the raise is pre-existing creep being paid
    // for here rather than silently carried; second, the headroom is the
    // same small margin the setPointer entry set, not a new cushion.
    'viewer.mjs': 61700,
    'dev.mjs': 66500,
    'core.mjs': 31600,
    'executor.mjs': 2200,
    'mini.mjs': 7300,
    'mini-no-audio.mjs': 6600,
  };
  // src/gpu.js hand-authored source ceiling. Briefly raised to 42500 on
  // 2026-07-19 to record creep that had already crossed it (42120 B on a clean
  // tree — this gate was red and unnoticed, since nothing runs it but
  // `zig build web-bundle`), then extracting uniform-convert.js took gpu.js to
  // 37.8 KB. Set to 39000 (below the original 40000) so the split's headroom
  // couldn't be banked as silent slack — then the error-scope attribution landed
  // in the very next commit and spent 1.2 KB of it, leaving 15 B of margin. Back
  // to 40000: a ceiling one comment can breach is noise, not a gate. The split
  // still bought ~1 KB of real headroom against where this started. Then
  // decodeWasmArgs (the #wasmCall arg fix) spent another 311 B on top: 40500.
  // 2026-07-19: extracting gpu-queue-commands.js took gpu.js to 33.5 KB.
  // LOWERED to 34500 rather than left at 40500 — the whole point of the split
  // is headroom that stays visible, and a ceiling 7 KB above the file is not a
  // gate. Same reasoning as the 39000 step above.
  // +2000 2026-08-07: gpu.destroy() now releases the kinds it skipped
  // (GPUQuerySet destroy, ImageBitmap close) and clears the closure state a
  // dispatcher can outlive its device holding — `mem` most of all, which pins
  // the executor's entire WASM memory. Most of the delta is the comment
  // explaining WHY each of those has to be there, which is the part that stops
  // the next reader deleting them as ceremony.
  // +700 same day: getStats() + the per-frame execute counter.
  // 2026-08-14 (§351): 37800 → 45000. Two things worth saying rather than a
  // silent bump. First, this gate had been RED on a clean tree since §349
  // (39396 B) and nobody saw it, because nothing runs it but `zig build
  // web-bundle` — the same blind spot its own comment history records twice
  // already. Second, what it measures is source INCLUDING comments, so it
  // taxes the explanations this codebase asks for; the shipping cost of the
  // same work was 36/76/128 B on the three bundle budgets above, which is what
  // a user actually pays. Kept (a module that needs 45 KB of source is worth a
  // second look) but set with the ~3% headroom its own "a ceiling one comment
  // can breach is noise" rule implies, not to the current size.
  // 2026-08-19: 45000 → 46500 — the `scoped()` try/finally and the bind-group
  // write-order comments of the third leak pass crossed it by 127 B of prose;
  // re-set at the same ~3% headroom over today's 45.1 KB.
  // 2026-09-02: 46500 → 48000. The host write path went into its own module
  // (gpu-host-write.js) precisely so this file would not pay for it; gpu.js's
  // share is four lines (the import, `bufSize`, its clear, the forward) and
  // one ops-bag entry, 356 B, and the gate was 344 B from its ceiling. Re-set
  // at the same ~3% headroom over today's 46.5 KB.
  // 2026-09-03: 48000 → 49500. The buffer-name block's reader lives in
  // parseUniformTable — gpu.js's parse territory, beside the bindings it
  // follows, not the write module's — and its doc comment says what the block
  // is and when it is read. ~1.3 KB, most of it that comment. Re-set at ~3%
  // headroom over today's 48.3 KB.
  const GPU_SOURCE_BUDGET = 49500;

  const violations = [];
  for (const [label, file] of files) {
    const budget = SIZE_BUDGETS[label];
    if (budget === undefined) continue;
    const raw = fs.statSync(file).size;
    if (raw > budget) {
      violations.push(`${label}: ${raw} B exceeds budget ${budget} B (+${raw - budget})`);
    }
  }
  const gpuRaw = fs.statSync(path.join(SRC_DIR, 'gpu.js')).size;
  if (gpuRaw > GPU_SOURCE_BUDGET) {
    violations.push(`src/gpu.js: ${gpuRaw} B exceeds budget ${GPU_SOURCE_BUDGET} B (+${gpuRaw - GPU_SOURCE_BUDGET})`);
  }

  if (violations.length > 0) {
    console.error('\n=== SIZE GATE FAILED (item 4.2 / A8) ===');
    for (const v of violations) console.error(`  x ${v}`);
    console.error('\nA bundle grew past its budget. If deliberate, bump it in scripts/bundle.cjs.');
    process.exit(1);
  }
  console.log('\nSize gates OK (all production bundles + gpu.js within budget).');
}

console.log('\nDone!');
