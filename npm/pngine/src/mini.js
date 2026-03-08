// PNGine Mini Viewer - flat pNGf only, no WASM executor
// Main thread, no Worker, no OffscreenCanvas

async function P(ab) {
  const b = new Uint8Array(ab);
  let p = 8, au, fl;
  while (p + 12 <= b.length) {
    const l = (b[p] << 24 | b[p+1] << 16 | b[p+2] << 8 | b[p+3]) >>> 0;
    const t = b[p+7];
    if (b[p+4] === 0x70 && b[p+5] === 0x4E && b[p+6] === 0x47) {
      const d = b.subarray(p+8, p+8+l);
      if (AUDIO && t === 97) au = await D(d);
      else if (t === 102) fl = await D(d);
    }
    p += 12 + l;
  }
  return { au, fl };
}

async function D(d) {
  const p = d.subarray(2);
  if (!(d[1] & 1)) return new Uint8Array(p);
  const s = new DecompressionStream('deflate-raw');
  const w = s.writable.getWriter();
  const r = s.readable.getReader();
  w.write(p); w.close();
  const c = []; let n = 0;
  for (;;) { const {done, value} = await r.read(); if (done) break; c.push(value); n += value.length; }
  const o = new Uint8Array(n); let i = 0;
  for (const k of c) { o.set(k, i); i += k.length; }
  return o;
}

function X(d, ds, p, e, V, dv, ctx, fm, bf, sh, pp, cp, bg, sm, tv, tm, W, H) {
  const R=o=>V.getUint16(o,!0),G=o=>V.getUint32(o,!0);
  const rs = (o, l) => new TextDecoder().decode(d.subarray(ds + o, ds + o + l));
  e = p + e; let ps, en;
  while (p < e) {
    const o = d[p++];
    switch (o) {
      case 1: {
        const id = R(p), sz = G(p+2), u = d[p+6];
        let f = 0; if (u & 8) f |= 8; if (u & 0x20) f |= 32; if (u & 0x40) f |= 64; if (u & 0x80) f |= 128;
        bf[id] = dv.createBuffer({size: sz, usage: f}); p += 7; break;
      }
      case 4: sh[R(p)] = dv.createShaderModule({code: rs(G(p+2), G(p+6))}); p += 10; break;
      case 5: {
        const id = R(p), dd = JSON.parse(rs(G(p+2), G(p+6)));
        pp[id] = dv.createRenderPipeline({layout:'auto', vertex:{module:sh[dd.vertex?.shader??0],entryPoint:dd.vertex?.entryPoint??'vs',buffers:dd.vertex?.buffers??[]}, fragment:{module:sh[dd.fragment?.shader??0],entryPoint:dd.fragment?.entryPoint??'fs',targets:[{format:fm}]}, primitive:dd.primitive??{topology:'triangle-list'}});
        p += 10; break;
      }
      case 6: {
        const id = R(p), dd = JSON.parse(rs(G(p+2), G(p+6)));
        cp[id] = dv.createComputePipeline({layout:'auto', compute:{module:sh[dd.compute?.shader??0],entryPoint:dd.compute?.entryPoint??'main'}});
        p += 10; break;
      }
      case 7: {
        const id = R(p), pl = R(p+2), dp = G(p+4), dl = G(p+8);
        const b = d.subarray(ds + dp, ds + dp + dl), bv = new DataView(b.buffer, b.byteOffset, b.byteLength);
        let q = 2, gi = 0; const es = [];
        for (let k = 0; k < b[1]; k++) {
          const fi = b[q++], vt = b[q++];
          if (fi === 1 && vt === 7) gi = b[q++];
          else if (fi === 2 && vt === 3) { let ec = b[q++]; while (ec--) { const bi = b[q++], rt = b[q++], ri = bv.getUint16(q, true); q += 2; if (rt === 0) { es.push({binding:bi,resource:{buffer:bf[ri]}}); q += 8; } else if (rt === 2) es.push({binding:bi,resource:sm[ri]}); else if (rt === 3) es.push({binding:bi,resource:tv[ri].createView()}); } }
        }
        bg[id] = dv.createBindGroup({layout:(pp[pl]||cp[pl]).getBindGroupLayout(gi),entries:es}); p += 12; break;
      }
      case 16: en = dv.createCommandEncoder(); ps = en.beginRenderPass({colorAttachments:[{view:ctx.getCurrentTexture().createView(),loadOp:'clear',storeOp:'store',clearValue:[0,0,0,1]}]}); p += 6; break;
      case 17: if (!en) en = dv.createCommandEncoder(); ps = en.beginComputePass(); break;
      case 18: { const pid = R(p); ps.setPipeline(pp[pid]||cp[pid]); p += 2; break; }
      case 19: ps.setBindGroup(d[p], bg[R(p+1)]); p += 3; break;
      case 20: ps.setVertexBuffer(d[p], bf[R(p+1)]); p += 3; break;
      case 21: ps.draw(G(p), G(p+4)); p += 16; break;
      case 22: ps.drawIndexed(G(p), G(p+4)); p += 20; break;
      case 23: ps.end(); ps = null; break;
      case 24: ps.dispatchWorkgroups(G(p), G(p+4), G(p+8)); p += 12; break;
      case 33: dv.queue.writeBuffer(bf[R(p)], 0, new Float32Array([tm, W, H, W/H])); p += 8; break;
      case 240: if (en) { dv.queue.submit([en.finish()]); en = null; } break;
      case 255: return;
    }
  }
}

