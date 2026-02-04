# Shadertoy to PNGine Conversion Tool

## Overview

This document outlines the design and implementation plan for a tool that
converts Shadertoy shaders (GLSL ES) to PNGine format (WGSL + DSL).

**Goal**: Enable artists to take existing Shadertoy creations and run them as
self-contained PNGs via PNGine.

**Scope**: Single-pass shaders first, then multipass, with graceful degradation
for unsupported features.

---

## Table of Contents

1. [Shadertoy Architecture](#1-shadertoy-architecture)
2. [GLSL ES vs WGSL Differences](#2-glsl-es-vs-wgsl-differences)
3. [Conversion Strategy](#3-conversion-strategy)
4. [Tool Architecture](#4-tool-architecture)
5. [Implementation Phases](#5-implementation-phases)
6. [Input Formats](#6-input-formats)
7. [Output Format](#7-output-format)
8. [Testing Strategy](#8-testing-strategy)
9. [Limitations and Unsupported Features](#9-limitations-and-unsupported-features)

---

## 1. Shadertoy Architecture

### 1.1 Implicit Uniforms

Shadertoy provides these uniforms automatically to every shader:

```glsl
uniform vec3      iResolution;           // viewport resolution (pixels)
uniform float     iTime;                 // playback time (seconds)
uniform float     iTimeDelta;            // render time (seconds)
uniform float     iFrameRate;            // shader frame rate
uniform int       iFrame;                // playback frame number
uniform float     iChannelTime[4];       // channel playback time (seconds)
uniform vec3      iChannelResolution[4]; // channel resolution (pixels)
uniform vec4      iMouse;                // mouse: xy=current, zw=click position
uniform sampler2D iChannel0;             // input channel 0
uniform sampler2D iChannel1;             // input channel 1
uniform sampler2D iChannel2;             // input channel 2
uniform sampler2D iChannel3;             // input channel 3
uniform vec4      iDate;                 // (year, month, day, seconds)
uniform float     iSampleRate;           // sound sample rate (44100)
```

### 1.2 Entry Point

```glsl
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // fragCoord: pixel coordinates, (0,0) at bottom-left
    // fragColor: output color (RGBA)
}
```

### 1.3 Coordinate System

- `fragCoord.xy`: Pixel coordinates, origin at **bottom-left**
- `iResolution.xy`: Canvas size in pixels
- Normalized UV: `fragCoord / iResolution.xy` gives `[0,1]` range

### 1.4 Multipass (Buffers)

Shadertoy supports up to 4 buffer passes (A, B, C, D) plus final Image pass:

```
Buffer A ──┐
Buffer B ──┼──► Image (final output)
Buffer C ──┤
Buffer D ──┘
```

Each buffer:
- Has its own `mainImage` function
- Can read from any channel (textures, other buffers, itself for feedback)
- Renders to an offscreen texture (same size as viewport)
- Persists across frames (enables feedback/simulation)

### 1.5 Channel Types

| Type | Description | Sampler Type |
|------|-------------|--------------|
| Texture | 2D image | `sampler2D` |
| Cubemap | 6-face environment map | `samplerCube` |
| Volume | 3D texture | `sampler3D` |
| Video | Video file | `sampler2D` |
| Audio | FFT/waveform | `sampler2D` (512x2) |
| Keyboard | Key states | `sampler2D` (256x3) |
| Buffer | Other pass output | `sampler2D` |

### 1.6 Texture Sampling

```glsl
// Standard filtered sampling (uv in [0,1])
vec4 color = texture(iChannel0, uv);

// Direct texel fetch (integer coordinates)
vec4 texel = texelFetch(iChannel0, ivec2(x, y), 0);

// With LOD
vec4 color = textureLod(iChannel0, uv, lod);
```

### 1.7 Common Shader Pattern

```glsl
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // Normalized coordinates [0,1]
    vec2 uv = fragCoord / iResolution.xy;

    // Centered coordinates [-aspect, aspect] x [-1, 1]
    vec2 p = (2.0 * fragCoord - iResolution.xy) / iResolution.y;

    // Animation
    float t = iTime;

    // Output
    fragColor = vec4(color, 1.0);
}
```

---

## 2. GLSL ES vs WGSL Differences

### 2.1 Type Names

| GLSL ES | WGSL | Notes |
|---------|------|-------|
| `float` | `f32` | |
| `int` | `i32` | |
| `uint` | `u32` | |
| `bool` | `bool` | Same |
| `vec2` | `vec2f` | Or `vec2<f32>` |
| `vec3` | `vec3f` | |
| `vec4` | `vec4f` | |
| `ivec2` | `vec2i` | Or `vec2<i32>` |
| `ivec3` | `vec3i` | |
| `ivec4` | `vec4i` | |
| `uvec2` | `vec2u` | |
| `mat2` | `mat2x2f` | Or `mat2x2<f32>` |
| `mat3` | `mat3x3f` | |
| `mat4` | `mat4x4f` | |
| `sampler2D` | `texture_2d<f32>` + `sampler` | Separate objects |

### 2.2 Variable Declarations

```glsl
// GLSL
float x = 1.0;
const float PI = 3.14159;
vec3 color = vec3(1.0, 0.0, 0.0);
```

```wgsl
// WGSL
var x: f32 = 1.0;           // mutable
let x = 1.0;                // immutable (inferred type)
const PI = 3.14159;         // compile-time constant
var color = vec3f(1.0, 0.0, 0.0);
```

### 2.3 Function Declarations

```glsl
// GLSL
float square(float x) {
    return x * x;
}

void modify(inout vec3 v) {
    v *= 2.0;
}
```

```wgsl
// WGSL
fn square(x: f32) -> f32 {
    return x * x;
}

fn modify(v: ptr<function, vec3f>) {
    *v *= 2.0;
}
```

### 2.4 Out Parameters

```glsl
// GLSL - Shadertoy entry point
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    fragColor = vec4(1.0);
}
```

```wgsl
// WGSL - must use pointer
fn mainImage(fragColor: ptr<function, vec4f>, fragCoord: vec2f) {
    *fragColor = vec4f(1.0);
}

// Or return directly in wrapper
@fragment
fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
    var fragColor: vec4f;
    mainImage(&fragColor, pos.xy);
    return fragColor;
}
```

### 2.5 Texture Sampling

```glsl
// GLSL
vec4 c = texture(iChannel0, uv);
vec4 t = texelFetch(iChannel0, ivec2(x, y), 0);
```

```wgsl
// WGSL - texture and sampler are separate
@group(0) @binding(1) var tex0: texture_2d<f32>;
@group(0) @binding(2) var samp0: sampler;

let c = textureSample(tex0, samp0, uv);
let t = textureLoad(tex0, vec2u(x, y), 0);
```

### 2.6 Built-in Functions

| GLSL | WGSL | Notes |
|------|------|-------|
| `mod(x, y)` | `x % y` | **Different behavior for negatives!** |
| `fract(x)` | `fract(x)` | Same |
| `mix(a, b, t)` | `mix(a, b, t)` | Same |
| `clamp(x, lo, hi)` | `clamp(x, lo, hi)` | Same |
| `atan(y, x)` | `atan2(y, x)` | **Different name!** |
| `atan(x)` | `atan(x)` | Same (single arg) |
| `dFdx(x)` | `dpdx(x)` | Different name |
| `dFdy(x)` | `dpdy(x)` | Different name |
| `fwidth(x)` | `fwidth(x)` | Same |
| `inversesqrt(x)` | `inverseSqrt(x)` | Different case |
| `lessThan(a, b)` | `a < b` | Returns bool in WGSL |
| `step(edge, x)` | `step(edge, x)` | Same |
| `smoothstep(e0, e1, x)` | `smoothstep(e0, e1, x)` | Same |

### 2.7 The `mod` Problem

GLSL's `mod(x, y)` always returns a positive result:
```glsl
mod(-1.0, 3.0) == 2.0  // GLSL
```

WGSL's `%` operator follows C semantics:
```wgsl
-1.0 % 3.0 == -1.0     // WGSL
```

**Solution**: Replace `mod(x, y)` with `((x % y) + y) % y` or define a helper:

```wgsl
fn glsl_mod(x: f32, y: f32) -> f32 {
    return x - y * floor(x / y);
}
```

### 2.8 Swizzling and Constructors

```glsl
// GLSL
vec3 a = vec3(1.0);           // (1, 1, 1)
vec4 b = vec4(a, 1.0);        // (1, 1, 1, 1)
vec2 c = a.xy;                // (1, 1)
a.rgb = a.bgr;                // swizzle assignment
```

```wgsl
// WGSL
var a = vec3f(1.0);           // (1, 1, 1)
var b = vec4f(a, 1.0);        // (1, 1, 1, 1)
var c = a.xy;                 // (1, 1)
a = vec3f(a.b, a.g, a.r);     // no swizzle assignment!
```

### 2.9 Arrays

```glsl
// GLSL
float arr[3] = float[](1.0, 2.0, 3.0);
int len = arr.length();
```

```wgsl
// WGSL
var arr = array<f32, 3>(1.0, 2.0, 3.0);
let len = 3u;  // size must be compile-time known
```

### 2.10 Preprocessor

```glsl
// GLSL
#define PI 3.14159
#define SQR(x) ((x) * (x))
#ifdef FEATURE
  // ...
#endif
```

```wgsl
// WGSL - no preprocessor!
const PI = 3.14159;
fn sqr(x: f32) -> f32 { return x * x; }
// Conditional compilation: use override constants or code generation
```

---

## 3. Conversion Strategy

### 3.1 High-Level Pipeline

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              INPUT                                          │
│  Shadertoy JSON or raw GLSL code                                            │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         1. PARSE & ANALYZE                                  │
│  - Extract shader code per renderpass                                       │
│  - Identify used uniforms (iTime, iResolution, iChannelN, etc.)             │
│  - Identify used functions (texture, texelFetch, mod, atan, etc.)           │
│  - Extract channel configuration (textures, buffers)                        │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        2. GLSL → WGSL SYNTAX                                │
│  Option A: Naga (robust, handles edge cases)                                │
│  Option B: Regex transforms (fast, may miss edge cases)                     │
│  Option C: Custom parser (most control, most work)                          │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                     3. SHADERTOY → PNGINE MAPPING                           │
│  - Add uniform struct with used uniforms only                               │
│  - Add texture/sampler bindings for used channels                           │
│  - Wrap mainImage in @fragment entry point                                  │
│  - Fix coordinate system (flip Y if needed)                                 │
│  - Replace iChannelN references with texture/sampler calls                  │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      4. GENERATE .pngine FILE                               │
│  - #wgsl shader with converted code                                         │
│  - #buffer for uniforms                                                     │
│  - #texture for each channel texture                                        │
│  - #sampler for texture sampling                                            │
│  - #bindGroup, #renderPipeline, #renderPass                                 │
│  - #frame with proper execution order                                       │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            OUTPUT                                           │
│  - .pngine file (ready for pngine compile)                                  │
│  - Downloaded textures (if any)                                             │
│  - Warnings for unsupported features                                        │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Uniform Mapping

| Shadertoy | PNGine Uniform Struct | Size |
|-----------|----------------------|------|
| `iResolution` | `resolution: vec3f` | 12B (+4 pad) |
| `iTime` | `time: f32` | 4B |
| `iTimeDelta` | `timeDelta: f32` | 4B |
| `iFrameRate` | `frameRate: f32` | 4B |
| `iFrame` | `frame: i32` | 4B |
| `iMouse` | `mouse: vec4f` | 16B |
| `iDate` | `date: vec4f` | 16B |
| `iChannelResolution[4]` | `channelRes: array<vec4f, 4>` | 64B |

**Optimized struct** (only include what's used):

```wgsl
// Minimal (most shaders)
struct Uniforms {
    resolution: vec3f,  // iResolution
    time: f32,          // iTime
}

// With mouse
struct Uniforms {
    resolution: vec3f,
    time: f32,
    mouse: vec4f,       // iMouse
}

// Full (rare)
struct Uniforms {
    resolution: vec3f,
    time: f32,
    timeDelta: f32,
    frameRate: f32,
    frame: i32,
    _pad0: i32,
    mouse: vec4f,
    date: vec4f,
    channelRes: array<vec4f, 4>,
}
```

### 3.3 Entry Point Wrapper

```wgsl
// Converted mainImage (original logic)
fn mainImage(fragColor: ptr<function, vec4f>, fragCoord: vec2f) {
    // ... converted shader code ...
}

// Fullscreen triangle vertex shader
@vertex
fn vs(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4f {
    // Generates fullscreen triangle from vertex index
    let x = f32((vi << 1u) & 2u);
    let y = f32(vi & 2u);
    return vec4f(x * 2.0 - 1.0, y * 2.0 - 1.0, 0.0, 1.0);
}

// Fragment shader entry point
@fragment
fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
    var fragColor: vec4f;
    // Flip Y: Shadertoy has (0,0) at bottom-left, WebGPU at top-left
    let fragCoord = vec2f(pos.x, u.resolution.y - pos.y);
    mainImage(&fragColor, fragCoord);
    return fragColor;
}
```

### 3.4 Texture Channel Mapping

For each used `iChannelN`:

```wgsl
// Bindings (group 0, binding 1+ for textures)
@group(0) @binding(1) var channel0_tex: texture_2d<f32>;
@group(0) @binding(2) var channel0_samp: sampler;
@group(0) @binding(3) var channel1_tex: texture_2d<f32>;
@group(0) @binding(4) var channel1_samp: sampler;
// ... etc

// Helper functions to match Shadertoy API
fn texChannel0(uv: vec2f) -> vec4f {
    return textureSample(channel0_tex, channel0_samp, uv);
}

fn texelChannel0(coord: vec2i, lod: i32) -> vec4f {
    return textureLoad(channel0_tex, vec2u(coord), lod);
}
```

Then replace in shader:
- `texture(iChannel0, uv)` → `texChannel0(uv)`
- `texelFetch(iChannel0, coord, lod)` → `texelChannel0(coord, lod)`

### 3.5 Common Function Replacements

```wgsl
// GLSL mod() compatibility
fn glsl_mod(x: f32, y: f32) -> f32 {
    return x - y * floor(x / y);
}

fn glsl_mod2(x: vec2f, y: vec2f) -> vec2f {
    return x - y * floor(x / y);
}

fn glsl_mod3(x: vec3f, y: vec3f) -> vec3f {
    return x - y * floor(x / y);
}

// Note: atan2 already exists in WGSL
// Just need to rename: atan(y, x) → atan2(y, x)
```

---

## 4. Tool Architecture

### 4.1 Component Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           shadertoy2pngine                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────────────┐ │
│  │  Input Parser   │    │  GLSL→WGSL      │    │  PNGine Generator       │ │
│  │                 │    │  Transpiler     │    │                         │ │
│  │  - JSON (API)   │───►│                 │───►│  - Uniform struct       │ │
│  │  - Raw GLSL     │    │  - Naga WASM    │    │  - Texture bindings     │ │
│  │  - Annotated    │    │  - or Regex     │    │  - Entry point wrapper  │ │
│  │    paste        │    │                 │    │  - .pngine DSL          │ │
│  └─────────────────┘    └─────────────────┘    └─────────────────────────┘ │
│           │                                              │                  │
│           │         ┌─────────────────┐                  │                  │
│           └────────►│  Analyzer       │◄─────────────────┘                  │
│                     │                 │                                     │
│                     │  - Used uniforms│                                     │
│                     │  - Used channels│                                     │
│                     │  - Function deps│                                     │
│                     └─────────────────┘                                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Implementation Location

**Recommended: Hybrid JS + Zig**

| Component | Language | Reason |
|-----------|----------|--------|
| Input parsing | JavaScript | JSON handling, string manipulation |
| GLSL→WGSL | Naga WASM | Robust, battle-tested |
| Shadertoy transforms | JavaScript | Regex, string templates |
| .pngine generation | JavaScript | Template strings |
| Final compilation | Zig (pngine CLI) | Existing toolchain |

**Alternative: Pure Zig** (if we want single binary)

| Component | Implementation |
|-----------|----------------|
| Input parsing | `std.json` |
| GLSL→WGSL | Shell out to `naga-cli` or custom transform |
| Shadertoy transforms | String manipulation in Zig |
| .pngine generation | Zig `std.fmt` |

### 4.3 Naga Integration Options

**Option A: naga-cli as external tool**
```bash
# User installs naga-cli
cargo install naga-cli

# Converter shells out
naga input.frag --profile es300 output.wgsl
```
- Pros: Simple, always up-to-date
- Cons: External dependency, slower (process spawn)

**Option B: Naga compiled to WASM**
```javascript
// In browser or Node
import { glslToWgsl } from './naga.wasm';
const wgsl = glslToWgsl(glslCode, { profile: 'es300' });
```
- Pros: No external dependency, fast after load
- Cons: ~500KB WASM, need to build/maintain

**Option C: Direct regex transforms**
```javascript
// Simple but fragile
function glslToWgsl(code) {
    return code
        .replace(/\bvec2\b/g, 'vec2f')
        .replace(/\bvec3\b/g, 'vec3f')
        .replace(/\bmat3\b/g, 'mat3x3f')
        .replace(/\bmod\s*\(/g, 'glsl_mod(')
        // ... many more
}
```
- Pros: Zero dependencies, tiny, fast
- Cons: Fragile, won't handle complex cases

**Recommendation**: Start with Option C (regex) for MVP, graduate to Option A or B
for robustness.

### 4.4 CLI Interface

```bash
# Basic usage - paste code, get .pngine
shadertoy2pngine input.glsl -o output.pngine

# From Shadertoy JSON (e.g., from API)
shadertoy2pngine shader.json -o output.pngine

# With texture downloads
shadertoy2pngine shader.json -o output.pngine --download-textures

# Specify Shadertoy ID (fetches via API if key is set)
shadertoy2pngine --id XsBXWt -o output.pngine

# Validate only (check what would be converted)
shadertoy2pngine input.glsl --validate

# Verbose output (show warnings, unsupported features)
shadertoy2pngine input.glsl -o output.pngine --verbose
```

### 4.5 Web Interface

For easier adoption, a web-based converter:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Shadertoy → PNGine Converter                                    [?] [⚙]   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────┐    ┌─────────────────────────────────────┐│
│  │ Input (GLSL)                │    │ Output (.pngine)                    ││
│  │                             │    │                                     ││
│  │ void mainImage(out vec4    │    │ #wgsl shader {                      ││
│  │   fragColor,                │    │   value="                           ││
│  │   in vec2 fragCoord) {     │    │     struct Uniforms {               ││
│  │     vec2 uv = fragCoord /   │    │       resolution: vec3f,            ││
│  │       iResolution.xy;       │    │       time: f32,                    ││
│  │     fragColor = vec4(uv,   │    │     }                               ││
│  │       sin(iTime), 1.0);     │ ►► │     ...                             ││
│  │ }                           │    │   "                                 ││
│  │                             │    │ }                                   ││
│  │                             │    │ #buffer uniforms { ... }            ││
│  │                             │    │ #frame main { ... }                 ││
│  └─────────────────────────────┘    └─────────────────────────────────────┘│
│                                                                             │
│  Channels: [None ▾] [None ▾] [None ▾] [None ▾]                              │
│                                                                             │
│  ⚠ Warnings:                                                                │
│    - iMouse used but not yet supported in PNGine                            │
│                                                                             │
│  [Convert] [Copy Output] [Download .pngine] [Download .png]                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. Implementation Phases

### Phase 1: MVP - Single Pass, No Textures (Week 1-2)

**Scope**:
- Single `mainImage` function
- `iTime`, `iResolution` uniforms only
- No texture channels
- Regex-based GLSL→WGSL

**Deliverables**:
- `tools/shadertoy2pngine.js` script
- Basic CLI: `node tools/shadertoy2pngine.js input.glsl -o output.pngine`
- Test with 10 simple Shadertoy shaders

**Supported shaders**: ~30% of Shadertoy

**Example input**:
```glsl
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec3 col = 0.5 + 0.5 * cos(iTime + uv.xyx + vec3(0, 2, 4));
    fragColor = vec4(col, 1.0);
}
```

**Example output**:
```
#wgsl shader {
  value="
    struct Uniforms {
        resolution: vec3f,
        time: f32,
    }
    @group(0) @binding(0) var<uniform> u: Uniforms;

    fn mainImage(fragColor: ptr<function, vec4f>, fragCoord: vec2f) {
        let uv = fragCoord / u.resolution.xy;
        let col = 0.5 + 0.5 * cos(u.time + uv.xyx + vec3f(0.0, 2.0, 4.0));
        *fragColor = vec4f(col, 1.0);
    }

    @vertex fn vs(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4f {
        let x = f32((vi << 1u) & 2u);
        let y = f32(vi & 2u);
        return vec4f(x * 2.0 - 1.0, y * 2.0 - 1.0, 0.0, 1.0);
    }

    @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
        var fragColor: vec4f;
        let fragCoord = vec2f(pos.x, u.resolution.y - pos.y);
        mainImage(&fragColor, fragCoord);
        return fragColor;
    }
  "
}

#buffer uniforms {
  size=16
  usage=[UNIFORM COPY_DST]
}

#bindGroupLayout mainLayout {
  entries=[
    { binding=0 visibility=[FRAGMENT] type=buffer }
  ]
}

#bindGroup main {
  layout=$bindGroupLayout.mainLayout
  entries=[
    { binding=0 buffer=$buffer.uniforms }
  ]
}

#renderPipeline pipe {
  vertex={ module=$wgsl.shader entryPoint="vs" }
  fragment={ module=$wgsl.shader entryPoint="fs" targets=[{format=canvas}] }
}

#renderPass render {
  pipeline=$renderPipeline.pipe
  bindGroups=[$bindGroup.main]
  draw=3
}

#queue writeUniforms {
  writeBuffer={
    buffer=uniforms
    bufferOffset=0
    data=pngineInputs
  }
}

#frame main {
  perform=[writeUniforms render]
}
```

### Phase 2: Texture Channels (Week 3-4)

**Scope**:
- `iChannel0-3` as 2D textures
- `texture()` and `texelFetch()` calls
- Texture URL extraction from Shadertoy JSON
- Optional texture embedding or external reference

**Deliverables**:
- Texture binding generation
- Sampler configuration (filter, wrap modes)
- `--download-textures` flag

**Supported shaders**: ~60% of Shadertoy

### Phase 3: Multipass Buffers (Week 5-6)

**Scope**:
- Buffer A/B/C/D renderpasses
- Buffer-to-buffer dependencies
- Feedback loops (buffer reading itself)

**Deliverables**:
- Multi-renderpass .pngine generation
- Ping-pong buffer setup for feedback
- Proper pass ordering

**Supported shaders**: ~80% of Shadertoy

### Phase 4: Additional Uniforms (Week 7-8)

**Scope**:
- `iMouse` (requires PNGine runtime addition)
- `iFrame`, `iTimeDelta`, `iFrameRate`
- `iDate`
- `iChannelResolution`

**Deliverables**:
- Extended uniform struct
- PNGine runtime mouse input support
- Frame counter support

**Supported shaders**: ~90% of Shadertoy

### Phase 5: Advanced Features (Future)

**Scope**:
- Cubemap textures
- Video textures
- Audio/FFT input
- Keyboard input
- VR mode

**Supported shaders**: ~95%+ of Shadertoy

---

## 6. Input Formats

### 6.1 Shadertoy API JSON

From `https://www.shadertoy.com/api/v1/shaders/{id}?key={apiKey}`:

```json
{
  "Shader": {
    "ver": "0.1",
    "info": {
      "id": "XsBXWt",
      "date": "1424942564",
      "viewed": 123456,
      "name": "Example Shader",
      "username": "author",
      "description": "Description...",
      "likes": 1234,
      "published": 3,
      "flags": 0,
      "usePreview": 0,
      "tags": ["raymarching", "3d"],
      "hasliked": 0
    },
    "renderpass": [
      {
        "inputs": [
          {
            "id": 257,
            "src": "/media/a/0a40562379b63dfb89227e6d172f39fdce9022cba76623f1054a2c83d6c0ba5d.png",
            "ctype": "texture",
            "channel": 0,
            "sampler": {
              "filter": "mipmap",
              "wrap": "repeat",
              "vflip": "true",
              "srgb": "false",
              "internal": "byte"
            },
            "published": 1
          }
        ],
        "outputs": [
          { "id": 37, "channel": 0 }
        ],
        "code": "void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n    ...\n}",
        "name": "Image",
        "description": "",
        "type": "image"
      },
      {
        "inputs": [],
        "outputs": [{ "id": 257, "channel": 0 }],
        "code": "void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n    ...\n}",
        "name": "Buffer A",
        "description": "",
        "type": "buffer"
      }
    ]
  }
}
```

### 6.2 Annotated GLSL (Manual Paste)

For users without API access:

```glsl
// SHADERTOY: XsBXWt
// NAME: Example Shader
// AUTHOR: username
//
// CHANNEL0: texture https://www.shadertoy.com/media/a/0a40562379b63dfb89227e6d172f39fdce9022cba76623f1054a2c83d6c0ba5d.png
// CHANNEL0_FILTER: mipmap
// CHANNEL0_WRAP: repeat
//
// CHANNEL1: buffer BufferA
//
// PASS: Image
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    fragColor = texture(iChannel0, uv);
}

// PASS: BufferA
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // Buffer A code...
}
```

### 6.3 Raw GLSL (Minimal)

Just the shader code, analyzer detects uniforms:

```glsl
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec3 col = 0.5 + 0.5 * cos(iTime + uv.xyx);
    fragColor = vec4(col, 1.0);
}
```

---

## 7. Output Format

### 7.1 Generated .pngine Structure

```
// =============================================================================
// Auto-generated by shadertoy2pngine
// Source: https://www.shadertoy.com/view/XsBXWt
// Name: Example Shader
// Author: username
// =============================================================================

// -----------------------------------------------------------------------------
// WGSL Shader
// -----------------------------------------------------------------------------
#wgsl shader {
  value="
    // Shadertoy compatibility uniforms
    struct Uniforms {
        resolution: vec3f,
        time: f32,
        // mouse: vec4f,  // Uncomment if iMouse is used
    }
    @group(0) @binding(0) var<uniform> iGlobals: Uniforms;

    // Shadertoy compatibility aliases
    alias iResolution = iGlobals.resolution;
    alias iTime = iGlobals.time;
    // alias iMouse = iGlobals.mouse;

    // Channel textures (if used)
    // @group(0) @binding(1) var iChannel0: texture_2d<f32>;
    // @group(0) @binding(2) var iChannel0_sampler: sampler;

    // GLSL mod() compatibility
    fn glsl_mod(x: f32, y: f32) -> f32 {
        return x - y * floor(x / y);
    }

    // --- Converted shader code begins ---
    fn mainImage(fragColor: ptr<function, vec4f>, fragCoord: vec2f) {
        // ... converted code ...
    }
    // --- Converted shader code ends ---

    // Fullscreen triangle vertex shader
    @vertex fn vs(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4f {
        let x = f32((vi << 1u) & 2u);
        let y = f32(vi & 2u);
        return vec4f(x * 2.0 - 1.0, y * 2.0 - 1.0, 0.0, 1.0);
    }

    // Fragment entry point
    @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
        var fragColor: vec4f;
        let fragCoord = vec2f(pos.x, iResolution.y - pos.y);
        mainImage(&fragColor, fragCoord);
        return fragColor;
    }
  "
}

// -----------------------------------------------------------------------------
// Resources
// -----------------------------------------------------------------------------
#buffer uniforms {
  size=16
  usage=[UNIFORM COPY_DST]
}

#bindGroupLayout mainLayout {
  entries=[
    { binding=0 visibility=[VERTEX FRAGMENT] type=buffer }
  ]
}

#bindGroup main {
  layout=$bindGroupLayout.mainLayout
  entries=[
    { binding=0 buffer=$buffer.uniforms }
  ]
}

#renderPipeline pipe {
  vertex={ module=$wgsl.shader entryPoint="vs" }
  fragment={ module=$wgsl.shader entryPoint="fs" targets=[{format=canvas}] }
  primitive={ topology=triangle-list }
}

#renderPass render {
  pipeline=$renderPipeline.pipe
  bindGroups=[$bindGroup.main]
  draw=3
}

// -----------------------------------------------------------------------------
// Frame
// -----------------------------------------------------------------------------
#queue writeUniforms {
  writeBuffer={
    buffer=uniforms
    bufferOffset=0
    data=pngineInputs
  }
}

#frame main {
  perform=[writeUniforms render]
}
```

### 7.2 With Textures

Additional resources for texture channels:

```
#texture channel0 {
  // Embedded data or external URL
  // data=$data.channel0_pixels
  url="https://www.shadertoy.com/media/a/..."
  format=rgba8unorm
}

#sampler sampler0 {
  addressModeU=repeat
  addressModeV=repeat
  magFilter=linear
  minFilter=linear
  mipmapFilter=linear
}

#bindGroupLayout mainLayout {
  entries=[
    { binding=0 visibility=[VERTEX FRAGMENT] type=buffer }
    { binding=1 visibility=[FRAGMENT] type=texture }
    { binding=2 visibility=[FRAGMENT] type=sampler }
  ]
}

#bindGroup main {
  layout=$bindGroupLayout.mainLayout
  entries=[
    { binding=0 buffer=$buffer.uniforms }
    { binding=1 texture=$texture.channel0 }
    { binding=2 sampler=$sampler.sampler0 }
  ]
}
```

---

## 8. Testing Strategy

### 8.1 Test Categories

| Category | Examples | Expected Support |
|----------|----------|------------------|
| Minimal | UV gradient, solid color | Phase 1 |
| Time-based | Sine waves, rotation | Phase 1 |
| Math-heavy | Raymarching, SDF | Phase 1 |
| Single texture | Image filter, distortion | Phase 2 |
| Multi-texture | Blend, composite | Phase 2 |
| Buffer feedback | Game of Life, fluid | Phase 3 |
| Mouse input | Interactive paint | Phase 4 |
| Complex multipass | Path tracing | Phase 3+ |

### 8.2 Test Shaders

**Phase 1 Test Set**:
1. `void mainImage(out vec4 c, vec2 f) { c = vec4(f/iResolution.xy, 0, 1); }` - minimal
2. Seascape by TDM - raymarching, iTime only
3. Protean clouds by nimitz - noise, iTime only
4. Happy Jumping by iq - SDF animation
5. Rainbow Plasma - classic demo effect

**Phase 2 Test Set**:
6. Image blur - single texture
7. Edge detection - single texture
8. Texture blend - multiple textures

**Phase 3 Test Set**:
9. Conway's Game of Life - buffer feedback
10. Simple fluid simulation - multi-buffer

### 8.3 Validation Workflow

```bash
# 1. Convert
node tools/shadertoy2pngine.js test/seascape.glsl -o test/seascape.pngine

# 2. Compile
./zig-out/bin/pngine compile test/seascape.pngine -o test/seascape.pngb

# 3. Check (validate bytecode)
./zig-out/bin/pngine check test/seascape.pngb --verbose

# 4. Render frame
./zig-out/bin/pngine test/seascape.pngine --frame -s 512x512 -o test/seascape.png

# 5. Visual comparison with Shadertoy screenshot
```

---

## 9. Limitations and Unsupported Features

### 9.1 Known Limitations

| Feature | Status | Workaround |
|---------|--------|------------|
| Cubemaps | Not supported | Convert to equirectangular |
| 3D textures | Not supported | Use 2D atlas |
| Video input | Not supported | Use image sequence |
| Audio/FFT | Not supported | Pre-bake to texture |
| Keyboard | Not supported | Remove interactivity |
| VR mode | Not supported | - |
| Sound output | Not supported | - |
| `#define` macros | Partially supported | Manual expansion |
| Complex `#ifdef` | Not supported | Manual selection |

### 9.2 GLSL Features Not in WGSL

| GLSL Feature | WGSL Equivalent | Notes |
|--------------|-----------------|-------|
| Swizzle assignment `a.xy = b` | Manual: `a = vec3f(b.x, b.y, a.z)` | |
| `gl_FragCoord.z/w` | Not available | Depth not accessible |
| `discard` in loops | Limited | May cause issues |
| Implicit casts | Explicit required | `float(int_val)` |
| Array `.length()` | Compile-time size | Must know size |

### 9.3 Error Messages

The converter should provide helpful errors:

```
⚠ Warning: iMouse used but not yet supported in PNGine runtime
  → Shader will work but mouse input will be zero
  → Lines: 15, 23, 45

⚠ Warning: textureLod() used - converting to textureSample()
  → LOD parameter will be ignored
  → Lines: 67

✗ Error: samplerCube (cubemap) not supported
  → Cannot convert iChannel2 which uses cubemap
  → Consider: Convert to equirectangular projection

✗ Error: #define with parameters not supported
  → Line 5: #define ROTATE(a) mat2(cos(a), -sin(a), sin(a), cos(a))
  → Workaround: Expand macro manually to function
```

---

## Appendix A: Regex Transform Rules (Phase 1)

```javascript
const transforms = [
  // Types
  [/\bvec2\b/g, 'vec2f'],
  [/\bvec3\b/g, 'vec3f'],
  [/\bvec4\b/g, 'vec4f'],
  [/\bivec2\b/g, 'vec2i'],
  [/\bivec3\b/g, 'vec3i'],
  [/\bivec4\b/g, 'vec4i'],
  [/\buvec2\b/g, 'vec2u'],
  [/\buvec3\b/g, 'vec3u'],
  [/\buvec4\b/g, 'vec4u'],
  [/\bmat2\b/g, 'mat2x2f'],
  [/\bmat3\b/g, 'mat3x3f'],
  [/\bmat4\b/g, 'mat4x4f'],
  [/\bfloat\b/g, 'f32'],
  [/\bint\b/g, 'i32'],
  [/\buint\b/g, 'u32'],

  // Shadertoy uniforms
  [/\biResolution\b/g, 'u.resolution'],
  [/\biTime\b/g, 'u.time'],
  [/\biMouse\b/g, 'u.mouse'],

  // Functions
  [/\bmod\s*\(/g, 'glsl_mod('],
  [/\batan\s*\(\s*([^,]+)\s*,\s*([^)]+)\s*\)/g, 'atan2($1, $2)'],
  [/\bdFdx\b/g, 'dpdx'],
  [/\bdFdy\b/g, 'dpdy'],
  [/\binversesqrt\b/g, 'inverseSqrt'],

  // Variable declarations (simple cases)
  [/\bconst\s+(vec\df|mat\dx\df|f32|i32)\s+(\w+)\s*=/g, 'const $2: $1 ='],

  // Entry point (handled specially, not regex)
];
```

---

## Appendix B: PNGine Runtime Changes Needed

### B.1 Extended pngineInputs

Current:
```javascript
// 16 bytes
struct PngineInputs {
    time: f32,
    canvasWidth: f32,
    canvasHeight: f32,
    aspect: f32,
}
```

Extended for Shadertoy:
```javascript
// 64 bytes (fits in single uniform buffer write)
struct ShadertoyInputs {
    resolution: vec3f,      // 12 bytes
    time: f32,              // 4 bytes
    timeDelta: f32,         // 4 bytes
    frameRate: f32,         // 4 bytes
    frame: i32,             // 4 bytes
    _pad: i32,              // 4 bytes (alignment)
    mouse: vec4f,           // 16 bytes
    date: vec4f,            // 16 bytes
}
```

### B.2 Mouse Input Support

Add to PNGine JS runtime:
```javascript
// Track mouse state
let mouseX = 0, mouseY = 0;
let mouseClickX = 0, mouseClickY = 0;
let mouseDown = false;

canvas.addEventListener('mousemove', (e) => {
    mouseX = e.offsetX;
    mouseY = canvas.height - e.offsetY;  // Flip Y
});

canvas.addEventListener('mousedown', (e) => {
    mouseDown = true;
    mouseClickX = e.offsetX;
    mouseClickY = canvas.height - e.offsetY;
});

canvas.addEventListener('mouseup', () => {
    mouseDown = false;
});

// In frame update:
const mouseVec = new Float32Array([
    mouseX, mouseY,
    mouseDown ? mouseClickX : -mouseClickX,
    mouseDown ? mouseClickY : -mouseClickY
]);
```

---

## Appendix C: Reference Implementations

- [pygfx/shadertoy](https://github.com/pygfx/shadertoy) - Python, uses wgpu
- [bevy_shadertoy_wgsl](https://github.com/eliotbo/bevy_shadertoy_wgsl) - Rust/Bevy
- [WgShadertoy](https://github.com/fralonra/wgshadertoy) - Rust standalone
- [glsl2wgsl](https://eliotbo.github.io/glsl2wgsl/) - Web converter
- [Naga](https://github.com/gfx-rs/naga) - Rust shader transpiler
