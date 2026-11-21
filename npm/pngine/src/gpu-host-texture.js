// Host texture writes and reflection — the runtime half of
// `writeTexture(p, name, bytes, opts)` / `getTextures(p)` (plan 04 Task 2).
//
// Split out of gpu.js the way gpu-host-write.js was, and for the same reason:
// gpu.js has a source budget, and the refusal messages and descriptor record do
// not fit in it. gpu.js keeps the map (`texNames`, beside `bufNames`) and three
// one-line forwards; the bodies read the dispatcher's state through the same
// ops bag the extracted dispatchers use (types/gpu-ops.d.ts).
//
// Addressing is by the SJON `(texture :name …)` name, from the first commit:
// raw ids are an emission-order artefact, change when the document is edited,
// and never appear in a public record. The name → { id, pool, frameWritten }
// map comes from the payload's texture-name block (header flag bit 7); until it
// is installed every name is unknown.
//
// Two kinds of failure, kept apart on purpose:
//   - A REFUSAL is a fact about the document or the destination: no such name,
//     the frame writes it itself, a bad pool member, no copy-dst, multisampled,
//     1D, a bad mip/origin/extent/stride/aspect, too little data. It reaches
//     the host through onError as a PngineGPUError with source "write-texture"
//     and makes no queue call.
//   - A malformed MAP or RECORD (bytes that are not bytes, an offset/poolIndex/
//     aspect/size that is not what it must be) is the caller's bug: a TypeError
//     thrown before any entry is applied, so a call is either well-formed or
//     does nothing.
//
// The layout arithmetic is NOT here. `calculateWrite` (plan 01) is the one
// contract the compiler, the static command decoder and this host share; this
// module only turns the public option shapes into its input and its output into
// the WebGPU call. The descriptor likewise comes from plan 03's `txd`, kept
// current by createTexture and the canvas resize rebuild.

import { calculateWrite, formatInfo, missingFormatFeature } from "./texture-layout.js";

// Same build-flag fallback the sibling modules install (esbuild
// --define:DEBUG=false strips the debug paths in production).
if (typeof DEBUG === "undefined") globalThis.DEBUG = false;

/** GPUTextureUsage.COPY_DST — what `queue.writeTexture` requires of its target. */
const COPY_DST = 0x02;

/** The aspects the public API and the wire contract share, in wire tag order. */
/** @type {("all"|"depth-only"|"stencil-only")[]} */
const ASPECTS = ["all", "depth-only", "stencil-only"];

/** Every numeric option is a u32 in the wire/calculator contract. */
const U32_MAX = 0xffffffff;

/**
 * @typedef {object} TextureName
 * @property {number} id - dispatcher id of the pool's first member
 * @property {number} pool - member count: 1 for an ordinary texture, N for `:pool N`
 * @property {boolean} frameWritten - the frame's own queue ops write it every draw
 */

/**
 * The public reflection record. Every field is the descriptor's current state;
 * no raw ids are exposed (those are in `TextureName`, host-private).
 *
 * @typedef {object} TextureInfo
 * @property {[number, number, number]} size - current resolved extent
 * @property {"1d"|"2d"|"3d"} dimension
 * @property {string} format - the preferred sentinel already resolved
 * @property {number} mipLevelCount
 * @property {number} arrayDepth - 2D size[2]; otherwise 1
 * @property {number} usage - GPUTextureUsage bits
 * @property {number} sampleCount
 * @property {"explicit"|"canvas"|"image-bitmap"} sizeSource
 * @property {number} pool - 1 or N
 * @property {boolean} frameWritten
 * @property {boolean} writable - at least one host write is currently permitted
 * @property {("all"|"depth-only"|"stencil-only")[]} writableAspects
 */

/** @typedef {ArrayBufferView|ArrayBuffer} Bytes */

/**
 * The long form of one entry in a draw message's `textures` map. All options
 * are the public `writeTexture` options except `redraw`, which belongs to the
 * pending scheduler, not one write.
 *
 * @typedef {object} HostTextureWrite
 * @property {Bytes} bytes - what to write; a view is written as the window it covers
 * @property {number} [offset=0] - byte offset into the source view
 * @property {number} [bytesPerRow] - absent stays absent at the WebGPU boundary (D26)
 * @property {number} [rowsPerImage] - absent stays absent at the WebGPU boundary (D26)
 * @property {number[]} [origin] - [x, y, z]; length 0-3, missing members 0
 * @property {number} [mipLevel=0]
 * @property {"all"|"depth-only"|"stencil-only"} [aspect="all"]
 * @property {number[]} [size] - [w], [w h] or [w h d]; default remaining extent
 * @property {number|"active"} [poolIndex] - k for base+k, "active" for the coming frame
 */

