# Declarative Data Generation Plan

> **Status**: Partially superseded by `cpu-wasm-data-initialization-plan.md`.
> The `fill=` syntax was never implemented. Use `#init` macro with compute
> shaders instead. The compute-first principle remains valid.

## Overview

This document describes how to enable CPU-side procedural data generation in
pngine without relying on nested WASM (which is problematic on iOS and other
native platforms).

**Goal**: Allow buffers to be initialized with procedural data (noise,
positions, matrices, complex math) declared entirely in the .pngine DSL file.

**Constraints**:

- Must work on all platforms (browser, iOS, Android, desktop)
- No nested WASM dependency
- Declarative specification in .pngine files
- **Payload (.pngb) must be small** - no large pre-computed blobs
- **Executor (WASM) must be small** - no complex VM in runtime

---

## Design Principle: Compute-First

The key insight: **WGSL code compresses better than data, and the executor
already has compute dispatch.**

| Approach           | Payload Size             | Executor Size | Use Case            |
| ------------------ | ------------------------ | ------------- | ------------------- |
| Pre-computed bytes | Large (N × stride)       | +0 lines      | Small static meshes |
| Compute shader     | Small (~150B compressed) | +0 lines      | Everything else     |

For 1000 particles (32 bytes each):

- Pre-computed: 32KB raw → 8KB compressed
- Compute WGSL: 400 bytes → 150 bytes compressed

**Compute shaders win for anything > 1KB of data.**

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    .pngine Source                           │
│                                                             │
│  fill=cubeMesh        initCompute={ shader dispatch }       │
│       ↓                         ↓                           │
│  ┌──────────────┐         ┌──────────────┐                  │
│  │ Compile-time │         │ Compute      │                  │
│  │ Generator    │         │ Shader       │                  │
│  └──────┬───────┘         └──────┬───────┘                  │
│         ↓                        ↓                          │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              .pngb Payload                          │    │
│  │  - Small static data (meshes < 2KB)                 │    │
│  │  - WGSL shader code (compresses well)               │    │
│  │  - Compute dispatch commands                        │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│                 Runtime Executor (tiny)                     │
│                                                             │
│  1. memcpy pre-computed data to buffers                     │
│  2. dispatch compute shaders (existing infrastructure)      │
│                                                             │
│  Added code: ~0 lines (uses existing compute dispatch)      │
└─────────────────────────────────────────────────────────────┘
```

---

## Two-Tier Approach

| Tier           | Mechanism          | Where    | Use Case                               |
| -------------- | ------------------ | -------- | -------------------------------------- |
| **1. Static**  | Pre-computed bytes | Compiler | Small meshes (< 2KB compressed)        |
| **2. Dynamic** | Compute shader     | GPU      | Particles, noise, matrices, large data |

---

## Tier 1: Compile-Time Generators

For small, static geometry that doesn't vary at runtime. Generated in the
**compiler**, not the executor.

### When to Use

- Output < 2KB compressed
- Same data for every instance
- No runtime variation needed

### Supported Generators

```
#buffer cubeVertices {
  fill=cubeMesh {
    size=1.0
    format=pos_normal_uv
  }
}
// Output: 36 vertices × 32 bytes = 1152 bytes → ~400 bytes compressed

#buffer cubeIndices {
  fill=cubeIndices { }
}
// Output: 36 × 2 bytes = 72 bytes

#buffer planeVertices {
  fill=planeMesh {
    width=10.0
    depth=10.0
    subdivisionsX=4
    subdivisionsZ=4
    format=pos_normal_uv
  }
}

