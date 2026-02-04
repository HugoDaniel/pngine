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

// UniformType enum values (must match uniform_table.zig)
const UT_F32 = 0, UT_I32 = 1, UT_U32 = 2;
const UT_VEC2F = 3, UT_VEC3F = 4, UT_VEC4F = 5;
const UT_MAT3X3F = 6, UT_MAT4X4F = 7;
const UT_VEC2I = 8, UT_VEC3I = 9, UT_VEC4I = 10;
const UT_VEC2U = 11, UT_VEC3U = 12, UT_VEC4U = 13;

// PNGB header constants (must match format.zig)
const PNGB_HEADER_SIZE = 40;
const PNGB_MAGIC = 0x42474e50; // "PNGB" little-endian

/**
 * Parse uniform table from PNGB bytecode.
 * Returns: { uniforms: Map<string, {bufferId, offset, size, type}>, strings: string[] }
 */
export function parseUniformTable(bytecode) {
  const view = new DataView(bytecode.buffer, bytecode.byteOffset, bytecode.byteLength);

  // Validate PNGB magic
  if (view.getUint32(0, true) !== PNGB_MAGIC) {
    return { uniforms: new Map(), strings: [] };
  }

  // Read header offsets
  const stringTableOffset = view.getUint32(20, true);
  const uniformTableOffset = view.getUint32(32, true);

  // Parse string table first
  const strings = parseStringTable(bytecode, stringTableOffset);

  // Parse uniform table
  const uniforms = new Map();
  if (uniformTableOffset === 0 || uniformTableOffset >= bytecode.length) {
    return { uniforms, strings };
  }

  let pos = uniformTableOffset;
  const bindingCount = view.getUint16(pos, true);
  pos += 2;

  for (let b = 0; b < bindingCount && pos + 8 <= bytecode.length; b++) {
    const bufferId = view.getUint16(pos, true);
    pos += 2;
    // Skip name_string_id (u16), group (u8), binding_index (u8)
    pos += 4;
    const fieldCount = view.getUint16(pos, true);
    pos += 2;

    // Parse fields (10 bytes each)
    for (let f = 0; f < fieldCount && pos + 10 <= bytecode.length; f++) {
      // Skip slot (u16)
      pos += 2;
      const nameStringId = view.getUint16(pos, true);
      pos += 2;
      const offset = view.getUint16(pos, true);
      pos += 2;
      const size = view.getUint16(pos, true);
      pos += 2;
      const uniformType = view.getUint8(pos);
      pos += 2; // type + padding

      // Get field name from string table
      const fieldName = strings[nameStringId] || `field_${nameStringId}`;
      uniforms.set(fieldName, { bufferId, offset, size, type: uniformType });
    }
  }

  return { uniforms, strings };
}

/**
 * Parse string table from PNGB bytecode.
 * Format: [count: u16] [offsets: count*u16] [lengths: count*u16] [data: UTF-8]
 */
