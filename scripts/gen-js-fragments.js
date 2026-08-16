#!/usr/bin/env node
// Generates src/cli/js_fragments.zig from individual JS fragments.
//
//   node scripts/gen-js-fragments.js           # rewrite the Zig file
//   node scripts/gen-js-fragments.js --check   # exit 1 if it is stale
//
// Requires: npm install terser
//
// The --check half exists because the generated file drives shipped `--html`
// output and had a regen step with no gate: edit a fragment here, forget to
// run this, and every `--html` page keeps the old JS with nothing complaining.
//
// The `fragments` object below is the ONLY source. `scripts/js-html-template.mjs`
// used to sit beside it as a readable mirror, describing itself as "processed
// by Terser at build time" — this script never opened it, and its marker names
// (FS, GPU, D) had stopped corresponding to the fragment names anyway. Deleted
// rather than gated: a second copy of shipped JS that nothing reads is a place
// for edits to disappear into.
//
// Variables are deliberately single-letter — do NOT rename:
//   c = canvas element (from <canvas id=c>)
//   a = GPU adapter, d = device, x = context, f = format
//   D = decompression helper, W = shader array, L = requiredLimits
//   t0 = start time, t = elapsed time, F = frame function, R = rAF handle
//   window.__pngineStop = this run's teardown, called by the NEXT run
//   ai = audio instance, am/as/al/at = audio exports
//   afr = audio frames, asp = audio samples
//   ax = AudioContext, ab = audio buffer, sr = source node
//   s = user-supplied --audio-js start fn, _af = its FFT return handle
//   px/py = pointer pos, pcx/pcy = down pos (negated on up),
//   pdx/pdy = drag delta, pbt = buttons, ppr = pressure,
//   pm = modifier bitmask (shift1 ctrl2 alt4 meta8 space16), psx/psy = scroll

import { readFileSync, writeFileSync } from 'fs';

const CHECK = process.argv.includes('--check');

// terser is a devDependency, so it is absent in a fresh clone — including the
// release mirror, where `zig build test` depends on `drift` and would fail on
// a missing node_modules rather than on anything real. Absent + --check is a
// clean, LOUD skip; absent + regen is an error, because you asked to rewrite
// the file and cannot.
let minify;
try {
  ({ minify } = await import('terser'));
} catch {
  if (!CHECK) {
    console.error('gen-js-fragments: terser not installed — run `npm install` first');
    process.exit(2);
  }
  console.log('gen-js-fragments: terser not installed — skipping drift check (run `npm install` to enable).');
  process.exit(0);
}

