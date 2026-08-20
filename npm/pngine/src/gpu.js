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

import { dispatchResourcePassCommand } from "./gpu-resource-pass-commands.js";
import { dispatchQueueCommand } from "./gpu-queue-commands.js";
import { countCachedBindGroups, countLive } from "./gpu-stats.js";
import { uniformToTypedArray } from "./uniform-convert.js";
import { decodeTextureFormat } from "./enums.js";
import {
  decodeTextureDescriptor,
  decodeSamplerDescriptor,
  decodeBindGroupData,
} from "./descriptor-decode.js";

// Optional WebGPU device features PNGine opportunistically requests at device
// creation. A bytecode may use a feature-gated value (tier1 16-bit formats,
// bgra8 srgb, depth32float-stencil8, dual-source blend); requesting the feature
// where the adapter supports it lets that value render. Single source of truth —
// imported by worker.js, worker-viewer.js, and core.js (each gates on
// adapter.features.has(), since requesting an unsupported feature rejects
// requestDevice). See descriptors.zig TextureFormat + schema/pngine.sjon.
/** @type {GPUFeatureName[]} */
export const OPTIONAL_DEVICE_FEATURES = [
  "timestamp-query",
  "primitive-index",
  "texture-formats-tier1",
  "rg11b10ufloat-renderable",
  "core-features-and-limits",
  "depth32float-stencil8",
  "dual-source-blending",
  // Powers (primitive :unclipped-depth true) → GPUPrimitiveState.unclippedDepth.
  "depth-clip-control",
];

// The optional features this adapter actually supports, in
// OPTIONAL_DEVICE_FEATURES order — the array to pass as requiredFeatures at
// device creation. Each is gated on adapter.features.has() because requesting a
// feature the adapter lacks rejects requestDevice(). Single source imported by
// worker.js, worker-viewer.js, and core.js.
export function requiredFeaturesFor(adapter) {
  /** @type {GPUFeatureName[]} */
  const out = [];
  for (const f of OPTIONAL_DEVICE_FEATURES) {
    if (adapter.features.has(f)) out.push(f);
  }
  return out;
}

// One decoder for the process, not one per string read. A TextDecoder carries
// native decoding state and is stateless between decode() calls with no
// `stream: true`, so a fresh one per read bought nothing — and rs() is on the
// frame path (call_wasm_func reads its function name every frame), which made
// it the only per-frame allocation in the corpus that was not a few bytes.
const DECODER = new TextDecoder();

// Build flag - esbuild replaces DEBUG with false in production (--define:DEBUG=false)
// For dev: Vite provides DEBUG=true via define config
// Fallback for Worker contexts where Vite's define doesn't reach
if (typeof DEBUG === "undefined") globalThis.DEBUG = false;

// Descriptor enum decoders (TextureFormat/FilterMode/AddressMode/CompareFunction)
// are imported from enums.js — the single JS source of truth, byte-pinned to
// descriptors.zig by tests/npm/webgpu-conformance.test.js. See enums.js.


// PNGB header constants (must match format.zig)
const PNGB_HEADER_SIZE = 40;
const PNGB_MAGIC = 0x42474e50; // "PNGB" little-endian
// flags bit 2 — payload carries an authored device-limits table appended after
// the animation table; its byte offset lives in the 3 reserved header bytes.
const PNGB_FLAG_DEVICE_LIMITS = 0x04;
// flags bit 3 — the author requested a PREMULTIPLIED canvas ((canvas
// :alpha-mode premultiplied)); clear = "opaque", the GPUCanvasConfiguration
// default. The bit used to mean the opposite, back when this runtime's own
// default was premultiplied. (spec/04, spec/09 D)
const PNGB_FLAG_PREMULTIPLIED_CANVAS = 0x08;

/**
 * Canvas alphaMode the payload requests: "premultiplied" when header flag bit 3
 * is set, else "opaque" — which is also what a non-PNGB or short buffer gets,
 * since the spec default is the right answer when the payload says nothing.
 * @param {Uint8Array|null|undefined} bytecode
 * @returns {"opaque"|"premultiplied"}
 */
export function canvasAlphaMode(bytecode) {
  if (!bytecode || bytecode.length < PNGB_HEADER_SIZE) return "opaque";
  const view = new DataView(bytecode.buffer, bytecode.byteOffset, bytecode.byteLength);
  if (view.getUint32(0, true) !== PNGB_MAGIC) return "opaque";
  return (view.getUint16(6, true) & PNGB_FLAG_PREMULTIPLIED_CANVAS) ? "premultiplied" : "opaque";
}

/**
 * Parse uniform table from PNGB bytecode.
 * Returns: { uniforms: Map<string, {bufferId, offset, size, type, elemCount}>, strings: string[] }
 * For a fixed-size array field, `type` is the ELEMENT's UT_* tag and
 * `elemCount` its element count; elemCount 0 = not an array (the byte was
 * padding in older payloads, so they parse identically).
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
      const elemCount = view.getUint8(pos + 1);
      pos += 2; // type + elem_count

      // Get field name from string table
      const fieldName = strings[nameStringId] || `field_${nameStringId}`;
      uniforms.set(fieldName, { bufferId, offset, size, type: uniformType, elemCount });
    }
  }

  return { uniforms, strings };
}

/**
 * Parse the authored device-limits table (flags bit 2 + reserved-u24 offset).
 * Returns a plain { camelCaseLimitName: Number } object suitable for
 * requestDevice({ requiredLimits }), or null when the payload carries no limits
 * (flag clear → byte-identical to a pre-§5.3b payload). Limit names are interned
 * as EXACT WebGPU camelCase in the string table, so no name map is needed here.
 */
