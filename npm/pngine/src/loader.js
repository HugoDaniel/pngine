/**
 * Loader for embedded executor PNGs
 *
 * Parses PNGB v0 format to detect and extract embedded executor WASM.
 * Falls back to shared executor if not embedded.
 *
 * PNGB Header (40 bytes):
 * - magic: "PNGB" (4 bytes)
 * - version: u16 (0; 1 marks an executor-less guarded payload — D6)
 * - flags: u16 (bit 0 = has_embedded_executor, bit 1 = has_animation_table)
 * - plugins: u8 (PluginSet bitfield)
 * - reserved: [3]u8
 * - executor_offset: u32 (0 if not embedded)
 * - executor_length: u32
 * - string_table_offset: u32
 * - data_section_offset: u32
 * - wgsl_table_offset: u32
 * - uniform_table_offset: u32
 * - animation_table_offset: u32
 */

// Build flag - esbuild replaces EMBEDDED_ONLY per profile (--define:EMBEDDED_ONLY=…)
// Fallback for raw-source consumers (Node tests, dev servers without the define)
if (typeof EMBEDDED_ONLY === "undefined") globalThis.EMBEDDED_ONLY = false;

const PNGB_MAGIC = [0x50, 0x4e, 0x47, 0x42]; // "PNGB"
const VERSION_V0 = 0;
// D6 (frame-program §12): version 1 marks an executor-less guarded payload —
// the only signal a runtime that predates the §9 handshake obeys. Every
// reader of the field accepts both; the 40-byte layout is unchanged.
const VERSION_V1 = 1;
const HEADER_SIZE_V0 = 40;

// Header flags
const FLAG_HAS_EMBEDDED_EXECUTOR = 0x01;
const FLAG_HAS_ANIMATION_TABLE = 0x02;

// Stock fallback capacities for a binary that predates the capacity exports.
// They describe the legacy STANDARD executor only: a custom build with other
// caps must export them or its own host must know the numbers. Raw
// `instance.exports` still shows the absence, so a host can feature-detect.
const LEGACY_STANDARD_BYTECODE_CAPACITY = 262144;
const LEGACY_STANDARD_DATA_CAPACITY = 524288;

// Plugin bits
const PLUGIN_CORE = 0x01;
const PLUGIN_RENDER = 0x02;
const PLUGIN_COMPUTE = 0x04;
const PLUGIN_WASM = 0x08;
const PLUGIN_ANIMATION = 0x10;
const PLUGIN_TEXTURE = 0x20;

/**
 * Parse PNGB payload and extract components.
 *
 * @param {Uint8Array} pngb - Raw PNGB bytecode
 * @returns {Object} Parsed payload info
 */
export function parsePayload(pngb) {
  if (pngb.length < HEADER_SIZE_V0) {
    throw new Error("Invalid PNGB: too short");
  }

  // Check magic
  if (!PNGB_MAGIC.every((v, i) => pngb[i] === v)) {
    throw new Error("Invalid PNGB: bad magic");
  }

  const view = new DataView(pngb.buffer, pngb.byteOffset, pngb.byteLength);
  const version = view.getUint16(4, true);

  // v0, and v1 for an executor-less guarded payload (D6): the §9 handshake,
  // not this gate, refuses the pairing that is unsafe to run.
  if (version !== VERSION_V0 && version !== VERSION_V1) {
    throw new Error(`Unsupported PNGB version: ${version}`);
  }

  return parseV0Header(pngb, view, version);
}

/**
 * Parse the 40-byte header (v0 layout, shared by v1 — D6 changed the field's
 * value, never its size or position).
 */