// Each fragment is defined as a complete, valid JS program.
// Terser processes each independently to avoid cross-fragment optimization.
// The wrapper function is stripped after minification.
const fragments = {
  fs_setup: {
    // Fullscreen DPR setup (two statements)
    code: `c.width = innerWidth * devicePixelRatio;
           c.height = innerHeight * devicePixelRatio;`,
  },
  webgpu_init: {
    // WebGPU adapter, device, context, format
    code: `let a = await navigator.gpu.requestAdapter(),
             d = await a.requestDevice(),
             x = c.getContext('webgpu'),
             f = navigator.gpu.getPreferredCanvasFormat();
           x.configure({ device: d, format: f });`,
  },
  webgpu_init_limits: {
    // Same as webgpu_init but requests authored device limits (Arc-3 §5.3b).
    // The free `L` is emitted by js_codegen as `let L={requiredLimits:{…}}`
    // immediately before this fragment; mangle:false keeps `L` intact.
    code: `let a = await navigator.gpu.requestAdapter(),
             d = await a.requestDevice(L),
             x = c.getContext('webgpu'),
             f = navigator.gpu.getPreferredCanvasFormat();
           x.configure({ device: d, format: f });`,
  },
  decompress: {
    // Decompression helper (atob → inflate → text)
    code: `let D = s => new Response(
             new Blob([Uint8Array.from(atob(s), c => c.charCodeAt(0))])
               .stream()
               .pipeThrough(new DecompressionStream('deflate-raw'))
           ).text();`,
  },
  stop_prev: {
    // First statement of every page: stop whatever a PREVIOUS run of this
    // payload left behind. The packed bootstrap evals an async IIFE, so a second
    // eval — an SPA slot re-injecting the page, a hot reload, `eval` of `#` a
    // second time — used to run cleanly and abandon the first run entirely:
    // adapter, device, every created resource, the configured context, and an
    // rAF loop still drawing into a canvas packed mode had already detached.
    // The handle is global (window) because the two runs share nothing else.
    // `R` is declared here rather than with the loop so a STATIC page — no loop,
    // but still a device to release — registers the same stop hook below.
    code: `window.__pngineStop?.();
           let R;`,
  },
  stop_reg: {
    // …and publish this run's stop hook, once the device and loop it closes over
    // exist. Whole-device teardown, matching the runtime tiers: destroying the
    // device releases everything reachable from it, which is the only release
    // path a page with no runtime library can afford to spell out.
    code: `window.__pngineStop = () => { cancelAnimationFrame(R); d.destroy(); };`,
  },
  device_lost: {
    // Device loss (TDR, driver reset, another tab's device destroy) leaves F()
    // spinning on a dead device forever, one validation-error object per frame
    // into the console; only Esc → history.go() escaped. `d.lost` also resolves
    // on our own destroy(), where cancelling again is a no-op.
    code: `d.lost.then(() => cancelAnimationFrame(R));`,
  },
  pointer: {
    // Pointer/keyboard/wheel input state + event listeners (emitted when the
    // bytecode writes pointer-inputs). State packs into the pointer uniform:
    //   px,py    = pointer position (0..1)      pcx,pcy = down-pos, negated on up
    //   pdx,pdy  = drag delta (reset each frame) pbt = buttons  ppr = pressure
    //   pm       = modifier bitmask (shift1 ctrl2 alt4 meta8 space16)
    //   psx,psy  = wheel scroll (reset each frame) lx,ly = last pos (drag basis)
    code: `let px = 0, py = 0, pcx = 0, pcy = 0, pdx = 0, pdy = 0,
             pbt = 0, ppr = 0, pm = 0, psx = 0, psy = 0, lx = 0, ly = 0;
           c.onpointerdown = e => {
             let r = c.getBoundingClientRect(),
                 x = (e.clientX - r.left) / r.width,
                 y = (e.clientY - r.top) / r.height;
             px = x; py = y; pcx = x; pcy = y;
             pbt = e.buttons;
             ppr = e.pressure || .5;
             pm = (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0) | (pm & 16);
             lx = x; ly = y;
             c.setPointerCapture(e.pointerId);
           };
           c.onpointermove = e => {
             let r = c.getBoundingClientRect(),
                 x = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)),
                 y = Math.max(0, Math.min(1, (e.clientY - r.top) / r.height));
             pdx += x - lx; pdy += y - ly;
             px = x; py = y;
             pbt = e.buttons;
             ppr = e.pressure || (e.buttons ? .5 : 0);
             pm = (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0) | (pm & 16);
             lx = x; ly = y;
           };
           c.onpointerup = () => {
             pcx = -Math.abs(pcx); pcy = -Math.abs(pcy);
             pbt = 0; ppr = 0;
           };
           c.onpointercancel = c.onpointerup;
           document.onkeydown = e => { if (e.code === 'Space') pm |= 16; };
           document.onkeyup = e => { if (e.code === 'Space') pm &= ~16; };
           c.onwheel = e => {
             e.preventDefault();
             psx += Math.sign(e.deltaX);
             psy += Math.sign(e.deltaY);
             pm = (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0) | (pm & 16);
           };`,
  },
  dark_setup: {
    // Dark-mode flag state (emitted when a uniform struct has a top-level f32
    // member named `dark` — the same bind-by-name convention as entry points
    // and @group/@binding, and --minify preserves member names for it).
    //   dk  = the live 0/1 value, written per frame by js_codegen
    //   dkq = localStorage read; the `pngine-dark` key ('1'/'0') OVERRIDES the
    //         OS scheme so an embedding page (e.g. a same-origin iframe host)
    //         can drive the flag — a `storage` write from the parent flips it
    //         live, no reload. Guarded: storage access throws under blocked-
    //         cookies settings, and one throw here would kill the whole page.
    //   dkm = prefers-color-scheme fallback, tracked while no override is set.
    code: `let dkq = () => { try { return localStorage.getItem('pngine-dark') } catch { return null } },
             dkm = matchMedia('(prefers-color-scheme:dark)'),
             dk = +(dkq() ?? dkm.matches);
           dkm.onchange = e => { if (dkq() == null) dk = +e.matches; };
           onstorage = e => { if (e.key === 'pngine-dark') dk = +(e.newValue ?? dkm.matches); };`,
  },
  audio_pre: {
    // Audio WASM instantiation — prefix before base64 data
    // Fragment: everything up to and including atob('
    raw: "let{instance:ai}=await WebAssembly.instantiate(Uint8Array.from(atob('",
  },
  audio_post: {
    // Audio WASM instantiation — suffix after base64 data, plus sample extraction
    code: `let { instance: ai } = await WebAssembly.instantiate(
             Uint8Array.from(atob('X'), c => c.charCodeAt(0)),
             { m: Math }
           );
           let am = ai.exports.m,
             as = ai.exports.s.value,
             al = ai.exports.l.value,
             at = ai.exports.t.value == 1;
           let afr = at ? al / 4 : al / 8,
             asp = at
               ? new Int16Array(am.buffer, as, afr * 2)
               : new Float32Array(am.buffer, as, afr * 2);
           let ax = new AudioContext({ sampleRate: 44100 }),
             ab = ax.createBuffer(2, afr, 44100);
           for (let c = 0; c < 2; c++) {
             let d = ab.getChannelData(c);
             for (let i = 0; i < afr; i++)
               d[i] = at ? asp[i * 2 + c] / 32768 : asp[i * 2 + c];
           }
           let sr;`,
    // After minification, extract everything after atob('X
    // audio_pre ends with atob(' — base64 goes in — audio_post starts with ')
    postprocess: s => {
      const marker = "atob('X";
      const idx = s.indexOf(marker);
      return idx >= 0 ? s.slice(idx + marker.length) : s;
    },
  },
  anim_start: {
    // Animation loop opening — declares t0, opens F() with time calc
    code: `let t0;
           function F() {
             let t = (performance.now() - t0) / 1e3;
             __FRAME__(t);
             R = requestAnimationFrame(F);
           }`,
    postprocess: s => {
      const idx = s.indexOf('__FRAME__');
      return idx >= 0 ? s.slice(0, idx) : s;
    },
  },
  anim_end: {
    // Animation loop closing — rAF call + closing brace. The handle is KEPT
    // (`R=`): a bare requestAnimationFrame(F) discards the only thing that can
    // ever stop the loop, so device loss and a re-run both had nothing to
    // cancel. R is declared by stop_prev, at the top of the page.
    code: `let t0;
           function F() {
             let t = (performance.now() - t0) / 1e3;
             __FRAME__(t);
             R = requestAnimationFrame(F);
           }`,
    postprocess: s => {
      const re = /__FRAME__\(t\)[;,]?/;
      const match = s.match(re);
      if (!match) return 'R=requestAnimationFrame(F)}';
      return s.slice(match.index + match[0].length);
    },
  },
  esc_handler: {
    // Escape = reload page (kills rAF, audio, GPU — no cleanup needed)
    code: `onkeydown = e => e.which - 27 || history.go();`,
  },
  click_handler: {
    // Complete click handler (without audio)
    code: `c.onclick = () => {
             t0 = performance.now();
             F();
             c.onclick = 0;
           };`,
  },
  click_handler_audio: {
    // Complete click handler (with audio start + prompt removal)
    code: `p.onclick = () => {
             p.remove();
             t0 = performance.now();
             __AUDIO_START__;
             F();
           };`,
    postprocess: s => {
      const idx = s.indexOf('__AUDIO_START__');
      return idx >= 0 ? { before: s.slice(0, idx), after: s.slice(idx + '__AUDIO_START__'.length) } : null;
    },
  },
  click_audio_start: {
    // Audio start inside click handler
    code: `if (ax) {
             if (ax.state == 'suspended') ax.resume();
             sr = ax.createBufferSource();
             sr.buffer = ab;
             sr.connect(ax.destination);
             sr.start(0, 0);
           }`,
  },
  click_handler_audiojs: {
    // Complete audio-JS click handler (--audio-js): the user-supplied s()
    // starts audio directly, then the rAF loop begins. Split at F() so the
    // shared post (F()};) is reused by the FFT variant below.
    code: `p.onclick = () => {
             p.remove();
             t0 = performance.now();
             s();
             F();
           };`,
    postprocess: s => {
      const idx = s.indexOf('F()');
      return idx >= 0 ? { before: s.slice(0, idx), after: s.slice(idx) } : null;
    },
  },
  click_handler_audiojs_fft: {
    // Audio-JS click handler, FFT variant: capture s()'s return handle into
    // _af (used by write_audio_data). Pre-half only — shares the post above.
    code: `p.onclick = () => {
             p.remove();
             t0 = performance.now();
             _af = s();
             F();
           };`,
    postprocess: s => {
      const idx = s.indexOf('F()');
      return idx >= 0 ? s.slice(0, idx) : s;
    },
  },
};

