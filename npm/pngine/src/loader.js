/**
 * Loader for embedded executor PNGs
 *
 * Parses PNGB v5 format to detect and extract embedded executor WASM.
 * Falls back to shared executor if not embedded.
 *
 * PNGB v5 Header (40 bytes):
 * - magic: "PNGB" (4 bytes)
 * - version: u16 (5)
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

const PNGB_MAGIC = [0x50, 0x4e, 0x47, 0x42]; // "PNGB"
const VERSION_V5 = 5;
const VERSION_V4 = 4;
const HEADER_SIZE_V5 = 40;
const HEADER_SIZE_V4 = 28;

// Header flags
const FLAG_HAS_EMBEDDED_EXECUTOR = 0x01;
const FLAG_HAS_ANIMATION_TABLE = 0x02;

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
  if (pngb.length < HEADER_SIZE_V4) {
    throw new Error("Invalid PNGB: too short");
  }

  // Check magic
  if (!PNGB_MAGIC.every((v, i) => pngb[i] === v)) {
    throw new Error("Invalid PNGB: bad magic");
  }

  const view = new DataView(pngb.buffer, pngb.byteOffset, pngb.byteLength);
  const version = view.getUint16(4, true);

  if (version !== VERSION_V5 && version !== VERSION_V4) {
    throw new Error(`Unsupported PNGB version: ${version}`);
  }

  // Parse based on version
  if (version === VERSION_V5) {
    return parseV5Header(pngb, view);
  } else {
    return parseV4Header(pngb, view);
  }
}

/**
 * Parse v5 header (40 bytes)
 */
function parseV5Header(pngb, view) {
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
    : HEADER_SIZE_V5;
  const bytecodeLength = stringTableOffset - bytecodeOffset;

  return {
    version: VERSION_V5,
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
 * Parse v4 header (28 bytes) - backward compatibility
 */
function parseV4Header(pngb, view) {
  const stringTableOffset = view.getUint32(8, true);
  const dataOffset = view.getUint32(12, true);
  const wgslOffset = view.getUint32(16, true);
  const uniformOffset = view.getUint32(20, true);
  const animationOffset = view.getUint32(24, true);

  const bytecodeOffset = HEADER_SIZE_V4;
  const bytecodeLength = stringTableOffset - bytecodeOffset;

  return {
    version: VERSION_V4,
    hasEmbeddedExecutor: false,
    hasAnimationTable: false,
    plugins: { core: true, render: false, compute: false, wasm: false, animation: false, texture: false },

    executor: null,
    bytecode: pngb.subarray(bytecodeOffset, bytecodeOffset + bytecodeLength),
    payload: pngb,

    offsets: {
      executor: 0,
      executorLength: 0,
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
      log: callbacks.log || ((ptr, len) => {}),

      // WASM-in-WASM plugin imports
      wasmInstantiate: callbacks.wasmInstantiate || ((id, ptr, len) => {}),
      wasmCall: callbacks.wasmCall || ((callId, modId, namePtr, nameLen, argsPtr, argsLen) => {}),
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
  const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
  const exports = instance.exports;
  const memory = exports.memory;

  return {
    instance,
    memory,
    exports,

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
 *
 * @param {Object} plugins - Plugin flags
 * @returns {string} Variant name (e.g., "core-render-compute")
 */
export function getExecutorVariantName(plugins) {
  const parts = ["core"];
  if (plugins.render) parts.push("render");
  if (plugins.compute) parts.push("compute");
  if (plugins.wasm) parts.push("wasm");
  if (plugins.animation) parts.push("anim");
  if (plugins.texture) parts.push("texture");
  return parts.join("-");
}