function parseV0Header(pngb, view, version) {
  const flags = view.getUint16(6, true);
  const plugins = pngb[8];
  const executorOffset = view.getUint32(12, true);
  const executorLength = view.getUint32(16, true);
  const stringTableOffset = view.getUint32(20, true);
  const dataOffset = view.getUint32(24, true);
  const wgslOffset = view.getUint32(28, true);
  const uniformOffset = view.getUint32(32, true);
  const animationOffset = view.getUint32(36, true);

  const hasEmbeddedExecutor = (flags & FLAG_HAS_EMBEDDED_EXECUTOR) !== 0;
  const hasAnimationTable = (flags & FLAG_HAS_ANIMATION_TABLE) !== 0;

  // Calculate bytecode start (after header + executor)
  const bytecodeOffset = hasEmbeddedExecutor
    ? executorOffset + executorLength
    : HEADER_SIZE_V0;

  // Geometry guard, before this file or any caller subtracts or slices:
  // every boundary must ascend and stay inside the buffer. The executor is a
  // section after the header when the flag is set; a zero length leaves its
  // offset unused (the executor slice is empty either way). JS numbers are
  // exact throughout the u32 range, so these additions cannot wrap.
  if (
    (hasEmbeddedExecutor &&
      (executorOffset + executorLength > pngb.length ||
        (executorLength > 0 && executorOffset < HEADER_SIZE_V0))) ||
    bytecodeOffset > stringTableOffset ||
    stringTableOffset > dataOffset ||
    dataOffset > wgslOffset ||
    wgslOffset > uniformOffset ||
    uniformOffset > animationOffset ||
    animationOffset > pngb.length
  ) {
    throw new Error("Invalid PNGB: malformed section geometry");
  }

  const bytecodeLength = stringTableOffset - bytecodeOffset;

  return {
    version,
    hasEmbeddedExecutor,
    hasAnimationTable,
    plugins: parsePlugins(plugins),

    // Executor section (if embedded)
    executor: hasEmbeddedExecutor
      ? pngb.subarray(executorOffset, executorOffset + executorLength)
      : null,

    // Bytecode section (for WASM dispatcher)
    bytecode: pngb.subarray(bytecodeOffset, bytecodeOffset + bytecodeLength),

    // Full payload for WASM loading
    payload: pngb,

    // Section offsets (for direct access if needed)
    offsets: {
      executor: hasEmbeddedExecutor ? executorOffset : 0,
      executorLength,
      bytecode: bytecodeOffset,
      bytecodeLength,
      stringTable: stringTableOffset,
      data: dataOffset,
      wgsl: wgslOffset,
      uniform: uniformOffset,
      animation: animationOffset,
    },
  };
}

/**
 * Refuse a payload whose sections exceed the executor's input capacities,
 * before any host writes.
 *
 * `parsed` is `parsePayload`'s result: its geometry guard already proved
 * `dataOffset <= wgslOffset <= payload.length`, so the subtraction below
 * cannot underflow. `executorExportsOrCaps` is an executor wrapper (the
 * `createExecutor` result or raw `instance.exports`) or an explicit
 * `{headCap, dataCap}` pair; absent exports fall back to the legacy standard
 * capacities, never a guess that an old binary is micro. `whole` is the
 * single-buffer host mode: it writes the entire payload into the bytecode
 * buffer and populates no data buffer, so the total length is what must fit
 * the head capacity.
 *
 * @param {Object} parsed - `parsePayload` result
 * @param {Object|null} executorExportsOrCaps - executor exports or explicit caps
 * @param {boolean} [whole] - single-buffer mode
 * @returns {{headLen: number, dataLen: number, headCap: number, dataCap: number}}
 */
export function preflightPayload(parsed, executorExportsOrCaps = null, whole = false) {
  const headCap = capacityFrom(
    executorExportsOrCaps, "getBytecodeCapacity", "headCap", LEGACY_STANDARD_BYTECODE_CAPACITY);
  const dataCap = capacityFrom(
    executorExportsOrCaps, "getDataCapacity", "dataCap", LEGACY_STANDARD_DATA_CAPACITY);

  const headLen = whole ? parsed.payload.length : parsed.offsets.data;
  const dataLen = whole ? 0 : parsed.offsets.wgsl - parsed.offsets.data;

  if (headLen > headCap) {
    throw new Error(
      `executor-head-capacity: PNGB head is ${headLen} bytes; executor capacity is ${headCap} bytes`);
  }
  if (!whole && dataLen > dataCap) {
    throw new Error(
      `executor-data-capacity: PNGB data section is ${dataLen} bytes; executor capacity is ${dataCap} bytes`);
  }

  return { headLen, dataLen, headCap, dataCap };
}

/**
 * One capacity from an executor's additive exports, else an explicit cap, else
 * the stock legacy value. The method wins because it describes THIS binary;
 * the explicit pair exists for hosts that already resolved it.
 */
function capacityFrom(source, method, field, fallback) {
  const read = source?.[method];
  if (typeof read === "function") {
    const value = read.call(source);
    if (Number.isSafeInteger(value) && value >= 0) return value;
  }
  const explicit = source?.[field];
  if (Number.isSafeInteger(explicit) && explicit >= 0) return explicit;
  return fallback;
}

/**
 * Parse plugins byte into named flags
 */
function parsePlugins(byte) {
  return {
    core: (byte & PLUGIN_CORE) !== 0,
    render: (byte & PLUGIN_RENDER) !== 0,
    compute: (byte & PLUGIN_COMPUTE) !== 0,
    wasm: (byte & PLUGIN_WASM) !== 0,
    animation: (byte & PLUGIN_ANIMATION) !== 0,
    texture: (byte & PLUGIN_TEXTURE) !== 0,
  };
}

