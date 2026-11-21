/**
 * Texture write-layout contract — host (JS) binding.
 *
 * Plan 01's pure model, the JS half of the shared contract. It proves a
 * raw-byte write fits its source and destination before the host emits a
 * WebGPU call. Nothing here imports WebGPU globals, touches GPU state, reads
 * IO, allocates a result owned elsewhere, or holds mutable module state: every
 * call is a pure function of its arguments.
 *
 * The same `tests/fixtures/texture-layout.json` corpus drives this binding and
 * the Zig binding (`src/types/texture_layout.zig`). Refusal codes, fields and
 * the normalized layout values are the contract's, not this language's.
 *
 * JS arithmetic guard: the contract is u64/u32 integer arithmetic. Every
 * numeric input must be a nonnegative safe integer within its field bound
 * before it is used; every product and sum is checked before it is performed
 * (and again against u32 before it can become a returned value). A refused
 * value is data, `{ refuse: { code, field, actual, limit } }`, never a thrown
 * TypeError substitute.
 *
 * Plan 03/04 call `calculateWrite` and pass absence through unchanged: an
 * omitted `bytesPerRow`/`rowsPerImage` is `undefined`/`null`, not 0. An
 * authored 0 stays 0 and is judged by the stride-presence and minimum rules.
 */

const U32_MAX = 0xffffffff;
const MAX_SAFE = Number.MAX_SAFE_INTEGER;

/**
 * @typedef {"invalid-format" | "invalid-texture-descriptor" | "unsupported-dimension" |
 *   "missing-copy-dst" | "missing-copy-src" | "multisampled-destination" |
 *   "sample-count-mismatch" | "overlapping-subresources" | "invalid-aspect" |
 *   "aspect-not-writable" | "partial-depth-stencil-write" | "partial-subresource-copy" |
 *   "mip-out-of-range" |
 *   "origin-out-of-bounds" | "extent-out-of-bounds" | "unaligned-block-origin" |
 *   "unaligned-block-extent" | "missing-bytes-per-row" | "missing-rows-per-image" |
 *   "bytes-per-row-too-small" | "rows-per-image-too-small" |
 *   "bytes-per-row-alignment" | "buffer-offset-alignment" |
 *   "buffer-out-of-bounds" | "insufficient-data" |
 *   "arithmetic-overflow"} Code
 */

/**
 * @typedef {"none" | "format" | "aspect" | "dimension" | "usage" | "sample-count" |
 *   "mip-level" | "mip-level-count" | "size-width" | "size-height" |
 *   "size-depth-or-array-layers" | "origin-x" | "origin-y" | "origin-z" |
 *   "bytes-per-row" | "rows-per-image" | "offset" | "data"} Field
 */

/**
 * @typedef {{ code: Code, field: Field, actual: number, limit: number }} Refusal
 * @typedef {{ width: number, height: number, depthOrArrayLayers: number }} Extent
 * @typedef {{ x: number, y: number, z: number }} Origin
 * @typedef {"1d" | "2d" | "3d"} Dimension
 * @typedef {"all" | "stencil-only" | "depth-only"} AspectName
 *
 * @typedef {{
 *   width: number,
 *   height?: number | null,
 *   depthOrArrayLayers?: number | null,
 * }} ExtentInput
 *
 * @typedef {{ x?: number | null, y?: number | null, z?: number | null }} OriginInput
 *
 * @typedef {{
 *   size: ExtentInput,
 *   dimension: Dimension | string,
 *   format: string | number,
 *   usage: number,
 *   sampleCount: number,
 *   mipLevelCount: number,
 *   extentSource?: "explicit" | "canvas" | "image-bitmap" | string,
 * }} TextureDescriptorInput
 *
 * @typedef {{
 *   offset?: number | null,
 *   bytesPerRow?: number | null,
 *   rowsPerImage?: number | null,
 *   origin?: OriginInput | null,
 *   mipLevel?: number | null,
 *   aspect?: AspectName | number | string | null,
 *   size?: ExtentInput | null,
 * }} WriteLayoutInput
 *
 * @typedef {{
 *   blockWidth: number,
 *   blockHeight: number,
 *   bytesPerBlock: number,
 *   hasDepth: boolean,
 *   hasStencil: boolean,
 *   writeDestination: boolean,
 * }} FormatInfo
 *
 * @typedef {{ logical: Extent, physical: Extent }} MipExtent
 *
 * @typedef {{
 *   logicalMipExtent: Extent,
 *   physicalMipExtent: Extent,
 *   copyExtent: Extent,
 *   widthInBlocks: number,
 *   heightInBlocks: number,
 *   bytesInLastRow: number,
 *   bytesPerRow: number,
 *   rowsPerImage: number,
 *   imageStride: number,
 *   requiredBytesInCopy: number,
 *   endOffset: number,
 * }} Layout
 *
 * @typedef {{ ok: FormatInfo } | { refuse: Refusal }} FormatInfoResult
 * @typedef {{ ok: MipExtent } | { refuse: Refusal }} MipExtentResult
 * @typedef {{ ok: Layout } | { refuse: Refusal }} Result
 * @typedef {{ value: number } | { refuse: Refusal }} NumberRead
 * @typedef {{ value: Extent } | { refuse: Refusal }} ExtentRead
 * @typedef {{ value: Origin } | { refuse: Refusal }} OriginRead
 * @typedef {{ value: number } | { refuse: Refusal }} CheckedValue
 * @typedef {{ value: FormatRow } | { refuse: Refusal }} RowRead
 */

/**
 * Operation policy for the shared calculator. `queueWrite` is `writeTexture`
 * and sets `aligned = false`; the GPUCommandEncoder buffer↔texture copies set
 * it true AND name the direction their texture endpoint occupies. Only the
 * aligned policies acquire the bytes-per-row and buffer-offset rules, so a
 * queue write can never reach them.
 *
 * The objects are frozen identity constants: `calculateCopy` rejects any other
 * value with a TypeError rather than silently reinterpreting a typo as "no
 * alignment" or as the other direction.
 *
 * @typedef {{ readonly aligned: boolean, readonly direction: "buffer-to-texture" | "texture-to-buffer" }} CopyPolicyValue
 * @type {{ readonly queueWrite: CopyPolicyValue, readonly bufferToTexture: CopyPolicyValue, readonly textureToBuffer: CopyPolicyValue }}
 */
export const CopyPolicy = Object.freeze({
  queueWrite: Object.freeze({ aligned: false, direction: "buffer-to-texture" }),
  bufferToTexture: Object.freeze({ aligned: true, direction: "buffer-to-texture" }),
  textureToBuffer: Object.freeze({ aligned: true, direction: "texture-to-buffer" }),
});

/**
 * One row of WebGPU's texel-block facts for a named format, in the same shape
 * as the Zig binding's `FormatRow`. A zero footprint with a false destination
 * flag means the CRD publishes none for that aspect (depth24plus), never an
 * invented size. Writability is a separate verdict from the footprint.
 *
 * @typedef {{
 *   name: string,
 *   byte: number,
 *   blockWidth: number,
 *   blockHeight: number,
 *   colorBytesPerBlock: number,
 *   hasDepth: boolean,
 *   hasStencil: boolean,
 *   depthBytesPerBlock: number,
 *   depthWriteDestination: boolean,
 *   stencilBytesPerBlock: number,
 *   stencilWriteDestination: boolean,
 *   family?: "bc" | "etc2" | "astc",
 *   sliced3d?: boolean,
 * }} FormatRow
 */

/**
 * @param {string} name
 * @param {number} byte
 * @param {number} bytesPerBlock
 * @returns {FormatRow}
 */
function colorFormat(name, byte, bytesPerBlock) {
  return {
    name,
    byte,
    blockWidth: 1,
    blockHeight: 1,
    colorBytesPerBlock: bytesPerBlock,
    hasDepth: false,
    hasStencil: false,
    depthBytesPerBlock: 0,
    depthWriteDestination: false,
    stencilBytesPerBlock: 0,
    stencilWriteDestination: false,
  };
}

/**
 * @param {string} name
 * @param {number} byte
 * @param {Partial<FormatRow>} fields
 * @returns {FormatRow}
 */
function depthStencilFormat(name, byte, fields) {
  return {
    name,
    byte,
    blockWidth: 1,
    blockHeight: 1,
    colorBytesPerBlock: 0,
    hasDepth: false,
    hasStencil: false,
    depthBytesPerBlock: 0,
    depthWriteDestination: false,
    stencilBytesPerBlock: 0,
    stencilWriteDestination: false,
    ...fields,
  };
}

/** BC names in plan/CRD byte order; `0x80 + index` is the ABI byte. */
const BC_NAMES = [
  "bc1-rgba-unorm", "bc1-rgba-unorm-srgb",
  "bc2-rgba-unorm", "bc2-rgba-unorm-srgb",
  "bc3-rgba-unorm", "bc3-rgba-unorm-srgb",
  "bc4-r-unorm", "bc4-r-snorm",
  "bc5-rg-unorm", "bc5-rg-snorm",
  "bc6h-rgb-ufloat", "bc6h-rgb-float",
  "bc7-rgba-unorm", "bc7-rgba-unorm-srgb",
];