export async function miniPngine(canvas, source, opts) {
  const ab = typeof source === 'string'
    ? await (await fetch(source)).arrayBuffer()
    : source instanceof Uint8Array ? source.buffer : source;

  const {au, fl} = await P(ab);
  if (!fl) throw new Error('No pNGf chunk found');

  const dv = (await (await navigator.gpu.requestAdapter()).requestDevice());
  const ctx = canvas.getContext('webgpu');
  const fm = navigator.gpu.getPreferredCanvasFormat();
  ctx.configure({device: dv, format: fm, alphaMode: 'premultiplied'});

  const W = canvas.width, H = canvas.height;
  const V = new DataView(fl.buffer, fl.byteOffset, fl.byteLength);
  const il = V.getUint32(2, true), frl = V.getUint32(6, true);
  const ds = 14 + il + frl;
  const bf = [], sh = [], pp = [], cp_ = [], bg = [], sm = [], tv = [];

  // Run init commands
  X(fl, ds, 14, il, V, dv, ctx, fm, bf, sh, pp, cp_, bg, sm, tv, 0, W, H);
  // Run first frame
  X(fl, ds, 14 + il, frl, V, dv, ctx, fm, bf, sh, pp, cp_, bg, sm, tv, 0, W, H);

  let on = 0, t0 = 0, tm = 0, raf = 0;
  let ax, ab2, sr;

  if (AUDIO && au) {
    const {instance: ai} = await WebAssembly.instantiate(au, {m: Math});
    const m = ai.exports.m, s = ai.exports.s.value, l = ai.exports.l.value, t = ai.exports.t.value === 1;
    const fr = t ? l / 4 : l / 8;
    const smp = t ? new Int16Array(m.buffer, s, fr * 2) : new Float32Array(m.buffer, s, fr * 2);
    ax = new AudioContext({sampleRate: 44100});
    ab2 = ax.createBuffer(2, fr, 44100);
    for (let c = 0; c < 2; c++) { const d = ab2.getChannelData(c); for (let i = 0; i < fr; i++) d[i] = t ? smp[i*2+c] / 32768 : smp[i*2+c]; }
  }

  function frame() {
    if (!on) return;
    tm = (performance.now() - t0) / 1e3;
    X(fl, ds, 14 + il, frl, V, dv, ctx, fm, bf, sh, pp, cp_, bg, sm, tv, tm, W, H);
    raf = requestAnimationFrame(frame);
  }

  const inst = {
    play() {
      if (on) return;
      on = 1; t0 = performance.now() - tm * 1e3;
      if (AUDIO && ax) { if (ax.state === 'suspended') ax.resume(); sr = ax.createBufferSource(); sr.buffer = ab2; sr.connect(ax.destination); sr.start(0, tm); }
      frame();
    },
    pause() { on = 0; cancelAnimationFrame(raf); if (AUDIO && sr) { try { sr.stop(); } catch(_){} sr = null; } },
    stop() { on = 0; tm = 0; cancelAnimationFrame(raf); if (AUDIO && sr) { try { sr.stop(); } catch(_){} sr = null; } },
    destroy() { on = 0; cancelAnimationFrame(raf); if (AUDIO && sr) try { sr.stop(); } catch(_){} if (AUDIO && ax) ax.close(); dv.destroy(); },
    get time() { return tm; },
    get isPlaying() { return !!on; }
  };
  if (opts?.autoplay) inst.play();
  return inst;
}
