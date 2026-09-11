// Pure descriptor decoders: TLV descriptor bytes → plain descriptor objects.
//
// The decode half of the decode/effect split — the JS mirror of the Zig
// dispatcher's typed-decode layer (wire_schema.zig, journal §196). These
// functions touch NO device, no navigator, no GPU objects; they turn the bytes
// the Zig DescriptorEncoder emits into ordinary objects the gpu.js handlers then
// realise into GPU resources. Kept pure so tests/npm/texture-descriptor.test.js
// can drive the REAL decoder instead of a hand-copied replica that drifts.
//
// Enum decoders come from enums.js — the single JS source of truth, byte-pinned
// to descriptors.zig by tests/npm/webgpu-conformance.test.js.

import { decodeTextureFormat, decodeFilterMode, decodeAddressMode, COMPARE_FUNCTION } from "./enums.js";

// GPUTextureUsage.RENDER_ATTACHMENT — bytecode usage flags match WebGPU numerics.
const RENDER_ATTACHMENT = 0x10;

/**
 * Decode a texture descriptor (TLV, type tag 0x01).
 * @param {Uint8Array} bytes - descriptor blob
 * @param {string} defaultFormat - canvas-preferred format the caller resolves
 *   (navigator.gpu.getPreferredCanvasFormat()); used when no format field present
 * @param {number} cw - canvas width fallback for size
 * @param {number} ch - canvas height fallback for size
 * @param {Array} [bmp] - ImageBitmap table for size-from-image (field 0x0A)
 * @returns {{desc: object, canvasBound: boolean, canvasScale: number}} -
 *   descriptor, whether size tracks the canvas (bytecode omitted explicit
 *   width AND height), and the fraction of the canvas it tracks (1 unless
 *   field 0x0B said otherwise; the resize path applies it again)
 */
export function decodeTextureDescriptor(bytes, defaultFormat, cw, ch, bmp) {
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let off = 2; // skip type tag + field count
  const desc = { size: [cw || 512, ch || 512], format: defaultFormat, usage: RENDER_ATTACHMENT, sampleCount: 1 };
  let hasW = false, hasH = false, scale = 1;
  const fc = bytes[1];
  for (let i = 0; i < fc; i++) {
    const fid = bytes[off++], vt = bytes[off++];
    if (vt === 0x00) { // u32
      const val = v.getUint32(off, true); off += 4;
      if (fid === 0x01) { desc.size[0] = val; hasW = true; }
      else if (fid === 0x02) { desc.size[1] = val; hasH = true; }
      else if (fid === 0x03) desc.size[2] = val; // depthOrArrayLayers
      else if (fid === 0x04) desc.mipLevelCount = val;
      else if (fid === 0x05) desc.sampleCount = val;
    } else if (vt === 0x01) { // f32
      const val = v.getFloat32(off, true); off += 4;
      // fid 0x0B = size_canvas_scale: this texture is a FRACTION of the canvas
      // in each dimension. Applied below, and again by the resize path.
      if (fid === 0x0B && val > 0) scale = val;
    } else if (vt === 0x06) { // u16 (resource ID reference)
      const val = v.getUint16(off, true); off += 2;
      // fid 0x0A = size_from_image_bitmap: use ImageBitmap dimensions
      if (fid === 0x0A && bmp && bmp[val]) {
        desc.size = [bmp[val].width, bmp[val].height];
        hasW = true; hasH = true;
      }
    } else if (vt === 0x07) { // enum
      const val = bytes[off++];
      if (fid === 0x06) desc.dimension = ['1d', '2d', '3d'][val] || '2d';
      else if (fid === 0x07) desc.format = decodeTextureFormat(val);
      // Bytecode texture usage flags match WebGPU GPUTextureUsage values directly
      else if (fid === 0x08) desc.usage = val || RENDER_ATTACHMENT;
    } else {
      // A value type this decoder does not read still has to be STRIDDEN, or
      // every field after it decodes from the middle of this one's bytes. The
      // walk used to advance only for the three types above, which held only
      // because no texture descriptor carried another — the f32 arm above was
      // added the day one did.
      off += SCALAR_BYTES[vt] ?? 0;
      if (SCALAR_BYTES[vt] === undefined) break; // array/nested: not self-describing
    }
  }
  const canvasBound = !hasW && !hasH;
  // Rebuild in place rather than as a fresh 3-element array: `size` holds two
  // entries unless a depth field arrived, and a third element of `undefined` is
  // "Value is not of type 'unsigned long'" from createTexture.
  if (canvasBound && scale !== 1) {
    desc.size[0] = scaleExtent(desc.size[0], scale);
    desc.size[1] = scaleExtent(desc.size[1], scale);
  }
  return { desc, canvasBound, canvasScale: scale };
}

/// Byte width of each scalar ValueType (src/types/descriptors.zig
/// `ValueType.scalarByteSize`). Array (0x03) and nested (0x04) are absent:
/// they are not self-describing, so a walk stops there rather than guessing.
const SCALAR_BYTES = { 0x00: 4, 0x01: 4, 0x02: 2, 0x05: 1, 0x06: 2, 0x07: 1 };