/** @typedef {Record<string, Bytes|HostTextureWrite>} HostTextures */

/**
 * WebGPU's BufferSource: a typed array, a DataView, or a bare ArrayBuffer.
 * @param {unknown} b
 * @returns {b is GPUAllowSharedBufferSource}
 */
function isBytes(b) {
  return ArrayBuffer.isView(b) || b instanceof ArrayBuffer;
}

/** @param {unknown} v @returns {boolean} */
function isIndex(v) {
  return typeof v === "number" && Number.isSafeInteger(v) && v >= 0 && v <= U32_MAX;
}

/** @param {unknown} v @returns {boolean} */
function isArrayLike(v) {
  return Array.isArray(v) || ArrayBuffer.isView(v);
}

/**
 * D13's source state: a detached buffer has no bytes left to read, and a
 * resizable/growable one could move between this check and the queue copy.
 * Both are refused by name, before the calculator and the queue, rather than
 * read as a short/zero window (EOF) or a stale one.
 * @param {Bytes} bytes
 * @returns {"detached-source"|"resizable-source"|null}
 */
function sourceState(bytes) {
  const buffer = /** @type {any} */ (ArrayBuffer.isView(bytes) ? bytes.buffer : bytes);
  if (!buffer) return null;
  if (buffer.detached === true) return "detached-source";
  if (buffer.resizable === true || buffer.growable === true) return "resizable-source";
  return null;
}

/**
 * Install the name map (a Map or a plain object), replacing the previous one
 * whole — a reload must never inherit the last payload's names.
 * @param {GpuOps} ops
 * @param {Map<string, TextureName>|Record<string, TextureName>} names
 */
export function setTextureNames(ops, names) {
  ops.texNames.clear();
  for (const [name, r] of names instanceof Map ? names : Object.entries(names)) {
    ops.texNames.set(name, { id: r.id, pool: r.pool || 1, frameWritten: !!r.frameWritten });
  }
}

/**
 * Every named texture that currently exists: the public record, no ids.
 *
 * `writable` means at least one host write is permitted right now: created,
 * copy-dst, one sample, a 2D/3D dimension, not frameWritten, and at least one
 * writable aspect. `writableAspects` describes format/aspect legality alone, so
 * a combined depth/stencil texture advertises its stencil aspect even though a
 * frame may have forbidden the name for this draw.
 *
 * @param {GpuOps} ops
 * @returns {Record<string, TextureInfo>}
 */
export function listTextures(ops) {
  /** @type {Record<string, TextureInfo>} */
  const out = {};
  for (const [name, { id, pool, frameWritten }] of ops.texNames) {
    const d = ops.txd[id];
    if (!ops.tex[id] || !d) continue;
    /** @type {("all"|"depth-only"|"stencil-only")[]} */
    const writableAspects = [];
    for (const aspect of ASPECTS) {
      if ("ok" in formatInfo(d.format, aspect)) writableAspects.push(aspect);
    }
    const writable =
      !!(d.usage & COPY_DST) &&
      d.sampleCount === 1 &&
      d.dimension !== "1d" &&
      !frameWritten &&
      writableAspects.length > 0;
    out[name] = {
      size: [d.size.width, d.size.height, d.size.depthOrArrayLayers],
      dimension: /** @type {"1d"|"2d"|"3d"} */ (d.dimension),
      format: d.format,
      mipLevelCount: d.mipLevelCount,
      arrayDepth: d.dimension === "2d" ? d.size.depthOrArrayLayers : 1,
      usage: d.usage,
      sampleCount: d.sampleCount,
      sizeSource: /** @type {"explicit"|"canvas"|"image-bitmap"} */ (d.extentSource),
      pool,
      frameWritten,
      writable,
      writableAspects,
    };
  }
  return out;
}

/**
 * One map entry, defaulted and shape-checked, or a TypeError. Runs for every
 * entry BEFORE any write resolves, so a malformed record cannot ride behind a
 * valid one that already reached the queue.
 *
 * @param {string} name
 * @param {Bytes|HostTextureWrite} spec
 */