/** ETC2/EAC names in plan/CRD byte order; `0x90 + index` is the ABI byte. */
const ETC2_NAMES = [
  "etc2-rgb8unorm", "etc2-rgb8unorm-srgb",
  "etc2-rgb8a1unorm", "etc2-rgb8a1unorm-srgb",
  "etc2-rgba8unorm", "etc2-rgba8unorm-srgb",
  "eac-r11unorm", "eac-r11snorm",
  "eac-rg11unorm", "eac-rg11snorm",
];

/** ASTC shapes in plan/CRD order: low nibble width, high nibble height. */
const ASTC_SHAPES = [
  0x44, 0x45, 0x55, 0x56, 0x66, 0x58, 0x68,
  0x88, 0x5a, 0x6a, 0x8a, 0xaa, 0xac, 0xcc,
];

/**
 * ASTC names in plan/CRD byte order, derived from the packed shape table:
 * `0xa0 + index*2` is linear and `0xa1 + index*2` sRGB. Deriving the 28
 * spellings from the fourteen shapes keeps one table instead of two.
 */
const ASTC_NAMES = ASTC_SHAPES.flatMap((shape) => {
  const suffix = `${shape & 0x0f}x${shape >> 4}-unorm`;
  return [`astc-${suffix}`, `astc-${suffix}-srgb`];
});

/**
 * One compressed format's facts, from a name or ABI byte. Plan 07's tranche A
 * fills all 52 rows now (slim codes + one packed ASTC shape table) so the later
 * tranches add schema names and decoders only, never arithmetic. All 52 names
 * now resolve as strings, ASTC's from the shape table above.
 *
 * @param {string | number} format
 * @returns {{byte: number, blockWidth: number, blockHeight: number, bytesPerBlock: number, family: "bc" | "etc2" | "astc", sliced3d: boolean} | null}
 */
function compressedFacts(format) {
  let code = format;
  if (typeof code === "string") {
    const bc = BC_NAMES.indexOf(code);
    if (bc >= 0) {
      code = 0x80 + bc;
    } else {
      const etc2 = ETC2_NAMES.indexOf(code);
      if (etc2 >= 0) {
        code = 0x90 + etc2;
      } else {
        const astc = ASTC_NAMES.indexOf(code);
        if (astc < 0) return null;
        code = 0xa0 + astc;
      }
    }
  }
  if (!Number.isSafeInteger(code) || code < 0 || code > 255) return null;
  if (code >= 0x80 && code <= 0x8d) {
    const index = code - 0x80;
    return {
      byte: code,
      blockWidth: 4,
      blockHeight: 4,
      bytesPerBlock: index === 0 || index === 1 || index === 6 || index === 7 ? 8 : 16,
      family: "bc",
      sliced3d: true,
    };
  }
  if (code >= 0x90 && code <= 0x99) {
    const index = code - 0x90;
    return {
      byte: code,
      blockWidth: 4,
      blockHeight: 4,
      bytesPerBlock: index <= 3 || index === 6 || index === 7 ? 8 : 16,
      family: "etc2",
      sliced3d: false,
    };
  }
  if (code >= 0xa0 && code <= 0xbb) {
    const shape = ASTC_SHAPES[(code - 0xa0) >> 1];
    return {
      byte: code,
      blockWidth: shape & 0x0f,
      blockHeight: shape >> 4,
      bytesPerBlock: 16,
      family: "astc",
      sliced3d: true,
    };
  }
  return null;
}

/**
 * Every named ordinary format, in the Zig enum's own declaration order. The
 * two sentinels (`preferredCanvasFormat`, unknown bytes) and compressed names
 * deliberately have no row here: a compressed name/byte resolves through
 * `compressedFacts`, which is also the single block/byte table.
 *
 * @type {FormatRow[]}
 */
const FORMAT_ROWS = [
  // 8-bit RGBA/BGRA and wide RGBA/sRGB (0x0x).
  colorFormat("rgba8unorm", 0x00, 4),
  colorFormat("rgba8snorm", 0x01, 4),
  colorFormat("rgba8uint", 0x02, 4),
  colorFormat("rgba8sint", 0x03, 4),
  colorFormat("bgra8unorm", 0x04, 4),
  colorFormat("rgba16float", 0x05, 8),
  colorFormat("rgba32float", 0x06, 16),
  colorFormat("rgba8unorm-srgb", 0x07, 4),
  colorFormat("bgra8unorm-srgb", 0x08, 4),

  // Depth / stencil (0x1x). depth24plus has no copy footprint; the
  // depth32float family's depth aspect is a validated copy source but not a
  // destination. stencil8 and depth16unorm are both.
  depthStencilFormat("depth24plus", 0x10, { hasDepth: true }),
  depthStencilFormat("depth24plus-stencil8", 0x11, {
    hasDepth: true,
    hasStencil: true,
    stencilBytesPerBlock: 1,
    stencilWriteDestination: true,
  }),
  depthStencilFormat("depth32float", 0x12, {
    hasDepth: true,
    depthBytesPerBlock: 4,
  }),
  depthStencilFormat("stencil8", 0x13, {
    hasStencil: true,
    stencilBytesPerBlock: 1,
    stencilWriteDestination: true,
  }),
  depthStencilFormat("depth16unorm", 0x14, {
    hasDepth: true,
    depthBytesPerBlock: 2,
    depthWriteDestination: true,
  }),
  depthStencilFormat("depth32float-stencil8", 0x15, {
    hasDepth: true,
    hasStencil: true,
    depthBytesPerBlock: 4,
    stencilBytesPerBlock: 1,
    stencilWriteDestination: true,
  }),

  // 32-bit-per-channel r/rg (0x2x).
  colorFormat("r32float", 0x20, 4),
  colorFormat("rg32float", 0x21, 8),
  colorFormat("r32uint", 0x22, 4),
  colorFormat("r32sint", 0x23, 4),
  colorFormat("rg32uint", 0x24, 8),
  colorFormat("rg32sint", 0x25, 8),

  // 8-bit & 16-bit-float r/rg (0x3x).
  colorFormat("r8unorm", 0x30, 1),
  colorFormat("rg8unorm", 0x31, 2),
  colorFormat("r16float", 0x32, 2),
  colorFormat("rg16float", 0x33, 4),
  colorFormat("r8snorm", 0x34, 1),
  colorFormat("r8uint", 0x35, 1),
  colorFormat("r8sint", 0x36, 1),
  colorFormat("rg8snorm", 0x37, 2),
  colorFormat("rg8uint", 0x38, 2),
  colorFormat("rg8sint", 0x39, 2),

  // 16-bit int/unorm r/rg (0x4x).
  colorFormat("r16uint", 0x40, 2),
  colorFormat("r16sint", 0x41, 2),
  colorFormat("rg16uint", 0x42, 4),
  colorFormat("rg16sint", 0x43, 4),
  colorFormat("r16unorm", 0x44, 2),
  colorFormat("r16snorm", 0x45, 2),
  colorFormat("rg16unorm", 0x46, 4),
  colorFormat("rg16snorm", 0x47, 4),

  // 16-bit int/unorm rgba (0x5x).
  colorFormat("rgba16uint", 0x50, 8),
  colorFormat("rgba16sint", 0x51, 8),
  colorFormat("rgba16unorm", 0x52, 8),
  colorFormat("rgba16snorm", 0x53, 8),

  // 32-bit int rgba (0x6x).
  colorFormat("rgba32uint", 0x60, 16),
  colorFormat("rgba32sint", 0x61, 16),

  // Packed 32-bit (0x7x).
  colorFormat("rgb10a2unorm", 0x70, 4),
  colorFormat("rgb10a2uint", 0x71, 4),
  colorFormat("rg11b10ufloat", 0x72, 4),
  colorFormat("rgb9e5ufloat", 0x73, 4),
];

/** @type {Map<string, FormatRow>} */
const FORMAT_BY_NAME = new Map(FORMAT_ROWS.map((row) => [row.name, row]));
/** @type {Map<number, FormatRow>} */
const FORMAT_BY_BYTE = new Map(FORMAT_ROWS.map((row) => [row.byte, row]));

/** @type {Map<string, number>} */
const ASPECT_TAGS = new Map([
  ["all", 0],
  ["stencil-only", 1],
  ["depth-only", 2],
]);

/**
 * @param {Code} code
 * @param {Field} field
 * @param {number} [actual]
 * @param {number} [limit]
 * @returns {Refusal}
 */
function refusal(code, field, actual = 0, limit = 0) {
  return { code, field, actual, limit };
}