function parseStringTable(bytecode, offset) {
  if (offset === 0 || offset >= bytecode.length - 2) {
    return [];
  }

  const view = new DataView(bytecode.buffer, bytecode.byteOffset, bytecode.byteLength);
  const decoder = new TextDecoder();
  const strings = [];

  const count = view.getUint16(offset, true);
  if (count === 0) return strings;

  // Calculate positions
  const offsetsStart = offset + 2;
  const lengthsStart = offsetsStart + count * 2;
  const dataStart = lengthsStart + count * 2;

  // Bounds check
  if (dataStart > bytecode.length) return strings;

  for (let i = 0; i < count; i++) {
    const strOffset = view.getUint16(offsetsStart + i * 2, true);
    const strLen = view.getUint16(lengthsStart + i * 2, true);
    const strStart = dataStart + strOffset;

    if (strStart + strLen <= bytecode.length) {
      strings.push(decoder.decode(bytecode.subarray(strStart, strStart + strLen)));
    } else {
      strings.push(`string_${i}`); // Fallback for out-of-bounds
    }
  }

  return strings;
}

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
    if (len === 0) return "";
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
    DEBUG && dbg && console.log(`[GPU] createShader(${id}, ${len}b)`);
    if (len === 0) {
      DEBUG && dbg && console.warn(`[GPU] createShader(${id}) skipped: len=0`);
      return;
    }
    
    // Check for null bytes (corruption debug)
    const bytes = new Uint8Array(mem.buffer, ptr, len);
    for (let i = 0; i < len; i++) {
        if (bytes[i] === 0) {
            console.error(`[GPU] NULL BYTE at offset ${i} in shader ${id}! Context: "${new TextDecoder().decode(bytes.subarray(Math.max(0, i-10), Math.min(len, i+10)))}"`);
        }
    }

    const code = rs(ptr, len);
    DEBUG && dbg && console.log(`[GPU]   code:\n${code}`);
    const module = device.createShaderModule({ code });
    // Check for compilation errors asynchronously
    module.getCompilationInfo().then(info => {
      for (const msg of info.messages) {
        if (msg.type === 'error') {
          console.error(`[GPU] Shader ${id} error at line ${msg.lineNum}:${msg.linePos}: ${msg.message}`);
          console.error(`[GPU] Context: ${code.split('\n').slice(Math.max(0,msg.lineNum-3), msg.lineNum+2).join('\n')}`);
        }
      }
    });
    shd[id] = module;
  }

  function createRenderPipeline(id, ptr, len) {
    if (pip[id]) return;
    if (len === 0) {
      DEBUG && dbg && console.warn(`[GPU] createRenderPipeline(${id}) skipped: len=0`);
      return;
    }
    const desc = JSON.parse(rs(ptr, len));
    const fmt = navigator.gpu.getPreferredCanvasFormat();
    DEBUG && dbg && console.log(`[GPU] createRenderPipeline(${id}) desc=`, JSON.stringify(desc));
    // Use targetFormat if specified, otherwise default to canvas format
    // "preferredCanvasFormat" means use actual preferred format
    let targetFormat = desc.fragment?.targetFormat;
    if (!targetFormat || targetFormat === "preferredCanvasFormat") {
      targetFormat = fmt;
    }
    DEBUG && dbg && console.log(`[GPU]   targetFormat: ${targetFormat}`);
    const targets = [{ format: targetFormat }];
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
        targets,
      },
      primitive: desc.primitive ?? { topology: "triangle-list" },
      depthStencil: desc.depthStencil,
    });
    pip[id] = p;
    bgl[id] = p.getBindGroupLayout(0);
  }

  function createComputePipeline(id, ptr, len) {
    if (pip[id]) return;
    if (len === 0) {
      DEBUG && dbg && console.warn(`[GPU] createComputePipeline(${id}) skipped: len=0`);
      return;
    }
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
    if (len === 0) {
      DEBUG && dbg && console.warn(`[GPU] createTexture(${id}) skipped: len=0`);
      return;
    }
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
    DEBUG && dbg && console.log(`[GPU] createTexture(${id}) ${desc.size[0]}x${desc.size[1]} ${desc.format} usage=0x${desc.usage.toString(16)}`);
    tex[id] = device.createTexture(desc);
  }

  function createSampler(id, ptr, len) {
    if (smp[id]) return;
    if (len === 0) {
      DEBUG && dbg && console.warn(`[GPU] createSampler(${id}) skipped: len=0`);
      return;
    }
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
    DEBUG && dbg && console.log(`[GPU] createSampler(${id}) ${desc.magFilter}/${desc.minFilter}`);
    smp[id] = device.createSampler(desc);
  }

  function createBindGroup(id, layoutId, ptr, len) {
    if (bg[id]) return;
    if (len === 0) {
      DEBUG && dbg && console.warn(`[GPU] createBindGroup(${id}) skipped: len=0`);
      return;
    }
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
    DEBUG && dbg && console.log(`[GPU] createBindGroup(${id}) layoutId=${layoutId} entries=[${entries.map(e => `{b=${e.binding} rt=${e.rt} rid=${e.rid}}`).join(',')}]`);
    const p = pip[layoutId];
    if (!p) return;
    const ge = entries.map(e => {
      const entry = { binding: e.binding };
      if (e.rt === 0) { entry.resource = { buffer: buf[e.rid] }; if (e.offset) entry.resource.offset = e.offset; if (e.size) entry.resource.size = e.size; }
      else if (e.rt === 1) {
        entry.resource = tex[e.rid]?.createView();
        DEBUG && dbg && console.log(`[GPU]   bindGroup entry b=${e.binding}: tex[${e.rid}]=${tex[e.rid] ? 'exists' : 'MISSING'} view=${entry.resource ? 'valid' : 'NULL'}`);
      }
      else if (e.rt === 2) entry.resource = smp[e.rid];
      return entry;
    });
    bg[id] = device.createBindGroup({ layout: p.getBindGroupLayout(gi), entries: ge });
  }

  function beginRenderPass(colorId, loadOp, storeOp, depthId) {
    if (!enc) enc = device.createCommandEncoder();
    const CANVAS = 0xfffe;
    let cv;
    if (colorId === CANVAS) {
      const canvasTex = ctx.getCurrentTexture();
      DEBUG && dbg && console.log(`[GPU]   canvasTex: ${canvasTex?.width}x${canvasTex?.height} ${canvasTex?.format}`);
      cv = canvasTex.createView();
    } else {
      cv = tex[colorId]?.createView();
    }
    DEBUG && dbg && console.log(`[GPU] beginRenderPass colorId=${colorId === CANVAS ? 'CANVAS' : colorId} loadOp=${loadOp} storeOp=${storeOp} depthId=${depthId}`);
    DEBUG && dbg && console.log(`[GPU]   tex[${colorId}]=${tex[colorId] ? 'exists' : 'MISSING'} view=${cv ? 'valid' : 'NULL'}`);
    // Clear to transparent so CSS background shows through (alphaMode: "premultiplied")
    // TODO: Pass actual clearValue from bytecode once command buffer format is extended
    const pd = { colorAttachments: [{ view: cv, loadOp: loadOp === 1 ? "clear" : "load", storeOp: storeOp === 0 ? "store" : "discard", clearValue: { r: 0, g: 0, b: 0, a: 0 } }] };
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
  // Opcode dispatch - MUST match src/executor/command_buffer.zig Cmd enum!
  // (NOT types/opcodes.zig - that's for bytecode format, not command buffer)
  function dispatch(cmd, view, pos) {
    switch (cmd) {
      // === Resource Creation (0x01-0x0D) - matches command_buffer.zig ===
      case 0x01: { // create_buffer
        createBuffer(view.getUint16(pos, true), view.getUint32(pos + 2, true), view.getUint8(pos + 6));
        return pos + 7;
      }
      case 0x02: { // create_texture
        createTexture(view.getUint16(pos, true), view.getUint32(pos + 2, true), view.getUint32(pos + 6, true));
        return pos + 10;
      }
      case 0x03: { // create_sampler
        createSampler(view.getUint16(pos, true), view.getUint32(pos + 2, true), view.getUint32(pos + 6, true));
        return pos + 10;
      }
      case 0x04: { // create_shader
        createShader(view.getUint16(pos, true), view.getUint32(pos + 2, true), view.getUint32(pos + 6, true));
        return pos + 10;
      }
      case 0x05: { // create_render_pipeline
        createRenderPipeline(view.getUint16(pos, true), view.getUint32(pos + 2, true), view.getUint32(pos + 6, true));
        return pos + 10;
      }
      case 0x06: { // create_compute_pipeline
        createComputePipeline(view.getUint16(pos, true), view.getUint32(pos + 2, true), view.getUint32(pos + 6, true));
        return pos + 10;
      }
      case 0x07: { // create_bind_group
        createBindGroup(view.getUint16(pos, true), view.getUint16(pos + 2, true), view.getUint32(pos + 4, true), view.getUint32(pos + 8, true));
        return pos + 12;
      }
      case 0x08: { // create_texture_view
        const id = view.getUint16(pos, true), tid = view.getUint16(pos + 2, true);
        if (!txv[id] && tex[tid]) txv[id] = tex[tid].createView();
        return pos + 12;
      }
      case 0x09: { // create_query_set (stub)
        return pos + 10;
      }
      case 0x0A: { // create_bind_group_layout
        const id = view.getUint16(pos, true), ptr = view.getUint32(pos + 2, true), len = view.getUint32(pos + 6, true);
        if (!bgl[id]) bgl[id] = device.createBindGroupLayout(JSON.parse(rs(ptr, len)));
        return pos + 10;
      }
      case 0x0B: { // create_image_bitmap (async)
        const id = view.getUint16(pos, true), ptr = view.getUint32(pos + 2, true), len = view.getUint32(pos + 6, true);
        if (len === 0) return pos + 10;
        const blob = new Blob([new Uint8Array(mem.buffer, ptr, len)]);
        return createImageBitmap(blob).then(b => { bmp[id] = b; return pos + 10; });
      }
      case 0x0C: { // create_pipeline_layout
        const id = view.getUint16(pos, true), ptr = view.getUint32(pos + 2, true), len = view.getUint32(pos + 6, true);
        const desc = JSON.parse(rs(ptr, len));
        ppl[id] = device.createPipelineLayout({ bindGroupLayouts: desc.bindGroupLayouts.map(i => bgl[i]) });
        return pos + 10;
      }
      case 0x0D: { // create_render_bundle (stub)
        return pos + 10;
      }

      // === Pass Operations (0x10-0x1A) - matches command_buffer.zig ===
      case 0x10: { // begin_render_pass
        beginRenderPass(view.getUint16(pos, true), view.getUint8(pos + 2), view.getUint8(pos + 3), view.getUint16(pos + 4, true));
        return pos + 6;
      }
      case 0x11: { // begin_compute_pass
        beginComputePass();
        return pos;
      }
      case 0x12: { // set_pipeline
        const pipId = view.getUint16(pos, true);
        DEBUG && dbg && console.log(`[GPU] setPipeline(${pipId})`);
        pass?.setPipeline(pip[pipId]);
        return pos + 2;
      }
      case 0x13: { // set_bind_group
        const gi = view.getUint8(pos), bgId = view.getUint16(pos + 1, true);
        DEBUG && dbg && console.log(`[GPU] setBindGroup(${gi}, ${bgId}) pass=${pass ? 'valid' : 'NULL'} bg[${bgId}]=${bg[bgId] ? 'exists' : 'MISSING'}`);
        pass?.setBindGroup(gi, bg[bgId]);
        return pos + 3;
      }
      case 0x14: { // set_vertex_buffer
        pass?.setVertexBuffer(view.getUint8(pos), buf[view.getUint16(pos + 1, true)]);
        return pos + 3;
      }
      case 0x15: { // draw
        const vc = view.getUint32(pos, true), ic = view.getUint32(pos + 4, true);
        DEBUG && dbg && console.log(`[GPU] draw(${vc}, ${ic}) pass=${pass ? 'valid' : 'NULL'}`);
        pass?.draw(vc, ic, view.getUint32(pos + 8, true), view.getUint32(pos + 12, true));
        return pos + 16;
      }
      case 0x16: { // draw_indexed
        pass?.drawIndexed(view.getUint32(pos, true), view.getUint32(pos + 4, true), view.getUint32(pos + 8, true), view.getInt32(pos + 12, true), view.getUint32(pos + 16, true));
        return pos + 20;
      }
      case 0x17: { // end_pass
        DEBUG && dbg && console.log(`[GPU] endPass`);
        pass?.end();
        pass = null;
        return pos;
      }
      case 0x18: { // dispatch
        pass?.dispatchWorkgroups(view.getUint32(pos, true), view.getUint32(pos + 4, true), view.getUint32(pos + 8, true));
        return pos + 12;
      }
      case 0x19: { // set_index_buffer
        pass?.setIndexBuffer(buf[view.getUint16(pos, true)], view.getUint8(pos + 2) === 1 ? "uint32" : "uint16");
        return pos + 3;
      }
      case 0x1A: { // execute_bundles
        const count = view.getUint8(pos);
        return pos + 1 + count * 2;
      }

      // === Queue Operations (0x20-0x25) - matches command_buffer.zig ===
      case 0x20: { // write_buffer
        const id = view.getUint16(pos, true), offset = view.getUint32(pos + 2, true);
        const dataPtr = view.getUint32(pos + 6, true), dataLen = view.getUint32(pos + 10, true);
        DEBUG && dbg && console.log(`[GPU] write_buffer: id=${id}, offset=${offset}, dataPtr=${dataPtr}, dataLen=${dataLen}`);
        if (buf[id] && dataLen > 0) device.queue.writeBuffer(buf[id], offset, new Uint8Array(mem.buffer, dataPtr, dataLen));
        return pos + 14;
      }
      case 0x21: { // write_time_uniform
        const id = view.getUint16(pos, true), offset = view.getUint32(pos + 2, true), size = view.getUint16(pos + 6, true);
        DEBUG && dbg && console.log(`[GPU] writeTimeUniform buf[${id}] time=${time} cw=${cw} ch=${ch}`);
        if (buf[id]) {
          const data = new Float32Array([time, cw, ch, cw / (ch || 1)]);
          device.queue.writeBuffer(buf[id], offset, new Uint8Array(data.buffer, 0, Math.min(size, 16)));
        }
        return pos + 8;
      }
      case 0x22: { // copy_buffer_to_buffer
        const sid = view.getUint16(pos, true), so = view.getUint32(pos + 2, true);
        const did = view.getUint16(pos + 6, true), dof = view.getUint32(pos + 8, true);
        const sz = view.getUint32(pos + 12, true);
        if (!enc) enc = device.createCommandEncoder();
        enc.copyBufferToBuffer(buf[sid], so, buf[did], dof, sz);
        return pos + 16;
      }
      case 0x23: { // copy_texture_to_texture
        const sid = view.getUint16(pos, true), did = view.getUint16(pos + 2, true);
        const w = view.getUint16(pos + 4, true), h = view.getUint16(pos + 6, true);
        if (!enc) enc = device.createCommandEncoder();
        enc.copyTextureToTexture({ texture: tex[sid] }, { texture: tex[did] }, [w, h]);
        return pos + 8;
      }
      case 0x24: { // write_buffer_from_wasm
        const bid = view.getUint16(pos, true), off = view.getUint32(pos + 2, true);
        const callId = view.getUint32(pos + 6, true), sz = view.getUint32(pos + 10, true);
        const cr = wcr[callId];
        DEBUG && dbg && console.log(`[GPU] write_buffer_from_wasm: bid=${bid}, off=${off}, callId=${callId}, sz=${sz}, cr=`, cr);
        if (buf[bid] && cr && sz > 0) {
          // Get WASM module's memory - prefer exported, fall back to imported
          const mod = wm[cr.mid];
          const wasmMem = mod?.inst?.exports?.memory?.buffer || mod?.importedMem?.buffer;
          DEBUG && dbg && console.log(`[GPU] write_buffer_from_wasm: mod=${!!mod}, wasmMem=${!!wasmMem}, result=${cr.result}, memSize=${wasmMem?.byteLength}`);
          if (wasmMem && cr.result != null && cr.result + sz <= wasmMem.byteLength) {
            device.queue.writeBuffer(buf[bid], off, new Uint8Array(wasmMem, cr.result, sz));
          } else {
            DEBUG && dbg && console.warn(`[GPU] write_buffer_from_wasm: invalid params - result=${cr.result}, sz=${sz}, memSize=${wasmMem?.byteLength}`);
          }
        }
        return pos + 14;
      }
      case 0x25: { // copy_external_image_to_texture (async)
        const bid = view.getUint16(pos, true), tid = view.getUint16(pos + 2, true);
        const mip = view.getUint8(pos + 4), ox = view.getUint16(pos + 5, true), oy = view.getUint16(pos + 7, true);
        const b = bmp[bid];
        if (b && tex[tid]) {
          device.queue.copyExternalImageToTexture({ source: b }, { texture: tex[tid], mipLevel: mip, origin: [ox, oy] }, [b.width, b.height]);
        }
        return pos + 9;
      }

      // === WASM Operations (0x30-0x31) - matches command_buffer.zig ===
      case 0x30: { // init_wasm_module (async)
        const id = view.getUint16(pos, true), ptr = view.getUint32(pos + 2, true), len = view.getUint32(pos + 6, true);
        DEBUG && dbg && console.log(`[GPU] init_wasm_module: id=${id}, ptr=${ptr}, len=${len}`);
        if (len === 0) return pos + 10;
        const bytes = new Uint8Array(mem.buffer, ptr, len).slice();
        const importedMem = new WebAssembly.Memory({ initial: 1 });
        const wasmImports = { env: { abort: () => { throw new Error('WASM abort'); }, memory: importedMem } };
        return WebAssembly.compile(bytes).then(mod =>
          WebAssembly.instantiate(mod, wasmImports).then(inst => {
            wm[id] = { inst, importedMem };
            DEBUG && dbg && console.log(`[GPU] init_wasm_module done: id=${id}, exports=`, Object.keys(inst.exports));
            return pos + 10;
          })
        );
      }
      case 0x31: { // call_wasm_func (async)
        const cid = view.getUint16(pos, true), mid = view.getUint16(pos + 2, true);
        const np = view.getUint32(pos + 4, true), nl = view.getUint32(pos + 8, true);
        const ac = view.getUint8(pos + 12);
        const ab = new Uint8Array(mem.buffer, pos + 13, ac).slice();
        const name = rs(np, nl);
        DEBUG && dbg && console.log(`[GPU] call_wasm_func: cid=${cid}, mid=${mid}, name="${name}", ac=${ac}`);
        const { inst } = wm[mid] || {};
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
        if (fn) {
          const result = fn(...args);
          wcr[cid] = { mid, result };
          DEBUG && dbg && console.log(`[GPU] call_wasm_func result: cid=${cid}, result=${result}`);
        } else {
          DEBUG && dbg && console.log(`[GPU] call_wasm_func: fn not found! mid=${mid}, name="${name}"`);
        }
        return pos + 13 + ac;
      }

      // === Control (0xF0-0xFF) - matches command_buffer.zig ===
      case 0xF0: { // submit
        DEBUG && dbg && console.log(`[GPU] submit enc=${!!enc}`);
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

  // Uniform table: Map<string, {bufferId, offset, size, type}>
  let uniformMap = null;

  /**
   * Set uniform table from parsed bytecode.
   * @param {Map<string, {bufferId, offset, size, type}>} map
   */
  function setUniformTable(map) {
    uniformMap = map;
    DEBUG && dbg && console.log(`[GPU] setUniformTable: ${map.size} uniforms`);
  }

  /**
   * Set a uniform value by name.
   * @param {string} name - Uniform field name
   * @param {number|number[]} value - Value to set
   * @returns {boolean} - true if uniform was found and written
   */
  function setUniform(name, value) {
    if (!uniformMap) return false;
    const info = uniformMap.get(name);
    if (!info) {
      DEBUG && dbg && console.warn(`[GPU] setUniform: unknown uniform '${name}'`);
      return false;
    }

    const buffer = buf[info.bufferId];
    if (!buffer) {
      DEBUG && dbg && console.warn(`[GPU] setUniform: buffer ${info.bufferId} not found`);
      return false;
    }

    // Convert value to typed array based on uniform type
    const data = uniformToTypedArray(value, info.type, info.size);
    if (!data) {
      DEBUG && dbg && console.warn(`[GPU] setUniform: failed to convert value for '${name}'`);
      return false;
    }

    // Write to GPU buffer
    device.queue.writeBuffer(buffer, info.offset, data);
    DEBUG && dbg && console.log(`[GPU] setUniform: ${name} = ${Array.isArray(value) ? `[${value.join(',')}]` : value} @ buffer[${info.bufferId}]+${info.offset}`);
    return true;
  }

  /**
   * Set multiple uniforms at once.
   * @param {Object} uniforms - Map of name -> value
   * @returns {number} - Number of uniforms successfully written
   */
  function setUniforms(uniforms) {
    let count = 0;
    for (const [name, value] of Object.entries(uniforms)) {
      if (setUniform(name, value)) count++;
    }
    return count;
  }

  // Return public interface only - these names stay, everything else minifies
  return {
    setDebug(v) { dbg = v; },
    setMemory(m) { mem = m; },
    setTime(t) { time = t; },
    setCanvasSize(w, h) { cw = w; ch = h; },
    setUniformTable,
    setUniform,
    setUniforms,
    execute,
    destroy,
  };
}

/**
 * Convert JS value to TypedArray based on UniformType.
 * @param {number|number[]} value
 * @param {number} uniformType - UniformType enum value
 * @param {number} size - Expected byte size
 * @returns {Uint8Array|null}
 */
function uniformToTypedArray(value, uniformType, size) {
  // Normalize to array
  const arr = Array.isArray(value) ? value : [value];

  switch (uniformType) {
    case UT_F32:
    case UT_VEC2F:
    case UT_VEC3F:
    case UT_VEC4F: {
      const f32 = new Float32Array(arr);
      return new Uint8Array(f32.buffer, 0, Math.min(f32.byteLength, size));
    }

    case UT_I32:
    case UT_VEC2I:
    case UT_VEC3I:
    case UT_VEC4I: {
      const i32 = new Int32Array(arr);
      return new Uint8Array(i32.buffer, 0, Math.min(i32.byteLength, size));
    }

    case UT_U32:
    case UT_VEC2U:
    case UT_VEC3U:
    case UT_VEC4U: {
      const u32 = new Uint32Array(arr);
      return new Uint8Array(u32.buffer, 0, Math.min(u32.byteLength, size));
    }

    case UT_MAT3X3F: {
      // mat3x3 in WGSL is 3 vec4 columns (48 bytes with padding)
      // Input: 9 floats (row-major), output: 3 vec4 columns (column-major with padding)
      const f32 = new Float32Array(12); // 3 columns × 4 floats
      if (arr.length >= 9) {
        // Column 0
        f32[0] = arr[0]; f32[1] = arr[3]; f32[2] = arr[6]; f32[3] = 0;
        // Column 1
        f32[4] = arr[1]; f32[5] = arr[4]; f32[6] = arr[7]; f32[7] = 0;
        // Column 2
        f32[8] = arr[2]; f32[9] = arr[5]; f32[10] = arr[8]; f32[11] = 0;
      }
      return new Uint8Array(f32.buffer, 0, Math.min(48, size));
    }

    case UT_MAT4X4F: {
      // mat4x4 in WGSL is 4 vec4 columns (64 bytes)
      // Assume input is column-major (WebGPU convention)
      const f32 = new Float32Array(arr.length >= 16 ? arr : [...arr, ...Array(16 - arr.length).fill(0)]);
      return new Uint8Array(f32.buffer, 0, Math.min(64, size));
    }

    default:
      // Unknown type - try as f32
      const f32 = new Float32Array(arr);
      return new Uint8Array(f32.buffer, 0, Math.min(f32.byteLength, size));
  }
}

// Compatibility alias
export const CommandDispatcher = {
  create: createCommandDispatcher,
};
