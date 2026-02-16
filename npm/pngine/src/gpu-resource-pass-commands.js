// Core resource/pass command handlers for the GPU dispatcher.
// Handles opcodes 0x01-0x1A (creation + pass operations).

/**
 * Dispatch core resource/pass commands.
 *
 * @param {number} cmd
 * @param {DataView} view
 * @param {number} pos
 * @param {object} ops
 * @returns {number|Promise<number>|null}
 */
export function dispatchResourcePassCommand(cmd, view, pos, ops) {
  switch (cmd) {
    // === Resource Creation (0x01-0x0D) ===
    case 0x01: { // create_buffer
      ops.createBuffer(view.getUint16(pos, true), view.getUint32(pos + 2, true), view.getUint8(pos + 6));
      return pos + 7;
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
      if (!ops.txv[id] && ops.tex[tid]) ops.txv[id] = ops.tex[tid].createView();
      return pos + 12;
    }
    case 0x09: { // create_query_set (stub)
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
      if (len === 0) return pos + 10;
      const blob = new Blob([new Uint8Array(ops.mem.buffer, ptr, len)]);
      return createImageBitmap(blob).then((bitmap) => {
        ops.bmp[id] = bitmap;
        return pos + 10;
      });
    }
    case 0x0C: { // create_pipeline_layout
      const id = view.getUint16(pos, true);
      const ptr = view.getUint32(pos + 2, true);
      const len = view.getUint32(pos + 6, true);
      const desc = JSON.parse(ops.rs(ptr, len));
      ops.ppl[id] = ops.device.createPipelineLayout({ bindGroupLayouts: desc.bindGroupLayouts.map((i) => ops.bgl[i]) });
      return pos + 10;
    }
    case 0x0D: { // create_render_bundle (stub)
      return pos + 10;
    }

    // === Pass Operations (0x10-0x1A) ===
    case 0x10: { // begin_render_pass
      ops.beginRenderPass(view.getUint16(pos, true), view.getUint8(pos + 2), view.getUint8(pos + 3), view.getUint16(pos + 4, true));
      return pos + 6;
    }
    case 0x11: { // begin_compute_pass
      ops.beginComputePass();
      return pos;
    }
    case 0x12: { // set_pipeline
      const pipId = view.getUint16(pos, true);
      ops.log(`[GPU] setPipeline(${pipId})`);
      ops.getPass()?.setPipeline(ops.pip[pipId]);
      return pos + 2;
    }
    case 0x13: { // set_bind_group
      const gi = view.getUint8(pos);
      const bgId = view.getUint16(pos + 1, true);
      ops.log(`[GPU] setBindGroup(${gi}, ${bgId}) pass=${ops.getPass() ? 'valid' : 'NULL'} bg[${bgId}]=${ops.bg[bgId] ? 'exists' : 'MISSING'}`);
      ops.getPass()?.setBindGroup(gi, ops.bg[bgId]);
      return pos + 3;
    }
    case 0x14: { // set_vertex_buffer
      ops.getPass()?.setVertexBuffer(view.getUint8(pos), ops.buf[view.getUint16(pos + 1, true)]);
      return pos + 3;
    }
    case 0x15: { // draw
      const vc = view.getUint32(pos, true);
      const ic = view.getUint32(pos + 4, true);
      ops.log(`[GPU] draw(${vc}, ${ic}) pass=${ops.getPass() ? 'valid' : 'NULL'}`);
      ops.getPass()?.draw(vc, ic, view.getUint32(pos + 8, true), view.getUint32(pos + 12, true));
      return pos + 16;
    }
    case 0x16: { // draw_indexed
      ops.getPass()?.drawIndexed(view.getUint32(pos, true), view.getUint32(pos + 4, true), view.getUint32(pos + 8, true), view.getInt32(pos + 12, true), view.getUint32(pos + 16, true));
      return pos + 20;
    }
    case 0x17: { // end_pass
      ops.log("[GPU] endPass");
      ops.getPass()?.end();
      ops.setPass(null);
      return pos;
    }
    case 0x18: { // dispatch
      ops.getPass()?.dispatchWorkgroups(view.getUint32(pos, true), view.getUint32(pos + 4, true), view.getUint32(pos + 8, true));
      return pos + 12;
    }
    case 0x19: { // set_index_buffer
      ops.getPass()?.setIndexBuffer(ops.buf[view.getUint16(pos, true)], view.getUint8(pos + 2) === 1 ? "uint32" : "uint16");
      return pos + 3;
    }
    case 0x1A: { // execute_bundles
      const count = view.getUint8(pos);
      return pos + 1 + count * 2;
    }
    default:
      return null;
  }
}
