// Queue / WASM / control command handlers for the GPU dispatcher.
// Handles opcodes 0x20-0x2B (queue), 0x30-0x31 (WASM), 0xF0-0xFF (control).
//
// Split out of gpu.js alongside gpu-resource-pass-commands.js (0x01-0x52). The
// two modules share one `ops` bag — see types/gpu-ops.d.ts for its shape and
// for why the mutable closure scalars are reached through accessors.
//
// Operand widths here are pinned against src/executor/command_buffer.zig by
// tests/npm/command-buffer-widths.test.js. A wrong `return pos + N` desyncs
// every LATER command in the buffer, so treat those numbers as wire format.

import {
  calculateCopy,
  calculateTextureCopy,
  calculateWrite,
  CopyPolicy,
} from "./texture-layout.js";

// Same build-flag fallback gpu.js installs (esbuild --define:DEBUG=false strips
// the debug paths in production). Declared locally rather than relying on
// gpu.js's copy having run first: that import-side-effect coupling is what left
// AUDIO and EMBEDDED_ONLY undefined in some contexts.
if (typeof DEBUG === "undefined") globalThis.DEBUG = false;

/** Sentinel texture id meaning "the canvas", not an entry in the texture table. */
const CANVAS = 0xfffe;

/**
 * Wire aspect tags, in the contract's fixed byte order.
 * @type {GPUTextureAspect[]}
 */
const ASPECT_NAMES = ["all", "stencil-only", "depth-only"];

/**
 * The public SJON name for a resource id, or null when the payload carries no
 * name block for it (an old payload, an unnamed resource). A pool member is
 * addressed by its declared base name.
 * @param {Map<string, {id: number, pool: number}>} names
 * @param {number} id
 * @returns {string|null}
 */
function nameFor(names, id) {
  for (const [name, r] of names) {
    if (id >= r.id && id < r.id + (r.pool || 1)) return name;
  }
  return null;
}

/**
 * One failed byte readback, through the existing command-error route. Every
 * failure — a rejected map, a range the mapping does not cover, a throwing
 * host callback — names the buffer and the `readback-unavailable` code.
 * @param {GpuOps} ops
 * @param {object} rb
 * @param {unknown} e
 */
function readbackFailed(ops, rb, e) {
  ops.reportError({
    message: `texture readback failed for buffer ${rb.id}: ${/** @type {any} */ (e)?.message || e} (readback-unavailable)`,
    source: "readback",
  });
}

/**
 * Map one scheduled texture→buffer destination and hand its bytes to the host.
 *
 * mapAsync requires an 8-byte-aligned offset and a 4-byte-multiple size, which
 * a legal texel-copy layout need not satisfy (a depth-stencil copy allows a
 * 4-byte offset; a stencil row can end on an odd byte). Map the enclosing
 * aligned window and slice exactly the copied span — final row padding
 * excluded — out of it.
 *
 * The byte array is an OWNED copy: the mapping is released in `finally` before
 * the host is called, so a retained or mutated array can never alias driver
 * memory, and a throwing callback cannot leave the buffer mapped (the 0x22 skip
 * would then poison every later copy to it). A destroyed dispatcher (a stale
 * generation) releases a late mapping and delivers nothing, including no error.
 *
 * @param {GpuOps} ops
 * @param {object} rb
 * @param {(readback: object) => void} onTextureReadback
 */
function deliverTextureReadback(ops, rb, onTextureReadback) {
  const b = ops.buf[rb.id];
  if (!b || b.mapState !== "unmapped") {
    readbackFailed(ops, rb, new Error(b ? `buffer is ${b.mapState}` : "buffer is gone"));
    return;
  }
  const mapOffset = rb.offset & ~7;
  const mapSize = Math.ceil((rb.offset - mapOffset + rb.size) / 4) * 4;
  b.mapAsync(GPUMapMode.READ, mapOffset, mapSize).then(() => {
    let bytes = null;
    try {
      if (ops.alive()) {
        const mapped = new Uint8Array(b.getMappedRange(mapOffset, mapSize));
        bytes = mapped.slice(rb.offset - mapOffset, rb.offset - mapOffset + rb.size);
      }
    } catch (e) {
      readbackFailed(ops, rb, e);
    } finally {
      if (b.mapState === "mapped") {
        try { b.unmap(); } catch { /* raced a teardown */ }
      }
    }
    if (!bytes || !ops.alive()) return;
    try {
      onTextureReadback({
        texture: rb.textureName,
        buffer: rb.bufferName,
        offset: rb.offset,
        size: rb.size,
        bytes,
        bytesPerRow: rb.bytesPerRow,
        rowsPerImage: rb.rowsPerImage,
        mipLevel: rb.mipLevel,
        origin: rb.origin,
        aspect: rb.aspect,
        copySize: rb.copySize,
      });
    } catch (e) {
      readbackFailed(ops, rb, e);
    }
  }).catch((e) => readbackFailed(ops, rb, e));
}