#buffer indices {
  fill=sequence {
    type=u32
    count=256
    start=0
    step=1
  }
}
// Output: 256 × 4 bytes = 1024 bytes → ~200 bytes compressed
```

### Generator Reference

| Generator       | Output   | Params                             | Typical Size |
| --------------- | -------- | ---------------------------------- | ------------ |
| `cubeMesh`      | vertices | size, format                       | 1.1KB        |
| `sphereMesh`    | vertices | radius, segments, format           | 2-8KB        |
| `planeMesh`     | vertices | width, depth, subdivisions, format | varies       |
| `cubeIndices`   | u16/u32  | -                                  | 72B          |
| `sphereIndices` | u16/u32  | segments                           | varies       |
| `planeIndices`  | u16/u32  | subdivisions                       | varies       |
| `sequence`      | scalar   | count, start, step                 | 4×count      |

see their implementation in JS in
/Users/hugo/Development/specs-llm/repositories/webgpu-samples/sample/**

### Vertex Format Options

| Format          | Floats/Vertex | Bytes | Layout                 |
| --------------- | ------------- | ----- | ---------------------- |
| `pos`           | 3             | 12    | position only          |
| `pos_normal`    | 6             | 24    | position + normal      |
| `pos_uv`        | 5             | 20    | position + uv          |
| `pos_normal_uv` | 8             | 32    | position + normal + uv |

---

## Tier 2: Compute Shader Init

For everything else. The WGSL code lives in the payload and compresses well.
Execution uses existing compute dispatch infrastructure.

### Syntax

```
#wgsl initParticles {
  value="
    struct Particle {
      pos: vec3f,
      vel: vec3f,
      life: f32,
      _pad: f32,
    }

    @group(0) @binding(0) var<storage, read_write> particles: array<Particle>;
    @group(0) @binding(1) var<uniform> params: vec4u;  // seed, count, _, _

    // PCG random - compact and fast
    fn pcg(state: ptr<function, u32>) -> f32 {
      *state = *state * 747796405u + 2891336453u;
      let word = ((*state >> ((*state >> 28u) + 4u)) ^ *state) * 277803737u;
      return f32((word >> 22u) ^ word) / 4294967295.0;
    }

    // Fibonacci sphere point distribution
    fn spherePoint(i: u32, n: u32) -> vec3f {
      let phi = (1.0 + sqrt(5.0)) / 2.0;
      let theta = 2.0 * 3.14159 * f32(i) / phi;
      let z = 1.0 - 2.0 * (f32(i) + 0.5) / f32(n);
      let r = sqrt(1.0 - z * z);
      return vec3f(r * cos(theta), r * sin(theta), z);
    }

    @compute @workgroup_size(64)
    fn main(@builtin(global_invocation_id) id: vec3u) {
      let i = id.x;
      let count = params.y;
      if (i >= count) { return; }

      var state = params.x + i;  // seed + index

      let pos = spherePoint(i, count) * mix(5.0, 15.0, pcg(&state));
      let vel = normalize(pos) * mix(0.5, 2.0, pcg(&state));
      let life = pcg(&state);

      particles[i] = Particle(pos, vel, life, 0.0);
    }
  "
}

#computePipeline initParticlesPipeline {
  layout=auto
  compute={ module=initParticles entryPoint="main" }
}

#buffer particles {
  size=131072  // 4096 particles × 32 bytes
  usage=[VERTEX STORAGE]
}

#buffer initParams {
  size=16
  usage=[UNIFORM]
  data=[12345 4096 0 0]  // seed, count
}

#bindGroup initBindGroup {
  layout={ pipeline=initParticlesPipeline index=0 }
  entries=[
    { binding=0 resource={ buffer=particles } }
    { binding=1 resource={ buffer=initParams } }
  ]
}

#computePass initParticlesPass {
  pipeline=initParticlesPipeline
  bindGroups=[initBindGroup]
  dispatchWorkgroups=[64 1 1]  // 64 workgroups × 64 threads = 4096
}

#frame init {
  perform=[initParticlesPass]
  runOnce=true  // Only run on first frame
}
```

### Common WGSL Snippets

These patterns fit in ~100-300 bytes of WGSL each:

#### PCG Random (Minimal)

```wgsl
fn pcg(state: ptr<function, u32>) -> f32 {
  *state = *state * 747796405u + 2891336453u;
  let word = ((*state >> ((*state >> 28u) + 4u)) ^ *state) * 277803737u;
  return f32((word >> 22u) ^ word) / 4294967295.0;
}
```

#### Perlin Noise 2D

```wgsl
fn hash2(p: vec2f) -> f32 {
  let h = dot(p, vec2f(127.1, 311.7));
  return fract(sin(h) * 43758.5453);
}

fn noise2d(p: vec2f) -> f32 {
  let i = floor(p);
  let f = fract(p);
  let u = f * f * (3.0 - 2.0 * f);
  return mix(
    mix(hash2(i), hash2(i + vec2f(1, 0)), u.x),
    mix(hash2(i + vec2f(0, 1)), hash2(i + vec2f(1, 1)), u.x),
    u.y
  ) * 2.0 - 1.0;
}
```

#### FBM (Fractal Brownian Motion)

```wgsl
fn fbm(p: vec2f, octaves: u32) -> f32 {
  var sum = 0.0;
  var amp = 0.5;
  var freq = 1.0;
  var pos = p;
  for (var i = 0u; i < octaves; i++) {
    sum += amp * noise2d(pos * freq);
    amp *= 0.5;
    freq *= 2.0;
  }
  return sum;
}
```

#### Fibonacci Sphere

```wgsl
fn spherePoint(i: u32, n: u32) -> vec3f {
  let phi = (1.0 + sqrt(5.0)) / 2.0;
  let theta = 2.0 * 3.14159 * f32(i) / phi;
  let z = 1.0 - 2.0 * (f32(i) + 0.5) / f32(n);
  let r = sqrt(1.0 - z * z);
  return vec3f(r * cos(theta), r * sin(theta), z);
}
```

#### Grid Position

```wgsl
fn gridPos(i: u32, cols: u32, spacing: f32) -> vec3f {
  let row = i / cols;
  let col = i % cols;
  return vec3f(f32(col) * spacing, 0.0, f32(row) * spacing);
}
```

---

## Examples

### Particle System

```
#wgsl particleInit { value="..." }  // ~400 bytes WGSL

