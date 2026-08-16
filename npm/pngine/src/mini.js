// PNGine Mini Viewer - flat pNGf only, no WASM executor
// Main thread, no Worker, no OffscreenCanvas

import { walkChunks } from "./png-chunks.js";
import { inflateRaw } from "./inflate.js";
import { deinterleaveStereo } from "./audio.js";

// Build flag — esbuild replaces AUDIO per profile (--define:AUDIO=false builds
// mini-no-audio). Same typeof-guard fallback gpu.js gives DEBUG and loader.js
// gives EMBEDDED_ONLY: without it, importing this module raw (from src/, in a
// test, or from any bundler that doesn't define it) throws ReferenceError on
// the first chunk walk rather than simply playing without audio.
if (typeof AUDIO === "undefined") globalThis.AUDIO = true;

async function P(ab) {
  const b = new Uint8Array(ab);
  let au, fl;
  for (const c of walkChunks(b)) {
    if (c.type[0] === 0x70 && c.type[1] === 0x4E && c.type[2] === 0x47) {
      if (AUDIO && c.type[3] === 97) au = await D(c.data);
      else if (c.type[3] === 102) fl = await D(c.data);
    }
  }
  return { au, fl };
}

// Parse a pNG* chunk payload (version + flags header), inflating if flag bit 0.
async function D(d) {
  const p = d.subarray(2);
  return (d[1] & 1) ? inflateRaw(p) : new Uint8Array(p);
}

