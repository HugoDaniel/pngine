/**
 * WebGPU Enum Lookup Tables
 * 
 * Centralized enum-to-string mappings for PNGine runtime.
 * These tables decode numeric bytecode values to WebGPU strings.
 * 
 * ═══════════════════════════════════════════════════════════════════════════
 * IMPORTANT: When adding new enum values, update BOTH:
 * 1. This file (add to appropriate array/object)
 * 2. src/types/descriptors.zig (add to Zig enum)
 * 
 * The numeric index/key in JS MUST match the enum value in Zig.
 * ═══════════════════════════════════════════════════════════════════════════
 * 
 * @see src/types/descriptors.zig - Zig enum definitions
 */

// ============================================================================
// Texture Formats
// (descriptors.zig:TextureFormat)
// Note: Non-contiguous indices due to format groupings
// ============================================================================
// Typed as GPUTextureFormat rather than plain strings so a typo in this table
// is a build error. At runtime a bad name would fall through the `??` in
// decodeTextureFormat() to the preferred canvas format — silently rendering the
// wrong format instead of failing.
/** @type {Record<number, GPUTextureFormat>} */
export const TEXTURE_FORMAT = {
    0x00: "rgba8unorm",
    0x01: "rgba8snorm",
    0x02: "rgba8uint",
    0x03: "rgba8sint",
    0x04: "bgra8unorm",
    0x05: "rgba16float",
    0x06: "rgba32float",
    0x07: "rgba8unorm-srgb",
    0x08: "bgra8unorm-srgb", // gated on core-features-and-limits
    // Gap: 0x09-0x0F reserved
    0x10: "depth24plus",
    0x11: "depth24plus-stencil8",
    0x12: "depth32float",
    0x13: "stencil8",
    0x14: "depth16unorm",
    0x15: "depth32float-stencil8", // gated on the depth32float-stencil8 feature
    // Gap: 0x16-0x1F reserved
    0x20: "r32float",
    0x21: "rg32float",
    0x22: "r32uint",
    0x23: "r32sint",
    0x24: "rg32uint",
    0x25: "rg32sint",
    // Gap: 0x26-0x2F reserved
    0x30: "r8unorm",
    0x31: "rg8unorm",
    0x32: "r16float",
    0x33: "rg16float",
    0x34: "r8snorm",
    0x35: "r8uint",
    0x36: "r8sint",
    0x37: "rg8snorm",
    0x38: "rg8uint",
    0x39: "rg8sint",
    // 16-bit int r/rg; 0x44-0x47 tier1 unorm/snorm siblings (texture-formats-tier1)
    0x40: "r16uint",
    0x41: "r16sint",
    0x42: "rg16uint",
    0x43: "rg16sint",
    0x44: "r16unorm",
    0x45: "r16snorm",
    0x46: "rg16unorm",
    0x47: "rg16snorm",
    // 16-bit int rgba; 0x52-0x53 tier1 unorm/snorm siblings (texture-formats-tier1)
    0x50: "rgba16uint",
    0x51: "rgba16sint",
    0x52: "rgba16unorm",
    0x53: "rgba16snorm",
    // 32-bit int rgba
    0x60: "rgba32uint",
    0x61: "rgba32sint",
    // packed 32-bit
    0x70: "rgb10a2unorm",
    0x71: "rgb10a2uint",
    0x72: "rg11b10ufloat",
    0x73: "rgb9e5ufloat",
    // 0xFF: Use preferred canvas format (handled specially)
};

/**
 * Decode texture format from bytecode value.
 * @param {number} v - Bytecode enum value
 * @returns {GPUTextureFormat} WebGPU texture format
 */
export function decodeTextureFormat(v) {
    return TEXTURE_FORMAT[v] ?? navigator.gpu.getPreferredCanvasFormat();
}

// ============================================================================
// Filter Modes
// (descriptors.zig:FilterMode)
// Contiguous: 0=nearest, 1=linear
// ============================================================================
export const FILTER_MODE = ["nearest", "linear"];

/**
 * Decode filter mode from bytecode value.
 * @param {number} v - 0=nearest, 1=linear
 * @returns {string} WebGPU filter mode
 */
export function decodeFilterMode(v) {
    return FILTER_MODE[v] ?? "linear";
}

// ============================================================================
// Address Modes
// (descriptors.zig:AddressMode)
// Contiguous: 0=clamp-to-edge, 1=repeat, 2=mirror-repeat
// ============================================================================
export const ADDRESS_MODE = ["clamp-to-edge", "repeat", "mirror-repeat"];

/**
 * Decode address mode from bytecode value.
 * @param {number} v - 0=clamp-to-edge, 1=repeat, 2=mirror-repeat
 * @returns {string} WebGPU address mode
 */
export function decodeAddressMode(v) {
    return ADDRESS_MODE[v] ?? "clamp-to-edge";
}

// ============================================================================
// Compare Functions
// (WebGPU standard order, add to descriptors.zig:CompareFunction)
// Contiguous: 0-7
// ============================================================================
export const COMPARE_FUNCTION = [
    "never",        // 0
    "less",         // 1
    "equal",        // 2
    "less-equal",   // 3
    "greater",      // 4
    "not-equal",    // 5
    "greater-equal",// 6
    "always",       // 7
];

/**
 * Decode compare function from bytecode value.
 * @param {number} v - 0-7
 * @returns {string} WebGPU compare function
 */
export function decodeCompareFunction(v) {
    return COMPARE_FUNCTION[v] ?? "less";
}

// NOTE: there are deliberately NO blend-factor / blend-operation tables here.
// Blend state is a PASSTHROUGH: the Emitter writes the WebGPU strings verbatim
// into the pipeline-descriptor JSON and the runtime hands them to WebGPU
// unmapped, so a byte table would be a second source of truth that can only
// drift (the ones that used to sit here were already missing the four src1
// dual-source factors). See docs/plans/spec/08 item 1.