#computePipeline initPipeline {
  layout=auto
  compute={ module=particleInit entryPoint="main" }
}

#buffer particles {
  size=1638400  // 50000 × 32 bytes
  usage=[VERTEX STORAGE]
}

#bindGroup initGroup {
  layout={ pipeline=initPipeline index=0 }
  entries=[{ binding=0 resource={ buffer=particles } }]
}

#computePass initPass {
  pipeline=initPipeline
  bindGroups=[initGroup]
  dispatchWorkgroups=[782 1 1]  // ceil(50000/64)
}

#frame init {
  perform=[initPass]
  runOnce=true
}
```

Payload: ~150 bytes compressed (WGSL) Executor: +0 lines

### Heightmap Terrain

```
#wgsl terrainInit {
  value="
    @group(0) @binding(0) var<storage, read_write> heights: array<f32>;
    @group(0) @binding(1) var<uniform> params: vec4u;  // width, height, seed, _

    // ... noise2d and fbm functions ...

    @compute @workgroup_size(8, 8)
    fn main(@builtin(global_invocation_id) id: vec3u) {
      let width = params.x;
      let height = params.y;
      if (id.x >= width || id.y >= height) { return; }

      let uv = vec2f(f32(id.x), f32(id.y)) / vec2f(f32(width), f32(height));
      let h = fbm(uv * 4.0, 6u) * 20.0;

      heights[id.y * width + id.x] = h;
    }
  "
}

#computePipeline terrainPipeline {
  layout=auto
  compute={ module=terrainInit entryPoint="main" }
}

#buffer heightmap {
  size=65536  // 128 × 128 × 4 bytes
  usage=[STORAGE]
}

#buffer terrainParams {
  size=16
  usage=[UNIFORM]
  data=[128 128 42 0]  // width, height, seed
}

#bindGroup terrainGroup {
  layout={ pipeline=terrainPipeline index=0 }
  entries=[
    { binding=0 resource={ buffer=heightmap } }
    { binding=1 resource={ buffer=terrainParams } }
  ]
}

#computePass terrainPass {
  pipeline=terrainPipeline
  bindGroups=[terrainGroup]
  dispatchWorkgroups=[16 16 1]
}

