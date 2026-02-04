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
export const TEXTURE_FORMAT = {
    0x00: "rgba8unorm",
    0x01: "rgba8snorm",
    0x02: "rgba8uint",
    0x03: "rgba8sint",
    0x04: "bgra8unorm",
    0x05: "rgba16float",
    0x06: "rgba32float",
    // Gap: 0x07-0x0F reserved
    0x10: "depth24plus",
    0x11: "depth24plus-stencil8",
    0x12: "depth32float",
    // Gap: 0x13-0x1F reserved
    0x20: "r32float",
    0x21: "rg32float",
    // 0xFF: Use preferred canvas format (handled specially)
};

/**
 * Decode texture format from bytecode value.
 * @param {number} v - Bytecode enum value
 * @returns {string} WebGPU texture format string
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
// Primitive Topology
// (WebGPU standard order, add to descriptors.zig:PrimitiveTopology)
// Contiguous: 0-4
// ============================================================================
export const TOPOLOGY = [
    "point-list",     // 0
    "line-list",      // 1
    "line-strip",     // 2
    "triangle-list",  // 3
    "triangle-strip", // 4
];

/**
 * Decode primitive topology from bytecode value.
 * @param {number} v - 0-4
 * @returns {string} WebGPU primitive topology
 */
export function decodeTopology(v) {
    return TOPOLOGY[v] ?? "triangle-list";
}

// ============================================================================
// Cull Mode
// (WebGPU standard order, add to descriptors.zig:CullMode)
// Contiguous: 0-2
// ============================================================================
export const CULL_MODE = ["none", "front", "back"];

/**
 * Decode cull mode from bytecode value.
 * @param {number} v - 0=none, 1=front, 2=back
 * @returns {string} WebGPU cull mode
 */
export function decodeCullMode(v) {
    return CULL_MODE[v] ?? "none";
}

// ============================================================================
// Front Face
// (WebGPU standard order, add to descriptors.zig:FrontFace)
// Contiguous: 0-1
// ============================================================================
export const FRONT_FACE = ["ccw", "cw"];

/**
 * Decode front face from bytecode value.
 * @param {number} v - 0=ccw, 1=cw
 * @returns {string} WebGPU front face
 */
export function decodeFrontFace(v) {
    return FRONT_FACE[v] ?? "ccw";
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

// ============================================================================
// Blend Factors
// (WebGPU standard order - for future use)
// ============================================================================
export const BLEND_FACTOR = [
    "zero",               // 0
    "one",                // 1
    "src",                // 2
    "one-minus-src",      // 3
    "src-alpha",          // 4
    "one-minus-src-alpha",// 5
    "dst",                // 6
    "one-minus-dst",      // 7
    "dst-alpha",          // 8
    "one-minus-dst-alpha",// 9
    "src-alpha-saturated",// 10
    "constant",           // 11
    "one-minus-constant", // 12
];

// ============================================================================
// Blend Operations
// (WebGPU standard order - for future use)
// ============================================================================
export const BLEND_OPERATION = [
    "add",              // 0
    "subtract",         // 1
    "reverse-subtract", // 2
    "min",              // 3
    "max",              // 4
];
