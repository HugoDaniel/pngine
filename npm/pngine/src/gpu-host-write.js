// Host buffer writes — the runtime half of `writeBuffer(p, name, bytes)`
// (docs/plans/public-write-buffer.md).
//
// Split out of gpu.js the way gpu-queue-commands.js and uniform-convert.js
// were, and for the same reason: gpu.js has a source budget
// (scripts/bundle.cjs GPU_SOURCE_BUDGET) with a few hundred bytes of headroom,
// and the refusal messages below do not fit in it. gpu.js keeps the tables
// (`bufSize` beside `bufUsage`, the `bufNames` map) and three one-line
// forwards; the bodies read that state through the same ops bag the extracted
// dispatchers use (types/gpu-ops.d.ts).
//
// Addressing is by the SJON `(buffer :name …)` name, from the first commit: an
// id is an emission-order artefact of the compiler's buffer table, changes
// when the document is edited, and a host cannot derive it from the source it
// wrote (plan R1). The name → { id, pool, frameWritten } map comes from the
// payload's buffer-name block; until it is installed every name is unknown.
//
// Two kinds of failure, kept apart on purpose:
//   - A REFUSAL is a fact about the document or the buffer: no such name, the
//     frame writes it itself, a bad pool member, no copy-dst, misaligned, out
//     of range. It reaches the host through onError as a PngineGPUError with
//     source "write-buffer" — the route every other command fault takes — and
//     never reaches the queue. setUniform's DEBUG-gated console.warn +
//     `return false` is the thing this deliberately does not copy: a host
//     that cannot hear a refusal ships a write that never lands.
//   - A malformed RECORD (bytes that are not bytes, an offset or poolIndex
//     that is not what it must be) is the caller's bug: a TypeError, thrown
//     before any entry is applied, so a call is either well-formed or does
//     nothing.

// Same build-flag fallback the sibling modules install (esbuild
// --define:DEBUG=false strips the debug paths in production).
if (typeof DEBUG === "undefined") globalThis.DEBUG = false;

/** GPUBufferUsage.COPY_DST — what `queue.writeBuffer` requires of its target. */
const COPY_DST = 0x0008;

/**
 * @typedef {object} BufferName
 * @property {number} id - dispatcher id of the pool's first member
 * @property {number} pool - member count: 1 for an ordinary buffer, N for `:pool N`
 * @property {boolean} frameWritten - the frame's own queue ops write it every draw
 */

/** @typedef {ArrayBufferView|ArrayBuffer} Bytes */

/**
 * The long form of one entry in a draw message's `buffers` map.
 * @typedef {object} HostWrite
 * @property {Bytes} bytes - what to write; a view is written as the window it
 *   covers, so a slice out of an arena is fine
 * @property {number} [offset=0] - byte offset into the buffer
 * @property {number|"active"} [poolIndex] - which member of a pooled name:
 *   `k` for base + k, `"active"` for the member the coming frame reads at
 *   `:ping-pong 0`, absent for every member
 */

/** @typedef {Record<string, Bytes|HostWrite>} HostWrites */

/**
 * WebGPU's BufferSource: a typed array, a DataView, or a bare ArrayBuffer.
 * @param {unknown} b
 * @returns {b is GPUAllowSharedBufferSource}
 */
function isBytes(b) {
  return ArrayBuffer.isView(b) || b instanceof ArrayBuffer;
}

/**
 * Install the name map (a Map or a plain object), replacing the previous one
 * whole — a reload must never inherit the last payload's names.
 * @param {GpuOps} ops
 * @param {Map<string, BufferName>|Record<string, BufferName>} names
 */
export function setBufferNames(ops, names) {
  ops.bufNames.clear();
  for (const [name, r] of names instanceof Map ? names : Object.entries(names)) {
    ops.bufNames.set(name, { id: r.id, pool: r.pool || 1, frameWritten: !!r.frameWritten });
  }
}

/**
 * Every named buffer that exists: `{ size, usage, writable, pool, frameWritten }`.
 * `writable` is the usage's copy-dst bit and nothing else. No ids.
 * @param {GpuOps} ops
 * @returns {Record<string, {size: number, usage: number, writable: boolean, pool: number, frameWritten: boolean}>}
 */
export function listBuffers(ops) {
  /** @type {Record<string, {size: number, usage: number, writable: boolean, pool: number, frameWritten: boolean}>} */
  const out = {};
  for (const [name, { id, pool, frameWritten }] of ops.bufNames) {
    if (!ops.buf[id]) continue;
    const usage = ops.bufUsage[id];
    out[name] = { size: ops.bufSize[id], usage, writable: !!(usage & COPY_DST), pool, frameWritten };
  }
  return out;
}

/**
 * One map entry, defaulted and shape-checked, or a TypeError.
 * @param {string} name
 * @param {Bytes|HostWrite} spec
 */