/**
 * Refuse a numeric value that cannot enter the contract's checked arithmetic.
 * The JS host has no u64; a non-safe, negative, nonnumeric or above-bound
 * value is not an integer the calculator can prove. The refusal is data and
 * happens before any product or sum touches the value.
 *
 * `actual` carries the value only when it is itself a nonnegative safe integer
 * (so an above-u32 field bound is reported exactly); otherwise it is 0, the
 * same convention the catalogue uses for a nonnumeric aspect/format.
 *
 * @param {Field} field
 * @param {number} actual
 * @param {number} limit
 * @returns {Refusal}
 */
function hostRefusal(field, actual, limit) {
  return refusal("arithmetic-overflow", field, actual, limit);
}

/**
 * Read a numeric input and prove it is a nonnegative safe integer within
 * `limit` before any arithmetic uses it.
 *
 * @param {Field} field
 * @param {unknown} value
 * @param {number} limit
 * @returns {NumberRead}
 */
function readBounded(field, value, limit) {
  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value) ||
    value < 0
  ) {
    return { refuse: hostRefusal(field, 0, limit) };
  }
  if (value > limit) {
    return { refuse: hostRefusal(field, value, limit) };
  }
  return { value };
}

/**
 * Read an optional u32 field. `undefined` and `null` are absence, not 0.
 *
 * @param {Field} field
 * @param {unknown} value
 * @returns {{ present: false } | { present: true, value: number } | { refuse: Refusal }}
 */
function readOptionalU32(field, value) {
  if (value === undefined || value === null) return { present: false };
  const read = readBounded(field, value, U32_MAX);
  if ("refuse" in read) return { refuse: read.refuse };
  return { present: true, value: read.value };
}

/**
 * @param {unknown} value
 * @returns {ExtentRead}
 */
function readExtent(value) {
  if (value === null || typeof value !== "object") {
    return { refuse: hostRefusal("size-width", 0, U32_MAX) };
  }
  const source = /** @type {ExtentInput} */ (value);
  const width = readBounded("size-width", source.width, U32_MAX);
  if ("refuse" in width) return { refuse: width.refuse };
  const height =
    source.height === undefined || source.height === null
      ? { value: 1 }
      : readBounded("size-height", source.height, U32_MAX);
  if ("refuse" in height) return { refuse: height.refuse };
  const depth =
    source.depthOrArrayLayers === undefined ||
    source.depthOrArrayLayers === null
      ? { value: 1 }
      : readBounded("size-depth-or-array-layers", source.depthOrArrayLayers, U32_MAX);
  if ("refuse" in depth) return { refuse: depth.refuse };
  return {
    value: { width: width.value, height: height.value, depthOrArrayLayers: depth.value },
  };
}

/**
 * @param {unknown} value
 * @returns {OriginRead}
 */
function readOrigin(value) {
  if (value === undefined || value === null) {
    return { value: { x: 0, y: 0, z: 0 } };
  }
  if (typeof value !== "object") {
    return { refuse: hostRefusal("origin-x", 0, U32_MAX) };
  }
  const source = /** @type {OriginInput} */ (value);
  const x =
    source.x === undefined || source.x === null
      ? { value: 0 }
      : readBounded("origin-x", source.x, U32_MAX);
  if ("refuse" in x) return { refuse: x.refuse };
  const y =
    source.y === undefined || source.y === null
      ? { value: 0 }
      : readBounded("origin-y", source.y, U32_MAX);
  if ("refuse" in y) return { refuse: y.refuse };
  const z =
    source.z === undefined || source.z === null
      ? { value: 0 }
      : readBounded("origin-z", source.z, U32_MAX);
  if ("refuse" in z) return { refuse: z.refuse };
  return { value: { x: x.value, y: y.value, z: z.value } };
}

/**
 * Resolve a format name or its ABI byte to the format row. Sentinels,
 * undeclared bytes and unknown names resolve to no row (never a fallback).
 *
 * @param {unknown} format
 * @returns {FormatRow | null}
 */
function resolveFormat(format) {
  if (typeof format === "string") return FORMAT_BY_NAME.get(format) ?? null;
  if (
    typeof format === "number" &&
    Number.isSafeInteger(format) &&
    format >= 0 &&
    format <= 255
  ) {
    return FORMAT_BY_BYTE.get(format) ?? null;
  }
  return null;
}

/**
 * Resolve an aspect name or numeric tag to its wire tag. Anything that is not
 * a known name or an integer tag in 0..255 stays an unknown tag; the format
 * row decides whether that is `invalid-aspect`.
 *
 * @param {unknown} aspect
 * @returns {number}
 */
function aspectTag(aspect) {
  if (aspect === undefined || aspect === null) return 0;
  if (typeof aspect === "string") return ASPECT_TAGS.get(aspect) ?? 0xff;
  if (
    typeof aspect === "number" &&
    Number.isSafeInteger(aspect) &&
    aspect >= 0 &&
    aspect <= 255
  ) {
    return aspect;
  }
  return 0xff;
}

/**
 * Resolve a format and the selected aspect to its copy footprint. Unknown
 * formats, sentinels and absent aspect rows refuse with `invalid-format`
 * instead of falling back to any format. Depth/stencil rows resolve exactly
 * one legal aspect and apply the destination policy before exposing a
 * footprint; plain colour formats accept only the `all` tag.
 *
 * @param {string | number} format
 * @param {AspectName | number | string | null} [aspect]
 * @returns {FormatInfoResult}
 */
export function formatInfo(format, aspect = "all") {
  const row = resolveFormat(format);
  if (row === null) {
    const compressed = compressedFacts(format);
    if (compressed === null) return { refuse: refusal("invalid-format", "format") };
    if (aspectTag(aspect) !== 0) return { refuse: refusal("invalid-aspect", "aspect") };
    return {
      ok: {
        blockWidth: compressed.blockWidth,
        blockHeight: compressed.blockHeight,
        bytesPerBlock: compressed.bytesPerBlock,
        hasDepth: false,
        hasStencil: false,
        writeDestination: true,
      },
    };
  }
  const tag = aspectTag(aspect);

  if (row.hasDepth || row.hasStencil) {
    /** @type {number} */
    let bytesPerBlock;
    switch (tag) {
      case 2: {
        if (!row.hasDepth) return { refuse: refusal("invalid-aspect", "aspect") };
        if (!row.depthWriteDestination) {
          return { refuse: refusal("aspect-not-writable", "aspect") };
        }
        bytesPerBlock = row.depthBytesPerBlock;
        break;
      }
      case 1: {
        if (!row.hasStencil) return { refuse: refusal("invalid-aspect", "aspect") };
        if (!row.stencilWriteDestination) {
          return { refuse: refusal("aspect-not-writable", "aspect") };
        }
        bytesPerBlock = row.stencilBytesPerBlock;
        break;
      }
      default:
        // `.all` is not singular, and an undeclared aspect tag is unknown.
        return { refuse: refusal("invalid-aspect", "aspect") };
    }
    if (bytesPerBlock === 0) {
      return { refuse: refusal("invalid-format", "format") };
    }
    return {
      ok: {
        blockWidth: row.blockWidth,
        blockHeight: row.blockHeight,
        bytesPerBlock,
        hasDepth: row.hasDepth,
        hasStencil: row.hasStencil,
        writeDestination: true,
      },
    };
  }

  if (tag !== 0) return { refuse: refusal("invalid-aspect", "aspect") };
  if (row.colorBytesPerBlock === 0) {
    return { refuse: refusal("invalid-format", "format") };
  }
  return {
    ok: {
      blockWidth: row.blockWidth,
      blockHeight: row.blockHeight,
      bytesPerBlock: row.colorBytesPerBlock,
      hasDepth: false,
      hasStencil: false,
      writeDestination: true,
    },
  };
}

/** Compressed family → the device feature that admits it. */
const FAMILY_FEATURE = {
  bc: "texture-compression-bc",
  etc2: "texture-compression-etc2",
  astc: "texture-compression-astc",
};
/** Compressed family → the feature that admits 3D. ETC2 has none. */
const FAMILY_SLICED_FEATURE = {
  bc: "texture-compression-bc-sliced-3d",
  astc: "texture-compression-astc-sliced-3d",
};

/**
 * The first device feature a format/dimension pair requires but `features`
 * lacks, or null. Ordinary formats need none; a compressed format needs its
 * family feature and, for 3D, the family's sliced feature. ETC2/EAC 3D is
 * refused by the descriptor rule below, not by a feature (the CRD defines no
 * ETC2 sliced feature), so this never invents one.
 *
 * @param {string | number} format
 * @param {Dimension | string} dimension
 * @param {Set<string> | { has(f: string): boolean }} features
 * @returns {string | null}
 */
export function missingFormatFeature(format, dimension, features) {
  const row = compressedFacts(format);
  if (row === null) return null;
  const base = FAMILY_FEATURE[row.family];
  if (!features.has(base)) return base;
  if (dimension === "3d" && row.sliced3d) {
    const sliced = FAMILY_SLICED_FEATURE[row.family];
    if (!features.has(sliced)) return sliced;
  }
  return null;
}

