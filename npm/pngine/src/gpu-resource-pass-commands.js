// Core resource/pass command handlers for the GPU dispatcher.
// Handles opcodes 0x01-0x1A (creation + pass operations).

import { decodeTextureViewDescriptor } from "./descriptor-decode.js";

/**
 * A pass-scoped command outside an open pass is a dropped command — and a
 * missing begin_*_pass drops its ENTIRE pass this way, silently (an executor
 * variant without the compute plugin would erase a whole simulation with
 * zero output). Report through the host's onError; worker-core dedupes
 * consecutive identical gpu-error messages, so a persistently broken frame
 * surfaces once, not per-command-per-frame.
 *
 * @param {GpuOps} ops
 * @param {string} opName - WebGPU method name, used verbatim in the report
 */
function requirePass(ops, opName) {
  const pass = ops.getPass();
  if (!pass) {
    const message = `${opName} with no active pass — command dropped`;
    ops.log(`[GPU] ${message}`);
    ops.reportError({ message, source: "command" });
  }
  return pass;
}

/**
 * Dispatch core resource/pass commands.
 *
 * @param {number} cmd
 * @param {DataView} view
 * @param {number} pos - offset of this command's first OPERAND byte
 * @param {GpuOps} ops - see types/gpu-ops.d.ts
 * @returns {number|Promise<number>|null} next position, or null if unhandled
 */
