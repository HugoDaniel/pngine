//! R4 Tier 2 — typed SJON↔WGSL agreement comparators.
//!
//! Pure functions comparing a shader's REFLECTED types (from wgslender) against
//! the SJON-DECLARED descriptors — one layer deeper than R1's structural checks
//! (binding present? buffer big enough? right kind?). Each returns whether the two
//! UNAMBIGUOUSLY disagree; the Emitter join gates every call on `validate_shaders`
//! and turns a `true` into a located `.wgsl` diagnostic + `ValidationError`.
//!
//! ## Design — conservative, class-only
//! The R3 corpus audit proved false-positives block valid art. So:
//! - A null/empty/ambiguous input is NEVER a mismatch — the caller SKIPS.
//! - Compare only the coarse SCALAR CLASS (float / sint / uint), never texture
//!   dimension or component count (WebGPU is lenient there — normalized formats
//!   read as f32, missing vertex/fragment components pad with (0,0,0,1)).
//! - Depth/stencil formats and storage textures return null (skip): WebGPU lets a
//!   depth texture sample as depth OR unfilterable-float, and wgslender already
//!   validates storage-texture formats internally.
//!
//! ## Invariants
//! - Pure: no allocation, no I/O, no global state.
//! - Total: every input maps to a defined result (unknown → null/false).

const std = @import("std");
const reflect = @import("reflect");
const values = @import("values.zig");

const TextureFormat = values.TextureFormat;
const TextureInfo = reflect.wgslender.TextureInfo;
const SamplerInfo = reflect.wgslender.SamplerInfo;

/// Coarse scalar class shared by texture formats and (later phases) vertex formats,
/// WGSL `@location` types, and color targets. `float` covers unorm/snorm/float/half
/// — every format sampled or interpolated as `f32` in-shader.
pub const ScalarClass = enum { float, sint, uint };

/// The sample class of a SJON texture `:format`, or null when the format is
/// depth / stencil / a sentinel — WebGPU is lenient about sampling those, so the
/// caller SKIPS rather than risk a false reject. `preferred-canvas-format` resolves
/// at runtime to a float (bgra8/rgba8) format, so it classifies float.
pub fn textureFormatClass(fmt: TextureFormat) ?ScalarClass {
    return switch (fmt) {
        // float-class: unorm / snorm / float / half + srgb + packed float.
        .rgba8unorm,
        .rgba8snorm,
        .bgra8unorm,
        .rgba16float,
        .rgba32float,
        .rgba8unorm_srgb,
        .bgra8unorm_srgb,
        .r32float,
        .rg32float,
        .r8unorm,
        .rg8unorm,
        .r16float,
        .rg16float,
        .r8snorm,
        .rg8snorm,
        .r16unorm,
        .r16snorm,
        .rg16unorm,
        .rg16snorm,
        .rgba16unorm,
        .rgba16snorm,
        .rgb10a2unorm,
        .rg11b10ufloat,
        .rgb9e5ufloat,
        .preferred_canvas_format,
        => .float,
        // uint-class.
        .rgba8uint,
        .r32uint,
        .rg32uint,
        .r8uint,
        .rg8uint,
        .r16uint,
        .rg16uint,
        .rgba16uint,
        .rgba32uint,
        .rgb10a2uint,
        => .uint,
        // sint-class.
        .rgba8sint,
        .r32sint,
        .rg32sint,
        .r8sint,
        .rg8sint,
        .r16sint,
        .rg16sint,
        .rgba16sint,
        .rgba32sint,
        => .sint,
        // depth / stencil (sampled as depth OR unfilterable-float — WebGPU lenient)
        // and the sentinels: skip (null), never a false reject.
        .depth24plus,
        .depth24plus_stencil8,
        .depth32float,
        .stencil8,
        .depth16unorm,
        .depth32float_stencil8,
        .invalid,
        _,
        => null,
    };
}

/// The sample class the shader declares for a sampled texture, from the reflected
/// `TextureInfo.sample_type` leaf ("f32"/"i32"/"u32"). Returns null for storage /
/// depth / external textures (sample_type empty) → the caller SKIPS. Using
/// sample_type alone (not `kind`) is what makes storage/depth/external skip
/// automatically: wgslender leaves sample_type empty for all three.
pub fn textureSampleClass(tex: TextureInfo) ?ScalarClass {
    if (std.mem.eql(u8, tex.sample_type, "f32")) return .float;
    if (std.mem.eql(u8, tex.sample_type, "i32")) return .sint;
    if (std.mem.eql(u8, tex.sample_type, "u32")) return .uint;
    return null;
}