/**
 * The complete create-time refusal reason for a compressed format, or null.
 * Feature absence is checked before the descriptor shape, matching the plan's
 * order, and the caller prefixes the public texture name.
 *
 * @param {string | number} format
 * @param {Dimension | string} dimension
 * @param {Extent} size
 * @param {Set<string> | { has(f: string): boolean }} features
 * @returns {string | null}
 */
export function formatCreationRefusal(format, dimension, size, features) {
  const missing = missingFormatFeature(format, dimension, features);
  if (missing !== null) {
    return `format '${format}' requires '${missing}'; this adapter does not support it`;
  }
  const refusal = formatDescriptorRefusal(format, dimension, size);
  if (refusal === null) return null;
  if (refusal.field === "format") return `format '${format}' cannot be ${dimension}`;
  const block = compressedFacts(format);
  if (block === null) return null;
  return `format '${format}' size ${size.width}x${size.height} is not a multiple of its ${block.blockWidth}x${block.blockHeight} texel block`;
}

/**
 * The creation-side compressed descriptor rule, device-independent: 1D is
 * never compressed, a 3D descriptor needs a sliced-3d family, and the BASE
 * width/height must be whole texel blocks. This tranche does not request
 * `texture-compression-unaligned`, so the strict rule is the contract's rule.
 *
 * @param {string | number} format
 * @param {Dimension | string} dimension
 * @param {Extent} size
 * @returns {Refusal | null}
 */
export function formatDescriptorRefusal(format, dimension, size) {
  const row = compressedFacts(format);
  if (row === null) return null;
  if (dimension === "1d") {
    return refusal("invalid-texture-descriptor", "format", row.byte, 0);
  }
  if (dimension === "3d" && !row.sliced3d) {
    return refusal("invalid-texture-descriptor", "format", row.byte, 0);
  }
  if (size.width % row.blockWidth !== 0) {
    return refusal("invalid-texture-descriptor", "size-width", size.width, row.blockWidth);
  }
  if (size.height % row.blockHeight !== 0) {
    return refusal("invalid-texture-descriptor", "size-height", size.height, row.blockHeight);
  }
  return null;
}

/**
 * WebGPU's `maximum mipLevel count`: floor(log2(maxDimension)) + 1, with 1D
 * fixed at one level. `Math.clz32` gives the same bit length for a u32.
 *
 * @param {Dimension} dimension
 * @param {Extent} size
 * @returns {number}
 */
function maximumMipLevelCount(dimension, size) {
  if (dimension === "1d") return 1;
  const maxDimension =
    dimension === "2d"
      ? Math.max(size.width, size.height)
      : Math.max(size.width, size.height, size.depthOrArrayLayers);
  return 32 - Math.clz32(maxDimension);
}

/**
 * Logical and physical (block-rounded) extents at `mipLevel` for a concrete
 * base size. 2D array layers are not reduced by the mip; 3D depth is. Every
 * division is a shift after proving the index is below 32, and rounding is
 * computed in Number space only after the operands are proven safe integers.
 *
 * @param {ExtentInput} size
 * @param {Dimension | string} dimension
 * @param {number} mipLevel
 * @param {number} blockWidth
 * @param {number} blockHeight
 * @returns {MipExtentResult}
 */
export function mipExtent(size, dimension, mipLevel, blockWidth, blockHeight) {
  const extent = readExtent(size);
  if ("refuse" in extent) return { refuse: extent.refuse };
  const base = extent.value;

  if (dimension !== "1d" && dimension !== "2d" && dimension !== "3d") {
    return { refuse: refusal("invalid-texture-descriptor", "dimension") };
  }
  // `blockWidth`/`blockHeight` are format facts: without a usable block there
  // is no format row to resolve, matching `invalid-format`.
  if (
    !Number.isSafeInteger(blockWidth) ||
    !Number.isSafeInteger(blockHeight) ||
    blockWidth <= 0 ||
    blockHeight <= 0 ||
    blockWidth > U32_MAX ||
    blockHeight > U32_MAX
  ) {
    return { refuse: refusal("invalid-format", "format") };
  }

  const level = readBounded("mip-level", mipLevel, U32_MAX);
  if ("refuse" in level) return { refuse: level.refuse };
  if (level.value >= 32) {
    return {
      refuse: refusal("mip-out-of-range", "mip-level", level.value, 32),
    };
  }

  /** @type {Extent} */
  let logical;
  switch (dimension) {
    case "1d":
      logical = {
        width: Math.max(1, base.width >>> level.value),
        height: 1,
        depthOrArrayLayers: 1,
      };
      break;
    case "3d":
      logical = {
        width: Math.max(1, base.width >>> level.value),
        height: Math.max(1, base.height >>> level.value),
        depthOrArrayLayers: Math.max(1, base.depthOrArrayLayers >>> level.value),
      };
      break;
    default:
      logical = {
        width: Math.max(1, base.width >>> level.value),
        height: Math.max(1, base.height >>> level.value),
        depthOrArrayLayers: base.depthOrArrayLayers,
      };
      break;
  }

  // Round the logical axes up to whole texel blocks with exact integer
  // remainder arithmetic; the +block sum is at most 2^33, which Number
  // carries exactly. Avoid floating division here so no rounding mode can
  // change the rounded extent.
  const widthRemainder = logical.width % blockWidth;
  const paddedWidth =
    widthRemainder === 0 ? logical.width : logical.width + (blockWidth - widthRemainder);
  if (paddedWidth > U32_MAX) {
    return {
      refuse: refusal("arithmetic-overflow", "size-width", paddedWidth, U32_MAX),
    };
  }
  /** @type {number} */
  let physicalHeight = 1;
  if (dimension !== "1d") {
    const heightRemainder = logical.height % blockHeight;
    const paddedHeight =
      heightRemainder === 0
        ? logical.height
        : logical.height + (blockHeight - heightRemainder);
    if (paddedHeight > U32_MAX) {
      return {
        refuse: refusal("arithmetic-overflow", "size-height", paddedHeight, U32_MAX),
      };
    }
    physicalHeight = paddedHeight;
  }

  return {
    ok: {
      logical,
      physical: {
        width: paddedWidth,
        height: physicalHeight,
        depthOrArrayLayers: logical.depthOrArrayLayers,
      },
    },
  };
}

/**
 * @param {unknown} descriptor
 * @returns {{ value: TextureDescriptorInput } | { refuse: Refusal }}
 */
function normalizeDescriptor(descriptor) {
  if (descriptor === null || typeof descriptor !== "object") {
    return { refuse: refusal("invalid-texture-descriptor", "none") };
  }
  const source = /** @type {TextureDescriptorInput} */ (descriptor);
  const size = readExtent(source.size);
  if ("refuse" in size) return { refuse: size.refuse };
  if (
    source.dimension !== "1d" &&
    source.dimension !== "2d" &&
    source.dimension !== "3d"
  ) {
    return { refuse: refusal("invalid-texture-descriptor", "dimension") };
  }
  return {
    value: {
      size: size.value,
      dimension: source.dimension,
      format: source.format,
      usage: source.usage,
      sampleCount: source.sampleCount,
      mipLevelCount: source.mipLevelCount,
      extentSource: source.extentSource,
    },
  };
}

/**
 * @param {TextureDescriptorInput} descriptor
 * @returns {Refusal | null}
 */
function validateDescriptor(descriptor) {
  const size = /** @type {Extent} */ (descriptor.size);
  if (size.width === 0) {
    return refusal("invalid-texture-descriptor", "size-width", 0, 1);
  }
  if (size.height === 0) {
    return refusal("invalid-texture-descriptor", "size-height", 0, 1);
  }
  if (size.depthOrArrayLayers === 0) {
    return refusal("invalid-texture-descriptor", "size-depth-or-array-layers", 0, 1);
  }

  const mipCount = readBounded("mip-level-count", descriptor.mipLevelCount, U32_MAX);
  if ("refuse" in mipCount) return mipCount.refuse;
  if (mipCount.value === 0) {
    return refusal("invalid-texture-descriptor", "mip-level-count", 0, 1);
  }

  const dimension = /** @type {Dimension} */ (descriptor.dimension);
  if (dimension === "1d") {
    if (size.height !== 1) {
      return refusal("invalid-texture-descriptor", "size-height", size.height, 1);
    }
    if (size.depthOrArrayLayers !== 1) {
      return refusal(
        "invalid-texture-descriptor",
        "size-depth-or-array-layers",
        size.depthOrArrayLayers,
        1,
      );
    }
  }

  const maxMips = maximumMipLevelCount(dimension, size);
  if (mipCount.value > maxMips) {
    return refusal(
      "invalid-texture-descriptor",
      "mip-level-count",
      mipCount.value,
      maxMips,
    );
  }

  // Compressed creation rules before the ordinary format/dimension rules:
  // 1D is never compressed, 3D needs a sliced-3d family, and the base extent
  // is block-aligned.
  const compressed = formatDescriptorRefusal(descriptor.format, dimension, size);
  if (compressed !== null) return compressed;

  // Plain colour formats support 1D, 2D and 3D; depth/stencil formats do not
  // support 1D or 3D. Unknown formats fall through to `formatInfo`.
  const row = resolveFormat(descriptor.format);
  if (
    row !== null &&
    (row.hasDepth || row.hasStencil) &&
    (dimension === "1d" || dimension === "3d")
  ) {
    return refusal("invalid-texture-descriptor", "format", row.byte, 0);
  }
  return null;
}