/**
 * One dimension of a canvas-tracking texture at `scale`. Rounded, and never
 * below one texel — a zero-texel dimension is invalid in every direction, and
 * a small canvas at a small scale reaches zero long before the author notices.
 * @param {number} n - the canvas dimension in texels
 * @param {number} scale - the fraction, > 0
 * @returns {number}
 */
export function scaleExtent(n, scale) {
  return Math.max(1, Math.round((n || 1) * scale));
}

/**
 * Decode a texture-view descriptor (TLV, type tag 0x09) into a
 * GPUTextureViewDescriptor. Every field is optional; an absent field means
 * WebGPU's own default, so an all-default view decodes to an empty object
 * (equivalent to a bare createView()).
 * @param {Uint8Array} bytes - descriptor blob
 * @returns {object} - GPUTextureViewDescriptor-shaped object
 */
export function decodeTextureViewDescriptor(bytes) {
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let off = 2; // skip type tag + field count
  const desc = /** @type {Record<string, string|number>} */ ({});
  const fc = bytes[1];
  for (let i = 0; i < fc; i++) {
    const fid = bytes[off++], vt = bytes[off++];
    if (vt === 0x00) { // u32
      const val = v.getUint32(off, true); off += 4;
      if (fid === 0x04) desc.baseMipLevel = val;
      else if (fid === 0x05) desc.mipLevelCount = val;
      else if (fid === 0x06) desc.baseArrayLayer = val;
      else if (fid === 0x07) desc.arrayLayerCount = val;
    } else if (vt === 0x07) { // enum
      const val = bytes[off++];
      if (fid === 0x01) desc.format = decodeTextureFormat(val);
      else if (fid === 0x02) desc.dimension = ['1d', '2d', '2d-array', 'cube', 'cube-array', '3d'][val] || '2d';
      else if (fid === 0x03) desc.aspect = ['all', 'stencil-only', 'depth-only'][val] || 'all';
    } else {
      // Same rule as decodeTextureDescriptor: a value type this decoder does
      // not read still has to be STRIDDEN. This walk had no such arm at all, so
      // the first unrecognized type left `off` mid-value and every field after
      // it decoded from the middle of that one's bytes -- silently, as a
      // plausible mipLevelCount or aspect. Held only because the encoder has
      // never written one here yet (§438).
      off += SCALAR_BYTES[vt] ?? 0;
      if (SCALAR_BYTES[vt] === undefined) break; // array/nested: not self-describing
    }
  }
  return desc;
}

/**
 * Decode a sampler descriptor (TLV, type tag 0x03).
 * @param {Uint8Array} bytes - descriptor blob
 * @returns {object} - GPUSamplerDescriptor-shaped object
 */
export function decodeSamplerDescriptor(bytes) {
  // Seeded with the GPUSamplerDescriptor defaults (spec/09 step D flipped the
  // filters from linear). The encoder always writes all four fields, so this
  // seed only shows through for a descriptor that omits one — which is to say,
  // never from this compiler.
  const desc = /** @type {Record<string, string|number>} */ ({ magFilter: "nearest", minFilter: "nearest", addressModeU: "clamp-to-edge", addressModeV: "clamp-to-edge" });
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let off = 2;
  const fc = bytes[1];
  // Walk stride-correct by value type (enum=1, u16=2, f32=4) so an unrecognized
  // field never desyncs the cursor — the append-only field-id contract.
  for (let i = 0; i < fc; i++) {
    const fid = bytes[off++], vt = bytes[off++];
    if (vt === 0x07) { // enum (u8)
      const val = bytes[off++];
      if (fid === 0x04) desc.magFilter = decodeFilterMode(val);
      else if (fid === 0x05) desc.minFilter = decodeFilterMode(val);
      else if (fid === 0x06) desc.mipmapFilter = decodeFilterMode(val);
      else if (fid === 0x01) desc.addressModeU = decodeAddressMode(val);
      else if (fid === 0x02) desc.addressModeV = decodeAddressMode(val);
      else if (fid === 0x03) desc.addressModeW = decodeAddressMode(val);
      else if (fid === 0x09) desc.compare = COMPARE_FUNCTION[val];
    } else if (vt === 0x01) { // f32
      const val = v.getFloat32(off, true); off += 4;
      if (fid === 0x07) desc.lodMinClamp = val;
      else if (fid === 0x08) desc.lodMaxClamp = val;
    } else if (vt === 0x06) { // u16
      const val = v.getUint16(off, true); off += 2;
      if (fid === 0x0A) desc.maxAnisotropy = val;
    } else {
      // The three read arms above cover every type the sampler encoder writes
      // today; this covers the rest by table rather than by three more
      // hand-written cases, so a new scalar type strides correctly the day it
      // is added instead of desyncing the cursor (§438).
      off += SCALAR_BYTES[vt] ?? 0;
      if (SCALAR_BYTES[vt] === undefined) break; // array/nested: not self-describing
    }
  }
  return desc;
}

/**
 * Decode a bind-group descriptor (TLV, type tag 0x07) into its group index and
 * entry list. Entries are `{binding, rt, rid}` (+ `{offset, size}` for buffers,
 * rt 0); resolving rt → GPU resource is the caller's effect step
 * (buildBindGroupEntries in gpu.js).
 * @param {Uint8Array} bytes - descriptor blob
 * @returns {{gi: number, entries: object[]}}
 */
export function decodeBindGroupData(bytes) {
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
  return { gi, entries };
}