// The pointer-inputs buffer (`pt`) is allocated PER INSTANCE in miniPngine and
// threaded through here as the last parameter. It used to be eleven
// module-level `let`s shared by this executor and every player: two mini
// players on one page wrote into the same variables, so whichever canvas last
// received an event won for both, and a player nobody was touching followed the
// cursor over its neighbour. Scroll was worse — it ACCUMULATES, so the two
// players' wheel deltas summed into one running total.
//
// Layout (12 f32, pinned by tests/npm/helpers/pointer-layout.js, identical to
// init-core.js attachPointerTracking):
//   0 x · 1 y · 2 clickX · 3 clickY · 4 dx · 5 dy · 6 buttons · 7 pressure
//   8 modifiers · 9 scrollX · 10 scrollY · 11 _pad
//
// `bd` (the bind-group rebuild cache) and `ti` (the time-uniform staging array)
// are threaded in for the same reason `pt` is: they are PER-INSTANCE state that
// must survive from one call of this function to the next. `bd` used to be a
// `const bd = []` declared right here — populated only by the init call, so
// every frame call got an empty one and case 19's rebuild branch could never
// run (see there).
function X(d, ds, p, e, V, dv, ctx, fm, bf, sh, pp, cp, bg, tm, W, H, pt, bd, ti) {
  const R=o=>V.getUint16(o,!0),G=o=>V.getUint32(o,!0);
  const rs = (o, l) => new TextDecoder().decode(d.subarray(ds + o, ds + o + l));
  e = p + e; let ps, en, cP = -1;
  while (p < e) {
    const o = d[p++];
    switch (o) {
      // The five create arms are IDEMPOTENT (pitfall 35 rule 1, mirroring
      // gpu.js's `if (table[id]) return`). They used to assign unconditionally,
      // so a create anywhere in the frame range minted a fresh GPU object at
      // 60Hz — none released, and the id table repointed away from whatever the
      // bind groups already held. The flat writer refuses to emit such a pNGf,
      // but mini plays bytes that arrived in a PNG and nothing makes those the
      // compiler's bytes. The guard also skips the arm's decode work (a
      // TextDecoder pass, a JSON.parse), which is the per-frame cost that made
      // this expensive as well as wrong.
      case 1: {
        const id = R(p), sz = G(p+2), u = R(p+6);
        let f = 0; if (u & 8) f |= 8; if (u & 0x20) f |= 32; if (u & 0x40) f |= 64; if (u & 0x80) f |= 128; if (u & 0x100) f |= 0x100;
        bf[id] ??= dv.createBuffer({size: sz, usage: f}); p += 8; break;
      }
      case 4: sh[R(p)] ??= dv.createShaderModule({code: rs(G(p+2), G(p+6))}); p += 10; break;
      case 5: {
        const id = R(p);
        if (!pp[id]) {
          const dd = JSON.parse(rs(G(p+2), G(p+6)));
          pp[id] = dv.createRenderPipeline({layout:'auto', vertex:{module:sh[dd.vertex?.shader??0],entryPoint:dd.vertex?.entryPoint??'vs',buffers:dd.vertex?.buffers??[]}, fragment:{module:sh[dd.fragment?.shader??0],entryPoint:dd.fragment?.entryPoint??'fs',targets:[{format:fm}]}, primitive:dd.primitive??{topology:'triangle-list'}});
        }
        p += 10; break;
      }
      case 6: {
        const id = R(p);
        if (!cp[id]) {
          const dd = JSON.parse(rs(G(p+2), G(p+6)));
          cp[id] = dv.createComputePipeline({layout:'auto', compute:{module:sh[dd.compute?.shader??0],entryPoint:dd.compute?.entryPoint??'main'}});
        }
        p += 10; break;
      }
      case 7: {
        const id = R(p), pl = R(p+2), dp = G(p+4), dl = G(p+8);
        if (bg[id]) { p += 12; break; }
        const b = d.subarray(ds + dp, ds + dp + dl), bv = new DataView(b.buffer, b.byteOffset, b.byteLength);
        let q = 2, gi = 0; const es = [];
        for (let k = 0; k < b[1]; k++) {
          const fi = b[q++], vt = b[q++];
          if (fi === 1 && vt === 7) gi = b[q++];
          // Bind-group entries. BUFFER-ONLY, and that is total rather than a
          // subset: every resource a non-buffer entry could name (ResourceType
          // texture_view/sampler/external_texture/explicit_texture_view, 1..4)
          // has to be created by create_texture / create_sampler /
          // create_texture_view, and flat.zig refuses to export a pNGf
          // containing any of the three. So `rt !== 0` is unreachable through
          // the writer, and only a hostile/corrupt payload gets here — throw
          // like the opcode default below instead of guessing.
          //
          // (It previously "handled" rt 2 and 3 by indexing sampler/texture-view
          // tables that are necessarily empty, with 3 read as a texture view
          // when 3 is external_texture. Dead code that read as support, and
          // invited the belief that mini merely misparses textures.)
          else if (fi === 2 && vt === 3) { let ec = b[q++]; while (ec--) { const bi = b[q++], rt = b[q++], ri = bv.getUint16(q, true); q += 2; if (rt !== 0) throw new Error(`pngine/mini: bind-group resource type ${rt} is unsupported by the minimal player — re-export without --flat (the viewer runtime binds textures and samplers)`); es.push({binding:bi,resource:{buffer:bf[ri]}}); q += 8; } }
        }
        // `a` caches the per-pipeline auto-layout rebuilds case 19 makes.
        bd[id] = {pl, gi, es, a: /** @type {Record<number, GPUBindGroup>|null} */ (null)}; bg[id] = dv.createBindGroup({layout:(pp[pl]||cp[pl]).getBindGroupLayout(gi),entries:es}); p += 12; break;
      }
      case 16: cP = -1; en = dv.createCommandEncoder(); ps = en.beginRenderPass({colorAttachments:[{view:ctx.getCurrentTexture().createView(),loadOp:'clear',storeOp:'store',clearValue:[d[p+6]/255,d[p+7]/255,d[p+8]/255,d[p+9]/255]}]}); p += 10; break;
      case 17: cP = -1; if (!en) en = dv.createCommandEncoder(); ps = en.beginComputePass(); break;
      case 18: { const pid = R(p); cP = pid; ps.setPipeline(pp[pid]||cp[pid]); p += 2; break; }
      // Auto-layout rebuild, cached per (bind group, pipeline) in `dd.a` —
      // mirrors gpu-resource-pass-commands.js 0x13. Uncached this made a fresh
      // GPUBindGroup on EVERY frame that bound the group, none of them
      // released; keyed by pipeline because one slot would thrash on a payload
      // alternating two pipelines over one group.
      //
      // This branch was UNREACHABLE from a frame until `bd` became per-instance:
      // only the init call populated it, and it was a local, so `dd` was always
      // undefined here. The visible symptom was not the leak the cache prevents
      // but the correctness bug underneath it — a group created against one
      // pipeline and bound under another was handed over unrebuilt, which WebGPU
      // rejects silently.
      case 19: { let g = bg[R(p+1)]; const dd = bd[R(p+1)]; if (dd && cP >= 0 && dd.pl !== cP) { const P = pp[cP]||cp[cP]; if (P) g = (dd.a ??= {})[cP] ??= dv.createBindGroup({layout:P.getBindGroupLayout(dd.gi),entries:dd.es}); } ps.setBindGroup(d[p], g); p += 3; break; }
      case 20: ps.setVertexBuffer(d[p], bf[R(p+1)]); p += 3; break;
      case 21: ps.draw(G(p), G(p+4)); p += 16; break;
      case 22: ps.drawIndexed(G(p), G(p+4)); p += 20; break;
      case 23: ps.end(); ps = null; break;
      case 24: ps.dispatchWorkgroups(G(p), G(p+4), G(p+8)); p += 12; break;
      // Staged through the instance's own `ti`, not a `new Float32Array([…])`
      // per frame: at 60Hz that is sixty allocations a second whose only purpose
      // is to be copied by writeBuffer and dropped. Its neighbour below already
      // avoided exactly this (the §310 lesson, applied to one arm and not the
      // other).
      case 33: ti[0]=tm; ti[1]=W; ti[2]=H; ti[3]=W/H; dv.queue.writeBuffer(bf[R(p)], 0, ti); p += 8; break;
      // The buffer is written wholesale — it already IS the wire layout, so
      // there is no per-frame Float32Array to build.
      case 38: dv.queue.writeBuffer(bf[R(p)], 0, pt); p += 8; break;
      case 240: if (en) { dv.queue.submit([en.finish()]); en = null; } break;
      case 255: return;
      // An opcode mini can't decode. Its operands would be re-read as opcodes and
      // desync the whole stream (mini has no per-opcode length table). The flat
      // writer refuses to emit such a pNGf (src/cli/flat.zig), so this fires only
      // on a hostile/corrupt payload — throw loud instead of playing garbage. In a
      // frame the throw is caught and delivered to opts.onError (miniPngine); during
      // init/first-frame it rejects the miniPngine promise.
      default: throw new Error(`pngine/mini: opcode ${o} is unsupported by the minimal player — re-export without --flat (the viewer runtime plays every command)`);
    }
  }
}