/**
 * Execute a buffer↔texture encoder copy (0x29 / 0x2A).
 *
 * The record is 46 fixed operand bytes:
 * `[texture_id:u16][buffer_id:u16][offset:u32][bytes_per_row:u32]
 * [rows_per_image:u32][mip_level:u32][origin_x/y/z:u32][aspect:u8]
 * [size_width:u32][size_height:u32][size_depth:u32][flags:u8]`.
 * No WASM pointer appears: the linear side is a GPUBuffer.
 *
 * The opcode is the direction. It selects the calculator policy, so the
 * texture endpoint is validated as a destination (`copy-dst`) for 0x29 and as
 * a source (`copy-src`) for 0x2A — two different usage checks. A refusal
 * reaches the host through onError and records no encoder call.
 *
 * @param {number} cmd
 * @param {DataView} view
 * @param {number} pos
 * @param {GpuOps} ops
 * @returns {number}
 */
function copyTextureBuffer(cmd, view, pos, ops) {
  const bufferToTexture = cmd === 0x29;
  const textureId = view.getUint16(pos, true);
  const bufferId = view.getUint16(pos + 2, true);
  const offset = view.getUint32(pos + 4, true);
  const bytesPerRow = view.getUint32(pos + 8, true);
  const rowsPerImage = view.getUint32(pos + 12, true);
  const mipLevel = view.getUint32(pos + 16, true);
  const ox = view.getUint32(pos + 20, true);
  const oy = view.getUint32(pos + 24, true);
  const oz = view.getUint32(pos + 28, true);
  const aspect = view.getUint8(pos + 32);
  const sizeWidth = view.getUint32(pos + 33, true);
  const sizeHeight = view.getUint32(pos + 37, true);
  const sizeDepth = view.getUint32(pos + 41, true);
  const flags = view.getUint8(pos + 45);

  // Presence is the flags byte's only job: an absent stride/size and an
  // authored zero carry the same value. Keep absence as undefined through the
  // calculator AND the WebGPU layout — passing the normalized minimum here
  // would silently turn omission into an explicit stride.
  const hasBytesPerRow = (flags & 1) !== 0;
  const hasRowsPerImage = (flags & 2) !== 0;
  const hasSize = (flags & 4) !== 0;
  const write = {
    offset,
    mipLevel,
    origin: { x: ox, y: oy, z: oz },
    aspect,
    bytesPerRow: hasBytesPerRow ? bytesPerRow : undefined,
    rowsPerImage: hasRowsPerImage ? rowsPerImage : undefined,
    size: hasSize
      ? { width: sizeWidth, height: sizeHeight, depthOrArrayLayers: sizeDepth }
      : undefined,
  };

  const label = bufferToTexture ? "copyBufferToTexture" : "copyTextureToBuffer";
  const source = bufferToTexture ? "copy-buffer-to-texture" : "copy-texture-to-buffer";
  const refuse = (code, field, actual, limit) =>
    ops.reportError({ message: `${label}: ${code} — ${field}/${actual}/${limit}`, source });

  const texture = ops.tex[textureId];
  const descriptor = ops.txd[textureId];
  if (!texture || !descriptor) {
    refuse("missing-texture", "texture", textureId, 0);
    return pos + 46;
  }
  const buffer = ops.buf[bufferId];
  const bufferSize = ops.bufSize[bufferId];
  if (!buffer || bufferSize === undefined) {
    refuse("missing-buffer", "buffer", bufferId, 0);
    return pos + 46;
  }

  const calc = calculateCopy(
    descriptor,
    write,
    bufferSize,
    bufferToTexture ? CopyPolicy.bufferToTexture : CopyPolicy.textureToBuffer,
  );
  if ("refuse" in calc) {
    refuse(calc.refuse.code, calc.refuse.field, calc.refuse.actual, calc.refuse.limit);
    return pos + 46;
  }

  const copy = calc.ok.copyExtent;
  const size = /** @type {[number, number, number]} */ ([copy.width, copy.height, copy.depthOrArrayLayers]);
  const textureInfo = { texture, mipLevel, origin: [ox, oy, oz], aspect: ASPECT_NAMES[aspect] };
  const bufferInfo = {
    buffer,
    offset,
    bytesPerRow: write.bytesPerRow,
    rowsPerImage: write.rowsPerImage,
  };
  // A texture→buffer copy into MAP_READ|COPY_DST is a byte readback, not a
  // query resolution. A destination already mapped (a host-held mapping, or a
  // prior delivery that has not released yet) makes the copy invalid; report
  // it rather than skipping silently, which is what 0x22's query path does.
  const usage = ops.bufUsage[bufferId] || 0;
  const readbackDestination = !bufferToTexture && (usage & 0x0001) !== 0 && (usage & 0x0008) !== 0;
  if (readbackDestination && buffer.mapState !== "unmapped") {
    refuse("buffer-mapped", "buffer", bufferId, 0);
    return pos + 46;
  }
  const enc = ops.encoder();
  if (bufferToTexture) enc.copyBufferToTexture(bufferInfo, textureInfo, size);
  else enc.copyTextureToBuffer(textureInfo, bufferInfo, size);
  if (readbackDestination && calc.ok.requiredBytesInCopy > 0) {
    ops.pendingReadbacks.push({
      kind: "texture",
      id: bufferId,
      offset,
      size: calc.ok.requiredBytesInCopy,
      bytesPerRow: calc.ok.bytesPerRow,
      rowsPerImage: calc.ok.rowsPerImage,
      mipLevel,
      origin: [ox, oy, oz],
      aspect: ASPECT_NAMES[aspect],
      copySize: size,
      textureName: nameFor(ops.texNames, textureId),
      bufferName: nameFor(ops.bufNames, bufferId),
    });
  }
  return pos + 46;
}