const terserOpts = {
  module: true,
  compress: {
    passes: 2,
    sequences: true,
    conditionals: true,
    booleans: true,
    dead_code: false,     // don't remove "unused" declarations
    collapse_vars: false,
    reduce_vars: false,
    reduce_funcs: false,
    hoist_vars: false,
    hoist_funs: false,
    side_effects: false,  // don't remove expression statements
    unused: false,        // don't remove unused variables
  },
  mangle: false,
  output: {
    quote_style: 1,
    semicolons: true,
  },
};

// Minify each fragment
const results = {};

for (const [name, frag] of Object.entries(fragments)) {
  if (frag.raw) {
    // Raw string — no minification
    results[name] = frag.raw;
    continue;
  }

  // Wrap in async function to make valid JS (handles await, top-level const, etc.)
  const wrapped = `async function _(){${frag.code}}`;
  const res = await minify(wrapped, terserOpts);
  if (res.error) {
    console.error(`Terser error in ${name}:`, res.error);
    process.exit(1);
  }

  // Extract function body
  let body = res.code;
  const openBrace = body.indexOf('{');
  const lastBrace = body.lastIndexOf('}');
  if (openBrace >= 0 && lastBrace > openBrace) {
    body = body.slice(openBrace + 1, lastBrace).trim();
  }

  // Apply postprocessing if defined
  if (frag.postprocess) {
    body = frag.postprocess(body);
  }

  results[name] = body;
}