/// Does a bound texture's SJON `:format` sample-class UNAMBIGUOUSLY disagree with
/// the shader's `texture_Nd<T>`? True only when BOTH classes are known and differ.
/// Either side null (storage / depth / external / unknown format) → false (skip).
/// Pure.
pub fn textureSampleClassMismatch(tex: TextureInfo, sjon_fmt: TextureFormat) bool {
    const shader = textureSampleClass(tex) orelse return false;
    const declared = textureFormatClass(sjon_fmt) orelse return false;
    return shader != declared;
}

/// Does a bound sampler's comparison-ness disagree with the shader's
/// `sampler` / `sampler_comparison`? Unambiguous — WebGPU rejects binding a plain
/// sampler where the shader wants a comparison sampler and vice-versa. Pure.
pub fn samplerComparisonMismatch(samp: SamplerInfo, sjon_comparison: bool) bool {
    return samp.comparison != sjon_comparison;
}

/// Does a bound STORAGE texture's SJON `:format` disagree with the shader's
/// `texture_storage_Nd<FMT, …>`? WebGPU mandates EXACT format equality for storage
/// textures (unlike sampled textures, which R4 #4 checks only by scalar class), so
/// this compares the full format enum, not the class. Fires only when the shader
/// reflects a storage texture (`kind == "storage"`) carrying a known texel format
/// AND both formats resolve to a non-sentinel enum; either side unknown/sentinel →
/// false (skip). Disjoint from `textureSampleClassMismatch` by construction: a
/// storage texture reflects an empty `sample_type` (R4 skips) but a non-empty
/// `format` (this fires); a sampled texture is the reverse. Pure.
pub fn storageTextureFormatMismatch(tex: TextureInfo, sjon_fmt: TextureFormat) bool {
    if (!std.mem.eql(u8, tex.kind, "storage")) return false;
    if (tex.format.len == 0) return false;
    const shader_fmt = values.mapTextureFormat(tex.format);
    if (shader_fmt == .invalid or shader_fmt == .preferred_canvas_format) return false;
    if (sjon_fmt == .invalid or sjon_fmt == .preferred_canvas_format) return false;
    return shader_fmt != sjon_fmt;
}

/// Human name of a scalar class, for the diagnostic message.
pub fn className(c: ScalarClass) []const u8 {
    return switch (c) {
        .float => "float",
        .sint => "sint",
        .uint => "uint",
    };
}

// --- #5/#6: WGSL `@location` type + vertex-format parsers (shared) ---

/// A parsed scalar class + component count. Phase B (#5, vertex attributes) and
/// Phase C (#6, fragment outputs) both join on `.class` only; `components` is the
/// vector width (1 for a scalar), parsed + tested here for the deferred
/// component-count check but intentionally NOT consulted by the class-only joins.
pub const TypeClass = struct { class: ScalarClass, components: u8 };

/// The scalar class + width of a WGSL `@location` type string as reflected by
/// wgslender. Handles BOTH forms the reflector emits (it preserves `vec.shorthand`):
/// the long `vecN<f32>` / scalar `f32`, and the shorthand `vecNf`/`vecNi`/`vecNu`/
/// `vecNh`. `f16`/`vecNh` classify float (half reads as f32 at an attribute).
/// Returns null on anything outside that bounded grammar (matrices, structs,
/// arrays, `vec5`, `vec4<bool>`, unknown) → the caller SKIPS. Pure.
pub fn wgslScalarClass(typ: []const u8) ?TypeClass {
    if (std.mem.startsWith(u8, typ, "vec")) {
        if (typ.len < 5) return null; // shortest valid is "vecNf" (5 chars)
        const components: u8 = switch (typ[3]) {
            '2' => 2,
            '3' => 3,
            '4' => 4,
            else => return null,
        };
        const rest = typ[4..];
        // Long form: "<f32>" / "<i32>" / "<u32>" / "<f16>".
        if (rest.len >= 2 and rest[0] == '<' and rest[rest.len - 1] == '>') {
            const leaf = rest[1 .. rest.len - 1];
            return .{ .class = scalarLeafClass(leaf) orelse return null, .components = components };
        }
        // Shorthand: a single trailing letter ("vec4f" → 'f').
        if (rest.len == 1) {
            return .{ .class = shorthandLeafClass(rest[0]) orelse return null, .components = components };
        }
        return null;
    }
    // Scalar leaf: "f32" / "f16" / "i32" / "u32".
    return .{ .class = scalarLeafClass(typ) orelse return null, .components = 1 };
}

