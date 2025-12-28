/**
 * Minification-friendly GPU Command Dispatcher
 *
 * Key changes from class-based approach:
 * 1. Closure pattern - all internal vars/functions become minifiable
 * 2. No CMD object - inline numeric constants
 * 3. Arrays instead of Maps for resource tables (IDs are numeric)
 * 4. Debug code behind build flag (stripped by esbuild --define:DEBUG=false)
 * 5. Short internal names (but readable - minifier handles the rest)
 */

// Build flag - esbuild eliminates dead code with: --define:DEBUG=false
// For dev: keep as true; for prod: esbuild replaces at build time
const DEBUG = true;

// Usage flags (must match opcodes.zig)
const U_COPY_DST = 0x08, U_INDEX = 0x10, U_VERTEX = 0x20, U_UNIFORM = 0x40, U_STORAGE = 0x80;

/**
 * Create a command dispatcher.
 * Returns object with only public methods - everything else is minifiable.
 */
export function createCommandDispatcher(device, ctx) {
  // State - all minifiable
  let mem = null;
  let time = 0;
  let cw = 0, ch = 0;  // canvas width/height
  let enc = null;      // command encoder
  let pass = null;     // current pass
  let dbg = false;     // debug flag

  // Resource tables - arrays indexed by ID (more minifiable than Maps)
  const buf = [];      // buffers
  const tex = [];      // textures
  const txv = [];      // texture views
  const smp = [];      // samplers
  const shd = [];      // shaders
  const pip = [];      // pipelines
  const bg = [];       // bind groups
  const bgl = [];      // bind group layouts
  const ppl = [];      // pipeline layouts
  const bmp = [];      // image bitmaps
  const wm = [];       // wasm modules
  const wcr = [];      // wasm call results
  const bgd = [];      // bind group descriptors (for recreation)
  const txd = [];      // texture descriptors

  // Helper: read string from WASM memory
  function rs(ptr, len) {
    return new TextDecoder().decode(new Uint8Array(mem.buffer, ptr, len));
  }

  // Helper: translate buffer usage flags
  function tu(u) {
    let r = 0;
    if (u & 0x01) r |= GPUBufferUsage.MAP_READ;
    if (u & 0x02) r |= GPUBufferUsage.MAP_WRITE;
    if (u & 0x04) r |= GPUBufferUsage.COPY_SRC;
    if (u & U_COPY_DST) r |= GPUBufferUsage.COPY_DST;
    if (u & U_INDEX) r |= GPUBufferUsage.INDEX;
    if (u & U_VERTEX) r |= GPUBufferUsage.VERTEX;
    if (u & U_UNIFORM) r |= GPUBufferUsage.UNIFORM;
    if (u & U_STORAGE) r |= GPUBufferUsage.STORAGE;
    return r || GPUBufferUsage.COPY_DST;
  }

  // Decode texture format enum
  function dtf(v) {
    const f = {
      0x00: "rgba8unorm", 0x01: "rgba8snorm", 0x04: "bgra8unorm",
      0x05: "rgba16float", 0x06: "rgba32float",
      0x10: "depth24plus", 0x11: "depth24plus-stencil8", 0x12: "depth32float",
    };
    return f[v] || navigator.gpu.getPreferredCanvasFormat();
  }

  // Decode texture usage flags
  function dtu(v) {
    let u = 0;
    if (v & 0x01) u |= GPUTextureUsage.COPY_SRC;
    if (v & 0x02) u |= GPUTextureUsage.COPY_DST;
    if (v & 0x04) u |= GPUTextureUsage.TEXTURE_BINDING;
    if (v & 0x08) u |= GPUTextureUsage.STORAGE_BINDING;
    if (v & 0x10) u |= GPUTextureUsage.RENDER_ATTACHMENT;
    return u || GPUTextureUsage.RENDER_ATTACHMENT;
  }

  // Command handlers - all minifiable function names
  function createBuffer(id, size, usage) {
    if (buf[id]) return;
    DEBUG && dbg && console.log(`[GPU] createBuffer(${id}, ${size}, 0x${usage.toString(16)})`);
    buf[id] = device.createBuffer({ size, usage: tu(usage) });
  }

  function createShader(id, ptr, len) {
    if (shd[id]) return;
    const code = rs(ptr, len);
    DEBUG && dbg && console.log(`[GPU] createShader(${id}, ${len}b)`);
    shd[id] = device.createShaderModule({ code });
  }

  function createRenderPipeline(id, ptr, len) {
    if (pip[id]) return;
    const desc = JSON.parse(rs(ptr, len));
    const fmt = navigator.gpu.getPreferredCanvasFormat();
    DEBUG && dbg && console.log(`[GPU] createRenderPipeline(${id})`);
    const p = device.createRenderPipeline({
      layout: "auto",
      vertex: {
        module: shd[desc.vertex?.shader ?? 0],
        entryPoint: desc.vertex?.entryPoint ?? "vs_main",
        buffers: desc.vertex?.buffers ?? [],
      },
      fragment: {
        module: shd[desc.fragment?.shader ?? desc.vertex?.shader ?? 0],
        entryPoint: desc.fragment?.entryPoint ?? "fs_main",
        targets: [{ format: fmt }],
      },
      primitive: desc.primitive ?? { topology: "triangle-list" },
      depthStencil: desc.depthStencil,
    });
    pip[id] = p;
    bgl[id] = p.getBindGroupLayout(0);
  }

  function createComputePipeline(id, ptr, len) {
    if (pip[id]) return;
    const desc = JSON.parse(rs(ptr, len));
    const p = device.createComputePipeline({
      layout: "auto",
      compute: {
        module: shd[desc.compute?.shader ?? 0],
        entryPoint: desc.compute?.entryPoint ?? "main",
      },
    });
    pip[id] = p;
    bgl[id] = p.getBindGroupLayout(0);
  }

  function createTexture(id, ptr, len) {
    if (tex[id]) return;
    const bytes = new Uint8Array(mem.buffer, ptr, len);
    const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    let off = 2; // skip type tag + field count
    const desc = { size: [cw || 512, ch || 512], format: navigator.gpu.getPreferredCanvasFormat(), usage: GPUTextureUsage.RENDER_ATTACHMENT, sampleCount: 1 };
    const fc = bytes[1];
    for (let i = 0; i < fc; i++) {
      const fid = bytes[off++], vt = bytes[off++];
      if (vt === 0x00) { // u32
        const val = v.getUint32(off, true); off += 4;
        if (fid === 0x01) desc.size[0] = val;
        else if (fid === 0x02) desc.size[1] = val;
        else if (fid === 0x05) desc.sampleCount = val;
      } else if (vt === 0x07) { // enum
        const val = bytes[off++];
        if (fid === 0x07) desc.format = dtf(val);
        else if (fid === 0x08) desc.usage = dtu(val);
      }
    }
    txd[id] = { format: desc.format, usage: desc.usage };
    tex[id] = device.createTexture(desc);
  }

  function createSampler(id, ptr, len) {
    if (smp[id]) return;
    const bytes = new Uint8Array(mem.buffer, ptr, len);
    let off = 2;
    const desc = { magFilter: "linear", minFilter: "linear", addressModeU: "clamp-to-edge", addressModeV: "clamp-to-edge" };
    const fc = bytes[1];
    for (let i = 0; i < fc; i++) {
      const fid = bytes[off++], vt = bytes[off++];
      if (vt === 0x07) {
        const val = bytes[off++];
        if (fid === 0x04) desc.magFilter = val === 0 ? "nearest" : "linear";
        else if (fid === 0x05) desc.minFilter = val === 0 ? "nearest" : "linear";
        else if (fid === 0x01) desc.addressModeU = ["clamp-to-edge", "repeat", "mirror-repeat"][val];
        else if (fid === 0x02) desc.addressModeV = ["clamp-to-edge", "repeat", "mirror-repeat"][val];
      }
    }
    smp[id] = device.createSampler(desc);
  }

  function createBindGroup(id, layoutId, ptr, len) {
    if (bg[id]) return;
    const bytes = new Uint8Array(mem.buffer, ptr, len);
    const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    let off = 2, gi = 0;
    const entries = [];
    const fc = bytes[1];
    for (let i = 0; i < fc; i++) {
      const fid = bytes[off++], vt = bytes[off++];
      if (fid === 0x01 && vt === 0x07) gi = bytes[off++];
      else if (fid === 0x02 && vt === 0x03) {
        const ec = bytes[off++];
        for (let j = 0; j < ec; j++) {
          const binding = bytes[off++], rt = bytes[off++], rid = v.getUint16(off, true); off += 2;
          const e = { binding, rt, rid };
          if (rt === 0) { e.offset = v.getUint32(off, true); off += 4; e.size = v.getUint32(off, true); off += 4; }
          entries.push(e);
        }
      }
    }
    bgd[id] = { layoutId, gi, entries };
    const p = pip[layoutId];
    if (!p) return;
    const ge = entries.map(e => {
      const entry = { binding: e.binding };
      if (e.rt === 0) { entry.resource = { buffer: buf[e.rid] }; if (e.offset) entry.resource.offset = e.offset; if (e.size) entry.resource.size = e.size; }
      else if (e.rt === 1) entry.resource = tex[e.rid]?.createView();
      else if (e.rt === 2) entry.resource = smp[e.rid];
      return entry;
    });
    bg[id] = device.createBindGroup({ layout: p.getBindGroupLayout(gi), entries: ge });
  }

  function beginRenderPass(colorId, loadOp, storeOp, depthId) {
    if (!enc) enc = device.createCommandEncoder();
    const CANVAS = 0xfffe;
    const cv = colorId === CANVAS ? ctx.getCurrentTexture().createView() : tex[colorId]?.createView();
    const pd = { colorAttachments: [{ view: cv, loadOp: loadOp === 1 ? "clear" : "load", storeOp: storeOp === 0 ? "store" : "discard", clearValue: { r: 0, g: 0, b: 0, a: 1 } }] };
    if (depthId !== 0xffff && tex[depthId]) {
      pd.depthStencilAttachment = { view: tex[depthId].createView(), depthLoadOp: "clear", depthStoreOp: "store", depthClearValue: 1.0 };
    }
    pass = enc.beginRenderPass(pd);
  }

  function beginComputePass() {
    if (!enc) enc = device.createCommandEncoder();
    pass = enc.beginComputePass();
  }

  // Main dispatch - inline command constants for minification
  function dispatch(cmd, view, pos) {
    switch (cmd) {
      case 0x01: { // CREATE_BUFFER
        createBuffer(view.getUint16(pos, true), view.getUint32(pos + 2, true), view.getUint8(pos + 6));
        return pos + 7;
      }
      case 0x02: { // CREATE_TEXTURE
        createTexture(view.getUint16(pos, true), view.getUint32(pos + 2, true), view.getUint32(pos + 6, true));
        return pos + 10;
      }
      case 0x03: { // CREATE_SAMPLER
        createSampler(view.getUint16(pos, true), view.getUint32(pos + 2, true), view.getUint32(pos + 6, true));
        return pos + 10;
      }
      case 0x04: { // CREATE_SHADER
        createShader(view.getUint16(pos, true), view.getUint32(pos + 2, true), view.getUint32(pos + 6, true));
        return pos + 10;
      }
      case 0x05: { // CREATE_RENDER_PIPELINE
        createRenderPipeline(view.getUint16(pos, true), view.getUint32(pos + 2, true), view.getUint32(pos + 6, true));
        return pos + 10;
      }
      case 0x06: { // CREATE_COMPUTE_PIPELINE
        createComputePipeline(view.getUint16(pos, true), view.getUint32(pos + 2, true), view.getUint32(pos + 6, true));
        return pos + 10;
      }
      case 0x07: { // CREATE_BIND_GROUP
        createBindGroup(view.getUint16(pos, true), view.getUint16(pos + 2, true), view.getUint32(pos + 4, true), view.getUint32(pos + 8, true));
        return pos + 12;
      }
      case 0x10: { // BEGIN_RENDER_PASS
        beginRenderPass(view.getUint16(pos, true), view.getUint8(pos + 2), view.getUint8(pos + 3), view.getUint16(pos + 4, true));
        return pos + 6;
      }
      case 0x11: { // BEGIN_COMPUTE_PASS
        beginComputePass();
        return pos;
      }
      case 0x12: { // SET_PIPELINE
        pass?.setPipeline(pip[view.getUint16(pos, true)]);
        return pos + 2;
      }
      case 0x13: { // SET_BIND_GROUP
        pass?.setBindGroup(view.getUint8(pos), bg[view.getUint16(pos + 1, true)]);
        return pos + 3;
      }
      case 0x14: { // SET_VERTEX_BUFFER
        pass?.setVertexBuffer(view.getUint8(pos), buf[view.getUint16(pos + 1, true)]);
        return pos + 3;
      }
      case 0x15: { // DRAW
        pass?.draw(view.getUint32(pos, true), view.getUint32(pos + 4, true), view.getUint32(pos + 8, true), view.getUint32(pos + 12, true));
        return pos + 16;
      }
      case 0x16: { // DRAW_INDEXED
        pass?.drawIndexed(view.getUint32(pos, true), view.getUint32(pos + 4, true), view.getUint32(pos + 8, true), view.getInt32(pos + 12, true), view.getUint32(pos + 16, true));
        return pos + 20;
      }
      case 0x17: { // END_PASS
        pass?.end();
        pass = null;
        return pos;
      }
      case 0x18: { // DISPATCH
        pass?.dispatchWorkgroups(view.getUint32(pos, true), view.getUint32(pos + 4, true), view.getUint32(pos + 8, true));
        return pos + 12;
      }
      case 0x19: { // SET_INDEX_BUFFER
        pass?.setIndexBuffer(buf[view.getUint16(pos, true)], view.getUint8(pos + 2) === 1 ? "uint32" : "uint16");
        return pos + 3;
      }
      case 0x20: { // WRITE_BUFFER
        const id = view.getUint16(pos, true), offset = view.getUint32(pos + 2, true);
        const dataPtr = view.getUint32(pos + 6, true), dataLen = view.getUint32(pos + 10, true);
        if (buf[id]) device.queue.writeBuffer(buf[id], offset, new Uint8Array(mem.buffer, dataPtr, dataLen));
        return pos + 14;
      }
      case 0x21: { // WRITE_TIME_UNIFORM
        const id = view.getUint16(pos, true), offset = view.getUint32(pos + 2, true), size = view.getUint16(pos + 6, true);
        if (buf[id]) {
          const data = new Float32Array([time, cw, ch, cw / (ch || 1)]);
          device.queue.writeBuffer(buf[id], offset, new Uint8Array(data.buffer, 0, Math.min(size, 16)));
        }
        return pos + 8;
      }
      case 0x08: { // CREATE_TEXTURE_VIEW
        const id = view.getUint16(pos, true), tid = view.getUint16(pos + 2, true);
        if (!txv[id] && tex[tid]) txv[id] = tex[tid].createView();
        return pos + 12;
      }
      case 0x09: { // CREATE_QUERY_SET (stub)
        return pos + 10;
      }
      case 0x0a: { // CREATE_BIND_GROUP_LAYOUT
        const id = view.getUint16(pos, true), ptr = view.getUint32(pos + 2, true), len = view.getUint32(pos + 6, true);
        if (!bgl[id]) bgl[id] = device.createBindGroupLayout(JSON.parse(rs(ptr, len)));
        return pos + 10;
      }
      case 0x0b: { // CREATE_IMAGE_BITMAP (async)
        const id = view.getUint16(pos, true), ptr = view.getUint32(pos + 2, true), len = view.getUint32(pos + 6, true);
        const blob = new Blob([new Uint8Array(mem.buffer, ptr, len)]);
        return createImageBitmap(blob).then(b => { bmp[id] = b; return pos + 10; });
      }
      case 0x0c: { // CREATE_PIPELINE_LAYOUT
        const id = view.getUint16(pos, true), ptr = view.getUint32(pos + 2, true), len = view.getUint32(pos + 6, true);
        const desc = JSON.parse(rs(ptr, len));
        ppl[id] = device.createPipelineLayout({ bindGroupLayouts: desc.bindGroupLayouts.map(i => bgl[i]) });
        return pos + 10;
      }
      case 0x0d: { // CREATE_RENDER_BUNDLE (stub)
        return pos + 10;
      }
      case 0x1a: { // EXECUTE_BUNDLES
        const count = view.getUint8(pos);
        return pos + 1 + count * 2;
      }
      case 0x22: { // COPY_BUFFER_TO_BUFFER
        const sid = view.getUint16(pos, true), so = view.getUint32(pos + 2, true);
        const did = view.getUint16(pos + 6, true), dof = view.getUint32(pos + 8, true);
        const sz = view.getUint32(pos + 12, true);
        if (!enc) enc = device.createCommandEncoder();
        enc.copyBufferToBuffer(buf[sid], so, buf[did], dof, sz);
        return pos + 16;
      }
      case 0x23: { // COPY_TEXTURE_TO_TEXTURE
        const sid = view.getUint16(pos, true), did = view.getUint16(pos + 2, true);
        const w = view.getUint16(pos + 4, true), h = view.getUint16(pos + 6, true);
        if (!enc) enc = device.createCommandEncoder();
        enc.copyTextureToTexture({ texture: tex[sid] }, { texture: tex[did] }, [w, h]);
        return pos + 8;
      }
      case 0x24: { // WRITE_BUFFER_FROM_WASM
        const bid = view.getUint16(pos, true), off = view.getUint32(pos + 2, true);
        const ptr = view.getUint32(pos + 6, true), sz = view.getUint32(pos + 10, true);
        if (buf[bid]) device.queue.writeBuffer(buf[bid], off, new Uint8Array(mem.buffer, ptr, sz));
        return pos + 14;
      }
      case 0x25: { // COPY_EXTERNAL_IMAGE_TO_TEXTURE (async)
        const bid = view.getUint16(pos, true), tid = view.getUint16(pos + 2, true);
        const mip = view.getUint8(pos + 4), ox = view.getUint16(pos + 5, true), oy = view.getUint16(pos + 7, true);
        const b = bmp[bid];
        if (b && tex[tid]) {
          device.queue.copyExternalImageToTexture({ source: b }, { texture: tex[tid], mipLevel: mip, origin: [ox, oy] }, [b.width, b.height]);
        }
        return pos + 9;
      }
      case 0x30: { // INIT_WASM_MODULE (async)
        const id = view.getUint16(pos, true), ptr = view.getUint32(pos + 2, true), len = view.getUint32(pos + 6, true);
        const bytes = new Uint8Array(mem.buffer, ptr, len).slice();
        return WebAssembly.compile(bytes).then(mod =>
          WebAssembly.instantiate(mod, {}).then(inst => { wm[id] = inst; return pos + 10; })
        );
      }
      case 0x31: { // CALL_WASM_FUNC (async)
        const cid = view.getUint16(pos, true), mid = view.getUint16(pos + 2, true);
        const np = view.getUint32(pos + 4, true), nl = view.getUint32(pos + 8, true);
        const ac = view.getUint8(pos + 12);
        const ab = new Uint8Array(mem.buffer, pos + 13, ac).slice();
        const name = rs(np, nl);
        const inst = wm[mid];
        const fn = inst?.exports[name];
        const args = [];
        const av = new DataView(ab.buffer, ab.byteOffset, ab.byteLength);
        for (let i = 0, o = 0; i < (ac / 5) | 0; i++) {
          const t = ab[o++];
          if (t === 0) args.push(av.getFloat32(o, true));
          else if (t === 1) args.push(av.getInt32(o, true));
          else if (t === 2) args.push(av.getUint32(o, true));
          o += 4;
        }
        if (fn) wcr[cid] = fn(...args);
        return pos + 13 + ac;
      }
      case 0xf0: { // SUBMIT
        if (enc) { device.queue.submit([enc.finish()]); enc = null; }
        return pos;
      }
      case 0xff: // END
        return pos;
      default:
        DEBUG && console.warn(`Unknown cmd: 0x${cmd.toString(16)}`);
        return pos;
    }
  }

  // Execute command buffer
  async function execute(ptr) {
    let view = new DataView(mem.buffer);
    const totalLen = view.getUint32(ptr, true);
    const cmdCount = view.getUint16(ptr + 4, true);
    DEBUG && dbg && console.log(`[GPU] Execute: ${cmdCount} cmds, ${totalLen}b`);

    let pos = ptr + 8;
    const end = ptr + totalLen;
    for (let i = 0; i < cmdCount && pos < end; i++) {
      const cmd = view.getUint8(pos++);
      const result = dispatch(cmd, view, pos);
      if (result instanceof Promise) {
        pos = await result;
        view = new DataView(mem.buffer);
      } else {
        pos = result;
      }
    }
  }

  // Destroy resources
  function destroy() {
    buf.forEach(b => b?.destroy?.());
    tex.forEach(t => t?.destroy?.());
    buf.length = tex.length = txv.length = smp.length = shd.length = pip.length = 0;
    bg.length = bgl.length = ppl.length = bmp.length = wm.length = 0;
    wcr.length = bgd.length = txd.length = 0;
  }

  // Return public interface only - these names stay, everything else minifies
  return {
    setDebug(v) { dbg = v; },
    setMemory(m) { mem = m; },
    setTime(t) { time = t; },
    setCanvasSize(w, h) { cw = w; ch = h; },
    execute,
    destroy,
  };
}

// Compatibility alias
export const CommandDispatcher = {
  create: createCommandDispatcher,
};