/**
 * The texture half of WebGPU's `validating texture buffer copy`: the texture
 * endpoint must carry the usage bit the copy direction requires (COPY_DST for
 * a destination, COPY_SRC for a source) and exactly one sample. Usage is the
 * outer check, so a texture that is the wrong endpoint never reaches aspect
 * parsing. `actual` is the usage byte (or sample count); `limit` is the
 * required usage bit (or 1).
 *
 * @param {TextureDescriptorInput} descriptor
 * @param {CopyPolicyValue} policy
 * @returns {Refusal | null}
 */
function textureEndpointRefusal(descriptor, policy) {
  const usage = readBounded("usage", descriptor.usage, 0xff);
  if ("refuse" in usage) return usage.refuse;
  const isSource = policy.direction === "texture-to-buffer";
  const required = isSource ? 1 : 2;
  if ((usage.value & required) === 0) {
    return refusal(
      isSource ? "missing-copy-src" : "missing-copy-dst",
      "usage",
      usage.value,
      required,
    );
  }
  const sampleCount = readBounded("sample-count", descriptor.sampleCount, U32_MAX);
  if ("refuse" in sampleCount) return sampleCount.refuse;
  if (sampleCount.value !== 1) {
    return refusal("multisampled-destination", "sample-count", sampleCount.value, 1);
  }
  return null;
}

/**
 * @param {Origin} origin
 * @param {Extent} physical
 * @returns {Refusal | null}
 */
function originRefusal(origin, physical) {
  if (origin.x > physical.width) {
    return refusal("origin-out-of-bounds", "origin-x", origin.x, physical.width);
  }
  if (origin.y > physical.height) {
    return refusal("origin-out-of-bounds", "origin-y", origin.y, physical.height);
  }
  if (origin.z > physical.depthOrArrayLayers) {
    return refusal(
      "origin-out-of-bounds",
      "origin-z",
      origin.z,
      physical.depthOrArrayLayers,
    );
  }
  return null;
}

/**
 * WebGPU requires a depth/stencil texel copy to cover the full physical
 * subresource: the copy extent must equal the physical mip extent, which also
 * forces every origin component to zero. A reduced extent or a nonzero origin
 * is a partial write, named per axis in x, y, z, width, height, depth order.
 *
 * @param {Origin} origin
 * @param {Extent} copy
 * @param {Extent} physical
 * @param {Code} [code] - the path's code; a texture→texture copy names
 *   `partial-subresource-copy` because it also covers multisampled endpoints.
 * @returns {Refusal | null}
 */
function fullSubresourceRefusal(origin, copy, physical, code = "partial-depth-stencil-write") {
  if (origin.x !== 0) {
    return refusal(code, "origin-x", origin.x, 0);
  }
  if (origin.y !== 0) {
    return refusal(code, "origin-y", origin.y, 0);
  }
  if (origin.z !== 0) {
    return refusal(code, "origin-z", origin.z, 0);
  }
  if (copy.width !== physical.width) {
    return refusal(code, "size-width", copy.width, physical.width);
  }
  if (copy.height !== physical.height) {
    return refusal(code, "size-height", copy.height, physical.height);
  }
  if (copy.depthOrArrayLayers !== physical.depthOrArrayLayers) {
    return refusal(
      code,
      "size-depth-or-array-layers",
      copy.depthOrArrayLayers,
      physical.depthOrArrayLayers,
    );
  }
  return null;
}

/**
 * Default an omitted size to the remaining physical extent at the origin, or
 * prove an explicit size fits. A sum of two u32 values is at most 2^33, which
 * Number carries exactly, so no wrapping can occur here.
 *
 * @param {Extent} physical
 * @param {Origin} origin
 * @param {WriteLayoutInput} write
 * @returns {{ value: Extent } | { refuse: Refusal }}
 */
function resolveCopyExtent(physical, origin, write) {
  if (write.size !== undefined && write.size !== null) {
    const size = readExtent(write.size);
    if ("refuse" in size) return size;
    const endX = origin.x + size.value.width;
    if (endX > physical.width) {
      return {
        refuse: refusal("extent-out-of-bounds", "size-width", endX, physical.width),
      };
    }
    const endY = origin.y + size.value.height;
    if (endY > physical.height) {
      return {
        refuse: refusal("extent-out-of-bounds", "size-height", endY, physical.height),
      };
    }
    const endZ = origin.z + size.value.depthOrArrayLayers;
    if (endZ > physical.depthOrArrayLayers) {
      return {
        refuse: refusal(
          "extent-out-of-bounds",
          "size-depth-or-array-layers",
          endZ,
          physical.depthOrArrayLayers,
        ),
      };
    }
    return { value: size.value };
  }
  return {
    value: {
      width: physical.width - origin.x,
      height: physical.height - origin.y,
      depthOrArrayLayers: physical.depthOrArrayLayers - origin.z,
    },
  };
}

/**
 * Check a copy origin and extent against a format's texel-block dimensions.
 * Plan 01 has no block larger than 1x1, so `calculateWrite` always passes; the
 * pure rule exists for plan 07's compressed rows.
 *
 * @param {Origin} origin
 * @param {Extent} size
 * @param {number} blockWidth
 * @param {number} blockHeight
 * @returns {Refusal | null}
 */
function blockAlignmentRefusal(origin, size, blockWidth, blockHeight) {
  if (origin.x % blockWidth !== 0) {
    return refusal("unaligned-block-origin", "origin-x", origin.x, blockWidth);
  }
  if (origin.y % blockHeight !== 0) {
    return refusal("unaligned-block-origin", "origin-y", origin.y, blockHeight);
  }
  if (size.width % blockWidth !== 0) {
    return refusal("unaligned-block-extent", "size-width", size.width, blockWidth);
  }
  if (size.height % blockHeight !== 0) {
    return refusal("unaligned-block-extent", "size-height", size.height, blockHeight);
  }
  return null;
}

/**
 * The two buffer-copy alignment rules, applied only under the aligned policy.
 * `validating GPUTexelCopyBufferInfo` requires a supplied `bytesPerRow` to be
 * a multiple of 256; `validating texture buffer copy` requires the buffer
 * offset to be a multiple of the texel block copy footprint, except that a
 * depth-stencil texture endpoint — source or destination — sets it to 4.
 * `writeTexture` passes `aligned = false` and acquires neither.
 *
 * @param {WriteLayoutInput} write
 * @param {FormatInfo} info
 * @returns {Refusal | null}
 */
function copyAlignmentRefusal(write, info) {
  if (write.bytesPerRow !== undefined && write.bytesPerRow !== null) {
    const supplied = readBounded("bytes-per-row", write.bytesPerRow, U32_MAX);
    if ("refuse" in supplied) return supplied.refuse;
    if (supplied.value % 256 !== 0) {
      return refusal(
        "bytes-per-row-alignment",
        "bytes-per-row",
        supplied.value,
        256,
      );
    }
  }

  const offsetAlignment =
    info.hasDepth || info.hasStencil ? 4 : info.bytesPerBlock;
  // `formatInfo` never exposes a zero footprint, but keep the rule total.
  if (offsetAlignment === 0) return refusal("invalid-format", "format");
  const offset = readBounded("offset", write.offset ?? 0, U32_MAX);
  if ("refuse" in offset) return offset.refuse;
  if (offset.value % offsetAlignment !== 0) {
    return refusal(
      "buffer-offset-alignment",
      "offset",
      offset.value,
      offsetAlignment,
    );
  }
  return null;
}

/**
 * Multiply two nonnegative values, proving the exact product is a safe
 * integer BEFORE the multiplication and a legal returned u32 after it. A
 * Number product outside the safe range would otherwise round silently.
 *
 * When the exact product is beyond `Number.MAX_SAFE_INTEGER`, the refusal
 * reports `actual = Number.MAX_SAFE_INTEGER`; JS cannot carry the exact u64
 * the Zig binding would report. The code, field and limit are identical.
 *
 * @param {Field} field
 * @param {number} a
 * @param {number} b
 * @returns {CheckedValue}
 */
function checkedMul(field, a, b) {
  if (a !== 0 && b > Math.floor(MAX_SAFE / a)) {
    return { refuse: refusal("arithmetic-overflow", field, MAX_SAFE, U32_MAX) };
  }
  const product = a * b;
  if (product > U32_MAX) {
    return { refuse: refusal("arithmetic-overflow", field, product, U32_MAX) };
  }
  return { value: product };
}