/// Class of a WGSL scalar leaf spelled in full (`f32`/`f16`/`i32`/`u32`).
fn scalarLeafClass(leaf: []const u8) ?ScalarClass {
    if (std.mem.eql(u8, leaf, "f32")) return .float;
    if (std.mem.eql(u8, leaf, "f16")) return .float;
    if (std.mem.eql(u8, leaf, "i32")) return .sint;
    if (std.mem.eql(u8, leaf, "u32")) return .uint;
    return null;
}

/// Class of a WGSL vector shorthand suffix letter (`vec4f` → 'f', `vec2h` → 'h').
fn shorthandLeafClass(letter: u8) ?ScalarClass {
    return switch (letter) {
        'f', 'h' => .float, // f32 / f16 — both read as float
        'i' => .sint,
        'u' => .uint,
        else => null,
    };
}

/// The scalar class + component count of a SJON vertex `:format` string
/// (`uint32x4`, `float32x3`, `unorm8x4`, …). Normalized (`unorm`/`snorm`) and
/// half/float (`float16`/`float32`) formats read as f32 in-shader → float; `uint*`
/// → uint; `sint*` → sint. No member of {float,unorm,snorm,uint,sint} is a prefix
/// of another, so the order is irrelevant. Component count is the trailing `xN`
/// (none → 1; the two packed formats report their nominal parse, unused by the
/// class-only join). Returns null on an unknown spelling → the caller SKIPS. Pure.
pub fn vertexFormatClass(fmt: []const u8) ?TypeClass {
    const class: ScalarClass =
        if (std.mem.startsWith(u8, fmt, "float")) .float else if (std.mem.startsWith(u8, fmt, "unorm")) .float else if (std.mem.startsWith(u8, fmt, "snorm")) .float else if (std.mem.startsWith(u8, fmt, "uint")) .uint else if (std.mem.startsWith(u8, fmt, "sint")) .sint else return null;
    return .{ .class = class, .components = vertexFormatComponents(fmt) };
}

/// Component count from a vertex format's trailing `xN` (`float32x3` → 3); a
/// scalar format (`uint8`, `float32`) → 1. Best-effort — the join is class-only.
fn vertexFormatComponents(fmt: []const u8) u8 {
    if (std.mem.lastIndexOfScalar(u8, fmt, 'x')) |xi| {
        if (xi + 1 < fmt.len and fmt[xi + 1] >= '1' and fmt[xi + 1] <= '4')
            return fmt[xi + 1] - '0';
    }
    return 1;
}

/// The scalar class of a SJON color-target `:format` STRING (#6), or null when the
/// format is depth/stencil/unknown/a sentinel — the caller SKIPS. Deliberately
/// delegates to the exhaustive, unit-tested `textureFormatClass` table via the
/// SAME `mapTextureFormat` the emitter uses to encode the target, so there is ONE
/// source of truth: a color target and a bound texture of the same format always
/// classify identically, and a newly-added format is picked up here for free
/// (rather than a parallel prefix table that could drift — `rgb10a2unorm`,
/// `rg11b10ufloat`, `rgb9e5ufloat` all trap a naive `startsWith` matcher).
/// `preferred-canvas-format` (the canvas's own format, the spelling pass-v1 writes
/// for its canvas target) resolves to a float canvas format; an unknown spelling maps to `.invalid` →
/// null. Pure. Used by the Emitter's `checkFragmentTargets` join.
pub fn colorTargetFormatClass(fmt: []const u8) ?ScalarClass {
    return textureFormatClass(values.mapTextureFormat(fmt));
}

// --- Unit tests (the red-first spec for the pure comparators) ---

const testing = std.testing;

// --- #5: the shared WGSL type + vertex-format parsers ---

// --- #6: the color-target format parser (delegates to the texture-format table) ---