export function dispatchResourcePassCommand(cmd, view, pos, ops) {
  switch (cmd) {
    // === Resource Creation (0x01-0x0D) ===
    case 0x01: { // create_buffer
      ops.createBuffer(view.getUint16(pos, true), view.getUint32(pos + 2, true), view.getUint16(pos + 6, true));
      return pos + 8;
    }
    case 0x02: { // create_texture
      ops.createTexture(view.getUint16(pos, true), view.getUint32(pos + 2, true), view.getUint32(pos + 6, true));
      return pos + 10;
    }
    case 0x03: { // create_sampler
      ops.createSampler(view.getUint16(pos, true), view.getUint32(pos + 2, true), view.getUint32(pos + 6, true));
      return pos + 10;
    }
    case 0x04: { // create_shader
      ops.createShader(view.getUint16(pos, true), view.getUint32(pos + 2, true), view.getUint32(pos + 6, true));
      return pos + 10;
    }
    case 0x05: { // create_render_pipeline
      ops.createRenderPipeline(view.getUint16(pos, true), view.getUint32(pos + 2, true), view.getUint32(pos + 6, true));
      return pos + 10;
    }
    case 0x06: { // create_compute_pipeline
      ops.createComputePipeline(view.getUint16(pos, true), view.getUint32(pos + 2, true), view.getUint32(pos + 6, true));
      return pos + 10;
    }
    case 0x07: { // create_bind_group
      ops.createBindGroup(view.getUint16(pos, true), view.getUint16(pos + 2, true), view.getUint32(pos + 4, true), view.getUint32(pos + 8, true));
      return pos + 12;
    }
    case 0x08: { // create_texture_view
      const id = view.getUint16(pos, true);
      const tid = view.getUint16(pos + 2, true);
      const ptr = view.getUint32(pos + 4, true);
      const len = view.getUint32(pos + 8, true);
      // An explicit (texture-view …): decode the GPUTextureViewDescriptor so a
      // 1d/3d/array/cube view is created with the right dimension/aspect/range.
      // An all-default view decodes to {} → a plain createView(). Bound by view id
      // via resource_type explicit_texture_view (rt 4).
      if (!ops.txv[id] && ops.tex[tid]) {
        const desc = len ? decodeTextureViewDescriptor(new Uint8Array(ops.mem.buffer, ptr, len)) : {};
        ops.txv[id] = ops.tex[tid].createView(desc);
        // Remembered, not recomputed: the descriptor bytes live in the command
        // stream, which is rewritten every frame, so by the time a resize needs
        // to rebuild this view they are long gone.
        ops.txs[id] = { tid, desc };
      }
      return pos + 12;
    }
    case 0x09: { // create_query_set
      const id = view.getUint16(pos, true);
      const ptr = view.getUint32(pos + 2, true);
      const len = view.getUint32(pos + 6, true);
      // Guarded like every other create: the wire protocol has no destroy, so
      // overwriting a populated slot would strand the previous object with no
      // way to release it. A repeat create is a no-op, which is what turns a
      // create landing in replayed bytecode from an unbounded leak into noise.
      if (ops.qs[id]) return pos + 10;
      const d = new Uint8Array(ops.mem.buffer, ptr, len);
      // Descriptor: [type:u8] [count:u16 LE]
      const type = d[0] === 1 ? 'timestamp' : 'occlusion';
      const count = d[1] | (d[2] << 8);
      ops.qs[id] = ops.device.createQuerySet({ type, count });
      return pos + 10;
    }
    case 0x0A: { // create_bind_group_layout
      const id = view.getUint16(pos, true);
      const ptr = view.getUint32(pos + 2, true);
      const len = view.getUint32(pos + 6, true);
      if (!ops.bgl[id]) ops.bgl[id] = ops.device.createBindGroupLayout(JSON.parse(ops.rs(ptr, len)));
      return pos + 10;
    }
    case 0x0B: { // create_image_bitmap (async)
      const id = view.getUint16(pos, true);
      const ptr = view.getUint32(pos + 2, true);
      const len = view.getUint32(pos + 6, true);
      // Guarded (see 0x09): a decoded bitmap is megabytes of pixel memory, and
      // an overwritten slot loses the only handle that could close() it.
      if (len === 0 || ops.bmp[id]) return pos + 10;
      // Blob format: [mime_len:u8][mime:bytes][image_data:bytes]
      const raw = new Uint8Array(ops.mem.buffer, ptr, len);
      const mimeLen = raw[0];
      const mimeStr = new TextDecoder().decode(raw.slice(1, 1 + mimeLen));
      const imageData = raw.slice(1 + mimeLen);
      const blob = new Blob([imageData], { type: mimeStr });
      return createImageBitmap(blob).then((bitmap) => {
        // destroy() may have run during the decode. This closure holds the OLD
        // dispatcher's table, already emptied — writing here strands megabytes
        // of pixel memory whose only explicit release is the close() below.
        if (!ops.alive()) bitmap.close();
        else ops.bmp[id] = bitmap;
        return pos + 10;
      });
    }
    case 0x0C: { // create_pipeline_layout
      const id = view.getUint16(pos, true);
      const ptr = view.getUint32(pos + 2, true);
      const len = view.getUint32(pos + 6, true);
      if (ops.ppl[id]) return pos + 10; // guarded (see 0x09)
      const desc = JSON.parse(ops.rs(ptr, len));
      ops.ppl[id] = ops.device.createPipelineLayout({ bindGroupLayouts: desc.bindGroupLayouts.map((i) => ops.bgl[i]) });
      return pos + 10;
    }
    case 0x0D: { // create_render_bundle
      const id = view.getUint16(pos, true);
      const ptr = view.getUint32(pos + 2, true);
      const len = view.getUint32(pos + 6, true);
      if (ops.bun[id]) return pos + 10; // guarded (see 0x09)
      const d = new Uint8Array(ops.mem.buffer, ptr, len);
      const dv = new DataView(d.buffer, d.byteOffset, d.byteLength);
      let off = 0;

      // Parse colorFormats
      const cfCount = d[off++];
      /** @type {GPUTextureFormat[]} */
      const colorFormats = [];
      for (let i = 0; i < cfCount; i++) colorFormats.push(ops.dtf(d[off++]));
      if (cfCount === 0) colorFormats.push(navigator.gpu.getPreferredCanvasFormat());

      // Parse depthStencilFormat
      const dsFmt = d[off++];
      const depthStencilFormat = dsFmt !== 0xFF ? ops.dtf(dsFmt) : undefined;

      // Parse sampleCount
      const sampleCount = d[off++];

      // Create encoder
      const encoderDesc = { colorFormats };
      if (depthStencilFormat) encoderDesc.depthStencilFormat = depthStencilFormat;
      if (sampleCount > 1) encoderDesc.sampleCount = sampleCount;
      const encoder = ops.device.createRenderBundleEncoder(encoderDesc);

      // Parse and record pipeline
      const pipeId = dv.getUint16(off, true); off += 2;
      // A render bundle can only carry a render pipeline; the pipeline table
      // holds both kinds, and only the emitter knows which id this is.
      if (ops.pip[pipeId]) encoder.setPipeline(/** @type {GPURenderPipeline} */ (ops.pip[pipeId]));

      // Parse and record bind groups
      const bgCount = d[off++];
      for (let i = 0; i < bgCount; i++) {
        const bgId = dv.getUint16(off, true); off += 2;
        if (ops.bg[bgId]) encoder.setBindGroup(i, ops.bg[bgId]);
      }

      // Parse and record vertex buffers
      const vbCount = d[off++];
      for (let i = 0; i < vbCount; i++) {
        const bufId = dv.getUint16(off, true); off += 2;
        if (ops.buf[bufId]) encoder.setVertexBuffer(i, ops.buf[bufId]);
      }

      // Parse and optionally record index buffer
      const hasIB = d[off++];
      if (hasIB) {
        const ibId = dv.getUint16(off, true); off += 2;
        if (ops.buf[ibId]) encoder.setIndexBuffer(ops.buf[ibId], 'uint16');
      }

      // Parse and record draw command
      const drawType = d[off++];
      if (drawType === 1) { // drawIndexed
        encoder.drawIndexed(dv.getUint32(off, true), dv.getUint32(off+4, true), dv.getUint32(off+8, true), dv.getInt32(off+12, true), dv.getUint32(off+16, true));
      } else { // draw
        encoder.draw(dv.getUint32(off, true), dv.getUint32(off+4, true), dv.getUint32(off+8, true), dv.getUint32(off+12, true));
      }

      ops.bun[id] = encoder.finish();
      return pos + 10;
    }

    // === Pass Operations (0x10-0x1A) ===
    case 0x10: { // begin_render_pass (with optional resolveTarget)
      const resolveId = view.getUint16(pos + 10, true);
      ops.curPip = -1;
      ops.beginRenderPass(view.getUint16(pos, true), view.getUint8(pos + 2), view.getUint8(pos + 3), view.getUint16(pos + 4, true), view.getUint8(pos + 6), view.getUint8(pos + 7), view.getUint8(pos + 8), view.getUint8(pos + 9), resolveId);
      return pos + 12;
    }
    case 0x11: { // begin_compute_pass
      ops.curPip = -1;
      ops.beginComputePass();
      return pos;
    }
    case 0x12: { // set_pipeline
      const pipId = view.getUint16(pos, true);
      ops.curPip = pipId;
      ops.log(`[GPU] setPipeline(${pipId})`);
      requirePass(ops, "setPipeline")?.setPipeline(ops.pip[pipId]);
      return pos + 2;
    }
    case 0x13: { // set_bind_group
      const gi = view.getUint8(pos);
      const bgId = view.getUint16(pos + 1, true);
      let group = ops.bg[bgId];
      // A bind group built against `layout: "auto"` belongs to the pipeline
      // whose layout produced it; binding it under a different pipeline is
      // invalid, so it has to be rebuilt for the bound one.
      //
      // CACHED PER (bind group, pipeline). This used to store the rebuilt group
      // in a local and never write it back, and never update d.layoutId — so
      // the condition stayed true and every frame that bound the group made a
      // fresh GPUBindGroup, none of them released. A single write-back slot
      // would not do either: a payload alternating two pipelines over one group
      // needs both, and one slot would thrash every frame.
      // Only AUTO-layout groups need this. A group built from an explicitly
      // authored (bind-group-layout …) — layoutId carries BGL_TAG (0x8000) — is
      // already usable with every pipeline built from that layout, and rebuilding
      // it under `curPip`'s auto layout would swap the authored layout for the
      // derived one: the exact substitution the explicit form exists to prevent,
      // and one WebGPU rejects if the pipeline has an explicit layout. §339.
      const d = ops.bgd[bgId];
      if (d && ops.curPip >= 0 && (d.layoutId & 0x8000) === 0 && d.layoutId !== ops.curPip) {
        const p = ops.pip[ops.curPip];
        if (p) {
          const cache = d.alt ??= new Map();
          group = cache.get(ops.curPip);
          if (!group) {
            group = ops.device.createBindGroup({ layout: p.getBindGroupLayout(d.gi), entries: ops.buildBindGroupEntries(d.entries) });
            cache.set(ops.curPip, group);
            ops.log(`[GPU] setBindGroup(${gi}, ${bgId}) recreated for pipeline ${ops.curPip}`);
          }
        }
      }
      ops.log(`[GPU] setBindGroup(${gi}, ${bgId}) pass=${ops.getPass() ? 'valid' : 'NULL'} bg[${bgId}]=${group ? 'exists' : 'MISSING'}`);
      requirePass(ops, "setBindGroup")?.setBindGroup(gi, group);
      return pos + 3;
    }
    case 0x14: { // set_vertex_buffer
      requirePass(ops, "setVertexBuffer")?.setVertexBuffer(view.getUint8(pos), ops.buf[view.getUint16(pos + 1, true)]);
      return pos + 3;
    }
    case 0x15: { // draw
      const vc = view.getUint32(pos, true);
      const ic = view.getUint32(pos + 4, true);
      ops.log(`[GPU] draw(${vc}, ${ic}) pass=${ops.getPass() ? 'valid' : 'NULL'}`);
      requirePass(ops, "draw")?.draw(vc, ic, view.getUint32(pos + 8, true), view.getUint32(pos + 12, true));
      return pos + 16;
    }
    case 0x16: { // draw_indexed
      requirePass(ops, "drawIndexed")?.drawIndexed(view.getUint32(pos, true), view.getUint32(pos + 4, true), view.getUint32(pos + 8, true), view.getInt32(pos + 12, true), view.getUint32(pos + 16, true));
      return pos + 20;
    }
    case 0x17: { // end_pass
      ops.log("[GPU] endPass");
      requirePass(ops, "endPass")?.end();
      ops.setPass(null);
      return pos;
    }
    case 0x18: { // dispatch
      requirePass(ops, "dispatchWorkgroups")?.dispatchWorkgroups(view.getUint32(pos, true), view.getUint32(pos + 4, true), view.getUint32(pos + 8, true));
      return pos + 12;
    }
    case 0x19: { // set_index_buffer
      requirePass(ops, "setIndexBuffer")?.setIndexBuffer(ops.buf[view.getUint16(pos, true)], view.getUint8(pos + 2) === 1 ? "uint32" : "uint16");
      return pos + 3;
    }
    case 0x1A: { // execute_bundles
      const count = view.getUint8(pos);
      const bundles = [];
      for (let i = 0; i < count; i++) {
        const bid = view.getUint16(pos + 1 + i * 2, true);
        if (ops.bun[bid]) bundles.push(ops.bun[bid]);
      }
      if (bundles.length > 0) requirePass(ops, "executeBundles")?.executeBundles(bundles);
      return pos + 1 + count * 2;
    }
    case 0x1B: { // begin_render_pass_mrt
      ops.curPip = -1;
      let off = pos;
      const count = view.getUint8(off++);
      const attachments = [];
      for (let i = 0; i < count; i++) {
        const tid = view.getUint16(off, true); off += 2;
        const load = view.getUint8(off++);
        const store = view.getUint8(off++);
        const r = view.getUint8(off++), g = view.getUint8(off++);
        const b = view.getUint8(off++), a = view.getUint8(off++);
        attachments.push({ tid, load, store, r, g, b, a });
      }
      const depthId = view.getUint16(off, true); off += 2;
      ops.beginRenderPassMRT(attachments, depthId);
      return off;
    }
    case 0x1F: { // set_viewport
      const x = view.getUint32(pos, true);
      const y = view.getUint32(pos + 4, true);
      const w = view.getUint32(pos + 8, true);
      const h = view.getUint32(pos + 12, true);
      const minD = view.getFloat32(pos + 16, true);
      const maxD = view.getFloat32(pos + 20, true);
      ops.getPass()?.setViewport(x, y, w, h, minD, maxD);
      return pos + 24;
    }
    case 0x4A: { // set_pass_timestamp_writes
      const qsId = view.getUint16(pos, true);
      const beginIdx = view.getUint16(pos + 2, true);
      const endIdx = view.getUint16(pos + 4, true);
      if (ops.qs[qsId]) ops.setPendingTimestampWrites({ querySet: ops.qs[qsId], beginningOfPassWriteIndex: beginIdx, endOfPassWriteIndex: endIdx });
      return pos + 6;
    }
    case 0x4B: { // set_pass_occlusion_query_set
      const qsId = view.getUint16(pos, true);
      if (ops.qs[qsId]) ops.setPendingOcclusionQS(ops.qs[qsId]);
      return pos + 2;
    }
    case 0x4C: { // end_occlusion_query
      ops.getPass()?.endOcclusionQuery();
      return pos;
    }
    case 0x4D: { // begin_occlusion_query
      const idx = view.getUint32(pos, true);
      ops.getPass()?.beginOcclusionQuery(idx);
      return pos + 4;
    }
    case 0x4E: { // set_stencil_reference
      ops.getPass()?.setStencilReference(view.getUint32(pos, true));
      return pos + 4;
    }
    case 0x4F: { // set_scissor_rect
      const x = view.getUint32(pos, true);
      const y = view.getUint32(pos + 4, true);
      const w = view.getUint32(pos + 8, true);
      const h = view.getUint32(pos + 12, true);
      ops.getPass()?.setScissorRect(x, y, w, h);
      return pos + 16;
    }
    case 0x50: { // set_pass_depth_stencil_ops
      const LO = ["load", "clear"];
      const SO = ["store", "discard"];
      ops.setPendingDepthStencilOps(LO[view.getUint8(pos)] || "clear", SO[view.getUint8(pos + 1)] || "store", LO[view.getUint8(pos + 2)] || "clear", SO[view.getUint8(pos + 3)] || "store");
      return pos + 4;
    }
    case 0x51: { // set_blend_constant — [r g b a] as f32
      const r = view.getFloat32(pos, true);
      const g = view.getFloat32(pos + 4, true);
      const b = view.getFloat32(pos + 8, true);
      const a = view.getFloat32(pos + 12, true);
      ops.getPass()?.setBlendConstant({ r, g, b, a });
      return pos + 16;
    }
    case 0x52: { // set_pass_clear_values — [depth:f32] [stencil:u32]
      ops.setPendingClearValues(view.getFloat32(pos, true), view.getUint32(pos + 4, true));
      return pos + 8;
    }
    case 0x1C: { // draw_indirect
      const bufId = view.getUint16(pos, true);
      const offset = view.getUint32(pos + 2, true);
      ops.getPass()?.drawIndirect(ops.buf[bufId], offset);
      return pos + 6;
    }
    case 0x1D: { // draw_indexed_indirect
      const bufId = view.getUint16(pos, true);
      const offset = view.getUint32(pos + 2, true);
      ops.getPass()?.drawIndexedIndirect(ops.buf[bufId], offset);
      return pos + 6;
    }
    case 0x1E: { // dispatch_indirect
      const bufId = view.getUint16(pos, true);
      const offset = view.getUint32(pos + 2, true);
      ops.getPass()?.dispatchWorkgroupsIndirect(ops.buf[bufId], offset);
      return pos + 6;
    }
    default:
      return null;
  }
}