/**
 * The canvas as a copy endpoint. The configured canvas is
 * RENDER_ATTACHMENT|COPY_SRC (`core.js`/`worker-core.js` configure it that
 * way), so a canvas SOURCE can be validated while a canvas DESTINATION is
 * refused by the shared calculator's missing-copy-dst stage.
 *
 * @param {GpuOps} ops
 * @returns {object}
 */
function canvasCopyDescriptor(ops) {
  const { cw, ch } = ops.clock();
  return {
    size: { width: cw, height: ch, depthOrArrayLayers: 1 },
    dimension: "2d",
    format: navigator.gpu.getPreferredCanvasFormat(),
    usage: 0x10 | 0x01, // RENDER_ATTACHMENT | COPY_SRC
    sampleCount: 1,
    mipLevelCount: 1,
    extentSource: "canvas",
  };
}

/**
 * Execute a subresource texture→texture copy (0x2B).
 *
 * The record is 51 fixed operand bytes:
 * `[src_id:u16][dst_id:u16] [src_mip:u32][src_origin_x/y/z:u32][src_aspect:u8]
 * [dst_mip:u32][dst_origin_x/y/z:u32][dst_aspect:u8]
 * [size_width:u32][size_height:u32][size_depth:u32][flags:u8]`.
 * No WASM pointer appears: both sides are GPUTextures the runtime holds.
 *
 * `flags` bit 0 records whether a size was authored. An absent size defers to
 * `calculateTextureCopy`'s remaining-physical-source-extent rule. The opcode
 * executes ONLY after that calculator accepts both endpoints — a refusal
 * reaches onError and records no encoder call.
 *
 * @param {DataView} view
 * @param {number} pos
 * @param {GpuOps} ops
 * @returns {number}
 */