/**
 * Add two nonnegative values, proving the exact sum is a safe integer BEFORE
 * the addition and a legal returned u32 after it.
 *
 * @param {Field} field
 * @param {number} a
 * @param {number} b
 * @returns {CheckedValue}
 */
function checkedAdd(field, a, b) {
  if (a > MAX_SAFE - b) {
    return { refuse: refusal("arithmetic-overflow", field, MAX_SAFE, U32_MAX) };
  }
  const sum = a + b;
  if (sum > U32_MAX) {
    return { refuse: refusal("arithmetic-overflow", field, sum, U32_MAX) };
  }
  return { value: sum };
}

/**
 * @typedef {{
 *   widthInBlocks: number,
 *   heightInBlocks: number,
 *   bytesInLastRow: number,
 *   bytesPerRow: number,
 *   rowsPerImage: number,
 *   imageStride: number,
 *   requiredBytesInCopy: number,
 *   endOffset: number,
 * }} LinearLayout
 * @typedef {{ value: LinearLayout } | { refuse: Refusal }} LinearResult
 */

/**
 * The arithmetic specification's steps 5-9: block counts, stride presence and
 * minima, normalized strides, the required span with final-row and
 * final-image padding excluded, and the offset-inclusive end. Every product
 * and sum is checked and must fit u32 before it becomes a returned value.
 *
 * @param {WriteLayoutInput} write
 * @param {Extent} copy
 * @param {FormatInfo} info
 * @returns {LinearResult}
 */
function resolveLinearLayout(write, copy, info) {
  const widthInBlocks = Math.trunc(copy.width / info.blockWidth);
  const heightInBlocks = Math.trunc(copy.height / info.blockHeight);

  const bytesInLastRow = checkedMul("size-width", widthInBlocks, info.bytesPerBlock);
  if ("refuse" in bytesInLastRow) return { refuse: bytesInLastRow.refuse };

  const depth = copy.depthOrArrayLayers;
  const bytesPerRowPresent =
    write.bytesPerRow !== undefined && write.bytesPerRow !== null;
  const rowsPerImagePresent =
    write.rowsPerImage !== undefined && write.rowsPerImage !== null;

  // Presence is decided before any value is read, exactly like Zig's `?u32`.
  if ((heightInBlocks > 1 || depth > 1) && !bytesPerRowPresent) {
    return {
      refuse: refusal("missing-bytes-per-row", "bytes-per-row", 0, bytesInLastRow.value),
    };
  }
  if (depth > 1 && !rowsPerImagePresent) {
    return {
      refuse: refusal("missing-rows-per-image", "rows-per-image", 0, heightInBlocks),
    };
  }

  const bytesPerRow = readOptionalU32("bytes-per-row", write.bytesPerRow);
  const rowsPerImage = readOptionalU32("rows-per-image", write.rowsPerImage);
  if ("refuse" in bytesPerRow) return { refuse: bytesPerRow.refuse };
  if ("refuse" in rowsPerImage) return { refuse: rowsPerImage.refuse };

  // Supplied minima apply even when the field was not required.
  if (bytesPerRow.present && bytesPerRow.value < bytesInLastRow.value) {
    return {
      refuse: refusal(
        "bytes-per-row-too-small",
        "bytes-per-row",
        bytesPerRow.value,
        bytesInLastRow.value,
      ),
    };
  }
  if (rowsPerImage.present && rowsPerImage.value < heightInBlocks) {
    return {
      refuse: refusal(
        "rows-per-image-too-small",
        "rows-per-image",
        rowsPerImage.value,
        heightInBlocks,
      ),
    };
  }

  // Presence is decided above; only now may an omitted stride take its
  // normalized minimum. An authored zero never becomes a minimum.
  const normalizedBytesPerRow = bytesPerRow.present
    ? bytesPerRow.value
    : bytesInLastRow.value;
  const normalizedRowsPerImage = rowsPerImage.present
    ? rowsPerImage.value
    : heightInBlocks;
  const imageStride = checkedMul(
    "bytes-per-row",
    normalizedBytesPerRow,
    normalizedRowsPerImage,
  );
  if ("refuse" in imageStride) return { refuse: imageStride.refuse };

  let requiredBytes = 0;
  if (depth > 0) {
    // One full image stride per gap before the final image. This term exists
    // even when the copy height is zero.
    const imageGap = checkedMul(
      "size-depth-or-array-layers",
      imageStride.value,
      depth - 1,
    );
    if ("refuse" in imageGap) return { refuse: imageGap.refuse };
    const withGap = checkedAdd("data", requiredBytes, imageGap.value);
    if ("refuse" in withGap) return { refuse: withGap.refuse };
    requiredBytes = withGap.value;

    if (heightInBlocks > 0) {
      // The final row contributes bytesInLastRow, never a full stride.
      const rowGap = checkedMul(
        "bytes-per-row",
        normalizedBytesPerRow,
        heightInBlocks - 1,
      );
      if ("refuse" in rowGap) return { refuse: rowGap.refuse };
      const rowsAndLast = checkedAdd(
        "bytes-per-row",
        rowGap.value,
        bytesInLastRow.value,
      );
      if ("refuse" in rowsAndLast) return { refuse: rowsAndLast.refuse };
      const withRows = checkedAdd("data", requiredBytes, rowsAndLast.value);
      if ("refuse" in withRows) return { refuse: withRows.refuse };
      requiredBytes = withRows.value;
    }
  }

  // `offset` is counted once, outside the span.
  const offset = readBounded("offset", write.offset ?? 0, U32_MAX);
  if ("refuse" in offset) return { refuse: offset.refuse };
  const endOffset = checkedAdd("offset", offset.value, requiredBytes);
  if ("refuse" in endOffset) return { refuse: endOffset.refuse };

  return {
    value: {
      widthInBlocks,
      heightInBlocks,
      bytesInLastRow: bytesInLastRow.value,
      bytesPerRow: normalizedBytesPerRow,
      rowsPerImage: normalizedRowsPerImage,
      imageStride: imageStride.value,
      requiredBytesInCopy: requiredBytes,
      endOffset: endOffset.value,
    },
  };
}

/**
 * The shared texel-copy calculator. Stages, in order, so the first refusal is
 * stable and identical to the Zig binding: descriptor, the texture endpoint's
 * usage/sample count for the policy's direction, format/aspect, mip range, mip
 * extent, origin, default/explicit copy extent and range, depth/stencil full
 * subresource, block alignment, the policy's buffer-copy alignment, then the
 * linear-data rules (stride presence and minima, normalized strides, required
 * span, source/buffer length). A short aligned buffer reports
 * `buffer-out-of-bounds`; the queue write keeps plan 01's `insufficient-data`.
 *
 * `descriptor` and `write` use the shared corpus's camelCase object shapes.
 * `bytesPerRow`, `rowsPerImage` and `size` are optional; absence is
 * `undefined`/`null` and is never treated as an authored zero.
 *
 * `policy` is REQUIRED and must be one of the `CopyPolicy` identity constants:
 * a missing policy is a caller-shape error, never a silent queue write.
 *
 * @param {TextureDescriptorInput} descriptor
 * @param {WriteLayoutInput} write
 * @param {number} dataLength
 * @param {CopyPolicyValue} policy
 * @returns {Result}
 */