function normalize(name, spec) {
  if (name.length === 0) throw new TypeError("writeTexture: texture names must be nonempty strings");
  const w = isBytes(spec) ? { bytes: spec } : /** @type {HostTextureWrite} */ (spec);
  if (!w || !isBytes(w.bytes)) throw new TypeError(`writeTexture '${name}': bytes must be an ArrayBufferView or an ArrayBuffer`);

  const offset = w.offset ?? 0;
  if (!isIndex(offset)) throw new TypeError(`writeTexture '${name}': offset must be a non-negative u32 integer, got ${offset}`);
  const mipLevel = w.mipLevel ?? 0;
  if (!isIndex(mipLevel)) throw new TypeError(`writeTexture '${name}': mipLevel must be a non-negative u32 integer, got ${mipLevel}`);
  if (w.bytesPerRow !== undefined && !isIndex(w.bytesPerRow)) {
    throw new TypeError(`writeTexture '${name}': bytesPerRow must be a non-negative u32 integer, got ${w.bytesPerRow}`);
  }
  if (w.rowsPerImage !== undefined && !isIndex(w.rowsPerImage)) {
    throw new TypeError(`writeTexture '${name}': rowsPerImage must be a non-negative u32 integer, got ${w.rowsPerImage}`);
  }

  const aspect = w.aspect ?? "all";
  if (!ASPECTS.includes(/** @type {any} */ (aspect))) throw new TypeError(`writeTexture '${name}': aspect must be one of ${ASPECTS.join(", ")}, got ${aspect}`);

  const origin = w.origin ?? [];
  if (!isArrayLike(origin) || origin.length > 3) throw new TypeError(`writeTexture '${name}': origin must be an array of 0-3 numbers`);
  const originValues = Array.from(origin);
  for (const v of originValues) {
    if (!isIndex(v)) throw new TypeError(`writeTexture '${name}': origin members must be non-negative u32 integers, got ${v}`);
  }

  /** @type {{width: number, height?: number, depthOrArrayLayers?: number}|undefined} */
  let size;
  if (w.size !== undefined) {
    if (!isArrayLike(w.size) || w.size.length < 1 || w.size.length > 3) {
      throw new TypeError(`writeTexture '${name}': size must be an array of 1-3 numbers`);
    }
    const values = Array.from(w.size);
    for (const v of values) {
      if (!isIndex(v)) throw new TypeError(`writeTexture '${name}': size members must be non-negative u32 integers, got ${v}`);
    }
    size = { width: values[0] };
    if (values.length > 1) size.height = values[1];
    if (values.length > 2) size.depthOrArrayLayers = values[2];
  }

  const poolIndex = w.poolIndex;
  if (poolIndex !== undefined && poolIndex !== "active" && !isIndex(poolIndex)) {
    throw new TypeError(`writeTexture '${name}': poolIndex must be a non-negative integer or "active", got ${poolIndex}`);
  }

  return {
    name,
    bytes: w.bytes,
    offset,
    bytesPerRow: w.bytesPerRow,
    rowsPerImage: w.rowsPerImage,
    mipLevel,
    aspect,
    origin: {
      x: originValues[0] ?? 0,
      y: originValues[1] ?? 0,
      z: originValues[2] ?? 0,
    },
    size,
    poolIndex,
  };
}

/**
 * The member ids one write selects, or the refusal that stops it.
 * @param {string} name
 * @param {TextureName} r
 * @param {number|"active"|undefined} poolIndex
 * @param {number|undefined} counter
 * @returns {number[]|string}
 */
function members(name, r, poolIndex, counter) {
  const { id, pool } = r;
  if (poolIndex === undefined) return Array.from({ length: pool }, (_, k) => id + k);
  if (poolIndex === "active") {
    if (pool === 1) return [id];
    if (counter === undefined) return `active-counter — '${name}' poolIndex "active" needs getFrameCounter, which this embedded executor predates`;
    return [id + (counter % pool)];
  }
  if (pool === 1) return `not-pooled — '${name}' is not pooled (poolIndex given)`;
  if (poolIndex >= pool) return `pool-index-out-of-range — '${name}' poolIndex ${poolIndex} is out of range for a pool of ${pool}`;
  return [id + poolIndex];
}

