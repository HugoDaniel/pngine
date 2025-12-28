# Buffer Initialization Plan

> **Status**: Active - Phase 6 (fill opcode removal) complete.
>
> **Context**:
> - Main project guide: `CLAUDE.md`
> - Embedded executor plan: `docs/embedded-executor-plan.md`

---

## Executive Summary

Buffer initialization in PNGine uses two complementary approaches:

1. **Compile-time `#data` blocks** - Static data inlined in bytecode
2. **Compute shader `#init` macro** - GPU-generated data at runtime

The legacy fill opcodes (0x50-0x55) have been removed. All buffer initialization
now uses these two approaches.

---

## Approach 1: Compile-Time `#data` Blocks

### Current State

Static vertex data is written inline in the DSL:

```
#data cubeVertexArray {
  float32Array=[
    // 36 vertices × 10 floats = 360 values manually typed
    1 -1 1 1   1 0 1 1  0 1
    -1 -1 1 1  0 0 1 1  1 1
    // ... 34 more vertices
  ]
}

#buffer verticesBuffer {
  size=cubeVertexArray
  usage=[VERTEX]
  mappedAtCreation=cubeVertexArray
}
```

This works but is verbose for common shapes.

### Proposed: Built-in Shape Generators

Add compile-time shape generators that emit vertex data:

```
#data cubeVertexArray {
  cube={
    format=[position4 color4 uv2]   // Output format per vertex
  }
}

#data sphereVertexArray {
  sphere={
    segments=32
    rings=16
    format=[position3 normal3 uv2]
  }
}

#data planeVertexArray {
  plane={
    width=10
    height=10
    format=[position3 uv2]
  }
}
```

### Supported Shapes

| Shape | Vertices | Description |
|-------|----------|-------------|
| `cube` | 36 | Unit cube with per-face colors |
| `plane` | 6 | Single quad, XY plane |
| `sphere` | varies | UV sphere with configurable segments |
| `cylinder` | varies | Configurable segments |

### Format Specifiers

| Format | Size | Description |
|--------|------|-------------|
| `position3` | 12B | vec3f position |
| `position4` | 16B | vec4f position (w=1) |
| `normal3` | 12B | vec3f normal |
| `color3` | 12B | vec3f RGB color |
| `color4` | 16B | vec4f RGBA color |
| `uv2` | 8B | vec2f texture coordinates |

### Implementation

Shape generators run at **compile time** in the Zig compiler:

```zig
// src/dsl/emitter/shapes.zig
pub fn emitCubeVertices(format: []const FormatSpec) []const u8 {
    // Generate 36 vertices with specified attributes
    // Returns byte array to embed in data section
}
```

The executor and bytecode format remain unchanged - shapes are just a
DSL convenience that emits raw float arrays.

---

## Approach 2: Compute Shader `#init` Macro

### Use Case

For procedural data that requires computation:
- Particle systems with random positions
- Noise-based terrain heightmaps
- Instance transforms
- Any data requiring math beyond simple patterns

### Proposed Syntax

```
#wgsl initParticles {
  value="
    struct Particle { pos: vec3f, vel: vec3f }
    @group(0) @binding(0) var<storage, read_write> data: array<Particle, 10000>;
    @group(0) @binding(1) var<uniform> seed: u32;

    @compute @workgroup_size(64)
    fn main(@builtin(global_invocation_id) id: vec3u) {
      if (id.x >= 10000u) { return; }
      // PCG random, sphere distribution, etc.
      data[id.x] = Particle(randomPos(), randomVel());
    }
  "
}

#buffer particles {
  size=initParticles.data         // Auto-size from shader reflection
  usage=[VERTEX STORAGE]
}

#init resetParticles {
  buffer=particles
  shader=initParticles
  params=[12345]                  // seed value
}

#frame main {
  init=[resetParticles]           // Runs once before first frame
  perform=[updatePass renderPass]
}
```

### Key Features

1. **Auto-sizing**: `size=shaderName.varName` uses reflection to compute buffer size
2. **One-time execution**: `init=` in `#frame` runs before first frame only
3. **Params**: Compile-time constants passed to shader as uniforms
4. **Shader as source of truth**: Array size defined once in WGSL

### Behind the Scenes

The `#init` macro expands to:

```
#computePipeline _initParticles_pipeline {
  compute={ module=initParticles entryPoint="main" }
}

#buffer _initParticles_params {
  size=4
  usage=[UNIFORM]
  mappedAtCreation=[12345]        // The params values
}

#bindGroup _initParticles_bg {
  layout={ pipeline=_initParticles_pipeline index=0 }
  entries=[
    { binding=0 resource={ buffer=particles } }
    { binding=1 resource={ buffer=_initParticles_params } }
  ]
}

#computePass _initParticles_pass {
  pipeline=_initParticles_pipeline
  bindGroups=[_initParticles_bg]
  dispatch=[157 1 1]              // ceil(10000/64)
}
```

---

## Implementation Phases