export function calculateCopy(
  descriptor,
  write,
  dataLength,
  policy,
) {
  if (
    policy !== CopyPolicy.queueWrite &&
    policy !== CopyPolicy.bufferToTexture &&
    policy !== CopyPolicy.textureToBuffer
  ) {
    throw new TypeError(
      "copy policy must be CopyPolicy.queueWrite, CopyPolicy.bufferToTexture or CopyPolicy.textureToBuffer",
    );
  }
  const aligned = policy.aligned;

  const writable =
    write !== null && typeof write === "object" ? write : {};

  const normalized = normalizeDescriptor(descriptor);
  if ("refuse" in normalized) return { refuse: normalized.refuse };
  const descriptorValue = normalized.value;

  const descriptorRefusal = validateDescriptor(descriptorValue);
  if (descriptorRefusal !== null) return { refuse: descriptorRefusal };

  const endpoint = textureEndpointRefusal(descriptorValue, policy);
  if (endpoint !== null) return { refuse: endpoint };

  const infoResult = formatInfo(descriptorValue.format, writable.aspect);
  if ("refuse" in infoResult) return { refuse: infoResult.refuse };
  const info = infoResult.ok;

  const mipLevel = readBounded("mip-level", writable.mipLevel ?? 0, U32_MAX);
  if ("refuse" in mipLevel) return { refuse: mipLevel.refuse };
  const mipCount = /** @type {number} */ (descriptorValue.mipLevelCount);
  if (mipLevel.value >= mipCount) {
    return {
      refuse: refusal("mip-out-of-range", "mip-level", mipLevel.value, mipCount),
    };
  }

  const mip = mipExtent(
    /** @type {Extent} */ (descriptorValue.size),
    /** @type {Dimension} */ (descriptorValue.dimension),
    mipLevel.value,
    info.blockWidth,
    info.blockHeight,
  );
  if ("refuse" in mip) return { refuse: mip.refuse };

  const originRead = readOrigin(writable.origin);
  if ("refuse" in originRead) return { refuse: originRead.refuse };
  const origin = originRead.value;

  const physical = mip.ok.physical;

  const originProblem = originRefusal(origin, physical);
  if (originProblem !== null) return { refuse: originProblem };

  const copyResult = resolveCopyExtent(physical, origin, writable);
  if ("refuse" in copyResult) return { refuse: copyResult.refuse };
  const copy = copyResult.value;

  // The CRD's range stage requires depth/stencil copies to cover the full
  // physical subresource; a subregion or nonzero origin is never a partial
  // aspect write. Plain colour formats keep their subregions.
  if (info.hasDepth || info.hasStencil) {
    const partial = fullSubresourceRefusal(origin, copy, physical);
    if (partial !== null) return { refuse: partial };
  }

  const blockProblem = blockAlignmentRefusal(
    origin,
    copy,
    info.blockWidth,
    info.blockHeight,
  );
  if (blockProblem !== null) return { refuse: blockProblem };

  if (aligned) {
    const alignmentProblem = copyAlignmentRefusal(writable, info);
    if (alignmentProblem !== null) return { refuse: alignmentProblem };
  }

  const linear = resolveLinearLayout(writable, copy, info);
  if ("refuse" in linear) return { refuse: linear.refuse };

  const source = readBounded("data", dataLength, MAX_SAFE);
  if ("refuse" in source) return { refuse: source.refuse };

  if (linear.value.endOffset > source.value) {
    return {
      refuse: refusal(
        aligned ? "buffer-out-of-bounds" : "insufficient-data",
        "data",
        linear.value.endOffset,
        source.value,
      ),
    };
  }

  return {
    ok: {
      logicalMipExtent: mip.ok.logical,
      physicalMipExtent: physical,
      copyExtent: copy,
      widthInBlocks: linear.value.widthInBlocks,
      heightInBlocks: linear.value.heightInBlocks,
      bytesInLastRow: linear.value.bytesInLastRow,
      bytesPerRow: linear.value.bytesPerRow,
      rowsPerImage: linear.value.rowsPerImage,
      imageStride: linear.value.imageStride,
      requiredBytesInCopy: linear.value.requiredBytesInCopy,
      endOffset: linear.value.endOffset,
    },
  };
}

/**
 * `GPUQueue.writeTexture`'s calculator: plan 01 exactly, with the aligned
 * policy's two buffer-copy rules permanently off.
 *
 * @param {TextureDescriptorInput} descriptor
 * @param {WriteLayoutInput} write
 * @param {number} dataLength
 * @returns {Result}
 */
export function calculateWrite(descriptor, write, dataLength) {
  return calculateCopy(descriptor, write, dataLength, CopyPolicy.queueWrite);
}

// ── texture→texture subresource copies (plan 06) ─────────────────────────────

/**
 * @typedef {{ textureId: number, mipLevel?: number, origin?: OriginInput,
 *   aspect?: AspectName | number | string }} SubresourceEndpointInput
 * @typedef {{ source: SubresourceEndpointInput, destination: SubresourceEndpointInput,
 *   size?: ExtentInput | null }} SubresourceCopyInput
 * @typedef {{ mip: MipExtent, copyExtent: Extent }} EndpointLayout
 * @typedef {{ ok: { source: EndpointLayout, destination: EndpointLayout,
 *   copyExtent: Extent } } | { refuse: Refusal }} SubresourceCopyResult
 */

/**
 * A format's texel-block size, independent of aspect. `null` for a sentinel or
 * an unknown format byte — the copy refuses rather than inventing a footprint.
 * @param {string | number} format
 * @returns {{ width: number, height: number } | null}
 */
function copyBlock(format) {
  const row = resolveFormat(format);
  if (row !== null) return { width: row.blockWidth, height: row.blockHeight };
  const compressed = compressedFacts(format);
  return compressed === null
    ? null
    : { width: compressed.blockWidth, height: compressed.blockHeight };
}

/**
 * @param {string | number} format
 * @returns {boolean}
 */
function formatHasDepthOrStencil(format) {
  const row = resolveFormat(format);
  return row !== null && (row.hasDepth || row.hasStencil);
}

/**
 * `copyTextureToTexture`'s aspect rule: both endpoints carry `all`. For a
 * depth-stencil format that means all aspects on both sides (CRD
 * `index.bs:11192-11195`) — deliberately the opposite of plan 02's write path,
 * which requires one aspect. A colour format accepts only `all` too.
 *
 * @param {string | number} format
 * @param {AspectName | number | string | null | undefined} aspect
 * @returns {Refusal | null}
 */
function copyAspectRefusal(format, aspect) {
  if (resolveFormat(format) === null && compressedFacts(format) === null) {
    return refusal("invalid-format", "format");
  }
  const tag = aspectTag(aspect);
  if (tag !== 0) return refusal("invalid-aspect", "aspect", tag, 0);
  return null;
}

/**
 * WebGPU `copy-compatible`: equal, or equal except for the `-srgb` suffix.
 * @param {string | number} source
 * @param {string | number} destination
 * @returns {boolean}
 */
function copyCompatible(source, destination) {
  const src = resolveFormat(source);
  const dst = resolveFormat(destination);
  if (src === null || dst === null) {
    // Compressed rows alternate linear then sRGB in adjacent bytes (plan 07's
    // order), so a pair sharing `byte & 0xfe` is the same format modulo sRGB.
    const srcCompressed = compressedFacts(source);
    const dstCompressed = compressedFacts(destination);
    return srcCompressed !== null && dstCompressed !== null &&
      srcCompressed.family === dstCompressed.family &&
      (srcCompressed.byte | 1) === (dstCompressed.byte | 1);
  }
  if (src.byte === dst.byte) return true;
  const sibling = {
    "rgba8unorm": "rgba8unorm-srgb",
    "rgba8unorm-srgb": "rgba8unorm",
    "bgra8unorm": "bgra8unorm-srgb",
    "bgra8unorm-srgb": "bgra8unorm",
  };
  return sibling[src.name] === dst.name;
}

/**
 * `copyTextureToTexture`'s aspect-COPYABILITY rule, named before any range
 * arithmetic. Every aspect the format actually has must be copyable on this
 * side:
 *   - `depth24plus` (and the depth aspect of `depth24plus-stencil8`) has no
 *     copy footprint, so it is never a valid copy source (`invalid-format`);
 *   - `depth32float` (and the depth aspect of `depth32float-stencil8`) is a
 *     valid copy source but not a copy destination (`aspect-not-writable`).
 * A depth-only aspect on a stencil-only texture, or the reverse, is refused by
 * `copyAspectRefusal`'s `invalid-aspect` before reaching a footprint lookup.
 *
 * @param {string | number} format
 * @param {"source" | "destination"} role
 * @returns {Refusal | null}
 */
function copyFormatRefusal(format, role) {
  const row = resolveFormat(format);
  if (row === null) {
    return compressedFacts(format) === null ? refusal("invalid-format", "format") : null;
  }

  if (row.hasDepth) {
    if (role === "source") {
      if (row.depthBytesPerBlock === 0) return refusal("invalid-format", "format");
    } else if (!row.depthWriteDestination) {
      return refusal("aspect-not-writable", "aspect");
    }
  }
  if (row.hasStencil) {
    if (role === "source") {
      if (row.stencilBytesPerBlock === 0) return refusal("invalid-format", "format");
    } else if (!row.stencilWriteDestination) {
      return refusal("aspect-not-writable", "aspect");
    }
  }
  if (!row.hasDepth && !row.hasStencil && row.colorBytesPerBlock === 0) {
    return refusal("invalid-format", "format");
  }
  return null;
}

/**
 * Resolve one `GPUTexelCopyTextureInfo` against its concrete descriptor:
 * aspect, mip range, physical mip extent, origin, explicit-or-remaining copy
 * extent and block alignment. `size === undefined/null` is the source's
 * omission rule (the remaining physical extent at the origin) and the same
 * `resolveCopyExtent` plan 01's write/buffer-copy paths use.
 *
 * @param {TextureDescriptorInput} descriptor
 * @param {{ mipLevel: number, origin: Origin, aspect: AspectName | number }} endpoint
 * @param {ExtentInput | null | undefined} size
 * @returns {{ ok: EndpointLayout } | { refuse: Refusal }}
 */