/**
 * Put host bytes in textures, by name.
 *
 * Every name is either applied or refused through `ops.reportError` with
 * source "write-texture" — one message per refused member, and a refusal does
 * not stop the names after it. A refused write makes no queue call. The whole
 * map is shape-checked before the first byte moves.
 *
 * The calculator's copy extent is what the queue receives as `size`, but the
 * AUTHOR'S stride presence is preserved: an absent `bytesPerRow`/
 * `rowsPerImage` reaches `queue.writeTexture` as `undefined`, never the
 * calculator's normalized minimum (D26).
 *
 * @param {GpuOps} ops
 * @param {HostTextures} textures - the draw message's `textures` map
 * @param {number} [counter] - the coming frame's counter (`wasm.getFrameCounter()`),
 *   read before `frame()`; undefined when the executor has no such export
 * @returns {number} how many queue writes were made (a pool counts once per member)
 * @throws {TypeError} on a malformed map or record
 */
export function writeTextures(ops, textures, counter) {
  if (!textures || typeof textures !== "object" || Array.isArray(textures)) {
    throw new TypeError("writeTexture: textures must be an object keyed by texture name");
  }
  if (counter !== undefined && !(Number.isInteger(counter) && counter >= 0)) {
    throw new TypeError(`writeTexture: the frame counter must be a non-negative integer, got ${counter}`);
  }
  const writes = Object.entries(textures).map(([name, spec]) => normalize(name, spec));

  /** @param {string} why */
  const report = (why) => ops.reportError({ message: `writeTexture: ${why}`, source: "write-texture" });

  let count = 0;
  for (const w of writes) {
    const r = ops.texNames.get(w.name);
    if (!r) {
      report(`unknown-texture — '${w.name}' (see getTextures())`);
      continue;
    }
    if (r.frameWritten) {
      report(`frame-written — '${w.name}' is written by the frame after any host write: use a dedicated texture`);
      continue;
    }
    const source = sourceState(w.bytes);
    if (source) {
      report(`${source} — '${w.name}' has no stable source bytes to copy`);
      continue;
    }
    const selected = members(w.name, r, w.poolIndex, counter);
    if (typeof selected === "string") {
      report(selected);
      continue;
    }

    // The public option shape -> plan 01's input shape. Absence stays absence:
    // an undefined optional member is not passed as a normalized value.
    const write = {
      offset: w.offset,
      mipLevel: w.mipLevel,
      origin: w.origin,
      aspect: w.aspect,
      bytesPerRow: w.bytesPerRow,
      rowsPerImage: w.rowsPerImage,
      size: w.size,
    };

    for (const id of selected) {
      const texture = ops.tex[id];
      const descriptor = ops.txd[id];
      if (!texture || !descriptor) {
        report(`missing-texture — '${w.name}' names a texture this payload never created`);
        continue;
      }
      if (descriptor.dimension === "1d") {
        report(`unsupported-dimension — '${w.name}' is 1d; host writes support 2d and 3d textures`);
        continue;
      }

      // The format implies its device feature on this path too: a device whose
      // rebuild dropped it must not accept a compressed write because the
      // texture object happened to survive.
      const missing = missingFormatFeature(descriptor.format, descriptor.dimension, ops.device.features);
      if (missing !== null) {
        report(`texture '${w.name}' format '${descriptor.format}' requires '${missing}'; this adapter does not support it`);
        continue;
      }

      const calc = calculateWrite(descriptor, write, w.bytes.byteLength);
      if ("refuse" in calc) {
        const { code, field, actual, limit } = calc.refuse;
        report(`'${w.name}': ${code} — ${field}/${actual}/${limit}`);
        continue;
      }

      const copy = calc.ok.copyExtent;
      DEBUG && ops.debug() && console.log(`[GPU] writeTexture '${w.name}': tex[${id}] ${copy.width}x${copy.height}x${copy.depthOrArrayLayers}`);
      ops.device.queue.writeTexture(
        {
          texture,
          mipLevel: w.mipLevel,
          origin: [w.origin.x, w.origin.y, w.origin.z],
          aspect: w.aspect,
        },
        /** @type {GPUAllowSharedBufferSource} */ (w.bytes),
        { offset: w.offset, bytesPerRow: w.bytesPerRow, rowsPerImage: w.rowsPerImage },
        [copy.width, copy.height, copy.depthOrArrayLayers],
      );
      count++;
    }
  }
  return count;
}