export function parseDeviceLimits(bytecode) {
  if (bytecode.length < PNGB_HEADER_SIZE) return null;
  const view = new DataView(bytecode.buffer, bytecode.byteOffset, bytecode.byteLength);

  if (view.getUint32(0, true) !== PNGB_MAGIC) return null;
  const flags = view.getUint16(6, true);
  if ((flags & PNGB_FLAG_DEVICE_LIMITS) === 0) return null;

  // reserved[9..12] as u24 LE = limits table offset.
  const limitsOffset =
    view.getUint8(9) | (view.getUint8(10) << 8) | (view.getUint8(11) << 16);
  if (limitsOffset === 0 || limitsOffset >= bytecode.length) return null;

  const strings = parseStringTable(bytecode, view.getUint32(20, true));

  let pos = limitsOffset;
  const count = view.getUint8(pos);
  pos += 1;

  const limits = {};
  // Each entry: [name_string_id: u16 LE][value: u64 LE] (10 bytes).
  for (let i = 0; i < count && pos + 10 <= bytecode.length; i++) {
    const nameStringId = view.getUint16(pos, true);
    pos += 2;
    const value = view.getBigUint64(pos, true);
    pos += 8;
    const name = strings[nameStringId];
    if (name) limits[name] = Number(value);
  }

  return Object.keys(limits).length > 0 ? limits : null;
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

// Sentinel dispatch() returns for an opcode it can't decode. The operand length
// is then unknown, so execute() can't safely advance the command stream — it
// aborts the buffer and reports via onError instead of re-reading operand bytes
// as opcodes (the silent desync this replaces). A distinct value from any valid
// pos (always a positive memory offset).
const UNKNOWN_CMD = Symbol("pngine.unknownCmd");

/**
 * Decode a `call_wasm_func` arg blob: `[count:u8] ( [type:u8] [value:4]? )…`
 * per src/types/opcodes.zig WasmArgType — literal tags carry 4 LE bytes, the
 * four runtime tags carry none and are resolved here (wasm_ops.zig forwards
 * them unresolved on purpose: only the player knows the canvas and the clock).
 * Variable-width, so the walk follows count + per-tag widths, never the blob
 * length. Pinned to the Zig enum by tests/npm/wasm-args-decode.test.js.
 *
 * @param {Uint8Array} ab - the blob, starting at its count byte
 * @param {{cw: number, ch: number, time: number, tdelta: number}} rt - runtime values
 * @returns {number[]} arguments, in declared order
 */
export function decodeWasmArgs(ab, rt) {
  const av = new DataView(ab.buffer, ab.byteOffset, ab.byteLength);
  const args = [];
  for (let i = 0, n = ab[0], o = 1; i < n && o < ab.length; i++) {
    const t = ab[o++];
    if (t === 0x00) { args.push(av.getFloat32(o, true)); o += 4; }
    else if (t === 0x04) { args.push(av.getInt32(o, true)); o += 4; }
    else if (t === 0x05) { args.push(av.getUint32(o, true)); o += 4; }
    else if (t === 0x01) args.push(rt.cw);
    else if (t === 0x02) args.push(rt.ch);
    else if (t === 0x03) args.push(rt.time);
    else if (t === 0x06) args.push(rt.tdelta);
    else break; // unknown tag: its width is unknown, so the rest can't be walked
  }
  return args;
}

/**
 * Create a command dispatcher.
 * Returns object with only public methods - everything else is minifiable.
 */
export function createCommandDispatcher(device, ctx) {
  // State - all minifiable
  let mem = null;
  // Active render-target context. Swapped to a secondary OffscreenCanvas
  // context during prefetch so thumbnail renders don't touch the visible canvas.
  let targetCtx = ctx;
  let time = 0;
  // Seconds between the last two setTime calls (one per rendered frame). Only
  // the `time-delta` wasm-call arg reads it; a seek reports the seek distance,
  // which is the honest answer to "how far did the clock move".
  let tdelta = 0;
  let cw = 0, ch = 0;  // canvas width/height
  // Staging for the two built-in uniform writes, allocated once per dispatcher.
  //
  // Both used to build `new Float32Array([…])` per write — 60 allocations a
  // second each, whose whole purpose was to be copied by writeBuffer and
  // dropped, and multiplied by however many queue steps a frame runs (the step
  // list is uncapped). mini already avoided this on one of the two arms (§310);
  // this is the same move on both, one tier up.
  //
  // `.ptr` doubles as the pointer STATE — setPointer writes into it directly, so
  // there is no per-frame copy either. Index 11 is the layout's padding float
  // and stays 0 (pinned by tests/npm/helpers/pointer-layout.js).
  //
  // The byte views exist so the queue write can be BYTE-counted: writeBuffer's
  // 5-argument form measures dataOffset/size in ELEMENTS of the array it is
  // handed, and the sizes on the wire are byte counts.
  const timeAB = new ArrayBuffer(16);   // pngine-inputs: time, w, h, aspect
  const ptrAB = new ArrayBuffer(48);    // pointer-inputs: 11 floats + padding
  const scratch = {
    time: new Float32Array(timeAB), timeBytes: new Uint8Array(timeAB),
    ptr: new Float32Array(ptrAB), ptrBytes: new Uint8Array(ptrAB),
  };
  let enc = null;      // command encoder
  let pass = null;     // current pass
  let dbg = false;     // debug flag
  let curPip = -1;     // current pipeline ID (for bind group layout recreation)
  // Cleared by destroy(). Read by the execute loop and by the two async create
  // handlers, both of which can resume after this dispatcher was released.
  let alive = true;

  // Resource tables - arrays indexed by ID (more minifiable than Maps)
  const buf = [];      // buffers
  const tex = [];      // textures
  const txv = [];      // texture views, explicit — (texture-view …), rt 4
  const dfv = [];      // texture views, default — createView(), cached per texture id
  // What each explicit view was made from: {tid, desc}. Kept because a view
  // outlives nothing — when resizeCanvasBound destroys and recreates its source
  // texture, the only way to rebuild the view is to still know how it was made.
  const txs = [];
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
  // create_bind_group's layout_id id-space tag; mirrors
  // src/types/opcodes.zig BIND_GROUP_LAYOUT_TAG. Set ⇒ standalone bgl id.
  const BGL_TAG = 0x8000;
  const txd = [];      // texture descriptors
  const bun = [];      // render bundles
  const qs = [];       // query sets
  const bufUsage = []; // buffer usage flags (for MAP_READ detection)
  let pendingOcclusionQS = null;
  let pendingTimestampWrites = null;
  let pendingDepthStencilOps = null;
  let pendingClearValues = null;
  // Const, and cleared with .length = 0 rather than reassigned: the array is
  // handed to the queue-command module by reference, so a fresh array here
  // would leave that module writing into an orphan.
  /** @type {{id: number, offset: number, size: number}[]} */
  const pendingReadbacks = [];
  let onQueryResult = null;

  // Helper: read string from WASM memory
  function rs(ptr, len) {
    if (len === 0) return "";
    return DECODER.decode(new Uint8Array(mem.buffer, ptr, len));
  }

  // A create-resource command arrived with an empty descriptor payload — a
  // malformed / desynced stream (well-formed bytecode never emits one). Skip the
  // op (the id stays unpopulated, so later ops referencing it no-op) and report
  // once so the host isn't left with a silent blank / undefined-ref render.
  // Returns undefined so callers can `return emptyDescriptor(...)`.
  function emptyDescriptor(kind, id) {
    DEBUG && dbg && console.warn(`[GPU] ${kind}(${id}) skipped: empty descriptor`);
    onError && onError({ message: `${kind}(${id}) skipped: empty descriptor`, source: "command" });
  }

  // Run one resource-creation call inside a validation error scope, so a failure
  // can be attributed to the opcode and id that caused it.
  //
  // WebGPU never throws synchronously for a bad descriptor. Unscoped, the only
  // signal is the device-global onuncapturederror (worker-core.js) — a spec
  // message with no hint of WHICH pipeline or texture produced it. In the editor
  // that reads as "validation error" next to a blank canvas.
  //
  // Skipped entirely when no host is listening, and that is correctness rather
  // than thrift: pushing a scope SUPPRESSES onuncapturederror for the enclosed
  // call, so scoping without reporting would lose the error altogether.
  //
  // The pop is in a `finally`: a create that THROWS (a TypeError from a missing
  // required member on a desynced stream) used to leave the scope pushed, and
  // a pushed scope captures every later validation error on the device —
  // onuncapturederror never fired again.
  function scoped(kind, id, make) {
    if (!onError) return make();
    device.pushErrorScope("validation");
    try {
      return make();
    } finally {
      device.popErrorScope().then((e) => {
        if (e) onError({ message: `${kind}(${id}) failed validation: ${e.message}`, source: "validation" });
      });
    }
  }

  // Decode texture format enum - uses centralized lookup from enums.js
  const dtf = decodeTextureFormat;

  // Command handlers - all minifiable function names
  function createBuffer(id, size, usage) {
    if (buf[id]) return;
    DEBUG && dbg && console.log(`[GPU] createBuffer(${id}, ${size}, 0x${usage.toString(16)})`);
    // Bytecode usage flags match WebGPU GPUBufferUsage values directly
    buf[id] = scoped("createBuffer", id, () => device.createBuffer({ size, usage: usage || GPUBufferUsage.COPY_DST }));
    bufUsage[id] = usage;
  }


  function createShader(id, ptr, len) {
    if (shd[id]) return;
    DEBUG && dbg && console.log(`[GPU] createShader(${id}, ${len}b)`);
    if (len === 0) return emptyDescriptor("createShader", id);
    const code = rs(ptr, len);
    DEBUG && dbg && console.log(`[GPU]   code:\n${code}`);
    const module = device.createShaderModule({ code });
    // Check for compilation errors asynchronously
    module.getCompilationInfo().then(info => {
      const lines = code.split('\n');
      for (const msg of info.messages) {
        if (msg.type === 'error') {
          const ctx = lines.slice(Math.max(0, msg.lineNum - 3), msg.lineNum + 2).join('\n');
          console.error(`[GPU] Shader ${id} error at line ${msg.lineNum}:${msg.linePos}: ${msg.message}`);
          console.error(`[GPU] Context:\n${ctx}`);
          if (onShaderError) onShaderError({
            message: msg.message,
            lineNum: msg.lineNum,
            linePos: msg.linePos,
            context: ctx,
          });
        }
      }
    });
    shd[id] = module;
  }

  function createRenderPipeline(id, ptr, len) {
    if (pip[id]) return;
    if (len === 0) return emptyDescriptor("createRenderPipeline", id);
    const desc = JSON.parse(rs(ptr, len));
    const fmt = navigator.gpu.getPreferredCanvasFormat();
    DEBUG && dbg && console.log(`[GPU] createRenderPipeline(${id}) desc=`, JSON.stringify(desc));
    const pipeDesc = {
      layout: (desc.layoutId !== undefined && ppl[desc.layoutId]) ? ppl[desc.layoutId] : "auto",
      vertex: {
        module: shd[desc.vertex?.shader ?? 0],
        // No `?? "vs_main"` fallback: the compiler resolves every stage's entry
        // point (explicit `:entry`, else the module's sole entry for the
        // stage) and always writes a real name. A fabricated one here could only
        // hide a compiler bug behind a driver-level abort. Same below and in
        // createComputePipeline.
        entryPoint: desc.vertex.entryPoint,
        buffers: desc.vertex?.buffers ?? [],
      },
      primitive: desc.primitive ?? { topology: "triangle-list" },
      depthStencil: desc.depthStencil,
      multisample: desc.multisample,
    };
    if (desc.fragment) {
      // Full targets array (with blend/writeMask) or legacy targetFormat fallback
      let targets;
      if (desc.fragment.targets) {
        targets = desc.fragment.targets.map(t => ({ ...t, format: t.format || fmt }));
      } else {
        let targetFormat = desc.fragment.targetFormat;
        if (!targetFormat || targetFormat === "preferredCanvasFormat") targetFormat = fmt;
        targets = [{ format: targetFormat }];
      }
      DEBUG && dbg && console.log(`[GPU]   targets:`, JSON.stringify(targets));
      pipeDesc.fragment = {
        module: shd[desc.fragment.shader ?? desc.vertex?.shader ?? 0],
        entryPoint: desc.fragment.entryPoint,
        targets,
      };
    } else {
      DEBUG && dbg && console.log(`[GPU]   depth-only pipeline (no fragment stage)`);
    }
    const p = scoped("createRenderPipeline", id, () => device.createRenderPipeline(pipeDesc));
    pip[id] = p;
  }

  function createComputePipeline(id, ptr, len) {
    if (pip[id]) return;
    if (len < 4) return emptyDescriptor("createComputePipeline", id);
    // Binary format: [type_tag:0x06][shader_id:u16 LE][entry_len:u8][entry_bytes]
    const bytes = new Uint8Array(mem.buffer, ptr, len);
    const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const shaderId = v.getUint16(1, true); // bytes 1-2, little endian
    const entryLen = bytes[3];
    // A zero-length entry is a malformed descriptor, not a request for "main":
    // the compiler resolves the sole compute entry when `:entry` is omitted.
    if (entryLen === 0) return emptyDescriptor("createComputePipeline", id);
    const entryPoint = new TextDecoder().decode(bytes.slice(4, 4 + entryLen));
    DEBUG && dbg && console.log(`[GPU] createComputePipeline(${id}) shader=${shaderId} entry=${entryPoint}`);
    // Check for optional layout ID after entry point bytes
    const layoutOff = 4 + entryLen;
    const computeLayoutId = (layoutOff + 2 <= len) ? v.getUint16(layoutOff, true) : 0xFFFF;
    const p = scoped("createComputePipeline", id, () => device.createComputePipeline({
      layout: (computeLayoutId !== 0xFFFF && ppl[computeLayoutId]) ? ppl[computeLayoutId] : "auto",
      compute: {
        module: shd[shaderId] ?? shd[0],
        entryPoint,
      },
    }));
    pip[id] = p;
  }


  function createTexture(id, ptr, len) {
    if (tex[id]) return;
    if (len === 0) return emptyDescriptor("createTexture", id);
    const { desc, canvasBound } = decodeTextureDescriptor(
      new Uint8Array(mem.buffer, ptr, len), navigator.gpu.getPreferredCanvasFormat(), cw, ch, bmp);
    // Canvas-bound: bytecode omitted width/height, so size tracks canvas dims.
    // Remember the static fields so the resize path can rebuild at new cw/ch.
    txd[id] = { format: desc.format, usage: desc.usage, canvasBound,
                dimension: desc.dimension, sampleCount: desc.sampleCount, depth: desc.size[2] };
    DEBUG && dbg && console.log(`[GPU] createTexture(${id}) ${desc.size[0]}x${desc.size[1]} ${desc.format} usage=0x${desc.usage.toString(16)}${canvasBound ? ' [canvas]' : ''}`);
    installTexture(id, scoped("createTexture", id, () => device.createTexture(desc)));
  }

  function createSampler(id, ptr, len) {
    if (smp[id]) return;
    if (len === 0) return emptyDescriptor("createSampler", id);
    const desc = decodeSamplerDescriptor(new Uint8Array(mem.buffer, ptr, len));
    DEBUG && dbg && console.log(`[GPU] createSampler(${id}) ${desc.magFilter}/${desc.minFilter}${desc.compare ? ' compare=' + desc.compare : ''}`);
    smp[id] = scoped("createSampler", id, () => device.createSampler(desc));
  }

  function createBindGroup(id, layoutId, ptr, len) {
    if (bg[id]) return;
    if (len === 0) return emptyDescriptor("createBindGroup", id);
    const { gi, entries } = decodeBindGroupData(new Uint8Array(mem.buffer, ptr, len));
    // `alt` caches the auto-layout rebuilds set_bind_group makes when this
    // group is bound under a pipeline other than `layoutId`, keyed by pipeline
    // id. Filled lazily there; invalidated by resizeCanvasBound below, whose
    // rebuilt textures would otherwise leave every cached entry holding a view
    // of a destroyed texture. An explicit-BGL group never rebuilds (see below),
    // so its `alt` stays null.
    DEBUG && dbg && console.log(`[GPU] createBindGroup(${id}) layoutId=${fmtLayoutId(layoutId)} entries=[${entries.map(e => `{b=${e.binding} rt=${e.rt} rid=${e.rid}}`).join(',')}]`);
    const layout = resolveBindGroupLayout(layoutId, gi);
    if (!layout) return;
    // `bgd` (the rebuild recipe set_bind_group reads) is written only once the
    // group EXISTS: written first, a throwing createBindGroup left a recipe
    // with no group behind it, and every later set_bind_group re-threw from
    // the rebuild — once per frame, an undeduped error post at 60 Hz.
    bg[id] = scoped("createBindGroup", id, () => device.createBindGroup({ layout, entries: buildBindGroupEntries(entries) }));
    bgd[id] = { layoutId, gi, entries, alt: null };
  }

  // `layout_id` names one of two id spaces, discriminated by BGL_TAG: tagged is a
  // standalone (bind-group-layout …) id, untagged is the id of the pipeline whose
  // auto-derived layout the group targets. Both are numbered from 0, so the tag is
  // the only thing separating them.
  //
  // The spaces do NOT fall back to each other. WebGPU makes an auto-derived layout
  // exclusive to its own pipeline, and an explicitly created layout incompatible
  // with any auto-layout pipeline — so resolving one as the other does not produce
  // a merely different layout, it produces a bind group the driver rejects at draw
  // time. Returning undefined (→ no bind group) is the honest outcome. §339.
  function resolveBindGroupLayout(layoutId, gi) {
    if (layoutId & BGL_TAG) return bgl[layoutId & ~BGL_TAG];
    return pip[layoutId]?.getBindGroupLayout(gi);
  }

  function fmtLayoutId(layoutId) {
    return (layoutId & BGL_TAG) ? `bgl:${layoutId & ~BGL_TAG}` : `pipeline:${layoutId}`;
  }

  // Install a texture and its default view together, so `dfv[id]` exists for
  // exactly the ids `tex[id]` does. The two call sites are the only places a
  // texture enters a table: createTexture and the resize rebuild.
  //
  // Why the view is cached at all: every attachment and every rt-1 bind-group
  // entry used to mint a fresh `createView()` at the point of use, which for an
  // attachment is once per pass per FRAME — 99 views per frame across the
  // example corpus, none released (the wire protocol has no destroy for a view,
  // and WebGPU offers none either; they go when the GC reaches the wrapper).
  // Collectable, so not growth — but invisible to BOTH leak instruments, which
  // is what made it worth fixing rather than documenting (LEAK-07-A, §351).
  //
  // Why eagerly rather than lazily: a lazy fill happens on the first pass that
  // needs the view, i.e. inside frame 0, and a create inside a frame is exactly
  // what the frame-purity gate exists to forbid. Creating it here keeps the
  // gate's allowlist honest instead of carving out an exception for the fill.
  //
  // NOT used for the swap-chain texture: getCurrentTexture() returns a DIFFERENT
  // GPUTexture each frame, so a cached view of it would point a pass at a stale
  // image. That one createView stays per-frame, and is the only one the
  // frame-purity allowlist admits.
  function installTexture(id, texture) {
    tex[id] = texture;
    dfv[id] = texture.createView();
  }

  // Map decoded bind-group entries (rt 0=buffer, 1=texture default-view,
  // 2=sampler, 4=explicit texture-view object) to GPU BindGroupEntry resources.
  // Shared by createBindGroup, the resize rebuild, and set_bind_group's
  // auto-layout recreation.
  function buildBindGroupEntries(entries) {
    return entries.map(e => {
      const entry = { binding: e.binding };
      if (e.rt === 0) { entry.resource = { buffer: buf[e.rid] }; if (e.offset) entry.resource.offset = e.offset; if (e.size) entry.resource.size = e.size; }
      else if (e.rt === 1) entry.resource = dfv[e.rid];
      else if (e.rt === 2) entry.resource = smp[e.rid];
      else if (e.rt === 4) entry.resource = txv[e.rid]; // pre-created (texture-view …)
      return entry;
    });
  }

  // Build one color attachment. r/g/b/a are GPUColor channels — plain numbers,
  // not clamped and not 0-255 bytes. They WERE bytes decoding `/255` until
  // spec/09 step D; the `/255` now lives in the two legacy opcode cases
  // (0x10/0x1B), which is where the lossy wire actually is. load 1=clear else
  // load, store 0=store else discard.
  function colorAttachment(view, load, store, r, g, b, a) {
    return { view, loadOp: load === 1 ? "clear" : "load", storeOp: store === 0 ? "store" : "discard",
             clearValue: { r: r || 0, g: g || 0, b: b || 0, a: a || 0 } };
  }

  // Apply pending pass-scoped state (depth-stencil attachment, occlusion query
  // set, timestamp writes) to a render-pass descriptor. Shared by begin*Pass.
  function applyPendingPassState(pd, depthId) {
    if (depthId !== 0xffff && tex[depthId]) {
      const pds = pendingDepthStencilOps;
      const pcv = pendingClearValues;
      const dsa = { view: dfv[depthId], depthLoadOp: pds ? pds.dl : "clear", depthStoreOp: pds ? pds.ds : "store", depthClearValue: pcv ? pcv.depth : 1.0 };
      if (txd[depthId]?.format?.includes("stencil")) { dsa.stencilLoadOp = pds ? pds.sl : "clear"; dsa.stencilStoreOp = pds ? pds.ss : "store"; dsa.stencilClearValue = pcv ? pcv.stencil : 0; }
      pd.depthStencilAttachment = dsa;
      pendingDepthStencilOps = null;
      pendingClearValues = null;
    }
    if (pendingOcclusionQS) { pd.occlusionQuerySet = pendingOcclusionQS; pendingOcclusionQS = null; }
    if (pendingTimestampWrites) { pd.timestampWrites = pendingTimestampWrites; pendingTimestampWrites = null; }
  }

  function beginRenderPass(colorId, loadOp, storeOp, depthId, cr, cg, cb, ca, resolveId) {
    if (!enc) enc = device.createCommandEncoder();
    const CANVAS = 0xfffe;
    DEBUG && dbg && console.log(`[GPU] beginRenderPass colorId=${colorId === CANVAS ? 'CANVAS' : colorId} loadOp=${loadOp} storeOp=${storeOp} depthId=${depthId} clear=[${cr},${cg},${cb},${ca}] resolve=${resolveId}`);
    let pd;
    if (colorId === 0xffff) {
      // Depth-only pass: no color attachments
      pd = { colorAttachments: [] };
    } else {
      let cv;
      if (colorId === CANVAS) {
        const canvasTex = targetCtx.getCurrentTexture();
        cv = canvasTex.createView();
      } else {
        cv = dfv[colorId];
      }
      const att = colorAttachment(cv, loadOp, storeOp, cr, cg, cb, ca);
      if (resolveId !== undefined && resolveId !== 0xffff) {
        att.resolveTarget = (resolveId === CANVAS) ? targetCtx.getCurrentTexture().createView() : dfv[resolveId];
      }
      pd = { colorAttachments: [att] };
    }
    applyPendingPassState(pd, depthId);
    pass = enc.beginRenderPass(pd);
  }

  function beginRenderPassMRT(attachments, depthId) {
    if (!enc) enc = device.createCommandEncoder();
    const CANVAS = 0xfffe;
    const colorAttachments = attachments.map(a => {
      const cv = (a.tid === CANVAS) ? targetCtx.getCurrentTexture().createView() : dfv[a.tid];
      return colorAttachment(cv, a.load, a.store, a.r, a.g, a.b, a.a);
    });
    DEBUG && dbg && console.log(`[GPU] beginRenderPassMRT count=${attachments.length} depth=${depthId}`);
    const pd = { colorAttachments };
    applyPendingPassState(pd, depthId);
    pass = enc.beginRenderPass(pd);
  }

  function beginComputePass() {
    if (!enc) enc = device.createCommandEncoder();
    pass = enc.beginComputePass();
  }

  /**
   * The state bag both command modules read through. Mutable closure scalars
   * (mem, enc, the clock, the pointer) are reached via accessors because a
   * plain property would capture a stale value at bag-construction time; the
   * resource TABLES are handed over directly, since those are mutated in place.
   * @type {GpuOps}
   */
  const gpuOps = {
    createBuffer,
    createTexture,
    createSampler,
    createShader,
    createRenderPipeline,
    createComputePipeline,
    createBindGroup,
    txv,
    txs,
    tex,
    bgl,
    device,
    rs,
    get mem() {
      return mem;
    },
    bmp,
    ppl,
    beginRenderPass,
    beginRenderPassMRT,
    beginComputePass,
    getPass: () => pass,
    setPass: (v) => {
      pass = v;
    },
    pip,
    bg,
    buf,
    bun,
    smp,
    qs,
    dtf,
    setPendingOcclusionQS: (v) => { pendingOcclusionQS = v; },
    setPendingTimestampWrites: (v) => { pendingTimestampWrites = v; },
    setPendingDepthStencilOps: (dl, ds, sl, ss) => { pendingDepthStencilOps = { dl, ds, sl, ss }; },
    setPendingClearValues: (depth, stencil) => { pendingClearValues = { depth, stencil }; },
    bgd,
    buildBindGroupEntries,
    get curPip() { return curPip; },
    set curPip(v) { curPip = v; },
    log: (message) => {
      DEBUG && dbg && console.log(message);
    },

    // --- queue / WASM / control (gpu-queue-commands.js) ---
    wm,
    wcr,
    bufUsage,
    pendingReadbacks,
    targetCtx: () => targetCtx,
    // Lazy get-or-create: several commands are the first thing in a frame that
    // needs an encoder, and creating one per frame unconditionally would emit
    // empty command buffers on frames that only write uniforms.
    encoder: () => (enc ??= device.createCommandEncoder()),
    // Peek-and-clear, so submit cannot leave a finished encoder installed.
    takeEnc: () => {
      const e = enc;
      enc = null;
      return e;
    },
    clock: () => ({ time, cw, ch }),
    scratch,
    decodeWasmArgs: (ab) => decodeWasmArgs(ab, { cw, ch, time, tdelta }),
    getOnQueryResult: () => onQueryResult,
    debug: () => dbg,
    reportError: (e) => { onError && onError(e); },
    alive: () => alive,
  };

  // Main dispatch - inline command constants for minification
  // Opcode dispatch - MUST match src/executor/command_buffer.zig Cmd enum!
  // (NOT types/opcodes.zig - that is for bytecode format, not command buffer)
  //
  // Each handler returns the position AFTER its operands; a module returns null
  // for an opcode it does not own. Operand widths are pinned against the Zig
  // emitter by tests/npm/command-buffer-widths.test.js.
  function dispatch(cmd, view, pos) {
    const resourcePassResult = dispatchResourcePassCommand(cmd, view, pos, gpuOps);
    if (resourcePassResult !== null) return resourcePassResult;

    const queueResult = dispatchQueueCommand(cmd, view, pos, gpuOps);
    if (queueResult !== null) return queueResult;

    DEBUG && console.warn(`Unknown cmd: 0x${cmd.toString(16)}`);
    return UNKNOWN_CMD;
  }

  // Command buffers executed since this dispatcher was built. The denominator
  // for "resources per frame" in a soak — a live count that is flat over 10
  // buffers and flat over 600 are very different statements.
  let executed = 0;

  /**
   * Live GPU objects this dispatcher holds, by kind. See gpu-stats.js for why
   * these are derived from the tables rather than counted at each create.
   */
  function getStats() {
    const { live, total } = countLive({
      // Two view tables, counted apart: `txv` is an authored resource
      // ((texture-view …), bound as rt 4), `dfv` is the dispatcher's own
      // per-texture default-view cache. Merging them would hide which side grew.
      buffer: buf, texture: tex, textureView: txv, defaultView: dfv,
      sampler: smp, shader: shd,
      pipeline: pip, bindGroup: bg, bindGroupLayout: bgl, pipelineLayout: ppl,
      imageBitmap: bmp, wasmModule: wm, renderBundle: bun, querySet: qs,
    });
    const cachedBindGroups = countCachedBindGroups(bgd);
    live.bindGroup += cachedBindGroups;
    return { live, total: total + cachedBindGroups, cachedBindGroups, executed };
  }

  // Execute command buffer
  async function execute(ptr) {
    executed++;
    let view = new DataView(mem.buffer);
    const totalLen = view.getUint32(ptr, true);
    const cmdCount = view.getUint16(ptr + 4, true);
    DEBUG && dbg && console.log(`[GPU] Execute: ${cmdCount} cmds, ${totalLen}b`);

    let pos = ptr + 8;
    const end = ptr + totalLen;
    for (let i = 0; i < cmdCount && pos < end; i++) {
      const cmd = view.getUint8(pos++);
      const result = dispatch(cmd, view, pos);
      if (result === UNKNOWN_CMD) {
        // Operand length unknown → advancing would re-read operand bytes as
        // opcodes (a desync). Abort the buffer and tell the host, loudly.
        onError && onError({ message: `unknown GPU command 0x${cmd.toString(16)} — command buffer aborted`, source: "command" });
        break;
      }
      if (result instanceof Promise) {
        pos = await result;
        // destroy() is synchronous and can run during an async command (0x0B
        // decode, 0x30 compile). Past this point the loop reads `mem`, which
        // destroy() drops (a TypeError), and every create it reaches lands in a
        // table already emptied (a leak).
        if (!alive) break;
        view = new DataView(mem.buffer);
      } else {
        pos = result;
      }
    }
  }

  // Release everything this dispatcher holds.
  //
  // Runs on every payload reload (worker-core.js loadBytecode) — in an editor,
  // that is once per compile — and on teardown. The reload path then builds a
  // FRESH dispatcher, so the tables below become garbage wholesale either way;
  // what this function buys is DETERMINISTIC release, which for GPU-backed
  // objects is the difference between freeing driver memory now and freeing it
  // whenever the JS wrapper happens to be collected.
  //
  // Three kinds carry an explicit release and so must appear here: GPUBuffer
  // and GPUTexture (destroy), GPUQuerySet (destroy), and ImageBitmap (close —
  // a decoded bitmap is megabytes of pixel memory). GPURenderBundle, shader
  // modules, pipelines and layouts have no release method; truncating their
  // tables just drops the references.
  function destroy() {
    alive = false;
    buf.forEach(b => b?.destroy?.());
    tex.forEach(t => t?.destroy?.());
    qs.forEach(q => q?.destroy?.());
    bmp.forEach(b => b?.close?.());
    buf.length = tex.length = txv.length = dfv.length = smp.length = shd.length = pip.length = 0;
    bg.length = bgl.length = ppl.length = bmp.length = wm.length = 0;
    wcr.length = bgd.length = txd.length = txs.length = bufUsage.length = 0;
    qs.length = bun.length = 0;
    curPip = -1;
    pendingReadbacks.length = 0;
    pendingOcclusionQS = pendingTimestampWrites = null;
    pendingDepthStencilOps = pendingClearValues = null;
    // The remaining closure state. Moot while a destroyed dispatcher is
    // immediately replaced, but handleDestroy now keeps the worker alive
    // between the device teardown and the terminate — so a dispatcher can
    // genuinely outlive its device, and `mem` in particular pins the executor's
    // whole WASM memory.
    onQueryResult = onError = onShaderError = null;
    uniformMap = null;
    mem = null;
    targetCtx = null;
    enc = pass = null;
  }

  // Uniform table: Map<string, {bufferId, offset, size, type, elemCount}>
  let uniformMap = null;

  /**
   * Set uniform table from parsed bytecode.
   * @param {Map<string, {bufferId, offset, size, type, elemCount}>} map
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

    // Convert value to typed array based on uniform type (array fields
    // expand per-element at the wire-implied stride — see uniformToTypedArray)
    const data = uniformToTypedArray(value, info.type, info.size, info.elemCount);
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

  // Shader error callback — called with { message, lineNum, linePos, context }
  let onShaderError = null;
  // Command-stream error callback — called with { message, source } for a
  // command the dispatcher can't honor (unknown opcode → aborted buffer; an
  // empty create-resource descriptor → skipped op). The host maps it to a
  // PngineGPUError so a malformed/desynced stream fails loud instead of silently
  // rendering blank or leaving undefined resource refs.
  let onError = null;

  // Recreate textures whose size tracks the canvas (bytecode omitted width/height)
  // when the canvas is resized. Without this, depth/color attachments drift out
  // of sync with the swap chain's current texture and WebGPU rejects the pass
  // with a "size does not match" error.
  function resizeCanvasBound(w, h) {
    if (cw === w && ch === h) return;
    cw = w; ch = h;
    for (let id = 0; id < tex.length; id++) {
      const d = txd[id];
      if (!d || !d.canvasBound || !tex[id]) continue;
      tex[id].destroy?.();
      const desc = { size: [w || 1, h || 1, d.depth || 1], format: d.format, usage: d.usage, sampleCount: d.sampleCount || 1 };
      if (d.dimension) desc.dimension = d.dimension;
      installTexture(id, device.createTexture(desc));
    }
    // Explicit (texture-view …) resources of a recreated texture, remade from
    // their recorded source. Must run BEFORE the bind-group loop below, which
    // reads txv. Skipped for views of ordinary textures: those textures were
    // not touched, so their views are still valid.
    for (let id = 0; id < txv.length; id++) {
      const s = txs[id];
      if (!s || !txd[s.tid]?.canvasBound || !tex[s.tid]) continue;
      txv[id] = tex[s.tid].createView(s.desc);
    }
    // Bind groups that referenced a recreated texture still hold a stale view.
    // Rebuild any bind group with an entry pointing at a canvas-bound texture,
    // by its default view (rt 1) or through an explicit one (rt 4). Missing the
    // rt-4 half left the group binding a view of a texture whose memory this
    // function had just freed — bounded, and permanently broken (LEAK-07-B).
    for (let id = 0; id < bg.length; id++) {
      const d = bgd[id];
      if (!d) continue;
      const needsRebuild = d.entries.some(e => e.rt === 1
        ? txd[e.rid]?.canvasBound
        : e.rt === 4 && txd[txs[e.rid]?.tid]?.canvasBound);
      if (!needsRebuild) continue;
      // Drop the per-pipeline auto-layout cache too: its entries hold views of
      // the textures just destroyed above, and set_bind_group would keep
      // handing them out. They rebuild lazily on the next bind.
      d.alt = null;
      const layout = resolveBindGroupLayout(d.layoutId, d.gi);
      if (!layout) continue;
      bg[id] = device.createBindGroup({ layout, entries: buildBindGroupEntries(d.entries) });
    }
  }

  // Return public interface only - these names stay, everything else minifies
  return {
    setDebug(v) { dbg = v; },
    setMemory(m) { mem = m; },
    setTime(t) { tdelta = t - time; time = t; },
    setPointer(s) { scratch.ptr.set(s); },
    setCanvasSize(w, h) { cw = w; ch = h; },
    resizeCanvasBound,
    setRenderTargetContext(c) { targetCtx = c || ctx; },
    setOnShaderError(fn) { onShaderError = fn; },
    setOnError(fn) { onError = fn; },
    setOnQueryResult(fn) { onQueryResult = fn; },
    setUniformTable,
    setUniform,
    setUniforms,
    getStats,
    execute,
    destroy,
  };
}

// setUniform's value→bytes conversion now lives in uniform-convert.js (it has no
// GPU in it). Re-exported here so every existing importer — and the tests that
// pin it against the wire UniformType tags — is unchanged by the move.
export { uniformToTypedArray };
