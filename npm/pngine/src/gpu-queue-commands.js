// Queue / WASM / control command handlers for the GPU dispatcher.
// Handles opcodes 0x20-0x27 (queue), 0x30-0x31 (WASM), 0xF0-0xFF (control).
//
// Split out of gpu.js alongside gpu-resource-pass-commands.js (0x01-0x52). The
// two modules share one `ops` bag — see types/gpu-ops.d.ts for its shape and
// for why the mutable closure scalars are reached through accessors.
//
// Operand widths here are pinned against src/executor/command_buffer.zig by
// tests/npm/command-buffer-widths.test.js. A wrong `return pos + N` desyncs
// every LATER command in the buffer, so treat those numbers as wire format.

// Same build-flag fallback gpu.js installs (esbuild --define:DEBUG=false strips
// the debug paths in production). Declared locally rather than relying on
// gpu.js's copy having run first: that import-side-effect coupling is what left
// AUDIO and EMBEDDED_ONLY undefined in some contexts.
if (typeof DEBUG === "undefined") globalThis.DEBUG = false;

/** Sentinel texture id meaning "the canvas", not an entry in the texture table. */
const CANVAS = 0xfffe;

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
      const { time, cw, ch } = ops.clock();
      DEBUG && ops.debug() && console.log(`[GPU] writeTimeUniform buf[${id}] time=${time} cw=${cw} ch=${ch}`);
      if (ops.buf[id]) {
        // Staged through the dispatcher's own scratch rather than a fresh
        // Float32Array per write: this runs every frame, once per queue step.
        const s = ops.scratch;
        s.time[0] = time; s.time[1] = cw; s.time[2] = ch; s.time[3] = cw / (ch || 1);
        ops.device.queue.writeBuffer(ops.buf[id], offset, s.timeBytes, 0, Math.min(size, 16));
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
        ops.pendingReadbacks.push({ id: did, offset: dof, size: sz });
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
      // Readback MAP_READ buffers after submit (for occlusion query results etc.)
      const onQueryResult = ops.getOnQueryResult();
      if (ops.pendingReadbacks.length > 0 && onQueryResult) {
        const rbs = ops.pendingReadbacks.splice(0);
        for (const rb of rbs) {
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