/**
 * Get required WASM imports for embedded executor.
 *
 * The embedded executor needs host functions to execute GPU commands.
 * Unlike the shared executor which outputs a command buffer to memory,
 * the embedded executor may call these directly.
 *
 * @param {Object} callbacks - Host callback implementations
 * @returns {Object} WASM imports object
 */
export function getExecutorImports(callbacks = {}) {
  return {
    env: {
      // Debug logging (optional)
      log: callbacks.log || ((ptr, len) => { }),

      // WASM-in-WASM plugin imports
      wasmInstantiate: callbacks.wasmInstantiate || ((id, ptr, len) => { }),
      wasmCall: callbacks.wasmCall || ((callId, modId, namePtr, nameLen, argsPtr, argsLen) => { }),
      wasmGetResult: callbacks.wasmGetResult || ((callId, outPtr, outLen) => 0),
    },
  };
}

/**
 * Create a minimal executor instance from embedded WASM.
 *
 * This instantiates the embedded executor WASM and returns an interface
 * for initializing and running frames.
 *
 * @param {Uint8Array} wasmBytes - Embedded executor WASM
 * @param {Object} imports - WASM imports
 * @returns {Promise<Object>} Executor instance
 */
export async function createExecutor(wasmBytes, imports = {}) {
  // Cast: TS 5.7+ Uint8Array<ArrayBufferLike> no longer satisfies BufferSource
  // (SharedArrayBuffer), so overload resolution falls through to instantiate(Module).
  const { instance } = await WebAssembly.instantiate(
    /** @type {BufferSource} */ (/** @type {unknown} */ (wasmBytes)), imports);
  const exports = /** @type {PngineExecutorExports} */ (/** @type {unknown} */ (instance.exports));
  const memory = exports.memory;

  return {
    instance,
    memory,
    exports,

    /**
     * ABI version of the executor↔host interface (docs/abi.md).
     * Binaries predating the export are version 1.
     */
    getAbiVersion() {
      return exports.getAbiVersion?.() ?? 1;
    },

    /**
     * Get pointer where host should write bytecode.
     */
    getBytecodePtr() {
      return exports.getBytecodePtr?.() || 0;
    },

    /**
     * Set bytecode length after writing.
     */
    setBytecodeLen(len) {
      exports.setBytecodeLen?.(len);
    },

    /**
     * Get pointer where host should write data section.
     */
    getDataPtr() {
      return exports.getDataPtr?.() || 0;
    },

    /**
     * Set data section length after writing.
     */
    setDataLen(len) {
      exports.setDataLen?.(len);
    },

    /**
     * Exact bytecode-input capacity in bytes, read from this binary. A binary
     * without the export predates it, so the stock fallback is the legacy
     * STANDARD capacity — never a guess at a custom build's size. Raw
     * `exports` still reveals the absence for a feature-detecting host.
     */
    getBytecodeCapacity() {
      return exports.getBytecodeCapacity?.() ?? LEGACY_STANDARD_BYTECODE_CAPACITY;
    },

    /**
     * Exact data-section capacity in bytes. Same additive fallback rule as
     * `getBytecodeCapacity`.
     */
    getDataCapacity() {
      return exports.getDataCapacity?.() ?? LEGACY_STANDARD_DATA_CAPACITY;
    },

    /**
     * Initialize executor (parses bytecode, emits resource creation commands).
     */
    init() {
      exports.init?.();
    },

    /**
     * Render a frame.
     * @param {number} time - Time in seconds
     * @param {number} width - Canvas width
     * @param {number} height - Canvas height
     */
    frame(time, width, height) {
      exports.frame?.(time, width, height);
    },

    /**
     * Get pointer to command buffer output.
     */
    getCommandPtr() {
      return exports.getCommandPtr?.() || 0;
    },

    /**
     * Get length of command buffer.
     */
    getCommandLen() {
      return exports.getCommandLen?.() || 0;
    },
  };
}

/**
 * Generate a name for the executor variant based on plugins.
 *
 * Used for fetching shared executor when not embedded.
 * Only available in --shared builds.
 *
 * @param {Object} plugins - Plugin flags
 * @returns {string} Variant name (e.g., "core-render-compute")
 */
export function getExecutorVariantName(plugins) {
  if (EMBEDDED_ONLY) {
    throw new Error("getExecutorVariantName not available in embedded-only builds");
  }
  const parts = ["core"];
  if (plugins.render) parts.push("render");
  if (plugins.compute) parts.push("compute");
  if (plugins.wasm) parts.push("wasm");
  if (plugins.animation) parts.push("anim");
  if (plugins.texture) parts.push("texture");
  return parts.join("-");
}