#frame init {
  perform=[terrainPass]
  runOnce=true
}
```

Payload: ~300 bytes compressed Executor: +0 lines

### Instance Transforms (Grid of Objects)

```
#wgsl instanceInit {
  value="
    @group(0) @binding(0) var<storage, read_write> transforms: array<mat4x4f>;
    @group(0) @binding(1) var<uniform> params: vec4u;  // cols, rows, seed, _

    fn pcg(state: ptr<function, u32>) -> f32 { ... }

    fn rotationY(angle: f32) -> mat4x4f {
      let c = cos(angle);
      let s = sin(angle);
      return mat4x4f(
        vec4f(c, 0, s, 0),
        vec4f(0, 1, 0, 0),
        vec4f(-s, 0, c, 0),
        vec4f(0, 0, 0, 1)
      );
    }

    @compute @workgroup_size(64)
    fn main(@builtin(global_invocation_id) id: vec3u) {
      let i = id.x;
      let cols = params.x;
      let rows = params.y;
      if (i >= cols * rows) { return; }

      var state = params.z + i;
      let col = i % cols;
      let row = i / cols;

      let x = (f32(col) - f32(cols-1) * 0.5) * 3.0;
      let z = (f32(row) - f32(rows-1) * 0.5) * 3.0;
      let angle = pcg(&state) * 6.28318;
      let scale = 0.8 + pcg(&state) * 0.4;

      var m = rotationY(angle);
      m[0] *= scale;
      m[1] *= scale;
      m[2] *= scale;
      m[3] = vec4f(x, 0, z, 1);

      transforms[i] = m;
    }
  "
}
```

### Boids Initial State

```
#wgsl boidsInit {
  value="
    struct Boid { pos: vec2f, vel: vec2f }

    @group(0) @binding(0) var<storage, read_write> boids: array<Boid>;
    @group(0) @binding(1) var<uniform> params: vec4u;

    fn pcg(state: ptr<function, u32>) -> f32 { ... }

    @compute @workgroup_size(64)
    fn main(@builtin(global_invocation_id) id: vec3u) {
      let i = id.x;
      if (i >= params.y) { return; }

      var state = params.x + i;

      boids[i] = Boid(
        vec2f(pcg(&state), pcg(&state)) * 2.0 - 1.0,
        vec2f(pcg(&state), pcg(&state)) * 0.2 - 0.1
      );
    }
  "
}
```

---

## Bytecode Format Extension

Add `initCompute` field to buffer definitions:

```
Buffer Definition (extended):
┌─────────────────────────────────────────┐
│ ... existing buffer fields ...          │
├─────────────────────────────────────────┤
│ has_init: u8 (0 = no, 1 = compute)      │
│ -- if has_init == 1 --                  │
│ init_pipeline_id: u16                   │
│ init_dispatch: [3]u32                   │
│ init_bind_group_id: u16                 │
└─────────────────────────────────────────┘
```

Or use a separate init section:

```
Init Section (0x06):
┌─────────────────────────────────────────┐
│ section_type: u8 = 0x06                 │
│ section_size: u32                       │
├─────────────────────────────────────────┤
│ init_count: u16                         │
├─────────────────────────────────────────┤
│ InitEntry[init_count]:                  │
│   buffer_id: u16                        │
│   pipeline_id: u16                      │
│   bind_group_id: u16                    │
│   dispatch: [3]u32                      │
└─────────────────────────────────────────┘
```

---

## Implementation

### Compiler Changes

| File                   | Change                                    |
| ---------------------- | ----------------------------------------- |
| `src/dsl/Token.zig`    | Add `initCompute`, `runOnce` keywords     |
| `src/dsl/Parser.zig`   | Parse `initCompute` block in buffer/frame |
| `src/dsl/Analyzer.zig` | Validate pipeline/dispatch references     |
| `src/dsl/Emitter.zig`  | Emit init section or extended buffer def  |
| `src/dsl/generators/`  | **NEW** - Compile-time mesh generators    |

### Executor Changes

**None required.** Compute dispatch already exists. The only change is reading
the init section and dispatching before the first frame.

```zig
// In dispatcher.zig - minimal addition
pub fn executeInit(self: *Dispatcher, init_section: []const u8) void {
    // Parse init entries and dispatch compute passes
    // Uses existing dispatchCompute() infrastructure
}
```

~20 lines of new code.

### Generator Implementation (Compiler-Side)

```zig
// src/dsl/generators/cube.zig
pub fn generateCubeMesh(format: VertexFormat) []const u8 {
    // Pre-compute 36 vertices with positions, normals, UVs
    // Returns static byte slice
}

// src/dsl/generators/sphere.zig
pub fn generateSphereMesh(
    radius: f32,
    width_segments: u32,
    height_segments: u32,
    format: VertexFormat,
) []u8 {
    // Generate sphere vertices at compile time
}
```

This code runs in the **compiler**, not the executor.

---

## Size Analysis

### Payload Comparison

| Data                    | Pre-computed | Compute WGSL |
| ----------------------- | ------------ | ------------ |
| Cube mesh               | 400B         | overkill     |
| 100 particles           | 1KB          | 150B         |
| 1000 particles          | 8KB          | 150B         |
| 10000 particles         | 80KB         | 150B         |
| 128×128 heightmap       | 16KB         | 200B         |
| 100 instance transforms | 6.4KB        | 200B         |

### Executor Impact

| Approach      | Lines Added | WASM Size |
| ------------- | ----------- | --------- |
| Compute-first | ~20         | +0.5KB    |
| Full DataVM   | ~800-1200   | +15-25KB  |

---

## Decision Tree

```
Need to generate buffer data?
│
├─ Is it a standard mesh (cube, sphere, plane)?
│  └─ YES → Use compile-time generator (Tier 1)
│
├─ Is output < 1KB?
│  └─ YES → Consider compile-time, or compute if varying
│
└─ Otherwise → Use compute shader (Tier 2)
```

---

## What NOT to Implement

These were in the original plan but are **removed**:

- **DataVM bytecode interpreter** - Compute shaders handle this
- **Noise opcodes** - WGSL snippets instead
- **Matrix opcodes** - WGSL snippets instead
- **Expression language parser** - Not needed
- **Expression compiler** - Not needed

This removes ~1000 lines of potential executor code.

---

## Summary

**Tier 1 (Compile-time)**: Small static meshes, generated in compiler

- cubeMesh, sphereMesh, planeMesh, sequence
- Output: raw bytes in .pngb data section
- Executor: +0 lines

**Tier 2 (Compute shaders)**: Everything else

- Particles, noise, matrices, large datasets
- Output: WGSL code in .pngb (compresses well)
- Executor: +20 lines (dispatch init passes)

**Result**:

- Payload: Small (WGSL compresses to ~150-300 bytes)
- Executor: Small (+20 lines, +0.5KB WASM)
- Capability: Full (anything expressible in WGSL)

---

## Related Documents

- `docs/multiplatform-command-buffer-plan.md` - Platform architecture
- `docs/video-support-plan.md` - Video texture handling
