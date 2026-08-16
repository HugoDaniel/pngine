// setUniform's value → bytes conversion: the UniformType tag table and the
// per-type packers.
//
// Split out of gpu.js (Phase 4 of the js-runtime-hardening plan) because it is
// the one part of that file with no GPU in it — pure, module-scoped, already
// unit-tested on its own, and coupled instead to the WIRE format: the UT_* tags
// must match uniform_table.zig, which tests/npm/uniform-type-lanes.test.js pins
// by parsing THIS file. gpu.js keeps a re-export so `import { uniformToTypedArray }
// from "./gpu.js"` still resolves.
//
// ## Invariants
// - A tag this runtime doesn't recognize is packed as f32 rather than dropped:
//   255 (unreflectable) is a legitimate wire value, and an unknown one means the
//   payload is newer than the runtime. Best-effort beats a blank frame.
// - Array fields expand at the WIRE stride (size / elemCount), not packed —
//   WGSL uniform-space array strides are 16-byte multiples.

// Build flag — see gpu.js. Guarded so this module is importable raw.
if (typeof DEBUG === "undefined") globalThis.DEBUG = false;

// UniformType enum values (must match uniform_table.zig — the coupling is
// gated by tests/npm/uniform-type-lanes.test.js)
const UT_F32 = 0, UT_I32 = 1, UT_U32 = 2;
const UT_VEC2F = 3, UT_VEC3F = 4, UT_VEC4F = 5;
const UT_MAT3X3F = 6, UT_MAT4X4F = 7;
const UT_VEC2I = 8, UT_VEC3I = 9, UT_VEC4I = 10;
const UT_VEC2U = 11, UT_VEC3U = 12, UT_VEC4U = 13;
const UT_UNKNOWN = 255; // unreflectable field type — best-effort f32 by design
// Input lanes (JS numbers) per single value of each type — used to slice a
// flat array into per-element chunks for array uniforms. Scalars and unknown
// tags fall back to 1 (matches convertOne's f32 best-effort default).
const UT_LANES = {
  [UT_VEC2F]: 2, [UT_VEC2I]: 2, [UT_VEC2U]: 2,
  [UT_VEC3F]: 3, [UT_VEC3I]: 3, [UT_VEC3U]: 3,
  [UT_VEC4F]: 4, [UT_VEC4I]: 4, [UT_VEC4U]: 4,
  [UT_MAT3X3F]: 9, // row-major input, padded to 48B on convert
  [UT_MAT4X4F]: 16,
};

/**
 * Convert JS value to a TypedArray-backed byte view based on UniformType.
 * For array fields (elemCount > 0) the value is expanded per-element at the
 * wire-implied stride (size / elemCount — WGSL uniform-space array strides
 * are 16-byte multiples, so elements are padded, not packed). Accepts flat
 * ([1,2,3,4,5,6]) or nested ([[1,2,3],[4,5,6]]) input; missing trailing
 * elements stay zero. Exported for tests/npm/gpu-uniform-arrays.test.js.
 * @param {number|number[]|number[][]} value
 * @param {number} uniformType - UniformType enum value (the ELEMENT type for arrays)
 * @param {number} size - Expected byte size (TOTAL array bytes for arrays)
 * @param {number} [elemCount] - Array element count; 0/undefined = not an array
 * @returns {Uint8Array|null}
 */
export function uniformToTypedArray(value, uniformType, size, elemCount) {
  const arr = Array.isArray(value) ? value : [value];
  if (!elemCount) return convertOne(/** @type {number[]} */ (arr), uniformType, size); // not an array field
  const stride = Math.floor(size / elemCount);
  if (stride === 0) return convertOne(/** @type {number[]} */ (arr), uniformType, size); // degenerate wire data
  const lanes = UT_LANES[uniformType] || 1;
  const out = new Uint8Array(size);
  // `nested` picks which of the two shapes `arr` actually is; the two views
  // below just name that invariant so each branch reads as the shape it needs.
  const nested = Array.isArray(arr[0]);
  const rows = /** @type {number[][]} */ (arr);
  const flat = /** @type {number[]} */ (arr);
  for (let i = 0; i < elemCount; i++) {
    const elem = nested ? rows[i] : flat.slice(i * lanes, (i + 1) * lanes);
    if (!elem || elem.length === 0) break; // short input: rest stays zero
    const chunk = convertOne(elem, uniformType, stride);
    if (!chunk) return null;
    out.set(chunk.subarray(0, Math.min(chunk.length, stride)), i * stride);
  }
  return out;
}

/**
 * Convert ONE value (a normalized number[]) to bytes for a single element of
 * the given UniformType; `size` clamps the output byte length.
 * @param {number[]} arr
 * @param {number} uniformType - UniformType enum value
 * @param {number} size - Expected byte size
 * @returns {Uint8Array|null}
 */
function convertOne(arr, uniformType, size) {
  switch (uniformType) {
    case UT_F32:
    case UT_VEC2F:
    case UT_VEC3F:
    case UT_VEC4F: {
      const f32 = new Float32Array(arr);
      return new Uint8Array(f32.buffer, 0, Math.min(f32.byteLength, size));
    }

    case UT_I32:
    case UT_VEC2I:
    case UT_VEC3I:
    case UT_VEC4I: {
      const i32 = new Int32Array(arr);
      return new Uint8Array(i32.buffer, 0, Math.min(i32.byteLength, size));
    }

    case UT_U32:
    case UT_VEC2U:
    case UT_VEC3U:
    case UT_VEC4U: {
      const u32 = new Uint32Array(arr);
      return new Uint8Array(u32.buffer, 0, Math.min(u32.byteLength, size));
    }

    case UT_MAT3X3F: {
      // mat3x3 in WGSL is 3 vec4 columns (48 bytes with padding)
      // Input: 9 floats (row-major), output: 3 vec4 columns (column-major with padding)
      const f32 = new Float32Array(12); // 3 columns × 4 floats
      if (arr.length >= 9) {
        // Column 0
        f32[0] = arr[0]; f32[1] = arr[3]; f32[2] = arr[6]; f32[3] = 0;
        // Column 1
        f32[4] = arr[1]; f32[5] = arr[4]; f32[6] = arr[7]; f32[7] = 0;
        // Column 2
        f32[8] = arr[2]; f32[9] = arr[5]; f32[10] = arr[8]; f32[11] = 0;
      }
      return new Uint8Array(f32.buffer, 0, Math.min(48, size));
    }

    case UT_MAT4X4F: {
      // mat4x4 in WGSL is 4 vec4 columns (64 bytes)
      // Assume input is column-major (WebGPU convention)
      const f32 = new Float32Array(arr.length >= 16 ? arr : [...arr, ...Array(16 - arr.length).fill(0)]);
      return new Uint8Array(f32.buffer, 0, Math.min(64, size));
    }

    default: {
      // 255 (unknown) is a legitimate wire tag for unreflectable field types —
      // best-effort f32 is the designed path there. Any OTHER tag means this
      // runtime predates the tag (version skew): say so, then still try f32.
      if (uniformType !== UT_UNKNOWN) {
        DEBUG && console.warn(`[GPU] setUniform: unrecognized UniformType tag ${uniformType} — treating as f32 (runtime older than payload?)`);
      }
      const f32 = new Float32Array(arr);
      return new Uint8Array(f32.buffer, 0, Math.min(f32.byteLength, size));
    }
  }
}