function normalize(name, spec) {
  const w = isBytes(spec) ? { bytes: spec } : /** @type {HostWrite} */ (spec);
  if (!w || !isBytes(w.bytes)) throw new TypeError(`writeBuffer '${name}': bytes must be an ArrayBufferView or an ArrayBuffer`);
  const offset = w.offset ?? 0;
  if (!Number.isInteger(offset) || offset < 0) throw new TypeError(`writeBuffer '${name}': offset must be a non-negative integer, got ${offset}`);
  const poolIndex = w.poolIndex;
  if (poolIndex !== undefined && poolIndex !== "active" && !(Number.isInteger(poolIndex) && poolIndex >= 0)) {
    throw new TypeError(`writeBuffer '${name}': poolIndex must be a non-negative integer or "active", got ${poolIndex}`);
  }
  return { name, bytes: w.bytes, offset, poolIndex };
}

/**
 * The member ids one write selects, or the refusal that stops it.
 * @param {string} name
 * @param {BufferName} r
 * @param {number|"active"|undefined} poolIndex
 * @param {number|undefined} counter - the coming frame's counter, if the executor exports one
 * @returns {number[]|string}
 */
function members(name, r, poolIndex, counter) {
  const { id, pool } = r;
  if (poolIndex === undefined) return Array.from({ length: pool }, (_, k) => id + k);
  if (poolIndex === "active") {
    if (pool === 1) return [id];
    if (counter === undefined) return `writeBuffer: '${name}' poolIndex "active" needs getFrameCounter, which this embedded executor predates`;
    return [id + (counter % pool)];
  }
  if (pool === 1) return `writeBuffer: '${name}' is not pooled (poolIndex given)`;
  if (poolIndex >= pool) return `writeBuffer: '${name}' poolIndex ${poolIndex} is out of range for a pool of ${pool}`;
  return [id + poolIndex];
}

/**
 * Why a write to member `id` cannot be applied, or null. Checked on the first
 * selected member only: a pool's members share size and usage.
 *
 * The order is the order an author fixes things in: a buffer without
 * copy-dst refuses every write, so its usage comes before the arithmetic of
 * this one; alignment is the more local mistake than range.
 *
 * @param {GpuOps} ops
 * @param {string} name
 * @param {number} id
 * @param {number} offset
 * @param {number} len
 * @returns {string|null}
 */
function refusal(ops, name, id, offset, len) {
  if (!ops.buf[id]) return `writeBuffer: '${name}' names a buffer this payload never created`;
  if (!(ops.bufUsage[id] & COPY_DST)) {
    // The same words the compiler uses for an authored copy into such a
    // buffer, at the host boundary: the fix is a usage keyword, not a call.
    return `writeBuffer: '${name}' is not host-writable: add copy-dst to (buffer :name ${name} :usage [...])`;
  }
  if (offset % 4 || len % 4) return `writeBuffer: '${name}': offset ${offset} and a length of ${len} bytes must each be a multiple of 4`;
  const size = ops.bufSize[id];
  if (offset + len > size) return `writeBuffer: '${name}': ${offset} + ${len} bytes exceeds its ${size}-byte size`;
  return null;
}

/**
 * Put host bytes in buffers, by name.
 *
 * Every name is either applied, or refused through `ops.reportError` with
 * source "write-buffer" — one message per refused name, and a refusal does
 * not stop the names after it. A zero-length write is a no-op that is neither
 * queued nor counted (the 0x20 handler skips `dataLen 0` the same way). The
 * whole map is shape-checked before the first byte moves.
 *
 * @param {GpuOps} ops
 * @param {HostWrites} buffers - the draw message's `buffers` map
 * @param {number} [counter] - the coming frame's counter (`wasm.getFrameCounter()`),
 *   read before `frame()`; undefined when the executor has no such export
 * @returns {number} how many queue writes were made (a pool write to every
 *   member counts once per member)
 * @throws {TypeError} on a malformed map or record
 */
export function writeBuffers(ops, buffers, counter) {
  if (!buffers || typeof buffers !== "object" || Array.isArray(buffers)) throw new TypeError("writeBuffer: buffers must be an object keyed by buffer name");
  if (counter !== undefined && !(Number.isInteger(counter) && counter >= 0)) throw new TypeError(`writeBuffer: the frame counter must be a non-negative integer, got ${counter}`);
  const writes = Object.entries(buffers).map(([name, spec]) => normalize(name, spec));
  let count = 0;
  for (const w of writes) {
    const r = ops.bufNames.get(w.name);
    let ids = /** @type {number[]} */ ([]);
    let why = null;
    if (!r) why = `writeBuffer: no buffer named '${w.name}' (see getBuffers())`;
    else if (r.frameWritten) why = `writeBuffer: '${w.name}' is written by the frame after any host write: use a dedicated buffer`;
    else {
      const m = members(w.name, r, w.poolIndex, counter);
      if (typeof m === "string") why = m;
      else { ids = m; why = refusal(ops, w.name, ids[0], w.offset, w.bytes.byteLength); }
    }
    if (why) {
      ops.reportError({ message: why, source: "write-buffer" });
      continue;
    }
    if (w.bytes.byteLength === 0) continue;
    for (const id of ids) {
      DEBUG && ops.debug() && console.log(`[GPU] writeBuffer '${w.name}': buf[${id}]+${w.offset} ${w.bytes.byteLength}b`);
      ops.device.queue.writeBuffer(ops.buf[id], w.offset, /** @type {GPUAllowSharedBufferSource} */ (w.bytes));
      count++;
    }
  }
  return count;
}