function copyTextureSubresource(view, pos, ops) {
  const sourceId = view.getUint16(pos, true);
  const destinationId = view.getUint16(pos + 2, true);
  const sourceMip = view.getUint32(pos + 4, true);
  const sourceX = view.getUint32(pos + 8, true);
  const sourceY = view.getUint32(pos + 12, true);
  const sourceZ = view.getUint32(pos + 16, true);
  const sourceAspect = view.getUint8(pos + 20);
  const destinationMip = view.getUint32(pos + 21, true);
  const destinationX = view.getUint32(pos + 25, true);
  const destinationY = view.getUint32(pos + 29, true);
  const destinationZ = view.getUint32(pos + 33, true);
  const destinationAspect = view.getUint8(pos + 37);
  const sizeWidth = view.getUint32(pos + 38, true);
  const sizeHeight = view.getUint32(pos + 42, true);
  const sizeDepth = view.getUint32(pos + 46, true);
  const flags = view.getUint8(pos + 50);

  const label = "copyTextureToTexture";
  const source = "copy-texture-subresource";
  const refuse = (code, field, actual, limit) =>
    ops.reportError({ message: `${label}: ${code} — ${field}/${actual}/${limit}`, source });

  // Only bit 0 is defined. Any other bit makes the record uninterpretable, so
  // this is a refusal rather than a silently ignored feature bit.
  if ((flags & ~1) !== 0) {
    refuse("invalid-flags", "flags", flags, 1);
    return pos + 51;
  }
  const hasSize = (flags & 1) !== 0;

  const descriptorOf = (id) =>
    id === CANVAS ? canvasCopyDescriptor(ops) : ops.txd[id];
  const sourceDescriptor = descriptorOf(sourceId);
  const destinationDescriptor = descriptorOf(destinationId);
  if (!sourceDescriptor) {
    refuse("missing-texture", "texture", sourceId, 0);
    return pos + 51;
  }
  if (!destinationDescriptor) {
    refuse("missing-texture", "texture", destinationId, 0);
    return pos + 51;
  }

  const calc = calculateTextureCopy(sourceDescriptor, destinationDescriptor, {
    source: {
      textureId: sourceId,
      mipLevel: sourceMip,
      origin: { x: sourceX, y: sourceY, z: sourceZ },
      aspect: sourceAspect,
    },
    destination: {
      textureId: destinationId,
      mipLevel: destinationMip,
      origin: { x: destinationX, y: destinationY, z: destinationZ },
      aspect: destinationAspect,
    },
    size: hasSize
      ? { width: sizeWidth, height: sizeHeight, depthOrArrayLayers: sizeDepth }
      : undefined,
  });
  if ("refuse" in calc) {
    refuse(calc.refuse.code, calc.refuse.field, calc.refuse.actual, calc.refuse.limit);
    return pos + 51;
  }

  // Resolve the live handles only after validation: a canvas destination never
  // acquires a swapchain texture it is about to be refused.
  const sourceTexture =
    sourceId === CANVAS ? ops.targetCtx().getCurrentTexture() : ops.tex[sourceId];
  const destinationTexture =
    destinationId === CANVAS ? ops.targetCtx().getCurrentTexture() : ops.tex[destinationId];
  if (!sourceTexture || !destinationTexture) {
    refuse("missing-texture", "texture", sourceTexture ? destinationId : sourceId, 0);
    return pos + 51;
  }

  const extent = calc.ok.copyExtent;
  const enc = ops.encoder();
  enc.copyTextureToTexture(
    {
      texture: sourceTexture,
      mipLevel: sourceMip,
      origin: [sourceX, sourceY, sourceZ],
      aspect: ASPECT_NAMES[sourceAspect],
    },
    {
      texture: destinationTexture,
      mipLevel: destinationMip,
      origin: [destinationX, destinationY, destinationZ],
      aspect: ASPECT_NAMES[destinationAspect],
    },
    [extent.width, extent.height, extent.depthOrArrayLayers],
  );
  return pos + 51;
}

/**
 * Dispatch queue / WASM / control commands.
 *
 * @param {number} cmd
 * @param {DataView} view
 * @param {number} pos - offset of this command's first OPERAND byte
 * @param {GpuOps} ops
 * @returns {number|Promise<number>|null} next position, or null if unhandled
 */