### Phase 1: Built-in Shapes (compile-time)

**Files to modify**:
1. `src/dsl/Analyzer.zig` - Parse shape syntax in `#data` blocks
2. `src/dsl/emitter/shapes.zig` - New file with shape generators
3. `src/dsl/emitter/resources.zig` - Call shape generators for `cube=`, `sphere=`, etc.

**Deliverable**: `#data { cube={...} }` works, generates inline vertex data.

### Phase 2: Auto-sizing via Reflection

**Files to modify**:
1. `src/dsl/Analyzer.zig` - Parse `size=shaderName.varName` syntax
2. `src/dsl/emitter/resources.zig` - Call miniray for size computation

**Dependencies**: miniray 0.3.0+ for memory layout reflection.

**Deliverable**: `size=shader.data` computes buffer size from shader.

### Phase 3: `#init` Macro

**Files to modify**:
1. `src/dsl/Token.zig` - Add `macro_init` keyword
2. `src/dsl/Parser.zig` - Parse `#init` blocks
3. `src/dsl/Analyzer.zig` - Validate shader/buffer references
4. `src/dsl/Emitter.zig` - Expand to pipeline/bindgroup/pass

**Deliverable**: `#init { buffer= shader= params= }` works.

### Phase 4: Frame `init=` Support

**Files to modify**:
1. `src/dsl/Parser.zig` - Parse `init=` in `#frame`
2. `src/dsl/Emitter.zig` - Emit runOnce passes before regular passes

**Deliverable**: `#frame { init=[...] perform=[...] }` works.

---

## Example: Rotating Cube with Built-in Shape

### Before (360 floats manually typed)

```
#data cubeVertexArray {
  float32Array=[
    1 -1 1 1   1 0 1 1  0 1
    -1 -1 1 1  0 0 1 1  1 1
    // ... 34 more lines
  ]
}
```

### After (one line)

```
#data cubeVertexArray {
  cube={ format=[position4 color4 uv2] }
}
```

---

## Example: Particle System with `#init`

```
#wgsl initParticles {
  value="
    struct Particle {
      pos: vec3f,
      vel: vec3f,
    }

    @group(0) @binding(0) var<storage, read_write> particles: array<Particle, 10000>;
    @group(0) @binding(1) var<uniform> seed: u32;

    // PCG random number generator
    fn pcg(state: ptr<function, u32>) -> u32 {
      let old = *state;
      *state = old * 747796405u + 2891336453u;
      let word = ((old >> ((old >> 28u) + 4u)) ^ old) * 277803737u;
      return (word >> 22u) ^ word;
    }

    fn randomFloat(state: ptr<function, u32>) -> f32 {
      return f32(pcg(state)) / 4294967295.0;
    }

    fn spherePoint(state: ptr<function, u32>) -> vec3f {
      let theta = randomFloat(state) * 6.283185;
      let phi = acos(2.0 * randomFloat(state) - 1.0);
      return vec3f(
        sin(phi) * cos(theta),
        sin(phi) * sin(theta),
        cos(phi)
      );
    }

    @compute @workgroup_size(64)
    fn main(@builtin(global_invocation_id) id: vec3u) {
      if (id.x >= 10000u) { return; }
      var state = seed + id.x;
      let pos = spherePoint(&state) * randomFloat(&state) * 2.0;
      let vel = spherePoint(&state) * 0.1;
      particles[id.x] = Particle(pos, vel);
    }
  "
}

#buffer particles {
  size=initParticles.particles    // 10000 × 24 bytes = 240KB
  usage=[VERTEX STORAGE]
}

#init resetParticles {
  buffer=particles
  shader=initParticles
  params=[42]                     // seed=42
}

#frame main {
  init=[resetParticles]
  perform=[simulatePass renderPass]
}
```

---

## Phase Checklist

- [x] Phase 1: Built-in shapes (`cube=`, `plane=`) - DONE
- [ ] Phase 2: Auto-sizing via reflection (`size=shader.var`)
- [ ] Phase 3: `#init` macro
- [ ] Phase 4: Frame `init=` support
- [x] Phase 6: Remove data-gen opcodes (DONE)

---

## Design Decisions

### Why compile-time shapes instead of runtime?

1. **Smaller payload**: Shape generator is in compiler, not bytecode
2. **No executor bloat**: No mesh generation code in WASM
3. **Predictable**: Same output every time
4. **Fast**: No runtime computation for static meshes

### Why `#init` instead of reviving fill opcodes?

1. **GPU-native**: Compute shaders run on GPU, massively parallel
2. **Flexible**: Any WGSL code, not limited to predefined patterns
3. **Compressible**: WGSL compresses better than bytecode opcodes
4. **Debuggable**: Shader code visible, not opaque opcodes

### Why auto-sizing from shaders?

1. **Single source of truth**: Array size defined once in WGSL
2. **No manual calculation**: `size=shader.particles` vs `size=10000*24`
3. **Refactoring-safe**: Change struct, size updates automatically