/**
 * Minimal main-thread pNGf player. Setup failures (no WebGPU adapter, no pNGf
 * chunk) reject the returned promise. Runtime failures after it resolves — an
 * undecodable opcode mid-frame, a WebGPU validation error, device loss — are
 * delivered to `opts.onError` (an Error; GPU faults carry name "PngineGPUError"
 * to match the viewer tier). With no onError handler runtime faults are
 * console.error'd. On any runtime fault the animation loop stops rather than
 * spinning on a dead device.
 * @param {HTMLCanvasElement} canvas
 * @param {string|ArrayBuffer|Uint8Array} source
 * @param {{autoplay?: boolean, onError?: (err: Error) => void}} [opts]
 */
export async function miniPngine(canvas, source, opts) {
  const ab = typeof source === 'string'
    ? await (await fetch(source)).arrayBuffer()
    : source instanceof Uint8Array ? source.buffer : source;

  const {au, fl} = await P(ab);
  if (!fl) throw new Error('No pNGf chunk found');

  // The single runtime error surface. Setup errors above throw (rejecting the
  // promise the caller awaits); everything after device acquisition routes here.
  const report = err => {
    const e = err instanceof Error ? err : new Error(String(err));
    if (typeof opts?.onError === 'function') opts.onError(e);
    else console.error('[pngine/mini]', e);
  };
  const gpuError = (message, origin) => {
    const e = /** @type {Error & {source?: string}} */ (new Error(message));
    e.name = 'PngineGPUError';
    e.source = origin;
    return e;
  };

  const adapter = await navigator.gpu?.requestAdapter();
  if (!adapter) throw new Error('pngine/mini: WebGPU unavailable — requestAdapter() returned no adapter');
  const dv = await adapter.requestDevice();
  // Surface WebGPU validation / OOM the way the viewer does; without this a bad
  // draw is silently wrong (WebGPU never throws synchronously for these).
  dv.onuncapturederror = ev => report(gpuError(ev.error.message, 'uncaptured'));

  // Everything from here on can throw, and everything from here on is something
  // that has to be released: the device above, the configured context, the five
  // canvas listeners, every resource the init commands create. `inst` — the only
  // object that used to carry a destroy() — is not built until the very end, so
  // a throw in between rejected this promise with NOTHING able to release any of
  // it: device, context and listeners stayed alive for the page's life. The
  // worker tier documents this exact class and fixes it (init-core.js: "every
  // failure path TERMINATES the worker before rejecting").
  //
  // So the teardown exists BEFORE the things it releases, and there is only one
  // of it: a setup failure and a host destroy() are the same release, run from
  // the same closure. `dead` makes it idempotent — a second destroy() used to
  // call ax.close() on an already-closed AudioContext (an unhandled rejection)
  // and dv.destroy() twice — and it is also what keeps play() from resurrecting
  // the loop, since WebGPU calls on a destroyed device do not throw
  // synchronously and frame()'s try/catch would never have fired.
  let on = 0, t0 = 0, tm = 0, raf = 0, dead = 0;
  let ax, ab2, sr, ctx;
  const teardown = () => {
    if (dead) return; dead = 1;
    on = 0; cancelAnimationFrame(raf);
    if (AUDIO && sr) { try { sr.stop(); } catch(_){} sr = null; }
    if (AUDIO && ax && ax.state !== 'closed') ax.close();
    // Nulling the five on* handlers is the mini tier's whole listener story:
    // they are properties, not addEventListener registrations, and each closes
    // over the canvas. Leaving them set kept the canvas and this instance's
    // pointer state alive for as long as the host held the element.
    canvas.onpointerdown = canvas.onpointermove = canvas.onpointerup = canvas.onpointercancel = canvas.onwheel = null;
    dv.onuncapturederror = null;
    ctx?.unconfigure?.();
    dv.destroy();
  };

  try {
    ctx = /** @type {GPUCanvasContext} */ (canvas.getContext('webgpu'));
    const fm = navigator.gpu.getPreferredCanvasFormat();
    // pNGf flags bit 0 = opaque canvas (mirrors the PNGB header flag; spec/04).
    ctx.configure({device: dv, format: fm, alphaMode: fl[1] & 1 ? 'opaque' : 'premultiplied'});

    const W = canvas.width, H = canvas.height;
    const V = new DataView(fl.buffer, fl.byteOffset, fl.byteLength);
    const il = V.getUint32(2, true), frl = V.getUint32(6, true);
    const ds = 14 + il + frl;
    const bf = [], sh = [], pp = [], cp_ = [], bg = [];

    // Pointer/wheel listeners fill this instance's 12 pointer-inputs floats.
    // Per-instance, not module-level: see the layout note above X().
    // Modifier bits 1/2/4/8 (shift/ctrl/alt/meta) mirror init-core.js; the Space
    // bit (16) is omitted — the minimal viewer attaches no document keyboard
    // listeners. Scroll (9/10) accumulates sign(delta) like init-core.
    const pt = new Float32Array(12);
    let lx=0,ly=0;
    const M=e=>(e.shiftKey?1:0)|(e.ctrlKey?2:0)|(e.altKey?4:0)|(e.metaKey?8:0);
    canvas.onpointerdown=e=>{const r=canvas.getBoundingClientRect(),x=(e.clientX-r.left)/r.width,y=(e.clientY-r.top)/r.height;pt[0]=pt[2]=x;pt[1]=pt[3]=y;pt[6]=e.buttons;pt[7]=e.pressure||.5;pt[8]=M(e);lx=x;ly=y;canvas.setPointerCapture(e.pointerId)};
    canvas.onpointermove=e=>{const r=canvas.getBoundingClientRect(),x=Math.max(0,Math.min(1,(e.clientX-r.left)/r.width)),y=Math.max(0,Math.min(1,(e.clientY-r.top)/r.height));pt[4]=x-lx;pt[5]=y-ly;pt[0]=x;pt[1]=y;pt[6]=e.buttons;pt[7]=e.pressure||(e.buttons?.5:0);pt[8]=M(e);lx=x;ly=y};
    canvas.onpointerup=()=>{pt[2]=-Math.abs(pt[2]);pt[3]=-Math.abs(pt[3]);pt[6]=0;pt[7]=0};
    canvas.onpointercancel=canvas.onpointerup;
    canvas.onwheel=e=>{e.preventDefault();pt[9]+=Math.sign(e.deltaX);pt[10]+=Math.sign(e.deltaY);pt[8]=M(e)};

    // The bind-group rebuild cache and the time-uniform staging array: per
    // instance, and threaded into every X() call so they survive between them.
    const bd = [], ti = new Float32Array(4);

    // Run init commands
    X(fl, ds, 14, il, V, dv, ctx, fm, bf, sh, pp, cp_, bg, 0, W, H, pt, bd, ti);
    // Run first frame
    X(fl, ds, 14 + il, frl, V, dv, ctx, fm, bf, sh, pp, cp_, bg, 0, W, H, pt, bd, ti);

    // Device loss stops the loop and reports once. `destroyed` is our own destroy()
    // teardown — ignore it, and so is anything arriving after `dead` (a device can
    // be lost for another reason in the same turn we tear it down). mini keeps no
    // self-recovery (size play); the host decides whether to re-create the player.
    dv.lost.then(info => {
      if (dead || info.reason === 'destroyed') return;
      on = 0; cancelAnimationFrame(raf);
      report(gpuError('pngine/mini: WebGPU device lost — ' + (info.message || info.reason || 'unknown'), 'device-lost'));
    });

    if (AUDIO && au) {
      const {instance: ai} = await WebAssembly.instantiate(/** @type {BufferSource} */ (/** @type {unknown} */ (au)), /** @type {WebAssembly.Imports} */ (/** @type {unknown} */ ({m: Math})));
      const ax2 = /** @type {SointuExports} */ (/** @type {unknown} */ (ai.exports));
      const m = ax2.m, s = ax2.s.value, l = ax2.l.value, t = ax2.t.value === 1;
      const fr = t ? l / 4 : l / 8;
      const smp = t ? new Int16Array(m.buffer, s, fr * 2) : new Float32Array(m.buffer, s, fr * 2);
      ax = new AudioContext({sampleRate: 44100});
      ab2 = ax.createBuffer(2, fr, 44100);
      deinterleaveStereo(ab2, smp, fr, t);
    }

    function frame() {
      if (!on) return;
      tm = (performance.now() - t0) / 1e3;
      // A runtime fault (undecodable opcode, lost device) stops the loop and
      // reports, instead of throwing uncaught out of rAF on every frame.
      try {
        X(fl, ds, 14 + il, frl, V, dv, ctx, fm, bf, sh, pp, cp_, bg, tm, W, H, pt, bd, ti);
      } catch (err) {
        on = 0; cancelAnimationFrame(raf);
        report(err);
        return;
      }
      pt[4] = 0; pt[5] = 0; // reset pointer deltas per frame
      raf = requestAnimationFrame(frame);
    }

    const inst = {
      // `dead` and not just `on`: destroy() left no flag, so play() — which
      // checked only `if (on) return` — restarted the rAF chain on a destroyed
      // device. Nothing threw (WebGPU is asynchronous about that), so the loop
      // reschedules at 60Hz for the page's life, retaining the canvas, the payload
      // and every closure in this function.
      play() {
        if (on || dead) return;
        on = 1; t0 = performance.now() - tm * 1e3;
        if (AUDIO && ax) { if (ax.state === 'suspended') ax.resume(); sr = ax.createBufferSource(); sr.buffer = ab2; sr.connect(ax.destination); sr.start(0, tm); }
        frame();
      },
      pause() { on = 0; cancelAnimationFrame(raf); if (AUDIO && sr) { try { sr.stop(); } catch(_){} sr = null; } },
      stop() { on = 0; tm = 0; cancelAnimationFrame(raf); if (AUDIO && sr) { try { sr.stop(); } catch(_){} sr = null; } },
      destroy: teardown,
      get time() { return tm; },
      get isPlaying() { return !!on; }
    };
    if (opts?.autoplay) inst.play();
    return inst;
  } catch (err) { teardown(); throw err; }
}