export function dispatchQueueCommand(cmd, view, pos, ops) {
  switch (cmd) {
    // === Queue Operations (0x20-0x27) - matches command_buffer.zig ===
    case 0x20: { // write_buffer
      const id = view.getUint16(pos, true), offset = view.getUint32(pos + 2, true);
      const dataPtr = view.getUint32(pos + 6, true), dataLen = view.getUint32(pos + 10, true);
      DEBUG && ops.debug() && console.log(`[GPU] write_buffer: id=${id}, offset=${offset}, dataPtr=${dataPtr}, dataLen=${dataLen}`);
      if (ops.buf[id] && dataLen > 0) ops.device.queue.writeBuffer(ops.buf[id], offset, new Uint8Array(ops.mem.buffer, dataPtr, dataLen));
      return pos + 14;
    }
    case 0x21: { // write_time_uniform
      const id = view.getUint16(pos, true), offset = view.getUint32(pos + 2, true), size = view.getUint16(pos + 6, true);
      const { time, cw, ch, frame } = ops.clock();
      DEBUG && ops.debug() && console.log(`[GPU] writeTimeUniform buf[${id}] time=${time} cw=${cw} ch=${ch} frame=${frame}`);
      if (ops.buf[id]) {
        // Staged through the dispatcher's own scratch rather than a fresh
        // Float32Array per write: this runs every frame, once per queue step.
        // `size` picks the window: 12 (scene-time-inputs), 16 (pngine-inputs),
        // 20 (pngine-frame-inputs). Filling all 20 regardless costs one store
        // and keeps the three sources one payload rather than three branches.
        const s = ops.scratch;
        s.time[0] = time; s.time[1] = cw; s.time[2] = ch; s.time[3] = cw / (ch || 1);
        s.frame[0] = frame;
        ops.device.queue.writeBuffer(ops.buf[id], offset, s.timeBytes, 0, Math.min(size, 20));
      }
      return pos + 8;
    }
    case 0x26: { // write_pointer_uniform
      const id = view.getUint16(pos, true), offset = view.getUint32(pos + 2, true), size = view.getUint16(pos + 6, true);
      const s = ops.scratch;
      DEBUG && ops.debug() && console.log(`[GPU] writePointerUniform buf[${id}] x=${s.ptr[0]} y=${s.ptr[1]}`);
      // 12 floats = 48 bytes; the 12th is padding. Layout is pinned by
      // tests/npm/helpers/pointer-layout.js. setPointer writes the state
      // straight into this array, so the write copies with no staging at all.
      if (ops.buf[id]) ops.device.queue.writeBuffer(ops.buf[id], offset, s.ptrBytes, 0, Math.min(size, 48));
      return pos + 8;
    }
    case 0x27: { // resolve_query_set
      const qsId = view.getUint16(pos, true);
      const first = view.getUint32(pos + 2, true);
      const count = view.getUint32(pos + 6, true);
      const destBuf = view.getUint16(pos + 10, true);
      const destOff = view.getUint32(pos + 12, true);
      const enc = ops.encoder();
      if (ops.qs[qsId] && ops.buf[destBuf]) enc.resolveQuerySet(ops.qs[qsId], first, count, ops.buf[destBuf], destOff);
      return pos + 16;
    }
    case 0x28: { // write_texture
      const id = view.getUint16(pos, true);
      const dataPtr = view.getUint32(pos + 2, true);
      const dataLen = view.getUint32(pos + 6, true);
      const offset = view.getUint32(pos + 10, true);
      const bytesPerRow = view.getUint32(pos + 14, true);
      const rowsPerImage = view.getUint32(pos + 18, true);
      const mipLevel = view.getUint32(pos + 22, true);
      const ox = view.getUint32(pos + 26, true);
      const oy = view.getUint32(pos + 30, true);
      const oz = view.getUint32(pos + 34, true);
      const aspect = view.getUint8(pos + 38);
      const sizeWidth = view.getUint32(pos + 39, true);
      const sizeHeight = view.getUint32(pos + 43, true);
      const sizeDepth = view.getUint32(pos + 47, true);
      const flags = view.getUint8(pos + 51);

      // Presence is the flags byte's only job: an absent stride/size and an
      // authored zero carry the same value. Keep absence as undefined through
      // the calculator AND the WebGPU layout — passing the normalized minimum
      // here would silently turn omission into an explicit stride.
      const hasBytesPerRow = (flags & 1) !== 0;
      const hasRowsPerImage = (flags & 2) !== 0;
      const hasSize = (flags & 4) !== 0;
      const write = {
        offset,
        mipLevel,
        origin: { x: ox, y: oy, z: oz },
        aspect,
        bytesPerRow: hasBytesPerRow ? bytesPerRow : undefined,
        rowsPerImage: hasRowsPerImage ? rowsPerImage : undefined,
        size: hasSize
          ? { width: sizeWidth, height: sizeHeight, depthOrArrayLayers: sizeDepth }
          : undefined,
      };

      const refuse = (code, field, actual, limit) =>
        ops.reportError({
          message: `writeTexture: ${code} — ${field}/${actual}/${limit}`,
          source: "write-texture",
        });

      const texture = ops.tex[id];
      const descriptor = ops.txd[id];
      if (!texture || !descriptor) {
        refuse("missing-texture", "texture", id, 0);
        return pos + 52;
      }
      // The window is referenced straight out of executor memory, so its u64
      // end is bounded before the view is constructed. Two u32 operands sum to
      // at most 2^33, which a JS Number carries exactly; equality is legal (a
      // zero-length window at the very end), one byte past is not.
      const memBytes = ops.mem.buffer.byteLength;
      const end = dataPtr + dataLen;
      if (dataPtr > memBytes || end > memBytes) {
        refuse("invalid-data-window", "data", end, memBytes);
        return pos + 52;
      }

      // The retained record IS the calculator descriptor: concrete extent,
      // resolved format, destination usage, sample count and mip count, all
      // kept current by create/resize. Nothing is re-derived from bindings.
      const calc = calculateWrite(descriptor, write, dataLen);
      if ("refuse" in calc) {
        refuse(calc.refuse.code, calc.refuse.field, calc.refuse.actual, calc.refuse.limit);
        return pos + 52;
      }

      const copy = calc.ok.copyExtent;
      ops.device.queue.writeTexture(
        { texture, mipLevel, origin: [ox, oy, oz], aspect: ASPECT_NAMES[aspect] },
        new Uint8Array(ops.mem.buffer, dataPtr, dataLen),
        { offset, bytesPerRow: write.bytesPerRow, rowsPerImage: write.rowsPerImage },
        [copy.width, copy.height, copy.depthOrArrayLayers],
      );
      return pos + 52;
    }
    case 0x29: // copy_buffer_to_texture
    case 0x2a: // copy_texture_to_buffer
      return copyTextureBuffer(cmd, view, pos, ops);
    case 0x2b: // copy_texture_subresource
      return copyTextureSubresource(view, pos, ops);
    case 0x22: { // copy_buffer_to_buffer
      const sid = view.getUint16(pos, true), so = view.getUint32(pos + 2, true);
      const did = view.getUint16(pos + 6, true), dof = view.getUint32(pos + 8, true);
      const sz = view.getUint32(pos + 12, true);
      // Encoder created BEFORE the skip check, matching the pre-split code: on
      // the skip path this leaves an encoder that submit may finish empty.
      // Wasteful but load-bearing to preserve — moving it below the early
      // return would change what gets submitted on such a frame, and that is a
      // behaviour decision, not a refactor.
      const enc = ops.encoder();
      // Skip copy to MAP_READ buffers that are still mapped from a prior readback
      const isMapRead = ops.bufUsage[did] & 0x0001;
      if (isMapRead && ops.buf[did]?.mapState !== 'unmapped') {
        return pos + 16;
      }
      enc.copyBufferToBuffer(ops.buf[sid], so, ops.buf[did], dof, sz);
      // Schedule readback for MAP_READ destination buffers
      if (isMapRead) {
        ops.pendingReadbacks.push({ kind: "query", id: did, offset: dof, size: sz });
      }
      return pos + 16;
    }
    case 0x23: { // copy_texture_to_texture
      const sid = view.getUint16(pos, true), did = view.getUint16(pos + 2, true);
      const { cw, ch } = ops.clock();
      const w = view.getUint16(pos + 4, true) || cw, h = view.getUint16(pos + 6, true) || ch;
      const enc = ops.encoder();
      const srcTex = (sid === CANVAS) ? ops.targetCtx().getCurrentTexture() : ops.tex[sid];
      const dstTex = (did === CANVAS) ? ops.targetCtx().getCurrentTexture() : ops.tex[did];
      DEBUG && ops.debug() && console.log(`[GPU] copy_texture_to_texture: src=${sid === CANVAS ? 'CANVAS' : sid} dst=${did === CANVAS ? 'CANVAS' : did} ${w}x${h}`);
      if (srcTex && dstTex) enc.copyTextureToTexture({ texture: srcTex }, { texture: dstTex }, [w, h]);
      return pos + 8;
    }
    case 0x24: { // write_buffer_from_wasm
      const bid = view.getUint16(pos, true), off = view.getUint32(pos + 2, true);
      const callId = view.getUint32(pos + 6, true), sz = view.getUint32(pos + 10, true);
      const cr = ops.wcr[callId];
      DEBUG && ops.debug() && console.log(`[GPU] write_buffer_from_wasm: bid=${bid}, off=${off}, callId=${callId}, sz=${sz}, cr=`, cr);
      if (ops.buf[bid] && cr && sz > 0) {
        // Get WASM module's memory - prefer exported, fall back to imported
        const mod = ops.wm[cr.mid];
        // A data module may export its own memory or take ours as an import;
        // WebAssembly.Exports is an untyped bag, hence the cast.
        const exportedMem = /** @type {WebAssembly.Memory|undefined} */ (mod?.inst?.exports?.memory);
        const wasmMem = exportedMem?.buffer || mod?.importedMem?.buffer;
        DEBUG && ops.debug() && console.log(`[GPU] write_buffer_from_wasm: mod=${!!mod}, wasmMem=${!!wasmMem}, result=${cr.result}, memSize=${wasmMem?.byteLength}`);
        if (wasmMem && cr.result != null && cr.result + sz <= wasmMem.byteLength) {
          ops.device.queue.writeBuffer(ops.buf[bid], off, new Uint8Array(wasmMem, cr.result, sz));
        } else {
          DEBUG && ops.debug() && console.warn(`[GPU] write_buffer_from_wasm: invalid params - result=${cr.result}, sz=${sz}, memSize=${wasmMem?.byteLength}`);
        }
      }
      return pos + 14;
    }
    case 0x25: { // copy_external_image_to_texture (async)
      const bid = view.getUint16(pos, true), tid = view.getUint16(pos + 2, true);
      const mip = view.getUint8(pos + 4), ox = view.getUint16(pos + 5, true), oy = view.getUint16(pos + 7, true);
      const oz = view.getUint16(pos + 9, true); // destination array layer / depth slice
      const b = ops.bmp[bid];
      if (b && ops.tex[tid]) {
        ops.device.queue.copyExternalImageToTexture({ source: b }, { texture: ops.tex[tid], mipLevel: mip, origin: [ox, oy, oz] }, [b.width, b.height]);
      }
      return pos + 11;
    }

    // === WASM Operations (0x30-0x31) - matches command_buffer.zig ===
    case 0x30: { // init_wasm_module (async)
      const id = view.getUint16(pos, true), ptr = view.getUint32(pos + 2, true), len = view.getUint32(pos + 6, true);
      DEBUG && ops.debug() && console.log(`[GPU] init_wasm_module: id=${id}, ptr=${ptr}, len=${len}`);
      // Guarded like the create_* handlers: each occurrence compiles a module
      // AND allocates a fresh WebAssembly.Memory, dropping the previous
      // instance to GC with no way to release it explicitly.
      if (len === 0 || ops.wm[id]) return pos + 10;
      const bytes = new Uint8Array(ops.mem.buffer, ptr, len).slice();
      const importedMem = new WebAssembly.Memory({ initial: 1 });
      const wasmImports = { env: { abort: () => { throw new Error('WASM abort'); }, memory: importedMem } };
      return WebAssembly.compile(bytes).then(mod =>
        WebAssembly.instantiate(mod, wasmImports).then(inst => {
          // Same window as 0x0B: a dispatcher released mid-compile has an
          // emptied table, and this instance carries its own
          // WebAssembly.Memory. Nothing to release explicitly — just don't
          // hand it to an array nobody will walk again.
          if (!ops.alive()) return pos + 10;
          ops.wm[id] = { inst, importedMem };
          DEBUG && ops.debug() && console.log(`[GPU] init_wasm_module done: id=${id}, exports=`, Object.keys(inst.exports));
          return pos + 10;
        })
      );
    }
    case 0x31: { // call_wasm_func (async)
      const cid = view.getUint16(pos, true), mid = view.getUint16(pos + 2, true);
      const np = view.getUint32(pos + 4, true), nl = view.getUint32(pos + 8, true);
      const ac = view.getUint8(pos + 12);
      // Args are inline in the command stream (writeSlice), NOT behind a
      // pointer — hence the read at pos + 13 rather than through a ptr operand.
      const ab = new Uint8Array(ops.mem.buffer, pos + 13, ac).slice();
      const name = ops.rs(np, nl);
      DEBUG && ops.debug() && console.log(`[GPU] call_wasm_func: cid=${cid}, mid=${mid}, name="${name}", ac=${ac}`);
      const { inst } = ops.wm[mid] || {};
      const fn = /** @type {((...a: number[]) => number)|undefined} */ (inst?.exports[name]);
      const args = ops.decodeWasmArgs(ab);
      if (fn) {
        const result = fn(...args);
        ops.wcr[cid] = { mid, result };
        DEBUG && ops.debug() && console.log(`[GPU] call_wasm_func result: cid=${cid}, result=${result}`);
      } else {
        DEBUG && ops.debug() && console.log(`[GPU] call_wasm_func: fn not found! mid=${mid}, name="${name}"`);
      }
      return pos + 13 + ac;
    }

    // === Control (0xF0-0xFF) - matches command_buffer.zig ===
    case 0xF0: { // submit
      const enc = ops.takeEnc();
      DEBUG && ops.debug() && console.log(`[GPU] submit enc=${!!enc}`);
      if (enc) ops.device.queue.submit([enc.finish()]);
      // Readback MAP_READ buffers after submit (query numbers and texture
      // bytes are distinct consumers; the record's `kind` keeps them apart).
      const onQueryResult = ops.getOnQueryResult();
      const onTextureReadback = ops.getOnTextureReadback();
      if (ops.pendingReadbacks.length > 0 && (onQueryResult || onTextureReadback)) {
        const rbs = ops.pendingReadbacks.splice(0);
        for (const rb of rbs) {
          if (rb.kind === "texture") {
            if (onTextureReadback) deliverTextureReadback(ops, rb, onTextureReadback);
            continue;
          }
          if (!onQueryResult) continue;
          const b = ops.buf[rb.id];
          if (b?.mapState === 'unmapped') {
            b.mapAsync(GPUMapMode.READ, rb.offset, rb.size).then(() => {
              const data = new BigUint64Array(b.getMappedRange(rb.offset, rb.size));
              onQueryResult(Array.from(data, v => Number(v)));
              b.unmap();
            }).catch((e) => {
              // A throw in the success path above — getMappedRange, or the
              // host's own onQueryResult — lands here with the buffer still
              // MAPPED and unmap() unreached. That is permanent: 0x22 above
              // skips a MAP_READ destination whose mapState isn't 'unmapped',
              // so one bad callback kills readback for the rest of the session
              // and leaves the buffer mapped. Guarded on mapState because a
              // REJECTED mapAsync leaves the buffer unmapped per spec, where
              // an unconditional unmap() would itself throw.
              if (b.mapState === 'mapped') { try { b.unmap(); } catch { /* raced a teardown */ } }
              // Swallowed, this waits forever: onQueryResult never fires either,
              // so a failed readback looks exactly like one still in flight.
              ops.reportError({ message: `query readback failed for buffer ${rb.id}: ${e?.message || e}`, source: "readback" });
            });
          }
        }
      }
      // Readbacks scheduled with no consumer attached are dropped, not carried
      // into the next frame — they would map buffers nobody ever reads.
      ops.pendingReadbacks.length = 0;
      return pos;
    }
    case 0xff: // END
      return pos;
    default:
      return null;
  }
}