function calculateCopyEndpoint(descriptor, endpoint, size) {
  const descriptorRefusal = validateDescriptor(descriptor);
  if (descriptorRefusal !== null) return { refuse: descriptorRefusal };

  const block = copyBlock(descriptor.format);
  if (block === null) return { refuse: refusal("invalid-format", "format") };
  const aspectProblem = copyAspectRefusal(descriptor.format, endpoint.aspect);
  if (aspectProblem !== null) return { refuse: aspectProblem };
  if (endpoint.mipLevel >= descriptor.mipLevelCount) {
    return {
      refuse: refusal(
        "mip-out-of-range",
        "mip-level",
        endpoint.mipLevel,
        descriptor.mipLevelCount,
      ),
    };
  }

  const mip = mipExtent(
    /** @type {Extent} */ (descriptor.size),
    /** @type {Dimension} */ (descriptor.dimension),
    endpoint.mipLevel,
    block.width,
    block.height,
  );
  if ("refuse" in mip) return { refuse: mip.refuse };
  const physical = mip.ok.physical;

  const originProblem = originRefusal(endpoint.origin, physical);
  if (originProblem !== null) return { refuse: originProblem };

  const copyResult = resolveCopyExtent(physical, endpoint.origin, { size: size ?? null });
  if ("refuse" in copyResult) return { refuse: copyResult.refuse };
  const copy = copyResult.value;

  const blockProblem = blockAlignmentRefusal(
    endpoint.origin,
    copy,
    block.width,
    block.height,
  );
  if (blockProblem !== null) return { refuse: blockProblem };

  return { ok: { mip: mip.ok, copyExtent: copy } };
}

/**
 * Normalize one endpoint's optional fields without inventing a resource:
 * a missing object is malformed, and absent mip/origin/aspect take the IDL
 * defaults. `textureId` is carried for the same-texture disjoint rule.
 *
 * @param {unknown} value
 * @returns {{ textureId: number, mipLevel: number, origin: Origin,
 *   aspect: AspectName | number } | null}
 */
function normalizeCopyEndpoint(value) {
  if (value === null || typeof value !== "object") return null;
  const endpoint = /** @type {SubresourceEndpointInput} */ (value);
  const origin = readOrigin(endpoint.origin);
  if ("refuse" in origin) return null;
  return {
    textureId: typeof endpoint.textureId === "number" ? endpoint.textureId : 0,
    mipLevel: endpoint.mipLevel ?? 0,
    origin: origin.value,
    aspect: /** @type {AspectName | number} */ (endpoint.aspect ?? "all"),
  };
}

/**
 * Plan 06's `copyTextureToTexture` calculator. Stages, first refusal stable:
 * both descriptors, usage (COPY_SRC / COPY_DST), sample-count equality,
 * copy-compatible formats, each endpoint's per-role aspect copyability, the
 * source endpoint (aspect/mip/origin/extent/block), the destination endpoint
 * against the RESOLVED source extent, the depth-stencil/MSAA full-subresource
 * rule, then the same-texture disjoint-subresource rule (`index.bs:11196`).
 * The default size is plan 01's remaining physical source extent — one
 * calculation, no second formula.
 *
 * @param {TextureDescriptorInput} sourceDescriptor
 * @param {TextureDescriptorInput} destinationDescriptor
 * @param {SubresourceCopyInput} copy
 * @returns {SubresourceCopyResult}
 */
export function calculateTextureCopy(sourceDescriptor, destinationDescriptor, copy) {
  const normalizedSource = normalizeDescriptor(sourceDescriptor);
  if ("refuse" in normalizedSource) return { refuse: normalizedSource.refuse };
  const normalizedDestination = normalizeDescriptor(destinationDescriptor);
  if ("refuse" in normalizedDestination) return { refuse: normalizedDestination.refuse };
  const source = normalizedSource.value;
  const destination = normalizedDestination.value;

  const sourceDescriptorRefusal = validateDescriptor(source);
  if (sourceDescriptorRefusal !== null) return { refuse: sourceDescriptorRefusal };
  const destinationDescriptorRefusal = validateDescriptor(destination);
  if (destinationDescriptorRefusal !== null) return { refuse: destinationDescriptorRefusal };

  const sourceUsage = readBounded("usage", source.usage, 0xff);
  if ("refuse" in sourceUsage) return { refuse: sourceUsage.refuse };
  if ((sourceUsage.value & 1) === 0) {
    return {
      refuse: refusal("missing-copy-src", "usage", sourceUsage.value, 1),
    };
  }
  const destinationUsage = readBounded("usage", destination.usage, 0xff);
  if ("refuse" in destinationUsage) return { refuse: destinationUsage.refuse };
  if ((destinationUsage.value & 2) === 0) {
    return {
      refuse: refusal("missing-copy-dst", "usage", destinationUsage.value, 2),
    };
  }

  const sourceSamples = readBounded("sample-count", source.sampleCount, U32_MAX);
  if ("refuse" in sourceSamples) return { refuse: sourceSamples.refuse };
  const destinationSamples = readBounded("sample-count", destination.sampleCount, U32_MAX);
  if ("refuse" in destinationSamples) return { refuse: destinationSamples.refuse };
  if (sourceSamples.value !== destinationSamples.value) {
    return {
      refuse: refusal(
        "sample-count-mismatch",
        "sample-count",
        sourceSamples.value,
        destinationSamples.value,
      ),
    };
  }

  if (!copyCompatible(source.format, destination.format)) {
    const src = resolveFormat(source.format);
    const dst = resolveFormat(destination.format);
    return {
      refuse: refusal(
        "invalid-format",
        "format",
        src === null ? 0 : src.byte,
        dst === null ? 0 : dst.byte,
      ),
    };
  }
  // Each endpoint's format must be copyable on its side BEFORE any extent is
  // resolved: an absent aspect footprint would otherwise read as a zero-size
  // range and surface as a downstream range error.
  const sourceFormatRefusal = copyFormatRefusal(source.format, "source");
  if (sourceFormatRefusal !== null) return { refuse: sourceFormatRefusal };
  const destinationFormatRefusal = copyFormatRefusal(destination.format, "destination");
  if (destinationFormatRefusal !== null) return { refuse: destinationFormatRefusal };

  const copyInput = copy !== null && typeof copy === "object" ? copy : {};
  const sourceEndpoint = normalizeCopyEndpoint(copyInput.source);
  const destinationEndpoint = normalizeCopyEndpoint(copyInput.destination);
  if (sourceEndpoint === null || destinationEndpoint === null) {
    return { refuse: refusal("invalid-texture-descriptor", "none") };
  }

  const sourceLayout = calculateCopyEndpoint(source, sourceEndpoint, copyInput.size);
  if ("refuse" in sourceLayout) return { refuse: sourceLayout.refuse };
  const destinationLayout = calculateCopyEndpoint(
    destination,
    destinationEndpoint,
    sourceLayout.ok.copyExtent,
  );
  if ("refuse" in destinationLayout) return { refuse: destinationLayout.refuse };

  // For a depth-stencil or multisampled endpoint the copy must cover the
  // ENTIRE physical subresource (CRD `sections/copies.bs:263-266`). Extent
  // equality also forces the origin to zero through the range checks above.
  if (formatHasDepthOrStencil(source.format) || sourceSamples.value > 1) {
    const partial = fullSubresourceRefusal(
      sourceEndpoint.origin,
      sourceLayout.ok.copyExtent,
      sourceLayout.ok.mip.physical,
      "partial-subresource-copy",
    );
    if (partial !== null) return { refuse: partial };
  }
  if (formatHasDepthOrStencil(destination.format) || destinationSamples.value > 1) {
    const partial = fullSubresourceRefusal(
      destinationEndpoint.origin,
      destinationLayout.ok.copyExtent,
      destinationLayout.ok.mip.physical,
      "partial-subresource-copy",
    );
    if (partial !== null) return { refuse: partial };
  }

  // A copy within one texture may not share a subresource (mip + aspect +
  // layer/slice), even when the texel ranges inside it would not overlap.
  // Both endpoints carry `all` aspects, so only the mip and z ranges differ.
  if (
    sourceEndpoint.textureId === destinationEndpoint.textureId &&
    sourceEndpoint.mipLevel === destinationEndpoint.mipLevel &&
    sourceLayout.ok.copyExtent.depthOrArrayLayers > 0
  ) {
    const srcStart = sourceEndpoint.origin.z;
    const dstStart = destinationEndpoint.origin.z;
    const srcEnd = srcStart + sourceLayout.ok.copyExtent.depthOrArrayLayers;
    const dstEnd = dstStart + sourceLayout.ok.copyExtent.depthOrArrayLayers;
    if (srcStart < dstEnd && dstStart < srcEnd) {
      return {
        refuse: refusal(
          "overlapping-subresources",
          "mip-level",
          sourceEndpoint.mipLevel,
          destinationEndpoint.mipLevel,
        ),
      };
    }
  }

  return {
    ok: {
      source: sourceLayout.ok,
      destination: destinationLayout.ok,
      copyExtent: sourceLayout.ok.copyExtent,
    },
  };
}