// Now assemble the final Zig constants from the processed fragments

function zigEscape(s) {
  return s
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')
    .replace(/\n/g, '\\n')
    .replace(/\t/g, '\\t');
}

// Ensure a string ends with ; (for safe concatenation with following code)
function ensureSemi(s) {
  if (!s || s.endsWith(';')) return s;
  return s + ';';
}

// Build the output mapping — some fragments split into parts
const zigConsts = {};

// Standalone fragments need trailing ; for safe concatenation
zigConsts.stop_prev = ensureSemi(results.stop_prev);
zigConsts.stop_reg = ensureSemi(results.stop_reg);
zigConsts.device_lost = ensureSemi(results.device_lost);
zigConsts.fs_setup = ensureSemi(results.fs_setup);
zigConsts.webgpu_init = ensureSemi(results.webgpu_init);
zigConsts.webgpu_init_limits = ensureSemi(results.webgpu_init_limits);
zigConsts.decompress = ensureSemi(results.decompress);
zigConsts.pointer = ensureSemi(results.pointer);
zigConsts.dark_setup = ensureSemi(results.dark_setup);
zigConsts.audio_pre = results.audio_pre;  // prefix — no ;
zigConsts.audio_post = ensureSemi(results.audio_post);
zigConsts.anim_start = results.anim_start; // opens function body — no trailing ;
zigConsts.anim_end = results.anim_end;     // ends with }

// Escape handler: single handler for all cases (history.go() kills everything)
zigConsts.esc_handler = ensureSemi(results.esc_handler);

// Click handler: use the full handler for no-audio case
zigConsts.click_handler = ensureSemi(results.click_handler);

// For audio case: split around __AUDIO_START__ marker
const clickParts = results.click_handler_audio;
if (clickParts && typeof clickParts === 'object') {
  zigConsts.click_handler_audio_pre = clickParts.before;
  zigConsts.click_audio_start = results.click_audio_start;
  zigConsts.click_handler_audio_post = ensureSemi(clickParts.after);
}

// For --audio-js case: pre halves differ (s() vs _af=s()), post (F()};) is shared
const ajsParts = results.click_handler_audiojs;
if (ajsParts && typeof ajsParts === 'object') {
  zigConsts.click_handler_audiojs_pre = ajsParts.before;
  zigConsts.click_handler_audiojs_fft_pre = results.click_handler_audiojs_fft;
  zigConsts.click_handler_audiojs_post = ensureSemi(ajsParts.after);
}

// Generate Zig file
let zig = `//! Auto-generated by scripts/gen-js-fragments.js — do not edit manually.
//! Regenerate: node scripts/gen-js-fragments.js
//! Verify:     node scripts/gen-js-fragments.js --check  (runs in \`zig build drift\`)
//! Source:     the \`fragments\` object in that script — NOT js-html-template.mjs,
//!             which is a readable mirror nothing reads at build time.

`;

const emitted = [];
for (const [name, code] of Object.entries(zigConsts)) {
  if (code !== undefined && code !== null && code !== '') {
    zig += `pub const ${name} = "${zigEscape(code)}";\n`;
    emitted.push(name);
  }
}

const outPath = new URL('../src/cli/js_fragments.zig', import.meta.url).pathname;

if (emitted.length === 0) {
  console.error('gen-js-fragments: zero fragments emitted — refusing to write or verify an empty file');
  process.exit(2);
}

if (CHECK) {
  if (readFileSync(outPath, 'utf8') !== zig) {
    console.error('=== JS FRAGMENT DRIFT ===');
    console.error(`  x ${outPath} does not match this script's output`);
    console.error('\nRegenerate with: node scripts/gen-js-fragments.js');
    process.exit(1);
  }
  console.log(`gen-js-fragments: ok (${emitted.length} fragments, ${zig.length} B)`);
  process.exit(0);
}

writeFileSync(outPath, zig);

// Report
console.log('Generated:', outPath);
console.log('\nFragment sizes:');
let total = 0;
for (const [name, code] of Object.entries(zigConsts)) {
  if (code) {
    console.log(`  ${name}: ${code.length}B`);
    total += code.length;
  }
}
console.log(`  TOTAL: ${total}B`);
